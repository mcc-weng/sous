"""Sous worker v0: poll → claim → render → brain → reply row.

Realtime job subscription is a M2 optimization; a 3s poll on an indexed
status column is plenty for one household and much simpler to reason about.
"""
import json
import logging
import pathlib
import time

from dotenv import load_dotenv

from sous_worker import brain, context, db, gemini_intake

ROOT = pathlib.Path(__file__).resolve().parent.parent  # worker/
log = logging.getLogger("sous_worker")


def load_config() -> dict:
    return json.loads((ROOT / "config.json").read_text())


def _apologize(conn, household_id: str, job_id: str) -> None:
    copy_pack = db.get_household(conn, household_id)["copy_pack"]
    message = copy_pack.get("failure_message", "Something went wrong — please try again.")
    db.insert_chef_message(conn, household_id, message, job_id)


def generate_chat_reply(conn, job: db.Job, cfg: dict) -> str:
    """Fetch context and run the brain — the worker's own connection does no
    writes here; the brain now writes through state_api subprocesses.

    Deliberately kept outside any DB transaction: brain.run_brain() shells out
    to `claude -p` and can block up to cfg["chat_timeout_sec"] (480s) for a
    heavy turn. Holding a transaction open across that wait would leave the
    connection idle-in-transaction for minutes, risking it getting killed by
    a server-side idle_in_transaction_session_timeout or pooler timeout right
    as generation finishes (see finding: worker now points at pooled/cloud
    Postgres, not just local).
    """
    ctx = context.fetch_context(conn, job.household_id, cfg["history_limit"])
    template = (ROOT / "prompts" / "chat.md").read_text()
    new_message = ""
    if job.payload.get("message_id"):
        content = db.get_message_content(conn, job.payload["message_id"])
        if content is not None:
            new_message = f"user: {content}"
    prompt = context.build_chat_prompt(template, ctx, new_message or "(none)")
    return brain.run_brain(prompt, model=cfg["chat_model"],
                           timeout=cfg["chat_timeout_sec"],
                           allowed_tools=cfg["chat_allowed_tools"],
                           cwd=str(ROOT),
                           extra_env={"SOUS_HOUSEHOLD_ID": job.household_id})


def generate_ritual_reply(conn, job: db.Job, cfg: dict) -> str:
    """Ritual mode: same shape as generate_chat_reply, but renders the ritual
    context/prompt and deterministically ensures a 'proposing' plan_weeks row
    exists for the target week before the brain runs (idempotent — a retry
    re-enters this function and finds the row already there)."""
    ctx = context.fetch_ritual_context(conn, job.household_id, cfg["history_limit"])
    db.ensure_proposing_week(conn, job.household_id, ctx["target_week_of"])
    template = (ROOT / "prompts" / "ritual.md").read_text()
    new_message = ""
    if job.payload.get("message_id"):
        content = db.get_message_content(conn, job.payload["message_id"])
        if content is not None:
            new_message = f"user: {content}"
    prompt = context.build_ritual_prompt(template, ctx, new_message or "(none)")
    return brain.run_brain(prompt, model=cfg["chat_model"],
                           timeout=cfg["chat_timeout_sec"],
                           allowed_tools=cfg["chat_allowed_tools"],
                           cwd=str(ROOT),
                           extra_env={"SOUS_HOUSEHOLD_ID": job.household_id})


def generate_recipe_intake_reply(conn, job: db.Job, cfg: dict) -> str:
    """Recipe intake: a worker-side, deterministic Gemini pre-fetch (ported
    from alfred's listener.py) runs before the brain is invoked at all — the
    brain never calls the video pipeline itself, only sees rendered text."""
    url = job.payload["url"]
    by = job.payload.get("by", "someone")
    prefetch = gemini_intake.fetch_recipe_context(url)
    ctx = context.fetch_recipe_intake_context(conn, job.household_id)
    template = (ROOT / "prompts" / "recipe_intake.md").read_text()
    prompt = context.build_recipe_intake_prompt(template, ctx, url, by, prefetch)
    return brain.run_brain(prompt, model=cfg["chat_model"],
                           timeout=cfg["recipe_intake_timeout_sec"],
                           allowed_tools=cfg["recipe_intake_allowed_tools"],
                           cwd=str(ROOT),
                           extra_env={"SOUS_HOUSEHOLD_ID": job.household_id})


def process_one(conn, cfg: dict) -> bool:
    for job_id in db.requeue_stale(conn, cfg["stale_after_sec"], cfg["max_attempts"]):
        hid = db.get_job_household(conn, job_id)
        _apologize(conn, hid, job_id)

    job = db.claim_next_job(conn)
    if job is None:
        return False
    try:
        if job.kind in ("chat", "ritual"):
            mode = ("ritual" if job.kind == "ritual"
                    or db.get_proposing_week(conn, job.household_id) else "chat")
            reply = (generate_ritual_reply(conn, job, cfg) if mode == "ritual"
                     else generate_chat_reply(conn, job, cfg))
        elif job.kind == "recipe_intake":
            mode = "recipe_intake"
            reply = generate_recipe_intake_reply(conn, job, cfg)
        else:
            raise ValueError(f"unknown job kind: {job.kind}")
        with conn.transaction():
            db.insert_chef_message(conn, job.household_id, reply, job.id)
            db.complete_job(conn, job.id, {"reply_chars": len(reply), "mode": mode})
    except Exception as exc:  # noqa: BLE001 — worker must never die on one job
        log.exception("job %s failed (attempt %d)", job.id, job.attempts)
        if job.attempts >= cfg["max_attempts"]:
            db.fail_job(conn, job.id, str(exc))
            _apologize(conn, job.household_id, job.id)
        else:
            db.requeue_job(conn, job.id)
    return True


def main() -> None:
    logging.basicConfig(level=logging.INFO,
                        format="%(asctime)s %(levelname)s %(message)s")
    load_dotenv(ROOT / ".env")
    cfg = load_config()
    conn = db.connect()
    log.info("sous worker v0 up — polling every %ss", cfg["poll_interval_sec"])
    last_beat = 0.0
    while True:
        now = time.monotonic()
        if now - last_beat >= cfg["heartbeat_interval_sec"]:
            db.heartbeat(conn)
            last_beat = now
        try:
            worked = process_one(conn, cfg)
        except Exception:
            log.exception("loop error; reconnecting in 5s")
            time.sleep(5)
            conn = db.connect()
            continue
        if not worked:
            time.sleep(cfg["poll_interval_sec"])


if __name__ == "__main__":
    main()
