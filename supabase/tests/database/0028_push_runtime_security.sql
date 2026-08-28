begin;

select plan(22);

\set tenant_fixture_setup true
\ir helpers/tenant-fixtures.sql
\unset tenant_fixture_setup
select test_helpers.seed_tenant_fixtures();

insert into auth.users (
  id, instance_id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at
) values (
  '96969696-9696-9696-9696-969696969696'::uuid,
  '00000000-0000-0000-0000-000000000000'::uuid,
  'authenticated', 'authenticated', 'push-runtime-driver@carrierflow.test',
  '$2a$10$not-a-real-password-hash-for-local-tests-only', timezone('utc', now()),
  '{}'::jsonb, '{}'::jsonb, timezone('utc', now()), timezone('utc', now())
);
insert into public.company_memberships (id, company_id, user_id, role, status)
values (
  '67676767-6767-6767-6767-676767676767'::uuid,
  '11111111-1111-1111-1111-111111111111'::uuid,
  '96969696-9696-9696-9696-969696969696'::uuid,
  'driver', 'active'
);

select has_column('public', 'driver_push_devices', 'token_encryption_version', 'push devices identify their encryption format');
select has_column('public', 'driver_push_devices', 'token_iv', 'push devices retain an AES-GCM IV separately');
select has_column('public', 'driver_push_devices', 'token_auth_tag', 'push devices retain an AES-GCM authentication tag separately');
select ok(
  not has_function_privilege('authenticated', 'public.register_own_driver_push_device(text,text)', 'execute'),
  'an authenticated client cannot call the legacy GUC-backed registration RPC'
);
select ok(
  to_regprocedure('public.register_server_encrypted_driver_push_device(uuid,bytea,bytea,bytea,bytea,text)') is not null,
  'only a server-side writer may register an AES-encrypted device token'
);
select ok(
  case
    when to_regprocedure('public.register_server_encrypted_driver_push_device(uuid,bytea,bytea,bytea,bytea,text)') is null then false
    else has_function_privilege(
      'service_role',
      to_regprocedure('public.register_server_encrypted_driver_push_device(uuid,bytea,bytea,bytea,bytea,text)'),
      'execute'
    ) and not has_function_privilege(
      'authenticated',
      to_regprocedure('public.register_server_encrypted_driver_push_device(uuid,bytea,bytea,bytea,bytea,text)'),
      'execute'
    )
  end,
  'the encrypted registration writer is service-role-only'
);
select ok(
  position(
    'app.push_token_encryption_key' in pg_get_functiondef('public.claim_pending_driver_push_delivery(uuid)'::regprocedure)
  ) = 0
  and position(
    'pgp_sym_decrypt' in pg_get_functiondef('public.claim_pending_driver_push_delivery(uuid)'::regprocedure)
  ) = 0,
  'the active private claim path has no PostgREST GUC or PGP decryption dependency'
);
select is(
  (select count(*) from public.driver_push_devices where status = 'active' and token_encryption_version = 1),
  0::bigint,
  'legacy PGP device rows cannot remain active after the runtime hardening migration'
);

