begin;

select no_plan();

\set tenant_fixture_setup true
\ir helpers/tenant-fixtures.sql
\unset tenant_fixture_setup
select test_helpers.seed_tenant_fixtures();

-- This view exists only inside the rolled-back pgTAP transaction. It keeps
-- production job idempotency keys and lease fields off authenticated tables
-- while allowing the test to inspect durable state precisely.
create view test_helpers.route_estimate_recompute_jobs as
select * from public.route_estimate_recompute_jobs;
grant usage on schema test_helpers to authenticated;
grant select on test_helpers.route_estimate_recompute_jobs to authenticated;

insert into auth.users (
  id, instance_id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at
) values (
  '99999999-9999-9999-9999-999999999912'::uuid,
  '00000000-0000-0000-0000-000000000000'::uuid,
  'authenticated', 'authenticated', 'proposal-worker-b@carrierflow.test',
  '$2a$10$not-a-real-password-hash-for-local-tests-only', timezone('utc', now()),
  '{}'::jsonb, '{}'::jsonb, timezone('utc', now()), timezone('utc', now())
);
insert into public.company_memberships (id, company_id, user_id, role, status) values (
  '41414141-4141-4141-4141-414141414912'::uuid,
  '11111111-1111-1111-1111-111111111111'::uuid,
  '99999999-9999-9999-9999-999999999912'::uuid,
  'dispatcher', 'active'
);

