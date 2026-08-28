begin;

select plan(48);

\set tenant_fixture_setup true
\ir helpers/tenant-fixtures.sql
\unset tenant_fixture_setup
select test_helpers.seed_tenant_fixtures();

insert into auth.users (
  id,
  instance_id,
  aud,
  role,
  email,
  encrypted_password,
  email_confirmed_at,
  raw_app_meta_data,
  raw_user_meta_data,
  created_at,
  updated_at
) values
  (
    '12121212-1212-1212-1212-121212121212'::uuid,
    '00000000-0000-0000-0000-000000000000'::uuid,
    'authenticated',
    'authenticated',
    'dispatcher-a@carrierflow.test',
    '$2a$10$not-a-real-password-hash-for-local-tests-only',
    timezone('utc', now()),
    '{}'::jsonb,
    '{}'::jsonb,
    timezone('utc', now()),
    timezone('utc', now())
  ),
  (
    '99999999-9999-9999-9999-999999999999'::uuid,
    '00000000-0000-0000-0000-000000000000'::uuid,
    'authenticated',
    'authenticated',
    'driver-a@carrierflow.test',
    '$2a$10$not-a-real-password-hash-for-local-tests-only',
    timezone('utc', now()),
    '{}'::jsonb,
    '{}'::jsonb,
    timezone('utc', now()),
    timezone('utc', now())
  ),
  (
    '88888888-8888-8888-8888-888888888888'::uuid,
    '00000000-0000-0000-0000-000000000000'::uuid,
    'authenticated',
    'authenticated',
    'driver-b@carrierflow.test',
    '$2a$10$not-a-real-password-hash-for-local-tests-only',
    timezone('utc', now()),
    '{}'::jsonb,
    '{}'::jsonb,
    timezone('utc', now()),
    timezone('utc', now())
  );

insert into public.company_memberships (id, company_id, user_id, role, status) values
  (
    '31313131-3131-3131-3131-313131313131'::uuid,
    '11111111-1111-1111-1111-111111111111'::uuid,
    '12121212-1212-1212-1212-121212121212'::uuid,
    'dispatcher',
    'active'
  ),
  (
    '41414141-4141-4141-4141-414141414141'::uuid,
    '11111111-1111-1111-1111-111111111111'::uuid,
    '99999999-9999-9999-9999-999999999999'::uuid,
    'driver',
    'active'
  ),
  (
    '51515151-5151-5151-5151-515151515151'::uuid,
    '22222222-2222-2222-2222-222222222222'::uuid,
    '88888888-8888-8888-8888-888888888888'::uuid,
    'driver',
    'active'
  );

select has_table('public', 'drivers', 'creates tenant-scoped driver profiles');
select has_table('public', 'vehicles', 'creates tenant-scoped vehicles');
select has_table('public', 'driver_vehicle_assignments', 'records driver vehicle assignments');
select has_table('public', 'driver_shifts', 'records driver shifts');

select ok((select relrowsecurity from pg_class where oid = 'public.drivers'::regclass), 'enables RLS on drivers');
select ok((select relrowsecurity from pg_class where oid = 'public.vehicles'::regclass), 'enables RLS on vehicles');
select ok((select relrowsecurity from pg_class where oid = 'public.driver_vehicle_assignments'::regclass), 'enables RLS on driver vehicle assignments');
select ok((select relrowsecurity from pg_class where oid = 'public.driver_shifts'::regclass), 'enables RLS on driver shifts');

select ok(
  not has_table_privilege('authenticated', 'public.drivers', 'insert,update,delete'),
  'authenticated clients have no direct driver mutations'
);
select ok(
  not has_table_privilege('authenticated', 'public.vehicles', 'insert,update,delete'),
  'authenticated clients have no direct vehicle mutations'
);
select ok(
  not has_table_privilege('authenticated', 'public.driver_shifts', 'insert,update,delete'),
  'authenticated clients have no direct shift mutations'
);

set local role authenticated;
select set_config('request.jwt.claim.sub', '12121212-1212-1212-1212-121212121212', true);

