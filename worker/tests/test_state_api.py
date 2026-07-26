import datetime
import json
import os
import pathlib
import subprocess
import sys
from zoneinfo import ZoneInfo

import pytest

import state_api
from sous_worker.context import week_monday
from tests.conftest import SANDBOX, TEST_DB_URL

WORKER_DIR = pathlib.Path(state_api.__file__).resolve().parent
MONDAY = week_monday(datetime.datetime.now(ZoneInfo("Australia/Sydney")).date())
TUESDAY = MONDAY + datetime.timedelta(days=1)


@pytest.fixture
def api_hid(conn):
    """Dedicated household so verb tests never disturb the seeded sandbox."""
    hid = conn.execute(
        "insert into households (name, persona_id) "
        "select 'state-api-test', id from personas limit 1 returning id::text"
    ).fetchone()[0]
    wid = conn.execute(
        "insert into plan_weeks (household_id, week_of) values (%s, %s) returning id",
        (hid, MONDAY),
    ).fetchone()[0]
    conn.execute(
        "insert into plan_days (week_id, household_id, date, dish, mode, prep_note) values "
        "(%s, %s, %s, '咖哩飯', 'batch', '前一晚醃肉'), (%s, %s, %s, '三杯雞', 'fast', null)",
        (wid, hid, MONDAY, wid, hid, TUESDAY),
    )
    yield hid
    conn.execute("delete from households where id = %s", (hid,))


def test_get_plan_returns_current_week(conn, api_hid):
    out = state_api.get_plan(conn, api_hid)
    assert out["ok"] is True
    assert out["week_of"] == MONDAY
    assert [d["dish"] for d in out["days"]] == ["咖哩飯", "三杯雞"]
    assert out["days"][0]["prep_note"] == "前一晚醃肉"


def test_update_day_changes_only_given_fields(conn, api_hid):
    out = state_api.update_day(conn, api_hid, MONDAY, dish="番茄炒蛋", status="cooked")
    assert out == {"ok": True, "date": MONDAY, "dish": "番茄炒蛋",
                   "mode": "batch", "status": "cooked"}
    row = conn.execute(
        "select dish, mode, prep_note, status from plan_days "
        "where household_id = %s and date = %s", (api_hid, MONDAY),
    ).fetchone()
    assert row == ("番茄炒蛋", "batch", "前一晚醃肉", "cooked")


def test_update_day_is_idempotent(conn, api_hid):
    first = state_api.update_day(conn, api_hid, MONDAY, dish="番茄炒蛋")
    again = state_api.update_day(conn, api_hid, MONDAY, dish="番茄炒蛋")
    assert first == again


def test_update_day_rejects_bad_mode_and_missing_day(conn, api_hid):
    with pytest.raises(ValueError, match="mode"):
        state_api.update_day(conn, api_hid, MONDAY, mode="yolo")
    with pytest.raises(ValueError, match="no plan day"):
        state_api.update_day(conn, api_hid, MONDAY + datetime.timedelta(days=30),
                             dish="幽靈菜")
    with pytest.raises(ValueError, match="nothing to update"):
        state_api.update_day(conn, api_hid, MONDAY)


def test_update_day_scopes_to_household(conn, api_hid):
    # SANDBOX's seeded week also has a row on MONDAY — updating it must not
    # touch api_hid's row for the same date. Restore the seed row after.
    original = conn.execute(
        "select dish from plan_days where household_id = %s and date = %s",
        (SANDBOX, MONDAY),
    ).fetchone()[0]
    try:
        state_api.update_day(conn, SANDBOX, MONDAY, dish="別家的菜")
        row = conn.execute(
            "select dish from plan_days where household_id = %s and date = %s",
            (api_hid, MONDAY),
        ).fetchone()
        assert row == ("咖哩飯",)
    finally:
        conn.execute(
            "update plan_days set dish = %s where household_id = %s and date = %s",
            (original, SANDBOX, MONDAY),
        )


