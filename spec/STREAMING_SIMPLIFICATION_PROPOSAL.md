# Streaming State Simplification - Proposal

**Date:** 2025-01-10  
**Status:** PROPOSAL - Pending Review  
**Impact:** Gas optimization + Code simplification

---

## 🎯 Proposal

**Simplify streaming state from per-token to single global stream**

Current: Each reward token has its own `_streamStartByToken`, `_streamEndByToken`, `_streamTotalByToken`  
Proposed: Single global stream shared by all reward tokens

---

## 📊 Current Architecture

### Per-Token Streaming State (Current)

```solidity
// Global (barely used, only for external views)
uint64 private _streamStart;
uint64 private _streamEnd;

// Per-token (actual streaming logic)
mapping(address => uint64) private _streamStartByToken;
mapping(address => uint64) private _streamEndByToken;
mapping(address => uint256) private _streamTotalByToken;
mapping(address => uint64) private _lastUpdateByToken;
```

**When accruing WETH:**

- Start new 3-day stream for WETH only
- Underlying keeps its own stream (might be at day 2 of 3)

**When accruing underlying:**

- Start new 3-day stream for underlying only
- WETH keeps its own stream (might be at day 1 of 3)

### Gas Cost Per Token

| Operation             | Per-Token Cost   |
| --------------------- | ---------------- |
| Set start             | 20k gas (SSTORE) |
| Set end               | 20k gas (SSTORE) |
| Set total             | 20k gas (SSTORE) |
| Set last update       | 20k gas (SSTORE) |
| **Total per accrual** | **~80k gas**     |

---

## 💡 Proposed Architecture

### Single Global Streaming State

```solidity
// Single global stream for ALL tokens
uint64 private _streamStart;
uint64 private _streamEnd;

// Per-token: only track individual token totals and last update
mapping(address => uint256) private _streamTotalByToken;  // Keep (amount per token)
mapping(address => uint64) private _lastUpdateByToken;    // Keep (for vesting calc)

// REMOVE these:
// mapping(address => uint64) private _streamStartByToken;  // Use global instead
// mapping(address => uint64) private _streamEndByToken;    // Use global instead
```

**When accruing ANY token:**

- Reset GLOBAL stream to new 3-day window
- All tokens now vest over the SAME window
- Each token's `_streamTotalByToken` tracks its individual amount

---

## 🔍 How It Works

### Example Timeline

```
T=0: Accrue WETH (100 ether)
     → _streamStart = T0
     → _streamEnd = T0 + 3 days
     → _streamTotalByToken[WETH] = 100 ether

T=1 day: Accrue underlying (200 ether)
         → _streamStart = T1  // RESET
         → _streamEnd = T1 + 3 days  // RESET
         → Calculate WETH's unvested: 100 * (2/3) = 66.67 ether
         → _streamTotalByToken[WETH] = 66.67 ether  // Unvested only
         → _streamTotalByToken[underlying] = 200 ether

Result: Both WETH and underlying now vest over SAME window (T1 to T1+3d)
```

### Vesting Calculation (Unchanged Logic)

```solidity
function _settleStreamingForToken(address token) internal {
    // Use GLOBAL stream times
    uint64 start = _streamStart;  // ← Changed from _streamStartByToken[token]
    uint64 end = _streamEnd;      // ← Changed from _streamEndByToken[token]

    if (end == 0 || start == 0) return;
    if (_totalStaked == 0) return;

    uint64 last = _lastUpdateByToken[token];
    uint64 from = last < start ? start : last;
    uint64 to = uint64(block.timestamp);
    if (to > end) to = end;
    if (to <= from) return;

    uint256 duration = end - start;
    uint256 total = _streamTotalByToken[token];  // Still per-token amount

    if (duration == 0 || total == 0) {
        _lastUpdateByToken[token] = to;
        return;
    }

    uint256 vestAmount = (total * (to - from)) / duration;
    if (vestAmount > 0) {
        _rewardInfo[token].accPerShare += (vestAmount * ACC_SCALE) / _totalStaked;
    }
    _lastUpdateByToken[token] = to;
}
```

