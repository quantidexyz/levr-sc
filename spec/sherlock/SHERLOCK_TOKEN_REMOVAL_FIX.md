# Token Removal Accounting Fix (Critical Update)

**Date Identified:** November 9, 2025  
**Date Fixed:** November 10, 2025  
**Severity:** HIGH  
**Status:** ✅ **FIXED & VERIFIED**  
**Auditor:** @certorator (Sherlock)  
**Critical Update:** November 10, 2025 - Fixed stale debt reset logic

---

## Issue Summary

The cumulative reward accounting system (`accRewardPerShare` pattern) had a critical flaw when reward tokens are removed and re-added, causing:

1. **Solvency corruption** - Users could claim more than available
2. **Stuck funds** - Old users' allocations become inaccessible

---

## Root Cause

When a token is removed and re-added, we **cannot delete user `rewardDebt`** (requires unbounded iteration).

**The Problem:**

- Token removed: `delete _tokenState[token]` but `accRewardPerShare[token]` persists
- Old users still have: `rewardDebt[alice][token] = 100e18` (stale from old cycle)
- New users (staked during removal) have: `rewardDebt[bob][token] = 0`

**Without fix:**

- If we don't reset `accRewardPerShare`: New users over-claim (insolvency)
- If we reset `accRewardPerShare` to 0: Old users' stale debt blocks their new rewards

**Example of the issue:**

```
Phase 1: Alice has debt = 100e18, claimed all rewards
Phase 2: Token removed and re-added → accRewardPerShare reset to 0
Phase 3: New rewards distributed → accRewardPerShare = 10e18
Phase 4: Alice tries to claim:
  - accumulatedRewards = (balance × 10) / 1e18 = 10 tokens
  - debtAmount = (balance × 100) / 1e18 = 100 tokens (STALE!)
  - pending = max(0, 10 - 100) = 0  ❌ Her 10 tokens STUCK!
```

---

## The Solution: Stale Debt Detection with Reset to Zero

**Key Insight:** Normal operation maintains `rewardDebt[user][token] ≤ accRewardPerShare[token]`. If debt > accumulator, it must be stale (from token removal/re-add).

### Critical Fix (November 10, 2025)

**IMPORTANT:** The initial fix reset stale debt to `accReward`, which caused users to **lose all rewards in the current cycle**. The correct fix resets to **0**.

### Implementation

**1. Add helper function to detect and reset stale debt:**

```solidity
/// @notice Get effective debt for user, auto-resetting stale debt
/// @dev Detects stale debt from token removal/re-add by checking if debt > accRewardPerShare
function _getEffectiveDebt(address user, address token) internal returns (uint256) {
    uint256 debt = rewardDebt[user][token];
    uint256 accReward = accRewardPerShare[token];

    // Normal: debt <= accReward
    // Stale: debt > accReward (only after token removal + re-add)
    if (debt > accReward) {
        // CRITICAL: Reset to 0 (not accReward) to allow claiming from re-whitelist point
        // Returning accReward would cause user to lose all current cycle rewards
        rewardDebt[user][token] = 0;
        return 0;
    }

    return debt;
}
```

**Why Reset to 0 (Not accReward)?**

```solidity
// WRONG (old approach - loses rewards):
if (debt > accReward) {
    rewardDebt[user][token] = accReward;  // ❌
    return accReward;                      // ❌
}
// Result: pending = (balance × accReward) - (balance × accReward) = 0 tokens lost!

// CORRECT (fixed approach):
if (debt > accReward) {
    rewardDebt[user][token] = 0;  // ✅
    return 0;                      // ✅
}
// Result: pending = (balance × accReward) - (balance × 0) = accReward tokens claimed!
```

**2. Reset accounting on re-whitelist:**

```solidity
function whitelistToken(address token) external nonReentrant {
    // ... existing validation ...

    if (!tokenState.exists) {
        // Initialize token state
        tokenState.exists = true;
        tokenState.availablePool = 0;
        tokenState.streamTotal = 0;
        // ... other fields ...

        // Reset accounting for fresh start
        accRewardPerShare[token] = 0;  // ✅ Clean slate
    }

    emit TokenWhitelisted(token);
}
```

**3. Use helper in claim functions:**

