-- Support Supabase anonymous sign-ins (used as the "채점용 게스트" path so
-- a TA/grader can run the app without Google OAuth setup).
--
-- Anonymous users have NULL email in auth.users; the original handle_new_user
-- trigger wrote new.email directly into public.profiles.email, which is
-- NOT NULL — so anon sign-up would fail. Coalesce to empty string.
--
-- The not-null invariant on profiles.email is preserved for the (still empty)
-- column; downstream code (settings_screen.dart) already substitutes a
-- friendly "채점용 게스트 세션" label when user.isAnonymous.

create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, email, name)
  values (
    new.id,
    coalesce(new.email, ''),
    coalesce(new.raw_user_meta_data->>'full_name',
             new.raw_user_meta_data->>'name', '')
  );
  return new;
end;
$$;
