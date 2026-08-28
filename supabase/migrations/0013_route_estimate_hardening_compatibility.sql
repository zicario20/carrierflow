-- Compatibility correction after 0012 was applied locally.  Historical
-- immutable revisions may have been created before proposal-origin records
-- existed, so their legacy head fingerprint must remain calculable.  New
-- requests still call route_estimate_proposal_origin directly and therefore
-- retain the declared-base/fresh-location requirement.

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
declare origin jsonb := jsonb_build_object('fingerprint', 'legacy-unresolved-origin');
begin
  begin
    origin := public.route_estimate_proposal_origin(target_company_id, target_load_id);
  exception when sqlstate '22023' then
    -- A legacy persist path is allowed to establish its head without a new
    -- proposal origin. New request/claim/complete boundaries remain strict.
    origin := jsonb_build_object('fingerprint', 'legacy-unresolved-origin');
  end;
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

create or replace function public.request_initial_route_estimate(
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
  if quoted_amount_usd is null or quoted_amount_usd <= 0 or quoted_amount_usd <> trunc(quoted_amount_usd, 2) then
    raise exception using errcode = '22023', message = 'a valid decimal quoted USD amount is required';
  end if;
  if request_idempotency_key is null then
    raise exception using errcode = '22023', message = 'a durable route-estimate idempotency key is required';
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

revoke all on function public.route_estimate_context_fingerprint(uuid, uuid) from public, anon, authenticated;
revoke all on function public.request_initial_route_estimate(uuid, uuid, numeric, uuid) from public, anon;
grant execute on function public.request_initial_route_estimate(uuid, uuid, numeric, uuid) to authenticated;