select lives_ok(
  $$select * from public.create_driver(
    '11111111-1111-1111-1111-111111111111'::uuid,
    '41414141-4141-4141-4141-414141414141'::uuid,
    'Driver A'
  )$$,
  'an active dispatcher creates a driver only in their company'
);
select is(
  (select company_id from public.drivers where membership_id = '41414141-4141-4141-4141-414141414141'::uuid),
  '11111111-1111-1111-1111-111111111111'::uuid,
  'the driver profile is persisted in dispatcher A company'
);
select is(
  (select action from public.audit_events where action = 'driver.created' order by occurred_at desc limit 1),
  'driver.created',
  'driver creation writes an audit event'
);

select lives_ok(
  $$select * from public.create_vehicle(
    '11111111-1111-1111-1111-111111111111'::uuid,
    'A-101',
    'cargo_van',
    3500
  )$$,
  'an active dispatcher creates a vehicle only in their company'
);
select is(
  (select company_id from public.vehicles where unit_number = 'A-101'),
  '11111111-1111-1111-1111-111111111111'::uuid,
  'the vehicle is persisted in dispatcher A company'
);
select is(
  (select action from public.audit_events where action = 'vehicle.created' order by occurred_at desc limit 1),
  'vehicle.created',
  'vehicle creation writes an audit event'
);
select lives_ok(
  $$select * from public.assign_driver_vehicle(
    '11111111-1111-1111-1111-111111111111'::uuid,
    (select id from public.drivers where membership_id = '41414141-4141-4141-4141-414141414141'::uuid),
    (select id from public.vehicles where unit_number = 'A-101')
  )$$,
  'an active dispatcher can assign an active tenant driver and vehicle'
);
select is(
  (select count(*) from public.driver_vehicle_assignments where unassigned_at is null),
  1::bigint,
  'the active assignment is persisted in the dispatchers company'
);
select is(
  (select count(*) from public.audit_events where action = 'driver_vehicle.assigned'),
  1::bigint,
  'an authorized assignment writes an audit event'
);

select throws_ok(
  $$select * from public.create_vehicle(
    '22222222-2222-2222-2222-222222222222'::uuid,
    'B-UNAUTHORIZED',
    'box_truck',
    null
  )$$,
  '42501',
  'only active owners, admins, or dispatchers may manage fleet resources',
  'a dispatcher cannot create a vehicle for another company'
);
select is(
  (select count(*) from public.vehicles where unit_number = 'B-UNAUTHORIZED'),
  0::bigint,
  'a cross-company rejection does not create a vehicle'
);
select is(
  (select count(*) from public.audit_events where after_data ->> 'unitNumber' = 'B-UNAUTHORIZED'),
  0::bigint,
  'a cross-company rejection does not audit a vehicle mutation'
);

reset role;
set local role authenticated;
select set_config('request.jwt.claim.sub', '99999999-9999-9999-9999-999999999999', true);
select throws_ok(
  $$select * from public.create_vehicle(
    '11111111-1111-1111-1111-111111111111'::uuid,
    'A-UNAUTHORIZED',
    'cargo_van',
    null
  )$$,
  '42501',
  'only active owners, admins, or dispatchers may manage fleet resources',
  'a driver cannot create a vehicle'
);
select is(
  (select count(*) from public.vehicles where unit_number = 'A-UNAUTHORIZED'),
  0::bigint,
  'a denied driver mutation does not create a vehicle'
);

select lives_ok(
  $$select * from public.start_driver_shift(
    (select id from public.drivers where membership_id = '41414141-4141-4141-4141-414141414141'::uuid)
  )$$,
  'a driver can start their own shift'
);
select ok(
  (select on_duty_at is not null and off_duty_at is null from public.driver_shifts order by on_duty_at desc limit 1),
  'starting a shift records an open on-duty shift'
);
select results_eq(
  'select company_id from public.drivers order by company_id',
  array['11111111-1111-1111-1111-111111111111'::uuid],
  'a driver sees only their own profile'
);
select results_eq(
  'select unit_number from public.vehicles order by unit_number',
  array['A-101'::text],
  'a driver sees only their currently assigned vehicle'
);

reset role;
select is(
  (select action from public.audit_events where action = 'driver_shift.started' order by occurred_at desc limit 1),
  'driver_shift.started',
  'starting a shift writes an audit event'
);
set local role authenticated;
select set_config('request.jwt.claim.sub', '88888888-8888-8888-8888-888888888888', true);
select throws_ok(
  $$select * from public.end_driver_shift(
    (select id from public.drivers where membership_id = '41414141-4141-4141-4141-414141414141'::uuid)
  )$$,
  '42501',
  'a driver may only manage their own shift',
  'another tenant driver cannot end driver A shift'
);
select is(
  (select count(*) from public.audit_events where action = 'driver_shift.ended'),
  0::bigint,
  'an unauthorized shift end does not write audit history'
);

