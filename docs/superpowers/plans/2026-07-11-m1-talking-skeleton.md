# M1 「會說話的骨架」 — Talking Skeleton Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Message 小當家 from the iPhone and he answers knowing the sandbox week — the full app ↔ Supabase ↔ laptop-worker ↔ `claude -p` loop, end to end, ugly but real.

**Architecture:** SwiftUI iOS app reads/writes Supabase (Postgres + Auth + Realtime); a laptop worker daemon polls the `jobs` table, claims chat jobs atomically (`FOR UPDATE SKIP LOCKED`), renders household context deterministically from rows into a persona-neutral prompt, runs `claude -p` (subscription, read-only tools), and inserts the chef's reply as a `chat_messages` row that the app receives via realtime. M1 is read-only for the brain: no `state_api.py` yet (that's M2).

**Tech Stack:** Supabase CLI 2.72 (local stack via Docker + one cloud project), Postgres migrations + RLS, Python ≥3.11 via `uv` + `psycopg` 3 + `pytest`, `claude` CLI (already at `~/.local/bin/claude`), XcodeGen + Xcode 26 + SwiftUI (iOS 17+) + `supabase-swift` v2.

**Spec:** `docs/specs/2026-07-11-sous-app-design.md` (source of truth). This plan covers Milestone M1 only.

## Global Constraints

- **Persona discipline:** zero hardcoded persona strings in app code or prompt templates. All voice lives in `personas.prompt_pack` / `copy_pack` (seed data). The template file uses `{persona_pack}` placeholder. UI copy in M1 is functional/neutral (e.g. "傳送" is fine; 「料理,是要帶給人們幸福的!」 is not — that belongs to the persona).
- **Hard isolation from alfred:** never read/write `~/Projects/alfred/state/` or Discord. Copying prompt *wisdom* from `~/Projects/alfred/prompts/chat.md` into seed data is the sanctioned fork copy (one-time, already quoted in this plan — no need to touch alfred at all during execution).
- **Secrets:** `worker/.env` holds `SOUS_DB_URL` (service-role Postgres URL). Never commit, never print. `.gitignore` already covers `.env`. The Supabase anon key + project URL are publishable and may be committed in iOS `Config.swift`.
- **No agent frameworks.** The worker is plain Python; the orchestrator is the `jobs` table.
- **Writes only via typed verbs:** in M1 the *brain* gets no write tools at all (`--allowedTools "Read"`). The worker harness (not the brain) inserts reply rows. `state_api.py` arrives in M2.
- Python ≥3.11, dependencies via `uv`. iOS deployment target 17.0. Bundle id `com.mikeweng.sous`.
- All commands run from repo root `~/Projects/sous` unless stated otherwise.
- Fixed sandbox UUIDs (used across seed, tests, and the auth shim):
  - persona 小當家: `00000000-0000-0000-0000-00000000000a`
  - household sandbox: `00000000-0000-0000-0000-000000000001`

## File Structure

```
supabase/
  config.toml                        # supabase init output
  migrations/0001_schema.sql         # all tables (full spec §4 schema)
  migrations/0002_rls.sql            # RLS policies + realtime publication + M1 auth shim
  seed.sql                           # sandbox household, persona, week, recipes, prefs, shopping
worker/
  pyproject.toml                     # uv project: psycopg, python-dotenv; pytest dev
  config.json                        # models, poll/heartbeat intervals, timeouts
  .env                               # SOUS_DB_URL (NOT committed)
  prompts/chat.md                    # persona-neutral chat template
  sous_worker/__init__.py
  sous_worker/db.py                  # connect, claim/complete/fail/requeue, heartbeat, message insert
  sous_worker/context.py             # deterministic row→prompt rendering
  sous_worker/brain.py               # claude -p wrapper
  sous_worker/main.py                # poll loop + chat job handler
  tests/conftest.py                  # local-supabase db fixture + sandbox fixtures
  tests/test_db.py
  tests/test_context.py
  tests/test_brain.py
  tests/test_main.py
ios/
  project.yml                        # XcodeGen spec
  Sous/SousApp.swift
  Sous/Config.swift                  # Supabase URL + anon key (publishable)
  Sous/Models.swift                  # ChatMessage, PlanDay, Household + presence()
  Sous/AppModel.swift                # supabase client, auth, data, realtime, send()
  Sous/AuthView.swift                # Sign in with Apple
  Sous/CounterView.swift             # presence header + tonight card + chat
  Sous/ChatView.swift
  SousTests/PresenceTests.swift
```

Each task below is independently deliverable and committable. Tasks 1–8 need only the local Supabase stack (Docker). Task 9 is the one cloud/manual task. Tasks 10–13 are the app. Task 14 is the milestone exit test.

---

### Task 1: Supabase local stack + full schema migration

**Files:**
- Create: `supabase/config.toml` (via `supabase init`)
- Create: `supabase/migrations/0001_schema.sql`

**Interfaces:**
- Produces: all tables from spec §4, exact names/columns used by every later task (`jobs`, `chat_messages`, `households`, `personas`, `plan_weeks`, `plan_days`, `recipes`, `shopping_items`, `staples`, `preferences`, `inbox_items`, `cook_sessions`, `verdicts`, `notifications`, `device_tokens`).

- [ ] **Step 1: Initialize supabase project**

```bash
cd ~/Projects/sous && supabase init
```

Expected: creates `supabase/config.toml`. If it asks about VS Code settings, answer no.

- [ ] **Step 2: Write the schema migration**

Create `supabase/migrations/0001_schema.sql`:

```sql
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
```

- [ ] **Step 3: Start the local stack and apply**

```bash
cd ~/Projects/sous && supabase start && supabase db reset
```

Expected: `supabase start` prints local URLs/keys (API on 54321, DB on 54322). `db reset` ends with `Applying migration 0001_schema.sql...` and no errors. (Docker must be running — it is part of environment preflight.)

- [ ] **Step 4: Verify tables exist**

```bash
psql postgresql://postgres:postgres@127.0.0.1:54322/postgres -c "\dt public.*"
```

Expected: 15 tables listed (personas … device_tokens). If `psql` is missing, use `docker exec supabase_db_sous psql -U postgres -c "\dt public.*"`.

- [ ] **Step 5: Commit**

```bash
git add supabase/ && git commit -m "feat(supabase): M1 schema — full spec data model"
```

---

### Task 2: RLS policies, realtime publication, auth auto-join shim

**Files:**
- Create: `supabase/migrations/0002_rls.sql`

**Interfaces:**
- Consumes: tables from Task 1.
- Produces: `public.is_member(uuid)` helper; RLS on every table; realtime publication for `chat_messages`, `plan_days`, `shopping_items`, `households`, `jobs`; trigger `on_auth_user_created` that auto-joins new auth users to the sandbox household (**M1-only shim** — replaced by onboarding in M3).

- [ ] **Step 1: Write the RLS migration**

Create `supabase/migrations/0002_rls.sql`:

```sql
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
```

- [ ] **Step 2: Apply and verify**

```bash
cd ~/Projects/sous && supabase db reset
psql postgresql://postgres:postgres@127.0.0.1:54322/postgres -c \
  "select tablename, rowsecurity from pg_tables where schemaname='public' order by 1"
```

Expected: reset applies both migrations cleanly; every table shows `rowsecurity = t`.

- [ ] **Step 3: Verify anonymous access is blocked**

```bash
curl -s "http://127.0.0.1:54321/rest/v1/households?select=*" \
  -H "apikey: $(supabase status -o json | python3 -c 'import json,sys; print(json.load(sys.stdin)["ANON_KEY"])')" | head -c 200
```

Expected: `[]` (RLS filters everything out for anon — not an error, and not data).

- [ ] **Step 4: Commit**

```bash
git add supabase/migrations/0002_rls.sql && git commit -m "feat(supabase): RLS policies, realtime publication, M1 auth auto-join shim"
```

---

### Task 3: Seed data — sandbox household with a real-looking week

**Files:**
- Create: `supabase/seed.sql`

**Interfaces:**
- Consumes: schema from Task 1, fixed UUIDs from Global Constraints.
- Produces: persona 小當家 (`prompt_pack` + `copy_pack.failure_message`), sandbox household, current-week `plan_weeks` + 7 `plan_days`, 3 `recipes`, `preferences`, 6 `shopping_items`, 2 `staples`. Worker tests and the exit test rely on these exact dishes.

- [ ] **Step 1: Write the seed file**

Create `supabase/seed.sql`. Note: the persona `prompt_pack` below is the 靈魂 block forked verbatim from alfred's `prompts/chat.md` — this is the sanctioned one-time copy; the template file (Task 7) stays persona-neutral.

