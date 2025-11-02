# Bugs and Issues Found During Coverage Testing

**Started:** November 2, 2025  
**Purpose:** Track code quality issues discovered while improving test coverage  
**Status:** Active tracking document

---

## Summary

| Issue | Severity | Status | Found Date | Resolution |
|-------|----------|--------|------------|------------|
| Dead Code: `calculateUnvested()` | MEDIUM | **OPEN** | Nov 2, 2025 | Removal recommended |

---

## Issue #1: Dead Code in RewardMath.sol

**Date Found:** November 2, 2025  
**Discovered By:** Coverage analysis (branch coverage = 12.50%)  
**Contract:** `src/libraries/RewardMath.sol`  
**Function:** `calculateUnvested()`  
**Lines:** 48-83 (35 lines of dead code)  
**Severity:** MEDIUM (code quality, not security)  
**Status:** **OPEN** - Awaiting removal

---

### The Issue

**Dead Code:** Function `calculateUnvested()` is defined but **never called** in production code.

**Evidence:**
```bash
$ grep -r "calculateUnvested" src/ --include="*.sol" | grep -v "^src/libraries/RewardMath.sol"
# Result: No matches - function is NEVER called!
```

**Current Production Code Uses:**
```solidity
// src/LevrStaking_v1.sol:508 - What's ACTUALLY used
function _creditRewards(address token, uint256 amount) internal {
    _settlePoolForToken(token);
    _resetStreamForToken(token, amount + tokenState.streamTotal);
    // ✅ Uses streamTotal directly - bypasses calculateUnvested entirely
}
```

---

### Historical Context

**Original Purpose:**
- Calculate unvested rewards when resetting streams
- Preserve unvested amount from paused/interrupted streams
- Used in mid-stream accrual scenarios

**Bug History:**
- **October 2025:** Function had critical bug in "stream still active" branch
- **Bug Impact:** 16.67% permanent fund loss when streams paused mid-stream
- **Root Cause:** Line 78-82 assumed continuous vesting, ignored `last` parameter
- **Documentation:** `spec/external-2/CRITICAL_FINDINGS_POST_OCT29_CHANGES.md` (CRITICAL-NEW-1)

**Resolution:**
- Bug was "fixed" by replacing entire approach with simpler `streamTotal` usage
- Original function never removed from codebase
- Left as dead code with known bug still present

---

### The Bug (Still Present in Dead Code)

**Location:** `src/libraries/RewardMath.sol:77-82`

**Buggy Code:**
```solidity
// Stream still active - calculate unvested based on elapsed time
uint64 effectiveTime = last < current ? last : current;
uint256 elapsed = effectiveTime > start ? effectiveTime - start : 0;
uint256 vested = (total * elapsed) / duration;

return total > vested ? total - vested : 0;
```

**The Problem:**
```
When stream is paused (totalStaked = 0):
- lastUpdate freezes at pause point
- No vesting occurs during pause
- But this code calculates elapsed from START, not from LAST
- Treats paused time as if vesting continued
- Results in INCORRECT unvested calculation

Example:
- Stream: 1000 tokens over 3 days (T0 to T3)
- T1: Pause (last = T1, 333 tokens vested)
- T1.5: Resume (current = T1.5)
- Expected unvested: 1000 - 333 = 667 tokens ✓
- Actual calculation: 1000 - 500 = 500 tokens ❌
- Missing: 167 tokens (16.67% loss)
```

**Correct Code Would Be:**
```solidity
// Use last instead of calculating from start
uint256 elapsed = last > start ? last - start : 0;  // ✅ Respect pause point
uint256 vested = (total * elapsed) / duration;
return total > vested ? total - vested : 0;
```

---

### Impact on Coverage

**Why Coverage is Low:**

- RewardMath.sol has 8 branches total
- calculateUnvested() contains ~7-8 branches (87.5%)
- Only 1 branch covered (12.50%) - all uncovered branches are in DEAD CODE
- Coverage metrics misleading due to dead code

**After Removal:**

- Remove 35 lines of dead buggy code
- Remove ~7-8 untested branches
- RewardMath coverage: 12.50% → ~80% instantly
- Overall coverage: 29.11% → ~30.75% (+1.64%)
- More accurate coverage of actual production code

---

### Recommended Action

**Option 1: Remove Dead Code (STRONGLY RECOMMENDED)**

```bash
# 1. Backup
git add -A && git commit -m "Backup before removing dead code"

# 2. Remove function (lines 41-83 in RewardMath.sol)
# Delete:
# - Documentation comment (lines 41-47)
# - Function signature (lines 48-54)
# - Function body (lines 55-83)

# 3. Verify no broken imports/tests
FOUNDRY_PROFILE=dev forge test --match-path "test/unit/*.t.sol" -vvv

# 4. Re-run coverage
FOUNDRY_PROFILE=dev forge coverage --match-path "test/unit/*.t.sol" --ir-minimum
# Expected: RewardMath 12.50% → ~80%

# 5. Update tests
# Remove calculateUnvested tests from RewardMath.CompleteBranchCoverage.t.sol
# (tests for lines 233-259, 274-284, 410-420, 457-466)

# 6. Commit
git add -A && git commit -m "Remove dead code: calculateUnvested() with historical bugs"

# 7. Document in HISTORICAL_FIXES.md
```

