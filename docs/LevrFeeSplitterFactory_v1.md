# LevrFeeSplitterFactory_v1

## Glossary

*   **CREATE2**: An opcode that allows deploying a contract to a specific address that can be calculated *before* deployment.
*   **Salt**: A random(ish) piece of data used in CREATE2 to ensure uniqueness.
*   **Deterministic Deployment**: The ability to know a contract's address before it exists.

## Overview
`LevrFeeSplitterFactory_v1` is a vending machine for Fee Splitters. Since every project needs its own Fee Splitter (to keep its money separate), this factory churns them out on demand.

## Architecture
- **Implementation**: `LevrFeeSplitterFactory_v1.sol`
- **Inheritance**: `ERC2771ContextBase`.

## Complex Logic Explained

### 1. CREATE2 vs. New
The factory offers two ways to make a splitter:
1.  `deploy`: Uses the standard `new` keyword. The address depends on the factory's nonce. Simple.
2.  `deployDeterministic`: Uses `CREATE2`. The address depends on a `salt`.
    - **Why?** Sometimes you want to tell people "Send money to address X" *before* you have actually paid the gas to deploy address X. CREATE2 allows this "counterfactual" deployment.

## API Reference

### Functions
- `deploy(token)`: Standard deployment.
- `deployDeterministic(token, salt)`: Fancy deployment.
- `computeDeterministicAddress(token, salt)`: "Crystal Ball" function to predict the address.

## Errors
- `AlreadyDeployed`: You already have a splitter for this token.
