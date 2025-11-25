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

Levr uses EIP-1167 Clones for **all** per-project components to save gas and keep deterministic bytecode.

- **Treasury**: Cloned from a single implementation bound to the factory.
- **Staking**: Cloned and initialized with reward whitelist + treasury wiring.
- **Governor**: Cloned and initialized with references to treasury/staking/stToken.
- **Staked Token**: _Now cloned as well_. Each clone calls `initialize(...)` to set dynamic metadata (name/symbol/decimals) plus the staking authority. This keeps block explorer verification simple (one implementation) while still giving each project branded ERC20 metadata.
- Every clone enforces an `OnlyFactory` guard on `initialize` so attackers cannot frontrun setup.

## API Reference

### Functions

- `prepareContracts()`: Deploys Treasury and Staking clones (deterministic addresses ahead of time). Step 1 of deployment.
- `deployProject(...)`: Deploys (clones) Governor + StakedToken, initializes everything, and wires reward whitelist. Step 2.

### Events

- `ProjectDeployed`: Emitted when the full suite is ready.

## Errors

- `UnauthorizedFactory`: You tried to call this contract directly, but you aren't the Factory.
