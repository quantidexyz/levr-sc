# Reward Accounting Analysis - Complex Staking Scenario

## Summary

Created comprehensive unit tests to reproduce the UI bug scenario where "claimable rewards exceed available rewards" after unstaking all tokens and restaking.

## Test Files Created

1. `LevrStakingV1.ComplexRewardAccounting.t.sol` - Full flow test with all 11 phases
2. `LevrStakingV1.ExactBugReproduction.t.sol` - Exact scenario with realistic token amounts
3. `LevrStakingV1.AvailableVsClaimableBug.t.sol` - Focused test on the "claimable > available" issue

## Bug Found: Claimable > Available

### Reproduction Steps:

1. User stakes 1,000,000 tokens
2. Accrue 100 WETH rewards (3-day stream window)
3. Warp 1 day (1/3 of stream vested = 33 WETH claimable)
4. User unstakes ALL tokens
   - 33 WETH claimed automatically via `_settleAll()`
   - Reserve: 66 WETH remaining
   - Balance: 66 WETH remaining
5. Warp to END of stream with ZERO stakers
   - Rewards DON'T vest (totalStaked == 0)
   - Reserve: 66 WETH (unchanged)
   - Balance: 66 WETH (unchanged)
6. User restakes 1,000,000 tokens
7. **BUG APPEARS**:
   - **Available: 0 WETH** (balance - reserve = 0)
   - **Claimable: 66 WETH**
   - Claimable > Available!

### Test Output:

```
=== CRITICAL CHECK ===
  Available (UI): 0 WETH
  Claimable (UI): 66 WETH

!!! BUG FOUND: Claimable exceeds Available !!!
  Difference: 66 WETH

Diagnostics:
    Contract balance: 66
    Reserve: 66
    Balance: 66
    Claimable: 66

>>> Attempting to CLAIM <<<
  Claim SUCCEEDED
  User WETH balance: 99
```

### Key Observations:

1. **Claim succeeds** - User receives 99 WETH total (33 + 66)
2. **Unstake succeeds** - No "insufficient reward balance" error
3. **Accounting is correct** at the contract level
4. **UI shows confusing state** where "Available: 0" but "Claimable: 66"

## Root Cause Analysis

### Why Available = 0:

```solidity
function _availableUnaccountedRewards(address token) internal view returns (uint256) {
    uint256 bal = IERC20(token).balanceOf(address(this));
    // ...
    uint256 accounted = _rewardReserve[token];
    return bal > accounted ? bal - accounted : 0;
}
```

- Balance: 66 WETH
- Reserve: 66 WETH
- Available: 66 - 66 = **0**

This is correct! "Available" means "new unaccounted rewards that can be accrued".

### Why Claimable = 66:

The 66 WETH in reserve was:
1. Accrued during the initial accrual (100 WETH)
2. Partially vested (33 WETH) before user unstaked
3. NOT vested during zero-staker period (33 WETH remaining unvested)
4. Still in reserve when user restakes

When user restakes:
- Their debt is recalculated based on current accPerShare
- The unvested rewards (66 WETH) are still in the system
- User can claim them because they're the only staker

### State Dump at Key Points:

**After 1 Day (Before Unstake):**
```
Total Staked: 1,000,000
Available: 0
Claimable: 33
Reserve: 100
Balance: 100
AccPerShare: 0  <- Not yet settled!
```

**After Full Unstake:**
```
Total Staked: 0
Available: 0
Claimable: 0
Reserve: 66  <- 100 - 33 claimed
Balance: 66
AccPerShare: 0
```

**After Stream End (Zero Stakers):**
```
Total Staked: 0
Available: 0
Claimable: 0
Reserve: 66  <- Unchanged (no vesting when totalStaked=0)
Balance: 66
AccPerShare: 0
```

**After Restake:**
```
Total Staked: 1,000,000
Available: 0  <- balance == reserve
Claimable: 66  <- Can claim all remaining reserve
Reserve: 66
Balance: 66
Debt: 33  <- Why 33?
AccPerShare: 0  <- Why 0?
```

## Outstanding Questions

1. **Why is AccPerShare = 0 after restake?**
   - If stream has ended, accPerShare should reflect vested amount
   - Need to investigate `_settleStreamingForToken()` logic

2. **Why is Debt = 33 after restake?**
   - Debt should be calculated as: `(balance * accPerShare) / ACC_SCALE`
   - If accPerShare = 0, debt should be 0
   - This suggests debt is carried over from before unstake (incorrect?)

3. **How does claimableRewards() calculate 66 when accPerShare = 0?**
   - Need to check if it's adding pending streaming amounts
   - But stream has ended, so no pending should exist

## Hypothesis

The issue might be in how `claimableRewards()` view function calculates pending rewards vs how actual claiming works. The view might be showing incorrect "claimable" amount by:

1. Including unvested rewards that won't actually be vested
2. Not properly accounting for the stream being inactive (totalStaked = 0)
3. Miscalculating pending streaming when stream has ended

## Contract Behavior vs Expected Behavior

### Current Behavior:
- ✅ Claims succeed
- ✅ Unstakes succeed  
- ✅ No funds are stuck
- ❌ UI shows "Available: 0" but "Claimable: 66" (confusing)

### Expected Behavior:
- Available should show 66 WETH (or match claimable)
- OR Claimable should show 0 (if rewards truly aren't available)

## Recommendation

Need to investigate:

1. `claimableRewards()` calculation logic
2. `_settleStreamingForToken()` behavior when totalStaked = 0
3. Debt tracking across unstake/restake cycles
4. AccPerShare updates during streaming periods

## Test Commands

Run all tests:
```bash
forge test --match-path test/unit/LevrStakingV1.ComplexRewardAccounting.t.sol -vv
forge test --match-path test/unit/LevrStakingV1.ExactBugReproduction.t.sol -vv
forge test --match-path test/unit/LevrStakingV1.AvailableVsClaimableBug.t.sol -vv
```

Focus on the bug:
```bash
forge test --match-path test/unit/LevrStakingV1.AvailableVsClaimableBug.t.sol --match-test test_AvailableVsClaimable_Bug -vv
```

