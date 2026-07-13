import datetime
from zoneinfo import ZoneInfo

from sous_worker import context
from tests.conftest import SANDBOX

TEMPLATE = (
    "{persona_pack}\nToday is {today} ({weekday}).\n"
    "PLAN:\n{week_plan}\nPREFS:\n{preferences}\nCOOKBOOK:\n{cookbook_index}\n"
    "SHOPPING:\n{shopping_open}\nHISTORY:\n{history}\nNEW:\n{messages}"
)


def test_fetch_context_renders_seeded_week(conn):
    ctx = context.fetch_context(conn, SANDBOX)
    assert "蔥香雞腿飯" in ctx["week_plan"]
    assert "batch" in ctx["week_plan"]           # mode tags rendered
    assert "不吃香菜" in ctx["preferences"]
    assert "麻婆豆腐" in ctx["cookbook_index"]
    assert "chicken thigh fillets" in ctx["shopping_open"]
    assert "小當家" in ctx["household"]["prompt_pack"]


def test_history_renders_last_messages_oldest_first(conn):
    for i in range(3):
        conn.execute(
            "insert into chat_messages (household_id, sender, content) "
            "values (%s, 'user', %s)", (SANDBOX, f"msg{i}"),
        )
    ctx = context.fetch_context(conn, SANDBOX, history_limit=2)
    assert "msg0" not in ctx["history"]
    assert ctx["history"].index("msg1") < ctx["history"].index("msg2")


def test_build_chat_prompt_substitutes_everything(conn):
    ctx = context.fetch_context(conn, SANDBOX)
    prompt = context.build_chat_prompt(TEMPLATE, ctx, "user: 今晚吃什麼?")
    assert "今晚吃什麼?" in prompt
    assert "蔥香雞腿飯" in prompt
    assert "{" not in prompt.replace("{}", "")  # no unsubstituted placeholders


def test_checked_shopping_items_excluded(conn):
    conn.execute(
        "update shopping_items set checked=true where name='basil pesto' "
        "and household_id=%s", (SANDBOX,),
    )
    try:
        ctx = context.fetch_context(conn, SANDBOX)
        assert "basil pesto" not in ctx["shopping_open"]
    finally:
        conn.execute(
            "update shopping_items set checked=false where household_id=%s", (SANDBOX,),
        )


def test_week_monday_anchors_iso_monday():
    assert context.week_monday(datetime.date(2026, 7, 13)) == datetime.date(2026, 7, 13)  # Mon
    assert context.week_monday(datetime.date(2026, 7, 16)) == datetime.date(2026, 7, 13)  # Thu
    assert context.week_monday(datetime.date(2026, 7, 19)) == datetime.date(2026, 7, 13)  # Sun


def test_fetch_context_selects_week_from_household_local_now(conn):
    # Regression for the M1 live bug: at Sydney Mon 00:30 the UTC date is still
    # Sunday of the *previous* ISO week. The week window must follow the
    # household-local clock passed via `now`, not the DB's current_date.
    monday = datetime.date(2030, 1, 7)   # a Monday, far from the seeded week
    wid = conn.execute(
        "insert into plan_weeks (household_id, week_of) values (%s, %s) returning id",
        (SANDBOX, monday),
    ).fetchone()[0]
    conn.execute(
        "insert into plan_days (week_id, household_id, date, dish, mode) "
        "values (%s, %s, %s, '未來測試菜', 'fast')",
        (wid, SANDBOX, monday),
    )
    try:
        sydney_after_midnight = datetime.datetime(
            2030, 1, 7, 0, 30, tzinfo=ZoneInfo("Australia/Sydney")
        )  # == 2030-01-06 13:30 UTC (Sunday)
        ctx = context.fetch_context(conn, SANDBOX, now=sydney_after_midnight)
        assert "未來測試菜" in ctx["week_plan"]
        assert ctx["now"] is sydney_after_midnight
    finally:
        conn.execute("delete from plan_weeks where id = %s", (wid,))


def test_build_chat_prompt_uses_ctx_now(conn):
    fixed = datetime.datetime(2030, 1, 9, 18, 0, tzinfo=ZoneInfo("Australia/Sydney"))
    ctx = context.fetch_context(conn, SANDBOX, now=fixed)
    prompt = context.build_chat_prompt(TEMPLATE, ctx, "hi")
    assert "2030-01-09" in prompt
    assert "週三" in prompt   # 2030-01-09 is a Wednesday
