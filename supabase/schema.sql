-- ============================================================
-- Shattlecoach DB schema (Supabase) — run in SQL Editor
-- ============================================================

create extension if not exists "uuid-ossp";

-- ---------- Enums ----------
create type handedness     as enum ('left', 'right');
create type user_role      as enum ('member', 'executive');
create type session_status as enum ('scheduled', 'canceled');
create type post_kind      as enum ('group_buy', 'sharing');
create type post_status    as enum ('in_progress', 'ended');

-- ---------- profiles ----------
-- Extends auth.users with onboarding info.
create table public.profiles (
  id           uuid primary key references auth.users(id) on delete cascade,
  email        text not null,
  name         text not null default '',
  handedness   handedness,
  role         user_role not null default 'member',
  onboarded_at timestamptz,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);
create index profiles_role_idx on public.profiles(role);

-- ---------- workout_sessions ----------
-- One row per (week, slot). Executives open / cancel.
-- slot examples: mon_1, mon_2, wed_1, wed_2, fri_1, fri_2, sat_1
create table public.workout_sessions (
  id           uuid primary key default uuid_generate_v4(),
  session_date date not null,
  slot         text not null,
  capacity     int  not null check (capacity > 0),
  status       session_status not null default 'scheduled',
  opened_by    uuid references public.profiles(id),
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  unique (session_date, slot)
);
create index workout_sessions_date_idx on public.workout_sessions(session_date);

-- ---------- attendance ----------
create table public.attendance (
  session_id    uuid not null references public.workout_sessions(id) on delete cascade,
  user_id       uuid not null references public.profiles(id) on delete cascade,
  registered_at timestamptz not null default now(),
  primary key (session_id, user_id)
);
create index attendance_user_idx on public.attendance(user_id);

-- ---------- coaching_clips ----------
-- Video file lives on device; DB stores only count + light metadata.
create table public.coaching_clips (
  id          uuid primary key default uuid_generate_v4(),
  user_id     uuid not null references public.profiles(id) on delete cascade,
  captured_at timestamptz not null default now(),
  local_ref   text,
  created_at  timestamptz not null default now()
);
create index coaching_clips_user_time_idx on public.coaching_clips(user_id, captured_at);

-- ---------- posts ----------
create table public.posts (
  id         uuid primary key default uuid_generate_v4(),
  kind       post_kind   not null,
  title      text        not null,
  body       text        not null default '',
  status     post_status not null default 'in_progress',
  author_id  uuid        not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index posts_kind_status_idx on public.posts(kind, status);
create index posts_created_idx     on public.posts(created_at desc);

-- ---------- post_images ----------
create table public.post_images (
  id           uuid primary key default uuid_generate_v4(),
  post_id      uuid not null references public.posts(id) on delete cascade,
  storage_path text not null,
  ord          int  not null default 0,
  created_at   timestamptz not null default now()
);
create index post_images_post_idx on public.post_images(post_id, ord);

-- ============================================================
-- Helper functions
-- ============================================================

-- SECURITY DEFINER so RLS on profiles doesn't recurse when policies call it.
create or replace function public.is_executive()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.profiles
    where id = auth.uid() and role = 'executive'
  );
$$;

-- ============================================================
-- Triggers
-- ============================================================

create or replace function public.set_updated_at()
returns trigger language plpgsql as $$
begin new.updated_at = now(); return new; end;
$$;

create trigger trg_profiles_updated         before update on public.profiles         for each row execute function public.set_updated_at();
create trigger trg_workout_sessions_updated before update on public.workout_sessions for each row execute function public.set_updated_at();
create trigger trg_posts_updated            before update on public.posts            for each row execute function public.set_updated_at();

-- Auto-create profile on Google sign-up.
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, email, name)
  values (
    new.id,
    new.email,
    coalesce(new.raw_user_meta_data->>'full_name',
             new.raw_user_meta_data->>'name', '')
  );
  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- Block email change + non-executive role escalation.
-- RPCs that intentionally bump role (e.g. redeem_executive_code) set
-- app.role_change_authorized=true within their transaction to bypass this.
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

create trigger trg_profile_guard
  before update on public.profiles
  for each row execute function public.guard_profile_changes();

