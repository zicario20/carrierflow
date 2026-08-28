-- CarrierFlow routing estimates: immutable, tenant-scoped operational pricing.
-- This boundary stores estimates only. It neither exposes broker revenue/margin
-- to drivers nor claims that a provider route is truck-safe or legally valid.

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

create table public.route_estimate_revisions (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete restrict,
  load_id uuid not null,
  revision_number integer not null check (revision_number > 0),
  previous_revision_id uuid,
  quote_context_driver_id uuid,
  empty_origin_kind text not null check (
    empty_origin_kind in (
      'active_load_final_stop', 'last_accepted_location', 'declared_base'
    )
  ),
  empty_origin_load_id uuid,
  empty_origin_stop_id uuid,
  empty_miles numeric(12, 3) not null check (empty_miles >= 0),
  loaded_miles numeric(12, 3) not null check (loaded_miles > 0),
  total_miles numeric generated always as (empty_miles + loaded_miles) stored,
  quote_usd numeric(14, 2) not null check (quote_usd > 0),
  quote_usd_per_total_mile numeric generated always as (
    quote_usd / (empty_miles + loaded_miles)
  ) stored,
  provider_name text not null check (
    provider_name = lower(btrim(provider_name))
    and char_length(provider_name) between 1 and 80
  ),
  provider_route_data jsonb not null check (jsonb_typeof(provider_route_data) = 'object'),
  created_by uuid not null references auth.users(id) on delete restrict,
  created_at timestamptz not null default timezone('utc', now()),
  unique (id, company_id),
  unique (company_id, load_id, revision_number),
  foreign key (load_id, company_id)
    references public.loads (id, company_id) on delete restrict,
  foreign key (previous_revision_id, company_id)
    references public.route_estimate_revisions (id, company_id) on delete restrict,
  foreign key (quote_context_driver_id, company_id)
    references public.drivers (id, company_id) on delete restrict,
  foreign key (empty_origin_load_id, company_id)
    references public.loads (id, company_id) on delete restrict,
  foreign key (empty_origin_stop_id, company_id)
    references public.load_stops (id, company_id) on delete restrict,
  check (
    (empty_origin_kind = 'active_load_final_stop'
      and empty_origin_load_id is not null
      and empty_origin_stop_id is not null)
    or (empty_origin_kind in ('last_accepted_location', 'declared_base')
      and empty_origin_load_id is null
      and empty_origin_stop_id is null)
  )
);

create table public.route_estimate_invalidations (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete restrict,
  load_id uuid not null,
  prior_revision_id uuid not null,
  replacement_revision_id uuid not null,
  reason text not null check (
    reason in ('active_final_stop_changed', 'driver_changed', 'assignment_changed')
  ),
  invalidated_by uuid not null references auth.users(id) on delete restrict,
  invalidated_at timestamptz not null default timezone('utc', now()),
  unique (prior_revision_id),
  unique (replacement_revision_id),
  foreign key (load_id, company_id)
    references public.loads (id, company_id) on delete restrict,
  foreign key (prior_revision_id, company_id)
    references public.route_estimate_revisions (id, company_id) on delete restrict,
  foreign key (replacement_revision_id, company_id)
    references public.route_estimate_revisions (id, company_id) on delete restrict
);

create table public.route_estimate_notifications (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete restrict,
  load_id uuid not null,
  route_estimate_revision_id uuid not null,
  recipient_role public.company_role not null check (
    recipient_role in ('owner', 'admin', 'dispatcher')
  ),
  notification_type text not null check (notification_type = 'route_estimate_invalidated'),
  payload jsonb not null check (jsonb_typeof(payload) = 'object'),
  created_at timestamptz not null default timezone('utc', now()),
  read_at timestamptz,
  unique (id, company_id),
  foreign key (load_id, company_id)
    references public.loads (id, company_id) on delete restrict,
  foreign key (route_estimate_revision_id, company_id)
    references public.route_estimate_revisions (id, company_id) on delete restrict
);

create index route_estimate_revisions_company_load_revision_idx
  on public.route_estimate_revisions (company_id, load_id, revision_number desc);
create index route_estimate_revisions_company_driver_created_idx
  on public.route_estimate_revisions (company_id, quote_context_driver_id, created_at desc);
create index route_estimate_invalidations_company_load_created_idx
  on public.route_estimate_invalidations (company_id, load_id, invalidated_at desc);
create index route_estimate_notifications_company_role_created_idx
  on public.route_estimate_notifications (company_id, recipient_role, created_at desc);

comment on table public.route_estimate_revisions is
  'Dispatcher-only operational quote revisions. Driver-visible rate requires separate dispatch authorization.';
comment on column public.route_estimate_revisions.quote_usd_per_total_mile is
  'Exact numeric division of quoted USD by estimated total miles; UI rounding is presentation-only.';

create function public.prevent_route_estimate_revision_mutation()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  raise exception using errcode = '42501', message = 'route estimate revisions are immutable';
end;
$$;

