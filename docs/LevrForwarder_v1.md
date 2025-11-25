# LevrForwarder_v1

## Glossary

- **Meta-Transaction**: A transaction signed by User A but submitted to the blockchain by Relayer B. User A doesn't need ETH for gas; Relayer B pays it.
- **ERC-2771**: A standard for secure meta-transactions. The Forwarder verifies the signature and appends the signer's address to the data. The target contract reads this appended address to know who the "real" caller is.
- **Multicall**: Executing multiple distinct function calls in a single Ethereum transaction.

## Overview

`LevrForwarder_v1` is a utility belt. It combines a standard Meta-Transaction Forwarder (allowing gasless txs) with a Multicall feature (batching txs). This makes the user experience smoother and cheaper.

## Architecture

- **Implementation**: `LevrForwarder_v1.sol`
- **Inheritance**: `ERC2771Forwarder` (OpenZeppelin), `ReentrancyGuard`.

## Complex Logic Explained

### 1. Dual-Mode Multicall

The `executeMulticall` function is unique because it handles two types of calls mixed together:

1.  **External Calls (ERC-2771)**:
    - "I want to call the Staking contract."
    - The Forwarder appends the user's address to the calldata.
    - The Staking contract (which is ERC-2771 aware) decodes this and knows it was _you_.

2.  **Self Calls (Direct)**:
    - "I want to call `approve` on a random USDT token."
    - USDT is _not_ ERC-2771 aware. If we append your address, the call might fail or be ignored.
    - Instead, we use `executeTransaction`. This executes a "raw" call without appending data.
    - This allows the Forwarder to interact with legacy contracts.
    - **Security Note**: `executeTransaction` CANNOT be used on contracts that trust the Forwarder. This prevents spoofing attacks where an attacker could bypass the sender verification.

### 2. Value Integrity Check

**Problem**: A user sends 1 ETH with the transaction, but the batched calls try to spend 2 ETH total.
**Solution**:

- The contract sums up the `value` field of every call in the batch.
- It compares this sum to `msg.value`.
- If they don't match exactly, it reverts. This prevents funds from getting stuck or calls failing due to lack of funds.

### 3. Asset Recovery

The Forwarder is not designed to hold funds, but users might accidentally send tokens to it.

- `withdrawTrappedETH()`: Recover ETH.
- `withdrawTrappedTokens(token, amount)`: Recover ERC20 tokens.
- Both are protected by `OnlyDeployer`.

## API Reference

### Functions

- `executeMulticall(SingleCall[] calls)`: The main entry point. Batches calls.
- `executeTransaction(...)`: Helper for raw calls. Can _only_ be called by the Forwarder itself (during a multicall). Reverts if target trusts the forwarder.
- `withdrawTrappedETH()`: Recover ETH (Deployer only).
- `withdrawTrappedTokens(token, amount)`: Recover tokens (Deployer only).

## Errors

- `ValueMismatch`: You sent the wrong amount of ETH.
- `OnlyMulticallCanExecuteTransaction`: You tried to call the internal helper directly.
- `TargetTrustsForwarder`: Attempted to use `executeTransaction` on a trusted target (spoofing prevention).
- `OnlyDeployer`: Unauthorized access to recovery functions.
