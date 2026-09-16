#!/usr/bin/env python3
"""Exercise the agent hooks that protect the gate.

The hooks in .claude/hooks/ decide what an agent may write, so a regression in
them is silent: the gate keeps reporting green while it stops being enforced.
Nothing else in this repository checks them — `forge lint` is scoped to src/,
and the analysis lanes read Solidity.

What is covered is the part that makes a decision:

  wall_guard.py         which writes are refused, by path, by foundry.toml key,
                        and by settings subtree
  wall_turn_start.py    the baseline it records
  wall_stop.py          the comparison that catches a write through any route

wall_post_edit.py is not covered here. Its decision is trivial — did a .sol
file move — and the part worth testing is `forge fmt` and `forge build`, which
ordinary use exercises on every edit.

Each case runs the installed hook as a subprocess against a throwaway git
repository built at the layout the hooks expect, so what is tested is the file
on disk rather than an importable copy of it.

Run with `make test-hooks`. Deliberately outside `make verify`: the Stop hook
runs verify on every turn that touches Solidity, and this adds a couple of
seconds of subprocess work that has nothing to say about the contracts. CI runs
it as its own step.
"""

import json
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[2]
HOOKS = ROOT / ".claude" / "hooks"
REQUIRED_HOOKS = (
    "wall_protected.py",
    "wall_solidity.py",
    "wall_guard.py",
    "wall_turn_start.py",
    "wall_stop.py",
)

REQUIRED_TOOLS = ("forge", "slither", "aderyn", "make", "python3")

BLOCK, ALLOW = 2, 0

SETTINGS = """{
  "permissions": {
    "deny": ["Read(./.env)"]
  },
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Write|Edit",
        "hooks": [{"type": "command", "command": "python3 .claude/hooks/wall_guard.py"}]
      }
    ],
    "Stop": [
      {
        "hooks": [{"type": "command", "command": "python3 .claude/hooks/wall_stop.py"}]
      }
    ]
  }
}
"""

SETTINGS_LOCAL = """{
  "permissions": {
    "allow": ["Bash(make verify)"]
  }
}
"""

# A minimal tree carrying one of everything the hooks reason about. src/A.sol is
# committed, so a turn that leaves it alone asks for no gate run; the verify
# target records that it was invoked rather than doing any work, which is what
# gate_run() reads.
FIXTURE = {
    "aderyn.triage": "reentrancy-state-change|src/A.sol|30\n",
    "slither.db.json": "{}\n",
    "wall/slither.config.json": "{}\n",
    "wall/wall.mk": "verify:\n\t@touch .git/verify-ran\n",
    "Makefile": "include wall/wall.mk\n",
    "wall/script/gate_aderyn.py": "# gate\n",
    "wall/script/gate_tests.py": "# gate\n",
    ".claude/settings.json": SETTINGS,
    ".claude/settings.local.json": SETTINGS_LOCAL,
    ".githooks/pre-commit": "#!/bin/sh\n",
    ".github/workflows/wall.yml": "name: CI\n",
    "src/A.sol": "contract A {}\n",
    "CLAUDE.md": "# docs\n",
    "foundry.toml": (
        "[profile.default]\n"
        'solc_version = "0.8.28"\n'
        "[lint]\n"
        'exclude_lints = ["asm-keccak256"]\n'
        "[profile.default.fuzz]\n"
        "runs = 256\n"
    ),
}

results: list[tuple[str, object, object, bool]] = []


def check(name, expected, got):
    ok = expected == got
    results.append((name, expected, got, ok))
    print(f"  {'ok  ' if ok else 'FAIL'} {name}")


# WALL_GUARD=0 is how a human works on the wall, and working on the wall is
# exactly when these checks need to run. Inherited into a spawned hook it would
# reach wall_guard.py, which would lift itself and allow every refusal case, so
# the whole suite fails in the one session that most needs it. The caller that
# is testing the lift passes its own env.
CLEAN_ENV = {k: v for k, v in os.environ.items() if k != "WALL_GUARD"}


def hook(root, script, payload, env=None):
    proc = subprocess.run(
        [sys.executable, str(root / ".claude" / "hooks" / script)],
        input=json.dumps(payload),
        capture_output=True,
        text=True,
        cwd=root,
        env=CLEAN_ENV if env is None else env,
    )
    return proc.returncode, (proc.stdout + proc.stderr)


def install(root):
    for name in REQUIRED_HOOKS:
        shutil.copy(HOOKS / name, root / ".claude" / "hooks" / name)


