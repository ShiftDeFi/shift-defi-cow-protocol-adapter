# test/CLAUDE.md

Layout and naming for tests. Both are enforced by `script/gate_tests.py`, which
runs in the `test` lane ahead of `forge test` — see its docstring for why each
check exists and what it cannot catch.

## Layout

- `test/` — unit tests.
- `test/mocks/` — stand-ins for third-party contracts, shared by every test
  directory. They contain no test functions and mirror only the surface the
  adapter calls.
- `test/invariant/` — property/invariant and fuzz tests. Split out because they
  are slow, and because they catch accounting and authorization errors that are
  only wrong relative to the rest of the contract and that static analysis
  misses.
- `test/fork/` — mainnet fork tests. Not part of `verify`; run via `make fork`
  with `ETH_RPC_URL` set. Pin the block in `setUp()` — forking `latest` makes
  runs non-reproducible.

## Suite structure

Tests for a contract live in `test/<ContractName>/`, one file per function under
test (`Constructor.t.sol`, `Sweep.t.sol`), each inheriting
`<ContractName>Base.sol` in the same directory. The base holds the fixture —
constants, deployed contracts, `setUp` — and no test functions, hence no `.t.sol`
suffix. `setUp` is `virtual`, and every override calls `super.setUp()` first.
Invariant suites for the same contract inherit the same base. A contract whose
tests still read in one sitting stays in a single `test/<ContractName>.t.sol`.

## Naming

Every segment is PascalCase:

| Form | For |
|---|---|
| `test_Subject` | a behaviour that should succeed |
| `test_Subject_Detail` | one aspect of that behaviour |
| `test_RevertIf_Subject_Reason` | a behaviour that should revert |
| `testFuzz_Subject`, `testFuzz_RevertIf_Subject_Reason` | fuzzed variants |
| `invariant_Property` | invariant and property tests |

`Subject` is the function under test — `test_SetDefaultPriceFeedStalenessThreshold`,
`test_RevertIf_SetDefaultPriceFeedStalenessThreshold_ZeroThreshold`. It stays in
the name even when the file and contract already identify the function.

The reason segment is required on a reverting test: it is what separates one
revert path from another, and a test that reverts for the wrong reason still
passes. `test_RevertIf_Subject` alone is rejected for that reason. `testFail_`
is rejected outright — it passes on *any* revert, including one from an
unrelated cause.

The guard has one blind spot worth knowing while writing: it sees only functions
Foundry already recognises as tests, so a misspelled prefix (`tets_Foo`) is
invisible to it, and silently never runs.

## Fixtures

Test code is exempt from the `Code style` rule in the root `CLAUDE.md` that
contracts cross boundaries as `address`: a fixture may hold and pass interface
or contract types directly. The `lint` lane is scoped to `src/` for the same
reason — fixtures legitimately use idioms the linter flags.
