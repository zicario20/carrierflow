-- Mandatory dispatch assignment is a manager-only, tenant-scoped transaction.
-- The idempotency key is persisted with the immutable event so network retries
-- cannot create duplicate assignment history or driver notifications.

create table public.load_assignment_events (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete restrict,
  load_id uuid not null,
  idempotency_key uuid not null,
  action text not null check (action in ('assigned', 'reassigned')),
  previous_driver_id uuid,
  previous_vehicle_id uuid,
  assigned_driver_id uuid not null,
  assigned_vehicle_id uuid not null,
  actor_id uuid not null references auth.users(id) on delete restrict,
  created_at timestamptz not null default now(),
  unique (id, company_id),
  unique (company_id, idempotency_key),
  foreign key (load_id, company_id) references public.loads(id, company_id) on delete restrict,
  foreign key (previous_driver_id, company_id) references public.drivers(id, company_id) on delete restrict,
  foreign key (previous_vehicle_id, company_id) references public.vehicles(id, company_id) on delete restrict,
  foreign key (assigned_driver_id, company_id) references public.drivers(id, company_id) on delete restrict,
  foreign key (assigned_vehicle_id, company_id) references public.vehicles(id, company_id) on delete restrict
);

create table public.load_dispatch_notifications (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete restrict,
  load_id uuid not null,
  assignment_event_id uuid not null,
  recipient_driver_id uuid not null,
  notification_type text not null check (notification_type in ('load_assigned', 'load_reassigned')),
  payload jsonb not null check (jsonb_typeof(payload) = 'object'),
  created_at timestamptz not null default now(),
  delivered_at timestamptz,
  unique (company_id, assignment_event_id, recipient_driver_id),
  foreign key (load_id, company_id) references public.loads(id, company_id) on delete restrict,
  foreign key (assignment_event_id, company_id) references public.load_assignment_events(id, company_id) on delete restrict,
  foreign key (recipient_driver_id, company_id) references public.drivers(id, company_id) on delete restrict
);

create index load_assignment_events_company_load_created_idx
  on public.load_assignment_events (company_id, load_id, created_at desc);
create index load_dispatch_notifications_company_driver_created_idx
  on public.load_dispatch_notifications (company_id, recipient_driver_id, created_at desc);

alter table public.load_assignment_events enable row level security;
alter table public.load_assignment_events force row level security;
alter table public.load_dispatch_notifications enable row level security;
alter table public.load_dispatch_notifications force row level security;

revoke all on table public.load_assignment_events, public.load_dispatch_notifications from public, anon, authenticated;
grant select on table public.load_assignment_events, public.load_dispatch_notifications to authenticated;
revoke insert, update, delete, truncate, references, trigger on table public.load_assignment_events, public.load_dispatch_notifications from authenticated;

create policy load_assignment_events_select_dispatch_management
  on public.load_assignment_events for select to authenticated
  using (public.has_active_company_role(company_id, array['owner', 'admin', 'dispatcher']::public.company_role[]));
create policy load_dispatch_notifications_select_dispatch_management
  on public.load_dispatch_notifications for select to authenticated
  using (public.has_active_company_role(company_id, array['owner', 'admin', 'dispatcher']::public.company_role[]));

