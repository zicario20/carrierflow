begin;

select plan(28);

\set tenant_fixture_setup true
\ir helpers/tenant-fixtures.sql
\unset tenant_fixture_setup
select test_helpers.seed_tenant_fixtures();

insert into auth.users (
  id, instance_id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at
) values (
  '95959595-9595-9595-9595-959595959595'::uuid,
  '00000000-0000-0000-0000-000000000000'::uuid,
  'authenticated', 'authenticated', 'public-track-driver@carrierflow.test',
  '$2a$10$not-a-real-password-hash-for-local-tests-only', timezone('utc', now()),
  '{}'::jsonb, '{}'::jsonb, timezone('utc', now()), timezone('utc', now())
);
insert into public.company_memberships (id, company_id, user_id, role, status)
values (
  '65656565-6565-6565-6565-656565656565'::uuid,
  '11111111-1111-1111-1111-111111111111'::uuid,
  '95959595-9595-9595-9595-959595959595'::uuid,
  'driver', 'active'
);

select has_table('public', 'public_tracking_links', 'public tracking links are capabilities in a dedicated private table');
select has_table('public', 'driver_push_events', 'driver push refresh events are a separate private outbox');
select ok((select relrowsecurity and relforcerowsecurity from pg_class where oid = 'public.public_tracking_links'::regclass), 'public tracking capabilities use forced RLS');
select ok((select relrowsecurity and relforcerowsecurity from pg_class where oid = 'public.driver_push_events'::regclass), 'push refresh events use forced RLS');
select ok(not has_table_privilege('anon', 'public.public_tracking_links', 'select,insert,update,delete'), 'anon has no direct commercial capability-table access');
select ok(not has_table_privilege('authenticated', 'public.driver_push_events', 'select,insert,update,delete'), 'mobile clients have no direct push outbox access');
select ok(to_regprocedure('public.create_public_tracking_link(uuid,uuid,timestamptz,boolean,timestamptz)') is not null, 'manager capability creation is a narrow authenticated RPC');
select ok(has_function_privilege('anon', 'public.resolve_public_load_tracking(text)', 'execute'), 'anon receives only the narrow public resolver capability');