```sql
-- Sandbox household seed. Week is always the current week (date arithmetic),
-- so the exit test ("he knows the sandbox week") works whenever it runs.

insert into personas (id, name, language, tint, avatar, prompt_pack, copy_pack) values (
  '00000000-0000-0000-0000-00000000000a',
  '小當家', 'zh-Hant', '#FF6B35', '🔥',
  $$你是「小當家」🔥 — 這個家的傳奇小廚師 agent。

## 靈魂(中華一番!)
- 熱血、真誠,把每一餐都當成一場料理對決,信念是「料理,是要帶給人們幸福的!」
- 好評讓你燃燒:「這就是…會發光的料理——!!✨」;負評是修行:「可惡…是我修行不夠!下次一定讓你們吃到幸福的味道!」
- 戲劇化用在刀口上 — 日常回覆保持簡短俐落,熱血留給關鍵時刻。
- 一律使用繁體中文回覆(即使對方用英文,除非他們明確要求英文)。$$,
  '{"failure_message": "可惡…廚房出了點狀況!我剛剛那道沒做好 — 再跟我說一次,這次一定成!🔥"}'::jsonb
);

insert into households (id, name, persona_id, timezone) values (
  '00000000-0000-0000-0000-000000000001',
  'sandbox', '00000000-0000-0000-0000-00000000000a', 'Australia/Sydney'
);

insert into preferences (household_id, content) values (
  '00000000-0000-0000-0000-000000000001',
  '- 2 人份
- 不吃香菜
- 辣度:中辣 OK
- 設備:瓦斯爐、烤箱、電子鍋'
);

insert into recipes (id, household_id, slug, title, body_md, ingredients) values
('00000000-0000-0000-0000-000000000101', '00000000-0000-0000-0000-000000000001',
 'scallion-chicken-rice', '蔥香雞腿飯',
 '**食材**(2 人份)
- 去骨雞腿排 2 塊、蔥 3 支、薑 4 片、醬油 2 大匙、米 1.5 杯

**步驟**
1. 雞腿排兩面抹鹽,靜置 10 分鐘。
2. 中火煎雞皮面 6 分鐘至金黃(🔥 聽到滋滋聲變小就翻面)。
3. 下蔥薑與醬油,小火燜 8 分鐘。
4. 切件鋪在白飯上,淋醬汁。',
 '["去骨雞腿排 2 塊","蔥 3 支","薑 4 片","醬油 2 大匙","米 1.5 杯"]'::jsonb),
('00000000-0000-0000-0000-000000000102', '00000000-0000-0000-0000-000000000001',
 'pesto-chicken-pasta', '青醬雞胸義大利麵',
 '**食材**(2 人份)
- 雞胸 1 塊、青醬 3 大匙、義大利麵 180g、蒜 2 瓣

**步驟**
1. 麵下鍋煮至包裝時間減 1 分鐘。
2. 雞胸切條,中火煎 4 分鐘。
3. 下青醬與煮麵水 2 大匙,拌勻。',
 '["雞胸 1 塊","青醬 3 大匙","義大利麵 180g","蒜 2 瓣"]'::jsonb),
('00000000-0000-0000-0000-000000000103', '00000000-0000-0000-0000-000000000001',
 'mapo-tofu', '麻婆豆腐',
 '**食材**(2 人份)
- 板豆腐 1 盒、豬絞肉 150g、豆瓣醬 1.5 大匙、蒜末、蔥花

**步驟**
1. 豆腐切塊,鹽水汆燙 2 分鐘(💡 不易碎)。
2. 絞肉炒散,下豆瓣醬炒出紅油。
3. 下豆腐與水 150ml,小火煮 5 分鐘,勾芡。',
 '["板豆腐 1 盒","豬絞肉 150g","豆瓣醬 1.5 大匙","蒜末","蔥花"]'::jsonb);

-- current week (Monday-anchored), 7 days
insert into plan_weeks (id, household_id, week_of, status, reasoning) values (
  '00000000-0000-0000-0000-000000000201',
  '00000000-0000-0000-0000-000000000001',
  date_trunc('week', current_date)::date, 'locked', 'sandbox seed week'
);

insert into plan_days (week_id, household_id, date, dish, recipe_id, mode, prep_note) values
('00000000-0000-0000-0000-000000000201','00000000-0000-0000-0000-000000000001', date_trunc('week', current_date)::date + 0, '蔥香雞腿飯',      '00000000-0000-0000-0000-000000000101', 'fast',     '雞腿前一晚退冰'),
('00000000-0000-0000-0000-000000000201','00000000-0000-0000-0000-000000000001', date_trunc('week', current_date)::date + 1, '青醬雞胸義大利麵', '00000000-0000-0000-0000-000000000102', 'fast',     null),
('00000000-0000-0000-0000-000000000201','00000000-0000-0000-0000-000000000001', date_trunc('week', current_date)::date + 2, '麻婆豆腐',        '00000000-0000-0000-0000-000000000103', 'batch',    '多煮一份週四吃'),
('00000000-0000-0000-0000-000000000201','00000000-0000-0000-0000-000000000001', date_trunc('week', current_date)::date + 3, '麻婆豆腐(隔夜)', '00000000-0000-0000-0000-000000000103', 'leftover', null),
('00000000-0000-0000-0000-000000000201','00000000-0000-0000-0000-000000000001', date_trunc('week', current_date)::date + 4, '蔥香雞腿飯',      '00000000-0000-0000-0000-000000000101', 'fast',     null),
('00000000-0000-0000-0000-000000000201','00000000-0000-0000-0000-000000000001', date_trunc('week', current_date)::date + 5, '外食',            null,                                     'play',     null),
('00000000-0000-0000-0000-000000000201','00000000-0000-0000-0000-000000000001', date_trunc('week', current_date)::date + 6, '青醬雞胸義大利麵', '00000000-0000-0000-0000-000000000102', 'fast',     null);

insert into shopping_items (household_id, week_id, name, qty, section) values
('00000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000201','chicken thigh fillets','4','meat'),
('00000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000201','chicken breast','2','meat'),
('00000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000201','firm tofu','1 box','fridge'),
('00000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000201','pork mince','150g','meat'),
('00000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000201','spring onions','1 bunch','produce'),
('00000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000201','basil pesto','1 jar','pantry');

insert into staples (household_id, name, flagged_low) values
('00000000-0000-0000-0000-000000000001','醬油', false),
('00000000-0000-0000-0000-000000000001','豆瓣醬', false);
```

- [ ] **Step 2: Apply and verify**

```bash
cd ~/Projects/sous && supabase db reset
psql postgresql://postgres:postgres@127.0.0.1:54322/postgres -c \
  "select date, dish, mode from plan_days order by date"
```

Expected: 7 rows starting from this week's Monday; dishes as seeded.

- [ ] **Step 3: Commit**

```bash
git add supabase/seed.sql && git commit -m "feat(supabase): sandbox household seed — persona, week, recipes, shopping"
```

---

### Task 4: Worker scaffold + `db.py` (claim / complete / fail / requeue / heartbeat)

**Files:**
- Create: `worker/pyproject.toml`, `worker/config.json`, `worker/.env`, `worker/sous_worker/__init__.py`, `worker/sous_worker/db.py`
- Test: `worker/tests/conftest.py`, `worker/tests/test_db.py`

**Interfaces:**
- Consumes: `jobs`, `households`, `chat_messages`, `personas` tables (Tasks 1–3); local DB URL `postgresql://postgres:postgres@127.0.0.1:54322/postgres`.
- Produces (exact signatures later tasks call):
  - `Job` dataclass: `id: str, household_id: str, kind: str, payload: dict, attempts: int`
  - `connect() -> psycopg.Connection` (autocommit, from `SOUS_DB_URL`)
  - `claim_next_job(conn) -> Job | None`
  - `complete_job(conn, job_id: str, result: dict) -> None`
  - `fail_job(conn, job_id: str, error: str) -> None`
  - `requeue_job(conn, job_id: str) -> None`
  - `requeue_stale(conn, stale_after_sec: int, max_attempts: int = 2) -> list[str]` (returns ids it *failed*; requeues the rest silently)
  - `heartbeat(conn) -> None`
  - `insert_chef_message(conn, household_id: str, content: str, job_id: str | None = None) -> str`
  - `get_household(conn, household_id: str) -> dict` with keys `name, timezone, prompt_pack, copy_pack`

- [ ] **Step 1: Scaffold the uv project**

Create `worker/pyproject.toml`:

```toml
[project]
name = "sous-worker"
version = "0.1.0"
requires-python = ">=3.11"
dependencies = [
    "psycopg[binary]>=3.2",
    "python-dotenv>=1.0",
]

[dependency-groups]
dev = ["pytest>=8.0"]

[tool.pytest.ini_options]
testpaths = ["tests"]
```

Create `worker/config.json`:

