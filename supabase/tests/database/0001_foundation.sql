begin;

select plan(16);

select has_table('public', 'companies', 'creates the companies table');
select has_table('public', 'company_memberships', 'creates the company memberships table');
select has_table('public', 'audit_events', 'creates the audit events table');
select ok(to_regtype('public.company_role') is not null, 'creates the closed company role type');

select ok((select relrowsecurity from pg_class where oid = 'public.companies'::regclass), 'enables RLS on companies');
select ok((select relrowsecurity from pg_class where oid = 'public.company_memberships'::regclass), 'enables RLS on company memberships');
select ok((select relrowsecurity from pg_class where oid = 'public.audit_events'::regclass), 'enables RLS on audit events');

\set tenant_fixture_setup true
\ir helpers/tenant-fixtures.sql
\unset tenant_fixture_setup
select test_helpers.seed_tenant_fixtures();

set local role authenticated;
select set_config('request.jwt.claim.sub', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', true);
select results_eq(
  'select id from public.companies order by id',
  array['11111111-1111-1111-1111-111111111111'::uuid],
  'owner A can read only company A'
);
select results_eq(
  'select company_id from public.company_memberships order by company_id',
  array['11111111-1111-1111-1111-111111111111'::uuid],
  'owner A cannot read company B memberships'
);
select results_eq(
  'select company_id from public.audit_events order by company_id',
  array['11111111-1111-1111-1111-111111111111'::uuid],
  'owner A cannot read company B audit events'
);

reset role;
set local role authenticated;
select set_config('request.jwt.claim.sub', 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', true);
select results_eq(
  'select id from public.companies order by id',
  array['22222222-2222-2222-2222-222222222222'::uuid],
  'dispatcher B can read only company B'
);
select results_eq(
  'select company_id from public.company_memberships order by company_id',
  array['22222222-2222-2222-2222-222222222222'::uuid],
  'dispatcher B cannot read company A memberships'
);
select results_eq(
  'select company_id from public.audit_events order by company_id',
  array['22222222-2222-2222-2222-222222222222'::uuid],
  'dispatcher B cannot read company A audit events'
);

reset role;
set local role anon;
select set_config('request.jwt.claim.sub', '', true);
select is_empty('select 1 from public.companies', 'anonymous access returns zero companies');
select is_empty('select 1 from public.company_memberships', 'anonymous access returns zero memberships');
select is_empty('select 1 from public.audit_events', 'anonymous access returns zero audit events');

select * from finish();
rollback;
