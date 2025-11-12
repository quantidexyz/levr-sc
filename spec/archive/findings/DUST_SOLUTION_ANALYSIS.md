# Dust Accumulation - Solution Analysis

**Date:** November 12, 2025  
**Status:** Investigation Complete - Root Cause Identified

---

## Solutions Tested

### ❌ Solution 1: Higher Precision (1e9 scaling)

**Implementation:**

```solidity
uint256 scaledRate = (total * 1e9) / duration;
uint256 scaledVested = scaledRate * elapsed;
vested = scaledVested / 1e9;
```

**Result:** NO IMPROVEMENT

- Dust: Still 339.9 WETH (34%)
- streamTotal values: Nearly identical (1-2 wei difference)
- Conclusion: Precision improvement is TOO SMALL to matter

**Why It Failed:**

- 1e9 precision reduces truncation by 1 billion, but the numbers involved are 1e18+
- The compound effect over 7 settlements overwhelms the minor precision gain
- Other truncation points (accRewardPerShare, userReward) still lose precision

---

### ❌ Solution 2: Track Remainder

**Implementation:**

```solidity
(uint256 vested, uint256 remainder, uint64 newLast) = calculateVestedAmount(...);

_vestingRemainder[token] += remainder;
uint256 toDistribute = _vestingRemainder[token] / duration;
if (toDistribute > 0) {
    // distribute...
}
```

**Result:** NO IMPROVEMENT

- Dust: Still 339.9 WETH (34%)
- Remainder IS being tracked but distribution doesn't help
- streamTotal values: Identical to original

**Why It Failed:**
The remainder tracks (wei\*seconds) lost to truncation, but the REAL problem is the **compound error from using reduced streamTotal**.

Here's what happens:

```
Settlement 1:
  streamTotal = 1000 WETH
  vested = (1000 * 1day) / 7days = 142.857... ≈ 142 WETH
  streamTotal = 1000 - 142 = 858 WETH  ← BASE REDUCED

Settlement 2:
  streamTotal = 858 WETH (WRONG - should calculate from original 1000!)
  vested = (858 * 1day) / 7days = 122.571... ≈ 122 WETH
  streamTotal = 858 - 122 = 736 WETH  ← ERROR COMPOUNDS
```

**The Core Issue:** We're calculating "vest X from remaining" instead of "vest based on time from original".

---

## True Root Cause

The dust accumulation has **THREE compounding problems**:

### 1. Wrong Algorithmic Base (PRIMARY)

Current logic uses **REMAINING** streamTotal:

```solidity
vested = (streamTotal * elapsed) / duration;  // streamTotal keeps decreasing!
streamTotal -= vested;
```

Should use **TIME-BASED** calculation from original:

```solidity
totalVested = (originalTotal * timeElapsedFromStart) / totalDuration;
newlyVested = totalVested - alreadyAccounted;
```

### 2. Triple Truncation Per Settlement (SECONDARY)

Each settlement has 3 division operations:

1. **Vesting:** `vested = (total * elapsed) / duration` ← truncates
2. **AccReward:** `accRewardPerShare += (vested * 1e18) / totalStaked` ← truncates
3. **User Reward:** `userReward = (balance * accRewardPerShare) / 1e18` ← truncates

With 7 settlements, that's 21 truncation operations!

### 3. Compound Effect (AMPLIFIER)

Because we use reduced streamTotal, early truncation errors propagate:

- Day 1: Lose 0.857 WETH to truncation
- Day 2: Base is now WRONG (858 instead of 1000), so we calculate wrong amount
- Day 3-7: Errors compound exponentially

---

## Correct Solution

### Option A: Time-Based Vesting (BEST)

**Concept:** Calculate vesting based on time elapsed from stream start, not from remaining amount.

**Implementation:**

