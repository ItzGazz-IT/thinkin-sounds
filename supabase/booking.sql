begin;
create extension if not exists btree_gist with schema extensions;

create table public.studio_rooms (
  id integer generated always as identity primary key,
  name text not null unique,
  active boolean not null default true
);

create table public.studio_hours (
  room_id integer not null references public.studio_rooms,
  weekday integer not null check (weekday between 0 and 6),
  opens time not null,
  closes time not null check (closes > opens),
  primary key (room_id, weekday)
);

with room as (
  insert into public.studio_rooms (name) values ('Recording studio') returning id
)
insert into public.studio_hours (room_id, weekday, opens, closes)
select room.id, schedule.weekday, schedule.opens, schedule.closes
from room cross join (values
  (5, time '17:00', time '24:00'),
  (6, time '08:00', time '20:00'),
  (0, time '08:00', time '17:00')
) as schedule(weekday, opens, closes);

create table public.studio_blackouts (
  id bigint generated always as identity primary key,
  room_id integer not null references public.studio_rooms,
  period tstzrange not null check (not isempty(period))
);

create table public.studio_bookings (
  id uuid primary key default gen_random_uuid(),
  client_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  room_id integer not null references public.studio_rooms,
  starts_at timestamptz not null,
  hours integer not null check (hours between 1 and 8),
  ends_at timestamptz not null,
  headcount integer not null check (headcount between 1 and 5),
  status text not null default 'requested' check (status in ('requested', 'confirmed', 'cancelled', 'declined')),
  created_at timestamptz not null default now(),
  constraint booking_length check (ends_at = starts_at + hours * interval '1 hour'),
  constraint same_room_no_overlap exclude using gist (
    room_id extensions.gist_int4_ops with =,
    tstzrange(starts_at, ends_at, '[)') with &&
  ) where (status = 'confirmed')
);

alter table public.studio_rooms enable row level security;
alter table public.studio_hours enable row level security;
alter table public.studio_blackouts enable row level security;
alter table public.studio_bookings enable row level security;

revoke all on public.studio_rooms, public.studio_hours, public.studio_blackouts, public.studio_bookings from anon, authenticated;
grant select on public.studio_bookings to authenticated;
create policy clients_view_own_bookings on public.studio_bookings
  for select to authenticated using (client_id = (select auth.uid()));

create function public.studio_availability(booking_date date, booking_hours integer)
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
        and tstzrange(booking.starts_at, booking.ends_at, '[)') &&
            tstzrange(proposed.slot, proposed.slot + booking_hours * interval '1 hour', '[)')
    )
  order by proposed.slot, room.name;
$$;

create function public.request_studio_booking(requested_room integer, requested_start timestamptz, requested_hours integer, requested_headcount integer)
returns uuid
language plpgsql security definer set search_path = ''
as $$
declare
  client uuid := auth.uid();
  booking_id uuid;
begin
  if client is null then raise exception 'Sign in to request a booking.'; end if;
  if requested_headcount is null or requested_headcount not between 1 and 5 then
    raise exception 'Choose between one and five people.';
  end if;
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(client::text, 0));
  select id into booking_id from public.studio_bookings
    where client_id = client and room_id = requested_room and starts_at = requested_start
      and hours = requested_hours and headcount = requested_headcount and status = 'requested';
  if found then return booking_id; end if;
  if (select count(*) from public.studio_bookings
      where client_id = client and status = 'requested' and starts_at > now()) >= 3 then
    raise exception 'You already have three upcoming requests. Cancel one to request another session.';
  end if;
  insert into public.studio_bookings (client_id, room_id, starts_at, ends_at, hours, headcount)
    select client, available.room_id, available.starts_at,
      available.starts_at + requested_hours * interval '1 hour', requested_hours, requested_headcount
    from public.studio_availability((requested_start at time zone 'Africa/Johannesburg')::date, requested_hours) as available
    where available.room_id = requested_room and available.starts_at = requested_start
    returning id into booking_id;
  if not found then raise exception 'That time is no longer available. Choose another slot.'; end if;
  return booking_id;
end;
$$;

create function public.cancel_studio_request(booking_id uuid)
returns boolean
language sql security definer set search_path = ''
as $$
  with cancelled as (
    update public.studio_bookings set status = 'cancelled'
    where id = booking_id and client_id = auth.uid() and status = 'requested'
    returning id
  )
  select exists(select 1 from cancelled);
$$;

revoke all on function public.studio_availability(date, integer), public.request_studio_booking(integer, timestamptz, integer, integer), public.cancel_studio_request(uuid) from public, anon, authenticated;
grant execute on function public.studio_availability(date, integer), public.request_studio_booking(integer, timestamptz, integer, integer), public.cancel_studio_request(uuid) to authenticated;
commit;
