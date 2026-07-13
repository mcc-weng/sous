# Sous M2a 「會動手的主廚」 — Brain Writes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the chef brain hands — `state_api.py` write verbs invoked from `claude -p`, so chat requests like 「今晚不想吃咖哩」 and 「醬油沒了」 mutate real rows and the app updates live.

**Architecture:** M2 (spec §9 「完整的一週」) is split into three sequential sub-plans. This is **M2a**: the vetted write seam (`worker/state_api.py`, spec §5), the chat prompt upgraded from read-only to write-enabled, worker wiring (tool allowlist + per-job household env pinning), the tracked M1 timezone bug fixed at the root, and one small iOS change so the Tonight card live-refreshes when the brain edits the plan. M2b (ritual mode + week/shopping sheets) and M2c (recipe pipeline + cook mode) get their own plans after this lands.

**Tech Stack:** Python 3.11+ / psycopg3 / pytest (worker); Supabase Postgres (local stack for tests at `127.0.0.1:54322`, cloud project `ftobrcxtbtdjgrrkavzb` for real use); `claude -p` headless brain with `--allowedTools`; SwiftUI + supabase-swift (iOS).

## Global Constraints

- **Writes only via `state_api.py`** — the brain never free-writes state (CLAUDE.md, spec §5).
- **Persona discipline:** zero hardcoded persona strings in app or prompts — voice arrives via `{persona_pack}` (spec §7). `worker/prompts/chat.md` must never contain 小當家 or any persona name.
- **Hard isolation from alfred:** never read/write `~/Projects/alfred/state/` or Discord.
- **`.env` holds secrets** — never commit, never print. `worker/.env` already exists with `SOUS_DB_URL`.
- **Idempotency:** state_api verbs must be idempotent or at-least-once safe (spec §3 failure handling). Exception: `swap-days` is self-inverse; the prompt compensates (see Task 6).
- **Household pinning:** state_api takes household **only** from the `SOUS_HOUSEHOLD_ID` env var set by the worker per job — never from CLI args the model controls.
- **Shopping item names are English** (Woolworths-searchable, spec §4).
- Worker tests run against the **local Supabase stack** (`supabase start` from repo root; test DB URL default `postgresql://postgres:postgres@127.0.0.1:54322/postgres`). Run tests from `worker/` with `uv run pytest`.
- Commit messages follow the repo convention: `feat(worker):`, `fix(worker):`, `feat(ios):`, `chore:` etc., ending with the Claude co-author trailer already used in this repo.

## Pre-existing interfaces you'll touch (M1, already on main)

- `worker/sous_worker/context.py` — `fetch_context(conn, household_id, history_limit=20) -> dict`, `build_chat_prompt(template, ctx, new_messages) -> str`, private `_render_week(conn, household_id)`.
- `worker/sous_worker/brain.py` — `run_brain(prompt, model="sonnet", timeout=480, allowed_tools="Read") -> str` (subprocess around `claude -p`, prompt via STDIN).
- `worker/sous_worker/main.py` — `generate_chat_reply(conn, job, cfg)`, `process_one(conn, cfg)`, `ROOT` = `worker/`.
- `worker/sous_worker/db.py` — `get_household(conn, household_id) -> {"name","timezone","prompt_pack","copy_pack"}`.
- `worker/tests/conftest.py` — `conn` fixture (local stack, truncates `jobs, chat_messages` around each test), `SANDBOX = "00000000-0000-0000-0000-000000000001"`, `chat_job` fixture.
- `worker/config.json` — flat dict; `load_config()` reads it.
- `ios/Sous/AppModel.swift` — `subscribe()` opens channel `"kitchen"` watching `chat_messages` inserts; `loadTonight()` fetches today's `plan_days` row.
- Realtime publication already includes `plan_days` (migration `0002_rls.sql:66`) — no new migration needed.

---

### Task 1: Timezone-aware week window (the tracked M1 bug)

The M1 live bug: `_render_week` filters on Postgres `current_date` (UTC session), while `{today}` uses `datetime.now(ZoneInfo(household.timezone))` (Sydney, UTC+10). For ~10h/day the two disagree. Fix: all "today"/week math derives from one household-local clock in Python; SQL takes the Monday as a parameter. The seed must anchor the same way.

**Files:**
- Modify: `worker/sous_worker/context.py`
- Modify: `supabase/seed.sql:63-77` (week anchor)
- Test: `worker/tests/test_context.py`

**Interfaces:**
- Consumes: existing `fetch_context` / `build_chat_prompt` / `_render_week`.
- Produces: `week_monday(day: datetime.date) -> datetime.date` (public, reused by state_api in Task 2); `fetch_context(conn, household_id, history_limit=20, now=None)` where `now` is an optional aware `datetime` override for tests; `ctx["now"]` (aware datetime) added to the context dict; `_render_week(conn, household_id, monday: datetime.date)`.

- [ ] **Step 1: Write the failing tests**

Append to `worker/tests/test_context.py`:

```python
import datetime
from zoneinfo import ZoneInfo


def test_week_monday_anchors_iso_monday():
    assert context.week_monday(datetime.date(2026, 7, 13)) == datetime.date(2026, 7, 13)  # Mon
    assert context.week_monday(datetime.date(2026, 7, 16)) == datetime.date(2026, 7, 13)  # Thu
    assert context.week_monday(datetime.date(2026, 7, 19)) == datetime.date(2026, 7, 13)  # Sun


def test_fetch_context_selects_week_from_household_local_now(conn):
    # Regression for the M1 live bug: at Sydney Mon 00:30 the UTC date is still
    # Sunday of the *previous* ISO week. The week window must follow the
    # household-local clock passed via `now`, not the DB's current_date.
    monday = datetime.date(2030, 1, 7)   # a Monday, far from the seeded week
    wid = conn.execute(
        "insert into plan_weeks (household_id, week_of) values (%s, %s) returning id",
        (SANDBOX, monday),
    ).fetchone()[0]
    conn.execute(
        "insert into plan_days (week_id, household_id, date, dish, mode) "
        "values (%s, %s, %s, '未來測試菜', 'fast')",
        (wid, SANDBOX, monday),
    )
    try:
        sydney_after_midnight = datetime.datetime(
            2030, 1, 7, 0, 30, tzinfo=ZoneInfo("Australia/Sydney")
        )  # == 2030-01-06 13:30 UTC (Sunday)
        ctx = context.fetch_context(conn, SANDBOX, now=sydney_after_midnight)
        assert "未來測試菜" in ctx["week_plan"]
        assert ctx["now"] is sydney_after_midnight
    finally:
        conn.execute("delete from plan_weeks where id = %s", (wid,))


def test_build_chat_prompt_uses_ctx_now(conn):
    fixed = datetime.datetime(2030, 1, 9, 18, 0, tzinfo=ZoneInfo("Australia/Sydney"))
    ctx = context.fetch_context(conn, SANDBOX, now=fixed)
    prompt = context.build_chat_prompt(TEMPLATE, ctx, "hi")
    assert "2030-01-09" in prompt
    assert "週三" in prompt   # 2030-01-09 is a Wednesday
```

