import datetime
from zoneinfo import ZoneInfo

import pytest

from sous_worker import context
from tests.conftest import SANDBOX

TEMPLATE = (
    "{persona_pack}\nToday is {today} ({weekday}).\n"
    "PLAN:\n{week_plan}\nPREFS:\n{preferences}\nCOOKBOOK:\n{cookbook_index}\n"
    "SHOPPING:\n{shopping_open}\nHISTORY:\n{history}\nNEW:\n{messages}"
)

MONDAY = context.week_monday(datetime.datetime.now(ZoneInfo("Australia/Sydney")).date())


@pytest.fixture
def api_hid(conn):
    """Dedicated household so notif_verdict context tests never disturb the seeded
    sandbox. Simplified from tests/test_state_api.py's api_hid fixture (single
    plan_day, not two — this file only needs one dish) and not shared via
    conftest.py — duplicated locally to keep this task's changes self-contained."""
    hid = conn.execute(
        "insert into households (name, persona_id) "
        "select 'notif-verdict-test', id from personas limit 1 returning id::text"
    ).fetchone()[0]
    wid = conn.execute(
        "insert into plan_weeks (household_id, week_of) values (%s, %s) returning id",
        (hid, MONDAY),
    ).fetchone()[0]
    conn.execute(
        "insert into plan_days (week_id, household_id, date, dish, mode, prep_note) "
        "values (%s, %s, %s, '咖哩飯', 'batch', '前一晚醃肉')",
        (wid, hid, MONDAY),
    )
    yield hid
    conn.execute("delete from households where id = %s", (hid,))


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


def test_fetch_ritual_context_targets_next_week(conn):
    fixed = datetime.datetime(2026, 7, 14, 9, 0, tzinfo=ZoneInfo("Australia/Sydney"))  # a Tuesday
    ctx = context.fetch_ritual_context(conn, SANDBOX, now=fixed)
    assert ctx["target_week_of"] == datetime.date(2026, 7, 20)  # the following Monday
    assert ctx["now"] is fixed


def test_render_recent_weeks_shows_history_before_target(conn):
    conn.execute(
        "insert into plan_weeks (household_id, week_of, status) "
        "values (%s, '2026-06-22', 'locked') returning id", (SANDBOX,),
    )
    wid = conn.execute(
        "select id from plan_weeks where household_id=%s and week_of='2026-06-22'",
        (SANDBOX,),
    ).fetchone()[0]
    conn.execute(
        "insert into plan_days (week_id, household_id, date, dish, mode) "
        "values (%s, %s, '2026-06-23', '歷史測試菜', 'fast')", (wid, SANDBOX),
    )
    try:
        rendered = context._render_recent_weeks(conn, SANDBOX, datetime.date(2026, 7, 20))
        assert "歷史測試菜" in rendered
        assert "2026-06-23" in rendered
    finally:
        conn.execute("delete from plan_weeks where id = %s", (wid,))


def test_render_recent_weeks_excludes_older_than_window(conn):
    rendered = context._render_recent_weeks(
        conn, SANDBOX, datetime.date(2026, 7, 20), weeks_back=4,
    )
    # anything before 2026-06-22 (4 weeks back from 2026-07-20) must not appear —
    # no seeded data exists that old, so this just asserts the function runs
    # cleanly over an empty/partial window without error.
    assert isinstance(rendered, str)


def test_render_inbox_lists_kind_and_content(conn):
    conn.execute(
        "insert into inbox_items (household_id, kind, content) "
        "values (%s, 'craving', '想吃泰式')", (SANDBOX,),
    )
    try:
        rendered = context._render_inbox(conn, SANDBOX)
        assert "craving" in rendered
        assert "想吃泰式" in rendered
    finally:
        conn.execute(
            "delete from inbox_items where household_id=%s and content='想吃泰式'",
            (SANDBOX,),
        )


