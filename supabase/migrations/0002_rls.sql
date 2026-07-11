-- RLS: members read their household; app writes only ★app-owned tables/columns.
-- The worker connects with the service role and bypasses RLS entirely.

create or replace function public.is_member(hid uuid)
returns boolean language sql stable security definer set search_path = public as
$$ select exists (select 1 from household_members
                  where household_id = hid and user_id = auth.uid()); $$;

alter table personas          enable row level security;
alter table households        enable row level security;
alter table household_members enable row level security;
alter table recipes           enable row level security;
alter table plan_weeks        enable row level security;
alter table plan_days         enable row level security;
alter table shopping_items    enable row level security;
alter table staples           enable row level security;
alter table preferences       enable row level security;
alter table inbox_items       enable row level security;
alter table chat_messages     enable row level security;
alter table cook_sessions     enable row level security;
alter table verdicts          enable row level security;
alter table jobs              enable row level security;
alter table notifications     enable row level security;
alter table device_tokens     enable row level security;

-- personas are global content, readable by any signed-in user
create policy personas_read on personas for select to authenticated using (true);

create policy households_read on households for select to authenticated
  using (is_member(id));
create policy members_read on household_members for select to authenticated
  using (user_id = auth.uid());

-- kitchen state: read-only for members (mutations go through jobs → worker/service role)
create policy recipes_read        on recipes        for select to authenticated using (is_member(household_id));
create policy plan_weeks_read     on plan_weeks     for select to authenticated using (is_member(household_id));
create policy plan_days_read      on plan_days      for select to authenticated using (is_member(household_id));
create policy shopping_read       on shopping_items for select to authenticated using (is_member(household_id));
create policy staples_read        on staples        for select to authenticated using (is_member(household_id));
create policy preferences_read    on preferences    for select to authenticated using (is_member(household_id));
create policy inbox_read          on inbox_items    for select to authenticated using (is_member(household_id));
create policy notifications_read  on notifications  for select to authenticated using (is_member(household_id));

-- ★checked is the one app-writable kitchen column (M2 tightens to column-level; row-level is fine for M1)
create policy shopping_check on shopping_items for update to authenticated
  using (is_member(household_id)) with check (is_member(household_id));

-- interaction: app-owned
create policy chat_read  on chat_messages for select to authenticated using (is_member(household_id));
create policy chat_write on chat_messages for insert to authenticated
  with check (is_member(household_id) and sender = 'user');
create policy cook_rw    on cook_sessions for all to authenticated
  using (is_member(household_id)) with check (is_member(household_id));
create policy verdict_rw on verdicts for all to authenticated
  using (is_member(household_id)) with check (is_member(household_id));

-- jobs: members may enqueue chat jobs and watch their status
create policy jobs_read  on jobs for select to authenticated using (is_member(household_id));
create policy jobs_write on jobs for insert to authenticated
  with check (is_member(household_id) and kind = 'chat');

create policy tokens_rw on device_tokens for all to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());

-- realtime: tables the app subscribes to
alter publication supabase_realtime add table chat_messages, plan_days, shopping_items, households, jobs;

-- ── M1 SHIM: auto-join every new auth user to the sandbox household. ──
-- Replaced by real onboarding in M3. Fine while the only users are Mike's devices.
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into household_members (user_id, household_id)
  values (new.id, '00000000-0000-0000-0000-000000000001')
  on conflict do nothing;
  return new;
end $$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();
