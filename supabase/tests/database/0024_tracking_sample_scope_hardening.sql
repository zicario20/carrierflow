begin;

select plan(15);

\set tenant_fixture_setup true
\ir helpers/tenant-fixtures.sql
\unset tenant_fixture_setup
select test_helpers.seed_tenant_fixtures();

insert into auth.users (
  id, instance_id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at
) values (
  '98989898-9898-9898-9898-989898989898'::uuid,
  '00000000-0000-0000-0000-000000000000'::uuid,
  'authenticated', 'authenticated', 'tracking-scope-driver@carrierflow.test',
  '$2a$10$not-a-real-password-hash-for-local-tests-only', timezone('utc', now()),
  '{}'::jsonb, '{}'::jsonb, timezone('utc', now()), timezone('utc', now())
);
insert into public.company_memberships (id, company_id, user_id, role, status)
values (
  '64646464-6464-6464-6464-646464646464'::uuid,
  '11111111-1111-1111-1111-111111111111'::uuid,
  '98989898-9898-9898-9898-989898989898'::uuid,
  'driver', 'active'
);

set local role authenticated;
select set_config('request.jwt.claim.sub', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', true);
select * from public.create_driver(
  '11111111-1111-1111-1111-111111111111'::uuid,
  '64646464-6464-6464-6464-646464646464'::uuid,
  'Tracking Scope Driver'
);
select id as driver_id from public.drivers
where membership_id = '64646464-6464-6464-6464-646464646464'::uuid \gset
select * from public.create_vehicle(
  '11111111-1111-1111-1111-111111111111'::uuid,
  'TRACK-SCOPE-UNIT', 'cargo_van', 3500
);
select id as vehicle_id from public.vehicles
where unit_number = 'TRACK-SCOPE-UNIT' \gset
select public.assign_driver_vehicle(
  '11111111-1111-1111-1111-111111111111'::uuid,
  :'driver_id'::uuid, :'vehicle_id'::uuid
);
select * from public.create_pilot_load(
  '11111111-1111-1111-1111-111111111111'::uuid,
  'TRACKING-SCOPE-A',
  '{"address":"1 Pickup Way","country":"US","timezone":"America/Chicago"}'::jsonb,
  '{"address":"2 Delivery Lane","country":"US","timezone":"America/Chicago"}'::jsonb
);
select id as load_id from public.loads
where load_number = 'TRACKING-SCOPE-A' \gset
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
select set_config('request.jwt.claim.sub', '98989898-9898-9898-9898-989898989898', true);
select throws_ok(
  $$select public.record_own_driver_location_sample(41.8781, -87.6298, 9, 12, 90, timezone('utc', now()))$$,
  '42501', 'an active driver tracking context is required',
  'an assigned off-duty driver cannot submit a direct own-location sample'
);
select * from public.start_driver_shift(:'driver_id'::uuid);
select lives_ok(
  $$select public.record_own_driver_location_sample(41.8781, -87.6298, 9, 12, 90, timezone('utc', now()))$$,
  'an assigned driver with an open shift can submit a foreground location sample'
);
reset role;
select ok(
  (select load_id is null from public.current_driver_locations where driver_id = :'driver_id'::uuid),
  'an assigned foreground shift sample is not linked to an upcoming load'
);

set local role authenticated;
select set_config('request.jwt.claim.sub', '98989898-9898-9898-9898-989898989898', true);
select * from public.end_driver_shift(:'driver_id'::uuid);
reset role;
set local role authenticated;
select set_config('request.jwt.claim.sub', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', true);
select is(
  public.get_authorized_current_driver_location('11111111-1111-1111-1111-111111111111'::uuid),
  null::jsonb,
  'an off-duty driver with no operational active load does not release current coordinates to the manager map'
);
select lives_ok(
  $$select public.run_location_retention('11111111-1111-1111-1111-111111111111'::uuid)$$,
  'retention clears an off-duty current location pointer without deleting private history early'
);
reset role;
select is(
  (select count(*) from public.current_driver_locations where driver_id = :'driver_id'::uuid),
  0::bigint,
  'retention deletes the off-duty current location pointer'
);

set local role authenticated;
select set_config('request.jwt.claim.sub', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', true);
select public.advance_load_state('11111111-1111-1111-1111-111111111111'::uuid, :'load_id'::uuid, 'en_route_to_pickup');
reset role;

set local role authenticated;
select set_config('request.jwt.claim.sub', '98989898-9898-9898-9898-989898989898', true);
select lives_ok(
  $$select public.record_own_driver_location_sample(41.8810, -87.6300, 8, 14, 95, timezone('utc', now()) - interval '6 minutes')$$,
  'an off-duty driver with an operational active load can submit a bounded stale sample'
);
reset role;
set local role authenticated;
select set_config('request.jwt.claim.sub', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', true);
select is(
  public.get_authorized_current_driver_location('11111111-1111-1111-1111-111111111111'::uuid),
  null::jsonb,
  'a stale current location is not released with coordinates to the manager map'
);
select lives_ok(
  $$select public.run_location_retention('11111111-1111-1111-1111-111111111111'::uuid)$$,
  'retention clears a stale current location pointer'
);
reset role;
select is(
  (select count(*) from public.current_driver_locations where driver_id = :'driver_id'::uuid),
  0::bigint,
  'retention deletes the stale current location pointer'
);

set local role authenticated;
select set_config('request.jwt.claim.sub', '98989898-9898-9898-9898-989898989898', true);
select lives_ok(
  $$select public.record_own_driver_location_sample(41.8820, -87.6310, 8, 14, 95, timezone('utc', now()))$$,
  'an off-duty driver with an operational active load can submit a fresh background location sample'
);
reset role;
select is(
  (select load_id from public.current_driver_locations where driver_id = :'driver_id'::uuid),
  :'load_id'::uuid,
  'an operational active sample remains linked to its active load'
);

set local role authenticated;
select set_config('request.jwt.claim.sub', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', true);
select is(
  public.get_authorized_current_driver_location('11111111-1111-1111-1111-111111111111'::uuid) ->> 'loadNumber',
  'TRACKING-SCOPE-A',
  'manager map continues to receive only the current authorized active load context'
);
select lives_ok(
  $$select public.run_location_retention('11111111-1111-1111-1111-111111111111'::uuid)$$,
  'location retention remains available after tracking scope hardening'
);
reset role;
select is(
  (select count(*) from public.driver_location_history where driver_id = :'driver_id'::uuid),
  3::bigint,
  'hardening preserves the three authorized private history samples'
);

select * from finish();
rollback;
