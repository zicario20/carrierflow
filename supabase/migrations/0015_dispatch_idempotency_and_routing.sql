-- Forward-only closure of proposal, assignment and cancellation intents.
-- Browser retries carry UUIDs; all duplicate suppression remains in PostgreSQL.

create table public.load_proposal_receipts (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete restrict,
  intent_key uuid not null,
  load_id uuid not null,
  request_fingerprint text not null check (char_length(request_fingerprint) = 32),
  quote_usd numeric(12,2) not null check (quote_usd > 0),
  actor_id uuid not null references auth.users(id) on delete restrict,
  created_at timestamptz not null default now(),
  unique (id, company_id),
  unique (company_id, intent_key),
  unique (load_id, company_id),
  foreign key (load_id, company_id) references public.loads(id, company_id) on delete restrict
);

create table public.load_dispatch_action_receipts (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete restrict,
  intent_key uuid not null,
  operation text not null check (operation = 'cancel'),
  load_id uuid not null,
  actor_id uuid not null references auth.users(id) on delete restrict,
  created_at timestamptz not null default now(),
  unique (id, company_id),
  unique (company_id, operation, intent_key),
  foreign key (load_id, company_id) references public.loads(id, company_id) on delete restrict
);

alter table public.load_proposal_receipts enable row level security;
alter table public.load_proposal_receipts force row level security;
alter table public.load_dispatch_action_receipts enable row level security;
alter table public.load_dispatch_action_receipts force row level security;
revoke all on table public.load_proposal_receipts, public.load_dispatch_action_receipts from public, anon, authenticated;
grant select on table public.load_proposal_receipts, public.load_dispatch_action_receipts to authenticated;
create policy load_proposal_receipts_select_management on public.load_proposal_receipts for select to authenticated
  using (public.has_active_company_role(company_id, array['owner', 'admin', 'dispatcher']::public.company_role[]));
create policy load_dispatch_action_receipts_select_management on public.load_dispatch_action_receipts for select to authenticated
  using (public.has_active_company_role(company_id, array['owner', 'admin', 'dispatcher']::public.company_role[]));

create function public.create_load_proposal(
  target_company_id uuid,
  proposal_intent_key uuid,
  proposal_load_number text,
  pickup_stop jsonb,
  delivery_stop jsonb,
  proposal_quote_usd numeric
)
returns public.loads
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor_id uuid := (select auth.uid());
  existing_receipt public.load_proposal_receipts%rowtype;
  created_load public.loads%rowtype;
  normalized_load_number text := upper(btrim(proposal_load_number));
  pickup_country text := upper(btrim(pickup_stop ->> 'country'));
  delivery_country text := upper(btrim(delivery_stop ->> 'country'));
  pickup_timezone text := btrim(pickup_stop ->> 'timezone');
  delivery_timezone text := btrim(delivery_stop ->> 'timezone');
  request_fingerprint text;
