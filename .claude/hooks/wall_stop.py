#!/usr/bin/env python3
"""Stop hook: run `make verify` before a turn that changed Solidity can end.

Exits 0 without running anything when no .sol file differs from the working
tree, so turns that touched no contracts are unaffected.

A failing gate exits 2 and returns the failing output, which prevents the turn
from ending while the wall is red.

Two cases exit 0 with a notice instead of blocking:

  - Missing toolchain. `make verify` needs slither and aderyn; blocking every
    turn on an uninstalled binary would only lead to hooks being switched off.
    CI still enforces the gate.
  - stop_hook_active, set when the turn is resuming from a previous block by
    this hook. The gate runs once per turn so an unfixable failure does not
    trap the session; run `make verify` directly to see what remains.
"""

import json
import pathlib
import shutil
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
MAX_OUTPUT_LINES = 120
REQUIRED = ("forge", "slither", "aderyn", "make", "python3")


def solidity_changed() -> bool:
    proc = subprocess.run(
        ["git", "status", "--porcelain", "--", "*.sol"],
        cwd=ROOT,
        capture_output=True,
        text=True,
    )
    return bool(proc.stdout.strip())


def main() -> int:
    try:
        payload = json.load(sys.stdin)
    except (json.JSONDecodeError, ValueError):
        payload = {}

    if payload.get("stop_hook_active"):
        return 0

    if not solidity_changed():
        return 0

    missing = [t for t in REQUIRED if shutil.which(t) is None]
    if missing:
        print(
            f"Wall: skipping `make verify` — not installed: {', '.join(missing)}. "
            "See the toolchain table in CLAUDE.md."
        )
        return 0

    verify = subprocess.run(
        ["make", "verify"], cwd=ROOT, capture_output=True, text=True
    )
    if verify.returncode != 0:
        out = (verify.stdout + verify.stderr).strip().splitlines()
        tail = "\n".join(out[-MAX_OUTPUT_LINES:])
        print(
            "Wall: `make verify` is red and Solidity changed in this turn. Fix "
            "the failing lane below, or state plainly that it is unresolved.\n\n"
            + tail,
            file=sys.stderr,
        )
        return 2

    return 0


if __name__ == "__main__":
    sys.exit(main())
