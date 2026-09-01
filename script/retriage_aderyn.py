#!/usr/bin/env python3
"""Re-anchor accepted aderyn keys that only moved.

`aderyn.triage` keys a finding as detector|path|line, so inserting a line above
a reviewed finding renumbers its key. The key stops matching, the gate fails,
and the fix is to retype a number — a mechanical edit that is indistinguishable
from accepting a finding, and so costs a human review step on almost every
commit that grows a file.

This re-anchors those keys, and only those. A stale accepted key is paired with
a current finding when the detector, the path, and the *source text* the key is
anchored to are all identical — the code did not change, its line number did.
Old text comes from HEAD, new text from the working tree.

What it will not do:

  - Add a key. A current finding with no stale counterpart is a new finding,
    and accepting one is a human review decision. It is reported and the exit
    status is non-zero.
  - Remove a key. A stale key that pairs with nothing may mean the finding was
    fixed, or that the anchored code changed and deserves re-reading. Both are
    review decisions, so it is reported and left in place.
  - Pair ambiguously. Where several findings share the same anchored text, a
    three-line window disambiguates; failing that, the group is left alone.

Comments, blank lines and entry order in aderyn.triage are preserved: only the
line numbers on re-anchored keys change.

Usage:
  python3 script/retriage_aderyn.py aderyn.out.json           # re-anchor
  python3 script/retriage_aderyn.py aderyn.out.json --check   # report only
"""

import json
import pathlib
import subprocess
import sys

from gate_aderyn import TRIAGE, instance_keys


def normalize(text: str) -> str:
    """Source text with whitespace collapsed, so a reflow is not a change."""
    return " ".join(text.split())


def head_lines(path: str) -> list[str] | None:
    proc = subprocess.run(
        ["git", "show", f"HEAD:{path}"], capture_output=True, text=True
    )
    if proc.returncode != 0:
        return None
    return proc.stdout.splitlines()


def worktree_lines(path: str) -> list[str] | None:
    try:
        return pathlib.Path(path).read_text().splitlines()
    except OSError:
        return None


def anchored(lines: list[str] | None, line_no: int) -> tuple[str, str] | None:
    """The normalized text at `line_no`, and a three-line window around it."""
    if lines is None or not (1 <= line_no <= len(lines)):
        return None
    i = line_no - 1
    window = lines[max(0, i - 1): i + 2]
    return normalize(lines[i]), normalize(" ".join(window))


def split_key(key: str) -> tuple[str, str, int] | None:
    parts = key.split("|")
    if len(parts) != 3 or not parts[2].isdigit():
        return None
    return parts[0], parts[1], int(parts[2])


def pair(stale: list[str], new: list[str]) -> dict[str, str]:
    """Map stale keys to the current keys anchored to the same source text."""
    remap: dict[str, str] = {}
    groups: dict[tuple[str, str], tuple[list[str], list[str]]] = {}
    for key in stale:
        parsed = split_key(key)
        if parsed:
            groups.setdefault(parsed[:2], ([], []))[0].append(key)
    for key in new:
        parsed = split_key(key)
        if parsed and parsed[:2] in groups:
            groups[parsed[:2]][1].append(key)

    for (_detector, path), (stale_keys, new_keys) in groups.items():
        old_src, new_src = head_lines(path), worktree_lines(path)
        stale_text = {}
        for key in stale_keys:
            text = anchored(old_src, split_key(key)[2])
            if text:
                stale_text[key] = text
        new_text = {}
        for key in new_keys:
            text = anchored(new_src, split_key(key)[2])
            if text:
                new_text[key] = text

        taken: set[str] = set()
        for key in sorted(stale_text, key=lambda k: split_key(k)[2]):
            line, window = stale_text[key]
            candidates = [
                c for c, (cl, _cw) in new_text.items()
                if c not in taken and cl == line
            ]
            if len(candidates) > 1:
                narrowed = [c for c in candidates if new_text[c][1] == window]
                if narrowed:
                    candidates = narrowed
            if len(candidates) == 1:
                remap[key] = candidates[0]
                taken.add(candidates[0])
    return remap


def main(argv: list[str]) -> int:
    report = json.loads(pathlib.Path(argv[1]).read_text())
    check_only = "--check" in argv

    current = instance_keys(report)
    raw = TRIAGE.read_text().splitlines() if TRIAGE.exists() else []
    accepted = [line.strip() for line in raw if line.strip() and not line.strip().startswith("#")]

    stale = [k for k in accepted if k not in current]
    new = [k for k in current if k not in accepted]
    remap = pair(stale, new)

    for old, fresh in sorted(remap.items()):
        print(f"  re-anchor    {old}  ->  {split_key(fresh)[2]}")
    for key in sorted(k for k in stale if k not in remap):
        print(f"  stale        {key}  (finding gone, or its code changed — review)")
    for key in sorted(k for k in new if k not in remap.values()):
        print(f"  NEW FINDING  {key}  (not accepted — review required)")

    unresolved = [k for k in new if k not in remap.values()]
    left_stale = [k for k in stale if k not in remap]
    print(
        f"retriage: {len(remap)} re-anchored, {len(left_stale)} stale, "
        f"{len(unresolved)} new finding(s) needing review."
    )

    if remap and not check_only:
        out = []
        for line in raw:
            key = line.strip()
            out.append(remap[key] if key in remap else line)
        TRIAGE.write_text("\n".join(out) + "\n")
        print(f"retriage: rewrote {TRIAGE}.")
    elif remap and check_only:
        print("retriage: --check, nothing written.")

    if unresolved:
        print("Fix the code, or add the key to aderyn.triage after review.")
        return 1
    if check_only and remap:
        return 1
    return 0


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("usage: retriage_aderyn.py <aderyn.out.json> [--check]", file=sys.stderr)
        sys.exit(2)
    sys.exit(main(sys.argv))
