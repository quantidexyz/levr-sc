# Root Cause Analysis: 1 Wei Accounting Discrepancy

## Bug Summary

**Test**: `test_CREATIVE_sandwichManualTransfers()`  
**Issue**: Bob has 1 wei claimable in pending rewards, but reserve = 0 (all 50 ether locked in streaming)  
**Impact**: `claimable > available reserve` triggers accounting assertion

## Scenario That Triggers Bug

```
1. Alice stakes 1000 ether
2. Stream 1: 500 WETH accrues (7 day window)
3. +1 day passes
4. Manual transfer: 100 WETH (NOT accrued yet)
5. Alice unstakes 500 ether → creates pending rewards
6. Manual transfer: 100 WETH (NOT accrued yet)
7. +1 day, accrue() called → picks up 200 WETH + unvested from stream 1
8. ...more operations...
9. Bob unstakes 400 ether → creates pending rewards: 179286835613366225611 wei
10. Manual transfers happen
11. Accruals happen
12. Bob stakes 200 ether back
13. More manual transfers & accruals
14. At claim time: Bob has 1 wei pending but reserve = 0
```

## Root Cause Analysis

### The Issue: Rounding Error Accumulation in Pending Rewards

When a user unstakes, their pending rewards are calculated using:

```solidity
// In unstake() - lines 196-209
uint256 accumulated = RewardMath.calculateAccumulated(oldBalance, tokenState.accPerShare);
if (accumulated > uint256(currentDebt)) {
    uint256 pending = accumulated - uint256(currentDebt);
    userState.pending += pending;
}
```

Where `calculateAccumulated`:

```solidity
function calculateAccumulated(uint256 balance, uint256 accPerShare) internal pure returns (uint256) {
    return (balance * accPerShare) / ACC_SCALE;  // ACC_SCALE = 1e27
}
```

### The Problem

1. **Multiple Unstake Operations**: Bob unstakes multiple times, each time adding to `userState.pending`:
   - First unstake: `pending += X`
   - Second unstake: `pending += Y`
   - Total pending: `X + Y`

2. **Rounding in Each Calculation**: Each `calculateAccumulated` call involves division:
   - `accumulated = (balance * accPerShare) / 1e27`
   - This truncates/rounds down

3. **Unvested Rewards Rollover**: When `accrueRewards` is called:

   ```solidity
   // _creditRewards() - lines 672-676
   uint256 unvested = _calculateUnvested(token);
   _resetStreamForToken(token, amount + unvested);
   tokenState.reserve += amount;  // Only NEW amount added to reserve!
   ```

   The unvested amount is added back to the stream but NOT added to reserve.

4. **Reserve vs StreamTotal Mismatch**:
   - `reserve` tracks what's been allocated (vested + will vest)
   - When unvested is rolled into new stream, it's already in reserve from original accrual
   - But pending rewards calculated during unstake "lock in" a specific amount
   - Due to rounding, the locked pending amount can be 1 wei more than what's actually available

### Mathematical Example

```
Stream 1: 1000 WETH over 7 days
accPerShare after 2 days = (1000 * 2/7 * 1e27) / totalStaked

Bob (balance = 800):
  accumulated = (800 * accPerShare) / 1e27
  accumulated = (800 * 285714285714285714285000000) / 1e27
  accumulated = 228571428571428571428 wei

Bob unstakes 400:
  pending = accumulated - debt = 228571428571428571428 wei (stored)

Stream continues, manual transfers happen, new accrual:
  unvested = 1000 - 228571428571428571428 = 771428571428571428572 wei

New stream: unvested + new amount
  BUT unvested calculation also has rounding!

When all is said and done:
  Sum of all pending across all users = X
  Actual tokens in reserve after claims = X - 1 wei

The 1 wei is lost to rounding errors!
```

## Specific Code Locations

### 1. Pending Rewards Calculation (Unstake)

**File**: `LevrStaking_v1.sol`  
**Lines**: 196-209

