-- E3-T3 forward-only remediation for active device rows that existed before
-- 0029 introduced the per-driver capacity writer. Existing rows could still
-- fan out an event to more than three destinations, so trim them immediately
-- and retain a server-only idempotent maintenance boundary for recovery.

create schema if not exists push_delivery_private;
revoke all on schema push_delivery_private from public, anon, authenticated;

create or replace function push_delivery_private.harden_legacy_driver_push_device_capacity()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  deactivated_device_count integer := 0;
begin
  -- 0029 serializes future registrations by driver. This bounded, repeatable
  -- maintenance pass handles only historical excess rows and ranks ties by id
  -- so every company/driver group retains the exact newest three devices.
  with ranked_devices as (
    select
      device.id,
      device.company_id,
      device.driver_id,
      row_number() over (
        partition by device.company_id, device.driver_id
        order by device.last_seen_at desc, device.registered_at desc, device.id desc
      ) as active_rank
    from public.driver_push_devices as device
    where device.status = 'active'
  ),
  deactivated_devices as (
    update public.driver_push_devices as device
    set status = 'deactivated',
        deactivated_at = timezone('utc', now())
    from ranked_devices as ranked
    where device.id = ranked.id
      and device.company_id = ranked.company_id
      and device.status = 'active'
      and ranked.active_rank > 3
    returning device.id, device.company_id, device.driver_id
  ),
  suppressed_deliveries as (
    update public.driver_push_deliveries as delivery
    set status = 'suppressed',
        suppressed_at = coalesce(delivery.suppressed_at, timezone('utc', now())),
        updated_at = timezone('utc', now())
    from deactivated_devices as device
    where delivery.company_id = device.company_id
      and delivery.device_id = device.id
      and delivery.status in ('pending', 'claimed')
    returning delivery.id
  ),
  audit_rows as (
    insert into public.audit_events (
      company_id, actor_id, action, before_data, after_data, entity_type, entity_id
    )
    select
      device.company_id,
      null,
      'push_device.deactivated_for_legacy_capacity',
      jsonb_build_object('status', 'active'),
      jsonb_build_object(
        'status', 'deactivated',
        'reason', 'legacy_active_device_cap_backfill',
        'maxActiveDevices', 3
      ),
      'driver_push_device',
      device.id
    from deactivated_devices as device
    returning id
  )
  select count(*) into deactivated_device_count
  from audit_rows;

  return jsonb_build_object(
    'deactivatedDeviceCount', deactivated_device_count
  );
end;
$$;

revoke all on function push_delivery_private.harden_legacy_driver_push_device_capacity()
  from public, anon, authenticated;
grant usage on schema push_delivery_private to service_role;
grant execute on function push_delivery_private.harden_legacy_driver_push_device_capacity()
  to service_role;

-- Apply once at upgrade time. The retained service-role function is safe to
-- rerun during a repair: it touches only historical excess active rows and
-- suppresses their undelivered work without ever handling provider tokens.
select push_delivery_private.harden_legacy_driver_push_device_capacity();
