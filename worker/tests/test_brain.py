import os
import stat

import pytest

from sous_worker import brain


@pytest.fixture
def fake_claude(tmp_path, monkeypatch):
    """A stand-in claude binary that echoes a marker + first line of stdin."""
    script = tmp_path / "claude"
    script.write_text('#!/bin/sh\nread line\necho "FAKE-REPLY: $line"\n')
    script.chmod(script.stat().st_mode | stat.S_IEXEC)
    monkeypatch.setenv("CLAUDE_BIN", str(script))
    return script


def test_run_brain_returns_stdout(fake_claude):
    assert brain.run_brain("你好") == "FAKE-REPLY: 你好"


def test_run_brain_timeout_raises(tmp_path, monkeypatch):
    script = tmp_path / "claude"
    script.write_text("#!/bin/sh\nsleep 5\n")
    script.chmod(script.stat().st_mode | stat.S_IEXEC)
    monkeypatch.setenv("CLAUDE_BIN", str(script))
    with pytest.raises(RuntimeError, match="timed out"):
        brain.run_brain("hi", timeout=1)


def test_run_brain_nonzero_exit_raises(tmp_path, monkeypatch):
    script = tmp_path / "claude"
    script.write_text("#!/bin/sh\necho boom >&2\nexit 3\n")
    script.chmod(script.stat().st_mode | stat.S_IEXEC)
    monkeypatch.setenv("CLAUDE_BIN", str(script))
    with pytest.raises(RuntimeError, match="exited 3"):
        brain.run_brain("hi")


def test_run_brain_passes_tools_env_and_cwd(tmp_path, monkeypatch):
    script = tmp_path / "claude"
    script.write_text('#!/bin/sh\necho "ARGS=$* HID=$SOUS_HOUSEHOLD_ID PWD=$(pwd -P)"\n')
    script.chmod(0o755)
    monkeypatch.setenv("CLAUDE_BIN", str(script))
    out = brain.run_brain(
        "hi", allowed_tools=["Read", "Bash(.venv/bin/python state_api.py:*)"],
        cwd=str(tmp_path), extra_env={"SOUS_HOUSEHOLD_ID": "h-1"},
    )
    assert "Bash(.venv/bin/python state_api.py:*)" in out
    assert "HID=h-1" in out
    assert f"PWD={tmp_path.resolve()}" in out


def test_run_brain_passes_safe_mode(fake_claude):
    """--safe-mode disables global plugin/hook customizations (e.g. context-mode's
    unconditional WebFetch block) for the brain's headless call, without touching
    OAuth/keychain subscription auth — see worker-worktree-network-fetch-blocked
    project memory. Must not regress silently if the flag is ever dropped."""
    script = fake_claude
    script.write_text('#!/bin/sh\necho "ARGS=$*"\n')
    script.chmod(script.stat().st_mode | 0o111)
    out = brain.run_brain("hi")
    assert "--safe-mode" in out
