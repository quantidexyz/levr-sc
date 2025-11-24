# LevrDeployer_v1

## Glossary

- **Clones (EIP-1167)**: Minimal Proxy Contracts. Small, cheap contracts that forward all calls to a "Master" implementation.
- **Implementation Contract**: The "Master" contract that holds the logic for all clones.
- **Authorized Factory**: The only address allowed to call this deployer.

## Overview

`LevrDeployer_v1` is the "Hands" of the factory. While the Factory (`LevrFactory_v1`) makes the decisions, the Deployer does the heavy lifting of actually creating the contracts. It is designed to be invisible, working behind the scenes via `delegatecall`.

## Architecture

- **Implementation**: `LevrDeployer_v1.sol`
- **Inheritance**: `ILevrDeployer_v1`.

## Complex Logic Explained

### 1. Why Delegatecall?

The Deployer is not meant to be used directly. It is designed to have its code "borrowed" by the Factory.

- When the Factory calls `deployProject`, it uses `delegatecall`.
- This means the `msg.sender` remains the user (or the Factory context), and the _storage_ being written to is the Factory's storage (though this specific deployer mostly returns values rather than writing complex storage).
- **Benefit**: This separates code responsibilities. The Factory handles registry/config, the Deployer handles instantiation.

### 2. Cloning Strategy

Levr uses EIP-1167 Clones for most components to save gas.

- **Treasury**: Cloned. (Logic is identical for everyone).
- **Staking**: Cloned. (Logic is identical for everyone).
- **Governor**: Cloned. (Logic is identical for everyone).
- **Staked Token**: **NOT Cloned**.
  - _Why?_ The Staked Token is an ERC20. It needs a unique Name ("Levr Staked Clanker") and Symbol ("sCLANKER") stored in its bytecode/storage. While clones _can_ be initialized, deploying a fresh instance is cleaner for ERC20 metadata and ensures distinct contract identity on block explorers.

## API Reference

### Functions

- `prepareContracts()`: Deploys Treasury and Staking clones. Step 1 of deployment.
- `deployProject(...)`: Deploys Governor and StakedToken, and initializes everything. Step 2.

### Events

- `ProjectDeployed`: Emitted when the full suite is ready.

## Errors

- `UnauthorizedFactory`: You tried to call this contract directly, but you aren't the Factory.
