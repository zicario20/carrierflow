begin;

select plan(11);

\set tenant_fixture_setup true
\ir helpers/tenant-fixtures.sql
\unset tenant_fixture_setup
select test_helpers.seed_tenant_fixtures();

insert into auth.users (
  id, instance_id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at
) values (
  '97979797-9797-9797-9797-979797979797'::uuid,
  '00000000-0000-0000-0000-000000000000'::uuid,
  'authenticated', 'authenticated', 'tracking-lifecycle-driver@carrierflow.test',
  '$2a$10$not-a-real-password-hash-for-local-tests-only', timezone('utc', now()),
  '{}'::jsonb, '{}'::jsonb, timezone('utc', now()), timezone('utc', now())
);
insert into public.company_memberships (id, company_id, user_id, role, status)
values (
  '62626262-6262-6262-6262-626262626262'::uuid,
  '11111111-1111-1111-1111-111111111111'::uuid,
  '97979797-9797-9797-9797-979797979797'::uuid,
  'driver', 'active'
);

set local role authenticated;
select set_config('request.jwt.claim.sub', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', true);
select * from public.create_driver(
  '11111111-1111-1111-1111-111111111111'::uuid,
  '62626262-6262-6262-6262-626262626262'::uuid,
  'Tracking Lifecycle Driver'
);
select id as driver_id from public.drivers
where membership_id = '62626262-6262-6262-6262-626262626262'::uuid \gset
select * from public.create_vehicle(
  '11111111-1111-1111-1111-111111111111'::uuid,
  'TRACK-LIFECYCLE-UNIT', 'cargo_van', 3500
);
select id as vehicle_id from public.vehicles
where unit_number = 'TRACK-LIFECYCLE-UNIT' \gset
select public.assign_driver_vehicle(
  '11111111-1111-1111-1111-111111111111'::uuid,
  :'driver_id'::uuid, :'vehicle_id'::uuid
);
select * from public.create_pilot_load(
  '11111111-1111-1111-1111-111111111111'::uuid,
  'TRACKING-LIFECYCLE-A',
  '{"address":"1 Pickup Way","country":"US","timezone":"America/Chicago"}'::jsonb,
  '{"address":"2 Delivery Lane","country":"US","timezone":"America/Chicago"}'::jsonb
);
select id as load_id from public.loads
where load_number = 'TRACKING-LIFECYCLE-A' \gset
reset role;
update public.loads
set assigned_driver_id = :'driver_id'::uuid, assigned_vehicle_id = :'vehicle_id'::uuid
where id = :'load_id'::uuid;
set local role authenticated;
select set_config('request.jwt.claim.sub', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', true);
select public.advance_load_state('11111111-1111-1111-1111-111111111111'::uuid, :'load_id'::uuid, 'scheduled');
select public.advance_load_state('11111111-1111-1111-1111-111111111111'::uuid, :'load_id'::uuid, 'assigned');
select public.advance_load_state('11111111-1111-1111-1111-111111111111'::uuid, :'load_id'::uuid, 'en_route_to_pickup');
reset role;

set local role authenticated;
select set_config('request.jwt.claim.sub', '97979797-9797-9797-9797-979797979797', true);
select * from public.start_driver_shift(:'driver_id'::uuid);
select lives_ok(
  $$select public.record_own_driver_location_sample(41.8781, -87.6298, 9, 12, 90, timezone('utc', now()) - interval '8 days')$$,
  'an active driver can record the detailed sample that must purge at seven days'
);
select lives_ok(
  $$select public.record_own_driver_location_sample(41.8810, -87.6300, 8, 14, 95, timezone('utc', now()))$$,
  'an active driver can retain a fresh current location before deactivation'
);
reset role;

set local role authenticated;
select set_config('request.jwt.claim.sub', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', true);
select is(
  public.get_authorized_current_driver_location('11111111-1111-1111-1111-111111111111'::uuid) ->> 'driverLabel',
  'Tracking Lifecycle Driver',
  'the active member is visible through the one-current-location capability before deactivation'
);
reset role;

-- Simulate a legacy/partial deactivation where an operational load and open
-- shift remain. The privacy capability must not rely on those stale records.
update public.drivers set status = 'inactive' where id = :'driver_id'::uuid;
update public.company_memberships set status = 'suspended'
where id = '62626262-6262-6262-6262-626262626262'::uuid;

set local role authenticated;
select set_config('request.jwt.claim.sub', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', true);
select is(
  public.get_authorized_current_driver_location('11111111-1111-1111-1111-111111111111'::uuid),
  null::jsonb,
  'a deactivated or suspended driver with legacy active records releases no map coordinates'
);
select lives_ok(
  $$select public.run_location_retention('11111111-1111-1111-1111-111111111111'::uuid)$$,
  'retention clears a deactivated driver current pointer and applies the fixed seven-day window'
);
reset role;
select is(
  (select count(*) from public.current_driver_locations where driver_id = :'driver_id'::uuid),
  0::bigint,
  'retention deletes the deactivated driver current pointer despite legacy shift/load records'
);
select is(
  (select count(*) from public.driver_location_history
    where driver_id = :'driver_id'::uuid
      and recorded_at < timezone('utc', now()) - interval '7 days'),
  0::bigint,
  'raw coordinates older than seven days are purged'
);
select is(
  (select sample_count::bigint from public.driver_location_daily_rollups
    where driver_id = :'driver_id'::uuid),
  1::bigint,
  'the purged detailed sample remains only as a minimum-data daily aggregate'
);
select ok(
  not (select to_jsonb(rollup) ?| array['latitude', 'longitude', 'heading_degrees', 'speed_meters_per_second']
    from public.driver_location_daily_rollups as rollup
    where rollup.driver_id = :'driver_id'::uuid),
  'the retained daily aggregate contains no coordinates or route telemetry'
);
select ok(
  not (select after_data ?| array['latitude', 'longitude', 'headingDegrees', 'speedMetersPerSecond']
    from public.audit_events
    where action = 'location_history.retained'
      and company_id = '11111111-1111-1111-1111-111111111111'::uuid),
  'the retention audit records only counts and policy, not coordinates'
);
select throws_ok(
  $$insert into public.company_location_retention_policies (company_id, detailed_history_days)
    values ('11111111-1111-1111-1111-111111111111'::uuid, 31)$$,
  '23514', null,
  'a company cannot configure detailed location history beyond the mandatory seven-day policy'
);

select * from finish();
rollback;