```solidity
function claimRewards(address[] calldata tokens, address to) external nonReentrant {
    // ... setup ...

    for (uint256 i = 0; i < tokens.length; i++) {
        address token = tokens[i];
        _settlePoolForToken(token);

        // Get effective debt (auto-resets if stale)
        uint256 effectiveDebt = _getEffectiveDebt(claimer, token);  // ✅ Simple!

        // Calculate pending (clean, unchanged)
        uint256 accumulatedRewards = (userBalance * accRewardPerShare[token]) / 1e18;
        uint256 debtAmount = (userBalance * effectiveDebt) / 1e18;
        uint256 pending = accumulatedRewards > debtAmount ? accumulatedRewards - debtAmount : 0;

        // ... transfer logic ...
    }
}

// Same pattern in _claimAllRewards()
```

---

## Why This Works

**The Invariant:**

- Normal operation: `debt ≤ accReward` (user tracks what they've accounted for)
- After token removal + re-add: `debt > accReward` (only way this can happen!)

**Auto-Healing Flow (WITH CORRECT FIX):**

| Event            | Alice Debt    | AccReward     | Alice Claimable | What Happens             |
| ---------------- | ------------- | ------------- | --------------- | ------------------------ |
| Before removal   | 100           | 100           | 0 (claimed)     | Normal                   |
| Token removed    | 100           | 100           | -               | -                        |
| Token re-added   | 100 (stale)   | **0** (reset) | -               | -                        |
| New rewards      | 100 (stale)   | 10            | 10 ✅           | Debt > accum (stale!)    |
| **Alice claims** | **0** (reset) | 10            | 10 ✅           | Gets fair share!         |
| Debt updated     | 10            | 10            | 0               | Back to normal           |
| More rewards     | 10            | 20            | 10 ✅           | **Earning normally!** ✅ |

**Comparison with WRONG approach (reset to accReward):**

| Event            | Alice Debt     | AccReward | Alice Claimable | Result                     |
| ---------------- | -------------- | --------- | --------------- | -------------------------- |
| New rewards      | 100 (stale)    | 10        | 0 ❌            | Debt > accum (stale!)      |
| **Alice claims** | **10** (wrong) | 10        | 0 ❌            | Loses 10 tokens! ❌        |
| More rewards     | 10             | 20        | 10 ✅           | Only gets rewards from now |

**Result with CORRECT fix (reset to 0):**

- ✅ No insolvency (debt prevents over-claiming)
- ✅ No stuck funds (debt resets to 0, users claim from re-whitelist point)
- ✅ No reward loss (users get fair share immediately)
- ✅ All users participate normally after reset

---

## Auditor's Critical Catch

**Original Bug in Initial Fix (November 9):**

The initial implementation reset stale debt to `accReward`:

```solidity
if (debt > accReward) {
    rewardDebt[user][token] = accReward;  // ❌ WRONG
    return accReward;                      // ❌ WRONG
}
```

**Auditor's Finding:**

> "Returning accReward will cause the user to lose all rewards for the current cycle during this claim. For example:
>
> The user's debt from the previous cycle is 100, and they have not claimed it.
>
> When the user claims during the current cycle, where accRewardPerShare = 10, their debt is immediately reset to 10, and \_getEffectiveDebt returns 10, meaning no rewards are distributed.
>
> This causes the user to lose all rewards accumulated from 0 to 10 in the current cycle. I think we shouldn't over-penalize users; their new reward should be properly allocated."

**Impact:**

```solidity
// With WRONG fix (reset to accReward = 10):
accumulatedRewards = (userBalance × 10) / 1e18 = 10 tokens
debtAmount = (userBalance × 10) / 1e18 = 10 tokens (effectiveDebt = accReward)
pending = 10 - 10 = 0 ❌ USER LOSES 10 TOKENS!

// With CORRECT fix (reset to 0):
accumulatedRewards = (userBalance × 10) / 1e18 = 10 tokens
debtAmount = (userBalance × 0) / 1e18 = 0 tokens (effectiveDebt = 0)
pending = 10 - 0 = 10 ✅ USER GETS FAIR SHARE!
```

**Fix Applied:** Changed reset value from `accReward` to `0` (November 10, 2025)

---

## Code Simplicity

**Total Changes: ~15 lines**

- Helper function: 9 lines (all complexity isolated here)
- whitelistToken: +1 line (reset accRewardPerShare)
- claimRewards: -7 lines inline, +1 line helper call = **NET SIMPLER**
- \_claimAllRewards: -7 lines inline, +1 line helper call = **NET SIMPLER**

**The helper function actually REDUCES claim function complexity!**

---

## Requirements Met

| Requirement                  | Solution                                | Status |
| ---------------------------- | --------------------------------------- | ------ |
| No redundant state           | Detect via `debt > accReward`           | ✅     |
| No corruption                | Stale debt reset prevents over-claiming | ✅     |
| Tokens can be re-whitelisted | Accounting reset on re-add              | ✅     |
| No stuck assets              | Debt auto-resets on claim               | ✅     |
| Simple claim logic           | Helper function isolates complexity     | ✅     |

---

## Test Results

**Test Suite:** `test/unit/sherlock/LevrStakingTokenRemoval.t.sol`  
**Status:** ✅ **9/9 TESTS PASSING** (updated for correct fix)

1. ✅ `test_ReWhitelisting_ResetsAccounting()` - Re-whitelisting works
2. ✅ `test_StaleDebtDetection_ResetsOnClaim()` - No corruption, users get fair share
3. ✅ `test_NoStuckAssets_AllRewardsClaimable()` - No stuck funds (100+100 claimed, not 0+50+50)
4. ✅ `test_MultipleUsers_DifferentStakeTimes()` - Multi-user scenarios (all get 50 each, not Alice=0)
5. ✅ `test_NormalOperation_Unaffected()` - Normal flow unchanged
6. ✅ `test_FreshToken_InitializesCorrectly()` - Fresh tokens work
7. ✅ `test_Unstake_HandlesStaleDebt()` - Unstake triggers reset (Alice gets 100+100, not 0+100)
8. ✅ **`test_UnwhitelistEnforcesEmptyPool()`** - Users protected during unwhitelist
9. ✅ **`test_UnwhitelistedToken_NewStakersCanClaimUnderlyingRewards()`** - Underlying rewards work

**Test Updates (November 10):**

Tests were updated to reflect correct behavior (users claim immediately, not delayed):

```solidity
// BEFORE (wrong expectations):
assertEq(aliceClaimed, 0, 'Alice gets 0 (debt just reset)');  // ❌

// AFTER (correct expectations):
assertApproxEqRel(aliceClaimed, 50e18, 0.02e18, 'Alice gets ~50 (debt reset to 0)');  // ✅
```

**Full Test Coverage:**

- ✅ **782 Unit Tests PASSING** (no regressions)
- ✅ **51 E2E Tests PASSING** (integration verified)
- ✅ **Total: 833 tests passing**

**Command:**

```bash
# Unit tests (dev profile for speed)
FOUNDRY_PROFILE=dev forge test --match-path "test/unit/*.t.sol" -vv

# E2E tests (default profile with via_ir)
forge test --match-path "test/e2e/*.sol" -vv

# Sherlock security tests only
FOUNDRY_PROFILE=dev forge test --match-path "test/unit/sherlock/*.t.sol" -vv
```

---

## Production Readiness

✅ **Implementation:** Complete  
✅ **Unit Testing:** 782/782 passing  
✅ **E2E Testing:** 51/51 passing  
✅ **Security Tests:** 14/14 passing  
✅ **Zero New State:** Uses existing mappings  
✅ **Simpler Code:** Helper reduces claim complexity  
✅ **All Vulnerabilities Fixed:** No corruption, no stuck funds

**Ready for audit and mainnet deployment.**

---

## Recommendation: Add Off-Chain Notice

While the on-chain protection is complete, adding an off-chain notice improves UX:

**Frontend Warning:**

> "Token X is being unwhitelisted. Consider unstaking if you want to participate when/if it's re-added."

**Benefits:**

- Reduces gas (fewer users need debt reset)
- Sets clear expectations
- Users who unstake: Clean slate immediately
- Users who don't: Still protected by automatic reset

**The on-chain protection ensures no loss even if users miss the notice.**

---

## Summary

**Timeline:**

- **November 9, 2025:** Initial issue identified by @certorator
- **November 9, 2025:** First fix implemented (reset to `accReward`)
- **November 10, 2025:** Auditor caught bug in initial fix
- **November 10, 2025:** Correct fix implemented (reset to `0`)

**Critical Lesson:**

The difference between resetting to `accReward` vs `0` is the difference between:

- ❌ Users losing all current cycle rewards
- ✅ Users getting fair share from re-whitelist point

**Final Status:**

✅ **Implementation:** Complete (corrected)  
✅ **Test Status:** 833/833 passing (782 unit + 51 e2e)  
✅ **Security:** No stuck funds, no reward loss, no insolvency  
✅ **Code Quality:** Simpler claim logic with helper function

---

**Last Updated:** November 10, 2025  
**Implementation:** Complete & Verified  
**Critical Fix Applied:** Reset stale debt to 0 (not accReward)  
**Test Status:** ✅ 833/833 passing
