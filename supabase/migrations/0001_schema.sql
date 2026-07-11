-- Sous M1 schema — full data model from docs/specs/2026-07-11-sous-app-design.md §4.
-- All household-scoped tables carry household_id. ★app-owned tables/columns noted.

create extension if not exists pgcrypto;

-- ── identity & config ──────────────────────────────────────────────
create table personas (
  id          uuid primary key default gen_random_uuid(),
  name        text not null,
  language    text not null default 'zh-Hant',
  tint        text,
  avatar      text,
  prompt_pack text not null,          -- system-prompt fragment (the voice)
  copy_pack   jsonb not null default '{}'::jsonb,  -- notification/UI copy templates
  created_at  timestamptz not null default now()
);

create table households (
  id             uuid primary key default gen_random_uuid(),
  name           text not null,
  persona_id     uuid not null references personas(id),
  timezone       text not null default 'Australia/Sydney',
  worker_seen_at timestamptz,         -- worker heartbeat → presence
  created_at     timestamptz not null default now()
);

create table household_members (
  user_id      uuid not null references auth.users(id) on delete cascade,
  household_id uuid not null references households(id) on delete cascade,
  role         text not null default 'member',
  primary key (user_id, household_id)
);

-- ── kitchen state (brain-owned; app mutates only via jobs) ─────────
create table recipes (
  id           uuid primary key default gen_random_uuid(),
  household_id uuid not null references households(id) on delete cascade,
  slug         text not null,
  title        text not null,
  source_block text,                  -- verbatim 📌 原始食譜
  body_md      text not null default '',
  ingredients  jsonb not null default '[]'::jsonb,
  steps        jsonb not null default '[]'::jsonb,  -- [{stage,text,duration_sec?,tip?}]
  created_at   timestamptz not null default now(),
  unique (household_id, slug)
);

create table plan_weeks (
  id           uuid primary key default gen_random_uuid(),
  household_id uuid not null references households(id) on delete cascade,
  week_of      date not null,
  status       text not null default 'locked',
  reasoning    text,
  created_at   timestamptz not null default now(),
  unique (household_id, week_of)
);

create table plan_days (
  id           uuid primary key default gen_random_uuid(),
  week_id      uuid not null references plan_weeks(id) on delete cascade,
  household_id uuid not null references households(id) on delete cascade,
  date         date not null,
  dish         text not null,
  recipe_id    uuid references recipes(id),
  mode         text not null default 'fast',   -- batch/fast/leftover/play
  prep_note    text,
  nutrition    jsonb,
  reasoning    text,
  status       text not null default 'planned', -- planned/cooked/skipped
  unique (household_id, date)
);

create table shopping_items (
  id           uuid primary key default gen_random_uuid(),
  household_id uuid not null references households(id) on delete cascade,
  week_id      uuid references plan_weeks(id) on delete cascade,
  name         text not null,          -- English, searchable
  qty          text,
  section      text,
  checked      boolean not null default false,  -- ★app-owned column
  recipe_refs  jsonb not null default '[]'::jsonb,
  created_at   timestamptz not null default now()
);

create table staples (
  id           uuid primary key default gen_random_uuid(),
  household_id uuid not null references households(id) on delete cascade,
  name         text not null,
  flagged_low  boolean not null default false,
  unique (household_id, name)
);

create table preferences (
  household_id uuid primary key references households(id) on delete cascade,
  content      text not null default '',
  updated_at   timestamptz not null default now()
);

create table inbox_items (
  id           uuid primary key default gen_random_uuid(),
  household_id uuid not null references households(id) on delete cascade,
  kind         text not null,          -- craving/feedback/note/…
  content      text not null,
  created_at   timestamptz not null default now()
);

-- ── interaction (★app-owned; brain reads, never authors) ───────────
create table chat_messages (
  id           uuid primary key default gen_random_uuid(),
  household_id uuid not null references households(id) on delete cascade,
  sender       text not null check (sender in ('user','chef')),
  content      text not null,
  cards        jsonb,
  job_id       uuid,
  created_at   timestamptz not null default now()
);
create index chat_messages_household_created on chat_messages (household_id, created_at desc);

create table cook_sessions (
  id           uuid primary key default gen_random_uuid(),
  household_id uuid not null references households(id) on delete cascade,
  recipe_id    uuid references recipes(id),
  started_at   timestamptz not null default now(),
  completed_at timestamptz,
  step_ticks   jsonb not null default '[]'::jsonb
);

create table verdicts (
  id           uuid primary key default gen_random_uuid(),
  household_id uuid not null references households(id) on delete cascade,
  plan_day_id  uuid references plan_days(id),
  rating       text not null,          -- 神作/不錯/普通/翻車
  note         text,
  created_at   timestamptz not null default now()
);

-- ── machinery ──────────────────────────────────────────────────────
create table jobs (
  id           uuid primary key default gen_random_uuid(),
  household_id uuid not null references households(id) on delete cascade,
  kind         text not null,          -- chat/ritual/recipe_intake/notif_generate/…
  payload      jsonb not null default '{}'::jsonb,
  status       text not null default 'queued'
               check (status in ('queued','running','done','failed')),
  attempts     int not null default 0,
  result       jsonb,
  claimed_at   timestamptz,
  created_at   timestamptz not null default now()
);
create index jobs_queued on jobs (status, created_at);

create table notifications (
  id           uuid primary key default gen_random_uuid(),
  household_id uuid not null references households(id) on delete cascade,
  send_at      timestamptz not null,
  title        text not null,
  body         text not null,
  deeplink     text,
  status       text not null default 'scheduled',
  created_at   timestamptz not null default now()
);

create table device_tokens (
  token      text primary key,
  user_id    uuid not null references auth.users(id) on delete cascade,
  platform   text not null default 'ios',
  created_at timestamptz not null default now()
);
