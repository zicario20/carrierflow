-- Forward-only initial route-estimate request boundary. 0009's durable
-- re-computation queue deliberately starts after a revision exists; this
-- migration adds the first revision without reopening the retired arbitrary
-- persistence RPC from 0008.

alter table public.route_estimate_recompute_jobs
  alter column expected_revision_id drop not null,
  drop constraint route_estimate_recompute_jobs_reason_check,
  add constraint route_estimate_recompute_jobs_reason_check check (
    reason in ('initial', 'active_final_stop_changed', 'driver_changed', 'assignment_changed')
  ),
  drop constraint route_estimate_recompute_jobs_operation_check,
  add constraint route_estimate_recompute_jobs_operation_check check (
    operation in ('initial_request', 'context_recompute')
  );

create function public.request_initial_route_estimate(
  target_company_id uuid,
  target_load_id uuid,
  quoted_amount_usd numeric,
  request_idempotency_key uuid
)
returns public.route_estimate_recompute_jobs
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor_id uuid := (select auth.uid());
  target_load public.loads%rowtype;
  existing_job public.route_estimate_recompute_jobs%rowtype;
  created_job public.route_estimate_recompute_jobs%rowtype;
  current_fingerprint text;
begin
  if actor_id is null or not public.has_active_company_role(
    target_company_id, array['owner', 'admin', 'dispatcher']::public.company_role[]
  ) then
    raise exception using errcode = '42501', message = 'only an authorized dispatcher may request a route estimate';
  end if;
  if quoted_amount_usd is null
    or quoted_amount_usd <= 0
    or quoted_amount_usd <> trunc(quoted_amount_usd, 2) then
    raise exception using errcode = '22023', message = 'a valid decimal quoted USD amount is required';
  end if;
  if request_idempotency_key is null then
    raise exception using errcode = '22023', message = 'a durable route-estimate idempotency key is required';
  end if;

  select * into target_load
  from public.loads
  where company_id = target_company_id and id = target_load_id
  for update;
  if not found or target_load.assigned_driver_id is null then
    raise exception using errcode = '22023', message = 'an assigned route driver is required';
  end if;
  current_fingerprint := public.route_estimate_context_fingerprint(target_company_id, target_load_id);

  select * into existing_job
  from public.route_estimate_recompute_jobs
  where company_id = target_company_id
    and operation = 'initial_request'
    and idempotency_key = request_idempotency_key
  for update;
  if found then
    if existing_job.load_id is distinct from target_load_id
      or existing_job.quote_usd is distinct from quoted_amount_usd
      or existing_job.context_fingerprint is distinct from current_fingerprint then
      raise exception using errcode = '22023', message = 'the initial route-estimate idempotency context is stale';
    end if;
    return existing_job;
  end if;

  if exists (
    select 1 from public.route_estimate_revisions
    where company_id = target_company_id and load_id = target_load_id
  ) or exists (
    select 1 from public.route_estimate_heads
    where company_id = target_company_id and load_id = target_load_id
  ) then
    raise exception using errcode = '22023', message = 'an initial route estimate already exists for this load';
  end if;

  insert into public.route_estimate_recompute_jobs (
    company_id, load_id, operation, context_version, context_fingerprint,
    expected_revision_id, quote_usd, reason, idempotency_key, created_by
  ) values (
    target_company_id, target_load_id, 'initial_request', 1, current_fingerprint,
    null, quoted_amount_usd, 'initial', request_idempotency_key, actor_id
  ) returning * into created_job;

  insert into public.audit_events (
    company_id, actor_id, action, before_data, after_data, entity_type, entity_id
  ) values (
    target_company_id, actor_id, 'route_estimate.initial_requested', '{}'::jsonb,
    jsonb_build_object('jobId', created_job.id, 'quoteUsd', created_job.quote_usd,
      'contextFingerprint', created_job.context_fingerprint),
    'load', target_load_id
  );
  return created_job;
end;
$$;

