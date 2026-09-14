include wall.mk

.PHONY: install tools hooks test-hooks fork coverage coverage-lcov

# Coverage builds with the optimizer disabled, which overflows the stack on
# forge-std's cheatcode interface; --ir-minimum enables viaIR with minimal
# optimization, which compiles. Branch percentages are unreliable under viaIR —
# read lines, statements and functions.
COVERAGE_ARGS := --ir-minimum --no-match-coverage '^(test|script)/'

## install : fetch pinned submodule dependencies and install the git hooks.
install: hooks
	git submodule update --init --recursive

## hooks : route git at the tracked hooks in .githooks/. Needed once per clone,
##         since .git/hooks is not part of the repository.
hooks:
	git config core.hooksPath .githooks
	@echo "git hooks -> .githooks/ (pre-commit runs make verify)"

## test-hooks : exercise the agent hooks in .claude/hooks/. They decide what an
##              agent may write, so a regression in them is silent — the gate
##              keeps reporting green while it stops being enforced — and no
##              other lane reads them.
##
##              Outside `make verify` on purpose: the Stop hook runs verify on
##              every turn that touches Solidity, and this adds a couple of
##              seconds that say nothing about the contracts. CI runs it as its
##              own step, before the gate, so a broken hook fails in seconds.
test-hooks:
	python3 script/test_hooks.py

## coverage : coverage for src/ as a table, with the test and script trees left
##            out of the report. Outside the gate.
coverage:
	forge coverage $(COVERAGE_ARGS)

## coverage-lcov : the same run, written to lcov.info for editor gutters and
##                 external coverage tooling.
coverage-lcov:
	forge coverage $(COVERAGE_ARGS) --report lcov

## tools : report the local toolchain. These must match the pins in
##         .github/workflows/wall.yml.
tools:
	@forge --version
	@printf 'slither '; slither --version
	@aderyn --version
	@python3 --version

## fork : mainnet fork tests. Not part of `make verify`; needs ETH_RPC_URL.
##        Pin the block in setUp() — forking `latest` makes runs non-reproducible.
fork:
	@if [ -z "$$ETH_RPC_URL" ]; then \
	  echo "ETH_RPC_URL is unset — cannot run fork tests."; \
	  echo "export ETH_RPC_URL=https://... (see [rpc_endpoints] in foundry.toml)"; \
	  exit 1; \
	fi
	forge test --match-path "$(FORK_DIR)/*" -vvv
