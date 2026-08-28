begin;

-- Upgrade verification path (not a reset-only assertion):
--   corepack pnpm@11.24.0 exec supabase db reset --local --version 0003
--   corepack pnpm@11.24.0 exec supabase migration up --local
--   corepack pnpm@11.24.0 exec supabase test db
-- This test exercises the lifecycle contract after the forward-only 0004
-- migration has been applied to an already-migrated 0003 database.
select plan(45);

\set tenant_fixture_setup true
\ir helpers/tenant-fixtures.sql
\unset tenant_fixture_setup
select test_helpers.seed_tenant_fixtures();

insert into auth.users (
  id, instance_id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at
) values
  ('12121212-1212-1212-1212-121212121212'::uuid, '00000000-0000-0000-0000-000000000000'::uuid, 'authenticated', 'authenticated', 'dispatcher-a@carrierflow.test', '$2a$10$not-a-real-password-hash-for-local-tests-only', timezone('utc', now()), '{}'::jsonb, '{}'::jsonb, timezone('utc', now()), timezone('utc', now())),
  ('99999999-9999-9999-9999-999999999999'::uuid, '00000000-0000-0000-0000-000000000000'::uuid, 'authenticated', 'authenticated', 'driver-a@carrierflow.test', '$2a$10$not-a-real-password-hash-for-local-tests-only', timezone('utc', now()), '{}'::jsonb, '{}'::jsonb, timezone('utc', now()), timezone('utc', now())),
  ('88888888-8888-8888-8888-888888888888'::uuid, '00000000-0000-0000-0000-000000000000'::uuid, 'authenticated', 'authenticated', 'driver-b@carrierflow.test', '$2a$10$not-a-real-password-hash-for-local-tests-only', timezone('utc', now()), '{}'::jsonb, '{}'::jsonb, timezone('utc', now()), timezone('utc', now()));

insert into public.company_memberships (id, company_id, user_id, role, status) values
  ('31313131-3131-3131-3131-313131313131'::uuid, '11111111-1111-1111-1111-111111111111'::uuid, '12121212-1212-1212-1212-121212121212'::uuid, 'dispatcher', 'active'),
  ('41414141-4141-4141-4141-414141414141'::uuid, '11111111-1111-1111-1111-111111111111'::uuid, '99999999-9999-9999-9999-999999999999'::uuid, 'driver', 'active'),
  ('51515151-5151-5151-5151-515151515151'::uuid, '22222222-2222-2222-2222-222222222222'::uuid, '88888888-8888-8888-8888-888888888888'::uuid, 'driver', 'active');

select ok(
  (select prosecdef from pg_proc where oid = 'public.update_driver(uuid,uuid,text,text)'::regprocedure),
  'driver lifecycle remains behind a security definer boundary'
);
select ok(
  (select prosecdef from pg_proc where oid = 'public.update_vehicle(uuid,uuid,text,text,numeric,text)'::regprocedure),
  'vehicle lifecycle remains behind a security definer boundary'
);

set local role authenticated;
select set_config('request.jwt.claim.sub', '12121212-1212-1212-1212-121212121212', true);
select lives_ok(
  $$select * from public.create_driver('11111111-1111-1111-1111-111111111111'::uuid, '41414141-4141-4141-4141-414141414141'::uuid, 'Driver A')$$,
  'dispatcher creates the driver used by the access lifecycle'
);
select lives_ok(
  $$select * from public.create_vehicle('11111111-1111-1111-1111-111111111111'::uuid, 'A-404', 'cargo_van', 3500)$$,
  'dispatcher creates the vehicle used by the access lifecycle'
);
select id as driver_a_id from public.drivers where membership_id = '41414141-4141-4141-4141-414141414141'::uuid \gset
select id as vehicle_a_id from public.vehicles where unit_number = 'A-404' \gset
select lives_ok(
  format('select * from public.assign_driver_vehicle(%L::uuid, %L::uuid, %L::uuid)', '11111111-1111-1111-1111-111111111111', :'driver_a_id', :'vehicle_a_id'),
  'dispatcher assigns the active driver and vehicle'
);

reset role;
set local role authenticated;
select set_config('request.jwt.claim.sub', '99999999-9999-9999-9999-999999999999', true);
select results_eq(
  'select unit_number from public.vehicles order by unit_number',
  array['A-404'::text],
  'an active assigned driver can view their active vehicle'
);
select lives_ok(
  format('select * from public.start_driver_shift(%L::uuid)', :'driver_a_id'),
  'an active driver can start a shift before deactivation'
);

