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
