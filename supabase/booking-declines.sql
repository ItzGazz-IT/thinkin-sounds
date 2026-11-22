begin;

alter table public.studio_bookings add column decline_reason text;
alter table public.studio_bookings add constraint studio_decline_reason_length
  check (decline_reason is null or char_length(decline_reason) between 1 and 500);

alter table studio_private.booking_alerts drop constraint booking_alerts_kind_check;
alter table studio_private.booking_alerts add constraint booking_alerts_kind_check
  check (kind in ('request', 'confirmation', 'decline'));

create function public.admin_decline_studio_booking(booking_id uuid, reason text)
returns void language plpgsql security definer set search_path = ''
as $$
declare
  booking public.studio_bookings%rowtype;
  cleaned_reason text := trim(reason);
begin
  if not public.is_studio_admin() then raise exception 'Studio staff access required.' using errcode = '42501'; end if;
  if cleaned_reason is null or cleaned_reason !~ '[^[:space:]]' or char_length(cleaned_reason) > 500 then
    raise exception 'Enter a reason of 1 to 500 characters.';
  end if;
  select * into booking from public.studio_bookings where id = booking_id for update;
  if not found then raise exception 'Booking request not found.'; end if;
  if booking.status = 'declined' and booking.decline_reason = cleaned_reason then return; end if;
  if booking.status <> 'requested' then raise exception 'This booking is no longer pending.'; end if;
  update public.studio_bookings set status = 'declined', decline_reason = cleaned_reason where id = booking_id;
end;
$$;

create function studio_private.queue_decline_alert()
returns trigger language plpgsql security definer set search_path = ''
as $$
begin
  if new.decline_reason is null or new.decline_reason !~ '[^[:space:]]' then
    raise exception 'Enter a reason before declining this booking.';
  end if;
  insert into studio_private.booking_alerts (booking_id, kind) values (new.id, 'decline');
  return new;
end;
$$;

create trigger queue_booking_decline
after update of status on public.studio_bookings
for each row when (old.status = 'requested' and new.status = 'declined')
execute function studio_private.queue_decline_alert();

revoke all on function studio_private.queue_decline_alert(), public.admin_decline_studio_booking(uuid, text)
  from public, anon, authenticated;
grant execute on function public.admin_decline_studio_booking(uuid, text) to authenticated;

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
       or (alert_row.kind = 'decline' and alert_row.status <> 'declined') then
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
                        else 'Your Thinkin’ Sounds booking request was declined' end,
          'text_body', case when alert_row.kind = 'request' then
            'A recording session has been requested.' || E'\n\n' || body_text ||
            'Review in the studio admin page: https://thinkinsounds.co.za/admin.html' || E'\n' ||
            'Confirm only once you agree on scope and deposit.'
          when alert_row.kind = 'confirmation' then
            'Your recording session at Thinkin’ Sounds is confirmed.' || E'\n\n' || body_text ||
            'View your booking or contact the studio: https://thinkinsounds.co.za/account.html'
          else
            'The studio has declined your recording session request.' || E'\n\n' || body_text ||
            'Reason: ' || alert_row.decline_reason || E'\n\n' ||
            'Choose another session or contact the studio: https://thinkinsounds.co.za/account.html'
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
    left join studio_private.booking_alerts a on a.booking_id = b.id and a.kind = case when b.status = 'declined' then 'decline' else 'confirmation' end
    order by (b.status = 'requested') desc, b.starts_at desc, b.id
    limit 51 offset greatest(page_offset, 0);
end;
$$;

commit;
