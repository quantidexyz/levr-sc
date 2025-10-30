# Staking Design Change: Remove Auto-Claim on Unstake - Oct 29, 2025

## Summary

**Changed unstake behavior from auto-claim to manual-claim design**

This fixes the critical bug where users could claim unvested rewards they didn't earn.

## Design Changes

### OLD Design (Before):
```solidity
function unstake(amount, to) {
    _settleAll(staker, to, bal);  // ← AUTO-CLAIMS all pending rewards
    // burn tokens, transfer underlying
    _updateDebtAll(staker, remainingBalance);
}
```

### NEW Design (After):
```solidity
function unstake(amount, to) {
    // NO auto-claim - just withdraw tokens
    // burn tokens, transfer underlying
    _updateDebtAll(staker, remainingBalance);  // Freeze rewards at current level
}
```

## Key Changes

### 1. Unstake - Removed Auto-Claim
- **Before**: `unstake()` called `_settleAll()` which auto-claimed all rewards
- **After**: `unstake()` just withdraws tokens, rewards stay tracked
- **Effect**: Simpler, cheaper gas, no unexpected reward claims

### 2. Rewards Tracking
- **Staked users**: Earn rewards (balance > 0, accPerShare increases)
- **Unstaked users**: Rewards frozen (balance = 0, no new accumulation)
- **Formula**: `pending = (balance * accPerShare) - debt`
  - If balance = 0 → pending = 0 (no accumulation)
  - Debt stays fixed until user claims or stakes again

### 3. Claim Anytime
- Users can call `claimRewards()` whether staked or unstaked
- Claims their accumulated rewards based on time they WERE staked

### 4. Fix for Unvested Rewards Bug
- Added check in `_settleStreamingForToken()`:
```solidity
// If stream ended and last update is before end, don't vest the gap
if (block.timestamp > end && last < end) {
    return;  // Don't vest - rewards preserved for next accrual
}
```

- Added check in `claimableRewards()` VIEW:
```solidity
// Only calculate pending for ACTIVE streams
if (block.timestamp < end) {
    // calculate pending...
}
```

## Impact on User Flow

### Scenario: Stake → Earn → Unstake → Claim

**OLD Flow:**
```
1. Stake 100 tokens
2. Earn 10 tokens rewards
3. Unstake 100 → AUTO-CLAIMS 10 tokens
4. User has 110 tokens total
```

**NEW Flow:**
```
1. Stake 100 tokens
2. Earn 10 tokens rewards  
3. Unstake 100 → NO auto-claim
4. User has 100 tokens, 10 rewards pending
5. Claim rewards → receives 10 tokens
6. User has 110 tokens total
```

## Bug Fixed

### The Critical Bug:
1. User staked, earned rewards
2. User unstaked (rewards frozen at X)
3. Stream ended while user unstaked
4. **BUG**: User could stake again and claim unvested rewards
5. **FIX**: Now they can't - unvested rewards preserved for next accrual

### Test Proof:
```
BEFORE FIX:
  Claimed: 226 mWETH (unvested rewards - WRONG!)

AFTER FIX:
  Claimed: 0 mWETH (correct - they weren't staked!)
```

## Test Updates Needed

~30 tests need updating because they expect old auto-claim behavior:
- Tests that check balances immediately after unstake
- Tests that expect rewards in user wallet after unstake
- Tests need to add explicit `claimRewards()` call

## Benefits

✅ **Simpler logic** - no auto-claim complexity  
✅ **Safer** - prevents unvested reward exploits  
✅ **Lower gas** - unstake is cheaper  
✅ **Flexible** - users choose when to claim  
✅ **Clear** - stake/unstake vs claim are separate actions  

## Migration Note

**Smart Contract**: Breaking change - unstake no longer claims
**Frontend**: Must update to show "Claim" button separately from "Unstake"
**Users**: Need to manually claim after unstaking (won't happen automatically)

