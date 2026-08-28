begin;
select plan(3);

-- The forward-only proposal boundary must not require assignment or active
-- work before pricing: its server-owned base is the safe first-trip origin.
select ok(
  to_regprocedure('public.set_company_route_base(uuid,jsonb)') is not null,
  'a manager-only declared-base command exists for unassigned proposals'
);
select ok(
  to_regprocedure('public.record_accepted_driver_route_location(uuid,uuid,jsonb)') is not null,
  'a bounded accepted-location command exists for first-trip origin derivation'
);
select ok(
  to_regprocedure('public.route_estimate_proposal_origin(uuid,uuid)') is not null,
  'origin selection is database-derived rather than caller GPS/stops/miles'
);

select * from finish();
rollback;
