include wall.mk

.PHONY: install tools fork

## install : fetch pinned submodule dependencies.
install:
	git submodule update --init --recursive

## tools : report the local toolchain. These must match the pins in
##         .github/workflows/wall.yml.
tools:
	@forge --version
	@printf 'slither '; slither --version
	@aderyn --version
	@python3 --version

## fork : mainnet fork tests. Deliberately outside the gate in wall.mk — they
##        need network access and ETH_RPC_URL, which CI does not hold, so they
##        cannot be part of a hermetic, reproducible run. Pin the block in
##        setUp(); forking `latest` makes runs non-reproducible.
fork:
	@if [ -z "$$ETH_RPC_URL" ]; then \
	  echo "ETH_RPC_URL is unset — cannot run fork tests."; \
	  echo "export ETH_RPC_URL=https://... (see [rpc_endpoints] in foundry.toml)"; \
	  exit 1; \
	fi
	forge test --match-path "test/fork/*" -vvv
