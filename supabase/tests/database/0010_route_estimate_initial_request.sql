begin;

select no_plan();

\set tenant_fixture_setup true
\ir helpers/tenant-fixtures.sql
\unset tenant_fixture_setup
select test_helpers.seed_tenant_fixtures();

-- Test-only privileged inspector; production clients use the bounded RPCs.
create view test_helpers.route_estimate_recompute_jobs as
select * from public.route_estimate_recompute_jobs;
grant usage on schema test_helpers to authenticated;
grant select on test_helpers.route_estimate_recompute_jobs to authenticated;
create function test_helpers.expire_route_estimate_job(target_job_id uuid)
returns void
language sql
security definer
set search_path = ''
as $$
  update public.route_estimate_recompute_jobs
  set claimed_at = timezone('utc', now()) - interval '6 minutes'
  where id = target_job_id;
$$;
grant execute on function test_helpers.expire_route_estimate_job(uuid) to authenticated;

insert into auth.users (
  id, instance_id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at
) values (
  '99999999-9999-9999-9999-999999999910'::uuid,
  '00000000-0000-0000-0000-000000000000'::uuid,
  'authenticated', 'authenticated', 'initial-route-driver@carrierflow.test',
  '$2a$10$not-a-real-password-hash-for-local-tests-only', timezone('utc', now()),
  '{}'::jsonb, '{}'::jsonb, timezone('utc', now()), timezone('utc', now())
);
insert into public.company_memberships (id, company_id, user_id, role, status) values (
  '41414141-4141-4141-4141-414141414910'::uuid,
  '11111111-1111-1111-1111-111111111111'::uuid,
  '99999999-9999-9999-9999-999999999910'::uuid,
  'driver', 'active'
);

