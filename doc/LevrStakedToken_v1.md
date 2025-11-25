# LevrStakedToken_v1

## Glossary

- **sToken**: Short for "Staked Token".
- **Receipt Token**: A token that proves you deposited something else.
- **Non-Transferable**: A token that cannot be sent from Alice to Bob.

## Overview

`LevrStakedToken_v1` is the receipt you get when you stake. If you stake CLANKER, you get sCLANKER. It is an ERC20 token, so you can see it in your wallet, but it has special restrictions.

## Architecture

- **Implementation**: `LevrStakedToken_v1.sol`
- **Inheritance**: `ERC20`.
- **Deployment Pattern**: EIP-1167 clone with `initialize(...)`.

## Complex Logic Explained

### 1. Clone Initialization

Levr deploys a single implementation at factory bootstrap time, then clones it per project.

- `initialize(name, symbol, decimals, underlying, staking)` wires metadata and staking authority.
- Only `LevrFactory_v1` can call `initialize` (`OnlyFactory` guard prevents frontrunning).
- Calls are one-shot thanks to the `AlreadyInitialized` guard.
- `name()` / `symbol()` are overridden to read from clone-specific storage so every project gets unique branding (e.g., "Levr Staked CLANKER").

### 2. Why Non-Transferable?

**Concept**: In normal DeFi, you can trade your receipt tokens (like aLP tokens). In Levr, you cannot.
**Reasoning**:

- **Voting Power Integrity**: Voting power in Levr is based on _Time Held_. If Alice holds for 1 year and then transfers to Bob, should Bob get 1 year of credit? No. Should the timer reset? Yes.
- **Complexity**: Tracking time-weighting across transfers is extremely complex and prone to exploits.
- **Solution**: We disable transfers.
  - `mint`: Allowed (only by Staking contract).
  - `burn`: Allowed (only by Staking contract).
  - `transfer`: **REVERTS**.
- To move your stake, you must Unstake (burn) and then someone else must Stake (mint). This correctly resets the time timer.

## API Reference

### Functions

- `initialize(name, symbol, decimals, underlying, staking)`: One-time wiring for each clone (factory only).
- `mint(to, amount)`: Only callable by Staking contract.
- `burn(from, amount)`: Only callable by Staking contract.
- `_update`: Overridden to enforce the "No Transfer" rule.

## Errors

- `CannotModifyUnderlying`: You tried to transfer the token.
- `OnlyStaking`: Mint/Burn caller was not the staking contract.
- `OnlyFactory`: A non-factory address attempted to initialize the clone.
- `ZeroAddress`: Initialization received an empty address.
- `AlreadyInitialized`: Attempted to initialize a clone twice.
