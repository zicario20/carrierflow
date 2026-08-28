begin;

select plan(31);

\set tenant_fixture_setup true
\ir helpers/tenant-fixtures.sql
\unset tenant_fixture_setup
select test_helpers.seed_tenant_fixtures();

insert into auth.users (
  id, instance_id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at
) values
  ('99999999-9999-9999-9999-999999999999'::uuid, '00000000-0000-0000-0000-000000000000'::uuid, 'authenticated', 'authenticated', 'driver-a@carrierflow.test', '$2a$10$not-a-real-password-hash-for-local-tests-only', timezone('utc', now()), '{}'::jsonb, '{}'::jsonb, timezone('utc', now()), timezone('utc', now()));

insert into public.company_memberships (id, company_id, user_id, role, status) values
  ('41414141-4141-4141-4141-414141414141'::uuid, '11111111-1111-1111-1111-111111111111'::uuid, '99999999-9999-9999-9999-999999999999'::uuid, 'driver', 'active');

set local role authenticated;
select set_config('request.jwt.claim.sub', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', true);
select lives_ok(
  $$select * from public.create_driver(
    '11111111-1111-1111-1111-111111111111'::uuid,
    '41414141-4141-4141-4141-414141414141'::uuid,
    'Driver A'
  )$$,
  'an owner creates the active driver used by the load domain'
);
select id as driver_id from public.drivers where membership_id = '41414141-4141-4141-4141-414141414141'::uuid \gset
select lives_ok(
  $$select * from public.create_vehicle('11111111-1111-1111-1111-111111111111'::uuid, 'LOAD-100-VEHICLE', 'cargo_van', 3500)$$,
  'an owner creates the active vehicle used by the load domain'
);
select id as vehicle_id from public.vehicles where unit_number = 'LOAD-100-VEHICLE' \gset
select lives_ok(
  format('select * from public.assign_driver_vehicle(%L::uuid, %L::uuid, %L::uuid)', '11111111-1111-1111-1111-111111111111', :'driver_id', :'vehicle_id'),
  'an owner pairs the active driver and vehicle for load assignment'
);
select lives_ok(
  $$select * from public.create_pilot_load(
    '11111111-1111-1111-1111-111111111111'::uuid,
    'LOAD-100',
    '{"businessName":"Chicago Pickup","address":"1 Pickup Way","country":"US","timezone":"America/Chicago"}'::jsonb,
    '{"businessName":"Toronto Delivery","address":"2 Delivery Lane","country":"CA","timezone":"America/Toronto"}'::jsonb
  )$$,
  'an owner creates a pilot load with one pickup and one delivery'
);
select id as load_id from public.loads where load_number = 'LOAD-100' \gset
reset role;
insert into storage.objects (bucket_id, name, owner, metadata)
values (
  'carrierflow-private-evidence',
  format('private/11111111-1111-1111-1111-111111111111/loads/%s/evidence/bol.pdf', :'load_id'),
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'::uuid,
  '{"mimetype":"application/pdf","size":128}'::jsonb
);
update public.loads
set assigned_driver_id = :'driver_id'::uuid, assigned_vehicle_id = :'vehicle_id'::uuid
where id = :'load_id'::uuid;
set local role authenticated;
select set_config('request.jwt.claim.sub', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', true);
select results_eq(
  format($sql$select stop_type::text || ':' || sequence::text from public.load_stops where load_id = %L::uuid order by sequence$sql$, :'load_id'),
  array['pickup:1'::text, 'delivery:2'::text],
  'the pilot load persists exactly ordered pickup and delivery stops'
);
select is(
  (select operational_status from public.loads where id = :'load_id'::uuid),
  'draft',
  'a newly created pilot load begins as a dispatch-owned draft'
);
select throws_ok(
  format('select * from public.advance_load_state(%L::uuid, %L::uuid, %L)', '11111111-1111-1111-1111-111111111111', :'load_id', 'delivered'),
  '22023',
  'the requested load state transition is not allowed',
  'delivery before pickup is rejected by the server'
);
reset role;
select is(
  (select operational_status from public.loads where id = :'load_id'::uuid),
  'draft',
  'a rejected transition retains the prior load state'
);

set local role authenticated;
select set_config('request.jwt.claim.sub', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', true);
select lives_ok(format('select * from public.advance_load_state(%L::uuid, %L::uuid, %L)', '11111111-1111-1111-1111-111111111111', :'load_id', 'scheduled'), 'the server allows a dispatcher to schedule a draft');
select lives_ok(format('select * from public.advance_load_state(%L::uuid, %L::uuid, %L)', '11111111-1111-1111-1111-111111111111', :'load_id', 'assigned'), 'the server allows mandatory assignment after scheduling');
select lives_ok(format('select * from public.advance_load_state(%L::uuid, %L::uuid, %L)', '11111111-1111-1111-1111-111111111111', :'load_id', 'en_route_to_pickup'), 'the server allows the first ordered transition');
select lives_ok(format('select * from public.advance_load_state(%L::uuid, %L::uuid, %L)', '11111111-1111-1111-1111-111111111111', :'load_id', 'arrived_pickup'), 'the server allows arrival at pickup');
select lives_ok(format('select * from public.advance_load_state(%L::uuid, %L::uuid, %L)', '11111111-1111-1111-1111-111111111111', :'load_id', 'loading'), 'the server allows loading');
select lives_ok(format('select * from public.advance_load_state(%L::uuid, %L::uuid, %L)', '11111111-1111-1111-1111-111111111111', :'load_id', 'picked_up'), 'the server records pickup before delivery');
select lives_ok(format('select * from public.advance_load_state(%L::uuid, %L::uuid, %L)', '11111111-1111-1111-1111-111111111111', :'load_id', 'en_route_to_delivery'), 'the server allows transport after pickup');
select lives_ok(format('select * from public.advance_load_state(%L::uuid, %L::uuid, %L)', '11111111-1111-1111-1111-111111111111', :'load_id', 'arrived_delivery'), 'the server allows delivery arrival');
select lives_ok(format('select * from public.advance_load_state(%L::uuid, %L::uuid, %L)', '11111111-1111-1111-1111-111111111111', :'load_id', 'unloading'), 'the server allows unloading');
select lives_ok(
  format('select public.configure_load_evidence_requirements(%L::uuid, %L::uuid, %L::jsonb)', '11111111-1111-1111-1111-111111111111', :'load_id', '["photo", "signature", "bol"]'),
  'an owner configures delivery evidence requirements'
);
select throws_ok(
  format('select * from public.advance_load_state(%L::uuid, %L::uuid, %L)', '11111111-1111-1111-1111-111111111111', :'load_id', 'delivered'),
  '22023',
  'required delivery evidence is incomplete',
  'required non-photo evidence blocks delivery'
);
select lives_ok(
  format('select * from public.record_load_evidence(%L::uuid, %L::uuid, %L, %L::jsonb)', '11111111-1111-1111-1111-111111111111', :'load_id', 'signature', '{"value":"Receiver signature"}'),
  'a valid signature is recorded as load evidence'
);
select lives_ok(
  format('select * from public.record_load_evidence(%L::uuid, %L::uuid, %L, %L::jsonb)', '11111111-1111-1111-1111-111111111111', :'load_id', 'bol', format('{"storagePath":"private/11111111-1111-1111-1111-111111111111/loads/%s/evidence/bol.pdf"}', :'load_id')),
  'a valid BOL is recorded as load evidence'
);
select lives_ok(
  format('select * from public.advance_load_state(%L::uuid, %L::uuid, %L)', '11111111-1111-1111-1111-111111111111', :'load_id', 'delivered'),
  'delivery succeeds after required non-photo evidence is complete without a photo'
);
reset role;
select ok(
  exists (select 1 from public.audit_events where action = 'load.delivered' and entity_id = :'load_id'::uuid),
  'the delivered state transition is audited'
);

set local role authenticated;
select set_config('request.jwt.claim.sub', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', true);
select lives_ok(
  $$select * from public.create_pilot_load(
    '11111111-1111-1111-1111-111111111111'::uuid,
    'LOAD-INCIDENT',
    '{"businessName":"Dallas Pickup","address":"3 Pickup Way","country":"US","timezone":"America/Chicago"}'::jsonb,
    '{"businessName":"Houston Delivery","address":"4 Delivery Lane","country":"US","timezone":"America/Chicago"}'::jsonb
  )$$,
  'an owner creates an active load for incident reporting'
);
select id as incident_load_id from public.loads where load_number = 'LOAD-INCIDENT' \gset
reset role;
insert into storage.objects (bucket_id, name, owner, metadata)
values (
  'carrierflow-private-evidence',
  format('private/11111111-1111-1111-1111-111111111111/loads/%s/evidence/incident.pdf', :'incident_load_id'),
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'::uuid,
  '{"mimetype":"application/pdf","size":128}'::jsonb
);
update public.loads
set assigned_driver_id = :'driver_id'::uuid, assigned_vehicle_id = :'vehicle_id'::uuid
where id = :'incident_load_id'::uuid;
set local role authenticated;
select set_config('request.jwt.claim.sub', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', true);
select lives_ok(
  format('select * from public.advance_load_state(%L::uuid, %L::uuid, %L)', '11111111-1111-1111-1111-111111111111', :'incident_load_id', 'scheduled'),
  'the incident fixture load is scheduled before operations begin'
);
select lives_ok(
  format('select * from public.advance_load_state(%L::uuid, %L::uuid, %L)', '11111111-1111-1111-1111-111111111111', :'incident_load_id', 'assigned'),
  'the incident fixture load is assigned before the problem is reported'
);
select lives_ok(
  format('select * from public.report_load_incident(%L::uuid, %L::uuid, %L, %L, %L::jsonb, %L::jsonb)', '11111111-1111-1111-1111-111111111111', :'incident_load_id', 'customer_unavailable', 'Receiver asked the driver to wait.', format('["private/11111111-1111-1111-1111-111111111111/loads/%s/evidence/incident.pdf"]', :'incident_load_id'), '{"latitude":41.8781,"longitude":-87.6298}'),
  'an incident records its type, text, private attachment path and location'
);
reset role;
select is(
  (select operational_status from public.loads where id = :'incident_load_id'::uuid),
  'assigned',
  'reporting an incident does not cancel or bypass the active load state'
);
select ok(
  exists (
    select 1 from public.load_incidents
    where load_id = :'incident_load_id'::uuid
      and incident_type = 'customer_unavailable'
      and attachments = format('["private/11111111-1111-1111-1111-111111111111/loads/%s/evidence/incident.pdf"]', :'incident_load_id')::jsonb
  ),
  'incident fields are retained privately with the load'
);

set local role authenticated;
select set_config('request.jwt.claim.sub', 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', true);
select results_eq('select id from public.loads', array[]::uuid[], 'another company cannot read this tenant''s loads through RLS');
select throws_ok(
  format('select * from public.advance_load_state(%L::uuid, %L::uuid, %L)', '11111111-1111-1111-1111-111111111111', :'incident_load_id', 'en_route_to_pickup'),
  '42501',
  'only an authorized company actor may operate this load',
  'another company cannot mutate a load through the RPC'
);

reset role;
select * from finish();
rollback;
