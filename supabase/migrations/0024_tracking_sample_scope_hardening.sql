-- Forward-only security hardening for E3-T2. An upcoming assigned load is
-- not operational work: it may be sampled only during an open shift and is
-- never associated to that next load. Current coordinates are released only
-- while a driver is on duty or has an operational active load, and only when
-- the reading is no more than five minutes old.

create or replace function driver_tracking_private.current_own_driver_tracking_scope()
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
          'en_route_to_pickup', 'arrived_pickup', 'loading', 'picked_up',
          'en_route_to_delivery', 'arrived_delivery', 'unloading'
        )
      order by load.load_number, load.id
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
            'en_route_to_pickup', 'arrived_pickup', 'loading', 'picked_up',
            'en_route_to_delivery', 'arrived_delivery', 'unloading'
          )
      )
    )
  limit 1;

  if not found then
    raise exception using errcode = '42501', message = 'an active driver tracking context is required';
  end if;
end;
$$;

create or replace function public.get_authorized_current_driver_location(
  target_company_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  result jsonb;
  current_location_freshness_cutoff timestamptz := timezone('utc', now()) - interval '5 minutes';
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
    and load.operational_status in (
      'en_route_to_pickup', 'arrived_pickup', 'loading', 'picked_up',
      'en_route_to_delivery', 'arrived_delivery', 'unloading'
    )
  where current_location.company_id = target_company_id
    and current_location.recorded_at >= current_location_freshness_cutoff
    and (
      exists (
        select 1
        from public.driver_shifts as shift
        where shift.company_id = current_location.company_id
          and shift.driver_id = current_location.driver_id
          and shift.off_duty_at is null
      )
      or exists (
        select 1
        from public.loads as active_load
        where active_load.company_id = current_location.company_id
          and active_load.assigned_driver_id = current_location.driver_id
          and active_load.operational_status in (
            'en_route_to_pickup', 'arrived_pickup', 'loading', 'picked_up',
            'en_route_to_delivery', 'arrived_delivery', 'unloading'
          )
      )
    )
  order by current_location.recorded_at desc, current_location.driver_id
  limit 1;

  return result;
end;
$$;

create or replace function public.run_location_retention(
  target_company_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  detailed_history_days_value integer;
  deleted_current_count integer := 0;
  deleted_history_count integer := 0;
  current_location_freshness_cutoff timestamptz := timezone('utc', now()) - interval '5 minutes';
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

  -- A current-pointer is not retained as a movement-history cache. Clear it
  -- once stale or once its driver is neither on duty nor operating a load.
  delete from public.current_driver_locations as current_location
  where current_location.company_id = target_company_id
    and (
      current_location.recorded_at < current_location_freshness_cutoff
      or (
        not exists (
          select 1
          from public.driver_shifts as shift
          where shift.company_id = current_location.company_id
            and shift.driver_id = current_location.driver_id
            and shift.off_duty_at is null
        )
        and not exists (
          select 1
          from public.loads as active_load
          where active_load.company_id = current_location.company_id
            and active_load.assigned_driver_id = current_location.driver_id
            and active_load.operational_status in (
              'en_route_to_pickup', 'arrived_pickup', 'loading', 'picked_up',
              'en_route_to_delivery', 'arrived_delivery', 'unloading'
            )
        )
      )
    );
  get diagnostics deleted_current_count = row_count;

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
  get diagnostics deleted_history_count = row_count;

  insert into public.audit_events (
    company_id, actor_id, action, before_data, after_data, entity_type, entity_id
  ) values (
    target_company_id,
    (select auth.uid()),
    'location_history.retained',
    '{}'::jsonb,
    jsonb_build_object(
      'detailedHistoryDays', detailed_history_days_value,
      'purgedCurrentLocationCount', deleted_current_count,
      'purgedDetailedSampleCount', deleted_history_count
    ),
    'company_location_retention_policy',
    target_company_id
  );

  return jsonb_build_object(
    'detailedHistoryDays', detailed_history_days_value,
    'purgedCurrentLocationCount', deleted_current_count,
    'purgedDetailedSampleCount', deleted_history_count
  );
end;
$$;

revoke all on function driver_tracking_private.current_own_driver_tracking_scope()
  from public, anon, authenticated;
revoke all on function public.get_authorized_current_driver_location(uuid)
  from public, anon;
revoke all on function public.run_location_retention(uuid)
  from public, anon;
grant execute on function public.get_authorized_current_driver_location(uuid)
  to authenticated;
grant execute on function public.run_location_retention(uuid)
  to authenticated;