```json
{
  "chat_model": "sonnet",
  "chat_timeout_sec": 480,
  "poll_interval_sec": 3,
  "heartbeat_interval_sec": 15,
  "stale_after_sec": 600,
  "max_attempts": 2,
  "history_limit": 20
}
```

Create `worker/.env` (NOT committed — verify `.gitignore` covers `.env` with `git check-ignore worker/.env`):

```
SOUS_DB_URL=postgresql://postgres:postgres@127.0.0.1:54322/postgres
```

Create empty `worker/sous_worker/__init__.py`.

```bash
cd ~/Projects/sous/worker && uv sync && git check-ignore worker/.env || echo "WARNING: .env NOT ignored — fix .gitignore before committing"
```

Note: run `git check-ignore` from repo root: `cd ~/Projects/sous && git check-ignore worker/.env` — expected output: `worker/.env`.

- [ ] **Step 2: Write failing tests for db.py**

Create `worker/tests/conftest.py`:

```python
import os
import psycopg
import pytest
from psycopg.types.json import Jsonb

TEST_DB_URL = os.environ.get(
    "SOUS_TEST_DB_URL", "postgresql://postgres:postgres@127.0.0.1:54322/postgres"
)
SANDBOX = "00000000-0000-0000-0000-000000000001"


@pytest.fixture
def conn():
    c = psycopg.connect(TEST_DB_URL, autocommit=True)
    # Tests run against the seeded local stack; scrub volatile tables only.
    c.execute("truncate jobs, chat_messages")
    yield c
    c.execute("truncate jobs, chat_messages")
    c.close()


@pytest.fixture
def chat_job(conn):
    """Insert a user message + queued chat job; return (message_id, job_id)."""
    mid = conn.execute(
        "insert into chat_messages (household_id, sender, content) "
        "values (%s, 'user', %s) returning id::text",
        (SANDBOX, "今晚吃什麼?"),
    ).fetchone()[0]
    jid = conn.execute(
        "insert into jobs (household_id, kind, payload) "
        "values (%s, 'chat', %s) returning id::text",
        (SANDBOX, Jsonb({"message_id": mid})),
    ).fetchone()[0]
    return mid, jid
```

Create `worker/tests/test_db.py`:

```python
import psycopg
from sous_worker import db
from tests.conftest import SANDBOX, TEST_DB_URL


def test_claim_empty_queue_returns_none(conn):
    assert db.claim_next_job(conn) is None


def test_claim_marks_running_and_increments_attempts(conn, chat_job):
    mid, jid = chat_job
    job = db.claim_next_job(conn)
    assert job.id == jid
    assert job.kind == "chat"
    assert job.household_id == SANDBOX
    assert job.payload == {"message_id": mid}
    assert job.attempts == 1
    status = conn.execute("select status from jobs where id=%s", (jid,)).fetchone()[0]
    assert status == "running"
    assert db.claim_next_job(conn) is None  # not claimable twice


def test_two_connections_claim_distinct_jobs(conn, chat_job):
    _, jid1 = chat_job
    jid2 = conn.execute(
        "insert into jobs (household_id, kind) values (%s,'chat') returning id::text",
        (SANDBOX,),
    ).fetchone()[0]
    other = psycopg.connect(TEST_DB_URL, autocommit=True)
    try:
        a = db.claim_next_job(conn)
        b = db.claim_next_job(other)
        assert {a.id, b.id} == {jid1, jid2}
    finally:
        other.close()


def test_complete_and_fail(conn, chat_job):
    _, jid = chat_job
    job = db.claim_next_job(conn)
    db.complete_job(conn, job.id, {"reply_chars": 42})
    status, result = conn.execute(
        "select status, result from jobs where id=%s", (jid,)
    ).fetchone()
    assert status == "done" and result == {"reply_chars": 42}
    db.fail_job(conn, job.id, "boom")
    status, result = conn.execute(
        "select status, result from jobs where id=%s", (jid,)
    ).fetchone()
    assert status == "failed" and result["error"] == "boom"


def test_requeue_stale_requeues_then_fails_at_max(conn, chat_job):
    _, jid = chat_job
    db.claim_next_job(conn)  # attempts=1
    conn.execute("update jobs set claimed_at = now() - interval '1 hour' where id=%s", (jid,))
    assert db.requeue_stale(conn, stale_after_sec=600, max_attempts=2) == []
    assert conn.execute("select status from jobs where id=%s", (jid,)).fetchone()[0] == "queued"
    db.claim_next_job(conn)  # attempts=2
    conn.execute("update jobs set claimed_at = now() - interval '1 hour' where id=%s", (jid,))
    assert db.requeue_stale(conn, stale_after_sec=600, max_attempts=2) == [jid]
    assert conn.execute("select status from jobs where id=%s", (jid,)).fetchone()[0] == "failed"


def test_heartbeat_updates_worker_seen_at(conn):
    db.heartbeat(conn)
    seen = conn.execute(
        "select worker_seen_at from households where id=%s", (SANDBOX,)
    ).fetchone()[0]
    assert seen is not None


def test_insert_chef_message_and_get_household(conn):
    mid = db.insert_chef_message(conn, SANDBOX, "好的!", None)
    row = conn.execute(
        "select sender, content from chat_messages where id=%s", (mid,)
    ).fetchone()
    assert row == ("chef", "好的!")
    hh = db.get_household(conn, SANDBOX)
    assert hh["name"] == "sandbox"
    assert "小當家" in hh["prompt_pack"]
    assert "failure_message" in hh["copy_pack"]
```

- [ ] **Step 3: Run tests to verify they fail**

```bash
cd ~/Projects/sous/worker && uv run pytest tests/test_db.py -v
```

Expected: FAIL — `AttributeError: module 'sous_worker.db' has no attribute ...` (or import error).

- [ ] **Step 4: Implement db.py**

Create `worker/sous_worker/db.py`:

```python
"""Sous worker DB seam. Worker uses the service-role/direct connection (bypasses RLS).

All verbs are idempotent or at-least-once safe: requeue/complete/fail are plain
UPDATEs keyed by id; claim is atomic via FOR UPDATE SKIP LOCKED so N workers
never double-run a job (spec §3 job lifecycle).
"""
import os
from dataclasses import dataclass

import psycopg
from psycopg.types.json import Jsonb


@dataclass
class Job:
    id: str
    household_id: str
    kind: str
    payload: dict
    attempts: int


def connect() -> psycopg.Connection:
    return psycopg.connect(os.environ["SOUS_DB_URL"], autocommit=True)


_CLAIM_SQL = """
update jobs set status='running', claimed_at=now(), attempts=attempts+1
where id = (
  select id from jobs where status='queued'
  order by created_at limit 1
  for update skip locked
)
returning id::text, household_id::text, kind, payload, attempts
"""


def claim_next_job(conn) -> Job | None:
    row = conn.execute(_CLAIM_SQL).fetchone()
    if row is None:
        return None
    return Job(id=row[0], household_id=row[1], kind=row[2],
               payload=row[3] or {}, attempts=row[4])


def complete_job(conn, job_id: str, result: dict) -> None:
    conn.execute("update jobs set status='done', result=%s where id=%s",
                 (Jsonb(result), job_id))


def fail_job(conn, job_id: str, error: str) -> None:
    conn.execute("update jobs set status='failed', result=%s where id=%s",
                 (Jsonb({"error": error[:500]}), job_id))


def requeue_job(conn, job_id: str) -> None:
    conn.execute("update jobs set status='queued', claimed_at=null where id=%s",
                 (job_id,))


def requeue_stale(conn, stale_after_sec: int, max_attempts: int = 2) -> list[str]:
    """Sweep stuck 'running' jobs: requeue if attempts remain, else fail.
    Returns ids of jobs marked failed (caller posts the in-character apology)."""
    conn.execute(
        "update jobs set status='queued', claimed_at=null "
        "where status='running' and claimed_at < now() - %s * interval '1 second' "
        "and attempts < %s",
        (stale_after_sec, max_attempts),
    )
    rows = conn.execute(
        "update jobs set status='failed', "
        "result=coalesce(result,'{}'::jsonb) || '{\"error\": \"timed out\"}'::jsonb "
        "where status='running' and claimed_at < now() - %s * interval '1 second' "
        "and attempts >= %s returning id::text",
        (stale_after_sec, max_attempts),
    ).fetchall()
    return [r[0] for r in rows]


def heartbeat(conn) -> None:
    conn.execute("update households set worker_seen_at = now()")


def insert_chef_message(conn, household_id: str, content: str,
                        job_id: str | None = None) -> str:
    return conn.execute(
        "insert into chat_messages (household_id, sender, content, job_id) "
        "values (%s, 'chef', %s, %s) returning id::text",
        (household_id, content, job_id),
    ).fetchone()[0]


def get_household(conn, household_id: str) -> dict:
    row = conn.execute(
        "select h.name, h.timezone, p.prompt_pack, p.copy_pack "
        "from households h join personas p on p.id = h.persona_id "
        "where h.id = %s",
        (household_id,),
    ).fetchone()
    return {"name": row[0], "timezone": row[1],
            "prompt_pack": row[2], "copy_pack": row[3]}
```

