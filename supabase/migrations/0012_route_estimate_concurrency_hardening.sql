-- Route-estimate proposal, lease and concurrency hardening.
--
-- Lock order for every route-estimate mutation is deliberately uniform:
-- resolve immutable job metadata without a row lock, then loads -> advisory
-- xact lock(company_id, load_id) -> heads -> jobs. Trigger paths already own
-- the load row, then take the same advisory lock before touching heads/jobs.
-- This removes the previous job -> head/load path and serializes an estimate
-- worker with a dispatcher changing stops, driver or vehicle.

alter table public.company_route_bases enable row level security;
alter table public.company_route_bases force row level security;
alter table public.driver_accepted_route_locations enable row level security;
alter table public.driver_accepted_route_locations force row level security;

alter table public.route_estimate_heads
  drop constraint route_estimate_heads_check,
  drop constraint route_estimate_heads_state_check,
  add constraint route_estimate_heads_state_check check (
    state in ('current', 'initial_requested', 'recompute_requested', 'recomputing')
  ),
  add constraint route_estimate_heads_check check (
    (state = 'current' and current_revision_id is not null and stale_revision_id is null)
    or (state = 'initial_requested' and current_revision_id is null and stale_revision_id is null)
    or (state in ('recompute_requested', 'recomputing')
      and current_revision_id is null and stale_revision_id is not null)
  );

alter table public.route_estimate_recompute_jobs
  add column empty_origin_kind text,
  add column empty_origin_load_id uuid,
  add column empty_origin_stop_id uuid;

update public.route_estimate_recompute_jobs
set empty_origin_kind = 'active_load_final_stop'
where empty_origin_kind is null;

alter table public.route_estimate_recompute_jobs
  alter column empty_origin_kind set not null,
  add constraint route_estimate_recompute_jobs_empty_origin_kind_check check (
    empty_origin_kind in ('active_load_final_stop', 'last_accepted_location', 'declared_base')
  ),
  add constraint route_estimate_recompute_jobs_empty_origin_load_id_company_id_fkey
    foreign key (empty_origin_load_id, company_id)
    references public.loads (id, company_id) on delete restrict,
  add constraint route_estimate_recompute_jobs_empty_origin_stop_id_company_id_fkey
    foreign key (empty_origin_stop_id, company_id)
    references public.load_stops (id, company_id) on delete restrict,
  add constraint route_estimate_recompute_jobs_empty_origin_check check (
    (empty_origin_kind = 'active_load_final_stop'
      and empty_origin_load_id is not null and empty_origin_stop_id is not null)
    or (empty_origin_kind in ('last_accepted_location', 'declared_base')
      and empty_origin_load_id is null and empty_origin_stop_id is null)
  );

create index route_estimate_recompute_jobs_origin_load_idx
  on public.route_estimate_recompute_jobs (company_id, empty_origin_load_id)
  where status in ('pending', 'claimed');

create function public.route_estimate_lock_key(target_company_id uuid, target_load_id uuid)
returns bigint
language sql
immutable
set search_path = ''
as $$
  select pg_catalog.hashtextextended(target_company_id::text || ':' || target_load_id::text, 0);
$$;

