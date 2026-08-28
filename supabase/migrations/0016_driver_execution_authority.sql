-- Driver mobile authority boundary. These zero-scope RPCs derive the active
-- driver, company and assigned load from auth.uid(); the Flutter client never
-- supplies a tenant, driver, load, or operational target state.

create table public.driver_incident_receipts (
  actor_id uuid not null references auth.users(id) on delete restrict,
  client_mutation_id uuid not null,
  company_id uuid not null references public.companies(id) on delete restrict,
  load_id uuid not null,
  incident_id uuid not null,
  request_fingerprint text not null check (char_length(request_fingerprint) = 32),
  created_at timestamptz not null default now(),
  primary key (actor_id, client_mutation_id),
  foreign key (load_id, company_id)
    references public.loads (id, company_id) on delete restrict,
  foreign key (incident_id, company_id)
    references public.load_incidents (id, company_id) on delete restrict
);

alter table public.driver_incident_receipts enable row level security;
alter table public.driver_incident_receipts force row level security;
revoke all on table public.driver_incident_receipts from public, anon, authenticated;

-- Kept private: all public driver RPCs below invoke this helper while
-- retaining auth.uid() as the effective actor. Its ordering matches the
-- mobile current/next partition: an active operational load precedes an
-- assigned upcoming load, independent of updated_at response ordering.
create function public.current_own_driver_load()
returns public.loads
language plpgsql
security definer
set search_path = ''
as $$
declare
  current_actor_id uuid := (select auth.uid());
  selected_load public.loads%rowtype;
begin
  if current_actor_id is null then
    raise exception using errcode = '42501', message = 'no active assigned load is available for this driver';
  end if;

  select load.* into selected_load
  from public.loads as load
  join public.drivers as driver
    on driver.id = load.assigned_driver_id
    and driver.company_id = load.company_id
  join public.company_memberships as membership
    on membership.id = driver.membership_id
    and membership.company_id = driver.company_id
  where membership.user_id = current_actor_id
    and membership.role = 'driver'::public.company_role
    and membership.status = 'active'::public.membership_status
    and driver.status = 'active'
    and load.operational_status in (
      'assigned', 'en_route_to_pickup', 'arrived_pickup', 'loading',
      'picked_up', 'en_route_to_delivery', 'arrived_delivery', 'unloading'
    )
  order by
    case when load.operational_status = 'assigned' then 1 else 0 end,
    load.load_number,
    load.id
  limit 1
  for update of load;

  if not found then
    raise exception using errcode = '42501', message = 'no active assigned load is available for this driver';
  end if;
  return selected_load;
end;
$$;

create function public.next_driver_operational_status(current_status text)
returns text
language sql
immutable
set search_path = ''
as $$
  select case current_status
    when 'assigned' then 'en_route_to_pickup'
    when 'en_route_to_pickup' then 'arrived_pickup'
    when 'arrived_pickup' then 'loading'
    when 'loading' then 'picked_up'
    when 'picked_up' then 'en_route_to_delivery'
    when 'en_route_to_delivery' then 'arrived_delivery'
    when 'arrived_delivery' then 'unloading'
    when 'unloading' then 'delivered'
    else null
  end;
$$;

create function public.get_own_driver_assigned_loads()
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'loadId', visible_load.id,
        'loadNumber', visible_load.load_number,
        'pickupLabel', visible_load.pickup_label,
        'deliveryLabel', visible_load.delivery_label,
        'operationalStatus', visible_load.operational_status
      ) order by
        case when visible_load.operational_status = 'assigned' then 1 else 0 end,
        visible_load.load_number,
        visible_load.id
    ),
    '[]'::jsonb
  )
  from (
    select
      load.id,
      load.load_number,
      load.operational_status,
      coalesce((
        select nullif(btrim(stop.stop_data ->> 'address'), '')
        from public.load_stops as stop
        where stop.company_id = load.company_id
          and stop.load_id = load.id
          and stop.stop_type = 'pickup'
        order by stop.sequence
        limit 1
      ), '—') as pickup_label,
      coalesce((
        select nullif(btrim(stop.stop_data ->> 'address'), '')
        from public.load_stops as stop
        where stop.company_id = load.company_id
          and stop.load_id = load.id
          and stop.stop_type = 'delivery'
        order by stop.sequence
        limit 1
      ), '—') as delivery_label
    from public.loads as load
    join public.drivers as driver
      on driver.id = load.assigned_driver_id
      and driver.company_id = load.company_id
    join public.company_memberships as membership
      on membership.id = driver.membership_id
      and membership.company_id = driver.company_id
    where membership.user_id = (select auth.uid())
      and membership.role = 'driver'::public.company_role
      and membership.status = 'active'::public.membership_status
      and driver.status = 'active'
      and load.operational_status in (
        'assigned', 'en_route_to_pickup', 'arrived_pickup', 'loading',
        'picked_up', 'en_route_to_delivery', 'arrived_delivery', 'unloading'
      )
  ) as visible_load;
