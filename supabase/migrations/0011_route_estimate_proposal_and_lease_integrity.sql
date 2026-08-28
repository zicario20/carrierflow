-- Forward-only proposal sources. These are intentionally private, bounded
-- server records: clients never submit a GPS point as a route estimate input.
create table public.company_route_bases (
  company_id uuid primary key references public.companies(id) on delete restrict,
  point jsonb not null check (jsonb_typeof(point) = 'object'),
  updated_by uuid not null references auth.users(id) on delete restrict,
  updated_at timestamptz not null default timezone('utc', now())
);
create table public.driver_accepted_route_locations (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete restrict,
  driver_id uuid not null,
  point jsonb not null check (jsonb_typeof(point) = 'object'),
  accepted_at timestamptz not null,
  recorded_by uuid not null references auth.users(id) on delete restrict,
  foreign key (driver_id, company_id) references public.drivers(id, company_id) on delete restrict
);
create index driver_accepted_route_locations_latest_idx on public.driver_accepted_route_locations(company_id, driver_id, accepted_at desc);

create function public.route_estimate_valid_origin_point(value jsonb)
returns boolean language sql immutable set search_path = '' as $$
  select public.route_estimate_stop_coordinates_are_valid(value)
    and char_length(coalesce(btrim(value ->> 'label'), '')) between 1 and 160;
$$;
create function public.set_company_route_base(target_company_id uuid, base_point jsonb)
returns public.company_route_bases language plpgsql security definer set search_path = '' as $$
declare actor_id uuid := (select auth.uid()); saved public.company_route_bases%rowtype;
begin
  if actor_id is null or not public.has_active_company_role(target_company_id, array['owner','admin','dispatcher']::public.company_role[]) then
    raise exception using errcode='42501', message='only an authorized dispatcher may set a route base'; end if;
  if not public.route_estimate_valid_origin_point(base_point) or octet_length(base_point::text) > 1024 then
    raise exception using errcode='22023', message='a bounded US-first declared base with valid coordinates is required'; end if;
  insert into public.company_route_bases(company_id, point, updated_by) values(target_company_id,base_point,actor_id)
  on conflict(company_id) do update set point=excluded.point, updated_by=excluded.updated_by, updated_at=timezone('utc',now()) returning * into saved;
  return saved;
end; $$;
create function public.record_accepted_driver_route_location(target_company_id uuid, target_driver_id uuid, accepted_point jsonb)
returns public.driver_accepted_route_locations language plpgsql security definer set search_path = '' as $$
declare actor_id uuid := (select auth.uid()); saved public.driver_accepted_route_locations%rowtype;
begin
  if actor_id is null or not public.has_active_company_role(target_company_id, array['owner','admin','dispatcher']::public.company_role[]) then
    raise exception using errcode='42501', message='only an authorized dispatcher may record a route location'; end if;
  if not public.route_estimate_valid_origin_point(accepted_point) or octet_length(accepted_point::text)>1024
    or not exists(select 1 from public.drivers where company_id=target_company_id and id=target_driver_id) then
    raise exception using errcode='22023', message='a bounded accepted driver location is required'; end if;
  insert into public.driver_accepted_route_locations(company_id,driver_id,point,accepted_at,recorded_by)
  values(target_company_id,target_driver_id,accepted_point,timezone('utc',now()),actor_id) returning * into saved; return saved;
end; $$;
create function public.route_estimate_proposal_origin(target_company_id uuid, target_load_id uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare target_load public.loads%rowtype; final_stop public.load_stops%rowtype; located public.driver_accepted_route_locations%rowtype; base public.company_route_bases%rowtype;
begin
 select * into target_load from public.loads where company_id=target_company_id and id=target_load_id;
 if target_load.assigned_driver_id is not null then
   select stop.* into final_stop from public.loads l join public.load_stops stop on stop.company_id=l.company_id and stop.load_id=l.id
   where l.company_id=target_company_id and l.assigned_driver_id=target_load.assigned_driver_id and l.id<>target_load_id
   and l.operational_status in('assigned','en_route_to_pickup','arrived_pickup','loading','picked_up','en_route_to_delivery','arrived_delivery','unloading') order by stop.sequence desc limit 1;
   if found and public.route_estimate_stop_coordinates_are_valid(final_stop.stop_data) then return jsonb_build_object('kind','active_load_final_stop','id',final_stop.id,'label',left(final_stop.stop_data->>'address',160),'latitude',(final_stop.stop_data->>'latitude')::numeric,'longitude',(final_stop.stop_data->>'longitude')::numeric); end if;
   select * into located from public.driver_accepted_route_locations where company_id=target_company_id and driver_id=target_load.assigned_driver_id and accepted_at >= timezone('utc',now())-interval '24 hours' order by accepted_at desc limit 1;
   if found then return jsonb_build_object('kind','last_accepted_location','id',located.id,'label',located.point->>'label','latitude',(located.point->>'latitude')::numeric,'longitude',(located.point->>'longitude')::numeric); end if;
 end if;
 select * into base from public.company_route_bases where company_id=target_company_id;
 if found then return jsonb_build_object('kind','declared_base','id',base.company_id,'label',base.point->>'label','latitude',(base.point->>'latitude')::numeric,'longitude',(base.point->>'longitude')::numeric); end if;
 raise exception using errcode='22023', message='a declared base or fresh accepted driver location is required';
end; $$;
revoke all on table public.company_route_bases, public.driver_accepted_route_locations from public,anon,authenticated;
revoke all on function public.route_estimate_valid_origin_point(jsonb), public.route_estimate_proposal_origin(uuid,uuid) from public,anon,authenticated;
revoke all on function public.set_company_route_base(uuid,jsonb), public.record_accepted_driver_route_location(uuid,uuid,jsonb) from public,anon;
grant execute on function public.set_company_route_base(uuid,jsonb), public.record_accepted_driver_route_location(uuid,uuid,jsonb) to authenticated;