- [ ] **Step 2: Run tests to verify they fail**

Run (from `worker/`): `uv run pytest tests/test_context.py -v`
Expected: the three new tests FAIL (`AttributeError: module ... has no attribute 'week_monday'`, `TypeError: fetch_context() got an unexpected keyword argument 'now'`).

- [ ] **Step 3: Implement in `context.py`**

Add after the `_WEEKDAYS_ZH` constant:

```python
def week_monday(day: datetime.date) -> datetime.date:
    """ISO-Monday anchor for plan_weeks.week_of. All week math goes through
    here, driven by the household-local date — never the DB session's UTC
    clock (M1 live bug: `current_date` is UTC; Sydney is UTC+10)."""
    return day - datetime.timedelta(days=day.weekday())
```

Change `_render_week` to take the anchor as a parameter:

```python
def _render_week(conn, household_id: str, monday: datetime.date) -> str:
    rows = conn.execute(
        "select d.date, d.dish, d.mode, d.prep_note, d.status "
        "from plan_days d join plan_weeks w on w.id = d.week_id "
        "where d.household_id = %s and w.week_of = %s "
        "order by d.date",
        (household_id, monday),
    ).fetchall()
```
(rest of the function body unchanged)

Change `fetch_context` to compute the clock once and thread it through:

```python
def fetch_context(conn, household_id: str, history_limit: int = 20,
                  now: datetime.datetime | None = None) -> dict:
    household = db.get_household(conn, household_id)
    if now is None:
        now = datetime.datetime.now(ZoneInfo(household["timezone"]))
    return {
        "household": household,
        "now": now,
        "week_plan": _render_week(conn, household_id, week_monday(now.date())),
        "preferences": _render_preferences(conn, household_id),
        "cookbook_index": _render_cookbook_index(conn, household_id),
        "shopping_open": _render_shopping_open(conn, household_id),
        "history": _render_history(conn, household_id, history_limit),
    }
```

Change `build_chat_prompt` to stop calling `datetime.now` — first line becomes:

```python
    now = ctx["now"]
```

- [ ] **Step 4: Fix the seed anchor**

In `supabase/seed.sql`, replace every `date_trunc('week', current_date)::date` (lines 63–77, 8 occurrences) with:

```sql
date_trunc('week', (now() at time zone 'Australia/Sydney'))::date
```

