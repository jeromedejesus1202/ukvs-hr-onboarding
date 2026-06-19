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
    )
  having count(*) > 0;

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

grant execute on function public.move_carrier(uuid, smallint, smallint, time, integer) to authenticated;
