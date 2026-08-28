begin;

select plan(22);

\set tenant_fixture_setup true
\ir helpers/tenant-fixtures.sql
\unset tenant_fixture_setup
select test_helpers.seed_tenant_fixtures();

insert into auth.users (
  id,
  instance_id,
  aud,
  role,
  email,
  encrypted_password,
  email_confirmed_at,
  raw_app_meta_data,
  raw_user_meta_data,
  created_at,
  updated_at
) values (
  '99999999-9999-9999-9999-999999999999'::uuid,
  '00000000-0000-0000-0000-000000000000'::uuid,
  'authenticated',
  'authenticated',
  'driver-a@carrierflow.test',
  '$2a$10$not-a-real-password-hash-for-local-tests-only',
  timezone('utc', now()),
  '{}'::jsonb,
  '{}'::jsonb,
  timezone('utc', now()),
  timezone('utc', now())
);

insert into public.company_memberships (company_id, user_id, role, status) values (
  '11111111-1111-1111-1111-111111111111'::uuid,
  '99999999-9999-9999-9999-999999999999'::uuid,
  'driver',
  'active'
);

select ok(
  to_regprocedure('public.create_company_invitation(uuid,text,public.company_role)') is not null,
  'creates the company invitation mutation boundary'
);

set local role authenticated;
select set_config('request.jwt.claim.sub', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', true);

select lives_ok(
  $$select * from public.create_company_invitation(
    '11111111-1111-1111-1111-111111111111'::uuid,
    'new-driver@carrierflow.test',
    'driver'::public.company_role
  )$$,
  'an active owner can create a pending invitation for their company'
);

select is(
  (select status::text from public.company_memberships where invited_email = 'new-driver@carrierflow.test'),
  'pending',
  'the invitation creates a pending membership'
);
select ok(
  (select user_id is null from public.company_memberships where invited_email = 'new-driver@carrierflow.test'),
  'the pending invitation has no user identity before acceptance'
);
select is(
  (select actor_id from public.audit_events where action = 'membership.invited' and after_data ->> 'email' = 'new-driver@carrierflow.test'),
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'::uuid,
  'the invitation audit event identifies the owner actor'
);
select ok(
  (select before_data is null from public.audit_events where action = 'membership.invited' and after_data ->> 'email' = 'new-driver@carrierflow.test'),
  'a create audit event has null before data'
);
select is(
  (select after_data ->> 'status' from public.audit_events where action = 'membership.invited' and after_data ->> 'email' = 'new-driver@carrierflow.test'),
  'pending',
  'the audit event contains the resulting membership status'
);
select ok(
  (select occurred_at is not null from public.audit_events where action = 'membership.invited' and after_data ->> 'email' = 'new-driver@carrierflow.test'),
  'the audit event records a timestamp'
);
select is(
  (select entity_type from public.audit_events where action = 'membership.invited' and after_data ->> 'email' = 'new-driver@carrierflow.test'),
  'company_membership',
  'the audit event identifies the changed entity type'
);
select ok(
  (select audit.entity_id = membership.id
   from public.audit_events as audit
   join public.company_memberships as membership
     on membership.invited_email = audit.after_data ->> 'email'
   where audit.action = 'membership.invited' and membership.invited_email = 'new-driver@carrierflow.test'),
  'the audit event identifies the changed membership'
);

reset role;
set local role authenticated;
select set_config('request.jwt.claim.sub', '99999999-9999-9999-9999-999999999999', true);

select throws_ok(
  $$select * from public.create_company_invitation(
    '11111111-1111-1111-1111-111111111111'::uuid,
    'forbidden-driver@carrierflow.test',
    'driver'::public.company_role
  )$$,
  '42501',
  'only active owners may create company invitations',
  'a driver cannot invoke an administrative invitation mutation'
);
select is(
  (select count(*) from public.company_memberships where invited_email = 'forbidden-driver@carrierflow.test'),
  0::bigint,
  'a denied driver mutation does not create a membership'
);
select is(
  (select count(*) from public.audit_events where after_data ->> 'email' = 'forbidden-driver@carrierflow.test'),
  0::bigint,
  'a denied driver mutation does not write an audit event'
);

reset role;
set local role authenticated;
select set_config('request.jwt.claim.sub', 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', true);

select throws_ok(
  $$select * from public.create_company_invitation(
    '22222222-2222-2222-2222-222222222222'::uuid,
    'forbidden-dispatcher@carrierflow.test',
    'driver'::public.company_role
  )$$,
  '42501',
  'only active owners may create company invitations',
  'a dispatcher cannot invoke an owner-only invitation mutation'
);
select is(
  (select count(*) from public.company_memberships where invited_email = 'forbidden-dispatcher@carrierflow.test'),
  0::bigint,
  'a denied dispatcher mutation does not create a membership'
);

reset role;
set local role authenticated;
select set_config('request.jwt.claim.sub', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', true);

select throws_ok(
  $$select * from public.create_company_invitation(
    '22222222-2222-2222-2222-222222222222'::uuid,
    'cross-company@carrierflow.test',
    'driver'::public.company_role
  )$$,
  '42501',
  'only active owners may create company invitations',
  'an owner cannot create an invitation for another company'
);
select is(
  (select count(*) from public.company_memberships where invited_email = 'cross-company@carrierflow.test'),
  0::bigint,
  'a cross-company refusal does not create a membership'
);

reset role;
select ok(
  (select prosecdef from pg_proc where oid = 'public.create_company_invitation(uuid,text,public.company_role)'::regprocedure),
  'the mutation is a controlled security definer boundary'
);
select ok(
  (select array_to_string(proconfig, ',') like 'search_path=%' from pg_proc where oid = 'public.create_company_invitation(uuid,text,public.company_role)'::regprocedure),
  'the mutation locks its search path'
);
select ok(
  not has_function_privilege('anon', 'public.create_company_invitation(uuid,text,public.company_role)', 'execute'),
  'anonymous callers cannot execute the mutation'
);
select ok(
  has_function_privilege('authenticated', 'public.create_company_invitation(uuid,text,public.company_role)', 'execute'),
  'authenticated callers may execute the database-authorized mutation'
);

set local role authenticated;
select set_config('request.jwt.claim.sub', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', true);
select throws_ok(
  $$update public.audit_events set action = 'tampered' where action = 'membership.invited'$$,
  '42501',
  null,
  'clients cannot alter audit history'
);

select * from finish();
rollback;
