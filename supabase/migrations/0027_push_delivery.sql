-- E3-T3 forward-only push delivery. The minimal 0026 event outbox remains
-- destination-free. Device tokens are encrypted at rest and can be decrypted
-- only by a service_role worker claim; mobile clients use a zero-scope RPC.

create extension if not exists pgcrypto with schema extensions;

create table public.driver_push_devices (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete restrict,
  driver_id uuid not null,
  token_hash bytea not null check (octet_length(token_hash) = 32),
  token_ciphertext bytea not null check (octet_length(token_ciphertext) > 0),
  platform text not null check (platform in ('android', 'ios')),
  status text not null default 'active' check (
    status in ('active', 'invalidated', 'deactivated')
  ),
  registered_at timestamptz not null default timezone('utc', now()),
  last_seen_at timestamptz not null default timezone('utc', now()),
  invalidated_at timestamptz,
  deactivated_at timestamptz,
  unique (company_id, driver_id, token_hash),
  unique (id, company_id),
  foreign key (driver_id, company_id)
    references public.drivers(id, company_id) on delete restrict,
  check (
    (status = 'active' and invalidated_at is null and deactivated_at is null)
    or (status = 'invalidated' and invalidated_at is not null)
    or (status = 'deactivated' and deactivated_at is not null)
  )
);

create table public.driver_push_deliveries (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete restrict,
  push_event_id uuid not null references public.driver_push_events(id) on delete restrict,
  device_id uuid not null,
  status text not null default 'pending' check (
    status in ('pending', 'claimed', 'delivered', 'invalidated', 'suppressed')
  ),
  attempt_count integer not null default 0 check (attempt_count >= 0),
  claim_token uuid,
  claimed_at timestamptz,
  claim_expires_at timestamptz,
  delivered_at timestamptz,
  invalidated_at timestamptz,
  suppressed_at timestamptz,
  created_at timestamptz not null default timezone('utc', now()),
  updated_at timestamptz not null default timezone('utc', now()),
  unique (push_event_id, device_id),
  unique (id, company_id),
  foreign key (device_id, company_id)
    references public.driver_push_devices(id, company_id) on delete restrict,
  check (
    (status = 'pending' and claim_token is null and claimed_at is null and claim_expires_at is null)
    or (status = 'claimed' and claim_token is not null and claimed_at is not null and claim_expires_at is not null)
    or (status = 'delivered' and claim_token is not null and delivered_at is not null)
    or (status = 'invalidated' and claim_token is not null and invalidated_at is not null)
    or (status = 'suppressed' and suppressed_at is not null)
  )
);

create index driver_push_devices_active_recipient_idx
  on public.driver_push_devices (company_id, driver_id, last_seen_at desc)
  where status = 'active';
create index driver_push_deliveries_claim_idx
  on public.driver_push_deliveries (created_at, id)
  where status in ('pending', 'claimed');

alter table public.driver_push_devices enable row level security;
alter table public.driver_push_devices force row level security;
alter table public.driver_push_deliveries enable row level security;
alter table public.driver_push_deliveries force row level security;

revoke all on table public.driver_push_devices, public.driver_push_deliveries
  from public, anon, authenticated;

-- The only mobile token write accepts neither tenant nor driver identity. A
-- per-connection operator GUC supplies the encryption key. The key is never
-- returned, logged, audited, or accepted as a client argument.
create function public.register_own_driver_push_device(
  push_token text,
  platform_value text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor_id uuid := (select auth.uid());
  key_value text := nullif(btrim(current_setting('app.push_token_encryption_key', true)), '');
  normalized_token text := btrim(push_token);
  normalized_platform text := lower(btrim(platform_value));
  candidate record;
  registered_device public.driver_push_devices%rowtype;
  registered_count integer := 0;
begin
  if actor_id is null then
    raise exception using errcode = '42501', message = 'an active driver context is required';
  end if;
  if key_value is null then
    raise exception using errcode = '22023', message = 'push device encryption is unavailable';
  end if;
  if normalized_token is null
    or char_length(normalized_token) not between 20 and 4096
    or normalized_token !~ '^[A-Za-z0-9:_-]+$' then
    raise exception using errcode = '22023', message = 'a valid push token is required';
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
    where membership.user_id = actor_id
      and membership.role = 'driver'::public.company_role
      and membership.status = 'active'::public.membership_status
      and driver.status = 'active'
    for update of driver
  loop
    insert into public.driver_push_devices (
      company_id, driver_id, token_hash, token_ciphertext, platform, status,
      registered_at, last_seen_at, invalidated_at, deactivated_at
    ) values (
      candidate.company_id,
      candidate.driver_id,
      extensions.digest(normalized_token, 'sha256'),
      extensions.pgp_sym_encrypt(
        normalized_token,
        key_value,
        'cipher-algo=aes256,compress-algo=0'
      ),
      normalized_platform,
      'active',
      timezone('utc', now()), timezone('utc', now()), null, null
    ) on conflict (company_id, driver_id, token_hash) do update set
      token_ciphertext = excluded.token_ciphertext,
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
      actor_id,
      'push_device.registered',
      '{}'::jsonb,
      jsonb_build_object('platform', normalized_platform, 'status', 'active'),
      'driver_push_device',
      registered_device.id
    );
    registered_count := registered_count + 1;
  end loop;

  if registered_count = 0 then
    raise exception using errcode = '42501', message = 'an active driver context is required';
  end if;

  -- No device, tenant, driver, or token value crosses the mobile boundary.
  return jsonb_build_object('registered', true);
