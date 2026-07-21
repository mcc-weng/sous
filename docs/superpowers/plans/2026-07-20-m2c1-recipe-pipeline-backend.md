# M2c1 — Recipe Pipeline Backend Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the worker a `recipe_intake` job kind that turns a shared IG/YouTube/web
recipe URL into a real `recipes` row with structured `steps`/`ingredients` JSONB, driven
end-to-end by direct job insertion (no iOS involved — that's M2c2).

**Architecture:** A new `save-recipe` state_api verb (following the exact JSON-blob-CLI-arg
pattern `set-plan` already established) is the only new write seam. A new worker-side
module (`gemini_intake.py`, ported from alfred's `scripts/recipe_intake.py`) does a
deterministic Gemini video/audio-fusion pre-fetch *before* the brain runs — not an LLM tool
call, exactly like alfred's `listener.py`. A new prompt (`recipe_intake.md`) gets the
pre-fetched context plus a `WebFetch` tool and must end by calling `save-recipe` then
`capture-inbox` (already exists). `main.py`'s `process_one` gains a third branch alongside
`chat`/`ritual`, reusing the exact same "brain returns text → insert as a chat_messages row
→ complete the job" completion path — no new verb is needed to "announce" the save; the
brain's own final reply *is* the announcement, exactly like alfred's chat mode.

**Tech Stack:** Python 3.11+, psycopg3, `google-genai` SDK (new dependency), system `yt-dlp`
binary (already installed via alfred's setup — confirmed at `/opt/homebrew/bin/yt-dlp`),
pytest.

**Deviation from the approved design spec, found during planning:** the spec
(`docs/superpowers/specs/2026-07-20-m2c-recipe-pipeline-design.md`) named a new `post-card`
verb for announcing "新菜學會了". Closer inspection of `main.py`'s existing completion path
shows it's unnecessary: whatever text `generate_recipe_intake_reply` returns already gets
inserted as a `chat_messages` row by the same code that already does this for `chat`/
`ritual` jobs (`main.py:91-93`). The brain's final turn — after calling `save-recipe` and
`capture-inbox` — naturally ends with a short announcement, which becomes that row for
free. This plan drops `post-card` entirely; nothing in the design's actual behavior changes,
just how it's wired.

## Global Constraints

- Household comes from `SOUS_HOUSEHOLD_ID` env only, injected by the worker per job —
  never a CLI arg, never trusted from job payload (state_api contract, `state_api.py:8-10`).
- Every state_api verb prints exactly one JSON line (`{"ok": true, ...}` or
  `{"ok": false, "error": ...}` + exit 1) and must be idempotent or at-least-once safe
  (`state_api.py:11-16`).
- No persona strings hardcoded in prompts — voice arrives only via `{persona_pack}`
  (CLAUDE.md persona-discipline rule; enforced today by `test_chat_prompt_is_persona_neutral`
  in `worker/tests/test_prompts.py`).
- No markdown tables in any prompt (chat rendering doesn't support them — existing rule in
  `chat.md`/`ritual.md`, carry into `recipe_intake.md`).
- `duration_sec` is required (prompt-level instruction, not schema-enforced) whenever a
  step is genuinely time-bound; optional for pure actions — ported from alfred's
  2026-07-13 lesson that leaving this "judgment-based" caused silent drops.
- `steps` must mirror the source's step count and order exactly — no adding/splitting/
  merging (ported from alfred's enrichment rules).
- Frames/vision/image fallback tiers are explicitly **out of scope** (user's scope decision,
  2026-07-20) — `gemini_intake.py` only ever produces `gemini`/`caption`/`none`, never a
  `frames` tier.
- `yt-dlp` and `ffmpeg` are system binaries, not Python dependencies — resolved via
  `shutil.which()`, matching alfred's `_bin()` helper exactly. Confirmed already installed
  at `/opt/homebrew/bin/yt-dlp` (ffmpeg isn't actually needed for M2c1 — no frames tier —
  but is already present too).

---

### Task 1: `save-recipe` state_api verb

**Files:**
- Modify: `worker/state_api.py`
- Test: `worker/tests/test_state_api.py`

**Interfaces:**
- Produces: `save_recipe(conn, household_id: str, title: str, ingredients: list, steps: list, source_block: str, body_md: str = "", slug: str | None = None) -> dict` returning `{"ok": True, "id": <uuid str>, "slug": <str>, "created": <bool>}`. CLI verb: `save-recipe --title --slug? --source-block --body-md? --ingredients <JSON> --steps <JSON>`.

- [ ] **Step 1: Write the failing tests**

Add to `worker/tests/test_state_api.py` (near the end, after the `cancel-ritual` tests,
before `_JSONErrorParser`/CLI parser tests — i.e. keep it grouped with the other
verb-level tests):

```python
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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd worker && uv run pytest tests/test_state_api.py -k save_recipe -v`
Expected: FAIL with `AttributeError: module 'state_api' has no attribute 'save_recipe'`

- [ ] **Step 3: Add imports to `worker/state_api.py`**

At the top, alongside the existing imports:

```python
import re
```

and change:

```python
from dotenv import load_dotenv
```

to:

```python
from dotenv import load_dotenv
from psycopg.types.json import Jsonb
```

- [ ] **Step 4: Implement `save_recipe` and `_slugify`**

Add after `cancel_ritual` (before `_ensure_proposing_week_for_test`):

```python
def _slugify(text: str) -> str:
    text = text.strip().lower()
    text = re.sub(r"[^a-z0-9]+", "-", text)
    return text.strip("-")


def save_recipe(conn, household_id: str, title: str, ingredients: list, steps: list,
                source_block: str, body_md: str = "", slug: str | None = None) -> dict:
    if not ingredients:
        raise ValueError("ingredients must be a non-empty list")
    for ing in ingredients:
        if "name" not in ing:
            raise ValueError('each ingredient needs a "name"')
    if not steps:
        raise ValueError("steps must be a non-empty list")
    for st in steps:
        if "text" not in st:
            raise ValueError('each step needs "text"')
    resolved_slug = _slugify(slug or title)
    if not resolved_slug:
        raise ValueError("empty slug after deriving from title — pass an explicit "
                         "--slug for non-Latin titles")
    row = conn.execute(
        "insert into recipes (household_id, slug, title, source_block, body_md, "
        "ingredients, steps) values (%s, %s, %s, %s, %s, %s, %s) "
        "on conflict (household_id, slug) do update set "
        "title = excluded.title, source_block = excluded.source_block, "
        "body_md = excluded.body_md, ingredients = excluded.ingredients, "
        "steps = excluded.steps "
        "returning id::text, (xmax = 0) as inserted",
        (household_id, resolved_slug, title, source_block, body_md,
         Jsonb(ingredients), Jsonb(steps)),
    ).fetchone()
    return {"ok": True, "id": row[0], "slug": resolved_slug, "created": row[1]}
```

- [ ] **Step 5: Wire the CLI subparser**

In `_parser()`, add after `sub.add_parser("cancel-ritual")`:

```python
    sr = sub.add_parser("save-recipe")
    sr.add_argument("--title", required=True)
    sr.add_argument("--slug")
    sr.add_argument("--source-block", dest="source_block", required=True)
    sr.add_argument("--body-md", dest="body_md", default="")
    sr.add_argument("--ingredients", required=True,
                    help='JSON array: [{"name","qty"?}, ...]')
    sr.add_argument("--steps", required=True,
                    help='JSON array: [{"text","duration_sec"?,"tip"?}, ...]')
```

- [ ] **Step 6: Wire the CLI dispatch**

In `_dispatch()`, add before `raise ValueError(f"unknown verb {args.verb}")`:

```python
    if args.verb == "save-recipe":
        try:
            ingredients = json.loads(args.ingredients)
            steps = json.loads(args.steps)
        except json.JSONDecodeError as exc:
            raise ValueError(f"invalid JSON in --ingredients or --steps: {exc}") from None
        return save_recipe(conn, household_id, args.title, ingredients, steps,
                           args.source_block, body_md=args.body_md, slug=args.slug)
```

- [ ] **Step 7: Run tests to verify they pass**

Run: `cd worker && uv run pytest tests/test_state_api.py -v`
Expected: PASS (all tests, including the pre-existing ones — this confirms nothing broke)

- [ ] **Step 8: Commit**

```bash
git add worker/state_api.py worker/tests/test_state_api.py
git commit -m "feat(worker): save-recipe state_api verb with upsert-by-slug"
```

---

### Task 2: `gemini_intake.py` — worker-side pre-fetch module

**Files:**
- Create: `worker/sous_worker/gemini_intake.py`
- Test: `worker/tests/test_gemini_intake.py`

**Interfaces:**
- Produces: `is_recipe_video_url(url: str) -> bool`; `fetch_recipe_context(url: str) -> dict` returning one of `{"source": "gemini", "understanding": str}`, `{"source": "caption", "title": str, "uploader": str, "description": str}`, `{"source": "none", "error": str}`. Never raises.

- [ ] **Step 1: Write the failing tests**

Create `worker/tests/test_gemini_intake.py`:

```python
from sous_worker import gemini_intake


def test_is_recipe_video_url_matches_instagram_reel():
    assert gemini_intake.is_recipe_video_url("https://www.instagram.com/reel/DUNy6_ADXyp/")


def test_is_recipe_video_url_matches_youtube_watch_shorts_and_short_link():
    assert gemini_intake.is_recipe_video_url("https://www.youtube.com/watch?v=abc123")
    assert gemini_intake.is_recipe_video_url("https://www.youtube.com/shorts/abc123")
    assert gemini_intake.is_recipe_video_url("https://youtu.be/abc123")


def test_is_recipe_video_url_rejects_plain_web_page():
    assert not gemini_intake.is_recipe_video_url("https://www.seriouseats.com/three-cup-chicken")


def test_fetch_recipe_context_skips_prefetch_for_non_video_url():
    out = gemini_intake.fetch_recipe_context("https://www.seriouseats.com/three-cup-chicken")
    assert out == {"source": "none", "error": "not an IG/YouTube video URL"}


def test_fetch_recipe_context_prefers_gemini_when_it_succeeds(monkeypatch):
    monkeypatch.setattr(gemini_intake, "_fetch_gemini",
                        lambda url, caption_description: {"understanding": "看到雞腿肉..."})
    monkeypatch.setattr(gemini_intake, "_fetch_caption",
                        lambda url: {"title": "t", "uploader": "u", "description": "d"})
    out = gemini_intake.fetch_recipe_context("https://youtu.be/abc123")
    assert out == {"source": "gemini", "understanding": "看到雞腿肉..."}


def test_fetch_recipe_context_falls_back_to_caption_when_gemini_fails(monkeypatch):
    monkeypatch.setattr(gemini_intake, "_fetch_gemini",
                        lambda url, caption_description: {"error": "no GEMINI_API_KEY"})
    monkeypatch.setattr(gemini_intake, "_fetch_caption",
                        lambda url: {"title": "三杯雞食譜", "uploader": "u", "description": "d"})
    out = gemini_intake.fetch_recipe_context("https://youtu.be/abc123")
    assert out == {"source": "caption", "title": "三杯雞食譜", "uploader": "u", "description": "d"}


def test_fetch_recipe_context_returns_none_when_both_fail(monkeypatch):
    monkeypatch.setattr(gemini_intake, "_fetch_gemini",
                        lambda url, caption_description: {"error": "no GEMINI_API_KEY"})
    monkeypatch.setattr(gemini_intake, "_fetch_caption",
                        lambda url: {"error": "video unavailable"})
    out = gemini_intake.fetch_recipe_context("https://youtu.be/abc123")
    assert out == {"source": "none", "error": "video unavailable"}


def test_fetch_caption_parses_yt_dlp_json(monkeypatch):
    import json as _json
    import subprocess

    fake_stdout = _json.dumps({
        "title": "三杯雞食譜", "uploader": "chef_x", "description": "300g 雞腿肉...",
    }).encode()

    def fake_run(*a, **kw):
        return subprocess.CompletedProcess(a, 0, stdout=fake_stdout, stderr=b"")

    monkeypatch.setattr(subprocess, "run", fake_run)
    out = gemini_intake._fetch_caption("https://youtu.be/abc123")
    assert out == {"title": "三杯雞食譜", "uploader": "chef_x", "description": "300g 雞腿肉..."}


def test_fetch_caption_handles_yt_dlp_failure(monkeypatch):
    import subprocess

    def fake_run(*a, **kw):
        return subprocess.CompletedProcess(a, 1, stdout=b"", stderr=b"video unavailable")

    monkeypatch.setattr(subprocess, "run", fake_run)
    out = gemini_intake._fetch_caption("https://youtu.be/abc123")
    assert "error" in out
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd worker && uv run pytest tests/test_gemini_intake.py -v`
Expected: FAIL with `ModuleNotFoundError: No module named 'sous_worker.gemini_intake'`

- [ ] **Step 3: Implement `worker/sous_worker/gemini_intake.py`**

```python
"""Worker-side deterministic recipe pre-fetch for IG/YouTube links — runs
before the brain is ever invoked (never as an LLM tool call), mirroring
alfred's listener.py. Ported from alfred's scripts/recipe_intake.py
(`cmd_gemini`/`cmd_caption`); frames/vision fallback intentionally dropped —
M2c scope decision (2026-07-20): IG/YouTube via Gemini + plain web pages via
the brain's own WebFetch only, nothing else in v1.
"""
import json
import os
import pathlib
import re
import shutil
import subprocess
import time

GEMINI_MODELS = ("gemini-2.5-flash", "gemini-2.0-flash")
GEMINI_HTTP_TIMEOUT_MS = 70_000
GEMINI_FILE_WAIT = 45  # max seconds to wait for an uploaded video to become ACTIVE
DOWNLOAD_TIMEOUT = 90
MAX_FILESIZE = "150M"
CAPTION_TIMEOUT = 60

_TMP_DIR = pathlib.Path(__file__).resolve().parent.parent / ".runtime" / "recipe_intake"


def _bin(name: str, env: str) -> str:
    return os.environ.get(env) or shutil.which(name) or name


def is_recipe_video_url(url: str) -> bool:
    return bool(re.search(
        r"(instagram\.com/(reel|p|tv)/|youtube\.com/(watch|shorts)|youtu\.be/)",
        url, re.IGNORECASE,
    ))


def is_youtube(url: str) -> bool:
    return bool(re.search(r"youtube\.com|youtu\.be", url, re.IGNORECASE))


def _fetch_caption(url: str) -> dict:
    try:
        out = subprocess.run(
            [_bin("yt-dlp", "YT_DLP_BIN"), "-j", "--skip-download",
             "--no-warnings", "--no-playlist", url],
            capture_output=True, timeout=CAPTION_TIMEOUT,
        )
    except subprocess.TimeoutExpired:
        return {"error": "caption fetch timed out"}
    if out.returncode != 0:
        return {"error": out.stderr.decode()[:300]}
    try:
        info = json.loads(out.stdout.decode())
    except json.JSONDecodeError:
        return {"error": "bad json from yt-dlp"}
    return {
        "title": info.get("title") or "",
        "uploader": info.get("uploader") or info.get("channel") or "",
        "description": info.get("description") or "",
    }


def _clip_path(url: str) -> pathlib.Path:
    vid = "".join(c for c in url if c.isalnum())[-16:] or "clip"
    return _TMP_DIR / vid / "clip.mp4"


def _download_video(url: str, dest: pathlib.Path) -> bool:
    dest.parent.mkdir(parents=True, exist_ok=True)
    try:
        dl = subprocess.run(
            [_bin("yt-dlp", "YT_DLP_BIN"), "-f", "mp4/best", "--no-warnings",
             "--no-playlist", "--max-filesize", MAX_FILESIZE, "-o", str(dest), url],
            capture_output=True, timeout=DOWNLOAD_TIMEOUT,
        )
    except subprocess.TimeoutExpired:
        return False
    return dl.returncode == 0 and dest.exists()


def _file_state(f) -> str:
    return str(getattr(f.state, "name", f.state)).upper()


def _gemini_prompt(caption: str) -> str:
    base = (
        "看這支料理影片,給我關於它的『完整理解』(不只是食譜):\n"
        "1) 菜名\n2) 食材(盡量含份量)\n3) 步驟\n"
        "4) 值得注意的細節:技巧、火候、時間、感官線索(看到/聽到/聞到什麼才算對)、"
        "視覺觀察、主廚會注意的 nuance。\n"
        "最後,把來源(影片字幕/貼文)原本寫的食材與步驟『原文照抄』另列一段,"
        "標題寫「原文食譜」,讓我能保留原始食譜。\n全部用繁體中文。"
    )
    if caption.strip():
        base += f"\n\n【貼文文字(請一併參考並原文保留)】\n{caption.strip()}"
    return base


def _fetch_gemini(url: str, caption_description: str) -> dict:
    key = os.environ.get("GEMINI_API_KEY")
    if not key:
        return {"error": "no GEMINI_API_KEY"}
    try:
        from google import genai
        from google.genai import types
    except ImportError:
        return {"error": "google-genai not installed"}
    prompt = _gemini_prompt(caption_description)
    try:
        client = genai.Client(
            api_key=key, http_options=types.HttpOptions(timeout=GEMINI_HTTP_TIMEOUT_MS))
        if is_youtube(url):
            contents = [types.Part(file_data=types.FileData(file_uri=url)), prompt]
        else:
            mp4 = _clip_path(url)
            if not _download_video(url, mp4):
                return {"error": "download failed or file too large"}
            gfile = client.files.upload(file=str(mp4))
            waited = 0
            while _file_state(gfile) == "PROCESSING" and waited < GEMINI_FILE_WAIT:
                time.sleep(3)
                waited += 3
                gfile = client.files.get(name=gfile.name)
            if _file_state(gfile) != "ACTIVE":
                return {"error": f"gemini file state {_file_state(gfile)}"}
            contents = [gfile, prompt]
        text = ""
        for model in GEMINI_MODELS:
            try:
                text = client.models.generate_content(model=model, contents=contents).text
                break
            except Exception:  # noqa: BLE001 — try next model
                continue
        return {"understanding": text} if text else {"error": "empty gemini response"}
    except Exception as exc:  # noqa: BLE001 — degrade to caption upstream
        return {"error": str(exc)[:200]}


def fetch_recipe_context(url: str) -> dict:
    """Never raises. Returns exactly one of:
    {"source": "gemini", "understanding": str}
    {"source": "caption", "title": str, "uploader": str, "description": str}
    {"source": "none", "error": str}
    """
    if not is_recipe_video_url(url):
        return {"source": "none", "error": "not an IG/YouTube video URL"}
    caption = _fetch_caption(url)
    gemini = _fetch_gemini(url, caption.get("description", ""))
    if "understanding" in gemini:
        return {"source": "gemini", "understanding": gemini["understanding"]}
    if "error" not in caption:
        return {"source": "caption", **caption}
    return {"source": "none", "error": gemini.get("error") or caption.get("error")}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd worker && uv run pytest tests/test_gemini_intake.py -v`
Expected: PASS (9 tests)

- [ ] **Step 5: Commit**

```bash
git add worker/sous_worker/gemini_intake.py worker/tests/test_gemini_intake.py
git commit -m "feat(worker): gemini_intake pre-fetch module ported from alfred"
```

---

### Task 3: `recipe_intake.md` prompt + `context.py` additions

**Files:**
- Create: `worker/prompts/recipe_intake.md`
- Modify: `worker/sous_worker/context.py`
- Test: `worker/tests/test_context.py`, `worker/tests/test_prompts.py`

**Interfaces:**
- Consumes: the `fetch_recipe_context` return shape from Task 2 (`{"source": "gemini"|"caption"|"none", ...}`) as the documented input contract for `_render_prefetch`.
- Produces: `context.fetch_recipe_intake_context(conn, household_id, now=None) -> dict`; `context.build_recipe_intake_prompt(template, ctx, url, by, prefetch) -> str`; `context._render_prefetch(prefetch: dict) -> str`.

- [ ] **Step 1: Write the failing tests**

Add to `worker/tests/test_context.py` (at the end):

```python
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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd worker && uv run pytest tests/test_context.py -k recipe_intake -v`
Run: `cd worker && uv run pytest tests/test_context.py -k render_prefetch -v`
Run: `cd worker && uv run pytest tests/test_context.py -k build_recipe_intake -v`
Expected: FAIL with `AttributeError` for each new function

- [ ] **Step 3: Implement the `context.py` additions**

Add at the end of `worker/sous_worker/context.py`:

```python
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
```

- [ ] **Step 4: Create `worker/prompts/recipe_intake.md`**

```markdown
{persona_pack}

Today is {today}({weekday})。這是「食譜擷取」模式 — 有人分享了一則連結,把它存進食譜庫。

## 這次要擷取的內容
來源網址:{url}
分享者:{by}

{prefetched_context}

## 擷取規則
**鐵則:只處理上面這則連結帶來的食譜。不要從其他來源編造或挪用別道菜。**

- 上面若有「Gemini 完整理解」,把它當素材、萃取精華做成「精簡」食譜卡(深度依菜的技術
  門檻調整:簡單菜只用 inline 提示,別開一堆區塊),並把其中「原文食譜」段落的食材/
  步驟原文整理進 source_block。
- 上面若只有標題/說明(沒有 Gemini 理解),或完全沒有預先擷取到內容,用 **WebFetch**
  試著讀這個網址本身(食譜網頁常常直接抓得到);抓不到就照實回覆抓不到,不要編造。
- **步驟結構照原文走 — 不增、不拆、不併步驟**,原文幾步就幾步、同順序(只有原文把
  好幾個動作擠成一句、新手會跟不上時,才在文字裡合理拆解說明,但存檔的 steps 陣列
  仍照原文步數)。
- **每一步都要判斷是否需要 duration_sec**:有實際花費時間的動作(燉、煮、烤、醃、
  發酵、靜置)**一定要標秒數**;純動作(調味、拌勻、盛盤)可以不標。
- 份量換算到 2 人份;換不乾淨的(1 顆蛋、一撮鹽)就照原樣寫,不要編造假分數。
- 心得/秘訣當 tip 掛在對應步驟。

## 你的手(state_api — 存食譜的唯一途徑)
用 Bash 執行以下指令。每個指令回一行 JSON;看到 "ok": true 才算存成功。

- 存食譜:
  `.venv/bin/python state_api.py save-recipe --title "<繁中標題>" --slug "<英文-kebab-slug>" --source-block "<原文食材+步驟,未改動>" --body-md "<選填的整體心得/秘訣>" --ingredients '[{"name":"...","qty":"..."}]' --steps '[{"text":"...","duration_sec":180,"tip":"..."}]'`
  `--slug` 一定要給英文小寫連字號代稱(中文標題不能當 slug)。
- 存好食譜後,排進下週候選(save-recipe 成功之後一定要做):
  `.venv/bin/python state_api.py capture-inbox --kind craving --content "想做<標題>"`

## 規則
- 兩個指令都要呼叫,且順序固定:`save-recipe` 先成功,才呼叫 `capture-inbox`。
- 只回報 state_api 確認過(ok: true)的結果;失敗就老實說失敗,不要假裝存好了。
- 完全抓不到食譜內容(連結失效、不是料理、Gemini 和 WebFetch 都沒有結果)→ 不要呼叫
  save-recipe,老實回覆抓不到,建議對方換個方式分享(截圖或直接打字食譜)。
- 回覆的最後一段文字會直接貼進聊天室,當作「存好了」的公告 — 用小當家的口吻,
  簡短帶出菜名 + 一句「排進下週候選了」,**不用把整張食譜卡複誦一次**(食譜庫本身
  已經存好完整內容,聊天室不必重複貼一次全文)。
- 不要署名;emoji 點到為止。不要用 markdown 表格;要列就條列。
```

- [ ] **Step 5: Add prompt-contract tests to `worker/tests/test_prompts.py`**

Append at the end:

```python
RECIPE_INTAKE_PROMPT = (pathlib.Path(__file__).resolve().parent.parent / "prompts" / "recipe_intake.md").read_text()

RECIPE_INTAKE_VERBS = ["save-recipe", "capture-inbox"]
RECIPE_INTAKE_PLACEHOLDERS = ["{persona_pack}", "{today}", "{weekday}", "{url}",
                              "{by}", "{prefetched_context}"]


def test_recipe_intake_prompt_documents_every_verb():
    for verb in RECIPE_INTAKE_VERBS:
        assert verb in RECIPE_INTAKE_PROMPT, f"recipe_intake.md must document {verb}"
    assert ".venv/bin/python state_api.py" in RECIPE_INTAKE_PROMPT


def test_recipe_intake_prompt_is_persona_neutral():
    assert "小當家" not in RECIPE_INTAKE_PROMPT


def test_recipe_intake_prompt_keeps_all_placeholders():
    for ph in RECIPE_INTAKE_PLACEHOLDERS:
        assert ph in RECIPE_INTAKE_PROMPT
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `cd worker && uv run pytest tests/test_context.py tests/test_prompts.py -v`
Expected: PASS (all tests, including pre-existing ones)

- [ ] **Step 7: Commit**

```bash
git add worker/prompts/recipe_intake.md worker/sous_worker/context.py \
        worker/tests/test_context.py worker/tests/test_prompts.py
git commit -m "feat(worker): recipe_intake prompt + context rendering"
```

---

### Task 4: `main.py` job-kind wiring + config

**Files:**
- Modify: `worker/sous_worker/main.py`
- Modify: `worker/config.json`
- Modify: `worker/tests/test_main.py`

**Interfaces:**
- Consumes: `gemini_intake.fetch_recipe_context` (Task 2), `context.fetch_recipe_intake_context` / `context.build_recipe_intake_prompt` (Task 3).
- Produces: `main.generate_recipe_intake_reply(conn, job: db.Job, cfg: dict) -> str`; `process_one` now handles `job.kind == "recipe_intake"`.

- [ ] **Step 1: Fix the pre-existing test-placeholder collision**

`worker/tests/test_main.py` currently has `test_unknown_job_kind_fails_cleanly` using
`'recipe_intake'` as a stand-in for an unknown kind — that collides with this task making
`recipe_intake` a real kind (flagged in project memory as an expected collision). Find:

```python
def test_unknown_job_kind_fails_cleanly(conn):
    jid = conn.execute(
        "insert into jobs (household_id, kind) values (%s,'recipe_intake') returning id::text",
        (SANDBOX,),
    ).fetchone()[0]
```

Replace with:

```python
def test_unknown_job_kind_fails_cleanly(conn):
    jid = conn.execute(
        "insert into jobs (household_id, kind) values (%s,'bogus_kind') returning id::text",
        (SANDBOX,),
    ).fetchone()[0]
```

- [ ] **Step 2: Add the `gemini_intake` import to `main.py`**

Do this small piece first so the failing tests in Step 3 fail for the *intended* reason
(job kind not handled yet) rather than an unrelated `AttributeError` on a missing module
attribute. Change:

```python
from sous_worker import brain, context, db
```

to:

```python
from sous_worker import brain, context, db, gemini_intake
```

- [ ] **Step 3: Write the new failing tests**

Append to `worker/tests/test_main.py`:

```python
def _insert_recipe_intake_job(conn, url: str, by: str = "mike"):
    jid = conn.execute(
        "insert into jobs (household_id, kind, payload) "
        "values (%s, 'recipe_intake', %s) returning id::text",
        (SANDBOX, Jsonb({"url": url, "by": by})),
    ).fetchone()[0]
    return jid


def test_recipe_intake_job_runs_prefetch_and_wires_prompt(conn, monkeypatch):
    seen = {}

    def fake_prefetch(url):
        seen["prefetch_url"] = url
        return {"source": "caption", "title": "三杯雞", "uploader": "x", "description": "y"}

    def fake_run_brain(prompt, **kw):
        seen["prompt"] = prompt
        seen.update(kw)
        return "存好了!🔥 三杯雞排進下週候選了"

    monkeypatch.setattr(main.gemini_intake, "fetch_recipe_context", fake_prefetch)
    monkeypatch.setattr(main.brain, "run_brain", fake_run_brain)
    jid = _insert_recipe_intake_job(conn, "https://instagram.com/reel/abc")
    assert main.process_one(conn, main.load_config()) is True

    assert seen["prefetch_url"] == "https://instagram.com/reel/abc"
    assert "三杯雞" in seen["prompt"]          # caption title rendered into the prompt
    assert "WebFetch" in seen["allowed_tools"]
    assert seen["extra_env"] == {"SOUS_HOUSEHOLD_ID": SANDBOX}

    sender, content, job_id = conn.execute(
        "select sender, content, job_id::text from chat_messages "
        "where sender='chef' order by created_at desc limit 1"
    ).fetchone()
    assert content == "存好了!🔥 三杯雞排進下週候選了" and job_id == jid
    result = conn.execute("select result from jobs where id=%s", (jid,)).fetchone()[0]
    assert result["mode"] == "recipe_intake"
```

- [ ] **Step 4: Run tests to verify they fail**

Run: `cd worker && uv run pytest tests/test_main.py -k recipe_intake -v`
Expected: `test_unknown_job_kind_fails_cleanly` PASSes (unrelated to this feature — just
confirms the placeholder swap from Step 1 didn't break it). `test_recipe_intake_job_runs_prefetch_and_wires_prompt`
FAILs with `ValueError: unknown job kind: recipe_intake` — the `gemini_intake` import from
Step 2 means the monkeypatch itself succeeds; the failure is `process_one` correctly not
knowing what to do with the new kind yet.

- [ ] **Step 5: Update `worker/config.json`**

Replace the full file with:

```json
{
  "chat_model": "sonnet",
  "chat_timeout_sec": 480,
  "chat_allowed_tools": ["Read", "Bash(.venv/bin/python state_api.py:*)"],
  "recipe_intake_timeout_sec": 300,
  "recipe_intake_allowed_tools": ["Bash(.venv/bin/python state_api.py:*)", "WebFetch"],
  "poll_interval_sec": 3,
  "heartbeat_interval_sec": 15,
  "stale_after_sec": 600,
  "max_attempts": 2,
  "history_limit": 20
}
```

(`recipe_intake_timeout_sec` is deliberately smaller than `chat_timeout_sec` — most of the
"understanding" work already happened in the worker-side pre-fetch before the brain even
starts, so the brain's own turn just needs to call `save-recipe`/`capture-inbox`, or at
most one `WebFetch`. Keeping it at 300s leaves headroom under `stale_after_sec` (600s) even
after the pre-fetch's own up-to-~160s worst case.)

- [ ] **Step 6: Wire `main.py`**

The `gemini_intake` import was already added in Step 2. Add after `generate_ritual_reply`:

```python
def generate_recipe_intake_reply(conn, job: db.Job, cfg: dict) -> str:
    """Recipe intake: a worker-side, deterministic Gemini pre-fetch (ported
    from alfred's listener.py) runs before the brain is invoked at all — the
    brain never calls the video pipeline itself, only sees rendered text."""
    url = job.payload["url"]
    by = job.payload.get("by", "someone")
    prefetch = gemini_intake.fetch_recipe_context(url)
    ctx = context.fetch_recipe_intake_context(conn, job.household_id)
    template = (ROOT / "prompts" / "recipe_intake.md").read_text()
    prompt = context.build_recipe_intake_prompt(template, ctx, url, by, prefetch)
    return brain.run_brain(prompt, model=cfg["chat_model"],
                           timeout=cfg["recipe_intake_timeout_sec"],
                           allowed_tools=cfg["recipe_intake_allowed_tools"],
                           cwd=str(ROOT),
                           extra_env={"SOUS_HOUSEHOLD_ID": job.household_id})
```

Replace `process_one` with:

```python
def process_one(conn, cfg: dict) -> bool:
    for job_id in db.requeue_stale(conn, cfg["stale_after_sec"], cfg["max_attempts"]):
        hid = db.get_job_household(conn, job_id)
        _apologize(conn, hid, job_id)

    job = db.claim_next_job(conn)
    if job is None:
        return False
    try:
        if job.kind in ("chat", "ritual"):
            mode = ("ritual" if job.kind == "ritual"
                    or db.get_proposing_week(conn, job.household_id) else "chat")
            reply = (generate_ritual_reply(conn, job, cfg) if mode == "ritual"
                     else generate_chat_reply(conn, job, cfg))
        elif job.kind == "recipe_intake":
            mode = "recipe_intake"
            reply = generate_recipe_intake_reply(conn, job, cfg)
        else:
            raise ValueError(f"unknown job kind: {job.kind}")
        with conn.transaction():
            db.insert_chef_message(conn, job.household_id, reply, job.id)
            db.complete_job(conn, job.id, {"reply_chars": len(reply), "mode": mode})
    except Exception as exc:  # noqa: BLE001 — worker must never die on one job
        log.exception("job %s failed (attempt %d)", job.id, job.attempts)
        if job.attempts >= cfg["max_attempts"]:
            db.fail_job(conn, job.id, str(exc))
            _apologize(conn, job.household_id, job.id)
        else:
            db.requeue_job(conn, job.id)
    return True
```

- [ ] **Step 7: Run tests to verify they pass**

Run: `cd worker && uv run pytest tests/test_main.py -v`
Expected: PASS (all tests, including the fixed placeholder test and the new recipe_intake
test)

- [ ] **Step 8: Run the full test suite**

Run: `cd worker && uv run pytest -v` (smoke tests auto-skip without `SOUS_SMOKE=1`)
Expected: PASS, no regressions across the whole suite

- [ ] **Step 9: Commit**

```bash
git add worker/sous_worker/main.py worker/config.json worker/tests/test_main.py
git commit -m "feat(worker): wire recipe_intake job kind into process_one"
```

---

### Task 5: Gemini dependency, credentials, and the real-pipeline smoke test

**Files:**
- Modify: `worker/pyproject.toml`
- Modify: `worker/.env` (gitignored — not committed)
- Create: `worker/tests/test_smoke_recipe_intake.py`

**Interfaces:**
- Consumes: the full pipeline from Tasks 1–4.
- Produces: nothing new for other tasks — this is the end-to-end verification.

- [ ] **Step 1: Add the `google-genai` dependency**

In `worker/pyproject.toml`, change:

```toml
dependencies = [
    "psycopg[binary]>=3.2",
    "python-dotenv>=1.0",
]
```

to:

```toml
dependencies = [
    "psycopg[binary]>=3.2",
    "python-dotenv>=1.0",
    "google-genai>=1.0",
]
```

Run: `cd worker && uv sync`
Expected: `google-genai` installs cleanly into `worker/.venv`

- [ ] **Step 2: Add `GEMINI_API_KEY` to `worker/.env`**

Reuse alfred's existing key (per the 2026-07-20 scope decision — it's a credential, not
shared state, so this doesn't violate alfred/sous isolation). Run this command as-is; it
extracts and appends the value without printing it to the terminal or this conversation:

```bash
echo "GEMINI_API_KEY=$(grep '^GEMINI_API_KEY=' ~/Projects/alfred/.env | cut -d= -f2-)" >> ~/Projects/sous/worker/.env
```

Verify (without printing the value) that the line landed:

```bash
grep -c '^GEMINI_API_KEY=' ~/Projects/sous/worker/.env
```

Expected: `1`

- [ ] **Step 3: Write the gated real-pipeline smoke test**

Create `worker/tests/test_smoke_recipe_intake.py`:

```python
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
```

- [ ] **Step 4: Fill in a real recipe URL**

Before running, replace `RECIPE_URL` with a real, currently-live Instagram reel or
YouTube video of an actual recipe (pick one together with Mike, or use any known-good
recipe video). This can't be scripted — it needs a real, currently-live URL.

- [ ] **Step 5: Run the smoke test for real**

Run: `cd worker && SOUS_SMOKE=1 uv run pytest tests/test_smoke_recipe_intake.py -v -s`
Expected: PASS. Note the wall-clock time in the commit message (mirrors
`test_smoke_ritual.py`'s convention of recording real timing, e.g. "~90s").

- [ ] **Step 6: Commit**

```bash
git add worker/pyproject.toml worker/uv.lock worker/tests/test_smoke_recipe_intake.py
git commit -m "feat(worker): google-genai dependency + gated recipe-intake smoke test"
```

(`worker/.env` is gitignored — nothing to add there.)

---

## Out of scope for M2c1 (tracked for later)

- **`jobs_write` RLS policy** currently only allows `kind = 'chat'` (migration `0002_rls.sql`)
  — the same gap `0005_jobs_allow_ritual_kind.sql` fixed for ritual. M2c1 never inserts jobs
  through the RLS-bound anon path (tests/smoke test use the service-role connection
  directly), so this doesn't block M2c1, but **M2c2's share extension will hit the exact
  same silent-rejection bug that M2b2 hit** unless a migration adding `recipe_intake` to
  that policy ships as part of M2c2's plan. Flagging now so it isn't rediscovered the hard
  way again.
- Everything under M2c2 (share extension, cookbook UI, cook mode) — separate plan, written
  after M2c1 is merged and cloud-verified, matching the M2a → M2b1 → M2b2 precedent.

---

## M2c1 cloud exit verification (2026-07-21, real polling daemon against cloud sandbox household)

Unlike the earlier local smoke test (which called `main.process_one()` in-process) and
the standalone script run (which called `gemini_intake`/`save-recipe` directly), this
check ran the actual `sous_worker.main` daemon as its own background process, polling
the real cloud `jobs` table every 3s, matching how the app uses it in production.

Cloud deploy: no migration was pending for M2c1 (recipes/jobs schema already present
from `0001_schema.sql`; M2c1 added no migration file). `worker/.env` was missing
`GEMINI_API_KEY` (only `SOUS_DB_URL` was present) — copied from `~/Projects/alfred/.env`
(same key alfred already uses). `SOUS_DB_URL` confirmed pointed at the cloud Session
Pooler (`aws-0-ap-northeast-1.pooler.supabase.com:5432`); connection verified before
starting the daemon.

Driven via direct job insertion against the cloud sandbox household
(`00000000-0000-0000-0000-000000000001`), bypassing RLS the same way M2b1's Task 10 did
(no client exists yet to exercise the RLS-bound path — that's `jobs_write`'s tracked
`recipe_intake` gap above, deferred to M2c2). Recipe URL: YouTube Shorts
`https://www.youtube.com/watch?v=NbmT_9oH1SY` (紅燒牛肉麵), the same one verified working
for Gemini video-understanding in the prior local session.

**Result: PASS.** Job went `queued` → `running` → `done` in ~2m15s (19:35:08 →
19:37:23 local), `result: {"mode": "recipe_intake", "reply_chars": 64}`. Verified
against live cloud DB:
- `recipes`: 紅燒牛肉麵, 9 steps (each with a `text` key, several with `tip`), 13
  ingredients (each with `name`/`qty`), non-null `source_block` (157 chars, verbatim
  capture). Row was an upsert onto the same slug as the prior standalone run
  (`created_at` unchanged, no `updated_at` column exists) — expected behavior of
  `save-recipe`'s upsert-by-slug design, not stale data.
- `inbox_items`: fresh `kind='craving'` row ("想做紅燒牛肉麵"), timestamped inside the job's
  run window — confirms `capture-inbox` was called this run, not left over.
- `chat_messages`: fresh chef announcement ("紅燒牛肉麵補完整了!牛肉擦乾大火煎上色、同鍋爆香辛香料、紅蘿蔔抓最後15分鐘下鍋——這鍋一小時燉出的湯頭,已經排進下週候選了 🔥"),
  timestamped inside the run window, in-persona (小當家 tone, 🔥), no hardcoded persona
  name — the brain's own final turn after `save-recipe`+`capture-inbox` *is* the
  announcement, as designed (no separate `post-card` verb needed).

No test-data cleanup — this is real cookbook content for the sandbox household now,
useful for M2c2's iOS work. Worker daemon left running against cloud afterward (needed
for chat/ritual regardless of this check).

M2c1 is now fully closed: implementation done, merged, and cloud-verified through the
real production code path (not just tests/scripts). M2c2 (share-sheet intake, cookbook
UI, cook mode) can proceed.
