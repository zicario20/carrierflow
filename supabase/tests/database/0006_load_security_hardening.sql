begin;

select plan(53);

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
select lives_ok(
  $$select * from public.create_driver('11111111-1111-1111-1111-111111111111'::uuid, '41414141-4141-4141-4141-414141414141'::uuid, 'Driver A')$$,
  'an owner creates driver A'
);
select id as driver_a_id from public.drivers where membership_id = '41414141-4141-4141-4141-414141414141'::uuid \gset
select lives_ok(
  $$select * from public.create_driver('11111111-1111-1111-1111-111111111111'::uuid, '51515151-5151-5151-5151-515151515151'::uuid, 'Driver B')$$,
  'an owner creates driver B in the same company'
);
select id as driver_b_id from public.drivers where membership_id = '51515151-5151-5151-5151-515151515151'::uuid \gset
select lives_ok(
  $$select * from public.create_vehicle('11111111-1111-1111-1111-111111111111'::uuid, 'LOAD-SEC', 'cargo_van', 3500)$$,
  'an owner creates the vehicle used by the load assignment'
);
select id as vehicle_id from public.vehicles where unit_number = 'LOAD-SEC' \gset
select lives_ok(
  format('select * from public.assign_driver_vehicle(%L::uuid, %L::uuid, %L::uuid)', '11111111-1111-1111-1111-111111111111', :'driver_a_id', :'vehicle_id'),
  'the active vehicle is assigned to driver A'
);
select lives_ok(
  $$select * from public.create_pilot_load(
    '11111111-1111-1111-1111-111111111111'::uuid,
    'SEC-LOAD-A',
    '{"address":"1 Pickup Way","country":"US","timezone":"America/Chicago"}'::jsonb,
    '{"address":"2 Delivery Lane","country":"US","timezone":"America/Chicago"}'::jsonb
  )$$,
  'an owner creates the protected load'
);
select id as load_a_id from public.loads where load_number = 'SEC-LOAD-A' \gset
reset role;
insert into storage.objects (bucket_id, name, owner, metadata)
values
  (
    'carrierflow-private-evidence',
    format('private/11111111-1111-1111-1111-111111111111/loads/%s/evidence/bill', :'load_a_id'),
    '99999999-9999-9999-9999-999999999999'::uuid,
    '{"mimetype":"application/pdf","size":128}'::jsonb
  ),
  (
    'carrierflow-private-evidence',
    format('private/11111111-1111-1111-1111-111111111111/loads/%s/evidence/pod', :'load_a_id'),
    '99999999-9999-9999-9999-999999999999'::uuid,
    '{"mimetype":"application/pdf","size":128}'::jsonb
  );