begin
  if actor_id is null or not public.has_active_company_role(target_company_id, array['owner', 'admin', 'dispatcher']::public.company_role[]) then
    raise exception using errcode = '42501', message = 'only an authorized manager may create a load proposal';
  end if;
  if proposal_intent_key is null or normalized_load_number is null or char_length(normalized_load_number) not between 1 and 80
    or proposal_quote_usd is null or proposal_quote_usd <= 0 or proposal_quote_usd <> trunc(proposal_quote_usd, 2)
    or jsonb_typeof(pickup_stop) <> 'object' or jsonb_typeof(delivery_stop) <> 'object'
    or char_length(coalesce(btrim(pickup_stop ->> 'address'), '')) not between 1 and 400
    or char_length(coalesce(btrim(delivery_stop ->> 'address'), '')) not between 1 and 400
    or pickup_country not in ('US', 'CA') or delivery_country not in ('US', 'CA')
    or pickup_timezone is null or delivery_timezone is null then
    raise exception using errcode = '22023', message = 'a valid proposal intent, quote, load number, pickup and delivery are required';
  end if;
  request_fingerprint := pg_catalog.md5(normalized_load_number || '|' || pickup_stop::text || '|' || delivery_stop::text || '|' || proposal_quote_usd::text);
  perform pg_advisory_xact_lock(pg_catalog.hashtextextended(target_company_id::text || ':proposal:' || proposal_intent_key::text, 0));
  select * into existing_receipt from public.load_proposal_receipts
  where company_id = target_company_id and intent_key = proposal_intent_key for update;
  if found then
    if existing_receipt.request_fingerprint <> request_fingerprint then
      raise exception using errcode = '22023', message = 'proposal intent key cannot be reused with different data';
    end if;
    select * into created_load from public.loads where company_id = target_company_id and id = existing_receipt.load_id;
    return created_load;
  end if;
  insert into public.loads (company_id, load_number, created_by) values (target_company_id, normalized_load_number, actor_id) returning * into created_load;
  insert into public.load_stops (company_id, load_id, sequence, stop_type, stop_data, country_code, timezone_name) values
    (target_company_id, created_load.id, 1, 'pickup', pickup_stop, pickup_country, pickup_timezone),
    (target_company_id, created_load.id, 2, 'delivery', delivery_stop, delivery_country, delivery_timezone);
  insert into public.load_proposal_receipts (company_id, intent_key, load_id, request_fingerprint, quote_usd, actor_id)
    values (target_company_id, proposal_intent_key, created_load.id, request_fingerprint, proposal_quote_usd, actor_id);
  insert into public.audit_events (company_id, actor_id, action, before_data, after_data, entity_type, entity_id) values
    (target_company_id, actor_id, 'load.proposal_created', '{}'::jsonb,
     jsonb_build_object('loadNumber', created_load.load_number, 'operationalStatus', 'draft', 'quoteUsd', proposal_quote_usd), 'load', created_load.id);
  return created_load;
end;
$$;

-- The prior function remains only as a safe compatibility wrapper for older
-- server tests and integrations: its deterministic key makes repeats idempotent.
create or replace function public.create_pilot_load(target_company_id uuid, pilot_load_number text, pickup_stop jsonb, delivery_stop jsonb)
returns public.loads
language plpgsql security definer set search_path = ''
as $$
declare legacy_key uuid;
begin
  legacy_key := (
    substr(pg_catalog.md5(target_company_id::text || '|legacy-proposal|' || upper(btrim(pilot_load_number)) || '|' || pickup_stop::text || '|' || delivery_stop::text), 1, 8) || '-' ||
    substr(pg_catalog.md5(target_company_id::text || '|legacy-proposal|' || upper(btrim(pilot_load_number)) || '|' || pickup_stop::text || '|' || delivery_stop::text), 9, 4) || '-' ||
    substr(pg_catalog.md5(target_company_id::text || '|legacy-proposal|' || upper(btrim(pilot_load_number)) || '|' || pickup_stop::text || '|' || delivery_stop::text), 13, 4) || '-' ||
    substr(pg_catalog.md5(target_company_id::text || '|legacy-proposal|' || upper(btrim(pilot_load_number)) || '|' || pickup_stop::text || '|' || delivery_stop::text), 17, 4) || '-' ||
    substr(pg_catalog.md5(target_company_id::text || '|legacy-proposal|' || upper(btrim(pilot_load_number)) || '|' || pickup_stop::text || '|' || delivery_stop::text), 21, 12)
  )::uuid;
  return public.create_load_proposal(target_company_id, legacy_key, pilot_load_number, pickup_stop, delivery_stop, 1.00);
end;
$$;

drop function public.assign_load_resources(uuid, uuid, uuid, uuid);

create or replace function public.assign_load_resources(target_company_id uuid, target_load_id uuid, target_driver_id uuid, target_vehicle_id uuid, idempotency_key uuid)
returns public.loads
language plpgsql security definer set search_path = ''
as $$
declare
  actor_id uuid := (select auth.uid());
  existing_load public.loads%rowtype;
  updated_load public.loads%rowtype;
  prior_event public.load_assignment_events%rowtype;
  assignment_event public.load_assignment_events%rowtype;
  proposal_receipt public.load_proposal_receipts%rowtype;
  action_value text;
  prior_status text;