-- Enforce capacity + status on attendance insert.
create or replace function public.check_attendance_capacity()
returns trigger language plpgsql as $$
declare cap int; curr int; st session_status;
begin
  select capacity, status into cap, st
    from public.workout_sessions
    where id = new.session_id
    for update;

  if st <> 'scheduled' then
    raise exception 'session not open (status=%)', st;
  end if;

  select count(*) into curr from public.attendance where session_id = new.session_id;
  if curr >= cap then
    raise exception 'session full (capacity=%)', cap;
  end if;

  return new;
end;
$$;

create trigger trg_attendance_capacity
  before insert on public.attendance
  for each row execute function public.check_attendance_capacity();

-- ============================================================
-- RLS
-- ============================================================

alter table public.profiles         enable row level security;
alter table public.workout_sessions enable row level security;
alter table public.attendance       enable row level security;
alter table public.coaching_clips   enable row level security;
alter table public.posts            enable row level security;
alter table public.post_images      enable row level security;

-- profiles
create policy profiles_select_all on public.profiles
  for select to authenticated using (true);
create policy profiles_update_self on public.profiles
  for update to authenticated
  using  (id = auth.uid() or public.is_executive())
  with check (id = auth.uid() or public.is_executive());
-- insert path: handle_new_user trigger (SECURITY DEFINER) — no client policy.

-- workout_sessions
create policy sessions_select_all on public.workout_sessions
  for select to authenticated using (true);
create policy sessions_write_exec on public.workout_sessions
  for all to authenticated
  using  (public.is_executive())
  with check (public.is_executive());

-- attendance
create policy attendance_select_all on public.attendance
  for select to authenticated using (true);
create policy attendance_insert_self on public.attendance
  for insert to authenticated with check (user_id = auth.uid());
create policy attendance_delete_self on public.attendance
  for delete to authenticated
  using (user_id = auth.uid() or public.is_executive());

-- coaching_clips (personal log: owner-only)
create policy clips_owner_select on public.coaching_clips
  for select to authenticated using (user_id = auth.uid());
create policy clips_owner_insert on public.coaching_clips
  for insert to authenticated with check (user_id = auth.uid());
create policy clips_owner_delete on public.coaching_clips
  for delete to authenticated using (user_id = auth.uid());

-- posts
create policy posts_select_all on public.posts
  for select to authenticated using (true);
create policy posts_insert on public.posts
  for insert to authenticated
  with check (
    author_id = auth.uid() and (
      kind = 'sharing'
      or (kind = 'group_buy' and public.is_executive())
    )
  );
create policy posts_update on public.posts
  for update to authenticated
  using  (author_id = auth.uid() or public.is_executive())
  with check (author_id = auth.uid() or public.is_executive());
create policy posts_delete on public.posts
  for delete to authenticated
  using (author_id = auth.uid() or public.is_executive());

-- post_images
create policy post_images_select_all on public.post_images
  for select to authenticated using (true);
create policy post_images_write on public.post_images
  for all to authenticated
  using (exists (
    select 1 from public.posts p
    where p.id = post_id and (p.author_id = auth.uid() or public.is_executive())
  ))
  with check (exists (
    select 1 from public.posts p
    where p.id = post_id and (p.author_id = auth.uid() or public.is_executive())
  ));

-- ============================================================
-- RPC: redeem executive registration code
-- ============================================================
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

-- ============================================================
-- Storage bucket: post-images
-- Path convention: <post_id>/<filename>
-- ============================================================
insert into storage.buckets (id, name, public)
values ('post-images', 'post-images', true)
on conflict (id) do nothing;

create policy "post-images read"
on storage.objects for select to authenticated
using (bucket_id = 'post-images');

create policy "post-images insert"
on storage.objects for insert to authenticated
with check (
  bucket_id = 'post-images' and (
    public.is_executive()
    or exists (
      select 1 from public.posts p
      where p.id::text = split_part(name, '/', 1)
        and p.author_id = auth.uid()
    )
  )
);

create policy "post-images delete"
on storage.objects for delete to authenticated
using (
  bucket_id = 'post-images' and (
    public.is_executive()
    or exists (
      select 1 from public.posts p
      where p.id::text = split_part(name, '/', 1)
        and p.author_id = auth.uid()
    )
  )
);