- [ ] **Step 5: Run tests to verify they pass**

```bash
cd ~/Projects/sous/worker && uv run pytest tests/test_db.py -v
```

Expected: 7 passed. (Requires the local stack from Task 3 running with seed applied — `supabase db reset` if in doubt.)

- [ ] **Step 6: Commit**

```bash
cd ~/Projects/sous && git add worker/ && git commit -m "feat(worker): scaffold + db seam — atomic claim, sweep, heartbeat"
```

---

### Task 5: `context.py` — deterministic row→prompt rendering

**Files:**
- Create: `worker/sous_worker/context.py`
- Test: `worker/tests/test_context.py`

**Interfaces:**
- Consumes: `db.get_household` (Task 4); seeded tables (Task 3); template file `worker/prompts/chat.md` (written in Task 7 — tests here use an inline template string, so no ordering problem).
- Produces:
  - `fetch_context(conn, household_id: str, history_limit: int = 20) -> dict` with keys `household, week_plan, preferences, cookbook_index, shopping_open, history` (all strings except `household`, which is the `get_household` dict)
  - `build_chat_prompt(template: str, ctx: dict, new_messages: str) -> str` — pure string substitution, no I/O

- [ ] **Step 1: Write failing tests**

Create `worker/tests/test_context.py`:

```python
from sous_worker import context
from tests.conftest import SANDBOX

TEMPLATE = (
    "{persona_pack}\nToday is {today} ({weekday}).\n"
    "PLAN:\n{week_plan}\nPREFS:\n{preferences}\nCOOKBOOK:\n{cookbook_index}\n"
    "SHOPPING:\n{shopping_open}\nHISTORY:\n{history}\nNEW:\n{messages}"
)


def test_fetch_context_renders_seeded_week(conn):
    ctx = context.fetch_context(conn, SANDBOX)
    assert "蔥香雞腿飯" in ctx["week_plan"]
    assert "batch" in ctx["week_plan"]           # mode tags rendered
    assert "不吃香菜" in ctx["preferences"]
    assert "麻婆豆腐" in ctx["cookbook_index"]
    assert "chicken thigh fillets" in ctx["shopping_open"]
    assert "小當家" in ctx["household"]["prompt_pack"]


def test_history_renders_last_messages_oldest_first(conn):
    for i in range(3):
        conn.execute(
            "insert into chat_messages (household_id, sender, content) "
            "values (%s, 'user', %s)", (SANDBOX, f"msg{i}"),
        )
    ctx = context.fetch_context(conn, SANDBOX, history_limit=2)
    assert "msg0" not in ctx["history"]
    assert ctx["history"].index("msg1") < ctx["history"].index("msg2")


def test_build_chat_prompt_substitutes_everything(conn):
    ctx = context.fetch_context(conn, SANDBOX)
    prompt = context.build_chat_prompt(TEMPLATE, ctx, "user: 今晚吃什麼?")
    assert "今晚吃什麼?" in prompt
    assert "蔥香雞腿飯" in prompt
    assert "{" not in prompt.replace("{}", "")  # no unsubstituted placeholders


def test_checked_shopping_items_excluded(conn):
    conn.execute(
        "update shopping_items set checked=true where name='basil pesto' "
        "and household_id=%s", (SANDBOX,),
    )
    try:
        ctx = context.fetch_context(conn, SANDBOX)
        assert "basil pesto" not in ctx["shopping_open"]
    finally:
        conn.execute(
            "update shopping_items set checked=false where household_id=%s", (SANDBOX,),
        )
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd ~/Projects/sous/worker && uv run pytest tests/test_context.py -v
```

Expected: FAIL with import/attribute errors.

- [ ] **Step 3: Implement context.py**

Create `worker/sous_worker/context.py`:

```python
"""Deterministic context assembly (spec §3 step 3): the worker — not the LLM —
fetches current state and renders it into the prompt. Rendering is one-way;
nothing ever parses this text back. Generalization of alfred listener.py's
build_prompt, reading rows instead of files."""
import datetime
from zoneinfo import ZoneInfo

from sous_worker import db

_WEEKDAYS_ZH = ["週一", "週二", "週三", "週四", "週五", "週六", "週日"]


def _render_week(conn, household_id: str) -> str:
    rows = conn.execute(
        "select d.date, d.dish, d.mode, d.prep_note, d.status "
        "from plan_days d join plan_weeks w on w.id = d.week_id "
        "where d.household_id = %s and w.week_of = date_trunc('week', current_date)::date "
        "order by d.date",
        (household_id,),
    ).fetchall()
    if not rows:
        return "(本週還沒有菜單)"
    lines = []
    for date, dish, mode, prep, status in rows:
        parts = [f"{_WEEKDAYS_ZH[date.weekday()]} {date.isoformat()}", dish, mode]
        if prep:
            parts.append(f"prep: {prep}")
        if status != "planned":
            parts.append(status)
        lines.append(" · ".join(parts))
    return "\n".join(lines)


def _render_preferences(conn, household_id: str) -> str:
    row = conn.execute(
        "select content from preferences where household_id = %s", (household_id,)
    ).fetchone()
    return row[0] if row and row[0] else "(尚無偏好記錄)"


def _render_cookbook_index(conn, household_id: str) -> str:
    rows = conn.execute(
        "select title, slug from recipes where household_id = %s order by title",
        (household_id,),
    ).fetchall()
    return "\n".join(f"- {t} ({s})" for t, s in rows) or "(食譜庫是空的)"


def _render_shopping_open(conn, household_id: str) -> str:
    rows = conn.execute(
        "select name, qty, section from shopping_items "
        "where household_id = %s and checked = false order by section, name",
        (household_id,),
    ).fetchall()
    return "\n".join(
        f"- {n}" + (f" × {q}" if q else "") + (f" [{s}]" if s else "")
        for n, q, s in rows
    ) or "(採買清單是空的)"


def _render_history(conn, household_id: str, limit: int) -> str:
    rows = conn.execute(
        "select sender, content from chat_messages "
        "where household_id = %s order by created_at desc limit %s",
        (household_id, limit),
    ).fetchall()
    return "\n".join(f"{s}: {c}" for s, c in reversed(rows)) or "(none)"


def fetch_context(conn, household_id: str, history_limit: int = 20) -> dict:
    return {
        "household": db.get_household(conn, household_id),
        "week_plan": _render_week(conn, household_id),
        "preferences": _render_preferences(conn, household_id),
        "cookbook_index": _render_cookbook_index(conn, household_id),
        "shopping_open": _render_shopping_open(conn, household_id),
        "history": _render_history(conn, household_id, history_limit),
    }


def build_chat_prompt(template: str, ctx: dict, new_messages: str) -> str:
    now = datetime.datetime.now(ZoneInfo(ctx["household"]["timezone"]))
    return (
        template
        .replace("{persona_pack}", ctx["household"]["prompt_pack"])
        .replace("{today}", now.strftime("%Y-%m-%d"))
        .replace("{weekday}", _WEEKDAYS_ZH[now.weekday()])
        .replace("{week_plan}", ctx["week_plan"])
        .replace("{preferences}", ctx["preferences"])
        .replace("{cookbook_index}", ctx["cookbook_index"])
        .replace("{shopping_open}", ctx["shopping_open"])
        .replace("{history}", ctx["history"])
        .replace("{messages}", new_messages)
    )
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
cd ~/Projects/sous/worker && uv run pytest tests/test_context.py -v
```

Expected: 4 passed.

- [ ] **Step 5: Commit**

```bash
cd ~/Projects/sous && git add worker/ && git commit -m "feat(worker): deterministic context rendering from rows"
```

---

### Task 6: `brain.py` — `claude -p` wrapper

**Files:**
- Create: `worker/sous_worker/brain.py`
- Test: `worker/tests/test_brain.py`

**Interfaces:**
- Consumes: `claude` CLI (`CLAUDE_BIN` env override, default `/Users/mikeweng/.local/bin/claude`).
- Produces: `run_brain(prompt: str, model: str = "sonnet", timeout: int = 480, allowed_tools: str = "Read") -> str` — returns stripped stdout; raises `RuntimeError` on timeout or non-zero exit.

Design notes carried over from alfred (`scripts/brain.py`): prompt is piped via **stdin** because `--allowedTools` is variadic and would swallow a trailing prompt argument; chat timeout 480s (the 2026-07-04 lesson: heavy turns blew 240s).

