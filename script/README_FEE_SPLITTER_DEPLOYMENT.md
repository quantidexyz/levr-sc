# LevrFeeSplitter_v1 Deployment Guide

## Overview

The `LevrFeeSplitter_v1` is a **singleton contract** that manages fee distribution for all Clanker projects. It should be deployed **once per network** after the LevrFactory_v1 is deployed.

## Prerequisites

Before deploying the fee splitter, ensure:

1. ✅ **LevrFactory_v1 is deployed** - The factory must exist and be verified
2. ✅ **You have the factory address** - Note the deployed factory address
3. ✅ **Deployment wallet is funded** - Minimum 0.05 ETH for gas
4. ✅ **Private key is in .env** - Set `MAINNET_PRIVATE_KEY` or `TESTNET_PRIVATE_KEY`

## Environment Setup

### Required Variables

Add to your `.env` file:

```bash
# Network-specific private keys
MAINNET_PRIVATE_KEY=0x... # For Base mainnet
TESTNET_PRIVATE_KEY=0x... # For Base Sepolia

# Required: Factory address
FACTORY_ADDRESS=0x... # Deployed LevrFactory_v1 address
```

### Optional Variables

```bash
# Optional: Override trusted forwarder (auto-detected from factory if not set)
TRUSTED_FORWARDER=0x...

# Optional: Etherscan verification
ETHERSCAN_KEY=...
```

### Example .env

```bash
# Private keys
MAINNET_PRIVATE_KEY=0xabcdef1234567890...
TESTNET_PRIVATE_KEY=0x1234567890abcdef...

# Factory address (from previous LevrFactory deployment)
FACTORY_ADDRESS=0x5FbDB2315678afecb367f032d93F642f64180aa3

# Optional - Etherscan verification
ETHERSCAN_KEY=ABC123XYZ456
```

## Deployment Methods

### Method 1: Using Forge Script (Recommended)

#### Dry Run (Simulation)

First, simulate the deployment to verify everything is configured correctly:

```bash
# Set up environment
source .env

# Simulate on Base Sepolia testnet
forge script script/DeployLevrFeeSplitter.s.sol \
  --rpc-url base-sepolia \
  -vvvv

# Simulate on Base mainnet
forge script script/DeployLevrFeeSplitter.s.sol \
  --rpc-url base-mainnet \
  -vvvv
```

**Expected Output:**

```
=== LEVR FEE SPLITTER V1 DEPLOYMENT ===
Network Chain ID: 84532
Deployer Address: 0x...
Deployer Balance: 1.0 ETH

=== PRE-DEPLOYMENT VALIDATION ===
Network: Base Sepolia

[OK] Deployer has sufficient ETH balance
[OK] Factory address is a valid contract: 0x...
[OK] Trusted forwarder queried from factory: 0x...
[OK] Trusted forwarder is a valid contract

=== DEPLOYMENT CONFIGURATION ===
Factory Address: 0x...
Trusted Forwarder: 0x...
Deployer: 0x...

Fee Splitter Details:
- Type: Singleton (manages all projects)
- Access Control: Per-project (token admin only)
- Distribution: Permissionless (anyone can trigger)
- Meta-transactions: Enabled (via trusted forwarder)

=== STARTING DEPLOYMENT ===

Deploying LevrFeeSplitter_v1...
- Fee Splitter deployed at: 0x...

=== DEPLOYMENT VERIFICATION ===
[OK] Factory address verified: 0x...
[OK] Basic functionality test passed
[OK] All deployment checks passed!

=== DEPLOYMENT SUCCESSFUL ===
```

#### Live Deployment

Once the dry run looks good, deploy for real:

```bash
# Deploy to Base Sepolia testnet
forge script script/DeployLevrFeeSplitter.s.sol \
  --rpc-url base-sepolia \
  --broadcast \
  --verify \
  -vvvv

# Deploy to Base mainnet
forge script script/DeployLevrFeeSplitter.s.sol \
  --rpc-url base-mainnet \
  --broadcast \
  --verify \
  -vvvv
```

**Flags:**

- `--broadcast`: Actually send the transactions
- `--verify`: Automatically verify on Etherscan
- `-vvvv`: Verbose output for debugging

### Method 2: Using Common.mk Menu

If the fee splitter is added to `common.mk`:

```bash
make deploy
```

Then select "LevrFeeSplitter" from the interactive menu.

## Post-Deployment Verification

### 1. Verify Deployment

Check that the contract was deployed correctly:

```bash
# Get deployment info
FACTORY_ADDRESS=0x...  # Your factory address
SPLITTER_ADDRESS=0x... # Deployed splitter address

# Verify factory is set correctly
cast call $SPLITTER_ADDRESS "factory()(address)" --rpc-url base-sepolia

# Should return your FACTORY_ADDRESS
```

### 2. Test Basic Functionality

```bash
# Test with a random token (should return false)
cast call $SPLITTER_ADDRESS \
  "isSplitsConfigured(address)(bool)" \
  0x1234567890123456789012345678901234567890 \
  --rpc-url base-sepolia

# Should return: false
```

### 3. Verify on Block Explorer

Visit Etherscan to confirm:

