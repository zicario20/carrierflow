-- CarrierFlow identity foundation: owner-created invitations and immutable audit history.
-- All client-originating writes stay behind explicitly granted, tenant-checked RPCs.

alter table public.company_memberships
  alter column user_id drop not null,
  add column invited_email text,
  add column invited_by uuid references auth.users(id) on delete restrict,
  add column invited_at timestamptz,
  add constraint company_memberships_invited_email_format_check check (
    invited_email is null
    or (
      invited_email = lower(btrim(invited_email))
      and char_length(invited_email) between 3 and 320
      and invited_email ~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$'
    )
  ),
  add constraint company_memberships_pending_invitation_check check (
    user_id is not null
    or (
      status = 'pending'::public.membership_status
      and invited_email is not null
      and invited_by is not null
      and invited_at is not null
    )
  ),
  add constraint company_memberships_company_invited_email_key unique (company_id, invited_email);

alter table public.audit_events
  alter column before_data drop not null,
  add column entity_type text,
  add column entity_id uuid,
  add constraint audit_events_before_data_create_only_check check (
    before_data is not null or action = 'membership.invited'
  ),
  add constraint audit_events_membership_invitation_entity_check check (
    action <> 'membership.invited'
    or (entity_type = 'company_membership' and entity_id is not null)
  );

create index company_memberships_company_pending_invitation_idx
  on public.company_memberships (company_id, invited_email)
  where status = 'pending'::public.membership_status and invited_email is not null;

-- Defense in depth: authenticated roles lack DML grants, and this trigger also
-- prevents accidental history rewrites from privileged application paths.
create function public.prevent_audit_event_mutation()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  raise exception using
    errcode = '42501',
    message = 'audit events are immutable';
end;
$$;

create trigger audit_events_immutable
before update or delete on public.audit_events
for each row
execute function public.prevent_audit_event_mutation();

create function public.create_company_invitation(
  target_company_id uuid,
  invitee_email text,
  invitee_role public.company_role
)
returns public.company_memberships
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor_id uuid := (select auth.uid());
  normalized_email text := lower(btrim(invitee_email));
  created_membership public.company_memberships%rowtype;
begin
  if actor_id is null then
    raise exception using
      errcode = '42501',
      message = 'only active owners may create company invitations';
  end if;

  -- The target tenant is authorized from the authenticated actor's active
  -- owner membership; the caller cannot use this RPC to choose another tenant.
  if not exists (
    select 1
    from public.company_memberships as membership
    where membership.company_id = target_company_id
      and membership.user_id = actor_id
      and membership.role = 'owner'::public.company_role
      and membership.status = 'active'::public.membership_status
  ) then
    raise exception using
      errcode = '42501',
      message = 'only active owners may create company invitations';
  end if;

  if normalized_email is null
    or char_length(normalized_email) not between 3 and 320
    or normalized_email !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$' then
    raise exception using
      errcode = '22023',
      message = 'a valid invite email is required';
  end if;

  if invitee_role is null then
    raise exception using
      errcode = '22023',
      message = 'a valid company role is required';
  end if;

  if exists (
    select 1
    from public.company_memberships as membership
    left join auth.users as member_user on member_user.id = membership.user_id
    where membership.company_id = target_company_id
      and (
        membership.invited_email = normalized_email
        or lower(member_user.email) = normalized_email
      )
  ) then
    raise exception using
      errcode = '23505',
      message = 'an invitation or membership already exists for this email';
  end if;

  insert into public.company_memberships (
    company_id,
    user_id,
    role,
    status,
    invited_email,
    invited_by,
    invited_at
  ) values (
    target_company_id,
    null,
    invitee_role,
    'pending'::public.membership_status,
    normalized_email,
    actor_id,
    timezone('utc', now())
  )
  returning * into created_membership;

  insert into public.audit_events (
    company_id,
    actor_id,
    action,
    before_data,
    after_data,
    entity_type,
    entity_id
  ) values (
    target_company_id,
    actor_id,
    'membership.invited',
    null,
    jsonb_build_object(
      'id', created_membership.id,
      'companyId', created_membership.company_id,
      'email', created_membership.invited_email,
      'role', created_membership.role::text,
      'status', created_membership.status::text
    ),
    'company_membership',
    created_membership.id
  );

  return created_membership;
end;
$$;

revoke all on function public.create_company_invitation(uuid, text, public.company_role) from public, anon;
grant execute on function public.create_company_invitation(uuid, text, public.company_role) to authenticated;

revoke all on table public.audit_events from public;
grant select on table public.audit_events to anon, authenticated;
