-- Forward-only private-evidence integrity. References accepted by the load RPCs
-- must resolve to an immutable, private Storage object owned by the recording
-- actor; a syntactically valid path is never evidence by itself.

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'carrierflow-private-evidence',
  'CarrierFlow private evidence',
  false,
  10485760,
  array['application/pdf', 'image/heic', 'image/jpeg', 'image/png', 'image/webp']::text[]
)
on conflict (id) do update
set public = false,
    file_size_limit = excluded.file_size_limit,
    allowed_mime_types = excluded.allowed_mime_types,
    updated_at = timezone('utc', now());

create function public.is_admitted_load_storage_mime(
  object_kind text,
  content_type text
)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select case object_kind
    when 'photo' then content_type in ('image/heic', 'image/jpeg', 'image/png', 'image/webp')
    when 'bol' then content_type in ('application/pdf', 'image/heic', 'image/jpeg', 'image/png', 'image/webp')
    when 'pod' then content_type in ('application/pdf', 'image/heic', 'image/jpeg', 'image/png', 'image/webp')
    when 'incident_attachment' then content_type in ('application/pdf', 'image/heic', 'image/jpeg', 'image/png', 'image/webp')
    else false
  end;
$$;

create function public.is_verified_load_storage_object(
  target_company_id uuid,
  target_load_id uuid,
  target_actor_id uuid,
  reference_value text,
  object_kind text
)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select public.is_private_load_reference(target_company_id, target_load_id, reference_value)
    and exists (
      select 1
      from storage.objects as object
      join storage.buckets as bucket on bucket.id = object.bucket_id
      where object.bucket_id = 'carrierflow-private-evidence'
        and bucket.public = false
        and object.name = reference_value
        and object.owner = target_actor_id
        and object.archived_at is null
        and object.is_delete_marker = false
        and public.is_admitted_load_storage_mime(object_kind, object.metadata ->> 'mimetype')
    );
$$;

