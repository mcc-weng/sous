"""Deterministic context assembly (spec §3 step 3): the worker — not the LLM —
fetches current state and renders it into the prompt. Rendering is one-way;
nothing ever parses this text back. Generalization of alfred listener.py's
build_prompt, reading rows instead of files."""
import datetime
from zoneinfo import ZoneInfo

from sous_worker import db

_WEEKDAYS_ZH = ["週一", "週二", "週三", "週四", "週五", "週六", "週日"]


def _render_week(conn, household_id: str) -> str:
    rows = conn.execute(
        "select d.date, d.dish, d.mode, d.prep_note, d.status "
        "from plan_days d join plan_weeks w on w.id = d.week_id "
        "where d.household_id = %s and w.week_of = date_trunc('week', current_date)::date "
        "order by d.date",
        (household_id,),
    ).fetchall()
    if not rows:
        return "(本週還沒有菜單)"
    lines = []
    for date, dish, mode, prep, status in rows:
        parts = [f"{_WEEKDAYS_ZH[date.weekday()]} {date.isoformat()}", dish, mode]
        if prep:
            parts.append(f"prep: {prep}")
        if status != "planned":
            parts.append(status)
        lines.append(" · ".join(parts))
    return "\n".join(lines)


def _render_preferences(conn, household_id: str) -> str:
    row = conn.execute(
        "select content from preferences where household_id = %s", (household_id,)
    ).fetchone()
    return row[0] if row and row[0] else "(尚無偏好記錄)"


def _render_cookbook_index(conn, household_id: str) -> str:
    rows = conn.execute(
        "select title, slug from recipes where household_id = %s order by title",
        (household_id,),
    ).fetchall()
    return "\n".join(f"- {t} ({s})" for t, s in rows) or "(食譜庫是空的)"


def _render_shopping_open(conn, household_id: str) -> str:
    rows = conn.execute(
        "select name, qty, section from shopping_items "
        "where household_id = %s and checked = false order by section, name",
        (household_id,),
    ).fetchall()
    return "\n".join(
        f"- {n}" + (f" × {q}" if q else "") + (f" [{s}]" if s else "")
        for n, q, s in rows
    ) or "(採買清單是空的)"


def _render_history(conn, household_id: str, limit: int) -> str:
    rows = conn.execute(
        "select sender, content from chat_messages "
        "where household_id = %s order by created_at desc limit %s",
        (household_id, limit),
    ).fetchall()
    return "\n".join(f"{s}: {c}" for s, c in reversed(rows)) or "(none)"


def fetch_context(conn, household_id: str, history_limit: int = 20) -> dict:
    return {
        "household": db.get_household(conn, household_id),
        "week_plan": _render_week(conn, household_id),
        "preferences": _render_preferences(conn, household_id),
        "cookbook_index": _render_cookbook_index(conn, household_id),
        "shopping_open": _render_shopping_open(conn, household_id),
        "history": _render_history(conn, household_id, history_limit),
    }


def build_chat_prompt(template: str, ctx: dict, new_messages: str) -> str:
    now = datetime.datetime.now(ZoneInfo(ctx["household"]["timezone"]))
    return (
        template
        .replace("{persona_pack}", ctx["household"]["prompt_pack"])
        .replace("{today}", now.strftime("%Y-%m-%d"))
        .replace("{weekday}", _WEEKDAYS_ZH[now.weekday()])
        .replace("{week_plan}", ctx["week_plan"])
        .replace("{preferences}", ctx["preferences"])
        .replace("{cookbook_index}", ctx["cookbook_index"])
        .replace("{shopping_open}", ctx["shopping_open"])
        .replace("{history}", ctx["history"])
        .replace("{messages}", new_messages)
    )
