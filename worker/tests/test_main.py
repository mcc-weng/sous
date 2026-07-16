from sous_worker import db, main
from tests.conftest import SANDBOX


def _cfg():
    return {"chat_model": "sonnet", "chat_timeout_sec": 480,
            "chat_allowed_tools": ["Read", "Bash(.venv/bin/python state_api.py:*)"],
            "poll_interval_sec": 0, "heartbeat_interval_sec": 15,
            "stale_after_sec": 600, "max_attempts": 2, "history_limit": 20}


def test_process_one_happy_path(conn, chat_job, monkeypatch):
    mid, jid = chat_job
    captured = {}

    def fake_brain(prompt, **kw):
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

    def fake_brain(prompt, **kw):
        return "今晚是蔥香雞腿飯!"

    def broken_complete(*a, **kw):
        raise RuntimeError("connection blip")

    monkeypatch.setattr(main.brain, "run_brain", fake_brain)
    monkeypatch.setattr(main.db, "complete_job", broken_complete)

    assert main.process_one(conn, _cfg()) is True

    # the chef reply insert (done by process_one, before complete_job, inside
    # the same transaction) must have been rolled back along with the failed
    # complete_job — no orphaned reply.
    reply_count = conn.execute(
        "select count(*) from chat_messages where sender='chef'"
    ).fetchone()[0]
    assert reply_count == 0

    # job is back to queued for a clean retry (attempts=1 < max_attempts=2)
    status = conn.execute("select status from jobs where id=%s", (jid,)).fetchone()[0]
    assert status == "queued"


def test_process_one_idle_returns_false(conn):
    assert main.process_one(conn, _cfg()) is False


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


def test_unknown_job_kind_fails_cleanly(conn):
    jid = conn.execute(
        "insert into jobs (household_id, kind) values (%s,'recipe_intake') returning id::text",
        (SANDBOX,),
    ).fetchone()[0]
    cfg = _cfg() | {"max_attempts": 1}
    main.process_one(conn, cfg)
    status, result = conn.execute(
        "select status, result from jobs where id=%s", (jid,)
    ).fetchone()
    assert status == "failed" and "unknown job kind" in result["error"]


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
