-- OZON Pricing / Supabase schema
-- Apply this file in Supabase Dashboard > SQL Editor.
-- IMPORTANT: This migration never stores passwords. Supabase Auth stores password hashes.
-- Username login adapter uses a synthetic email: lower(username) || '@ozon-pricing.invalid'.
-- Disable email confirmations in Supabase Auth because synthetic addresses cannot receive mail.
-- Password recovery by email is not available with synthetic usernames; provide an admin-assisted reset process.

create extension if not exists pgcrypto;

create table if not exists public.profiles (
  user_id uuid primary key references auth.users(id) on delete cascade,
  username text not null unique,
  trial_started_at timestamptz not null default now(),
  trial_expires_at timestamptz not null default (now() + interval '3 days'),
  created_at timestamptz not null default now(),
  constraint profiles_username_format check (username = lower(username) and username ~ '^[a-z0-9_.-]{3,32}$')
);

create table if not exists public.memberships (
  user_id uuid primary key references auth.users(id) on delete cascade,
  plan_code text not null default 'free' check (plan_code in ('free','monthly','quarterly','yearly')),
  expires_at timestamptz,
  updated_at timestamptz not null default now(),
  constraint memberships_plan_expiry check (
    (plan_code = 'free' and expires_at is null) or
    (plan_code <> 'free' and expires_at is not null)
  )
);

create table if not exists public.admin_roles (
  user_id uuid primary key references auth.users(id) on delete cascade,
  created_at timestamptz not null default now()
);

create table if not exists public.membership_events (
  id bigint generated always as identity primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  actor_user_id uuid not null references auth.users(id),
  event_type text not null check (event_type in ('membership_granted','membership_extended')),
  plan_code text not null check (plan_code in ('monthly','quarterly','yearly')),
  amount_cny numeric(8,2) not null check (amount_cny in (9.90,29.90,99.00)),
  previous_expires_at timestamptz,
  new_expires_at timestamptz not null,
  note text not null default 'Manual WeChat payment verification',
  created_at timestamptz not null default now()
);

create index if not exists membership_events_user_created_idx
  on public.membership_events(user_id, created_at desc);

create or replace function public.handle_new_ozon_user()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_username text;
begin
  v_username := lower(trim(coalesce(new.raw_user_meta_data ->> 'username', '')));
  if v_username !~ '^[a-z0-9_.-]{3,32}$' then
    raise exception 'Username must be 3-32 chars: letters, numbers, dot, underscore or hyphen';
  end if;

  insert into public.profiles(user_id, username)
  values (new.id, v_username);

  insert into public.memberships(user_id, plan_code, expires_at)
  values (new.id, 'free', null);

  return new;
end;
$$;

drop trigger if exists on_auth_user_created_ozon on auth.users;
create trigger on_auth_user_created_ozon
after insert on auth.users
for each row execute procedure public.handle_new_ozon_user();

alter table public.profiles enable row level security;
alter table public.memberships enable row level security;
alter table public.admin_roles enable row level security;
alter table public.membership_events enable row level security;

revoke all on public.profiles from anon, authenticated;
revoke all on public.memberships from anon, authenticated;
revoke all on public.admin_roles from anon, authenticated;
revoke all on public.membership_events from anon, authenticated;

grant select on public.profiles to authenticated;
grant select on public.memberships to authenticated;
grant select on public.admin_roles to authenticated;
grant select on public.membership_events to authenticated;

drop policy if exists "profile read own or admin" on public.profiles;
create policy "profile read own or admin" on public.profiles
for select to authenticated
using (auth.uid() = user_id or exists (
  select 1 from public.admin_roles ar where ar.user_id = auth.uid()
));

drop policy if exists "membership read own or admin" on public.memberships;
create policy "membership read own or admin" on public.memberships
for select to authenticated
using (auth.uid() = user_id or exists (
  select 1 from public.admin_roles ar where ar.user_id = auth.uid()
));

drop policy if exists "admin roles read own" on public.admin_roles;
create policy "admin roles read own" on public.admin_roles
for select to authenticated
using (auth.uid() = user_id);

drop policy if exists "events read own or admin" on public.membership_events;
create policy "events read own or admin" on public.membership_events
for select to authenticated
using (auth.uid() = user_id or exists (
  select 1 from public.admin_roles ar where ar.user_id = auth.uid()
));

create or replace function public.admin_grant_membership(
  p_user_id uuid,
  p_plan_code text,
  p_note text default 'Manual WeChat payment verification'
)
returns table(plan_code text, expires_at timestamptz, event_id bigint)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_now timestamptz := now();
  v_duration interval;
  v_amount numeric(8,2);
  v_previous timestamptz;
  v_new_expiry timestamptz;
  v_event_type text;
  v_event_id bigint;
begin
  if auth.uid() is null or not exists (
    select 1 from public.admin_roles ar where ar.user_id = auth.uid()
  ) then
    raise exception 'Administrator permission required' using errcode = '42501';
  end if;

  case p_plan_code
    when 'monthly' then v_duration := interval '1 month'; v_amount := 9.90;
    when 'quarterly' then v_duration := interval '3 months'; v_amount := 29.90;
    when 'yearly' then v_duration := interval '12 months'; v_amount := 99.00;
    else raise exception 'Invalid membership plan';
  end case;

  if not exists (select 1 from public.profiles p where p.user_id = p_user_id) then
    raise exception 'User account not found';
  end if;

  select m.expires_at into v_previous
  from public.memberships m where m.user_id = p_user_id for update;

  if v_previous is not null and v_previous > v_now then
    v_new_expiry := v_previous + v_duration;
    v_event_type := 'membership_extended';
  else
    v_new_expiry := v_now + v_duration;
    v_event_type := 'membership_granted';
  end if;

  insert into public.memberships(user_id, plan_code, expires_at, updated_at)
  values (p_user_id, p_plan_code, v_new_expiry, v_now)
  on conflict (user_id) do update
    set plan_code = excluded.plan_code,
        expires_at = excluded.expires_at,
        updated_at = excluded.updated_at;

  insert into public.membership_events(
    user_id, actor_user_id, event_type, plan_code, amount_cny,
    previous_expires_at, new_expires_at, note
  ) values (
    p_user_id, auth.uid(), v_event_type, p_plan_code, v_amount,
    v_previous, v_new_expiry, left(coalesce(p_note, 'Manual WeChat payment verification'), 500)
  ) returning id into v_event_id;

  return query select p_plan_code, v_new_expiry, v_event_id;
end;
$$;

revoke all on function public.admin_grant_membership(uuid, text, text) from public, anon;
grant execute on function public.admin_grant_membership(uuid, text, text) to authenticated;

-- First-admin initialization (run manually AFTER creating your own account):
-- 1) Find your user UUID in Authentication > Users, or run:
-- select id, email from auth.users order by created_at desc;
-- 2) Replace YOUR_AUTH_USER_UUID below with that UUID and execute separately:
-- insert into public.admin_roles(user_id) values ('YOUR_AUTH_USER_UUID'::uuid);
-- Never expose an admin service key in the browser. Only a Supabase project owner should run this SQL.
