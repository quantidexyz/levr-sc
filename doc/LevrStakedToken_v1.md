# LevrStakedToken_v1

## Glossary

*   **sToken**: Short for "Staked Token".
*   **Receipt Token**: A token that proves you deposited something else.
*   **Non-Transferable**: A token that cannot be sent from Alice to Bob.

## Overview
`LevrStakedToken_v1` is the receipt you get when you stake. If you stake CLANKER, you get sCLANKER. It is an ERC20 token, so you can see it in your wallet, but it has special restrictions.

## Architecture
- **Implementation**: `LevrStakedToken_v1.sol`
- **Inheritance**: `ERC20`.

## Complex Logic Explained

### 1. Why Non-Transferable?
**Concept**: In normal DeFi, you can trade your receipt tokens (like aLP tokens). In Levr, you cannot.
**Reasoning**:
- **Voting Power Integrity**: Voting power in Levr is based on *Time Held*. If Alice holds for 1 year and then transfers to Bob, should Bob get 1 year of credit? No. Should the timer reset? Yes.
- **Complexity**: Tracking time-weighting across transfers is extremely complex and prone to exploits.
- **Solution**: We disable transfers.
    - `mint`: Allowed (only by Staking contract).
    - `burn`: Allowed (only by Staking contract).
    - `transfer`: **REVERTS**.
- To move your stake, you must Unstake (burn) and then someone else must Stake (mint). This correctly resets the time timer.

## API Reference

### Functions
- `mint(to, amount)`: Only callable by Staking contract.
- `burn(from, amount)`: Only callable by Staking contract.
- `_update`: Overridden to enforce the "No Transfer" rule.

## Errors
- `CannotModifyUnderlying`: You tried to transfer the token.
