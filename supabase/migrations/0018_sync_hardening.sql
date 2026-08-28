-- The legacy own-driver mutation routes bypass immutable outbox receipts.
-- Keep the read APIs and idempotent wrappers available, but prevent clients
-- from invoking non-idempotent state/evidence mutations directly.

revoke all on function public.advance_own_driver_load_state()
  from public, anon, authenticated;
revoke all on function public.record_own_driver_load_evidence(text, jsonb)
  from public, anon, authenticated;

revoke all on function public.advance_own_driver_load_state_idempotent(uuid)
  from public, anon;
revoke all on function public.record_own_driver_load_evidence_idempotent(uuid, text, jsonb)
  from public, anon;
revoke all on function public.report_own_driver_load_incident_idempotent(uuid, text, text, jsonb, jsonb)
  from public, anon;
grant execute on function public.advance_own_driver_load_state_idempotent(uuid)
  to authenticated;
grant execute on function public.record_own_driver_load_evidence_idempotent(uuid, text, jsonb)
  to authenticated;
grant execute on function public.report_own_driver_load_incident_idempotent(uuid, text, text, jsonb, jsonb)
  to authenticated;
