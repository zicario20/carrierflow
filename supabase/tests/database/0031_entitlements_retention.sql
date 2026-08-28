begin;

select plan(35);

\set tenant_fixture_setup true
\ir helpers/tenant-fixtures.sql
\unset tenant_fixture_setup
select test_helpers.seed_tenant_fixtures();

select has_table('public', 'company_pilot_entitlements', 'pilot entitlement rows are tenant-scoped');
select has_table('public', 'company_privacy_retention_runs', 'privacy retention runs preserve only metadata');
select ok(
  (select relforcerowsecurity from pg_class where oid = 'public.company_pilot_entitlements'::regclass),
  'pilot entitlements force RLS'
);
select ok(
  (select relforcerowsecurity from pg_class where oid = 'public.company_privacy_retention_runs'::regclass),
  'privacy retention runs force RLS'
);
select is(
  (select plan_code from public.company_pilot_entitlements where company_id = '11111111-1111-1111-1111-111111111111'::uuid),
  'starter',
  'existing companies receive the private-pilot starter plan'
);
select is(
  (select trial_ends_at - trial_started_at = interval '7 days' from public.company_pilot_entitlements where company_id = '11111111-1111-1111-1111-111111111111'::uuid),
  true,
  'the private pilot trial is exactly seven days with no payment record'
);

