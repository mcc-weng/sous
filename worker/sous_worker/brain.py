"""Wraps headless `claude -p` (Claude subscription, no API key).

Prompt is piped via STDIN — `--allowedTools` is variadic and would swallow a
trailing prompt argument (alfred spike, 2026-06-07). M1 brain is read-only:
allowed_tools defaults to "Read" only; state_api verbs arrive in M2.
"""
import os
import subprocess

_CLAUDE_DEFAULT = "/Users/mikeweng/.local/bin/claude"


def _claude_bin() -> str:
    return os.environ.get("CLAUDE_BIN", _CLAUDE_DEFAULT)


def run_brain(prompt: str, model: str = "sonnet", timeout: int = 480,
              allowed_tools: str = "Read") -> str:
    try:
        result = subprocess.run(
            [_claude_bin(), "-p", "--model", model, "--allowedTools", allowed_tools],
            input=prompt.encode(),
            capture_output=True,
            timeout=timeout,
        )
    except subprocess.TimeoutExpired:
        raise RuntimeError(f"brain timed out after {timeout}s") from None
    if result.returncode != 0:
        raise RuntimeError(
            f"brain exited {result.returncode}: {result.stderr.decode()[:500]}"
        )
    return result.stdout.decode().strip()
