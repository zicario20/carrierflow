-- Drivers must not bypass durable sync receipts by invoking the older scoped
-- mutation functions. Managers retain their existing direct operational API;
-- a driver reaches it only through a private transaction-local marker set by
-- the zero-scope idempotent wrappers below.

alter function public.advance_load_state(uuid, uuid, text)
  rename to advance_load_state_authorized;
alter function public.record_load_evidence(uuid, uuid, text, jsonb)
  rename to record_load_evidence_authorized;

revoke all on function public.advance_load_state_authorized(uuid, uuid, text)
  from public, anon, authenticated;
revoke all on function public.record_load_evidence_authorized(uuid, uuid, text, jsonb)
  from public, anon, authenticated;

create function public.enter_driver_sync_operation()
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  current_actor_id uuid := (select auth.uid());
begin
  if current_actor_id is null then
    raise exception using errcode = '42501', message = 'only an authorized company actor may operate this load';
  end if;
  perform pg_catalog.set_config(
    'carrierflow.driver_sync_actor',
    current_actor_id::text,
    true
  );
end;
$$;

revoke all on function public.enter_driver_sync_operation()
  from public, anon, authenticated;

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
  current_actor_id uuid := (select auth.uid());
  actor_is_manager boolean := false;
  actor_is_driver boolean := false;
begin
  actor_is_manager := public.has_active_company_role(
    target_company_id,
    array['owner', 'admin', 'dispatcher']::public.company_role[]
  );
  select exists (
    select 1
    from public.company_memberships as membership
    join public.drivers as driver
      on driver.membership_id = membership.id
      and driver.company_id = membership.company_id
    where membership.user_id = current_actor_id
      and membership.role = 'driver'::public.company_role
      and membership.status = 'active'::public.membership_status
      and driver.status = 'active'
  ) into actor_is_driver;
  if actor_is_driver
      and not coalesce(actor_is_manager, false)
      and current_setting('carrierflow.driver_sync_actor', true)
          is distinct from current_actor_id::text then
    raise exception using
      errcode = '42501',
      message = 'driver mutations must use the idempotent sync wrapper';
  end if;
  return public.advance_load_state_authorized(
    target_company_id,
    target_load_id,
    target_operational_status
  );
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
  current_actor_id uuid := (select auth.uid());
  actor_is_manager boolean := false;
  actor_is_driver boolean := false;
begin
  actor_is_manager := public.has_active_company_role(
    target_company_id,
    array['owner', 'admin', 'dispatcher']::public.company_role[]
  );
  select exists (
    select 1
    from public.company_memberships as membership
    join public.drivers as driver
      on driver.membership_id = membership.id
      and driver.company_id = membership.company_id
    where membership.user_id = current_actor_id
      and membership.role = 'driver'::public.company_role
      and membership.status = 'active'::public.membership_status
      and driver.status = 'active'
  ) into actor_is_driver;
  if actor_is_driver
      and not coalesce(actor_is_manager, false)
      and current_setting('carrierflow.driver_sync_actor', true)
          is distinct from current_actor_id::text then
    raise exception using
      errcode = '42501',
      message = 'driver mutations must use the idempotent sync wrapper';
  end if;
  return public.record_load_evidence_authorized(
    target_company_id,
    target_load_id,
    evidence_type_value,
    evidence_content
  );
end;
$$;

revoke all on function public.advance_load_state(uuid, uuid, text)
  from public, anon;
revoke all on function public.record_load_evidence(uuid, uuid, text, jsonb)
  from public, anon;
grant execute on function public.advance_load_state(uuid, uuid, text)
  to authenticated;
grant execute on function public.record_load_evidence(uuid, uuid, text, jsonb)
  to authenticated;

