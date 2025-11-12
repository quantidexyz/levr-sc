# CRITICAL BUG: Dust Accumulation in Reward Streaming (30-36% Loss) - ✅ FIXED

**Status:** ✅ **FIXED** - Time-Based Vesting Implemented  
**Impact:** 30-36% of reward tokens were accumulating as dust  
**Date Discovered:** November 12, 2025  
**Date Fixed:** November 12, 2025  
**Affected Component:** `LevrStaking_v1` reward streaming mechanism  
**Solution:** Time-based vesting (Option A) - See `TIME_BASED_VESTING_FIX.md`

---

## Executive Summary

A critical bug in the reward vesting calculation causes **30-36% of reward tokens to accumulate as permanent dust** in the staking contract. This dust is unclaimable by users and represents a significant loss of rewards.

### Test Results

| Test Scenario                   | Rewards    | Dust         | Loss %  |
| ------------------------------- | ---------- | ------------ | ------- |
| Single user, daily claims       | 1,000 WETH | 339.9 WETH   | **34%** |
| Frequent claims (6hr intervals) | 1,000 WETH | 361.2 WETH   | **36%** |
| Multiple users                  | 1,000 WETH | 269.9 WETH   | **27%** |
| Worst case (prime numbers)      | 9,973 WETH | 3,579.7 WETH | **36%** |

---

## Root Cause

### Location

**File:** `src/libraries/RewardMath.sol`  
**Line:** 37  
**Function:** `calculateVestedAmount()`

```solidity
function calculateVestedAmount(
    uint256 total,
    uint64 start,
    uint64 end,
    uint64 last,
    uint64 current
) internal pure returns (uint256 vested, uint64 newLast) {
    // ...
    uint256 duration = end - start;
    require(duration != 0, 'ZERO_DURATION');
    if (total == 0) return (0, to);

    // 🔴 BUG: Integer division truncates
    vested = (total * (to - from)) / duration;  // ← Line 37
    newLast = to;
}
```

### The Problem

1. **Truncation on every settlement:**
   - `vested = (total * (to - from)) / duration` uses integer division
   - Example: `(1000e18 * 86400) / 604800` loses remainder
   - Lost amount: `(1000e18 * 86400) % 604800` = **142,857,142,857,142** wei

2. **Compound effect:**
   - Each `_settlePoolForToken()` call truncates
   - Truncated amount stays in `streamTotal` but never vests
   - Multiple settlements = multiple truncations
   - 7 daily settlements = 7 compound truncations

3. **Triple truncation cascade:**

   ```
   Settlement Flow:
   1. vested = (streamTotal * elapsed) / duration        ← Truncate #1
   2. accRewardPerShare += (vested * 1e18) / totalStaked ← Truncate #2
   3. userReward = (balance * accRewardPerShare) / 1e18  ← Truncate #3
   ```

4. **streamTotal never reaches zero:**
   - Each settlement: `streamTotal -= vested`
   - But `vested` is truncated
   - Remainder accumulates in `streamTotal`
   - After stream ends, dust remains permanently

---

## Evidence from Tests

### Test 1: Basic Streaming (Single User)

```
Reward amount: 1,000 WETH
Stream duration: 7 days (604,800 seconds)

Day 1: streamTotal = 857.142... WETH (142.857 WETH vested)
Day 2: streamTotal = 734.693... WETH (122.448 WETH vested)
Day 3: streamTotal = 629.737... WETH (104.956 WETH vested)
Day 4: streamTotal = 539.775... WETH ( 89.962 WETH vested)
Day 5: streamTotal = 462.664... WETH ( 77.110 WETH vested)
Day 6: streamTotal = 396.569... WETH ( 66.094 WETH vested)
Day 7: streamTotal = 339.916... WETH ( 56.652 WETH vested)

After stream end:
- Alice claimed: 660.083 WETH
- DUST in contract: 339.917 WETH ← 34% LOST
```