- **Base Mainnet**: https://basescan.org/address/[SPLITTER_ADDRESS]
- **Base Sepolia**: https://sepolia.basescan.org/address/[SPLITTER_ADDRESS]

Check:

- ✅ Contract is verified
- ✅ Constructor args match (factory, trustedForwarder)
- ✅ No errors in deployment transaction

## Network-Specific Addresses

### Base Mainnet (Chain ID: 8453)

After deployment, note these addresses:

```
Factory: 0x...
Forwarder: 0x...
Fee Splitter: 0x...  # ← Your deployed singleton
```

### Base Sepolia (Chain ID: 84532)

After deployment, note these addresses:

```
Factory: 0x...
Forwarder: 0x...
Fee Splitter: 0x...  # ← Your deployed singleton
```

## Integration After Deployment

### 1. Update Frontend Configuration

Add to your frontend `.env`:

```bash
NEXT_PUBLIC_FEE_SPLITTER_ADDRESS=0x...
```

### 2. Document for Token Admins

Provide instructions for projects to:

**Configure Splits:**

```solidity
// Example: 50% staking, 30% team, 20% DAO
SplitConfig[] memory splits = new SplitConfig[](3);
splits[0] = SplitConfig({receiver: stakingAddress, bps: 5000});
splits[1] = SplitConfig({receiver: teamWallet, bps: 3000});
splits[2] = SplitConfig({receiver: daoTreasury, bps: 2000});

feeSplitter.configureSplits(clankerToken, splits);
```

**Update Reward Recipient:**

```solidity
IClankerLpLockerMultiple(lpLocker).updateRewardRecipient(
    clankerToken,
    0, // Primary reward index
    address(feeSplitter)
);
```

### 3. Add Distribution Triggers

In your app, add UI for:

- Viewing pending fees: `feeSplitter.pendingFees(clankerToken, rewardToken)`
- Triggering distribution: `feeSplitter.distribute(clankerToken, rewardToken)`
- Batch distribution: `feeSplitter.distributeBatch(clankerToken, [WETH, token])`

## Troubleshooting

### Error: "FACTORY_ADDRESS environment variable required"

**Solution:** Add `FACTORY_ADDRESS=0x...` to your `.env` file

### Error: "Factory address is not a contract"

**Solution:**

- Verify you're on the correct network
- Check that the factory address is correct
- Ensure the factory is actually deployed on this network

### Error: "Failed to query trusted forwarder from factory"

**Solution:**

- Verify the factory address is correct
- Try providing `TRUSTED_FORWARDER` explicitly in `.env`
- Check that the factory is the correct contract (implements `trustedForwarder()`)

### Error: "Insufficient deployer balance"

**Solution:** Fund your deployment wallet with at least 0.05 ETH

### Deployment succeeds but verification fails

**Solution:** Manually verify on Etherscan:

```bash
forge verify-contract \
  --chain-id 84532 \
  --constructor-args $(cast abi-encode "constructor(address,address)" $FACTORY_ADDRESS $FORWARDER_ADDRESS) \
  $SPLITTER_ADDRESS \
  src/LevrFeeSplitter_v1.sol:LevrFeeSplitter_v1 \
  --etherscan-api-key $ETHERSCAN_KEY
```

## Gas Estimates

Typical deployment costs:

- **Base Sepolia**: ~0.001 ETH (very cheap)
- **Base Mainnet**: ~0.001-0.005 ETH (depending on gas prices)

## Security Checklist

Before deploying to mainnet:

- [ ] Factory address is verified on Etherscan
- [ ] Deployment wallet is secure (hardware wallet recommended)
- [ ] Dry run completed successfully
- [ ] All tests pass (`forge test`)
- [ ] Code is audited (if applicable)
- [ ] Team has reviewed deployment parameters

## Example Deployment Session

```bash
# 1. Set up environment
cd contracts/
source .env

# 2. Verify factory exists
echo "Factory address: $FACTORY_ADDRESS"
cast code $FACTORY_ADDRESS --rpc-url base-sepolia | head -1

# 3. Dry run
forge script script/DeployLevrFeeSplitter.s.sol \
  --rpc-url base-sepolia \
  -vvvv

# 4. Review output, verify all checks pass

# 5. Deploy for real
forge script script/DeployLevrFeeSplitter.s.sol \
  --rpc-url base-sepolia \
  --broadcast \
  --verify \
  -vvvv

# 6. Note the deployed address
# Output: Fee Splitter deployed at: 0x123...

# 7. Save to environment
echo "NEXT_PUBLIC_FEE_SPLITTER_ADDRESS=0x123..." >> ../.env

# 8. Verify on Etherscan
open "https://sepolia.basescan.org/address/0x123..."

# Done!
```

## Next Steps

After successful deployment:

1. ✅ Verify contract on block explorer
2. ✅ Update frontend configuration
3. ✅ Document the address in project README
4. ✅ Test with a sample project
5. ✅ Provide integration guide to token admins
6. ✅ Set up monitoring for the singleton

## Support

For issues or questions:

- Review the [Fee Splitter Specification](../specs/fee-splitter.md)
- Check test examples in `test/e2e/LevrV1.FeeSplitter.t.sol`
- Open an issue on GitHub
