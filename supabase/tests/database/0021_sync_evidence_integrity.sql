begin;

select plan(8);

\set tenant_fixture_setup true
\ir helpers/tenant-fixtures.sql
\unset tenant_fixture_setup
select test_helpers.seed_tenant_fixtures();

insert into auth.users (
  id, instance_id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at
) values (
  '98989898-9898-9898-9898-989898989898'::uuid,
  '00000000-0000-0000-0000-000000000000'::uuid,
  'authenticated', 'authenticated', 'evidence-integrity-driver@carrierflow.test',
  '$2a$10$not-a-real-password-hash-for-local-tests-only', timezone('utc', now()),
  '{}'::jsonb, '{}'::jsonb, timezone('utc', now()), timezone('utc', now())
);
insert into public.company_memberships (id, company_id, user_id, role, status)
values (
  '52525252-5252-5252-5252-525252525252'::uuid,
  '11111111-1111-1111-1111-111111111111'::uuid,
  '98989898-9898-9898-9898-989898989898'::uuid,
  'driver', 'active'
);

set local role authenticated;
select set_config('request.jwt.claim.sub', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', true);
select * from public.create_driver(
  '11111111-1111-1111-1111-111111111111'::uuid,
  '52525252-5252-5252-5252-525252525252'::uuid,
  'Evidence Integrity Driver'
);
select id as driver_id from public.drivers
where membership_id = '52525252-5252-5252-5252-525252525252'::uuid \gset
select * from public.create_vehicle(
  '11111111-1111-1111-1111-111111111111'::uuid,
  'EVIDENCE-INTEGRITY-UNIT', 'cargo_van', 3500
);
select id as vehicle_id from public.vehicles
where unit_number = 'EVIDENCE-INTEGRITY-UNIT' \gset
select public.assign_driver_vehicle(
  '11111111-1111-1111-1111-111111111111'::uuid,
  :'driver_id'::uuid, :'vehicle_id'::uuid
);
select * from public.create_pilot_load(
  '11111111-1111-1111-1111-111111111111'::uuid,
  'EVIDENCE-INTEGRITY-A',
  '{"address":"1 Pickup Way","country":"US","timezone":"America/Chicago"}'::jsonb,
  '{"address":"2 Delivery Lane","country":"US","timezone":"America/Chicago"}'::jsonb
);
select id as load_id from public.loads
where load_number = 'EVIDENCE-INTEGRITY-A' \gset
reset role;
update public.loads
set assigned_driver_id = :'driver_id'::uuid,
    assigned_vehicle_id = :'vehicle_id'::uuid
where id = :'load_id'::uuid;
insert into storage.objects (bucket_id, name, owner, metadata)
values (
  'carrierflow-private-evidence',
  format('private/11111111-1111-1111-1111-111111111111/loads/%s/evidence/evidence-bol', :'load_id'),
  '98989898-9898-9898-9898-989898989898'::uuid,
  '{"mimetype":"application/pdf","size":128}'::jsonb
);
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
  not has_function_privilege(
    'authenticated',
    'driver_sync_private.normalize_and_record_current_driver_load_evidence(text,jsonb)',
    'execute'
  ),
  'the private evidence normalizer is not RPC-callable by authenticated clients'
);

set local role authenticated;
select set_config('request.jwt.claim.sub', '98989898-9898-9898-9898-989898989898', true);
select throws_ok(
  $$select * from driver_sync_private.normalize_and_record_current_driver_load_evidence(
    'bol', '{"receiptKey":"evidence-bol"}'::jsonb
  )$$,
  '42501', null,
  'the private evidence normalizer cannot be invoked directly'
);
select throws_ok(
  $$select * from public.record_own_driver_load_evidence_idempotent(
    '55555555-5555-4555-8555-555555555555'::uuid,
    'bol', '{"storagePath":"attacker-controlled"}'::jsonb
  )$$,
  '22023', 'a valid private evidence receipt is required',
  'the idempotent wrapper rejects a non-receipt evidence path'
);
select lives_ok(
  $$select * from public.record_own_driver_load_evidence_idempotent(
    '66666666-6666-4666-8666-666666666666'::uuid,
    'bol', '{"receiptKey":"evidence-bol","mimeType":"application/pdf","byteLength":128}'::jsonb
  )$$,
  'the idempotent wrapper accepts a validated opaque evidence receipt'
);
select is(
  (select evidence_value ->> 'storagePath'
   from public.load_evidence
   where load_id = :'load_id'::uuid and evidence_type = 'bol'),
  format('private/11111111-1111-1111-1111-111111111111/loads/%s/evidence/evidence-bol', :'load_id'),
  'the private core receives only a server-derived storage path'
);
select is(
  public.record_own_driver_load_evidence_idempotent(
    '66666666-6666-4666-8666-666666666666'::uuid,
    'bol', '{"receiptKey":"evidence-bol","mimeType":"application/pdf","byteLength":128}'::jsonb
  ) ->> 'evidenceType',
  'bol',
  'a valid evidence retry returns its stored idempotent response'
);
select is(
  (select count(*) from public.load_evidence
   where load_id = :'load_id'::uuid and evidence_type = 'bol'),
  1::bigint,
  'a valid evidence replay creates one evidence row'
);
select ok(
  has_function_privilege(
    'authenticated',
    'public.record_own_driver_load_evidence_idempotent(uuid,text,jsonb)',
    'execute'
  ),
  'authenticated callers retain only the idempotent evidence entry point'
);

select * from finish();
rollback;
