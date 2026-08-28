-- CarrierFlow route-estimate integrity hardening. This is deliberately
-- forward-only: 0008 revisions remain immutable history, while this migration
-- adds a mutable availability head and a durable recomputation boundary.
-- A route estimate is never "current" after the underlying assignment or
-- planned routing context has changed.

alter table public.audit_events
  drop constraint audit_events_before_data_create_only_check,
  add constraint audit_events_before_data_create_only_check check (
    before_data is not null
    or action in (
      'membership.invited', 'driver.created', 'vehicle.created',
      'driver_vehicle.assigned', 'driver_shift.started', 'load.created',
      'load.evidence_recorded', 'load.incident_reported',
      'route_estimate.created'
    )
  );

create table public.route_estimate_heads (
  company_id uuid not null references public.companies(id) on delete restrict,
  load_id uuid not null,
  current_revision_id uuid,
  stale_revision_id uuid,
  state text not null default 'current' check (
    state in ('current', 'recompute_requested', 'recomputing')
  ),
  context_version integer not null default 1 check (context_version > 0),
  context_fingerprint text not null check (char_length(context_fingerprint) between 16 and 128),
  updated_at timestamptz not null default timezone('utc', now()),
  primary key (company_id, load_id),
  foreign key (load_id, company_id)
    references public.loads (id, company_id) on delete restrict,
  foreign key (current_revision_id, company_id)
    references public.route_estimate_revisions (id, company_id) on delete restrict,
  foreign key (stale_revision_id, company_id)
    references public.route_estimate_revisions (id, company_id) on delete restrict,
  check (
    (state = 'current' and current_revision_id is not null and stale_revision_id is null)
    or (state in ('recompute_requested', 'recomputing') and current_revision_id is null and stale_revision_id is not null)
  )
);

create table public.route_estimate_context_invalidations (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete restrict,
  load_id uuid not null,
  prior_revision_id uuid not null,
  context_version integer not null check (context_version > 0),
  reason text not null check (
    reason in ('active_final_stop_changed', 'driver_changed', 'assignment_changed')
  ),
  invalidated_by uuid references auth.users(id) on delete set null,
  invalidated_at timestamptz not null default timezone('utc', now()),
  unique (company_id, load_id, context_version),
  foreign key (load_id, company_id)
    references public.loads (id, company_id) on delete restrict,
  foreign key (prior_revision_id, company_id)
    references public.route_estimate_revisions (id, company_id) on delete restrict
);

create table public.route_estimate_recompute_jobs (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete restrict,
  load_id uuid not null,
  operation text not null default 'context_recompute' check (operation = 'context_recompute'),
  context_version integer not null check (context_version > 0),
  context_fingerprint text not null check (char_length(context_fingerprint) between 16 and 128),
  expected_revision_id uuid not null,
  quote_usd numeric(14, 2) not null check (quote_usd > 0),
  reason text not null check (
    reason in ('active_final_stop_changed', 'driver_changed', 'assignment_changed')
  ),
  idempotency_key uuid not null,
  status text not null default 'pending' check (status in ('pending', 'claimed', 'completed')),
  claimed_by uuid references auth.users(id) on delete set null,
  claimed_at timestamptz,
  completed_revision_id uuid,
  completed_at timestamptz,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default timezone('utc', now()),
  unique (company_id, load_id, context_version),
  unique (company_id, operation, idempotency_key),
  foreign key (load_id, company_id)
    references public.loads (id, company_id) on delete restrict,
  foreign key (expected_revision_id, company_id)
    references public.route_estimate_revisions (id, company_id) on delete restrict,
  foreign key (completed_revision_id, company_id)
    references public.route_estimate_revisions (id, company_id) on delete restrict,
  check (
    (status = 'pending' and claimed_at is null and claimed_by is null and completed_at is null and completed_revision_id is null)
    or (status = 'claimed' and claimed_at is not null and claimed_by is not null and completed_at is null and completed_revision_id is null)
    or (status = 'completed' and completed_at is not null and completed_revision_id is not null)
  )
);

