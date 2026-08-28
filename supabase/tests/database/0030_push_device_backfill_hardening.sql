begin;

select plan(12);

\set tenant_fixture_setup true
\ir helpers/tenant-fixtures.sql
\unset tenant_fixture_setup
select test_helpers.seed_tenant_fixtures();

insert into auth.users (
  id, instance_id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at
) values (
  '98989898-9898-4898-8898-989898989898'::uuid,
  '00000000-0000-0000-0000-000000000000'::uuid,
  'authenticated', 'authenticated', 'push-backfill-driver@carrierflow.test',
  '$2a$10$not-a-real-password-hash-for-local-tests-only', timezone('utc', now()),
  '{}'::jsonb, '{}'::jsonb, timezone('utc', now()), timezone('utc', now())
);
insert into public.company_memberships (id, company_id, user_id, role, status)
values (
  '68686868-6868-4868-8868-686868686868'::uuid,
  '11111111-1111-1111-1111-111111111111'::uuid,
  '98989898-9898-4898-8898-989898989898'::uuid,
  'driver', 'active'
);

set local role authenticated;
select set_config('request.jwt.claim.sub', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', true);
select * from public.create_driver(
  '11111111-1111-1111-1111-111111111111'::uuid,
  '68686868-6868-4868-8868-686868686868'::uuid,
  'Push Backfill Driver'
);
select id as driver_id from public.drivers
where membership_id = '68686868-6868-4868-8868-686868686868'::uuid \gset
select * from public.create_pilot_load(
  '11111111-1111-1111-1111-111111111111'::uuid,
  'PUSH-BACKFILL-LOAD',
  '{"address":"1 Pickup Way","country":"US","timezone":"America/Chicago"}'::jsonb,
  '{"address":"2 Delivery Lane","country":"US","timezone":"America/Chicago"}'::jsonb
);
select id as load_id from public.loads where load_number = 'PUSH-BACKFILL-LOAD' \gset
reset role;

select ok(
  has_function_privilege(
    'service_role',
    'push_delivery_private.harden_legacy_driver_push_device_capacity()',
    'execute'
  ) and not has_function_privilege(
    'authenticated',
    'push_delivery_private.harden_legacy_driver_push_device_capacity()',
    'execute'
  ),
  'only the server-only maintenance boundary can run the legacy device-capacity hardening'
);

set local role service_role;
insert into public.driver_push_devices (
  id, company_id, driver_id, token_hash, token_ciphertext,
  token_encryption_version, token_iv, token_auth_tag, platform, status,
  registered_at, last_seen_at
) values
  (
    '10101010-1010-4010-8010-101010101001'::uuid,
    '11111111-1111-1111-1111-111111111111'::uuid, :'driver_id'::uuid,
    extensions.digest('legacy-capacity-one', 'sha256'), convert_to('opaque-ciphertext-one', 'utf8'),
    2, decode('000102030405060708090a0b', 'hex'), decode('000102030405060708090a0b0c0d0e0f', 'hex'),
    'android', 'active', timezone('utc', now()) - interval '4 hours', timezone('utc', now()) - interval '4 hours'
  ),
  (
    '10101010-1010-4010-8010-101010101002'::uuid,
    '11111111-1111-1111-1111-111111111111'::uuid, :'driver_id'::uuid,
    extensions.digest('legacy-capacity-two', 'sha256'), convert_to('opaque-ciphertext-two', 'utf8'),
    2, decode('000102030405060708090a0b', 'hex'), decode('000102030405060708090a0b0c0d0e0f', 'hex'),
    'ios', 'active', timezone('utc', now()) - interval '3 hours', timezone('utc', now()) - interval '3 hours'
  ),
  (
    '10101010-1010-4010-8010-101010101003'::uuid,
    '11111111-1111-1111-1111-111111111111'::uuid, :'driver_id'::uuid,
    extensions.digest('legacy-capacity-three', 'sha256'), convert_to('opaque-ciphertext-three', 'utf8'),
    2, decode('000102030405060708090a0b', 'hex'), decode('000102030405060708090a0b0c0d0e0f', 'hex'),
    'android', 'active', timezone('utc', now()) - interval '2 hours', timezone('utc', now()) - interval '2 hours'
  ),
  (
    '10101010-1010-4010-8010-101010101004'::uuid,
    '11111111-1111-1111-1111-111111111111'::uuid, :'driver_id'::uuid,
    extensions.digest('legacy-capacity-four', 'sha256'), convert_to('opaque-ciphertext-four', 'utf8'),
    2, decode('000102030405060708090a0b', 'hex'), decode('000102030405060708090a0b0c0d0e0f', 'hex'),
    'ios', 'active', timezone('utc', now()) - interval '1 hour', timezone('utc', now()) - interval '1 hour'
  );
select is(
  (select count(*) from public.driver_push_devices where driver_id = :'driver_id'::uuid and status = 'active'),
  4::bigint,
  'a simulated pre-hardening tenant can contain four legacy active devices'
);

insert into public.driver_push_events (
  company_id, load_id, recipient_driver_id, event_type, source_kind, source_id
) values (
  '11111111-1111-1111-1111-111111111111'::uuid,
  :'load_id'::uuid, :'driver_id'::uuid,
  'load_changed', 'load_state_event', '11111111-1111-4111-8111-111111111111'::uuid
) returning id as pending_event_id \gset
insert into public.driver_push_events (
  company_id, load_id, recipient_driver_id, event_type, source_kind, source_id
) values (
  '11111111-1111-1111-1111-111111111111'::uuid,
  :'load_id'::uuid, :'driver_id'::uuid,
  'load_changed', 'load_state_event', '22222222-2222-4222-8222-222222222222'::uuid
) returning id as claimed_event_id \gset
update public.driver_push_deliveries
set status = 'claimed',
    claim_token = '30303030-3030-4030-8030-303030303030'::uuid,
    claimed_at = timezone('utc', now()),
    claim_expires_at = timezone('utc', now()) + interval '5 minutes',
    updated_at = timezone('utc', now())
where push_event_id = :'claimed_event_id'::uuid
  and device_id = '10101010-1010-4010-8010-101010101001'::uuid;
select is(
  (select count(*) from public.driver_push_deliveries where device_id = '10101010-1010-4010-8010-101010101001'::uuid and status in ('pending', 'claimed')),
  2::bigint,
  'the oldest legacy device has both pending and claimed deliveries before backfill'
);

select is(
  push_delivery_private.harden_legacy_driver_push_device_capacity(),
  jsonb_build_object('deactivatedDeviceCount', 1),
  'the one-time hardener trims the pre-hardening excess deterministically'
);
select is(
  (select count(*) from public.driver_push_devices where driver_id = :'driver_id'::uuid and status = 'active'),
  3::bigint,
  'the hardener retains at most the newest three active devices'
);
select ok(
  (select status = 'deactivated' and deactivated_at is not null from public.driver_push_devices where id = '10101010-1010-4010-8010-101010101001'::uuid),
  'the oldest legacy device is deterministically deactivated'
);
select is(
  (select array_agg(id order by id) from public.driver_push_devices where driver_id = :'driver_id'::uuid and status = 'active'),
  array[
    '10101010-1010-4010-8010-101010101002'::uuid,
    '10101010-1010-4010-8010-101010101003'::uuid,
    '10101010-1010-4010-8010-101010101004'::uuid
  ],
  'the newest three legacy devices remain active after backfill'
);
select is(
  (select count(*) from public.driver_push_deliveries where device_id = '10101010-1010-4010-8010-101010101001'::uuid and status = 'suppressed'),
  2::bigint,
  'the hardener suppresses both pending and claimed deliveries for the deactivated device'
);
select ok(
  exists (
    select 1 from public.audit_events
    where action = 'push_device.deactivated_for_legacy_capacity'
      and entity_id = '10101010-1010-4010-8010-101010101001'::uuid
      and after_data = jsonb_build_object(
        'status', 'deactivated',
        'reason', 'legacy_active_device_cap_backfill',
        'maxActiveDevices', 3
      )
  ),
  'legacy capacity trimming writes a token-free audit event'
);
select ok(
  not exists (
    select 1 from public.audit_events
    where action = 'push_device.deactivated_for_legacy_capacity'
      and (before_data::text like '%legacy-capacity-%' or after_data::text like '%legacy-capacity-%')
  ),
  'the legacy capacity audit stores no token or token-hash material'
);

insert into public.driver_push_events (
  company_id, load_id, recipient_driver_id, event_type, source_kind, source_id
) values (
  '11111111-1111-1111-1111-111111111111'::uuid,
  :'load_id'::uuid, :'driver_id'::uuid,
  'load_changed', 'load_state_event', '33333333-3333-4333-8333-333333333333'::uuid
) returning id as after_event_id \gset
select is(
  (select count(*) from public.driver_push_deliveries where push_event_id = :'after_event_id'::uuid),
  3::bigint,
  'post-backfill events fan out to only the retained active devices'
);
reset role;

set local role authenticated;
select set_config('request.jwt.claim.sub', '98989898-9898-4898-8898-989898989898', true);
select throws_ok(
  $$select push_delivery_private.harden_legacy_driver_push_device_capacity()$$,
  '42501', null,
  'an authenticated driver cannot invoke the server-only legacy capacity hardener'
);
reset role;

select * from finish();
rollback;
