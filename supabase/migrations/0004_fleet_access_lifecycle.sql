-- Fleet access lifecycle hardening. This migration is intentionally forward-only:
-- it upgrades databases that have already applied 0003 without rewriting that
-- published migration or discarding fleet history.

-- An active membership alone is not sufficient for driver-owned data access.
-- The profile status is also a defense-in-depth part of the RLS contract.
create or replace function public.is_current_user_driver(
  target_company_id uuid,
  target_driver_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.drivers as driver
    join public.company_memberships as membership
      on membership.id = driver.membership_id
      and membership.company_id = driver.company_id
    where driver.company_id = target_company_id
      and driver.id = target_driver_id
      and driver.status = 'active'
      and membership.user_id = (select auth.uid())
      and membership.role = 'driver'::public.company_role
      and membership.status = 'active'::public.membership_status
  );
$$;

-- Managers retain historical vehicle visibility. A driver may only see an
-- active vehicle through an active assignment to their active profile.
create or replace function public.can_current_user_view_vehicle(
  target_company_id uuid,
  target_vehicle_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select public.has_active_company_role(
    target_company_id,
    array['owner', 'admin', 'dispatcher']::public.company_role[]
  )
  or exists (
    select 1
    from public.vehicles as vehicle
    join public.driver_vehicle_assignments as assignment
      on assignment.company_id = vehicle.company_id
      and assignment.vehicle_id = vehicle.id
    where vehicle.company_id = target_company_id
      and vehicle.id = target_vehicle_id
      and vehicle.status = 'active'
      and assignment.unassigned_at is null
      and public.is_current_user_driver(assignment.company_id, assignment.driver_id)
  );
$$;

-- Driver deactivation changes the profile, the linked membership, and all
-- currently-effective fleet access in one transaction. It deliberately keeps
-- the underlying rows for audit and operational history rather than deleting.
create or replace function public.update_driver(
  target_company_id uuid,
  target_driver_id uuid,
  driver_display_name text,
  driver_status text
)
returns public.drivers
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor_id uuid := (select auth.uid());
  existing_driver public.drivers%rowtype;
  updated_driver public.drivers%rowtype;
  linked_membership public.company_memberships%rowtype;
  closed_assignment public.driver_vehicle_assignments%rowtype;
  closed_shift public.driver_shifts%rowtype;
  normalized_name text := btrim(driver_display_name);
begin
  if actor_id is null or not exists (
    select 1
    from public.company_memberships as membership
    where membership.company_id = target_company_id
      and membership.user_id = actor_id
      and membership.status = 'active'::public.membership_status
      and membership.role = any(array['owner', 'admin', 'dispatcher']::public.company_role[])
  ) then
    raise exception using
      errcode = '42501',
      message = 'only active owners, admins, or dispatchers may manage fleet resources';
  end if;

  if normalized_name is null or char_length(normalized_name) not between 1 and 160 then
    raise exception using errcode = '22023', message = 'a driver display name is required';
  end if;
  if driver_status not in ('active', 'inactive') then
    raise exception using errcode = '22023', message = 'a valid driver status is required';
  end if;

  -- All lifecycle operations lock profile then its exact membership. Assignment
  -- uses the same lock order before it locks the vehicle.
  select * into existing_driver
  from public.drivers
  where id = target_driver_id and company_id = target_company_id
  for update;
  if not found then
    raise exception using errcode = '42501', message = 'only active owners, admins, or dispatchers may manage fleet resources';
  end if;

  select * into linked_membership
  from public.company_memberships
  where id = existing_driver.membership_id
    and company_id = target_company_id
  for update;
  if not found
    or linked_membership.role <> 'driver'::public.company_role
    or linked_membership.user_id is null then
    raise exception using errcode = '22023', message = 'the driver membership is not available';
  end if;

  if driver_status = 'inactive' and existing_driver.status <> 'inactive' then
    if linked_membership.status = 'active'::public.membership_status then
      update public.company_memberships
      set status = 'suspended'::public.membership_status, updated_at = timezone('utc', now())
      where id = linked_membership.id and company_id = target_company_id;

      insert into public.audit_events (
        company_id, actor_id, action, before_data, after_data, entity_type, entity_id
      ) values (
        target_company_id,
        actor_id,
        'membership.suspended',
        jsonb_build_object('role', linked_membership.role::text, 'status', linked_membership.status::text),
        jsonb_build_object('role', linked_membership.role::text, 'status', 'suspended', 'reason', 'driver_deactivated'),
        'company_membership',
        linked_membership.id
      );
    end if;

    for closed_assignment in
      update public.driver_vehicle_assignments
      set unassigned_at = timezone('utc', now())
      where company_id = target_company_id
        and driver_id = target_driver_id
        and unassigned_at is null
      returning *
    loop
      insert into public.audit_events (
        company_id, actor_id, action, before_data, after_data, entity_type, entity_id
      ) values (
        target_company_id,
        actor_id,
        'driver_vehicle.unassigned',
        jsonb_build_object(
          'id', closed_assignment.id,
          'driverId', closed_assignment.driver_id,
          'vehicleId', closed_assignment.vehicle_id,
          'assignedAt', closed_assignment.assigned_at,
          'unassignedAt', null
        ),
        jsonb_build_object(
          'id', closed_assignment.id,
          'driverId', closed_assignment.driver_id,
          'vehicleId', closed_assignment.vehicle_id,
          'assignedAt', closed_assignment.assigned_at,
          'unassignedAt', closed_assignment.unassigned_at,
          'reason', 'driver_deactivated'
        ),
        'driver_vehicle_assignment',
        closed_assignment.id
      );
    end loop;

    for closed_shift in
      update public.driver_shifts
      set
        off_duty_at = timezone('utc', now()),
        ended_by = actor_id,
        updated_at = timezone('utc', now())
      where company_id = target_company_id
        and driver_id = target_driver_id
        and off_duty_at is null
      returning *
    loop
      insert into public.audit_events (
        company_id, actor_id, action, before_data, after_data, entity_type, entity_id
      ) values (
        target_company_id,
        actor_id,
        'driver_shift.ended_by_deactivation',
        jsonb_build_object(
          'id', closed_shift.id,
          'driverId', closed_shift.driver_id,
          'onDutyAt', closed_shift.on_duty_at,
          'offDutyAt', null
        ),
        jsonb_build_object(
          'id', closed_shift.id,
          'driverId', closed_shift.driver_id,
          'onDutyAt', closed_shift.on_duty_at,
          'offDutyAt', closed_shift.off_duty_at,
          'reason', 'driver_deactivated'
        ),
        'driver_shift',
        closed_shift.id
      );
    end loop;
  elsif driver_status = 'active' and existing_driver.status <> 'active' then
    if linked_membership.status <> 'suspended'::public.membership_status then
      raise exception using
        errcode = '22023',
        message = 'a suspended driver membership is required to reactivate the driver';
    end if;

    update public.company_memberships
    set status = 'active'::public.membership_status, updated_at = timezone('utc', now())
    where id = linked_membership.id and company_id = target_company_id;

    insert into public.audit_events (
      company_id, actor_id, action, before_data, after_data, entity_type, entity_id
    ) values (
      target_company_id,
      actor_id,
      'membership.reactivated',
      jsonb_build_object('role', linked_membership.role::text, 'status', linked_membership.status::text),
      jsonb_build_object('role', linked_membership.role::text, 'status', 'active', 'reason', 'driver_reactivated'),
      'company_membership',
      linked_membership.id
    );
  end if;

  update public.drivers
  set display_name = normalized_name, status = driver_status, updated_at = timezone('utc', now())
  where id = target_driver_id and company_id = target_company_id
  returning * into updated_driver;

  insert into public.audit_events (
    company_id, actor_id, action, before_data, after_data, entity_type, entity_id
  ) values (
    target_company_id,
    actor_id,
    case
      when driver_status = 'inactive' and existing_driver.status <> 'inactive' then 'driver.deactivated'
      else 'driver.updated'
    end,
    jsonb_build_object('displayName', existing_driver.display_name, 'status', existing_driver.status),
    jsonb_build_object('displayName', updated_driver.display_name, 'status', updated_driver.status),
    'driver',
    updated_driver.id
  );

  return updated_driver;
end;
$$;

-- Deactivation severs present driver access without deleting the vehicle or
-- any historical assignment. Reactivation intentionally requires a new,
-- explicit assignment instead of reopening one of these records.
create or replace function public.update_vehicle(
  target_company_id uuid,
  target_vehicle_id uuid,
  vehicle_unit_number text,
  vehicle_type_value text,
  vehicle_capacity_lbs numeric,
  vehicle_status text
)
returns public.vehicles
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor_id uuid := (select auth.uid());
  existing_vehicle public.vehicles%rowtype;
  updated_vehicle public.vehicles%rowtype;
  closed_assignment public.driver_vehicle_assignments%rowtype;
  normalized_unit_number text := upper(btrim(vehicle_unit_number));
  normalized_vehicle_type text := lower(btrim(vehicle_type_value));
begin
  if actor_id is null or not exists (
    select 1
    from public.company_memberships as membership
    where membership.company_id = target_company_id
      and membership.user_id = actor_id
      and membership.status = 'active'::public.membership_status
      and membership.role = any(array['owner', 'admin', 'dispatcher']::public.company_role[])
  ) then
    raise exception using
      errcode = '42501',
      message = 'only active owners, admins, or dispatchers may manage fleet resources';
  end if;

  if normalized_unit_number is null or char_length(normalized_unit_number) not between 1 and 80 then
    raise exception using errcode = '22023', message = 'a vehicle unit number is required';
  end if;
  if normalized_vehicle_type is null or char_length(normalized_vehicle_type) not between 1 and 80 then
    raise exception using errcode = '22023', message = 'a vehicle type is required';
  end if;
  if vehicle_capacity_lbs is not null and vehicle_capacity_lbs <= 0 then
    raise exception using errcode = '22023', message = 'vehicle capacity must be greater than zero';
  end if;
  if vehicle_status not in ('active', 'inactive') then
    raise exception using errcode = '22023', message = 'a valid vehicle status is required';
  end if;

  select * into existing_vehicle
  from public.vehicles
  where id = target_vehicle_id and company_id = target_company_id
  for update;
  if not found then
    raise exception using errcode = '42501', message = 'only active owners, admins, or dispatchers may manage fleet resources';
  end if;

  if vehicle_status = 'inactive' and existing_vehicle.status <> 'inactive' then
    for closed_assignment in
      update public.driver_vehicle_assignments
      set unassigned_at = timezone('utc', now())
      where company_id = target_company_id
        and vehicle_id = target_vehicle_id
        and unassigned_at is null
      returning *
    loop
      insert into public.audit_events (
        company_id, actor_id, action, before_data, after_data, entity_type, entity_id
      ) values (
        target_company_id,
        actor_id,
        'driver_vehicle.unassigned',
        jsonb_build_object(
          'id', closed_assignment.id,
          'driverId', closed_assignment.driver_id,
          'vehicleId', closed_assignment.vehicle_id,
          'assignedAt', closed_assignment.assigned_at,
          'unassignedAt', null
        ),
        jsonb_build_object(
          'id', closed_assignment.id,
          'driverId', closed_assignment.driver_id,
          'vehicleId', closed_assignment.vehicle_id,
          'assignedAt', closed_assignment.assigned_at,
          'unassignedAt', closed_assignment.unassigned_at,
          'reason', 'vehicle_deactivated'
        ),
        'driver_vehicle_assignment',
        closed_assignment.id
      );
    end loop;
  end if;

  update public.vehicles
  set
    unit_number = normalized_unit_number,
    vehicle_type = normalized_vehicle_type,
    capacity_lbs = vehicle_capacity_lbs,
    status = vehicle_status,
    updated_at = timezone('utc', now())
  where id = target_vehicle_id and company_id = target_company_id
  returning * into updated_vehicle;

  insert into public.audit_events (
    company_id, actor_id, action, before_data, after_data, entity_type, entity_id
  ) values (
    target_company_id,
    actor_id,
    case
      when vehicle_status = 'inactive' and existing_vehicle.status <> 'inactive' then 'vehicle.deactivated'
      else 'vehicle.updated'
    end,
    jsonb_build_object(
      'unitNumber', existing_vehicle.unit_number,
      'vehicleType', existing_vehicle.vehicle_type,
      'capacityLbs', existing_vehicle.capacity_lbs,
      'status', existing_vehicle.status
    ),
    jsonb_build_object(
      'unitNumber', updated_vehicle.unit_number,
      'vehicleType', updated_vehicle.vehicle_type,
      'capacityLbs', updated_vehicle.capacity_lbs,
      'status', updated_vehicle.status
    ),
    'vehicle',
    updated_vehicle.id
  );

  return updated_vehicle;
end;
$$;

-- Assignments require both sides of the driver access unit to be active. This
-- prevents a stale active profile paired with a suspended membership from
-- receiving a new vehicle.
create or replace function public.assign_driver_vehicle(
  target_company_id uuid,
  target_driver_id uuid,
  target_vehicle_id uuid
)
returns public.driver_vehicle_assignments
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor_id uuid := (select auth.uid());
  target_driver public.drivers%rowtype;
  target_driver_membership public.company_memberships%rowtype;
  target_vehicle public.vehicles%rowtype;
  created_assignment public.driver_vehicle_assignments%rowtype;
  previous_assignments jsonb;
begin
  if actor_id is null or not exists (
    select 1
    from public.company_memberships as membership
    where membership.company_id = target_company_id
      and membership.user_id = actor_id
      and membership.status = 'active'::public.membership_status
      and membership.role = any(array['owner', 'admin', 'dispatcher']::public.company_role[])
  ) then
    raise exception using
      errcode = '42501',
      message = 'only active owners, admins, or dispatchers may manage fleet resources';
  end if;

  select * into target_driver
  from public.drivers
  where id = target_driver_id and company_id = target_company_id
  for update;
  if not found then
    raise exception using errcode = '42501', message = 'only active owners, admins, or dispatchers may manage fleet resources';
  end if;
  if target_driver.status <> 'active' then
    raise exception using errcode = '22023', message = 'driver must be active to receive a vehicle assignment';
  end if;

  select * into target_driver_membership
  from public.company_memberships
  where id = target_driver.membership_id
    and company_id = target_company_id
  for update;
  if not found
    or target_driver_membership.status <> 'active'::public.membership_status
    or target_driver_membership.role <> 'driver'::public.company_role
    or target_driver_membership.user_id is null then
    raise exception using
      errcode = '22023',
      message = 'an active driver membership is required to receive a vehicle assignment';
  end if;

  select * into target_vehicle
  from public.vehicles
  where id = target_vehicle_id and company_id = target_company_id
  for update;
  if not found then
    raise exception using errcode = '42501', message = 'only active owners, admins, or dispatchers may manage fleet resources';
  end if;
  if target_vehicle.status <> 'active' then
    raise exception using errcode = '22023', message = 'vehicle must be active to receive a driver assignment';
  end if;

  select coalesce(
    jsonb_agg(jsonb_build_object(
      'id', assignment.id,
      'driverId', assignment.driver_id,
      'vehicleId', assignment.vehicle_id,
      'assignedAt', assignment.assigned_at
    )),
    '[]'::jsonb
  ) into previous_assignments
  from public.driver_vehicle_assignments as assignment
  where assignment.company_id = target_company_id
    and assignment.unassigned_at is null
    and (assignment.driver_id = target_driver_id or assignment.vehicle_id = target_vehicle_id);

  update public.driver_vehicle_assignments
  set unassigned_at = timezone('utc', now())
  where company_id = target_company_id
    and unassigned_at is null
    and (driver_id = target_driver_id or vehicle_id = target_vehicle_id);

  insert into public.driver_vehicle_assignments (
    company_id, driver_id, vehicle_id, assigned_by
  ) values (
    target_company_id, target_driver_id, target_vehicle_id, actor_id
  ) returning * into created_assignment;

  insert into public.audit_events (
    company_id, actor_id, action, before_data, after_data, entity_type, entity_id
  ) values (
    target_company_id,
    actor_id,
    'driver_vehicle.assigned',
    previous_assignments,
    jsonb_build_object(
      'id', created_assignment.id,
      'driverId', created_assignment.driver_id,
      'vehicleId', created_assignment.vehicle_id,
      'assignedAt', created_assignment.assigned_at
    ),
    'driver_vehicle_assignment',
    created_assignment.id
  );

  return created_assignment;
end;
$$;

revoke all on function public.is_current_user_driver(uuid, uuid) from public;
revoke all on function public.can_current_user_view_vehicle(uuid, uuid) from public;
revoke all on function public.update_driver(uuid, uuid, text, text) from public, anon;
revoke all on function public.update_vehicle(uuid, uuid, text, text, numeric, text) from public, anon;
revoke all on function public.assign_driver_vehicle(uuid, uuid, uuid) from public, anon;
grant execute on function public.is_current_user_driver(uuid, uuid) to anon, authenticated;
grant execute on function public.can_current_user_view_vehicle(uuid, uuid) to anon, authenticated;
grant execute on function public.update_driver(uuid, uuid, text, text) to authenticated;
grant execute on function public.update_vehicle(uuid, uuid, text, text, numeric, text) to authenticated;
grant execute on function public.assign_driver_vehicle(uuid, uuid, uuid) to authenticated;
