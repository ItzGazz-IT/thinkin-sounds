begin;

alter table studio_private.project_workspaces add column mix_approved_at timestamptz;
create table studio_private.project_feedback (
  client_id uuid not null references auth.users(id) on delete cascade,
  id uuid not null,
  project_key uuid not null,
  action text not null check (action in ('revisions', 'approval')),
  notes jsonb not null,
  created_at timestamptz not null default now(),
  primary key (client_id, id)
);
alter table studio_private.project_feedback enable row level security;
create index studio_project_feedback_history on studio_private.project_feedback(client_id, project_key, created_at desc);

alter table studio_private.booking_alerts add column feedback_id uuid;
alter table studio_private.booking_alerts drop constraint booking_alerts_kind_check;
alter table studio_private.booking_alerts add constraint booking_alerts_kind_check
  check (kind in ('request', 'confirmation', 'decline', 'cancellation', 'first_mix_ready', 'masters_ready') or
    ((kind like 'reschedule:%' or kind like 'reminder:%') and scheduled_for is not null) or
    (kind like 'feedback:%' and feedback_id is not null and project_key is not null and project_client_id is not null));

create function studio_private.reset_mix_approval()
returns trigger language plpgsql security definer set search_path = ''
as $$
begin
  if new.first_mix_url is distinct from old.first_mix_url or new.first_mix_at is null then
    new.mix_approved_at := null;
  end if;
  return new;
end;
$$;

create trigger reset_approval_on_new_mix
before update of first_mix_at, first_mix_url on studio_private.project_workspaces
for each row execute function studio_private.reset_mix_approval();

create function public.submit_studio_mix_feedback(booking_id uuid, feedback_action text, song_notes jsonb, request_id uuid)
returns void language plpgsql security definer set search_path = ''
as $$
declare
  selected public.studio_bookings%rowtype;
  workspace studio_private.project_workspaces%rowtype;
  entry record;
  note_count integer;
  saved_notes jsonb := '[]'::jsonb;
begin
  select b.* into selected from public.studio_bookings b where b.id = booking_id
    and b.client_id = auth.uid() and b.bundle_request_id is not null;
  if not found then raise exception 'Project access required.' using errcode = '42501'; end if;
  if request_id is null or feedback_action is null or feedback_action not in ('revisions', 'approval') then
    raise exception 'Choose a valid feedback action.';
  end if;
  select w.* into workspace from studio_private.project_workspaces w
    where w.client_id = selected.client_id and w.project_key = selected.bundle_request_id for update;
  if not found or workspace.first_mix_at is null or workspace.masters_ready_at is not null then
    raise exception 'Feedback is available while your first mix is under review.';
  end if;
  if exists(select 1 from studio_private.project_feedback f where f.client_id = selected.client_id and f.id = request_id) then
    return;
  end if;
  if workspace.mix_approved_at is not null then
    if feedback_action = 'approval' then return; end if;
    raise exception 'This mix is already approved. Contact the studio for further changes.';
  end if;

  if feedback_action = 'revisions' then
    if song_notes is null or jsonb_typeof(song_notes) <> 'array' then raise exception 'Add revision notes by song.'; end if;
    note_count := jsonb_array_length(song_notes);
    if note_count not between 1 and selected.bundle_tracks then raise exception 'Add at least one revision note.'; end if;
    if (select count(distinct value->>'song') from jsonb_array_elements(song_notes)) <> note_count then
      raise exception 'Add one note per song.';
    end if;
    for entry in select * from jsonb_to_recordset(song_notes) as n(song integer, note text) loop
      if entry.song is null or entry.song not between 1 and selected.bundle_tracks
        or entry.note is null or entry.note !~ '[^[:space:]]' or char_length(trim(entry.note)) > 1000 then
        raise exception 'Keep each song note to 1–1,000 characters.';
      end if;
      if coalesce(workspace.revisions_used[entry.song], 0) >= 2 then
        raise exception 'Song % has no included revision rounds left.', entry.song;
      end if;
      if exists (
        select 1 from studio_private.project_feedback f
        cross join lateral jsonb_array_elements(f.notes) note
        where f.client_id = selected.client_id and f.project_key = selected.bundle_request_id
          and (note->>'song')::integer = entry.song
          and (note->>'round')::integer = coalesce(workspace.revisions_used[entry.song], 0) + 1
      ) then raise exception 'Notes were already submitted for this round of song %.', entry.song; end if;
      saved_notes := saved_notes || jsonb_build_array(jsonb_build_object(
        'song', entry.song, 'note', trim(entry.note), 'round', coalesce(workspace.revisions_used[entry.song], 0) + 1));
    end loop;
  else
    update studio_private.project_workspaces set mix_approved_at = now()
      where client_id = selected.client_id and project_key = selected.bundle_request_id;
  end if;

  insert into studio_private.project_feedback(client_id,id,project_key,action,notes)
  values (selected.client_id,request_id,selected.bundle_request_id,feedback_action,saved_notes);
  insert into studio_private.booking_alerts(booking_id,kind,project_key,project_client_id,feedback_id)
  values (booking_id,'feedback:' || request_id,selected.bundle_request_id,selected.client_id,request_id);
