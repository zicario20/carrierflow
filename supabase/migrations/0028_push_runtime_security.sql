-- E3-T3 security correction. Migration 0027 remains immutable; this forward
-- migration retires its per-connection PGP/GUC flow in favour of application
-- server AES-256-GCM encryption. The database never receives plaintext or a
-- client-provided encryption key.

alter table public.driver_push_devices
  add column token_encryption_version smallint not null default 1,
  add column token_iv bytea,
  add column token_auth_tag bytea;

alter table public.driver_push_devices
  add constraint driver_push_devices_encryption_parts_ck check (
    (token_encryption_version = 1 and token_iv is null and token_auth_tag is null)
    or (
      token_encryption_version = 2
      and octet_length(token_iv) = 12
      and octet_length(token_auth_tag) = 16
    )
  ) not valid;

-- Existing 0027 PGP records cannot be decrypted by the new server-only AES
-- path. Deactivate them and suppress outstanding work: a signed-in driver
-- must register again through the authenticated application endpoint.
update public.driver_push_devices
set status = 'deactivated',
    deactivated_at = coalesce(deactivated_at, timezone('utc', now()))
where token_encryption_version = 1
  and status = 'active';

update public.driver_push_deliveries as delivery
set status = 'suppressed',
    suppressed_at = coalesce(delivery.suppressed_at, timezone('utc', now())),
    updated_at = timezone('utc', now())
from public.driver_push_devices as device
where device.id = delivery.device_id
  and device.company_id = delivery.company_id
  and device.token_encryption_version = 1
  and delivery.status in ('pending', 'claimed');

alter table public.driver_push_devices
  validate constraint driver_push_devices_encryption_parts_ck;

-- No authenticated client may use the old GUC-backed function after this
-- point. The definition stays only as immutable migration history.
revoke all on function public.register_own_driver_push_device(text, text)
  from public, anon, authenticated, service_role;

-- This function is deliberately service-role-only. Its target user identity
-- is supplied by the trusted endpoint *after* auth.getUser verifies the
-- bearer. It derives driver/company rows itself and accepts neither tenant,
-- driver nor load scope from a mobile client.
create function public.register_server_encrypted_driver_push_device(
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
  candidate record;
  registered_device public.driver_push_devices%rowtype;
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

-- The claim intentionally returns only the opaque encrypted envelope. Node
-- decrypts it in memory with PUSH_TOKEN_ENCRYPTION_KEY immediately before the
-- Firebase Admin send; no raw provider token or database GUC is involved.
create or replace function public.claim_pending_driver_push_delivery(worker_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  selected_delivery public.driver_push_deliveries%rowtype;
  selected_device public.driver_push_devices%rowtype;
  lease_token_value uuid := gen_random_uuid();
begin
  if worker_id is null then
    raise exception using errcode = '22023', message = 'a worker identifier is required';
  end if;

  select delivery.* into selected_delivery
  from public.driver_push_deliveries as delivery
  join public.driver_push_devices as device
    on device.id = delivery.device_id
    and device.company_id = delivery.company_id
    and device.status = 'active'
    and device.token_encryption_version = 2
    and octet_length(device.token_iv) = 12
    and octet_length(device.token_auth_tag) = 16
  where delivery.status = 'pending'
    or (
      delivery.status = 'claimed'
      and delivery.claim_expires_at <= timezone('utc', now())
    )
  order by delivery.created_at, delivery.id
  limit 1
  for update of delivery skip locked;

  if not found then
    return null;
  end if;

  select * into selected_device
  from public.driver_push_devices as device
  where device.id = selected_delivery.device_id
    and device.company_id = selected_delivery.company_id
  for update;
  if not found
    or selected_device.status <> 'active'
    or selected_device.token_encryption_version <> 2
    or octet_length(selected_device.token_iv) <> 12
    or octet_length(selected_device.token_auth_tag) <> 16 then
    update public.driver_push_deliveries
    set status = 'suppressed',
        suppressed_at = timezone('utc', now()),
        updated_at = timezone('utc', now())
    where id = selected_delivery.id;
    return null;
  end if;

  update public.driver_push_deliveries
  set status = 'claimed',
      attempt_count = attempt_count + 1,
      claim_token = lease_token_value,
      claimed_at = timezone('utc', now()),
      claim_expires_at = timezone('utc', now()) + interval '5 minutes',
      updated_at = timezone('utc', now())
  where id = selected_delivery.id
  returning * into selected_delivery;

  return jsonb_build_object(
    'deliveryId', selected_delivery.id,
    'ciphertext', encode(selected_device.token_ciphertext, 'base64'),
    'iv', encode(selected_device.token_iv, 'base64'),
    'authTag', encode(selected_device.token_auth_tag, 'base64'),
    'leaseToken', selected_delivery.claim_token,
    'notificationId', selected_delivery.push_event_id
  );
end;
$$;

revoke all on function public.register_server_encrypted_driver_push_device(uuid, bytea, bytea, bytea, bytea, text)
  from public, anon, authenticated;
grant execute on function public.register_server_encrypted_driver_push_device(uuid, bytea, bytea, bytea, bytea, text)
  to service_role;
