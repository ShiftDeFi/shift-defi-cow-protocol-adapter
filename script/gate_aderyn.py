#!/usr/bin/env python3
"""Aderyn gate — per-finding triage, keyed by detector + path + line.

Fails the build if any current gated finding instance is not in the
acknowledged set. This is a per-finding model rather than a count: a new
instance of an already-accepted detector is a new key, so it still fails.

What gates: every HIGH-severity finding, plus the LOW-severity detectors named
in GATED_LOW_DETECTORS. Aderyn reports only two severities, and its low band
mixes advisory findings (centralization-risk fires on every owner-gated
function) with rules this repo treats as binding. Promoting individual
detectors keeps the binding ones enforced without adopting the whole band.

Report schema:
  report["high_issues"]["issues"] is a list of issue objects, one per detector.
  Each has "detector_name" and an "instances" list; each instance has
  "contract_path" and "line_no". Aderyn groups by detector, so the number of
  issue objects is not the number of findings — descend into instances.
  report["low_issues"] has the same shape.

Files (relative to the repo root):
  aderyn.out.json   the report (input, regenerated each run)
  aderyn.triage     one acknowledged key per line, "# comment" allowed.
                    Key format: detector_name|contract_path|line_no
                    Committed after human review.

Usage:
  python3 gate_aderyn.py aderyn.out.json                 # gate
  python3 gate_aderyn.py aderyn.out.json --print-keys    # list current keys
"""

import json
import pathlib
import sys

TRIAGE = pathlib.Path("aderyn.triage")

# Low-severity detectors promoted to gating. Each entry is a repository rule,
# not a severity judgement by the tool.
GATED_LOW_DETECTORS = {
    # Every function that modifies state must emit an event describing the
    # change. One event may cover several variables written in the same call.
    "state-change-without-event",
}


def instance_keys(report: dict) -> list[str]:
    """Every gated finding instance as a stable key: detector|path|line."""
    keys = []
    bands = (
        ("high_issues", None),
        ("low_issues", GATED_LOW_DETECTORS),
    )
    for band, allowed in bands:
        for issue in (report.get(band) or {}).get("issues", []):
            detector = issue.get("detector_name", "unknown-detector")
            if allowed is not None and detector not in allowed:
                continue
            for inst in issue.get("instances", []):
                path = inst.get("contract_path", "?")
                line = inst.get("line_no", "?")
                keys.append(f"{detector}|{path}|{line}")
    return keys


def load_acknowledged() -> set[str]:
    if not TRIAGE.exists():
        return set()
    out = set()
    for raw in TRIAGE.read_text().splitlines():
        line = raw.strip()
        if line and not line.startswith("#"):
            out.add(line)
    return out


def main(argv: list[str]) -> int:
    path = argv[1]
    report = json.loads(pathlib.Path(path).read_text())
    current = instance_keys(report)

    if "--print-keys" in argv:
        for k in current:
            print(k)
        return 0

    acknowledged = load_acknowledged()
    new = [k for k in current if k not in acknowledged]

    print(
        f"aderyn: {len(current)} gated instance(s); "
        f"{len(acknowledged)} acknowledged; {len(new)} un-triaged."
    )
    if new:
        print("WALL: gated finding(s) not in aderyn.triage:")
        for k in new:
            print(f"  - {k}")
        print("Fix the code, or add the key to aderyn.triage after review.")
        return 1
    return 0


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("usage: gate_aderyn.py <aderyn.out.json> [--print-keys]", file=sys.stderr)
        sys.exit(2)
    sys.exit(main(sys.argv))