reset role;
set local role authenticated;
select set_config('request.jwt.claim.sub', '99999999-9999-9999-9999-999999999999', true);
select lives_ok(
  $$select * from public.end_driver_shift(
    (select id from public.drivers where membership_id = '41414141-4141-4141-4141-414141414141'::uuid)
  )$$,
  'a driver can end their own open shift'
);
select ok(
  (select off_duty_at is not null from public.driver_shifts order by on_duty_at desc limit 1),
  'ending a shift records off-duty time'
);
reset role;
select is(
  (select action from public.audit_events where action = 'driver_shift.ended' order by occurred_at desc limit 1),
  'driver_shift.ended',
  'ending a shift writes an audit event'
);

set local role authenticated;
select set_config('request.jwt.claim.sub', '12121212-1212-1212-1212-121212121212', true);
select lives_ok(
  $$select * from public.update_driver(
    '11111111-1111-1111-1111-111111111111'::uuid,
    (select id from public.drivers where membership_id = '41414141-4141-4141-4141-414141414141'::uuid),
    'Driver A',
    'inactive'
  )$$,
  'a dispatcher can mark their driver inactive'
);
select throws_ok(
  $$select * from public.assign_driver_vehicle(
    '11111111-1111-1111-1111-111111111111'::uuid,
    (select id from public.drivers where membership_id = '41414141-4141-4141-4141-414141414141'::uuid),
    (select id from public.vehicles where unit_number = 'A-101')
  )$$,
  '22023',
  'driver must be active to receive a vehicle assignment',
  'an inactive driver cannot receive an assignment'
);
select is(
  (select count(*) from public.driver_vehicle_assignments),
  1::bigint,
  'inactive driver denial leaves no additional assignment'
);
select is(
  (select count(*) from public.audit_events where action = 'driver_vehicle.assigned'),
  1::bigint,
  'inactive driver denial leaves no additional assignment audit event'
);

select lives_ok(
  $$select * from public.update_driver(
    '11111111-1111-1111-1111-111111111111'::uuid,
    (select id from public.drivers where membership_id = '41414141-4141-4141-4141-414141414141'::uuid),
    'Driver A',
    'active'
  )$$,
  'a dispatcher can reactivate their driver'
);
select lives_ok(
  $$select * from public.update_vehicle(
    '11111111-1111-1111-1111-111111111111'::uuid,
    (select id from public.vehicles where unit_number = 'A-101'),
    'A-101',
    'cargo_van',
    3500,
    'inactive'
  )$$,
  'a dispatcher can mark their vehicle inactive'
);
select throws_ok(
  $$select * from public.assign_driver_vehicle(
    '11111111-1111-1111-1111-111111111111'::uuid,
    (select id from public.drivers where membership_id = '41414141-4141-4141-4141-414141414141'::uuid),
    (select id from public.vehicles where unit_number = 'A-101')
  )$$,
  '22023',
  'vehicle must be active to receive a driver assignment',
  'an inactive vehicle cannot receive an assignment'
);
select is(
  (select count(*) from public.driver_vehicle_assignments),
  1::bigint,
  'inactive vehicle denial leaves no additional assignment'
);
select is(
  (select count(*) from public.audit_events where action = 'driver_vehicle.assigned'),
  1::bigint,
  'inactive vehicle denial leaves no additional assignment audit event'
);

reset role;
select ok(
  (select prosecdef from pg_proc where oid = 'public.assign_driver_vehicle(uuid,uuid,uuid)'::regprocedure),
  'assignment uses a controlled security definer boundary'
);
select ok(
  (select array_to_string(proconfig, ',') like 'search_path=%' from pg_proc where oid = 'public.assign_driver_vehicle(uuid,uuid,uuid)'::regprocedure),
  'assignment locks its search path'
);
select ok(
  not has_function_privilege('anon', 'public.assign_driver_vehicle(uuid,uuid,uuid)', 'execute'),
  'anonymous callers cannot execute fleet mutations'
);
select ok(
  has_function_privilege('authenticated', 'public.assign_driver_vehicle(uuid,uuid,uuid)', 'execute'),
  'authenticated callers may execute database-authorized fleet mutations'
);

select * from finish();
rollback;
