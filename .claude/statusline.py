#!/usr/bin/env python3
"""Status line: branch, pending gate work, model, context and quota usage.

Renders as:

    feat/adapter  Wall: OK  Opus 5  ctx 27% 274k/1.0M  5-hour usage 53%  7-day usage 17%

Claude Code invokes this on every render, so it does one `git` call and no
`make` or `forge` — running the gate here would cost seconds per keystroke.

The gate indicator is deliberately modest about what it knows. It reports
whether any .sol differs from HEAD, not whether `make verify` passed:

  Wall: OK       no Solidity differs from HEAD, so what is checked out was
                 gated by the pre-commit hook and by CI
  Wall: PENDING  Solidity has changed, so the Stop hook will run the gate when
                 the turn ends and has not yet

Context and quota come from the session payload on stdin. Field names are read
from `context_window` and `rate_limits`, and every one is optional: a payload
missing a key drops that element rather than failing, so a change to the
payload shape degrades the line instead of breaking it.

On first run the payload is written to .git/statusline-payload.json, which is
where these field names came from. Delete that file to capture it again after a
Claude Code upgrade.
"""

import json
import pathlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
PAYLOAD_DUMP = ROOT / ".git" / "statusline-payload.json"

RESET = "\033[0m"
DIM = "\033[38;5;245m"
LIGHT_GREEN = "\033[38;5;114m"
GREEN = "\033[38;5;71m"
AMBER = "\033[38;5;179m"
RED = "\033[38;5;167m"
BLUE = "\033[38;5;110m"

# Usage percentages above these turn amber, then red.
WARN, ALARM = 60, 85


def paint(percent: float, text: str) -> str:
    if percent >= ALARM:
        return f"{RED}{text}{RESET}"
    if percent >= WARN:
        return f"{AMBER}{text}{RESET}"
    return f"{LIGHT_GREEN}{text}{RESET}"


def tokens(count: float) -> str:
    if count >= 1_000_000:
        return f"{count / 1_000_000:.1f}M"
    return f"{count / 1000:.0f}k"


def git(*args: str) -> str:
    proc = subprocess.run(
        ["git", *args], cwd=ROOT, capture_output=True, text=True
    )
    return proc.stdout.strip()


def gate() -> str:
    if git("status", "--porcelain", "--", "*.sol"):
        return f"{AMBER}Wall: PENDING{RESET}"
    return f"{GREEN}Wall: OK{RESET}"


def context(payload: dict) -> str | None:
    window = payload.get("context_window")
    if not isinstance(window, dict):
        return None

    percent = window.get("used_percentage")
    if percent is None:
        remaining = window.get("remaining_percentage")
        percent = None if remaining is None else 100 - remaining
    if not isinstance(percent, (int, float)):
        return None

    used = window.get("total_input_tokens")
    size = window.get("context_window_size")
    if isinstance(used, (int, float)) and isinstance(size, (int, float)) and size:
        return paint(percent, f"ctx {percent:.0f}% {tokens(used)}/{tokens(size)}")
    return paint(percent, f"ctx {percent:.0f}%")


def quota(payload: dict) -> list[str]:
    limits = payload.get("rate_limits")
    if not isinstance(limits, dict):
        return []
    out = []
    for key, label in (("five_hour", "5-hour usage"), ("seven_day", "7-day usage")):
        window = limits.get(key)
        if not isinstance(window, dict):
            continue
        percent = window.get("used_percentage")
        if isinstance(percent, (int, float)):
            out.append(paint(percent, f"{label} {percent:.0f}%"))
    return out


def main() -> int:
    try:
        payload = json.load(sys.stdin)
    except (json.JSONDecodeError, ValueError):
        payload = {}

    if not PAYLOAD_DUMP.exists():
        try:
            PAYLOAD_DUMP.write_text(json.dumps(payload, indent=2, sort_keys=True))
        except OSError:
            pass

    parts = [f"{BLUE}{git('rev-parse', '--abbrev-ref', 'HEAD') or 'detached'}{RESET}"]
    parts.append(gate())

    model = (payload.get("model") or {}).get("display_name")
    if model:
        parts.append(f"{DIM}{model}{RESET}")

    used = context(payload)
    if used:
        parts.append(used)

    parts.extend(quota(payload))

    print("  ".join(parts))
    return 0


if __name__ == "__main__":
    sys.exit(main())