create index route_estimate_heads_current_idx
  on public.route_estimate_heads (company_id, load_id)
  where state = 'current';
create index route_estimate_recompute_jobs_pending_idx
  on public.route_estimate_recompute_jobs (company_id, status, created_at)
  where status in ('pending', 'claimed');
create index route_estimate_context_invalidations_load_idx
  on public.route_estimate_context_invalidations (company_id, load_id, invalidated_at desc);
create unique index route_estimate_notifications_context_once_idx
  on public.route_estimate_notifications (
    company_id, load_id, notification_type, (payload ->> 'contextVersion')
  )
  where notification_type = 'route_estimate_invalidated'
    and payload ? 'contextVersion';

comment on table public.route_estimate_heads is
  'Mutable currentness pointer. Stale revisions remain immutable history and are intentionally not returned by get_current_route_estimate.';
comment on table public.route_estimate_recompute_jobs is
  'Durable, tenant-scoped routing-provider work queue. Context is derived inside the database, not accepted from a client.';

create function public.route_estimate_context_fingerprint(
  target_company_id uuid,
  target_load_id uuid
)
returns text
language sql
stable
security definer
set search_path = ''
as $$
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
    ), '')
  )
  from public.loads as load
  where load.company_id = target_company_id and load.id = target_load_id;
$$;

create function public.route_estimate_stop_coordinates_are_valid(stop_data_value jsonb)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select stop_data_value is not null
    and jsonb_typeof(stop_data_value) = 'object'
    and jsonb_typeof(stop_data_value -> 'latitude') = 'number'
    and jsonb_typeof(stop_data_value -> 'longitude') = 'number'
    and (stop_data_value ->> 'latitude')::numeric between -90 and 90
    and (stop_data_value ->> 'longitude')::numeric between -180 and 180;
$$;

create function public.route_estimate_safe_summary(route_summary jsonb)
returns boolean
language plpgsql
immutable
set search_path = ''
as $$
declare
  segment text;
  unexpected_key text;
begin
  if route_summary is null
    or jsonb_typeof(route_summary) <> 'object'
    or octet_length(route_summary::text) > 8192 then
    return false;
  end if;

  select key into unexpected_key
  from jsonb_object_keys(route_summary) as key
  where key not in ('empty', 'loaded')
  limit 1;
  if unexpected_key is not null then
    return false;
  end if;

  foreach segment in array array['empty', 'loaded']
  loop
    if jsonb_typeof(route_summary -> segment) <> 'object'
      or not (route_summary -> segment) ?& array['distanceMeters', 'durationSeconds'] then
      return false;
    end if;
    select key into unexpected_key
    from jsonb_object_keys(route_summary -> segment) as key
    where key not in ('distanceMeters', 'durationSeconds')
    limit 1;
    if unexpected_key is not null
      or jsonb_typeof(route_summary -> segment -> 'distanceMeters') <> 'number'
      or jsonb_typeof(route_summary -> segment -> 'durationSeconds') <> 'number'
      or (route_summary -> segment ->> 'distanceMeters')::numeric not between 0 and 5000000
      or (route_summary -> segment ->> 'durationSeconds')::numeric not between 0 and 604800 then
      return false;
    end if;
  end loop;

  return true;
end;
$$;

-- Each legacy revision obtains a head exactly once. New work is persisted only
-- by complete_route_estimate_recompute_job below, which advances this head
-- atomically after checking its expected context version/fingerprint.
create function public.sync_route_estimate_head_from_revision()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.route_estimate_heads (
    company_id, load_id, current_revision_id, state, context_version, context_fingerprint
  ) values (
    new.company_id,
    new.load_id,
    new.id,
    'current',
    1,
    public.route_estimate_context_fingerprint(new.company_id, new.load_id)
  )
  on conflict (company_id, load_id) do nothing;
  return new;
end;
$$;

create trigger route_estimate_revisions_create_head
after insert on public.route_estimate_revisions
for each row execute function public.sync_route_estimate_head_from_revision();

