begin;

select plan(24);

\set tenant_fixture_setup true
\ir helpers/tenant-fixtures.sql
\unset tenant_fixture_setup
select test_helpers.seed_tenant_fixtures();

insert into auth.users (
  id, instance_id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at
) values
  ('99999999-9999-9999-9999-999999999999'::uuid, '00000000-0000-0000-0000-000000000000'::uuid, 'authenticated', 'authenticated', 'driver-a@carrierflow.test', '$2a$10$not-a-real-password-hash-for-local-tests-only', timezone('utc', now()), '{}'::jsonb, '{}'::jsonb, timezone('utc', now()), timezone('utc', now())),
  ('88888888-8888-8888-8888-888888888888'::uuid, '00000000-0000-0000-0000-000000000000'::uuid, 'authenticated', 'authenticated', 'driver-b@carrierflow.test', '$2a$10$not-a-real-password-hash-for-local-tests-only', timezone('utc', now()), '{}'::jsonb, '{}'::jsonb, timezone('utc', now()), timezone('utc', now()));

insert into public.company_memberships (id, company_id, user_id, role, status) values
  ('41414141-4141-4141-4141-414141414141'::uuid, '11111111-1111-1111-1111-111111111111'::uuid, '99999999-9999-9999-9999-999999999999'::uuid, 'driver', 'active'),
  ('51515151-5151-5151-5151-515151515151'::uuid, '11111111-1111-1111-1111-111111111111'::uuid, '88888888-8888-8888-8888-888888888888'::uuid, 'driver', 'active');

