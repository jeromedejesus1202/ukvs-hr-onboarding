create extension if not exists pgcrypto;

create type public.app_role as enum ('admin', 'scheduler', 'viewer');
create type public.person_type as enum ('teacher', 'student');

create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  display_name text,
  role public.app_role not null default 'viewer',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.people (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  person_type public.person_type not null,
  year_level text,
  year_group text,
  active boolean not null default true,
  created_by uuid references public.profiles(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.class_carriers (
  id uuid primary key default gen_random_uuid(),
  subject text not null,
  year_level text,
  year_group text not null,
  class_group text not null check (class_group in ('A', 'B', 'C', 'Z')),
  teacher_id uuid not null references public.people(id),
  academic_year_start integer not null,
  month integer not null check (month between 1 and 12),
  version integer not null default 1,
  created_by uuid references public.profiles(id),
  updated_by uuid references public.profiles(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.carrier_students (
  carrier_id uuid not null references public.class_carriers(id) on delete cascade,
  student_id uuid not null references public.people(id),
  primary key (carrier_id, student_id)
);

create table public.schedule_slots (
  carrier_id uuid primary key references public.class_carriers(id) on delete cascade,
  week smallint not null check (week between 0 and 2),
  day smallint not null check (day between 0 and 4),
  start_time time not null,
  updated_by uuid references public.profiles(id),
  updated_at timestamptz not null default now()
);

create table public.audit_log (
  id bigint generated always as identity primary key,
  actor_id uuid references public.profiles(id),
  entity_type text not null,
  entity_id uuid,
  action text not null,
  previous_value jsonb,
  new_value jsonb,
  created_at timestamptz not null default now()
);

create index people_type_idx on public.people(person_type);
create index carriers_period_idx on public.class_carriers(academic_year_start, month);
create index carrier_students_student_idx on public.carrier_students(student_id);
create index schedule_time_idx on public.schedule_slots(week, day, start_time);

create or replace function public.current_user_role()
returns public.app_role
language sql
stable
security definer
set search_path = public
as $$
  select coalesce((select role from public.profiles where id = auth.uid()), 'viewer'::public.app_role);
$$;

create or replace function public.touch_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

create trigger profiles_touch before update on public.profiles
for each row execute function public.touch_updated_at();

create trigger people_touch before update on public.people
for each row execute function public.touch_updated_at();

create trigger carriers_touch before update on public.class_carriers
for each row execute function public.touch_updated_at();

create or replace function public.create_profile_for_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.profiles (id, display_name)
  values (new.id, coalesce(new.raw_user_meta_data ->> 'display_name', new.email))
  on conflict (id) do nothing;
  return new;
end;
$$;

create trigger auth_user_profile
after insert on auth.users
for each row execute function public.create_profile_for_new_user();

create or replace function public.move_carrier(
  p_carrier_id uuid,
  p_week smallint,
  p_day smallint,
  p_start_time time,
  p_expected_version integer
)
returns public.class_carriers
language plpgsql
security definer
set search_path = public
as $$
declare
  v_carrier public.class_carriers;
  v_conflict text;
begin
  if public.current_user_role() not in ('admin', 'scheduler') then
    raise exception 'You do not have permission to move classes.';
  end if;

  perform pg_advisory_xact_lock(hashtext(p_carrier_id::text));

  select * into v_carrier
  from public.class_carriers
  where id = p_carrier_id
  for update;

  if not found then
    raise exception 'Class carrier not found.';
  end if;

  if v_carrier.version <> p_expected_version then
    raise exception 'This class was changed by another user. Refresh and try again.';
  end if;

  select format('Teacher is already scheduled for %s %s.', other.year_group, other.subject)
  into v_conflict
  from public.schedule_slots slot
  join public.class_carriers other on other.id = slot.carrier_id
  where slot.carrier_id <> p_carrier_id
    and other.academic_year_start = v_carrier.academic_year_start
    and other.month = v_carrier.month
    and slot.week = p_week
    and slot.day = p_day
    and slot.start_time = p_start_time
    and other.teacher_id = v_carrier.teacher_id
  limit 1;

  if v_conflict is not null then
    raise exception '%', v_conflict;
  end if;

  select format('%s already has another class at this time.', string_agg(student.name, ', '))
  into v_conflict
  from public.carrier_students moving_student
  join public.people student on student.id = moving_student.student_id
  where moving_student.carrier_id = p_carrier_id
    and exists (
      select 1
      from public.schedule_slots slot
      join public.class_carriers other on other.id = slot.carrier_id
      join public.carrier_students other_student on other_student.carrier_id = other.id
      where other.id <> p_carrier_id
        and other.academic_year_start = v_carrier.academic_year_start
        and other.month = v_carrier.month
        and slot.week = p_week
        and slot.day = p_day
        and slot.start_time = p_start_time
        and other_student.student_id = moving_student.student_id
    );

  if v_conflict is not null then
    raise exception '%', v_conflict;
  end if;

  insert into public.schedule_slots (carrier_id, week, day, start_time, updated_by)
  values (p_carrier_id, p_week, p_day, p_start_time, auth.uid())
  on conflict (carrier_id) do update set
    week = excluded.week,
    day = excluded.day,
    start_time = excluded.start_time,
    updated_by = excluded.updated_by,
    updated_at = now();

  update public.class_carriers
  set version = version + 1, updated_by = auth.uid()
  where id = p_carrier_id
  returning * into v_carrier;

  insert into public.audit_log (actor_id, entity_type, entity_id, action, new_value)
  values (
    auth.uid(),
    'class_carrier',
    p_carrier_id,
    'move',
    jsonb_build_object('week', p_week, 'day', p_day, 'start_time', p_start_time)
  );

  return v_carrier;
end;
$$;

alter table public.profiles enable row level security;
alter table public.people enable row level security;
alter table public.class_carriers enable row level security;
alter table public.carrier_students enable row level security;
alter table public.schedule_slots enable row level security;
alter table public.audit_log enable row level security;

create policy "Authenticated users can read profiles"
on public.profiles for select to authenticated using (true);

create policy "Users can update their own profile"
on public.profiles for update to authenticated using (id = auth.uid())
with check (id = auth.uid() and role = (select role from public.profiles where id = auth.uid()));

create policy "Authenticated users can read people"
on public.people for select to authenticated using (true);

create policy "Schedulers can manage people"
on public.people for all to authenticated
using (public.current_user_role() in ('admin', 'scheduler'))
with check (public.current_user_role() in ('admin', 'scheduler'));

create policy "Authenticated users can read carriers"
on public.class_carriers for select to authenticated using (true);

create policy "Schedulers can manage carriers"
on public.class_carriers for all to authenticated
using (public.current_user_role() in ('admin', 'scheduler'))
with check (public.current_user_role() in ('admin', 'scheduler'));

create policy "Authenticated users can read enrolments"
on public.carrier_students for select to authenticated using (true);

create policy "Schedulers can manage enrolments"
on public.carrier_students for all to authenticated
using (public.current_user_role() in ('admin', 'scheduler'))
with check (public.current_user_role() in ('admin', 'scheduler'));

create policy "Authenticated users can read schedule"
on public.schedule_slots for select to authenticated using (true);

create policy "Schedulers can manage schedule"
on public.schedule_slots for all to authenticated
using (public.current_user_role() in ('admin', 'scheduler'))
with check (public.current_user_role() in ('admin', 'scheduler'));

create policy "Admins can read audit log"
on public.audit_log for select to authenticated
using (public.current_user_role() = 'admin');

grant execute on function public.move_carrier(uuid, smallint, smallint, time, integer) to authenticated;

alter publication supabase_realtime add table public.people;
alter publication supabase_realtime add table public.class_carriers;
alter publication supabase_realtime add table public.carrier_students;
alter publication supabase_realtime add table public.schedule_slots;