(The sandbox household's timezone is Australia/Sydney; the seed must land in the same Monday bucket `fetch_context` now computes.)

- [ ] **Step 5: Reset the local stack and run the full worker suite**

Run: `cd /Users/mikeweng/Projects/sous && supabase db reset` (starts from migrations + new seed; requires `supabase start` beforehand).
Then: `cd worker && uv run pytest -v`
Expected: ALL tests PASS (including the pre-existing seeded-week tests, which now read the Sydney-anchored seed).

- [ ] **Step 6: Commit**

```bash
git add worker/sous_worker/context.py worker/tests/test_context.py supabase/seed.sql
git commit -m "fix(worker): week window follows household-local date, not UTC current_date"
```

---

### Task 2: `state_api.py` scaffold + `get-plan` + `update-day`

The one vetted write seam (spec §5). A CLI at `worker/state_api.py` the brain invokes via Bash. Pure functions take `(conn, household_id, ...)` so tests hit them directly; a thin argparse `main` handles env + JSON output. Running `.venv/bin/python state_api.py` with cwd=`worker/` puts the script dir on `sys.path`, so `from sous_worker.context import week_monday` works (verified).

**Files:**
- Create: `worker/state_api.py`
- Test: `worker/tests/test_state_api.py`

**Interfaces:**
- Consumes: `week_monday` from Task 1; `households.timezone` column.
- Produces (later tasks add verbs to the same file/parser):
  - `get_plan(conn, household_id) -> dict` — `{"ok": True, "week_of": date, "days": [{"date","dish","mode","prep_note","status"}, …]}`
  - `update_day(conn, household_id, date, dish=None, mode=None, prep_note=None, status=None, reasoning=None) -> dict`
  - CLI contract: `SOUS_HOUSEHOLD_ID` + `SOUS_DB_URL` env; one JSON line on stdout; `{"ok": false, "error": …}` + exit 1 on failure.
  - `_parser()`, `_dispatch(conn, household_id, args)`, `main(argv=None) -> int` — Tasks 3–4 extend `_parser`/`_dispatch`.
  - Test fixture `api_hid` (module-level in `test_state_api.py`) — a dedicated household with a 2-day current week, cascade-deleted on teardown. Tasks 3–4 reuse it.

- [ ] **Step 1: Write the failing tests**

Create `worker/tests/test_state_api.py`:

```python
import datetime
import json
import os
import pathlib
import subprocess
import sys
from zoneinfo import ZoneInfo

import pytest

import state_api
from sous_worker.context import week_monday
from tests.conftest import SANDBOX, TEST_DB_URL

WORKER_DIR = pathlib.Path(state_api.__file__).resolve().parent
MONDAY = week_monday(datetime.datetime.now(ZoneInfo("Australia/Sydney")).date())
TUESDAY = MONDAY + datetime.timedelta(days=1)


@pytest.fixture
def api_hid(conn):
    """Dedicated household so verb tests never disturb the seeded sandbox."""
    hid = conn.execute(
        "insert into households (name, persona_id) "
        "select 'state-api-test', id from personas limit 1 returning id::text"
    ).fetchone()[0]
    wid = conn.execute(
        "insert into plan_weeks (household_id, week_of) values (%s, %s) returning id",
        (hid, MONDAY),
    ).fetchone()[0]
    conn.execute(
        "insert into plan_days (week_id, household_id, date, dish, mode, prep_note) values "
        "(%s, %s, %s, '咖哩飯', 'batch', '前一晚醃肉'), (%s, %s, %s, '三杯雞', 'fast', null)",
        (wid, hid, MONDAY, wid, hid, TUESDAY),
    )
    yield hid
    conn.execute("delete from households where id = %s", (hid,))


def test_get_plan_returns_current_week(conn, api_hid):
    out = state_api.get_plan(conn, api_hid)
    assert out["ok"] is True
    assert out["week_of"] == MONDAY
    assert [d["dish"] for d in out["days"]] == ["咖哩飯", "三杯雞"]
    assert out["days"][0]["prep_note"] == "前一晚醃肉"


def test_update_day_changes_only_given_fields(conn, api_hid):
    out = state_api.update_day(conn, api_hid, MONDAY, dish="番茄炒蛋", status="cooked")
    assert out == {"ok": True, "date": MONDAY, "dish": "番茄炒蛋",
                   "mode": "batch", "status": "cooked"}
    row = conn.execute(
        "select dish, mode, prep_note, status from plan_days "
        "where household_id = %s and date = %s", (api_hid, MONDAY),
    ).fetchone()
    assert row == ("番茄炒蛋", "batch", "前一晚醃肉", "cooked")


def test_update_day_is_idempotent(conn, api_hid):
    first = state_api.update_day(conn, api_hid, MONDAY, dish="番茄炒蛋")
    again = state_api.update_day(conn, api_hid, MONDAY, dish="番茄炒蛋")
    assert first == again


def test_update_day_rejects_bad_mode_and_missing_day(conn, api_hid):
    with pytest.raises(ValueError, match="mode"):
        state_api.update_day(conn, api_hid, MONDAY, mode="yolo")
    with pytest.raises(ValueError, match="no plan day"):
        state_api.update_day(conn, api_hid, MONDAY + datetime.timedelta(days=30),
                             dish="幽靈菜")
    with pytest.raises(ValueError, match="nothing to update"):
        state_api.update_day(conn, api_hid, MONDAY)


def test_update_day_scopes_to_household(conn, api_hid):
    # SANDBOX's seeded week also has a row on MONDAY — updating it must not
    # touch api_hid's row for the same date. Restore the seed row after.
    original = conn.execute(
        "select dish from plan_days where household_id = %s and date = %s",
        (SANDBOX, MONDAY),
    ).fetchone()[0]
    try:
        state_api.update_day(conn, SANDBOX, MONDAY, dish="別家的菜")
        row = conn.execute(
            "select dish from plan_days where household_id = %s and date = %s",
            (api_hid, MONDAY),
        ).fetchone()
        assert row == ("咖哩飯",)
    finally:
        conn.execute(
            "update plan_days set dish = %s where household_id = %s and date = %s",
            (original, SANDBOX, MONDAY),
        )


def _run_cli(args, hid):
    return subprocess.run(
        [sys.executable, "state_api.py", *args],
        capture_output=True, cwd=WORKER_DIR, text=True,
        env=os.environ | {"SOUS_HOUSEHOLD_ID": hid, "SOUS_DB_URL": TEST_DB_URL},
    )


def test_cli_get_plan_roundtrip(api_hid):
    proc = _run_cli(["get-plan"], api_hid)
    assert proc.returncode == 0, proc.stderr
    out = json.loads(proc.stdout)
    assert out["ok"] is True and out["days"][0]["dish"] == "咖哩飯"


def test_cli_update_day_and_error_paths(api_hid):
    proc = _run_cli(["update-day", "--date", str(MONDAY), "--dish", "打拋豬"], api_hid)
    assert json.loads(proc.stdout)["dish"] == "打拋豬"

    bad = _run_cli(["update-day", "--date", str(MONDAY), "--mode", "yolo"], api_hid)
    assert bad.returncode == 1
    assert json.loads(bad.stdout)["ok"] is False

    no_hid = subprocess.run(
        [sys.executable, "state_api.py", "get-plan"],
        capture_output=True, cwd=WORKER_DIR, text=True,
        env={k: v for k, v in os.environ.items() if k != "SOUS_HOUSEHOLD_ID"}
        | {"SOUS_DB_URL": TEST_DB_URL},
    )
    assert no_hid.returncode == 1
    assert "SOUS_HOUSEHOLD_ID" in json.loads(no_hid.stdout)["error"]
```

(`TEST_DB_URL` and `SANDBOX` are already module-level in `conftest.py` — importable as is.)

- [ ] **Step 2: Run tests to verify they fail**

Run: `uv run pytest tests/test_state_api.py -v`
Expected: FAIL at import — `ModuleNotFoundError: No module named 'state_api'`.

(If the import fails because pytest's rootdir isn't on `sys.path` for top-level modules: `uv run pytest` from `worker/` puts `worker/` on `sys.path` via rootdir/conftest; if not, add `pythonpath = ["."]` under `[tool.pytest.ini_options]` in `worker/pyproject.toml`.)

- [ ] **Step 3: Implement `worker/state_api.py`**

```python
#!/usr/bin/env python
"""Sous state_api — the one vetted write seam (spec §5).

The brain (claude -p) mutates household state ONLY through these verbs:

    .venv/bin/python state_api.py <verb> [--flag value ...]

Contract:
- Household comes from SOUS_HOUSEHOLD_ID env (set by the worker per job),
  never from arguments — a brain session cannot cross households.
- Verbs are idempotent or at-least-once safe: job retries re-run whole brain
  sessions, so re-applying must converge. swap-days is the one self-inverse
  verb; the chat prompt compensates (re-check rendered state before acting).
- Every verb prints exactly one JSON line: {"ok": true, ...} on success,
  {"ok": false, "error": "..."} + exit 1 on failure. The model treats that
  JSON as its only confirmation.
"""
import argparse
import datetime
import json
import os
import pathlib
import sys
from zoneinfo import ZoneInfo

import psycopg
from dotenv import load_dotenv

# Invoked with cwd = worker/, so the script dir is on sys.path.
from sous_worker.context import week_monday

MODES = {"batch", "fast", "leftover", "play"}
STATUSES = {"planned", "cooked", "skipped"}


def _household_today(conn, household_id: str) -> datetime.date:
    row = conn.execute(
        "select timezone from households where id = %s", (household_id,)
    ).fetchone()
    if row is None:
        raise ValueError(f"unknown household {household_id}")
    return datetime.datetime.now(ZoneInfo(row[0])).date()


def get_plan(conn, household_id: str) -> dict:
    monday = week_monday(_household_today(conn, household_id))
    rows = conn.execute(
        "select d.date, d.dish, d.mode, d.prep_note, d.status "
        "from plan_days d join plan_weeks w on w.id = d.week_id "
        "where d.household_id = %s and w.week_of = %s order by d.date",
        (household_id, monday),
    ).fetchall()
    return {"ok": True, "week_of": monday, "days": [
        {"date": r[0], "dish": r[1], "mode": r[2], "prep_note": r[3], "status": r[4]}
        for r in rows
    ]}


def update_day(conn, household_id: str, date: datetime.date, dish=None, mode=None,
               prep_note=None, status=None, reasoning=None) -> dict:
    if mode is not None and mode not in MODES:
        raise ValueError(f"mode must be one of {sorted(MODES)}")
    if status is not None and status not in STATUSES:
        raise ValueError(f"status must be one of {sorted(STATUSES)}")
    changes = {"dish": dish, "mode": mode, "prep_note": prep_note,
               "status": status, "reasoning": reasoning}
    changes = {k: v for k, v in changes.items() if v is not None}
    if not changes:
        raise ValueError("nothing to update — pass at least one field")
    sets = ", ".join(f"{col} = %s" for col in changes)  # keys are a fixed whitelist
    row = conn.execute(
        f"update plan_days set {sets} where household_id = %s and date = %s "
        "returning date, dish, mode, status",
        (*changes.values(), household_id, date),
    ).fetchone()
    if row is None:
        raise ValueError(f"no plan day on {date}")
    return {"ok": True, "date": row[0], "dish": row[1], "mode": row[2], "status": row[3]}


def _parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="state_api")
    sub = p.add_subparsers(dest="verb", required=True)
    sub.add_parser("get-plan")
    d = sub.add_parser("update-day")
    d.add_argument("--date", required=True, type=datetime.date.fromisoformat)
    d.add_argument("--dish")
    d.add_argument("--mode")
    d.add_argument("--prep-note", dest="prep_note")
    d.add_argument("--status")
    d.add_argument("--reasoning")
    return p


def _dispatch(conn, household_id: str, args) -> dict:
    if args.verb == "get-plan":
        return get_plan(conn, household_id)
    if args.verb == "update-day":
        return update_day(conn, household_id, args.date, dish=args.dish,
                          mode=args.mode, prep_note=args.prep_note,
                          status=args.status, reasoning=args.reasoning)
    raise ValueError(f"unknown verb {args.verb}")


def main(argv=None) -> int:
    load_dotenv(pathlib.Path(__file__).resolve().parent / ".env")  # no-override
    args = _parser().parse_args(argv)
    try:
        household_id = os.environ.get("SOUS_HOUSEHOLD_ID")
        if not household_id:
            raise RuntimeError("SOUS_HOUSEHOLD_ID not set")
        with psycopg.connect(os.environ["SOUS_DB_URL"], autocommit=True) as conn:
            result = _dispatch(conn, household_id, args)
    except Exception as exc:  # noqa: BLE001 — errors go back to the model as JSON
        print(json.dumps({"ok": False, "error": str(exc)}, ensure_ascii=False))
        return 1
    print(json.dumps(result, ensure_ascii=False, default=str))
    return 0


if __name__ == "__main__":
    sys.exit(main())
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `uv run pytest tests/test_state_api.py -v`
Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
git add worker/state_api.py worker/tests/test_state_api.py
git commit -m "feat(worker): state_api write seam — get-plan + update-day"
```

---

### Task 3: `state_api.py` — `swap-days`

**Files:**
- Modify: `worker/state_api.py` (add function + parser branch + dispatch branch)
- Test: `worker/tests/test_state_api.py` (append)

**Interfaces:**
- Consumes: `api_hid` fixture, `_parser`/`_dispatch` from Task 2.
- Produces: `swap_days(conn, household_id, date_a, date_b) -> dict` — swaps the dish payload (dish, recipe_id, mode, prep_note, nutrition, reasoning) between two existing plan days; `status` stays with the calendar slot.

- [ ] **Step 1: Write the failing tests**

Append to `worker/tests/test_state_api.py`:

```python
def test_swap_days_swaps_dish_payload_not_status(conn, api_hid):
    conn.execute(
        "update plan_days set status='cooked' where household_id=%s and date=%s",
        (api_hid, MONDAY),
    )
    out = state_api.swap_days(conn, api_hid, MONDAY, TUESDAY)
    assert out["ok"] is True
    rows = conn.execute(
        "select date, dish, mode, prep_note, status from plan_days "
        "where household_id = %s order by date", (api_hid,),
    ).fetchall()
    assert rows[0] == (MONDAY, "三杯雞", "fast", None, "cooked")
    assert rows[1] == (TUESDAY, "咖哩飯", "batch", "前一晚醃肉", "planned")


def test_swap_days_requires_both_days(conn, api_hid):
    with pytest.raises(ValueError, match="both"):
        state_api.swap_days(conn, api_hid, MONDAY,
                            MONDAY + datetime.timedelta(days=30))


def test_cli_swap_days(api_hid):
    proc = _run_cli(["swap-days", "--date-a", str(MONDAY), "--date-b", str(TUESDAY)],
                    api_hid)
    assert proc.returncode == 0, proc.stderr
    assert json.loads(proc.stdout)["ok"] is True
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `uv run pytest tests/test_state_api.py -k swap -v`
Expected: FAIL with `AttributeError: ... has no attribute 'swap_days'`.

- [ ] **Step 3: Implement**

Add to `worker/state_api.py` after `update_day`:

```python
def swap_days(conn, household_id: str, date_a: datetime.date,
              date_b: datetime.date) -> dict:
    n = conn.execute(
        "select count(*) from plan_days where household_id = %s and date = any(%s)",
        (household_id, [date_a, date_b]),
    ).fetchone()[0]
    if n != 2:
        raise ValueError(f"both days must exist on the plan ({date_a}, {date_b})")
    # UPDATE ... FROM reads the pre-statement snapshot, so one statement swaps
    # both rows without a temp value. status stays with the calendar slot.
    conn.execute(
        "update plan_days t set dish=o.dish, recipe_id=o.recipe_id, mode=o.mode, "
        "prep_note=o.prep_note, nutrition=o.nutrition, reasoning=o.reasoning "
        "from plan_days o "
        "where t.household_id = %s and o.household_id = %s "
        "and t.date in (%s, %s) and o.date in (%s, %s) and t.date <> o.date",
        (household_id, household_id, date_a, date_b, date_a, date_b),
    )
    return {"ok": True, "swapped": [date_a, date_b]}
```

In `_parser()` add:

```python
    s = sub.add_parser("swap-days")
    s.add_argument("--date-a", dest="date_a", required=True,
                   type=datetime.date.fromisoformat)
    s.add_argument("--date-b", dest="date_b", required=True,
                   type=datetime.date.fromisoformat)
```

In `_dispatch` add:

```python
    if args.verb == "swap-days":
        return swap_days(conn, household_id, args.date_a, args.date_b)
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `uv run pytest tests/test_state_api.py -v` — all PASS.

- [ ] **Step 5: Commit**

```bash
git add worker/state_api.py worker/tests/test_state_api.py
git commit -m "feat(worker): state_api swap-days verb"
```

---

### Task 4: `state_api.py` — shopping, staple, inbox verbs

**Files:**
- Modify: `worker/state_api.py`
- Test: `worker/tests/test_state_api.py` (append)

**Interfaces:**
- Consumes: Task 2 scaffold; `week_monday`; `plan_weeks` for the current week id.
- Produces:
  - `add_shopping_item(conn, household_id, name, qty=None, section=None) -> dict` — dedupes case-insensitively against unchecked items (retry-safe upsert).
  - `remove_shopping_item(conn, household_id, name) -> dict` — deletes unchecked matches; `removed: 0` is still `ok` (idempotent).
  - `flag_staple(conn, household_id, name) -> dict` — upsert on `(household_id, name)`, sets `flagged_low=true`.
  - `capture_inbox(conn, household_id, kind, content) -> dict` — plain insert (duplicates harmless; ritual reconciles).

- [ ] **Step 1: Write the failing tests**

Append to `worker/tests/test_state_api.py`:

```python
def test_add_shopping_item_inserts_with_current_week(conn, api_hid):
    out = state_api.add_shopping_item(conn, api_hid, "soy sauce",
                                      qty="1 bottle", section="pantry")
    assert out["ok"] is True and out["deduped"] is False
    row = conn.execute(
        "select name, qty, section, checked, week_id is not null "
        "from shopping_items where household_id = %s", (api_hid,),
    ).fetchone()
    assert row == ("soy sauce", "1 bottle", "pantry", False, True)


def test_add_shopping_item_dedupes_case_insensitively(conn, api_hid):
    state_api.add_shopping_item(conn, api_hid, "soy sauce")
    out = state_api.add_shopping_item(conn, api_hid, "Soy Sauce", qty="2 bottles")
    assert out["deduped"] is True
    rows = conn.execute(
        "select qty from shopping_items where household_id = %s", (api_hid,),
    ).fetchall()
    assert rows == [("2 bottles",)]   # one row, qty refreshed


def test_remove_shopping_item_is_idempotent(conn, api_hid):
    state_api.add_shopping_item(conn, api_hid, "soy sauce")
    assert state_api.remove_shopping_item(conn, api_hid, "SOY SAUCE")["removed"] == 1
    assert state_api.remove_shopping_item(conn, api_hid, "soy sauce")["removed"] == 0


def test_remove_leaves_checked_items_alone(conn, api_hid):
    state_api.add_shopping_item(conn, api_hid, "soy sauce")
    conn.execute(
        "update shopping_items set checked=true where household_id=%s", (api_hid,),
    )
    assert state_api.remove_shopping_item(conn, api_hid, "soy sauce")["removed"] == 0


def test_flag_staple_upserts(conn, api_hid):
    first = state_api.flag_staple(conn, api_hid, "jasmine rice")
    again = state_api.flag_staple(conn, api_hid, "jasmine rice")
    assert first["ok"] and again["ok"]
    rows = conn.execute(
        "select name, flagged_low from staples where household_id = %s", (api_hid,),
    ).fetchall()
    assert rows == [("jasmine rice", True)]


def test_capture_inbox_inserts(conn, api_hid):
    out = state_api.capture_inbox(conn, api_hid, "craving", "想吃泰式")
    assert out["ok"] is True
    row = conn.execute(
        "select kind, content from inbox_items where household_id = %s", (api_hid,),
    ).fetchone()
    assert row == ("craving", "想吃泰式")


def test_cli_shopping_verbs(api_hid):
    add = _run_cli(["add-shopping-item", "--name", "fish sauce",
                    "--qty", "1", "--section", "pantry"], api_hid)
    assert json.loads(add.stdout)["ok"] is True
    rm = _run_cli(["remove-shopping-item", "--name", "fish sauce"], api_hid)
    assert json.loads(rm.stdout)["removed"] == 1
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `uv run pytest tests/test_state_api.py -k "shopping or staple or inbox" -v`
Expected: FAIL with `AttributeError`.

- [ ] **Step 3: Implement**

Add to `worker/state_api.py`:

```python
def _current_week_id(conn, household_id: str):
    row = conn.execute(
        "select id from plan_weeks where household_id = %s and week_of = %s",
        (household_id, week_monday(_household_today(conn, household_id))),
    ).fetchone()
    return row[0] if row else None


def add_shopping_item(conn, household_id: str, name: str,
                      qty=None, section=None) -> dict:
    existing = conn.execute(
        "select id from shopping_items where household_id = %s "
        "and checked = false and lower(name) = lower(%s)",
        (household_id, name),
    ).fetchone()
    if existing:
        conn.execute(
            "update shopping_items set qty = coalesce(%s, qty), "
            "section = coalesce(%s, section) where id = %s",
            (qty, section, existing[0]),
        )
        return {"ok": True, "name": name, "deduped": True}
    conn.execute(
        "insert into shopping_items (household_id, week_id, name, qty, section) "
        "values (%s, %s, %s, %s, %s)",
        (household_id, _current_week_id(conn, household_id), name, qty, section),
    )
    return {"ok": True, "name": name, "deduped": False}


def remove_shopping_item(conn, household_id: str, name: str) -> dict:
    removed = conn.execute(
        "delete from shopping_items where household_id = %s "
        "and checked = false and lower(name) = lower(%s) returning id",
        (household_id, name),
    ).fetchall()
    return {"ok": True, "name": name, "removed": len(removed)}


def flag_staple(conn, household_id: str, name: str) -> dict:
    conn.execute(
        "insert into staples (household_id, name, flagged_low) values (%s, %s, true) "
        "on conflict (household_id, name) do update set flagged_low = true",
        (household_id, name),
    )
    return {"ok": True, "name": name, "flagged_low": True}


def capture_inbox(conn, household_id: str, kind: str, content: str) -> dict:
    row = conn.execute(
        "insert into inbox_items (household_id, kind, content) "
        "values (%s, %s, %s) returning id::text",
        (household_id, kind, content),
    ).fetchone()
    return {"ok": True, "id": row[0], "kind": kind}
```

In `_parser()` add:

```python
    a = sub.add_parser("add-shopping-item")
    a.add_argument("--name", required=True)
    a.add_argument("--qty")
    a.add_argument("--section")
    r = sub.add_parser("remove-shopping-item")
    r.add_argument("--name", required=True)
    f = sub.add_parser("flag-staple")
    f.add_argument("--name", required=True)
    c = sub.add_parser("capture-inbox")
    c.add_argument("--kind", required=True, choices=["craving", "feedback", "note"])
    c.add_argument("--content", required=True)
```

In `_dispatch` add:

```python
    if args.verb == "add-shopping-item":
        return add_shopping_item(conn, household_id, args.name,
                                 qty=args.qty, section=args.section)
    if args.verb == "remove-shopping-item":
        return remove_shopping_item(conn, household_id, args.name)
    if args.verb == "flag-staple":
        return flag_staple(conn, household_id, args.name)
    if args.verb == "capture-inbox":
        return capture_inbox(conn, household_id, args.kind, args.content)
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `uv run pytest tests/test_state_api.py -v` — all PASS.

- [ ] **Step 5: Commit**

```bash
git add worker/state_api.py worker/tests/test_state_api.py
git commit -m "feat(worker): state_api shopping/staple/inbox verbs"
```

---

### Task 5: Worker wiring — tool allowlist, household env, pinned cwd

The brain subprocess gains: (a) a configurable tool allowlist including the state_api Bash prefix, (b) `SOUS_HOUSEHOLD_ID` in its environment (the security pin — the model never chooses the household), (c) `cwd=worker/` so `.venv/bin/python state_api.py` resolves regardless of where the daemon was started.

**Files:**
- Modify: `worker/sous_worker/brain.py`
- Modify: `worker/sous_worker/main.py:29-49` (`generate_chat_reply`)
- Modify: `worker/config.json`
- Test: `worker/tests/test_brain.py`, `worker/tests/test_main.py` (append)

**Interfaces:**
- Consumes: `state_api.py` CLI contract (Tasks 2–4); existing `run_brain`, `generate_chat_reply`.
- Produces: `run_brain(prompt, model="sonnet", timeout=480, allowed_tools=("Read",), cwd=None, extra_env=None) -> str` (`allowed_tools` is now a sequence — each entry becomes one `--allowedTools` value); config key `chat_allowed_tools: list[str]`.

- [ ] **Step 1: Write the failing tests**

Append to `worker/tests/test_brain.py`:

```python
def test_run_brain_passes_tools_env_and_cwd(tmp_path, monkeypatch):
    script = tmp_path / "claude"
    script.write_text('#!/bin/sh\necho "ARGS=$* HID=$SOUS_HOUSEHOLD_ID PWD=$(pwd -P)"\n')
    script.chmod(0o755)
    monkeypatch.setenv("CLAUDE_BIN", str(script))
    out = brain.run_brain(
        "hi", allowed_tools=["Read", "Bash(.venv/bin/python state_api.py:*)"],
        cwd=str(tmp_path), extra_env={"SOUS_HOUSEHOLD_ID": "h-1"},
    )
    assert "Bash(.venv/bin/python state_api.py:*)" in out
    assert "HID=h-1" in out
    assert f"PWD={tmp_path.resolve()}" in out
```

Append to `worker/tests/test_main.py`:

```python
def test_generate_chat_reply_wires_tools_env_cwd(conn, chat_job, monkeypatch):
    seen = {}

    def fake_brain(prompt, **kw):
        seen.update(kw)
        return "ok"

    monkeypatch.setattr(main.brain, "run_brain", fake_brain)
    job = db.claim_next_job(conn)
    cfg = main.load_config()
    main.generate_chat_reply(conn, job, cfg)
    assert seen["extra_env"] == {"SOUS_HOUSEHOLD_ID": SANDBOX}
    assert seen["cwd"] == str(main.ROOT)
    assert "Bash(.venv/bin/python state_api.py:*)" in seen["allowed_tools"]
```

(Match the existing imports at the top of `test_main.py` — it already imports `main`, `db`, and `SANDBOX` from conftest; add whichever are missing.)

- [ ] **Step 2: Run tests to verify they fail**

Run: `uv run pytest tests/test_brain.py tests/test_main.py -v`
Expected: new tests FAIL (`TypeError: run_brain() got an unexpected keyword argument 'cwd'` / missing keys in `seen`).

- [ ] **Step 3: Implement**

`worker/sous_worker/brain.py` — add `from collections.abc import Sequence` to the imports at the top, update the module docstring's "M1 brain is read-only" sentence to say write verbs arrive via the state_api Bash allowlist, and replace `run_brain`:

```python
def run_brain(prompt: str, model: str = "sonnet", timeout: int = 480,
              allowed_tools: Sequence[str] = ("Read",), cwd: str | None = None,
              extra_env: dict | None = None) -> str:
    env = None if extra_env is None else {**os.environ, **extra_env}
    try:
        result = subprocess.run(
            [_claude_bin(), "-p", "--model", model, "--allowedTools", *allowed_tools],
            input=prompt.encode(),
            capture_output=True,
            timeout=timeout,
            cwd=cwd,
            env=env,
        )
    except subprocess.TimeoutExpired:
        raise RuntimeError(f"brain timed out after {timeout}s") from None
    if result.returncode != 0:
        raise RuntimeError(
            f"brain exited {result.returncode}: {result.stderr.decode()[:500]}"
        )
    return result.stdout.decode().strip()
```

`worker/sous_worker/main.py` — the `return` in `generate_chat_reply` becomes:

```python
    return brain.run_brain(prompt, model=cfg["chat_model"],
                           timeout=cfg["chat_timeout_sec"],
                           allowed_tools=cfg["chat_allowed_tools"],
                           cwd=str(ROOT),
                           extra_env={"SOUS_HOUSEHOLD_ID": job.household_id})
```

Also update `generate_chat_reply`'s docstring first line: it is no longer "reads only, no writes" — the brain now writes through state_api subprocesses; the *worker's own* connection still does no writes here (the transaction-scope reasoning in the rest of the docstring is unchanged and still applies).

`worker/config.json` — add one key:

```json
{
  "chat_model": "sonnet",
  "chat_timeout_sec": 480,
  "chat_allowed_tools": ["Read", "Bash(.venv/bin/python state_api.py:*)"],
  "poll_interval_sec": 3,
  "heartbeat_interval_sec": 15,
  "stale_after_sec": 600,
  "max_attempts": 2,
  "history_limit": 20
}
```

- [ ] **Step 4: Run the full worker suite**

Run: `uv run pytest -v`
Expected: ALL PASS (older `test_main.py` fakes take `(prompt, model, timeout)` positionally — if any break on the new kwargs, change their signatures to `def fake_brain(prompt, **kw)`).

- [ ] **Step 5: Commit**

```bash
git add worker/sous_worker/brain.py worker/sous_worker/main.py worker/config.json worker/tests/test_brain.py worker/tests/test_main.py
git commit -m "feat(worker): brain gains state_api Bash allowlist + per-job household env pin"
```

---

### Task 6: Write-enabled chat prompt

Replace the read-only rules in `worker/prompts/chat.md` with verb documentation and write etiquette. Persona discipline: the template must contain no persona names — voice comes from `{persona_pack}`.

**Files:**
- Modify: `worker/prompts/chat.md` (full replacement below)
- Test: `worker/tests/test_prompts.py` (create)

**Interfaces:**
- Consumes: verb CLI shapes from Tasks 2–4 (exact command lines).
- Produces: the M2a chat prompt; placeholders unchanged (`{persona_pack}`, `{today}`, `{weekday}`, `{week_plan}`, `{preferences}`, `{cookbook_index}`, `{shopping_open}`, `{history}`, `{messages}`) so `build_chat_prompt` needs no changes.

- [ ] **Step 1: Write the failing tests**

Create `worker/tests/test_prompts.py`:

```python
import pathlib

PROMPT = (pathlib.Path(__file__).resolve().parent.parent / "prompts" / "chat.md").read_text()

M2A_VERBS = ["get-plan", "update-day", "swap-days", "add-shopping-item",
             "remove-shopping-item", "flag-staple", "capture-inbox"]


def test_chat_prompt_documents_every_m2a_verb():
    for verb in M2A_VERBS:
        assert verb in PROMPT, f"chat.md must document {verb}"
    assert ".venv/bin/python state_api.py" in PROMPT  # exact allowlisted prefix


def test_chat_prompt_is_persona_neutral():
    assert "小當家" not in PROMPT   # voice arrives only via {persona_pack}


def test_chat_prompt_dropped_readonly_rule():
    assert "唯讀" not in PROMPT


def test_chat_prompt_keeps_all_placeholders():
    for ph in ["{persona_pack}", "{today}", "{weekday}", "{week_plan}",
               "{preferences}", "{cookbook_index}", "{shopping_open}",
               "{history}", "{messages}"]:
        assert ph in PROMPT
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `uv run pytest tests/test_prompts.py -v`
Expected: `test_chat_prompt_documents_every_m2a_verb` and `test_chat_prompt_dropped_readonly_rule` FAIL against the M1 prompt.

- [ ] **Step 3: Replace `worker/prompts/chat.md` with:**

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

## 你的手(state_api — 改動廚房狀態的唯一途徑)
用 Bash 執行以下指令。每個指令回一行 JSON;看到 "ok": true 才算改成功,
沒看到就不能宣稱改好了。日期一律 YYYY-MM-DD。

- 查本週菜單現況(動手前不確定就先查):
  `.venv/bin/python state_api.py get-plan`
- 改某一天(換菜、改備註、標記煮了/跳過):
  `.venv/bin/python state_api.py update-day --date 2026-07-15 --dish 三杯雞`
  可用:`--dish` `--mode`(batch/fast/leftover/play)`--prep-note` `--status`(planned/cooked/skipped)`--reasoning`
- 兩天對調:
  `.venv/bin/python state_api.py swap-days --date-a 2026-07-15 --date-b 2026-07-17`
- 採買清單加東西(名稱一律英文,方便在 Woolworths 搜尋):
  `.venv/bin/python state_api.py add-shopping-item --name "soy sauce" --qty "1 bottle" --section pantry`
- 採買清單移除:
  `.venv/bin/python state_api.py remove-shopping-item --name "soy sauce"`
- 常備品快沒了(醬油、米、蒜頭這類):
  `.venv/bin/python state_api.py flag-staple --name "soy sauce"`
- 記進 inbox,下次排菜單時處理(想吃的、回饋、雜記):
  `.venv/bin/python state_api.py capture-inbox --kind craving --content "想吃泰式"`

## 規則
- 對方要求改動:直接動手,做完明確講你改了什麼(例:「好!週三換成三杯雞了」)。
  要求太模糊(「換一道」但沒說換什麼)就先問清楚再動。
- 上面渲染好的狀態若「已經」反映了對方的要求,不要重複執行(可能是系統重試)—
  直接回報現況即可。
- 只回報 state_api 確認過(ok: true)的改動;失敗就老實說失敗,不要假裝成功。
- 你還做不到的事(存新食譜、重排整週菜單、發通知)老實說之後的版本會有。
- 回答菜單、食譜、料理問題,用上面渲染好的資訊;看不到的(完整食譜步驟、更久的
  歷史)老實說看不到,不要編造。
- 料理求救(技巧、替代食材、火候)照你的專業回答:給感官判斷線索、講為什麼、
  點出新手最常犯的錯。
- 回覆通常 ≤ 幾句話。不要署名;emoji 點到為止。不要用 markdown 表格;要列就條列。

最近對話:
{history}

需要回覆的新訊息:
{messages}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `uv run pytest tests/test_prompts.py tests/test_context.py -v` — all PASS.

- [ ] **Step 5: Commit**

```bash
git add worker/prompts/chat.md worker/tests/test_prompts.py
git commit -m "feat(worker): write-enabled chat prompt documenting state_api verbs"
```

---

### Task 7: iOS — Tonight card live-refreshes on plan edits

When the brain edits `plan_days`, the Kitchen Counter's Tonight card must update without an app restart. `plan_days` is already in the realtime publication; add a subscription that refetches on any change.

**Files:**
- Modify: `ios/Sous/AppModel.swift:103-122` (`subscribe()`)

**Interfaces:**
- Consumes: existing `loadTonight()`, channel `"kitchen"`, supabase-swift `postgresChange(AnyAction.self, …)`.
- Produces: no new API — behavioral change only.

- [ ] **Step 1: Implement**

In `subscribe()`, replace the first `Task { … }` block with:

```swift
        Task {
            let channel = client.channel("kitchen")
            let inserts = channel.postgresChange(
                InsertAction.self, schema: "public", table: "chat_messages"
            )
            let planChanges = channel.postgresChange(
                AnyAction.self, schema: "public", table: "plan_days"
            )
            await channel.subscribe()
            Task {
                for await _ in planChanges {
                    await loadTonight()
                }
            }
            for await _ in inserts {
                await loadMessages()
            }
        }
```

(Both change streams must be created **before** `channel.subscribe()` — supabase-swift registers bindings at subscribe time. The presence-poll Task below stays as is.)

- [ ] **Step 2: Build to verify it compiles**

Run: `cd /Users/mikeweng/Projects/sous/ios && xcodebuild -project Sous.xcodeproj -scheme Sous -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build 2>&1 | tail -5`
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 3: Manual realtime verification (cloud)**

With the app running in the simulator (signed in, Tonight card visible), run from `worker/` (uses the cloud `SOUS_DB_URL` from `worker/.env`; get the sandbox household id from the cloud `households` table first):

```bash
SOUS_HOUSEHOLD_ID=<sandbox-household-uuid> .venv/bin/python state_api.py \
  update-day --date <today YYYY-MM-DD> --dish 測試熱更新
```

Expected: the Tonight card shows 測試熱更新 within ~2s, no app restart. Then run it again restoring the original dish. (This step doubles as the first real-database exercise of `update-day`.)

- [ ] **Step 4: Run iOS tests + commit**

Run: `xcodebuild -project Sous.xcodeproj -scheme Sous -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test 2>&1 | tail -5`
Expected: existing PresenceTests PASS.

```bash
git add ios/Sous/AppModel.swift
git commit -m "feat(ios): tonight card live-refreshes on plan_days realtime changes"
```

---

### Task 8: Gated real-brain write smoke test + suite green

One end-to-end proof against the local stack with a **real** `claude -p`: a chat message asking for a shopping addition results in an actual `shopping_items` row plus an in-character confirmation. Gated behind `SOUS_SMOKE=1` (slow, costs a subscription turn) — same pattern as M1's smoke verification.

**Files:**
- Create: `worker/tests/test_smoke_write.py`

**Interfaces:**
- Consumes: `process_one`, `load_config`, conftest `conn`/`SANDBOX`; Tasks 1–6 all land before this.

- [ ] **Step 1: Write the smoke test**

Create `worker/tests/test_smoke_write.py`:

```python
"""Real-brain write-path smoke test. Slow (~30-90s) and uses a real
`claude -p` turn — run explicitly with:  SOUS_SMOKE=1 uv run pytest tests/test_smoke_write.py -v
Requires the local Supabase stack (conftest TEST_DB_URL)."""
import os

import pytest
from psycopg.types.json import Jsonb

from sous_worker import db, main
from tests.conftest import SANDBOX, TEST_DB_URL

pytestmark = pytest.mark.skipif(
    not os.environ.get("SOUS_SMOKE"), reason="set SOUS_SMOKE=1 to run the real-brain smoke test"
)


def test_brain_adds_shopping_item_end_to_end(conn, monkeypatch):
    # state_api subprocesses must hit the local stack, not the .env cloud URL.
    monkeypatch.setenv("SOUS_DB_URL", TEST_DB_URL)
    conn.execute(
        "delete from shopping_items where household_id = %s "
        "and lower(name) like '%%oyster%%'", (SANDBOX,),
    )
    mid = conn.execute(
        "insert into chat_messages (household_id, sender, content) "
        "values (%s, 'user', %s) returning id::text",
        (SANDBOX, "幫我把 oyster sauce 加進這週的採買清單,一瓶就好"),
    ).fetchone()[0]
    jid = conn.execute(
        "insert into jobs (household_id, kind, payload) "
        "values (%s, 'chat', %s) returning id::text",
        (SANDBOX, Jsonb({"message_id": mid})),
    ).fetchone()[0]
    try:
        assert main.process_one(conn, main.load_config()) is True
        status = conn.execute(
            "select status from jobs where id = %s", (jid,)).fetchone()[0]
        assert status == "done"
        item = conn.execute(
            "select name from shopping_items where household_id = %s "
            "and lower(name) like '%%oyster%%'", (SANDBOX,),
        ).fetchone()
        assert item is not None, "brain never called add-shopping-item"
        reply = conn.execute(
            "select content from chat_messages where household_id = %s "
            "and sender = 'chef' order by created_at desc limit 1", (SANDBOX,),
        ).fetchone()[0]
        assert reply  # in-character confirmation exists
    finally:
        conn.execute(
            "delete from shopping_items where household_id = %s "
            "and lower(name) like '%%oyster%%'", (SANDBOX,),
        )
```

- [ ] **Step 2: Run the fast suite (smoke skipped)**

Run: `uv run pytest -v`
Expected: all PASS; `test_smoke_write.py` shows SKIPPED.

- [ ] **Step 3: Run the smoke test for real**

Run: `SOUS_SMOKE=1 uv run pytest tests/test_smoke_write.py -v`
Expected: PASS — job `done`, oyster sauce row existed, chef replied. If the brain answers without calling the verb, that's a **prompt** problem: tighten the 規則 section in `chat.md` (Task 6) rather than the harness.

- [ ] **Step 4: Commit**

```bash
git add worker/tests/test_smoke_write.py
git commit -m "test(worker): gated real-brain write-path smoke test"
```

---

### Task 9: Deploy + M2a real-use exit check

No new code — bring the cloud environment up to date and verify live from the phone (household rule: verify via real use).

- [ ] **Step 1: Re-apply the seed to cloud**

The cloud week bucket still carries the UTC anchor (plus the M1 live workaround row). Re-apply the fixed seed against the cloud project (same flow as M1 Task 9): `supabase db push` if there are new migrations (there are none in M2a), then run `supabase/seed.sql` against the cloud DB via psql with the cloud `SOUS_DB_URL`. If the seed conflicts with existing rows (`unique (household_id, date)` etc.), first delete the sandbox household's `plan_weeks` rows for the current week (cascades to `plan_days`) and the current week's `shopping_items`, then re-run the seed's week/shopping sections. **Do not truncate `chat_messages`** — keep the real conversation history.

- [ ] **Step 2: Restart the worker with the new config**

Kill the running worker, start it again from `worker/` (`uv run python -m sous_worker.main`), confirm the heartbeat log line and that `config.json` now includes `chat_allowed_tools`.

- [ ] **Step 3: Real-use exit checks (from the phone)**

1. 「今晚不想吃<current dish>,換成三杯雞」 → chef confirms in-persona; `plan_days` row changed; **Tonight card updates live without reopening the app**.
2. 「醬油快沒了」 → chef confirms; `staples` row has `flagged_low=true` (spec: staple flagging goes to the flag, not straight to the list).
3. 「幫我把 fish sauce 加進採買清單」 → `shopping_items` row appears, English name.
4. Ask 「本週菜單是什麼?」 after Sydney midnight if feasible — the reply must name **today's** correct week (the timezone fix, live).
5. An impossible ask (「存一道新食譜」) → honest 之後的版本 refusal, no fake success.

- [ ] **Step 4: Record results + update memory**

Append a `## M2a exit verification` section to this plan file with pass/fail notes per check, commit as `docs: M2a exit verification notes`, and update the project-status memory file.

---

## Explicitly deferred to M2b / M2c (do not build here)

- `set-plan` verb, ritual mode/prompt, plan_weeks draft→locked flow → **M2b** (ritual + week/shopping sheets, including iOS drag-to-swap which reuses `swap-days`).
- `save-recipe`, `clear-inbox` verbs, recipe_intake mode, structured steps enrichment, share-sheet extension, cookbook sheet, cook mode → **M2c**.
- `queue-notification`, `post-card` verbs, APNs pipeline → **M3** (queue-notification lands with notif_generate).
- Chat `cards` JSONB rendering — chat stays text-only until M2b's rich week-proposal card.
