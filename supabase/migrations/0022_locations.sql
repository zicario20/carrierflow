-- Privacy-safe driver tracking. Current position, retained samples, and
-- aggregate-only retention are separate models. Mobile callers can submit a
-- bounded sample only through a zero-scope RPC; tenant, driver, and load are
-- always derived from auth.uid() in this migration.

create schema if not exists driver_tracking_private;
revoke all on schema driver_tracking_private from public, anon, authenticated;

create table public.current_driver_locations (
  company_id uuid not null references public.companies(id) on delete restrict,
  driver_id uuid not null,
  load_id uuid,
  latitude double precision not null check (latitude between -90 and 90),
  longitude double precision not null check (longitude between -180 and 180),
  accuracy_meters double precision not null check (accuracy_meters between 0 and 100000),
  speed_meters_per_second double precision check (speed_meters_per_second between 0 and 100),
  heading_degrees double precision check (heading_degrees >= 0 and heading_degrees < 360),
  recorded_at timestamptz not null,
  received_at timestamptz not null default timezone('utc', now()),
  primary key (company_id, driver_id),
  foreign key (driver_id, company_id)
    references public.drivers (id, company_id) on delete restrict,
  foreign key (load_id, company_id)
    references public.loads (id, company_id) on delete restrict
);

create table public.driver_location_history (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete restrict,
  driver_id uuid not null,
  load_id uuid,
  latitude double precision not null check (latitude between -90 and 90),
  longitude double precision not null check (longitude between -180 and 180),
  accuracy_meters double precision not null check (accuracy_meters between 0 and 100000),
  speed_meters_per_second double precision check (speed_meters_per_second between 0 and 100),
  heading_degrees double precision check (heading_degrees >= 0 and heading_degrees < 360),
  recorded_at timestamptz not null,
  received_at timestamptz not null default timezone('utc', now()),
  unique (id, company_id),
  foreign key (driver_id, company_id)
    references public.drivers (id, company_id) on delete restrict,
  foreign key (load_id, company_id)
    references public.loads (id, company_id) on delete restrict
);

-- Rollups intentionally omit coordinates, route geometry, speed, and heading.
-- They keep only enough information to prove a policy ran and quantify history
-- without retaining a driver movement trail.
create table public.driver_location_daily_rollups (
  company_id uuid not null references public.companies(id) on delete restrict,
  driver_id uuid not null,
  recorded_on date not null,
  sample_count integer not null check (sample_count > 0),
  first_recorded_at timestamptz not null,
  last_recorded_at timestamptz not null,
  average_accuracy_meters double precision not null check (average_accuracy_meters >= 0),
  created_at timestamptz not null default timezone('utc', now()),
  updated_at timestamptz not null default timezone('utc', now()),
  primary key (company_id, driver_id, recorded_on),
  foreign key (driver_id, company_id)
    references public.drivers (id, company_id) on delete restrict,
  check (last_recorded_at >= first_recorded_at)
);

create table public.company_location_retention_policies (
  company_id uuid primary key references public.companies(id) on delete restrict,
  detailed_history_days integer not null default 7 check (detailed_history_days between 1 and 31),
  updated_at timestamptz not null default timezone('utc', now())
);

create index driver_location_history_company_recorded_idx
  on public.driver_location_history (company_id, recorded_at desc);
create index driver_location_history_company_driver_recorded_idx
  on public.driver_location_history (company_id, driver_id, recorded_at desc);
create index current_driver_locations_company_received_idx
  on public.current_driver_locations (company_id, received_at desc);

alter table public.current_driver_locations enable row level security;
alter table public.current_driver_locations force row level security;
alter table public.driver_location_history enable row level security;
alter table public.driver_location_history force row level security;
alter table public.driver_location_daily_rollups enable row level security;
alter table public.driver_location_daily_rollups force row level security;
alter table public.company_location_retention_policies enable row level security;
alter table public.company_location_retention_policies force row level security;

-- Direct table privileges stay absent. These policies are defense in depth for
-- authenticated server reads and make manager scope explicit if a future
-- internal adapter is granted select access.
create policy current_driver_locations_select_managers
  on public.current_driver_locations for select to authenticated
  using (public.has_active_company_role(company_id, array['owner', 'admin', 'dispatcher']::public.company_role[]));
create policy driver_location_history_select_managers
  on public.driver_location_history for select to authenticated
  using (public.has_active_company_role(company_id, array['owner', 'admin']::public.company_role[]));
create policy driver_location_daily_rollups_select_managers
  on public.driver_location_daily_rollups for select to authenticated
  using (public.has_active_company_role(company_id, array['owner', 'admin']::public.company_role[]));
create policy company_location_retention_policies_select_owners
  on public.company_location_retention_policies for select to authenticated
  using (public.has_active_company_role(company_id, array['owner', 'admin']::public.company_role[]));

revoke all on table public.current_driver_locations,
  public.driver_location_history,
  public.driver_location_daily_rollups,
  public.company_location_retention_policies
  from public, anon, authenticated;

