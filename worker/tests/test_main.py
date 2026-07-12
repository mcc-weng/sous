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


def test_process_one_rolls_back_reply_if_complete_fails(conn, chat_job, monkeypatch):
    _, jid = chat_job

    def fake_brain(prompt, model, timeout, allowed_tools="Read"):
        return "今晚是蔥香雞腿飯!"

    def broken_complete(*a, **kw):
        raise RuntimeError("connection blip")

    monkeypatch.setattr(main.brain, "run_brain", fake_brain)
    monkeypatch.setattr(main.db, "complete_job", broken_complete)

    assert main.process_one(conn, _cfg()) is True

    # the chef reply insert (a side effect of handle_chat_job) must have been
    # rolled back along with the failed complete_job — no orphaned reply.
    reply_count = conn.execute(
        "select count(*) from chat_messages where sender='chef'"
    ).fetchone()[0]
    assert reply_count == 0

    # job is back to queued for a clean retry (attempts=1 < max_attempts=2)
    status = conn.execute("select status from jobs where id=%s", (jid,)).fetchone()[0]
    assert status == "queued"


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