end;
$$;

create or replace function public.studio_project_workspace(booking_id uuid)
returns jsonb language plpgsql stable security definer set search_path = ''
as $$
declare
  selected public.studio_bookings%rowtype;
  result jsonb;
  feedback jsonb;
begin
  select b.* into selected from public.studio_bookings b where b.id = booking_id
    and (b.client_id = auth.uid() or public.is_studio_admin());
  if not found then raise exception 'Booking access required.' using errcode = '42501'; end if;
  select to_jsonb(w) - 'client_id' - 'project_key' into result
    from studio_private.project_workspaces w where w.client_id = selected.client_id
      and w.project_key = coalesce(selected.bundle_request_id, selected.id);
  select jsonb_agg(to_jsonb(f) - 'client_id' - 'project_key' order by f.created_at desc) into feedback
    from (select * from studio_private.project_feedback f
      where f.client_id = selected.client_id and f.project_key = selected.bundle_request_id
      order by created_at desc limit 50) f;
  return coalesce(result, '{}'::jsonb) || jsonb_build_object(
    'song_count', selected.bundle_tracks, 'bundle_code', selected.bundle_code, 'feedback', coalesce(feedback, '[]'::jsonb)
  );
end;
$$;

create function studio_private.email_html_escape(input text)
returns text language sql immutable strict set search_path = ''
as $$
  select replace(replace(replace(replace(input, '&', '&amp;'), '<', '&lt;'), '>', '&gt;'), '"', '&quot;');
$$;

create function studio_private.branded_studio_email(title text, message text, action_url text, action_label text)
returns text language sql immutable strict set search_path = ''
as $$
  select '<!doctype html><html lang="en"><body style="margin:0;padding:0;background:#100d15;font-family:Arial,sans-serif">' ||
    '<table role="presentation" width="100%" cellspacing="0" cellpadding="0" style="background:#100d15"><tr><td align="center" style="padding:24px 12px">' ||
    '<table role="presentation" width="600" cellspacing="0" cellpadding="0" style="width:100%;max-width:600px;background:#21192d;border:1px solid #4b395e;border-radius:12px">' ||
    '<tr><td style="padding:18px 24px;background:#09090b;border-bottom:3px solid #ffc800">' ||
    '<img src="https://thinkinsounds.co.za/assets/logos/logo-color-transparent.png" width="110" alt="Thinkin’ Sounds" style="display:block;width:110px;height:auto"></td></tr>' ||
    '<tr><td style="padding:28px 24px;color:#f8f7fa"><h1 style="color:#fff;font-size:26px;line-height:1.2;margin:0 0 18px">' ||
    studio_private.email_html_escape(title) || '</h1><p style="color:#e8e0ed;font-size:16px;line-height:1.65;margin:0 0 22px">' ||
    replace(studio_private.email_html_escape(message), E'\n', '<br>') || '</p>' ||
    '<a href="' || studio_private.email_html_escape(action_url) || '" style="display:inline-block;background:#ffc800;color:#120e16;border-radius:6px;padding:13px 20px;font-weight:bold;text-decoration:none">' ||
    studio_private.email_html_escape(action_label) || '</a></td></tr>' ||
    '<tr><td style="padding:16px 24px;background:#17121e;color:#d6c8df;font-size:13px">Thinkin’ Sounds Recording Studio · Germiston</td></tr>' ||
    '</table></td></tr></table></body></html>';
$$;

revoke all on function studio_private.reset_mix_approval(), public.submit_studio_mix_feedback(uuid,text,jsonb,uuid),
  studio_private.email_html_escape(text), studio_private.branded_studio_email(text,text,text,text)
  from public, anon, authenticated;
grant execute on function public.submit_studio_mix_feedback(uuid,text,jsonb,uuid) to authenticated;

create or replace function studio_private.deliver_booking_alerts()
returns void language plpgsql security definer set search_path = ''
as $$
declare
  api_key text;
  owner_email text;
  destination text;
  body_text text;
  email_subject text;
  email_content text;
  action_url text;
  action_label text;
  alert_row record;
  response record;
  provider_accepted boolean;
