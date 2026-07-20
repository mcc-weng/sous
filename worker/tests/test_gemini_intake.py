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


def test_fetch_caption_handles_missing_yt_dlp_binary(monkeypatch):
    import subprocess

    def fake_run(*a, **kw):
        raise FileNotFoundError(2, "No such file or directory", "yt-dlp")

    monkeypatch.setattr(subprocess, "run", fake_run)
    out = gemini_intake._fetch_caption("https://youtu.be/abc123")
    assert "error" in out
    assert isinstance(out, dict)
