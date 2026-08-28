begin;

select no_plan();

\set tenant_fixture_setup true
\ir helpers/tenant-fixtures.sql
\unset tenant_fixture_setup
select test_helpers.seed_tenant_fixtures();

-- Test-only privileged inspector. Production authenticated sessions no longer
-- receive route-job idempotency or lease columns directly after 0012.
create view test_helpers.route_estimate_recompute_jobs as
select * from public.route_estimate_recompute_jobs;
grant usage on schema test_helpers to authenticated;
grant select on test_helpers.route_estimate_recompute_jobs to authenticated;

insert into auth.users (
  id, instance_id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at
) values
  ('99999999-9999-9999-9999-999999999901'::uuid, '00000000-0000-0000-0000-000000000000'::uuid, 'authenticated', 'authenticated', 'integrity-driver-a@carrierflow.test', '$2a$10$not-a-real-password-hash-for-local-tests-only', timezone('utc', now()), '{}'::jsonb, '{}'::jsonb, timezone('utc', now()), timezone('utc', now())),
  ('99999999-9999-9999-9999-999999999902'::uuid, '00000000-0000-0000-0000-000000000000'::uuid, 'authenticated', 'authenticated', 'integrity-driver-b@carrierflow.test', '$2a$10$not-a-real-password-hash-for-local-tests-only', timezone('utc', now()), '{}'::jsonb, '{}'::jsonb, timezone('utc', now()), timezone('utc', now()));

insert into public.company_memberships (id, company_id, user_id, role, status) values
  ('41414141-4141-4141-4141-414141414901'::uuid, '11111111-1111-1111-1111-111111111111'::uuid, '99999999-9999-9999-9999-999999999901'::uuid, 'driver', 'active'),
  ('41414141-4141-4141-4141-414141414902'::uuid, '11111111-1111-1111-1111-111111111111'::uuid, '99999999-9999-9999-9999-999999999902'::uuid, 'driver', 'active');

