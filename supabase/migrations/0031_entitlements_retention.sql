-- Private-pilot entitlements and privacy retention. Pilot catalogues are
-- informational only: there is deliberately no checkout, charge, invoice or
-- external billing boundary in this migration.

create schema if not exists entitlement_private;
revoke all on schema entitlement_private from public, anon, authenticated;

create type public.pilot_plan_code as enum ('starter', 'growth', 'scale');

create table public.company_pilot_entitlements (
  company_id uuid primary key references public.companies(id) on delete cascade,
  plan_code public.pilot_plan_code not null default 'starter',
  trial_started_at timestamptz not null default timezone('utc', now()),
  trial_ends_at timestamptz not null default (timezone('utc', now()) + interval '7 days'),
  created_at timestamptz not null default timezone('utc', now()),
  updated_at timestamptz not null default timezone('utc', now()),
  check (trial_ends_at = trial_started_at + interval '7 days')
);

-- A separate record proves a retention job ran without retaining route
-- geometry, coordinates, evidence content, signed links, or provider tokens.
create table public.company_privacy_retention_runs (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  actor_id uuid references auth.users(id) on delete set null,
  policy_version text not null check (policy_version = 'pilot-v1'),
  purged_current_location_count integer not null check (purged_current_location_count >= 0),
  purged_detailed_location_count integer not null check (purged_detailed_location_count >= 0),
  preserved_evidence_metadata_count integer not null check (preserved_evidence_metadata_count >= 0),
  completed_at timestamptz not null default timezone('utc', now()),
  unique (id, company_id)
);

create index company_privacy_retention_runs_company_completed_idx
  on public.company_privacy_retention_runs (company_id, completed_at desc);

alter table public.company_pilot_entitlements enable row level security;
alter table public.company_pilot_entitlements force row level security;
alter table public.company_privacy_retention_runs enable row level security;
alter table public.company_privacy_retention_runs force row level security;

-- Direct table access remains absent even for an owner. The narrow RPCs below
-- provide the only browser-facing read/run capabilities and reauthorize the
-- exact tenant in PostgreSQL.
revoke all on table public.company_pilot_entitlements, public.company_privacy_retention_runs
  from public, anon, authenticated;

create policy company_pilot_entitlements_select_owner
  on public.company_pilot_entitlements for select to authenticated
  using (public.has_active_company_role(company_id, array['owner']::public.company_role[]));
create policy company_privacy_retention_runs_select_owner
  on public.company_privacy_retention_runs for select to authenticated
  using (public.has_active_company_role(company_id, array['owner']::public.company_role[]));

create function entitlement_private.pilot_plan_terms(target_plan_code public.pilot_plan_code)
returns table (monthly_price_usd integer, driver_capacity integer)
language sql
immutable
set search_path = ''
as $$
  select terms.monthly_price_usd, terms.driver_capacity
  from (values
    ('starter'::public.pilot_plan_code, 20, 10),
    ('growth'::public.pilot_plan_code, 40, 25),
    ('scale'::public.pilot_plan_code, 60, 60)
  ) as terms(plan_code, monthly_price_usd, driver_capacity)
  where terms.plan_code = target_plan_code;
$$;

create function entitlement_private.create_default_company_pilot_entitlement()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  trial_started timestamptz := timezone('utc', now());
begin
  insert into public.company_pilot_entitlements (
    company_id, plan_code, trial_started_at, trial_ends_at
  ) values (
    new.id, 'starter', trial_started, trial_started + interval '7 days'
  ) on conflict (company_id) do nothing;
  return new;
end;
$$;

create trigger companies_create_default_pilot_entitlement
after insert on public.companies
for each row execute function entitlement_private.create_default_company_pilot_entitlement();

-- Existing tenants receive the same free trial baseline. The plan code, not a
-- caller-supplied capacity, is the source of truth for every future count.
insert into public.company_pilot_entitlements (
  company_id, plan_code, trial_started_at, trial_ends_at
)
select
  company.id,
  'starter',
  company.created_at,
  company.created_at + interval '7 days'
from public.companies as company
on conflict (company_id) do nothing;

