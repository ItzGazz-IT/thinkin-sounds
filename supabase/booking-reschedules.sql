begin;

alter table studio_private.booking_alerts add column scheduled_for timestamptz;
alter table studio_private.booking_alerts drop constraint booking_alerts_kind_check;
alter table studio_private.booking_alerts add constraint booking_alerts_kind_check
  check (kind in ('request', 'confirmation', 'decline') or
    (kind like 'reschedule:%' and scheduled_for is not null));

create function studio_private.booking_slots(booking_date date, booking_hours integer, ignore_booking uuid)
returns table (room_id integer, room_name text, starts_at timestamptz)
language sql stable security definer set search_path = ''
as $$
  select room.id, room.name, proposed.slot
  from public.studio_rooms as room
  join public.studio_hours as hours on hours.room_id = room.id
  cross join lateral generate_series(
    (booking_date + hours.opens) at time zone 'Africa/Johannesburg',
    ((booking_date + hours.closes) at time zone 'Africa/Johannesburg') - booking_hours * interval '1 hour',
    interval '30 minutes'
  ) as proposed(slot)
  where auth.uid() is not null and room.active
    and booking_hours between 1 and 8
    and booking_date between (now() at time zone 'Africa/Johannesburg')::date
      and (now() at time zone 'Africa/Johannesburg')::date + 90
    and hours.weekday = extract(dow from booking_date)
    and proposed.slot > now()
    and not exists (
      select 1 from public.studio_blackouts as blackout
      where blackout.room_id = room.id
        and blackout.period && tstzrange(proposed.slot, proposed.slot + booking_hours * interval '1 hour', '[)')
    )
    and not exists (
      select 1 from public.studio_bookings as booking
      where booking.room_id = room.id and booking.status = 'confirmed'
        and booking.id is distinct from ignore_booking
        and tstzrange(booking.starts_at, booking.ends_at, '[)') &&
            tstzrange(proposed.slot, proposed.slot + booking_hours * interval '1 hour', '[)')
    )
  order by proposed.slot, room.name;
$$;

create function public.admin_reschedule_availability(booking_id uuid, booking_date date)
returns table (room_id integer, room_name text, starts_at timestamptz)
language plpgsql stable security definer set search_path = ''
as $$
begin
  if not public.is_studio_admin() then raise exception 'Studio staff access required.' using errcode = '42501'; end if;
  return query
    select slots.room_id, slots.room_name, slots.starts_at
    from public.studio_bookings booking
    cross join lateral studio_private.booking_slots(booking_date, booking.hours, booking.id) slots
    where booking.id = booking_id and booking.status = 'confirmed'
      and booking.starts_at > now() and slots.starts_at <> booking.starts_at;
end;
$$;

create function public.admin_reschedule_studio_booking(booking_id uuid, requested_room integer, requested_start timestamptz)
returns void language plpgsql security definer set search_path = ''
as $$
declare
  booking public.studio_bookings%rowtype;
begin
  if not public.is_studio_admin() then raise exception 'Studio staff access required.' using errcode = '42501'; end if;
  select * into booking from public.studio_bookings where id = booking_id for update;
  if not found or booking.status <> 'confirmed' or booking.starts_at <= now() then
    raise exception 'Only upcoming confirmed bookings can be rescheduled.';
  end if;
  if booking.starts_at = requested_start and booking.room_id = requested_room then return; end if;
  if not exists (
    select 1 from public.admin_reschedule_availability(
      booking_id, (requested_start at time zone 'Africa/Johannesburg')::date
    ) slot
    where slot.room_id = requested_room and slot.starts_at = requested_start
  ) then raise exception 'That time is no longer available. Choose another slot.'; end if;

  update public.studio_bookings
    set room_id = requested_room, starts_at = requested_start,
        ends_at = requested_start + booking.hours * interval '1 hour'
    where id = booking_id;
  insert into studio_private.booking_alerts (booking_id, kind, scheduled_for)
    values (booking_id, 'reschedule:' || gen_random_uuid(), requested_start);
exception
  when exclusion_violation then
    raise exception 'This session overlaps another confirmed booking.';
end;
$$;

revoke all on function studio_private.booking_slots(date, integer, uuid),
  public.admin_reschedule_availability(uuid, date), public.admin_reschedule_studio_booking(uuid, integer, timestamptz)
  from public, anon, authenticated;
grant execute on function public.admin_reschedule_availability(uuid, date),
  public.admin_reschedule_studio_booking(uuid, integer, timestamptz) to authenticated;

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
    select alerts.*, bookings.starts_at, bookings.hours, bookings.headcount, users.email as client_email, bookings.status, bookings.decline_reason
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
    body_text := 'When: ' || to_char(alert_row.starts_at at time zone 'Africa/Johannesburg', 'Dy DD Mon YYYY, HH24:MI') || ' SAST' || E'\n' ||
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

create or replace function public.admin_studio_bookings(page_offset integer default 0)
returns table (
  id uuid, client_email text, starts_at timestamptz, hours integer,
  headcount integer, status text, confirmation_email text
)
language plpgsql stable security definer set search_path = ''
as $$
begin
  if not public.is_studio_admin() then raise exception 'Studio staff access required.' using errcode = '42501'; end if;
  return query
    select b.id, u.email::text, b.starts_at, b.hours, b.headcount, b.status,
      case when a.sent_at is not null then 'Sent'
           when a.failure is not null then 'Delivery needs attention'
           when a.booking_id is not null then 'Queued'
      end
    from public.studio_bookings b
    join auth.users u on u.id = b.client_id
    left join lateral (
      select alert.booking_id, alert.sent_at, alert.failure
      from studio_private.booking_alerts alert
      where alert.booking_id = b.id and (
        (b.status = 'declined' and alert.kind = 'decline')
        or (b.status = 'confirmed' and (alert.kind = 'confirmation' or alert.kind like 'reschedule:%'))
      )
      order by alert.created_at desc, alert.kind desc limit 1
    ) a on true
    order by (b.status = 'requested') desc, b.starts_at desc, b.id
    limit 51 offset greatest(page_offset, 0);
end;
$$;

commit;