def _run_cli(args, hid):
    return subprocess.run(
        [sys.executable, "state_api.py", *args],
        capture_output=True, cwd=WORKER_DIR, text=True,
        env=os.environ | {"SOUS_HOUSEHOLD_ID": hid, "SOUS_DB_URL": TEST_DB_URL},
    )


def test_cli_get_plan_roundtrip(api_hid):
    proc = _run_cli(["get-plan"], api_hid)
    assert proc.returncode == 0, proc.stderr
    out = json.loads(proc.stdout)
    assert out["ok"] is True and out["days"][0]["dish"] == "咖哩飯"


def test_cli_update_day_and_error_paths(api_hid):
    proc = _run_cli(["update-day", "--date", str(MONDAY), "--dish", "打拋豬"], api_hid)
    assert json.loads(proc.stdout)["dish"] == "打拋豬"

    bad = _run_cli(["update-day", "--date", str(MONDAY), "--mode", "yolo"], api_hid)
    assert bad.returncode == 1
    assert json.loads(bad.stdout)["ok"] is False

    no_hid = subprocess.run(
        [sys.executable, "state_api.py", "get-plan"],
        capture_output=True, cwd=WORKER_DIR, text=True,
        env={k: v for k, v in os.environ.items() if k != "SOUS_HOUSEHOLD_ID"}
        | {"SOUS_DB_URL": TEST_DB_URL},
    )
    assert no_hid.returncode == 1
    assert "SOUS_HOUSEHOLD_ID" in json.loads(no_hid.stdout)["error"]


def test_cli_argparse_errors_emit_json(api_hid):
    """Argparse-level failures (bad flag value, unknown verb) must funnel
    through the same JSON-on-stdout + exit-1 contract as every other
    failure — not argparse's default usage-text-on-stderr + exit 2."""
    bad_date = _run_cli(["update-day", "--date", "bogus", "--dish", "x"], api_hid)
    assert bad_date.returncode == 1
    assert bad_date.stderr == ""
    out = json.loads(bad_date.stdout)
    assert out["ok"] is False and "date" in out["error"]

    bad_verb = _run_cli(["nonexistent-verb"], api_hid)
    assert bad_verb.returncode == 1
    assert bad_verb.stderr == ""
    out = json.loads(bad_verb.stdout)
    assert out["ok"] is False and "nonexistent-verb" in out["error"]


def test_swap_days_swaps_dish_payload_not_status(conn, api_hid):
    conn.execute(
        "update plan_days set status='cooked' where household_id=%s and date=%s",
        (api_hid, MONDAY),
    )
    out = state_api.swap_days(conn, api_hid, MONDAY, TUESDAY)
    assert out["ok"] is True
    rows = conn.execute(
        "select date, dish, mode, prep_note, status from plan_days "
        "where household_id = %s order by date", (api_hid,),
    ).fetchall()
    assert rows[0] == (MONDAY, "三杯雞", "fast", None, "cooked")
    assert rows[1] == (TUESDAY, "咖哩飯", "batch", "前一晚醃肉", "planned")


def test_swap_days_requires_both_days(conn, api_hid):
    with pytest.raises(ValueError, match="both"):
        state_api.swap_days(conn, api_hid, MONDAY,
                            MONDAY + datetime.timedelta(days=30))


def test_cli_swap_days(api_hid):
    proc = _run_cli(["swap-days", "--date-a", str(MONDAY), "--date-b", str(TUESDAY)],
                    api_hid)
    assert proc.returncode == 0, proc.stderr
    assert json.loads(proc.stdout)["ok"] is True


def test_add_shopping_item_inserts_with_current_week(conn, api_hid):
    out = state_api.add_shopping_item(conn, api_hid, "soy sauce",
                                      qty="1 bottle", section="pantry")
    assert out["ok"] is True and out["deduped"] is False
    row = conn.execute(
        "select name, qty, section, checked, week_id is not null "
        "from shopping_items where household_id = %s", (api_hid,),
    ).fetchone()
    assert row == ("soy sauce", "1 bottle", "pantry", False, True)


