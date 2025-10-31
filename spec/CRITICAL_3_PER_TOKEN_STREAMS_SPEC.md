# CRITICAL-3: Per-Token Stream Windows - Implementation Spec

**Issue:** Global Stream Window Collision  
**Status:** 🔴 CONFIRMED VULNERABILITY (November 1, 2025)  
**Priority:** P0 - Only remaining critical issue from Audit 4  
**Estimated Effort:** 1-2 days

---

## **PROBLEM STATEMENT**

### **Current Broken Behavior**

All reward tokens share a **single global stream window** (`_streamStart`, `_streamEnd`). When rewards are added for ANY token, the global window resets, affecting ALL tokens.

**Proof:**
```solidity
// Setup: Token A streaming 1000 tokens over 7 days
accrueRewards(tokenA, 1000e18);  
// _streamStart = T0, _streamEnd = T0 + 7 days

// 3 days pass → Token A vested ~428 tokens
vm.warp(T0 + 3 days);

// Add rewards for Token B
accrueRewards(tokenB, 1e18);
→ _resetStreamForToken(tokenB, 1e18)
  → _streamStart = T0 + 3 days  // ⚠️ GLOBAL RESET!
  → _streamEnd = T0 + 10 days

// Result: Token A vesting BROKEN
// - Previously vested 428 → Now shows 0
// - Remaining 572 tokens re-streaming over NEW 7 days
```

**Test Evidence:**
```
Token A vested after 3 days: 428571428571428571428 (expected)
Token A vested after token B accrual: 0 (ACTUAL)
CRITICAL-3 CONFIRMED ❌
```

---

## **ROOT CAUSE ANALYSIS**

### **Current Implementation (Broken)**

**Global State:**
```solidity
// src/LevrStaking_v1.sol:40-41
uint64 private _streamStart;  // ⚠️ SHARED BY ALL TOKENS
uint64 private _streamEnd;    // ⚠️ SHARED BY ALL TOKENS
```

**Per-Token State:**
```solidity
// src/interfaces/ILevrStaking_v1.sol:29-35
struct RewardTokenState {
    uint256 availablePool;
    uint256 streamTotal;
    uint64 lastUpdate;
    bool exists;
    bool whitelisted;
    // ❌ MISSING: streamStart, streamEnd
}
```

**Reset Function (Sets Global Window):**
```solidity
// src/LevrStaking_v1.sol:400-413
function _resetStreamForToken(address token, uint256 amount) internal {
    uint32 window = ILevrFactory_v1(factory).streamWindowSeconds(underlying);
    
    // ⚠️ Resets GLOBAL window for ALL tokens!
    _streamStart = uint64(block.timestamp);
    _streamEnd = uint64(block.timestamp + window);
    emit StreamReset(window, _streamStart, _streamEnd);
    
    // Sets per-token amount
    tokenState.streamTotal = amount;
    tokenState.lastUpdate = uint64(block.timestamp);
}
```

**Settlement Function (Uses Global Window):**
```solidity
// src/LevrStaking_v1.sol:536-574
function _settlePoolForToken(address token) internal {
    uint64 start = _streamStart;  // ⚠️ GLOBAL!
    uint64 end = _streamEnd;      // ⚠️ GLOBAL!
    
    // Vesting calculation uses global window
    (uint256 vestAmount, ) = RewardMath.calculateVestedAmount(
        tokenState.streamTotal,
        start,  // ⚠️ Same for all tokens
        end,    // ⚠️ Same for all tokens
        last,
        settleTo
    );
}
```

---

## **SOLUTION DESIGN**

### **Option 1: Per-Token Stream Windows** ✅ RECOMMENDED

Move stream windows from global state into `RewardTokenState` struct.

**Advantages:**
- ✅ Complete isolation between token streams
- ✅ Each token vests independently
- ✅ Clean architecture (no shared state)
- ✅ Backward compatible (can migrate existing streams)

**Disadvantages:**
- Slightly more storage per token (2 extra uint64s = 16 bytes)

### **Option 2: Stream Coordinator** ❌ NOT RECOMMENDED

Keep global window but add coordinator logic to handle overlaps.

**Disadvantages:**
- Complex edge case handling
- Prone to bugs
- Hard to reason about
- No clear advantage

---

## **IMPLEMENTATION PLAN**

### **Phase 1: Update Data Structures**

#### **1.1 Update Interface**

**File:** `src/interfaces/ILevrStaking_v1.sol`

