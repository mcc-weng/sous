-- supabase/migrations/0020_recipe_swipes_ritual_cadence.sql
-- Pass 2a (swipe foundation): logs every swipe (Explore + Ritual context), adds
-- household ritual-cadence settings, and allows the client to insert recipe_tweak
-- jobs directly (swipe-up modification, Task 5). See
-- docs/superpowers/specs/2026-08-09-m3-pass2-swipe-judge-design.md §4/§7.

create table recipe_swipes (
  id           uuid primary key default gen_random_uuid(),
  household_id uuid not null references households(id) on delete cascade,
  -- Nullable: most of today's ritual proposals are free text (set-plan never calls
  -- save-recipe) — see the design spec's "Ritual deck delivery" correction. Explore
  -- Deck swipes always carry a real recipe_id since that surface only browses the
  -- cookbook; Ritual Session swipes carry one only when the candidate is a cookbook
  -- recipe.
  recipe_id    uuid references recipes(id),
  dish_text    text,
  action       text not null check (action in ('like','pass','modify')),
  context      text not null check (context in ('explore','ritual')),
  note         text,
  created_at   timestamptz not null default now(),
  check (recipe_id is not null or dish_text is not null)
);
create index recipe_swipes_household_created on recipe_swipes (household_id, created_at desc);

alter table households
  add column ritual_cadence_interval text not null default 'weekly'
    check (ritual_cadence_interval in ('weekly', 'biweekly')),
  -- Sun=1..Sat=7 — matches Calendar.component(.weekday) already used throughout the
  -- iOS app (WeekBoardView.weekdayGlyph), not an arbitrary new convention.
  add column ritual_cadence_anchor_day smallint not null default 1
    check (ritual_cadence_anchor_day between 1 and 7);

alter table recipe_swipes enable row level security;
create policy recipe_swipes_rw on recipe_swipes for all to authenticated
  using (is_member(household_id)) with check (is_member(household_id));

-- Same pattern as 0005/0006: jobs_write only ever allows an explicit kind allowlist.
-- recipe_tweak is inserted directly by the client on swipe-up (Task 5), not proxied
-- through a chat message first. Merges with the allowlist from 0007 (recipe_intake,
-- notif_generate) and 0005/0006 (chat, ritual).
alter policy jobs_write on jobs
  with check (is_member(household_id) and kind in ('chat','ritual','recipe_intake','notif_generate','recipe_tweak'));
