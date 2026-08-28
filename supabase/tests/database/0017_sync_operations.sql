begin;

select plan(14);

\set tenant_fixture_setup true
\ir helpers/tenant-fixtures.sql
\unset tenant_fixture_setup
select test_helpers.seed_tenant_fixtures();

insert into auth.users (
  id, instance_id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at
) values
  ('99999999-9999-9999-9999-999999999999'::uuid, '00000000-0000-0000-0000-000000000000'::uuid, 'authenticated', 'authenticated', 'sync-driver-a@carrierflow.test', '$2a$10$not-a-real-password-hash-for-local-tests-only', timezone('utc', now()), '{}'::jsonb, '{}'::jsonb, timezone('utc', now()), timezone('utc', now())),
  ('88888888-8888-8888-8888-888888888888'::uuid, '00000000-0000-0000-0000-000000000000'::uuid, 'authenticated', 'authenticated', 'sync-driver-b@carrierflow.test', '$2a$10$not-a-real-password-hash-for-local-tests-only', timezone('utc', now()), '{}'::jsonb, '{}'::jsonb, timezone('utc', now()), timezone('utc', now()));

insert into public.company_memberships (id, company_id, user_id, role, status) values
  ('41414141-4141-4141-4141-414141414141'::uuid, '11111111-1111-1111-1111-111111111111'::uuid, '99999999-9999-9999-9999-999999999999'::uuid, 'driver', 'active'),
  ('51515151-5151-5151-5151-515151515151'::uuid, '11111111-1111-1111-1111-111111111111'::uuid, '88888888-8888-8888-8888-888888888888'::uuid, 'driver', 'active');

set local role authenticated;
select set_config('request.jwt.claim.sub', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', true);
select * from public.create_driver('11111111-1111-1111-1111-111111111111'::uuid, '41414141-4141-4141-4141-414141414141'::uuid, 'Sync Driver A');
select id as driver_a_id from public.drivers where membership_id = '41414141-4141-4141-4141-414141414141'::uuid \gset
select * from public.create_driver('11111111-1111-1111-1111-111111111111'::uuid, '51515151-5151-5151-5151-515151515151'::uuid, 'Sync Driver B');
select id as driver_b_id from public.drivers where membership_id = '51515151-5151-5151-5151-515151515151'::uuid \gset
select * from public.create_vehicle('11111111-1111-1111-1111-111111111111'::uuid, 'SYNC-UNIT', 'cargo_van', 3500);
select id as vehicle_id from public.vehicles where unit_number = 'SYNC-UNIT' \gset
select public.assign_driver_vehicle('11111111-1111-1111-1111-111111111111'::uuid, :'driver_a_id'::uuid, :'vehicle_id'::uuid);
select * from public.create_pilot_load(
  '11111111-1111-1111-1111-111111111111'::uuid,
  'SYNC-A',
  '{"address":"1 Pickup Way","country":"US","timezone":"America/Chicago"}'::jsonb,
  '{"address":"2 Delivery Lane","country":"US","timezone":"America/Chicago"}'::jsonb
);
select id as load_a_id from public.loads where load_number = 'SYNC-A' \gset
reset role;
update public.loads set assigned_driver_id = :'driver_a_id'::uuid, assigned_vehicle_id = :'vehicle_id'::uuid where id = :'load_a_id'::uuid;
set local role authenticated;
select set_config('request.jwt.claim.sub', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', true);
select public.advance_load_state('11111111-1111-1111-1111-111111111111'::uuid, :'load_a_id'::uuid, 'scheduled');
select public.advance_load_state('11111111-1111-1111-1111-111111111111'::uuid, :'load_a_id'::uuid, 'assigned');
reset role;
set local role authenticated;
select set_config('request.jwt.claim.sub', '99999999-9999-9999-9999-999999999999', true);

select ok(to_regprocedure('public.advance_own_driver_load_state_idempotent(uuid)') is not null, 'state replay RPC has no caller-owned scope');
select ok(to_regprocedure('public.record_own_driver_load_evidence_idempotent(uuid,text,jsonb)') is not null, 'evidence replay RPC has no caller-owned scope');
select is(
  to_jsonb(public.advance_own_driver_load_state_idempotent('11111111-1111-4111-8111-111111111111'::uuid)) ->> 'operationalStatus',
  'en_route_to_pickup',
  'a first state mutation advances only through the server-defined transition'
);
select is(
  to_jsonb(public.advance_own_driver_load_state_idempotent('11111111-1111-4111-8111-111111111111'::uuid)) ->> 'operationalStatus',
  'en_route_to_pickup',
  'the same state mutation replays the original server result'
);
select is((select count(*) from public.load_state_events where load_id = :'load_a_id'::uuid and to_status = 'en_route_to_pickup'), 1::bigint, 'state replay creates one event');
select throws_ok(
  $$select * from public.record_own_driver_load_evidence_idempotent('11111111-1111-4111-8111-111111111111'::uuid, 'signature', '{"value":"Receiver signature"}'::jsonb)$$,
  '22023',
  'sync mutation id cannot be reused with different data',
  'a state mutation id cannot cross operation boundaries'
);
select lives_ok(
  $$select * from public.record_own_driver_load_evidence_idempotent('22222222-2222-4222-8222-222222222222'::uuid, 'signature', '{"value":"Receiver signature"}'::jsonb)$$,
  'a server-scoped evidence replay mutation records evidence'
);
select lives_ok(
  $$select * from public.record_own_driver_load_evidence_idempotent('22222222-2222-4222-8222-222222222222'::uuid, 'signature', '{"value":"Receiver signature"}'::jsonb)$$,
  'the same evidence mutation replays its original receipt'
);
select is((select count(*) from public.load_evidence where load_id = :'load_a_id'::uuid and evidence_type = 'signature'), 1::bigint, 'evidence replay creates one evidence row');
select throws_ok(
  $$select * from public.record_own_driver_load_evidence_idempotent('22222222-2222-4222-8222-222222222222'::uuid, 'signature', '{"value":"Changed receiver"}'::jsonb)$$,
  '22023',
  'sync mutation id cannot be reused with different data',
  'evidence mutation fingerprints the original payload'
);

reset role;
set local role authenticated;
select set_config('request.jwt.claim.sub', '88888888-8888-8888-8888-888888888888', true);
select throws_ok(
  $$select * from public.advance_own_driver_load_state_idempotent('33333333-3333-4333-8333-333333333333'::uuid)$$,
  '42501',
  'no active assigned load is available for this driver',
  'another driver cannot create a state receipt for the assigned load'
);

reset role;
select is((select count(*) from public.driver_sync_receipts), 2::bigint, 'unrelated drivers cannot add receipt rows');
select lives_ok(
  $$select 1 from public.driver_sync_receipts$$,
  'the table remains inaccessible to authenticated callers through direct grants'
);
set local role authenticated;
select set_config('request.jwt.claim.sub', '99999999-9999-9999-9999-999999999999', true);
select throws_ok(
  $$select 1 from public.driver_sync_receipts$$,
  '42501',
  null,
  'authenticated callers cannot directly read private sync receipts'
);

select * from finish();
rollback;