**Change:**
```solidity
struct RewardTokenState {
    uint256 availablePool;
    uint256 streamTotal;
    uint64 lastUpdate;
    bool exists;
    bool whitelisted;
    uint64 streamStart;  // ✅ ADD: Per-token stream start
    uint64 streamEnd;    // ✅ ADD: Per-token stream end
}
```

#### **1.2 Update Contract State**

**File:** `src/LevrStaking_v1.sol`

**Remove global variables:**
```solidity
// REMOVE THESE (lines 40-41):
// uint64 private _streamStart;
// uint64 private _streamEnd;
```

**Update public getters:**
```solidity
// CHANGE (lines 332-340):
// From:
function streamStart() external view override returns (uint256) {
    return _streamStart;
}

function streamEnd() external view override returns (uint256) {
    return _streamEnd;
}

// To:
// REMOVE these functions entirely
// (No longer meaningful - each token has its own window)
```

---

### **Phase 2: Update Stream Logic**

#### **2.1 Update _resetStreamForToken**

**File:** `src/LevrStaking_v1.sol:400-413`

**Change:**
```solidity
function _resetStreamForToken(address token, uint256 amount) internal {
    uint32 window = ILevrFactory_v1(factory).streamWindowSeconds(underlying);
    
    ILevrStaking_v1.RewardTokenState storage tokenState = _tokenState[token];
    
    // ✅ Set PER-TOKEN stream window
    tokenState.streamStart = uint64(block.timestamp);
    tokenState.streamEnd = uint64(block.timestamp + window);
    tokenState.streamTotal = amount;
    tokenState.lastUpdate = uint64(block.timestamp);
    
    // ✅ Event now includes token address
    emit StreamReset(token, window, tokenState.streamStart, tokenState.streamEnd);
}
```

#### **2.2 Update _settlePoolForToken**

**File:** `src/LevrStaking_v1.sol:536-574`

**Change:**
```solidity
function _settlePoolForToken(address token) internal {
    ILevrStaking_v1.RewardTokenState storage tokenState = _tokenState[token];
    
    // ✅ Use PER-TOKEN stream window
    uint64 start = tokenState.streamStart;
    uint64 end = tokenState.streamEnd;
    if (end == 0 || start == 0) return;
    
    // Pause if no stakers (preserves rewards)
    if (_totalStaked == 0) {
        tokenState.lastUpdate = uint64(block.timestamp);
        return;
    }
    
    uint64 last = tokenState.lastUpdate;
    uint64 current = uint64(block.timestamp);
    
    uint64 settleTo;
    if (current > end) {
        if (last >= end) return;
        settleTo = end;
    } else {
        settleTo = current;
    }
    
    // ✅ Vesting calculation now uses per-token window
    (uint256 vestAmount, uint64 newLast) = RewardMath.calculateVestedAmount(
        tokenState.streamTotal,
        start,    // ✅ Per-token start
        end,      // ✅ Per-token end
        last,
        settleTo
    );
    
    if (vestAmount > 0) {
        tokenState.availablePool += vestAmount;
        tokenState.streamTotal -= vestAmount;
    }
    
    tokenState.lastUpdate = newLast;
}
```

#### **2.3 Update _ensureRewardToken**

**File:** `src/LevrStaking_v1.sol:447-453`

**Change:**
```solidity
_tokenState[token] = ILevrStaking_v1.RewardTokenState({
    availablePool: 0,
    streamTotal: 0,
    lastUpdate: 0,
    exists: true,
    whitelisted: wasWhitelisted,
    streamStart: 0,  // ✅ ADD
    streamEnd: 0     // ✅ ADD
});
```

#### **2.4 Update Other Functions Using Global Stream**

**Files to check and update:**

1. `currentAPR()` - lines 373-398
   - Currently uses global `_streamStart`, `_streamEnd`
   - **Change:** Calculate per-token APR or aggregate across all active streams

2. `outstandingRewards()` - lines 266-278
   - Uses global stream for preview
   - **Change:** Use per-token stream for that specific token

---

### **Phase 3: Update Events**

#### **3.1 Update StreamReset Event**

**File:** `src/interfaces/ILevrStaking_v1.sol`

**Change:**
```solidity
// From:
event StreamReset(uint256 windowSeconds, uint64 streamStart, uint64 streamEnd);

// To:
event StreamReset(
    address indexed token,
    uint256 windowSeconds,
    uint64 streamStart,
    uint64 streamEnd
);
```

---

### **Phase 4: Update Interface**

#### **4.1 Remove Global Stream Getters**

**File:** `src/interfaces/ILevrStaking_v1.sol`