$$;

create function public.get_own_driver_execution_snapshot()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  selected_load public.loads%rowtype;
begin
  selected_load := public.current_own_driver_load();
  return jsonb_build_object(
    'loadId', selected_load.id,
    'loadNumber', selected_load.load_number,
    'pickupLabel', coalesce((
      select nullif(btrim(stop.stop_data ->> 'address'), '')
      from public.load_stops as stop
      where stop.company_id = selected_load.company_id
        and stop.load_id = selected_load.id
        and stop.stop_type = 'pickup'
      order by stop.sequence
      limit 1
    ), '—'),
    'deliveryLabel', coalesce((
      select nullif(btrim(stop.stop_data ->> 'address'), '')
      from public.load_stops as stop
      where stop.company_id = selected_load.company_id
        and stop.load_id = selected_load.id
        and stop.stop_type = 'delivery'
      order by stop.sequence
      limit 1
    ), '—'),
    'operationalStatus', selected_load.operational_status,
    'serverDefinedNextStatus', public.next_driver_operational_status(selected_load.operational_status),
    'requiredDeliveryEvidence', coalesce((
      select jsonb_agg(requirement.requirement_type order by requirement.requirement_type)
      from public.load_evidence_requirements as requirement
      where requirement.company_id = selected_load.company_id
        and requirement.load_id = selected_load.id
    ), '[]'::jsonb),
    'recordedEvidence', coalesce((
      select jsonb_agg(jsonb_build_object(
        'type', evidence.evidence_type,
        'recordedAt', evidence.recorded_at
      ) order by evidence.recorded_at, evidence.id)
      from public.load_evidence as evidence
      where evidence.company_id = selected_load.company_id
        and evidence.load_id = selected_load.id
    ), '[]'::jsonb)
  );
end;
$$;

create function public.advance_own_driver_load_state()
returns public.loads
language plpgsql
security definer
set search_path = ''
as $$
declare
  selected_load public.loads%rowtype;
  next_status text;
begin
  selected_load := public.current_own_driver_load();
  next_status := public.next_driver_operational_status(selected_load.operational_status);
  if next_status is null then
    raise exception using errcode = '22023', message = 'no driver transition is available';
  end if;
  return public.advance_load_state(
    selected_load.company_id,
    selected_load.id,
    next_status
  );
end;
$$;

create function public.record_own_driver_load_evidence(
  evidence_type_value text,
  evidence_content jsonb
)
returns public.load_evidence
language plpgsql
security definer
set search_path = ''
as $$
declare
  selected_load public.loads%rowtype;
  receipt_key text;
  normalized_evidence_content jsonb := evidence_content;
begin
  selected_load := public.current_own_driver_load();
  if evidence_type_value in ('photo', 'bol', 'pod') then
    receipt_key := evidence_content ->> 'receiptKey';
    if not coalesce(
      jsonb_typeof(evidence_content) = 'object'
      and jsonb_typeof(evidence_content -> 'receiptKey') = 'string'
      and receipt_key ~ '^[a-z0-9][a-z0-9_-]{0,95}$',
      false
    ) then
      raise exception using errcode = '22023', message = 'a valid private evidence receipt is required';
    end if;
    normalized_evidence_content := jsonb_build_object(
      'storagePath', format(
        'private/%s/loads/%s/evidence/%s',
        selected_load.company_id,
        selected_load.id,
        receipt_key
      )
    );
  end if;
  return public.record_load_evidence(
    selected_load.company_id,
    selected_load.id,
    evidence_type_value,
    normalized_evidence_content
  );
end;
$$;

