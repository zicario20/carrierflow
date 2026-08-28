-- CarrierFlow dispatch foundation: tenant-scoped loads, ordered stops,
-- configurable evidence and incidents. All writes remain inside narrow,
-- authenticated RPC boundaries with immutable audit history.

create table public.loads (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete restrict,
  load_number text not null check (
    load_number = upper(btrim(load_number))
    and char_length(load_number) between 1 and 80
  ),
  operational_status text not null default 'draft' check (
    operational_status in (
      'draft', 'scheduled', 'assigned', 'en_route_to_pickup',
      'arrived_pickup', 'loading', 'picked_up', 'en_route_to_delivery',
      'arrived_delivery', 'unloading', 'delivered', 'closed', 'cancelled'
    )
  ),
  assigned_driver_id uuid,
  assigned_vehicle_id uuid,
  created_by uuid not null references auth.users(id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (id, company_id),
  unique (company_id, load_number),
  foreign key (assigned_driver_id, company_id)
    references public.drivers (id, company_id) on delete restrict,
  foreign key (assigned_vehicle_id, company_id)
    references public.vehicles (id, company_id) on delete restrict
);

create table public.load_stops (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete restrict,
  load_id uuid not null,
  sequence integer not null check (sequence > 0),
  stop_type text not null check (stop_type in ('pickup', 'delivery')),
  stop_data jsonb not null check (jsonb_typeof(stop_data) = 'object'),
  country_code text not null check (country_code in ('US', 'CA')),
  timezone_name text not null check (char_length(btrim(timezone_name)) between 1 and 80),
  created_at timestamptz not null default now(),
  unique (id, company_id),
  unique (load_id, sequence),
  foreign key (load_id, company_id)
    references public.loads (id, company_id) on delete restrict
);

create table public.load_evidence_requirements (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete restrict,
  load_id uuid not null,
  requirement_type text not null check (
    requirement_type in (
      'photo', 'receiver_name', 'signature', 'bol', 'pod',
      'reference_number', 'delivery_timestamp', 'delivery_gps'
    )
  ),
  created_at timestamptz not null default now(),
  unique (load_id, requirement_type),
  foreign key (load_id, company_id)
    references public.loads (id, company_id) on delete restrict
);

create table public.load_evidence (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete restrict,
  load_id uuid not null,
  evidence_type text not null check (
    evidence_type in (
      'photo', 'receiver_name', 'signature', 'bol', 'pod',
      'reference_number', 'delivery_timestamp', 'delivery_gps'
    )
  ),
  evidence_value jsonb not null check (
    jsonb_typeof(evidence_value) = 'object' and evidence_value <> '{}'::jsonb
  ),
  recorded_by uuid not null references auth.users(id) on delete restrict,
  recorded_at timestamptz not null default now(),
  unique (id, company_id),
  foreign key (load_id, company_id)
    references public.loads (id, company_id) on delete restrict
);

create table public.load_incidents (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete restrict,
  load_id uuid not null,
  incident_type text not null check (
    incident_type in (
      'pickup_issue', 'delivery_issue', 'breakdown', 'bad_address',
      'customer_unavailable', 'site_rejected_load', 'accident_emergency',
      'awaiting_instruction'
    )
  ),
  description text not null check (char_length(btrim(description)) between 1 and 2000),
  attachments jsonb not null default '[]'::jsonb check (jsonb_typeof(attachments) = 'array'),
  location jsonb check (location is null or jsonb_typeof(location) = 'object'),
  status text not null default 'open' check (status in ('open', 'resolved')),
  created_by uuid not null references auth.users(id) on delete restrict,
  created_at timestamptz not null default now(),
  resolved_at timestamptz,
  resolved_by uuid references auth.users(id) on delete restrict,
  unique (id, company_id),
  foreign key (load_id, company_id)
    references public.loads (id, company_id) on delete restrict,
  check ((status = 'open' and resolved_at is null and resolved_by is null) or status = 'resolved')
);

create table public.load_state_events (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete restrict,
  load_id uuid not null,
  from_status text not null,
  to_status text not null,
  actor_id uuid not null references auth.users(id) on delete restrict,
  occurred_at timestamptz not null default now(),
  unique (id, company_id),
  foreign key (load_id, company_id)
    references public.loads (id, company_id) on delete restrict
);

create index loads_company_operational_status_idx
  on public.loads (company_id, operational_status, updated_at desc);
create index loads_company_driver_status_idx
  on public.loads (company_id, assigned_driver_id, operational_status);
create index load_stops_company_load_sequence_idx
  on public.load_stops (company_id, load_id, sequence);
create index load_evidence_company_load_type_idx
  on public.load_evidence (company_id, load_id, evidence_type);
create index load_incidents_company_load_status_idx
  on public.load_incidents (company_id, load_id, status, created_at desc);
create index load_state_events_company_load_occurred_at_idx
  on public.load_state_events (company_id, load_id, occurred_at desc);

alter table public.audit_events
  drop constraint audit_events_before_data_create_only_check,
  add constraint audit_events_before_data_create_only_check check (
    before_data is not null
    or action in (
      'membership.invited', 'driver.created', 'vehicle.created',
      'driver_vehicle.assigned', 'driver_shift.started', 'load.created',
      'load.evidence_recorded', 'load.incident_reported'
    )
  );

-- This helper is a fixed-search-path, tenant-aware read boundary. It does not
-- accept arbitrary SQL values and allows drivers only for their assigned load.
create function public.can_current_user_view_load(
  target_company_id uuid,
  target_load_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select public.has_active_company_role(
    target_company_id,
    array['owner', 'admin', 'dispatcher']::public.company_role[]
  )
  or exists (
    select 1
    from public.loads as load
    where load.company_id = target_company_id
      and load.id = target_load_id
      and load.assigned_driver_id is not null
      and public.is_current_user_driver(target_company_id, load.assigned_driver_id)
  );
$$;

alter table public.loads enable row level security;
alter table public.loads force row level security;
alter table public.load_stops enable row level security;
alter table public.load_stops force row level security;
alter table public.load_evidence_requirements enable row level security;
alter table public.load_evidence_requirements force row level security;
alter table public.load_evidence enable row level security;
alter table public.load_evidence force row level security;
alter table public.load_incidents enable row level security;
alter table public.load_incidents force row level security;
alter table public.load_state_events enable row level security;
alter table public.load_state_events force row level security;

revoke all on table public.loads, public.load_stops, public.load_evidence_requirements,
  public.load_evidence, public.load_incidents, public.load_state_events from public;
grant select on table public.loads, public.load_stops, public.load_evidence_requirements,
  public.load_evidence, public.load_incidents, public.load_state_events to anon, authenticated;
revoke insert, update, delete, truncate, references, trigger on table public.loads,
  public.load_stops, public.load_evidence_requirements, public.load_evidence,
  public.load_incidents, public.load_state_events from anon, authenticated;

create policy loads_select_authorized_company_actor
  on public.loads for select to anon, authenticated
  using (public.can_current_user_view_load(company_id, id));
create policy load_stops_select_authorized_company_actor
  on public.load_stops for select to anon, authenticated
  using (public.can_current_user_view_load(company_id, load_id));
create policy load_evidence_requirements_select_authorized_company_actor
  on public.load_evidence_requirements for select to anon, authenticated
  using (public.can_current_user_view_load(company_id, load_id));
create policy load_evidence_select_authorized_company_actor
  on public.load_evidence for select to anon, authenticated
  using (public.can_current_user_view_load(company_id, load_id));
create policy load_incidents_select_authorized_company_actor
  on public.load_incidents for select to anon, authenticated
  using (public.can_current_user_view_load(company_id, load_id));
create policy load_state_events_select_authorized_company_actor
  on public.load_state_events for select to anon, authenticated
  using (public.can_current_user_view_load(company_id, load_id));

create function public.create_pilot_load(
  target_company_id uuid,
  pilot_load_number text,
  pickup_stop jsonb,
  delivery_stop jsonb
)
returns public.loads
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor_id uuid := (select auth.uid());
  created_load public.loads%rowtype;
  normalized_load_number text := upper(btrim(pilot_load_number));
  pickup_country text := upper(btrim(pickup_stop ->> 'country'));
  delivery_country text := upper(btrim(delivery_stop ->> 'country'));
  pickup_timezone text := btrim(pickup_stop ->> 'timezone');
  delivery_timezone text := btrim(delivery_stop ->> 'timezone');
begin
  if actor_id is null or not public.has_active_company_role(
    target_company_id,
    array['owner', 'admin', 'dispatcher']::public.company_role[]
  ) then
    raise exception using errcode = '42501', message = 'only an authorized company actor may operate this load';
  end if;
  if normalized_load_number is null or char_length(normalized_load_number) not between 1 and 80 then
    raise exception using errcode = '22023', message = 'a load number is required';
  end if;
  if jsonb_typeof(pickup_stop) <> 'object' or jsonb_typeof(delivery_stop) <> 'object'
    or btrim(pickup_stop ->> 'address') is null or btrim(delivery_stop ->> 'address') is null
    or pickup_country not in ('US', 'CA') or delivery_country not in ('US', 'CA')
    or pickup_timezone is null or delivery_timezone is null then
    raise exception using errcode = '22023', message = 'one valid pickup and one valid delivery stop are required';
  end if;

  insert into public.loads (company_id, load_number, created_by)
  values (target_company_id, normalized_load_number, actor_id)
  returning * into created_load;

  insert into public.load_stops (company_id, load_id, sequence, stop_type, stop_data, country_code, timezone_name)
  values
    (target_company_id, created_load.id, 1, 'pickup', pickup_stop, pickup_country, pickup_timezone),
    (target_company_id, created_load.id, 2, 'delivery', delivery_stop, delivery_country, delivery_timezone);

  insert into public.audit_events (
    company_id, actor_id, action, before_data, after_data, entity_type, entity_id
  ) values (
    target_company_id,
    actor_id,
    'load.created',
    null,
    jsonb_build_object('loadNumber', created_load.load_number, 'operationalStatus', created_load.operational_status),
    'load',
    created_load.id
  );

  return created_load;
end;
$$;

create function public.configure_load_evidence_requirements(
  target_company_id uuid,
  target_load_id uuid,
  requirement_types jsonb
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor_id uuid := (select auth.uid());
  existing_load public.loads%rowtype;
  previous_requirements jsonb;
begin
  if actor_id is null or not public.has_active_company_role(
    target_company_id,
    array['owner', 'admin', 'dispatcher']::public.company_role[]
  ) then
    raise exception using errcode = '42501', message = 'only an authorized company actor may operate this load';
  end if;
  if jsonb_typeof(requirement_types) <> 'array'
    or exists (
      select 1 from jsonb_array_elements_text(requirement_types) as requirement(value)
      where requirement.value not in (
        'photo', 'receiver_name', 'signature', 'bol', 'pod',
        'reference_number', 'delivery_timestamp', 'delivery_gps'
      )
    )
    or (select count(*) from jsonb_array_elements_text(requirement_types))
      <> (select count(distinct value) from jsonb_array_elements_text(requirement_types) as requirement(value)) then
    raise exception using errcode = '22023', message = 'valid unique evidence requirements are required';
  end if;

  select * into existing_load from public.loads
  where company_id = target_company_id and id = target_load_id
  for update;
  if not found then
    raise exception using errcode = '42501', message = 'only an authorized company actor may operate this load';
  end if;

  select coalesce(jsonb_agg(requirement_type order by requirement_type), '[]'::jsonb)
  into previous_requirements
  from public.load_evidence_requirements
  where company_id = target_company_id and load_id = target_load_id;

  delete from public.load_evidence_requirements
  where company_id = target_company_id and load_id = target_load_id;
  insert into public.load_evidence_requirements (company_id, load_id, requirement_type)
  select target_company_id, target_load_id, requirement.value
  from jsonb_array_elements_text(requirement_types) as requirement(value);

  insert into public.audit_events (
    company_id, actor_id, action, before_data, after_data, entity_type, entity_id
  ) values (
    target_company_id, actor_id, 'load.evidence_requirements_configured',
    jsonb_build_object('requirements', previous_requirements),
    jsonb_build_object('requirements', requirement_types), 'load', target_load_id
  );
end;
$$;

create function public.advance_load_state(
  target_company_id uuid,
  target_load_id uuid,
  target_operational_status text
)
returns public.loads
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor_id uuid := (select auth.uid());
  existing_load public.loads%rowtype;
  updated_load public.loads%rowtype;
  actor_is_manager boolean := false;
begin
  if actor_id is null then
    raise exception using errcode = '42501', message = 'only an authorized company actor may operate this load';
  end if;

  select * into existing_load from public.loads
  where company_id = target_company_id and id = target_load_id
  for update;
  if not found then
    raise exception using errcode = '42501', message = 'only an authorized company actor may operate this load';
  end if;

  actor_is_manager := public.has_active_company_role(
    target_company_id,
    array['owner', 'admin', 'dispatcher']::public.company_role[]
  );
  if not actor_is_manager and (
    existing_load.assigned_driver_id is null
    or not public.is_current_user_driver(target_company_id, existing_load.assigned_driver_id)
  ) then
    raise exception using errcode = '42501', message = 'only an authorized company actor may operate this load';
  end if;

  if not (
    (existing_load.operational_status = 'draft' and target_operational_status = 'scheduled')
    or (existing_load.operational_status = 'scheduled' and target_operational_status = 'assigned')
    or (existing_load.operational_status = 'assigned' and target_operational_status = 'en_route_to_pickup')
    or (existing_load.operational_status = 'en_route_to_pickup' and target_operational_status = 'arrived_pickup')
    or (existing_load.operational_status = 'arrived_pickup' and target_operational_status = 'loading')
    or (existing_load.operational_status = 'loading' and target_operational_status = 'picked_up')
    or (existing_load.operational_status = 'picked_up' and target_operational_status = 'en_route_to_delivery')
    or (existing_load.operational_status = 'en_route_to_delivery' and target_operational_status = 'arrived_delivery')
    or (existing_load.operational_status = 'arrived_delivery' and target_operational_status = 'unloading')
    or (existing_load.operational_status = 'unloading' and target_operational_status = 'delivered')
    or (actor_is_manager and existing_load.operational_status = 'delivered' and target_operational_status = 'closed')
    or (actor_is_manager and existing_load.operational_status not in ('delivered', 'closed', 'cancelled') and target_operational_status = 'cancelled')
  ) then
    raise exception using errcode = '22023', message = 'the requested load state transition is not allowed';
  end if;

  if target_operational_status = 'delivered' and exists (
    select 1
    from public.load_evidence_requirements as requirement
    where requirement.company_id = target_company_id
      and requirement.load_id = target_load_id
      and requirement.requirement_type <> 'photo'
      and not exists (
        select 1
        from public.load_evidence as evidence
        where evidence.company_id = target_company_id
          and evidence.load_id = target_load_id
          and evidence.evidence_type = requirement.requirement_type
      )
  ) then
    raise exception using errcode = '22023', message = 'required delivery evidence is incomplete';
  end if;

  update public.loads
  set operational_status = target_operational_status, updated_at = timezone('utc', now())
  where company_id = target_company_id and id = target_load_id
  returning * into updated_load;

  insert into public.load_state_events (company_id, load_id, from_status, to_status, actor_id)
  values (target_company_id, target_load_id, existing_load.operational_status, updated_load.operational_status, actor_id);

  insert into public.audit_events (
    company_id, actor_id, action, before_data, after_data, entity_type, entity_id
  ) values (
    target_company_id,
    actor_id,
    case
      when updated_load.operational_status = 'delivered' then 'load.delivered'
      when updated_load.operational_status = 'cancelled' then 'load.cancelled'
      when updated_load.operational_status = 'closed' then 'load.closed'
      else 'load.state_changed'
    end,
    jsonb_build_object('operationalStatus', existing_load.operational_status),
    jsonb_build_object('operationalStatus', updated_load.operational_status),
    'load',
    target_load_id
  );

  return updated_load;
end;
$$;

create function public.record_load_evidence(
  target_company_id uuid,
  target_load_id uuid,
  evidence_type_value text,
  evidence_content jsonb
)
returns public.load_evidence
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor_id uuid := (select auth.uid());
  existing_load public.loads%rowtype;
  created_evidence public.load_evidence%rowtype;
begin
  if actor_id is null then
    raise exception using errcode = '42501', message = 'only an authorized company actor may operate this load';
  end if;
  if evidence_type_value not in (
    'photo', 'receiver_name', 'signature', 'bol', 'pod',
    'reference_number', 'delivery_timestamp', 'delivery_gps'
  ) or jsonb_typeof(evidence_content) <> 'object' or evidence_content = '{}'::jsonb then
    raise exception using errcode = '22023', message = 'valid load evidence is required';
  end if;

  select * into existing_load from public.loads
  where company_id = target_company_id and id = target_load_id
  for update;
  if not found or existing_load.operational_status in ('closed', 'cancelled') then
    raise exception using errcode = '42501', message = 'only an authorized company actor may operate this load';
  end if;
  if not public.has_active_company_role(
    target_company_id,
    array['owner', 'admin', 'dispatcher']::public.company_role[]
  ) and (
    existing_load.assigned_driver_id is null
    or not public.is_current_user_driver(target_company_id, existing_load.assigned_driver_id)
  ) then
    raise exception using errcode = '42501', message = 'only an authorized company actor may operate this load';
  end if;

  insert into public.load_evidence (
    company_id, load_id, evidence_type, evidence_value, recorded_by
  ) values (
    target_company_id, target_load_id, evidence_type_value, evidence_content, actor_id
  ) returning * into created_evidence;

  insert into public.audit_events (
    company_id, actor_id, action, before_data, after_data, entity_type, entity_id
  ) values (
    target_company_id, actor_id, 'load.evidence_recorded', null,
    jsonb_build_object('evidenceType', created_evidence.evidence_type),
    'load_evidence', created_evidence.id
  );

  return created_evidence;
end;
$$;

create function public.report_load_incident(
  target_company_id uuid,
  target_load_id uuid,
  incident_type_value text,
  incident_description text,
  incident_attachments jsonb default '[]'::jsonb,
  incident_location jsonb default null
)
returns public.load_incidents
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor_id uuid := (select auth.uid());
  existing_load public.loads%rowtype;
  created_incident public.load_incidents%rowtype;
begin
  if actor_id is null then
    raise exception using errcode = '42501', message = 'only an authorized company actor may operate this load';
  end if;
  if incident_type_value not in (
    'pickup_issue', 'delivery_issue', 'breakdown', 'bad_address',
    'customer_unavailable', 'site_rejected_load', 'accident_emergency',
    'awaiting_instruction'
  ) or btrim(incident_description) is null
    or char_length(btrim(incident_description)) not between 1 and 2000
    or jsonb_typeof(incident_attachments) <> 'array'
    or (incident_location is not null and jsonb_typeof(incident_location) <> 'object') then
    raise exception using errcode = '22023', message = 'valid incident details are required';
  end if;

  select * into existing_load from public.loads
  where company_id = target_company_id and id = target_load_id
  for update;
  if not found or existing_load.operational_status in ('closed', 'cancelled') then
    raise exception using errcode = '42501', message = 'only an authorized company actor may operate this load';
  end if;
  if not public.has_active_company_role(
    target_company_id,
    array['owner', 'admin', 'dispatcher']::public.company_role[]
  ) and (
    existing_load.assigned_driver_id is null
    or not public.is_current_user_driver(target_company_id, existing_load.assigned_driver_id)
  ) then
    raise exception using errcode = '42501', message = 'only an authorized company actor may operate this load';
  end if;

  insert into public.load_incidents (
    company_id, load_id, incident_type, description, attachments, location, created_by
  ) values (
    target_company_id, target_load_id, incident_type_value, btrim(incident_description),
    incident_attachments, incident_location, actor_id
  ) returning * into created_incident;

  insert into public.audit_events (
    company_id, actor_id, action, before_data, after_data, entity_type, entity_id
  ) values (
    target_company_id, actor_id, 'load.incident_reported', null,
    jsonb_build_object('incidentType', created_incident.incident_type, 'loadId', target_load_id),
    'load_incident', created_incident.id
  );

  return created_incident;
end;
$$;

revoke all on function public.can_current_user_view_load(uuid, uuid) from public;
revoke all on function public.create_pilot_load(uuid, text, jsonb, jsonb) from public, anon;
revoke all on function public.configure_load_evidence_requirements(uuid, uuid, jsonb) from public, anon;
revoke all on function public.advance_load_state(uuid, uuid, text) from public, anon;
revoke all on function public.record_load_evidence(uuid, uuid, text, jsonb) from public, anon;
revoke all on function public.report_load_incident(uuid, uuid, text, text, jsonb, jsonb) from public, anon;
grant execute on function public.can_current_user_view_load(uuid, uuid) to anon, authenticated;
grant execute on function public.create_pilot_load(uuid, text, jsonb, jsonb) to authenticated;
grant execute on function public.configure_load_evidence_requirements(uuid, uuid, jsonb) to authenticated;
grant execute on function public.advance_load_state(uuid, uuid, text) to authenticated;
grant execute on function public.record_load_evidence(uuid, uuid, text, jsonb) to authenticated;
grant execute on function public.report_load_incident(uuid, uuid, text, text, jsonb, jsonb) to authenticated;
