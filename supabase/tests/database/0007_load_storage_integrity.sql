begin;

select plan(38);

\set tenant_fixture_setup true
\ir helpers/tenant-fixtures.sql
\unset tenant_fixture_setup
select test_helpers.seed_tenant_fixtures();

insert into auth.users (
  id, instance_id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at
) values
  ('99999999-9999-9999-9999-999999999999'::uuid, '00000000-0000-0000-0000-000000000000'::uuid, 'authenticated', 'authenticated', 'storage-driver-a@carrierflow.test', '$2a$10$not-a-real-password-hash-for-local-tests-only', timezone('utc', now()), '{}'::jsonb, '{}'::jsonb, timezone('utc', now()), timezone('utc', now())),
  ('88888888-8888-8888-8888-888888888888'::uuid, '00000000-0000-0000-0000-000000000000'::uuid, 'authenticated', 'authenticated', 'storage-driver-b@carrierflow.test', '$2a$10$not-a-real-password-hash-for-local-tests-only', timezone('utc', now()), '{}'::jsonb, '{}'::jsonb, timezone('utc', now()), timezone('utc', now()));

insert into public.company_memberships (id, company_id, user_id, role, status) values
  ('41414141-4141-4141-4141-414141414141'::uuid, '11111111-1111-1111-1111-111111111111'::uuid, '99999999-9999-9999-9999-999999999999'::uuid, 'driver', 'active'),
  ('51515151-5151-5151-5151-515151515151'::uuid, '11111111-1111-1111-1111-111111111111'::uuid, '88888888-8888-8888-8888-888888888888'::uuid, 'driver', 'active');

reset role;
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'carrierflow-private-evidence',
  'CarrierFlow private evidence',
  false,
  10485760,
  array['application/pdf', 'image/heic', 'image/jpeg', 'image/png', 'image/webp']::text[]
)
on conflict (id) do nothing;