def test_add_shopping_item_dedupes_case_insensitively(conn, api_hid):
    state_api.add_shopping_item(conn, api_hid, "soy sauce")
    out = state_api.add_shopping_item(conn, api_hid, "Soy Sauce", qty="2 bottles")
    assert out["deduped"] is True
    rows = conn.execute(
        "select qty from shopping_items where household_id = %s", (api_hid,),
    ).fetchall()
    assert rows == [("2 bottles",)]   # one row, qty refreshed


def test_remove_shopping_item_is_idempotent(conn, api_hid):
    state_api.add_shopping_item(conn, api_hid, "soy sauce")
    assert state_api.remove_shopping_item(conn, api_hid, "SOY SAUCE")["removed"] == 1
    assert state_api.remove_shopping_item(conn, api_hid, "soy sauce")["removed"] == 0


def test_remove_leaves_checked_items_alone(conn, api_hid):
    state_api.add_shopping_item(conn, api_hid, "soy sauce")
    conn.execute(
        "update shopping_items set checked=true where household_id=%s", (api_hid,),
    )
    assert state_api.remove_shopping_item(conn, api_hid, "soy sauce")["removed"] == 0


def test_flag_staple_upserts(conn, api_hid):
    first = state_api.flag_staple(conn, api_hid, "jasmine rice")
    again = state_api.flag_staple(conn, api_hid, "jasmine rice")
    assert first["ok"] and again["ok"]
    rows = conn.execute(
        "select name, flagged_low from staples where household_id = %s", (api_hid,),
    ).fetchall()
    assert rows == [("jasmine rice", True)]


def test_capture_inbox_inserts(conn, api_hid):
    out = state_api.capture_inbox(conn, api_hid, "craving", "想吃泰式")
    assert out["ok"] is True
    row = conn.execute(
        "select kind, content from inbox_items where household_id = %s", (api_hid,),
    ).fetchone()
    assert row == ("craving", "想吃泰式")


def test_update_preferences_upserts(conn, api_hid):
    first = state_api.update_preferences(conn, api_hid, "2人份\n不吃香菜")
    assert first["ok"] is True
    row = conn.execute(
        "select content from preferences where household_id = %s", (api_hid,),
    ).fetchone()
    assert row == ("2人份\n不吃香菜",)

    again = state_api.update_preferences(conn, api_hid, "2人份\n不吃香菜、內臟")
    assert again["ok"] is True
    row = conn.execute(
        "select content from preferences where household_id = %s", (api_hid,),
    ).fetchone()
    assert row == ("2人份\n不吃香菜、內臟",)


def test_cli_shopping_verbs(api_hid):
    add = _run_cli(["add-shopping-item", "--name", "fish sauce",
                    "--qty", "1", "--section", "pantry"], api_hid)
    assert json.loads(add.stdout)["ok"] is True
    rm = _run_cli(["remove-shopping-item", "--name", "fish sauce"], api_hid)
    assert json.loads(rm.stdout)["removed"] == 1


def test_cli_update_preferences(api_hid):
    proc = _run_cli(["update-preferences", "--content", "辣度:中辣 OK"], api_hid)
    assert proc.returncode == 0, proc.stderr
    out = json.loads(proc.stdout)
    assert out["ok"] is True and out["content"] == "辣度:中辣 OK"


def _week_of(monday: datetime.date, offset: int) -> str:
    return (monday + datetime.timedelta(days=offset)).isoformat()


def _next_monday_for(household_today: datetime.date) -> datetime.date:
    return week_monday(household_today) + datetime.timedelta(days=7)