-- Upgrade any 0008 revisions already present before this migration was applied.
insert into public.route_estimate_heads (
  company_id, load_id, current_revision_id, state, context_version, context_fingerprint
)
select latest.company_id,
       latest.load_id,
       latest.id,
       'current',
       1,
       public.route_estimate_context_fingerprint(latest.company_id, latest.load_id)
from (
  select distinct on (revision.company_id, revision.load_id)
    revision.company_id, revision.load_id, revision.id
  from public.route_estimate_revisions as revision
  order by revision.company_id, revision.load_id, revision.revision_number desc
) as latest
on conflict (company_id, load_id) do nothing;

create function public.invalidate_route_estimate_context(
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
  if not found or existing_head.state <> 'current' then
    return false;
  end if;

  select * into prior_revision
  from public.route_estimate_revisions
  where company_id = target_company_id and id = existing_head.current_revision_id;

  update public.route_estimate_heads
  set current_revision_id = null,
      stale_revision_id = existing_head.current_revision_id,
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
    company_id, load_id, context_version, context_fingerprint,
    expected_revision_id, quote_usd, reason, idempotency_key, created_by
  ) values (
    target_company_id, target_load_id, invalidated_head.context_version,
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
      'loadId', target_load_id,
      'revisionNumber', prior_revision.revision_number,
      'reason', invalidation_reason,
      'contextVersion', invalidated_head.context_version
    )
  ) on conflict do nothing;

  insert into public.audit_events (
    company_id, actor_id, action, before_data, after_data, entity_type, entity_id
  ) values (
    target_company_id, invalidating_actor_id, 'route_estimate.context_invalidated',
    jsonb_build_object('revisionId', prior_revision.id, 'revisionNumber', prior_revision.revision_number),
    jsonb_build_object(
      'reason', invalidation_reason,
      'contextVersion', invalidated_head.context_version,
      'recomputeJobQueued', true
    ),
    'load', target_load_id
  );

  return true;
end;
$$;

