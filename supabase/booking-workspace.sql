begin;

create function public.studio_open_days(month_start date, session_hours integer)
returns table (open_date date)
language sql stable security definer set search_path = ''
as $$
  select day::date from generate_series(
    greatest(month_start, (now() at time zone 'Africa/Johannesburg')::date)::timestamp,
    least((month_start + interval '1 month - 1 day')::date,
      (now() at time zone 'Africa/Johannesburg')::date + 90)::timestamp,
    interval '1 day'
  ) day
  where auth.uid() is not null and month_start is not null
    and extract(day from month_start) = 1 and session_hours between 1 and 8
    and exists (select 1 from public.studio_availability(day::date, session_hours));
$$;

create table studio_private.project_workspaces (
  client_id uuid not null references auth.users(id) on delete cascade,
  project_key uuid not null,
  tracklist text not null default '' check (char_length(tracklist) <= 2500),
  beat_links text not null default '' check (char_length(beat_links) <= 2500),
  reference_links text not null default '' check (char_length(reference_links) <= 2500),
  files_received_at timestamptz,
  first_mix_at timestamptz,
  masters_ready_at timestamptz,
  first_mix_url text check (first_mix_url is null or (left(first_mix_url, 8) = 'https://' and char_length(first_mix_url) <= 2000)),
  master_url text check (master_url is null or (left(master_url, 8) = 'https://' and char_length(master_url) <= 2000)),
  revisions_used integer[] not null default '{}' check (0 <= all(revisions_used) and 2 >= all(revisions_used)),
  primary key (client_id, project_key)
);
alter table studio_private.project_workspaces enable row level security;

create function public.studio_project_workspace(booking_id uuid)
returns jsonb language plpgsql stable security definer set search_path = ''
as $$
declare
  selected public.studio_bookings%rowtype;
  result jsonb;
begin
  select b.* into selected from public.studio_bookings b where b.id = booking_id
    and (b.client_id = auth.uid() or public.is_studio_admin());
  if not found then raise exception 'Booking access required.' using errcode = '42501'; end if;
  select to_jsonb(w) - 'client_id' - 'project_key' into result
    from studio_private.project_workspaces w where w.client_id = selected.client_id
      and w.project_key = coalesce(selected.bundle_request_id, selected.id);
  return coalesce(result, '{}'::jsonb) || jsonb_build_object(
    'song_count', selected.bundle_tracks, 'bundle_code', selected.bundle_code
  );
end;
$$;

create function public.save_studio_prep(booking_id uuid, tracks text, beats text, refs text)
returns void language plpgsql security definer set search_path = ''
as $$
declare
  selected public.studio_bookings%rowtype;
begin
  select b.* into selected from public.studio_bookings b where b.id = booking_id
    and b.client_id = auth.uid() and b.status in ('requested', 'confirmed');
  if not found then raise exception 'An active booking is required.' using errcode = '42501'; end if;
  if greatest(char_length(tracks), char_length(beats), char_length(refs)) > 2500 then
    raise exception 'Keep each field to 2,500 characters.';
  end if;
  insert into studio_private.project_workspaces(client_id, project_key, tracklist, beat_links, reference_links)
    values (selected.client_id, coalesce(selected.bundle_request_id, selected.id),
      coalesce(trim(tracks), ''), coalesce(trim(beats), ''), coalesce(trim(refs), ''))
  on conflict (client_id, project_key) do update set
    tracklist = excluded.tracklist, beat_links = excluded.beat_links, reference_links = excluded.reference_links;
end;
$$;

create function public.admin_save_project_timeline(
  booking_id uuid, timeline_stage integer, mix_link text, masters_link text, used_rounds integer[]
)
returns void language plpgsql security definer set search_path = ''
as $$
declare
  selected public.studio_bookings%rowtype;
begin
  if not public.is_studio_admin() then raise exception 'Studio staff access required.' using errcode = '42501'; end if;
  select b.* into selected from public.studio_bookings b where b.id = booking_id and b.bundle_request_id is not null;
  if not found then raise exception 'Choose a project bundle.'; end if;
  if timeline_stage is null or timeline_stage not between 0 and 3 or used_rounds is null
    or cardinality(used_rounds) <> selected.bundle_tracks or array_position(used_rounds, null) is not null
    or exists(select 1 from unnest(used_rounds) rounds where rounds not between 0 and 2) then
    raise exception 'Enter a valid stage and 0 to 2 used revision rounds per song.';
  end if;
  mix_link := nullif(trim(mix_link), '');
  masters_link := nullif(trim(masters_link), '');
  if timeline_stage < 2 then mix_link := null; end if;
  if timeline_stage < 3 then masters_link := null; end if;
  if timeline_stage = 3 and masters_link is null then raise exception 'Add the final master link before marking delivery ready.'; end if;
  if (mix_link is not null and mix_link !~ '^https://[^[:space:]]+$')
    or (masters_link is not null and masters_link !~ '^https://[^[:space:]]+$') then
    raise exception 'Use HTTPS links for file delivery.';
  end if;

  insert into studio_private.project_workspaces(
    client_id, project_key, files_received_at, first_mix_at, masters_ready_at, first_mix_url, master_url, revisions_used
  ) values (selected.client_id, selected.bundle_request_id,
    case when timeline_stage >= 1 then now() end, case when timeline_stage >= 2 then now() end,
    case when timeline_stage >= 3 then now() end, mix_link, masters_link, used_rounds)
  on conflict (client_id, project_key) do update set
    files_received_at = case when timeline_stage >= 1 then coalesce(studio_private.project_workspaces.files_received_at, now()) end,
    first_mix_at = case when timeline_stage >= 2 then coalesce(studio_private.project_workspaces.first_mix_at, now()) end,
    masters_ready_at = case when timeline_stage >= 3 then coalesce(studio_private.project_workspaces.masters_ready_at, now()) end,
    first_mix_url = excluded.first_mix_url, master_url = excluded.master_url, revisions_used = excluded.revisions_used;