create or replace function public.advance_own_driver_load_state_idempotent(
  client_mutation_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  current_actor_id uuid := (select auth.uid());
  selected_load public.loads%rowtype;
  updated_load public.loads%rowtype;
  saved_receipt public.driver_sync_receipts%rowtype;
  next_status text;
  request_fingerprint text := pg_catalog.md5('advance_state');
  response_value jsonb;
begin
  if current_actor_id is null or client_mutation_id is null then
    raise exception using errcode = '22023', message = 'a valid sync mutation id is required';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(current_actor_id::text || ':driver-sync:' || client_mutation_id::text, 0)
  );
  select * into saved_receipt
  from public.driver_sync_receipts as receipt
  where receipt.actor_id = current_actor_id
    and receipt.client_mutation_id = $1
  for update;
  if found then
    if saved_receipt.operation <> 'advance_state'
        or saved_receipt.request_fingerprint <> request_fingerprint then
      raise exception using errcode = '22023', message = 'sync mutation id cannot be reused with different data';
    end if;
    return saved_receipt.response;
  end if;

  selected_load := public.current_own_driver_load();
  next_status := public.next_driver_operational_status(selected_load.operational_status);
  if next_status is null then
    raise exception using errcode = '22023', message = 'no driver transition is available';
  end if;
  perform public.enter_driver_sync_operation();
  updated_load := public.advance_load_state(
    selected_load.company_id,
    selected_load.id,
    next_status
  );
  response_value := jsonb_build_object(
    'clientMutationId', client_mutation_id,
    'operationalStatus', updated_load.operational_status
  );
  insert into public.driver_sync_receipts (
    actor_id, client_mutation_id, company_id, load_id, operation,
    request_fingerprint, response
  ) values (
    current_actor_id, client_mutation_id, selected_load.company_id,
    selected_load.id, 'advance_state', request_fingerprint, response_value
  );
  return response_value;
end;
$$;

create or replace function public.record_own_driver_load_evidence_idempotent(
  client_mutation_id uuid,
  evidence_type_value text,
  evidence_content jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  current_actor_id uuid := (select auth.uid());
  selected_load public.loads%rowtype;
  created_evidence public.load_evidence%rowtype;
  saved_receipt public.driver_sync_receipts%rowtype;
  request_fingerprint text;
  response_value jsonb;
begin
  if current_actor_id is null or client_mutation_id is null then
    raise exception using errcode = '22023', message = 'a valid sync mutation id is required';
  end if;
  request_fingerprint := pg_catalog.md5(
    'record_evidence|' || coalesce(evidence_type_value, '') || '|'
    || coalesce(evidence_content::text, 'null')
  );

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(current_actor_id::text || ':driver-sync:' || client_mutation_id::text, 0)
  );
  select * into saved_receipt
  from public.driver_sync_receipts as receipt
  where receipt.actor_id = current_actor_id
    and receipt.client_mutation_id = $1
  for update;
  if found then
    if saved_receipt.operation <> 'record_evidence'
        or saved_receipt.request_fingerprint <> request_fingerprint then
      raise exception using errcode = '22023', message = 'sync mutation id cannot be reused with different data';
    end if;
    return saved_receipt.response;
  end if;

  selected_load := public.current_own_driver_load();
  perform public.enter_driver_sync_operation();
  created_evidence := public.record_own_driver_load_evidence(
    evidence_type_value,
    evidence_content
  );
  response_value := jsonb_build_object(
    'clientMutationId', client_mutation_id,
    'evidenceId', created_evidence.id,
    'evidenceType', created_evidence.evidence_type
  );
  insert into public.driver_sync_receipts (
    actor_id, client_mutation_id, company_id, load_id, operation,
    request_fingerprint, response
  ) values (
    current_actor_id, client_mutation_id, selected_load.company_id,
    selected_load.id, 'record_evidence', request_fingerprint, response_value
  );
  return response_value;
end;
$$;

revoke all on function public.advance_own_driver_load_state_idempotent(uuid)
  from public, anon;
revoke all on function public.record_own_driver_load_evidence_idempotent(uuid, text, jsonb)
  from public, anon;
grant execute on function public.advance_own_driver_load_state_idempotent(uuid)
  to authenticated;
grant execute on function public.record_own_driver_load_evidence_idempotent(uuid, text, jsonb)
  to authenticated;