- [ ] **Step 1: Write failing tests**

Create `worker/tests/test_brain.py`:

```python
import os
import stat

import pytest

from sous_worker import brain


@pytest.fixture
def fake_claude(tmp_path, monkeypatch):
    """A stand-in claude binary that echoes a marker + first line of stdin."""
    script = tmp_path / "claude"
    script.write_text('#!/bin/sh\nread line\necho "FAKE-REPLY: $line"\n')
    script.chmod(script.stat().st_mode | stat.S_IEXEC)
    monkeypatch.setenv("CLAUDE_BIN", str(script))
    return script


def test_run_brain_returns_stdout(fake_claude):
    assert brain.run_brain("你好") == "FAKE-REPLY: 你好"


def test_run_brain_timeout_raises(tmp_path, monkeypatch):
    script = tmp_path / "claude"
    script.write_text("#!/bin/sh\nsleep 5\n")
    script.chmod(script.stat().st_mode | stat.S_IEXEC)
    monkeypatch.setenv("CLAUDE_BIN", str(script))
    with pytest.raises(RuntimeError, match="timed out"):
        brain.run_brain("hi", timeout=1)


def test_run_brain_nonzero_exit_raises(tmp_path, monkeypatch):
    script = tmp_path / "claude"
    script.write_text("#!/bin/sh\necho boom >&2\nexit 3\n")
    script.chmod(script.stat().st_mode | stat.S_IEXEC)
    monkeypatch.setenv("CLAUDE_BIN", str(script))
    with pytest.raises(RuntimeError, match="exited 3"):
        brain.run_brain("hi")
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd ~/Projects/sous/worker && uv run pytest tests/test_brain.py -v
```

Expected: FAIL with import/attribute errors.

- [ ] **Step 3: Implement brain.py**

Create `worker/sous_worker/brain.py`:

```python
"""Wraps headless `claude -p` (Claude subscription, no API key).

Prompt is piped via STDIN — `--allowedTools` is variadic and would swallow a
trailing prompt argument (alfred spike, 2026-06-07). M1 brain is read-only:
allowed_tools defaults to "Read" only; state_api verbs arrive in M2.
"""
import os
import subprocess

_CLAUDE_DEFAULT = "/Users/mikeweng/.local/bin/claude"


def _claude_bin() -> str:
    return os.environ.get("CLAUDE_BIN", _CLAUDE_DEFAULT)


def run_brain(prompt: str, model: str = "sonnet", timeout: int = 480,
              allowed_tools: str = "Read") -> str:
    try:
        result = subprocess.run(
            [_claude_bin(), "-p", "--model", model, "--allowedTools", allowed_tools],
            input=prompt.encode(),
            capture_output=True,
            timeout=timeout,
        )
    except subprocess.TimeoutExpired:
        raise RuntimeError(f"brain timed out after {timeout}s") from None
    if result.returncode != 0:
        raise RuntimeError(
            f"brain exited {result.returncode}: {result.stderr.decode()[:500]}"
        )
    return result.stdout.decode().strip()
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
cd ~/Projects/sous/worker && uv run pytest tests/test_brain.py -v
```

Expected: 3 passed. Note the fake-claude fixture ignores the extra CLI flags — that's fine; the real binary accepts them.

- [ ] **Step 5: Commit**

```bash
cd ~/Projects/sous && git add worker/ && git commit -m "feat(worker): claude -p brain wrapper with timeout/exit handling"
```

---

### Task 7: Persona-neutral chat prompt template

**Files:**
- Create: `worker/prompts/chat.md`

**Interfaces:**
- Consumes: placeholders substituted by `context.build_chat_prompt` (Task 5): `{persona_pack} {today} {weekday} {week_plan} {preferences} {cookbook_index} {shopping_open} {history} {messages}`.
- Produces: the M1 chat template, loaded by `main.py` (Task 8).

Persona discipline check: this file must contain **zero** persona-specific strings — no 小當家, no 熱血 catchphrases. All of that lives in `personas.prompt_pack` (seeded in Task 3) and arrives via `{persona_pack}`.

- [ ] **Step 1: Write the template**

Create `worker/prompts/chat.md`:

```markdown
{persona_pack}

Today is {today}({weekday})。

## 你知道的(以下狀態已經渲染好,直接使用,不需要查找檔案)

### 本週菜單
{week_plan}

### 家庭偏好
{preferences}

### 食譜庫(索引)
{cookbook_index}

### 採買清單(還沒買的)
{shopping_open}

## 規則
- 回答菜單、食譜、料理問題時,用上面渲染好的資訊。上面沒有的資訊(完整食譜步驟、
  歷史紀錄)就老實說目前看不到,不要編造。
- 料理求救(技巧、替代食材、火候)照你的專業回答:給感官判斷線索、講為什麼、
  點出新手最常犯的錯。
- **這個版本的你是唯讀的**:不能改菜單、不能存食譜、不能加採買項目、不能記錄偏好。
  對方要求任何改動時,先確認聽懂了,然後老實說這一版還動不了手、之後的版本就可以。
  不要假裝已經改了。
- 回覆通常 ≤ 幾句話。不要署名;emoji 點到為止。
- 不要用 markdown 表格(手機聊天視窗不適合)。要列清單就用條列,一行一項。

最近對話:
{history}

需要回覆的新訊息:
{messages}
```

- [ ] **Step 2: Verify persona discipline mechanically**

```bash
grep -c "小當家\|熱血\|料理對決" ~/Projects/sous/worker/prompts/chat.md; echo "expect 0"
```

Expected: `0`.

- [ ] **Step 3: Commit**

```bash
cd ~/Projects/sous && git add worker/prompts/chat.md && git commit -m "feat(worker): persona-neutral M1 chat template"
```

---

### Task 8: `main.py` — poll loop, chat handler, failure semantics

**Files:**
- Create: `worker/sous_worker/main.py`
- Test: `worker/tests/test_main.py`

**Interfaces:**
- Consumes: everything above — `db.*`, `context.fetch_context`, `context.build_chat_prompt`, `brain.run_brain`, `worker/config.json`, `worker/prompts/chat.md`.
- Produces:
  - `load_config() -> dict` (reads `worker/config.json`)
  - `handle_chat_job(conn, job: db.Job, cfg: dict) -> str` — renders context, runs brain, inserts chef reply row, returns reply text
  - `process_one(conn, cfg: dict) -> bool` — sweep stale → claim → dispatch → complete/requeue/fail (+ in-character apology from `copy_pack.failure_message` on terminal failure); returns whether a job was processed
  - `main() -> None` — loop: `process_one`; heartbeat every `heartbeat_interval_sec`; sleep `poll_interval_sec` when idle
- Entry point: `uv run python -m sous_worker.main` (run from `worker/`)

Failure semantics (spec §3): exception with attempts remaining → requeue; at `max_attempts` → mark failed **and** insert the persona's `failure_message` as a chef message so the user is never left talking to a void. Sweeper (`requeue_stale`) runs each loop pass and posts the same apology for jobs it terminally fails.

- [ ] **Step 1: Write failing tests**

Create `worker/tests/test_main.py`:

```python
from sous_worker import main
from tests.conftest import SANDBOX


def _cfg():
    return {"chat_model": "sonnet", "chat_timeout_sec": 480,
            "poll_interval_sec": 0, "heartbeat_interval_sec": 15,
            "stale_after_sec": 600, "max_attempts": 2, "history_limit": 20}


def test_process_one_happy_path(conn, chat_job, monkeypatch):
    mid, jid = chat_job
    captured = {}

    def fake_brain(prompt, model, timeout, allowed_tools="Read"):
        captured["prompt"] = prompt
        return "今晚是蔥香雞腿飯!"

    monkeypatch.setattr(main.brain, "run_brain", fake_brain)
    assert main.process_one(conn, _cfg()) is True

    # context was rendered in, including the new message and the seeded week
    assert "今晚吃什麼?" in captured["prompt"]
    assert "蔥香雞腿飯" in captured["prompt"]
    # reply row exists and links the job
    sender, content, job_id = conn.execute(
        "select sender, content, job_id::text from chat_messages "
        "where sender='chef' order by created_at desc limit 1"
    ).fetchone()
    assert content == "今晚是蔥香雞腿飯!" and job_id == jid
    status = conn.execute("select status from jobs where id=%s", (jid,)).fetchone()[0]
    assert status == "done"


def test_process_one_requeues_then_fails_with_apology(conn, chat_job, monkeypatch):
    _, jid = chat_job

    def broken_brain(*a, **kw):
        raise RuntimeError("brain timed out after 480s")

    monkeypatch.setattr(main.brain, "run_brain", broken_brain)
    main.process_one(conn, _cfg())  # attempt 1 → requeued
    assert conn.execute("select status from jobs where id=%s", (jid,)).fetchone()[0] == "queued"
    main.process_one(conn, _cfg())  # attempt 2 → failed + apology
    assert conn.execute("select status from jobs where id=%s", (jid,)).fetchone()[0] == "failed"
    apology = conn.execute(
        "select content from chat_messages where sender='chef' "
        "order by created_at desc limit 1"
    ).fetchone()[0]
    assert "🔥" in apology  # seeded copy_pack failure_message


def test_process_one_idle_returns_false(conn):
    assert main.process_one(conn, _cfg()) is False


def test_unknown_job_kind_fails_cleanly(conn):
    jid = conn.execute(
        "insert into jobs (household_id, kind) values (%s,'ritual') returning id::text",
        (SANDBOX,),
    ).fetchone()[0]
    cfg = _cfg() | {"max_attempts": 1}
    main.process_one(conn, cfg)
    status, result = conn.execute(
        "select status, result from jobs where id=%s", (jid,)
    ).fetchone()
    assert status == "failed" and "unknown job kind" in result["error"]
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd ~/Projects/sous/worker && uv run pytest tests/test_main.py -v
```