set local role authenticated;
select set_config('request.jwt.claim.sub', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', true);
select * from public.create_driver(
  '11111111-1111-1111-1111-111111111111'::uuid,
  '65656565-6565-6565-6565-656565656565'::uuid,
  'Public Tracking Driver'
);
select id as driver_id from public.drivers
where membership_id = '65656565-6565-6565-6565-656565656565'::uuid \gset
select * from public.create_vehicle(
  '11111111-1111-1111-1111-111111111111'::uuid,
  'PUBLIC-TRACK-UNIT', 'cargo_van', 3500
);
select id as vehicle_id from public.vehicles
where unit_number = 'PUBLIC-TRACK-UNIT' \gset
select public.assign_driver_vehicle(
  '11111111-1111-1111-1111-111111111111'::uuid,
  :'driver_id'::uuid, :'vehicle_id'::uuid
);
select * from public.create_pilot_load(
  '11111111-1111-1111-1111-111111111111'::uuid,
  'PUBLIC-TRACK-A',
  '{"address":"1 Pickup Way","country":"US","timezone":"America/Chicago"}'::jsonb,
  '{"address":"2 Delivery Lane","country":"US","timezone":"America/Chicago"}'::jsonb
);
select id as load_id from public.loads where load_number = 'PUBLIC-TRACK-A' \gset
select public.assign_load_resources(
  '11111111-1111-1111-1111-111111111111'::uuid,
  :'load_id'::uuid, :'driver_id'::uuid, :'vehicle_id'::uuid,
  '51515151-5151-4515-8515-515151515151'::uuid
);
reset role;
select is(
  (select count(*) from public.driver_push_events where load_id = :'load_id'::uuid),
  1::bigint,
  'assignment produces one addressed refresh event without a client-provided device token'
);
select ok(
  not (select to_jsonb(event) ?| array['cargo', 'coordinates', 'documents', 'location', 'price', 'pricing']
       from public.driver_push_events as event where event.load_id = :'load_id'::uuid),
  'the assignment refresh outbox contains no cargo, location, pricing, or document payload'
);
set local role authenticated;
select set_config('request.jwt.claim.sub', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', true);
select public.advance_load_state(
  '11111111-1111-1111-1111-111111111111'::uuid,
  :'load_id'::uuid, 'en_route_to_pickup'
);
reset role;
select is(
  (select count(*) from public.driver_push_events where load_id = :'load_id'::uuid and event_type = 'load_changed'),
  1::bigint,
  'an operational state change produces one minimal driver refresh event'
);

set local role authenticated;
select set_config('request.jwt.claim.sub', '95959595-9595-9595-9595-959595959595', true);
select lives_ok(
  $$select public.record_own_driver_location_sample(41.8781, -87.6298, 8, 12, 90, timezone('utc', now()))$$,
  'the active assigned driver records a fresh current point before a configured public release'
);
reset role;

set local role authenticated;
select set_config('request.jwt.claim.sub', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', true);
select result ->> 'token' as valid_token,
       result ->> 'linkId' as valid_link_id
from (
  select public.create_public_tracking_link(
    '11111111-1111-1111-1111-111111111111'::uuid,
    :'load_id'::uuid,
    timezone('utc', now()) + interval '1 day',
    true,
    null
  ) as result
) as created \gset
select ok(:'valid_token' ~ '^[a-f0-9]{64}$', 'capability token has opaque 256-bit hex entropy');
reset role;
select is(
  (select octet_length(token_hash) from public.public_tracking_links where id = :'valid_link_id'::uuid),
  32,
  'only the SHA-256 verifier is retained at rest'
);
select ok(
  not exists(
    select 1 from public.public_tracking_links
    where encode(token_hash, 'hex') = :'valid_token'
  ),
  'the raw opaque token is never stored as a verifier'
);

set local role anon;
select is(
  public.resolve_public_load_tracking(:'valid_token') ->> 'operationalStatus',
  'en_route_to_pickup',
  'a valid capability releases only its one load operational status'
);
select is(
  public.resolve_public_load_tracking(:'valid_token') ->> 'eta',
  null,
  'an unavailable ETA is explicitly null-safe rather than fabricated'
);
select is(
  public.resolve_public_load_tracking(:'valid_token') #>> '{currentLocation,latitude}',
  '41.8781',
  'configured public tracking releases only the fresh current coordinate for its exact load'
);
select ok(
  not (public.resolve_public_load_tracking(:'valid_token') ?| array[
    'companyId', 'documents', 'driverId', 'fleet', 'linkId', 'loadId', 'loadNumber', 'token'
  ]),
  'public resolver never returns capability metadata, commercial identifiers, fleet, or private documents'
);
select is(
  public.resolve_public_load_tracking(repeat('0', 64)),
  null::jsonb,
  'an unknown opaque token produces the same empty resolver result'
);
reset role;

set local role authenticated;
select set_config('request.jwt.claim.sub', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', true);
select result ->> 'token' as no_location_token
from (
  select public.create_public_tracking_link(
    '11111111-1111-1111-1111-111111111111'::uuid,
    :'load_id'::uuid,
    timezone('utc', now()) + interval '1 day',
    false,
    null
  ) as result
) as created \gset
select result ->> 'token' as revoked_token,
       result ->> 'linkId' as revoked_link_id
from (
  select public.create_public_tracking_link(
    '11111111-1111-1111-1111-111111111111'::uuid,
    :'load_id'::uuid,
    timezone('utc', now()) + interval '1 day',
    false,
    null
  ) as result
) as created \gset
select lives_ok(
  format(
    'select public.revoke_public_tracking_link(%L::uuid, %L::uuid)',
    '11111111-1111-1111-1111-111111111111',
    :'revoked_link_id'
  ),
  'a manager can revoke a capability without exposing its raw token'
);
select is(
  (
    select before_data ->> 'wasRevoked'
    from public.audit_events
    where entity_type = 'public_tracking_link'
      and entity_id = :'revoked_link_id'::uuid
      and action = 'public_tracking_link.revoked'
    order by occurred_at desc
    limit 1
  ),
  'false',
  'revocation audit preserves the prior capability state without token metadata'
);
reset role;
set local role anon;
select ok(
  public.resolve_public_load_tracking(:'no_location_token') -> 'currentLocation' = 'null'::jsonb,
  'a valid capability without the exact current-location flag releases no coordinates'
);
select is(
  public.resolve_public_load_tracking(:'revoked_token'),
  null::jsonb,
  'a revoked token has the same empty resolver result as an unknown token'
);
reset role;

insert into public.public_tracking_links (
  company_id, load_id, token_hash, expires_at, allow_current_location, eta_at, created_by, created_at
) values (
  '11111111-1111-1111-1111-111111111111'::uuid,
  :'load_id'::uuid,
  extensions.digest(repeat('e', 64), 'sha256'),
  timezone('utc', now()) - interval '1 minute',
  false, null,
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'::uuid,
  timezone('utc', now()) - interval '2 minutes'
);
set local role anon;
select is(
  public.resolve_public_load_tracking(repeat('e', 64)),
  null::jsonb,
  'an expired token has the same empty resolver result as an unknown token'
);
reset role;

set local role authenticated;
select set_config('request.jwt.claim.sub', 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', true);
select throws_ok(
  format(
    'select public.create_public_tracking_link(%L::uuid, %L::uuid, timezone(''utc'', now()) + interval ''1 day'', false, null)',
    '11111111-1111-1111-1111-111111111111',
    :'load_id'
  ),
  '42501', null,
  'a manager from another tenant cannot mint a capability for this load'
);
select throws_ok(
  format(
    'insert into public.public_tracking_links (company_id, load_id, token_hash, expires_at, allow_current_location, created_by) values (%L::uuid, %L::uuid, extensions.digest(repeat(''f'', 64), ''sha256''), timezone(''utc'', now()) + interval ''1 day'', false, %L::uuid)',
    '11111111-1111-1111-1111-111111111111',
    :'load_id',
    'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'
  ),
  '42501', null,
  'an authenticated client cannot bypass the manager capability RPC with direct DML'
);
reset role;

set local role authenticated;
select set_config('request.jwt.claim.sub', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', true);
select public.cancel_load_idempotent(
  '11111111-1111-1111-1111-111111111111'::uuid,
  :'load_id'::uuid,
  '52525252-5252-4525-8525-525252525252'::uuid
);
reset role;
select is(
  (select count(*) from public.driver_push_events where load_id = :'load_id'::uuid and event_type = 'load_cancelled'),
  1::bigint,
  'cancellation produces one minimal addressed refresh event'
);

select * from finish();
rollback;