set local role authenticated;
select set_config('request.jwt.claim.sub', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', true);

select lives_ok($$select * from public.create_pilot_load(
  '11111111-1111-1111-1111-111111111111'::uuid,
  'PROPOSAL-UNASSIGNED',
  '{"address":"Proposal pickup","country":"US","timezone":"America/Chicago","latitude":41.8781,"longitude":-87.6298}'::jsonb,
  '{"address":"Proposal delivery","country":"US","timezone":"America/Chicago","latitude":42.3314,"longitude":-83.0458}'::jsonb
)$$, 'an authorized dispatcher can create an unassigned proposal load');
select id as proposal_load_id from public.loads where load_number = 'PROPOSAL-UNASSIGNED' \gset

select lives_ok($$select * from public.set_company_route_base(
  '11111111-1111-1111-1111-111111111111'::uuid,
  '{"label":"Carrier A base","latitude":41.8810,"longitude":-87.6270}'::jsonb
)$$, 'the dispatcher records the private declared base for a first-trip proposal');

select lives_ok(format($sql$select * from public.request_initial_route_estimate(
  '11111111-1111-1111-1111-111111111111'::uuid, %L::uuid, 175.00,
  '12121212-1212-4121-8121-121212121212'::uuid
)$sql$, :'proposal_load_id'), 'an unassigned proposal queues an initial estimate from the declared base');

select throws_ok(
  'select * from public.route_estimate_recompute_jobs',
  '42501',
  'permission denied for table route_estimate_recompute_jobs',
  'route-job idempotency and lease fields are not directly exposed to authenticated clients'
);
select (
  public.request_initial_route_estimate(
    '11111111-1111-1111-1111-111111111111'::uuid,
    :'proposal_load_id'::uuid, 175.00,
    '12121212-1212-4121-8121-121212121212'::uuid
  ) ->> 'id'
)::uuid as proposal_job_id \gset
select idempotency_key as proposal_job_key, context_version as proposal_context_version,
  context_fingerprint as proposal_context_fingerprint
from test_helpers.route_estimate_recompute_jobs
where id = :'proposal_job_id'::uuid \gset
select is(
  (select state from public.route_estimate_heads where load_id = :'proposal_load_id'::uuid),
  'initial_requested',
  'the first initial job creates a durable initial-requested head before any revision exists'
);
select is(
  (public.claim_route_estimate_recompute_job(
    '11111111-1111-1111-1111-111111111111'::uuid,
    :'proposal_job_id'::uuid, :'proposal_job_key'::uuid
  ) ->> 'empty_origin_kind'),
  'declared_base',
  'the first unassigned trip derives its empty origin from the server-owned declared base'
);

-- Reclaim after lease expiry belongs to worker B. Worker A cannot release or
-- publish with the obsolete claim, even though both remain dispatchers.
reset role;
update public.route_estimate_recompute_jobs
set claimed_at = timezone('utc', now()) - interval '6 minutes'
where id = :'proposal_job_id'::uuid;
set local role authenticated;
select set_config('request.jwt.claim.sub', '99999999-9999-9999-9999-999999999912', true);
select lives_ok(format($sql$select public.claim_route_estimate_recompute_job(
  '11111111-1111-1111-1111-111111111111'::uuid, %L::uuid, %L::uuid
)$sql$, :'proposal_job_id', :'proposal_job_key'), 'worker B reclaims an expired lease');
select is(
  (select claimed_by from test_helpers.route_estimate_recompute_jobs where id = :'proposal_job_id'::uuid),
  '99999999-9999-9999-9999-999999999912'::uuid,
  'the reclaimed lease is durably owned by worker B'
);
select set_config('request.jwt.claim.sub', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', true);
select throws_ok(format($sql$select public.release_route_estimate_recompute_job(
  '11111111-1111-1111-1111-111111111111'::uuid, %L::uuid, %L::uuid
)$sql$, :'proposal_job_id', :'proposal_job_key'), '42501',
  'a current route estimate lease owned by this worker is required',
  'a prior worker cannot release a lease reclaimed by another worker');
select throws_ok(format($sql$select public.complete_route_estimate_recompute_job(
  '11111111-1111-1111-1111-111111111111'::uuid, %L::uuid, %L::uuid,
  %s, %L, 12.000, 80.000, 'test-routing',
  '{"empty":{"distanceMeters":19312,"durationSeconds":1200},"loaded":{"distanceMeters":128748,"durationSeconds":7200}}'::jsonb
)$sql$, :'proposal_job_id', :'proposal_job_key', :'proposal_context_version', :'proposal_context_fingerprint'), '42501',
  'a current route estimate lease owned by this worker is required',
  'a prior worker cannot complete a lease reclaimed by another worker');

select set_config('request.jwt.claim.sub', '99999999-9999-9999-9999-999999999912', true);
select is(
  public.release_route_estimate_recompute_job(
    '11111111-1111-1111-1111-111111111111'::uuid,
    :'proposal_job_id'::uuid, :'proposal_job_key'::uuid
  ),
  true,
  'the current lease owner can release its own valid lease'
);
select set_config('request.jwt.claim.sub', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', true);
select lives_ok(format($sql$select public.claim_route_estimate_recompute_job(
  '11111111-1111-1111-1111-111111111111'::uuid, %L::uuid, %L::uuid
)$sql$, :'proposal_job_id', :'proposal_job_key'), 'worker A claims the latest initial job before a dispatcher change');
select id as proposal_final_stop_id from public.load_stops
where load_id = :'proposal_load_id'::uuid order by sequence desc limit 1 \gset
select lives_ok(format($sql$select * from public.update_final_planned_stop(
  '11111111-1111-1111-1111-111111111111'::uuid, %L::uuid, %L::uuid,
  '{"address":"Proposal delivery revised","country":"US","timezone":"America/Chicago","latitude":42.4,"longitude":-83.1}'::jsonb
)$sql$, :'proposal_load_id', :'proposal_final_stop_id'),
  'a stop mutation supersedes a claimed first-job context without rolling back the dispatcher change');
select is(
  (select status from test_helpers.route_estimate_recompute_jobs where id = :'proposal_job_id'::uuid),
  'superseded',
  'the claimed initial job is durably superseded after its stop changes'
);
select is(
  (select count(*) from test_helpers.route_estimate_recompute_jobs
    where load_id = :'proposal_load_id'::uuid and status = 'pending'),
  1::bigint,
  'exactly one fresh pending job remains after the claimed initial job becomes stale'
);
select is(
  (public.complete_route_estimate_recompute_job(
    '11111111-1111-1111-1111-111111111111'::uuid,
    :'proposal_job_id'::uuid, :'proposal_job_key'::uuid,
    :'proposal_context_version'::integer, :'proposal_context_fingerprint',
    12.000, 80.000, 'test-routing',
    '{"empty":{"distanceMeters":19312,"durationSeconds":1200},"loaded":{"distanceMeters":128748,"durationSeconds":7200}}'::jsonb
  ) ->> 'status'),
  'stale',
  'completion returns typed stale state and never publishes the obsolete provider result'
);
select is(
  (select count(*) from public.route_estimate_revisions where load_id = :'proposal_load_id'::uuid),
  0::bigint,
  'a stale initial completion creates no immutable route revision'
);

select * from finish();
rollback;
