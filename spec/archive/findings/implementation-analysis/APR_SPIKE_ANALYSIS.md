# APR Spike Analysis - LevrStaking_v1

## Summary

The 125% APR "spike" you observed is **NOT a bug in the APR calculation** - it's **mathematically correct** based on the actual `totalStaked` amount. The issue is that the UI is likely showing incorrect data or you're looking at a different staking pool than you think.

## Key Findings

### 1. **The 125% APR is Correct Math** ✅

To get 125% APR from accruing 1000 tokens over a 3-day stream:

```
APR = (annualized_rewards / totalStaked) * 10,000 bps

125% = (1000 tokens * 365 days / 3 days / totalStaked) * 10,000
totalStaked ≈ 97,333 tokens
```

**NOT 10 million tokens!**

### 2. **Test Results Prove This**

```
test_reproduce_exact_125_percent_apr()
  Total Staked: 97,333 tokens
  Reward Amount: 1,000 tokens
  APR: 12,500 bps = 125% ✅
```

### 3. **What You're Probably Seeing in the UI**

| Scenario | Likely Issue |
|----------|--------------|
| **UI shows 10M staked** | UI is reading from wrong contract or wrong chain |
| **UI shows 97K staked** | This is CORRECT - explains the 125% APR perfectly |
| **Multiple staking pools** | You might be looking at pool A's stake but pool B's APR |
| **Recent unstakes** | Total staked dropped from 10M to ~97K recently |

## APR Calculation Breakdown

With **10M tokens staked** + **1000 token accrual**:
```
Annual rewards: 1000 * (365 days / 3 days) = 121,666 tokens
APR: (121,666 / 10,000,000) * 10,000 = 121 bps = 1.21%
```

With **97,333 tokens staked** + **1000 token accrual**:
```
Annual rewards: 1000 * (365 days / 3 days) = 121,666 tokens  
APR: (121,666 / 97,333) * 10,000 = 12,500 bps = 125%
```

## Critical Issue Discovered: Lost Rewards ⚠️

**This is the REAL problem that needs attention!**

### The Problem

When you call `accrueRewards()` during an active reward stream, **the unvested portion of the previous stream is LOST forever**.

### Example from Tests

```
Timeline:
  T=0:     Accrue 600K tokens → stream over 3 days
  T=1 day: Only 200K vested (1/3 of stream)
  T=1 day: Accrue 1K tokens → RESETS stream to just 1K tokens
  T=4 days: Stream ends
  
Result: 
  - Claimed: 201K tokens (200K from first stream + 1K from second)
  - LOST: 400K tokens (unvested portion of first stream)
```

See `test_apr_spike_reproduction()` output:
```
First accrual: 600K tokens, stream for 3 days
After 1 day: ~200K vested (1/3 of stream)
Second accrual: 1K tokens, RESETS stream
The 400K unvested from first stream is lost!

Unaccounted underlying: 400,000 tokens
```

### Root Cause

In `LevrStaking_v1.sol`:

```solidity
function _creditRewards(address token, uint256 amount) internal {
    ILevrStaking_v1.RewardInfo storage info = _ensureRewardToken(token);
    // Settle current stream up to now before resetting
    _settleStreamingForToken(token);
    // Reset stream window with new amount only (no remaining carry-over)
    _resetStreamForToken(token, amount);  // ⚠️ Only uses NEW amount!
    // Increase reserve by newly provided amount only
    _rewardReserve[token] += amount;
    emit RewardsAccrued(token, amount, info.accPerShare);
}
```

The `_resetStreamForToken()` call **replaces** the stream with the new amount instead of **adding** to it.

### Impact

- Frequent small reward accruals waste large amounts of tokens
- The 400K tokens remain in the contract but are never distributed
- This is especially problematic for automated fee collection systems

## Recommendations

### Immediate Actions

1. **Check UI Data Source**
   - Verify which contract address the UI is reading `totalStaked()` from
   - Confirm you're on the right chain (Base vs Base Sepolia)
   - Check if there are multiple staking pools

2. **Verify On-Chain**
   ```javascript
   // Check actual values on-chain
   const totalStaked = await staking.totalStaked()
   console.log("Total Staked:", totalStaked / 1e18, "tokens")
   
   const apr = await staking.aprBps()
   console.log("APR:", apr / 100, "%")
   ```

3. **Fix Lost Rewards Issue**
   
   **Option A: Accumulate unvested rewards**
   ```solidity
   function _creditRewards(address token, uint256 amount) internal {
       _settleStreamingForToken(token);
       
       // Calculate unvested from current stream
       uint256 unvested = _calculateUnvested(token);
       
       // Reset with NEW amount + UNVESTED from previous stream
       _resetStreamForToken(token, amount + unvested);
       _rewardReserve[token] += amount; // Only increase by actual new amount
   }
   ```
   
   **Option B: Document and warn**
   - Add clear warnings in docs about mid-stream accruals
   - Recommend accruing only after streams complete
   - Add a function to query remaining stream time

### Testing Recommendations

Run these commands to verify your specific scenario:

```bash
# All APR tests
forge test --match-contract LevrStakingV1AprSpikeTest -vv

# Specific tests
forge test --match-test test_apr_spike_reproduction -vv
forge test --match-test test_reproduce_exact_125_percent_apr -vv
forge test --match-test test_apr_with_very_low_stake -vv
```

## Emission Verification ✅

The tests confirm that **all accrued rewards ARE properly emitted** (as long as you don't interrupt the stream):

```
test_apr_calculation_with_small_rewards():
  ✅ 1,000 tokens accrued → 1,000 tokens claimed
  ✅ 10,000 tokens accrued → 10,000 tokens claimed  
  ✅ 100,000 tokens accrued → 100,000 tokens claimed
  ✅ 500,000 tokens accrued → 500,000 tokens claimed
  ✅ 1,000,000 tokens accrued → 1,000,000 tokens claimed
```

**But only if you wait for the full stream to complete!** If you accrue mid-stream, the unvested portion is lost.

## Conclusion

1. ✅ **APR calculation is correct** - no bugs there
2. ⚠️ **UI might be showing wrong totalStaked** - investigate data source
3. 🔴 **Lost rewards on mid-stream accrual** - THIS IS THE REAL ISSUE
4. ✅ **Rewards do emit fully** - but only if stream completes

The "weird issue" is actually revealing a critical design flaw in the reward streaming system that causes permanent loss of unvested rewards when new rewards are accrued mid-stream.

