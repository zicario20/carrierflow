begin;

select plan(19);

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
  'authenticated', 'authenticated', 'core-authority-driver@carrierflow.test',
  '$2a$10$not-a-real-password-hash-for-local-tests-only', timezone('utc', now()),
  '{}'::jsonb, '{}'::jsonb, timezone('utc', now()), timezone('utc', now())
);
insert into public.company_memberships (id, company_id, user_id, role, status)
values (
  '51515151-5151-5151-5151-515151515151'::uuid,
  '11111111-1111-1111-1111-111111111111'::uuid,
  '99999999-9999-9999-9999-999999999999'::uuid,
  'driver', 'active'
);

set local role authenticated;
select set_config('request.jwt.claim.sub', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', true);
select * from public.create_driver(
  '11111111-1111-1111-1111-111111111111'::uuid,
  '51515151-5151-5151-5151-515151515151'::uuid,
  'Core Authority Driver'
);
select id as driver_id from public.drivers
where membership_id = '51515151-5151-5151-5151-515151515151'::uuid \gset
select * from public.create_vehicle(
  '11111111-1111-1111-1111-111111111111'::uuid,
  'CORE-AUTH-UNIT', 'cargo_van', 3500
);
select id as vehicle_id from public.vehicles where unit_number = 'CORE-AUTH-UNIT' \gset
select public.assign_driver_vehicle(
  '11111111-1111-1111-1111-111111111111'::uuid,
  :'driver_id'::uuid,
  :'vehicle_id'::uuid
);
select * from public.create_pilot_load(
  '11111111-1111-1111-1111-111111111111'::uuid,
  'CORE-AUTH-A',
  '{"address":"1 Pickup Way","country":"US","timezone":"America/Chicago"}'::jsonb,
  '{"address":"2 Delivery Lane","country":"US","timezone":"America/Chicago"}'::jsonb
);
select id as load_id from public.loads where load_number = 'CORE-AUTH-A' \gset
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
  pg_get_functiondef('public.advance_load_state(uuid,uuid,text)'::regprocedure)
    not like '%carrierflow.driver_sync_actor%',
  'the public state route has no client-controlled sync marker'
);
select ok(
  pg_get_functiondef('public.record_load_evidence(uuid,uuid,text,jsonb)'::regprocedure)
    not like '%carrierflow.driver_sync_actor%',
  'the public evidence route has no client-controlled sync marker'
);
select ok(
  to_regprocedure('public.enter_driver_sync_operation()') is null,
  'the old public sync marker is removed'
);
select ok(
  not has_schema_privilege('authenticated', 'driver_sync_private', 'usage'),
  'authenticated callers cannot use the private sync schema'
);
select ok(
  not has_function_privilege(
    'authenticated',
    'driver_sync_private.advance_current_driver_load_state()',
    'execute'
  ),
  'authenticated callers cannot execute the private state helper'
);
select ok(
  not has_function_privilege(
    'authenticated',
    'driver_sync_private.record_current_driver_load_evidence(text,jsonb)',
    'execute'
  ),
  'authenticated callers cannot execute the private evidence helper'
);

set local role authenticated;
select set_config('request.jwt.claim.sub', '99999999-9999-9999-9999-999999999999', true);
select lives_ok(
  $$select set_config('carrierflow.driver_sync_actor', auth.uid()::text, true)$$,
  'a driver can set a custom transaction value but it grants no authority'
);
select throws_ok(
  format(
    'select * from public.advance_load_state(%L::uuid, %L::uuid, %L)',
    '11111111-1111-1111-1111-111111111111', :'load_id', 'en_route_to_pickup'
  ),
  '42501',
  'driver mutations must use the idempotent sync wrapper',
  'direct driver state remains denied after a client-set marker'
);
select throws_ok(
  format(
    'select * from public.record_load_evidence(%L::uuid, %L::uuid, %L, %L::jsonb)',
    '11111111-1111-1111-1111-111111111111', :'load_id', 'signature',
    '{"value":"Direct driver evidence"}'
  ),
  '42501',
  'driver mutations must use the idempotent sync wrapper',
  'direct driver evidence remains denied after a client-set marker'
);
select throws_ok(
  $$select * from driver_sync_private.advance_current_driver_load_state()$$,
  '42501',
  null,
  'a client cannot invoke the private state helper'
);
select throws_ok(
  $$select * from driver_sync_private.record_current_driver_load_evidence('signature', '{"value":"Direct private evidence"}'::jsonb)$$,
  '42501',
  null,
  'a client cannot invoke the private evidence helper'
);
select is(
  public.advance_own_driver_load_state_idempotent(
    '33333333-3333-4333-8333-333333333333'::uuid
  ) ->> 'operationalStatus',
  'en_route_to_pickup',
  'the driver idempotent state wrapper reaches the private core'
);
select is(
  public.advance_own_driver_load_state_idempotent(
    '33333333-3333-4333-8333-333333333333'::uuid
  ) ->> 'operationalStatus',
  'en_route_to_pickup',
  'state replay returns the original result through the private core'
);
select is(
  (select count(*) from public.load_state_events
   where load_id = :'load_id'::uuid and to_status = 'en_route_to_pickup'),
  1::bigint,
  'state replay creates one event'
);
select lives_ok(
  $$select * from public.record_own_driver_load_evidence_idempotent(
    '44444444-4444-4444-8444-444444444444'::uuid,
    'signature', '{"value":"Receiver signature"}'::jsonb
  )$$,
  'the driver idempotent evidence wrapper reaches the private core'
);
select lives_ok(
  $$select * from public.record_own_driver_load_evidence_idempotent(
    '44444444-4444-4444-8444-444444444444'::uuid,
    'signature', '{"value":"Receiver signature"}'::jsonb
  )$$,
  'evidence replay returns through its original receipt'
);
select is(
  (select count(*) from public.load_evidence
   where load_id = :'load_id'::uuid and evidence_type = 'signature'),
  1::bigint,
  'evidence replay creates one evidence row'
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
