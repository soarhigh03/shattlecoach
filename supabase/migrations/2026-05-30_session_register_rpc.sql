-- ============================================================
-- Migration: register_session RPC
-- Date: 2026-05-30
-- Run on top of the initial schema.sql.
-- ============================================================
-- The schedule (Mon/Wed/Fri/Sat × 2 slots) is implicit — every week has the
-- same shape, so workout_sessions rows aren't pre-seeded. The first signup
-- needs to lazily create the row, but the workout_sessions insert policy is
-- exec-only. This RPC runs SECURITY DEFINER to upsert the row and insert
-- attendance atomically. Capacity is still enforced by check_attendance_capacity.

create or replace function public.register_session(
  p_date     date,
  p_slot     text,
  p_capacity int
) returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_session_id uuid;
begin
  if auth.uid() is null then
    raise exception 'not authenticated';
  end if;

  insert into public.workout_sessions(session_date, slot, capacity)
  values (p_date, p_slot, p_capacity)
  on conflict (session_date, slot) do nothing;

  select id into v_session_id
    from public.workout_sessions
    where session_date = p_date and slot = p_slot;

  -- Capacity & session-status enforced by trg_attendance_capacity.
  insert into public.attendance(session_id, user_id)
  values (v_session_id, auth.uid())
  on conflict do nothing;

  return v_session_id;
end;
$$;

revoke all on function public.register_session(date, text, int) from public;
grant execute on function public.register_session(date, text, int) to authenticated;