create function driver_tracking_private.current_own_driver_tracking_scope()
returns table (company_id uuid, driver_id uuid, active_load_id uuid)
language plpgsql
security definer
set search_path = ''
as $$
declare
  current_actor_id uuid := (select auth.uid());
begin
  if current_actor_id is null then
    raise exception using errcode = '42501', message = 'an active driver tracking context is required';
  end if;

  return query
  select
    driver.company_id,
    driver.id,
    (
      select load.id
      from public.loads as load
      where load.company_id = driver.company_id
        and load.assigned_driver_id = driver.id
        and load.operational_status in (
          'assigned', 'en_route_to_pickup', 'arrived_pickup', 'loading',
          'picked_up', 'en_route_to_delivery', 'arrived_delivery', 'unloading'
        )
      order by
        case when load.operational_status = 'assigned' then 1 else 0 end,
        load.load_number,
        load.id
      limit 1
    )
  from public.drivers as driver
  join public.company_memberships as membership
    on membership.id = driver.membership_id
    and membership.company_id = driver.company_id
  where membership.user_id = current_actor_id
    and membership.role = 'driver'::public.company_role
    and membership.status = 'active'::public.membership_status
    and driver.status = 'active'
    and (
      exists (
        select 1
        from public.driver_shifts as shift
        where shift.company_id = driver.company_id
          and shift.driver_id = driver.id
          and shift.off_duty_at is null
      )
      or exists (
        select 1
        from public.loads as load
        where load.company_id = driver.company_id
          and load.assigned_driver_id = driver.id
          and load.operational_status in (
            'assigned', 'en_route_to_pickup', 'arrived_pickup', 'loading',
            'picked_up', 'en_route_to_delivery', 'arrived_delivery', 'unloading'
          )
      )
    )
  limit 1;

  if not found then
    raise exception using errcode = '42501', message = 'an active driver tracking context is required';
  end if;
end;
$$;