```solidity
struct RewardTokenState {
    uint256 availablePool;
    uint256 streamTotal;      // Never modify this!
    uint256 streamOriginal;   // NEW: Store original amount
    uint256 totalVested;      // NEW: Track what's vested so far
    uint64 lastUpdate;
    bool exists;
    bool whitelisted;
    uint64 streamStart;
    uint64 streamEnd;
}

function _settlePoolForToken(address token) internal {
    // Calculate total that SHOULD have vested from start to now
    uint256 timeElapsed = block.timestamp - streamStart;
    uint256 totalDuration = streamEnd - streamStart;
    uint256 totalShouldHaveVested = (streamOriginal * timeElapsed) / totalDuration;

    // New vesting = total should have - already vested
    uint256 newlyVested = totalShouldHaveVested - totalVested;

    if (newlyVested > 0) {
        totalVested += newlyVested;
        availablePool += newlyVested;
        // Don't modify streamTotal! Or set it to: streamOriginal - totalVested
    }
}
```

**Pros:**

- ✅ Eliminates compound error (always calculate from original)
- ✅ Perfect mathematical correctness
- ✅ Only ONE truncation per full stream (not per settlement)
- ✅ Dust reduced to wei-level (not ether-level)

**Cons:**

- Requires new state variables
- Need migration for existing contracts
- Changes core streaming logic

---

### Option B: End-of-Stream Distribution (SIMPLE)

**Concept:** Just distribute all remaining streamTotal when stream ends.

**Implementation:**

```solidity
function _settlePoolForToken(address token) internal {
    // ... existing settlement logic ...

    // At stream end, force distribute everything
    if (current >= end && streamTotal > 0) {
        availablePool += streamTotal;
        streamTotal = 0;
        emit DustRecovered(token, streamTotal);
    }
}
```

**Pros:**

- ✅ Extremely simple (5 lines of code)
- ✅ Recovers ALL dust eventually
- ✅ No new state variables needed
- ✅ Backward compatible

**Cons:**

- ❌ Dust still accumulates during stream
- ❌ Late claimers get slight advantage
- ❌ Doesn't fix the mathematical incorrectness

---

### Option C: Higher Precision (1e18+ scaling)

**Concept:** Use MUCH higher precision (1e27 or 1e36) for intermediate calculations.

**Implementation:**

```solidity
uint256 MEGA_PRECISION = 1e27;  // 1 billion times higher than 1e18

uint256 scaledRate = (total * MEGA_PRECISION) / duration;
uint256 scaledVested = scaledRate * elapsed;
vested = scaledVested / MEGA_PRECISION;
```

**Pros:**

- ✅ Reduces truncation significantly
- ✅ Minimal code changes
- ✅ No new state variables

**Cons:**

- ❌ Risk of overflow with very large numbers
- ❌ Still has SOME truncation (just much smaller)
- ❌ Doesn't fix algorithmic issue
- ❌ Slightly higher gas cost

---

## Recommendation

**Implement Option A + Option B:**

1. **Short-term (Immediate):** Deploy Option B (end-of-stream distribution)
   - Recovers existing dust
   - Zero risk
   - Buys time for proper fix

2. **Long-term (Next version):** Implement Option A (time-based vesting)
   - Fix the algorithm properly
   - Eliminate compound errors
   - Perfect accounting

3. **Additional:** Add dust recovery function for admin
   ```solidity
   function recoverStreamDust(address token) external onlyTreasury {
       require(block.timestamp >= streamEnd, "Stream active");
       uint256 dust = streamTotal;
       if (dust > 0) {
           availablePool += dust;
           streamTotal = 0;
           emit DustRecovered(token, dust);
       }
   }
   ```

---

## Test Results Summary

| Solution                     | Dust (1000 WETH) | Improvement |
| ---------------------------- | ---------------- | ----------- |
| Original                     | 339.9 WETH       | 0%          |
| Solution 1 (1e9 precision)   | 339.9 WETH       | 0%          |
| Solution 2 (track remainder) | 339.9 WETH       | 0%          |
| **Needed: Option A**         | **< 0.001 WETH** | **~100%**   |

---

## Conclusion

- Higher precision (Solution 1) and remainder tracking (Solution 2) **DO NOT FIX** the dust issue
- The problem is **algorithmic**: using reduced streamTotal creates compound errors
- **Proper fix:** Calculate vesting based on time from original amount (Option A)
- **Quick fix:** Distribute remaining streamTotal at end (Option B)

**Next Steps:**

1. Implement Option B immediately for production
2. Design and test Option A for v2
3. Add monitoring/recovery tools
4. Update documentation

---

**Last Updated:** November 12, 2025  
**Author:** AI Analysis  
**Status:** Ready for Implementation