def build(tmp):
    root = pathlib.Path(tmp) / "repo"
    for rel, body in FIXTURE.items():
        path = root / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(body)
    (root / ".claude" / "hooks").mkdir(parents=True, exist_ok=True)
    install(root)
    subprocess.run(["git", "init", "-q"], cwd=root, capture_output=True)
    subprocess.run(["git", "add", "-A"], cwd=root, capture_output=True)
    subprocess.run(
        ["git", "-c", "user.email=wall@example.invalid", "-c", "user.name=wall",
         "commit", "-qm", "fixture"],
        cwd=root,
        capture_output=True,
    )
    return root


def edit(**kwargs):
    return {"tool_name": "Edit", "tool_input": kwargs}


def write(**kwargs):
    return {"tool_name": "Write", "tool_input": kwargs}


def restore(root):
    subprocess.run(["git", "checkout", "-q", "--", "."], cwd=root, capture_output=True)
    (root / ".claude" / "hooks" / "sneak.py").unlink(missing_ok=True)
    install(root)


def guard_paths(root):
    print("wall_guard.py — fully protected paths")
    for rel in (
        "aderyn.triage",
        "slither.db.json",
        "wall/slither.config.json",
        "wall/wall.mk",
        "Makefile",
        "wall/script/gate_aderyn.py",
        ".claude/hooks/wall_guard.py",
        ".githooks/pre-commit",
        ".github/workflows/wall.yml",
    ):
        rc, _ = hook(root, "wall_guard.py", edit(file_path=rel))
        check(f"refuses {rel}", BLOCK, rc)

    rc, _ = hook(root, "wall_guard.py",
                 edit(file_path="/elsewhere/repo/.claude/hooks/wall_stop.py"))
    check("refuses a hook addressed from outside the tree", BLOCK, rc)

    for rel in ("src/A.sol", "CLAUDE.md", "test/A.t.sol", "README.md"):
        rc, _ = hook(root, "wall_guard.py", edit(file_path=rel))
        check(f"allows {rel}", ALLOW, rc)


def guard_foundry(root):
    print("\nwall_guard.py — foundry.toml, by key")
    for setting in ("exclude_lints", "deny_warnings", "solc_version", "fail_on_revert"):
        rc, _ = hook(root, "wall_guard.py",
                     edit(file_path="foundry.toml", new_string=f"{setting} = 0"))
        check(f"refuses {setting}", BLOCK, rc)
    rc, _ = hook(root, "wall_guard.py",
                 edit(file_path="foundry.toml", new_string="runs = 512"))
    check("allows an ordinary setting", ALLOW, rc)


def guard_settings(root):
    print("\nwall_guard.py — agent settings, by subtree")
    rc, _ = hook(root, "wall_guard.py", edit(
        file_path=".claude/settings.local.json",
        old_string='"allow": ["Bash(make verify)"]',
        new_string='"allow": ["Bash(make verify)", "Bash(make verify:*)"]'))
    check("allows adding a permission", ALLOW, rc)

    rc, _ = hook(root, "wall_guard.py", edit(
        file_path=".claude/settings.json",
        old_string='"deny": ["Read(./.env)"]',
        new_string='"deny": ["Read(./.env)", "Read(./.env.*)"]'))
    check("allows widening a deny rule", ALLOW, rc)

    rc, _ = hook(root, "wall_guard.py", write(
        file_path=".claude/settings.local.json",
        content='{"permissions": {"allow": ["Bash(make test)"]}}'))
    check("allows a permissions-only rewrite", ALLOW, rc)

    # The nested case a text match cannot see: neither string says "hooks",
    # and the edit disables the guard completely.
    rc, out = hook(root, "wall_guard.py", edit(
        file_path=".claude/settings.json",
        old_string='"matcher": "Write|Edit"',
        new_string='"matcher": "NeverMatchesAnything"'))
    check("refuses defanging a matcher", BLOCK, rc)
    check("names the reason", True, "hooks or env" in out)

    rc, _ = hook(root, "wall_guard.py", edit(
        file_path=".claude/settings.json",
        old_string='"command": "python3 .claude/hooks/wall_stop.py"',
        new_string='"command": "true"'))
    check("refuses repointing a hook command", BLOCK, rc)

    rc, _ = hook(root, "wall_guard.py", write(
        file_path=".claude/settings.json",
        content='{"permissions": {}, "hooks": {}}'))
    check("refuses dropping the hooks block", BLOCK, rc)

    rc, _ = hook(root, "wall_guard.py", write(
        file_path=".claude/settings.local.json",
        content='{"env": {"WALL_GUARD": "0"}}'))
    check("refuses lifting the guard through env", BLOCK, rc)

    rc, _ = hook(root, "wall_guard.py", edit(
        file_path=".claude/settings.json",
        old_string='"permissions"', new_string='"permissions'))
    check("refuses an edit that breaks the JSON", BLOCK, rc)

    rc, _ = hook(root, "wall_guard.py", edit(
        file_path=".claude/settings.json",
        old_string="text that is not in the file", new_string="x"))
    check("refuses an edit it cannot resolve", BLOCK, rc)