create function entitlement_private.assert_active_driver_capacity(target_company_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  entitlement public.company_pilot_entitlements%rowtype;
  permitted_driver_capacity integer;
  active_driver_count integer;
begin
  -- Every create/reactivation of this company takes this exact row lock. The
  -- second concurrent transaction re-counts only after the first commits, so
  -- capacity cannot be oversubscribed by parallel activation attempts.
  select * into entitlement
  from public.company_pilot_entitlements
  where company_id = target_company_id
  for update;
  if not found then
    raise exception using errcode = '22023', message = 'a pilot entitlement is required before activating a driver';
  end if;

  select terms.driver_capacity into permitted_driver_capacity
  from entitlement_private.pilot_plan_terms(entitlement.plan_code) as terms;
  if permitted_driver_capacity is null then
    raise exception using errcode = '22023', message = 'a valid pilot entitlement is required before activating a driver';
  end if;

  select count(*)::integer into active_driver_count
  from public.drivers as driver
  where driver.company_id = target_company_id
    and driver.status = 'active';

  if active_driver_count >= permitted_driver_capacity then
    raise exception using errcode = '22023', message = 'the active driver capacity has been reached';
  end if;
end;
$$;

create function entitlement_private.enforce_active_driver_capacity()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.status = 'active'
    and (tg_op = 'INSERT' or old.status is distinct from 'active') then
    perform entitlement_private.assert_active_driver_capacity(new.company_id);
  end if;
  return new;
end;
$$;

-- This trigger is intentionally the forward-only activation boundary. It
-- covers existing update_driver lifecycle code, create_driver, and any future
-- trusted mutation that attempts to make a driver active.
create trigger drivers_enforce_pilot_active_capacity
before insert or update of status on public.drivers
for each row execute function entitlement_private.enforce_active_driver_capacity();

create function public.get_company_pilot_entitlement(target_company_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  entitlement public.company_pilot_entitlements%rowtype;
  terms record;
  active_driver_count integer;
begin
  if target_company_id is null or not public.has_active_company_role(
    target_company_id,
    array['owner']::public.company_role[]
  ) then
    raise exception using errcode = '42501', message = 'an active owner is required to view pilot plan settings';
  end if;

  select * into entitlement
  from public.company_pilot_entitlements
  where company_id = target_company_id;
  if not found then
    raise exception using errcode = '22023', message = 'the company pilot entitlement is unavailable';
  end if;

  select * into terms
  from entitlement_private.pilot_plan_terms(entitlement.plan_code);
  select count(*)::integer into active_driver_count
  from public.drivers as driver
  where driver.company_id = target_company_id
    and driver.status = 'active';

  return jsonb_build_object(
    'activeDriverCount', active_driver_count,
    'availableDriverSlots', greatest(terms.driver_capacity - active_driver_count, 0),
    'driverCapacity', terms.driver_capacity,
    'monthlyPriceUsd', terms.monthly_price_usd,
    'planCode', entitlement.plan_code::text,
    'trialEndsAt', entitlement.trial_ends_at,
    'trialStartedAt', entitlement.trial_started_at,
    'trialState', case when timezone('utc', now()) < entitlement.trial_ends_at then 'active' else 'expired' end
  );
end;
$$;

create function public.run_pilot_privacy_retention(target_company_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor_id uuid := (select auth.uid());
  location_result jsonb;
  preserved_evidence_metadata_count integer;
  created_run public.company_privacy_retention_runs%rowtype;
begin
  if target_company_id is null or not public.has_active_company_role(
    target_company_id,
    array['owner']::public.company_role[]
  ) then
    raise exception using errcode = '42501', message = 'an active owner is required to run pilot privacy retention';
  end if;

  -- Location retention is fixed at seven detailed days by 0025. It rolls up
  -- coordinate-free aggregates; this wrapper does not receive or return raw
  -- samples. Evidence stays intact for operational/legal audit, so only its
  -- record count is permitted in this run record.
  location_result := public.run_location_retention(target_company_id);
  select count(*)::integer into preserved_evidence_metadata_count
  from public.load_evidence as evidence
  where evidence.company_id = target_company_id;

  insert into public.company_privacy_retention_runs (
    company_id,
    actor_id,
    policy_version,
    purged_current_location_count,
    purged_detailed_location_count,
    preserved_evidence_metadata_count
  ) values (
    target_company_id,
    actor_id,
    'pilot-v1',
    coalesce((location_result ->> 'purgedCurrentLocationCount')::integer, 0),
    coalesce((location_result ->> 'purgedDetailedSampleCount')::integer, 0),
    preserved_evidence_metadata_count
  ) returning * into created_run;

  insert into public.audit_events (
    company_id, actor_id, action, before_data, after_data, entity_type, entity_id
  ) values (
    target_company_id,
    actor_id,
    'privacy_retention.completed',
    '{}'::jsonb,
    jsonb_build_object(
      'policyVersion', created_run.policy_version,
      'purgedCurrentLocationCount', created_run.purged_current_location_count,
      'purgedDetailedLocationCount', created_run.purged_detailed_location_count,
      'preservedEvidenceMetadataCount', created_run.preserved_evidence_metadata_count
    ),
    'company_privacy_retention_run',
    created_run.id
  );

  return jsonb_build_object(
    'policyVersion', created_run.policy_version,
    'purgedCurrentLocationCount', created_run.purged_current_location_count,
    'purgedDetailedLocationCount', created_run.purged_detailed_location_count,
    'preservedEvidenceMetadataCount', created_run.preserved_evidence_metadata_count
  );
end;
$$;

revoke all on function entitlement_private.pilot_plan_terms(public.pilot_plan_code) from public, anon, authenticated;
revoke all on function entitlement_private.create_default_company_pilot_entitlement() from public, anon, authenticated;
revoke all on function entitlement_private.assert_active_driver_capacity(uuid) from public, anon, authenticated;
revoke all on function entitlement_private.enforce_active_driver_capacity() from public, anon, authenticated;
revoke all on function public.get_company_pilot_entitlement(uuid) from public, anon;
revoke all on function public.run_pilot_privacy_retention(uuid) from public, anon;
grant execute on function public.get_company_pilot_entitlement(uuid) to authenticated;
grant execute on function public.run_pilot_privacy_retention(uuid) to authenticated;
