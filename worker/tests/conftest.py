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