create function public.invalidate_route_estimate_dependents(
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
declare
  dependent_load_id uuid;
begin
  for dependent_load_id in
    select head.load_id
    from public.route_estimate_heads as head
    join public.route_estimate_revisions as revision
      on revision.company_id = head.company_id
      and revision.id = head.current_revision_id
    where head.company_id = target_company_id
      and head.state = 'current'
      and revision.empty_origin_load_id = changed_origin_load_id
  loop
    perform public.invalidate_route_estimate_context(
      target_company_id, dependent_load_id, invalidation_reason, invalidating_actor_id
    );
  end loop;
end;
$$;

create function public.invalidate_route_estimates_after_load_context_change()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  context_reason text;
begin
  if new.assigned_driver_id is distinct from old.assigned_driver_id then
    context_reason := 'driver_changed';
  elsif new.assigned_vehicle_id is distinct from old.assigned_vehicle_id then
    context_reason := 'assignment_changed';
  else
    return new;
  end if;

  perform public.invalidate_route_estimate_context(new.company_id, new.id, context_reason, (select auth.uid()));
  perform public.invalidate_route_estimate_dependents(new.company_id, new.id, context_reason, (select auth.uid()));
  return new;
end;
$$;

create trigger loads_invalidate_route_estimate_context
after update of assigned_driver_id, assigned_vehicle_id on public.loads
for each row execute function public.invalidate_route_estimates_after_load_context_change();

create function public.invalidate_route_estimates_after_stop_context_change()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  changed_company_id uuid := coalesce(new.company_id, old.company_id);
  changed_load_id uuid := coalesce(new.load_id, old.load_id);
begin
  -- A change to the final stop is material. Invalidating on any planned-stop
  -- change is intentionally conservative, which prevents an ordering edit from
  -- leaving a former final stop quoted as though it were still the endpoint.
  perform public.invalidate_route_estimate_context(
    changed_company_id, changed_load_id, 'active_final_stop_changed', (select auth.uid())
  );
  perform public.invalidate_route_estimate_dependents(
    changed_company_id, changed_load_id, 'active_final_stop_changed', (select auth.uid())
  );
  return coalesce(new, old);
end;
$$;

create trigger load_stops_invalidate_route_estimate_context
after insert or update or delete on public.load_stops
for each row execute function public.invalidate_route_estimates_after_stop_context_change();

create function public.get_current_route_estimate(
  target_company_id uuid,
  target_load_id uuid
)
returns setof public.route_estimate_revisions
language sql
stable
security invoker
set search_path = ''
as $$
  select revision.*
  from public.route_estimate_heads as head
  join public.route_estimate_revisions as revision
    on revision.company_id = head.company_id
    and revision.id = head.current_revision_id
  where head.company_id = target_company_id
    and head.load_id = target_load_id
    and head.state = 'current'
    and public.has_active_company_role(
      target_company_id,
      array['owner', 'admin', 'dispatcher']::public.company_role[]
    );
$$;

create function public.assign_load_resources(
  target_company_id uuid,
  target_load_id uuid,
  target_driver_id uuid,
  target_vehicle_id uuid
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
begin
  if actor_id is null or not public.has_active_company_role(
    target_company_id, array['owner', 'admin', 'dispatcher']::public.company_role[]
  ) then
    raise exception using errcode = '42501', message = 'only an authorized dispatcher may assign a load';
  end if;
  if not exists (
    select 1 from public.drivers
    where company_id = target_company_id and id = target_driver_id and status = 'active'
  ) or not exists (
    select 1 from public.vehicles
    where company_id = target_company_id and id = target_vehicle_id and status = 'active'
  ) or not exists (
    select 1 from public.driver_vehicle_assignments
    where company_id = target_company_id
      and driver_id = target_driver_id
      and vehicle_id = target_vehicle_id
      and unassigned_at is null
  ) then
    raise exception using errcode = '22023', message = 'an active driver and its active vehicle assignment are required';
  end if;

  select * into existing_load
  from public.loads
  where company_id = target_company_id and id = target_load_id
  for update;
  if not found then
    raise exception using errcode = '42501', message = 'only an authorized dispatcher may assign a load';
  end if;

  update public.loads
  set assigned_driver_id = target_driver_id,
      assigned_vehicle_id = target_vehicle_id,
      updated_at = timezone('utc', now())
  where company_id = target_company_id and id = target_load_id
  returning * into updated_load;

  insert into public.audit_events (
    company_id, actor_id, action, before_data, after_data, entity_type, entity_id
  ) values (
    target_company_id, actor_id, 'load.resources_assigned',
    jsonb_build_object('driverId', existing_load.assigned_driver_id, 'vehicleId', existing_load.assigned_vehicle_id),
    jsonb_build_object('driverId', updated_load.assigned_driver_id, 'vehicleId', updated_load.assigned_vehicle_id),
    'load', target_load_id
  );
  return updated_load;
end;
$$;

create function public.update_final_planned_stop(
  target_company_id uuid,
  target_load_id uuid,
  target_stop_id uuid,
  replacement_stop_data jsonb
)
returns public.load_stops
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor_id uuid := (select auth.uid());
  existing_stop public.load_stops%rowtype;
  updated_stop public.load_stops%rowtype;
begin
  if actor_id is null or not public.has_active_company_role(
    target_company_id, array['owner', 'admin', 'dispatcher']::public.company_role[]
  ) then
    raise exception using errcode = '42501', message = 'only an authorized dispatcher may edit a planned stop';
  end if;
  if replacement_stop_data is null
    or jsonb_typeof(replacement_stop_data) <> 'object'
    or octet_length(replacement_stop_data::text) > 4096
    or char_length(coalesce(btrim(replacement_stop_data ->> 'address'), '')) not between 1 and 400
    or replacement_stop_data ->> 'country' not in ('US', 'CA')
    or char_length(coalesce(btrim(replacement_stop_data ->> 'timezone'), '')) not between 1 and 80
    or not public.route_estimate_stop_coordinates_are_valid(replacement_stop_data) then
    raise exception using errcode = '22023', message = 'a bounded final planned stop with valid coordinates is required';
  end if;

  select * into existing_stop
  from public.load_stops as stop
  where stop.company_id = target_company_id
    and stop.load_id = target_load_id
    and stop.id = target_stop_id
  for update;
  if not found or exists (
    select 1 from public.load_stops as later_stop
    where later_stop.company_id = target_company_id
      and later_stop.load_id = target_load_id
      and later_stop.sequence > existing_stop.sequence
  ) then
    raise exception using errcode = '22023', message = 'only the final planned stop may be updated by this command';
  end if;

  update public.load_stops
  set stop_data = replacement_stop_data,
      country_code = replacement_stop_data ->> 'country',
      timezone_name = replacement_stop_data ->> 'timezone'
  where company_id = target_company_id and id = target_stop_id
  returning * into updated_stop;

  insert into public.audit_events (
    company_id, actor_id, action, before_data, after_data, entity_type, entity_id
  ) values (
    target_company_id, actor_id, 'load.final_stop_updated',
    jsonb_build_object('stopId', target_stop_id, 'stopData', existing_stop.stop_data),
    jsonb_build_object('stopId', target_stop_id, 'stopData', updated_stop.stop_data),
    'load', target_load_id
  );
  return updated_stop;
end;
$$;

create function public.claim_route_estimate_recompute_job(
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
begin
  if actor_id is null or not public.has_active_company_role(
    target_company_id, array['owner', 'admin', 'dispatcher']::public.company_role[]
  ) then
    raise exception using errcode = '42501', message = 'only an authorized dispatcher may process a route estimate';
  end if;
  select * into job
  from public.route_estimate_recompute_jobs
  where company_id = target_company_id
    and id = target_job_id
    and idempotency_key = expected_idempotency_key
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
        'id', completed_revision.id,
        'company_id', completed_revision.company_id,
        'revision_number', completed_revision.revision_number,
        'empty_miles', completed_revision.empty_miles,
        'loaded_miles', completed_revision.loaded_miles,
        'total_miles', completed_revision.total_miles,
        'quote_usd', completed_revision.quote_usd,
        'quote_usd_per_total_mile', completed_revision.quote_usd_per_total_mile
      )
    );
  end if;
  if job.status = 'claimed' then
    raise exception using errcode = '55P03', message = 'the route estimate job is already claimed';
  end if;
  if not exists (
    select 1 from public.route_estimate_heads as head
    where head.company_id = target_company_id
      and head.load_id = job.load_id
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
      'id', stop.id,
      'label', left(coalesce(stop.stop_data ->> 'address', ''), 400),
      'latitude', (stop.stop_data ->> 'latitude')::numeric,
      'longitude', (stop.stop_data ->> 'longitude')::numeric
    ) order by stop.sequence
  ) into planned_stop_count, planned_stops
  from public.load_stops as stop
  where stop.company_id = target_company_id
    and stop.load_id = job.load_id
    and public.route_estimate_stop_coordinates_are_valid(stop.stop_data);
  if planned_stop_count not between 2 and 16
    or exists (
      select 1 from public.load_stops as stop
      where stop.company_id = target_company_id and stop.load_id = job.load_id
        and not public.route_estimate_stop_coordinates_are_valid(stop.stop_data)
    ) then
    raise exception using errcode = '22023', message = 'between two and sixteen planned stops with valid coordinates are required';
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
  order by load.updated_at desc
  limit 1;
  if not found then
    raise exception using errcode = '22023', message = 'an active load final planned stop is required for this route estimate';
  end if;
  select * into active_final_stop
  from public.load_stops as stop
  where stop.company_id = target_company_id and stop.load_id = active_load.id
  order by stop.sequence desc
  limit 1;
  if not found or not public.route_estimate_stop_coordinates_are_valid(active_final_stop.stop_data) then
    raise exception using errcode = '22023', message = 'the active load requires a final planned stop with valid coordinates';
  end if;

  update public.route_estimate_recompute_jobs
  set status = 'claimed', claimed_by = actor_id, claimed_at = timezone('utc', now())
  where id = job.id and company_id = target_company_id;

  return jsonb_build_object(
    'id', job.id,
    'company_id', job.company_id,
    'load_id', job.load_id,
    'context_version', job.context_version,
    'context_fingerprint', job.context_fingerprint,
    'quote_usd', job.quote_usd,
    'empty_origin_kind', 'active_load_final_stop',
    'empty_origin', jsonb_build_object(
      'id', active_final_stop.id,
      'label', left(coalesce(active_final_stop.stop_data ->> 'address', ''), 400),
      'latitude', (active_final_stop.stop_data ->> 'latitude')::numeric,
      'longitude', (active_final_stop.stop_data ->> 'longitude')::numeric
    ),
    'planned_stops', planned_stops
  );
