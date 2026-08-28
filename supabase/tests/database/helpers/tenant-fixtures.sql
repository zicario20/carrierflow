-- Deterministic local-only identities used by pgTAP tenant-isolation tests.
-- The helper deliberately contains no credential or production data.
-- Supabase executes every .sql file under tests/database, so the standalone
-- branch below emits a valid TAP plan. The integration test sets the psql
-- variable before including this file to load the actual fixture function.
\if :{?tenant_fixture_setup}

create schema if not exists test_helpers;

create or replace function test_helpers.seed_tenant_fixtures()
returns void
language plpgsql
as $$
begin
  delete from public.audit_events
  where id in (
    'cccccccc-cccc-cccc-cccc-cccccccccccc'::uuid,
    'dddddddd-dddd-dddd-dddd-dddddddddddd'::uuid
  );

  delete from public.company_memberships
  where id in (
    'eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee'::uuid,
    'ffffffff-ffff-ffff-ffff-ffffffffffff'::uuid
  );

  delete from public.companies
  where id in (
    '11111111-1111-1111-1111-111111111111'::uuid,
    '22222222-2222-2222-2222-222222222222'::uuid
  );

  delete from auth.users
  where id in (
    'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'::uuid,
    'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'::uuid
  );

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
  ) values
    (
      'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'::uuid,
      '00000000-0000-0000-0000-000000000000'::uuid,
      'authenticated',
      'authenticated',
      'owner-a@carrierflow.test',
      '$2a$10$not-a-real-password-hash-for-local-tests-only',
      timezone('utc', now()),
      '{}'::jsonb,
      '{}'::jsonb,
      timezone('utc', now()),
      timezone('utc', now())
    ),
    (
      'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'::uuid,
      '00000000-0000-0000-0000-000000000000'::uuid,
      'authenticated',
      'authenticated',
      'dispatcher-b@carrierflow.test',
      '$2a$10$not-a-real-password-hash-for-local-tests-only',
      timezone('utc', now()),
      '{}'::jsonb,
      '{}'::jsonb,
      timezone('utc', now()),
      timezone('utc', now())
    );

  insert into public.companies (id, name) values
    ('11111111-1111-1111-1111-111111111111'::uuid, 'Carrier A'),
    ('22222222-2222-2222-2222-222222222222'::uuid, 'Carrier B');

  insert into public.company_memberships (id, company_id, user_id, role, status) values
    (
      'eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee'::uuid,
      '11111111-1111-1111-1111-111111111111'::uuid,
      'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'::uuid,
      'owner',
      'active'
    ),
    (
      'ffffffff-ffff-ffff-ffff-ffffffffffff'::uuid,
      '22222222-2222-2222-2222-222222222222'::uuid,
      'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'::uuid,
      'dispatcher',
      'active'
    );

  insert into public.audit_events (id, company_id, actor_id, action, before_data, after_data) values
    (
      'cccccccc-cccc-cccc-cccc-cccccccccccc'::uuid,
      '11111111-1111-1111-1111-111111111111'::uuid,
      'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'::uuid,
      'test.company.created',
      '{}'::jsonb,
      '{"name":"Carrier A"}'::jsonb
    ),
    (
      'dddddddd-dddd-dddd-dddd-dddddddddddd'::uuid,
      '22222222-2222-2222-2222-222222222222'::uuid,
      'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'::uuid,
      'test.company.created',
      '{}'::jsonb,
      '{"name":"Carrier B"}'::jsonb
    );
end;
$$;

\else

begin;
select plan(1);
select pass('tenant fixture helper is loadable through psql inclusion');
select * from finish();
rollback;

\endif