create function public.report_own_driver_load_incident_idempotent(
  client_mutation_id uuid,
  incident_type_value text,
  incident_description text,
  incident_attachments jsonb default '[]'::jsonb,
  incident_location jsonb default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  current_actor_id uuid := (select auth.uid());
  selected_load public.loads%rowtype;
  receipt public.driver_incident_receipts%rowtype;
  created_incident public.load_incidents%rowtype;
  request_fingerprint text;
  normalized_incident_attachments jsonb;
begin
  if current_actor_id is null or client_mutation_id is null then
    raise exception using errcode = '22023', message = 'a valid incident mutation id is required';
  end if;
  request_fingerprint := pg_catalog.md5(
    coalesce(incident_type_value, '') || '|' ||
    coalesce(btrim(incident_description), '') || '|' ||
    coalesce(incident_attachments::text, 'null') || '|' ||
    coalesce(incident_location::text, 'null')
  );
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(current_actor_id::text || ':driver-incident:' || client_mutation_id::text, 0)
  );
  select * into receipt
  from public.driver_incident_receipts as saved_receipt
  where saved_receipt.actor_id = current_actor_id
    and saved_receipt.client_mutation_id = $1
  for update;
  if found then
    if receipt.request_fingerprint <> request_fingerprint then
      raise exception using errcode = '22023', message = 'incident mutation id cannot be reused with different data';
    end if;
    select * into created_incident
    from public.load_incidents as incident
    where incident.company_id = receipt.company_id
      and incident.id = receipt.incident_id;
    if not found then
      raise exception using errcode = '42501', message = 'the stored incident receipt is no longer available';
    end if;
    -- A receipt-first replay is deliberately allowed after reassignment or
    -- deactivation, but must not turn this SECURITY DEFINER boundary into an
    -- historical incident read. The opaque client mutation id is all the
    -- offline outbox needs to confirm its durable acknowledgement.
    return jsonb_build_object('clientMutationId', client_mutation_id);
  end if;

  selected_load := public.current_own_driver_load();
  if not coalesce(
    jsonb_typeof(incident_attachments) = 'array'
    and jsonb_array_length(incident_attachments) <= 10
    and not exists (
      select 1
      from jsonb_array_elements(incident_attachments) as attachment(value)
      where jsonb_typeof(attachment.value) <> 'string'
        or attachment.value #>> '{}' !~ '^[a-z0-9][a-z0-9_-]{0,95}$'
    ),
    false
  ) then
    raise exception using errcode = '22023', message = 'valid private incident receipts are required';
  end if;
  select coalesce(
    jsonb_agg(to_jsonb(format(
      'private/%s/loads/%s/evidence/%s',
      selected_load.company_id,
      selected_load.id,
      attachment.value #>> '{}'
    ))),
    '[]'::jsonb
  ) into normalized_incident_attachments
  from jsonb_array_elements(incident_attachments) as attachment(value);

  select * into created_incident from public.report_load_incident(
    selected_load.company_id,
    selected_load.id,
    incident_type_value,
    incident_description,
    normalized_incident_attachments,
    incident_location
  );
  insert into public.driver_incident_receipts (
    actor_id, client_mutation_id, company_id, load_id, incident_id, request_fingerprint
  ) values (
    current_actor_id, client_mutation_id, selected_load.company_id, selected_load.id,
    created_incident.id, request_fingerprint
  );
  return jsonb_build_object('clientMutationId', client_mutation_id);
end;
$$;

revoke all on function public.current_own_driver_load() from public, anon, authenticated;
revoke all on function public.next_driver_operational_status(text) from public, anon, authenticated;
revoke all on function public.get_own_driver_assigned_loads() from public, anon;
revoke all on function public.get_own_driver_execution_snapshot() from public, anon;
revoke all on function public.advance_own_driver_load_state() from public, anon;
revoke all on function public.record_own_driver_load_evidence(text, jsonb) from public, anon;
revoke all on function public.report_own_driver_load_incident_idempotent(uuid, text, text, jsonb, jsonb) from public, anon;
grant execute on function public.get_own_driver_assigned_loads() to authenticated;
grant execute on function public.get_own_driver_execution_snapshot() to authenticated;
grant execute on function public.advance_own_driver_load_state() to authenticated;
grant execute on function public.record_own_driver_load_evidence(text, jsonb) to authenticated;
grant execute on function public.report_own_driver_load_incident_idempotent(uuid, text, text, jsonb, jsonb) to authenticated;