set local role authenticated;
select set_config('request.jwt.claim.sub', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', true);
select lives_ok($$select * from public.set_company_route_base(
  '11111111-1111-1111-1111-111111111111'::uuid,
  '{"label":"Integrity carrier base","latitude":41.8781,"longitude":-87.6298}'::jsonb
)$$, 'owner records a declared route base for unassigned and reassigned continuity');
select lives_ok($$select * from public.create_driver('11111111-1111-1111-1111-111111111111'::uuid, '41414141-4141-4141-4141-414141414901'::uuid, 'Integrity Driver A')$$, 'owner creates driver A');
select id as driver_a_id from public.drivers where membership_id = '41414141-4141-4141-4141-414141414901'::uuid \gset
select lives_ok($$select * from public.create_driver('11111111-1111-1111-1111-111111111111'::uuid, '41414141-4141-4141-4141-414141414902'::uuid, 'Integrity Driver B')$$, 'owner creates driver B');
select id as driver_b_id from public.drivers where membership_id = '41414141-4141-4141-4141-414141414902'::uuid \gset
select lives_ok($$select * from public.create_vehicle('11111111-1111-1111-1111-111111111111'::uuid, 'INTEGRITY-A', 'cargo_van', 3500)$$, 'owner creates vehicle A');
select id as vehicle_a_id from public.vehicles where unit_number = 'INTEGRITY-A' \gset
select lives_ok($$select * from public.create_vehicle('11111111-1111-1111-1111-111111111111'::uuid, 'INTEGRITY-B', 'cargo_van', 3500)$$, 'owner creates vehicle B');
select id as vehicle_b_id from public.vehicles where unit_number = 'INTEGRITY-B' \gset
select lives_ok(format('select * from public.assign_driver_vehicle(%L::uuid, %L::uuid, %L::uuid)', '11111111-1111-1111-1111-111111111111', :'driver_a_id', :'vehicle_a_id'), 'owner assigns vehicle A to driver A');
select lives_ok(format('select * from public.assign_driver_vehicle(%L::uuid, %L::uuid, %L::uuid)', '11111111-1111-1111-1111-111111111111', :'driver_b_id', :'vehicle_b_id'), 'owner assigns vehicle B to driver B');

select lives_ok($$select * from public.create_pilot_load(
  '11111111-1111-1111-1111-111111111111'::uuid, 'INTEGRITY-ACTIVE',
  '{"address":"1 Active Pickup","country":"US","timezone":"America/Chicago","latitude":41.8781,"longitude":-87.6298}'::jsonb,
  '{"address":"2 Active Delivery","country":"US","timezone":"America/Chicago","latitude":42.3314,"longitude":-83.0458}'::jsonb
)$$, 'owner creates the active continuity load');
select id as active_load_id from public.loads where load_number = 'INTEGRITY-ACTIVE' \gset
reset role;
update public.loads set assigned_driver_id = :'driver_a_id'::uuid, assigned_vehicle_id = :'vehicle_a_id'::uuid where id = :'active_load_id'::uuid;
set local role authenticated;
select set_config('request.jwt.claim.sub', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', true);
select lives_ok(format('select * from public.advance_load_state(%L::uuid, %L::uuid, %L)', '11111111-1111-1111-1111-111111111111', :'active_load_id', 'scheduled'), 'active load is scheduled');
select lives_ok(format('select * from public.advance_load_state(%L::uuid, %L::uuid, %L)', '11111111-1111-1111-1111-111111111111', :'active_load_id', 'assigned'), 'active load is assigned');
select id as active_final_stop_id from public.load_stops where load_id = :'active_load_id'::uuid order by sequence desc limit 1 \gset

select lives_ok($$select * from public.create_pilot_load(
  '11111111-1111-1111-1111-111111111111'::uuid, 'INTEGRITY-STOP',
  '{"address":"3 Stop Pickup","country":"US","timezone":"America/Chicago","latitude":41.0,"longitude":-87.0}'::jsonb,
  '{"address":"4 Stop Delivery","country":"US","timezone":"America/Chicago","latitude":40.0,"longitude":-86.0}'::jsonb
)$$, 'owner creates a load for final-stop invalidation');
select id as stop_load_id from public.loads where load_number = 'INTEGRITY-STOP' \gset
select lives_ok($$select * from public.create_pilot_load(
  '11111111-1111-1111-1111-111111111111'::uuid, 'INTEGRITY-DRIVER',
  '{"address":"5 Driver Pickup","country":"US","timezone":"America/Chicago","latitude":41.0,"longitude":-87.0}'::jsonb,
  '{"address":"6 Driver Delivery","country":"US","timezone":"America/Chicago","latitude":40.0,"longitude":-86.0}'::jsonb
)$$, 'owner creates a load for driver invalidation');
select id as driver_load_id from public.loads where load_number = 'INTEGRITY-DRIVER' \gset
select lives_ok($$select * from public.create_pilot_load(
  '11111111-1111-1111-1111-111111111111'::uuid, 'INTEGRITY-ASSIGNMENT',
  '{"address":"7 Assignment Pickup","country":"US","timezone":"America/Chicago","latitude":41.0,"longitude":-87.0}'::jsonb,
  '{"address":"8 Assignment Delivery","country":"US","timezone":"America/Chicago","latitude":40.0,"longitude":-86.0}'::jsonb
)$$, 'owner creates a load for vehicle-assignment invalidation');
select id as assignment_load_id from public.loads where load_number = 'INTEGRITY-ASSIGNMENT' \gset

reset role;
update public.loads
set assigned_driver_id = :'driver_a_id'::uuid, assigned_vehicle_id = :'vehicle_a_id'::uuid
where id in (:'stop_load_id'::uuid, :'driver_load_id'::uuid, :'assignment_load_id'::uuid);
set local role authenticated;
select set_config('request.jwt.claim.sub', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', true);
-- Seed legacy immutable history as a privileged migration fixture. The new
-- application boundary below is the authenticated claim/complete job RPC.
reset role;
select lives_ok(format($sql$select * from public.persist_route_estimate_revision(
  '11111111-1111-1111-1111-111111111111'::uuid, %L::uuid, %L::uuid, 10, 90, 200.00,
  'test-routing', '{}'::jsonb, 'active_load_final_stop', %L::uuid, 'initial'
)$sql$, :'stop_load_id', :'driver_a_id', :'active_final_stop_id'), 'the stop load receives its initial revision');
select lives_ok(format($sql$select * from public.persist_route_estimate_revision(
  '11111111-1111-1111-1111-111111111111'::uuid, %L::uuid, %L::uuid, 10, 90, 200.00,
  'test-routing', '{}'::jsonb, 'active_load_final_stop', %L::uuid, 'initial'
)$sql$, :'driver_load_id', :'driver_a_id', :'active_final_stop_id'), 'the driver load receives its initial revision');
select lives_ok(format($sql$select * from public.persist_route_estimate_revision(
  '11111111-1111-1111-1111-111111111111'::uuid, %L::uuid, %L::uuid, 10, 90, 200.00,
  'test-routing', '{}'::jsonb, 'active_load_final_stop', %L::uuid, 'initial'
)$sql$, :'assignment_load_id', :'driver_a_id', :'active_final_stop_id'), 'the assignment load receives its initial revision');

set local role authenticated;
select set_config('request.jwt.claim.sub', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', true);
select ok(exists (select 1 from public.route_estimate_heads where load_id = :'stop_load_id'::uuid and state = 'current'), 'a current head is created for a persisted revision');
select results_eq(format('select id from public.get_current_route_estimate(%L::uuid, %L::uuid)', '11111111-1111-1111-1111-111111111111', :'stop_load_id'), array[(select current_revision_id from public.route_estimate_heads where load_id = :'stop_load_id'::uuid)], 'the current route read returns only the current head revision');

select id as stop_final_stop_id from public.load_stops where load_id = :'stop_load_id'::uuid order by sequence desc limit 1 \gset
select lives_ok(format($sql$select * from public.update_final_planned_stop(
  '11111111-1111-1111-1111-111111111111'::uuid, %L::uuid, %L::uuid,
  '{"address":"4 Revised Final Delivery","country":"US","timezone":"America/Chicago","latitude":39.0,"longitude":-85.0}'::jsonb
)$sql$, :'stop_load_id', :'stop_final_stop_id'), 'an authorized final-stop mutation runs through the command boundary');
select is((select state from public.route_estimate_heads where load_id = :'stop_load_id'::uuid), 'recompute_requested', 'a final-stop mutation invalidates the current estimate before recalculation');
select results_eq(format('select id from public.get_current_route_estimate(%L::uuid, %L::uuid)', '11111111-1111-1111-1111-111111111111', :'stop_load_id'), array[]::uuid[], 'a stale route estimate is never returned by the current read path');
select is((select count(*) from test_helpers.route_estimate_recompute_jobs where load_id = :'stop_load_id'::uuid), 1::bigint, 'a final-stop mutation enqueues exactly one durable recomputation job');
select is((select count(*) from public.route_estimate_context_invalidations where load_id = :'stop_load_id'::uuid and reason = 'active_final_stop_changed'), 1::bigint, 'the final-stop invalidation is append-only and durable');
select is((select count(*) from public.route_estimate_notifications where load_id = :'stop_load_id'::uuid and notification_type = 'route_estimate_invalidated'), 1::bigint, 'the final-stop invalidation creates exactly one dispatcher notification');

-- Keep this as a historical route-integrity fixture. The current UI command
-- also creates an initial routing job for draft proposals, which is tested in
-- 0015; invoking it here would pollute this single-recompute scenario.
reset role;
update public.loads set assigned_driver_id = :'driver_b_id'::uuid, assigned_vehicle_id = :'vehicle_b_id'::uuid where id = :'driver_load_id'::uuid;
set local role authenticated;
select set_config('request.jwt.claim.sub', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', true);
select is((select assigned_driver_id from public.loads where id = :'driver_load_id'::uuid), :'driver_b_id'::uuid, 'the privileged historical fixture reassigns the driver without UI-command side effects');
select is((select state from public.route_estimate_heads where load_id = :'driver_load_id'::uuid), 'recompute_requested', 'a driver change invalidates the current estimate');
select is((select count(*) from test_helpers.route_estimate_recompute_jobs where load_id = :'driver_load_id'::uuid and reason = 'driver_changed'), 1::bigint, 'a driver change creates one recomputation job');

select lives_ok(format('select * from public.assign_driver_vehicle(%L::uuid, %L::uuid, %L::uuid)', '11111111-1111-1111-1111-111111111111', :'driver_a_id', :'vehicle_b_id'), 'owner makes the replacement vehicle active for driver A');
reset role;
update public.loads set assigned_driver_id = :'driver_a_id'::uuid, assigned_vehicle_id = :'vehicle_b_id'::uuid where id = :'assignment_load_id'::uuid;
set local role authenticated;
select set_config('request.jwt.claim.sub', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', true);
select is((select assigned_vehicle_id from public.loads where id = :'assignment_load_id'::uuid), :'vehicle_b_id'::uuid, 'the privileged historical fixture moves the replacement vehicle without UI-command side effects');
select is((select state from public.route_estimate_heads where load_id = :'assignment_load_id'::uuid), 'recompute_requested', 'a vehicle assignment change invalidates the current estimate');
select is((select count(*) from test_helpers.route_estimate_recompute_jobs where load_id = :'assignment_load_id'::uuid and reason = 'assignment_changed'), 1::bigint, 'a vehicle assignment change creates one recomputation job');

select id as stop_job_id, idempotency_key as stop_job_key from test_helpers.route_estimate_recompute_jobs where load_id = :'stop_load_id'::uuid \gset
select is(
  (public.claim_route_estimate_recompute_job(
    '11111111-1111-1111-1111-111111111111'::uuid,
    :'stop_job_id'::uuid,
    :'stop_job_key'::uuid
  ) ->> 'empty_origin_kind'),
  'active_load_final_stop',
  'a claimed job returns server-derived snake_case routing context for the server adapter'
);
select is(
  (public.complete_route_estimate_recompute_job(
    '11111111-1111-1111-1111-111111111111'::uuid, :'stop_job_id'::uuid, :'stop_job_key'::uuid,
    999, 'obsolete-context-fingerprint', 11.000, 89.000, 'test-routing',
    '{"empty":{"distanceMeters":17703,"durationSeconds":1200},"loaded":{"distanceMeters":143232,"durationSeconds":7200}}'::jsonb
  ) ->> 'status'),
  'stale',
  'a stale expected context is represented without publishing a revision'
);
select throws_ok(
  format($sql$select * from public.complete_route_estimate_recompute_job(
    '11111111-1111-1111-1111-111111111111'::uuid, %L::uuid, %L::uuid,
    (select context_version from test_helpers.route_estimate_recompute_jobs where id = %L::uuid),
    (select context_fingerprint from test_helpers.route_estimate_recompute_jobs where id = %L::uuid),
    11.000, 89.000, 'test-routing',
    '{"empty":{"distanceMeters":17703,"durationSeconds":1200,"apiKey":"must-not-persist"},"loaded":{"distanceMeters":143232,"durationSeconds":7200}}'::jsonb
  )$sql$, :'stop_job_id', :'stop_job_key', :'stop_job_id', :'stop_job_id'),
  '22023',
  'bounded route estimate output is required',
  'the database independently rejects provider secrets outside the summary allowlist'
);
select lives_ok(format($sql$select * from public.complete_route_estimate_recompute_job(
  '11111111-1111-1111-1111-111111111111'::uuid, %L::uuid, %L::uuid,
  (select context_version from test_helpers.route_estimate_recompute_jobs where id = %L::uuid),
  (select context_fingerprint from test_helpers.route_estimate_recompute_jobs where id = %L::uuid),
  11.000, 89.000, 'test-routing',
  '{"empty":{"distanceMeters":17703,"durationSeconds":1200},"loaded":{"distanceMeters":143232,"durationSeconds":7200}}'::jsonb
)$sql$, :'stop_job_id', :'stop_job_key', :'stop_job_id', :'stop_job_id'), 'the claimed worker persists the replacement revision once');
select is((select state from public.route_estimate_heads where load_id = :'stop_load_id'::uuid), 'current', 'completion restores a non-stale current head');
select is((select count(*) from public.route_estimate_revisions where load_id = :'stop_load_id'::uuid), 2::bigint, 'completion creates exactly one immutable replacement revision');
select lives_ok(format($sql$select * from public.complete_route_estimate_recompute_job(
  '11111111-1111-1111-1111-111111111111'::uuid, %L::uuid, %L::uuid,
  (select context_version from test_helpers.route_estimate_recompute_jobs where id = %L::uuid),
  (select context_fingerprint from test_helpers.route_estimate_recompute_jobs where id = %L::uuid),
  11.000, 89.000, 'test-routing',
  '{"empty":{"distanceMeters":17703,"durationSeconds":1200},"loaded":{"distanceMeters":143232,"durationSeconds":7200}}'::jsonb
)$sql$, :'stop_job_id', :'stop_job_key', :'stop_job_id', :'stop_job_id'), 'the same idempotent completion returns the original revision after a lost response');
select is((select count(*) from public.route_estimate_revisions where load_id = :'stop_load_id'::uuid), 2::bigint, 'an idempotent retry creates no second revision');
select is((select count(*) from public.route_estimate_notifications where load_id = :'stop_load_id'::uuid), 1::bigint, 'the idempotent retry creates no duplicate notification');
select is(
  (
    public.claim_route_estimate_recompute_job(
      '11111111-1111-1111-1111-111111111111'::uuid,
      :'stop_job_id'::uuid,
      :'stop_job_key'::uuid
    ) -> 'revision' ->> 'id'
  )::uuid,
  (select current_revision_id from public.route_estimate_heads where load_id = :'stop_load_id'::uuid),
  'a lost-response retry reads the original completed immutable revision without another provider call'
);

select * from finish();
rollback;
