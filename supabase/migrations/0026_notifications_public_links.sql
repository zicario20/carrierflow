-- E3-T3 notifications and public tracking capabilities. Public tracking is a
-- narrow resolver capability: opaque bearer tokens are hashed at rest and no
-- commercial/location table is ever readable by anon or authenticated clients.

create extension if not exists pgcrypto with schema extensions;

create table public.public_tracking_links (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete restrict,
  load_id uuid not null,
  token_hash bytea not null check (octet_length(token_hash) = 32),
  expires_at timestamptz not null,
  revoked_at timestamptz,
  allow_current_location boolean not null default false,
  eta_at timestamptz,
  created_by uuid not null references auth.users(id) on delete restrict,
  created_at timestamptz not null default timezone('utc', now()),
  unique (token_hash),
  unique (id, company_id),
  foreign key (load_id, company_id)
    references public.loads(id, company_id) on delete restrict,
  check (expires_at > created_at),
  check (revoked_at is null or revoked_at >= created_at)
);

-- This outbox deliberately has no device registration, destination token, or
-- transport payload. A future server-only sender may address an authorized
-- device and send only this event identifier as a refresh hint.
create table public.driver_push_events (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete restrict,
  load_id uuid not null,
  recipient_driver_id uuid not null,
  event_type text not null check (
    event_type in ('load_assigned', 'load_reassigned', 'load_changed', 'load_cancelled')
  ),
  source_kind text not null check (
    source_kind in ('dispatch_notification', 'load_state_event')
  ),
  source_id uuid not null,
  created_at timestamptz not null default timezone('utc', now()),
  delivered_at timestamptz,
  unique (company_id, source_kind, source_id, recipient_driver_id),
  foreign key (load_id, company_id)
    references public.loads(id, company_id) on delete restrict,
  foreign key (recipient_driver_id, company_id)
    references public.drivers(id, company_id) on delete restrict
);

create index public_tracking_links_company_load_expires_idx
  on public.public_tracking_links (company_id, load_id, expires_at desc)
  where revoked_at is null;
create index driver_push_events_pending_recipient_idx
  on public.driver_push_events (company_id, recipient_driver_id, created_at)
  where delivered_at is null;

alter table public.public_tracking_links enable row level security;
alter table public.public_tracking_links force row level security;
alter table public.driver_push_events enable row level security;
alter table public.driver_push_events force row level security;

revoke all on table public.public_tracking_links, public.driver_push_events
  from public, anon, authenticated;