-- The origin is always derived from private, server-maintained state.  The
-- returned fingerprint is deliberately included in the route context so a
-- changed base/location/final-stop can never publish an older provider result.
create or replace function public.route_estimate_proposal_origin(
  target_company_id uuid,
  target_load_id uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  target_load public.loads%rowtype;
  active_load public.loads%rowtype;
  active_final_stop public.load_stops%rowtype;
  located public.driver_accepted_route_locations%rowtype;
  base public.company_route_bases%rowtype;
  point jsonb;
begin
  select * into target_load
  from public.loads
  where company_id = target_company_id and id = target_load_id;
  if not found then
    raise exception using errcode = '42501', message = 'a matching route load is required';
  end if;

  if target_load.assigned_driver_id is not null then
    select * into active_load
    from public.loads as load
    where load.company_id = target_company_id
      and load.assigned_driver_id = target_load.assigned_driver_id
      and load.id <> target_load_id
      and load.operational_status in (
        'assigned', 'en_route_to_pickup', 'arrived_pickup', 'loading',
        'picked_up', 'en_route_to_delivery', 'arrived_delivery', 'unloading'
      )
    order by load.updated_at desc, load.id
    limit 1;
    if found then
      select * into active_final_stop
      from public.load_stops as stop
      where stop.company_id = target_company_id and stop.load_id = active_load.id
      order by stop.sequence desc
      limit 1;
      if found and public.route_estimate_stop_coordinates_are_valid(active_final_stop.stop_data) then
        point := jsonb_build_object(
          'id', active_final_stop.id,
          'label', left(coalesce(active_final_stop.stop_data ->> 'address', ''), 160),
          'latitude', (active_final_stop.stop_data ->> 'latitude')::numeric,
          'longitude', (active_final_stop.stop_data ->> 'longitude')::numeric
        );
        return jsonb_build_object(
          'kind', 'active_load_final_stop', 'point', point,
          'origin_load_id', active_load.id, 'origin_stop_id', active_final_stop.id,
          'fingerprint', pg_catalog.md5('active|' || active_load.id || '|' || active_final_stop.id || '|' || active_final_stop.stop_data::text)
        );
      end if;
    end if;

    select * into located
    from public.driver_accepted_route_locations
    where company_id = target_company_id
      and driver_id = target_load.assigned_driver_id
      and accepted_at >= timezone('utc', now()) - interval '24 hours'
    order by accepted_at desc, id
    limit 1;
    if found then
      point := jsonb_build_object(
        'id', located.id,
        'label', located.point ->> 'label',
        'latitude', (located.point ->> 'latitude')::numeric,
        'longitude', (located.point ->> 'longitude')::numeric
      );
      return jsonb_build_object(
        'kind', 'last_accepted_location', 'point', point,
        'origin_load_id', null, 'origin_stop_id', null,
        'fingerprint', pg_catalog.md5('location|' || located.id || '|' || located.point::text || '|' || located.accepted_at::text)
      );
    end if;
  end if;

  select * into base
  from public.company_route_bases
  where company_id = target_company_id;
  if found then
    point := jsonb_build_object(
      'id', base.company_id,
      'label', base.point ->> 'label',
      'latitude', (base.point ->> 'latitude')::numeric,
      'longitude', (base.point ->> 'longitude')::numeric
    );
    return jsonb_build_object(
      'kind', 'declared_base', 'point', point,
      'origin_load_id', null, 'origin_stop_id', null,
      'fingerprint', pg_catalog.md5('base|' || base.company_id || '|' || base.point::text || '|' || base.updated_at::text)
    );
  end if;

  raise exception using errcode = '22023', message = 'a declared base or fresh accepted driver location is required';
end;
$$;

create or replace function public.route_estimate_context_fingerprint(
  target_company_id uuid,
  target_load_id uuid
)
returns text
language plpgsql
stable
security definer
set search_path = ''
as $$
declare origin jsonb;
begin
  origin := public.route_estimate_proposal_origin(target_company_id, target_load_id);
  return (
    select pg_catalog.md5(
      coalesce(load.assigned_driver_id::text, '') || '|' ||
      coalesce(load.assigned_vehicle_id::text, '') || '|' ||
      coalesce((
        select pg_catalog.string_agg(
          stop.sequence::text || ':' || stop.stop_type || ':' || stop.stop_data::text,
          '|' order by stop.sequence
        )
        from public.load_stops as stop
        where stop.company_id = target_company_id and stop.load_id = target_load_id
      ), '') || '|' || coalesce(origin ->> 'fingerprint', '')
    )
    from public.loads as load
    where load.company_id = target_company_id and load.id = target_load_id
  );
end;
$$;

create function public.route_estimate_revision_response(revision public.route_estimate_revisions)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object(
    'id', revision.id, 'company_id', revision.company_id,
    'revision_number', revision.revision_number,
    'empty_miles', revision.empty_miles, 'loaded_miles', revision.loaded_miles,
    'total_miles', revision.total_miles, 'quote_usd', revision.quote_usd,
    'quote_usd_per_total_mile', revision.quote_usd_per_total_mile
  );
$$;

create function public.route_estimate_job_response(job public.route_estimate_recompute_jobs)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object(
    'id', job.id, 'company_id', job.company_id, 'load_id', job.load_id,
    'context_version', job.context_version, 'context_fingerprint', job.context_fingerprint,
    'quote_usd', job.quote_usd, 'empty_origin_kind', job.empty_origin_kind,
    'status', job.status
  );
$$;

drop function public.request_initial_route_estimate(uuid, uuid, numeric, uuid);
create function public.request_initial_route_estimate(
  target_company_id uuid,
  target_load_id uuid,
  quoted_amount_usd numeric,
  request_idempotency_key uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor_id uuid := (select auth.uid());
  target_load public.loads%rowtype;
  head public.route_estimate_heads%rowtype;
  existing_job public.route_estimate_recompute_jobs%rowtype;
  created_job public.route_estimate_recompute_jobs%rowtype;
  origin jsonb;
  current_fingerprint text;
begin
  if actor_id is null or not public.has_active_company_role(
    target_company_id, array['owner', 'admin', 'dispatcher']::public.company_role[]
  ) then
    raise exception using errcode = '42501', message = 'only an authorized dispatcher may request a route estimate';
  end if;
  if quoted_amount_usd is null or quoted_amount_usd <= 0 or quoted_amount_usd <> trunc(quoted_amount_usd, 2)
    or request_idempotency_key is null then
    raise exception using errcode = '22023', message = 'a valid decimal quote and durable idempotency key are required';
  end if;

  select * into target_load from public.loads
  where company_id = target_company_id and id = target_load_id for update;
  if not found then
    raise exception using errcode = '42501', message = 'a matching route load is required';
  end if;
  perform pg_advisory_xact_lock(public.route_estimate_lock_key(target_company_id, target_load_id));
  select * into head from public.route_estimate_heads
  where company_id = target_company_id and load_id = target_load_id for update;
  select * into existing_job from public.route_estimate_recompute_jobs
  where company_id = target_company_id and operation = 'initial_request'
    and idempotency_key = request_idempotency_key
  for update;

  origin := public.route_estimate_proposal_origin(target_company_id, target_load_id);
  current_fingerprint := public.route_estimate_context_fingerprint(target_company_id, target_load_id);
  if found then
    if existing_job.load_id is distinct from target_load_id
      or existing_job.quote_usd is distinct from quoted_amount_usd then
      raise exception using errcode = '22023', message = 'the initial route-estimate idempotency context is stale';
    end if;
    return public.route_estimate_job_response(existing_job);
  end if;
  if head.company_id is not null then
    raise exception using errcode = '22023', message = 'an initial route estimate already exists for this load';
  end if;

  insert into public.route_estimate_heads (
    company_id, load_id, state, context_version, context_fingerprint
  ) values (
    target_company_id, target_load_id, 'initial_requested', 1, current_fingerprint
  ) returning * into head;
  insert into public.route_estimate_recompute_jobs (
    company_id, load_id, operation, context_version, context_fingerprint,
    expected_revision_id, quote_usd, reason, idempotency_key, created_by,
    empty_origin_kind, empty_origin_load_id, empty_origin_stop_id
  ) values (
    target_company_id, target_load_id, 'initial_request', head.context_version,
    head.context_fingerprint, null, quoted_amount_usd, 'initial', request_idempotency_key, actor_id,
    origin ->> 'kind', nullif(origin ->> 'origin_load_id', '')::uuid,
    nullif(origin ->> 'origin_stop_id', '')::uuid
  ) returning * into created_job;
  insert into public.audit_events (
    company_id, actor_id, action, before_data, after_data, entity_type, entity_id
  ) values (
    target_company_id, actor_id, 'route_estimate.initial_requested', '{}'::jsonb,
    jsonb_build_object('jobId', created_job.id, 'quoteUsd', created_job.quote_usd,
      'contextVersion', created_job.context_version,
      'emptyOriginKind', created_job.empty_origin_kind),
    'load', target_load_id
  );
  return public.route_estimate_job_response(created_job);
end;
$$;

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
  target_load public.loads%rowtype;
  existing_head public.route_estimate_heads%rowtype;
  invalidated_head public.route_estimate_heads%rowtype;
  prior_revision public.route_estimate_revisions%rowtype;
  prior_job public.route_estimate_recompute_jobs%rowtype;
  created_job public.route_estimate_recompute_jobs%rowtype;
  origin jsonb;
begin
  if invalidation_reason not in ('active_final_stop_changed', 'driver_changed', 'assignment_changed') then
    raise exception using errcode = '22023', message = 'a valid route estimate context invalidation reason is required';
  end if;
  select * into target_load from public.loads
  where company_id = target_company_id and id = target_load_id for update;
  if not found then return false; end if;
  perform pg_advisory_xact_lock(public.route_estimate_lock_key(target_company_id, target_load_id));
  select * into existing_head from public.route_estimate_heads
  where company_id = target_company_id and load_id = target_load_id for update;
  if not found then return false; end if;
  select * into prior_job from public.route_estimate_recompute_jobs
  where company_id = target_company_id and load_id = target_load_id
    and status in ('pending', 'claimed')
  order by context_version desc
  limit 1 for update;
  select * into prior_revision from public.route_estimate_revisions
  where company_id = target_company_id
    and id = coalesce(existing_head.current_revision_id, existing_head.stale_revision_id);
  origin := public.route_estimate_proposal_origin(target_company_id, target_load_id);

  update public.route_estimate_recompute_jobs
  set status = 'superseded'
  where company_id = target_company_id and load_id = target_load_id
    and status in ('pending', 'claimed');
  update public.route_estimate_heads
  set current_revision_id = null,
      stale_revision_id = prior_revision.id,
      state = case when prior_revision.id is null then 'initial_requested' else 'recompute_requested' end,
      context_version = existing_head.context_version + 1,
      context_fingerprint = public.route_estimate_context_fingerprint(target_company_id, target_load_id),
      updated_at = timezone('utc', now())
  where company_id = target_company_id and load_id = target_load_id
  returning * into invalidated_head;

  insert into public.route_estimate_recompute_jobs (
    company_id, load_id, operation, context_version, context_fingerprint,
    expected_revision_id, quote_usd, reason, idempotency_key, created_by,
    empty_origin_kind, empty_origin_load_id, empty_origin_stop_id
  ) values (
    target_company_id, target_load_id,
    case when prior_revision.id is null then 'initial_request' else 'context_recompute' end,
    invalidated_head.context_version, invalidated_head.context_fingerprint,
    prior_revision.id, coalesce(prior_revision.quote_usd, prior_job.quote_usd),
    case when prior_revision.id is null then 'initial' else invalidation_reason end,
    gen_random_uuid(), invalidating_actor_id,
    origin ->> 'kind', nullif(origin ->> 'origin_load_id', '')::uuid,
    nullif(origin ->> 'origin_stop_id', '')::uuid
  ) returning * into created_job;

  if prior_revision.id is not null then
    insert into public.route_estimate_context_invalidations (
      company_id, load_id, prior_revision_id, context_version, reason, invalidated_by
    ) values (
      target_company_id, target_load_id, prior_revision.id,
      invalidated_head.context_version, invalidation_reason, invalidating_actor_id
    );
    insert into public.route_estimate_notifications (
      company_id, load_id, route_estimate_revision_id, recipient_role,
      notification_type, payload
    ) values (
      target_company_id, target_load_id, prior_revision.id, 'dispatcher',
      'route_estimate_invalidated', jsonb_build_object(
        'loadId', target_load_id, 'revisionNumber', prior_revision.revision_number,
        'reason', invalidation_reason, 'contextVersion', invalidated_head.context_version
      )
    ) on conflict do nothing;
  end if;
  insert into public.audit_events (
    company_id, actor_id, action, before_data, after_data, entity_type, entity_id
  ) values (
    target_company_id, invalidating_actor_id, 'route_estimate.context_invalidated',
    jsonb_build_object('priorRevisionId', prior_revision.id, 'priorJobId', prior_job.id),
    jsonb_build_object('reason', invalidation_reason,
      'contextVersion', invalidated_head.context_version,
      'recomputeJobQueued', true, 'emptyOriginKind', created_job.empty_origin_kind),
    'load', target_load_id
  );
  return true;
end;
$$;

create or replace function public.invalidate_route_estimate_dependents(
  target_company_id uuid,
  changed_origin_load_id uuid,
  invalidation_reason text,
  invalidating_actor_id uuid default null
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare dependent_load_id uuid;
begin
  for dependent_load_id in
    select distinct dependent.load_id from (
      select head.load_id
      from public.route_estimate_heads as head
      join public.route_estimate_revisions as revision
        on revision.company_id = head.company_id and revision.id = head.current_revision_id
      where head.company_id = target_company_id and head.state = 'current'
        and revision.empty_origin_load_id = changed_origin_load_id
      union
      select job.load_id
      from public.route_estimate_recompute_jobs as job
      where job.company_id = target_company_id and job.empty_origin_load_id = changed_origin_load_id
        and job.status in ('pending', 'claimed')
    ) as dependent
  loop
    perform public.invalidate_route_estimate_context(
      target_company_id, dependent_load_id, invalidation_reason, invalidating_actor_id
    );
  end loop;
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
  target_load_id uuid;
  target_load public.loads%rowtype;
  head public.route_estimate_heads%rowtype;
  job public.route_estimate_recompute_jobs%rowtype;
  completed_revision public.route_estimate_revisions%rowtype;
  origin jsonb;
  planned_stops jsonb;
  planned_stop_count integer;
begin
  if actor_id is null or not public.has_active_company_role(
    target_company_id, array['owner', 'admin', 'dispatcher']::public.company_role[]
  ) then
    raise exception using errcode = '42501', message = 'only an authorized dispatcher may process a route estimate';
  end if;
  select load_id into target_load_id from public.route_estimate_recompute_jobs
  where company_id = target_company_id and id = target_job_id and idempotency_key = expected_idempotency_key;
  if not found then raise exception using errcode = '42501', message = 'a matching route estimate job is required'; end if;
  select * into target_load from public.loads
  where company_id = target_company_id and id = target_load_id for update;
  perform pg_advisory_xact_lock(public.route_estimate_lock_key(target_company_id, target_load_id));
  select * into head from public.route_estimate_heads
  where company_id = target_company_id and load_id = target_load_id for update;
  select * into job from public.route_estimate_recompute_jobs
  where company_id = target_company_id and id = target_job_id and idempotency_key = expected_idempotency_key
  for update;
  if job.status = 'completed' then
    select * into completed_revision from public.route_estimate_revisions
    where company_id = target_company_id and id = job.completed_revision_id;
    return jsonb_build_object('status', 'completed', 'revision', public.route_estimate_revision_response(completed_revision));
  end if;
  if job.status = 'superseded' then
    return jsonb_build_object('status', 'stale', 'reason', 'superseded');
  end if;
  if job.status = 'claimed' and job.claimed_at > timezone('utc', now()) - interval '5 minutes' then
    raise exception using errcode = '55P03', message = 'the route estimate job is already claimed';
  end if;
  origin := public.route_estimate_proposal_origin(target_company_id, target_load_id);
  if job.context_fingerprint is distinct from public.route_estimate_context_fingerprint(target_company_id, target_load_id)
    or head.context_version <> job.context_version
    or head.context_fingerprint is distinct from job.context_fingerprint then
    perform public.invalidate_route_estimate_context(
      target_company_id, target_load_id, 'active_final_stop_changed', actor_id
    );
    return jsonb_build_object('status', 'stale', 'reason', 'context_changed');
  end if;
  select count(*), jsonb_agg(jsonb_build_object(
    'id', stop.id, 'label', left(coalesce(stop.stop_data ->> 'address', ''), 160),
    'latitude', (stop.stop_data ->> 'latitude')::numeric,
    'longitude', (stop.stop_data ->> 'longitude')::numeric
  ) order by stop.sequence) into planned_stop_count, planned_stops
  from public.load_stops as stop
  where stop.company_id = target_company_id and stop.load_id = target_load_id
    and public.route_estimate_stop_coordinates_are_valid(stop.stop_data);
  if planned_stop_count not between 2 and 16 or exists (
    select 1 from public.load_stops as stop
    where stop.company_id = target_company_id and stop.load_id = target_load_id
      and not public.route_estimate_stop_coordinates_are_valid(stop.stop_data)
  ) then
    raise exception using errcode = '22023', message = 'between two and sixteen planned stops with valid coordinates are required';
  end if;
  update public.route_estimate_recompute_jobs
  set status = 'claimed', claimed_by = actor_id, claimed_at = timezone('utc', now()),
      empty_origin_kind = origin ->> 'kind',
      empty_origin_load_id = nullif(origin ->> 'origin_load_id', '')::uuid,
      empty_origin_stop_id = nullif(origin ->> 'origin_stop_id', '')::uuid
  where company_id = target_company_id and id = target_job_id;
  return jsonb_build_object(
    'id', job.id, 'company_id', job.company_id, 'load_id', job.load_id,
    'context_version', job.context_version, 'context_fingerprint', job.context_fingerprint,
    'quote_usd', job.quote_usd, 'empty_origin_kind', origin ->> 'kind',
    'empty_origin', origin -> 'point', 'planned_stops', planned_stops
  );
end;
$$;

drop function public.complete_route_estimate_recompute_job(uuid, uuid, uuid, integer, text, numeric, numeric, text, jsonb);
create function public.complete_route_estimate_recompute_job(
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
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor_id uuid := (select auth.uid());
  target_load_id uuid;
  target_load public.loads%rowtype;
  head public.route_estimate_heads%rowtype;
  job public.route_estimate_recompute_jobs%rowtype;
  prior_revision public.route_estimate_revisions%rowtype;
  created_revision public.route_estimate_revisions%rowtype;
  origin jsonb;
begin
  if actor_id is null or not public.has_active_company_role(
    target_company_id, array['owner', 'admin', 'dispatcher']::public.company_role[]
  ) then
    raise exception using errcode = '42501', message = 'only an authorized dispatcher may persist a route estimate';
  end if;
  select load_id into target_load_id from public.route_estimate_recompute_jobs
  where company_id = target_company_id and id = target_job_id and idempotency_key = expected_idempotency_key;
  if not found then raise exception using errcode = '42501', message = 'a matching route estimate job is required'; end if;
  select * into target_load from public.loads
  where company_id = target_company_id and id = target_load_id for update;
  perform pg_advisory_xact_lock(public.route_estimate_lock_key(target_company_id, target_load_id));
  select * into head from public.route_estimate_heads
  where company_id = target_company_id and load_id = target_load_id for update;
  select * into job from public.route_estimate_recompute_jobs
  where company_id = target_company_id and id = target_job_id and idempotency_key = expected_idempotency_key
  for update;
  if job.status = 'completed' then
    select * into created_revision from public.route_estimate_revisions
    where company_id = target_company_id and id = job.completed_revision_id;
    return jsonb_build_object('status', 'completed', 'revision', public.route_estimate_revision_response(created_revision));
  end if;
  if job.status = 'superseded' then
    return jsonb_build_object('status', 'stale', 'reason', 'superseded');
  end if;
  if job.status <> 'claimed' or job.claimed_by is distinct from actor_id
    or job.claimed_at <= timezone('utc', now()) - interval '5 minutes' then
    raise exception using errcode = '42501', message = 'a current route estimate lease owned by this worker is required';
  end if;
  if expected_context_version <> job.context_version
    or expected_context_fingerprint is distinct from job.context_fingerprint then
    return jsonb_build_object('status', 'stale', 'reason', 'caller_context_mismatch');
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
  origin := public.route_estimate_proposal_origin(target_company_id, target_load_id);
  if job.context_fingerprint is distinct from public.route_estimate_context_fingerprint(target_company_id, target_load_id)
    or head.context_version <> job.context_version
    or head.context_fingerprint is distinct from job.context_fingerprint
    or (job.reason = 'initial' and head.state <> 'initial_requested')
    or (job.reason <> 'initial' and (
      head.state not in ('recompute_requested', 'recomputing')
      or head.stale_revision_id is distinct from job.expected_revision_id
    )) then
    perform public.invalidate_route_estimate_context(
      target_company_id, target_load_id, 'active_final_stop_changed', actor_id
    );
    return jsonb_build_object('status', 'stale', 'reason', 'context_changed');
  end if;
  if job.reason <> 'initial' then
    select * into prior_revision from public.route_estimate_revisions
    where company_id = target_company_id and id = job.expected_revision_id;
  end if;
  insert into public.route_estimate_revisions (
    company_id, load_id, revision_number, previous_revision_id,
    quote_context_driver_id, empty_origin_kind, empty_origin_load_id,
    empty_origin_stop_id, empty_miles, loaded_miles, quote_usd,
    provider_name, provider_route_data, created_by
  ) values (
    target_company_id, target_load_id, coalesce(prior_revision.revision_number, 0) + 1,
    prior_revision.id, target_load.assigned_driver_id, job.empty_origin_kind,
    job.empty_origin_load_id, job.empty_origin_stop_id,
    calculated_empty_miles, calculated_loaded_miles, job.quote_usd,
    selected_provider_name, route_summary, actor_id
  ) returning * into created_revision;
  update public.route_estimate_heads
  set current_revision_id = created_revision.id, stale_revision_id = null,
      state = 'current', updated_at = timezone('utc', now())
  where company_id = target_company_id and load_id = target_load_id;
  if prior_revision.id is not null then
    insert into public.route_estimate_invalidations (
      company_id, load_id, prior_revision_id, replacement_revision_id, reason, invalidated_by
    ) values (
      target_company_id, target_load_id, prior_revision.id, created_revision.id, job.reason, actor_id
    ) on conflict (prior_revision_id) do nothing;
  end if;
  update public.route_estimate_recompute_jobs
  set status = 'completed', completed_revision_id = created_revision.id,
      completed_at = timezone('utc', now())
  where company_id = target_company_id and id = target_job_id;
  insert into public.audit_events (
    company_id, actor_id, action, before_data, after_data, entity_type, entity_id
  ) values (
    target_company_id, actor_id,
    case when job.reason = 'initial' then 'route_estimate.created' else 'route_estimate.recomputed' end,
    jsonb_build_object('priorRevisionId', prior_revision.id),
    jsonb_build_object('revisionId', created_revision.id, 'revisionNumber', created_revision.revision_number,
      'contextVersion', job.context_version, 'emptyOriginKind', job.empty_origin_kind),
    'load', target_load_id
  );
  return jsonb_build_object('status', 'completed', 'revision', public.route_estimate_revision_response(created_revision));
end;
$$;

create or replace function public.release_route_estimate_recompute_job(
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
  target_load_id uuid;
  target_load public.loads%rowtype;
  head public.route_estimate_heads%rowtype;
  job public.route_estimate_recompute_jobs%rowtype;
begin
  if actor_id is null or not public.has_active_company_role(
    target_company_id, array['owner', 'admin', 'dispatcher']::public.company_role[]
  ) then
    raise exception using errcode = '42501', message = 'only an authorized dispatcher may release a route estimate job';
  end if;
  select load_id into target_load_id from public.route_estimate_recompute_jobs
  where company_id = target_company_id and id = target_job_id and idempotency_key = expected_idempotency_key;
  if not found then raise exception using errcode = '42501', message = 'a matching route estimate job is required'; end if;
  select * into target_load from public.loads
  where company_id = target_company_id and id = target_load_id for update;
  perform pg_advisory_xact_lock(public.route_estimate_lock_key(target_company_id, target_load_id));
  select * into head from public.route_estimate_heads
  where company_id = target_company_id and load_id = target_load_id for update;
  select * into job from public.route_estimate_recompute_jobs
  where company_id = target_company_id and id = target_job_id and idempotency_key = expected_idempotency_key
  for update;
  if job.status <> 'claimed' or job.claimed_by is distinct from actor_id
    or job.claimed_at <= timezone('utc', now()) - interval '5 minutes' then
    raise exception using errcode = '42501', message = 'a current route estimate lease owned by this worker is required';
  end if;
  if job.context_fingerprint is distinct from public.route_estimate_context_fingerprint(target_company_id, target_load_id)
    or head.context_version <> job.context_version
    or head.context_fingerprint is distinct from job.context_fingerprint then
    perform public.invalidate_route_estimate_context(
      target_company_id, target_load_id, 'active_final_stop_changed', actor_id
    );
    return false;
  end if;
  update public.route_estimate_recompute_jobs
  set status = 'pending', claimed_by = null, claimed_at = null
  where company_id = target_company_id and id = target_job_id;
  return true;
end;
$$;

create or replace function public.invalidate_route_estimates_after_driver_location_change()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare dependent_load_id uuid;
begin
  for dependent_load_id in
    select distinct load.id from public.loads as load
    join public.route_estimate_heads as head
      on head.company_id = load.company_id and head.load_id = load.id
    where load.company_id = new.company_id and load.assigned_driver_id = new.driver_id
      and head.state in ('initial_requested', 'recompute_requested', 'recomputing')
  loop
    perform public.invalidate_route_estimate_context(
      new.company_id, dependent_load_id, 'active_final_stop_changed', (select auth.uid())
    );
  end loop;
  return new;
end;
$$;

create trigger driver_accepted_route_locations_invalidate_estimates
after insert on public.driver_accepted_route_locations
for each row execute function public.invalidate_route_estimates_after_driver_location_change();

create or replace function public.invalidate_route_estimates_after_base_change()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare dependent_load_id uuid;
begin
  for dependent_load_id in
    select distinct job.load_id
    from public.route_estimate_recompute_jobs as job
    where job.company_id = new.company_id and job.empty_origin_kind = 'declared_base'
      and job.status in ('pending', 'claimed')
  loop
    perform public.invalidate_route_estimate_context(
      new.company_id, dependent_load_id, 'active_final_stop_changed', (select auth.uid())
    );
  end loop;
  return new;
end;
$$;

create trigger company_route_bases_invalidate_estimates
after insert or update of point on public.company_route_bases
for each row execute function public.invalidate_route_estimates_after_base_change();

drop policy if exists route_estimate_recompute_jobs_select_dispatch_management
  on public.route_estimate_recompute_jobs;
revoke select on public.route_estimate_recompute_jobs from authenticated;

revoke all on function public.route_estimate_lock_key(uuid, uuid),
  public.route_estimate_proposal_origin(uuid, uuid),
  public.route_estimate_context_fingerprint(uuid, uuid),
  public.route_estimate_revision_response(public.route_estimate_revisions),
  public.route_estimate_job_response(public.route_estimate_recompute_jobs),
  public.invalidate_route_estimate_context(uuid, uuid, text, uuid),
  public.invalidate_route_estimate_dependents(uuid, uuid, text, uuid),
  public.invalidate_route_estimates_after_driver_location_change(),
  public.invalidate_route_estimates_after_base_change() from public, anon, authenticated;
revoke all on function public.request_initial_route_estimate(uuid, uuid, numeric, uuid),
  public.claim_route_estimate_recompute_job(uuid, uuid, uuid),
  public.complete_route_estimate_recompute_job(uuid, uuid, uuid, integer, text, numeric, numeric, text, jsonb),
  public.release_route_estimate_recompute_job(uuid, uuid, uuid) from public, anon;
grant execute on function public.request_initial_route_estimate(uuid, uuid, numeric, uuid),
  public.claim_route_estimate_recompute_job(uuid, uuid, uuid),
  public.complete_route_estimate_recompute_job(uuid, uuid, uuid, integer, text, numeric, numeric, text, jsonb),
  public.release_route_estimate_recompute_job(uuid, uuid, uuid) to authenticated;
