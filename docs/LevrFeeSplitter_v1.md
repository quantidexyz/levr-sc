# LevrFeeSplitter_v1

## Glossary

*   **Split**: A rule saying "X% of fees go to Address Y".
*   **BPS (Basis Points)**: A unit of measure where 10000 = 100%. 1 BPS = 0.01%.
*   **Dust**: Tiny amounts of tokens left over from math rounding errors.
*   **Reward Token**: Any ERC20 token that accumulates in this contract (fees).

## Overview
`LevrFeeSplitter_v1` handles the income. When a project generates fees (e.g., from trading), they are sent here. This contract's job is to divvy up that money and send it to the right places (e.g., 50% to Stakers, 50% to the Dev Team).

## Architecture
- **Implementation**: `LevrFeeSplitter_v1.sol`
- **Inheritance**: `ERC2771ContextBase`, `ReentrancyGuard`.

## Complex Logic Explained

### 1. Permissionless Distribution
**Concept**: We don't want to rely on a centralized bot to hand out money.
**Logic**: `distribute(tokenAddress)` is public.
- Anyone can call it.
- When called, it checks the contract's balance of `tokenAddress`.
- It calculates the payouts based on the configured splits.
- It sends the tokens immediately.
- **Result**: If you are waiting for your fees, you can just click "Distribute" yourself. You don't have to wait for us.

### 2. Staking Integration (Auto-Accrual)
**Concept**: If one of the recipients is the Staking contract, we can't just send tokens there. The Staking contract needs to *know* rewards arrived so it can start the streaming process.
**Logic**:
- The contract checks if a receiver address matches the `staking` address.
- If it does, after transferring the tokens, it attempts to call `staking.accrueRewards(token)`.
- **Graceful Failure**: If this call fails (e.g., gas issues), the transaction *does not revert*. The tokens are still transferred. Someone else can call `accrueRewards` on the staking contract manually later.

### 3. Dust Recovery
**Problem**: Division isn't always perfect. `100 / 3 = 33`. `33 * 3 = 99`. Where did the 1 go?
**Solution**:
- Over time, tiny amounts of "dust" might accumulate in the contract.
- The `recoverDust` function allows the admin to sweep these leftovers.
- **Safety**: It sweeps *everything* in the contract. It assumes that if `distribute` was called, the main bulk of funds is already gone. Use with care.

## API Reference

### Functions
- `configureSplits(SplitConfig[] splits)`: Admin sets the rules. (Total must be 100%).
- `distribute(address token)`: Triggers payout.
- `recoverDust(address token, address to)`: Sweeps leftovers.

## Events
- `SplitsConfigured`: Rules changed.
- `FeeDistributed`: Money moved.
- `AutoAccrualSuccess`: Staking contract was notified successfully.

## Errors
- `InvalidTotalBps`: Splits didn't add up to 100%.
- `DuplicateReceiver`: You listed the same person twice.