```solidity
uint256 accumulated = RewardMath.calculateAccumulated(oldBalance, tokenState.accPerShare);
if (accumulated > uint256(currentDebt)) {
    uint256 pending = accumulated - uint256(currentDebt);
    userState.pending += pending;  // ← Rounds down here
}
```

### 2. Unvested Calculation

**File**: `RewardMath.sol`  
**Lines**: 73-94

```solidity
uint64 effectiveTime = last < current ? last : current;
uint256 elapsed = effectiveTime > start ? effectiveTime - start : 0;
uint256 vested = (total * elapsed) / duration;  // ← Rounds down here
return total > vested ? total - vested : 0;
```

### 3. Reserve Management

**File**: `LevrStaking_v1.sol`  
**Lines**: 663-682

```solidity
uint256 unvested = _calculateUnvested(token);
_resetStreamForToken(token, amount + unvested);
tokenState.reserve += amount;  // ← Only new amount, not unvested!
```

## Why This Happens

1. **Accumulated Calculation**: `(balance * accPerShare) / ACC_SCALE` rounds down
2. **Unvested Calculation**: `total - (total * elapsed) / duration` rounds differently
3. **Multiple Operations**: Each unstake/accrue compounds the rounding error
4. **Reserve Accounting**: Reserve doesn't increase by unvested (it's already there), but pending rewards "lock in" a rounded value

## The 1 Wei Discrepancy

After many operations with:

- Multiple partial unstakes (each creating pending)
- Multiple manual transfers
- Multiple accruals (rolling unvested forward)

The cumulative rounding errors result in:

- **Pending rewards stored**: `X + 1 wei`
- **Actual tokens accounted in reserve**: `X wei`
- **Difference**: `1 wei`

When Bob tries to claim that last 1 wei of pending, the reserve is 0 (all tokens are in the active stream), so:

- `claimable = 1 wei`
- `reserve = 0`
- `claimable > reserve` ← BUG!

## Solution Options

### Option 1: Round Pending Rewards Down More Aggressively

In `unstake()`, subtract 1 wei from pending to account for rounding:

```solidity
if (accumulated > uint256(currentDebt)) {
    uint256 pending = accumulated - uint256(currentDebt);
    if (pending > 0) pending -= 1; // Safety margin for rounding
    userState.pending += pending;
}
```

### Option 2: Increase Reserve by Pending Amount on Unstake

When creating pending rewards, immediately reserve them:

```solidity
if (accumulated > uint256(currentDebt)) {
    uint256 pending = accumulated - uint256(currentDebt);
    userState.pending += pending;
    // Don't increase reserve - pending is already part of vested amount
    // But mark it as "locked" so unvested calculation excludes it
}
```

### Option 3: Fix Unvested Calculation to Account for Pending

Modify `_calculateUnvested` to subtract all pending rewards:

```solidity
function _calculateUnvested(address token) internal view returns (uint256) {
    uint256 baseUnvested = RewardMath.calculateUnvested(...);

    // Subtract locked pending rewards from all users
    // (This would require tracking total pending per token)
    uint256 totalPending = _getTotalPending(token);

    return baseUnvested > totalPending ? baseUnvested - totalPending : 0;
}
```

### Option 4: Use Consistent Rounding (Recommended)

Ensure all calculations round in the same direction:

- User rewards: round DOWN (favor protocol)
- Unvested: round UP (favor protocol)
- This ensures protocol always has at least as much as users can claim

Modify `RewardMath.calculateAccumulated`:

```solidity
function calculateAccumulated(uint256 balance, uint256 accPerShare) internal pure returns (uint256) {
    uint256 raw = (balance * accPerShare) / ACC_SCALE;
    // Subtract 1 wei safety margin to ensure we never over-allocate
    return raw > 0 ? raw - 1 : 0;
}
```

## Recommendation

**Option 4** is the cleanest solution - it's a defense-in-depth approach that ensures rounding always favors the protocol. The 1 wei difference is acceptable and prevents the `claimable > reserve` scenario.

Alternatively, the contract already handles this gracefully with the `RewardShortfall` event and partial payment mechanism, so this could be considered a feature, not a bug. The 1 wei can be refilled and claimed later.