create or replace function public.claim_route_estimate_recompute_job(
  target_company_id uuid,
  target_job_id uuid,
  expected_idempotency_key uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor_id uuid := (select auth.uid());
  job public.route_estimate_recompute_jobs%rowtype;
  target_load public.loads%rowtype;
  active_load public.loads%rowtype;
  active_final_stop public.load_stops%rowtype;
  completed_revision public.route_estimate_revisions%rowtype;
  planned_stops jsonb;
  planned_stop_count integer;
  active_load_count integer;
begin
  if actor_id is null or not public.has_active_company_role(
    target_company_id, array['owner', 'admin', 'dispatcher']::public.company_role[]
  ) then
    raise exception using errcode = '42501', message = 'only an authorized dispatcher may process a route estimate';
  end if;
  select * into job
  from public.route_estimate_recompute_jobs
  where company_id = target_company_id and id = target_job_id and idempotency_key = expected_idempotency_key
  for update;
  if not found then
    raise exception using errcode = '42501', message = 'a matching route estimate job is required';
  end if;
  if job.status = 'completed' then
    select * into completed_revision
    from public.route_estimate_revisions
    where company_id = target_company_id and id = job.completed_revision_id;
    return jsonb_build_object(
      'status', 'completed',
      'revision', jsonb_build_object(
        'id', completed_revision.id, 'company_id', completed_revision.company_id,
        'revision_number', completed_revision.revision_number,
        'empty_miles', completed_revision.empty_miles, 'loaded_miles', completed_revision.loaded_miles,
        'total_miles', completed_revision.total_miles, 'quote_usd', completed_revision.quote_usd,
        'quote_usd_per_total_mile', completed_revision.quote_usd_per_total_mile
      )
    );
  end if;
  if job.status = 'claimed' then
    raise exception using errcode = '55P03', message = 'the route estimate job is already claimed';
  end if;
  if job.context_fingerprint is distinct from public.route_estimate_context_fingerprint(target_company_id, job.load_id) then
    raise exception using errcode = '22023', message = 'the route estimate job context is stale';
  end if;
  if job.reason = 'initial' then
    if exists (
      select 1 from public.route_estimate_revisions
      where company_id = target_company_id and load_id = job.load_id
    ) then
      raise exception using errcode = '22023', message = 'the initial route estimate already exists';
    end if;
  elsif not exists (
    select 1 from public.route_estimate_heads as head
    where head.company_id = target_company_id and head.load_id = job.load_id
      and head.state = 'recompute_requested'
      and head.context_version = job.context_version
      and head.context_fingerprint = job.context_fingerprint
  ) then
    raise exception using errcode = '22023', message = 'the route estimate job context is stale';
  end if;

  select * into target_load
  from public.loads
  where company_id = target_company_id and id = job.load_id
  for update;
  if not found or target_load.assigned_driver_id is null then
    raise exception using errcode = '22023', message = 'an assigned route driver is required';
  end if;
  select count(*), jsonb_agg(
    jsonb_build_object(
      'id', stop.id, 'label', left(coalesce(stop.stop_data ->> 'address', ''), 400),
      'latitude', (stop.stop_data ->> 'latitude')::numeric,
      'longitude', (stop.stop_data ->> 'longitude')::numeric
    ) order by stop.sequence
  ) into planned_stop_count, planned_stops
  from public.load_stops as stop
  where stop.company_id = target_company_id and stop.load_id = job.load_id
    and public.route_estimate_stop_coordinates_are_valid(stop.stop_data);
  if planned_stop_count not between 2 and 16 or exists (
    select 1 from public.load_stops as stop
    where stop.company_id = target_company_id and stop.load_id = job.load_id
      and not public.route_estimate_stop_coordinates_are_valid(stop.stop_data)
  ) then
    raise exception using errcode = '22023', message = 'between two and sixteen planned stops with valid coordinates are required';
  end if;
  select count(*) into active_load_count
  from public.loads as load
  where load.company_id = target_company_id
    and load.assigned_driver_id = target_load.assigned_driver_id
    and load.id <> target_load.id
    and load.operational_status in (
      'assigned', 'en_route_to_pickup', 'arrived_pickup', 'loading',
      'picked_up', 'en_route_to_delivery', 'arrived_delivery', 'unloading'
    );
  if active_load_count <> 1 then
    raise exception using errcode = '22023', message = 'exactly one active load must determine the empty-mile origin';
  end if;
  select * into active_load
  from public.loads as load
  where load.company_id = target_company_id
    and load.assigned_driver_id = target_load.assigned_driver_id
    and load.id <> target_load.id
    and load.operational_status in (
      'assigned', 'en_route_to_pickup', 'arrived_pickup', 'loading',
      'picked_up', 'en_route_to_delivery', 'arrived_delivery', 'unloading'
    )
  for update;
  select * into active_final_stop
  from public.load_stops as stop
  where stop.company_id = target_company_id and stop.load_id = active_load.id
  order by stop.sequence desc limit 1;
  if not found or not public.route_estimate_stop_coordinates_are_valid(active_final_stop.stop_data) then
    raise exception using errcode = '22023', message = 'the active load requires a final planned stop with valid coordinates';
  end if;

  update public.route_estimate_recompute_jobs
  set status = 'claimed', claimed_by = actor_id, claimed_at = timezone('utc', now())
  where id = job.id and company_id = target_company_id;
  return jsonb_build_object(
    'id', job.id, 'company_id', job.company_id, 'load_id', job.load_id,
    'context_version', job.context_version, 'context_fingerprint', job.context_fingerprint,
    'quote_usd', job.quote_usd, 'empty_origin_kind', 'active_load_final_stop',
    'empty_origin', jsonb_build_object(
      'id', active_final_stop.id, 'label', left(coalesce(active_final_stop.stop_data ->> 'address', ''), 400),
      'latitude', (active_final_stop.stop_data ->> 'latitude')::numeric,
      'longitude', (active_final_stop.stop_data ->> 'longitude')::numeric
    ),
    'planned_stops', planned_stops
  );
end;
$$;

create or replace function public.complete_route_estimate_recompute_job(
  target_company_id uuid,
  target_job_id uuid,
  expected_idempotency_key uuid,
  expected_context_version integer,
  expected_context_fingerprint text,
  calculated_empty_miles numeric,
  calculated_loaded_miles numeric,
  selected_provider_name text,
  route_summary jsonb
)
returns public.route_estimate_revisions
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor_id uuid := (select auth.uid());
  job public.route_estimate_recompute_jobs%rowtype;
  head public.route_estimate_heads%rowtype;
  target_load public.loads%rowtype;
  active_load public.loads%rowtype;
  active_final_stop public.load_stops%rowtype;
  prior_revision public.route_estimate_revisions%rowtype;
  created_revision public.route_estimate_revisions%rowtype;
  active_load_count integer;
begin
  if actor_id is null or not public.has_active_company_role(
    target_company_id, array['owner', 'admin', 'dispatcher']::public.company_role[]
  ) then
    raise exception using errcode = '42501', message = 'only an authorized dispatcher may persist a route estimate';
  end if;
  select * into job
  from public.route_estimate_recompute_jobs
  where company_id = target_company_id and id = target_job_id and idempotency_key = expected_idempotency_key
  for update;
  if not found then
    raise exception using errcode = '42501', message = 'a matching route estimate job is required';
  end if;
  if job.status = 'completed' then
    select * into created_revision
    from public.route_estimate_revisions
    where company_id = target_company_id and id = job.completed_revision_id;
    return created_revision;
  end if;
  if job.status <> 'claimed' then
    raise exception using errcode = '22023', message = 'the route estimate job must be claimed before completion';
  end if;
  if expected_context_version <> job.context_version
    or expected_context_fingerprint is distinct from job.context_fingerprint
    or job.context_fingerprint is distinct from public.route_estimate_context_fingerprint(target_company_id, job.load_id) then
    raise exception using errcode = '22023', message = 'the supplied route estimate context is stale';
  end if;
  if calculated_empty_miles is null or calculated_empty_miles < 0
    or calculated_empty_miles <> trunc(calculated_empty_miles, 3)
    or calculated_loaded_miles is null or calculated_loaded_miles <= 0
    or calculated_loaded_miles <> trunc(calculated_loaded_miles, 3)
    or selected_provider_name is null or selected_provider_name <> lower(btrim(selected_provider_name))
    or char_length(selected_provider_name) not between 1 and 80
    or not public.route_estimate_safe_summary(route_summary) then
    raise exception using errcode = '22023', message = 'bounded route estimate output is required';
  end if;

  if job.reason = 'initial' then
    if exists (
      select 1 from public.route_estimate_revisions
      where company_id = target_company_id and load_id = job.load_id
    ) then
      raise exception using errcode = '22023', message = 'the initial route estimate already exists';
    end if;
  else
    select * into head
    from public.route_estimate_heads
    where company_id = target_company_id and load_id = job.load_id
    for update;
    if not found or head.state not in ('recompute_requested', 'recomputing')
      or head.context_version <> job.context_version
      or head.context_fingerprint is distinct from job.context_fingerprint
      or head.stale_revision_id is distinct from job.expected_revision_id then
      raise exception using errcode = '22023', message = 'the route estimate context changed before completion';
    end if;
  end if;

  select * into target_load
  from public.loads
  where company_id = target_company_id and id = job.load_id
  for update;
  select count(*) into active_load_count
  from public.loads as load
  where load.company_id = target_company_id
    and load.assigned_driver_id = target_load.assigned_driver_id
    and load.id <> target_load.id
    and load.operational_status in (
      'assigned', 'en_route_to_pickup', 'arrived_pickup', 'loading',
      'picked_up', 'en_route_to_delivery', 'arrived_delivery', 'unloading'
    );
  if target_load.assigned_driver_id is null or active_load_count <> 1 then
    raise exception using errcode = '22023', message = 'the server-derived active route context is no longer valid';
  end if;
  select * into active_load
  from public.loads as load
  where load.company_id = target_company_id
    and load.assigned_driver_id = target_load.assigned_driver_id
    and load.id <> target_load.id
    and load.operational_status in (
      'assigned', 'en_route_to_pickup', 'arrived_pickup', 'loading',
      'picked_up', 'en_route_to_delivery', 'arrived_delivery', 'unloading'
    )
  for update;
  select * into active_final_stop
  from public.load_stops as stop
  where stop.company_id = target_company_id and stop.load_id = active_load.id
  order by stop.sequence desc limit 1;
  if not found or not public.route_estimate_stop_coordinates_are_valid(active_final_stop.stop_data) then
    raise exception using errcode = '22023', message = 'the server-derived active route context is no longer valid';
  end if;

  if job.reason <> 'initial' then
    select * into prior_revision
    from public.route_estimate_revisions
    where company_id = target_company_id and id = job.expected_revision_id;
  end if;
  insert into public.route_estimate_revisions (
    company_id, load_id, revision_number, previous_revision_id,
    quote_context_driver_id, empty_origin_kind, empty_origin_load_id,
    empty_origin_stop_id, empty_miles, loaded_miles, quote_usd,
    provider_name, provider_route_data, created_by
  ) values (
    target_company_id, job.load_id, coalesce(prior_revision.revision_number, 0) + 1, prior_revision.id,
    target_load.assigned_driver_id, 'active_load_final_stop', active_load.id,
    active_final_stop.id, calculated_empty_miles, calculated_loaded_miles, job.quote_usd,
    selected_provider_name, route_summary, actor_id
  ) returning * into created_revision;

  update public.route_estimate_heads
  set current_revision_id = created_revision.id, stale_revision_id = null,
      state = 'current', updated_at = timezone('utc', now())
  where company_id = target_company_id and load_id = job.load_id;

  if job.reason <> 'initial' then
    insert into public.route_estimate_invalidations (
      company_id, load_id, prior_revision_id, replacement_revision_id, reason, invalidated_by
    ) values (
      target_company_id, job.load_id, prior_revision.id, created_revision.id, job.reason, actor_id
    ) on conflict (prior_revision_id) do nothing;
  end if;
  update public.route_estimate_recompute_jobs
  set status = 'completed', completed_revision_id = created_revision.id, completed_at = timezone('utc', now())
  where company_id = target_company_id and id = job.id;
  insert into public.audit_events (
    company_id, actor_id, action, before_data, after_data, entity_type, entity_id
  ) values (
    target_company_id, actor_id,
    case when job.reason = 'initial' then 'route_estimate.created' else 'route_estimate.recomputed' end,
    case when job.reason = 'initial' then '{}'::jsonb else jsonb_build_object(
      'revisionId', prior_revision.id, 'revisionNumber', prior_revision.revision_number
    ) end,
    jsonb_build_object('revisionId', created_revision.id, 'revisionNumber', created_revision.revision_number,
      'contextVersion', job.context_version),
    'load', job.load_id
  );
  return created_revision;
end;
$$;

revoke all on function public.request_initial_route_estimate(uuid, uuid, numeric, uuid) from public, anon;
grant execute on function public.request_initial_route_estimate(uuid, uuid, numeric, uuid) to authenticated;

-- A second real context change can happen while a provider is processing the
-- first job. Keep the old immutable revision stale, supersede the obsolete
-- job, and issue exactly one fresh version in the same transaction.
alter table public.route_estimate_recompute_jobs
  drop constraint route_estimate_recompute_jobs_check,
  drop constraint route_estimate_recompute_jobs_status_check,
  add constraint route_estimate_recompute_jobs_lifecycle_check check (
    (status = 'pending' and claimed_at is null and claimed_by is null and completed_at is null and completed_revision_id is null)
    or (status = 'claimed' and claimed_at is not null and claimed_by is not null and completed_at is null and completed_revision_id is null)
    or (status = 'completed' and completed_at is not null and completed_revision_id is not null)
    or (status = 'superseded' and completed_at is null and completed_revision_id is null)
  );

create or replace function public.invalidate_route_estimate_context(
  target_company_id uuid,
  target_load_id uuid,
  invalidation_reason text,
  invalidating_actor_id uuid default null
)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  existing_head public.route_estimate_heads%rowtype;
  invalidated_head public.route_estimate_heads%rowtype;
  prior_revision public.route_estimate_revisions%rowtype;
begin
  if invalidation_reason not in ('active_final_stop_changed', 'driver_changed', 'assignment_changed') then
    raise exception using errcode = '22023', message = 'a valid route estimate context invalidation reason is required';
  end if;
  select * into existing_head
  from public.route_estimate_heads
  where company_id = target_company_id and load_id = target_load_id
  for update;
  if not found then
    return false;
  end if;
  select * into prior_revision
  from public.route_estimate_revisions
  where company_id = target_company_id
    and id = coalesce(existing_head.current_revision_id, existing_head.stale_revision_id);

  update public.route_estimate_recompute_jobs
  set status = 'superseded'
  where company_id = target_company_id
    and load_id = target_load_id
    and status in ('pending', 'claimed');

  update public.route_estimate_heads
  set current_revision_id = null,
      stale_revision_id = coalesce(existing_head.stale_revision_id, existing_head.current_revision_id),
      state = 'recompute_requested',
      context_version = existing_head.context_version + 1,
      context_fingerprint = public.route_estimate_context_fingerprint(target_company_id, target_load_id),
      updated_at = timezone('utc', now())
  where company_id = target_company_id and load_id = target_load_id
  returning * into invalidated_head;

  insert into public.route_estimate_context_invalidations (
    company_id, load_id, prior_revision_id, context_version, reason, invalidated_by
  ) values (
    target_company_id, target_load_id, prior_revision.id,
    invalidated_head.context_version, invalidation_reason, invalidating_actor_id
  );
  insert into public.route_estimate_recompute_jobs (
    company_id, load_id, operation, context_version, context_fingerprint,
    expected_revision_id, quote_usd, reason, idempotency_key, created_by
  ) values (
    target_company_id, target_load_id, 'context_recompute', invalidated_head.context_version,
    invalidated_head.context_fingerprint, prior_revision.id, prior_revision.quote_usd,
    invalidation_reason, gen_random_uuid(), invalidating_actor_id
  );
  insert into public.route_estimate_notifications (
    company_id, load_id, route_estimate_revision_id, recipient_role,
    notification_type, payload
  ) values (
    target_company_id, target_load_id, prior_revision.id, 'dispatcher',
    'route_estimate_invalidated',
    jsonb_build_object(
      'loadId', target_load_id, 'revisionNumber', prior_revision.revision_number,
      'reason', invalidation_reason, 'contextVersion', invalidated_head.context_version
    )
  ) on conflict do nothing;
  insert into public.audit_events (
    company_id, actor_id, action, before_data, after_data, entity_type, entity_id
  ) values (
    target_company_id, invalidating_actor_id, 'route_estimate.context_invalidated',
    jsonb_build_object('revisionId', prior_revision.id, 'revisionNumber', prior_revision.revision_number),
    jsonb_build_object('reason', invalidation_reason, 'contextVersion', invalidated_head.context_version,
      'recomputeJobQueued', true),
    'load', target_load_id
  );
  return true;
end;
$$;

create function public.release_route_estimate_recompute_job(
  target_company_id uuid,
  target_job_id uuid,
  expected_idempotency_key uuid
)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor_id uuid := (select auth.uid());
  job public.route_estimate_recompute_jobs%rowtype;
begin
  if actor_id is null or not public.has_active_company_role(
    target_company_id, array['owner', 'admin', 'dispatcher']::public.company_role[]
  ) then
    raise exception using errcode = '42501', message = 'only an authorized dispatcher may release a route estimate job';
  end if;
  select * into job
  from public.route_estimate_recompute_jobs
  where company_id = target_company_id and id = target_job_id and idempotency_key = expected_idempotency_key
  for update;
  if not found then
    raise exception using errcode = '42501', message = 'a matching route estimate job is required';
  end if;
  if job.status <> 'claimed' then
    return false;
  end if;
  if job.context_fingerprint is distinct from public.route_estimate_context_fingerprint(target_company_id, job.load_id) then
    update public.route_estimate_recompute_jobs set status = 'superseded'
    where company_id = target_company_id and id = target_job_id;
    return false;
  end if;
  if job.reason <> 'initial' and not exists (
    select 1 from public.route_estimate_heads as head
    where head.company_id = target_company_id and head.load_id = job.load_id
      and head.state = 'recompute_requested'
      and head.context_version = job.context_version
      and head.context_fingerprint = job.context_fingerprint
  ) then
    update public.route_estimate_recompute_jobs set status = 'superseded'
    where company_id = target_company_id and id = target_job_id;
    return false;
  end if;
  update public.route_estimate_recompute_jobs
  set status = 'pending', claimed_by = null, claimed_at = null
  where company_id = target_company_id and id = target_job_id;
  return true;
end;
$$;

create or replace function public.claim_route_estimate_recompute_job(
  target_company_id uuid,
  target_job_id uuid,
  expected_idempotency_key uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor_id uuid := (select auth.uid());
  job public.route_estimate_recompute_jobs%rowtype;
  target_load public.loads%rowtype;
  active_load public.loads%rowtype;
  active_final_stop public.load_stops%rowtype;
  completed_revision public.route_estimate_revisions%rowtype;
  planned_stops jsonb;
  planned_stop_count integer;
  active_load_count integer;
begin
  if actor_id is null or not public.has_active_company_role(
    target_company_id, array['owner', 'admin', 'dispatcher']::public.company_role[]
  ) then
    raise exception using errcode = '42501', message = 'only an authorized dispatcher may process a route estimate';
  end if;
  select * into job from public.route_estimate_recompute_jobs
  where company_id = target_company_id and id = target_job_id and idempotency_key = expected_idempotency_key
  for update;
  if not found then
    raise exception using errcode = '42501', message = 'a matching route estimate job is required';
  end if;
  if job.status = 'completed' then
    select * into completed_revision from public.route_estimate_revisions
    where company_id = target_company_id and id = job.completed_revision_id;
    return jsonb_build_object('status', 'completed', 'revision', jsonb_build_object(
      'id', completed_revision.id, 'company_id', completed_revision.company_id,
      'revision_number', completed_revision.revision_number, 'empty_miles', completed_revision.empty_miles,
      'loaded_miles', completed_revision.loaded_miles, 'total_miles', completed_revision.total_miles,
      'quote_usd', completed_revision.quote_usd,
      'quote_usd_per_total_mile', completed_revision.quote_usd_per_total_mile
    ));
  end if;
  if job.status = 'claimed' and job.claimed_at > timezone('utc', now()) - interval '5 minutes' then
    raise exception using errcode = '55P03', message = 'the route estimate job is already claimed';
  end if;
  if job.status = 'superseded' then
    raise exception using errcode = '22023', message = 'the route estimate job context is stale';
  end if;
  if job.context_fingerprint is distinct from public.route_estimate_context_fingerprint(target_company_id, job.load_id) then
    update public.route_estimate_recompute_jobs set status = 'superseded'
    where company_id = target_company_id and id = target_job_id;
    raise exception using errcode = '22023', message = 'the route estimate job context is stale';
  end if;
  if job.reason = 'initial' then
    if exists (select 1 from public.route_estimate_revisions where company_id = target_company_id and load_id = job.load_id) then
      raise exception using errcode = '22023', message = 'the initial route estimate already exists';
    end if;
  elsif not exists (
    select 1 from public.route_estimate_heads as head
    where head.company_id = target_company_id and head.load_id = job.load_id
      and head.state = 'recompute_requested' and head.context_version = job.context_version
      and head.context_fingerprint = job.context_fingerprint
  ) then
    update public.route_estimate_recompute_jobs set status = 'superseded'
    where company_id = target_company_id and id = target_job_id;
    raise exception using errcode = '22023', message = 'the route estimate job context is stale';
  end if;
  select * into target_load from public.loads
  where company_id = target_company_id and id = job.load_id for update;
  if not found or target_load.assigned_driver_id is null then
    raise exception using errcode = '22023', message = 'an assigned route driver is required';
  end if;
  select count(*), jsonb_agg(jsonb_build_object(
    'id', stop.id, 'label', left(coalesce(stop.stop_data ->> 'address', ''), 400),
    'latitude', (stop.stop_data ->> 'latitude')::numeric, 'longitude', (stop.stop_data ->> 'longitude')::numeric
  ) order by stop.sequence) into planned_stop_count, planned_stops
  from public.load_stops as stop
  where stop.company_id = target_company_id and stop.load_id = job.load_id
    and public.route_estimate_stop_coordinates_are_valid(stop.stop_data);
  if planned_stop_count not between 2 and 16 or exists (
    select 1 from public.load_stops as stop where stop.company_id = target_company_id and stop.load_id = job.load_id
      and not public.route_estimate_stop_coordinates_are_valid(stop.stop_data)
  ) then
    raise exception using errcode = '22023', message = 'between two and sixteen planned stops with valid coordinates are required';
  end if;
  select count(*) into active_load_count from public.loads as load
  where load.company_id = target_company_id and load.assigned_driver_id = target_load.assigned_driver_id
    and load.id <> target_load.id and load.operational_status in (
      'assigned', 'en_route_to_pickup', 'arrived_pickup', 'loading', 'picked_up',
      'en_route_to_delivery', 'arrived_delivery', 'unloading'
    );
  if active_load_count <> 1 then
    raise exception using errcode = '22023', message = 'exactly one active load must determine the empty-mile origin';
  end if;
  select * into active_load from public.loads as load
  where load.company_id = target_company_id and load.assigned_driver_id = target_load.assigned_driver_id
    and load.id <> target_load.id and load.operational_status in (
      'assigned', 'en_route_to_pickup', 'arrived_pickup', 'loading', 'picked_up',
      'en_route_to_delivery', 'arrived_delivery', 'unloading'
    ) for update;
  select * into active_final_stop from public.load_stops as stop
  where stop.company_id = target_company_id and stop.load_id = active_load.id
  order by stop.sequence desc limit 1;
  if not found or not public.route_estimate_stop_coordinates_are_valid(active_final_stop.stop_data) then
    raise exception using errcode = '22023', message = 'the active load requires a final planned stop with valid coordinates';
  end if;
  update public.route_estimate_recompute_jobs
  set status = 'claimed', claimed_by = actor_id, claimed_at = timezone('utc', now())
  where id = job.id and company_id = target_company_id;
  return jsonb_build_object(
    'id', job.id, 'company_id', job.company_id, 'load_id', job.load_id,
    'context_version', job.context_version, 'context_fingerprint', job.context_fingerprint,
    'quote_usd', job.quote_usd, 'empty_origin_kind', 'active_load_final_stop',
    'empty_origin', jsonb_build_object('id', active_final_stop.id,
      'label', left(coalesce(active_final_stop.stop_data ->> 'address', ''), 400),
      'latitude', (active_final_stop.stop_data ->> 'latitude')::numeric,
      'longitude', (active_final_stop.stop_data ->> 'longitude')::numeric),
    'planned_stops', planned_stops
  );
end;
$$;

revoke all on function public.release_route_estimate_recompute_job(uuid, uuid, uuid) from public, anon;
grant execute on function public.release_route_estimate_recompute_job(uuid, uuid, uuid) to authenticated;
