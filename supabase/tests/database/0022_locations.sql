begin;

select plan(21);

\set tenant_fixture_setup true
\ir helpers/tenant-fixtures.sql
\unset tenant_fixture_setup
select test_helpers.seed_tenant_fixtures();

insert into auth.users (
  id, instance_id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at
) values (
  '96969696-9696-9696-9696-969696969696'::uuid,
  '00000000-0000-0000-0000-000000000000'::uuid,
  'authenticated', 'authenticated', 'location-driver@carrierflow.test',
  '$2a$10$not-a-real-password-hash-for-local-tests-only', timezone('utc', now()),
  '{}'::jsonb, '{}'::jsonb, timezone('utc', now()), timezone('utc', now())
);
insert into public.company_memberships (id, company_id, user_id, role, status)
values (
  '62626262-6262-6262-6262-626262626262'::uuid,
  '11111111-1111-1111-1111-111111111111'::uuid,
  '96969696-9696-9696-9696-969696969696'::uuid,
  'driver', 'active'
);

select has_table('public', 'current_driver_locations', 'current location is stored separately');
select has_table('public', 'driver_location_history', 'location history is retained separately');
select ok((select relrowsecurity from pg_class where oid = 'public.current_driver_locations'::regclass), 'current locations enable RLS');
select ok((select relforcerowsecurity from pg_class where oid = 'public.driver_location_history'::regclass), 'location history forces RLS');
select ok(not has_table_privilege('authenticated', 'public.driver_location_history', 'insert,update,delete'), 'drivers cannot write history directly');
select ok(to_regprocedure('public.record_own_driver_location_sample(double precision,double precision,double precision,double precision,double precision,timestamptz)') is not null, 'location RPC has no tenant, driver, or load parameter');
select ok(to_regprocedure('public.get_authorized_current_driver_location(uuid)') is not null, 'manager map RPC checks an explicit company context');
select ok(to_regprocedure('public.run_location_retention(uuid)') is not null, 'retention runs within an authenticated company boundary');

set local role authenticated;
select set_config('request.jwt.claim.sub', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', true);
select * from public.create_driver(
  '11111111-1111-1111-1111-111111111111'::uuid,
  '62626262-6262-6262-6262-626262626262'::uuid,
  'Location Driver'
);
select id as driver_id from public.drivers
where membership_id = '62626262-6262-6262-6262-626262626262'::uuid \gset
select * from public.create_vehicle(
  '11111111-1111-1111-1111-111111111111'::uuid,
  'LOCATION-UNIT', 'cargo_van', 3500
);
select id as vehicle_id from public.vehicles where unit_number = 'LOCATION-UNIT' \gset
select public.assign_driver_vehicle(
  '11111111-1111-1111-1111-111111111111'::uuid,
  :'driver_id'::uuid, :'vehicle_id'::uuid
);
select * from public.create_pilot_load(
  '11111111-1111-1111-1111-111111111111'::uuid,
  'LOCATION-A',
  '{"address":"1 Pickup Way","country":"US","timezone":"America/Chicago"}'::jsonb,
  '{"address":"2 Delivery Lane","country":"US","timezone":"America/Chicago"}'::jsonb
);
select id as load_id from public.loads where load_number = 'LOCATION-A' \gset
reset role;
update public.loads
set assigned_driver_id = :'driver_id'::uuid, assigned_vehicle_id = :'vehicle_id'::uuid
where id = :'load_id'::uuid;
set local role authenticated;
select set_config('request.jwt.claim.sub', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', true);
select public.advance_load_state('11111111-1111-1111-1111-111111111111'::uuid, :'load_id'::uuid, 'scheduled');
select public.advance_load_state('11111111-1111-1111-1111-111111111111'::uuid, :'load_id'::uuid, 'assigned');
reset role;

set local role authenticated;
select set_config('request.jwt.claim.sub', '96969696-9696-9696-9696-969696969696', true);
select throws_ok(
  format($sql$insert into public.driver_location_history (
    company_id, driver_id, latitude, longitude, accuracy_meters, recorded_at
  ) values (
    '11111111-1111-1111-1111-111111111111'::uuid,
    %L::uuid, 41.8781, -87.6298, 9, timezone('utc', now())
  )$sql$, :'driver_id'),
  '42501', null,
  'a driver cannot bypass the own-location RPC with direct history DML'
);
select throws_ok(
  $$select public.record_own_driver_location_sample(41.8781, -87.6298, 9, 12, 90, timezone('utc', now()) - interval '8 days')$$,
  '42501', 'an active driver tracking context is required',
  'an assigned off-duty driver cannot submit a location sample through the own RPC'
);
reset role;
set local role authenticated;
select set_config('request.jwt.claim.sub', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', true);
select public.advance_load_state('11111111-1111-1111-1111-111111111111'::uuid, :'load_id'::uuid, 'en_route_to_pickup');
reset role;
set local role authenticated;
select set_config('request.jwt.claim.sub', '96969696-9696-9696-9696-969696969696', true);
select lives_ok(
  $$select public.record_own_driver_location_sample(41.8781, -87.6298, 9, 12, 90, timezone('utc', now()) - interval '8 days')$$,
  'an off-duty driver with an operational active load can submit a bounded old sample through the own RPC'
);
select lives_ok(
  $$select public.record_own_driver_location_sample(41.8810, -87.6300, 8, 14, 95, timezone('utc', now()))$$,
  'an off-duty driver with an operational active load can submit the latest bounded sample through the own RPC'
);
reset role;
select is((select count(*) from public.driver_location_history where driver_id = :'driver_id'::uuid), 2::bigint, 'history retains two private samples');
select is((select latitude from public.current_driver_locations where driver_id = :'driver_id'::uuid), 41.8810::double precision, 'current location holds only the latest sample');
set local role authenticated;
select set_config('request.jwt.claim.sub', '96969696-9696-9696-9696-969696969696', true);
select throws_ok(
  $$select public.record_own_driver_location_sample(91, -87.6298, 9, null, null, timezone('utc', now()))$$,
  '22023', 'a valid location sample is required',
  'out-of-range coordinates are rejected at the server boundary'
);

reset role;
set local role authenticated;
select set_config('request.jwt.claim.sub', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', true);
select is(
  public.get_authorized_current_driver_location('11111111-1111-1111-1111-111111111111'::uuid) ->> 'loadNumber',
  'LOCATION-A',
  'the manager map capability returns current location with its active load context'
);
select lives_ok(
  $$select public.run_location_retention('11111111-1111-1111-1111-111111111111'::uuid)$$,
  'an owner can roll up policy-eligible location history without a client tenant parameter'
);
reset role;
select is((select count(*) from public.driver_location_history where driver_id = :'driver_id'::uuid), 1::bigint, 'retention purges only the detailed sample beyond policy');
select is((select sample_count::bigint from public.driver_location_daily_rollups where driver_id = :'driver_id'::uuid), 1::bigint, 'retention keeps a minimum-data daily rollup');
select ok(exists(select 1 from public.audit_events where action = 'location_history.retained'), 'retention writes an auditable minimum-data action');

set local role authenticated;
select set_config('request.jwt.claim.sub', 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', true);
select throws_ok(
  $$select public.get_authorized_current_driver_location('11111111-1111-1111-1111-111111111111'::uuid)$$,
  '42501', 'an authorized operations context is required',
  'another company cannot obtain Carrier A current location through the manager map RPC'
);

select * from finish();
rollback;
