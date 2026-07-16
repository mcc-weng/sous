# Sous M2b1 「規劃儀式」— Ritual Mode Backend Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Port alfred's weekly planning ritual (craving deck → propose the week → 鎖定) onto Sous's job-queue worker, entirely backend — no iOS UI in this plan. Provable via direct job insertion + a real-brain smoke test.

**Architecture:** M2 was split into three sub-plans (M2a/M2b/M2c); M2b itself is split into two (M2b1 backend, M2b2 iOS sheets — this is **M2b1**). Alfred's ritual is one long-running Discord session that waits mid-conversation for touchpoint replies; Sous's worker runs one bounded `claude -p` call per job, so the multi-turn ritual is re-mapped: the app always inserts plain `chat` jobs for every message (unchanged), and the **worker** decides chat vs ritual prompt purely by checking `plan_weeks.status` — deterministic, not intent-guessing. A new `ritual` job kind exists only to bootstrap touchpoint 1. Every touchpoint reply after that rides the exact same job/chat flow already built in M2a. The 276-line alfred `plan-week` skill (the actual planning algorithm) is copied nearly verbatim into a bundled reference file the brain reads via `Read` — spec §5 already allowances "Read for bundled reference files" for exactly this purpose — with file-read/file-write instructions swapped for "already rendered above" / state_api verb calls.

Task order matters here more than in M2a: the ritual skill file and prompt (Tasks 6–7) are written *before* the worker wiring that reads them (Task 8) — `generate_ritual_reply` calls `.read_text()` on `worker/prompts/ritual.md` unconditionally (mocking `brain.run_brain` does not skip that read), so if the worker wiring landed first its own tests would hit a real `FileNotFoundError`.

**Tech Stack:** Python 3.11+ / psycopg3 / pytest (worker); Supabase Postgres (local stack for tests, cloud project `ftobrcxtbtdjgrrkavzb` for the exit check); `claude -p` headless brain, unchanged tool allowlist from M2a (`Read` + `Bash(.venv/bin/python state_api.py:*)`).

## Global Constraints

- **Writes only via `state_api.py`** — the brain never free-writes state. The one exception, consistent with M1/M2a precedent (`db.insert_chef_message`): the WORKER's own deterministic harness code (not the brain) may write the `proposing` marker row directly via `db.py`, since that's infrastructure state transition, not brain-authored content.
- **Persona discipline:** zero hardcoded persona strings in `ritual.md` or the bundled skill file — voice flows only through `{persona_pack}`.
- **Hard isolation from alfred:** read alfred's files for porting reference only; never write to `~/Projects/alfred/state/` or invoke its Discord tooling.
- **Household pinning:** every new query/verb scopes by `household_id` sourced only from `SOUS_HOUSEHOLD_ID` env (unchanged from M2a) — never a CLI arg.
- **Idempotency:** verbs must converge on retry. `set-plan` recomputes its target week deterministically (`week_monday(household_today) + 7 days`) rather than accepting a week argument from the brain, so a retry always targets the same row `ensure_proposing_week` already guaranteed exists.
- **Two-touchpoint rule** (ported from alfred, binding on the prompt content, not the code): the ritual conversation may ask at most two questions total (the craving deck, then the week proposal) — everything else must be bundled or inferred.
- **Shopping item names are English** (Woolworths-searchable) — unchanged from M2a.
- Worker tests run against the **local Supabase stack**; run tests from `worker/` with `uv run pytest`.
- Commit messages follow repo convention: `feat(worker):`, `fix(worker):`, etc.

## Pre-existing interfaces you'll touch (M1/M2a, already on main)

- `worker/sous_worker/context.py` — `week_monday(day) -> date`; `fetch_context(conn, household_id, history_limit=20, now=None) -> dict`; `build_chat_prompt(template, ctx, new_messages) -> str`; private `_render_week`, `_render_preferences`, `_render_cookbook_index`, `_render_shopping_open`, `_render_history` (all reusable).
- `worker/sous_worker/db.py` — `connect()`, `claim_next_job(conn) -> Job|None`, `complete_job`, `fail_job`, `requeue_job`, `requeue_stale`, `heartbeat`, `insert_chef_message(conn, household_id, content, job_id=None) -> str`, `get_job_household`, `get_message_content`, `get_household(conn, household_id) -> {"name","timezone","prompt_pack","copy_pack"}`.
- `worker/sous_worker/main.py` — `ROOT` = `worker/`, `load_config()`, `generate_chat_reply(conn, job, cfg) -> str` (unchanged by this plan), `process_one(conn, cfg) -> bool`, `_apologize`.
- `worker/state_api.py` — verbs `get-plan`, `update-day`, `swap-days`, `add-shopping-item`, `remove-shopping-item`, `flag-staple`, `capture-inbox`; scaffold `_parser()`, `_dispatch(conn, household_id, args)`, `main(argv=None)`, `_JSONErrorParser`, `MODES = {"batch","fast","leftover","play"}`, `STATUSES = {"planned","cooked","skipped"}`, `_household_today(conn, household_id) -> date`, `_current_week_id(conn, household_id)`.
- `worker/tests/conftest.py` — `conn` fixture (local stack, truncates `jobs, chat_messages`), `SANDBOX = "00000000-0000-0000-0000-000000000001"`, `chat_job` fixture, `TEST_DB_URL`.
- `worker/config.json` — `chat_allowed_tools: ["Read", "Bash(.venv/bin/python state_api.py:*)"]` (unchanged — ritual reuses the same allowlist, no new tool needed).
- Schema (`supabase/migrations/0001_schema.sql`): `plan_weeks(id, household_id, week_of, status text default 'locked', reasoning, created_at)`; `plan_days(id, week_id, household_id, date, dish, recipe_id, mode, prep_note, nutrition, reasoning, status default 'planned')`, unique `(household_id, date)`; `shopping_items(id, household_id, week_id, name, qty, section, checked default false, recipe_refs, created_at)`; `staples(id, household_id, name, flagged_low default false)`, unique `(household_id, name)`; `inbox_items(id, household_id, kind, content, created_at)`; `verdicts(id, household_id, plan_day_id, rating, note, created_at)`.

---

### Task 1: Migration — `plan_weeks.status` CHECK constraint

Today `plan_weeks.status` is a bare `text default 'locked'` with no enforcement. This plan introduces a second value (`'proposing'`) as the routing signal between chat and ritual mode — worth a CHECK constraint now, matching the precedent set by `jobs.status`.

**Files:**
- Create: `supabase/migrations/0004_plan_weeks_status_check.sql`

**Interfaces:**
- Produces: `plan_weeks.status` now constrained to `('proposing', 'locked')`.

- [ ] **Step 1: Write the migration**

```sql
-- plan_weeks.status gains an enforced value set: 'proposing' (ritual mid-flow,
-- the routing signal between chat.md and ritual.md prompts) and 'locked'
-- (finalized week, unchanged default from M1). No existing row can violate
-- this — every row written so far (M1/M2a seeds, real use) used 'locked'.
alter table plan_weeks
  add constraint plan_weeks_status_check check (status in ('proposing', 'locked'));
```

- [ ] **Step 2: Apply to local stack and verify**

Run: `cd /Users/mikeweng/Projects/sous && supabase db reset 2>&1 | tail -15`
Expected: migration applies cleanly (no existing seeded row violates the constraint — the seed sets `status='locked'` explicitly).

- [ ] **Step 3: Commit**

```bash
git add supabase/migrations/0004_plan_weeks_status_check.sql
git commit -m "feat(db): constrain plan_weeks.status to proposing/locked"
```

---

### Task 2: `context.py` — ritual context rendering

**Files:**
- Modify: `worker/sous_worker/context.py`
- Test: `worker/tests/test_context.py`

**Interfaces:**
- Consumes: `week_monday`, `db.get_household`, private renderers already in the file (`_render_week`, `_render_preferences`, `_render_cookbook_index`, `_render_history`).
- Produces (new, public unless noted): `fetch_ritual_context(conn, household_id, history_limit=20, now=None) -> dict` — keys `household`, `now`, `target_week_of` (date), `current_week_plan`, `recent_weeks`, `inbox`, `verdicts_recent`, `staples_flagged`, `preferences`, `cookbook_index`, `history`. `build_ritual_prompt(template, ctx, new_messages) -> str`. Private: `_render_recent_weeks(conn, household_id, before, weeks_back=4)`, `_render_inbox(conn, household_id)`, `_render_verdicts_recent(conn, household_id, limit=15)`, `_render_staples_flagged(conn, household_id)`.

- [ ] **Step 1: Write the failing tests**

Append to `worker/tests/test_context.py` (the file already imports `context` and `SANDBOX` from `tests.conftest` — reuse those):

