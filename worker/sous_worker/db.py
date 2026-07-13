"""Sous worker DB seam. Worker uses the service-role/direct connection (bypasses RLS).

All verbs are idempotent or at-least-once safe: requeue/complete/fail are plain
UPDATEs keyed by id; claim is atomic via FOR UPDATE SKIP LOCKED so N workers
never double-run a job (spec §3 job lifecycle).
"""
import os
from dataclasses import dataclass

import psycopg
from psycopg.types.json import Jsonb


@dataclass
class Job:
    id: str
    household_id: str
    kind: str
    payload: dict
    attempts: int


def connect() -> psycopg.Connection:
    return psycopg.connect(os.environ["SOUS_DB_URL"], autocommit=True)


_CLAIM_SQL = """
update jobs set status='running', claimed_at=now(), attempts=attempts+1
where id = (
  select id from jobs where status='queued'
  order by created_at limit 1
  for update skip locked
)
returning id::text, household_id::text, kind, payload, attempts
"""


def claim_next_job(conn) -> Job | None:
    row = conn.execute(_CLAIM_SQL).fetchone()
    if row is None:
        return None
    return Job(id=row[0], household_id=row[1], kind=row[2],
               payload=row[3] or {}, attempts=row[4])


def complete_job(conn, job_id: str, result: dict) -> None:
    conn.execute("update jobs set status='done', result=%s where id=%s",
                 (Jsonb(result), job_id))


def fail_job(conn, job_id: str, error: str) -> None:
    conn.execute("update jobs set status='failed', result=%s where id=%s",
                 (Jsonb({"error": error[:500]}), job_id))


def requeue_job(conn, job_id: str) -> None:
    conn.execute("update jobs set status='queued', claimed_at=null where id=%s",
                 (job_id,))


def requeue_stale(conn, stale_after_sec: int, max_attempts: int = 2) -> list[str]:
    """Sweep stuck 'running' jobs: requeue if attempts remain, else fail.
    Returns ids of jobs marked failed (caller posts the in-character apology)."""
    conn.execute(
        "update jobs set status='queued', claimed_at=null "
        "where status='running' and claimed_at < now() - %s * interval '1 second' "
        "and attempts < %s",
        (stale_after_sec, max_attempts),
    )
    rows = conn.execute(
        "update jobs set status='failed', "
        "result=coalesce(result,'{}'::jsonb) || '{\"error\": \"timed out\"}'::jsonb "
        "where status='running' and claimed_at < now() - %s * interval '1 second' "
        "and attempts >= %s returning id::text",
        (stale_after_sec, max_attempts),
    ).fetchall()
    return [r[0] for r in rows]


def heartbeat(conn) -> None:
    conn.execute("update households set worker_seen_at = now()")


def insert_chef_message(conn, household_id: str, content: str,
                        job_id: str | None = None) -> str:
    return conn.execute(
        "insert into chat_messages (household_id, sender, content, job_id) "
        "values (%s, 'chef', %s, %s) returning id::text",
        (household_id, content, job_id),
    ).fetchone()[0]


def get_job_household(conn, job_id: str) -> str:
    return conn.execute(
        "select household_id::text from jobs where id = %s", (job_id,)
    ).fetchone()[0]


def get_message_content(conn, message_id: str) -> str | None:
    row = conn.execute(
        "select content from chat_messages where id = %s", (message_id,)
    ).fetchone()
    return row[0] if row else None


def get_household(conn, household_id: str) -> dict:
    row = conn.execute(
        "select h.name, h.timezone, p.prompt_pack, p.copy_pack "
        "from households h join personas p on p.id = h.persona_id "
        "where h.id = %s",
        (household_id,),
    ).fetchone()
    return {"name": row[0], "timezone": row[1],
            "prompt_pack": row[2], "copy_pack": row[3]}


def ensure_proposing_week(conn, household_id: str, week_of) -> str:
    """Idempotent create-if-absent. Never touches a row that already exists —
    in particular never downgrades an already-'locked' week back to
    'proposing', so re-triggering a ritual for an already-planned week is
    safe (the brain sees the existing plan via current/recent-weeks context
    and can decide to re-propose honestly rather than silently reopening it)."""
    row = conn.execute(
        "select id::text from plan_weeks where household_id = %s and week_of = %s",
        (household_id, week_of),
    ).fetchone()
    if row:
        return row[0]
    row = conn.execute(
        "insert into plan_weeks (household_id, week_of, status) "
        "values (%s, %s, 'proposing') returning id::text",
        (household_id, week_of),
    ).fetchone()
    return row[0]


def get_proposing_week(conn, household_id: str) -> dict | None:
    row = conn.execute(
        "select id::text, week_of from plan_weeks "
        "where household_id = %s and status = 'proposing' "
        "order by week_of desc limit 1",
        (household_id,),
    ).fetchone()
    return {"id": row[0], "week_of": row[1]} if row else None
