# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

`shift-defi-cow-protocol-adapter` (ShiftDeFi) — a Foundry/Solidity project for a CoW Protocol adapter.

**Current state:** the verification gate is in place. `src/` holds `OwnerImmutable` (immutable single-owner access control), the `GPv2Order` library (CoW Protocol's order type and identifier derivation) and `CowProtocolAdapter`, which exposes `placeOrder` and `sweep` with views over pending orders and committed balances. Fill detection is not implemented yet.

This repo is public. Keep comments in committed files factual and about what the code does; no internal planning, roadmap, or deliberation.

## The gate

`make verify` is the gate, and CI runs the same target. Lanes run cheapest-first: `fmt` → `build` → `lint` → `test` → `slither` → `aderyn` → `invariant`. Each runs standalone (`make lint`, `make slither`, …), which is the fast way to iterate on one failure. README.md describes what every lane checks, and each gate script documents its own mechanics and blind spots.

```shell
make verify        # the full gate
make help          # list targets
make tools         # local toolchain versions (must match the CI pins)
make install       # git submodule update --init --recursive
make fork          # mainnet fork tests; needs ETH_RPC_URL
make test-hooks    # exercise the agent hooks; outside the gate, run by CI
make triage        # interactive Slither triage (human review step)
make retriage      # re-anchor accepted aderyn keys whose finding only moved
make clean
```

**Lint.** Suppress a rule in `foundry.toml` under `[lint]` — `exclude_lints` or `mixed_case_exceptions` — after review, rather than in a triage file next to the script. The lane is scoped to `src/`.

**Tests.** Unit tests are always required, and invariant tests under `test/invariant/` are required by default; `WALL_REQUIRE_INVARIANT=0` stages adoption. Layout and naming are enforced — see `test/CLAUDE.md`.

**Triage.** Slither fails at medium severity and above; acknowledge a finding with `make triage`, which writes `slither.db.json`. Aderyn gates per finding *instance*, keyed `detector|path|line` in `aderyn.triage`, so a new instance of an already-accepted detector still fails. Every high finding gates; from the low band only the detectors promoted in `gate_aderyn.py` do — currently `state-change-without-event` and `state-no-address-check`. When a key stops matching because a line was inserted above it, `make retriage` re-anchors it without accepting anything new.

**Adding a triage entry is a human review decision. Propose entries with reasoning; do not add them unilaterally** — the guard below refuses the write in any case.

`slither.out.json` and `aderyn.out.json` are regenerated each run and gitignored. `aderyn.triage` and `slither.db.json` are committed.

## Agent hooks

`.claude/settings.json` wires the gate into Claude Code sessions, so Solidity is checked as it is written rather than only at push time. In practice:

- **Editing a `.sol` file formats and compiles it in-turn**, whatever route the write took — `Write`, `Edit`, a heredoc, a stream edit or a script. A compile error comes straight back.
- **The gate itself cannot be written.** `aderyn.triage`, `slither.db.json`, `wall.mk`, `Makefile`, `script/*.py`, `.githooks/`, `.github/workflows/` and `.claude/hooks/*.py` are refused outright. `foundry.toml` and the two `.claude/settings*.json` files are refused only where the edit reaches a gate setting or the `hooks` and `env` blocks, so ordinary work on them is unaffected. Reading any of them is always allowed. Propose the change instead.
- **A turn cannot end on a red gate**, nor on a gate file this turn changed by any route.

`WALL_GUARD=0` in the session environment lifts the guard, and is how to work on the wall itself; leave it unset otherwise. `make test-hooks` exercises the hooks, and is the only thing that reads them.

Why each check is scoped the way it is — and which approach was tried first and abandoned — is documented in `.claude/hooks/wall_protected.py`. Changes under `.claude/` are executable configuration and warrant the same review as `src/`.

## Commits

**Never add a `Co-Authored-By` trailer, and never attribute a commit to the tooling used to write it.** This applies to every commit without exception, including ones authored entirely by an agent. A commit message describes the change; how it was produced is not part of the record.

The same reasoning as the comment rule under [Project](#project): this repository is public, and its history documents the code rather than the process behind it.

## Code style

Formatting and naming are enforced, not documented: `forge fmt` settings are pinned in `foundry.toml` (including `int_types = "long"`, so `uint256`/`int256` are automatic), and the `lint` lane gates on `forge lint`, which covers casing. Do not restate those rules here — the rules below are the ones no tool checks.

**Match the surrounding code first.** Inspect neighbouring contracts and follow their naming, file organisation, error handling and import patterns. Where repository convention conflicts with generic Solidity advice, convention wins. Do not introduce new stylistic conventions unless asked.

**Imports.** Explicit named imports only, bringing in nothing unused. Never traverse upwards — write `src/Foo.sol`, not `../src/Foo.sol` or `../../src/Foo.sol`; Foundry compiles with the project root as the base path, so a top-level directory resolves from any depth. Order from most external to most internal. Group imports from the same relative directory together, ordered alphabetically by path, with one blank line between groups. Do not align the `from` keyword — `forge fmt` collapses the padding, and the edit hook reformats on every write.

**Declaration ordering.**

```
using _ for _

address / bool / uint256 / mapping
Enum / Struct
Event

constant / immutable

modifier

constructor
external / public / internal / private
```

Functions follow the Solidity style guide's visibility order — most externally reachable
first, helpers last — so a reader meets the contract's surface before its internals.

**Naming.** Contracts PascalCase, functions and variables camelCase, constants and immutables UPPER_SNAKE_CASE. A function parameter whose name matches a storage variable is prefixed with an underscore.

**Loops.** Use `++i` and `--i`, never postfix. Always cache an array's length before iterating.

**Storage.** Cache a storage variable in memory if it is read more than once in a scope.

**Contract references.** Tokens and other contracts cross the external boundary as
`address` — function parameters, return values, event parameters, and the fields of any
struct that appears in one — and are cast to the interface type at the point of use:
`IERC20(token).safeTransfer(...)`. State variables and immutables may be declared as the
interface or contract type. Where a third-party interface or an external standard specifies
an interface type in a signature this repo implements or calls, match that signature.
`using SafeERC20 for IERC20` stays declared; it binds to the cast expression. Test fixtures
are exempt.

**Parameter validation.** Every external and public function validates its parameters and rejects invalid input with a named custom error. The rule is uniform: do not judge, per parameter, whether an invalid value would have failed anyway.

The `aderyn` lane gates the one case tooling detects — an address parameter written to storage with no zero-check. Parameters passed onward to a call, numeric bounds, array lengths and relationships between two parameters are invisible to both engines and are the author's responsibility.

**Events.** A function that modifies state emits an event. One event may cover several variables written in the same call — the rule is per function, not per variable. The `aderyn` lane enforces that an event exists; what it cannot check, and what still has to be got right by hand, is that the event carries the new values, so a consumer can reconstruct the state change from logs alone.

**Local variables.** When a function needs more than four reference-type (`memory`) locals, group them into a struct named `<FunctionName>LocalVars`, declared in the contract's interface file, containing only that function's variables and not reused elsewhere.

**Function parameters.** When a function takes more than three parameters, consider whether several of them express one domain concept. If so, group them into a struct named `<FunctionName>Params`, or something more specific where it reads better (`SwapParams`, `PermitData`). Pass it as `calldata` for external functions and `memory` for internal ones. Do not create a struct purely to shorten a parameter list.

**Interfaces.** Split every contract into interface and implementation. Custom errors, events, function signatures, enums and structs are declared in the interface file. Interface functions appear in the same order as in the implementation. Functions, events and errors take named parameters and carry full NatSpec.

NatSpec lives in the interface and is never duplicated in the implementation: every implementing function carries `/// @inheritdoc <Interface>` and nothing else. An implementation-only function — a constructor, an `internal` helper — documents itself with `@dev` and `@param` in place.

## Toolchain

Pins live in `.github/workflows/wall.yml` and must match local versions; check with `make tools` and bump both sides together.

| Tool | Pin |
|---|---|
| Foundry | v1.4.4 |
| Slither | 0.11.6 |
| Aderyn | 0.6.8 |
| solc | 0.8.28 (`foundry.toml`) |

Dependencies are git submodules under `lib/`, pinned in `foundry.lock` (currently `forge-std` v1.16.2). Clone with `--recursive` or run `make install`; add new deps with `forge install`, not by hand.

`auto_detect_remappings` is off, so `remappings.txt` is the complete set and a new dependency needs its remapping added there by hand — `forge install` alone will not make it importable. Slither and Aderyn resolve imports through the same file.

## Foundry profiles

`[profile.default]` stays fast for the local loop. `[profile.ci]` is stricter — `deny_warnings = true` (compiler warnings fail the build), and heavier fuzz/invariant runs. CI sets `FOUNDRY_PROFILE=ci`.
