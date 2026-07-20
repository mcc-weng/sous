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
    return {"source": "none", "error": caption.get("error") or gemini.get("error")}