def test_set_plan_writes_full_week_and_locks(conn, api_hid):
    target = _next_monday_for(datetime.date.today())
    wid = state_api._ensure_proposing_week_for_test(conn, api_hid, target)
    days = [
        {"date": _week_of(target, i), "dish": f"測試菜{i}", "mode": "fast"}
        for i in range(7)
    ]
    shopping = [{"name": "soy sauce", "qty": "1 bottle", "section": "pantry"}]
    out = state_api.set_plan(conn, api_hid, days, shopping, reasoning="測試摘要")
    assert out == {"ok": True, "week_of": target, "days": 7, "shopping_items": 1}
    status, reasoning = conn.execute(
        "select status, reasoning from plan_weeks where id = %s", (wid,),
    ).fetchone()
    assert status == "locked" and reasoning == "測試摘要"
    written = conn.execute(
        "select date, dish, mode from plan_days where week_id = %s order by date",
        (wid,),
    ).fetchall()
    assert len(written) == 7
    assert written[0] == (target, "測試菜0", "fast")
    shopping_rows = conn.execute(
        "select name, qty, section from shopping_items where week_id = %s", (wid,),
    ).fetchall()
    assert shopping_rows == [("soy sauce", "1 bottle", "pantry")]


def test_set_plan_requires_exactly_seven_days(conn, api_hid):
    target = _next_monday_for(datetime.date.today())
    state_api._ensure_proposing_week_for_test(conn, api_hid, target)
    days = [{"date": _week_of(target, 0), "dish": "測試菜"}]
    with pytest.raises(ValueError, match="7"):
        state_api.set_plan(conn, api_hid, days, [])


def test_set_plan_rejects_date_outside_target_week(conn, api_hid):
    target = _next_monday_for(datetime.date.today())
    state_api._ensure_proposing_week_for_test(conn, api_hid, target)
    days = [
        {"date": _week_of(target, i), "dish": f"測試菜{i}"} for i in range(6)
    ] + [{"date": _week_of(target, 30), "dish": "越界菜"}]
    with pytest.raises(ValueError, match="outside"):
        state_api.set_plan(conn, api_hid, days, [])


def test_set_plan_rejects_no_active_ritual(conn, api_hid):
    conn.execute(
        "delete from plan_weeks where household_id=%s and status='proposing'",
        (api_hid,),
    )
    target = _next_monday_for(datetime.date.today())
    days = [{"date": _week_of(target, i), "dish": f"測試菜{i}"} for i in range(7)]
    with pytest.raises(ValueError, match="no active ritual"):
        state_api.set_plan(conn, api_hid, days, [])


def test_set_plan_replaces_shopping_items_not_accumulates(conn, api_hid):
    target = _next_monday_for(datetime.date.today())
    wid = state_api._ensure_proposing_week_for_test(conn, api_hid, target)
    days = [{"date": _week_of(target, i), "dish": f"測試菜{i}"} for i in range(7)]
    state_api.set_plan(conn, api_hid, days, [{"name": "item-a"}])
    # a second lock call (retry) must not leave item-a AND item-b both present
    conn.execute(
        "update plan_weeks set status='proposing' where id=%s", (wid,),
    )  # simulate a retry re-entering lock with a revised shopping list
    state_api.set_plan(conn, api_hid, days, [{"name": "item-b"}])
    names = {n for (n,) in conn.execute(
        "select name from shopping_items where week_id=%s", (wid,)
    ).fetchall()}
    assert names == {"item-b"}


def test_cli_set_plan(api_hid):
    target = _next_monday_for(datetime.date.today())
    import psycopg
    with psycopg.connect(TEST_DB_URL, autocommit=True) as c:
        state_api._ensure_proposing_week_for_test(c, api_hid, target)
    days_json = json.dumps([
        {"date": _week_of(target, i), "dish": f"CLI測試菜{i}"} for i in range(7)
    ])
    proc = _run_cli(
        ["set-plan", "--days", days_json, "--shopping-items", "[]",
         "--reasoning", "CLI 測試"],
        api_hid,
    )
    assert proc.returncode == 0, proc.stderr
    out = json.loads(proc.stdout)
    assert out["ok"] is True and out["days"] == 7