create function public.create_public_tracking_link(
  target_company_id uuid,
  target_load_id uuid,
  expiry_at timestamptz,
  allow_current_location_value boolean,
  eta_at_value timestamptz
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor_id uuid := (select auth.uid());
  created_link public.public_tracking_links%rowtype;
  token_value text;
  token_attempt integer := 0;
begin
  if actor_id is null or target_company_id is null or target_load_id is null
    or expiry_at is null or allow_current_location_value is null
    or not public.has_active_company_role(
      target_company_id,
      array['owner', 'admin', 'dispatcher']::public.company_role[]
    ) then
    raise exception using errcode = '42501', message = 'an authorized dispatch context is required';
  end if;

  if expiry_at <= timezone('utc', now())
    or expiry_at > timezone('utc', now()) + interval '7 days' then
    raise exception using errcode = '22023', message = 'the tracking link expiry must be within seven days';
  end if;

  if not exists (
    select 1
    from public.loads as load
    where load.company_id = target_company_id
      and load.id = target_load_id
  ) then
    raise exception using errcode = '42501', message = 'an authorized dispatch context is required';
  end if;

  -- Retain only a SHA-256 verifier. The 256-bit token is returned once to the
  -- authorized manager and cannot be reconstructed from this row.
  loop
    token_attempt := token_attempt + 1;
    token_value := encode(extensions.gen_random_bytes(32), 'hex');
    begin
      insert into public.public_tracking_links (
        company_id, load_id, token_hash, expires_at, allow_current_location,
        eta_at, created_by
      ) values (
        target_company_id, target_load_id,
        extensions.digest(token_value, 'sha256'), expiry_at,
        allow_current_location_value, eta_at_value, actor_id
      ) returning * into created_link;
      exit;
    exception when unique_violation then
      if token_attempt >= 3 then
        raise;
      end if;
    end;
  end loop;

  insert into public.audit_events (
    company_id, actor_id, action, before_data, after_data, entity_type, entity_id
  ) values (
    target_company_id, actor_id, 'public_tracking_link.created',
    '{}'::jsonb,
    jsonb_build_object(
      'expiresAt', created_link.expires_at,
      'currentLocationAllowed', created_link.allow_current_location
    ),
    'public_tracking_link', created_link.id
  );

  return jsonb_build_object(
    'expiresAt', created_link.expires_at,
    'linkId', created_link.id,
    'token', token_value
  );
end;
$$;

create function public.revoke_public_tracking_link(
  target_company_id uuid,
  target_link_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor_id uuid := (select auth.uid());
  revoked_link public.public_tracking_links%rowtype;
  was_revoked boolean;
begin
  if actor_id is null or target_company_id is null or target_link_id is null
    or not public.has_active_company_role(
      target_company_id,
      array['owner', 'admin', 'dispatcher']::public.company_role[]
    ) then
    raise exception using errcode = '42501', message = 'an authorized dispatch context is required';
  end if;

  select tracking_link.revoked_at is not null into was_revoked
  from public.public_tracking_links as tracking_link
  where tracking_link.company_id = target_company_id
    and tracking_link.id = target_link_id
  for update;
  if not found then
    raise exception using errcode = '42501', message = 'an authorized dispatch context is required';
  end if;

  update public.public_tracking_links
  set revoked_at = coalesce(revoked_at, timezone('utc', now()))
  where company_id = target_company_id
    and id = target_link_id
  returning * into revoked_link;

  insert into public.audit_events (
    company_id, actor_id, action, before_data, after_data, entity_type, entity_id
  ) values (
    target_company_id, actor_id, 'public_tracking_link.revoked',
    jsonb_build_object('wasRevoked', was_revoked),
    jsonb_build_object('revokedAt', revoked_link.revoked_at),
    'public_tracking_link', revoked_link.id
  );

  return jsonb_build_object('revoked', true);
end;
$$;

create function public.resolve_public_load_tracking(token_value text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  link_row public.public_tracking_links%rowtype;
  public_location jsonb := null;
begin
  -- A malformed, unknown, expired, or revoked value has one indistinguishable
  -- result. Hashing is delegated to pgcrypto; raw values never reach a table
  -- comparison or a response payload.
  if token_value is null or token_value !~ '^[a-f0-9]{64}$' then
    return null;
  end if;

  select * into link_row
  from public.public_tracking_links as tracking_link
  where tracking_link.token_hash = extensions.digest(token_value, 'sha256')
    and tracking_link.revoked_at is null
    and tracking_link.expires_at > timezone('utc', now());
  if not found then
    return null;
  end if;

  if link_row.allow_current_location then
    select jsonb_build_object(
      'accuracyMeters', current_location.accuracy_meters,
      'latitude', current_location.latitude,
      'longitude', current_location.longitude,
      'recordedAt', current_location.recorded_at
    ) into public_location
    from public.current_driver_locations as current_location
    join public.loads as load
      on load.company_id = current_location.company_id
      and load.id = current_location.load_id
      and load.id = link_row.load_id
      and load.assigned_driver_id = current_location.driver_id
      and load.operational_status in (
        'en_route_to_pickup', 'arrived_pickup', 'loading', 'picked_up',
        'en_route_to_delivery', 'arrived_delivery', 'unloading'
      )
    join public.drivers as driver
      on driver.company_id = current_location.company_id
      and driver.id = current_location.driver_id
      and driver.status = 'active'
    join public.company_memberships as membership
      on membership.id = driver.membership_id
      and membership.company_id = driver.company_id
      and membership.role = 'driver'::public.company_role
      and membership.status = 'active'::public.membership_status
    where current_location.company_id = link_row.company_id
      and current_location.load_id = link_row.load_id
      and current_location.recorded_at >= timezone('utc', now()) - interval '5 minutes'
      and (
        exists (
          select 1
          from public.driver_shifts as shift
          where shift.company_id = current_location.company_id
            and shift.driver_id = current_location.driver_id
            and shift.off_duty_at is null
        )
        or load.operational_status in (
          'en_route_to_pickup', 'arrived_pickup', 'loading', 'picked_up',
          'en_route_to_delivery', 'arrived_delivery', 'unloading'
        )
      )
    order by current_location.recorded_at desc
    limit 1;
  end if;

  return (
    select jsonb_build_object(
      'operationalStatus', load.operational_status,
      'eta', link_row.eta_at,
      'currentLocation', public_location
    )
    from public.loads as load
    where load.company_id = link_row.company_id
      and load.id = link_row.load_id
  );
end;
$$;

create function public.enqueue_driver_push_for_dispatch_notification()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.driver_push_events (
    company_id, load_id, recipient_driver_id, event_type, source_kind, source_id
  ) values (
    new.company_id,
    new.load_id,
    new.recipient_driver_id,
    new.notification_type,
    'dispatch_notification',
    new.id
  ) on conflict (company_id, source_kind, source_id, recipient_driver_id) do nothing;
  return new;
end;
$$;

create function public.enqueue_driver_push_for_load_state_event()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  assigned_driver_id_value uuid;
begin
  -- Assignment has its dedicated notification row above. Every subsequent
  -- operational transition, including cancellation, produces one refresh hint.
  if new.to_status in ('draft', 'scheduled', 'assigned') then
    return new;
  end if;

  select load.assigned_driver_id into assigned_driver_id_value
  from public.loads as load
  where load.company_id = new.company_id
    and load.id = new.load_id;
  if assigned_driver_id_value is null then
    return new;
  end if;

  insert into public.driver_push_events (
    company_id, load_id, recipient_driver_id, event_type, source_kind, source_id
  ) values (
    new.company_id,
    new.load_id,
    assigned_driver_id_value,
    case when new.to_status = 'cancelled' then 'load_cancelled' else 'load_changed' end,
    'load_state_event',
    new.id
  ) on conflict (company_id, source_kind, source_id, recipient_driver_id) do nothing;
  return new;
end;
$$;

create trigger load_dispatch_notifications_enqueue_driver_push
after insert on public.load_dispatch_notifications
for each row execute function public.enqueue_driver_push_for_dispatch_notification();

create trigger load_state_events_enqueue_driver_push
after insert on public.load_state_events
for each row execute function public.enqueue_driver_push_for_load_state_event();

revoke all on function public.create_public_tracking_link(uuid, uuid, timestamptz, boolean, timestamptz)
  from public, anon;
revoke all on function public.revoke_public_tracking_link(uuid, uuid)
  from public, anon;
revoke all on function public.resolve_public_load_tracking(text)
  from public, authenticated;
revoke all on function public.enqueue_driver_push_for_dispatch_notification()
  from public, anon, authenticated;
revoke all on function public.enqueue_driver_push_for_load_state_event()
  from public, anon, authenticated;
grant execute on function public.create_public_tracking_link(uuid, uuid, timestamptz, boolean, timestamptz)
  to authenticated;
grant execute on function public.revoke_public_tracking_link(uuid, uuid)
  to authenticated;
grant execute on function public.resolve_public_load_tracking(text)
  to anon;