def guard_scope(root):
    print("\nwall_guard.py — out of scope")
    # Shell text is not read: these are the Stop hook's problem, and matching
    # them here refused documentation about the gate. See wall_protected.py.
    for command in (
        "echo k >> aderyn.triage",
        "git commit --no-verify -m x",
        'echo "guard patch installed? $(cmp -s .claude/hooks/wall_guard.py x)"',
        "python3 -c \"import json; json.load(open('.claude/settings.json'))\"",
    ):
        rc, _ = hook(root, "wall_guard.py",
                     {"tool_name": "Bash", "tool_input": {"command": command}})
        check(f"defers to the Stop check: {command[:34]}", ALLOW, rc)

    rc, _ = hook(root, "wall_guard.py", edit(file_path="aderyn.triage"),
                 env=dict(os.environ, WALL_GUARD="0"))
    check("WALL_GUARD=0 lifts it", ALLOW, rc)


def turn_check(root):
    print("\nturn check — a clean turn")
    hook(root, "wall_turn_start.py", {})
    rc, _ = hook(root, "wall_stop.py", {})
    check("an unchanged gate passes", ALLOW, rc)

    print("\nturn check — a write through any route is caught")
    for name, mutate in (
        ("a shell append to aderyn.triage",
         lambda: (root / "aderyn.triage").write_text("extra|src/A.sol|9\n")),
        ("a lint rule dropped from foundry.toml",
         lambda: (root / "foundry.toml").write_text(
             (root / "foundry.toml").read_text().replace(
                 'exclude_lints = ["asm-keccak256"]', "exclude_lints = []"))),
        ("a gate script rewritten",
         lambda: (root / "wall" / "script" / "gate_aderyn.py").write_text("exit(0)\n")),
        ("a hook deleted",
         lambda: (root / ".claude" / "hooks" / "wall_guard.py").unlink()),
        ("a hook added",
         lambda: (root / ".claude" / "hooks" / "sneak.py").write_text("# x\n")),
        ("slither.db.json removed",
         lambda: (root / "slither.db.json").unlink()),
        ("a matcher defanged in settings.json",
         lambda: (root / ".claude" / "settings.json").write_text(
             SETTINGS.replace('"Write|Edit"', '"NeverMatchesAnything"'))),
        ("WALL_GUARD=0 added to settings.local.json",
         lambda: (root / ".claude" / "settings.local.json").write_text(
             '{"env": {"WALL_GUARD": "0"}}\n')),
    ):
        hook(root, "wall_turn_start.py", {})
        mutate()
        rc, _ = hook(root, "wall_stop.py", {})
        check(f"caught: {name}", BLOCK, rc)
        restore(root)

    print("\nturn check — ordinary work is not caught")
    for name, mutate in (
        ("an ordinary foundry.toml edit",
         lambda: (root / "foundry.toml").write_text(
             (root / "foundry.toml").read_text().replace("runs = 256", "runs = 512"))),
        ("a permission added to settings.json",
         lambda: (root / ".claude" / "settings.json").write_text(
             SETTINGS.replace('"deny": ["Read(./.env)"]',
                              '"deny": ["Read(./.env)", "Read(./.env.*)"]'))),
        ("settings.json reformatted, hooks unchanged",
         lambda: (root / ".claude" / "settings.json").write_text(
             json.dumps(json.loads(SETTINGS), indent=4))),
    ):
        hook(root, "wall_turn_start.py", {})
        mutate()
        rc, _ = hook(root, "wall_stop.py", {})
        check(name, ALLOW, rc)
        restore(root)

    print("\nturn check — the session is never trapped")
    # Gate work already uncommitted when the turn opened is the normal state
    # while the gate itself is being changed, and must not fail every turn.
    (root / "aderyn.triage").write_text("in-progress|src/A.sol|1\n")
    hook(root, "wall_turn_start.py", {})
    rc, _ = hook(root, "wall_stop.py", {})
    check("gate work already dirty at turn start", ALLOW, rc)
    restore(root)

    hook(root, "wall_turn_start.py", {})
    (root / "aderyn.triage").write_text("changed|src/A.sol|1\n")
    rc, _ = hook(root, "wall_stop.py", {"stop_hook_active": True})
    check("stop_hook_active does not block twice", ALLOW, rc)
    restore(root)

    state = root / ".git" / "wall-protected-state.json"
    state.unlink(missing_ok=True)
    rc, _ = hook(root, "wall_stop.py", {})
    check("no baseline establishes one and passes", ALLOW, rc)
    check("the baseline is written", True, state.exists())

    baseline = json.loads(state.read_text())
    baseline.pop("agent", None)
    state.write_text(json.dumps(baseline))
    (root / ".claude" / "settings.json").write_text(
        SETTINGS.replace('"Write|Edit"', '"Never"'))
    rc, _ = hook(root, "wall_stop.py", {})
    check("a baseline predating a dimension is not compared", ALLOW, rc)
    restore(root)


