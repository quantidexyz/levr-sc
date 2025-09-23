# Common Make library for InfoFi contract operations

# Variables (override from CLI):
#   CHAIN      = base | optimism
#   NETWORK    = sepolia | mainnet
#   SCRIPT     = MasterOven_v1 | TipOven_v1 (without Deploy prefix)
#   VERIFY     = true | false (default: true)
#   BROADCAST  = true | false (default: true)
#   EXTRA_ARGS = Additional flags forwarded to forge (optional)

DEFAULT_SCRIPT ?= MasterOven_v1

# CLI builder: resolved deploy command (used by top-level Makefile)
# Expects these shell variables to be set by the caller (Makefile recipe):
#   SCRIPT_PATH, SCRIPT_NAME, RPC_ALIAS, VERIFY_FLAG, BROADCAST_FLAG, PRIVATE_KEY, ETHERSCAN_KEY, EXTRA_ARGS
DEPLOY_CMD = PRIVATE_KEY=$$PRIVATE_KEY forge script $$SCRIPT_PATH --rpc-url $$RPC_ALIAS $$VERIFY_FLAG $$BROADCAST_FLAG $${ETHERSCAN_KEY:+--etherscan-api-key $$ETHERSCAN_KEY} $${PRIVATE_KEY:+--private-key $$PRIVATE_KEY} -vvv $$EXTRA_ARGS

.PHONY: common-deploy
common-deploy:
	@set -e; \
	if [ -f .env ]; then set -a; . ./.env; set +a; fi; \
	SCRIPTS="$$(ls -1 script/Deploy*.s.sol 2>/dev/null || true)"; \
	if [ -z "$$SCRIPTS" ]; then echo "No deploy scripts found under script/Deploy*.s.sol"; exit 1; fi; \
	AVAILABLE="$$(printf "%s\n" "$$SCRIPTS" | sed -E 's#^script/Deploy(.*)\\.s\\.sol#\\1#')"; \
	DEFAULT_SCRIPT="$$(printf "%s" "$$AVAILABLE" | head -n1)"; \
	echo "Available deploy scripts:"; \
	i=1; printf "%s\n" "$$AVAILABLE" | while read n; do echo "  $$i) $$n"; i=$$((i+1)); done; \
	printf "Select script name or number (default: %s): " "$$DEFAULT_SCRIPT"; read script_choice; \
	case "$$script_choice" in \
		[0-9]*) pick=$$(printf "%s" "$$AVAILABLE" | sed -n "$$script_choice"p);; \
		*) pick="$$script_choice";; \
	esac; \
	if printf "%s\n" "$$AVAILABLE" | grep -qx "$$pick"; then \
		SCRIPT_PATH="$$(printf "%s\n" "$$SCRIPTS" | sed -n "$$(printf "%s\n" "$$AVAILABLE" | grep -n "^$$pick$$" | cut -d: -f1)p")"; \
		SCRIPT_NAME="$$pick"; \
	else \
		SCRIPT_PATH="script/Deploy$$DEFAULT_SCRIPT.s.sol"; \
		SCRIPT_NAME="$$DEFAULT_SCRIPT"; \
	fi; \
	DEFAULT_VERIFY=y; DEFAULT_BROADCAST=y; \
	RPCS="$$(grep -A 10 '\[rpc_endpoints\]' foundry.toml | grep '=' | cut -d'=' -f1 | tr -d ' ' | sort -u)"; \
	if [ -z "$$RPCS" ]; then echo "No rpc_endpoints found in foundry.toml"; exit 1; fi; \
	DEFAULT_RPC=$$( \
		if [ -n "$$DEFAULT_RPC_ALIAS" ] && printf "%s\n" "$$RPCS" | grep -qx "$$DEFAULT_RPC_ALIAS"; then \
			echo "$$DEFAULT_RPC_ALIAS"; \
		elif printf "%s\n" "$$RPCS" | grep -qx base-sepolia; then \
			echo base-sepolia; \
		else \
			printf "%s\n" "$$RPCS" | head -n1; \
		fi \
	); \
	echo "Available RPC aliases from foundry.toml:"; \
	i=1; printf "%s\n" "$$RPCS" | while read n; do echo "  $$i) $$n"; i=$$((i+1)); done; \
	printf "Select RPC alias (name or number, default: %s): " "$$DEFAULT_RPC"; read RPC_CH; \
	case "$$RPC_CH" in \
		[0-9]*) pick=$$(printf "%s\n" "$$RPCS" | sed -n "$$RPC_CH"p);; \
		"") pick="$$DEFAULT_RPC";; \
		*) pick="$$RPC_CH";; \
	esac; \
	if ! printf "%s\n" "$$RPCS" | grep -qx "$$pick"; then echo "Invalid RPC alias: $$pick"; exit 1; fi; \
	RPC_ALIAS="$$pick"; \
	printf "Is this a mainnet? [y/n] (default: n): "; read IS_MAINNET_CH; IS_MAINNET_CH=$${IS_MAINNET_CH:-n}; \
	case "$$IS_MAINNET_CH" in y|Y) IS_MAINNET=true ;; n|N) IS_MAINNET=false ;; *) echo "Invalid choice for mainnet: $$IS_MAINNET_CH"; exit 1;; esac; \
	printf "Verify on explorer? [y/n] (default: %s): " "$$DEFAULT_VERIFY"; read VERIFY_CH; VERIFY_CH=$${VERIFY_CH:-$$DEFAULT_VERIFY}; \
	case "$$VERIFY_CH" in y|Y) VERIFY_FLAG=--verify ;; n|N) VERIFY_FLAG= ;; *) echo "Invalid choice for verify: $$VERIFY_CH"; exit 1;; esac; \
	printf "Broadcast transaction? [y/n] (default: %s): " "$$DEFAULT_BROADCAST"; read BROADCAST_CH; BROADCAST_CH=$${BROADCAST_CH:-$$DEFAULT_BROADCAST}; \
	case "$$BROADCAST_CH" in y|Y) BROADCAST_FLAG=--broadcast ;; n|N) BROADCAST_FLAG= ;; *) echo "Invalid choice for broadcast: $$BROADCAST_CH"; exit 1;; esac; \
	if [ "$$IS_MAINNET" = true ]; then PRIVATE_KEY=$${MAINNET_PRIVATE_KEY:-}; else PRIVATE_KEY=$${TESTNET_PRIVATE_KEY:-}; fi; \
	if [ -z "$$PRIVATE_KEY" ]; then printf "Enter private key (hex, no 0x) or leave empty to use default account: "; read PRIVATE_KEY; fi; \
	ETHERSCAN_KEY=$${ETHERSCAN_KEY:-}; \
	if [ -n "$$VERIFY_FLAG" ] && [ -z "$$ETHERSCAN_KEY" ]; then printf "ETHERSCAN_KEY not set. Enter key to enable verify (or leave empty to skip verify): "; read ETHERSCAN_KEY; [ -z "$$ETHERSCAN_KEY" ] && VERIFY_FLAG=""; fi; \
	echo "Deploying $$SCRIPT_NAME to $$RPC_ALIAS"; \
	SCRIPT_PATH="$$SCRIPT_PATH" SCRIPT_NAME="$$SCRIPT_NAME" RPC_ALIAS="$$RPC_ALIAS" VERIFY_FLAG="$$VERIFY_FLAG" BROADCAST_FLAG="$$BROADCAST_FLAG" PRIVATE_KEY="$$PRIVATE_KEY" ETHERSCAN_KEY="$$ETHERSCAN_KEY" EXTRA_ARGS="$$EXTRA_ARGS" $(DEPLOY_CMD)