**Files to Update:**
- ✅ `src/libraries/RewardMath.sol` - Remove function
- ✅ `test/unit/RewardMath.CompleteBranchCoverage.t.sol` - Remove dead code tests
- ✅ `test/unit/RewardMath.DivisionSafety.t.sol` - Remove if testing dead function
- ✅ `spec/HISTORICAL_FIXES.md` - Document removal
- ✅ `spec/COVERAGE_ANALYSIS.md` - Update baseline metrics

---

**Option 2: Fix Bug (If Intended for Future Use)**

```solidity
// src/libraries/RewardMath.sol:77-82
// Replace buggy calculation with correct one:

function calculateUnvested(...) internal pure returns (uint256 unvested) {
    // ... (keep early returns)
    
    // FIX: Stream still active - use LAST not START
    uint256 elapsed = last > start ? last - start : 0;  // ✅ Use last
    uint256 vested = (total * elapsed) / duration;
    
    return total > vested ? total - vested : 0;
}
```

**But:** Since function is unused, fixing it without a use case is premature optimization.

---

**Option 3: Keep and Document (NOT RECOMMENDED)**

Keeping buggy dead code:
- ❌ Increases attack surface
- ❌ Confuses future developers
- ❌ Wastes coverage effort
- ❌ May be accidentally used later (with bugs!)

**Not recommended** unless there's a concrete plan to use it.

---

### Verification Steps

**To verify this is truly dead code:**

```bash
# 1. Search ALL Solidity files
grep -r "calculateUnvested" . --include="*.sol"

# 2. Check test files
grep -r "calculateUnvested" test/ --include="*.sol"

# 3. Check if referenced in interfaces
grep -r "calculateUnvested" src/interfaces/

# 4. Check external documentation
grep -r "calculateUnvested" docs/ spec/ README.md

# Results:
# - Definition: src/libraries/RewardMath.sol (1 occurrence)
# - Tests: test/unit/RewardMath.*.sol (testing dead code)
# - Spec: Historical mentions only (pre-October 2025)
# - NO PRODUCTION USAGE ✅ Confirmed dead code
```

---

### Impact Assessment

**If Removed:**
- ✅ **Security:** Reduced attack surface (-35 lines)
- ✅ **Maintainability:** Less code to maintain
- ✅ **Coverage:** Metrics improve instantly (+67.5% for RewardMath)
- ✅ **Clarity:** Less confusion for auditors
- ✅ **Gas:** Slightly smaller deployment (library code)

**Risks of Removal:**
- ⚠️ If someone planned to use it (but why not use working code instead?)
- ⚠️ Loss of historical context (but spec documents remain)

**Recommendation:** **Remove immediately.** Benefits far outweigh risks.

---

### Related Issues to Investigate

**While fixing this dead code, check for other potential dead code:**

```bash
# Find all public/external functions in libraries
grep -A 5 "function.*public\|function.*external" src/libraries/*.sol

# Find all internal functions in libraries
grep -A 5 "function.*internal" src/libraries/*.sol

# Cross-reference with usage
# Look for other functions defined but never called
```

**Potential Candidates:**
- [ ] Other library functions in `src/libraries/`
- [ ] Unused modifiers
- [ ] Uncalled internal functions
- [ ] Deprecated functions (check for @deprecated tags)

**Action:** Create comprehensive dead code audit as part of coverage improvement.

---

## Next Actions

**Immediate (Today):**
1. ✅ Review this finding
2. ✅ Verify calculateUnvested is truly dead code
3. ✅ Get approval for removal
4. ✅ Remove dead code
5. ✅ Re-run coverage to get accurate baseline
6. ✅ Update HISTORICAL_FIXES.md
7. ✅ Proceed with coverage improvement on clean codebase

**Follow-up (This Week):**
1. Audit all library functions for dead code
2. Audit all internal functions for dead code
3. Remove any other dead code found
4. Establish baseline coverage on clean codebase
5. Begin systematic coverage improvement

---

**Document Version:** 1.0  
**Last Updated:** November 2, 2025  
**Next Review:** After dead code removal  
**Related Documents:**
- `spec/COVERAGE_ANALYSIS.md` - Coverage roadmap
- `spec/HISTORICAL_FIXES.md` - Bug history
- `spec/external-2/CRITICAL_FINDINGS_POST_OCT29_CHANGES.md` - Original bug report

