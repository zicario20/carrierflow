begin;

-- 0028 replaces the historical GUC/PGP runtime path. Keep this fixture scoped
-- to the durable 0027 table and private-worker contract; 0028 tests the new
-- envelope, registration and lifecycle behavior in full.
select plan(9);

select has_table('public', 'driver_push_devices', 'push delivery keeps registered destinations in a dedicated private table');
select has_table('public', 'driver_push_deliveries', 'push delivery claims are separate from the minimal refresh-event outbox');
select ok((select relrowsecurity and relforcerowsecurity from pg_class where oid = 'public.driver_push_devices'::regclass), 'registered device destinations use forced RLS');
select ok((select relrowsecurity and relforcerowsecurity from pg_class where oid = 'public.driver_push_deliveries'::regclass), 'private delivery claims use forced RLS');
select ok(not has_table_privilege('anon', 'public.driver_push_devices', 'select,insert,update,delete'), 'anon cannot access registered device destinations directly');
select ok(not has_table_privilege('authenticated', 'public.driver_push_deliveries', 'select,insert,update,delete'), 'authenticated clients cannot access delivery claims directly');
select ok(to_regprocedure('public.register_own_driver_push_device(text,text)') is not null, 'the immutable legacy registration function remains present only for migration history');
select ok(not has_function_privilege('authenticated', 'public.register_own_driver_push_device(text,text)', 'execute'), 'the authenticated legacy registration function is revoked by current runtime hardening');
select ok(
  has_function_privilege('service_role', 'public.claim_pending_driver_push_delivery(uuid)', 'execute')
  and not has_function_privilege('authenticated', 'public.claim_pending_driver_push_delivery(uuid)', 'execute'),
  'only the private worker can claim encrypted delivery material'
);

select * from finish();
rollback;