create function public.record_own_driver_location_sample(
  latitude_value double precision,
  longitude_value double precision,
  accuracy_meters_value double precision,
  speed_meters_per_second_value double precision,
  heading_degrees_value double precision,
  recorded_at_value timestamptz
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  scope record;
  saved_current public.current_driver_locations%rowtype;
  saved_history public.driver_location_history%rowtype;
begin
  if latitude_value is null
      or longitude_value is null
      or accuracy_meters_value is null
      or recorded_at_value is null
      or latitude_value <> latitude_value
      or longitude_value <> longitude_value
      or accuracy_meters_value <> accuracy_meters_value
      or latitude_value not between -90 and 90
      or longitude_value not between -180 and 180
      or accuracy_meters_value < 0
      or accuracy_meters_value > 100000
      or (speed_meters_per_second_value is not null and (
        speed_meters_per_second_value <> speed_meters_per_second_value
        or speed_meters_per_second_value < 0
        or speed_meters_per_second_value > 100
      ))
      or (heading_degrees_value is not null and (
        heading_degrees_value <> heading_degrees_value
        or heading_degrees_value < 0
        or heading_degrees_value >= 360
      ))
      or recorded_at_value < timezone('utc', now()) - interval '31 days'
      or recorded_at_value > timezone('utc', now()) + interval '5 minutes' then
    raise exception using errcode = '22023', message = 'a valid location sample is required';
  end if;

  select * into scope from driver_tracking_private.current_own_driver_tracking_scope();

  insert into public.driver_location_history (
    company_id, driver_id, load_id, latitude, longitude, accuracy_meters,
    speed_meters_per_second, heading_degrees, recorded_at
  ) values (
    scope.company_id, scope.driver_id, scope.active_load_id, latitude_value,
    longitude_value, accuracy_meters_value, speed_meters_per_second_value,
    heading_degrees_value, recorded_at_value
  ) returning * into saved_history;

  insert into public.current_driver_locations (
    company_id, driver_id, load_id, latitude, longitude, accuracy_meters,
    speed_meters_per_second, heading_degrees, recorded_at
  ) values (
    scope.company_id, scope.driver_id, scope.active_load_id, latitude_value,
    longitude_value, accuracy_meters_value, speed_meters_per_second_value,
    heading_degrees_value, recorded_at_value
  )
  on conflict (company_id, driver_id) do update set
    load_id = excluded.load_id,
    latitude = excluded.latitude,
    longitude = excluded.longitude,
    accuracy_meters = excluded.accuracy_meters,
    speed_meters_per_second = excluded.speed_meters_per_second,
    heading_degrees = excluded.heading_degrees,
    recorded_at = excluded.recorded_at,
    received_at = timezone('utc', now())
  where excluded.recorded_at >= public.current_driver_locations.recorded_at
  returning * into saved_current;

  if not found then
    select * into saved_current
    from public.current_driver_locations as current_location
    where current_location.company_id = scope.company_id
      and current_location.driver_id = scope.driver_id;
  end if;

  insert into public.audit_events (
    company_id, actor_id, action, before_data, after_data, entity_type, entity_id
  ) values (
    scope.company_id,
    (select auth.uid()),
    'location.sample_recorded',
    '{}'::jsonb,
    jsonb_build_object(
      'accuracyMeters', saved_history.accuracy_meters,
      'recordedAt', saved_history.recorded_at,
      'retainedAsCurrent', saved_current.recorded_at = saved_history.recorded_at
    ),
    'driver_location_history',
    saved_history.id
  );

  return jsonb_build_object(
    'accuracyMeters', saved_current.accuracy_meters,
    'recordedAt', saved_current.recorded_at
  );
end;
$$;

create function public.get_authorized_current_driver_location(
  target_company_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  result jsonb;
begin
  if target_company_id is null or not public.has_active_company_role(
    target_company_id,
    array['owner', 'admin', 'dispatcher']::public.company_role[]
  ) then
    raise exception using errcode = '42501', message = 'an authorized operations context is required';
  end if;

  select jsonb_build_object(
    'accuracyMeters', current_location.accuracy_meters,
    'driverLabel', driver.display_name,
    'latitude', current_location.latitude,
    'loadNumber', load.load_number,
    'longitude', current_location.longitude,
    'operationalStatus', load.operational_status,
    'recordedAt', current_location.recorded_at
  ) into result
  from public.current_driver_locations as current_location
  join public.drivers as driver
    on driver.company_id = current_location.company_id
    and driver.id = current_location.driver_id
  left join public.loads as load
    on load.company_id = current_location.company_id
    and load.id = current_location.load_id
  where current_location.company_id = target_company_id
  order by current_location.recorded_at desc, current_location.driver_id
  limit 1;

  return result;
end;
$$;

create function public.run_location_retention(
  target_company_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  detailed_history_days_value integer;
  deleted_count integer := 0;
begin
  if target_company_id is null or not public.has_active_company_role(
    target_company_id,
    array['owner', 'admin']::public.company_role[]
  ) then
    raise exception using errcode = '42501', message = 'an authorized privacy context is required';
  end if;

  select coalesce(policy.detailed_history_days, 7)
  into detailed_history_days_value
  from public.companies as company
  left join public.company_location_retention_policies as policy
    on policy.company_id = company.id
  where company.id = target_company_id;
  if detailed_history_days_value is null then
    raise exception using errcode = '42501', message = 'an authorized privacy context is required';
  end if;

  insert into public.driver_location_daily_rollups (
    company_id, driver_id, recorded_on, sample_count, first_recorded_at,
    last_recorded_at, average_accuracy_meters
  )
  select
    history.company_id,
    history.driver_id,
    (history.recorded_at at time zone 'UTC')::date,
    count(*)::integer,
    min(history.recorded_at),
    max(history.recorded_at),
    avg(history.accuracy_meters)
  from public.driver_location_history as history
  where history.company_id = target_company_id
    and history.recorded_at < timezone('utc', now()) - make_interval(days => detailed_history_days_value)
  group by history.company_id, history.driver_id, (history.recorded_at at time zone 'UTC')::date
  on conflict (company_id, driver_id, recorded_on) do update set
    sample_count = public.driver_location_daily_rollups.sample_count + excluded.sample_count,
    first_recorded_at = least(public.driver_location_daily_rollups.first_recorded_at, excluded.first_recorded_at),
    last_recorded_at = greatest(public.driver_location_daily_rollups.last_recorded_at, excluded.last_recorded_at),
    average_accuracy_meters = (
      (public.driver_location_daily_rollups.average_accuracy_meters * public.driver_location_daily_rollups.sample_count)
      + (excluded.average_accuracy_meters * excluded.sample_count)
    ) / (public.driver_location_daily_rollups.sample_count + excluded.sample_count),
    updated_at = timezone('utc', now());

  delete from public.driver_location_history as history
  where history.company_id = target_company_id
    and history.recorded_at < timezone('utc', now()) - make_interval(days => detailed_history_days_value);
  get diagnostics deleted_count = row_count;

  insert into public.audit_events (
    company_id, actor_id, action, before_data, after_data, entity_type, entity_id
  ) values (
    target_company_id,
    (select auth.uid()),
    'location_history.retained',
    '{}'::jsonb,
    jsonb_build_object(
      'detailedHistoryDays', detailed_history_days_value,
      'purgedDetailedSampleCount', deleted_count
    ),
    'company_location_retention_policy',
    target_company_id
  );

  return jsonb_build_object(
    'detailedHistoryDays', detailed_history_days_value,
    'purgedDetailedSampleCount', deleted_count
  );
end;
$$;

revoke all on function driver_tracking_private.current_own_driver_tracking_scope() from public, anon, authenticated;
revoke all on function public.record_own_driver_location_sample(
  double precision, double precision, double precision, double precision,
  double precision, timestamptz
) from public, anon;
revoke all on function public.get_authorized_current_driver_location(uuid)
  from public, anon;
revoke all on function public.run_location_retention(uuid) from public, anon;
grant execute on function public.record_own_driver_location_sample(
  double precision, double precision, double precision, double precision,
  double precision, timestamptz
) to authenticated;
grant execute on function public.get_authorized_current_driver_location(uuid)
  to authenticated;
grant execute on function public.run_location_retention(uuid) to authenticated;