end;
$$;

create function public.enqueue_push_deliveries_for_event()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.driver_push_deliveries (
    company_id, push_event_id, device_id, status
  )
  select new.company_id, new.id, device.id, 'pending'
  from public.driver_push_devices as device
  where device.company_id = new.company_id
    and device.driver_id = new.recipient_driver_id
    and device.status = 'active'
  on conflict (push_event_id, device_id) do nothing;
  return new;
end;
$$;

create trigger driver_push_events_enqueue_deliveries
after insert on public.driver_push_events
for each row execute function public.enqueue_push_deliveries_for_event();

-- Driver/membership deactivation suppresses any queued delivery before it can
-- be claimed. Invalid provider-token responses are handled by a worker RPC
-- below; neither path gives clients table DML access.
create function public.deactivate_driver_push_devices_for_lifecycle()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if tg_table_name = 'drivers' then
    if new.status = 'active' then
      return new;
    end if;
    update public.driver_push_devices
    set status = 'deactivated',
        deactivated_at = coalesce(deactivated_at, timezone('utc', now()))
    where company_id = new.company_id
      and driver_id = new.id
      and status = 'active';
  elsif tg_table_name = 'company_memberships' then
    if new.status = 'active' then
      return new;
    end if;
    update public.driver_push_devices as device
    set status = 'deactivated',
        deactivated_at = coalesce(device.deactivated_at, timezone('utc', now()))
    from public.drivers as driver
    where driver.company_id = new.company_id
      and driver.membership_id = new.id
      and device.company_id = driver.company_id
      and device.driver_id = driver.id
      and device.status = 'active';
  end if;

  update public.driver_push_deliveries as delivery
  set status = 'suppressed',
      suppressed_at = coalesce(delivery.suppressed_at, timezone('utc', now())),
      updated_at = timezone('utc', now())
  from public.driver_push_devices as device
  where delivery.company_id = device.company_id
    and delivery.device_id = device.id
    and delivery.status in ('pending', 'claimed')
    and device.status <> 'active';

  return new;
end;
$$;

create trigger drivers_deactivate_push_devices
after update of status on public.drivers
for each row execute function public.deactivate_driver_push_devices_for_lifecycle();
create trigger memberships_deactivate_push_devices
after update of status on public.company_memberships
for each row execute function public.deactivate_driver_push_devices_for_lifecycle();