def test_clear_inbox_removes_all_for_household(conn, api_hid):
    conn.execute(
        "insert into inbox_items (household_id, kind, content) values "
        "(%s, 'craving', '想吃泰式'), (%s, 'feedback', '上次太鹹')",
        (api_hid, api_hid),
    )
    out = state_api.clear_inbox(conn, api_hid)
    assert out == {"ok": True, "removed": 2}
    remaining = conn.execute(
        "select count(*) from inbox_items where household_id=%s", (api_hid,),
    ).fetchone()[0]
    assert remaining == 0


def test_clear_inbox_is_idempotent(conn, api_hid):
    first = state_api.clear_inbox(conn, api_hid)
    second = state_api.clear_inbox(conn, api_hid)
    assert second["removed"] == 0
    assert first["ok"] is True and second["ok"] is True


def test_clear_inbox_scopes_to_household(conn, api_hid):
    from tests.conftest import SANDBOX
    conn.execute(
        "insert into inbox_items (household_id, kind, content) "
        "values (%s, 'note', '不要清掉這個')", (SANDBOX,),
    )
    try:
        state_api.clear_inbox(conn, api_hid)
        row = conn.execute(
            "select content from inbox_items where household_id=%s and content='不要清掉這個'",
            (SANDBOX,),
        ).fetchone()
        assert row is not None
    finally:
        conn.execute(
            "delete from inbox_items where household_id=%s and content='不要清掉這個'",
            (SANDBOX,),
        )


def test_cli_clear_inbox(api_hid):
    proc = _run_cli(["clear-inbox"], api_hid)
    assert proc.returncode == 0, proc.stderr
    assert json.loads(proc.stdout)["ok"] is True


def test_cancel_ritual_removes_proposing_week(conn, api_hid):
    target = _next_monday_for(datetime.date.today())
    state_api._ensure_proposing_week_for_test(conn, api_hid, target)
    out = state_api.cancel_ritual(conn, api_hid)
    assert out == {"ok": True, "cancelled": 1}
    row = conn.execute(
        "select id from plan_weeks where household_id=%s and status='proposing'",
        (api_hid,),
    ).fetchone()
    assert row is None


def test_cancel_ritual_is_idempotent(conn, api_hid):
    first = state_api.cancel_ritual(conn, api_hid)
    second = state_api.cancel_ritual(conn, api_hid)
    assert first == {"ok": True, "cancelled": 0}
    assert second == {"ok": True, "cancelled": 0}


def test_cancel_ritual_leaves_locked_weeks_alone(conn, api_hid):
    target = _next_monday_for(datetime.date.today())
    wid = conn.execute(
        "insert into plan_weeks (household_id, week_of, status) "
        "values (%s, %s, 'locked') returning id", (api_hid, target),
    ).fetchone()[0]
    out = state_api.cancel_ritual(conn, api_hid)
    assert out == {"ok": True, "cancelled": 0}
    status = conn.execute(
        "select status from plan_weeks where id = %s", (wid,),
    ).fetchone()[0]
    assert status == "locked"


def test_cancel_ritual_scopes_to_household(conn, api_hid):
    target = _next_monday_for(datetime.date.today())
    state_api._ensure_proposing_week_for_test(conn, SANDBOX, target)
    try:
        state_api.cancel_ritual(conn, api_hid)
        row = conn.execute(
            "select id from plan_weeks where household_id=%s and status='proposing'",
            (SANDBOX,),
        ).fetchone()
        assert row is not None
    finally:
        conn.execute(
            "delete from plan_weeks where household_id=%s and week_of=%s",
            (SANDBOX, target),
        )


def test_cli_cancel_ritual(api_hid):
    target = _next_monday_for(datetime.date.today())
    import psycopg
    with psycopg.connect(TEST_DB_URL, autocommit=True) as c:
        state_api._ensure_proposing_week_for_test(c, api_hid, target)
    proc = _run_cli(["cancel-ritual"], api_hid)
    assert proc.returncode == 0, proc.stderr
    out = json.loads(proc.stdout)
    assert out == {"ok": True, "cancelled": 1}