end;
$$;

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
begin
  if actor_id is null or not public.has_active_company_role(
    target_company_id, array['owner', 'admin', 'dispatcher']::public.company_role[]
  ) then
    raise exception using errcode = '42501', message = 'only an authorized dispatcher may persist a route estimate';
  end if;
  select * into job
  from public.route_estimate_recompute_jobs
  where company_id = target_company_id
    and id = target_job_id
    and idempotency_key = expected_idempotency_key
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
    or expected_context_fingerprint is distinct from job.context_fingerprint then
    raise exception using errcode = '22023', message = 'the supplied route estimate context is stale';
  end if;
  if calculated_empty_miles is null
    or calculated_empty_miles < 0
    or calculated_empty_miles <> trunc(calculated_empty_miles, 3)
    or calculated_loaded_miles is null
    or calculated_loaded_miles <= 0
    or calculated_loaded_miles <> trunc(calculated_loaded_miles, 3)
    or selected_provider_name is null
    or selected_provider_name <> lower(btrim(selected_provider_name))
    or char_length(selected_provider_name) not between 1 and 80
    or not public.route_estimate_safe_summary(route_summary) then
    raise exception using errcode = '22023', message = 'bounded route estimate output is required';
  end if;

  select * into head
  from public.route_estimate_heads
  where company_id = target_company_id and load_id = job.load_id
  for update;
  if not found
    or head.state not in ('recompute_requested', 'recomputing')
    or head.context_version <> job.context_version
    or head.context_fingerprint is distinct from job.context_fingerprint
    or head.stale_revision_id is distinct from job.expected_revision_id then
    raise exception using errcode = '22023', message = 'the route estimate context changed before completion';
  end if;

  select * into target_load
  from public.loads
  where company_id = target_company_id and id = job.load_id
  for update;
  select * into active_load
  from public.loads as load
  where load.company_id = target_company_id
    and load.assigned_driver_id = target_load.assigned_driver_id
    and load.id <> target_load.id
    and load.operational_status in (
      'assigned', 'en_route_to_pickup', 'arrived_pickup', 'loading',
      'picked_up', 'en_route_to_delivery', 'arrived_delivery', 'unloading'
    )
  order by load.updated_at desc
  limit 1;
  select * into active_final_stop
  from public.load_stops as stop
  where stop.company_id = target_company_id and stop.load_id = active_load.id
  order by stop.sequence desc
  limit 1;
  if target_load.assigned_driver_id is null
    or not found
    or not public.route_estimate_stop_coordinates_are_valid(active_final_stop.stop_data) then
    raise exception using errcode = '22023', message = 'the server-derived active route context is no longer valid';
  end if;

  select * into prior_revision
  from public.route_estimate_revisions
  where company_id = target_company_id and id = job.expected_revision_id;

  insert into public.route_estimate_revisions (
    company_id, load_id, revision_number, previous_revision_id,
    quote_context_driver_id, empty_origin_kind, empty_origin_load_id,
    empty_origin_stop_id, empty_miles, loaded_miles, quote_usd,
    provider_name, provider_route_data, created_by
  ) values (
    target_company_id, job.load_id, prior_revision.revision_number + 1, prior_revision.id,
    target_load.assigned_driver_id, 'active_load_final_stop', active_load.id,
    active_final_stop.id, calculated_empty_miles, calculated_loaded_miles, job.quote_usd,
    selected_provider_name, route_summary, actor_id
  ) returning * into created_revision;

  update public.route_estimate_heads
  set current_revision_id = created_revision.id,
      stale_revision_id = null,
      state = 'current',
      updated_at = timezone('utc', now())
  where company_id = target_company_id and load_id = job.load_id;

  insert into public.route_estimate_invalidations (
    company_id, load_id, prior_revision_id, replacement_revision_id, reason, invalidated_by
  ) values (
    target_company_id, job.load_id, prior_revision.id, created_revision.id, job.reason, actor_id
  ) on conflict (prior_revision_id) do nothing;

  update public.route_estimate_recompute_jobs
  set status = 'completed', completed_revision_id = created_revision.id,
      completed_at = timezone('utc', now())
  where company_id = target_company_id and id = job.id;

  insert into public.audit_events (
    company_id, actor_id, action, before_data, after_data, entity_type, entity_id
  ) values (
    target_company_id, actor_id, 'route_estimate.recomputed',
    jsonb_build_object('revisionId', prior_revision.id, 'revisionNumber', prior_revision.revision_number),
    jsonb_build_object('revisionId', created_revision.id, 'revisionNumber', created_revision.revision_number,
      'contextVersion', job.context_version),
    'load', job.load_id
  );
  return created_revision;
