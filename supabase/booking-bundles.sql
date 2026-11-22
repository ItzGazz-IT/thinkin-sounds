begin;
alter table public.studio_bookings
  add column bundle_request_id uuid,
  add column bundle_code text,
  add column bundle_session integer,
  add column bundle_tracks integer,
  add constraint studio_bundle_fields check (
    (bundle_request_id is null and bundle_code is null and bundle_session is null and bundle_tracks is null)
    or (bundle_request_id is not null and bundle_code is not null and bundle_session is not null
      and bundle_tracks is not null and hours = 4 and bundle_session between 1 and 2
      and case bundle_code
        when 'ep' then bundle_tracks between 1 and 4 and bundle_session = 1
        when 'mixtape' then bundle_tracks between 1 and 7
        when 'album' then bundle_tracks between 1 and 10
        else false end)
  );

create unique index studio_bundle_session_once
  on public.studio_bookings(client_id, bundle_request_id, bundle_session);

create function public.request_studio_bundle(
  requested_bundle text, requested_tracks integer, requested_headcount integer,
  requested_slots jsonb, request_id uuid
)
returns uuid language plpgsql security definer set search_path = ''
as $$
declare
  client uuid := auth.uid();
  total_sessions integer;
  track_limit integer;
  selected record;
  previous_start timestamptz;
  session_number integer := 0;
begin
  if client is null then raise exception 'Sign in to request a bundle.'; end if;
  track_limit := case requested_bundle when 'ep' then 4 when 'mixtape' then 7 when 'album' then 10 end;
  total_sessions := case when requested_bundle = 'ep' then 1 else 2 end;
  if track_limit is null or requested_tracks is null or requested_tracks not between 1 and track_limit then
    raise exception 'Choose a song count within the limit for your bundle.';
  end if;
  if requested_headcount is null or requested_headcount not between 1 and 5 then
    raise exception 'Choose between one and five people.';
  end if;
  if request_id is null or requested_slots is null or jsonb_typeof(requested_slots) <> 'array' then
    raise exception 'Choose the recording times for your bundle.';
  end if;
  if jsonb_array_length(requested_slots) <> total_sessions then
    raise exception 'Choose every recording time for your bundle.';
  end if;
  perform pg_advisory_xact_lock(hashtextextended(client::text, 0));
  if exists (select 1 from public.studio_bookings b where b.client_id = client and b.bundle_request_id = request_id) then
    return request_id;
  end if;
  if (select count(*) from public.studio_bookings b
      where b.client_id = client and b.status = 'requested' and b.starts_at > now()) + total_sessions > 3 then
    raise exception 'You can have up to three pending sessions. Cancel a pending request before adding this bundle.';
  end if;

  for selected in select * from jsonb_to_recordset(requested_slots) as s(room_id integer, starts_at timestamptz) order by s.starts_at
  loop
    if not exists (
      select 1 from public.studio_availability((selected.starts_at at time zone 'Africa/Johannesburg')::date, 4) a
        where a.room_id = selected.room_id and a.starts_at = selected.starts_at
    ) then raise exception 'One of those times is no longer available. Choose another slot.'; end if;
    if previous_start is not null and selected.starts_at < previous_start + interval '4 hours' then
      raise exception 'The two recording sessions cannot overlap.';
    end if;
    session_number := session_number + 1;
    insert into public.studio_bookings (
      client_id, room_id, starts_at, ends_at, hours, headcount,
      bundle_request_id, bundle_code, bundle_session, bundle_tracks
    ) values (
      client, selected.room_id, selected.starts_at, selected.starts_at + interval '4 hours', 4, requested_headcount,
      request_id, requested_bundle, session_number, requested_tracks
    );
    previous_start := selected.starts_at;
  end loop;
  return request_id;
end;
$$;

create function public.admin_studio_bookings_with_bundles(page_offset integer default 0)
returns table (
  id uuid, client_email text, starts_at timestamptz, hours integer,
  headcount integer, status text, confirmation_email text,
  bundle_request_id uuid, bundle_code text, bundle_session integer, bundle_tracks integer
)
language sql stable security definer set search_path = ''
as $$
  select a.*, b.bundle_request_id, b.bundle_code, b.bundle_session, b.bundle_tracks
  from public.admin_studio_bookings(page_offset) a
    join public.studio_bookings b on b.id = a.id
  order by (a.status = 'requested') desc, a.starts_at desc, a.id;
$$;

revoke all on function public.request_studio_bundle(text, integer, integer, jsonb, uuid),
  public.admin_studio_bookings_with_bundles(integer) from public, anon, authenticated;
grant execute on function public.request_studio_bundle(text, integer, integer, jsonb, uuid),
  public.admin_studio_bookings_with_bundles(integer) to authenticated;

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
