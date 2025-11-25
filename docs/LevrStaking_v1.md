# LevrStaking_v1

## Glossary

- **Underlying Token**: The original token users deposit (e.g., CLANKER).
- **Staked Token (sToken)**: A non-transferable receipt token users get when they stake (e.g., sCLANKER).
- **Voting Power (VP)**: A measure of governance influence calculated as `Balance * Time`.
- **Streaming Rewards**: A mechanism where deposited rewards are released gradually over time (e.g., 7 days) instead of instantly.
- **Vesting**: The process of rewards becoming claimable.
- **Escrow**: The contract holding the Underlying tokens.
- **Protocol Fee**: A small fee taken by the Levr protocol on deposits/withdrawals.

## Overview

`LevrStaking_v1` is the heart of the user interaction. Users deposit tokens here to earn rewards and gain governance rights. It uses a sophisticated multi-token reward system with streaming to ensure sustainable APYs and prevent gaming.

## Architecture

- **Implementation**: `LevrStaking_v1.sol`
- **Interface**: `ILevrStaking_v1.sol`
- **Inheritance**: `ERC2771ContextBase`, `ReentrancyGuard`.
- **Dependencies**:
  - `LevrStakedToken_v1`: Minted to users as a receipt.
  - `RewardMath`: Handles the complex vesting math.

## Complex Logic Explained

### 1. Voting Power Calculation (Time-Weighted)

**Concept**: We want long-term holders to have more power than short-term speculators.
**Formula**: `VP = (Balance * Time_Staked) / CONSTANT`
**The Challenge**: How do we track "Time Staked" if a user adds more tokens later?
**The Solution (Weighted Average Timestamp)**:

- When you stake for the first time, your `stakeStartTime` is `now`.
- If you add more tokens later, we don't just reset `stakeStartTime` to `now` (that would punish you).
- Instead, we calculate a new, artificial start time that preserves your _existing_ accumulated time-weight but applies it to the _new, larger_ balance.
  - _Example_: You held 10 tokens for 10 days (100 token-days). You add 10 tokens. You now have 20 tokens. To keep your "credit" of 100 token-days, your effective time held must be 5 days (20 \* 5 = 100). So we set your start time to "5 days ago".

### 2. Streaming Rewards (Accrual & Reset)

**Problem**: If someone dumps 1,000 USDC in rewards into the pool, and we distribute it instantly, a whale could buy huge amounts of the token, claim the rewards, and dump the token immediately ("Snipe and Dump").
**Solution**:

- **Initial Accrual**: When rewards are added (via `accrueRewards`), they are added to a "Stream". The stream releases tokens linearly over a configurable window (e.g., 7 days). `Rate = Total_Rewards / 7_Days`.
- **Re-Accrual (Stream Extension)**: What happens if we add _more_ rewards while a stream is already active?
  1.  **Settle**: We calculate how many rewards from the _old_ stream have already vested (become claimable) up to `now`. We move these to the `availablePool`.
  2.  **Combine**: We take the _remaining_ unvested rewards from the old stream and add the _newly accrued_ rewards.
  3.  **Reset Window**: We start a **fresh 7-day window** for this combined total.
  - _Effect_: This extends the payout period for the old unvested rewards, smoothing out the APY and preventing spikes. It ensures that a large injection of rewards is always distributed over a full window from the moment it arrives.

### 3. Reward Debt (MasterChef Pattern)

**Concept**: Tracking how much every single user has earned every second is impossible (gas costs would be infinite).
**Solution**:

- We track a global variable: `accRewardPerShare` (Accumulated Rewards Per Share). This number only goes up. It represents "how many rewards would 1 token have earned since the beginning of time".
- When you stake, we calculate your `rewardDebt`: `MyBalance * accRewardPerShare`. This is the amount of rewards that _happened before you got here_.
- When you claim, your earnings are: `(MyBalance * accRewardPerShare) - rewardDebt`.
- Effectively: "Total earnings possible" minus "Earnings I missed because I wasn't here yet".

### 4. Handling Fee-on-Transfer Tokens

**Problem**: Some tokens burn 1% when you transfer them. If a user sends 100, the contract only gets 99. If we credit 100, the contract becomes insolvent.
**Solution**:

- We check `balanceOf(this)` _before_ the transfer.
- We transfer.
- We check `balanceOf(this)` _after_ the transfer.
- The difference is the `actualReceived` amount, and that is what we credit.

## API Reference

### Functions

#### User Actions

- `stake(uint256 amount)`: Deposit Underlying. Mints sTokens. Updates VP.
- `unstake(uint256 amount, address to)`: Burn sTokens. Returns Underlying.
- `claimRewards(address[] tokens, address to)`: Harvest earned rewards.

#### Reward Management

- `accrueRewards(address token)`: Permissionless. Tells the contract "Hey, I sent you tokens, please start streaming them to stakers."
- `whitelistToken(address token)`: Admin. Allows a new token to be used for rewards.

#### Views

- `getVotingPower(address user)`: Your current governance influence.
- `claimableRewards(...)`: Pending rewards.
- `aprBps()`: Current estimated yield.

## Events

- `Staked`, `Unstaked`, `RewardsClaimed`, `RewardsAccrued` (new stream started), `StreamReset`.

## Errors

- `InsufficientStake`: You don't have the tokens you're trying to withdraw.
- `RewardTooSmall`: We enforce a minimum reward amount to prevent dust attacks on the streaming logic.