end;
$$;

alter table public.route_estimate_heads enable row level security;
alter table public.route_estimate_heads force row level security;
alter table public.route_estimate_context_invalidations enable row level security;
alter table public.route_estimate_context_invalidations force row level security;
alter table public.route_estimate_recompute_jobs enable row level security;
alter table public.route_estimate_recompute_jobs force row level security;

revoke all on table public.route_estimate_heads,
  public.route_estimate_context_invalidations,
  public.route_estimate_recompute_jobs from public, anon, authenticated;
grant select on table public.route_estimate_heads,
  public.route_estimate_context_invalidations,
  public.route_estimate_recompute_jobs to authenticated;

create policy route_estimate_heads_select_dispatch_management
  on public.route_estimate_heads for select to authenticated
  using (public.has_active_company_role(
    company_id, array['owner', 'admin', 'dispatcher']::public.company_role[]
  ));
create policy route_estimate_context_invalidations_select_dispatch_management
  on public.route_estimate_context_invalidations for select to authenticated
  using (public.has_active_company_role(
    company_id, array['owner', 'admin', 'dispatcher']::public.company_role[]
  ));
create policy route_estimate_recompute_jobs_select_dispatch_management
  on public.route_estimate_recompute_jobs for select to authenticated
  using (public.has_active_company_role(
    company_id, array['owner', 'admin', 'dispatcher']::public.company_role[]
  ));

