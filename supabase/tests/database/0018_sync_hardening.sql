begin;

select plan(5);

select ok(
  not has_function_privilege('authenticated', 'public.advance_own_driver_load_state()', 'execute'),
  'authenticated callers cannot bypass state replay receipts through the legacy route'
);
select ok(
  not has_function_privilege('authenticated', 'public.record_own_driver_load_evidence(text,jsonb)', 'execute'),
  'authenticated callers cannot bypass evidence replay receipts through the legacy route'
);
select ok(
  has_function_privilege('authenticated', 'public.advance_own_driver_load_state_idempotent(uuid)', 'execute'),
  'authenticated callers retain the idempotent state wrapper'
);
select ok(
  has_function_privilege('authenticated', 'public.record_own_driver_load_evidence_idempotent(uuid,text,jsonb)', 'execute'),
  'authenticated callers retain the idempotent evidence wrapper'
);
select ok(
  has_function_privilege('authenticated', 'public.report_own_driver_load_incident_idempotent(uuid,text,text,jsonb,jsonb)', 'execute'),
  'authenticated callers retain the idempotent incident wrapper'
);

select * from finish();
rollback;