begin
  if actor_id is null or not public.has_active_company_role(target_company_id, array['owner', 'admin', 'dispatcher']::public.company_role[]) then
    raise exception using errcode = '42501', message = 'only an authorized manager may assign a load';
  end if;
  if target_company_id is null or target_load_id is null or target_driver_id is null or target_vehicle_id is null or idempotency_key is null then
    raise exception using errcode = '22023', message = 'load, driver, vehicle, and idempotency key are required';
  end if;
  perform pg_advisory_xact_lock(pg_catalog.hashtextextended(target_company_id::text || ':assignment:' || idempotency_key::text, 0));
  select * into prior_event from public.load_assignment_events where company_id = target_company_id and load_assignment_events.idempotency_key = assign_load_resources.idempotency_key for update;
  if found then
    if prior_event.load_id <> target_load_id or prior_event.assigned_driver_id <> target_driver_id or prior_event.assigned_vehicle_id <> target_vehicle_id then
      raise exception using errcode = '22023', message = 'idempotency key cannot be reused for another assignment';
    end if;
    select * into updated_load from public.loads where company_id = target_company_id and id = target_load_id;
    return updated_load;
  end if;
  select * into existing_load from public.loads where company_id = target_company_id and id = target_load_id for update;
  if not found then raise exception using errcode = '42501', message = 'only an authorized company actor may operate this load'; end if;
  if existing_load.operational_status in ('delivered', 'closed', 'cancelled') then raise exception using errcode = '22023', message = 'a completed or cancelled load cannot be assigned'; end if;
  if not public.has_active_load_assignment(target_company_id, target_driver_id, target_vehicle_id) then raise exception using errcode = '22023', message = 'an active driver and paired active vehicle are required'; end if;
  if existing_load.assigned_driver_id = target_driver_id and existing_load.assigned_vehicle_id = target_vehicle_id and existing_load.operational_status <> 'draft' then raise exception using errcode = '22023', message = 'the load is already assigned to this active driver and vehicle'; end if;
  prior_status := existing_load.operational_status;
  action_value := case when existing_load.assigned_driver_id is null then 'assigned' else 'reassigned' end;
  update public.loads set assigned_driver_id = target_driver_id, assigned_vehicle_id = target_vehicle_id,
    operational_status = case when operational_status in ('draft', 'scheduled') then 'assigned' else operational_status end,
    updated_at = timezone('utc', now()) where company_id = target_company_id and id = target_load_id returning * into updated_load;
  if prior_status = 'draft' then
    insert into public.load_state_events (company_id, load_id, from_status, to_status, actor_id) values
      (target_company_id, target_load_id, 'draft', 'scheduled', actor_id), (target_company_id, target_load_id, 'scheduled', 'assigned', actor_id);
  elsif prior_status = 'scheduled' then
    insert into public.load_state_events (company_id, load_id, from_status, to_status, actor_id) values (target_company_id, target_load_id, 'scheduled', 'assigned', actor_id);
  end if;
  insert into public.load_assignment_events (company_id, load_id, idempotency_key, action, previous_driver_id, previous_vehicle_id, assigned_driver_id, assigned_vehicle_id, actor_id)
    values (target_company_id, target_load_id, idempotency_key, action_value, existing_load.assigned_driver_id, existing_load.assigned_vehicle_id, target_driver_id, target_vehicle_id, actor_id) returning * into assignment_event;
  insert into public.audit_events (company_id, actor_id, action, before_data, after_data, entity_type, entity_id) values
    (target_company_id, actor_id, case when action_value = 'assigned' then 'load.assigned' else 'load.reassigned' end,
     jsonb_build_object('operationalStatus', prior_status, 'driverId', existing_load.assigned_driver_id, 'vehicleId', existing_load.assigned_vehicle_id),
     jsonb_build_object('operationalStatus', updated_load.operational_status, 'driverId', target_driver_id, 'vehicleId', target_vehicle_id, 'assignmentEventId', assignment_event.id), 'load', target_load_id);
  insert into public.load_dispatch_notifications (company_id, load_id, assignment_event_id, recipient_driver_id, notification_type, payload)
    values (target_company_id, target_load_id, assignment_event.id, target_driver_id, case when action_value = 'assigned' then 'load_assigned' else 'load_reassigned' end, jsonb_build_object('loadId', target_load_id, 'assignmentEventId', assignment_event.id));
  if action_value = 'reassigned' and existing_load.assigned_driver_id is distinct from target_driver_id then
    insert into public.load_dispatch_notifications (company_id, load_id, assignment_event_id, recipient_driver_id, notification_type, payload)
      values (target_company_id, target_load_id, assignment_event.id, existing_load.assigned_driver_id, 'load_reassigned', jsonb_build_object('loadId', target_load_id, 'assignmentEventId', assignment_event.id));
  end if;
  if prior_status in ('draft', 'scheduled') then
    select * into proposal_receipt from public.load_proposal_receipts where company_id = target_company_id and load_id = target_load_id;
    if found then
      begin
        perform public.request_initial_route_estimate(target_company_id, target_load_id, proposal_receipt.quote_usd, assignment_event.id);
      exception when sqlstate '22023' then
        -- Assignment remains successful. Pending routing waits for a validated
        -- base/location/coordinates rather than fabricating a route.
        null;
      end;
    end if;
  end if;
  return updated_load;