```python
def test_fetch_ritual_context_targets_next_week(conn):
    fixed = datetime.datetime(2026, 7, 14, 9, 0, tzinfo=ZoneInfo("Australia/Sydney"))  # a Tuesday
    ctx = context.fetch_ritual_context(conn, SANDBOX, now=fixed)
    assert ctx["target_week_of"] == datetime.date(2026, 7, 20)  # the following Monday
    assert ctx["now"] is fixed


def test_render_recent_weeks_shows_history_before_target(conn):
    conn.execute(
        "insert into plan_weeks (household_id, week_of, status) "
        "values (%s, '2026-06-22', 'locked') returning id", (SANDBOX,),
    )
    wid = conn.execute(
        "select id from plan_weeks where household_id=%s and week_of='2026-06-22'",
        (SANDBOX,),
    ).fetchone()[0]
    conn.execute(
        "insert into plan_days (week_id, household_id, date, dish, mode) "
        "values (%s, %s, '2026-06-23', '歷史測試菜', 'fast')", (wid, SANDBOX),
    )
    try:
        rendered = context._render_recent_weeks(conn, SANDBOX, datetime.date(2026, 7, 20))
        assert "歷史測試菜" in rendered
        assert "2026-06-23" in rendered
    finally:
        conn.execute("delete from plan_weeks where id = %s", (wid,))


def test_render_recent_weeks_excludes_older_than_window(conn):
    rendered = context._render_recent_weeks(
        conn, SANDBOX, datetime.date(2026, 7, 20), weeks_back=4,
    )
    # anything before 2026-06-22 (4 weeks back from 2026-07-20) must not appear —
    # no seeded data exists that old, so this just asserts the function runs
    # cleanly over an empty/partial window without error.
    assert isinstance(rendered, str)


def test_render_inbox_lists_kind_and_content(conn):
    conn.execute(
        "insert into inbox_items (household_id, kind, content) "
        "values (%s, 'craving', '想吃泰式')", (SANDBOX,),
    )
    try:
        rendered = context._render_inbox(conn, SANDBOX)
        assert "craving" in rendered
        assert "想吃泰式" in rendered
    finally:
        conn.execute(
            "delete from inbox_items where household_id=%s and content='想吃泰式'",
            (SANDBOX,),
        )


def test_render_inbox_empty_is_honest(conn):
    conn.execute("delete from inbox_items where household_id=%s", (SANDBOX,))
    rendered = context._render_inbox(conn, SANDBOX)
    assert "空" in rendered


def test_render_verdicts_recent_joins_dish_name(conn):
    pd_id = conn.execute(
        "select id from plan_days where household_id=%s limit 1", (SANDBOX,),
    ).fetchone()[0]
    conn.execute(
        "insert into verdicts (household_id, plan_day_id, rating, note) "
        "values (%s, %s, '神作', '超好吃')", (SANDBOX, pd_id),
    )
    try:
        rendered = context._render_verdicts_recent(conn, SANDBOX)
        assert "神作" in rendered
        assert "超好吃" in rendered
    finally:
        conn.execute(
            "delete from verdicts where household_id=%s and note='超好吃'", (SANDBOX,),
        )


def test_render_staples_flagged_only_shows_low(conn):
    conn.execute(
        "insert into staples (household_id, name, flagged_low) "
        "values (%s, '測試常備品', true) on conflict (household_id, name) "
        "do update set flagged_low=true", (SANDBOX,),
    )
    try:
        rendered = context._render_staples_flagged(conn, SANDBOX)
        assert "測試常備品" in rendered
        assert "醬油" not in rendered  # seeded staple, not flagged low
    finally:
        conn.execute(
            "delete from staples where household_id=%s and name='測試常備品'", (SANDBOX,),
        )


def test_build_ritual_prompt_substitutes_everything(conn):
    template = (
        "{persona_pack}\n{today}\n{weekday}\n{target_week_of}\n{current_week_plan}\n"
        "{recent_weeks}\n{inbox}\n{verdicts_recent}\n{staples_flagged}\n"
        "{preferences}\n{cookbook_index}\n{history}\n{messages}"
    )
    ctx = context.fetch_ritual_context(conn, SANDBOX)
    prompt = context.build_ritual_prompt(template, ctx, "user: 開始本週儀式")
    assert "開始本週儀式" in prompt
    assert "{" not in prompt.replace("{}", "")
```

Add the needed imports at the top of `test_context.py` if not already present (the file already has `datetime` and `ZoneInfo` from Task 1 of M2a):

```python
# (datetime, ZoneInfo, context, SANDBOX already imported by M2a's Task 1 tests)
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `uv run pytest tests/test_context.py -v -k "ritual or recent_weeks or render_inbox or render_verdicts or render_staples"`
Expected: FAIL with `AttributeError: module 'sous_worker.context' has no attribute 'fetch_ritual_context'` (and similar for the other new names).

- [ ] **Step 3: Implement**

Add to `worker/sous_worker/context.py`, after the existing `_render_history` function:

```python
def _render_recent_weeks(conn, household_id: str, before: datetime.date,
                         weeks_back: int = 4) -> str:
    since = before - datetime.timedelta(weeks=weeks_back)
    rows = conn.execute(
        "select date, dish, mode, status from plan_days "
        "where household_id = %s and date >= %s and date < %s order by date",
        (household_id, since, before),
    ).fetchall()
    if not rows:
        return "(近期沒有排菜紀錄)"
    lines = []
    for date, dish, mode, status in rows:
        parts = [date.isoformat(), dish, mode]
        if status != "planned":
            parts.append(status)
        lines.append(" · ".join(parts))
    return "\n".join(lines)


def _render_inbox(conn, household_id: str) -> str:
    rows = conn.execute(
        "select kind, content from inbox_items where household_id = %s "
        "order by created_at", (household_id,),
    ).fetchall()
    return "\n".join(f"[{k}] {c}" for k, c in rows) or "(收件匣是空的)"


def _render_verdicts_recent(conn, household_id: str, limit: int = 15) -> str:
    rows = conn.execute(
        "select pd.date, pd.dish, v.rating, v.note from verdicts v "
        "join plan_days pd on pd.id = v.plan_day_id "
        "where v.household_id = %s order by v.created_at desc limit %s",
        (household_id, limit),
    ).fetchall()
    lines = []
    for date, dish, rating, note in rows:
        line = f"{date.isoformat()} · {dish} · {rating}"
        if note:
            line += f"({note})"
        lines.append(line)
    return "\n".join(lines) or "(還沒有評價紀錄)"


def _render_staples_flagged(conn, household_id: str) -> str:
    rows = conn.execute(
        "select name from staples where household_id = %s and flagged_low = true "
        "order by name", (household_id,),
    ).fetchall()
    return "\n".join(f"- {n}" for (n,) in rows) or "(沒有常備品快用完)"


def fetch_ritual_context(conn, household_id: str, history_limit: int = 20,
                         now: datetime.datetime | None = None) -> dict:
    household = db.get_household(conn, household_id)
    if now is None:
        now = datetime.datetime.now(ZoneInfo(household["timezone"]))
    target_week_of = week_monday(now.date()) + datetime.timedelta(weeks=1)
    return {
        "household": household,
        "now": now,
        "target_week_of": target_week_of,
        "current_week_plan": _render_week(conn, household_id, week_monday(now.date())),
        "recent_weeks": _render_recent_weeks(conn, household_id, target_week_of),
        "inbox": _render_inbox(conn, household_id),
        "verdicts_recent": _render_verdicts_recent(conn, household_id),
        "staples_flagged": _render_staples_flagged(conn, household_id),
        "preferences": _render_preferences(conn, household_id),
        "cookbook_index": _render_cookbook_index(conn, household_id),
        "history": _render_history(conn, household_id, history_limit),
    }


def build_ritual_prompt(template: str, ctx: dict, new_messages: str) -> str:
    now = ctx["now"]
    return (
        template
        .replace("{persona_pack}", ctx["household"]["prompt_pack"])
        .replace("{today}", now.strftime("%Y-%m-%d"))
        .replace("{weekday}", _WEEKDAYS_ZH[now.weekday()])
        .replace("{target_week_of}", ctx["target_week_of"].isoformat())
        .replace("{current_week_plan}", ctx["current_week_plan"])
        .replace("{recent_weeks}", ctx["recent_weeks"])
        .replace("{inbox}", ctx["inbox"])
        .replace("{verdicts_recent}", ctx["verdicts_recent"])
        .replace("{staples_flagged}", ctx["staples_flagged"])
        .replace("{preferences}", ctx["preferences"])
        .replace("{cookbook_index}", ctx["cookbook_index"])
        .replace("{history}", ctx["history"])
        .replace("{messages}", new_messages)
    )
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `uv run pytest tests/test_context.py -v` — all PASS (existing chat-context tests plus the new ritual ones).

- [ ] **Step 5: Commit**

```bash
git add worker/sous_worker/context.py worker/tests/test_context.py
git commit -m "feat(worker): ritual context rendering — inbox/verdicts/staples/recent-weeks"
```

---

### Task 3: `db.py` — ritual routing helpers

**Files:**
- Modify: `worker/sous_worker/db.py`
- Test: `worker/tests/test_db.py`

