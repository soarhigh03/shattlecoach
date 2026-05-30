-- ============================================================
-- Migration: executive registration code RPC
-- Date: 2026-05-30
-- Run on top of the initial schema.sql.
-- Both statements use CREATE OR REPLACE, so re-running is safe.
-- ============================================================

-- 1) Replace the profile-guard so authorized RPCs can bump role.
create or replace function public.guard_profile_changes()
returns trigger language plpgsql as $$
begin
  if new.email is distinct from old.email then
    raise exception 'email is immutable';
  end if;
  if new.role is distinct from old.role
     and not public.is_executive()
     and coalesce(current_setting('app.role_change_authorized', true), 'false') <> 'true' then
    raise exception 'only executives can change role';
  end if;
  return new;
end;
$$;

-- 2) RPC: members redeem the quarterly code to become executive.
-- TODO: rotate quarterly. Eventually replace with a server-issued codes table.
create or replace function public.redeem_executive_code(code text)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  expected_code constant text := '1234';
begin
  if auth.uid() is null then
    raise exception 'not authenticated';
  end if;

  if code is null or btrim(code) <> expected_code then
    return false;
  end if;

  -- Bypass the role-change guard for this transaction only.
  perform set_config('app.role_change_authorized', 'true', true);

  update public.profiles
     set role = 'executive'
   where id = auth.uid();

  return true;
end;
$$;

revoke all on function public.redeem_executive_code(text) from public;
grant execute on function public.redeem_executive_code(text) to authenticated;