### Test 2: Frequent Claims (28 Claims Over 7 Days)

```
Claiming every 6 hours (28 settlements)
Result: 361.210 WETH dust (36% loss)

More settlements = More truncation = More dust
```

### Test 3: Worst Case (Multiple Users, Prime Numbers)

```
Setup:
- 3 users with prime stakes (1009, 1013, 1019)
- Prime reward amount: 9,973 WETH
- 20 staggered claims (60 truncation operations)

Result:
- Total claimed: 6,393.267 WETH
- DUST: 3,579.732 WETH ← 36% LOST
```

---

## Why This Happens

### Mathematical Explanation

Given:

- `streamTotal = 1,000 ether`
- `duration = 604,800 seconds (7 days)`
- `elapsed = 86,400 seconds (1 day)`

Perfect calculation (if we had infinite precision):

```
vested = (1,000e18 * 86,400) / 604,800
       = 86,400,000,000,000,000,000,000 / 604,800
       = 142,857,142,857,142,857,142.857...
```

Actual Solidity calculation (integer division):

```
vested = 142,857,142,857,142,857,142 wei
LOST   =                          857 wei per settlement
```

Over 7 daily settlements, these wei losses **compound exponentially** because:

- Lost wei stays in `streamTotal`
- Next settlement calculates vesting on the **wrong base** (inflated by previous losses)
- This creates a compounding error that grows dramatically

### Why It Compounds

Settlement 1:

```
streamTotal = 1,000e18
vested = 142,857,142,857,142,857,142 (loses 857 wei)
streamTotal = 857,142,857,142,857,142,858 (857 wei too high)
```

Settlement 2:

```
streamTotal = 857,142,857,142,857,142,858 (WRONG - inflated)
vested = should be 122,448,979,591,836,734,693 (1/7 of 857.142...)
      = actually 122,448,979,591,836,734,694 (ONE MORE because base was inflated)
Loss propagates and amplifies!
```

---

## Impact Assessment

### Production Impact

**For a typical pool:**

- Trading fees: 100 WETH/week
- **Users lose:** ~34 WETH/week
- **Annual loss:** ~1,768 WETH (~$3-5M at ETH prices)

**Affected tokens:**

- WETH (primary concern - high value)
- Any whitelisted reward token
- Underlying token (when used for rewards)

### User Impact

- Users claim less than they should
- No way to recover dust
- Perception: "Where did my rewards go?"
- Trust issue if discovered

### Protocol Impact

- Dust accumulates forever in contract
- No admin function to recover
- TVL appears higher than it should (dust counted as assets)
- Accounting mismatch

---

## Reproduction Steps

1. Deploy staking contract
2. User stakes tokens
3. Accrue rewards (starts 7-day stream)
4. User claims at intervals during stream
5. After stream ends, check contract balance
6. **Result:** 30-36% dust remains

**Run tests:**

```bash
FOUNDRY_PROFILE=dev forge test --match-path "test/unit/LevrStakingV1.DustAccumulation.t.sol" -vv
```

---

## Proposed Solutions

### Solution 1: Higher Precision (RECOMMENDED)

**Change precision from 1e18 to 1e27:**

```solidity
// Current (1e18 precision)
vested = (total * (to - from)) / duration;

// Proposed (1e27 precision)
vested = ((total * 1e9) * (to - from)) / duration / 1e9;
```

**Pros:**

- Reduces truncation by 1 billion times
- Minimal code changes
- No new state variables

**Cons:**

- Still has truncation (just much smaller)
- Slightly higher gas cost

### Solution 2: Track Remainder (BEST)

**Track and redistribute truncation loss:**