revoke all on function public.route_estimate_context_fingerprint(uuid, uuid),
  public.route_estimate_stop_coordinates_are_valid(jsonb),
  public.route_estimate_safe_summary(jsonb),
  public.sync_route_estimate_head_from_revision(),
  public.invalidate_route_estimate_context(uuid, uuid, text, uuid),
  public.invalidate_route_estimate_dependents(uuid, uuid, text, uuid),
  public.invalidate_route_estimates_after_load_context_change(),
  public.invalidate_route_estimates_after_stop_context_change() from public, anon, authenticated;
revoke all on function public.persist_route_estimate_revision(
  uuid, uuid, uuid, numeric, numeric, numeric, text, jsonb, text, uuid, text
) from authenticated;
revoke all on function public.get_current_route_estimate(uuid, uuid),
  public.assign_load_resources(uuid, uuid, uuid, uuid),
  public.update_final_planned_stop(uuid, uuid, uuid, jsonb),
  public.claim_route_estimate_recompute_job(uuid, uuid, uuid),
  public.complete_route_estimate_recompute_job(uuid, uuid, uuid, integer, text, numeric, numeric, text, jsonb)
from public, anon;
grant execute on function public.get_current_route_estimate(uuid, uuid),
  public.assign_load_resources(uuid, uuid, uuid, uuid),
  public.update_final_planned_stop(uuid, uuid, uuid, jsonb),
  public.claim_route_estimate_recompute_job(uuid, uuid, uuid),
  public.complete_route_estimate_recompute_job(uuid, uuid, uuid, integer, text, numeric, numeric, text, jsonb)
to authenticated;