set local role authenticated;
select set_config('request.jwt.claim.sub', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', true);
select lives_ok(
  format('select * from public.advance_load_state(%L::uuid, %L::uuid, %L)', '11111111-1111-1111-1111-111111111111', :'load_a_id', 'scheduled'),
  'a manager can schedule a draft'
);
select throws_ok(
  format('select * from public.advance_load_state(%L::uuid, %L::uuid, %L)', '11111111-1111-1111-1111-111111111111', :'load_a_id', 'assigned'),
  '22023',
  'a valid active driver and assigned vehicle are required',
  'a scheduled load without a driver and vehicle cannot become assigned'
);
reset role;
select is(
  (select operational_status from public.loads where id = :'load_a_id'::uuid),
  'scheduled',
  'a failed assignment retains the scheduled state'
);
select ok(
  not exists (
    select 1 from public.audit_events
    where entity_id = :'load_a_id'::uuid
      and after_data ->> 'operationalStatus' = 'assigned'
  ),
  'a failed assignment creates no assigned-state audit event'
);
update public.loads
set assigned_driver_id = :'driver_a_id'::uuid, assigned_vehicle_id = :'vehicle_id'::uuid
where id = :'load_a_id'::uuid;

set local role authenticated;
select set_config('request.jwt.claim.sub', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', true);
select lives_ok(
  format('select * from public.advance_load_state(%L::uuid, %L::uuid, %L)', '11111111-1111-1111-1111-111111111111', :'load_a_id', 'assigned'),
  'a manager can assign a load only after its driver and vehicle are eligible'
);

reset role;
set local role authenticated;
select set_config('request.jwt.claim.sub', '88888888-8888-8888-8888-888888888888', true);
select results_eq('select id from public.loads', array[]::uuid[], 'driver B cannot read driver A''s load in the same company');
select throws_ok(
  format('select * from public.advance_load_state(%L::uuid, %L::uuid, %L)', '11111111-1111-1111-1111-111111111111', :'load_a_id', 'en_route_to_pickup'),
  '42501',
  'driver mutations must use the idempotent sync wrapper',
  'driver B cannot advance driver A''s load'
);
select throws_ok(
  format('select * from public.record_load_evidence(%L::uuid, %L::uuid, %L, %L::jsonb)', '11111111-1111-1111-1111-111111111111', :'load_a_id', 'signature', '{"value":"Driver B"}'),
  '42501',
  'driver mutations must use the idempotent sync wrapper',
  'driver B cannot add evidence to driver A''s load'
);
select throws_ok(
  format('select * from public.report_load_incident(%L::uuid, %L::uuid, %L, %L, %L::jsonb, %L::jsonb)', '11111111-1111-1111-1111-111111111111', :'load_a_id', 'customer_unavailable', 'Driver B is not assigned.', format('["private/11111111-1111-1111-1111-111111111111/loads/%s/evidence/incident.pdf"]', :'load_a_id'), '{"latitude":41.8781,"longitude":-87.6298}'),
  '42501',
  'only an authorized company actor may operate this load',
  'driver B cannot report an incident for driver A''s load'
);
reset role;
select is(
  (select operational_status from public.loads where id = :'load_a_id'::uuid),
  'assigned',
  'driver B denial retains the load state'
);
select is((select count(*) from public.load_evidence where load_id = :'load_a_id'::uuid), 0::bigint, 'driver B denial creates no evidence');
select is((select count(*) from public.load_incidents where load_id = :'load_a_id'::uuid), 0::bigint, 'driver B denial creates no incident');
select ok(
  not exists (
    select 1 from public.audit_events
    where entity_id = :'load_a_id'::uuid
      and after_data ->> 'operationalStatus' = 'en_route_to_pickup'
  ),
  'driver B denial creates no state audit event'
);

set local role authenticated;
select set_config('request.jwt.claim.sub', '99999999-9999-9999-9999-999999999999', true);
select results_eq('select id from public.loads', array[:'load_a_id'::uuid], 'driver A can read only the load assigned to them');
select lives_ok(
  $$select * from public.advance_own_driver_load_state_idempotent(gen_random_uuid())$$,
  'driver A starts operational work only after assignment'
);
select lives_ok($$select * from public.advance_own_driver_load_state_idempotent(gen_random_uuid())$$, 'driver A can arrive at pickup');
select lives_ok($$select * from public.advance_own_driver_load_state_idempotent(gen_random_uuid())$$, 'driver A can begin loading');
select lives_ok($$select * from public.advance_own_driver_load_state_idempotent(gen_random_uuid())$$, 'driver A can confirm pickup');
select lives_ok($$select * from public.advance_own_driver_load_state_idempotent(gen_random_uuid())$$, 'driver A can begin delivery route');
select lives_ok($$select * from public.advance_own_driver_load_state_idempotent(gen_random_uuid())$$, 'driver A can arrive at delivery');
select lives_ok($$select * from public.advance_own_driver_load_state_idempotent(gen_random_uuid())$$, 'driver A can begin unloading');

reset role;
set local role authenticated;
select set_config('request.jwt.claim.sub', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', true);
select lives_ok(
  format('select public.configure_load_evidence_requirements(%L::uuid, %L::uuid, %L::jsonb)', '11111111-1111-1111-1111-111111111111', :'load_a_id', '["signature", "bol", "pod", "delivery_gps"]'),
  'a manager configures non-photo delivery evidence requirements'
);
reset role;
set local role authenticated;
select set_config('request.jwt.claim.sub', '99999999-9999-9999-9999-999999999999', true);
select throws_ok(
  $$select * from public.record_own_driver_load_evidence_idempotent(gen_random_uuid(), 'signature', '{"x":true}'::jsonb)$$,
  '22023', 'valid load evidence is required', 'an arbitrary object is not a valid signature'
);
select throws_ok(
  $$select * from public.record_own_driver_load_evidence_idempotent(gen_random_uuid(), 'bol', '{"x":true}'::jsonb)$$,
  '22023', 'a valid private evidence receipt is required', 'an arbitrary object is not a valid BOL receipt'
);
select throws_ok(
  $$select * from public.record_own_driver_load_evidence_idempotent(gen_random_uuid(), 'pod', '{"x":true}'::jsonb)$$,
  '22023', 'a valid private evidence receipt is required', 'an arbitrary object is not a valid POD receipt'
);
select throws_ok(
  $$select * from public.record_own_driver_load_evidence_idempotent(gen_random_uuid(), 'delivery_gps', '{"x":true}'::jsonb)$$,
  '22023', 'valid load evidence is required', 'an arbitrary object is not valid delivery GPS'
);
select throws_ok(
  $$select * from public.record_own_driver_load_evidence_idempotent(gen_random_uuid(), 'delivery_gps', '{"latitude":91,"longitude":-87.6298}'::jsonb)$$,
  '22023', 'valid load evidence is required', 'delivery GPS outside latitude bounds is rejected'
);
select is((select count(*) from public.load_evidence where load_id = :'load_a_id'::uuid), 0::bigint, 'invalid evidence creates no evidence records');
select throws_ok(
  $$select * from public.advance_own_driver_load_state_idempotent(gen_random_uuid())$$,
  '22023', 'required delivery evidence is incomplete', 'invalid evidence does not unlock delivery'
);
select lives_ok(
  $$select * from public.record_own_driver_load_evidence_idempotent(gen_random_uuid(), 'signature', '{"value":"Receiver signature"}'::jsonb)$$,
  'a non-empty signature value is valid'
);
select lives_ok(
  $$select * from public.record_own_driver_load_evidence_idempotent(gen_random_uuid(), 'bol', '{"receiptKey":"bill"}'::jsonb)$$,
  'a tenant- and load-scoped BOL reference is valid'
);
select lives_ok(
  $$select * from public.record_own_driver_load_evidence_idempotent(gen_random_uuid(), 'pod', '{"receiptKey":"pod"}'::jsonb)$$,
  'a tenant- and load-scoped POD reference is valid'
);
select lives_ok(
  $$select * from public.record_own_driver_load_evidence_idempotent(gen_random_uuid(), 'delivery_gps', '{"latitude":41.8781,"longitude":-87.6298}'::jsonb)$$,
  'delivery GPS with numeric in-range coordinates is valid'
);
select lives_ok(
  $$select * from public.advance_own_driver_load_state_idempotent(gen_random_uuid())$$,
  'delivery succeeds after valid required non-photo evidence'
);

reset role;
set local role authenticated;
select set_config('request.jwt.claim.sub', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', true);
select lives_ok(
  $$select * from public.create_pilot_load(
    '11111111-1111-1111-1111-111111111111'::uuid,
    'SEC-DRIVER-GATE',
    '{"address":"3 Pickup Way","country":"US","timezone":"America/Chicago"}'::jsonb,
    '{"address":"4 Delivery Lane","country":"US","timezone":"America/Chicago"}'::jsonb
  )$$,
  'an owner creates a load to test the driver administrative gate'
);
select id as driver_gate_load_id from public.loads where load_number = 'SEC-DRIVER-GATE' \gset
reset role;
update public.loads
set assigned_driver_id = :'driver_a_id'::uuid, assigned_vehicle_id = :'vehicle_id'::uuid
where id = :'driver_gate_load_id'::uuid;
set local role authenticated;
select set_config('request.jwt.claim.sub', '99999999-9999-9999-9999-999999999999', true);
select throws_ok(
  format('select * from public.advance_load_state(%L::uuid, %L::uuid, %L)', '11111111-1111-1111-1111-111111111111', :'driver_gate_load_id', 'scheduled'),
  '42501', 'driver mutations must use the idempotent sync wrapper', 'a driver cannot schedule an assigned draft'
);
reset role;
select is((select operational_status from public.loads where id = :'driver_gate_load_id'::uuid), 'draft', 'driver administrative denial retains draft state');
select ok(
  not exists (
    select 1 from public.audit_events
    where entity_id = :'driver_gate_load_id'::uuid
      and after_data ->> 'operationalStatus' = 'scheduled'
  ),
  'driver administrative denial creates no state audit event'
);

set local role authenticated;
select set_config('request.jwt.claim.sub', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', true);
select lives_ok(
  $$select * from public.create_pilot_load(
    '11111111-1111-1111-1111-111111111111'::uuid,
    'SEC-INCIDENT',
    '{"address":"5 Pickup Way","country":"US","timezone":"America/Chicago"}'::jsonb,
    '{"address":"6 Delivery Lane","country":"US","timezone":"America/Chicago"}'::jsonb
  )$$,
  'an owner creates the incident load'
);
select id as incident_load_id from public.loads where load_number = 'SEC-INCIDENT' \gset
reset role;
update public.loads
set assigned_driver_id = :'driver_a_id'::uuid, assigned_vehicle_id = :'vehicle_id'::uuid
where id = :'incident_load_id'::uuid;
set local role authenticated;
select set_config('request.jwt.claim.sub', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', true);
select lives_ok(format('select * from public.advance_load_state(%L::uuid, %L::uuid, %L)', '11111111-1111-1111-1111-111111111111', :'incident_load_id', 'scheduled'), 'the incident load is scheduled');
select lives_ok(format('select * from public.advance_load_state(%L::uuid, %L::uuid, %L)', '11111111-1111-1111-1111-111111111111', :'incident_load_id', 'assigned'), 'the incident load is assigned');
select throws_ok(
  format('select * from public.report_load_incident(%L::uuid, %L::uuid, %L, %L, %L::jsonb, %L::jsonb)', '11111111-1111-1111-1111-111111111111', :'incident_load_id', 'customer_unavailable', 'Location is invalid.', '[]', '{"latitude":91,"longitude":-87.6298}'),
  '22023', 'valid incident details are required', 'incident location outside latitude bounds is rejected'
);
select throws_ok(
  format('select * from public.report_load_incident(%L::uuid, %L::uuid, %L, %L, %L::jsonb, %L::jsonb)', '11111111-1111-1111-1111-111111111111', :'incident_load_id', 'customer_unavailable', 'Attachment must stay private.', '["https://example.test/public.pdf"]', '{"latitude":41.8781,"longitude":-87.6298}'),
  '22023', 'valid incident details are required', 'a public incident attachment URL is rejected'
);
select throws_ok(
  format('select * from public.report_load_incident(%L::uuid, %L::uuid, %L, %L, null::jsonb, %L::jsonb)', '11111111-1111-1111-1111-111111111111', :'incident_load_id', 'customer_unavailable', 'Attachment collection is required.', '{"latitude":41.8781,"longitude":-87.6298}'),
  '22023', 'valid incident details are required', 'a null attachment value is not a valid attachment collection'
);
select format('private/11111111-1111-1111-1111-111111111111/loads/%s/evidence/incident.pdf', :'incident_load_id') as incident_attachment \gset
reset role;
insert into storage.objects (bucket_id, name, owner, metadata)
values (
  'carrierflow-private-evidence',
  :'incident_attachment',
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'::uuid,
  '{"mimetype":"application/pdf","size":128}'::jsonb
);
set local role authenticated;
select set_config('request.jwt.claim.sub', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', true);
select throws_ok(
  format(
    $sql$select * from public.report_load_incident(%L::uuid, %L::uuid, 'customer_unavailable', 'Too many attachments.', jsonb_build_array(%L, %L, %L, %L, %L, %L, %L, %L, %L, %L, %L), '{"latitude":41.8781,"longitude":-87.6298}'::jsonb)$sql$,
    '11111111-1111-1111-1111-111111111111',
    :'incident_load_id',
    :'incident_attachment', :'incident_attachment', :'incident_attachment',
    :'incident_attachment', :'incident_attachment', :'incident_attachment',
    :'incident_attachment', :'incident_attachment', :'incident_attachment',
    :'incident_attachment', :'incident_attachment'
  ),
  '22023', 'valid incident details are required', 'an incident cannot include more than ten attachment references'
);
select lives_ok(
  format('select * from public.report_load_incident(%L::uuid, %L::uuid, %L, %L, %L::jsonb, %L::jsonb)', '11111111-1111-1111-1111-111111111111', :'incident_load_id', 'customer_unavailable', 'Receiver asked the driver to wait.', format('["private/11111111-1111-1111-1111-111111111111/loads/%s/evidence/incident.pdf"]', :'incident_load_id'), '{"latitude":41.8781,"longitude":-87.6298}'),
  'a valid private incident is recorded'
);
reset role;
select is((select operational_status from public.loads where id = :'incident_load_id'::uuid), 'assigned', 'a valid incident does not cancel or bypass state');
select is((select count(*) from public.load_incidents where load_id = :'incident_load_id'::uuid), 1::bigint, 'only the valid incident is persisted');

select * from finish();
rollback;