end;
$$;

create function public.cancel_load_idempotent(target_company_id uuid, target_load_id uuid, idempotency_key uuid)
returns public.loads
language plpgsql security definer set search_path = ''
as $$
declare actor_id uuid := (select auth.uid()); receipt public.load_dispatch_action_receipts%rowtype; updated_load public.loads%rowtype;
begin
  if actor_id is null or not public.has_active_company_role(target_company_id, array['owner', 'admin', 'dispatcher']::public.company_role[]) then raise exception using errcode = '42501', message = 'only an authorized manager may cancel a load'; end if;
  if target_company_id is null or target_load_id is null or idempotency_key is null then raise exception using errcode = '22023', message = 'load and idempotency key are required'; end if;
  perform pg_advisory_xact_lock(pg_catalog.hashtextextended(target_company_id::text || ':cancel:' || idempotency_key::text, 0));
  select * into receipt from public.load_dispatch_action_receipts where company_id = target_company_id and operation = 'cancel' and intent_key = idempotency_key for update;
  if found then
    if receipt.load_id <> target_load_id then raise exception using errcode = '22023', message = 'idempotency key cannot be reused for another cancellation'; end if;
    select * into updated_load from public.loads where company_id = target_company_id and id = target_load_id; return updated_load;
  end if;
  select * into updated_load from public.advance_load_state(target_company_id, target_load_id, 'cancelled');
  insert into public.load_dispatch_action_receipts(company_id, intent_key, operation, load_id, actor_id) values(target_company_id, idempotency_key, 'cancel', target_load_id, actor_id);
  return updated_load;
end;
$$;

create function public.get_dispatch_route_estimate_status(target_company_id uuid, target_load_id uuid)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare head public.route_estimate_heads%rowtype; revision public.route_estimate_revisions%rowtype; job public.route_estimate_recompute_jobs%rowtype;
begin
  if not public.has_active_company_role(target_company_id, array['owner', 'admin', 'dispatcher']::public.company_role[]) then raise exception using errcode = '42501', message = 'only an authorized manager may view route estimate status'; end if;
  select * into head from public.route_estimate_heads where company_id = target_company_id and load_id = target_load_id;
  if found and head.state = 'current' and head.current_revision_id is not null then
    select * into revision from public.route_estimate_revisions where company_id = target_company_id and id = head.current_revision_id;
    return jsonb_build_object('status', 'ready', 'revision', public.route_estimate_revision_response(revision));
  end if;
  select * into job from public.route_estimate_recompute_jobs where company_id = target_company_id and load_id = target_load_id and status in ('pending', 'claimed') order by created_at desc, id desc limit 1;
  if found then return jsonb_build_object('status', 'pending', 'jobId', job.id, 'idempotencyKey', job.idempotency_key); end if;
  return jsonb_build_object('status', 'pending');
end;
$$;

revoke all on function public.create_load_proposal(uuid, uuid, text, jsonb, jsonb, numeric), public.cancel_load_idempotent(uuid, uuid, uuid), public.get_dispatch_route_estimate_status(uuid, uuid) from public, anon;
grant execute on function public.create_load_proposal(uuid, uuid, text, jsonb, jsonb, numeric), public.cancel_load_idempotent(uuid, uuid, uuid), public.get_dispatch_route_estimate_status(uuid, uuid) to authenticated;
revoke all on function public.assign_load_resources(uuid, uuid, uuid, uuid, uuid) from public, anon;
grant execute on function public.assign_load_resources(uuid, uuid, uuid, uuid, uuid) to authenticated;