set local role authenticated;
select set_config('request.jwt.claim.sub', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', true);
select is(
  public.get_company_pilot_entitlement('11111111-1111-1111-1111-111111111111'::uuid) ->> 'planCode',
  'starter',
  'an owner receives only the company entitlement capability'
);
select is(
  (public.get_company_pilot_entitlement('11111111-1111-1111-1111-111111111111'::uuid) ->> 'driverCapacity')::integer,
  10,
  'the starter plan exposes a database-derived ten-driver capacity'
);
select is(
  (public.get_company_pilot_entitlement('11111111-1111-1111-1111-111111111111'::uuid) ->> 'monthlyPriceUsd')::integer,
  20,
  'the starter plan exposes the fixed USD 20 pilot catalogue price without checkout'
);
select throws_ok(
  $$insert into public.company_pilot_entitlements (company_id, plan_code, trial_started_at, trial_ends_at)
    values ('11111111-1111-1111-1111-111111111111'::uuid, 'scale', timezone('utc', now()), timezone('utc', now()) + interval '7 days')$$,
  '42501', null,
  'an authenticated owner cannot directly mutate an entitlement'
);
reset role;

insert into auth.users (
  id, instance_id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at
)
select
  ('30000000-0000-0000-0000-' || lpad(candidate::text, 12, '0'))::uuid,
  '00000000-0000-0000-0000-000000000000'::uuid,
  'authenticated', 'authenticated',
  format('pilot-capacity-%s@carrierflow.test', candidate),
  '$2a$10$not-a-real-password-hash-for-local-tests-only', timezone('utc', now()),
  '{}'::jsonb, '{}'::jsonb, timezone('utc', now()), timezone('utc', now())
from generate_series(1, 11) as candidate;

insert into public.company_memberships (id, company_id, user_id, role, status)
select
  ('31000000-0000-0000-0000-' || lpad(candidate::text, 12, '0'))::uuid,
  '11111111-1111-1111-1111-111111111111'::uuid,
  ('30000000-0000-0000-0000-' || lpad(candidate::text, 12, '0'))::uuid,
  'driver', 'active'
from generate_series(1, 11) as candidate;

set local role authenticated;
select set_config('request.jwt.claim.sub', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', true);
select lives_ok(
  $test$do $capacity$
    declare candidate integer;
    begin
      for candidate in 1..10 loop
        perform public.create_driver(
          '11111111-1111-1111-1111-111111111111'::uuid,
          ('31000000-0000-0000-0000-' || lpad(candidate::text, 12, '0'))::uuid,
          format('Pilot Driver %s', candidate)
        );
      end loop;
    end;
  $capacity$$test$,
  'the transactionally guarded create RPC fills all ten starter slots'
);
select is(
  (select count(*) from public.drivers where company_id = '11111111-1111-1111-1111-111111111111'::uuid and status = 'active'),
  10::bigint,
  'the starter plan has exactly ten active drivers at capacity'
);
select throws_ok(
  $$select public.create_driver(
    '11111111-1111-1111-1111-111111111111'::uuid,
    '31000000-0000-0000-0000-000000000011'::uuid,
    'Eleventh Driver'
  )$$,
  '22023', 'the active driver capacity has been reached',
  'an eleventh active driver is denied before any lifecycle mutation'
);
select is(
  (select count(*) from public.drivers where membership_id = '31000000-0000-0000-0000-000000000011'::uuid),
  0::bigint,
  'a capacity denial leaves the candidate driver absent'
);
select is(
  (select count(*) from public.audit_events where entity_id = '31000000-0000-0000-0000-000000000011'::uuid),
  0::bigint,
  'a capacity denial leaves no membership or driver audit event'
);

select id as first_driver_id from public.drivers
where membership_id = '31000000-0000-0000-0000-000000000001'::uuid \gset
select lives_ok(
  format('select public.update_driver(%L::uuid, %L::uuid, %L, %L)',
    '11111111-1111-1111-1111-111111111111', :'first_driver_id', 'Pilot Driver 1', 'inactive'),
  'deactivation remains available at the capacity boundary'
);
select lives_ok(
  $$select public.create_driver(
    '11111111-1111-1111-1111-111111111111'::uuid,
    '31000000-0000-0000-0000-000000000011'::uuid,
    'Eleventh Driver'
  )$$,
  'a freed slot can be filled exactly once'
);
select is(
  (select count(*) from public.drivers where company_id = '11111111-1111-1111-1111-111111111111'::uuid and status = 'active'),
  10::bigint,
  'sequential contenders never raise active drivers above capacity'
);
select throws_ok(
  format('select public.update_driver(%L::uuid, %L::uuid, %L, %L)',
    '11111111-1111-1111-1111-111111111111', :'first_driver_id', 'Pilot Driver 1', 'active'),
  '22023', 'the active driver capacity has been reached',
  'reactivation is denied when the final slot was consumed'
);
select is(
  (select status from public.drivers where id = :'first_driver_id'::uuid),
  'inactive',
  'a denied reactivation leaves the driver inactive'
);
select is(
  (select status::text from public.company_memberships where id = '31000000-0000-0000-0000-000000000001'::uuid),
  'suspended',
  'a denied reactivation leaves the membership suspended'
);
select is(
  (select count(*) from public.audit_events where action = 'membership.reactivated' and entity_id = '31000000-0000-0000-0000-000000000001'::uuid),
  0::bigint,
  'a denied reactivation writes no unintended audit event'
);
reset role;
select ok(
  position('for update' in pg_get_functiondef('entitlement_private.assert_active_driver_capacity(uuid)'::regprocedure)) > 0,
  'the shared entitlement row lock serializes simultaneous activation attempts'
);

set local role authenticated;
select set_config('request.jwt.claim.sub', 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', true);
select throws_ok(
  $$select public.get_company_pilot_entitlement('11111111-1111-1111-1111-111111111111'::uuid)$$,
  '42501', 'an active owner is required to view pilot plan settings',
  'a cross-tenant dispatcher cannot resolve another company entitlement'
);
select throws_ok(
  $$select public.run_pilot_privacy_retention('11111111-1111-1111-1111-111111111111'::uuid)$$,
  '42501', 'an active owner is required to run pilot privacy retention',
  'a cross-tenant dispatcher cannot run another company privacy job'
);
select throws_ok(
  $$insert into public.company_privacy_retention_runs (company_id, actor_id, policy_version, purged_current_location_count, purged_detailed_location_count, preserved_evidence_metadata_count)
    values ('11111111-1111-1111-1111-111111111111'::uuid, 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'::uuid, 'pilot-v1', 0, 0, 0)$$,
  '42501', null,
  'authenticated clients cannot directly write privacy retention run metadata'
);
reset role;

select id as retained_driver_id from public.drivers
where membership_id = '31000000-0000-0000-0000-000000000011'::uuid \gset
insert into public.loads (company_id, load_number, created_by)
values ('11111111-1111-1111-1111-111111111111'::uuid, 'PILOT-RETENTION-001', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'::uuid);
select id as retention_load_id from public.loads where load_number = 'PILOT-RETENTION-001' \gset
insert into public.load_evidence (company_id, load_id, evidence_type, evidence_value, recorded_by)
values (
  '11111111-1111-1111-1111-111111111111'::uuid,
  :'retention_load_id'::uuid,
  'pod',
  '{"privateDocumentContents":"must-never-appear-in-retention-audit","signedUrl":"https://private.example.test/opaque"}'::jsonb,
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'::uuid
);
insert into public.driver_location_history (company_id, driver_id, latitude, longitude, accuracy_meters, recorded_at)
values ('11111111-1111-1111-1111-111111111111'::uuid, :'retained_driver_id'::uuid, 41.8781, -87.6298, 9, timezone('utc', now()) - interval '8 days');
insert into public.current_driver_locations (company_id, driver_id, latitude, longitude, accuracy_meters, recorded_at)
values ('11111111-1111-1111-1111-111111111111'::uuid, :'retained_driver_id'::uuid, 41.8781, -87.6298, 9, timezone('utc', now()) - interval '6 minutes');

set local role authenticated;
select set_config('request.jwt.claim.sub', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', true);
select lives_ok(
  $$select public.run_pilot_privacy_retention('11111111-1111-1111-1111-111111111111'::uuid)$$,
  'an owner runs the privacy retention RPC without document or coordinate inputs'
);
reset role;
select is(
  (select count(*) from public.load_evidence where load_id = :'retention_load_id'::uuid),
  1::bigint,
  'retention preserves legal evidence rows rather than deleting document content'
);
select is(
  (select count(*) from public.driver_location_history where driver_id = :'retained_driver_id'::uuid),
  0::bigint,
  'retention purges detailed GPS older than seven days'
);
select is(
  (select count(*) from public.current_driver_locations where driver_id = :'retained_driver_id'::uuid),
  0::bigint,
  'retention purges stale current GPS pointers'
);
select is(
  (select count(*) from public.company_privacy_retention_runs where company_id = '11111111-1111-1111-1111-111111111111'::uuid),
  1::bigint,
  'the job records exactly one minimum-metadata retention run'
);
select ok(
  not exists (
    select 1
    from public.audit_events
    where action = 'privacy_retention.completed'
      and (after_data::text like '%must-never-appear%' or after_data::text like '%private.example.test%' or after_data::text like '%41.8781%' or after_data::text like '%-87.6298%')
  ),
  'the retention audit includes no document content, signed URL, or raw location'
);
select hasnt_column('public', 'company_privacy_retention_runs', 'evidence_value', 'retention runs never store evidence content');
select hasnt_column('public', 'company_privacy_retention_runs', 'latitude', 'retention runs never store raw latitude');
select hasnt_column('public', 'company_privacy_retention_runs', 'token', 'retention runs never store provider tokens');

select * from finish();
rollback;
