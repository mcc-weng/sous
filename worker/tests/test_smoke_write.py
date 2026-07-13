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
