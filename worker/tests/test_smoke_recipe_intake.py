"""Real-pipeline recipe intake smoke test. Slow (Gemini video fetch + a real
`claude -p` turn) — run explicitly with:
  SOUS_SMOKE=1 uv run pytest tests/test_smoke_recipe_intake.py -v -s
Requires GEMINI_API_KEY in worker/.env and the local Supabase stack.

RECIPE_URL below is a placeholder — replace it with a real, currently-live
Instagram reel or YouTube video of an actual recipe before running this test.
"""
import os

import pytest
from psycopg.types.json import Jsonb

from sous_worker import main
from tests.conftest import SANDBOX, TEST_DB_URL

pytestmark = pytest.mark.skipif(
    not os.environ.get("SOUS_SMOKE"), reason="set SOUS_SMOKE=1 to run the real-pipeline smoke test"
)

RECIPE_URL = "https://www.youtube.com/watch?v=REPLACE_WITH_REAL_RECIPE_VIDEO_ID"


def test_recipe_intake_end_to_end(conn, monkeypatch):
    monkeypatch.setenv("SOUS_DB_URL", TEST_DB_URL)
    conn.execute("delete from recipes where household_id=%s", (SANDBOX,))
    conn.execute("delete from inbox_items where household_id=%s and kind='craving'",
                 (SANDBOX,))
    jid = conn.execute(
        "insert into jobs (household_id, kind, payload) "
        "values (%s, 'recipe_intake', %s) returning id::text",
        (SANDBOX, Jsonb({"url": RECIPE_URL, "by": "mike"})),
    ).fetchone()[0]

    cfg = main.load_config()
    assert main.process_one(conn, cfg) is True

    status, result = conn.execute(
        "select status, result from jobs where id=%s", (jid,)
    ).fetchone()
    assert status == "done", result

    recipe = conn.execute(
        "select title, steps, ingredients, source_block from recipes "
        "where household_id=%s order by created_at desc limit 1", (SANDBOX,),
    ).fetchone()
    assert recipe is not None, "brain never called save-recipe"
    title, steps, ingredients, source_block = recipe
    assert len(steps) > 0 and len(ingredients) > 0
    assert source_block  # verbatim original captured
    for step in steps:
        assert "text" in step

    craving = conn.execute(
        "select content from inbox_items where household_id=%s and kind='craving' "
        "order by created_at desc limit 1", (SANDBOX,),
    ).fetchone()
    assert craving is not None and title in craving[0]
