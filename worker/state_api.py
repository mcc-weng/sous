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

from dotenv import load_dotenv

# Invoked with cwd = worker/, so the script dir is on sys.path.
from sous_worker.context import week_monday
from sous_worker.db import connect

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


def _current_week_id(conn, household_id: str):
    row = conn.execute(
        "select id from plan_weeks where household_id = %s and week_of = %s",
        (household_id, week_monday(_household_today(conn, household_id))),
    ).fetchone()
    return row[0] if row else None


def add_shopping_item(conn, household_id: str, name: str,
                      qty=None, section=None) -> dict:
    # Atomic upsert against the partial unique index on (household_id,
    # lower(name)) where checked = false (migration 0003) — a plain
    # check-then-act select+insert/update would race under concurrent brain
    # tool calls in the same session turn and could double-insert.
    row = conn.execute(
        "insert into shopping_items (household_id, week_id, name, qty, section) "
        "values (%s, %s, %s, %s, %s) "
        "on conflict (household_id, lower(name)) where checked = false "
        "do update set qty = coalesce(excluded.qty, shopping_items.qty), "
        "section = coalesce(excluded.section, shopping_items.section) "
        "returning (xmax = 0) as inserted",
        (household_id, _current_week_id(conn, household_id), name, qty, section),
    ).fetchone()
    return {"ok": True, "name": name, "deduped": not row[0]}


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


def clear_inbox(conn, household_id: str) -> dict:
    removed = conn.execute(
        "delete from inbox_items where household_id = %s returning id",
        (household_id,),
    ).fetchall()
    return {"ok": True, "removed": len(removed)}


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


class _JSONErrorParser(argparse.ArgumentParser):
    """Route argparse-level failures (bad flags, unknown verb) through the
    same {"ok": false, "error": ...} + exit 1 contract as every other
    failure, instead of argparse's default usage-text-to-stderr + exit 2.
    Subparsers inherit this class too (argparse's add_subparsers defaults
    parser_class to type(self))."""

    def error(self, message):
        raise ValueError(message)


def _parser() -> argparse.ArgumentParser:
    p = _JSONErrorParser(prog="state_api")
    sub = p.add_subparsers(dest="verb", required=True)
    sub.add_parser("get-plan")
    d = sub.add_parser("update-day")
    d.add_argument("--date", required=True, type=datetime.date.fromisoformat)
    d.add_argument("--dish")
    d.add_argument("--mode")
    d.add_argument("--prep-note", dest="prep_note")
    d.add_argument("--status")
    d.add_argument("--reasoning")
    s = sub.add_parser("swap-days")
    s.add_argument("--date-a", dest="date_a", required=True,
                   type=datetime.date.fromisoformat)
    s.add_argument("--date-b", dest="date_b", required=True,
                   type=datetime.date.fromisoformat)
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
    sp = sub.add_parser("set-plan")
    sp.add_argument("--days", required=True,
                    help='JSON array: [{"date","dish","mode"?,"prep_note"?,"reasoning"?}, ...] — exactly 7 entries')
    sp.add_argument("--shopping-items", dest="shopping_items", default="[]",
                    help='JSON array: [{"name","qty"?,"section"?}, ...]')
    sp.add_argument("--reasoning")
    sub.add_parser("clear-inbox")
    return p


def _dispatch(conn, household_id: str, args) -> dict:
    if args.verb == "get-plan":
        return get_plan(conn, household_id)
    if args.verb == "update-day":
        return update_day(conn, household_id, args.date, dish=args.dish,
                          mode=args.mode, prep_note=args.prep_note,
                          status=args.status, reasoning=args.reasoning)
    if args.verb == "swap-days":
        return swap_days(conn, household_id, args.date_a, args.date_b)
    if args.verb == "add-shopping-item":
        return add_shopping_item(conn, household_id, args.name,
                                 qty=args.qty, section=args.section)
    if args.verb == "remove-shopping-item":
        return remove_shopping_item(conn, household_id, args.name)
    if args.verb == "flag-staple":
        return flag_staple(conn, household_id, args.name)
    if args.verb == "capture-inbox":
        return capture_inbox(conn, household_id, args.kind, args.content)
    if args.verb == "set-plan":
        try:
            days = json.loads(args.days)
            shopping_items = json.loads(args.shopping_items)
        except json.JSONDecodeError as exc:
            raise ValueError(f"invalid JSON in --days or --shopping-items: {exc}") from None
        return set_plan(conn, household_id, days, shopping_items,
                        reasoning=args.reasoning)
    if args.verb == "clear-inbox":
        return clear_inbox(conn, household_id)
    raise ValueError(f"unknown verb {args.verb}")


def main(argv=None) -> int:
    load_dotenv(pathlib.Path(__file__).resolve().parent / ".env")  # no-override
    try:
        args = _parser().parse_args(argv)
        household_id = os.environ.get("SOUS_HOUSEHOLD_ID")
        if not household_id:
            raise RuntimeError("SOUS_HOUSEHOLD_ID not set")
        with connect() as conn:
            result = _dispatch(conn, household_id, args)
    except Exception as exc:  # noqa: BLE001 — errors go back to the model as JSON
        print(json.dumps({"ok": False, "error": str(exc)}, ensure_ascii=False))
        return 1
    print(json.dumps(result, ensure_ascii=False, default=str))
    return 0


if __name__ == "__main__":
    sys.exit(main())
