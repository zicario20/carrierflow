begin;

select plan(13);

\set tenant_fixture_setup true
\ir helpers/tenant-fixtures.sql
\unset tenant_fixture_setup
select test_helpers.seed_tenant_fixtures();

insert into auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at) values
  ('99999999-9999-9999-9999-999999999999', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'dispatch-driver@carrierflow.test', '$2a$10$not-a-real-password-hash-for-local-tests-only', now(), '{}'::jsonb, '{}'::jsonb, now(), now()),
  ('88888888-8888-8888-8888-888888888888', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'dispatch-driver-b@carrierflow.test', '$2a$10$not-a-real-password-hash-for-local-tests-only', now(), '{}'::jsonb, '{}'::jsonb, now(), now());
insert into public.company_memberships (id, company_id, user_id, role, status) values
  ('41414141-4141-4141-4141-414141414141', '11111111-1111-1111-1111-111111111111', '99999999-9999-9999-9999-999999999999', 'driver', 'active'),
  ('51515151-5151-5151-5151-515151515151', '11111111-1111-1111-1111-111111111111', '88888888-8888-8888-8888-888888888888', 'driver', 'active');

set local role authenticated;
select set_config('request.jwt.claim.sub', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', true);
select * from public.create_driver('11111111-1111-1111-1111-111111111111', '41414141-4141-4141-4141-414141414141', 'Dispatch Driver A');
select * from public.create_driver('11111111-1111-1111-1111-111111111111', '51515151-5151-5151-5151-515151515151', 'Dispatch Driver B');
select id as driver_a from public.drivers where membership_id = '41414141-4141-4141-4141-414141414141' \gset
select id as driver_b from public.drivers where membership_id = '51515151-5151-5151-5151-515151515151' \gset
select * from public.create_vehicle('11111111-1111-1111-1111-111111111111', 'DISPATCH-A', 'cargo_van', 3500);
select * from public.create_vehicle('11111111-1111-1111-1111-111111111111', 'DISPATCH-B', 'box_truck', 5000);
select id as vehicle_a from public.vehicles where unit_number = 'DISPATCH-A' \gset
select id as vehicle_b from public.vehicles where unit_number = 'DISPATCH-B' \gset
select * from public.assign_driver_vehicle('11111111-1111-1111-1111-111111111111', :'driver_a', :'vehicle_a');
select * from public.assign_driver_vehicle('11111111-1111-1111-1111-111111111111', :'driver_b', :'vehicle_b');
select * from public.create_pilot_load('11111111-1111-1111-1111-111111111111', 'DISPATCH-001', '{"address":"1 Pickup Way","country":"US","timezone":"America/Chicago"}'::jsonb, '{"address":"2 Delivery Way","country":"US","timezone":"America/Chicago"}'::jsonb);
select id as load_id from public.loads where load_number = 'DISPATCH-001' \gset

select lives_ok(format('select * from public.assign_load_resources(%L::uuid,%L::uuid,%L::uuid,%L::uuid,%L::uuid)', '11111111-1111-1111-1111-111111111111', :'load_id', :'driver_a', :'vehicle_a', '12121212-1212-4121-8121-121212121212'), 'authorized manager can make mandatory first assignment');
select is((select operational_status from public.loads where id = :'load_id'::uuid), 'assigned', 'first assignment atomically makes load assigned');
select results_eq(format('select from_status || ''>'' || to_status from public.load_state_events where load_id=%L::uuid order by from_status', :'load_id'), array['draft>scheduled'::text,'scheduled>assigned'::text], 'first assignment preserves ordered state history');
select is((select count(*)::integer from public.load_assignment_events where load_id = :'load_id'::uuid), 1, 'first assignment writes immutable history');
select is((select count(*)::integer from public.load_dispatch_notifications where load_id = :'load_id'::uuid), 1, 'first assignment writes one minimal outbox notification');
select lives_ok(format('select * from public.assign_load_resources(%L::uuid,%L::uuid,%L::uuid,%L::uuid,%L::uuid)', '11111111-1111-1111-1111-111111111111', :'load_id', :'driver_a', :'vehicle_a', '12121212-1212-4121-8121-121212121212'), 'same idempotency retry returns the assigned load');
select is((select count(*)::integer from public.load_assignment_events where load_id = :'load_id'::uuid), 1, 'retry duplicates neither assignment history');
select lives_ok(format('select * from public.assign_load_resources(%L::uuid,%L::uuid,%L::uuid,%L::uuid,%L::uuid)', '11111111-1111-1111-1111-111111111111', :'load_id', :'driver_b', :'vehicle_b', '13131313-1313-4131-8131-131313131313'), 'authorized manager can reassign an active load');
select is((select assigned_driver_id from public.loads where id = :'load_id'::uuid), :'driver_b'::uuid, 'reassignment updates visible assigned driver');
select is((select count(*)::integer from public.load_dispatch_notifications where load_id = :'load_id'::uuid), 3, 'reassignment notifies old and new drivers exactly once');
select ok(exists(select 1 from public.audit_events where entity_id = :'load_id'::uuid and action = 'load.reassigned'), 'reassignment creates generic audit event');
select throws_ok(format('select * from public.assign_load_resources(%L::uuid,%L::uuid,%L::uuid,%L::uuid,%L::uuid)', '22222222-2222-2222-2222-222222222222', :'load_id', :'driver_b', :'vehicle_b', '14141414-1414-4141-8141-141414141414'), '42501', 'only an authorized manager may assign a load', 'cross-tenant assignment is denied without disclosing load');

reset role;
set local role authenticated;
select set_config('request.jwt.claim.sub', '99999999-9999-9999-9999-999999999999', true);
select throws_ok(format('select * from public.assign_load_resources(%L::uuid,%L::uuid,%L::uuid,%L::uuid,%L::uuid)', '11111111-1111-1111-1111-111111111111', :'load_id', :'driver_a', :'vehicle_a', '15151515-1515-4151-8151-151515151515'), '42501', 'only an authorized manager may assign a load', 'driver cannot assign or reassign');

select * from finish();
rollback;
