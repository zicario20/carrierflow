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
  'authenticated', 'authenticated', 'tracking-context-driver@carrierflow.test',
  '$2a$10$not-a-real-password-hash-for-local-tests-only', timezone('utc', now()),
  '{}'::jsonb, '{}'::jsonb, timezone('utc', now()), timezone('utc', now())
);
insert into public.company_memberships (id, company_id, user_id, role, status)
values (
  '63636363-6363-6363-6363-636363636363'::uuid,
  '11111111-1111-1111-1111-111111111111'::uuid,
  '97979797-9797-9797-9797-979797979797'::uuid,
  'driver', 'active'
);

select ok(
  to_regprocedure('public.get_own_driver_tracking_context()') is not null,
  'tracking context RPC is zero-scope'
);
select ok(
  to_regprocedure('public.get_own_driver_tracking_context(uuid)') is null,
  'tracking context RPC accepts no company, driver, or load identifier'
);

set local role authenticated;
select set_config('request.jwt.claim.sub', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', true);
select * from public.create_driver(
  '11111111-1111-1111-1111-111111111111'::uuid,
  '63636363-6363-6363-6363-636363636363'::uuid,
  'Tracking Context Driver'
);
select id as driver_id from public.drivers
where membership_id = '63636363-6363-6363-6363-636363636363'::uuid \gset
reset role;

set local role authenticated;
select set_config('request.jwt.claim.sub', '97979797-9797-9797-9797-979797979797', true);
select is(
  public.get_own_driver_tracking_context(),
  '{"isOnDuty": false, "hasActiveLoad": false}'::jsonb,
  'a driver without an open shift or active load fails closed'
);
select * from public.start_driver_shift(:'driver_id'::uuid);
select is(
  public.get_own_driver_tracking_context(),
  '{"isOnDuty": true, "hasActiveLoad": false}'::jsonb,
  'an on-duty driver receives only the boolean foreground eligibility context'
);
select * from public.end_driver_shift(:'driver_id'::uuid);
select is(
  public.get_own_driver_tracking_context(),
  '{"isOnDuty": false, "hasActiveLoad": false}'::jsonb,
  'ending the shift removes foreground-only eligibility'
);
reset role;

set local role authenticated;
select set_config('request.jwt.claim.sub', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', true);
select * from public.create_vehicle(
  '11111111-1111-1111-1111-111111111111'::uuid,
  'TRACK-CONTEXT-UNIT', 'cargo_van', 3500
);
select id as vehicle_id from public.vehicles
where unit_number = 'TRACK-CONTEXT-UNIT' \gset
select public.assign_driver_vehicle(
  '11111111-1111-1111-1111-111111111111'::uuid,
  :'driver_id'::uuid, :'vehicle_id'::uuid
);
select * from public.create_pilot_load(
  '11111111-1111-1111-1111-111111111111'::uuid,
  'TRACKING-CONTEXT-A',
  '{"address":"1 Pickup Way","country":"US","timezone":"America/Chicago"}'::jsonb,
  '{"address":"2 Delivery Lane","country":"US","timezone":"America/Chicago"}'::jsonb
);
select id as load_id from public.loads
where load_number = 'TRACKING-CONTEXT-A' \gset
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
select set_config('request.jwt.claim.sub', '97979797-9797-9797-9797-979797979797', true);
select is(
  public.get_own_driver_tracking_context(),
  '{"isOnDuty": false, "hasActiveLoad": false}'::jsonb,
  'an assigned next load is not an active tracking load'
);
reset role;
set local role authenticated;
select set_config('request.jwt.claim.sub', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', true);
select public.advance_load_state('11111111-1111-1111-1111-111111111111'::uuid, :'load_id'::uuid, 'en_route_to_pickup');
reset role;

set local role authenticated;
select set_config('request.jwt.claim.sub', '97979797-9797-9797-9797-979797979797', true);
select is(
  public.get_own_driver_tracking_context(),
  '{"isOnDuty": false, "hasActiveLoad": true}'::jsonb,
  'an active load enables tracking context without a client-selected load id'
);
reset role;

set local role authenticated;
select set_config('request.jwt.claim.sub', 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', true);
select is(
  public.get_own_driver_tracking_context(),
  '{"isOnDuty": false, "hasActiveLoad": false}'::jsonb,
  'another company cannot select the first driver or its active load context'
);
reset role;

set local role anon;
select throws_ok(
  $$select public.get_own_driver_tracking_context()$$,
  '42501', null,
  'anonymous callers cannot read the authenticated tracking context'
);
reset role;

select ok(
  not has_function_privilege('anon', 'public.get_own_driver_tracking_context()', 'execute'),
  'anonymous callers have no execute privilege on tracking context'
);
select ok(
  has_function_privilege('authenticated', 'public.get_own_driver_tracking_context()', 'execute'),
  'authenticated caller may request only its own tracking context'
);

select * from finish();
rollback;