create trigger route_estimate_revisions_immutable
before update or delete on public.route_estimate_revisions
for each row
execute function public.prevent_route_estimate_revision_mutation();

create function public.persist_route_estimate_revision(
  target_company_id uuid,
  target_load_id uuid,
  quote_context_driver_id uuid,
  calculated_empty_miles numeric,
  calculated_loaded_miles numeric,
  quoted_amount_usd numeric,
  provider_name text,
  provider_route_data jsonb,
  empty_origin_kind text,
  empty_origin_stop_id uuid default null,
  invalidation_reason text default 'initial'
)
returns public.route_estimate_revisions
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor_id uuid := (select auth.uid());
  target_load public.loads%rowtype;
  active_load public.loads%rowtype;
  active_final_stop public.load_stops%rowtype;
  previous_revision public.route_estimate_revisions%rowtype;
  created_revision public.route_estimate_revisions%rowtype;
  active_load_count integer := 0;
begin
  if actor_id is null or not public.has_active_company_role(
    target_company_id,
    array['owner', 'admin', 'dispatcher']::public.company_role[]
  ) then
    raise exception using
      errcode = '42501',
      message = 'only an authorized dispatcher may manage route estimates';
  end if;

  select * into target_load
  from public.loads
  where id = target_load_id and company_id = target_company_id
  for update;
  if not found then
    raise exception using
      errcode = '42501',
      message = 'only an authorized dispatcher may manage route estimates';
  end if;

  if quote_context_driver_id is not null and not exists (
    select 1 from public.drivers
    where id = quote_context_driver_id and company_id = target_company_id
  ) then
    raise exception using errcode = '22023', message = 'a valid route driver context is required';
  end if;
  if target_load.assigned_driver_id is not null
    and target_load.assigned_driver_id is distinct from quote_context_driver_id then
    raise exception using errcode = '22023', message = 'the assigned driver must match the route estimate context';
  end if;
  if provider_name is null
    or provider_name <> lower(btrim(provider_name))
    or char_length(provider_name) not between 1 and 80
    or provider_route_data is null
    or jsonb_typeof(provider_route_data) <> 'object' then
    raise exception using errcode = '22023', message = 'valid routing provider data is required';
  end if;
  if calculated_empty_miles is null
    or calculated_empty_miles < 0
    or calculated_empty_miles <> trunc(calculated_empty_miles, 3)
    or calculated_loaded_miles is null
    or calculated_loaded_miles <= 0
    or calculated_loaded_miles <> trunc(calculated_loaded_miles, 3)
    or quoted_amount_usd is null
    or quoted_amount_usd <= 0
    or quoted_amount_usd <> trunc(quoted_amount_usd, 2) then
    raise exception using errcode = '22023', message = 'valid decimal route and quote values are required';
  end if;
  if invalidation_reason not in (
    'initial', 'active_final_stop_changed', 'driver_changed', 'assignment_changed'
  ) then
    raise exception using errcode = '22023', message = 'a valid route estimate revision reason is required';
  end if;

  if quote_context_driver_id is not null then
    select count(*) into active_load_count
    from public.loads as load
    where load.company_id = target_company_id
      and load.assigned_driver_id = quote_context_driver_id
      and load.id <> target_load_id
      and load.operational_status in (
        'assigned', 'en_route_to_pickup', 'arrived_pickup', 'loading',
        'picked_up', 'en_route_to_delivery', 'arrived_delivery', 'unloading'
      );
  end if;
  if active_load_count > 1 then
    raise exception using errcode = '22023', message = 'only one active load may determine the empty-mile origin';
  end if;

  if active_load_count = 1 then
    select * into active_load
    from public.loads as load
    where load.company_id = target_company_id
      and load.assigned_driver_id = quote_context_driver_id
      and load.id <> target_load_id
      and load.operational_status in (
        'assigned', 'en_route_to_pickup', 'arrived_pickup', 'loading',
        'picked_up', 'en_route_to_delivery', 'arrived_delivery', 'unloading'
      )
    for update;

    select * into active_final_stop
    from public.load_stops as stop
    where stop.company_id = target_company_id and stop.load_id = active_load.id
    order by stop.sequence desc
    limit 1;
    if not found then
      raise exception using errcode = '22023', message = 'the active load requires a final planned stop';
    end if;
    if empty_origin_kind <> 'active_load_final_stop'
      or empty_origin_stop_id is distinct from active_final_stop.id then
      raise exception using
        errcode = '22023',
        message = 'the active load final stop must be the empty-mile origin';
    end if;
  elsif empty_origin_kind not in ('last_accepted_location', 'declared_base')
    or empty_origin_stop_id is not null then
    raise exception using errcode = '22023', message = 'a valid fallback empty-mile origin is required';
  end if;

  select * into previous_revision
  from public.route_estimate_revisions as revision
  where revision.company_id = target_company_id and revision.load_id = target_load_id
  order by revision.revision_number desc
  limit 1
  for update;

  if found and invalidation_reason = 'initial' then
    raise exception using errcode = '22023', message = 'a replacement route estimate requires an invalidation reason';
  end if;
  if not found and invalidation_reason <> 'initial' then
    raise exception using errcode = '22023', message = 'the first route estimate must use the initial reason';
  end if;

  insert into public.route_estimate_revisions (
    company_id, load_id, revision_number, previous_revision_id,
    quote_context_driver_id, empty_origin_kind, empty_origin_load_id,
    empty_origin_stop_id, empty_miles, loaded_miles, quote_usd,
    provider_name, provider_route_data, created_by
  ) values (
    target_company_id,
    target_load_id,
    coalesce(previous_revision.revision_number, 0) + 1,
    previous_revision.id,
    quote_context_driver_id,
    empty_origin_kind,
    case when active_load_count = 1 then active_load.id else null end,
    empty_origin_stop_id,
    calculated_empty_miles,
    calculated_loaded_miles,
    quoted_amount_usd,
    provider_name,
    provider_route_data,
    actor_id
  ) returning * into created_revision;

  if previous_revision.id is not null then
    insert into public.route_estimate_invalidations (
      company_id, load_id, prior_revision_id, replacement_revision_id, reason, invalidated_by
    ) values (
      target_company_id, target_load_id, previous_revision.id, created_revision.id,
      invalidation_reason, actor_id
    );

    insert into public.route_estimate_notifications (
      company_id, load_id, route_estimate_revision_id, recipient_role,
      notification_type, payload
    ) values (
      target_company_id, target_load_id, created_revision.id, 'dispatcher',
      'route_estimate_invalidated',
      jsonb_build_object(
        'loadId', target_load_id,
        'revisionNumber', created_revision.revision_number,
        'reason', invalidation_reason
      )
    );
  end if;

  insert into public.audit_events (
    company_id, actor_id, action, before_data, after_data, entity_type, entity_id
  ) values (
    target_company_id,
    actor_id,
    case when previous_revision.id is null then 'route_estimate.created' else 'route_estimate.invalidated' end,
    case when previous_revision.id is null then null else jsonb_build_object(
      'revisionNumber', previous_revision.revision_number,
      'emptyMiles', previous_revision.empty_miles,
      'loadedMiles', previous_revision.loaded_miles,
      'totalMiles', previous_revision.total_miles,
      'quoteUsd', previous_revision.quote_usd
    ) end,
    jsonb_build_object(
      'revisionNumber', created_revision.revision_number,
      'emptyMiles', created_revision.empty_miles,
      'loadedMiles', created_revision.loaded_miles,
      'totalMiles', created_revision.total_miles,
      'quoteUsd', created_revision.quote_usd,
      'quoteUsdPerTotalMile', created_revision.quote_usd_per_total_mile,
      'invalidationReason', invalidation_reason
    ),
    'load',
    target_load_id
  );

  return created_revision;
