-- Restore the opaque evidence-receipt boundary after 0020 moved driver
-- mutations to a private core. The normalizer is private too: no client GUC
-- or publicly callable helper can reach the authoritative evidence function.

create or replace function driver_sync_private.normalize_and_record_current_driver_load_evidence(
  evidence_type_value text,
  evidence_content jsonb
)
returns public.load_evidence
language plpgsql
security definer
set search_path = ''
as $$
declare
  selected_load public.loads%rowtype;
  receipt_key text;
  normalized_evidence_content jsonb := evidence_content;
begin
  selected_load := public.current_own_driver_load();
  if evidence_type_value in ('photo', 'bol', 'pod') then
    receipt_key := evidence_content ->> 'receiptKey';
    if not coalesce(
      jsonb_typeof(evidence_content) = 'object'
      and jsonb_typeof(evidence_content -> 'receiptKey') = 'string'
      and receipt_key ~ '^[a-z0-9][a-z0-9_-]{0,95}$',
      false
    ) then
      raise exception using errcode = '22023', message = 'a valid private evidence receipt is required';
    end if;
    normalized_evidence_content := jsonb_build_object(
      'storagePath', format(
        'private/%s/loads/%s/evidence/%s',
        selected_load.company_id,
        selected_load.id,
        receipt_key
      )
    );
  end if;
  return driver_sync_private.record_current_driver_load_evidence(
    evidence_type_value,
    normalized_evidence_content
  );
end;
$$;

revoke all on function driver_sync_private.normalize_and_record_current_driver_load_evidence(text, jsonb)
  from public, anon, authenticated;

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
  created_evidence := driver_sync_private.normalize_and_record_current_driver_load_evidence(
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

revoke all on function public.record_own_driver_load_evidence_idempotent(uuid, text, jsonb)
  from public, anon;
grant execute on function public.record_own_driver_load_evidence_idempotent(uuid, text, jsonb)
  to authenticated;
