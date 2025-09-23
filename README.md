## Foundry

**Foundry is a blazing fast, portable and modular toolkit for Ethereum application development written in Rust.**

Foundry consists of:

- **Forge**: Ethereum testing framework (like Truffle, Hardhat and DappTools).
- **Cast**: Swiss army knife for interacting with EVM smart contracts, sending transactions and getting chain data.
- **Anvil**: Local Ethereum node, akin to Ganache, Hardhat Network.
- **Chisel**: Fast, utilitarian, and verbose solidity REPL.

## Documentation

https://book.getfoundry.sh/

## Usage

### Build

```shell
$ forge build
```

### Test

```shell
$ forge test
```

### Format

```shell
$ forge fmt
```

### Gas Snapshots

```shell
$ forge snapshot
```

### Anvil

```shell
$ anvil
```

### Deploy

```shell
$ forge script script/Counter.s.sol:CounterScript --rpc-url <your_rpc_url> --private-key <your_private_key>
```

### Cast

```shell
$ cast <subcommand>
```

### Help

```shell
$ forge --help
$ anvil --help
$ cast --help
```

# InfoFi Smart Contracts

This directory contains the smart contracts for the InfoFi platform, a Web3 content rewards system that connects projects with content creators through engagement-based leaderboards.

## Overview

The MasterOven_v1 contract handles:

- Token deposits from projects creating campaigns
- 5% platform fee collection
- Time-locked airdrops to content creators based on points
- Role-based access control (Super Admin and Admins)

## Contract Architecture

### MasterOven_v1

Main contract implementing:

- **Deposit**: Projects deposit ERC20 tokens (minimum 1% of token's max supply)
- **Airdrop Execution**: Admins distribute tokens based on user points after campaign duration
- **Fee Management**: 5% platform fee sent to treasury
- **Access Control**: Super Admin (deployer) and regular admins
- **Campaign Duration**: Fixed duration set at deployment (e.g., 30 days)

### Key Features

- Minimum deposit requirement (1% of token's max supply)
- Automatic airdrop timing (deposit time + fixed duration)
- Time-locked airdrops prevent premature distribution
- Events for all major actions (indexer-friendly)
- Safe ERC20 operations using OpenZeppelin's SafeERC20

## Setup

### Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation)
- Node.js (for Bun)

### Installation

```bash
# Install dependencies
forge install

# Build contracts
forge build
```

## Testing

Run the comprehensive test suite:

```bash
# Run all tests
forge test

# Run with verbose output
forge test -vv

# Run with gas reporting
forge test --gas-report

# Run specific test
forge test --match-test test_DepositSuccessful
```

## Deployment

### Local Testing

```bash
# Start local node
anvil

# Deploy to local node
forge script script/DeployMasterOven_v1.s.sol --chain-id 31337 --broadcast
```

### Mainnet/Testnet Deployment

```bash
# Set environment variables
export RPC_URL="your_rpc_url"
export PRIVATE_KEY="your_private_key"
export TREASURY_ADDRESS="your_treasury_address"
export AIRDROP_DURATION="2592000" # 30 days in seconds (optional, defaults to 30 days)

# Deploy
forge script script/DeployInfoFiVault.s.sol --rpc-url $RPC_URL --private-key $PRIVATE_KEY --broadcast --verify

# Verify contract (if not done during deployment)
forge verify-contract <DEPLOYED_ADDRESS> MasterOven_v1 --chain-id <CHAIN_ID>
```

## Contract Interaction

### For Projects (Depositors)

1. Approve MasterOven_v1 to spend your tokens
2. Call `deposit(token, amount)` with:
   - `token`: Your ERC20 token address
   - `amount`: Total tokens to deposit (must be ≥1% of max supply)
   - Note: Airdrop will be automatically scheduled for current time + campaign duration

### For Admins

1. Wait until after the campaign duration has passed
2. Call `executeAirdrop(token, recipients)` with:
   - `token`: The campaign token address
   - `recipients`: Array of `{address, points}` for distribution

### View Functions

- `getAirdropUnix(token)`: Get airdrop timestamp for a project
- `availableProjects()`: List all projects with campaigns
- `isAdminAddress(account)`: Check admin status
- `airdropDuration()`: Get the fixed campaign duration
- `treasury()`: Get current treasury address
- `superAdmin()`: Get super admin address

## Security Considerations

1. **Access Control**: Only super admin can add/remove admins
2. **Time Locks**: Airdrops can't be executed before campaign duration expires
3. **Reentrancy Protection**: State changes before external calls
4. **Input Validation**: All inputs are validated for zero addresses and amounts
5. **Safe Math**: Solidity 0.8+ automatic overflow protection
6. **Immutable Duration**: Campaign duration is set at deployment and cannot be changed

## Gas Costs (Approximate)

- Deployment: ~1,650,000 gas
- Deposit: ~200,000 gas
- Execute Airdrop: ~30,000-90,000 gas (depends on recipients)
- Admin Operations: ~25,000-45,000 gas

## License

MIT