begin
  select decrypted_secret into api_key from vault.decrypted_secrets
    where name = 'studio_booking_smtp2go_api_key';
  select decrypted_secret into owner_email from vault.decrypted_secrets
    where name = 'studio_booking_alert_recipient';
  if api_key is null then return; end if;

  for alert_row in
    select alerts.*, bookings.starts_at, bookings.hours, bookings.headcount, users.email as client_email, bookings.status, bookings.decline_reason, bookings.cancellation_reason, bookings.bundle_code, bookings.bundle_session, bookings.bundle_tracks, workspace.first_mix_at, workspace.masters_ready_at, feedback.action as feedback_action, feedback.notes as feedback_notes
    from studio_private.booking_alerts alerts
    join public.studio_bookings bookings on bookings.id = alerts.booking_id
    join auth.users users on users.id = bookings.client_id
    left join studio_private.project_workspaces workspace
      on workspace.client_id = bookings.client_id and workspace.project_key = alerts.project_key
    left join studio_private.project_feedback feedback
      on feedback.client_id = bookings.client_id and feedback.id = alerts.feedback_id
    where alerts.sent_at is null and alerts.failure is null and alerts.next_attempt_at <= now()
    order by alerts.created_at
    limit 25 for update of alerts skip locked
  loop
    if alert_row.request_id is not null then
      select status_code, content into response
        from net._http_response where id = alert_row.request_id;
      if not found then
        if alert_row.submitted_at < now() - interval '10 minutes' then
          update studio_private.booking_alerts set failure = 'Delivery outcome unknown'
            where booking_id = alert_row.booking_id and kind = alert_row.kind;
        end if;
        continue;
      end if;

      provider_accepted := false;
      if response.status_code between 200 and 299 and pg_input_is_valid(response.content, 'jsonb') then
        provider_accepted := (response.content::jsonb #>> '{data,succeeded}') = '1';
      end if;
      if provider_accepted then
        update studio_private.booking_alerts set sent_at = now()
          where booking_id = alert_row.booking_id and kind = alert_row.kind;
      elsif response.status_code = 429 and alert_row.attempts < 4 then
        update studio_private.booking_alerts
          set request_id = null, next_attempt_at = now() + alert_row.attempts * interval '2 minutes'
          where booking_id = alert_row.booking_id and kind = alert_row.kind;
      else
        update studio_private.booking_alerts
          set failure = 'SMTP2GO response ' || coalesce(response.status_code::text, 'unavailable')
          where booking_id = alert_row.booking_id and kind = alert_row.kind;
      end if;
      continue;
    end if;

    destination := case when alert_row.kind = 'request' or alert_row.kind like 'feedback:%' then owner_email else alert_row.client_email end;
    if destination is null or (alert_row.kind like 'feedback:%' and alert_row.feedback_action is null) or (alert_row.kind = 'confirmation' and alert_row.status <> 'confirmed')
       or (alert_row.kind = 'cancellation' and alert_row.status <> 'cancelled')
       or (alert_row.kind = 'decline' and alert_row.status <> 'declined')
       or (alert_row.kind = 'first_mix_ready' and alert_row.first_mix_at is null)
       or (alert_row.kind = 'masters_ready' and alert_row.masters_ready_at is null)
       or (alert_row.kind like 'reminder:%' and
          (alert_row.status <> 'confirmed' or alert_row.scheduled_for <> alert_row.starts_at or alert_row.starts_at <= now()))
       or (alert_row.kind like 'reschedule:%' and
           (alert_row.status <> 'confirmed' or alert_row.scheduled_for <> alert_row.starts_at
            or exists (select 1 from studio_private.booking_alerts newer
              where newer.booking_id = alert_row.booking_id and newer.kind like 'reschedule:%'
                and newer.created_at > alert_row.created_at))) then
      update studio_private.booking_alerts set failure = 'Delivery no longer applicable'
        where booking_id = alert_row.booking_id and kind = alert_row.kind;
      continue;
    end if;
    body_text := case when alert_row.bundle_code is null then '' else
      'Bundle: ' || case alert_row.bundle_code when 'ep' then 'EP' when 'mixtape' then 'Mixtape' else 'Album' end ||
      ' · Session ' || alert_row.bundle_session || ' of ' ||
      case when alert_row.bundle_code = 'ep' then '1' else '2' end ||
      ' · ' || alert_row.bundle_tracks || ' songs' || E'\n'
      end || 'When: ' || to_char(alert_row.starts_at at time zone 'Africa/Johannesburg', 'Dy DD Mon YYYY, HH24:MI') || ' SAST' || E'\n' ||
                 'Duration: ' || alert_row.hours || ' hour(s)' || E'\n' ||
                 'Attendees: ' || alert_row.headcount || E'\n' ||
                 'Booking ID: ' || alert_row.booking_id || E'\n\n';

    action_url := case
      when alert_row.kind like 'feedback:%' then 'https://thinkinsounds.co.za/admin.html?project=' || alert_row.booking_id
      when alert_row.kind = 'request' then 'https://thinkinsounds.co.za/admin.html'
      when alert_row.kind in ('first_mix_ready', 'masters_ready') then 'https://thinkinsounds.co.za/account.html?project=' || alert_row.booking_id
      else 'https://thinkinsounds.co.za/account.html' end;
    action_label := case
      when alert_row.kind like 'feedback:%' then 'Review project feedback'
      when alert_row.kind = 'request' then 'Review booking request'
      when alert_row.kind in ('first_mix_ready', 'masters_ready') then 'Open your project workspace'
      else 'Open Studio Account' end;
    email_subject := case when alert_row.kind = 'request' then 'New Thinkin’ Sounds booking request'
                        when alert_row.kind like 'feedback:%' then
                          case when alert_row.feedback_action = 'approval' then 'Client approved the mix | Thinkin’ Sounds'
                               else 'New song revision notes | Thinkin’ Sounds' end
                        when alert_row.kind = 'confirmation' then 'Your Thinkin’ Sounds booking is confirmed'
                        when alert_row.kind = 'decline' then 'Your Thinkin’ Sounds booking request was declined'
                        when alert_row.kind = 'cancellation' then 'Your Thinkin’ Sounds booking has been cancelled'
                        when alert_row.kind = 'first_mix_ready' then 'Your Thinkin’ Sounds first mix is ready'
                        when alert_row.kind = 'masters_ready' then 'Your Thinkin’ Sounds final masters are ready'
                        when alert_row.kind like 'reminder:%' then 'Reminder: your Thinkin’ Sounds recording session'
                        else 'Your Thinkin’ Sounds booking has been rescheduled' end;
    email_content := trim(both E'\n' from case when alert_row.kind = 'request' then
            'A recording session has been requested.' || E'\n\n' || body_text ||
            'Confirm only once you agree on scope and deposit.'
          when alert_row.kind like 'feedback:%' then
            case when alert_row.feedback_action = 'approval' then
              'Your client approved the mix.'
            else
              'Your client submitted revision notes for ' || jsonb_array_length(alert_row.feedback_notes) || ' song(s).'
            end || E'\n\n' ||
            'Client: ' || alert_row.client_email || E'\n' ||
            'Project: ' || case alert_row.bundle_code when 'ep' then 'EP' when 'mixtape' then 'Mixtape' else 'Album' end ||
            E'\n\n' || 'Open the private workspace to review the feedback.'
          when alert_row.kind = 'confirmation' then
            'Your recording session at Thinkin’ Sounds is confirmed.' || E'\n\n' || body_text
          when alert_row.kind = 'decline' then
            'The studio has declined your recording session request.' || E'\n\n' || body_text ||
            'Reason: ' || alert_row.decline_reason
          when alert_row.kind = 'cancellation' then
            'The studio has cancelled your confirmed recording session.' || E'\n\n' || body_text ||
            'Reason: ' || alert_row.cancellation_reason
          when alert_row.kind in ('first_mix_ready', 'masters_ready') then
            case when alert_row.kind = 'first_mix_ready' then
              'Your first mix is ready for review. Sign in to open your project and check your revision rounds.'
            else
              'Your final masters are ready. Sign in to open your project and download your files.'
            end
          when alert_row.kind like 'reminder:%' then
            'Your recording session is coming up.' || E'\n\n' || body_text ||
            'Before you arrive:' || E'\n' ||
            '- Rehearse your songs and check the track order.' || E'\n' ||
            '- Bring your cleared beats and share any reference tracks.' || E'\n' ||
            '- Add your tracklist, beat links and references in your Studio Account.'
          else
            'Your confirmed recording session at Thinkin’ Sounds has moved.' || E'\n\n' ||
            'New session time' || E'\n' || body_text
          end);

    update studio_private.booking_alerts
      set attempts = attempts + 1, submitted_at = now(), request_id = net.http_post(
        url := 'https://api.smtp2go.com/v3/email/send',
        headers := jsonb_build_object('Content-Type', 'application/json', 'X-Smtp2go-Api-Key', api_key),
        body := jsonb_build_object(
          'sender', 'Thinkin’ Sounds <bookings@thinkinsounds.co.za>',
          'to', jsonb_build_array(destination),
          'subject', email_subject,
          'text_body', email_content || E'\n\n' || action_label || ': ' || action_url,
          'html_body', studio_private.branded_studio_email(email_subject, email_content, action_url, action_label)
        ),
        timeout_milliseconds := 8000
      )
      where booking_id = alert_row.booking_id and kind = alert_row.kind;
  end loop;
end;
$$;

commit;