def gate_run(root):
    """Which turns run `make verify`.

    The question here is not whether the gate passes but whether it was asked,
    so these read the marker the fixture's verify target leaves behind. The
    hook skips the run outright when the toolchain is absent, which would look
    the same as not asking, so the whole section is skipped with it.
    """
    print("\ngate run — only turns with something to check")
    absent = [tool for tool in REQUIRED_TOOLS if shutil.which(tool) is None]
    if absent:
        print(f"  skipped — not installed: {', '.join(absent)}")
        return

    ran = root / ".git" / "verify-ran"
    red = root / ".git" / "wall-verify-red"
    sol_state = root / ".git" / "wall-turn-sol-state.json"
    sol = root / "src" / "A.sol"
    red.unlink(missing_ok=True)

    def run_stop():
        ran.unlink(missing_ok=True)
        return hook(root, "wall_stop.py", {})[0], ran.exists()

    # A branch carrying contract work differs from HEAD for its whole life, so
    # the working tree cannot answer what this turn did.
    sol.write_text("contract A { uint256 x; }\n")
    hook(root, "wall_turn_start.py", {})
    rc, invoked = run_stop()
    check("a dirty .sol left alone this turn passes", ALLOW, rc)
    check("and does not run the gate", False, invoked)

    hook(root, "wall_turn_start.py", {})
    sol.write_text("contract A { uint256 y; }\n")
    rc, invoked = run_stop()
    check("a .sol changed this turn passes", ALLOW, rc)
    check("and runs the gate", True, invoked)

    # A red gate outlives the turn that made it: narrowing which turns run the
    # gate must not widen which turns may end on a red one.
    restore(root)
    hook(root, "wall_turn_start.py", {})
    red.touch()
    rc, invoked = run_stop()
    check("a red gate runs on a turn that touched no Solidity", ALLOW, rc)
    check("and clears the marker once it passes", False, red.exists())
    check("having run the gate to find out", True, invoked)

    # No baseline is a fresh clone or a resumed session; the working tree is
    # the conservative answer, and the tree here is clean.
    sol_state.unlink(missing_ok=True)
    rc, invoked = run_stop()
    check("no baseline over a clean tree passes", ALLOW, rc)
    check("and does not run the gate either", False, invoked)
    restore(root)


def main() -> int:
    missing = [name for name in REQUIRED_HOOKS if not (HOOKS / name).is_file()]
    if missing:
        print(f"wall: hooks not installed: {', '.join(missing)}", file=sys.stderr)
        print(f"      expected under {HOOKS}", file=sys.stderr)
        return 1

    with tempfile.TemporaryDirectory() as tmp:
        root = build(tmp)
        guard_paths(root)
        guard_foundry(root)
        guard_settings(root)
        guard_scope(root)
        turn_check(root)
        gate_run(root)

    print()
    failed = [row for row in results if not row[3]]
    if failed:
        print(f"WALL: {len(failed)} hook check(s) failed:")
        for name, expected, got, _ in failed:
            print(f"  - {name}: expected {expected}, got {got}")
        return 1
    print(f"hooks: all {len(results)} checks pass")
    return 0


if __name__ == "__main__":
    sys.exit(main())
