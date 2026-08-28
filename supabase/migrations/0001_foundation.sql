-- CarrierFlow foundation: tenants, memberships, auditable records, and read-only RLS.
-- Mutations are intentionally deferred to authenticated server/RPC boundaries in later steps.

create type public.company_role as enum ('owner', 'admin', 'dispatcher', 'driver');
create type public.membership_status as enum ('pending', 'active', 'suspended', 'disabled');

create table public.companies (
  id uuid primary key default gen_random_uuid(),
  name text not null check (char_length(btrim(name)) between 1 and 160),
  status text not null default 'active' check (status in ('active', 'inactive')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.company_memberships (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete restrict,
  user_id uuid not null references auth.users(id) on delete restrict,
  role public.company_role not null,
  status public.membership_status not null default 'pending',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (company_id, user_id)
);

create table public.audit_events (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete restrict,
  actor_id uuid references auth.users(id) on delete set null,
  action text not null check (char_length(btrim(action)) between 1 and 160),
  before_data jsonb not null default '{}'::jsonb,
  after_data jsonb not null default '{}'::jsonb,
  occurred_at timestamptz not null default now()
);

create index company_memberships_active_user_company_idx
  on public.company_memberships (user_id, company_id)
  where status = 'active';

create index company_memberships_company_user_idx
  on public.company_memberships (company_id, user_id);

create index audit_events_company_occurred_at_idx
  on public.audit_events (company_id, occurred_at desc);

-- These helpers bypass membership RLS only to evaluate the caller's own active membership.
-- There are no caller-controlled SQL identifiers or values, and a fixed search_path prevents
-- search-path shadowing in this SECURITY DEFINER boundary.
create function public.active_company_ids()
returns setof uuid
language sql
stable
security definer
set search_path = ''
as $$
  select membership.company_id
  from public.company_memberships as membership
  where membership.user_id = (select auth.uid())
    and membership.status = 'active'::public.membership_status;
$$;

create function public.has_active_company_role(
  target_company_id uuid,
  allowed_roles public.company_role[]
)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.company_memberships as membership
    where membership.company_id = target_company_id
      and membership.user_id = (select auth.uid())
      and membership.status = 'active'::public.membership_status
      and membership.role = any(allowed_roles)
  );
$$;

revoke all on function public.active_company_ids() from public;
revoke all on function public.has_active_company_role(uuid, public.company_role[]) from public;
grant execute on function public.active_company_ids() to anon, authenticated;
grant execute on function public.has_active_company_role(uuid, public.company_role[]) to anon, authenticated;

alter table public.companies enable row level security;
alter table public.companies force row level security;
alter table public.company_memberships enable row level security;
alter table public.company_memberships force row level security;
alter table public.audit_events enable row level security;
alter table public.audit_events force row level security;

-- Read access is explicitly granted, but RLS remains the authorization boundary.
-- Client roles receive no direct insert, update, or delete permission in this foundation step.
grant usage on schema public to anon, authenticated;
grant select on public.companies, public.company_memberships, public.audit_events to anon, authenticated;
revoke insert, update, delete, truncate, references, trigger
  on public.companies, public.company_memberships, public.audit_events
  from anon, authenticated;

create policy companies_select_active_members
  on public.companies
  for select
  to anon, authenticated
  using (id in (select public.active_company_ids()));

create policy memberships_select_self_or_privileged_company_member
  on public.company_memberships
  for select
  to anon, authenticated
  using (
    (
      user_id = (select auth.uid())
      and company_id in (select public.active_company_ids())
    )
    or public.has_active_company_role(
      company_id,
      array['owner', 'admin', 'dispatcher']::public.company_role[]
    )
  );

create policy audit_events_select_privileged_company_member
  on public.audit_events
  for select
  to anon, authenticated
  using (
    public.has_active_company_role(
      company_id,
      array['owner', 'admin', 'dispatcher']::public.company_role[]
    )
  );