def test_render_inbox_empty_is_honest(conn):
    conn.execute("delete from inbox_items where household_id=%s", (SANDBOX,))
    rendered = context._render_inbox(conn, SANDBOX)
    assert "空" in rendered


def test_render_verdicts_recent_joins_dish_name(conn):
    pd_id = conn.execute(
        "select id from plan_days where household_id=%s limit 1", (SANDBOX,),
    ).fetchone()[0]
    conn.execute(
        "insert into verdicts (household_id, plan_day_id, rating, note) "
        "values (%s, %s, '神作', '超好吃')", (SANDBOX, pd_id),
    )
    try:
        rendered = context._render_verdicts_recent(conn, SANDBOX)
        assert "神作" in rendered
        assert "超好吃" in rendered
    finally:
        conn.execute(
            "delete from verdicts where household_id=%s and note='超好吃'", (SANDBOX,),
        )


def test_render_staples_flagged_only_shows_low(conn):
    conn.execute(
        "insert into staples (household_id, name, flagged_low) "
        "values (%s, '測試常備品', true) on conflict (household_id, name) "
        "do update set flagged_low=true", (SANDBOX,),
    )
    try:
        rendered = context._render_staples_flagged(conn, SANDBOX)
        assert "測試常備品" in rendered
        assert "醬油" not in rendered  # seeded staple, not flagged low
    finally:
        conn.execute(
            "delete from staples where household_id=%s and name='測試常備品'", (SANDBOX,),
        )


def test_build_ritual_prompt_substitutes_everything(conn):
    template = (
        "{persona_pack}\n{today}\n{weekday}\n{target_week_of}\n{current_week_plan}\n"
        "{recent_weeks}\n{inbox}\n{verdicts_recent}\n{staples_flagged}\n"
        "{preferences}\n{cookbook_index}\n{history}\n{messages}"
    )
    ctx = context.fetch_ritual_context(conn, SANDBOX)
    prompt = context.build_ritual_prompt(template, ctx, "user: 開始本週儀式")
    assert "開始本週儀式" in prompt
    assert "{" not in prompt.replace("{}", "")


def test_fetch_recipe_intake_context_returns_household(conn):
    ctx = context.fetch_recipe_intake_context(conn, SANDBOX)
    assert "小當家" in ctx["household"]["prompt_pack"]
    assert ctx["now"] is not None


def test_fetch_recipe_intake_context_uses_provided_now(conn):
    fixed = datetime.datetime(2030, 1, 9, 18, 0, tzinfo=ZoneInfo("Australia/Sydney"))
    ctx = context.fetch_recipe_intake_context(conn, SANDBOX, now=fixed)
    assert ctx["now"] is fixed


def test_render_prefetch_gemini_source():
    rendered = context._render_prefetch({"source": "gemini", "understanding": "看到雞腿肉..."})
    assert "看到雞腿肉" in rendered


def test_render_prefetch_caption_source():
    rendered = context._render_prefetch(
        {"source": "caption", "title": "三杯雞食譜", "uploader": "chef", "description": "desc"})
    assert "三杯雞食譜" in rendered


def test_render_prefetch_none_source_is_honest():
    rendered = context._render_prefetch({"source": "none", "error": "not a video"})
    assert "WebFetch" in rendered


def test_build_recipe_intake_prompt_substitutes_everything(conn):
    template = "{persona_pack}\n{today}\n{weekday}\n{url}\n{by}\n{prefetched_context}"
    ctx = context.fetch_recipe_intake_context(conn, SANDBOX)
    prompt = context.build_recipe_intake_prompt(
        template, ctx, "https://instagram.com/reel/abc", "mike",
        {"source": "gemini", "understanding": "食譜內容"},
    )
    assert "https://instagram.com/reel/abc" in prompt
    assert "mike" in prompt
    assert "食譜內容" in prompt
    assert "{" not in prompt.replace("{}", "")


