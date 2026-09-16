# ============================================================================
#  wall.mk — the deterministic verification gate.
#
#  `make verify` runs every lane. CI runs the same target, so a green pipeline
#  and a green local run mean the same thing.
#
#  Recipes run from the repo root. References to files shipped alongside this
#  fragment are anchored to $(WALL_DIR); generated reports and triage files stay
#  relative to the repo root.
# ============================================================================

WALL_MK  := $(lastword $(MAKEFILE_LIST))
WALL_DIR := $(dir $(WALL_MK))

.DEFAULT_GOAL := verify

SRC_DIR       ?= src
INVARIANT_DIR ?= test/invariant
FORK_DIR      ?= test/fork

# --fail-medium => non-zero exit on any finding >= medium severity. Findings
# acknowledged into slither.db.json (via `make triage`) are suppressed.
SLITHER_ARGS := --config-file $(WALL_DIR)slither.config.json --fail-medium

.PHONY: verify fmt build lint test slither aderyn invariant triage retriage help clean

## verify : the full gate. Prerequisites run left-to-right, cheapest first.
verify: fmt build lint test slither aderyn invariant
	@echo ""
	@echo "  WALL PASSED — this change is mergeable."

## fmt : formatting is part of the gate.
fmt:
	forge fmt --check

## build : contracts must compile, with sizes reported. The CI profile treats
##         compiler warnings as errors (see [profile.ci] in foundry.toml).
build:
	forge build --sizes

## lint : naming and style rules that `forge fmt` does not cover.
##        `forge lint` reports findings but exits 0, so the gate script is what
##        turns them into a failure. Suppress via [lint] in foundry.toml.
##        The import check is a text scan and covers src/, test/ and script/.
lint:
	python3 $(WALL_DIR)script/gate_lint.py $(SRC_DIR)
	@if grep -rn --include='*.sol' --exclude-dir=lib --exclude-dir=out \
	    --exclude-dir=cache -E '(import|from)[^;]*"\.\./' .; then \
	  echo "WALL: imports must not traverse upwards with '../'."; \
	  echo "      Foundry resolves from the project root — write \"src/Foo.sol\"."; \
	  exit 1; \
	fi

## test : unit tests only. Invariant and fuzz runs are split out below.
##        `forge test` exits 0 when it finds no tests, so the guard runs first
##        and rejects a tree that has contracts but no coverage. The same guard
##        checks test naming, which no Foundry tool covers.
##
##        Fork tests are excluded too: they need ETH_RPC_URL and a network
##        round trip, which would make the gate neither hermetic nor offline.
##        They run via `make fork`.
test:
	python3 $(WALL_DIR)script/gate_tests.py
	forge test --no-match-path "{$(INVARIANT_DIR),$(FORK_DIR)}/*"

## slither : static analysis. Writes a structured report and exits non-zero on
##           any finding at or above the threshold.
slither:
	@# Slither will not overwrite an existing --json file: it logs "the overwrite
	@# is prevented" at INFO level and exits 0, leaving a stale report next to a
	@# freshly-failing tree. The exit code stays correct, but anything reading the
	@# JSON would see the previous run. Clear it first.
	rm -f slither.out.json
	@slither . $(SLITHER_ARGS) --json slither.out.json || { \
	  echo "WALL: slither failed — a finding at medium severity or above, or"; \
	  echo "      the compilation above. For a finding: fix the code, or"; \
	  echo "      acknowledge it with \`make triage\` after review. The"; \
	  echo "      wall-triage skill covers deciding between the two."; \
	  exit 1; \
	}

## aderyn : second static analysis engine, for uncorrelated blind spots.
##          Structured report plus a per-finding triage gate on high severity,
##          and on the low-severity detectors promoted in gate_aderyn.py.
aderyn:
	aderyn . --src $(SRC_DIR) --output aderyn.out.json
	python3 $(WALL_DIR)script/gate_aderyn.py aderyn.out.json

## invariant : property, invariant and fuzz tests. Slowest, so it runs last.
invariant:
	forge test --match-path "$(INVARIANT_DIR)/*"

## triage : interactively acknowledge a Slither finding into slither.db.json.
##          Requires human review; aderyn's equivalent is editing aderyn.triage.
triage:
	slither . --config-file $(WALL_DIR)slither.config.json --triage-mode

## retriage : re-anchor accepted aderyn keys whose finding only moved. A key
##            is keyed by line, so inserting a line above a reviewed finding
##            renumbers it; this pairs the stale key with the current finding
##            carrying the same anchor — the digest of the source line recorded
##            in the key itself, which holds across a chain of uncommitted
##            edits. It never accepts a new finding and never removes a key —
##            both stay human decisions. To report without writing, run
##            `make retriage RETRIAGE_ARGS=--check`; a bare --check on the make
##            command line is swallowed as an abbreviation of make's own
##            --check-symlink-times and never reaches the script.
retriage:
	aderyn . --src $(SRC_DIR) --output aderyn.out.json
	python3 $(WALL_DIR)script/retriage_aderyn.py aderyn.out.json $(RETRIAGE_ARGS)

## help : list available targets.
help:
	@grep -hE '^##' $(MAKEFILE_LIST) | sed -E 's/^## ?//'

clean:
	forge clean
	rm -f slither.out.json aderyn.out.json lcov.info
