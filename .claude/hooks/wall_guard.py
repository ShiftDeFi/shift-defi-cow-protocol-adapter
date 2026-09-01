#!/usr/bin/env python3
"""PreToolUse hook: refuse to let the gate be edited instead of satisfied.

Accepting a finding, relaxing a threshold or disabling a hook is a human review
decision, and CLAUDE.md requires it to be proposed rather than made. This hook
declines the write and returns the reason, so the proposal happens.

The check is by path, against the list in wall_protected.py, plus a check of the
text a foundry.toml edit would write — that file holds routine settings next to
gate thresholds, so the keys matter rather than the path. Both are exact: a
Write or an Edit names the file it is about to change.

Shell routes are not checked here. See wall_protected.py for why matching
command text was the wrong instrument, and wall_stop.py for what replaced it: a
comparison of the gate's actual state across the turn, which catches a write
through any route and cannot be fooled by a command that merely quotes a path.

This is not a security boundary. WALL_GUARD=0 in the session environment lifts
it, and the person at the terminal can always edit the file directly. What it
removes is the quiet path — silencing a lane becomes a deliberate act with a
diff attached, and review of that diff is what enforces the gate.

Exits 2 to block the call and return stderr to the model, 0 to allow it.
"""

import json
import os
import pathlib
import sys

from wall_protected import FOUNDRY_TOML, PROTECTED_SETTINGS, protected_path

REFUSAL = (
    "Wall: {what}\n\n"
    "This file is the gate, not the code under test. Accepting a finding, "
    "relaxing a threshold or disabling a hook is a human review decision — "
    "CLAUDE.md requires it to be proposed, not made.\n\n"
    "Fix the code so the lane passes. If the finding is genuinely acceptable, "
    "explain why and what key or setting you would add, and let the human "
    "apply it.\n\n"
    "(A human can set WALL_GUARD=0 to lift this hook.)"
)


def touched_settings(tool_input: dict) -> list[str]:
    """Protected foundry.toml keys named in the text this call would write."""
    text = " ".join(
        str(tool_input.get(key) or "")
        for key in ("content", "old_string", "new_string")
    )
    return [setting for setting in PROTECTED_SETTINGS if setting in text]


def main() -> int:
    if os.environ.get("WALL_GUARD") == "0":
        return 0

    try:
        payload = json.load(sys.stdin)
    except (json.JSONDecodeError, ValueError):
        return 0

    tool = payload.get("tool_name") or ""
    if tool not in ("Write", "Edit", "MultiEdit", "NotebookEdit"):
        return 0

    tool_input = payload.get("tool_input") or {}
    path = str(tool_input.get("file_path") or "")

    pattern = protected_path(path)
    if pattern:
        print(REFUSAL.format(what=f"{pattern} is protected."), file=sys.stderr)
        return 2

    if pathlib.Path(path).name == FOUNDRY_TOML:
        keys = touched_settings(tool_input)
        if keys:
            print(
                REFUSAL.format(
                    what="this edit changes gate settings in "
                    f"{FOUNDRY_TOML}: {', '.join(keys)}."
                ),
                file=sys.stderr,
            )
            return 2

    return 0


if __name__ == "__main__":
    sys.exit(main())