**Interfaces:**
- Consumes: nothing new (plain psycopg queries, same pattern as existing `db.py` functions).
- Produces: `ensure_proposing_week(conn, household_id: str, week_of: datetime.date) -> str` (returns `plan_weeks.id`; idempotent create-if-absent, never downgrades an existing `'locked'` row back to `'proposing'`). `get_proposing_week(conn, household_id: str) -> dict | None` (returns `{"id": ..., "week_of": ...}` for the household's `'proposing'` row, or `None`).

- [ ] **Step 1: Write the failing tests**

Append to `worker/tests/test_db.py` (check the file's existing imports first — it already imports `db` and uses `SANDBOX`/`conn` from conftest):

```python
import datetime


def test_ensure_proposing_week_creates_when_absent(conn):
    target = datetime.date(2026, 8, 3)  # a Monday, far from any seeded week
    week_id = db.ensure_proposing_week(conn, SANDBOX, target)
    row = conn.execute(
        "select status, week_of from plan_weeks where id = %s", (week_id,),
    ).fetchone()
    try:
        assert row == ("proposing", target)
    finally:
        conn.execute("delete from plan_weeks where id = %s", (week_id,))


def test_ensure_proposing_week_is_idempotent(conn):
    target = datetime.date(2026, 8, 10)
    first = db.ensure_proposing_week(conn, SANDBOX, target)
    second = db.ensure_proposing_week(conn, SANDBOX, target)
    try:
        assert first == second
        count = conn.execute(
            "select count(*) from plan_weeks where household_id=%s and week_of=%s",
            (SANDBOX, target),
        ).fetchone()[0]
        assert count == 1
    finally:
        conn.execute("delete from plan_weeks where id = %s", (first,))


def test_ensure_proposing_week_never_downgrades_locked(conn):
    target = datetime.date(2026, 8, 17)
    week_id = conn.execute(
        "insert into plan_weeks (household_id, week_of, status) "
        "values (%s, %s, 'locked') returning id", (SANDBOX, target),
    ).fetchone()[0]
    try:
        returned_id = db.ensure_proposing_week(conn, SANDBOX, target)
        status = conn.execute(
            "select status from plan_weeks where id = %s", (week_id,),
        ).fetchone()[0]
        assert returned_id == week_id
        assert status == "locked"
    finally:
        conn.execute("delete from plan_weeks where id = %s", (week_id,))


def test_get_proposing_week_returns_none_when_absent(conn):
    conn.execute(
        "delete from plan_weeks where household_id=%s and status='proposing'",
        (SANDBOX,),
    )
    assert db.get_proposing_week(conn, SANDBOX) is None


def test_get_proposing_week_returns_the_row(conn):
    target = datetime.date(2026, 8, 24)
    week_id = db.ensure_proposing_week(conn, SANDBOX, target)
    try:
        found = db.get_proposing_week(conn, SANDBOX)
        assert found == {"id": week_id, "week_of": target}
    finally:
        conn.execute("delete from plan_weeks where id = %s", (week_id,))
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `uv run pytest tests/test_db.py -v -k "proposing"`
Expected: FAIL with `AttributeError: module 'sous_worker.db' has no attribute 'ensure_proposing_week'`.

- [ ] **Step 3: Implement**

Add to `worker/sous_worker/db.py`, after `get_household`:

```python
def ensure_proposing_week(conn, household_id: str, week_of) -> str:
    """Idempotent create-if-absent. Never touches a row that already exists —
    in particular never downgrades an already-'locked' week back to
    'proposing', so re-triggering a ritual for an already-planned week is
    safe (the brain sees the existing plan via current/recent-weeks context
    and can decide to re-propose honestly rather than silently reopening it)."""
    row = conn.execute(
        "select id::text from plan_weeks where household_id = %s and week_of = %s",
        (household_id, week_of),
    ).fetchone()
    if row:
        return row[0]
    row = conn.execute(
        "insert into plan_weeks (household_id, week_of, status) "
        "values (%s, %s, 'proposing') returning id::text",
        (household_id, week_of),
    ).fetchone()
    return row[0]


def get_proposing_week(conn, household_id: str) -> dict | None:
    row = conn.execute(
        "select id::text, week_of from plan_weeks "
        "where household_id = %s and status = 'proposing' "
        "order by week_of desc limit 1",
        (household_id,),
    ).fetchone()
    return {"id": row[0], "week_of": row[1]} if row else None
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `uv run pytest tests/test_db.py -v` — all PASS.

- [ ] **Step 5: Commit**

```bash
git add worker/sous_worker/db.py worker/tests/test_db.py
git commit -m "feat(worker): ritual routing helpers — ensure/get proposing week"
```

---

### Task 4: `state_api.py` — `set-plan` verb

The lock step: writes the full week's `plan_days` + `shopping_items`, flips `plan_weeks.status` to `'locked'`. Takes no week-date argument from the brain — it recomputes the same deterministic target (`week_monday(household_today) + 7 days`) that `ensure_proposing_week` already used, so a retry always finds the same row.

**Files:**
- Modify: `worker/state_api.py`
- Test: `worker/tests/test_state_api.py`

**Interfaces:**
- Consumes: `week_monday` (already imported), `MODES`, `_household_today`, `_parser`/`_dispatch` scaffold.
- Produces: `set_plan(conn, household_id: str, days: list[dict], shopping_items: list[dict], reasoning: str | None = None) -> dict` — `days` entries: `{"date": "YYYY-MM-DD", "dish": str, "mode"?: str (default "fast"), "prep_note"?: str, "reasoning"?: str}`, exactly 7 entries covering the target week's 7 dates, no gaps/duplicates. `shopping_items` entries: `{"name": str, "qty"?: str, "section"?: str}`. Returns `{"ok": True, "week_of": date, "days": 7, "shopping_items": N}`.

- [ ] **Step 1: Write the failing tests**

Append to `worker/tests/test_state_api.py` (reuse the `api_hid` fixture and `_run_cli` helper already defined in the file from M2a Tasks 2-4; also import `json` if not already at module scope — the file already imports `json`):

```python
def _week_of(monday: datetime.date, offset: int) -> str:
    return (monday + datetime.timedelta(days=offset)).isoformat()


def _next_monday_for(household_today: datetime.date) -> datetime.date:
    return week_monday(household_today) + datetime.timedelta(days=7)


def test_set_plan_writes_full_week_and_locks(conn, api_hid):
    target = _next_monday_for(datetime.date.today())
    wid = state_api._ensure_proposing_week_for_test(conn, api_hid, target)
    days = [
        {"date": _week_of(target, i), "dish": f"測試菜{i}", "mode": "fast"}
        for i in range(7)
    ]
    shopping = [{"name": "soy sauce", "qty": "1 bottle", "section": "pantry"}]
    out = state_api.set_plan(conn, api_hid, days, shopping, reasoning="測試摘要")
    assert out == {"ok": True, "week_of": target, "days": 7, "shopping_items": 1}
    status, reasoning = conn.execute(
        "select status, reasoning from plan_weeks where id = %s", (wid,),
    ).fetchone()
    assert status == "locked" and reasoning == "測試摘要"
    written = conn.execute(
        "select date, dish, mode from plan_days where week_id = %s order by date",
        (wid,),
    ).fetchall()
    assert len(written) == 7
    assert written[0] == (target, "測試菜0", "fast")
    shopping_rows = conn.execute(
        "select name, qty, section from shopping_items where week_id = %s", (wid,),
    ).fetchall()
    assert shopping_rows == [("soy sauce", "1 bottle", "pantry")]


def test_set_plan_requires_exactly_seven_days(conn, api_hid):
    target = _next_monday_for(datetime.date.today())
    state_api._ensure_proposing_week_for_test(conn, api_hid, target)
    days = [{"date": _week_of(target, 0), "dish": "測試菜"}]
    with pytest.raises(ValueError, match="7"):
        state_api.set_plan(conn, api_hid, days, [])


def test_set_plan_rejects_date_outside_target_week(conn, api_hid):
    target = _next_monday_for(datetime.date.today())
    state_api._ensure_proposing_week_for_test(conn, api_hid, target)
    days = [
        {"date": _week_of(target, i), "dish": f"測試菜{i}"} for i in range(6)
    ] + [{"date": _week_of(target, 30), "dish": "越界菜"}]
    with pytest.raises(ValueError, match="outside"):
        state_api.set_plan(conn, api_hid, days, [])


def test_set_plan_rejects_no_active_ritual(conn, api_hid):
    conn.execute(
        "delete from plan_weeks where household_id=%s and status='proposing'",
        (api_hid,),
    )
    target = _next_monday_for(datetime.date.today())
    days = [{"date": _week_of(target, i), "dish": f"測試菜{i}"} for i in range(7)]
    with pytest.raises(ValueError, match="no active ritual"):
        state_api.set_plan(conn, api_hid, days, [])


def test_set_plan_replaces_shopping_items_not_accumulates(conn, api_hid):
    target = _next_monday_for(datetime.date.today())
    wid = state_api._ensure_proposing_week_for_test(conn, api_hid, target)
    days = [{"date": _week_of(target, i), "dish": f"測試菜{i}"} for i in range(7)]
    state_api.set_plan(conn, api_hid, days, [{"name": "item-a"}])
    # a second lock call (retry) must not leave item-a AND item-b both present
    conn.execute(
        "update plan_weeks set status='proposing' where id=%s", (wid,),
    )  # simulate a retry re-entering lock with a revised shopping list
    state_api.set_plan(conn, api_hid, days, [{"name": "item-b"}])
    names = {n for (n,) in conn.execute(
        "select name from shopping_items where week_id=%s", (wid,)
    ).fetchall()}
    assert names == {"item-b"}


def test_cli_set_plan(api_hid):
    target = _next_monday_for(datetime.date.today())
    import psycopg
    with psycopg.connect(TEST_DB_URL, autocommit=True) as c:
        state_api._ensure_proposing_week_for_test(c, api_hid, target)
    days_json = json.dumps([
        {"date": _week_of(target, i), "dish": f"CLI測試菜{i}"} for i in range(7)
    ])
    proc = _run_cli(
        ["set-plan", "--days", days_json, "--shopping-items", "[]",
         "--reasoning", "CLI 測試"],
        api_hid,
    )
    assert proc.returncode == 0, proc.stderr
    out = json.loads(proc.stdout)
    assert out["ok"] is True and out["days"] == 7
```

Add one small test-only helper the tests above call — this is NOT part of the public verb surface, just a thin wrapper so tests don't duplicate `ensure_proposing_week`'s insert SQL. Add it to `worker/state_api.py` itself, clearly marked as test-only (mirrors the pattern of small internal helpers already in the file):

```python
def _ensure_proposing_week_for_test(conn, household_id: str, week_of) -> str:
    """Test-only helper — production code creates this row via
    sous_worker.db.ensure_proposing_week from main.py, not from here."""
    row = conn.execute(
        "select id::text from plan_weeks where household_id=%s and week_of=%s",
        (household_id, week_of),
    ).fetchone()
    if row:
        return row[0]
    return conn.execute(
        "insert into plan_weeks (household_id, week_of, status) "
        "values (%s, %s, 'proposing') returning id::text",
        (household_id, week_of),
    ).fetchone()[0]
```

Also add the needed imports at the top of `test_state_api.py` if missing: `from sous_worker.context import week_monday` is already imported (M2a Task 2); `import state_api` is already present too.

- [ ] **Step 2: Run tests to verify they fail**

Run: `uv run pytest tests/test_state_api.py -v -k "set_plan"`
Expected: FAIL with `AttributeError: module 'state_api' has no attribute 'set_plan'` (and `_ensure_proposing_week_for_test`).

- [ ] **Step 3: Implement**

Add to `worker/state_api.py`, after `capture_inbox`:

```python
def set_plan(conn, household_id: str, days: list, shopping_items: list,
            reasoning: str | None = None) -> dict:
    target = week_monday(_household_today(conn, household_id)) + datetime.timedelta(days=7)
    week_row = conn.execute(
        "select id from plan_weeks where household_id = %s and week_of = %s",
        (household_id, target),
    ).fetchone()
    if week_row is None:
        raise ValueError("no active ritual for next week — start the ritual first")
    week_id = week_row[0]
    if len(days) != 7:
        raise ValueError("days must have exactly 7 entries")
    seen_dates = set()
    parsed = []
    for d in days:
        date = datetime.date.fromisoformat(d["date"])
        if not (target <= date <= target + datetime.timedelta(days=6)):
            raise ValueError(f"date {date} is outside the target week {target}")
        if date in seen_dates:
            raise ValueError(f"duplicate date {date}")
        seen_dates.add(date)
        mode = d.get("mode", "fast")
        if mode not in MODES:
            raise ValueError(f"mode must be one of {sorted(MODES)}")
        parsed.append((date, d["dish"], mode, d.get("prep_note"), d.get("reasoning")))
    for date, dish, mode, prep_note, day_reasoning in parsed:
        conn.execute(
            "insert into plan_days (week_id, household_id, date, dish, mode, "
            "prep_note, reasoning) values (%s, %s, %s, %s, %s, %s, %s) "
            "on conflict (household_id, date) do update set "
            "week_id = excluded.week_id, dish = excluded.dish, mode = excluded.mode, "
            "prep_note = excluded.prep_note, reasoning = excluded.reasoning",
            (week_id, household_id, date, dish, mode, prep_note, day_reasoning),
        )
    conn.execute("delete from shopping_items where week_id = %s", (week_id,))
    for item in shopping_items:
        conn.execute(
            "insert into shopping_items (household_id, week_id, name, qty, section) "
            "values (%s, %s, %s, %s, %s)",
            (household_id, week_id, item["name"], item.get("qty"), item.get("section")),
        )
    conn.execute(
        "update plan_weeks set status = 'locked', reasoning = %s where id = %s",
        (reasoning, week_id),
    )
    return {"ok": True, "week_of": target, "days": len(parsed),
            "shopping_items": len(shopping_items)}
```

In `_parser()`, add after the `capture-inbox` subparser block:

```python
    sp = sub.add_parser("set-plan")
    sp.add_argument("--days", required=True,
                    help='JSON array: [{"date","dish","mode"?,"prep_note"?,"reasoning"?}, ...] — exactly 7 entries')
    sp.add_argument("--shopping-items", dest="shopping_items", default="[]",
                    help='JSON array: [{"name","qty"?,"section"?}, ...]')
    sp.add_argument("--reasoning")
```

In `_dispatch()`, add after the `capture-inbox` branch:

```python
    if args.verb == "set-plan":
        try:
            days = json.loads(args.days)
            shopping_items = json.loads(args.shopping_items)
        except json.JSONDecodeError as exc:
            raise ValueError(f"invalid JSON in --days or --shopping-items: {exc}") from None
        return set_plan(conn, household_id, days, shopping_items,
                        reasoning=args.reasoning)
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `uv run pytest tests/test_state_api.py -v` — all PASS.

- [ ] **Step 5: Commit**

```bash
git add worker/state_api.py worker/tests/test_state_api.py
git commit -m "feat(worker): state_api set-plan verb — locks the ritual's proposed week"
```

---

### Task 5: `state_api.py` — `clear-inbox` verb

**Files:**
- Modify: `worker/state_api.py`
- Test: `worker/tests/test_state_api.py`

**Interfaces:**
- Consumes: `_parser`/`_dispatch` scaffold.
- Produces: `clear_inbox(conn, household_id: str) -> dict` — deletes all `inbox_items` for the household (alfred's ritual Step 8 clears the inbox only after state commits; the brain is instructed to call this immediately after a successful `set-plan`). Returns `{"ok": True, "removed": N}`.

- [ ] **Step 1: Write the failing tests**

Append to `worker/tests/test_state_api.py`:

```python
def test_clear_inbox_removes_all_for_household(conn, api_hid):
    conn.execute(
        "insert into inbox_items (household_id, kind, content) values "
        "(%s, 'craving', '想吃泰式'), (%s, 'feedback', '上次太鹹')",
        (api_hid, api_hid),
    )
    out = state_api.clear_inbox(conn, api_hid)
    assert out == {"ok": True, "removed": 2}
    remaining = conn.execute(
        "select count(*) from inbox_items where household_id=%s", (api_hid,),
    ).fetchone()[0]
    assert remaining == 0


def test_clear_inbox_is_idempotent(conn, api_hid):
    first = state_api.clear_inbox(conn, api_hid)
    second = state_api.clear_inbox(conn, api_hid)
    assert second["removed"] == 0
    assert first["ok"] is True and second["ok"] is True


def test_clear_inbox_scopes_to_household(conn, api_hid):
    from tests.conftest import SANDBOX
    conn.execute(
        "insert into inbox_items (household_id, kind, content) "
        "values (%s, 'note', '不要清掉這個')", (SANDBOX,),
    )
    try:
        state_api.clear_inbox(conn, api_hid)
        row = conn.execute(
            "select content from inbox_items where household_id=%s and content='不要清掉這個'",
            (SANDBOX,),
        ).fetchone()
        assert row is not None
    finally:
        conn.execute(
            "delete from inbox_items where household_id=%s and content='不要清掉這個'",
            (SANDBOX,),
        )


def test_cli_clear_inbox(api_hid):
    proc = _run_cli(["clear-inbox"], api_hid)
    assert proc.returncode == 0, proc.stderr
    assert json.loads(proc.stdout)["ok"] is True
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `uv run pytest tests/test_state_api.py -v -k "clear_inbox"`
Expected: FAIL with `AttributeError: module 'state_api' has no attribute 'clear_inbox'`.

- [ ] **Step 3: Implement**

Add to `worker/state_api.py`, after `set_plan`:

```python
def clear_inbox(conn, household_id: str) -> dict:
    removed = conn.execute(
        "delete from inbox_items where household_id = %s returning id",
        (household_id,),
    ).fetchall()
    return {"ok": True, "removed": len(removed)}
```

In `_parser()`, add:

```python
    sub.add_parser("clear-inbox")
```

In `_dispatch()`, add:

```python
    if args.verb == "clear-inbox":
        return clear_inbox(conn, household_id)
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `uv run pytest tests/test_state_api.py -v` — all PASS.

- [ ] **Step 5: Commit**

```bash
git add worker/state_api.py worker/tests/test_state_api.py
git commit -m "feat(worker): state_api clear-inbox verb"
```

---

### Task 6: `worker/skills/plan-week.md` — ported planning algorithm

The actual planning wisdom (craving-deck composition, nutrition rules, recipe/shopping-list format) copied from alfred's `.claude/skills/plan-week/SKILL.md`, adapted: file-read instructions become "already rendered above in your context"; file-write/Discord-post instructions become state_api verb calls; alfred-specific auxiliary systems with no Sous schema equivalent (`state/skills.md` curriculum, `state/lessons.md` kitchen-quirks, `state/breakfasts.md` rotation) are dropped — flagged explicitly in this file as a deliberate scope reduction, not a silent omission, and noted in this plan's Deferred section at the end.

This task is sequenced *before* the worker wiring (Task 8) deliberately — Task 8's `generate_ritual_reply` reads `worker/prompts/ritual.md` (Task 7) unconditionally, and Task 7 in turn references this skill file, so both content files must exist first.

**Files:**
- Create: `worker/skills/plan-week.md`

**Interfaces:**
- Consumes: nothing (pure content file).
- Produces: a bundled reference file `worker/prompts/ritual.md` (Task 7) tells the brain to `Read` via its already-allowlisted `Read` tool.

- [ ] **Step 1: Write the file**

Create `worker/skills/plan-week.md`:

```markdown
# 排菜週規劃 — 完整流程

這份文件是規劃儀式的核心邏輯,從 alfred 系統移植過來。你的角色狀態(語氣、口吻)
由 persona pack 決定;這裡只講排菜的方法。

## 兩個問題的規則(硬性)

整個儀式最多問兩個問題:Step 2(菜色卡牌)一次、Step 3(提案整週)一次。除此之外
一律自己判斷、自己補,不要多問。過敏資訊若還不知道,附加在卡牌那則訊息裡問,
不要另外花一個提問額度。

## Step 1:已經渲染好的狀態(不用再查)

你的 context 裡已經有:本週菜單(current_week_plan)、近 4 週排菜歷史
(recent_weeks,用來判斷「banger 該重出江湖了」或「這道兩週內煮過先跳過」)、
收件匣(inbox,裡面混著 craving/feedback/note,先分類消化)、最近評價
(verdicts_recent,神作/不錯/普通/翻車)、常備品快用完清單(staples_flagged,
下週清單要記得補)、家庭偏好(preferences,過敏是硬限制,不喜歡除非對方明說
「這次想吃」否則避開)、食譜庫索引(cookbook_index)、最近對話(history)。

先讀 verdicts_recent:翻車的菜這輪別排;神作的菜若 recent_weeks 裡最近 4 週
沒出現過,列為候選 banger。

## Step 2:菜色卡牌(觸點 1)

不要問「冰箱有什麼」— 先丟 8 道候選菜避免對方腦袋一片空白:
- 🔁 banger ×2:cookbook 裡神作、近 4 週沒煮過的菜
- 💭 craving ×最多 2:inbox 裡這週的想吃清單
- ✨ new ×3:還沒煮過、符合偏好、蛋白質不錯的菜
- 🥋 挑戰 ×1:比目前技巧再進一步的 play 模式菜(沒有技巧曲線資料時,挑一道
  比較有挑戰性、但仍在偏好範圍內的菜代替)

不足額的 fallback:0 個 craving → 補 1 banger + 1 new;1 個 craving → 補 1 new;
歷史太薄(recent_weeks 幾乎是空的)→ 全部用 new + 挑戰填滿,誠實說「資料還不夠,
先這樣試試」。

硬規則:過敏原一律不上卡;不喜歡的除非對方這次明講要吃;兩週內煮過的不上卡
(除非是對方點名要的 banger)。

卡片格式(逐項條列,不要用表格):
`{n}. {bucket emoji} {菜名} · {mode} · ~{分鐘}分 · ~{蛋白質}P/{熱量}kcal — {一句話 hook}`

貼出卡牌後就停(這是觸點 1)。若過敏資訊還不知道,附加問在同一則訊息。
對方會用類似「1 4 6 想吃 · 3 不要 · 還有雞胸要用掉」的方式回覆 — 撿的、
不要的、順手提到的庫存都可能出現在同一句裡,自己解析。庫存資訊只用在這次
規劃,不要另外記錄。

## Step 3:提案整週(觸點 2)

先用卡牌被選中的菜當骨幹,其餘晚餐從常備/輪替/候選裡補,維持高蛋白路線。
預設 6 天晚餐(「這週想少排幾天說一聲」— 天數本身不算另一個提問)。

每一天是一組:1 主菜(卡牌選出) + 1 簡單配菜 + 至少 4 晚有湯(配菜/湯必須
≤10 分鐘或不用顧火,絕對不能變成第二個主菜)。

每日格式:`主菜 · mode(fast/batch/play) · ~分鐘 · 配菜 · 湯(如果有排) · 一句話原因`
(用掉什麼食材 / 誰的 craving / 蛋白質怎麼補 / 教什麼技巧)。

預設一週組合:3 fast + 1 batch + 2 play。營養規則:**每餐(主菜+配菜+湯合計)
蛋白質 ≥50g**— 主菜不夠就讓湯或配菜補(蛋花湯、豆腐、切肉片)。play 菜要
講清楚在教哪個具體技巧。

整週一次提案完,對方可以微調(「週三換一道」「週五不要辣」),微調完畢、
對方說「鎖定」類的話(鎖定/lock/可以/就這樣)才進入 Step 4。微調期間直接用
`update-day`/`swap-days` 這類既有 verb 調整,不需要重新整週提案(除非對方要求
重新來過)。

## Step 4:鎖定

對方確認後:
1. 把最終 7 天的資料(含週末,週末可以是「外食」這種輕鬆選項)組成
   `set-plan` 的 `--days` JSON,呼叫:
   ```
   .venv/bin/python state_api.py set-plan \
     --days '[{"date":"2026-07-20","dish":"三杯雞","mode":"fast","prep_note":"雞腿前一晚醃"}, ...共 7 筆...]' \
     --shopping-items '[{"name":"chicken thigh fillets","qty":"4","section":"meat"}, ...]' \
     --reasoning "這週摘要:三個 fast、一個 batch、兩個 play,主打清冰箱的雞胸跟...”
   ```
   `--days` 一定要剛好 7 筆,涵蓋目標週的週一到週日,每天都要有 dish(哪怕是
   「外食」)。`--shopping-items` 名稱一律英文(Woolworths 真實品名),依照
   Produce/Meat & seafood/Dairy & fridge/Pantry/Breakfast 分類到 `section`。
   ingredient 要涵蓋每道菜的配菜/湯,不只是主菜;常備品(staples,非
   staples_flagged 標記快用完的)不用列進清單。
2. `set-plan` 回傳 `"ok": true` 才算鎖定成功。
3. 立刻呼叫 `.venv/bin/python state_api.py clear-inbox` 清空收件匣(這週的
   craving/feedback 已經處理進這份計畫了)。
4. 用一則訊息收尾:本週摘要(逐日一行:菜名 + mode + 分鐘 + 蛋白質/熱量)、
   提醒「記得去採買」、大方向的 shopping list 重點(不用整份都列,對方可以在
   採買清單看完整版)。

## 食譜與採買清單細節

- 食譜寫給新手:每個步驟要有時間 + 感官線索(看/聽/聞什麼)+ 一句話原因。
  加熱步驟一定要講火力(大火/中大火/中火/中小火/小火 — 不要只寫「熱鍋」)。
- 採買清單:同一項目只列一次;每項後面用 `→ {用途}` 標明用在哪道菜,共用給
  4 道以上就寫 `→ 多道菜`。早餐食材獨立分組,不要散落進其他分類,並且要跟
  常備品/晚餐已列項目去重。

## 誠實原則

歷史資料薄(recent_weeks 幾乎空、cookbook 只有幾道菜)就照實說「食譜庫還不多,
先從這幾道開始」,不要假裝有更多選擇。過敏原絕對不上卡、不入選,即使對方在
卡牌回覆裡明確點名也要婉拒並說明原因。

## 這個版本還沒有的(誠實回答,不要假裝)

技巧曲線(state/skills.md 對應功能)、廚房小訣竅累積(state/lessons.md 對應
功能)、早餐輪替(state/breakfasts.md 對應功能)這幾個 alfred 既有的子系統
這一版還沒有對應資料表,先用「挑一道有點挑戰性的菜」「憑常識給新手提示」
代替。之後有需要再補。
```

- [ ] **Step 2: Sanity-check the file is readable from the worker's runtime cwd**

Run: `cd /Users/mikeweng/Projects/sous/worker && cat skills/plan-week.md | head -5`
Expected: prints the file's first 5 lines — confirms the path `skills/plan-week.md` resolves relative to `worker/` (the same directory `run_brain`'s `cwd` is pinned to), matching how `.venv/bin/python state_api.py` already resolves for the Bash tool.

- [ ] **Step 3: Commit**

```bash
git add worker/skills/plan-week.md
git commit -m "feat(worker): port alfred plan-week skill as a bundled ritual reference file"
```

---

### Task 7: `worker/prompts/ritual.md` — the ritual wrapper prompt

**Files:**
- Create: `worker/prompts/ritual.md`
- Test: `worker/tests/test_prompts.py`

**Interfaces:**
- Consumes: placeholders produced by `context.build_ritual_prompt` (Task 2): `{persona_pack}`, `{today}`, `{weekday}`, `{target_week_of}`, `{current_week_plan}`, `{recent_weeks}`, `{inbox}`, `{verdicts_recent}`, `{staples_flagged}`, `{preferences}`, `{cookbook_index}`, `{history}`, `{messages}`. References `worker/skills/plan-week.md` (Task 6) and every state_api verb (M2a's six plus this plan's `set-plan`/`clear-inbox`).
- Produces: `worker/prompts/ritual.md`, read unconditionally by `generate_ritual_reply` (Task 8) — this file must exist before Task 8's tests run.

- [ ] **Step 1: Write the failing tests**

Append to `worker/tests/test_prompts.py` (the file already has `PROMPT` for `chat.md` from M2a — add a second module-level constant):

```python
RITUAL_PROMPT = (pathlib.Path(__file__).resolve().parent.parent / "prompts" / "ritual.md").read_text()

RITUAL_VERBS = ["get-plan", "update-day", "swap-days", "add-shopping-item",
               "remove-shopping-item", "flag-staple", "capture-inbox",
               "set-plan", "clear-inbox"]

RITUAL_PLACEHOLDERS = ["{persona_pack}", "{today}", "{weekday}", "{target_week_of}",
                       "{current_week_plan}", "{recent_weeks}", "{inbox}",
                       "{verdicts_recent}", "{staples_flagged}", "{preferences}",
                       "{cookbook_index}", "{history}", "{messages}"]


def test_ritual_prompt_documents_every_verb():
    for verb in RITUAL_VERBS:
        assert verb in RITUAL_PROMPT, f"ritual.md must document {verb}"


def test_ritual_prompt_is_persona_neutral():
    assert "小當家" not in RITUAL_PROMPT


def test_skill_file_is_persona_neutral():
    skill_path = pathlib.Path(__file__).resolve().parent.parent / "skills" / "plan-week.md"
    assert "小當家" not in skill_path.read_text()


def test_ritual_prompt_keeps_all_placeholders():
    for ph in RITUAL_PLACEHOLDERS:
        assert ph in RITUAL_PROMPT, f"ritual.md must keep {ph}"


def test_ritual_prompt_references_the_skill_file():
    assert "skills/plan-week.md" in RITUAL_PROMPT


def test_ritual_prompt_states_two_touchpoint_rule():
    assert "兩" in RITUAL_PROMPT and ("觸點" in RITUAL_PROMPT or "問題" in RITUAL_PROMPT)
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `uv run pytest tests/test_prompts.py -v -k "ritual"`
Expected: FAIL — `FileNotFoundError` (`worker/prompts/ritual.md` doesn't exist yet).

- [ ] **Step 3: Create `worker/prompts/ritual.md`**

```markdown
{persona_pack}

Today is {today}({weekday})。這是「規劃儀式」模式 — 你正在幫忙規劃下週
({target_week_of} 那週)的菜單。

## 你知道的(以下狀態已經渲染好,直接使用,不需要查找檔案)

### 本週菜單(現在這週,供對照)
{current_week_plan}

### 近期排菜紀錄(過去約 4 週,用來判斷菜色輪替)
{recent_weeks}

### 收件匣(這段時間累積的 craving / feedback / note)
{inbox}

### 最近評價
{verdicts_recent}

### 常備品快用完
{staples_flagged}

### 家庭偏好
{preferences}

### 食譜庫(索引)
{cookbook_index}

## 完整規劃邏輯

用 Read 讀取 `skills/plan-week.md`(相對於你的工作目錄),裡面是完整的規劃
流程:菜色卡牌怎麼組、整週怎麼提案、鎖定時 `set-plan`/`clear-inbox` 怎麼呼叫、
食譜與採買清單格式規則。**先讀這份文件再開始規劃,不要憑印象亂猜格式。**

## 你的手(state_api — 改動廚房狀態的唯一途徑)
用 Bash 執行以下指令。每個指令回一行 JSON;看到 "ok": true 才算改成功。

- 查目前菜單:`.venv/bin/python state_api.py get-plan`
- 儀式期間對方臨時要調整某一天:
  `.venv/bin/python state_api.py update-day --date 2026-07-20 --dish 三杯雞`
- 兩天對調:`.venv/bin/python state_api.py swap-days --date-a ... --date-b ...`
- 鎖定整週(`skills/plan-week.md` Step 4 有完整範例):
  `.venv/bin/python state_api.py set-plan --days '[...7 筆...]' --shopping-items '[...]' --reasoning "..."`
- 鎖定成功後清空收件匣:`.venv/bin/python state_api.py clear-inbox`
- 採買清單加/移除單項:`add-shopping-item` / `remove-shopping-item`
- 常備品快沒了:`flag-staple`
- 記進收件匣供下次處理:`capture-inbox`

## 規則
- **整個儀式最多問兩個問題**(菜色卡牌一次、提案整週一次)— 其餘一律自己
  判斷、自己補齊,不要多問。細節見 `skills/plan-week.md`。
- 上面渲染好的狀態若已經反映了對方的要求,不要重複執行(可能是系統重試)—
  直接回報現況即可。尤其 `set-plan` 已經鎖定過的週,不要重新提案,除非對方
  明確要求重新來過。
- 只回報 state_api 確認過(ok: true)的改動;失敗就老實說失敗,不要假裝成功。
- 過敏原絕對不上卡、不排入計畫,即使對方點名也要婉拒並說明原因。
- 資料薄(recent_weeks/cookbook_index 內容很少)就照實說明,不要編造豐富的
  假選擇。
- 回覆通常簡短俐落,關鍵時刻(卡牌、整週提案、鎖定收尾)可以稍微多一點。
  不要署名;emoji 點到為止。不要用 markdown 表格;要列就條列。

最近對話:
{history}

需要回覆的新訊息:
{messages}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `uv run pytest tests/test_prompts.py tests/test_context.py -v` — all PASS.

- [ ] **Step 5: Commit**

```bash
git add worker/prompts/ritual.md worker/tests/test_prompts.py
git commit -m "feat(worker): ritual.md wrapper prompt — two-touchpoint flow, verb docs"
```

---

### Task 8: `main.py` — ritual job kind + chat-mode ritual routing

**Files:**
- Modify: `worker/sous_worker/main.py`
- Test: `worker/tests/test_main.py`

**Interfaces:**
- Consumes: `db.ensure_proposing_week`, `db.get_proposing_week` (Task 3), `context.fetch_ritual_context`, `context.build_ritual_prompt` (Task 2), `worker/prompts/ritual.md` (Task 7, must exist — it does by this point in the task order), existing `generate_chat_reply`, `brain.run_brain`.
- Produces: `generate_ritual_reply(conn, job: db.Job, cfg: dict) -> str`. `process_one(conn, cfg) -> bool` — behavior change: for `job.kind in ("chat", "ritual")`, computes `mode = "ritual" if job.kind == "ritual" or db.get_proposing_week(conn, job.household_id) else "chat"` and calls the matching generator; unknown kinds still raise `ValueError` as before. `job.result` gains a `"mode"` field.

- [ ] **Step 1: Write the failing tests**

Append to `worker/tests/test_main.py` (check existing imports — the file already imports `main`, `db`, `SANDBOX`, uses `monkeypatch`):

```python
import datetime
from psycopg.types.json import Jsonb


def _insert_chat_job(conn, content: str):
    mid = conn.execute(
        "insert into chat_messages (household_id, sender, content) "
        "values (%s, 'user', %s) returning id::text", (SANDBOX, content),
    ).fetchone()[0]
    jid = conn.execute(
        "insert into jobs (household_id, kind, payload) "
        "values (%s, 'chat', %s) returning id::text",
        (SANDBOX, Jsonb({"message_id": mid})),
    ).fetchone()[0]
    return mid, jid


def _insert_ritual_job(conn, content: str = "（開始本週儀式）"):
    mid = conn.execute(
        "insert into chat_messages (household_id, sender, content) "
        "values (%s, 'user', %s) returning id::text", (SANDBOX, content),
    ).fetchone()[0]
    jid = conn.execute(
        "insert into jobs (household_id, kind, payload) "
        "values (%s, 'ritual', %s) returning id::text",
        (SANDBOX, Jsonb({"message_id": mid})),
    ).fetchone()[0]
    return mid, jid


def test_ritual_job_creates_proposing_week_and_uses_ritual_prompt(conn, monkeypatch):
    seen = {}

    def fake_run_brain(prompt, **kw):
        seen["prompt"] = prompt
        seen.update(kw)
        return "深呼吸,今晚想吃點什麼?"

    monkeypatch.setattr(main.brain, "run_brain", fake_run_brain)
    _insert_ritual_job(conn)
    assert main.process_one(conn, main.load_config()) is True
    proposing = db.get_proposing_week(conn, SANDBOX)
    assert proposing is not None
    # ritual.md's target-week placeholder must have been substituted with the
    # actual computed date, proving build_ritual_prompt (not build_chat_prompt)
    # was used — a leftover literal "{target_week_of}" means the wrong path ran.
    assert "{target_week_of}" not in seen["prompt"]
    assert proposing["week_of"].isoformat() in seen["prompt"]
    result = conn.execute(
        "select result from jobs where household_id=%s order by created_at desc limit 1",
        (SANDBOX,),
    ).fetchone()[0]
    assert result["mode"] == "ritual"


def test_chat_job_routes_to_ritual_when_proposing_week_exists(conn, monkeypatch):
    target = datetime.date(2026, 9, 7)
    db.ensure_proposing_week(conn, SANDBOX, target)
    try:
        seen = {}

        def fake_run_brain(prompt, **kw):
            seen["prompt"] = prompt
            return "好,選好了嗎?"

        monkeypatch.setattr(main.brain, "run_brain", fake_run_brain)
        _insert_chat_job(conn, "1 4 6 想吃")
        assert main.process_one(conn, main.load_config()) is True
        assert "1 4 6 想吃" in seen["prompt"]
        assert "{target_week_of}" not in seen["prompt"]  # ritual prompt was used
    finally:
        conn.execute(
            "delete from plan_weeks where household_id=%s and week_of=%s",
            (SANDBOX, target),
        )


def test_chat_job_uses_chat_prompt_when_no_active_ritual(conn, monkeypatch):
    conn.execute(
        "delete from plan_weeks where household_id=%s and status='proposing'",
        (SANDBOX,),
    )
    seen = {}

    def fake_run_brain(prompt, **kw):
        seen["prompt"] = prompt
        return "今晚吃三杯雞"

    monkeypatch.setattr(main.brain, "run_brain", fake_run_brain)
    _insert_chat_job(conn, "今晚吃什麼?")
    assert main.process_one(conn, main.load_config()) is True
    assert "你的手(state_api" in seen["prompt"]  # chat.md's verb section header
    assert "target_week_of" not in seen["prompt"]  # ritual-only placeholder absent
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `uv run pytest tests/test_main.py -v -k "ritual"`
Expected: FAIL — `test_ritual_job_creates_proposing_week_and_uses_ritual_prompt` fails with `ValueError: unknown job kind: ritual` (the current `process_one` only recognizes `"chat"`).

- [ ] **Step 3: Implement**

In `worker/sous_worker/main.py`, add after `generate_chat_reply`:

```python
def generate_ritual_reply(conn, job: db.Job, cfg: dict) -> str:
    """Ritual mode: same shape as generate_chat_reply, but renders the ritual
    context/prompt and deterministically ensures a 'proposing' plan_weeks row
    exists for the target week before the brain runs (idempotent — a retry
    re-enters this function and finds the row already there)."""
    ctx = context.fetch_ritual_context(conn, job.household_id, cfg["history_limit"])
    db.ensure_proposing_week(conn, job.household_id, ctx["target_week_of"])
    template = (ROOT / "prompts" / "ritual.md").read_text()
    new_message = ""
    if job.payload.get("message_id"):
        content = db.get_message_content(conn, job.payload["message_id"])
        if content is not None:
            new_message = f"user: {content}"
    prompt = context.build_ritual_prompt(template, ctx, new_message or "(none)")
    return brain.run_brain(prompt, model=cfg["chat_model"],
                           timeout=cfg["chat_timeout_sec"],
                           allowed_tools=cfg["chat_allowed_tools"],
                           cwd=str(ROOT),
                           extra_env={"SOUS_HOUSEHOLD_ID": job.household_id})
```

Replace `process_one`'s body (the `if job.kind == "chat": ... else: raise ...` block) with:

```python
    job = db.claim_next_job(conn)
    if job is None:
        return False
    try:
        if job.kind in ("chat", "ritual"):
            mode = ("ritual" if job.kind == "ritual"
                    or db.get_proposing_week(conn, job.household_id) else "chat")
            reply = (generate_ritual_reply(conn, job, cfg) if mode == "ritual"
                     else generate_chat_reply(conn, job, cfg))
            with conn.transaction():
                db.insert_chef_message(conn, job.household_id, reply, job.id)
                db.complete_job(conn, job.id, {"reply_chars": len(reply), "mode": mode})
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
```

(Only the `try:` block's contents change — the `for job_id in db.requeue_stale(...)` sweep above it and the function signature are unchanged.)

- [ ] **Step 4: Run the full worker suite**

Run: `uv run pytest -v`
Expected: ALL PASS. `worker/prompts/ritual.md` and `worker/skills/plan-week.md` already exist from Tasks 6–7, so `generate_ritual_reply`'s `.read_text()` call succeeds for real — no mocking of the file read is needed, only `brain.run_brain` is mocked (to avoid a real subprocess call in this task's tests).

- [ ] **Step 5: Commit**

```bash
git add worker/sous_worker/main.py worker/tests/test_main.py
git commit -m "feat(worker): ritual job kind + chat-mode routing to ritual prompt"
```

---

### Task 9: Gated real-brain multi-turn ritual smoke test

Three sequential real `claude -p` turns against the local stack: touchpoint 1 (craving deck), touchpoint 2 (pick + propose), lock (「鎖定!」→ `set-plan` + `clear-inbox`). Slow (each turn ~20-90s, three turns ~1-4 min total) — gated behind `SOUS_SMOKE=1`, same pattern as M2a's Task 8.

**Files:**
- Create: `worker/tests/test_smoke_ritual.py`

**Interfaces:**
- Consumes: `process_one`, `load_config`, `db.get_proposing_week`, conftest `conn`/`SANDBOX`/`TEST_DB_URL`; all of Tasks 1–8 must be complete.

- [ ] **Step 1: Write the smoke test**

Create `worker/tests/test_smoke_ritual.py`:

```python
"""Real-brain multi-turn ritual smoke test. Slow (~1-4 min, three real
`claude -p` turns) — run explicitly with:
  SOUS_SMOKE=1 uv run pytest tests/test_smoke_ritual.py -v -s
Requires the local Supabase stack (conftest TEST_DB_URL)."""
import datetime
import os

import pytest
from psycopg.types.json import Jsonb

from sous_worker import context, db, main
from tests.conftest import SANDBOX, TEST_DB_URL

pytestmark = pytest.mark.skipif(
    not os.environ.get("SOUS_SMOKE"), reason="set SOUS_SMOKE=1 to run the real-brain smoke test"
)


def _insert_user_message_and_job(conn, content: str, kind: str):
    mid = conn.execute(
        "insert into chat_messages (household_id, sender, content) "
        "values (%s, 'user', %s) returning id::text", (SANDBOX, content),
    ).fetchone()[0]
    jid = conn.execute(
        "insert into jobs (household_id, kind, payload) "
        "values (%s, %s, %s) returning id::text",
        (SANDBOX, kind, Jsonb({"message_id": mid})),
    ).fetchone()[0]
    return mid, jid


def test_full_ritual_flow_end_to_end(conn, monkeypatch):
    monkeypatch.setenv("SOUS_DB_URL", TEST_DB_URL)
    target = context.week_monday(datetime.date.today()) + datetime.timedelta(days=7)
    conn.execute(
        "delete from plan_weeks where household_id=%s and week_of=%s",
        (SANDBOX, target),
    )
    cfg = main.load_config()
    try:
        # Touchpoint 1: bootstrap the ritual (kind='ritual', no prior user text needed).
        _insert_user_message_and_job(conn, "（開始本週儀式）", "ritual")
        assert main.process_one(conn, cfg) is True
        proposing = db.get_proposing_week(conn, SANDBOX)
        assert proposing is not None and proposing["week_of"] == target
        deck_reply = conn.execute(
            "select content from chat_messages where household_id=%s and sender='chef' "
            "order by created_at desc limit 1", (SANDBOX,),
        ).fetchone()[0]
        assert deck_reply  # the brain produced a craving deck

        # Touchpoint 2: user picks from the deck (routes via 'chat' kind + proposing-week check).
        _insert_user_message_and_job(conn, "1 2 3 都想吃,其他你決定", "chat")
        assert main.process_one(conn, cfg) is True
        proposal_reply = conn.execute(
            "select content from chat_messages where household_id=%s and sender='chef' "
            "order by created_at desc limit 1", (SANDBOX,),
        ).fetchone()[0]
        assert proposal_reply

        # Lock: user confirms (routes via 'chat' kind + proposing-week check → set-plan + clear-inbox).
        _insert_user_message_and_job(conn, "鎖定!", "chat")
        assert main.process_one(conn, cfg) is True

        locked = conn.execute(
            "select status from plan_weeks where household_id=%s and week_of=%s",
            (SANDBOX, target),
        ).fetchone()
        assert locked is not None and locked[0] == "locked", \
            "brain never called set-plan — check ritual.md / skills/plan-week.md guidance"
        days_written = conn.execute(
            "select count(*) from plan_days where household_id=%s and date >= %s "
            "and date < %s", (SANDBOX, target, target + datetime.timedelta(days=7)),
        ).fetchone()[0]
        assert days_written == 7
    finally:
        conn.execute(
            "delete from plan_weeks where household_id=%s and week_of=%s",
            (SANDBOX, target),
        )
```

- [ ] **Step 2: Run the fast suite (smoke skipped)**

Run: `uv run pytest -v`
Expected: all PASS; `test_smoke_ritual.py` shows SKIPPED.

- [ ] **Step 3: Run the smoke test for real**

Run: `SOUS_SMOKE=1 uv run pytest tests/test_smoke_ritual.py -v -s`
Expected: PASS — proposing week created after touchpoint 1, deck reply exists, proposal reply exists after touchpoint 2, `plan_weeks.status == 'locked'` with 7 `plan_days` rows after the lock turn. If the brain never calls `set-plan` at the lock step, that's a **prompt** problem (tighten `ritual.md`'s Step 4 instructions or `skills/plan-week.md`'s JSON example), not a harness problem — do not loosen the test's assertions to work around it.

- [ ] **Step 4: Commit**

```bash
git add worker/tests/test_smoke_ritual.py
git commit -m "test(worker): gated real-brain multi-turn ritual smoke test"
```

---

### Task 10: Deploy + M2b1 real-use exit check

No new code — bring the cloud environment up to date and verify the full ritual flow against real cloud data (household rule: verify via real use). Since there's no app UI yet for this sub-plan, "real use" means driving the same three-turn flow Task 9 automated, but against the cloud sandbox household via direct SQL/job insertion — the same shape the future iOS "開始本週儀式" button (M2b2) will produce.

- [ ] **Step 1: Push migrations to cloud**

Run: `supabase link --project-ref ftobrcxtbtdjgrrkavzb && supabase db push` (confirm the prompt) — applies migration `0004_plan_weeks_status_check.sql`.

- [ ] **Step 2: Restart the worker against cloud**

Kill any running worker process, restart from `worker/` (`uv run python -m sous_worker.main`), confirm the heartbeat log line.

- [ ] **Step 3: Drive the three-turn ritual against cloud**

Using a direct DB connection (same pattern as M2a's Task 9 cloud verification — `psycopg.connect(os.environ["SOUS_DB_URL"], ...)` with the cloud URL from `worker/.env`), insert the same sequence Task 9's smoke test automated: a `ritual`-kind job to bootstrap, then two `chat`-kind jobs for the touchpoint replies (using real craving/pick text of your choice rather than the test's canned strings — this is a real-use check, not a repeat of the automated test). Watch the worker log and query `chat_messages`/`plan_weeks`/`plan_days`/`shopping_items` between each turn.

- [ ] **Step 4: Verify against real data**

1. Craving deck reply names 8 candidates from a mix of the actual seeded cookbook + honest "資料還不多" framing (only 3 recipes exist in the sandbox).
2. Deck-pick reply proposes a full week honoring the ≥50g protein/serve and mode-mix guidance from `skills/plan-week.md`.
3. 「鎖定!」→ `plan_weeks.status = 'locked'` for next week, 7 `plan_days` rows, `shopping_items` rows with English names and `→ 用途`-style reasoning reflected in the chat summary (not necessarily in the DB row itself — the summary message is where this shows).
4. `inbox_items` for the household is empty after lock (proving `clear-inbox` was called).
5. A normal chat message sent AFTER the lock (e.g. 「今晚吃什麼?」) gets a plain `chat.md`-style reply, not a ritual-mode reply — proving the routing correctly falls back once `status` is no longer `'proposing'`.

- [x] **Step 5: Record results + update memory**

Append a `## M2b1 exit verification` section to this plan file with pass/fail notes per check, commit as `docs: M2b1 exit verification notes`, and update the project-status memory file.

---

## M2b1 exit verification (2026-07-16, real use against cloud sandbox household)

Cloud deploy: migration `0004_plan_weeks_status_check.sql` pushed via `supabase db push` (only pending migration; 0001-0003 already applied). `plan_weeks_status_check` constraint confirmed present on cloud post-push. Worker restarted against cloud (`uv run python -m sous_worker.main`, heartbeat confirmed fresh, polling every 3s). `worker/.env`'s `SOUS_DB_URL` reconstructed from `.env.local`'s `SUPABASE_PASSWORD` + the Session Pooler format (see project memory) since a fresh worktree/session has neither by default.

All 5 checks driven via direct job insertion against the cloud sandbox household (`00000000-0000-0000-0000-000000000001`), verified against live DB state after each turn:

1. **Touchpoint 1 — `ritual`-kind bootstrap job, message "（開始本週儀式）"** → PASS. `plan_weeks` row created for 2026-07-20 with `status='proposing'`. Craving deck reply named 8 real candidates (all "new"/"play" bucket — the plan's usual bangers were correctly excluded because all 4 seeded recipes had been cooked within the 2-week window, and the chef said so honestly rather than reusing them). Allergy question bundled into the same message per the two-touchpoint rule (no separate question spent). Job `result.mode == 'ritual'`.
2. **Touchpoint 2 — `chat`-kind job (routes via `get_proposing_week`), message picking 3 dishes + noting chicken breast to use up** → PASS. Full 7-day week proposed (Mon-Sun), each day with main + side + soup, mode mix (3 fast + 1 batch/leftover pair + 1 fast + 1 play + 1 fast), protein guidance honored (~50-55g/meal stated per day), the requested chicken-breast use-up correctly placed on Friday. Job `result.mode == 'ritual'`.
3. **Lock — `chat`-kind job, message "可以,鎖定!"** → PASS. `set-plan` called: `plan_weeks.status` flipped to `'locked'` for 2026-07-20 with a real `reasoning` summary, exactly 7 `plan_days` rows written (Mon-Sun, matching the proposal), `shopping_items` rows all English names (Woolworths-searchable: "chicken thigh (bone-in)", "beef sirloin (thinly sliced)", "Thai basil", etc.) correctly sectioned (produce/meat/pantry/dairy). Chat closing summary reflected the shopping-list reasoning per-dish. `clear-inbox` also called — `inbox_items` count for the household is 0 post-lock (was already 0 pre-ritual, but the call happened as part of the flow per the job trace).
4. **Inbox empty after lock** → PASS (confirmed above, count 0).
5. **Post-lock plain chat message, "今晚吃什麼?"** → PASS. Job `result.mode == 'chat'` (not `'ritual'`) — routing correctly fell back to plain `chat.md` once `plan_weeks.status` was no longer `'proposing'`. Reply was short and referenced the actual dish scheduled for today in the *current* (already-locked, pre-existing) week, not ritual-mode framing.

All 4 jobs completed `status='done'` on first attempt, no retries/failures, no errors in the worker log across the full run (~430s total wall-clock for all three ritual-mode turns + the post-lock check).

**M2b1 exit test: PASSED (5/5 clean).** The full ritual loop — bootstrap → craving deck → full week proposal → lock (writing `plan_days` + `shopping_items`, clearing the inbox) → routing fallback to normal chat — is proven end-to-end against real cloud data with a real brain, matching Task 9's local smoke test result. No UI exists yet to trigger this (that's M2b2); the same job-insertion shape here is what the future iOS "開始本週儀式" button will produce.

---

## Explicitly deferred (do not build here)

- **iOS UI** (Week board sheet, drag-to-swap, "開始本週儀式" button, Shopping list sheet) → **M2b2**, planned after this lands so it consumes real interfaces.
- **Skill curriculum, kitchen-quirks lessons, breakfast rotation** (alfred's `state/skills.md`/`state/lessons.md`/`state/breakfasts.md` equivalents) — no Sous schema/table exists for these; `skills/plan-week.md` (Task 6) explicitly notes their absence rather than faking equivalent behavior. Candidate for a future milestone if the simplified version proves insufficient.
- **`save-recipe` verb, recipe_intake mode, structured recipe steps/enrichment, share-sheet intake, cookbook sheet, cook mode** → **M2c**.
- **`queue-notification`, `post-card` verbs, APNs pipeline, actual Sunday-16:00 automated trigger (pg_cron)** → **M3**. This plan's ritual bootstrap stays manually/button-triggered; automating the trigger is explicitly a notification-pipeline concern.
- **Chat `cards` JSONB rendering** — the craving deck and week proposal stay plain text in this plan, same as M2a. Rich card rendering is deferred to whichever plan first needs it (iOS work in M2b2 or M2c).