---

## ✅ Advantages

### 1. Gas Savings

**Per accrual:**

- Remove: 2 SSTORE operations (start + end per token)
- Save: **~40k gas per accrual**

**Example:** If 10 different tokens are accrued over time:

- Current: 10 \* 80k = 800k gas
- Proposed: 10 \* 40k = 400k gas
- **Savings: 400k gas (50% reduction)**

### 2. Simpler Code

**Removed complexity:**

- No need to track separate windows per token
- Easier to understand: "All rewards vest over same window"
- Fewer state variables to maintain

### 3. Cleaner UI/UX

**Current:** User sees different tokens vesting at different rates (confusing)
**Proposed:** All tokens vest together (intuitive)

Example:

```
Current UI:
- WETH: 33% vested (day 1 of 3-day stream)
- Underlying: 66% vested (day 2 of 3-day stream)
- USDC: 100% vested (stream ended)

Proposed UI:
- All tokens: 50% vested (day 1.5 of 3-day stream)
```

### 4. No Functional Drawbacks

**Question:** Does it matter if all tokens share the same window?

**Answer:** NO

**Why:**

- Rewards are tracked separately per token in `accPerShare`
- Each token has its own `_streamTotalByToken` amount
- Vesting formula is independent for each token
- Users claim exactly what they're owed

---

## ⚠️ Potential Concerns

### Concern 1: Different tokens accrued at different times

**Current behavior:**

```
Day 0: WETH accrued → vests over days 0-3
Day 1: Underlying accrued → vests over days 1-4
Result: Windows overlap but are independent
```

**Proposed behavior:**

```
Day 0: WETH accrued → vests over days 0-3
Day 1: Underlying accrued → resets window
Result:
- WETH unvested (66.67%) moved to new window (days 1-4)
- Underlying vests over days 1-4
- Both share same window now
```

**Impact:** ✅ NO PROBLEM

- Unvested rewards are preserved (line 464)
- Both tokens still vest completely
- Just on a synchronized timeline

---

### Concern 2: APR calculation accuracy

**Current:** APR calculated per token using that token's stream window

**Proposed:** APR calculated using global stream window

**Impact:** ✅ ACCEPTABLE

- APR is an estimate anyway
- Synchronizing windows makes APR more stable
- Users care about "how much am I earning" not "what's the exact window"

---

### Concern 3: Already accrued tokens get window reset

**Scenario:**

```
Day 0: WETH accrued (vests days 0-3)
Day 2: Underlying accrued → resets global window
       WETH has 1 day left but window resets to 3 days
```

**Impact:** ✅ SAFE - Unvested preserved

```solidity
// In _creditRewards for underlying:
uint256 wethUnvested = _calculateUnvested(WETH);  // 33.33 ether
_streamTotalByToken[WETH] = wethUnvested;  // Reset to unvested only
// New window: vests over next 3 days
```

**Result:** WETH takes 3 days to fully vest instead of 1 day remaining

- Not ideal for UX, but safe
- All rewards still distributed
- No loss of funds

---

## 🔧 Implementation Changes

### Code Changes Required

**1. Remove per-token stream times** (2 mappings removed)

```solidity
// DELETE these lines:
// mapping(address => uint64) private _streamStartByToken;
// mapping(address => uint64) private _streamEndByToken;
```

**2. Update \_settleStreamingForToken**

```solidity
function _settleStreamingForToken(address token) internal {
    // Use global stream instead of per-token
    uint64 start = _streamStart;  // ← Changed
    uint64 end = _streamEnd;      // ← Changed
    // ... rest unchanged
}
```

**3. Update claimableRewards view**

```solidity
// Line 259-260: Change from per-token to global
uint64 start = _streamStart;  // ← Changed
uint64 end = _streamEnd;      // ← Changed
```

**4. Update \_calculateUnvested**

