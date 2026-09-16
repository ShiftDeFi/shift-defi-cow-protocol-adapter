#!/usr/bin/env python3
"""The Solidity half of the turn baseline: what this turn did to the contracts.

wall_stop.py runs `make verify` when Solidity changed. Which Solidity is the
whole question. Asking the working tree — `git status -- '*.sol'` — is true for
the entire life of a branch carrying contract work, so the gate ran on every
turn of that branch, including turns that only read a file or edited a
document. What is wanted is the question wall_protected.py already asks of the
gate's own files: what changed during this turn.

So this mirrors that module. wall_turn_start.py records a baseline when the
turn opens and wall_stop.py compares against it. The record lives in .git/,
which is per-clone and never committed.

The comparison is over file contents, not the mtime and size wall_post_edit.py
compares. That hook runs after every tool call and wants the cheapest possible
answer to "did anything move"; this one runs once a turn and is deciding
whether to spend several minutes, so an edit that was reverted, or a formatter
that rewrote a file byte-identically, should not spend them.

A red gate outlives the turn that made it. `make verify` failing leaves RED
behind, and wall_stop.py runs the gate on every turn until it passes, whatever
that turn touched. Narrowing which turns run the gate must not widen which
turns may end on a red one.
"""

import hashlib
import pathlib
import subprocess

ROOT = pathlib.Path(__file__).resolve().parents[2]

# Per-clone, never committed, and alongside the other hooks' own state.
STATE = ROOT / ".git" / "wall-turn-sol-state.json"

# Written when `make verify` fails, removed when it passes.
RED = ROOT / ".git" / "wall-verify-red"


def sol_files() -> list[str]:
    """Every tracked or untracked .sol path. Submodules under lib/ are a
    gitlink to the superproject and ignored trees are excluded, so out/ and
    cache/ build artefacts do not appear."""
    proc = subprocess.run(
        ["git", "ls-files", "-co", "--exclude-standard", "--", "*.sol"],
        cwd=ROOT,
        capture_output=True,
        text=True,
    )
    return [line for line in proc.stdout.splitlines() if line]


def snapshot() -> dict[str, str]:
    """Each .sol path against the hash of its contents. A file that cannot be
    read is left out, so deleting one is a difference like any other."""
    out = {}
    for rel in sol_files():
        try:
            out[rel] = hashlib.sha256((ROOT / rel).read_bytes()).hexdigest()
        except OSError:
            continue
    return out


def changed(baseline: dict[str, str]) -> bool:
    return snapshot() != baseline
