-- E3-T3 forward-only abuse hardening. Migration 0028 remains immutable.
-- The trusted endpoint authenticates a bearer with auth.getUser and supplies
-- only that user id to this service-role writer. The writer derives every
-- company/driver row itself, caps active devices per driver, and records a
-- persistent per-actor registration window without storing a raw FCM token.

create table public.driver_push_registration_rate_limits (
  actor_id uuid primary key references auth.users(id) on delete cascade,
  window_started_at timestamptz not null,
  attempt_count integer not null check (attempt_count between 0 and 10),
  updated_at timestamptz not null default timezone('utc', now())
);

alter table public.driver_push_registration_rate_limits enable row level security;
alter table public.driver_push_registration_rate_limits force row level security;
revoke all on table public.driver_push_registration_rate_limits
  from public, anon, authenticated;

-- Driver-row locking in the registration writer serializes the capacity check.
-- This index provides the deterministic LRU candidate without scanning another
-- driver's device set.
create index driver_push_devices_active_capacity_lru_idx
  on public.driver_push_devices (
    company_id, driver_id, last_seen_at asc, registered_at asc, id asc
  )
  where status = 'active';

create or replace function public.register_server_encrypted_driver_push_device(
  target_user_id uuid,
  token_hash_value bytea,
  token_ciphertext_value bytea,
  token_iv_value bytea,
  token_auth_tag_value bytea,
  platform_value text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  normalized_platform text := lower(btrim(platform_value));
  rate_limit public.driver_push_registration_rate_limits%rowtype;
  candidate record;
  existing_device public.driver_push_devices%rowtype;
  evicted_device public.driver_push_devices%rowtype;
  registered_device public.driver_push_devices%rowtype;
  active_device_count integer := 0;
  needs_active_slot boolean := false;
  has_active_driver boolean := false;
  registered_count integer := 0;
begin
  if target_user_id is null then
    raise exception using errcode = '42501', message = 'an active driver context is required';
  end if;
  if token_hash_value is null or octet_length(token_hash_value) <> 32
    or token_ciphertext_value is null or octet_length(token_ciphertext_value) = 0
    or token_iv_value is null or octet_length(token_iv_value) <> 12
    or token_auth_tag_value is null or octet_length(token_auth_tag_value) <> 16 then
    raise exception using errcode = '22023', message = 'a valid encrypted push token is required';
  end if;
  if normalized_platform not in ('android', 'ios') then
    raise exception using errcode = '22023', message = 'a valid push platform is required';
  end if;

  select exists (
    select 1
    from public.drivers as driver
    join public.company_memberships as membership
      on membership.id = driver.membership_id
      and membership.company_id = driver.company_id
    where membership.user_id = target_user_id
      and membership.role = 'driver'::public.company_role
      and membership.status = 'active'::public.membership_status
      and driver.status = 'active'
  ) into has_active_driver;
  if not has_active_driver then
    raise exception using errcode = '42501', message = 'an active driver context is required';
  end if;

  -- This insert-plus-row-lock serializes concurrent requests for the same
  -- endpoint-authenticated actor. A service role cannot select an arbitrary
  -- company, driver, or load through this API.
  insert into public.driver_push_registration_rate_limits (
    actor_id, window_started_at, attempt_count, updated_at
  ) values (
    target_user_id, timezone('utc', now()), 0, timezone('utc', now())
  ) on conflict (actor_id) do nothing;

  select * into rate_limit
  from public.driver_push_registration_rate_limits
  where actor_id = target_user_id
  for update;

  if rate_limit.window_started_at <= timezone('utc', now()) - interval '1 hour' then
    update public.driver_push_registration_rate_limits
    set window_started_at = timezone('utc', now()),
        attempt_count = 1,
        updated_at = timezone('utc', now())
    where actor_id = target_user_id;
  elsif rate_limit.attempt_count >= 10 then
    raise exception using
      errcode = 'P0001',
      message = 'push device registration rate limit exceeded';
  else
    update public.driver_push_registration_rate_limits
    set attempt_count = attempt_count + 1,
        updated_at = timezone('utc', now())
    where actor_id = target_user_id;
  end if;

  for candidate in
    select driver.company_id, driver.id as driver_id
    from public.drivers as driver
    join public.company_memberships as membership
      on membership.id = driver.membership_id
      and membership.company_id = driver.company_id
    where membership.user_id = target_user_id
      and membership.role = 'driver'::public.company_role
      and membership.status = 'active'::public.membership_status
      and driver.status = 'active'
    for update of driver
  loop
    select * into existing_device
    from public.driver_push_devices as device
    where device.company_id = candidate.company_id
      and device.driver_id = candidate.driver_id
      and device.token_hash = token_hash_value
    for update;
    needs_active_slot := not found or existing_device.status <> 'active';

    if needs_active_slot then
      select count(*) into active_device_count
      from public.driver_push_devices as device
      where device.company_id = candidate.company_id
        and device.driver_id = candidate.driver_id
        and device.status = 'active';

      if active_device_count >= 3 then
        select * into evicted_device
        from public.driver_push_devices as device
        where device.company_id = candidate.company_id
          and device.driver_id = candidate.driver_id
          and device.status = 'active'
        order by device.last_seen_at asc, device.registered_at asc, device.id asc
        limit 1
        for update;

        update public.driver_push_devices
        set status = 'deactivated',
            deactivated_at = timezone('utc', now())
        where id = evicted_device.id
          and company_id = candidate.company_id
          and status = 'active';

        update public.driver_push_deliveries
        set status = 'suppressed',
            suppressed_at = coalesce(suppressed_at, timezone('utc', now())),
            updated_at = timezone('utc', now())
        where company_id = candidate.company_id
          and device_id = evicted_device.id
          and status in ('pending', 'claimed');

        insert into public.audit_events (
          company_id, actor_id, action, before_data, after_data, entity_type, entity_id
        ) values (
          candidate.company_id,
          target_user_id,
          'push_device.deactivated_for_capacity',
          jsonb_build_object('status', 'active'),
          jsonb_build_object(
            'status', 'deactivated',
            'reason', 'active_device_limit',
            'maxActiveDevices', 3
          ),
          'driver_push_device',
          evicted_device.id
        );
      end if;
    end if;

    insert into public.driver_push_devices (
      company_id, driver_id, token_hash, token_ciphertext, token_encryption_version,
      token_iv, token_auth_tag, platform, status, registered_at, last_seen_at,
      invalidated_at, deactivated_at
    ) values (
      candidate.company_id, candidate.driver_id, token_hash_value,
      token_ciphertext_value, 2, token_iv_value, token_auth_tag_value,
      normalized_platform, 'active', timezone('utc', now()), timezone('utc', now()),
      null, null
    ) on conflict (company_id, driver_id, token_hash) do update set
      token_ciphertext = excluded.token_ciphertext,
      token_encryption_version = 2,
      token_iv = excluded.token_iv,
      token_auth_tag = excluded.token_auth_tag,
      platform = excluded.platform,
      status = 'active',
      last_seen_at = timezone('utc', now()),
      invalidated_at = null,
      deactivated_at = null
    returning * into registered_device;

    insert into public.audit_events (
      company_id, actor_id, action, before_data, after_data, entity_type, entity_id
    ) values (
      candidate.company_id,
      target_user_id,
      'push_device.registered',
      '{}'::jsonb,
      jsonb_build_object(
        'platform', normalized_platform,
        'status', 'active',
        'encryptionVersion', 2
      ),
      'driver_push_device',
      registered_device.id
    );
    registered_count := registered_count + 1;
  end loop;

  if registered_count = 0 then
    raise exception using errcode = '42501', message = 'an active driver context is required';
  end if;

  return jsonb_build_object('registered', true);
end;
$$;

revoke all on function public.register_server_encrypted_driver_push_device(uuid, bytea, bytea, bytea, bytea, text)
  from public, anon, authenticated;
grant execute on function public.register_server_encrypted_driver_push_device(uuid, bytea, bytea, bytea, bytea, text)
  to service_role;
