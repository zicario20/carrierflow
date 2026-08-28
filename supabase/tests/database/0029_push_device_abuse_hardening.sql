begin;

select plan(20);

\set tenant_fixture_setup true
\ir helpers/tenant-fixtures.sql
\unset tenant_fixture_setup
select test_helpers.seed_tenant_fixtures();

insert into auth.users (
  id, instance_id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at
) values (
  '97979797-9797-4797-8797-979797979797'::uuid,
  '00000000-0000-0000-0000-000000000000'::uuid,
  'authenticated', 'authenticated', 'push-cap-driver@carrierflow.test',
  '$2a$10$not-a-real-password-hash-for-local-tests-only', timezone('utc', now()),
  '{}'::jsonb, '{}'::jsonb, timezone('utc', now()), timezone('utc', now())
);
insert into public.company_memberships (id, company_id, user_id, role, status)
values (
  '67676767-6767-6767-6767-676767676768'::uuid,
  '11111111-1111-1111-1111-111111111111'::uuid,
  '97979797-9797-4797-8797-979797979797'::uuid,
  'driver', 'active'
);

set local role authenticated;
select set_config('request.jwt.claim.sub', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', true);
select * from public.create_driver(
  '11111111-1111-1111-1111-111111111111'::uuid,
  '67676767-6767-6767-6767-676767676768'::uuid,
  'Push Cap Driver'
);
select id as driver_id from public.drivers
where membership_id = '67676767-6767-6767-6767-676767676768'::uuid \gset
select * from public.create_pilot_load(
  '11111111-1111-1111-1111-111111111111'::uuid,
  'PUSH-CAP-LOAD',
  '{"address":"1 Pickup Way","country":"US","timezone":"America/Chicago"}'::jsonb,
  '{"address":"2 Delivery Lane","country":"US","timezone":"America/Chicago"}'::jsonb
);
select id as load_id from public.loads where load_number = 'PUSH-CAP-LOAD' \gset
reset role;

select has_table('public', 'driver_push_registration_rate_limits', 'push registration keeps a private persistent actor limiter');
select has_column('public', 'driver_push_registration_rate_limits', 'attempt_count', 'the private limiter records attempts atomically per actor');
select ok(
  to_regprocedure('public.register_server_encrypted_driver_push_device(uuid,bytea,bytea,bytea,bytea,text)') is not null
  and has_function_privilege(
    'service_role',
    'public.register_server_encrypted_driver_push_device(uuid,bytea,bytea,bytea,bytea,text)',
    'execute'
  ),
  'the hardened writer remains available only to the trusted service-role boundary'
);
select ok(
  not has_function_privilege(
    'authenticated',
    'public.register_server_encrypted_driver_push_device(uuid,bytea,bytea,bytea,bytea,text)',
    'execute'
  ),
  'an authenticated client cannot bypass endpoint-authenticated registration'
);

set local role authenticated;
select set_config('request.jwt.claim.sub', '97979797-9797-4797-8797-979797979797', true);
select throws_ok(
  $$insert into public.driver_push_registration_rate_limits (actor_id, window_started_at, attempt_count) values ('97979797-9797-4797-8797-979797979797'::uuid, timezone('utc', now()), 1)$$,
  '42501', null,
  'an authenticated driver cannot mutate the private registration limiter'
);
reset role;

set local role service_role;
select is(
  public.register_server_encrypted_driver_push_device(
    '97979797-9797-4797-8797-979797979797'::uuid,
    extensions.digest('private-fcm-token-one-abcdefghijklmnopqrstuvwxyz', 'sha256'),
    convert_to('ciphertext-one', 'utf8'),
    decode('000102030405060708090a0b', 'hex'),
    decode('000102030405060708090a0b0c0d0e0f', 'hex'),
    'android'
  ),
  jsonb_build_object('registered', true),
  'the first active device registers through the actor-derived writer'
);
select is(
  public.register_server_encrypted_driver_push_device(
    '97979797-9797-4797-8797-979797979797'::uuid,
    extensions.digest('private-fcm-token-two-abcdefghijklmnopqrstuvwxyz', 'sha256'),
    convert_to('ciphertext-two', 'utf8'),
    decode('000102030405060708090a0b', 'hex'),
    decode('000102030405060708090a0b0c0d0e0f', 'hex'),
    'ios'
  ),
  jsonb_build_object('registered', true),
  'the second active device registers through the actor-derived writer'
);
select is(
  public.register_server_encrypted_driver_push_device(
    '97979797-9797-4797-8797-979797979797'::uuid,
    extensions.digest('private-fcm-token-three-abcdefghijklmnopqrstuvwxyz', 'sha256'),
    convert_to('ciphertext-three', 'utf8'),
    decode('000102030405060708090a0b', 'hex'),
    decode('000102030405060708090a0b0c0d0e0f', 'hex'),
    'android'
  ),
  jsonb_build_object('registered', true),
  'the third active device registers through the actor-derived writer'
);
select is(
  (select count(*) from public.driver_push_devices where driver_id = :'driver_id'::uuid and status = 'active'),
  3::bigint,
  'a driver begins with exactly three active encrypted devices'
);

update public.driver_push_devices
set last_seen_at = case
  when token_hash = extensions.digest('private-fcm-token-one-abcdefghijklmnopqrstuvwxyz', 'sha256') then timezone('utc', now()) - interval '3 hours'
  when token_hash = extensions.digest('private-fcm-token-two-abcdefghijklmnopqrstuvwxyz', 'sha256') then timezone('utc', now()) - interval '2 hours'
  else timezone('utc', now()) - interval '1 hour'
end
where driver_id = :'driver_id'::uuid;

select is(
  public.register_server_encrypted_driver_push_device(
    '97979797-9797-4797-8797-979797979797'::uuid,
    extensions.digest('private-fcm-token-one-abcdefghijklmnopqrstuvwxyz', 'sha256'),
    convert_to('ciphertext-one-refreshed', 'utf8'),
    decode('000102030405060708090a0b', 'hex'),
    decode('000102030405060708090a0b0c0d0e0f', 'hex'),
    'android'
  ),
  jsonb_build_object('registered', true),
  're-registering the same token updates its existing device instead of consuming a slot'
);
select is(
  (select count(*) from public.driver_push_devices where driver_id = :'driver_id'::uuid and status = 'active'),
  3::bigint,
  'replaying a token leaves the active device count capped at three'
);

select is(
  public.register_server_encrypted_driver_push_device(
    '97979797-9797-4797-8797-979797979797'::uuid,
    extensions.digest('private-fcm-token-four-abcdefghijklmnopqrstuvwxyz', 'sha256'),
    convert_to('ciphertext-four', 'utf8'),
    decode('000102030405060708090a0b', 'hex'),
    decode('000102030405060708090a0b0c0d0e0f', 'hex'),
    'ios'
  ),
  jsonb_build_object('registered', true),
  'a fourth device registration is accepted by deterministic replacement'
);
select is(
  (select count(*) from public.driver_push_devices where driver_id = :'driver_id'::uuid and status = 'active'),
  3::bigint,
  'a fourth registration never exceeds the three-device active cap'
);
select is(
  (select status from public.driver_push_devices where driver_id = :'driver_id'::uuid and token_hash = extensions.digest('private-fcm-token-two-abcdefghijklmnopqrstuvwxyz', 'sha256')),
  'deactivated',
  'the deterministic least-recently-seen active device is replaced'
);
select ok(
  exists (
    select 1 from public.audit_events
    where actor_id = '97979797-9797-4797-8797-979797979797'::uuid
      and action = 'push_device.deactivated_for_capacity'
      and entity_id = (
        select id from public.driver_push_devices
        where driver_id = :'driver_id'::uuid
          and token_hash = extensions.digest('private-fcm-token-two-abcdefghijklmnopqrstuvwxyz', 'sha256')
      )
  ),
  'capacity replacement is auditable without storing a raw provider token'
);

insert into public.driver_push_events (
  company_id, load_id, recipient_driver_id, event_type, source_kind, source_id
) values (
  '11111111-1111-1111-1111-111111111111'::uuid,
  :'load_id'::uuid,
  :'driver_id'::uuid,
  'load_changed', 'load_state_event', '12121212-1212-4121-8121-121212121212'::uuid
) returning id as push_event_id \gset
select is(
  (select count(*) from public.driver_push_deliveries where push_event_id = :'push_event_id'::uuid),
  3::bigint,
  'one outbox event fans out to no more than the three active devices'
);
select is(
  (select count(*) from public.driver_push_deliveries as delivery join public.driver_push_devices as device on device.id = delivery.device_id where delivery.push_event_id = :'push_event_id'::uuid and device.status <> 'active'),
  0::bigint,
  'fanout excludes the deactivated capacity-replacement device'
);

do $$
begin
  for ignored in 1..5 loop
    perform public.register_server_encrypted_driver_push_device(
      '97979797-9797-4797-8797-979797979797'::uuid,
      extensions.digest('private-fcm-token-one-abcdefghijklmnopqrstuvwxyz', 'sha256'),
      convert_to('ciphertext-one-rate-check', 'utf8'),
      decode('000102030405060708090a0b', 'hex'),
      decode('000102030405060708090a0b0c0d0e0f', 'hex'),
      'android'
    );
  end loop;
end;
$$;
select is(
  (select attempt_count from public.driver_push_registration_rate_limits where actor_id = '97979797-9797-4797-8797-979797979797'::uuid),
  10,
  'the persistent actor limiter counts registrations in its one-hour window'
);
select throws_ok(
  $$select public.register_server_encrypted_driver_push_device('97979797-9797-4797-8797-979797979797'::uuid, extensions.digest('private-fcm-token-one-abcdefghijklmnopqrstuvwxyz', 'sha256'), convert_to('ciphertext-rate-limited', 'utf8'), decode('000102030405060708090a0b', 'hex'), decode('000102030405060708090a0b0c0d0e0f', 'hex'), 'android')$$,
  'P0001', 'push device registration rate limit exceeded',
  'the eleventh registration in the persistent actor window is rate limited'
);
select ok(
  not exists (
    select 1 from public.audit_events
    where entity_type = 'driver_push_device'
      and after_data::text like '%private-fcm-token-%'
  ),
  'registration and capacity audits retain no raw push token'
);

reset role;
select * from finish();
rollback;
