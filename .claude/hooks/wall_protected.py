#!/usr/bin/env python3
"""The files that define the gate, shared by the hooks that protect them.

A lane can be made green by editing one of these instead of the code: a finding
accepted into aderyn.triage or slither.db.json, a rule dropped from [lint]
exclude_lints, a threshold loosened in wall.mk, a hook switched off in
.claude/settings.json. None of those are code fixes, and none of them are
visible in a green run.

Two hooks share this list, and they check it in different ways.

wall_guard.py refuses Write and Edit against it. That check is exact, because
the tool call names the file it is about to write.

Shell routes are deliberately not pattern-matched. Matching regexes against
command text was tried and is the wrong instrument: it blocked commands that
merely quoted a protected path — documentation about the gate, a `cmp` of two
files, an `echo` containing the word "patch" — while still missing a write
buried in a heredoc body, which is where a script's real work lives. It guesses
what a command will do from how it reads. So instead wall_turn_start.py records
a hash per file when the turn begins and wall_stop.py compares them when it
ends: a write is caught by its effect, whatever route it took, and a command
that only mentions a path is not a write.

foundry.toml is not hashed. It carries both routine settings and gate
thresholds, and editing the routine ones is ordinary work, so what is compared
is the subset of its lines that name a protected setting.
"""

import fnmatch
import hashlib
import pathlib

ROOT = pathlib.Path(__file__).resolve().parents[2]

# Per-clone, never committed, and alongside the post-edit hook's own snapshot.
STATE = ROOT / ".git" / "wall-protected-state.json"

# Reviewed state, gate definitions, and the hooks and CI that run them.
PROTECTED_PATHS = (
    "aderyn.triage",
    "slither.db.json",
    "slither.config.json",
    "wall.mk",
    "Makefile",
    "script/*.py",
    ".claude/settings.json",
    ".claude/settings.local.json",
    ".claude/hooks/*.py",
    ".githooks/*",
    ".github/workflows/*",
)

# Settings inside foundry.toml that decide what the gate rejects.
PROTECTED_SETTINGS = (
    "exclude_lints",
    "mixed_case_exceptions",
    "lint_on_build",
    "deny_warnings",
    "fail_on_revert",
    "solc_version",
    "auto_detect_remappings",
)

FOUNDRY_TOML = "foundry.toml"


def protected_path(raw: str) -> str | None:
    """The matched pattern if `raw` names a protected file, else None."""
    if not raw:
        return None
    path = pathlib.Path(raw)
    if not path.is_absolute():
        path = ROOT / path
    try:
        rel = path.resolve().relative_to(ROOT).as_posix()
    except ValueError:
        # Outside the repo. Agent settings live there too, so match the tail.
        for pattern in (
            ".claude/settings.json",
            ".claude/settings.local.json",
            ".claude/hooks/*.py",
        ):
            if fnmatch.fnmatch(path.as_posix(), f"*/{pattern}"):
                return pattern
        return None
    for pattern in PROTECTED_PATHS:
        if fnmatch.fnmatch(rel, pattern):
            return pattern
    return None


def digest(path: pathlib.Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def protected_files() -> dict[str, str]:
    """A hash per protected file that exists. A file appearing or disappearing
    is itself a change to the gate, so the key set matters as much as the
    values."""
    out: dict[str, str] = {}
    for pattern in PROTECTED_PATHS:
        for path in sorted(ROOT.glob(pattern)):
            if path.is_file():
                try:
                    out[path.relative_to(ROOT).as_posix()] = digest(path)
                except OSError:
                    continue
    return out


def settings_fingerprint() -> list[str]:
    """The lines of foundry.toml that name a protected setting. Editing fuzz
    runs or the output directory does not move this; relaxing the gate does."""
    path = ROOT / FOUNDRY_TOML
    try:
        lines = path.read_text().splitlines()
    except OSError:
        return []
    return [
        " ".join(line.split())
        for line in lines
        if any(setting in line for setting in PROTECTED_SETTINGS)
    ]


def snapshot() -> dict:
    return {"files": protected_files(), "settings": settings_fingerprint()}


def compare(baseline: dict) -> list[str]:
    """What changed since `baseline`, as human-readable path descriptions."""
    current_files = protected_files()
    baseline_files = baseline.get("files") or {}

    changed = []
    for rel, value in current_files.items():
        if rel not in baseline_files:
            changed.append(f"{rel} (added)")
        elif baseline_files[rel] != value:
            changed.append(rel)
    for rel in baseline_files:
        if rel not in current_files:
            changed.append(f"{rel} (removed)")
    if (baseline.get("settings") or []) != settings_fingerprint():
        changed.append(f"{FOUNDRY_TOML} (gate settings)")
    return sorted(changed)