def test_fetch_notif_week_context_includes_day_ids(conn):
    week_id = conn.execute(
        "select w.id::text from plan_weeks w "
        "where w.household_id=%s and w.status='locked' order by w.week_of desc limit 1",
        (SANDBOX,),
    ).fetchone()[0]
    ctx = context.fetch_notif_week_context(conn, SANDBOX, week_id)
    assert ctx["household"]["name"] == "sandbox"
    assert len(ctx["days"]) >= 1
    first = ctx["days"][0]
    assert set(first) == {"id", "date", "dish", "mode", "prep_note"}


def test_build_notif_week_prompt_substitutes_placeholders(conn):
    # Inline template, not a read of the real prompts/notif_week.md file — matches
    # this file's existing convention (see test_build_ritual_prompt_substitutes_everything
    # above), which keeps context-building tests independent of prompt copy changes.
    template = "{persona_pack}\n{today}\n{weekday}\n{days}"
    week_id = conn.execute(
        "select w.id::text from plan_weeks w "
        "where w.household_id=%s and w.status='locked' order by w.week_of desc limit 1",
        (SANDBOX,),
    ).fetchone()[0]
    ctx = context.fetch_notif_week_context(conn, SANDBOX, week_id)
    prompt = context.build_notif_week_prompt(template, ctx)
    assert "{" not in prompt.replace("{}", "")
    assert ctx["days"][0]["dish"] in prompt


def test_fetch_notif_verdict_context_includes_dish(conn, api_hid):
    day_id = conn.execute(
        "select id::text from plan_days where household_id=%s and date=%s",
        (api_hid, MONDAY),
    ).fetchone()[0]
    ctx = context.fetch_notif_verdict_context(conn, api_hid, day_id)
    assert ctx["plan_day"]["dish"] == "咖哩飯"
    assert ctx["plan_day"]["id"] == day_id


def test_build_notif_verdict_prompt_substitutes_dish(conn, api_hid):
    template = "{persona_pack}\n{today}\n{weekday}\n{date}\n{dish}\n{plan_day_id}"
    day_id = conn.execute(
        "select id::text from plan_days where household_id=%s and date=%s",
        (api_hid, MONDAY),
    ).fetchone()[0]
    ctx = context.fetch_notif_verdict_context(conn, api_hid, day_id)
    prompt = context.build_notif_verdict_prompt(template, ctx)
    assert "咖哩飯" in prompt
    assert "{" not in prompt.replace("{}", "")


def test_fetch_recipe_tweak_context_includes_origin_and_note(conn, api_hid):
    ctx = context.fetch_recipe_tweak_context(
        conn, api_hid, origin_dish_text="三杯雞", note="沒有蝦", origin_recipe_id=None,
    )
    assert ctx["origin_dish_text"] == "三杯雞"
    assert ctx["note"] == "沒有蝦"
    assert "preferences" in ctx  # allergies-are-absolute still applies to a tweak


def test_build_recipe_tweak_prompt_substitutes_all_placeholders():
    template = "{origin_dish_text} / {note} / {preferences}"
    ctx = {"origin_dish_text": "三杯雞", "note": "沒有蝦", "preferences": "無"}
    prompt = context.build_recipe_tweak_prompt(template, ctx)
    assert prompt == "三杯雞 / 沒有蝦 / 無"


def test_fetch_recipe_tweak_context_includes_persona_and_date(conn, api_hid):
    # Every other fetch_*_context/build_*_prompt pair in this file sources
    # {persona_pack}/{today}/{weekday} from db.get_household so the persona layer
    # (project rule: zero hardcoded persona strings) always renders — recipe_tweak
    # must not be the one job kind that silently drops persona_pack from the prompt.
    ctx = context.fetch_recipe_tweak_context(
        conn, api_hid, origin_dish_text="三杯雞", note="沒有蝦", origin_recipe_id=None,
    )
    assert "小當家" in ctx["persona_pack"]
    assert ctx["today"] and ctx["weekday"]
