# shift-defi-cow-protocol-adapter

A [CoW Protocol](https://docs.cow.fi/) adapter for the ShiftDeFi platform.

CoW settlement is asynchronous: an order is signed and placed, and settled later
by a solver in a transaction the placer does not control. This adapter is the
contract that owns that lifecycle — placing orders, holding the sell-side tokens
that `GPv2Settlement` pulls from, and reporting fill status — so that the
consuming contract does not have to model an asynchronous swap itself.

One adapter instance is deployed per consuming contract and is owned by it.
Instances are independent: there is no shared implementation, no factory, and no
multi-tenant accounting.

## Installation

Published to npm as `@shift-defi/cow-protocol-adapter`. The package carries the
Solidity sources under `src/` and nothing else, so the consuming project
compiles them with its own solc settings.

```shell
npm install @shift-defi/cow-protocol-adapter
```

Foundry consumers add the remapping explicitly:

```
@shift-defi/cow-protocol-adapter=node_modules/@shift-defi/cow-protocol-adapter/src
```

```solidity
import {CowProtocolAdapter} from "@shift-defi/cow-protocol-adapter/CowProtocolAdapter.sol";
```

Compile with the optimizer on. Without it `CowProtocolAdapter` fails to
compile with stack-too-deep.

The contracts import OpenZeppelin v5, declared as a peer dependency. The
consumer supplies it — from npm, or from a submodule remapped to the same
`@openzeppelin/contracts/` prefix — so that one copy backs both trees.

Publishing runs `make verify` first, through `prepublishOnly`: the gate decides
what leaves the repository, not just what merges into it.

## Requirements

| Tool | Version |
|---|---|
| [Foundry](https://getfoundry.sh) | v1.4.4 |
| [Slither](https://github.com/crytic/slither) | 0.11.6 |
| [Aderyn](https://github.com/Cyfrin/aderyn) | 0.6.8 |
| Python | 3.12+ |
| npm | 12.0.2 |

Versions must match the pins in `.github/workflows/`; `make tools` reports what
is installed locally. npm is needed only to publish the package — no gate lane
uses it — and is pinned because trusted publishing requires 11.5.1 or newer and
the publish job holds a credential, so nothing there is fetched unpinned.

## Getting started

```shell
git clone --recursive git@github.com:ShiftDeFi/shift-defi-cow-protocol-adapter.git
cd shift-defi-cow-protocol-adapter
make verify
```

If the repository was cloned without `--recursive`, run `make install` first to
fetch the pinned submodules.

## The gate

`make verify` is the single verification entry point, and CI runs the same
target, so the two cannot drift apart in which checks they perform. CI selects
the stricter `ci` profile, which treats compiler warnings as errors and runs
fuzz and invariant campaigns far harder than the local default — so CI can still
surface a property failure a local run did not reach. Lanes run cheapest-first
and stop at the first failure:

| Lane | Checks |
|---|---|
| `fmt` | `forge fmt --check` |
| `build` | compiles; the CI profile treats compiler warnings as errors |
| `lint` | `forge lint` — naming, code size, and style rules |
| `test` | unit tests, guarded on test presence and naming |
| `slither` | static analysis; fails at medium severity and above |
| `aderyn` | second static analysis engine, gated per finding |
| `invariant` | property, invariant and fuzz tests |

Each lane also runs standalone (`make lint`, `make slither`, …), which is the
fast way to iterate on one failure. `make help` lists every target.

Two analysis engines are used deliberately: they have uncorrelated blind spots,
and findings that neither reports are the reason the invariant lane exists.

The test guard runs ahead of the analysis lanes on purpose. On a tree that has
contracts but no tests it fails there with a clear message, rather than reaching
`slither`, which aborts with `InvalidCompilation` on an empty `src/`.

The agent hooks under `.claude/` carry their own suite, `make test-hooks`. It is
not part of `make verify` — the hooks run the gate themselves, and a couple of
seconds per turn buys nothing about the contracts — but CI runs it as its own
step ahead of the gate.

### Triage

Both analysis lanes gate on findings and record accepted ones as reviewed state
that is committed alongside the code:

- **Slither** — `make triage` writes acknowledgements to `slither.db.json`.
- **Aderyn** — acknowledged findings are keyed `detector|path|line|anchor` in
  `aderyn.triage`, where the anchor is a digest of the source line the finding
  sits on. A new instance of an already-accepted detector is a new key, and
  still fails.

Because the key carries a line number, inserting a line above a reviewed finding
renumbers it, and the lane fails on something that is not a new finding at all.
`make retriage` re-anchors those: it pairs a stale key with the current finding
carrying the same anchor, and it never accepts a new finding nor removes an
existing one. Pairing on the recorded digest rather than on a baseline read from
HEAD is what makes it work more than once between commits.

Adding a triage entry is a human review decision and requires reasoning recorded
alongside it.

## Testing

- `test/` — unit tests.
- `test/invariant/` — property, invariant and fuzz tests. Run separately because
  they are slow, and because they catch accounting and authorization errors that
  are only wrong relative to the rest of a contract, which static analysis
  cannot see.
- `test/fork/` — mainnet fork tests against real settlement contracts. Not part
  of `make verify`; run with `make fork` and `ETH_RPC_URL` set. Fork blocks
  are pinned in `setUp()` so runs stay reproducible.

Both unit and invariant tests are required — `make verify` fails on a tree that
has contracts but no tests in either category.

Test names follow a fixed shape, checked by the same guard. Each segment is
PascalCase: `test_Subject` and `test_Subject_Detail` for behaviour that should
succeed, `test_RevertIf_Subject_Reason` for behaviour that should revert,
`testFuzz_` for fuzzed variants, and `invariant_Property` for invariant tests.
The reason segment is required on a reverting test — a test that reverts for the
wrong reason still passes, so naming the expected cause is what keeps one revert
path distinguishable from another.

## Repository layout

```
src/                 contracts
test/                unit tests
  invariant/         property and fuzz tests
  fork/              mainnet fork tests
wall/                the verification gate and its scripts
foundry.toml         compiler, formatter and profile settings
package.json         npm manifest: what the published package contains
.claude/             agent hooks that run the gate during development
```

## Contributing

`make verify` must pass before a change is merged; CI enforces it.

This repository configures [Claude Code](https://claude.com/claude-code) hooks in
`.claude/settings.json` that compile Solidity as it is edited and run the gate
before a session ends. They call the same `make` targets as CI and are inert if
the toolchain is not installed. To opt out locally, override them in
`.claude/settings.local.json`, which is untracked. Changes under `.claude/` are
executable configuration and are reviewed with the same care as `src/`.

Coding conventions are documented in `CLAUDE.md`.