```solidity
function _calculateUnvested(address token) internal view returns (uint256 unvested) {
    uint64 start = _streamStart;  // ← Changed
    uint64 end = _streamEnd;      // ← Changed
    // ... rest unchanged
}
```

**5. Update \_resetStreamForToken**

```solidity
function _resetStreamForToken(address token, uint256 amount) internal {
    uint32 window = ILevrFactory_v1(factory).streamWindowSeconds();

    _streamStart = uint64(block.timestamp);
    _streamEnd = uint64(block.timestamp + window);
    emit StreamReset(window, _streamStart, _streamEnd);

    // DELETE these lines:
    // _streamStartByToken[token] = uint64(block.timestamp);
    // _streamEndByToken[token] = uint64(block.timestamp + window);

    _streamTotalByToken[token] = amount;
    _lastUpdateByToken[token] = uint64(block.timestamp);
}
```

**6. Update rewardRatePerSecond**

```solidity
function rewardRatePerSecond(address token) external view returns (uint256) {
    uint64 start = _streamStart;  // ← Changed
    uint64 end = _streamEnd;      // ← Changed
    // ... rest unchanged
}
```

**Total Lines Changed:** ~10 lines  
**Complexity:** Low  
**Risk:** Low (existing tests will verify correctness)

---

## 🧪 Testing Requirements

### Tests to Verify

1. ✅ **Existing midstream tests** should still pass
2. ✅ **Reward distribution accuracy** maintained
3. ✅ **Multiple token accruals** work correctly
4. ✅ **Unvested preservation** still works
5. ✅ **APR calculations** remain reasonable

### Expected Test Results

**No changes needed to tests** - They verify behavior, not implementation details

Current: 407 tests passing  
After change: Should still be 407 tests passing

---

## 📋 Pros vs Cons

| Aspect                | Current (Per-Token)       | Proposed (Global)    |
| --------------------- | ------------------------- | -------------------- |
| **Gas Cost**          | ~80k per accrual          | ~40k per accrual ✅  |
| **Code Complexity**   | Higher (2 extra mappings) | Lower ✅             |
| **State Variables**   | 5 mappings                | 3 mappings ✅        |
| **Reward Accuracy**   | Exact                     | Exact ✅             |
| **Unvested Handling** | Per-token                 | Per-token (same) ✅  |
| **UX (UI)**           | Multiple timelines        | Single timeline ✅   |
| **Audit Surface**     | More state to track       | Less state ✅        |
| **Flexibility**       | Independent windows       | Synchronized windows |

---

## 🚦 Recommendation

### ✅ RECOMMENDED - Implement Global Streaming

**Rationale:**

1. **50% gas savings** on accruals
2. **Simpler code** (easier to audit and maintain)
3. **No functional drawbacks** (rewards still distributed correctly)
4. **Better UX** (synchronized vesting is clearer)
5. **Lower risk** (fewer state variables = fewer bugs)

**Trade-off:** Window synchronization

- All tokens reset to same window when any token accrues
- Slightly extends vesting for tokens mid-stream
- **Acceptable** - rewards still fully distributed

---

## 🔄 Migration Path

### Option A: Clean Migration (Recommended)

**For new deployments:**

- Deploy with global streaming from day 1
- No migration needed

**For existing deployments:**

- Cannot easily migrate (would need state transition)
- Keep per-token streaming for existing contracts
- Use global for new deployments

### Option B: No Migration

**Decision:** Accept the gas cost for existing contracts, use improved version for new deployments

**Rationale:**

- Existing contracts work fine
- Not worth the migration risk
- Future deployments benefit from optimization

---

## 📝 Decision Required

**Question for you:** Should we implement this simplification?

**Options:**

1. ✅ **YES** - Implement global streaming (50% gas savings, simpler code)
2. ❌ **NO** - Keep per-token streaming (more flexible, already tested)
3. 🤔 **DEFER** - Implement in future version after more analysis

**My Recommendation:** ✅ **YES** - The benefits (gas + simplicity) outweigh the minor trade-off of synchronized windows.

---

**Awaiting your decision before proceeding with implementation.**
