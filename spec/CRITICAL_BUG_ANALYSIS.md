# CRITICAL BUG ANALYSIS: Staking After Stream Ends

## Bug Confirmed! ✅

Successfully reproduced the user's exact scenario where **claimable > available** after staking when stream is inactive.

## Test Results

```
=== BUG CHECK ===
  !!! BUG CONFIRMED: Claimable > Available !!!
  Claimable: 77 WETH
  Available: 0 WETH
  Difference: 77 WETH
```

## Root Cause Identified

### The Accounting Mismatch:

```
Reward Info:
  accPerShare: 0       <- AccPerShare is ZERO!
  exists: true

Debt Tracking:
  User debt: 55        <- But debt is 55?!
  Expected debt: 111   <- Expected based on calculation

Claimable Calculation:
  Accumulated: 111
  Debt: 55
  Pending: 55
```

### What's Happening:

1. **Stream window exists** from first accrual (100 WETH + 50 WETH manual)
2. **User unstakes** after 1 day → claims 33 WETH, leaves 116 WETH in reserve
3. **Stream continues but NO vesting** (totalStaked = 0)
4. **Stream inactive** but window timestamps still exist
5. **User stakes AFTER stream ends**
6. **`_increaseDebtForAll()` called** but accPerShare = 0 (stream hasn't settled final amounts)
7. **`claimableRewards()` view** adds "pending streaming" from the ended stream
8. **Result**: Shows claimable rewards that were never actually vested!

## Key Code Paths

### When User Stakes (LevrStaking_v1.sol:90-105)

```solidity
function stake(uint256 amount) external nonReentrant {
    address staker = _msgSender();
    _settleStreamingAll();  // ← Settles streaming but totalStaked was 0
    
    // ...transfer tokens...
    
    _increaseDebtForAll(staker, amount);  // ← Sets debt based on accPerShare
    _totalStaked += amount;
    // ...
}
```

### The Problem with `_increaseDebtForAll()` (LevrStaking_v1.sol:518-527)

```solidity
function _increaseDebtForAll(address account, uint256 amount) internal {
    uint256 len = _rewardTokens.length;
    for (uint256 i = 0; i < len; i++) {
        address rt = _rewardTokens[i];
        uint256 acc = _rewardInfo[rt].accPerShare;  // ← Gets current accPerShare
        if (acc > 0) {
            _rewardDebt[account][rt] += int256((amount * acc) / ACC_SCALE);
        }
    }
}
```

**Issue**: When stream has ended but wasn't settled (because totalStaked = 0), accPerShare doesn't reflect the unvested portion.

### The Problem with `claimableRewards()` View (LevrStaking_v1.sol:242-281)

```solidity
function claimableRewards(address account, address token) external view returns (uint256 claimable) {
    // ...
    uint256 accPerShare = info.accPerShare;
    
    // Add any pending streaming rewards using GLOBAL stream window
    uint64 start = _streamStart;
    uint64 end = _streamEnd;
    if (end > 0 && start > 0 && block.timestamp > start) {
        uint64 last = _lastUpdateByToken[token];
        uint64 from = last < start ? start : last;
        uint64 to = uint64(block.timestamp);
        if (to > end) to = end;  // ← Caps at stream end
        if (to > from) {
            uint256 duration = end - start;
            uint256 total = _streamTotalByToken[token];
            if (duration > 0 && total > 0 && _totalStaked > 0) {  // ← Checks totalStaked NOW
                uint256 vestAmount = (total * (to - from)) / duration;
                accPerShare += (vestAmount * ACC_SCALE) / _totalStaked;  // ← Calculates as if it would vest
            }
        }
    }
    
    uint256 accumulated = (bal * accPerShare) / ACC_SCALE;
    int256 debt = _rewardDebt[account][token];
    
    if (accumulated > uint256(debt)) {
        claimable = accumulated - uint256(debt);
    }
}
```

**Issue**: This view function calculates "what would vest IF totalStaked > 0", but those rewards never actually vested (stream was inactive during zero-staker period).

## The Exact Sequence

### Timeline:

```
T=0:     User stakes 1M tokens
T=1:     Accrue 100 WETH → stream starts (3 days)
         streamStart = 1
         streamEnd = 259201
T=86401: Warp 1 day
         Accrue 50 WETH more → resets stream
         streamStart = 86401
         streamEnd = 345601
         User unstakes ALL
         → Claims ~33 WETH (vested portion)
         → Reserve: 116 WETH (unvested)
         → totalStaked = 0
T=172801: Warp more (stream still has time left)
T=259201: Stream time window expires
         BUT totalStaked was 0 entire time
         → Rewards did NOT vest (correct behavior per _settleStreamingForToken)
T=345602: User stakes again (AFTER stream window)
```

### What Happens at T=345602 (Stake After Stream End):

1. `_settleStreamingAll()` runs but:
   - totalStaked WAS 0, so no vesting happened
   - accPerShare didn't update with unvested rewards
2. `_increaseDebtForAll()` sets debt based on current accPerShare
   - If accPerShare = 0 → debt = 0
   - If accPerShare = X → debt = stakeAmount * X / SCALE
3. **User's debt is set incorrectly**
4. When UI calls `claimableRewards()`:
   - It calculates pending streaming from [last update → stream end]
   - Adds this to accPerShare
   - Shows user can claim rewards that never vested!

## Why Claim/Unstake Might Fail

In the test, claim/unstake **succeeded**, but user reports they **fail**. Possible reasons:

### Scenario 1: Multiple Reward Tokens

If there are multiple reward tokens and one has insufficient balance:

```solidity
function _settle(address token, address account, address to, uint256 bal) internal {
    // ...
    uint256 reserve = _rewardReserve[token];
    if (reserve < pending) revert InsufficientRewardLiquidity();  // ← Could fail here
    // ...
}
```

### Scenario 2: Third Accrual

If user tried to accrue again after stream ended, it would:
- Call `_resetStreamForToken()` with new amount + unvested
- Create NEW stream window
- This might expose different accounting bugs

### Scenario 3: Precision/Rounding Issues

With very large numbers or specific ratios, rounding could cause:
- Claimable to exceed reserve by tiny amount
- Reverts on claim/unstake

## The Fix

### Option 1: Don't calculate pending for ended streams

In `claimableRewards()`, check if stream is ended AND was inactive:

```solidity
// Only add pending if stream is active OR was active when rewards were vesting
if (end > 0 && start > 0 && block.timestamp > start) {
    // ... existing logic ...
    if (duration > 0 && total > 0 && _totalStaked > 0) {
        // Only add pending if CURRENTLY active, not for past inactive periods
        if (block.timestamp < end) {  // ← Add this check
            uint256 vestAmount = (total * (to - from)) / duration;
            accPerShare += (vestAmount * ACC_SCALE) / _totalStaked;
        }
    }
}
```

### Option 2: Force settlement on stake when stream ended

When user stakes after stream ended, force a final settlement:

```solidity
function stake(uint256 amount) external nonReentrant {
    address staker = _msgSender();
    _settleStreamingAll();
    
    // NEW: If stream has ended and totalStaked was 0, finalize accPerShare
    if (_totalStaked == 0 && _streamEnd > 0 && block.timestamp > _streamEnd) {
        _finalizeEndedStreams();  // ← New internal function
    }
    
    // ... rest of stake logic ...
}
```

### Option 3: Track when stream was active with stakers

Add state to track if stream had stakers:

```solidity
mapping(address => bool) private _streamHadStakers;

// In _settleStreamingForToken:
if (_totalStaked > 0 && vestAmount > 0) {
    _streamHadStakers[token] = true;
    // ... vest logic ...
}

// In claimableRewards:
if (duration > 0 && total > 0 && _streamHadStakers[token]) {
    // Only calculate pending if stream actually had stakers
}
```

## Recommendation

**Option 1** is simplest and safest:
- Minimal code changes
- Fixes the view function to not show phantom rewards
- Prevents UI confusion

**Testing**: Need to verify this doesn't break legitimate pending reward calculations for active streams.

## Next Steps

1. ✅ Confirm bug with exact reproduction test
2. ⏳ Implement fix (Option 1 recommended)
3. ⏳ Add regression tests
4. ⏳ Update spec documentation
5. ⏳ Run full test suite to ensure no breaking changes

