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


def test_cli_shopping_verbs(api_hid):
    add = _run_cli(["add-shopping-item", "--name", "fish sauce",
                    "--qty", "1", "--section", "pantry"], api_hid)
    assert json.loads(add.stdout)["ok"] is True
    rm = _run_cli(["remove-shopping-item", "--name", "fish sauce"], api_hid)
    assert json.loads(rm.stdout)["removed"] == 1
