-- A mobile runtime may only learn the booleans needed to decide whether to
-- attempt location collection. Identity, tenant, shift, and load state stay
-- server-derived; this capability deliberately accepts no client scope.

create function public.get_own_driver_tracking_context()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  current_actor_id uuid := (select auth.uid());
  own_driver record;
  is_on_duty boolean := false;
  has_active_load boolean := false;
begin
  if current_actor_id is null then
    return jsonb_build_object('isOnDuty', false, 'hasActiveLoad', false);
  end if;

  select driver.company_id, driver.id
  into own_driver
  from public.drivers as driver
  join public.company_memberships as membership
    on membership.id = driver.membership_id
    and membership.company_id = driver.company_id
  where membership.user_id = current_actor_id
    and membership.role = 'driver'::public.company_role
    and membership.status = 'active'::public.membership_status
    and driver.status = 'active'
  limit 1;

  if not found then
    return jsonb_build_object('isOnDuty', false, 'hasActiveLoad', false);
  end if;

  select exists (
    select 1
    from public.driver_shifts as shift
    where shift.company_id = own_driver.company_id
      and shift.driver_id = own_driver.id
      and shift.off_duty_at is null
  ) into is_on_duty;

  -- `assigned` is an upcoming load. It is intentionally excluded: it cannot
  -- silently enable background collection before operational travel begins.
  select exists (
    select 1
    from public.loads as load
    where load.company_id = own_driver.company_id
      and load.assigned_driver_id = own_driver.id
      and load.operational_status in (
        'en_route_to_pickup', 'arrived_pickup', 'loading', 'picked_up',
        'en_route_to_delivery', 'arrived_delivery', 'unloading'
      )
  ) into has_active_load;

  return jsonb_build_object(
    'isOnDuty', is_on_duty,
    'hasActiveLoad', has_active_load
  );
end;
$$;

revoke all on function public.get_own_driver_tracking_context()
  from public, anon, authenticated;
grant execute on function public.get_own_driver_tracking_context()
  to authenticated;
