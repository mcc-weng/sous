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
        "insert into jobs (household_id, kind) values (%s,'bogus_kind') returning id::text",
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


def _insert_recipe_intake_job(conn, url: str, by: str = "mike"):
    jid = conn.execute(
        "insert into jobs (household_id, kind, payload) "
        "values (%s, 'recipe_intake', %s) returning id::text",
        (SANDBOX, Jsonb({"url": url, "by": by})),
    ).fetchone()[0]
    return jid


def test_recipe_intake_job_runs_prefetch_and_wires_prompt(conn, monkeypatch):
    seen = {}

    def fake_prefetch(url):
        seen["prefetch_url"] = url
        return {"source": "caption", "title": "三杯雞", "uploader": "x", "description": "y"}

    def fake_run_brain(prompt, **kw):
        seen["prompt"] = prompt
        seen.update(kw)
        return "存好了!🔥 三杯雞排進下週候選了"

    monkeypatch.setattr(main.gemini_intake, "fetch_recipe_context", fake_prefetch)
    monkeypatch.setattr(main.brain, "run_brain", fake_run_brain)
    jid = _insert_recipe_intake_job(conn, "https://instagram.com/reel/abc")
    assert main.process_one(conn, main.load_config()) is True

    assert seen["prefetch_url"] == "https://instagram.com/reel/abc"
    assert "三杯雞" in seen["prompt"]          # caption title rendered into the prompt
    assert "WebFetch" in seen["allowed_tools"]
    assert seen["extra_env"] == {"SOUS_HOUSEHOLD_ID": SANDBOX}

    sender, content, job_id = conn.execute(
        "select sender, content, job_id::text from chat_messages "
        "where sender='chef' order by created_at desc limit 1"
    ).fetchone()
    assert content == "存好了!🔥 三杯雞排進下週候選了" and job_id == jid
    result = conn.execute("select result from jobs where id=%s", (jid,)).fetchone()[0]
    assert result["mode"] == "recipe_intake"


def _fake_run_brain_locks_week(conn):
    """A fake run_brain that locks the target week as its side effect, standing in
    for what a real brain turn's `state_api.py set-plan` subprocess call would have
    done. Must run AFTER ensure_proposing_week has created the 'proposing' row —
    generate_ritual_reply calls that before invoking run_brain, so by the time this
    fake fires (inside process_one, via run_brain) the row already exists."""
    def fake(prompt, **kw):
        conn.execute(
            "update plan_weeks set status='locked' "
            "where household_id=%s and status='proposing'", (SANDBOX,),
        )
        return "好,這週排好了!"
    return fake


def test_ritual_lock_enqueues_week_batch_notif_job(conn, monkeypatch):
    monkeypatch.setattr(main.brain, "run_brain", _fake_run_brain_locks_week(conn))
    _insert_ritual_job(conn)
    assert main.process_one(conn, main.load_config()) is True

    # order by week_of desc: the seeded SANDBOX household already has a locked
    # *current* week from supabase/seed.sql — the newly-locked *next* week sorts
    # after it, so this reliably picks the one this test just created.
    week_row = conn.execute(
        "select id::text from plan_weeks where household_id=%s and status='locked' "
        "order by week_of desc limit 1", (SANDBOX,),
    ).fetchone()
    assert week_row is not None
    try:
        job = conn.execute(
            "select payload from jobs where household_id=%s and kind='notif_generate' "
            "order by created_at desc limit 1", (SANDBOX,),
        ).fetchone()
        assert job is not None
        assert job[0] == {"notif_kind": "week_batch", "week_id": week_row[0]}
    finally:
        # Must clean up: plan_weeks isn't truncated between tests (unlike jobs/
        # chat_messages), and this row would otherwise collide with any later test
        # that also targets "next week" for SANDBOX (e.g. test_state_api.py's
        # test_cancel_ritual_scopes_to_household — caught via a real cross-test
        # failure when this cleanup was missing).
        conn.execute("delete from plan_weeks where id=%s", (week_row[0],))


def test_ritual_lock_enqueue_is_idempotent_on_retry(conn, monkeypatch):
    monkeypatch.setattr(main.brain, "run_brain", _fake_run_brain_locks_week(conn))
    _insert_ritual_job(conn)
    assert main.process_one(conn, main.load_config()) is True
    week_row = conn.execute(
        "select id::text from plan_weeks where household_id=%s and status='locked' "
        "order by week_of desc limit 1", (SANDBOX,),
    ).fetchone()
    assert week_row is not None
    try:
        # A second ritual-kind job arrives for the same already-locked week (e.g. a
        # retried turn, or the user re-entering ritual chat after it's already locked).
        # generate_ritual_reply's ensure_proposing_week is a no-op here since the week
        # is already 'locked', not 'proposing' — so the fake run_brain's own UPDATE
        # matches zero rows the second time, which is fine, it's idempotent too.
        _insert_ritual_job(conn)
        assert main.process_one(conn, main.load_config()) is True

        count = conn.execute(
            "select count(*) from jobs where household_id=%s and kind='notif_generate' "
            "and payload->>'week_id'=%s", (SANDBOX, week_row[0]),
        ).fetchone()[0]
        assert count == 1
    finally:
        conn.execute("delete from plan_weeks where id=%s", (week_row[0],))


def _insert_notif_week_job(conn, week_id: str):
    return conn.execute(
        "insert into jobs (household_id, kind, payload) "
        "values (%s, 'notif_generate', %s) returning id::text",
        (SANDBOX, Jsonb({"notif_kind": "week_batch", "week_id": week_id})),
    ).fetchone()[0]


def test_notif_generate_failure_skips_apology_message(conn, monkeypatch):
    # _apologize's in-character "可惡…廚房出了點狀況!" message is meant for
    # user-initiated actions (chat/ritual/recipe_intake) that visibly failed — a
    # notif_generate job is a background side effect the user never asked for in
    # this turn, so its failure must not inject a spurious chat message.
    def broken_brain(*a, **kw):
        raise RuntimeError("boom")
    monkeypatch.setattr(main.brain, "run_brain", broken_brain)
    week_id = conn.execute(
        "select id::text from plan_weeks where household_id=%s and status='locked' "
        "order by week_of desc limit 1", (SANDBOX,),
    ).fetchone()[0]
    _insert_notif_week_job(conn, week_id)
    cfg = main.load_config() | {"max_attempts": 1}
    main.process_one(conn, cfg)
    apology_count = conn.execute(
        "select count(*) from chat_messages where sender='chef' and content like '%可惡%'"
    ).fetchone()[0]
    assert apology_count == 0


def test_notif_generate_week_batch_uses_notif_week_prompt(conn, monkeypatch):
    seen = {}
    def fake_run_brain(prompt, **kw):
        seen["prompt"] = prompt
        return "已排定這週的通知"
    monkeypatch.setattr(main.brain, "run_brain", fake_run_brain)
    week_id = conn.execute(
        "select id::text from plan_weeks where household_id=%s and status='locked' "
        "order by week_of desc limit 1", (SANDBOX,),
    ).fetchone()[0]
    jid = _insert_notif_week_job(conn, week_id)
    assert main.process_one(conn, main.load_config()) is True
    assert "schedule-notification" in seen["prompt"]
    # no chat_messages row — notif_generate is not a user-facing reply
    linked = conn.execute(
        "select count(*) from chat_messages where job_id=%s", (jid,)
    ).fetchone()[0]
    assert linked == 0
    result = conn.execute("select result from jobs where id=%s", (jid,)).fetchone()[0]
    assert result["mode"] == "notif_generate"