reset role;
set local role authenticated;
select set_config('request.jwt.claim.sub', '12121212-1212-1212-1212-121212121212', true);
select lives_ok(
  format('select * from public.update_driver(%L::uuid, %L::uuid, %L, %L)', '11111111-1111-1111-1111-111111111111', :'driver_a_id', 'Driver A', 'inactive'),
  'driver deactivation is a transactional access revocation'
);

reset role;
select is(
  (select status::text from public.company_memberships where id = '41414141-4141-4141-4141-414141414141'::uuid),
  'suspended',
  'driver deactivation suspends the linked membership'
);
select is(
  (select count(*) from public.driver_vehicle_assignments where driver_id = :'driver_a_id'::uuid and unassigned_at is null),
  0::bigint,
  'driver deactivation closes every open assignment'
);
select is(
  (select count(*) from public.driver_shifts where driver_id = :'driver_a_id'::uuid and off_duty_at is null),
  0::bigint,
  'driver deactivation closes every open shift'
);
select ok(
  exists (select 1 from public.audit_events where action = 'membership.suspended' and entity_id = '41414141-4141-4141-4141-414141414141'::uuid),
  'driver deactivation audits membership suspension'
);
select ok(
  exists (select 1 from public.audit_events where action = 'driver_vehicle.unassigned' and after_data ->> 'reason' = 'driver_deactivated'),
  'driver deactivation audits assignment closure'
);
select ok(
  exists (select 1 from public.audit_events where action = 'driver_shift.ended_by_deactivation' and after_data ->> 'reason' = 'driver_deactivated'),
  'driver deactivation audits shift closure'
);

set local role authenticated;
select set_config('request.jwt.claim.sub', '99999999-9999-9999-9999-999999999999', true);
select results_eq('select id from public.drivers', array[]::uuid[], 'a deactivated driver cannot read their profile');
select results_eq('select id from public.vehicles', array[]::uuid[], 'a deactivated driver cannot read a formerly assigned vehicle');
select results_eq('select id from public.driver_shifts', array[]::uuid[], 'a deactivated driver cannot read their shifts');
select throws_ok(
  format('select * from public.start_driver_shift(%L::uuid)', :'driver_a_id'),
  '42501', 'a driver may only manage their own shift',
  'a deactivated driver cannot start a shift'
);
select throws_ok(
  format('select * from public.end_driver_shift(%L::uuid)', :'driver_a_id'),
  '42501', 'a driver may only manage their own shift',
  'a deactivated driver cannot end a shift'
);

reset role;
set local role authenticated;
select set_config('request.jwt.claim.sub', '12121212-1212-1212-1212-121212121212', true);
select results_eq('select id from public.drivers', array[:'driver_a_id'::uuid], 'a dispatcher retains access to deactivated driver history');
select results_eq('select id from public.vehicles', array[:'vehicle_a_id'::uuid], 'a dispatcher retains access to vehicle history');

reset role;
set local role authenticated;
select set_config('request.jwt.claim.sub', '88888888-8888-8888-8888-888888888888', true);
select results_eq('select id from public.drivers', array[]::uuid[], 'another tenant cannot read deactivated driver history');
select results_eq('select id from public.vehicles', array[]::uuid[], 'another tenant cannot read vehicle history');

reset role;
set local role authenticated;
select set_config('request.jwt.claim.sub', '12121212-1212-1212-1212-121212121212', true);
select lives_ok(
  format('select * from public.update_driver(%L::uuid, %L::uuid, %L, %L)', '11111111-1111-1111-1111-111111111111', :'driver_a_id', 'Driver A', 'active'),
  'dispatcher reactivates the suspended driver access unit'
);

reset role;
select is(
  (select status::text from public.company_memberships where id = '41414141-4141-4141-4141-414141414141'::uuid),
  'active',
  'driver reactivation restores the exact linked membership'
);
select ok(
  exists (select 1 from public.audit_events where action = 'membership.reactivated' and entity_id = '41414141-4141-4141-4141-414141414141'::uuid),
  'driver reactivation audits membership restoration'
);
set local role authenticated;
select set_config('request.jwt.claim.sub', '99999999-9999-9999-9999-999999999999', true);
select results_eq('select id from public.drivers', array[:'driver_a_id'::uuid], 'a reactivated driver can read their profile');
select lives_ok(format('select * from public.start_driver_shift(%L::uuid)', :'driver_a_id'), 'a reactivated driver can start a shift');
select lives_ok(format('select * from public.end_driver_shift(%L::uuid)', :'driver_a_id'), 'a reactivated driver can end their shift');

