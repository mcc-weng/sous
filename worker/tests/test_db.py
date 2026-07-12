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