create function public.is_valid_load_evidence_for_actor(
  target_company_id uuid,
  target_load_id uuid,
  evidence_type_value text,
  evidence_content jsonb,
  target_actor_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select public.is_valid_load_evidence(
    target_company_id,
    target_load_id,
    evidence_type_value,
    evidence_content
  ) and case
    when evidence_type_value in ('photo', 'bol', 'pod') then public.is_verified_load_storage_object(
      target_company_id,
      target_load_id,
      target_actor_id,
      evidence_content ->> 'storagePath',
      evidence_type_value
    )
    else true
  end;
$$;

create or replace function public.advance_load_state(
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
  actor_is_assigned_driver boolean := false;
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
  actor_is_assigned_driver := existing_load.assigned_driver_id is not null
    and public.is_current_user_driver(target_company_id, existing_load.assigned_driver_id);

  if target_operational_status in ('scheduled', 'assigned', 'cancelled', 'closed')
    and not actor_is_manager then
    raise exception using
      errcode = '42501',
      message = 'only an authorized manager may schedule, assign, cancel, or close a load';
  end if;
  if not actor_is_manager and not actor_is_assigned_driver then
    raise exception using errcode = '42501', message = 'only an authorized company actor may operate this load';
  end if;
  if existing_load.operational_status = 'scheduled'
    and target_operational_status = 'assigned'
    and not public.has_active_load_assignment(
      target_company_id,
      existing_load.assigned_driver_id,
      existing_load.assigned_vehicle_id
    ) then
    raise exception using
      errcode = '22023',
      message = 'a valid active driver and assigned vehicle are required';
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
          and public.is_valid_load_evidence_for_actor(
            target_company_id,
            target_load_id,
            evidence.evidence_type,
            evidence.evidence_value,
            evidence.recorded_by
          )
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

create or replace function public.record_load_evidence(
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
  if not public.is_valid_load_evidence_for_actor(
    target_company_id,
    target_load_id,
    evidence_type_value,
    evidence_content,
    actor_id
  ) then
    raise exception using errcode = '22023', message = 'valid load evidence is required';
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

create or replace function public.report_load_incident(
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
  latitude numeric;
  longitude numeric;
begin
  if actor_id is null then
    raise exception using errcode = '42501', message = 'only an authorized company actor may operate this load';
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

  if incident_type_value is null
    or incident_type_value not in (
      'pickup_issue', 'delivery_issue', 'breakdown', 'bad_address',
      'customer_unavailable', 'site_rejected_load', 'accident_emergency',
      'awaiting_instruction'
    ) or btrim(incident_description) is null
    or char_length(btrim(incident_description)) not between 1 and 2000
    or incident_attachments is null
    or jsonb_typeof(incident_attachments) <> 'array'
    or jsonb_array_length(incident_attachments) > 10
    or exists (
      select 1
      from jsonb_array_elements(incident_attachments) as attachment(value)
      where jsonb_typeof(attachment.value) <> 'string'
        or not public.is_verified_load_storage_object(
          target_company_id,
          target_load_id,
          actor_id,
          attachment.value #>> '{}',
          'incident_attachment'
        )
    ) then
    raise exception using errcode = '22023', message = 'valid incident details are required';
  end if;
  if incident_location is not null then
    if not coalesce(
      jsonb_typeof(incident_location) = 'object'
      and jsonb_typeof(incident_location -> 'latitude') = 'number'
      and jsonb_typeof(incident_location -> 'longitude') = 'number',
      false
    ) then
      raise exception using errcode = '22023', message = 'valid incident details are required';
    end if;
    latitude := (incident_location ->> 'latitude')::numeric;
    longitude := (incident_location ->> 'longitude')::numeric;
    if not coalesce(latitude between -90 and 90 and longitude between -180 and 180, false) then
      raise exception using errcode = '22023', message = 'valid incident details are required';
    end if;
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

create policy carrierflow_evidence_select_authorized_load
  on storage.objects
  for select
  to authenticated
  using (
    bucket_id = 'carrierflow-private-evidence'
    and case
      when name ~ '^private/[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}/loads/[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}/.+$'
        then public.can_current_user_view_load(
          split_part(name, '/', 2)::uuid,
          split_part(name, '/', 4)::uuid
        )
      else false
    end
  );

create policy carrierflow_evidence_insert_authorized_load
  on storage.objects
  for insert
  to authenticated
  with check (
    bucket_id = 'carrierflow-private-evidence'
    and owner = (select auth.uid())
    and coalesce(metadata ->> 'mimetype', '') in (
      'application/pdf', 'image/heic', 'image/jpeg', 'image/png', 'image/webp'
    )
    and case
      when name ~ '^private/[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}/loads/[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}/.+$'
        then public.can_current_user_view_load(
          split_part(name, '/', 2)::uuid,
          split_part(name, '/', 4)::uuid
        )
      else false
    end
  );

revoke all on function public.is_admitted_load_storage_mime(text, text) from public, anon, authenticated;
revoke all on function public.is_verified_load_storage_object(uuid, uuid, uuid, text, text) from public, anon, authenticated;
revoke all on function public.is_valid_load_evidence_for_actor(uuid, uuid, text, jsonb, uuid) from public, anon, authenticated;
revoke all on function public.advance_load_state(uuid, uuid, text) from public, anon;
revoke all on function public.record_load_evidence(uuid, uuid, text, jsonb) from public, anon;
revoke all on function public.report_load_incident(uuid, uuid, text, text, jsonb, jsonb) from public, anon;
grant execute on function public.advance_load_state(uuid, uuid, text) to authenticated;
grant execute on function public.record_load_evidence(uuid, uuid, text, jsonb) to authenticated;
grant execute on function public.report_load_incident(uuid, uuid, text, text, jsonb, jsonb) to authenticated;
