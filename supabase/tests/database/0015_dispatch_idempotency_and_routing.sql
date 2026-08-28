begin;

select plan(17);

\set tenant_fixture_setup true
\ir helpers/tenant-fixtures.sql
\unset tenant_fixture_setup
select test_helpers.seed_tenant_fixtures();

insert into auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at) values
  ('77777777-7777-7777-7777-777777777777', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'intent-driver@carrierflow.test', '$2a$10$not-a-real-password-hash-for-local-tests-only', now(), '{}'::jsonb, '{}'::jsonb, now(), now());
insert into public.company_memberships (id, company_id, user_id, role, status) values
  ('71717171-7171-7171-7171-717171717171', '11111111-1111-1111-1111-111111111111', '77777777-7777-7777-7777-777777777777', 'driver', 'active');

set local role authenticated;
select set_config('request.jwt.claim.sub', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', true);
select * from public.create_driver('11111111-1111-1111-1111-111111111111', '71717171-7171-7171-7171-717171717171', 'Intent Driver');
select id as driver_id from public.drivers where membership_id = '71717171-7171-7171-7171-717171717171' \gset
select * from public.create_vehicle('11111111-1111-1111-1111-111111111111', 'INTENT-1', 'cargo_van', 3500);
select id as vehicle_id from public.vehicles where unit_number = 'INTENT-1' \gset
select * from public.assign_driver_vehicle('11111111-1111-1111-1111-111111111111', :'driver_id', :'vehicle_id');
select public.set_company_route_base('11111111-1111-1111-1111-111111111111', '{"label":"Chicago base","latitude":41.8781,"longitude":-87.6298}'::jsonb);

select lives_ok($$select * from public.create_load_proposal(
  '11111111-1111-1111-1111-111111111111'::uuid,
  '10101010-1010-4010-8010-101010101010'::uuid,
  'INTENT-LOAD',
  '{"address":"Pickup","country":"US","timezone":"America/Chicago","latitude":41.0,"longitude":-87.0}'::jsonb,
  '{"address":"Delivery","country":"US","timezone":"America/Chicago","latitude":40.0,"longitude":-86.0}'::jsonb,
  250.00
)$$, 'manager creates an idempotent draft proposal');
select id as load_id from public.loads where load_number = 'INTENT-LOAD' \gset
select is((select operational_status from public.loads where id = :'load_id'::uuid), 'draft', 'proposal stays draft until resources are assigned');
reset role;
select is((select count(*) from public.route_estimate_recompute_jobs where load_id = :'load_id'::uuid), 0::bigint, 'draft proposal never requests a route estimate');
set local role authenticated;
select set_config('request.jwt.claim.sub', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', true);
select is((select (public.create_load_proposal(
  '11111111-1111-1111-1111-111111111111'::uuid,
  '10101010-1010-4010-8010-101010101010'::uuid,
  'INTENT-LOAD',
  '{"address":"Pickup","country":"US","timezone":"America/Chicago","latitude":41.0,"longitude":-87.0}'::jsonb,
  '{"address":"Delivery","country":"US","timezone":"America/Chicago","latitude":40.0,"longitude":-86.0}'::jsonb,
  250.00
)).id), :'load_id'::uuid, 'same proposal intent returns the original draft');
select is((select count(*) from public.loads where load_number = 'INTENT-LOAD'), 1::bigint, 'proposal retry creates no second load');
select is((select count(*) from public.audit_events where entity_id = :'load_id'::uuid and action = 'load.proposal_created'), 1::bigint, 'proposal retry creates no second audit event');
select throws_ok(format('select * from public.assign_load_resources(%L::uuid,%L::uuid,%L::uuid,%L::uuid)', '11111111-1111-1111-1111-111111111111', :'load_id', :'driver_id', :'vehicle_id'), '42883', 'function public.assign_load_resources(uuid, uuid, uuid, uuid) does not exist', 'legacy four-argument assignment overload is unavailable');
select lives_ok(format('select * from public.assign_load_resources(%L::uuid,%L::uuid,%L::uuid,%L::uuid,%L::uuid)', '11111111-1111-1111-1111-111111111111', :'load_id', :'driver_id', :'vehicle_id', '20202020-2020-4020-8020-202020202020'), 'secure assignment atomically assigns and requests initial routing');
select is((select operational_status from public.loads where id = :'load_id'::uuid), 'assigned', 'mandatory assignment changes status');
reset role;
select is((select count(*) from public.route_estimate_recompute_jobs where load_id = :'load_id'::uuid and reason = 'initial'), 1::bigint, 'assignment queues one durable initial route job');
set local role authenticated;
select set_config('request.jwt.claim.sub', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', true);
select lives_ok(format('select * from public.assign_load_resources(%L::uuid,%L::uuid,%L::uuid,%L::uuid,%L::uuid)', '11111111-1111-1111-1111-111111111111', :'load_id', :'driver_id', :'vehicle_id', '20202020-2020-4020-8020-202020202020'), 'assignment retry returns original result');
select is((select count(*) from public.load_assignment_events where load_id = :'load_id'::uuid), 1::bigint, 'assignment retry creates no second history event');
select lives_ok(format('select * from public.cancel_load_idempotent(%L::uuid,%L::uuid,%L::uuid)', '11111111-1111-1111-1111-111111111111', :'load_id', '30303030-3030-4030-8030-303030303030'), 'manager cancellation has an idempotent boundary');
select is((select operational_status from public.loads where id = :'load_id'::uuid), 'cancelled', 'cancellation changes state through audited state machine');
select lives_ok(format('select * from public.cancel_load_idempotent(%L::uuid,%L::uuid,%L::uuid)', '11111111-1111-1111-1111-111111111111', :'load_id', '30303030-3030-4030-8030-303030303030'), 'cancellation retry returns the original result');
select is((select count(*) from public.audit_events where entity_id = :'load_id'::uuid and action = 'load.cancelled'), 1::bigint, 'cancellation retry creates no second audit event');
reset role;
set local role authenticated;
select set_config('request.jwt.claim.sub', '77777777-7777-7777-7777-777777777777', true);
select throws_ok($$select * from public.create_load_proposal(
  '11111111-1111-1111-1111-111111111111'::uuid,
  '40404040-4040-4040-8040-404040404040'::uuid,
  'DRIVER-DENIED',
  '{"address":"Pickup","country":"US","timezone":"America/Chicago"}'::jsonb,
  '{"address":"Delivery","country":"US","timezone":"America/Chicago"}'::jsonb,
  1.00
)$$, '42501', 'only an authorized manager may create a load proposal', 'driver cannot create a proposal through the secure RPC');

select * from finish();
rollback;
