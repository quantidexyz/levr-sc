include common.mk

.PHONY: deploy
deploy:
	@$(MAKE) -s common-deploy

.PHONY: anvil-fork
anvil-fork:
	@echo "Starting Anvil with Base mainnet fork..."
	anvil --fork-url $(shell forge config --json | jq -r '.rpc_endpoints."base-mainnet"') --fork-block-number 36000000 --chain-id 31337

.PHONY: deploy-devnet-factory
deploy-devnet-factory:
	@echo "Deploying LevrFactoryDevnet..."
	@echo "Loading environment variables from .env file..."; \
	if [ -f .env ]; then set -a; . ./.env; set +a; fi; \
	echo "Using TESTNET_PRIVATE_KEY from environment"; \
	if [ -z "$$TESTNET_PRIVATE_KEY" ]; then \
		echo "ERROR: TESTNET_PRIVATE_KEY environment variable not set"; \
		exit 1; \
	fi; \
	if [ -z "$$FORK_URL" ]; then \
		echo "No FORK_URL specified, using local anvil fork..."; \
		export RPC_URL="http://localhost:8545"; \
		echo "Funding deployer on anvil fork..."; \
		export DEPLOYER_ADDRESS=$$(cast wallet address --private-key $$TESTNET_PRIVATE_KEY) && \
		cast send --rpc-url $$RPC_URL --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 --value 1000ether $$DEPLOYER_ADDRESS > /dev/null 2>&1 || true; \
	else \
		echo "Using custom FORK_URL: $$FORK_URL"; \
		export RPC_URL=$$FORK_URL; \
	fi; \
	export PRIVATE_KEY=$$TESTNET_PRIVATE_KEY && forge script script/DeployLevrFactoryDevnet.s.sol --rpc-url $$RPC_URL --broadcast -vvv