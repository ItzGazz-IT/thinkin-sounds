begin;
alter table public.studio_blackouts add column label text
  check (label is null or char_length(label) between 1 and 120);

-- All writes that can change confirmed availability use the same per-room lock.
create function studio_private.lock_confirmed_availability()
returns trigger language plpgsql security definer set search_path = ''
as $$
begin
  perform pg_advisory_xact_lock(874102, new.room_id);
  if exists (
    select 1 from public.studio_blackouts b where b.room_id = new.room_id
      and b.period && tstzrange(new.starts_at, new.ends_at, '[)')
  ) then raise exception 'This session overlaps blocked studio time.'; end if;
  return new;
end;
$$;

create trigger guard_confirmed_against_blackouts
before insert or update of status, room_id, starts_at, ends_at on public.studio_bookings
for each row when (new.status = 'confirmed')
execute function studio_private.lock_confirmed_availability();

create function studio_private.lock_blackout_availability()
returns trigger language plpgsql security definer set search_path = ''
as $$
begin
  perform pg_advisory_xact_lock(874102, new.room_id);
  if exists (
    select 1 from public.studio_bookings b where b.room_id = new.room_id and b.status = 'confirmed'
      and new.period && tstzrange(b.starts_at, b.ends_at, '[)')
  ) then raise exception 'That block overlaps a confirmed session. Reschedule or cancel the session first.'; end if;
  return new;
end;
$$;

create trigger guard_blackouts_against_confirmed
before insert or update of room_id, period on public.studio_blackouts
for each row execute function studio_private.lock_blackout_availability();

create function public.admin_studio_calendar(month_start date)
returns table (event_id text, event_kind text, starts_at timestamptz, ends_at timestamptz, event_label text)
language plpgsql stable security definer set search_path = ''
as $$
declare
  month_period tstzrange;
begin
  if not public.is_studio_admin() then raise exception 'Studio staff access required.' using errcode = '42501'; end if;
  if month_start is null or extract(day from month_start) <> 1 then raise exception 'Choose a valid month.'; end if;
  month_period := tstzrange(
    month_start::timestamp at time zone 'Africa/Johannesburg',
    (month_start + interval '1 month') at time zone 'Africa/Johannesburg', '[)');
  return query
    select calendar.id, calendar.kind, calendar.start_at, calendar.end_at, calendar.label
    from (
      select b.id::text as id, 'booking'::text as kind, b.starts_at as start_at, b.ends_at as end_at, u.email::text as label
      from public.studio_bookings b join auth.users u on u.id = b.client_id
      where b.status = 'confirmed' and tstzrange(b.starts_at, b.ends_at, '[)') && month_period
      union all
      select x.id::text, 'block', lower(x.period), upper(x.period), coalesce(x.label, 'Studio unavailable')
      from public.studio_blackouts x where x.period && month_period
    ) calendar
    order by calendar.start_at, calendar.kind, calendar.id;
end;
$$;

create function public.admin_block_studio(block_start timestamptz, block_end timestamptz, block_label text default null)
returns bigint language plpgsql security definer set search_path = ''
as $$
declare
  studio_room integer;
  block_id bigint;
  block_period tstzrange;
  cleaned_label text := nullif(trim(block_label), '');
begin
  if not public.is_studio_admin() then raise exception 'Studio staff access required.' using errcode = '42501'; end if;
  if block_start is null or block_end is null or not isfinite(block_start) or not isfinite(block_end)
    or block_end <= greatest(block_start, now()) or block_end > block_start + interval '366 days' then
    raise exception 'Choose a future end time after the start time. A block can cover up to 366 days.';
  end if;
  if char_length(cleaned_label) > 120 then raise exception 'Keep the note under 121 characters.'; end if;

  select id into strict studio_room from public.studio_rooms where active;
  block_period := tstzrange(block_start, block_end, '[)');
  perform pg_advisory_xact_lock(874102, studio_room);
  select id into block_id from public.studio_blackouts
    where room_id = studio_room and period = block_period and label is not distinct from cleaned_label
    order by id limit 1;
  if found then return block_id; end if;
  insert into public.studio_blackouts(room_id, period, label)
    values(studio_room, block_period, cleaned_label) returning id into block_id;
  return block_id;
end;
$$;

create function public.admin_remove_studio_block(block_id bigint)
returns boolean language plpgsql security definer set search_path = ''
as $$
begin
  if not public.is_studio_admin() then raise exception 'Studio staff access required.' using errcode = '42501'; end if;
  delete from public.studio_blackouts where id = block_id;
  return found;
end;
$$;

revoke all on function studio_private.lock_confirmed_availability(), studio_private.lock_blackout_availability(),
  public.admin_studio_calendar(date), public.admin_block_studio(timestamptz,timestamptz,text), public.admin_remove_studio_block(bigint)
  from public, anon, authenticated;
grant execute on function public.admin_studio_calendar(date), public.admin_block_studio(timestamptz,timestamptz,text),
  public.admin_remove_studio_block(bigint) to authenticated;
commit;