def test_save_recipe_inserts_new(conn, api_hid):
    ingredients = [{"name": "chicken thigh", "qty": "300g"}]
    steps = [{"text": "Marinate the chicken", "duration_sec": 600},
             {"text": "Pan-fry until golden", "duration_sec": 480,
              "tip": "don't move it too early"}]
    out = state_api.save_recipe(
        conn, api_hid, title="三杯雞", slug="three-cup-chicken",
        ingredients=ingredients, steps=steps,
        source_block="原文食譜:雞腿肉 300g...", body_md="經典台菜",
    )
    assert out["ok"] is True
    assert out["slug"] == "three-cup-chicken"
    assert out["created"] is True
    row = conn.execute(
        "select title, source_block, body_md, ingredients, steps from recipes "
        "where household_id = %s and slug = %s", (api_hid, "three-cup-chicken"),
    ).fetchone()
    assert row[0] == "三杯雞"
    assert row[1] == "原文食譜:雞腿肉 300g..."
    assert row[3] == ingredients
    assert row[4] == steps


def test_save_recipe_upserts_on_slug_conflict(conn, api_hid):
    first = state_api.save_recipe(
        conn, api_hid, title="三杯雞", slug="three-cup-chicken",
        ingredients=[{"name": "chicken", "qty": "300g"}],
        steps=[{"text": "cook it"}], source_block="v1",
    )
    second = state_api.save_recipe(
        conn, api_hid, title="三杯雞(更新版)", slug="three-cup-chicken",
        ingredients=[{"name": "chicken thigh", "qty": "400g"}],
        steps=[{"text": "cook it better"}], source_block="v2",
    )
    assert first["id"] == second["id"]
    assert first["created"] is True
    assert second["created"] is False
    rows = conn.execute(
        "select title, source_block from recipes where household_id = %s and slug = %s",
        (api_hid, "three-cup-chicken"),
    ).fetchall()
    assert len(rows) == 1
    assert rows[0] == ("三杯雞(更新版)", "v2")


def test_save_recipe_derives_slug_from_ascii_title(conn, api_hid):
    out = state_api.save_recipe(
        conn, api_hid, title="Garlic Fried Rice",
        ingredients=[{"name": "rice", "qty": "2 cups"}],
        steps=[{"text": "fry it"}], source_block="orig",
    )
    assert out["slug"] == "garlic-fried-rice"


def test_save_recipe_requires_explicit_slug_for_non_latin_title(conn, api_hid):
    with pytest.raises(ValueError, match="slug"):
        state_api.save_recipe(
            conn, api_hid, title="三杯雞",
            ingredients=[{"name": "chicken"}], steps=[{"text": "cook"}],
            source_block="orig",
        )


def test_save_recipe_validates_ingredient_and_step_shape(conn, api_hid):
    with pytest.raises(ValueError, match="ingredients"):
        state_api.save_recipe(conn, api_hid, title="x", slug="x",
                              ingredients=[], steps=[{"text": "a"}], source_block="s")
    with pytest.raises(ValueError, match="name"):
        state_api.save_recipe(conn, api_hid, title="x", slug="x",
                              ingredients=[{"qty": "1"}], steps=[{"text": "a"}],
                              source_block="s")
    with pytest.raises(ValueError, match="steps"):
        state_api.save_recipe(conn, api_hid, title="x", slug="x",
                              ingredients=[{"name": "a"}], steps=[], source_block="s")
    with pytest.raises(ValueError, match="text"):
        state_api.save_recipe(conn, api_hid, title="x", slug="x",
                              ingredients=[{"name": "a"}], steps=[{"duration_sec": 1}],
                              source_block="s")


