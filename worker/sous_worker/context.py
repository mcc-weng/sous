"""Deterministic context assembly (spec §3 step 3): the worker — not the LLM —
fetches current state and renders it into the prompt. Rendering is one-way;
nothing ever parses this text back. Generalization of alfred listener.py's
build_prompt, reading rows instead of files."""
import datetime
from zoneinfo import ZoneInfo

from sous_worker import db

_WEEKDAYS_ZH = ["週一", "週二", "週三", "週四", "週五", "週六", "週日"]


def week_monday(day: datetime.date) -> datetime.date:
    """ISO-Monday anchor for plan_weeks.week_of. All week math goes through
    here, driven by the household-local date — never the DB session's UTC
    clock (M1 live bug: `current_date` is UTC; Sydney is UTC+10)."""
    return day - datetime.timedelta(days=day.weekday())


def _render_week(conn, household_id: str, monday: datetime.date) -> str:
    rows = conn.execute(
        "select d.date, d.dish, d.mode, d.prep_note, d.status "
        "from plan_days d join plan_weeks w on w.id = d.week_id "
        "where d.household_id = %s and w.week_of = %s "
        "order by d.date",
        (household_id, monday),
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


def _fetch_week_days_with_ids(conn, household_id: str, week_id: str) -> list[dict]:
    rows = conn.execute(
        "select id::text, date, dish, mode, prep_note from plan_days "
        "where household_id = %s and week_id = %s order by date",
        (household_id, week_id),
    ).fetchall()
    return [{"id": r[0], "date": r[1], "dish": r[2], "mode": r[3], "prep_note": r[4]}
            for r in rows]


def fetch_notif_week_context(conn, household_id: str, week_id: str,
                             now: datetime.datetime | None = None) -> dict:
    household = db.get_household(conn, household_id)
    if now is None:
        now = datetime.datetime.now(ZoneInfo(household["timezone"]))
    return {"household": household, "now": now,
            "days": _fetch_week_days_with_ids(conn, household_id, week_id)}


def _render_notif_days(days: list[dict]) -> str:
    lines = []
    for d in days:
        parts = [f"{d['date'].isoformat()}(id: {d['id']})", d["dish"], d["mode"]]
        if d["prep_note"]:
            parts.append(f"prep: {d['prep_note']}")
        lines.append(" · ".join(parts))
    return "\n".join(lines)


def build_notif_week_prompt(template: str, ctx: dict) -> str:
    now = ctx["now"]
    return (
        template
        .replace("{persona_pack}", ctx["household"]["prompt_pack"])
        .replace("{today}", now.strftime("%Y-%m-%d"))
        .replace("{weekday}", _WEEKDAYS_ZH[now.weekday()])
        .replace("{days}", _render_notif_days(ctx["days"]))
    )


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


def _render_recent_weeks(conn, household_id: str, before: datetime.date,
                         weeks_back: int = 4) -> str:
    since = before - datetime.timedelta(weeks=weeks_back)
    rows = conn.execute(
        "select date, dish, mode, status from plan_days "
        "where household_id = %s and date >= %s and date < %s order by date",
        (household_id, since, before),
    ).fetchall()
    if not rows:
        return "(近期沒有排菜紀錄)"
    lines = []
    for date, dish, mode, status in rows:
        parts = [date.isoformat(), dish, mode]
        if status != "planned":
            parts.append(status)
        lines.append(" · ".join(parts))
    return "\n".join(lines)


def _render_inbox(conn, household_id: str) -> str:
    rows = conn.execute(
        "select kind, content from inbox_items where household_id = %s "
        "order by created_at", (household_id,),
    ).fetchall()
    return "\n".join(f"[{k}] {c}" for k, c in rows) or "(收件匣是空的)"


def _render_verdicts_recent(conn, household_id: str, limit: int = 15) -> str:
    rows = conn.execute(
        "select pd.date, pd.dish, v.rating, v.note from verdicts v "
        "join plan_days pd on pd.id = v.plan_day_id "
        "where v.household_id = %s order by v.created_at desc limit %s",
        (household_id, limit),
    ).fetchall()
    lines = []
    for date, dish, rating, note in rows:
        line = f"{date.isoformat()} · {dish} · {rating}"
        if note:
            line += f"({note})"
        lines.append(line)
    return "\n".join(lines) or "(還沒有評價紀錄)"


def _render_staples_flagged(conn, household_id: str) -> str:
    rows = conn.execute(
        "select name from staples where household_id = %s and flagged_low = true "
        "order by name", (household_id,),
    ).fetchall()
    return "\n".join(f"- {n}" for (n,) in rows) or "(沒有常備品快用完)"


def fetch_ritual_context(conn, household_id: str, history_limit: int = 20,
                         now: datetime.datetime | None = None) -> dict:
    household = db.get_household(conn, household_id)
    if now is None:
        now = datetime.datetime.now(ZoneInfo(household["timezone"]))
    target_week_of = week_monday(now.date()) + datetime.timedelta(weeks=1)
    return {
        "household": household,
        "now": now,
        "target_week_of": target_week_of,
        "current_week_plan": _render_week(conn, household_id, week_monday(now.date())),
        "recent_weeks": _render_recent_weeks(conn, household_id, target_week_of),
        "inbox": _render_inbox(conn, household_id),
        "verdicts_recent": _render_verdicts_recent(conn, household_id),
        "staples_flagged": _render_staples_flagged(conn, household_id),
        "preferences": _render_preferences(conn, household_id),
        "cookbook_index": _render_cookbook_index(conn, household_id),
        "history": _render_history(conn, household_id, history_limit),
    }


def build_ritual_prompt(template: str, ctx: dict, new_messages: str) -> str:
    now = ctx["now"]
    return (
        template
        .replace("{persona_pack}", ctx["household"]["prompt_pack"])
        .replace("{today}", now.strftime("%Y-%m-%d"))
        .replace("{weekday}", _WEEKDAYS_ZH[now.weekday()])
        .replace("{target_week_of}", ctx["target_week_of"].isoformat())
        .replace("{current_week_plan}", ctx["current_week_plan"])
        .replace("{recent_weeks}", ctx["recent_weeks"])
        .replace("{inbox}", ctx["inbox"])
        .replace("{verdicts_recent}", ctx["verdicts_recent"])
        .replace("{staples_flagged}", ctx["staples_flagged"])
        .replace("{preferences}", ctx["preferences"])
        .replace("{cookbook_index}", ctx["cookbook_index"])
        .replace("{history}", ctx["history"])
        .replace("{messages}", new_messages)
    )


def fetch_context(conn, household_id: str, history_limit: int = 20,
                  now: datetime.datetime | None = None) -> dict:
    household = db.get_household(conn, household_id)
    if now is None:
        now = datetime.datetime.now(ZoneInfo(household["timezone"]))
    return {
        "household": household,
        "now": now,
        "week_plan": _render_week(conn, household_id, week_monday(now.date())),
        "preferences": _render_preferences(conn, household_id),
        "cookbook_index": _render_cookbook_index(conn, household_id),
        "shopping_open": _render_shopping_open(conn, household_id),
        "history": _render_history(conn, household_id, history_limit),
    }


def build_chat_prompt(template: str, ctx: dict, new_messages: str) -> str:
    now = ctx["now"]
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


def _render_prefetch(prefetch: dict) -> str:
    source = prefetch.get("source")
    if source == "gemini":
        return f"### Gemini 完整理解(已看過影片)\n{prefetch['understanding']}"
    if source == "caption":
        title = prefetch.get("title") or ""
        description = prefetch.get("description") or ""
        return f"### 貼文/影片標題與說明(系統已自動抓取,未看影片本身)\n{title}\n{description}"
    return "(這個連結不是已知的影片平台,或抓取失敗 — 用 WebFetch 直接讀網址內容)"


def fetch_recipe_intake_context(conn, household_id: str,
                                now: datetime.datetime | None = None) -> dict:
    household = db.get_household(conn, household_id)
    if now is None:
        now = datetime.datetime.now(ZoneInfo(household["timezone"]))
    return {"household": household, "now": now}


def build_recipe_intake_prompt(template: str, ctx: dict, url: str, by: str,
                               prefetch: dict) -> str:
    now = ctx["now"]
    return (
        template
        .replace("{persona_pack}", ctx["household"]["prompt_pack"])
        .replace("{today}", now.strftime("%Y-%m-%d"))
        .replace("{weekday}", _WEEKDAYS_ZH[now.weekday()])
        .replace("{url}", url)
        .replace("{by}", by)
        .replace("{prefetched_context}", _render_prefetch(prefetch))
    )
