-- CarrierFlow fleet foundation: tenant-scoped driver profiles, vehicles,
-- assignments, and shifts. All writes remain inside narrow authenticated RPCs.

alter table public.company_memberships
  add constraint company_memberships_id_company_id_key unique (id, company_id);

alter table public.audit_events
  drop constraint audit_events_before_data_create_only_check,
  add constraint audit_events_before_data_create_only_check check (
    before_data is not null
    or action in (
      'membership.invited',
      'driver.created',
      'vehicle.created',
      'driver_vehicle.assigned',
      'driver_shift.started'
    )
  );

create table public.drivers (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete restrict,
  membership_id uuid not null,
  display_name text not null check (char_length(btrim(display_name)) between 1 and 160),
  status text not null default 'active' check (status in ('active', 'inactive')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (id, company_id),
  unique (company_id, membership_id),
  foreign key (membership_id, company_id)
    references public.company_memberships (id, company_id) on delete restrict
);

create table public.vehicles (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete restrict,
  unit_number text not null check (
    unit_number = upper(btrim(unit_number))
    and char_length(unit_number) between 1 and 80
  ),
  vehicle_type text not null check (
    vehicle_type = lower(btrim(vehicle_type))
    and char_length(vehicle_type) between 1 and 80
  ),
  capacity_lbs numeric(12, 2) check (capacity_lbs is null or capacity_lbs > 0),
  status text not null default 'active' check (status in ('active', 'inactive')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (id, company_id),
  unique (company_id, unit_number)
);

create table public.driver_vehicle_assignments (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete restrict,
  driver_id uuid not null,
  vehicle_id uuid not null,
  assigned_by uuid not null references auth.users(id) on delete restrict,
  assigned_at timestamptz not null default now(),
  unassigned_at timestamptz,
  unique (id, company_id),
  foreign key (driver_id, company_id)
    references public.drivers (id, company_id) on delete restrict,
  foreign key (vehicle_id, company_id)
    references public.vehicles (id, company_id) on delete restrict,
  check (unassigned_at is null or unassigned_at >= assigned_at)
);

create table public.driver_shifts (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete restrict,
  driver_id uuid not null,
  on_duty_at timestamptz not null default now(),
  off_duty_at timestamptz,
  started_by uuid not null references auth.users(id) on delete restrict,
  ended_by uuid references auth.users(id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (id, company_id),
  foreign key (driver_id, company_id)
    references public.drivers (id, company_id) on delete restrict,
  check (off_duty_at is null or off_duty_at >= on_duty_at)
);

create index drivers_company_status_idx on public.drivers (company_id, status);
create index vehicles_company_status_idx on public.vehicles (company_id, status);
create index driver_vehicle_assignments_company_driver_idx
  on public.driver_vehicle_assignments (company_id, driver_id, assigned_at desc);
create index driver_vehicle_assignments_company_vehicle_idx
  on public.driver_vehicle_assignments (company_id, vehicle_id, assigned_at desc);
create unique index driver_vehicle_assignments_open_driver_key
  on public.driver_vehicle_assignments (company_id, driver_id)
  where unassigned_at is null;
create unique index driver_vehicle_assignments_open_vehicle_key
  on public.driver_vehicle_assignments (company_id, vehicle_id)
  where unassigned_at is null;
create index driver_shifts_company_driver_idx
  on public.driver_shifts (company_id, driver_id, on_duty_at desc);
create unique index driver_shifts_open_driver_key
  on public.driver_shifts (company_id, driver_id)
  where off_duty_at is null;

-- These RLS helpers only answer whether the current authenticated user is the
-- driver that owns a profile or currently assigned vehicle. They use a fixed
-- search path and do not accept caller-controlled identifiers.
create function public.is_current_user_driver(
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

create function public.can_current_user_view_vehicle(
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
    from public.driver_vehicle_assignments as assignment
    where assignment.company_id = target_company_id
      and assignment.vehicle_id = target_vehicle_id
      and assignment.unassigned_at is null
      and public.is_current_user_driver(assignment.company_id, assignment.driver_id)
  );
$$;

revoke all on function public.is_current_user_driver(uuid, uuid) from public;
revoke all on function public.can_current_user_view_vehicle(uuid, uuid) from public;
grant execute on function public.is_current_user_driver(uuid, uuid) to anon, authenticated;
grant execute on function public.can_current_user_view_vehicle(uuid, uuid) to anon, authenticated;

alter table public.drivers enable row level security;
alter table public.drivers force row level security;
alter table public.vehicles enable row level security;
alter table public.vehicles force row level security;
alter table public.driver_vehicle_assignments enable row level security;
alter table public.driver_vehicle_assignments force row level security;
alter table public.driver_shifts enable row level security;
alter table public.driver_shifts force row level security;

revoke all on table public.drivers, public.vehicles, public.driver_vehicle_assignments, public.driver_shifts from public;
grant select on table public.drivers, public.vehicles, public.driver_vehicle_assignments, public.driver_shifts to anon, authenticated;
revoke insert, update, delete, truncate, references, trigger
  on table public.drivers, public.vehicles, public.driver_vehicle_assignments, public.driver_shifts
  from anon, authenticated;

create policy drivers_select_company_or_self
  on public.drivers
  for select
  to anon, authenticated
  using (
    public.has_active_company_role(
      company_id,
      array['owner', 'admin', 'dispatcher']::public.company_role[]
    )
    or public.is_current_user_driver(company_id, id)
  );

create policy vehicles_select_company_or_assigned_driver
  on public.vehicles
  for select
  to anon, authenticated
  using (public.can_current_user_view_vehicle(company_id, id));

create policy assignments_select_company_or_assigned_driver
  on public.driver_vehicle_assignments
  for select
  to anon, authenticated
  using (
    public.has_active_company_role(
      company_id,
      array['owner', 'admin', 'dispatcher']::public.company_role[]
    )
    or public.is_current_user_driver(company_id, driver_id)
  );

create policy shifts_select_company_or_own_driver
  on public.driver_shifts
  for select
  to anon, authenticated
  using (
    public.has_active_company_role(
      company_id,
      array['owner', 'admin', 'dispatcher']::public.company_role[]
    )
    or public.is_current_user_driver(company_id, driver_id)
  );

create function public.create_driver(
  target_company_id uuid,
  target_membership_id uuid,
  driver_display_name text
)
returns public.drivers
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor_id uuid := (select auth.uid());
  created_driver public.drivers%rowtype;
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

  if not exists (
    select 1
    from public.company_memberships as membership
    where membership.id = target_membership_id
      and membership.company_id = target_company_id
      and membership.role = 'driver'::public.company_role
      and membership.status = 'active'::public.membership_status
      and membership.user_id is not null
  ) then
    raise exception using errcode = '22023', message = 'an active driver membership is required';
  end if;

  insert into public.drivers (company_id, membership_id, display_name)
  values (target_company_id, target_membership_id, normalized_name)
  returning * into created_driver;

  insert into public.audit_events (
    company_id, actor_id, action, before_data, after_data, entity_type, entity_id
  ) values (
    target_company_id,
    actor_id,
    'driver.created',
    null,
    jsonb_build_object(
      'id', created_driver.id,
      'membershipId', created_driver.membership_id,
      'displayName', created_driver.display_name,
      'status', created_driver.status
    ),
    'driver',
    created_driver.id
  );

  return created_driver;
end;
$$;

create function public.update_driver(
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

  select * into existing_driver
  from public.drivers
  where id = target_driver_id and company_id = target_company_id
  for update;
  if not found then
    raise exception using errcode = '42501', message = 'only active owners, admins, or dispatchers may manage fleet resources';
  end if;

  -- A deactivation is an access revocation, not merely a display-status
  -- change. This SECURITY DEFINER function owns every related transition so
  -- membership, assignment, shift, and audit history commit or roll back as
  -- one transaction.
  if driver_status = 'inactive' and existing_driver.status <> 'inactive' then
    select * into linked_membership
    from public.company_memberships
    where id = existing_driver.membership_id
      and company_id = target_company_id
    for update;
    if not found then
      raise exception using errcode = '22023', message = 'the driver membership is not available';
    end if;

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
        jsonb_build_object(
          'role', linked_membership.role::text,
          'status', linked_membership.status::text
        ),
        jsonb_build_object(
          'role', linked_membership.role::text,
          'status', 'suspended',
          'reason', 'driver_deactivated'
        ),
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
    jsonb_build_object(
      'displayName', existing_driver.display_name,
      'status', existing_driver.status
    ),
    jsonb_build_object(
      'displayName', updated_driver.display_name,
      'status', updated_driver.status
    ),
    'driver',
    updated_driver.id
  );

  return updated_driver;
end;
$$;

create function public.create_vehicle(
  target_company_id uuid,
  vehicle_unit_number text,
  vehicle_type_value text,
  vehicle_capacity_lbs numeric
)
returns public.vehicles
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor_id uuid := (select auth.uid());
  created_vehicle public.vehicles%rowtype;
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

  insert into public.vehicles (company_id, unit_number, vehicle_type, capacity_lbs)
  values (target_company_id, normalized_unit_number, normalized_vehicle_type, vehicle_capacity_lbs)
  returning * into created_vehicle;

  insert into public.audit_events (
    company_id, actor_id, action, before_data, after_data, entity_type, entity_id
  ) values (
    target_company_id,
    actor_id,
    'vehicle.created',
    null,
    jsonb_build_object(
      'id', created_vehicle.id,
      'unitNumber', created_vehicle.unit_number,
      'vehicleType', created_vehicle.vehicle_type,
      'capacityLbs', created_vehicle.capacity_lbs,
      'status', created_vehicle.status
    ),
    'vehicle',
    created_vehicle.id
  );

  return created_vehicle;
end;
$$;

create function public.update_vehicle(
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
    'vehicle.updated',
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

create function public.assign_driver_vehicle(
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

create function public.start_driver_shift(target_driver_id uuid)
returns public.driver_shifts
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor_id uuid := (select auth.uid());
  target_driver public.drivers%rowtype;
  created_shift public.driver_shifts%rowtype;
begin
  select driver.* into target_driver
  from public.drivers as driver
  join public.company_memberships as membership
    on membership.id = driver.membership_id
    and membership.company_id = driver.company_id
  where driver.id = target_driver_id
    and membership.user_id = actor_id
    and membership.role = 'driver'::public.company_role
    and membership.status = 'active'::public.membership_status
  for update of driver;
  if not found then
    raise exception using errcode = '42501', message = 'a driver may only manage their own shift';
  end if;
  if target_driver.status <> 'active' then
    raise exception using errcode = '22023', message = 'an active driver profile is required to start a shift';
  end if;
  if exists (
    select 1
    from public.driver_shifts as shift
    where shift.company_id = target_driver.company_id
      and shift.driver_id = target_driver.id
      and shift.off_duty_at is null
  ) then
    raise exception using errcode = '22023', message = 'the driver already has an open shift';
  end if;

  insert into public.driver_shifts (company_id, driver_id, started_by)
  values (target_driver.company_id, target_driver.id, actor_id)
  returning * into created_shift;

  insert into public.audit_events (
    company_id, actor_id, action, before_data, after_data, entity_type, entity_id
  ) values (
    target_driver.company_id,
    actor_id,
    'driver_shift.started',
    null,
    jsonb_build_object(
      'id', created_shift.id,
      'driverId', created_shift.driver_id,
      'onDutyAt', created_shift.on_duty_at
    ),
    'driver_shift',
    created_shift.id
  );

  return created_shift;
end;
$$;

create function public.end_driver_shift(target_driver_id uuid)
returns public.driver_shifts
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor_id uuid := (select auth.uid());
  target_driver public.drivers%rowtype;
  existing_shift public.driver_shifts%rowtype;
  ended_shift public.driver_shifts%rowtype;
begin
  select driver.* into target_driver
  from public.drivers as driver
  join public.company_memberships as membership
    on membership.id = driver.membership_id
    and membership.company_id = driver.company_id
  where driver.id = target_driver_id
    and membership.user_id = actor_id
    and membership.role = 'driver'::public.company_role
    and membership.status = 'active'::public.membership_status
  for update of driver;
  if not found then
    raise exception using errcode = '42501', message = 'a driver may only manage their own shift';
  end if;

  select * into existing_shift
  from public.driver_shifts
  where company_id = target_driver.company_id
    and driver_id = target_driver.id
    and off_duty_at is null
  for update;
  if not found then
    raise exception using errcode = '22023', message = 'the driver does not have an open shift';
  end if;

  update public.driver_shifts
  set off_duty_at = timezone('utc', now()), ended_by = actor_id, updated_at = timezone('utc', now())
  where id = existing_shift.id and company_id = target_driver.company_id
  returning * into ended_shift;

  insert into public.audit_events (
    company_id, actor_id, action, before_data, after_data, entity_type, entity_id
  ) values (
    target_driver.company_id,
    actor_id,
    'driver_shift.ended',
    jsonb_build_object(
      'id', existing_shift.id,
      'driverId', existing_shift.driver_id,
      'onDutyAt', existing_shift.on_duty_at,
      'offDutyAt', existing_shift.off_duty_at
    ),
    jsonb_build_object(
      'id', ended_shift.id,
      'driverId', ended_shift.driver_id,
      'onDutyAt', ended_shift.on_duty_at,
      'offDutyAt', ended_shift.off_duty_at
    ),
    'driver_shift',
    ended_shift.id
  );

  return ended_shift;
end;
$$;

revoke all on function public.create_driver(uuid, uuid, text) from public, anon;
revoke all on function public.update_driver(uuid, uuid, text, text) from public, anon;
revoke all on function public.create_vehicle(uuid, text, text, numeric) from public, anon;
revoke all on function public.update_vehicle(uuid, uuid, text, text, numeric, text) from public, anon;
revoke all on function public.assign_driver_vehicle(uuid, uuid, uuid) from public, anon;
revoke all on function public.start_driver_shift(uuid) from public, anon;
revoke all on function public.end_driver_shift(uuid) from public, anon;
grant execute on function public.create_driver(uuid, uuid, text) to authenticated;
grant execute on function public.update_driver(uuid, uuid, text, text) to authenticated;
grant execute on function public.create_vehicle(uuid, text, text, numeric) to authenticated;
grant execute on function public.update_vehicle(uuid, uuid, text, text, numeric, text) to authenticated;
grant execute on function public.assign_driver_vehicle(uuid, uuid, uuid) to authenticated;
grant execute on function public.start_driver_shift(uuid) to authenticated;
grant execute on function public.end_driver_shift(uuid) to authenticated;
