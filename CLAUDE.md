# CLAUDE.md

## Project

`shift-defi-cow-protocol-adapter` (ShiftDeFi) — a Foundry/Solidity project for a CoW Protocol adapter.

This repo is public. Keep comments in committed files factual and about what the code does; no internal planning, roadmap, or deliberation.

## The gate

`make verify` is the gate, and CI runs the same target. Each lane also runs standalone (`make lint`, `make slither`, …), which is the fast way to iterate on one failure. README.md describes what every lane checks, `test/CLAUDE.md` covers test layout and naming, and each gate script documents its own mechanics and blind spots.

Unit and invariant tests are both required; `WALL_REQUIRE_INVARIANT=0` stages adoption. Suppress a lint rule in `foundry.toml` under `[lint]` — `exclude_lints` or `mixed_case_exceptions` — after review, rather than in a triage file of its own, the way aderyn has `aderyn.triage`.

**Adding a triage entry is a human review decision. Propose entries with reasoning; do not add them unilaterally** — the hooks refuse the write in any case.

## Agent hooks

`.claude/settings.json` wires the gate into Claude Code sessions, so Solidity is checked as it is written rather than only at push time. The gate's own files cannot be written, whatever route the write takes — propose the change instead; reading them is always allowed. A turn cannot end on a red gate, nor on a gate file this turn changed.

`WALL_GUARD=0` in the session environment lifts the guard, and is how to work on the wall itself; leave it unset otherwise. Changes under `.claude/` are executable configuration and warrant the same review as `src/`.

## Shell output

Shell output is the largest consumer of an agent's context window, and read-only
exploration is half of it.

Delegate to a subagent when exploring will take five or more read-only commands,
or when a single command dumps more than ten thousand characters, and only the
answer is needed rather than the source itself. Never delegate reading a file
that is about to be edited — an edit needs the exact text, and a subagent returns
excerpts and conclusions.

Cap output everywhere else. Pipe through `head`, count with `wc -l` before
printing a file, and use `grep -c` before `grep -n`.

## Commits

**Never add a `Co-Authored-By` trailer, and never attribute a commit to the tooling used to write it.** This applies to every commit without exception, including ones authored entirely by an agent. A commit message describes the change; how it was produced is not part of the record.

## Code style

Formatting and casing are enforced, not documented: `forge fmt` settings are pinned in `foundry.toml` (including `int_types = "long"`, so `uint256`/`int256` are automatic), and the `lint` lane gates on `forge lint`. The rules below are the ones no tool checks.

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

**Naming.** A function parameter whose name matches a storage variable is prefixed with an underscore.

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

**Parameter validation.** Every external and public function validates its parameters and rejects invalid input with a named custom error. The rule is uniform: do not judge, per parameter, whether an invalid value would have failed anyway. Numeric bounds, array lengths, relationships between two parameters and values passed onward to a call are all included, and are the author's responsibility — tooling sees none of them.

**Events.** A function that modifies state emits an event carrying the new values, so a consumer can reconstruct the state change from logs alone. One event may cover several variables written in the same call — the rule is per function, not per variable.

**Returns.** An implementation returns with an explicit `return` statement in its body and declares the return type only (`returns (uint256)`), never a named return variable assigned implicitly. The same holds in tests. An interface declaration, which has no body, keeps its named returns — they are what the `@return` tags pair against.

**Local variables.** When a function needs more than four reference-type (`memory`) locals, group them into a struct named `<FunctionName>LocalVars`, declared in the contract's interface file, containing only that function's variables and not reused elsewhere.

**Function parameters.** When a function takes more than three parameters, consider whether several of them express one domain concept. If so, group them into a struct named `<FunctionName>Params`, or something more specific where it reads better (`SwapParams`, `PermitData`). Pass it as `calldata` for external functions and `memory` for internal ones. Do not create a struct purely to shorten a parameter list.

**Interfaces.** Split every contract into interface and implementation. Custom errors, events, function signatures, enums and structs are declared in the interface file. Interface functions appear in the same order as in the implementation. Functions, events and errors take named parameters and carry full NatSpec.

NatSpec lives in the interface and is never duplicated in the implementation: every implementing function carries `/// @inheritdoc <Interface>` and nothing else. An implementation-only function — a constructor, an `internal` helper — documents itself with `@dev` and `@param` in place.

## Toolchain

Pins live in `.github/workflows/wall.yml` and must match local versions; check with `make tools` and bump both sides together.

Dependencies are git submodules under `lib/`, pinned in `foundry.lock`. Clone with `--recursive` or run `make install`; add new deps with `forge install`, not by hand.

`auto_detect_remappings` is off, so `remappings.txt` is the complete set and a new dependency needs its remapping added there by hand — `forge install` alone will not make it importable. Slither and Aderyn resolve imports through the same file.