**Remove:**
```solidity
function streamStart() external view returns (uint256);
function streamEnd() external view returns (uint256);
```

**Add (Optional - for debugging):**
```solidity
function getTokenStreamInfo(address token) external view returns (
    uint64 streamStart,
    uint64 streamEnd,
    uint256 streamTotal
);
```

---

## **MIGRATION STRATEGY**

### **Backward Compatibility**

**No storage migration needed!**

Since we're:
1. Removing global variables (`_streamStart`, `_streamEnd`)
2. Adding per-token fields to struct

Existing deployments:
- Will have `_streamStart = 0`, `_streamEnd = 0` (won't break)
- New per-token fields will initialize to 0 (correct default)
- First `accrueRewards()` will set per-token windows

**Note:** Any in-progress global streams will reset on next accrual. Document this in changelog.

---

## **TESTING REQUIREMENTS**

### **Test 1: Stream Isolation** (Primary Validation)

```solidity
function test_critical3_tokenStreamsAreIndependent() public {
    // Token A: Stream 1000 over 7 days
    accrueRewards(tokenA, 1000e18);
    
    // 3 days pass
    vm.warp(block.timestamp + 3 days);
    uint256 tokenAVested = outstandingRewards(tokenA);
    assertApproxEqRel(tokenAVested, 428e18, 0.01e18);
    
    // Token B: Stream 500 over 7 days
    accrueRewards(tokenB, 500e18);
    
    // Token A should be UNCHANGED
    uint256 tokenAVestedAfter = outstandingRewards(tokenA);
    assertEq(tokenAVestedAfter, tokenAVested, "Token A affected by token B!");
    
    // 4 more days pass (7 total for token A)
    vm.warp(block.timestamp + 4 days);
    
    // Token A fully vested, Token B partially vested
    assertApproxEqRel(outstandingRewards(tokenA), 1000e18, 0.01e18);
    assertApproxEqRel(outstandingRewards(tokenB), 285e18, 0.01e18); // 4/7 of 500
}
```

### **Test 2: Multiple Simultaneous Streams**

```solidity
function test_multipleSimultaneousStreams() public {
    // Start 3 different streams at different times
    accrueRewards(tokenA, 1000e18);
    
    vm.warp(block.timestamp + 2 days);
    accrueRewards(tokenB, 500e18);
    
    vm.warp(block.timestamp + 2 days); // 4 days from start
    accrueRewards(tokenC, 700e18);
    
    // Check all three vest independently
    vm.warp(block.timestamp + 3 days); // 7 days from tokenA start
    
    // Token A: 7 days → fully vested
    assertApproxEqRel(outstandingRewards(tokenA), 1000e18, 0.01e18);
    
    // Token B: 5 days → 5/7 vested
    assertApproxEqRel(outstandingRewards(tokenB), 357e18, 0.01e18);
    
    // Token C: 3 days → 3/7 vested  
    assertApproxEqRel(outstandingRewards(tokenC), 300e18, 0.01e18);
}
```

### **Test 3: Stream Extension (Existing Behavior)**

```solidity
function test_addingRewardsExtendsTokenStream() public {
    // Token A: 1000 over 7 days
    accrueRewards(tokenA, 1000e18);
    
    // 3 days pass
    vm.warp(block.timestamp + 3 days);
    
    // Add MORE rewards to token A (should extend its stream)
    accrueRewards(tokenA, 500e18);
    
    // Token A now has 1500 total over NEW 7 days
    // (vested 428 moved to pool, 572 + 500 = 1072 streaming)
    
    vm.warp(block.timestamp + 7 days);
    uint256 total = outstandingRewards(tokenA);
    
    // Should be close to 1500 (some rounding)
    assertApproxEqRel(total, 1500e18, 0.05e18);
}
```

### **Test 4: Zero-Staker Period**

```solidity
function test_perTokenStreamsDuringZeroStakerPeriod() public {
    stakeAs(alice, 100e18);
    
    accrueRewards(tokenA, 1000e18);
    accrueRewards(tokenB, 500e18);
    
    // 3 days pass
    vm.warp(block.timestamp + 3 days);
    
    // Alice unstakes (zero stakers)
    vm.prank(alice);
    unstake(100e18, alice);
    
    // 4 days pass (no stakers)
    vm.warp(block.timestamp + 4 days);
    
    // Bob stakes
    stakeAs(bob, 50e18);
    
    // Both tokens should continue vesting from where they left off
    // (vesting paused during zero-staker period)
    
    vm.warp(block.timestamp + 3 days); // Complete remaining vesting
    
    vm.prank(bob);
    claimRewards([tokenA, tokenB], bob);
    
    // Bob should get all rewards (both tokens)
    assertApproxEqRel(tokenA.balanceOf(bob), 1000e18, 0.05e18);
    assertApproxEqRel(tokenB.balanceOf(bob), 500e18, 0.05e18);
}
```

### **Test 5: APR Calculation**

```solidity
function test_aprReflectsAllActiveStreams() public {
    stakeAs(alice, 1000e18);
    
    // Add rewards for multiple tokens
    accrueRewards(tokenA, 3650e18); // 10% APR
    accrueRewards(tokenB, 3650e18); // 10% APR
    accrueRewards(tokenC, 3650e18); // 10% APR
    
    // Total APR should be ~30% (sum of all streams)
    uint256 apr = currentAPR();
    assertApproxEqRel(apr, 3000, 100); // 30% ± 1%
}
```

---

## **IMPLEMENTATION CHECKLIST**

### **Code Changes**

- [ ] Update `RewardTokenState` struct (add `streamStart`, `streamEnd`)
- [ ] Remove global `_streamStart`, `_streamEnd` variables
- [ ] Remove or update `streamStart()`, `streamEnd()` getters
- [ ] Update `_resetStreamForToken()` to use per-token windows
- [ ] Update `_settlePoolForToken()` to use per-token windows
- [ ] Update `_ensureRewardToken()` to initialize new fields
- [ ] Update `outstandingRewards()` to use per-token window
- [ ] Update `currentAPR()` to aggregate all active streams
- [ ] Update `StreamReset` event to include token address
- [ ] Add `getTokenStreamInfo()` getter (optional)

### **Testing**

- [ ] Test: Stream isolation (primary validation)
- [ ] Test: Multiple simultaneous streams
- [ ] Test: Stream extension on same token
- [ ] Test: Zero-staker period handling
- [ ] Test: APR calculation across multiple streams
- [ ] Test: Edge case - token A ends while token B continues
- [ ] Test: Edge case - 10 tokens streaming simultaneously
- [ ] Test: Backward compat - existing contracts can accrueRewards

### **Documentation**

- [ ] Update NatSpec for modified functions
- [ ] Update `spec/USER_FLOWS.md` with multi-token streaming examples
- [ ] Update `CHANGELOG.md` with breaking changes
- [ ] Add migration notes for existing deployments

### **Validation**

- [ ] Run full test suite (unit + e2e)
- [ ] Verify no regressions in existing tests
- [ ] Run gas comparison (should be minimal increase)
- [ ] Verify `testCritical3_tokenStreamsAreIndependent` PASSES

---

## **AFFECTED FILES**

### **Source Code (3 files)**

1. **`src/interfaces/ILevrStaking_v1.sol`**
   - Update `RewardTokenState` struct
   - Update `StreamReset` event
   - Remove `streamStart()`, `streamEnd()` getters
   - Add `getTokenStreamInfo()` (optional)

2. **`src/LevrStaking_v1.sol`**
   - Remove global `_streamStart`, `_streamEnd`
   - Update `_resetStreamForToken()`
   - Update `_settlePoolForToken()`
   - Update `_ensureRewardToken()`
   - Update `outstandingRewards()`
   - Update `currentAPR()`
   - Remove `streamStart()`, `streamEnd()` getters

3. **`src/libraries/RewardMath.sol`**
   - No changes needed (pure functions work with any window)

### **Tests (2 new files)**

4. **`test/unit/LevrStaking.PerTokenStreams.t.sol`** (NEW)
   - All validation tests from above

5. **`test/unit/LevrExternalAudit4.Validation.t.sol`** (EXISTING)
   - Should now PASS after fix

---

## **EDGE CASES TO HANDLE**

### **1. Token Stream Ends While Others Continue**

```solidity
// Token A: 7-day stream ends at T7
// Token B: 7-day stream ends at T10 (started later)
// Time T8: Token A fully vested, Token B still streaming
// ✅ Both work independently
```

### **2. Adding Rewards Mid-Stream (Same Token)**

```solidity
// Token A: 1000 streaming over 7 days
// Day 3: Add 500 more to Token A
// Result: Extends Token A's stream (existing behavior)
// ✅ Token B unaffected
```

### **3. APR Calculation with Multiple Active Streams**

```solidity
// 3 tokens streaming simultaneously
// APR = sum of all annual rates
// currentAPR() should aggregate:
//   APR = (tokenA_annual + tokenB_annual + tokenC_annual) / totalStaked
```

**Implementation:**
```solidity
function currentAPR() public view returns (uint256) {
    if (_totalStaked == 0) return 0;
    
    uint256 totalAnnualRate = 0;
    uint32 window = ILevrFactory_v1(factory).streamWindowSeconds(underlying);
    
    // Sum annual rates from all active streams
    for (uint256 i = 0; i < _rewardTokens.length; i++) {
        address token = _rewardTokens[i];
        RewardTokenState storage tokenState = _tokenState[token];
        
        if (tokenState.streamTotal > 0 && tokenState.streamEnd > block.timestamp) {
            uint256 rate = tokenState.streamTotal / window;
            uint256 annual = rate * 365 days;
            totalAnnualRate += annual;
        }
    }
    
    return (totalAnnualRate * BASIS_POINTS) / _totalStaked;
}
```

### **4. All Streams Inactive**

```solidity
// No active streams
// currentAPR() should return 0
// outstandingRewards() should only show availablePool (no streaming)
```

### **5. First Accrual After Deployment**

```solidity
// Fresh deployment: streamStart = 0, streamEnd = 0
// First accrueRewards(tokenA) sets tokenA.streamStart/End
// ✅ Works normally
```

---

## **GAS IMPACT ANALYSIS**

### **Storage Changes**

**Per Token:**
- Add: 2 × uint64 = 128 bits = 16 bytes
- Cost: ~20k gas on first accrual (SSTORE cold)
- Ongoing: No additional cost (already reading tokenState)

**Global:**
- Remove: 2 × uint64 = 128 bits = 16 bytes  
- Savings: ~20k gas on deployment

**Net Impact:** Approximately neutral (slightly more gas per token, but cleaner architecture)

### **Function Gas Changes**

| Function | Before | After | Change |
|----------|--------|-------|--------|
| `accrueRewards()` | Read 2 global | Read/write 2 per-token | ~neutral |
| `_settlePoolForToken()` | Read 2 global | Read 2 per-token | ~neutral |
| `claimRewards()` | Read global once | Read per-token in loop | +2k gas |

**Worst Case:** Claiming 10 tokens → +20k gas (negligible vs total claim cost ~100k+)

---

## **SECURITY CONSIDERATIONS**

### **Attack Vectors Eliminated**

✅ **Stream Collision Attack**
- Before: Attacker accrues 1 wei to reset ALL streams
- After: Each token stream independent

✅ **Vesting Manipulation**
- Before: Can delay other tokens' vesting
- After: Cannot affect other tokens

### **New Attack Vectors**

❌ None identified - This fix REDUCES attack surface

---

## **ROLLOUT PLAN**

### **Step 1: Development (1 day)**
1. Update struct and interfaces
2. Update all affected functions
3. Run validation test - should PASS
4. Run full unit test suite

### **Step 2: Testing (0.5 days)**
1. Add comprehensive multi-token tests
2. Test edge cases
3. Gas benchmarking
4. Check for regressions

### **Step 3: Documentation (0.5 days)**
1. Update NatSpec
2. Update user documentation
3. Write migration guide
4. Update CHANGELOG

### **Step 4: Validation (Final)**
1. Run all tests with `via_ir` (default profile)
2. Deploy to testnet
3. Verify behavior in real environment
4. Mark CRITICAL-3 as RESOLVED

---

## **SUCCESS CRITERIA**

**Test:** `testCritical3_tokenStreamsAreIndependent` PASSES ✅

**Acceptance Criteria:**
- [x] Token A vesting shows ~428e18 after 3 days
- [x] Adding Token B rewards does NOT affect Token A
- [x] Token A fully vests to 1000e18 after 7 days total
- [x] No regressions in existing test suite
- [x] Gas impact < 5% increase

---

## **REFERENCES**

**Current Implementation:**
- `src/LevrStaking_v1.sol:40-41` - Global stream variables
- `src/LevrStaking_v1.sol:400-413` - `_resetStreamForToken()`
- `src/LevrStaking_v1.sol:536-574` - `_settlePoolForToken()`

**Related Issues:**
- EXTERNAL_AUDIT_4_ACTIONS.md (this finding)
- Test: `test/unit/LevrExternalAudit4.Validation.t.sol:81-141`

**Similar Patterns:**
- Compound: Per-market state
- Aave: Per-reserve state
- MasterChef: Per-pool state

---

**Created:** November 1, 2025  
**Author:** External Audit 4 Validation  
**Status:** Ready for Implementation

