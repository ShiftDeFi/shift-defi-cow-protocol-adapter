#!/usr/bin/env python3
"""UserPromptSubmit hook: record the state the turn starts from.

Two records, both read by wall_stop.py, so what it acts on is what this turn
did rather than what was already uncommitted when the session began:
wall_protected.py's, over the files that define the gate, and
wall_solidity.py's, over the contracts. Without the first, a branch carrying
in-progress gate work — the normal state while the gate itself is being changed
— would fail every turn. Without the second, a branch carrying in-progress
contract work would run `make verify` on every turn, including the ones that
touched no Solidity at all.

Writes nothing to stdout: a UserPromptSubmit hook's output is added to the
model's context, and this has nothing to say when it succeeds.
"""

import json
import sys

import wall_protected
import wall_solidity


def main() -> int:
    for module in (wall_protected, wall_solidity):
        try:
            module.STATE.write_text(json.dumps(module.snapshot()))
        except OSError:
            # A missing record is handled where it is read: wall_stop.py
            # establishes the protected-file one and lets the turn pass, and
            # falls back to the working tree for Solidity. Failing the turn
            # over a state file would be worse.
            pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