reset role;
update public.company_memberships set status = 'suspended'::public.membership_status where id = '41414141-4141-4141-4141-414141414141'::uuid;
set local role authenticated;
select set_config('request.jwt.claim.sub', '12121212-1212-1212-1212-121212121212', true);
select throws_ok(
  format('select * from public.assign_driver_vehicle(%L::uuid, %L::uuid, %L::uuid)', '11111111-1111-1111-1111-111111111111', :'driver_a_id', :'vehicle_a_id'),
  '22023', 'an active driver membership is required to receive a vehicle assignment',
  'a suspended membership blocks assignment even if the profile is active'
);
reset role;
select is(
  (select count(*) from public.driver_vehicle_assignments where driver_id = :'driver_a_id'::uuid and unassigned_at is null),
  0::bigint,
  'suspended membership denial leaves no active assignment'
);
select is(
  (select count(*) from public.audit_events where action = 'driver_vehicle.assigned'),
  1::bigint,
  'suspended membership denial leaves no assignment audit event'
);
update public.company_memberships set status = 'active'::public.membership_status where id = '41414141-4141-4141-4141-414141414141'::uuid;

set local role authenticated;
select set_config('request.jwt.claim.sub', '12121212-1212-1212-1212-121212121212', true);
select lives_ok(
  format('select * from public.assign_driver_vehicle(%L::uuid, %L::uuid, %L::uuid)', '11111111-1111-1111-1111-111111111111', :'driver_a_id', :'vehicle_a_id'),
  'dispatcher assigns the reactivated driver to the active vehicle'
);
reset role;
set local role authenticated;
select set_config('request.jwt.claim.sub', '99999999-9999-9999-9999-999999999999', true);
select results_eq('select id from public.vehicles', array[:'vehicle_a_id'::uuid], 'driver can view the reassigned active vehicle');

reset role;
set local role authenticated;
select set_config('request.jwt.claim.sub', '12121212-1212-1212-1212-121212121212', true);
select lives_ok(
  format('select * from public.update_vehicle(%L::uuid, %L::uuid, %L, %L, 3500, %L)', '11111111-1111-1111-1111-111111111111', :'vehicle_a_id', 'A-404', 'cargo_van', 'inactive'),
  'vehicle deactivation closes current access atomically'
);

reset role;
select is(
  (select count(*) from public.driver_vehicle_assignments where vehicle_id = :'vehicle_a_id'::uuid and unassigned_at is null),
  0::bigint,
  'vehicle deactivation closes each open vehicle assignment'
);
select ok(
  exists (select 1 from public.audit_events where action = 'driver_vehicle.unassigned' and after_data ->> 'reason' = 'vehicle_deactivated'),
  'vehicle deactivation audits each assignment closure'
);
select ok(
  exists (select 1 from public.audit_events where action = 'vehicle.deactivated' and entity_id = :'vehicle_a_id'::uuid),
  'vehicle deactivation audits the vehicle lifecycle change'
);

set local role authenticated;
select set_config('request.jwt.claim.sub', '99999999-9999-9999-9999-999999999999', true);
select results_eq('select id from public.vehicles', array[]::uuid[], 'driver loses vehicle access immediately after vehicle deactivation');

reset role;
set local role authenticated;
select set_config('request.jwt.claim.sub', '12121212-1212-1212-1212-121212121212', true);
select results_eq('select id from public.vehicles', array[:'vehicle_a_id'::uuid], 'dispatcher can inspect inactive vehicle history');
select throws_ok(
  format('select * from public.assign_driver_vehicle(%L::uuid, %L::uuid, %L::uuid)', '11111111-1111-1111-1111-111111111111', :'driver_a_id', :'vehicle_a_id'),
  '22023', 'vehicle must be active to receive a driver assignment',
  'an inactive vehicle cannot receive a new assignment'
);
select is(
  (select count(*) from public.audit_events where action = 'driver_vehicle.assigned'),
  2::bigint,
  'inactive vehicle denial leaves no additional assignment audit event'
);
select lives_ok(
  format('select * from public.update_vehicle(%L::uuid, %L::uuid, %L, %L, 3500, %L)', '11111111-1111-1111-1111-111111111111', :'vehicle_a_id', 'A-404', 'cargo_van', 'active'),
  'dispatcher can reactivate the vehicle without restoring old assignments'
);

reset role;
select is(
  (select count(*) from public.driver_vehicle_assignments where vehicle_id = :'vehicle_a_id'::uuid and unassigned_at is null),
  0::bigint,
  'vehicle reactivation does not silently reinstate a prior assignment'
);
set local role authenticated;
select set_config('request.jwt.claim.sub', '99999999-9999-9999-9999-999999999999', true);
select results_eq('select id from public.vehicles', array[]::uuid[], 'vehicle reactivation does not restore driver access without a new assignment');

select * from finish();
rollback;