set local role authenticated;
select set_config('request.jwt.claim.sub', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', true);
select lives_ok($$select * from public.create_driver(
  '11111111-1111-1111-1111-111111111111'::uuid,
  '41414141-4141-4141-4141-414141414910'::uuid,
  'Initial Route Driver'
)$$, 'owner creates the route driver');
select id as driver_id from public.drivers where membership_id = '41414141-4141-4141-4141-414141414910'::uuid \gset
select lives_ok($$select * from public.create_vehicle(
  '11111111-1111-1111-1111-111111111111'::uuid, 'INITIAL-100', 'cargo_van', 3500
)$$, 'owner creates the route vehicle');
select id as vehicle_id from public.vehicles where unit_number = 'INITIAL-100' \gset
select lives_ok(format('select * from public.assign_driver_vehicle(%L::uuid, %L::uuid, %L::uuid)',
  '11111111-1111-1111-1111-111111111111', :'driver_id', :'vehicle_id'
), 'owner assigns the active vehicle');

select lives_ok($$select * from public.create_pilot_load(
  '11111111-1111-1111-1111-111111111111'::uuid, 'INITIAL-ACTIVE',
  '{"address":"Initial active pickup","country":"US","timezone":"America/Chicago","latitude":41.8781,"longitude":-87.6298}'::jsonb,
  '{"address":"Initial active delivery","country":"US","timezone":"America/Chicago","latitude":42.3314,"longitude":-83.0458}'::jsonb
)$$, 'owner creates the active continuity load');
select id as active_load_id from public.loads where load_number = 'INITIAL-ACTIVE' \gset
reset role;
update public.loads
set assigned_driver_id = :'driver_id'::uuid, assigned_vehicle_id = :'vehicle_id'::uuid
where id = :'active_load_id'::uuid;
set local role authenticated;
select set_config('request.jwt.claim.sub', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', true);
select lives_ok(format('select * from public.advance_load_state(%L::uuid, %L::uuid, %L)',
  '11111111-1111-1111-1111-111111111111', :'active_load_id', 'scheduled'
), 'active load is scheduled');
select lives_ok(format('select * from public.advance_load_state(%L::uuid, %L::uuid, %L)',
  '11111111-1111-1111-1111-111111111111', :'active_load_id', 'assigned'
), 'active load is assigned');

select lives_ok($$select * from public.create_pilot_load(
  '11111111-1111-1111-1111-111111111111'::uuid, 'INITIAL-NEXT',
  '{"address":"Initial next pickup","country":"US","timezone":"America/Chicago","latitude":41.0,"longitude":-87.0}'::jsonb,
  '{"address":"Initial next delivery","country":"US","timezone":"America/Chicago","latitude":40.0,"longitude":-86.0}'::jsonb
)$$, 'owner creates the first quoted load');
select id as initial_load_id from public.loads where load_number = 'INITIAL-NEXT' \gset
reset role;
update public.loads
set assigned_driver_id = :'driver_id'::uuid, assigned_vehicle_id = :'vehicle_id'::uuid
where id = :'initial_load_id'::uuid;
set local role authenticated;
select set_config('request.jwt.claim.sub', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', true);

select throws_ok(
  $$select * from public.request_initial_route_estimate(
    '11111111-1111-1111-1111-111111111111'::uuid,
    '00000000-0000-0000-0000-000000000000'::uuid,
    0.00,
    '55555555-5555-4555-8555-555555555555'::uuid
  )$$,
  '22023',
  'a valid decimal quoted USD amount is required',
  'initial request validates the dispatcher quote before any job is queued'
);
select lives_ok(format($sql$select * from public.request_initial_route_estimate(
  '11111111-1111-1111-1111-111111111111'::uuid, %L::uuid, 250.00,
  '55555555-5555-4555-8555-555555555555'::uuid
)$sql$, :'initial_load_id'), 'a manager queues the first route estimate without submitting stops, GPS or miles');
select id as initial_job_id, idempotency_key as initial_job_key
from test_helpers.route_estimate_recompute_jobs
where load_id = :'initial_load_id'::uuid \gset
select is((select reason from test_helpers.route_estimate_recompute_jobs where id = :'initial_job_id'::uuid), 'initial', 'the initial job is explicit and durable');
reset role;
select is(
  (select context_fingerprint from test_helpers.route_estimate_recompute_jobs where id = :'initial_job_id'::uuid),
  public.route_estimate_context_fingerprint('11111111-1111-1111-1111-111111111111'::uuid, :'initial_load_id'::uuid),
  'the initial job persists a server-derived routing context fingerprint'
);
set local role authenticated;
select set_config('request.jwt.claim.sub', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', true);
select is(
  (select (public.request_initial_route_estimate(
    '11111111-1111-1111-1111-111111111111'::uuid, :'initial_load_id'::uuid, 250.00,
    '55555555-5555-4555-8555-555555555555'::uuid
  ) ->> 'id')::uuid),
  :'initial_job_id'::uuid,
  'an identical initial request returns the original durable job'
);
select is(
  (public.claim_route_estimate_recompute_job(
    '11111111-1111-1111-1111-111111111111'::uuid,
    :'initial_job_id'::uuid,
    :'initial_job_key'::uuid
  ) ->> 'empty_origin_kind'),
  'active_load_final_stop',
  'the initial claim derives empty miles from the active load final planned stop'
);
select lives_ok(format($sql$select * from public.complete_route_estimate_recompute_job(
  '11111111-1111-1111-1111-111111111111'::uuid, %L::uuid, %L::uuid,
  (select context_version from test_helpers.route_estimate_recompute_jobs where id = %L::uuid),
  (select context_fingerprint from test_helpers.route_estimate_recompute_jobs where id = %L::uuid),
  12.500, 87.500, 'test-routing',
  '{"empty":{"distanceMeters":20116,"durationSeconds":1200},"loaded":{"distanceMeters":140817,"durationSeconds":7200}}'::jsonb
)$sql$, :'initial_job_id', :'initial_job_key', :'initial_job_id', :'initial_job_id'), 'the initial job completes through the same bounded provider boundary');
select is((select count(*) from public.route_estimate_revisions where load_id = :'initial_load_id'::uuid), 1::bigint, 'initial completion creates exactly one immutable first revision');
select is((select state from public.route_estimate_heads where load_id = :'initial_load_id'::uuid), 'current', 'initial completion creates a current non-stale head');
select id as initial_final_stop_id from public.load_stops
where load_id = :'initial_load_id'::uuid order by sequence desc limit 1 \gset
select lives_ok(format($sql$select * from public.update_final_planned_stop(
  '11111111-1111-1111-1111-111111111111'::uuid, %L::uuid, %L::uuid,
  '{"address":"Initial revised final A","country":"US","timezone":"America/Chicago","latitude":39.0,"longitude":-85.0}'::jsonb
)$sql$, :'initial_load_id', :'initial_final_stop_id'), 'the first final-stop change queues a recompute');
select id as superseded_job_id, idempotency_key as superseded_job_key
from test_helpers.route_estimate_recompute_jobs
where load_id = :'initial_load_id'::uuid and status = 'pending' and reason = 'active_final_stop_changed' \gset
select lives_ok(format('select public.claim_route_estimate_recompute_job(%L::uuid, %L::uuid, %L::uuid)',
  '11111111-1111-1111-1111-111111111111', :'superseded_job_id', :'superseded_job_key'
), 'a worker claims the first recompute job');
select lives_ok(format($sql$select * from public.update_final_planned_stop(
  '11111111-1111-1111-1111-111111111111'::uuid, %L::uuid, %L::uuid,
  '{"address":"Initial revised final B","country":"US","timezone":"America/Chicago","latitude":38.0,"longitude":-84.0}'::jsonb
)$sql$, :'initial_load_id', :'initial_final_stop_id'), 'a second context change occurs after the first job is claimed');
select is((select status from test_helpers.route_estimate_recompute_jobs where id = :'superseded_job_id'::uuid), 'superseded', 'the claimed obsolete job is superseded atomically');
select is((select count(*) from test_helpers.route_estimate_recompute_jobs where load_id = :'initial_load_id'::uuid and status = 'pending'), 1::bigint, 'exactly one fresh job remains pending after the second context change');
select is((public.complete_route_estimate_recompute_job(
  '11111111-1111-1111-1111-111111111111'::uuid, :'superseded_job_id'::uuid, :'superseded_job_key'::uuid,
  (select context_version from test_helpers.route_estimate_recompute_jobs where id = :'superseded_job_id'::uuid),
  (select context_fingerprint from test_helpers.route_estimate_recompute_jobs where id = :'superseded_job_id'::uuid),
  12.500, 87.500, 'test-routing',
  '{"empty":{"distanceMeters":20116,"durationSeconds":1200},"loaded":{"distanceMeters":140817,"durationSeconds":7200}}'::jsonb
)->> 'status'),
  'stale',
  'a superseded provider result cannot publish an obsolete revision'
);
select id as retry_job_id, idempotency_key as retry_job_key
from test_helpers.route_estimate_recompute_jobs
where load_id = :'initial_load_id'::uuid and status = 'pending' \gset
select lives_ok(format('select public.claim_route_estimate_recompute_job(%L::uuid, %L::uuid, %L::uuid)',
  '11111111-1111-1111-1111-111111111111', :'retry_job_id', :'retry_job_key'
), 'the fresh context job can be claimed');
select is(
  public.release_route_estimate_recompute_job(
    '11111111-1111-1111-1111-111111111111'::uuid,
    :'retry_job_id'::uuid,
    :'retry_job_key'::uuid
  ),
  true,
  'a failed provider attempt releases its claim for an immediate idempotent retry'
);
select is((select status from test_helpers.route_estimate_recompute_jobs where id = :'retry_job_id'::uuid), 'pending', 'released work is durable pending work rather than a permanently stale head');
select lives_ok(format('select public.claim_route_estimate_recompute_job(%L::uuid, %L::uuid, %L::uuid)',
  '11111111-1111-1111-1111-111111111111', :'retry_job_id', :'retry_job_key'
), 'the released job can be reclaimed');
select test_helpers.expire_route_estimate_job(:'retry_job_id'::uuid);
select lives_ok(format('select public.claim_route_estimate_recompute_job(%L::uuid, %L::uuid, %L::uuid)',
  '11111111-1111-1111-1111-111111111111', :'retry_job_id', :'retry_job_key'
), 'an expired five-minute lease is reclaimed safely after worker loss');

select * from finish();
rollback;
