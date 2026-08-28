begin;

select plan(23);

\set tenant_fixture_setup true
\ir helpers/tenant-fixtures.sql
\unset tenant_fixture_setup
select test_helpers.seed_tenant_fixtures();

insert into auth.users (
  id, instance_id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at
) values (
  '99999999-9999-9999-9999-999999999991'::uuid,
  '00000000-0000-0000-0000-000000000000'::uuid,
  'authenticated', 'authenticated', 'routing-driver-a@carrierflow.test',
  '$2a$10$not-a-real-password-hash-for-local-tests-only', timezone('utc', now()),
  '{}'::jsonb, '{}'::jsonb, timezone('utc', now()), timezone('utc', now())
);

insert into public.company_memberships (id, company_id, user_id, role, status) values (
  '41414141-4141-4141-4141-414141414141'::uuid,
  '11111111-1111-1111-1111-111111111111'::uuid,
  '99999999-9999-9999-9999-999999999991'::uuid,
  'driver', 'active'
);

set local role authenticated;
select set_config('request.jwt.claim.sub', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', true);
select lives_ok(
  $$select * from public.create_driver(
    '11111111-1111-1111-1111-111111111111'::uuid,
    '41414141-4141-4141-4141-414141414141'::uuid,
    'Routing Driver A'
  )$$,
  'an owner creates the driver used for continuous routing'
);
select id as driver_id from public.drivers
where membership_id = '41414141-4141-4141-4141-414141414141'::uuid \gset
select lives_ok(
  $$select * from public.create_vehicle(
    '11111111-1111-1111-1111-111111111111'::uuid,
    'ROUTE-100', 'cargo_van', 3500
  )$$,
  'an owner creates the active routing vehicle'
);
select id as vehicle_id from public.vehicles where unit_number = 'ROUTE-100' \gset
select lives_ok(
  format(
    'select * from public.assign_driver_vehicle(%L::uuid, %L::uuid, %L::uuid)',
    '11111111-1111-1111-1111-111111111111', :'driver_id', :'vehicle_id'
  ),
  'an owner assigns the routing vehicle to the driver'
);
select lives_ok(
  $$select * from public.create_pilot_load(
    '11111111-1111-1111-1111-111111111111'::uuid,
    'ROUTE-ACTIVE',
    '{"address":"1 Active Pickup Way","country":"US","timezone":"America/Chicago"}'::jsonb,
    '{"address":"2 Active Final Delivery Way","country":"US","timezone":"America/Chicago"}'::jsonb
  )$$,
  'an owner creates the active load that supplies the planned origin'
);
select id as active_load_id from public.loads where load_number = 'ROUTE-ACTIVE' \gset
reset role;
update public.loads
set assigned_driver_id = :'driver_id'::uuid, assigned_vehicle_id = :'vehicle_id'::uuid
where id = :'active_load_id'::uuid;
set local role authenticated;
select set_config('request.jwt.claim.sub', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', true);
select lives_ok(
  format('select * from public.advance_load_state(%L::uuid, %L::uuid, %L)', '11111111-1111-1111-1111-111111111111', :'active_load_id', 'scheduled'),
  'the active load is scheduled'
);
select lives_ok(
  format('select * from public.advance_load_state(%L::uuid, %L::uuid, %L)', '11111111-1111-1111-1111-111111111111', :'active_load_id', 'assigned'),
  'the active load is assigned'
);
select id as active_final_stop_id from public.load_stops
where load_id = :'active_load_id'::uuid order by sequence desc limit 1 \gset
select lives_ok(
  $$select * from public.create_pilot_load(
    '11111111-1111-1111-1111-111111111111'::uuid,
    'ROUTE-NEXT',
    '{"address":"3 Next Pickup Way","country":"US","timezone":"America/Chicago"}'::jsonb,
    '{"address":"4 Next Delivery Way","country":"US","timezone":"America/Chicago"}'::jsonb
  )$$,
  'an owner creates the next proposed load'
);
select id as next_load_id from public.loads where load_number = 'ROUTE-NEXT' \gset

-- 0009 retires this direct persistence RPC for application clients. Keep this
-- legacy-history fixture privileged so 0008's immutable-revision assertions
-- remain covered; all unprivileged app writes use the 0009 job boundary.
reset role;
select lives_ok(
  format(
    $sql$select * from public.persist_route_estimate_revision(
      '11111111-1111-1111-1111-111111111111'::uuid, %L::uuid, %L::uuid,
      12.500, 87.500, 250.00, 'test-routing',
      '{"empty":{"distanceMeters":20116},"loaded":{"distanceMeters":140817}}'::jsonb,
      'active_load_final_stop', %L::uuid, 'initial'
    )$sql$,
    :'next_load_id', :'driver_id', :'active_final_stop_id'
  ),
  'a dispatcher persists the first route estimate revision'
);
select is(
  (select empty_miles from public.route_estimate_revisions where load_id = :'next_load_id'::uuid and revision_number = 1),
  12.500::numeric,
  'empty miles persist as a separate decimal value'
);
select is(
  (select loaded_miles from public.route_estimate_revisions where load_id = :'next_load_id'::uuid and revision_number = 1),
  87.500::numeric,
  'loaded miles persist as a separate decimal value'
);
select is(
  (select total_miles from public.route_estimate_revisions where load_id = :'next_load_id'::uuid and revision_number = 1),
  100.000::numeric,
  'total miles are calculated separately without floating-point money'
);
select is(
  (select quote_usd_per_total_mile from public.route_estimate_revisions where load_id = :'next_load_id'::uuid and revision_number = 1),
  2.5::numeric,
  'quoted USD per total mile is stored as an exact decimal division'
);
select is(
  (select empty_origin_stop_id from public.route_estimate_revisions where load_id = :'next_load_id'::uuid and revision_number = 1),
  :'active_final_stop_id'::uuid,
  'the active load final planned stop, rather than GPS, is the persisted empty-mile origin'
);
select throws_ok(
  format(
    $sql$select * from public.persist_route_estimate_revision(
      '11111111-1111-1111-1111-111111111111'::uuid, %L::uuid, %L::uuid,
      1, 2, 6.00, 'test-routing', '{}'::jsonb,
      'last_accepted_location', null, 'assignment_changed'
    )$sql$,
    :'next_load_id', :'driver_id'
  ),
  '22023',
  'the active load final stop must be the empty-mile origin',
  'live GPS or a fallback origin cannot replace the active load final planned stop'
);
select lives_ok(
  format(
    $sql$select * from public.persist_route_estimate_revision(
      '11111111-1111-1111-1111-111111111111'::uuid, %L::uuid, %L::uuid,
      15.000, 85.000, 260.00, 'test-routing',
      '{"empty":{"distanceMeters":24140},"loaded":{"distanceMeters":136794}}'::jsonb,
      'active_load_final_stop', %L::uuid, 'active_final_stop_changed'
    )$sql$,
    :'next_load_id', :'driver_id', :'active_final_stop_id'
  ),
  'a changed planned context persists a replacement route revision'
);
select is(
  (select max(revision_number) from public.route_estimate_revisions where load_id = :'next_load_id'::uuid),
  2,
  'the replacement is an immutable sequential revision'
);
select ok(
  exists (
    select 1 from public.route_estimate_invalidations
    where load_id = :'next_load_id'::uuid and reason = 'active_final_stop_changed'
  ),
  'the prior revision has an append-only invalidation record'
);
select ok(
  exists (
    select 1 from public.route_estimate_notifications
    where load_id = :'next_load_id'::uuid and notification_type = 'route_estimate_invalidated'
  ),
  'the revision invalidation creates a minimal dispatcher notification'
);
select ok(
  exists (
    select 1 from public.audit_events
    where entity_id = :'next_load_id'::uuid and action = 'route_estimate.invalidated'
  ),
  'the revision invalidation is auditable with the actor and before/after values'
);
reset role;
set local role authenticated;
select set_config('request.jwt.claim.sub', '99999999-9999-9999-9999-999999999991', true);
select results_eq(
  'select id from public.route_estimate_revisions',
  array[]::uuid[],
  'a driver cannot read dispatcher-only rate and route revision data'
);
select throws_ok(
  format(
    $sql$select * from public.persist_route_estimate_revision(
      '11111111-1111-1111-1111-111111111111'::uuid, %L::uuid, %L::uuid,
      12.500, 87.500, 250.00, 'test-routing', '{}'::jsonb,
      'active_load_final_stop', %L::uuid, 'driver_changed'
    )$sql$,
    :'next_load_id', :'driver_id', :'active_final_stop_id'
  ),
  '42501',
  'permission denied for function persist_route_estimate_revision',
  'a driver cannot invoke the retired direct route-estimate persistence boundary'
);
reset role;
set local role authenticated;
select set_config('request.jwt.claim.sub', 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', true);
select results_eq(
  'select id from public.route_estimate_revisions',
  array[]::uuid[],
  'another company cannot read this tenant''s route estimates through RLS'
);
select ok(
  not has_table_privilege('authenticated', 'public.route_estimate_revisions', 'UPDATE'),
  'authenticated clients cannot mutate immutable route revisions directly'
);

select * from finish();
rollback;
