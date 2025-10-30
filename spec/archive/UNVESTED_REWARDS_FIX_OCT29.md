# Critical Fix: Unvested Rewards to Unstaked Users - October 29, 2025

## Bug Description

**CRITICAL**: Users who were fully unstaked during the unvested period could claim ALL unvested rewards when they staked again.

### Scenario:

1. User staked, rewards accruing
2. User claimed some vested rewards
3. User **unstaked ALL** (totalStaked = 0, streaming pauses)
4. Stream window expires while user unstaked
5. User **stakes again**
6. User could claim ALL unvested rewards (even though they weren't staked!)

### Example:

```
- 150 WETH accrued, 3-day stream starts
- User claims 33 WETH after 1 day (1/3 vested)
- User unstakes ALL
- 116 WETH remains unvested in contract
- Streaming pauses (totalStaked = 0)
- Stream window expires
- User stakes again
- BUG: User can claim all 116 WETH they shouldn't have!
```

## Root Cause

The issue was in the order of operations in `stake()`:

### Before Fix:

```solidity
function stake(uint256 amount) external {
    _settleStreamingAll();          // Settles with totalStaked = 0 (no-op)
    // ... transfer tokens ...
    _increaseDebtForAll(staker, amount);  // Sets debt based on stale accPerShare
    _totalStaked += amount;          // Updates totalStaked AFTER debt calculation
}
```

Problem:
- Settlement happened while `totalStaked = 0`, so no updates to `accPerShare`
- Debt was calculated using stale `accPerShare`
- User got credit for unvested rewards

## The Fix

### Changes Made:

1. **Re-ordered `stake()` operations**: Update `_totalStaked` BEFORE setting debt
2. **Added settlement in debt functions**: Both `_increaseDebtForAll()` and `_updateDebtAll()` now settle streaming first
3. **Conditional debt logic**: If user had zero balance (fully unstaked), use `_updateDebtAll()` to reset their position

### After Fix:

```solidity
function stake(uint256 amount) external {
    uint256 oldBalance = balanceOf(staker);
    
    _settleStreamingAll();          // Settles but totalStaked still 0
    // ... transfer tokens ...
    
    _totalStaked += amount;          // Update totalStaked FIRST
    
    // Now set debt with proper settlement
    if (oldBalance == 0) {
        _updateDebtAll(staker, amount);     // Settles again with totalStaked > 0
    } else {
        _increaseDebtForAll(staker, amount); // Settles again with totalStaked > 0
    }
}

function _updateDebtAll(address account, uint256 newBal) internal {
    for (...) {
        _settleStreamingForToken(rt);  // NEW: Settle before calculating debt
        uint256 acc = _rewardInfo[rt].accPerShare;
        _rewardDebt[account][rt] = int256((newBal * acc) / ACC_SCALE);
    }
}

function _increaseDebtForAll(address account, uint256 amount) internal {
    for (...) {
        _settleStreamingForToken(rt);  // NEW: Settle before calculating debt
        uint256 acc = _rewardInfo[rt].accPerShare;
        _rewardDebt[account][rt] += int256((amount * acc) / ACC_SCALE);
    }
}
```

## Test Coverage

### New Test: `LevrStakingV1.VideoRecordingScenario.t.sol`

Reproduces the exact user flow:

```
✅ BEFORE FIX:
   Claimable: 226 mWETH
   User claimed: 226 mWETH (WRONG!)

✅ AFTER FIX:
   Claimable: 0 mWETH
   User claimed: 0 mWETH (CORRECT!)
```

###All Existing Tests: ✅ PASS

- 56 unit tests pass
- 5 E2E tests pass
- No regressions

## Impact

**Severity**: CRITICAL

**Before Fix**: Users could steal unvested rewards by:
1. Unstaking during active stream
2. Waiting for stream to end
3. Staking again to claim rewards they didn't earn

**After Fix**: Debt is properly calculated, users only get rewards they actually earned while staked

## Files Changed

1. `src/LevrStaking_v1.sol`:
   - `stake()`: Re-ordered totalStaked update before debt calculation
   - `_increaseDebtForAll()`: Added `_settleStreamingForToken()` call
   - `_updateDebtAll()`: Added `_settleStreamingForToken()` call

2. Test coverage:
   - `test/unit/LevrStakingV1.VideoRecordingScenario.t.sol`: New test reproducing bug

## Verification

Run the test:
```bash
forge test --match-test test_ExactVideoRecordingScenario -vv
```

Expected output:
```
Claimable: 0 mWETH
Claimed: 0 mWETH
```

## Related Issues

This fix also resolves the "Claimable > Available" UI confusion, as claimable now correctly shows 0 for users who weren't staked during unvested periods.

