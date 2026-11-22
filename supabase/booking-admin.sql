begin;

create table studio_private.booking_admins (
  user_id uuid primary key references auth.users(id) on delete cascade
);
alter table studio_private.booking_admins enable row level security;

create function public.is_studio_admin()
returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (select 1 from studio_private.booking_admins where user_id = auth.uid());
$$;

create function public.admin_studio_bookings(page_offset integer default 0)
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
    left join studio_private.booking_alerts a on a.booking_id = b.id and a.kind = 'confirmation'
    order by (b.status = 'requested') desc, b.starts_at desc, b.id
    limit 51 offset greatest(page_offset, 0);
end;
$$;

create function public.admin_decide_studio_booking(booking_id uuid, decision text)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  booking public.studio_bookings%rowtype;
begin
  if not public.is_studio_admin() then raise exception 'Studio staff access required.' using errcode = '42501'; end if;
  if decision is null or decision not in ('confirmed', 'declined') then raise exception 'Invalid decision.'; end if;

  select * into booking from public.studio_bookings where id = booking_id for update;
  if not found then raise exception 'Booking request not found.'; end if;
  if booking.status = decision then return; end if;
  if booking.status <> 'requested' then raise exception 'This booking is no longer pending.'; end if;

  if decision = 'confirmed' and not exists (
    select 1 from public.studio_availability(
      (booking.starts_at at time zone 'Africa/Johannesburg')::date, booking.hours
    ) slot
    where slot.starts_at = booking.starts_at and slot.room_id = booking.room_id
  ) then
    raise exception 'That time is no longer available. The request is still pending.';
  end if;

  update public.studio_bookings set status = decision where id = booking_id;
exception
  when exclusion_violation then
    raise exception 'This session overlaps another confirmed booking.';
end;
$$;

alter table studio_private.booking_alerts
  add column kind text not null default 'request' check (kind in ('request', 'confirmation')),
  drop constraint booking_alerts_pkey,
  add primary key (booking_id, kind);

create function studio_private.queue_confirmation_alert()
returns trigger language plpgsql security definer set search_path = ''
as $$
begin
  insert into studio_private.booking_alerts (booking_id, kind) values (new.id, 'confirmation');
  return new;
end;
$$;

create trigger queue_booking_confirmation
after update of status on public.studio_bookings
for each row when (old.status = 'requested' and new.status = 'confirmed')
execute function studio_private.queue_confirmation_alert();

revoke all on function studio_private.queue_confirmation_alert() from public, anon, authenticated;
revoke all on function public.is_studio_admin(), public.admin_studio_bookings(integer), public.admin_decide_studio_booking(uuid, text)
  from public, anon, authenticated;
grant execute on function public.is_studio_admin(), public.admin_studio_bookings(integer), public.admin_decide_studio_booking(uuid, text)
  to authenticated;

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
    select alerts.*, bookings.starts_at, bookings.hours, bookings.headcount, users.email as client_email, bookings.status
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
    if destination is null or (alert_row.kind = 'confirmation' and alert_row.status <> 'confirmed') then
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
                        else 'Your Thinkin’ Sounds booking is confirmed' end,
          'text_body', case when alert_row.kind = 'request' then
            'A recording session has been requested.' || E'\n\n' || body_text ||
            'Review in the studio admin page: https://thinkinsounds.co.za/admin.html' || E'\n' ||
            'Confirm only once you agree on scope and deposit.'
          else
            'Your recording session at Thinkin’ Sounds is confirmed.' || E'\n\n' || body_text ||
            'View your booking or contact the studio: https://thinkinsounds.co.za/account.html'
          end
        ),
        timeout_milliseconds := 8000
      )
      where booking_id = alert_row.booking_id and kind = alert_row.kind;
  end loop;
end;
$$;

commit;