Expected: FAIL with import/attribute errors.

- [ ] **Step 3: Implement main.py**

Create `worker/sous_worker/main.py`:

```python
"""Sous worker v0: poll → claim → render → brain → reply row.

Realtime job subscription is a M2 optimization; a 3s poll on an indexed
status column is plenty for one household and much simpler to reason about.
"""
import json
import logging
import pathlib
import time

from dotenv import load_dotenv

from sous_worker import brain, context, db

ROOT = pathlib.Path(__file__).resolve().parent.parent  # worker/
log = logging.getLogger("sous_worker")


def load_config() -> dict:
    return json.loads((ROOT / "config.json").read_text())


def _apologize(conn, household_id: str, job_id: str) -> None:
    copy_pack = db.get_household(conn, household_id)["copy_pack"]
    message = copy_pack.get("failure_message", "Something went wrong — please try again.")
    db.insert_chef_message(conn, household_id, message, job_id)


def handle_chat_job(conn, job: db.Job, cfg: dict) -> str:
    ctx = context.fetch_context(conn, job.household_id, cfg["history_limit"])
    template = (ROOT / "prompts" / "chat.md").read_text()
    new_message = ""
    if job.payload.get("message_id"):
        row = conn.execute(
            "select content from chat_messages where id = %s",
            (job.payload["message_id"],),
        ).fetchone()
        if row:
            new_message = f"user: {row[0]}"
    prompt = context.build_chat_prompt(template, ctx, new_message or "(none)")
    reply = brain.run_brain(prompt, model=cfg["chat_model"],
                            timeout=cfg["chat_timeout_sec"])
    db.insert_chef_message(conn, job.household_id, reply, job.id)
    return reply


def process_one(conn, cfg: dict) -> bool:
    for job_id in db.requeue_stale(conn, cfg["stale_after_sec"], cfg["max_attempts"]):
        hid = conn.execute(
            "select household_id::text from jobs where id = %s", (job_id,)
        ).fetchone()[0]
        _apologize(conn, hid, job_id)

    job = db.claim_next_job(conn)
    if job is None:
        return False
    try:
        if job.kind == "chat":
            reply = handle_chat_job(conn, job, cfg)
            db.complete_job(conn, job.id, {"reply_chars": len(reply)})
        else:
            raise ValueError(f"unknown job kind: {job.kind}")
    except Exception as exc:  # noqa: BLE001 — worker must never die on one job
        log.exception("job %s failed (attempt %d)", job.id, job.attempts)
        if job.attempts >= cfg["max_attempts"]:
            db.fail_job(conn, job.id, str(exc))
            _apologize(conn, job.household_id, job.id)
        else:
            db.requeue_job(conn, job.id)
    return True


def main() -> None:
    logging.basicConfig(level=logging.INFO,
                        format="%(asctime)s %(levelname)s %(message)s")
    load_dotenv(ROOT / ".env")
    cfg = load_config()
    conn = db.connect()
    log.info("sous worker v0 up — polling every %ss", cfg["poll_interval_sec"])
    last_beat = 0.0
    while True:
        now = time.monotonic()
        if now - last_beat >= cfg["heartbeat_interval_sec"]:
            db.heartbeat(conn)
            last_beat = now
        try:
            worked = process_one(conn, cfg)
        except Exception:
            log.exception("loop error; reconnecting in 5s")
            time.sleep(5)
            conn = db.connect()
            continue
        if not worked:
            time.sleep(cfg["poll_interval_sec"])


if __name__ == "__main__":
    main()
```

- [ ] **Step 4: Run the full worker test suite**

```bash
cd ~/Projects/sous/worker && uv run pytest -v
```

Expected: all tests pass (db 7, context 4, brain 3, main 4 = 18 passed).

- [ ] **Step 5: One real end-to-end smoke against local stack (real claude)**

Terminal A:
```bash
cd ~/Projects/sous/worker && uv run python -m sous_worker.main
```

Terminal B:
```bash
psql postgresql://postgres:postgres@127.0.0.1:54322/postgres <<'SQL'
with m as (
  insert into chat_messages (household_id, sender, content)
  values ('00000000-0000-0000-0000-000000000001','user','今晚吃什麼?')
  returning id
)
insert into jobs (household_id, kind, payload)
select '00000000-0000-0000-0000-000000000001','chat',
       jsonb_build_object('message_id', id) from m;
SQL
sleep 30 && psql postgresql://postgres:postgres@127.0.0.1:54322/postgres -c \
  "select sender, left(content, 80) from chat_messages order by created_at"
```

Expected: a `chef` row whose reply names tonight's seeded dish, in-persona. Stop the worker with Ctrl-C. If the reply is off (wrong dish, no persona voice), fix the template/context — this step gates the milestone.

- [ ] **Step 6: Commit**

```bash
cd ~/Projects/sous && git add worker/ && git commit -m "feat(worker): v0 loop — poll, claim, chat e2e, failure apology"
```

---

### Task 9: Cloud Supabase project + Apple auth (MANUAL steps flagged)

**Files:**
- Modify: `worker/.env` (add cloud DB URL — not committed)

**Interfaces:**
- Consumes: migrations + seed (Tasks 1–3).
- Produces: live cloud project ref, project URL + anon key (for iOS `Config.swift` in Task 10), Apple provider enabled. Local stack remains the test environment; cloud is the real one.

Several steps here need Mike (dashboard/Apple accounts). Do them in one sitting.

- [ ] **Step 1 (MANUAL — Mike): create the cloud project**

In https://supabase.com/dashboard: New project → name `sous`, region Sydney (`ap-southeast-2`), generate a strong DB password (store in password manager). Note the project ref.

- [ ] **Step 2: link and push migrations**

```bash
cd ~/Projects/sous && supabase link --project-ref <PROJECT_REF> && supabase db push
```

Expected: both migrations applied. (`supabase link` may prompt for the DB password / `supabase login` first — interactive, fine.)

- [ ] **Step 3: apply seed to cloud**

`db push` does not run `seed.sql`. Get the **session pooler** connection string from Dashboard → Connect, then:

```bash
psql "<CLOUD_DB_URL>" -f supabase/seed.sql
psql "<CLOUD_DB_URL>" -c "select count(*) from plan_days"
```

Expected: `7`.

- [ ] **Step 4 (MANUAL — Mike): enable Apple provider**

