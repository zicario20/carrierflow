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
  '99999999-9999-9999-9999-999999999999'::uuid,
  '00000000-0000-0000-0000-000000000000'::uuid,
  'authenticated', 'authenticated', 'hardening-driver@carrierflow.test',
  '$2a$10$not-a-real-password-hash-for-local-tests-only', timezone('utc', now()),
  '{}'::jsonb, '{}'::jsonb, timezone('utc', now()), timezone('utc', now())
);
insert into public.company_memberships (id, company_id, user_id, role, status)
values (
  '41414141-4141-4141-4141-414141414141'::uuid,
  '11111111-1111-1111-1111-111111111111'::uuid,
  '99999999-9999-9999-9999-999999999999'::uuid,
  'driver', 'active'
);

set local role authenticated;
select set_config('request.jwt.claim.sub', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', true);
select * from public.create_driver(
  '11111111-1111-1111-1111-111111111111'::uuid,
  '41414141-4141-4141-4141-414141414141'::uuid,
  'Hardening Driver'
);
select id as driver_id from public.drivers
where membership_id = '41414141-4141-4141-4141-414141414141'::uuid \gset
select * from public.create_vehicle(
  '11111111-1111-1111-1111-111111111111'::uuid,
  'HARDEN-UNIT', 'cargo_van', 3500
);
select id as vehicle_id from public.vehicles where unit_number = 'HARDEN-UNIT' \gset
select public.assign_driver_vehicle(
  '11111111-1111-1111-1111-111111111111'::uuid,
  :'driver_id'::uuid,
  :'vehicle_id'::uuid
);
select * from public.create_pilot_load(
  '11111111-1111-1111-1111-111111111111'::uuid,
  'HARDEN-A',
  '{"address":"1 Pickup Way","country":"US","timezone":"America/Chicago"}'::jsonb,
  '{"address":"2 Delivery Lane","country":"US","timezone":"America/Chicago"}'::jsonb
);
select id as load_id from public.loads where load_number = 'HARDEN-A' \gset
reset role;
update public.loads
set assigned_driver_id = :'driver_id'::uuid,
    assigned_vehicle_id = :'vehicle_id'::uuid
where id = :'load_id'::uuid;
set local role authenticated;
select set_config('request.jwt.claim.sub', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', true);
select public.advance_load_state(
  '11111111-1111-1111-1111-111111111111'::uuid, :'load_id'::uuid, 'scheduled'
);
select public.advance_load_state(
  '11111111-1111-1111-1111-111111111111'::uuid, :'load_id'::uuid, 'assigned'
);
reset role;

select ok(
  not has_function_privilege('authenticated', 'public.advance_own_driver_load_state()', 'execute'),
  'authenticated callers cannot bypass state replay receipts through the legacy route'
);
select ok(
  not has_function_privilege('authenticated', 'public.record_own_driver_load_evidence(text,jsonb)', 'execute'),
  'authenticated callers cannot bypass evidence replay receipts through the legacy route'
);
select ok(
  has_function_privilege('authenticated', 'public.advance_own_driver_load_state_idempotent(uuid)', 'execute'),
  'authenticated callers retain the idempotent state wrapper'
);
select ok(
  has_function_privilege('authenticated', 'public.record_own_driver_load_evidence_idempotent(uuid,text,jsonb)', 'execute'),
  'authenticated callers retain the idempotent evidence wrapper'
);
select ok(
  has_function_privilege('authenticated', 'public.report_own_driver_load_incident_idempotent(uuid,text,text,jsonb,jsonb)', 'execute'),
  'authenticated callers retain the idempotent incident wrapper'
);
set local role authenticated;
select set_config('request.jwt.claim.sub', '99999999-9999-9999-9999-999999999999', true);
select throws_ok(
  format(
    'select * from public.advance_load_state(%L::uuid, %L::uuid, %L)',
    '11111111-1111-1111-1111-111111111111', :'load_id', 'en_route_to_pickup'
  ),
  '42501',
  'driver mutations must use the idempotent sync wrapper',
  'a driver cannot call the scoped state route directly'
);
select throws_ok(
  format(
    'select * from public.record_load_evidence(%L::uuid, %L::uuid, %L, %L::jsonb)',
    '11111111-1111-1111-1111-111111111111', :'load_id', 'signature',
    '{"value":"Direct driver evidence"}'
  ),
  '42501',
  'driver mutations must use the idempotent sync wrapper',
  'a driver cannot call the scoped evidence route directly'
);
select is(
  public.advance_own_driver_load_state_idempotent(
    '11111111-1111-4111-8111-111111111111'::uuid
  ) ->> 'operationalStatus',
  'en_route_to_pickup',
  'the driver idempotent state wrapper remains allowed'
);
select is(
  public.advance_own_driver_load_state_idempotent(
    '11111111-1111-4111-8111-111111111111'::uuid
  ) ->> 'operationalStatus',
  'en_route_to_pickup',
  'state replay returns the original receipt result'
);
select is(
  (select count(*) from public.load_state_events
   where load_id = :'load_id'::uuid and to_status = 'en_route_to_pickup'),
  1::bigint,
  'state replay still creates only one event'
);
select lives_ok(
  $$select * from public.record_own_driver_load_evidence_idempotent(
    '22222222-2222-4222-8222-222222222222'::uuid,
    'signature', '{"value":"Receiver signature"}'::jsonb
  )$$,
  'the driver idempotent evidence wrapper remains allowed'
);
select lives_ok(
  $$select * from public.record_own_driver_load_evidence_idempotent(
    '22222222-2222-4222-8222-222222222222'::uuid,
    'signature', '{"value":"Receiver signature"}'::jsonb
  )$$,
  'evidence replay remains allowed through its receipt'
);
select is(
  (select count(*) from public.load_evidence
   where load_id = :'load_id'::uuid and evidence_type = 'signature'),
  1::bigint,
  'evidence replay still creates only one evidence row'
);

reset role;
set local role authenticated;
select set_config('request.jwt.claim.sub', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', true);
select lives_ok(
  format(
    'select * from public.advance_load_state(%L::uuid, %L::uuid, %L)',
    '11111111-1111-1111-1111-111111111111', :'load_id', 'arrived_pickup'
  ),
  'a manager retains direct scoped state authority'
);
select lives_ok(
  format(
    'select * from public.record_load_evidence(%L::uuid, %L::uuid, %L, %L::jsonb)',
    '11111111-1111-1111-1111-111111111111', :'load_id', 'signature',
    '{"value":"Manager evidence"}'
  ),
  'a manager retains direct scoped evidence authority'
);

select * from finish();
rollback;