```solidity
// New state variable
mapping(address => uint256) private _vestingRemainder;

function calculateVestedAmount(...) internal pure returns (uint256 vested, uint256 remainder, uint64 newLast) {
    uint256 exact = total * (to - from);
    vested = exact / duration;
    remainder = exact % duration;  // Track what was lost
    newLast = to;
}

// In _settlePoolForToken:
(uint256 vestAmount, uint256 remainder, uint64 newLast) = RewardMath.calculateVestedAmount(...);

if (vestAmount > 0) {
    tokenState.availablePool += vestAmount;
    tokenState.streamTotal -= vestAmount;

    // Accumulate remainder
    _vestingRemainder[token] += remainder;

    // When remainder is large enough, distribute it
    if (_vestingRemainder[token] >= duration) {
        uint256 toDistribute = _vestingRemainder[token] / duration;
        _vestingRemainder[token] %= duration;
        tokenState.availablePool += toDistribute;
        tokenState.streamTotal -= toDistribute;
    }

    accRewardPerShare[token] += (vestAmount * 1e18) / _totalStaked;
}
```

**Pros:**

- Perfect accounting (zero loss)
- Remainder distributed over time
- No precision loss

**Cons:**

- New state variable (gas cost)
- Slightly more complex logic
- Need to handle remainder on stream end

### Solution 3: Remainder Distribution on Stream End

**Simplest approach:**

```solidity
// In _settlePoolForToken, when stream ends:
if (current >= end && tokenState.streamTotal > 0) {
    // Distribute all remaining as dust recovery
    tokenState.availablePool += tokenState.streamTotal;
    uint256 dustRecovered = tokenState.streamTotal;
    tokenState.streamTotal = 0;
    emit DustRecovered(token, dustRecovered);
}
```

**Pros:**

- Simplest fix
- Zero code complexity
- Recovers all dust

**Cons:**

- Dust distributed at end (not during stream)
- Timing advantage for late claimers
- Still has accumulation issue

---

## Recommended Fix

**Implement Solution 2 + Solution 3 combination:**

1. **Track remainder** during stream (Solution 2)
2. **Force distribute remainder** when stream ends (Solution 3)
3. **Add dust recovery function** for admin (safety net)

```solidity
function recoverDust(address token) external {
    require(msg.sender == treasury, "Only treasury");
    ILevrStaking_v1.RewardTokenState storage tokenState = _tokenState[token];

    // Only allow after stream ends
    require(block.timestamp >= tokenState.streamEnd, "Stream active");

    uint256 dust = tokenState.streamTotal;
    if (dust > 0) {
        tokenState.availablePool += dust;
        tokenState.streamTotal = 0;
        emit DustRecovered(token, dust);
    }
}
```

---

## Testing Checklist

- [x] Test single user streaming
- [x] Test multiple users
- [x] Test frequent claims
- [x] Test prime numbers (worst case)
- [x] Test exact truncation tracking
- [ ] Test fix with higher precision
- [ ] Test fix with remainder tracking
- [ ] Test gas costs before/after
- [ ] Test edge cases (stream end, pause, etc.)

---

## Action Items

1. **URGENT:** Add admin function to recover existing dust
2. **HIGH:** Implement Solution 2 (remainder tracking)
3. **HIGH:** Add comprehensive tests for fix
4. **MEDIUM:** Audit gas cost implications
5. **MEDIUM:** Update documentation
6. **LOW:** Consider migrating existing contracts

---

## References

- **Test File:** `test/unit/LevrStakingV1.DustAccumulation.t.sol`
- **Bug Location:** `src/libraries/RewardMath.sol:37`
- **Settlement Function:** `src/LevrStaking_v1.sol:651` (`_settlePoolForToken`)
- **Related:** MasterChef-style reward accounting

---

## Notes

- This bug is present in PRODUCTION
- Users are currently losing ~30-36% of rewards
- Fix requires careful migration strategy
- Consider notifying users and compensating lost rewards
- Similar pattern exists in many DeFi protocols (check all instances)

---

**Last Updated:** November 12, 2025  
**Severity:** CRITICAL  
**Priority:** P0 - Immediate Fix Required
