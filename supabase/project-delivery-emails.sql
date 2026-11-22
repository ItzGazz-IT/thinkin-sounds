begin;

alter table studio_private.booking_alerts drop constraint booking_alerts_kind_check;
alter table studio_private.booking_alerts add constraint booking_alerts_kind_check
  check (kind in ('request', 'confirmation', 'decline', 'cancellation', 'first_mix_ready', 'masters_ready') or
    ((kind like 'reschedule:%' or kind like 'reminder:%') and scheduled_for is not null));

alter table studio_private.booking_alerts add column project_key uuid, add column project_client_id uuid;

-- One notification per project milestone, even if another session in the bundle is used later.
create unique index studio_project_milestone_once on studio_private.booking_alerts(project_client_id, project_key, kind)
  where project_key is not null;

create function studio_private.queue_project_delivery_email()
returns trigger language plpgsql security definer set search_path = ''
as $$
declare
  target_booking uuid;
  delivery_kind text;
  previous_mix timestamptz;
  previous_masters timestamptz;
begin
  if tg_op = 'UPDATE' then
    previous_mix := old.first_mix_at;
    previous_masters := old.masters_ready_at;
  end if;

  if new.masters_ready_at is not null and previous_masters is null then
    delivery_kind := 'masters_ready';
  elsif new.first_mix_at is not null and previous_mix is null and new.masters_ready_at is null then
    delivery_kind := 'first_mix_ready';
  else
    return new;
  end if;

  select b.id into target_booking from public.studio_bookings b
    where b.client_id = new.client_id and b.bundle_request_id = new.project_key
    order by b.bundle_session, b.id limit 1;
  if target_booking is not null then
    insert into studio_private.booking_alerts(booking_id, kind, project_key, project_client_id)
      values(target_booking, delivery_kind, new.project_key, new.client_id)
      on conflict (project_client_id, project_key, kind) where project_key is not null do nothing;
  end if;
  return new;
end;
$$;

create trigger queue_project_delivery
after insert or update of first_mix_at, masters_ready_at on studio_private.project_workspaces
for each row execute function studio_private.queue_project_delivery_email();

revoke all on function studio_private.queue_project_delivery_email() from public, anon, authenticated;

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
    select alerts.*, bookings.starts_at, bookings.hours, bookings.headcount, users.email as client_email, bookings.status, bookings.decline_reason, bookings.cancellation_reason, bookings.bundle_code, bookings.bundle_session, bookings.bundle_tracks, workspace.first_mix_at, workspace.masters_ready_at
    from studio_private.booking_alerts alerts
    join public.studio_bookings bookings on bookings.id = alerts.booking_id
    join auth.users users on users.id = bookings.client_id
    left join studio_private.project_workspaces workspace
      on workspace.client_id = bookings.client_id and workspace.project_key = alerts.project_key
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
                        when alert_row.kind = 'first_mix_ready' then 'Your Thinkin’ Sounds first mix is ready'
                        when alert_row.kind = 'masters_ready' then 'Your Thinkin’ Sounds final masters are ready'
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
          when alert_row.kind in ('first_mix_ready', 'masters_ready') then
            case when alert_row.kind = 'first_mix_ready' then
              'Your first mix is ready for review. Sign in to open your project and check your revision rounds.'
            else
              'Your final masters are ready. Sign in to open your project and download your files.'
            end || E'\n\n' ||
            'Open your project workspace: https://thinkinsounds.co.za/account.html?project=' || alert_row.booking_id
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