-- This is intentionally service_role-only. It is the one boundary that may
-- decrypt a destination, and it returns only the private destination plus the
-- opaque refresh-event UUID required by FCM. The operator key must be set on
-- the worker connection; absence fails closed before a claim is made.
create function public.claim_pending_driver_push_delivery(worker_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  key_value text := nullif(btrim(current_setting('app.push_token_encryption_key', true)), '');
  selected_delivery public.driver_push_deliveries%rowtype;
  selected_device public.driver_push_devices%rowtype;
  lease_token_value uuid := gen_random_uuid();
  token_value text;
begin
  if worker_id is null then
    raise exception using errcode = '22023', message = 'a worker identifier is required';
  end if;
  if key_value is null then
    raise exception using errcode = '22023', message = 'push device encryption is unavailable';
  end if;

  select delivery.* into selected_delivery
  from public.driver_push_deliveries as delivery
  join public.driver_push_devices as device
    on device.id = delivery.device_id
    and device.company_id = delivery.company_id
    and device.status = 'active'
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
  if not found or selected_device.status <> 'active' then
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

  token_value := extensions.pgp_sym_decrypt(selected_device.token_ciphertext, key_value);
  if token_value is null or char_length(token_value) = 0 then
    raise exception using errcode = '22023', message = 'a registered push device is unavailable';
  end if;

  return jsonb_build_object(
    'deliveryId', selected_delivery.id,
    'deviceToken', token_value,
    'leaseToken', selected_delivery.claim_token,
    'notificationId', selected_delivery.push_event_id
  );
end;
$$;

create function public.complete_driver_push_delivery(
  delivery_id_value uuid,
  lease_token_value uuid
)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  completed_delivery public.driver_push_deliveries%rowtype;
begin
  if delivery_id_value is null or lease_token_value is null then
    raise exception using errcode = '22023', message = 'a delivery lease is required';
  end if;

  update public.driver_push_deliveries
  set status = 'delivered',
      delivered_at = coalesce(delivered_at, timezone('utc', now())),
      updated_at = timezone('utc', now())
  where id = delivery_id_value
    and status = 'claimed'
    and claim_token = lease_token_value
  returning * into completed_delivery;

  if not found then
    select * into completed_delivery
    from public.driver_push_deliveries
    where id = delivery_id_value
      and status = 'delivered'
      and claim_token = lease_token_value;
    if not found then
      return false;
    end if;
  end if;

  update public.driver_push_events as event
  set delivered_at = coalesce(event.delivered_at, timezone('utc', now()))
  where event.id = completed_delivery.push_event_id
    and not exists (
      select 1
      from public.driver_push_deliveries as delivery
      where delivery.push_event_id = event.id
        and delivery.status in ('pending', 'claimed')
    );
  return true;
end;
$$;

create function public.release_driver_push_delivery(
  delivery_id_value uuid,
  lease_token_value uuid
)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
begin
  if delivery_id_value is null or lease_token_value is null then
    raise exception using errcode = '22023', message = 'a delivery lease is required';
  end if;

  update public.driver_push_deliveries
  set status = 'pending',
      claim_token = null,
      claimed_at = null,
      claim_expires_at = null,
      updated_at = timezone('utc', now())
  where id = delivery_id_value
    and status = 'claimed'
    and claim_token = lease_token_value;
  return found;
end;
$$;

create function public.invalidate_driver_push_device(
  delivery_id_value uuid,
  lease_token_value uuid
)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  invalidated_delivery public.driver_push_deliveries%rowtype;
begin
  if delivery_id_value is null or lease_token_value is null then
    raise exception using errcode = '22023', message = 'a delivery lease is required';
  end if;

  update public.driver_push_deliveries
  set status = 'invalidated',
      invalidated_at = timezone('utc', now()),
      updated_at = timezone('utc', now())
  where id = delivery_id_value
    and status = 'claimed'
    and claim_token = lease_token_value
  returning * into invalidated_delivery;
  if not found then
    return false;
  end if;

  update public.driver_push_devices
  set status = 'invalidated',
      invalidated_at = timezone('utc', now())
  where id = invalidated_delivery.device_id
    and company_id = invalidated_delivery.company_id
    and status = 'active';

  update public.driver_push_events as event
  set delivered_at = coalesce(event.delivered_at, timezone('utc', now()))
  where event.id = invalidated_delivery.push_event_id
    and not exists (
      select 1
      from public.driver_push_deliveries as delivery
      where delivery.push_event_id = event.id
        and delivery.status in ('pending', 'claimed')
    );
  return true;
end;
$$;

revoke all on function public.register_own_driver_push_device(text, text)
  from public, anon;
revoke all on function public.enqueue_push_deliveries_for_event()
  from public, anon, authenticated;
revoke all on function public.deactivate_driver_push_devices_for_lifecycle()
  from public, anon, authenticated;
revoke all on function public.claim_pending_driver_push_delivery(uuid)
  from public, anon, authenticated;
revoke all on function public.complete_driver_push_delivery(uuid, uuid)
  from public, anon, authenticated;
revoke all on function public.release_driver_push_delivery(uuid, uuid)
  from public, anon, authenticated;
revoke all on function public.invalidate_driver_push_device(uuid, uuid)
  from public, anon, authenticated;

grant execute on function public.register_own_driver_push_device(text, text)
  to authenticated;
grant execute on function public.claim_pending_driver_push_delivery(uuid)
  to service_role;
grant execute on function public.complete_driver_push_delivery(uuid, uuid)
  to service_role;
grant execute on function public.release_driver_push_delivery(uuid, uuid)
  to service_role;
grant execute on function public.invalidate_driver_push_device(uuid, uuid)
  to service_role;
