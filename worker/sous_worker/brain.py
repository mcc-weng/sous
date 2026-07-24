"""Wraps headless `claude -p` (Claude subscription, no API key).

Prompt is piped via STDIN — `--allowedTools` is variadic and would swallow a
trailing prompt argument (alfred spike, 2026-06-07). Write verbs arrive via
the state_api Bash allowlist entry in `allowed_tools`, not a hardcoded tool.

`--safe-mode` disables globally-installed plugin/hook customizations for this
call only (auth, model selection, and built-in tools are unaffected) — without
it, a machine-wide plugin hook unconditionally blocks the WebFetch tool for
every headless `claude -p` invocation, breaking recipe_intake's documented
WebFetch fallback. See project memory `worker-worktree-network-fetch-blocked`.
"""
import os
import subprocess
from collections.abc import Sequence

_CLAUDE_DEFAULT = "/Users/mikeweng/.local/bin/claude"


def _claude_bin() -> str:
    return os.environ.get("CLAUDE_BIN", _CLAUDE_DEFAULT)


def run_brain(prompt: str, model: str = "sonnet", timeout: int = 480,
              allowed_tools: Sequence[str] = ("Read",), cwd: str | None = None,
              extra_env: dict | None = None) -> str:
    env = None if extra_env is None else {**os.environ, **extra_env}
    try:
        result = subprocess.run(
            [_claude_bin(), "-p", "--model", model, "--safe-mode",
             "--allowedTools", *allowed_tools],
            input=prompt.encode(),
            capture_output=True,
            timeout=timeout,
            cwd=cwd,
            env=env,
        )
    except subprocess.TimeoutExpired:
        raise RuntimeError(f"brain timed out after {timeout}s") from None
    if result.returncode != 0:
        raise RuntimeError(
            f"brain exited {result.returncode}: {result.stderr.decode()[:500]}"
        )
    return result.stdout.decode().strip()
