# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

`shift-defi-cow-protocol-adapter` (ShiftDeFi) — a Foundry/Solidity project for a CoW Protocol adapter.

**Current state:** the verification gate is in place. `src/` holds `OwnerImmutable` (immutable single-owner access control) and `CowProtocolAdapter`, which currently exposes `sweep` — order placement and fill detection are not implemented yet.

This repo is public. Keep comments in committed files factual and about what the code does; no internal planning, roadmap, or deliberation.

## The gate

`make verify` is the gate, and CI runs the same target. Lanes run cheapest-first: `fmt` → `build` → `lint` → `test` → `slither` → `aderyn` → `invariant`.

```shell
make verify        # the full gate
make help          # list targets
make tools         # local toolchain versions (must match the CI pins)
make install       # git submodule update --init --recursive
make fork          # mainnet fork tests; needs ETH_RPC_URL
make triage        # interactive Slither triage (human review step)
make retriage      # re-anchor accepted aderyn keys whose finding only moved
make clean
```

Individual lanes (`make build`, `make lint`, `make test`, `make slither`, `make aderyn`, `make invariant`) run standalone, which is the fast way to iterate on one failure.

### Lint gate

`forge lint` prints findings but exits 0, so `script/gate_lint.py` parses its JSON and fails on any diagnostic. Note the JSON goes to stderr, not stdout. Suppress a rule in `foundry.toml` under `[lint]` — `exclude_lints` or `mixed_case_exceptions` — after review, rather than in a separate triage file.

The lane is scoped to `src/`; test code is not linted, since fixtures legitimately use idioms the linter flags. `lint_on_build` is off so this lane is the only source of lint findings.

### Test guard

`script/gate_tests.py` runs before `forge test` and checks two things against one `forge test --list --json` listing.

**Presence.** `forge test` exits 0 when it finds no tests, so the guard counts them first and fails when either category is empty. Unit tests are always required; invariant tests under `test/invariant/` are required by default — set `WALL_REQUIRE_INVARIANT=0` to stage adoption.

This is also what makes the gate safe on a tree with no contracts: it runs before the analysis lanes, so `make verify` fails there with a clear message rather than reaching `slither`, which aborts with `InvalidCompilation` on an empty `src/`.

**Naming.** Nothing in Foundry checks test names, and the `lint` lane is scoped to `src/`, so this guard is the only enforcement. See [Testing layout](#testing-layout) for the accepted forms.

Its one blind spot: the listing contains only functions Foundry already recognises as tests, so a misspelled prefix (`tets_Foo`) is invisible here — and silently never runs.

### Triage

Both analysis lanes gate on findings, and both record accepted findings as reviewed state that is committed:

- **Slither** — `--fail-medium`, so anything at medium or above fails. Optimization-severity detectors (`immutable-states`, `cache-array-length`, and three others) are reported but do not gate, since the threshold is deliberately set at correctness. Acknowledge via `make triage`, which writes `slither.db.json`.
- **Aderyn** — `script/gate_aderyn.py` gates per finding *instance*, keyed `detector|path|line`, against `aderyn.triage`. A new instance of an already-accepted detector is a new key and still fails. Aderyn anchors an instance at the enclosing function declaration, so keys survive edits inside a function body but not line insertions above it.

  A key is anchored by line, so a line inserted above a reviewed finding renumbers it and the lane fails on something that is not a new finding at all. `make retriage` re-anchors those: it pairs a stale key with a current finding when the detector, the path and the anchored source text all match — old text from `HEAD`, new text from the working tree — and refuses to pair ambiguously. It never adds a key and never removes one, so accepting a finding and dropping a fixed one both stay human decisions. `--check` reports without writing.

  Aderyn reports only two severities. All high findings gate; from the low band, only the detectors listed in `GATED_LOW_DETECTORS` in `gate_aderyn.py` do. That band mixes advisory findings — `centralization-risk` fires on every owner-gated function — with rules this repo treats as binding, so detectors are promoted individually rather than by lowering the threshold. Currently promoted: `state-change-without-event`, `state-no-address-check`.

Adding a triage entry is a human review decision. Propose entries with reasoning; do not add them unilaterally.

`slither.out.json` and `aderyn.out.json` are regenerated each run and gitignored. `aderyn.triage` and `slither.db.json` are committed.

## Agent hooks

`.claude/settings.json` wires the gate into Claude Code sessions, so generated Solidity is checked as it is written rather than only at push time. Both hooks live in `.claude/hooks/` and call the same `make` targets as CI.

| Event | Script | Behaviour |
|---|---|---|
| `PostToolUse` on `Write`/`Edit` | `wall_post_edit.py` | For `.sol` files: applies `forge fmt`, then `forge build`. A compile error is returned to the model in-turn. |
| `Stop` | `wall_stop.py` | If any `.sol` differs in the working tree, runs `make verify`. A red gate prevents the turn ending. |

Both exit 0 and stay silent when they do not apply — a turn that touches no Solidity is unaffected. The `Stop` hook also stands down, with a notice, when the toolchain is not installed, and when resuming from its own previous block, so a failure it cannot fix does not trap the session. Neither case weakens CI, which enforces the gate unconditionally.

To opt out locally, disable or override the hooks in `.claude/settings.local.json`, which is untracked. Changes under `.claude/` are executable configuration and warrant the same review as `src/`.

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

## Testing layout

- `test/` — unit tests.
- `test/mocks/` — stand-ins for third-party contracts, shared by every test directory. They
  contain no test functions and mirror only the surface the adapter calls.
- `test/invariant/` — property/invariant and fuzz tests. Split out because they are slow, and because they catch accounting and authorization errors that are only wrong relative to the rest of the contract and that static analysis misses.
**Suite structure.** Tests for a contract live in `test/<ContractName>/`, one file per function
under test (`Constructor.t.sol`, `Sweep.t.sol`), each inheriting `<ContractName>Base.sol` in the
same directory. The base holds the fixture — constants, deployed contracts, `setUp` — and no
test functions, hence no `.t.sol` suffix. `setUp` is `virtual`, and every override calls
`super.setUp()` first. Invariant suites for the same contract inherit the same base. A contract
whose tests still read in one sitting stays in a single `test/<ContractName>.t.sol`.

- `test/fork/` — mainnet fork tests. Not part of `verify`; run via `make fork` with `ETH_RPC_URL` set. Pin the block in `setUp()` — forking `latest` makes runs non-reproducible.

**Test naming.** Enforced by `script/gate_tests.py`. Every segment is PascalCase:

| Form | For |
|---|---|
| `test_Subject` | a behaviour that should succeed |
| `test_Subject_Detail` | one aspect of that behaviour |
| `test_RevertIf_Subject_Reason` | a behaviour that should revert |
| `testFuzz_Subject`, `testFuzz_RevertIf_Subject_Reason` | fuzzed variants |
| `invariant_Property` | invariant and property tests |

`Subject` is the function under test — `test_SetDefaultPriceFeedStalenessThreshold`, `test_RevertIf_SetDefaultPriceFeedStalenessThreshold_ZeroThreshold`. It stays in the name even when the file and contract already identify the function.

The reason segment is required on a reverting test: it is what separates one revert path from another, and a test that reverts for the wrong reason still passes. `test_RevertIf_Subject` alone is rejected for that reason. `testFail_` is rejected outright — it passes on *any* revert, including one from an unrelated cause.

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