create function public.assign_load_resources(
  target_company_id uuid,
  target_load_id uuid,
  target_driver_id uuid,
  target_vehicle_id uuid,
  idempotency_key uuid
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
  prior_event public.load_assignment_events%rowtype;
  assignment_event public.load_assignment_events%rowtype;
  action_value text;
  prior_status text;
begin
  if actor_id is null or not public.has_active_company_role(
    target_company_id,
    array['owner', 'admin', 'dispatcher']::public.company_role[]
  ) then
    raise exception using errcode = '42501', message = 'only an authorized manager may assign a load';
  end if;
  if target_company_id is null or target_load_id is null or target_driver_id is null
    or target_vehicle_id is null or idempotency_key is null then
    raise exception using errcode = '22023', message = 'load, driver, vehicle, and idempotency key are required';
  end if;

  -- Serializing first on the durable retry key avoids duplicate side effects
  -- when a client retries after a completed request but before receiving it.
  perform pg_advisory_xact_lock(hashtextextended(target_company_id::text || ':' || idempotency_key::text, 0));
  select * into prior_event from public.load_assignment_events
  where company_id = target_company_id and load_assignment_events.idempotency_key = assign_load_resources.idempotency_key
  for update;
  if found then
    if prior_event.load_id <> target_load_id
      or prior_event.assigned_driver_id <> target_driver_id
      or prior_event.assigned_vehicle_id <> target_vehicle_id then
      raise exception using errcode = '22023', message = 'idempotency key cannot be reused for another assignment';
    end if;
    select * into updated_load from public.loads
    where company_id = target_company_id and id = target_load_id;
    return updated_load;
  end if;

  select * into existing_load from public.loads
  where company_id = target_company_id and id = target_load_id
  for update;
  if not found then
    raise exception using errcode = '42501', message = 'only an authorized company actor may operate this load';
  end if;
  if existing_load.operational_status in ('delivered', 'closed', 'cancelled') then
    raise exception using errcode = '22023', message = 'a completed or cancelled load cannot be assigned';
  end if;
  if not public.has_active_load_assignment(target_company_id, target_driver_id, target_vehicle_id) then
    raise exception using errcode = '22023', message = 'an active driver and paired active vehicle are required';
  end if;
  if existing_load.assigned_driver_id = target_driver_id
    and existing_load.assigned_vehicle_id = target_vehicle_id
    and existing_load.operational_status <> 'draft' then
    raise exception using errcode = '22023', message = 'the load is already assigned to this active driver and vehicle';
  end if;

  prior_status := existing_load.operational_status;
  action_value := case when existing_load.assigned_driver_id is null then 'assigned' else 'reassigned' end;
  update public.loads
  set assigned_driver_id = target_driver_id,
      assigned_vehicle_id = target_vehicle_id,
      operational_status = case when operational_status in ('draft', 'scheduled') then 'assigned' else operational_status end,
      updated_at = timezone('utc', now())
  where company_id = target_company_id and id = target_load_id
  returning * into updated_load;

  if prior_status = 'draft' then
    insert into public.load_state_events (company_id, load_id, from_status, to_status, actor_id)
    values
      (target_company_id, target_load_id, 'draft', 'scheduled', actor_id),
      (target_company_id, target_load_id, 'scheduled', 'assigned', actor_id);
  elsif prior_status = 'scheduled' then
    insert into public.load_state_events (company_id, load_id, from_status, to_status, actor_id)
    values (target_company_id, target_load_id, 'scheduled', 'assigned', actor_id);
  end if;

  insert into public.load_assignment_events (
    company_id, load_id, idempotency_key, action, previous_driver_id, previous_vehicle_id,
    assigned_driver_id, assigned_vehicle_id, actor_id
  ) values (
    target_company_id, target_load_id, idempotency_key, action_value,
    existing_load.assigned_driver_id, existing_load.assigned_vehicle_id,
    target_driver_id, target_vehicle_id, actor_id
  ) returning * into assignment_event;

  insert into public.audit_events (company_id, actor_id, action, before_data, after_data, entity_type, entity_id)
  values (
    target_company_id, actor_id,
    case when action_value = 'assigned' then 'load.assigned' else 'load.reassigned' end,
    jsonb_build_object('operationalStatus', prior_status, 'driverId', existing_load.assigned_driver_id, 'vehicleId', existing_load.assigned_vehicle_id),
    jsonb_build_object('operationalStatus', updated_load.operational_status, 'driverId', target_driver_id, 'vehicleId', target_vehicle_id, 'assignmentEventId', assignment_event.id),
    'load', target_load_id
  );

  insert into public.load_dispatch_notifications (
    company_id, load_id, assignment_event_id, recipient_driver_id, notification_type, payload
  ) values (
    target_company_id, target_load_id, assignment_event.id, target_driver_id,
    case when action_value = 'assigned' then 'load_assigned' else 'load_reassigned' end,
    jsonb_build_object('loadId', target_load_id, 'assignmentEventId', assignment_event.id)
  );
  if action_value = 'reassigned' and existing_load.assigned_driver_id is distinct from target_driver_id then
    insert into public.load_dispatch_notifications (
      company_id, load_id, assignment_event_id, recipient_driver_id, notification_type, payload
    ) values (
      target_company_id, target_load_id, assignment_event.id, existing_load.assigned_driver_id,
      'load_reassigned', jsonb_build_object('loadId', target_load_id, 'assignmentEventId', assignment_event.id)
    );
  end if;
  return updated_load;
end;
$$;

revoke all on function public.assign_load_resources(uuid, uuid, uuid, uuid, uuid) from public, anon;
grant execute on function public.assign_load_resources(uuid, uuid, uuid, uuid, uuid) to authenticated;