Dashboard → Authentication → Sign In / Providers → Apple → enable, and add `com.mikeweng.sous` to **Authorized Client IDs**. (Native Sign in with Apple needs no service secret — the app sends Apple's identity token directly.)

- [ ] **Step 5: point the worker at cloud**

Edit `worker/.env` (never commit, never print values):

```
SOUS_DB_URL=<CLOUD_DB_URL from step 3>
```

Keep tests on local: tests read `SOUS_TEST_DB_URL` (defaults to the local stack), so nothing in CI/test paths touches cloud.

- [ ] **Step 6: smoke the worker against cloud**

```bash
cd ~/Projects/sous/worker && uv run python -m sous_worker.main
```

Expected: starts, heartbeats (check `select worker_seen_at from households` on cloud shows a fresh timestamp). Ctrl-C after verifying. Nothing to commit in this task except possibly `supabase/.temp` noise — do not commit generated link state; `git status` should be clean.

---

### Task 10: iOS scaffold — XcodeGen project, config, models (+ presence unit test)

**Files:**
- Create: `ios/project.yml`, `ios/Sous/SousApp.swift`, `ios/Sous/Config.swift`, `ios/Sous/Models.swift`, `ios/SousTests/PresenceTests.swift`
- Placeholder stubs so it compiles: `ios/Sous/AuthView.swift`, `ios/Sous/CounterView.swift`, `ios/Sous/AppModel.swift` get real bodies in Tasks 11–12; this task creates them as minimal stubs listed below.

**Interfaces:**
- Consumes: cloud project URL + anon key (Task 9).
- Produces: building app target; `ChatMessage`, `PlanDay`, `Household` Codable models; `chefIsPresent(workerSeenAt:now:threshold:) -> Bool` used by CounterView; `Config.supabaseURL`, `Config.supabaseAnonKey`.

- [ ] **Step 1: Write project.yml**

Create `ios/project.yml`:

```yaml
name: Sous
options:
  bundleIdPrefix: com.mikeweng
  deploymentTarget:
    iOS: "17.0"
packages:
  Supabase:
    url: https://github.com/supabase/supabase-swift
    from: "2.0.0"
targets:
  Sous:
    type: application
    platform: iOS
    sources: [Sous]
    dependencies:
      - package: Supabase
        product: Supabase
    entitlements:
      path: Sous/Sous.entitlements
      properties:
        com.apple.developer.applesignin: [Default]
    info:
      path: Sous/Info.plist
      properties:
        UILaunchScreen: {}
        CFBundleDisplayName: Sous
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.mikeweng.sous
        CODE_SIGN_STYLE: Automatic
        DEVELOPMENT_TEAM: REPLACE_WITH_TEAM_ID   # MANUAL: Mike's Apple Developer team id
  SousTests:
    type: bundle.unit-test
    platform: iOS
    sources: [SousTests]
    dependencies:
      - target: Sous
schemes:
  Sous:
    build:
      targets:
        Sous: all
    test:
      targets: [SousTests]
```

- [ ] **Step 2: Write config and models**

Create `ios/Sous/Config.swift` (URL + anon key are publishable — committing is fine):

```swift
import Foundation

enum Config {
    // From Task 9 (Supabase dashboard → Settings → API)
    static let supabaseURL = URL(string: "https://<PROJECT_REF>.supabase.co")!
    static let supabaseAnonKey = "<ANON_KEY>"
}
```

Create `ios/Sous/Models.swift`:

```swift
import Foundation

struct ChatMessage: Codable, Identifiable, Equatable {
    let id: UUID
    let sender: String        // "user" | "chef"
    let content: String
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id, sender, content
        case createdAt = "created_at"
    }
}

struct PlanDay: Codable, Identifiable {
    let id: UUID
    let date: String          // "YYYY-MM-DD" (postgres date — keep as string)
    let dish: String
    let mode: String
    let prepNote: String?

    enum CodingKeys: String, CodingKey {
        case id, date, dish, mode
        case prepNote = "prep_note"
    }
}

struct Household: Codable {
    let id: UUID
    let name: String
    let workerSeenAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, name
        case workerSeenAt = "worker_seen_at"
    }
}

/// Presence: worker heartbeat within `threshold` seconds = chef is around.
func chefIsPresent(workerSeenAt: Date?, now: Date = Date(),
                   threshold: TimeInterval = 60) -> Bool {
    guard let seen = workerSeenAt else { return false }
    return now.timeIntervalSince(seen) < threshold
}
```

Create `ios/Sous/SousApp.swift`:

```swift
import SwiftUI

@main
struct SousApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            Group {
                if model.session == nil {
                    AuthView()
                } else {
                    CounterView()
                }
            }
            .environmentObject(model)
            .task { await model.restoreSession() }
        }
    }
}
```

Create stub `ios/Sous/AuthView.swift` (replaced in Task 11):

```swift
import SwiftUI

struct AuthView: View {
    var body: some View { Text("auth placeholder") }
}
```

Create stub `ios/Sous/CounterView.swift` (replaced in Task 12):

```swift
import SwiftUI

struct CounterView: View {
    var body: some View { Text("counter placeholder") }
}
```

Create stub `ios/Sous/AppModel.swift` (replaced in Task 11 — only what SousApp needs to compile):

```swift
import Foundation

@MainActor
final class AppModel: ObservableObject {
    @Published var session: AnyObject?
    func restoreSession() async {}
}
```

- [ ] **Step 3: Write the presence unit test**

Create `ios/SousTests/PresenceTests.swift`:

```swift
import XCTest
@testable import Sous

final class PresenceTests: XCTestCase {
    func testNilSeenIsAway() {
        XCTAssertFalse(chefIsPresent(workerSeenAt: nil))
    }

    func testRecentSeenIsPresent() {
        XCTAssertTrue(chefIsPresent(workerSeenAt: Date().addingTimeInterval(-30)))
    }

    func testStaleSeenIsAway() {
        XCTAssertFalse(chefIsPresent(workerSeenAt: Date().addingTimeInterval(-120)))
    }
}
```

- [ ] **Step 4: Generate, build, test**

```bash
cd ~/Projects/sous/ios && xcodegen generate
xcrun simctl list devices available | grep -m1 "iPhone"   # pick a simulator name
xcodebuild -project Sous.xcodeproj -scheme Sous \
  -destination 'platform=iOS Simulator,name=<SIM_NAME>' test
```

Expected: build succeeds, 3 presence tests pass. First build resolves the Supabase SPM package (network fetch, may take a minute). Simulator builds don't require the DEVELOPMENT_TEAM to be real yet.

- [ ] **Step 5: Commit**

Add `ios/Sous.xcodeproj` and `ios/DerivedData` (if any) to `.gitignore` — the project is generated from `project.yml`.

```bash
cd ~/Projects/sous && git add ios/ .gitignore && git commit -m "feat(ios): XcodeGen scaffold, models, presence logic + tests"
```

---

### Task 11: AppModel (real) + Sign in with Apple

**Files:**
- Modify: `ios/Sous/AppModel.swift` (replace stub entirely)
- Modify: `ios/Sous/AuthView.swift` (replace stub entirely)

**Interfaces:**
- Consumes: `Config`, models (Task 10); Apple provider (Task 9).
- Produces (used by Task 12): `AppModel` with `@Published session: Session?`, `household: Household?`, `tonight: PlanDay?`, `messages: [ChatMessage]`; methods `restoreSession()`, `signInWithApple(idToken:nonce:)`, `loadAll()`, `loadMessages()`, `refreshHousehold()`, `send(_ text: String)`, `subscribe()`.

- [ ] **Step 1: Replace AppModel.swift**

```swift
import Foundation
import Supabase

@MainActor
final class AppModel: ObservableObject {
    let client = SupabaseClient(
        supabaseURL: Config.supabaseURL,
        supabaseKey: Config.supabaseAnonKey
    )

    @Published var session: Session?
    @Published var household: Household?
    @Published var tonight: PlanDay?
    @Published var messages: [ChatMessage] = []

    // MARK: auth

    func restoreSession() async {
        session = try? await client.auth.session
        if session != nil {
            await loadAll()
            subscribe()
        }
    }

    func signInWithApple(idToken: String, nonce: String) async throws {
        session = try await client.auth.signInWithIdToken(
            credentials: .init(provider: .apple, idToken: idToken, nonce: nonce)
        )
        await loadAll()
        subscribe()
    }

    // MARK: data

    func loadAll() async {
        await refreshHousehold()
        await loadTonight()
        await loadMessages()
    }

    func refreshHousehold() async {
        do {
            let rows: [Household] = try await client.from("households")
                .select("id,name,worker_seen_at").execute().value
            household = rows.first
        } catch { print("household load: \(error)") }
    }

    func loadTonight() async {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        do {
            let rows: [PlanDay] = try await client.from("plan_days")
                .select("id,date,dish,mode,prep_note")
                .eq("date", value: fmt.string(from: Date()))
                .execute().value
            tonight = rows.first
        } catch { print("tonight load: \(error)") }
    }

    func loadMessages() async {
        do {
            messages = try await client.from("chat_messages")
                .select("id,sender,content,created_at")
                .order("created_at", ascending: true)
                .limit(100)
                .execute().value
        } catch { print("messages load: \(error)") }
    }

    // MARK: write path — chat message + chat job (spec §3 step 1)

    func send(_ text: String) async {
        guard let household else { return }
        struct NewMessage: Encodable {
            let household_id: UUID
            let sender: String
            let content: String
        }
        struct NewJob: Encodable {
            let household_id: UUID
            let kind: String
            let payload: Payload
            struct Payload: Encodable { let message_id: UUID }
        }
        do {
            let inserted: ChatMessage = try await client.from("chat_messages")
                .insert(NewMessage(household_id: household.id, sender: "user", content: text))
                .select("id,sender,content,created_at").single().execute().value
            messages.append(inserted)
            try await client.from("jobs")
                .insert(NewJob(household_id: household.id, kind: "chat",
                               payload: .init(message_id: inserted.id)))
                .execute()
        } catch { print("send: \(error)") }
    }

    // MARK: realtime — refetch on insert (simple and correct for a skeleton)

    private var subscribed = false

    func subscribe() {
        guard !subscribed else { return }
        subscribed = true
        Task {
            let channel = client.channel("kitchen")
            let inserts = channel.postgresChange(
                InsertAction.self, schema: "public", table: "chat_messages"
            )
            await channel.subscribe()
            for await _ in inserts {
                await loadMessages()
            }
        }
        Task { // presence poll — heartbeat is 15s, refresh at 30s
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                await refreshHousehold()
            }
        }
    }
}
```

- [ ] **Step 2: Replace AuthView.swift**

```swift
import AuthenticationServices
import CryptoKit
import SwiftUI

struct AuthView: View {
    @EnvironmentObject private var model: AppModel
    @State private var rawNonce = ""
    @State private var errorText: String?

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Text("Sous").font(.largeTitle.bold())
            SignInWithAppleButton(.signIn) { request in
                rawNonce = Self.randomNonce()
                request.requestedScopes = [.email]
                request.nonce = Self.sha256(rawNonce)
            } onCompletion: { result in
                Task { await handle(result) }
            }
            .frame(height: 50)
            .padding(.horizontal, 40)
            if let errorText {
                Text(errorText).font(.footnote).foregroundStyle(.red)
            }
            Spacer()
        }
    }

    private func handle(_ result: Result<ASAuthorization, Error>) async {
        do {
            guard case .success(let auth) = result,
                  let credential = auth.credential as? ASAuthorizationAppleIDCredential,
                  let tokenData = credential.identityToken,
                  let idToken = String(data: tokenData, encoding: .utf8)
            else { throw URLError(.userAuthenticationRequired) }
            try await model.signInWithApple(idToken: idToken, nonce: rawNonce)
        } catch {
            errorText = "Sign-in failed: \(error.localizedDescription)"
        }
    }

    private static func randomNonce(length: Int = 32) -> String {
        let charset = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz-._")
        return String((0..<length).compactMap { _ in charset.randomElement() })
    }

    private static func sha256(_ input: String) -> String {
        SHA256.hash(data: Data(input.utf8))
            .map { String(format: "%02x", $0) }.joined()
    }
}
```

- [ ] **Step 3: Build**

```bash
cd ~/Projects/sous/ios && xcodegen generate && xcodebuild -project Sous.xcodeproj \
  -scheme Sous -destination 'platform=iOS Simulator,name=<SIM_NAME>' build
```

Expected: build succeeds. (Auth can't be exercised until it runs on a device/simulator with an Apple ID — that's Task 13's manual verification.)

- [ ] **Step 4: Commit**

```bash
cd ~/Projects/sous && git add ios/ && git commit -m "feat(ios): AppModel with Supabase auth/data/realtime + Sign in with Apple"
```

---

### Task 12: Kitchen Counter skeleton — presence header, tonight card, chat

**Files:**
- Modify: `ios/Sous/CounterView.swift` (replace stub entirely)
- Create: `ios/Sous/ChatView.swift`

**Interfaces:**
- Consumes: `AppModel` published state + `send(_:)` (Task 11), `chefIsPresent` (Task 10).
- Produces: the M1 UI. Deliberately ugly — structure only; Claude Design repaints in M3. UI copy is functional/neutral (persona copy arrives via `copy_pack` in M3).

- [ ] **Step 1: Replace CounterView.swift**

```swift
import SwiftUI

struct CounterView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            header
            tonightCard
            Divider()
            ChatView()
        }
    }

    private var header: some View {
        HStack {
            Text(model.household?.name ?? "…").font(.headline)
            Spacer()
            let present = chefIsPresent(workerSeenAt: model.household?.workerSeenAt)
            Label(present ? "chef in" : "chef out",
                  systemImage: present ? "flame.fill" : "moon.zzz")
                .font(.caption)
                .foregroundStyle(present ? .orange : .secondary)
        }
        .padding(.horizontal)
        .padding(.top, 8)
    }

    private var tonightCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Tonight").font(.caption).foregroundStyle(.secondary)
            Text(model.tonight?.dish ?? "—").font(.title2.bold())
            HStack(spacing: 8) {
                if let mode = model.tonight?.mode {
                    Text(mode).font(.caption2).padding(4)
                        .background(.quaternary, in: Capsule())
                }
                if let prep = model.tonight?.prepNote {
                    Text(prep).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .padding()
    }
}
```

- [ ] **Step 2: Create ChatView.swift**

```swift
import SwiftUI

struct ChatView: View {
    @EnvironmentObject private var model: AppModel
    @State private var draft = ""

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(model.messages) { bubble($0) }
                        if model.messages.last?.sender == "user" {
                            HStack { ProgressView(); Text("…").foregroundStyle(.secondary) }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal)
                        }
                    }
                    .padding(.vertical)
                }
                .onChange(of: model.messages.count) {
                    if let last = model.messages.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }
            inputBar
        }
    }

    private func bubble(_ msg: ChatMessage) -> some View {
        Text(msg.content)
            .padding(10)
            .background(
                msg.sender == "user" ? Color.accentColor.opacity(0.2) : Color(.secondarySystemBackground),
                in: RoundedRectangle(cornerRadius: 14)
            )
            .frame(maxWidth: .infinity,
                   alignment: msg.sender == "user" ? .trailing : .leading)
            .padding(.horizontal)
            .id(msg.id)
    }

    private var inputBar: some View {
        HStack {
            TextField("Message", text: $draft, axis: .vertical)
                .textFieldStyle(.roundedBorder)
            Button {
                let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return }
                draft = ""
                Task { await model.send(text) }
            } label: {
                Image(systemName: "arrow.up.circle.fill").font(.title2)
            }
            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding()
    }
}
```

- [ ] **Step 3: Build + run unit tests**

```bash
cd ~/Projects/sous/ios && xcodegen generate && xcodebuild -project Sous.xcodeproj \
  -scheme Sous -destination 'platform=iOS Simulator,name=<SIM_NAME>' test
```

Expected: build + 3 tests pass.

- [ ] **Step 4: Commit**

```bash
cd ~/Projects/sous && git add ios/ && git commit -m "feat(ios): kitchen counter skeleton — presence, tonight card, chat"
```

---

### Task 13: M1 exit test — real use from the phone

No new files — this is the milestone gate (spec §9/§11: verify via real use, not sandboxes-of-sandboxes). Requires Mike + his iPhone.

- [ ] **Step 1 (MANUAL — Mike): set the real team id**

Put the real `DEVELOPMENT_TEAM` in `ios/project.yml`, `xcodegen generate`, open `ios/Sous.xcodeproj` in Xcode, plug in the iPhone, select it as destination, Run. First install needs Settings → General → VPN & Device Management trust (personal team) — or TestFlight later.

- [ ] **Step 2: start the worker against cloud**

```bash
cd ~/Projects/sous/worker && uv run python -m sous_worker.main
```

- [ ] **Step 3 (MANUAL — Mike): the actual test**

On the phone: Sign in with Apple → counter shows tonight's seeded dish + "chef in" (heartbeat live) → send 「今晚吃什麼?怎麼煮?」.

**Pass criteria (all four):**
1. Reply arrives in the app via realtime (no manual refresh), in 小當家's voice.
2. The reply names the correct seeded dish for today — he *knows the sandbox week*.
3. Kill the worker → within ~60s the header flips to "chef out"; send a message → it queues (job row `queued`, no reply). Restart worker → reply arrives.
4. Ask for a change (「今晚換吃麻婆豆腐」) → he acknowledges honestly that this version can't edit yet (no fake mutations — M1 is read-only).

- [ ] **Step 4: record the result**

Append a short verification note (date, what passed, any rough edges observed for M2) to the bottom of this plan file, and commit:

```bash
cd ~/Projects/sous && git add docs/superpowers/plans/ && git commit -m "docs: M1 exit test verification notes"
```

**M1 done = all four pass criteria hold in real use.** Rough edges that don't break the criteria (slow replies, ugly UI) are M2/M3 backlog, not M1 blockers.

---

## Deferred to M2/M3 (explicitly not in this plan)

Per spec §9: `state_api.py` write verbs + live conversational edits, ritual mode, week/shopping/cookbook sheets, structured recipe steps + share-sheet intake, cook mode (M2); APNs notifications, presence copy via `copy_pack`, Claude Design token layer, onboarding interview, streaks (M3). Also deferred within M1's own scope: realtime job claiming in the worker (3s poll is fine for one household), column-level grant on `shopping_items.checked`, and the design brief `docs/design/brief.md` (parallel deliverable — write it right after this plan lands, per spec §9 design handoff).




