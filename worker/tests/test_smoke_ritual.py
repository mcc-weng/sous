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
