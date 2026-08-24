#!/usr/bin/env python3
"""PostToolUse hook: format and compile after a Solidity edit.

Receives the tool-call context as JSON on stdin. Non-Solidity edits exit 0
immediately.

Formatting is applied rather than reported, so a formatting difference does not
cost a round trip. A compile failure exits 2, which returns stderr as feedback.
"""

import json
import pathlib
import shutil
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
MAX_OUTPUT_LINES = 80


def main() -> int:
    try:
        payload = json.load(sys.stdin)
    except (json.JSONDecodeError, ValueError):
        return 0

    tool_input = payload.get("tool_input") or {}
    tool_response = payload.get("tool_response") or {}
    path = tool_input.get("file_path") or tool_response.get("filePath") or ""

    if not path.endswith(".sol"):
        return 0

    if shutil.which("forge") is None:
        return 0

    subprocess.run(["forge", "fmt", path], cwd=ROOT, capture_output=True, text=True)

    build = subprocess.run(
        ["forge", "build"], cwd=ROOT, capture_output=True, text=True
    )
    if build.returncode != 0:
        out = (build.stdout + build.stderr).strip().splitlines()
        tail = "\n".join(out[-MAX_OUTPUT_LINES:])
        print(
            f"Wall: {pathlib.Path(path).name} does not compile.\n\n{tail}",
            file=sys.stderr,
        )
        return 2

    return 0


if __name__ == "__main__":
    sys.exit(main())