set local role authenticated;
select set_config('request.jwt.claim.sub', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', true);
select * from public.create_driver(
  '11111111-1111-1111-1111-111111111111'::uuid,
  '67676767-6767-6767-6767-676767676767'::uuid,
  'Push Runtime Driver'
);
select id as driver_id from public.drivers
where membership_id = '67676767-6767-6767-6767-676767676767'::uuid \gset
select * from public.create_vehicle(
  '11111111-1111-1111-1111-111111111111'::uuid,
  'PUSH-RUNTIME-UNIT', 'cargo_van', 3500
);
select id as vehicle_id from public.vehicles where unit_number = 'PUSH-RUNTIME-UNIT' \gset
select public.assign_driver_vehicle(
  '11111111-1111-1111-1111-111111111111'::uuid,
  :'driver_id'::uuid, :'vehicle_id'::uuid
);
reset role;

set local role authenticated;
select set_config('request.jwt.claim.sub', '96969696-9696-9696-9696-969696969696', true);
select throws_ok(
  $$select public.register_own_driver_push_device('private-fcm-token-abcdefghijklmnopqrstuvwxyz', 'android')$$,
  '42501', null,
  'the authenticated driver cannot revive the legacy GUC-backed registration path'
);
select throws_ok(
  format(
    'insert into public.driver_push_devices (company_id, driver_id, token_hash, token_ciphertext, token_encryption_version, token_iv, token_auth_tag, platform) values (%L::uuid, %L::uuid, extensions.digest(''client-bypass-token'', ''sha256''), convert_to(''client-bypass-token'', ''utf8''), 2, decode(''000102030405060708090a0b'', ''hex''), decode(''000102030405060708090a0b0c0d0e0f'', ''hex''), ''android'')',
    '11111111-1111-1111-1111-111111111111', :'driver_id'
  ),
  '42501', null,
  'a driver cannot bypass the server endpoint with direct device-table DML'
);
reset role;

set local role service_role;
select is(
  public.register_server_encrypted_driver_push_device(
    '96969696-9696-9696-9696-969696969696'::uuid,
    extensions.digest('private-fcm-token-abcdefghijklmnopqrstuvwxyz', 'sha256'),
    convert_to('aes-gcm-ciphertext-not-the-raw-provider-token', 'utf8'),
    decode('000102030405060708090a0b', 'hex'),
    decode('000102030405060708090a0b0c0d0e0f', 'hex'),
    'android'
  ),
  jsonb_build_object('registered', true),
  'the trusted server can register an AES envelope for its verified driver user'
);
reset role;
select is((select count(*) from public.driver_push_devices where driver_id = :'driver_id'::uuid), 1::bigint, 'one encrypted private destination is registered for the active driver');
select is((select octet_length(token_hash) from public.driver_push_devices where driver_id = :'driver_id'::uuid), 32, 'the private lookup material remains a SHA-256 token hash');
select ok(
  (select token_encryption_version = 2 and octet_length(token_iv) = 12 and octet_length(token_auth_tag) = 16 from public.driver_push_devices where driver_id = :'driver_id'::uuid),
  'the private destination stores a versioned AES-GCM IV and authentication tag'
);
select ok(
  (select token_ciphertext <> convert_to('private-fcm-token-abcdefghijklmnopqrstuvwxyz', 'utf8') from public.driver_push_devices where driver_id = :'driver_id'::uuid),
  'the database never stores the raw provider token as ciphertext'
);
select ok(
  not exists (
    select 1 from public.audit_events
    where entity_type = 'driver_push_device'
      and after_data::text like '%private-fcm-token-abcdefghijklmnopqrstuvwxyz%'
  ),
  'the registration audit contains no raw push token'
);

set local role authenticated;
select set_config('request.jwt.claim.sub', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', true);
select * from public.create_pilot_load(
  '11111111-1111-1111-1111-111111111111'::uuid,
  'PUSH-RUNTIME-A',
  '{"address":"1 Pickup Way","country":"US","timezone":"America/Chicago"}'::jsonb,
  '{"address":"2 Delivery Lane","country":"US","timezone":"America/Chicago"}'::jsonb
);
select id as load_id from public.loads where load_number = 'PUSH-RUNTIME-A' \gset
select public.assign_load_resources(
  '11111111-1111-1111-1111-111111111111'::uuid,
  :'load_id'::uuid, :'driver_id'::uuid, :'vehicle_id'::uuid,
  '64646464-6464-4646-8464-646464646464'::uuid
);
select public.advance_load_state(
  '11111111-1111-1111-1111-111111111111'::uuid,
  :'load_id'::uuid, 'en_route_to_pickup'
);
reset role;
select is(
  (select count(*) from public.driver_push_deliveries as delivery join public.driver_push_events as event on event.id = delivery.push_event_id where event.load_id = :'load_id'::uuid),
  2::bigint,
  'assignment and the later operational event each create one private encrypted delivery claim'
);

set local role authenticated;
select set_config('request.jwt.claim.sub', '96969696-9696-9696-9696-969696969696', true);
select throws_ok(
  $$select public.claim_pending_driver_push_delivery('60606060-6060-4060-8060-606060606060'::uuid)$$,
  '42501', null,
  'an authenticated client cannot claim an encrypted envelope'
);
reset role;
set local role service_role;
select result as claim_result
from (select public.claim_pending_driver_push_delivery('61616161-6161-4161-8161-616161616161'::uuid) as result) as claimed \gset
select ok(
  (:'claim_result'::jsonb ? 'ciphertext')
  and (:'claim_result'::jsonb ? 'iv')
  and (:'claim_result'::jsonb ? 'authTag')
  and not (:'claim_result'::jsonb ? 'deviceToken'),
  'a service-role claim returns only an encrypted envelope, never a raw provider token'
);
select is(
  (select array_agg(key order by key) from jsonb_object_keys(:'claim_result'::jsonb) as key),
  array['authTag', 'ciphertext', 'deliveryId', 'iv', 'leaseToken', 'notificationId']::text[],
  'the private claim contains only lease mechanics, encrypted bytes, and opaque notification id'
);
select ok(
  public.complete_driver_push_delivery(
    (:'claim_result'::jsonb ->> 'deliveryId')::uuid,
    (:'claim_result'::jsonb ->> 'leaseToken')::uuid
  ),
  'the service-role worker can idempotently acknowledge a sent envelope'
);
reset role;
select is(
  (select status from public.driver_push_deliveries where id = (:'claim_result'::jsonb ->> 'deliveryId')::uuid),
  'delivered',
  'the completed encrypted delivery reaches a terminal state'
);

select * from finish();
rollback;
