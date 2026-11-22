begin;
create extension if not exists pg_net with schema extensions;
create extension if not exists pg_cron with schema extensions;
create schema if not exists studio_private;
revoke all on schema studio_private from public, anon, authenticated;

create table studio_private.booking_alerts (
  booking_id uuid primary key references public.studio_bookings(id) on delete cascade,
  created_at timestamptz not null default now(),
  attempts integer not null default 0,
  next_attempt_at timestamptz not null default now(),
  request_id bigint,
  submitted_at timestamptz,
  sent_at timestamptz,
  failure text
);
alter table studio_private.booking_alerts enable row level security;

create function studio_private.queue_booking_alert()
returns trigger language plpgsql security definer set search_path = ''
as $$
begin
  insert into studio_private.booking_alerts (booking_id) values (new.id);
  return new;
end;
$$;

create trigger queue_new_booking_alert
after insert on public.studio_bookings
for each row when (new.status = 'requested')
execute function studio_private.queue_booking_alert();

create function studio_private.deliver_booking_alerts()
returns void language plpgsql security definer set search_path = ''
as $$
declare
  api_key text;
  recipient text;
  alert_row record;
  response record;
  provider_accepted boolean;
begin
  select decrypted_secret into api_key from vault.decrypted_secrets
    where name = 'studio_booking_smtp2go_api_key';
  select decrypted_secret into recipient from vault.decrypted_secrets
    where name = 'studio_booking_alert_recipient';
  if api_key is null or recipient is null then return; end if;

  for alert_row in
    select alerts.*, bookings.starts_at, bookings.hours, bookings.headcount
    from studio_private.booking_alerts alerts
    join public.studio_bookings bookings on bookings.id = alerts.booking_id
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
            where booking_id = alert_row.booking_id;
        end if;
        continue;
      end if;

      provider_accepted := false;
      if response.status_code between 200 and 299 and pg_input_is_valid(response.content, 'jsonb') then
        provider_accepted := (response.content::jsonb #>> '{data,succeeded}') = '1';
      end if;
      if provider_accepted then
        update studio_private.booking_alerts set sent_at = now()
          where booking_id = alert_row.booking_id;
      elsif response.status_code = 429 and alert_row.attempts < 4 then
        update studio_private.booking_alerts
          set request_id = null, next_attempt_at = now() + alert_row.attempts * interval '2 minutes'
          where booking_id = alert_row.booking_id;
      else
        update studio_private.booking_alerts
          set failure = 'SMTP2GO response ' || coalesce(response.status_code::text, 'unavailable')
          where booking_id = alert_row.booking_id;
      end if;
      continue;
    end if;

    update studio_private.booking_alerts
      set attempts = attempts + 1, submitted_at = now(), request_id = net.http_post(
        url := 'https://api.smtp2go.com/v3/email/send',
        headers := jsonb_build_object('Content-Type', 'application/json', 'X-Smtp2go-Api-Key', api_key),
        body := jsonb_build_object(
          'sender', 'Thinkin’ Sounds <bookings@thinkinsounds.co.za>',
          'to', jsonb_build_array(recipient),
          'subject', 'New Thinkin’ Sounds booking request',
          'text_body', 'A recording session has been requested.' || E'\n\n' ||
            'When: ' || to_char(alert_row.starts_at at time zone 'Africa/Johannesburg', 'Dy DD Mon YYYY, HH24:MI') || ' SAST' || E'\n' ||
            'Duration: ' || alert_row.hours || ' hour(s)' || E'\n' ||
            'Attendees: ' || alert_row.headcount || E'\n' ||
            'Booking ID: ' || alert_row.booking_id || E'\n\n' ||
            'Review in Supabase: https://supabase.com/dashboard/project/zrxvfzuhpcaqudocaggl/editor' || E'\n' ||
            'Confirm only once you agree on scope and deposit.'
        ),
        timeout_milliseconds := 8000
      )
      where booking_id = alert_row.booking_id;
  end loop;
end;
$$;

revoke all on function studio_private.queue_booking_alert(), studio_private.deliver_booking_alerts()
  from public, anon, authenticated;
select cron.schedule('thinkin-sounds-booking-alerts', '* * * * *', 'select studio_private.deliver_booking_alerts();');
commit;