def test_cli_save_recipe(api_hid):
    ingredients_json = json.dumps([{"name": "chicken", "qty": "300g"}])
    steps_json = json.dumps([{"text": "cook it", "duration_sec": 300}])
    proc = _run_cli(
        ["save-recipe", "--title", "三杯雞", "--slug", "three-cup-chicken",
         "--source-block", "orig text", "--ingredients", ingredients_json,
         "--steps", steps_json],
        api_hid,
    )
    assert proc.returncode == 0, proc.stderr
    out = json.loads(proc.stdout)
    assert out["ok"] is True and out["slug"] == "three-cup-chicken"


def test_schedule_notification_morning_nudge_uses_fixed_time(conn, api_hid):
    out = state_api.schedule_notification(
        conn, api_hid, "morning_nudge", "早安!", "今天煮咖哩飯", date=MONDAY,
    )
    assert out["ok"] is True and out["deduped"] is False
    send_at, kind, title, body = conn.execute(
        "select send_at, kind, title, body from notifications where id = %s",
        (out["id"],),
    ).fetchone()
    assert kind == "morning_nudge" and title == "早安!" and body == "今天煮咖哩飯"
    local = send_at.astimezone(ZoneInfo("Australia/Sydney"))
    assert (local.date(), local.hour, local.minute) == (MONDAY, 7, 30)


def test_schedule_notification_prep_reminder_uses_fixed_time(conn, api_hid):
    out = state_api.schedule_notification(
        conn, api_hid, "prep_reminder", "備料提醒", "記得先醃肉", date=MONDAY,
    )
    local = conn.execute(
        "select send_at from notifications where id = %s", (out["id"],)
    ).fetchone()[0].astimezone(ZoneInfo("Australia/Sydney"))
    assert (local.date(), local.hour, local.minute) == (MONDAY, 15, 0)


def test_schedule_notification_verdict_action_sends_now(conn, api_hid):
    before = datetime.datetime.now(ZoneInfo("Australia/Sydney"))
    out = state_api.schedule_notification(
        conn, api_hid, "verdict_action", "煮得如何?", "跟小當家說說今天的咖哩飯吧",
    )
    send_at = conn.execute(
        "select send_at from notifications where id = %s", (out["id"],)
    ).fetchone()[0]
    assert send_at >= before  # not scheduled for a fixed future time-of-day


def test_schedule_notification_requires_date_for_fixed_time_kinds(conn, api_hid):
    with pytest.raises(ValueError, match="requires --date"):
        state_api.schedule_notification(conn, api_hid, "morning_nudge", "t", "b")


def test_schedule_notification_rejects_unknown_kind(conn, api_hid):
    with pytest.raises(ValueError, match="kind must be one of"):
        state_api.schedule_notification(conn, api_hid, "bogus", "t", "b")


def test_schedule_notification_dedupes_on_source_id(conn, api_hid):
    day_row = conn.execute(
        "select id::text from plan_days where household_id=%s and date=%s",
        (api_hid, MONDAY),
    ).fetchone()
    first = state_api.schedule_notification(
        conn, api_hid, "morning_nudge", "早安!", "咖哩飯", date=MONDAY,
        source_id=day_row[0],
    )
    second = state_api.schedule_notification(
        conn, api_hid, "morning_nudge", "早安(retry)!", "咖哩飯", date=MONDAY,
        source_id=day_row[0],
    )
    assert first["deduped"] is False and second["deduped"] is True
    count = conn.execute(
        "select count(*) from notifications where household_id=%s and kind='morning_nudge'",
        (api_hid,),
    ).fetchone()[0]
    assert count == 1


def test_schedule_notification_cli_dispatches(api_hid):
    # Reuses the existing _run_cli helper (defined further down this file, around the
    # cli_get_plan_roundtrip tests) rather than inventing a new subprocess pattern.
    proc = _run_cli(["schedule-notification", "--kind", "verdict_action",
                     "--title", "煮得如何?", "--body", "說說看"], api_hid)
    assert proc.returncode == 0, proc.stderr
    out = json.loads(proc.stdout)
    assert out["ok"] is True and out["kind"] == "verdict_action"
