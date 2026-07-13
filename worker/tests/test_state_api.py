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