set local role authenticated;
select set_config('request.jwt.claim.sub', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', true);
select * from public.create_driver('11111111-1111-1111-1111-111111111111'::uuid, '41414141-4141-4141-4141-414141414141'::uuid, 'Driver A');
select id as driver_a_id from public.drivers where membership_id = '41414141-4141-4141-4141-414141414141'::uuid \gset
select * from public.create_driver('11111111-1111-1111-1111-111111111111'::uuid, '51515151-5151-5151-5151-515151515151'::uuid, 'Driver B');
select id as driver_b_id from public.drivers where membership_id = '51515151-5151-5151-5151-515151515151'::uuid \gset
select * from public.create_vehicle('11111111-1111-1111-1111-111111111111'::uuid, 'EXEC-UNIT', 'cargo_van', 3500);
select id as vehicle_id from public.vehicles where unit_number = 'EXEC-UNIT' \gset
select public.assign_driver_vehicle('11111111-1111-1111-1111-111111111111'::uuid, :'driver_a_id'::uuid, :'vehicle_id'::uuid);
select * from public.create_pilot_load(
  '11111111-1111-1111-1111-111111111111'::uuid,
  'EXEC-A',
  '{"address":"1 Pickup Way","country":"US","timezone":"America/Chicago"}'::jsonb,
  '{"address":"2 Delivery Lane","country":"US","timezone":"America/Chicago"}'::jsonb
);
select id as load_a_id from public.loads where load_number = 'EXEC-A' \gset
reset role;
update public.loads
set assigned_driver_id = :'driver_a_id'::uuid,
    assigned_vehicle_id = :'vehicle_id'::uuid
where id = :'load_a_id'::uuid;
insert into storage.objects (bucket_id, name, owner, metadata)
values (
  'carrierflow-private-evidence',
  format('private/11111111-1111-1111-1111-111111111111/loads/%s/evidence/receipt-bol', :'load_a_id'),
  '99999999-9999-9999-9999-999999999999'::uuid,
  '{"mimetype":"application/pdf","size":128}'::jsonb
);
set local role authenticated;
select set_config('request.jwt.claim.sub', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', true);
select public.advance_load_state('11111111-1111-1111-1111-111111111111'::uuid, :'load_a_id'::uuid, 'scheduled');
select public.advance_load_state('11111111-1111-1111-1111-111111111111'::uuid, :'load_a_id'::uuid, 'assigned');
select public.advance_load_state('11111111-1111-1111-1111-111111111111'::uuid, :'load_a_id'::uuid, 'en_route_to_pickup');
select public.advance_load_state('11111111-1111-1111-1111-111111111111'::uuid, :'load_a_id'::uuid, 'arrived_pickup');
select public.advance_load_state('11111111-1111-1111-1111-111111111111'::uuid, :'load_a_id'::uuid, 'loading');
select public.advance_load_state('11111111-1111-1111-1111-111111111111'::uuid, :'load_a_id'::uuid, 'picked_up');
select public.advance_load_state('11111111-1111-1111-1111-111111111111'::uuid, :'load_a_id'::uuid, 'en_route_to_delivery');
select public.advance_load_state('11111111-1111-1111-1111-111111111111'::uuid, :'load_a_id'::uuid, 'arrived_delivery');
select public.advance_load_state('11111111-1111-1111-1111-111111111111'::uuid, :'load_a_id'::uuid, 'unloading');
select public.configure_load_evidence_requirements('11111111-1111-1111-1111-111111111111'::uuid, :'load_a_id'::uuid, '["signature"]'::jsonb);
reset role;
set local role authenticated;
select set_config('request.jwt.claim.sub', '99999999-9999-9999-9999-999999999999', true);

select ok(to_regprocedure('public.get_own_driver_assigned_loads()') is not null, 'the own-load list RPC has no caller-controlled scope');
select ok(to_regprocedure('public.get_own_driver_execution_snapshot()') is not null, 'the own execution snapshot RPC has no caller-controlled scope');
select ok(to_regprocedure('public.advance_own_driver_load_state_idempotent(uuid)') is not null, 'the idempotent next-state RPC has no target status input');
select ok(to_regprocedure('public.advance_own_driver_load_state(uuid,uuid,text)') is null, 'no client-scoped advance RPC is exposed');
select ok(to_regprocedure('public.record_own_driver_load_evidence_idempotent(uuid,text,jsonb)') is not null, 'idempotent evidence accepts only a mutation id and typed evidence content');
select ok(to_regprocedure('public.report_own_driver_load_incident_idempotent(uuid,text,text,jsonb,jsonb)') is not null, 'incident accepts durable client mutation id without load scope');
select is(
  (select jsonb_array_length(public.get_own_driver_assigned_loads())),
  1,
  'the assigned driver receives exactly their own visible load'
);
select is(
  public.get_own_driver_execution_snapshot() ->> 'loadId',
  :'load_a_id',
  'the server snapshot derives the current assigned load'
);
select is(
  public.get_own_driver_execution_snapshot() ->> 'serverDefinedNextStatus',
  'delivered',
  'the server defines the next operational state'
);
select throws_ok(
  $$select * from public.advance_own_driver_load_state_idempotent('10101010-1010-4010-8010-101010101010'::uuid)$$,
  '22023',
  'required delivery evidence is incomplete',
  'the wrapper preserves configured evidence enforcement'
);
select lives_ok(
  $$select * from public.record_own_driver_load_evidence_idempotent('20202020-2020-4020-8020-202020202020'::uuid, 'bol', '{"receiptKey":"receipt-bol","mimeType":"application/pdf","byteLength":128}'::jsonb)$$,
  'opaque evidence receipt metadata resolves only to a verified private Storage object'
);
select is(
  (select evidence_value ->> 'storagePath' from public.load_evidence where load_id = :'load_a_id'::uuid and evidence_type = 'bol'),
  format('private/11111111-1111-1111-1111-111111111111/loads/%s/evidence/receipt-bol', :'load_a_id'),
  'the server derives the private evidence path rather than receiving it from the driver'
);
select lives_ok(
  $$select * from public.record_own_driver_load_evidence_idempotent('30303030-3030-4030-8030-303030303030'::uuid, 'signature', '{"value":"Receiver signature"}'::jsonb)$$,
  'the own-load evidence wrapper uses the existing server validation boundary'
);
select lives_ok(
  $$select * from public.advance_own_driver_load_state_idempotent('40404040-4040-4040-8040-404040404040'::uuid)$$,
  'the wrapper advances only to the server-defined delivered state'
);
select is((select operational_status from public.loads where id = :'load_a_id'::uuid), 'delivered', 'the server-derived transition is persisted');

reset role;
set local role authenticated;
select set_config('request.jwt.claim.sub', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', true);
select * from public.create_pilot_load(
  '11111111-1111-1111-1111-111111111111'::uuid,
  'EXEC-INCIDENT',
  '{"address":"3 Pickup Way","country":"US","timezone":"America/Chicago"}'::jsonb,
  '{"address":"4 Delivery Lane","country":"US","timezone":"America/Chicago"}'::jsonb
);
select id as incident_load_id from public.loads where load_number = 'EXEC-INCIDENT' \gset
reset role;
update public.loads
set assigned_driver_id = :'driver_a_id'::uuid,
    assigned_vehicle_id = :'vehicle_id'::uuid
where id = :'incident_load_id'::uuid;
set local role authenticated;
select set_config('request.jwt.claim.sub', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', true);
select public.advance_load_state('11111111-1111-1111-1111-111111111111'::uuid, :'incident_load_id'::uuid, 'scheduled');
select public.advance_load_state('11111111-1111-1111-1111-111111111111'::uuid, :'incident_load_id'::uuid, 'assigned');
reset role;
set local role authenticated;
select set_config('request.jwt.claim.sub', '99999999-9999-9999-9999-999999999999', true);
select is(
  to_jsonb(public.report_own_driver_load_incident_idempotent(
    '77777777-7777-4777-8777-777777777777'::uuid,
    'customer_unavailable',
    'Receiver asked the driver to wait.',
    '[]'::jsonb,
    '{"latitude":41.8781,"longitude":-87.6298}'::jsonb
  )),
  jsonb_build_object('clientMutationId', '77777777-7777-4777-8777-777777777777'),
  'a new incident returns only its opaque client mutation acknowledgement'
);
reset role;
set local role authenticated;
select set_config('request.jwt.claim.sub', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', true);
select public.advance_load_state('11111111-1111-1111-1111-111111111111'::uuid, :'incident_load_id'::uuid, 'cancelled');
reset role;
set local role authenticated;
select set_config('request.jwt.claim.sub', '99999999-9999-9999-9999-999999999999', true);
select is(
  to_jsonb(public.report_own_driver_load_incident_idempotent(
    '77777777-7777-4777-8777-777777777777'::uuid,
    'customer_unavailable',
    'Receiver asked the driver to wait.',
    '[]'::jsonb,
    '{"latitude":41.8781,"longitude":-87.6298}'::jsonb
  )),
  jsonb_build_object('clientMutationId', '77777777-7777-4777-8777-777777777777'),
  'an incident retry returns only its opaque acknowledgement after cancellation'
);
select is((select count(*) from public.load_incidents where load_id = :'incident_load_id'::uuid), 1::bigint, 'a repeated incident key replays one durable incident');
select is((select operational_status from public.loads where id = :'incident_load_id'::uuid), 'cancelled', 'an incident replay does not reverse a manager cancellation');

reset role;
update public.loads
set assigned_driver_id = :'driver_b_id'::uuid
where id = :'incident_load_id'::uuid;
update public.drivers
set status = 'inactive'
where id = :'driver_a_id'::uuid;
set local role authenticated;
select set_config('request.jwt.claim.sub', '99999999-9999-9999-9999-999999999999', true);
select is(
  to_jsonb(public.report_own_driver_load_incident_idempotent(
    '77777777-7777-4777-8777-777777777777'::uuid,
    'customer_unavailable',
    'Receiver asked the driver to wait.',
    '[]'::jsonb,
    '{"latitude":41.8781,"longitude":-87.6298}'::jsonb
  )),
  jsonb_build_object('clientMutationId', '77777777-7777-4777-8777-777777777777'),
  'a deactivated and reassigned former driver replays only the opaque acknowledgement'
);
select throws_ok(
  $$select * from public.report_own_driver_load_incident_idempotent(
    '66666666-6666-4666-8666-666666666666'::uuid,
    'customer_unavailable',
    'A new incident is not authorized for an inactive former driver.',
    '[]'::jsonb,
    null
  )$$,
  '42501',
  'no active assigned load is available for this driver',
  'receipt replay does not authorize a new incident for a deactivated former driver'
);
select throws_ok(
  $$select * from public.report_own_driver_load_incident_idempotent(
    '77777777-7777-4777-8777-777777777777'::uuid,
    'customer_unavailable',
    'Modified payload must never replace the persisted incident.',
    '[]'::jsonb,
    '{"latitude":41.8781,"longitude":-87.6298}'::jsonb
  )$$,
  '22023',
  'incident mutation id cannot be reused with different data',
  'a replay key cannot disclose or alter its original incident with a modified payload'
);

reset role;
set local role authenticated;
select set_config('request.jwt.claim.sub', '88888888-8888-8888-8888-888888888888', true);
select is(jsonb_array_length(public.get_own_driver_assigned_loads()), 0, 'another driver cannot obtain the assigned driver load through the wrapper');
select throws_ok(
  $$select * from public.advance_own_driver_load_state_idempotent('50505050-5050-4050-8050-505050505050'::uuid)$$,
  '42501',
  'no active assigned load is available for this driver',
  'another driver cannot transition the first driver load through the wrapper'
);

select * from finish();
rollback;
