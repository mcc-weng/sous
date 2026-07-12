"""Sous worker v0: poll → claim → render → brain → reply row.

Realtime job subscription is a M2 optimization; a 3s poll on an indexed
status column is plenty for one household and much simpler to reason about.
"""
import json
import logging
import pathlib
import time

from dotenv import load_dotenv

from sous_worker import brain, context, db

ROOT = pathlib.Path(__file__).resolve().parent.parent  # worker/
log = logging.getLogger("sous_worker")


def load_config() -> dict:
    return json.loads((ROOT / "config.json").read_text())


def _apologize(conn, household_id: str, job_id: str) -> None:
    copy_pack = db.get_household(conn, household_id)["copy_pack"]
    message = copy_pack.get("failure_message", "Something went wrong — please try again.")
    db.insert_chef_message(conn, household_id, message, job_id)


def handle_chat_job(conn, job: db.Job, cfg: dict) -> str:
    ctx = context.fetch_context(conn, job.household_id, cfg["history_limit"])
    template = (ROOT / "prompts" / "chat.md").read_text()
    new_message = ""
    if job.payload.get("message_id"):
        row = conn.execute(
            "select content from chat_messages where id = %s",
            (job.payload["message_id"],),
        ).fetchone()
        if row:
            new_message = f"user: {row[0]}"
    prompt = context.build_chat_prompt(template, ctx, new_message or "(none)")
    reply = brain.run_brain(prompt, model=cfg["chat_model"],
                            timeout=cfg["chat_timeout_sec"])
    db.insert_chef_message(conn, job.household_id, reply, job.id)
    return reply


def process_one(conn, cfg: dict) -> bool:
    for job_id in db.requeue_stale(conn, cfg["stale_after_sec"], cfg["max_attempts"]):
        hid = conn.execute(
            "select household_id::text from jobs where id = %s", (job_id,)
        ).fetchone()[0]
        _apologize(conn, hid, job_id)

    job = db.claim_next_job(conn)
    if job is None:
        return False
    try:
        if job.kind == "chat":
            reply = handle_chat_job(conn, job, cfg)
            db.complete_job(conn, job.id, {"reply_chars": len(reply)})
        else:
            raise ValueError(f"unknown job kind: {job.kind}")
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