end;
$$;

alter table public.route_estimate_revisions enable row level security;
alter table public.route_estimate_revisions force row level security;
alter table public.route_estimate_invalidations enable row level security;
alter table public.route_estimate_invalidations force row level security;
alter table public.route_estimate_notifications enable row level security;
alter table public.route_estimate_notifications force row level security;

revoke all on table public.route_estimate_revisions,
  public.route_estimate_invalidations, public.route_estimate_notifications from public;
grant select on table public.route_estimate_revisions,
  public.route_estimate_invalidations, public.route_estimate_notifications to authenticated;
revoke insert, update, delete, truncate, references, trigger on table public.route_estimate_revisions,
  public.route_estimate_invalidations, public.route_estimate_notifications from authenticated;

create policy route_estimate_revisions_select_dispatch_management
  on public.route_estimate_revisions for select to authenticated
  using (public.has_active_company_role(
    company_id, array['owner', 'admin', 'dispatcher']::public.company_role[]
  ));
create policy route_estimate_invalidations_select_dispatch_management
  on public.route_estimate_invalidations for select to authenticated
  using (public.has_active_company_role(
    company_id, array['owner', 'admin', 'dispatcher']::public.company_role[]
  ));
create policy route_estimate_notifications_select_dispatch_management
  on public.route_estimate_notifications for select to authenticated
  using (public.has_active_company_role(
    company_id, array['owner', 'admin', 'dispatcher']::public.company_role[]
  ));

revoke all on function public.prevent_route_estimate_revision_mutation() from public, anon, authenticated;
revoke all on function public.persist_route_estimate_revision(
  uuid, uuid, uuid, numeric, numeric, numeric, text, jsonb, text, uuid, text
) from public, anon;
grant execute on function public.persist_route_estimate_revision(
  uuid, uuid, uuid, numeric, numeric, numeric, text, jsonb, text, uuid, text
) to authenticated;