set local role authenticated;
select set_config('request.jwt.claim.sub', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', true);
select lives_ok(
  $$select * from public.create_driver('11111111-1111-1111-1111-111111111111'::uuid, '41414141-4141-4141-4141-414141414141'::uuid, 'Storage Driver A')$$,
  'an owner creates the evidence driver'
);
select id as driver_a_id from public.drivers where membership_id = '41414141-4141-4141-4141-414141414141'::uuid \gset
select lives_ok(
  $$select * from public.create_driver('11111111-1111-1111-1111-111111111111'::uuid, '51515151-5151-5151-5151-515151515151'::uuid, 'Storage Driver B')$$,
  'an owner creates the second driver'
);
select lives_ok(
  $$select * from public.create_vehicle('11111111-1111-1111-1111-111111111111'::uuid, 'STORAGE-SEC', 'cargo_van', 3500)$$,
  'an owner creates the assigned vehicle'
);
select id as vehicle_id from public.vehicles where unit_number = 'STORAGE-SEC' \gset
select lives_ok(
  format('select * from public.assign_driver_vehicle(%L::uuid, %L::uuid, %L::uuid)', '11111111-1111-1111-1111-111111111111', :'driver_a_id', :'vehicle_id'),
  'the active vehicle is assigned to driver A'
);
select lives_ok(
  $$select * from public.create_pilot_load(
    '11111111-1111-1111-1111-111111111111'::uuid,
    'STORAGE-LOAD-A',
    '{"address":"1 Pickup Way","country":"US","timezone":"America/Chicago"}'::jsonb,
    '{"address":"2 Delivery Lane","country":"US","timezone":"America/Chicago"}'::jsonb
  )$$,
  'an owner creates the protected storage load'
);
select id as load_a_id from public.loads where load_number = 'STORAGE-LOAD-A' \gset
reset role;
update public.loads
set assigned_driver_id = :'driver_a_id'::uuid, assigned_vehicle_id = :'vehicle_id'::uuid
where id = :'load_a_id'::uuid;
set local role authenticated;
select set_config('request.jwt.claim.sub', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', true);
select lives_ok(format('select * from public.advance_load_state(%L::uuid, %L::uuid, %L)', '11111111-1111-1111-1111-111111111111', :'load_a_id', 'scheduled'), 'the load is scheduled');
select lives_ok(format('select * from public.advance_load_state(%L::uuid, %L::uuid, %L)', '11111111-1111-1111-1111-111111111111', :'load_a_id', 'assigned'), 'the load is assigned');

reset role;
set local role authenticated;
select set_config('request.jwt.claim.sub', '99999999-9999-9999-9999-999999999999', true);
select lives_ok($$select * from public.advance_own_driver_load_state_idempotent(gen_random_uuid())$$, 'driver A starts the route');
select lives_ok($$select * from public.advance_own_driver_load_state_idempotent(gen_random_uuid())$$, 'driver A arrives at pickup');
select lives_ok($$select * from public.advance_own_driver_load_state_idempotent(gen_random_uuid())$$, 'driver A begins loading');
select lives_ok($$select * from public.advance_own_driver_load_state_idempotent(gen_random_uuid())$$, 'driver A confirms pickup');
select lives_ok($$select * from public.advance_own_driver_load_state_idempotent(gen_random_uuid())$$, 'driver A starts delivery');
select lives_ok($$select * from public.advance_own_driver_load_state_idempotent(gen_random_uuid())$$, 'driver A arrives at delivery');
select lives_ok($$select * from public.advance_own_driver_load_state_idempotent(gen_random_uuid())$$, 'driver A begins unloading');

reset role;
set local role authenticated;
select set_config('request.jwt.claim.sub', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', true);
select lives_ok(
  format('select public.configure_load_evidence_requirements(%L::uuid, %L::uuid, %L::jsonb)', '11111111-1111-1111-1111-111111111111', :'load_a_id', '["signature", "bol", "pod", "delivery_gps"]'),
  'a manager requires signature, BOL, POD and delivery GPS'
);
reset role;
set local role authenticated;
select set_config('request.jwt.claim.sub', '99999999-9999-9999-9999-999999999999', true);
select lives_ok(
  $$select * from public.record_own_driver_load_evidence_idempotent(gen_random_uuid(), 'signature', '{"value":"Receiver signature"}'::jsonb)$$,
  'a valid signature is recorded'
);
select lives_ok(
  $$select * from public.record_own_driver_load_evidence_idempotent(gen_random_uuid(), 'delivery_gps', '{"latitude":41.8781,"longitude":-87.6298}'::jsonb)$$,
  'valid delivery GPS is recorded'
);
select format('private/11111111-1111-1111-1111-111111111111/loads/%s/evidence/missing_bol', :'load_a_id') as missing_bol_path \gset
select throws_ok(
  $$select * from public.record_own_driver_load_evidence_idempotent(gen_random_uuid(), 'bol', '{"receiptKey":"missing_bol"}'::jsonb)$$,
  '22023', 'valid load evidence is required', 'a correctly-prefixed but nonexistent BOL object is rejected'
);
select throws_ok(
  $$select * from public.advance_own_driver_load_state_idempotent(gen_random_uuid())$$,
  '22023', 'required delivery evidence is incomplete', 'a nonexistent BOL keeps delivery blocked'
);

reset role;
insert into storage.objects (bucket_id, name, owner, metadata)
values (
  'carrierflow-private-evidence',
  :'missing_bol_path',
  '88888888-8888-8888-8888-888888888888'::uuid,
  '{"mimetype":"application/pdf","size":128}'::jsonb
);
set local role authenticated;
select set_config('request.jwt.claim.sub', '99999999-9999-9999-9999-999999999999', true);
select throws_ok(
  $$select * from public.record_own_driver_load_evidence_idempotent(gen_random_uuid(), 'bol', '{"receiptKey":"missing_bol"}'::jsonb)$$,
  '22023', 'valid load evidence is required', 'a BOL owned by another actor is rejected'
);

reset role;
set local role authenticated;
select set_config('request.jwt.claim.sub', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', true);
select lives_ok(
  $$select * from public.create_pilot_load(
    '11111111-1111-1111-1111-111111111111'::uuid,
    'STORAGE-OTHER-LOAD',
    '{"address":"3 Pickup Way","country":"US","timezone":"America/Chicago"}'::jsonb,
    '{"address":"4 Delivery Lane","country":"US","timezone":"America/Chicago"}'::jsonb
  )$$,
  'an owner creates another load for path isolation'
);
select id as other_load_id from public.loads where load_number = 'STORAGE-OTHER-LOAD' \gset
select format('private/11111111-1111-1111-1111-111111111111/loads/%s/evidence/other_load', :'other_load_id') as other_load_path \gset
reset role;
insert into storage.objects (bucket_id, name, owner, metadata)
values (
  'carrierflow-private-evidence',
  :'other_load_path',
  '99999999-9999-9999-9999-999999999999'::uuid,
  '{"mimetype":"application/pdf","size":128}'::jsonb
);
set local role authenticated;
select set_config('request.jwt.claim.sub', '99999999-9999-9999-9999-999999999999', true);
select throws_ok(
  $$select * from public.record_own_driver_load_evidence_idempotent(gen_random_uuid(), 'bol', '{"receiptKey":"other_load"}'::jsonb)$$,
  '22023', 'valid load evidence is required', 'a BOL object for another load is rejected'
);
select format('private/11111111-1111-1111-1111-111111111111/loads/%s/evidence/wrong_type', :'load_a_id') as wrong_type_path \gset
reset role;
insert into storage.objects (bucket_id, name, owner, metadata)
values (
  'carrierflow-private-evidence',
  :'wrong_type_path',
  '99999999-9999-9999-9999-999999999999'::uuid,
  '{"mimetype":"text/plain","size":128}'::jsonb
);
set local role authenticated;
select set_config('request.jwt.claim.sub', '99999999-9999-9999-9999-999999999999', true);
select throws_ok(
  $$select * from public.record_own_driver_load_evidence_idempotent(gen_random_uuid(), 'bol', '{"receiptKey":"wrong_type"}'::jsonb)$$,
  '22023', 'valid load evidence is required', 'a BOL object with a disallowed MIME type is rejected'
);
select is((select count(*) from public.load_evidence where load_id = :'load_a_id'::uuid), 2::bigint, 'invalid storage references create no evidence');

select format('private/11111111-1111-1111-1111-111111111111/loads/%s/evidence/bill', :'load_a_id') as valid_bol_path \gset
select format('private/11111111-1111-1111-1111-111111111111/loads/%s/evidence/pod', :'load_a_id') as valid_pod_path \gset
reset role;
insert into storage.objects (bucket_id, name, owner, metadata)
values
  ('carrierflow-private-evidence', :'valid_bol_path', '99999999-9999-9999-9999-999999999999'::uuid, '{"mimetype":"application/pdf","size":128}'::jsonb),
  ('carrierflow-private-evidence', :'valid_pod_path', '99999999-9999-9999-9999-999999999999'::uuid, '{"mimetype":"application/pdf","size":128}'::jsonb);
set local role authenticated;
select set_config('request.jwt.claim.sub', '99999999-9999-9999-9999-999999999999', true);
select lives_ok(
  $$select * from public.record_own_driver_load_evidence_idempotent(gen_random_uuid(), 'bol', '{"receiptKey":"bill"}'::jsonb)$$,
  'an existing private BOL object owned by the driver is recorded'
);
select lives_ok(
  $$select * from public.record_own_driver_load_evidence_idempotent(gen_random_uuid(), 'pod', '{"receiptKey":"pod"}'::jsonb)$$,
  'an existing private POD object owned by the driver is recorded'
);
reset role;
update storage.objects
set archived_at = timezone('utc', now())
where bucket_id = 'carrierflow-private-evidence'
  and name = :'valid_bol_path';
set local role authenticated;
select set_config('request.jwt.claim.sub', '99999999-9999-9999-9999-999999999999', true);
select throws_ok(
  $$select * from public.advance_own_driver_load_state_idempotent(gen_random_uuid())$$,
  '22023', 'required delivery evidence is incomplete', 'delivery is re-blocked when previously valid BOL is archived'
);
reset role;
select is((select operational_status from public.loads where id = :'load_a_id'::uuid), 'unloading', 'archived evidence does not advance the load state');

set local role authenticated;
select set_config('request.jwt.claim.sub', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', true);
select lives_ok(
  $$select * from public.create_pilot_load(
    '11111111-1111-1111-1111-111111111111'::uuid,
    'STORAGE-INCIDENT',
    '{"address":"5 Pickup Way","country":"US","timezone":"America/Chicago"}'::jsonb,
    '{"address":"6 Delivery Lane","country":"US","timezone":"America/Chicago"}'::jsonb
  )$$,
  'an owner creates an active incident load'
);
select id as incident_load_id from public.loads where load_number = 'STORAGE-INCIDENT' \gset
reset role;
update public.loads
set assigned_driver_id = :'driver_a_id'::uuid, assigned_vehicle_id = :'vehicle_id'::uuid
where id = :'incident_load_id'::uuid;
set local role authenticated;
select set_config('request.jwt.claim.sub', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', true);
select lives_ok(format('select * from public.advance_load_state(%L::uuid, %L::uuid, %L)', '11111111-1111-1111-1111-111111111111', :'incident_load_id', 'scheduled'), 'the incident load is scheduled');
select lives_ok(format('select * from public.advance_load_state(%L::uuid, %L::uuid, %L)', '11111111-1111-1111-1111-111111111111', :'incident_load_id', 'assigned'), 'the incident load is assigned');
select format('private/11111111-1111-1111-1111-111111111111/loads/%s/evidence/missing-incident.pdf', :'incident_load_id') as missing_incident_path \gset
reset role;
set local role authenticated;
select set_config('request.jwt.claim.sub', '99999999-9999-9999-9999-999999999999', true);
select throws_ok(
  format('select * from public.report_load_incident(%L::uuid, %L::uuid, %L, %L, %L::jsonb, %L::jsonb)', '11111111-1111-1111-1111-111111111111', :'incident_load_id', 'customer_unavailable', 'Missing attachment must fail.', format('["%s"]', :'missing_incident_path'), '{"latitude":41.8781,"longitude":-87.6298}'),
  '22023', 'valid incident details are required', 'a correctly-prefixed but nonexistent incident attachment is rejected'
);
reset role;
insert into storage.objects (bucket_id, name, owner, metadata)
values ('carrierflow-private-evidence', :'missing_incident_path', '99999999-9999-9999-9999-999999999999'::uuid, '{"mimetype":"application/pdf","size":128}'::jsonb);
set local role authenticated;
select set_config('request.jwt.claim.sub', '99999999-9999-9999-9999-999999999999', true);
select lives_ok(
  format('select * from public.report_load_incident(%L::uuid, %L::uuid, %L, %L, %L::jsonb, %L::jsonb)', '11111111-1111-1111-1111-111111111111', :'incident_load_id', 'customer_unavailable', 'Private attachment is stored.', format('["%s"]', :'missing_incident_path'), '{"latitude":41.8781,"longitude":-87.6298}'),
  'an existing private incident attachment is recorded'
);
reset role;
select is((select operational_status from public.loads where id = :'incident_load_id'::uuid), 'assigned', 'a valid incident leaves the active load state unchanged');
select is((select public from storage.buckets where id = 'carrierflow-private-evidence'), false, 'the evidence bucket is private');
select ok(exists (select 1 from pg_policies where schemaname = 'storage' and tablename = 'objects' and policyname = 'carrierflow_evidence_select_authorized_load'), 'the private evidence bucket has a scoped select policy');
select ok(exists (select 1 from pg_policies where schemaname = 'storage' and tablename = 'objects' and policyname = 'carrierflow_evidence_insert_authorized_load'), 'the private evidence bucket has a scoped upload policy');

set local role authenticated;
select set_config('request.jwt.claim.sub', '88888888-8888-8888-8888-888888888888', true);
select results_eq(
  format('select name from storage.objects where bucket_id = %L and name = %L', 'carrierflow-private-evidence', :'valid_bol_path'),
  array[]::text[],
  'driver B cannot enumerate driver A storage objects'
);

select * from finish();
rollback;