end;
$$;

alter table studio_private.booking_alerts drop constraint booking_alerts_kind_check;
alter table studio_private.booking_alerts add constraint booking_alerts_kind_check
  check (kind in ('request', 'confirmation', 'decline', 'cancellation') or
    ((kind like 'reschedule:%' or kind like 'reminder:%') and scheduled_for is not null));

create function studio_private.queue_session_reminders()
returns void language sql security definer set search_path = ''
as $$
  insert into studio_private.booking_alerts (booking_id, kind, scheduled_for)
  select b.id, 'reminder:' || extract(epoch from b.starts_at)::bigint::text, b.starts_at
  from public.studio_bookings b
  where b.status = 'confirmed' and b.starts_at > now() and b.starts_at <= now() + interval '24 hours'
  on conflict (booking_id, kind) do nothing;
$$;

revoke all on function public.studio_open_days(date,integer), public.studio_project_workspace(uuid),
  public.save_studio_prep(uuid,text,text,text), public.admin_save_project_timeline(uuid,integer,text,text,integer[]),
  studio_private.queue_session_reminders() from public, anon, authenticated;
grant execute on function public.studio_open_days(date,integer), public.studio_project_workspace(uuid),
  public.save_studio_prep(uuid,text,text,text), public.admin_save_project_timeline(uuid,integer,text,text,integer[])
  to authenticated;

select cron.schedule('thinkin-sounds-session-reminders','* * * * *','select studio_private.queue_session_reminders();');

create or replace function studio_private.deliver_booking_alerts()
returns void language plpgsql security definer set search_path = ''
as $$
declare
  api_key text;
  owner_email text;
  destination text;
  body_text text;
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
    select alerts.*, bookings.starts_at, bookings.hours, bookings.headcount, users.email as client_email, bookings.status, bookings.decline_reason, bookings.cancellation_reason, bookings.bundle_code, bookings.bundle_session, bookings.bundle_tracks
    from studio_private.booking_alerts alerts
    join public.studio_bookings bookings on bookings.id = alerts.booking_id
    join auth.users users on users.id = bookings.client_id
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

    destination := case when alert_row.kind = 'request' then owner_email else alert_row.client_email end;
    if destination is null or (alert_row.kind = 'confirmation' and alert_row.status <> 'confirmed')
       or (alert_row.kind = 'cancellation' and alert_row.status <> 'cancelled')
       or (alert_row.kind = 'decline' and alert_row.status <> 'declined')
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

    update studio_private.booking_alerts
      set attempts = attempts + 1, submitted_at = now(), request_id = net.http_post(
        url := 'https://api.smtp2go.com/v3/email/send',
        headers := jsonb_build_object('Content-Type', 'application/json', 'X-Smtp2go-Api-Key', api_key),
        body := jsonb_build_object(
          'sender', 'Thinkin’ Sounds <bookings@thinkinsounds.co.za>',
          'to', jsonb_build_array(destination),
          'subject', case when alert_row.kind = 'request' then 'New Thinkin’ Sounds booking request'
                        when alert_row.kind = 'confirmation' then 'Your Thinkin’ Sounds booking is confirmed'
                        when alert_row.kind = 'decline' then 'Your Thinkin’ Sounds booking request was declined'
                        when alert_row.kind = 'cancellation' then 'Your Thinkin’ Sounds booking has been cancelled'
                        when alert_row.kind like 'reminder:%' then 'Reminder: your Thinkin’ Sounds recording session'
                        else 'Your Thinkin’ Sounds booking has been rescheduled' end,
          'text_body', case when alert_row.kind = 'request' then
            'A recording session has been requested.' || E'\n\n' || body_text ||
            'Review in the studio admin page: https://thinkinsounds.co.za/admin.html' || E'\n' ||
            'Confirm only once you agree on scope and deposit.'
          when alert_row.kind = 'confirmation' then
            'Your recording session at Thinkin’ Sounds is confirmed.' || E'\n\n' || body_text ||
            'View your booking or contact the studio: https://thinkinsounds.co.za/account.html'
          when alert_row.kind = 'decline' then
            'The studio has declined your recording session request.' || E'\n\n' || body_text ||
            'Reason: ' || alert_row.decline_reason || E'\n\n' ||
            'Choose another session or contact the studio: https://thinkinsounds.co.za/account.html'
          when alert_row.kind = 'cancellation' then
            'The studio has cancelled your confirmed recording session.' || E'\n\n' || body_text ||
            'Reason: ' || alert_row.cancellation_reason || E'\n\n' ||
            'Request another session or contact the studio: https://thinkinsounds.co.za/account.html'
          when alert_row.kind like 'reminder:%' then
            'Your recording session is coming up.' || E'\n\n' || body_text ||
            'Before you arrive:' || E'\n' ||
            '- Rehearse your songs and check the track order.' || E'\n' ||
            '- Bring your cleared beats and share any reference tracks.' || E'\n' ||
            '- Add your tracklist, beat links and references in your Studio Account.' || E'\n\n' ||
            'View your session and prep checklist: https://thinkinsounds.co.za/account.html'
          else
            'Your confirmed recording session at Thinkin’ Sounds has moved.' || E'\n\n' ||
            'New session time' || E'\n' || body_text ||
            'View your updated booking: https://thinkinsounds.co.za/account.html'
          end
        ),
        timeout_milliseconds := 8000
      )
      where booking_id = alert_row.booking_id and kind = alert_row.kind;
  end loop;
end;
$$;

commit;
