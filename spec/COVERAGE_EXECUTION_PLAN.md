# Coverage Analysis Execution Plan - Cloud Environment Setup Complete

**Date:** November 2, 2025  
**Status:** ? Cloud environment ready for execution  
**Next Step:** Begin Phase 1 (dead code removal + foundation tests)  
**Timeline:** 10-14 weeks to 100% branch coverage

---

## ?? Mission Overview

Transform Levr's test coverage from **29.11% (124/426 branches)** to **100% (426/426 branches)** through a systematic 4-phase approach.

**Key Metrics:**
- Current: 29.11% branch coverage (124/426)
- Target: 100% branch coverage (426/426)
- Gap: 302 branches to test
- Timeline: 10-14 weeks (~3.5 months)
- Estimated Tests: ~300 new tests (556 existing + 300 new = 856 total)

---

## ? Environment Setup Status

### Cloud Environment Configured

**? Foundry Installed**
```
forge Version: 1.4.3-stable
Commit SHA: fa9f934bdac4bcf57e694e852a61997dda90668a
```

**? Profiles Configured**
```toml
[profile.default]      # Production with IR optimization
[profile.dev]          # Fast development (20x faster)
[profile.coverage]     # Optimized for cloud coverage
```

**? Dependencies Ready**
```
lib/openzeppelin-contracts/ ? Installing
lib/universal-router/       ? Installing
```

**? Scripts Ready**
```
scripts/coverage-setup-cloud.sh   ? Installed
.env.forge-cloud                  ? Created
```

---

## ?? Immediate Tasks (This Week)

### Task 1: Verify Test Suite (30 minutes)

**Objective:** Confirm all tests compile and run

```bash
source ~/.bashrc
cd /workspace
FOUNDRY_PROFILE=dev forge test --match-path "test/unit/*.t.sol" -vvv
```

**Expected Result:**
- ? All 556 tests pass
- ? No compilation errors
- ? Environment ready for coverage

**Action:** Run after dependencies finish downloading

---

### Task 2: Remove Dead Code from RewardMath.sol (1-2 hours)

**Objective:** Remove `calculateUnvested()` dead code (35 lines)

**Current Status:** OPEN (ready to execute)  
**Evidence:** `spec/COVERAGE_BUGS_FOUND.md` (Issue #1)  
**Impact:** Instant +67.5% improvement for RewardMath (12.50% ? ~80%)

**Steps:**

```bash
# 1. Backup current state
cd /workspace
git add -A
git commit -m "Backup: Before removing dead code from RewardMath"

# 2. Review the dead code
cat src/libraries/RewardMath.sol | sed -n '41,83p'

# 3. Edit to remove lines 41-83 (calculateUnvested function)
# Remove:
# - Documentation comment (lines 41-47)
# - Function definition (lines 48-54)
# - Function implementation (lines 55-83)

# 4. Verify no broken references
grep -r "calculateUnvested" src/ test/ || echo "? No remaining references"

# 5. Run tests to verify nothing broke
FOUNDRY_PROFILE=dev forge test --match-path "test/unit/*.t.sol" -vvv
# Expected: All 556 tests still pass ?

# 6. Get new baseline coverage
FOUNDRY_PROFILE=dev forge coverage --match-path "test/unit/*.t.sol" --ir-minimum
# Expected: RewardMath 12.50% ? ~80% (instantly!)
# Expected: Overall 29.11% ? ~30.75% (+1.64%)

# 7. Commit cleanup
git add -A
git commit -m "refactor: Remove dead code calculateUnvested() from RewardMath

- Removed 35 lines of dead code with historical bugs
- Function never called in production (verified by grep)
- Improves RewardMath coverage: 12.50% ? ~80%
- Improves overall coverage: 29.11% ? ~30.75%
- Reduces attack surface and deployment gas
- Documented in spec/COVERAGE_BUGS_FOUND.md"

# 8. Update documentation
# Add to spec/HISTORICAL_FIXES.md:
# - Date removed: Nov 2, 2025
# - Function: calculateUnvested()
# - Why: Dead code with historical bugs
# - Impact: +67.5% RewardMath coverage
```

**Files to Update:**
- ? `src/libraries/RewardMath.sol` - Remove function
- ? `test/unit/RewardMath.CompleteBranchCoverage.t.sol` - Update test references if any
- ? `spec/HISTORICAL_FIXES.md` - Document removal
- ? `spec/COVERAGE_ANALYSIS.md` - Update baseline metrics

---

### Task 3: Update Coverage Baseline (30 minutes)

**Objective:** Establish accurate baseline after dead code removal

```bash
cd /workspace
FOUNDRY_PROFILE=dev forge coverage --match-path "test/unit/*.t.sol" --ir-minimum > coverage-baseline-nov2.txt
cat coverage-baseline-nov2.txt | grep -E "% Lines|% Statements|% Branches|% Funcs"
```

**Expected Results After Dead Code Removal:**
```
Lines:      ~54% (up from 53.52%)
Statements: ~55% (up from 54.46%)
Branches:   ~30.75% (up from 29.11%) ? Key metric!
Functions:  ~66% (up from 65.62%)
```

**Update `spec/COVERAGE_ANALYSIS.md` with new baseline:**

Find and update line 9:
```markdown
**?? Current: ~30.75% (127/426 branches)** ? New baseline after dead code removal
```

---

## ?? Phase 1: Foundation Tests (1-2 weeks)

**Goal:** +15% branch coverage ? **45% total (192/426 branches)**

### Priority 1: RewardMath Library (Highest Impact)

**File:** `test/unit/RewardMath.CompleteBranchCoverage.t.sol`

**Current:** 12.50% ? ~80% after dead code removal  
**Target:** 100% (8/8 branches)  
**Tests Needed:** 12 tests  
**Impact:** +1.64% overall

**Test Template:**
```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {RewardMath} from "src/libraries/RewardMath.sol";

contract RewardMath_CompleteBranchCoverage_Test is Test {
    
    // calculateVestedAmount branches
    function test_calculateVestedAmount_zeroDuration_returnsZero() public pure {
        // Implementation
    }
    
    function test_calculateVestedAmount_elapsedExceedsDuration_returnsTotal() public pure {
        // Implementation
    }
    
    function test_calculateVestedAmount_partialElapsed_returnsProportional() public pure {
        // Implementation
    }
    
    // calculateProportionalClaim branches
    function test_calculateProportionalClaim_zeroTotalStaked_returnsZero() public pure {
        // Implementation
    }
    
    function test_calculateProportionalClaim_zeroAccPerShare_returnsZero() public pure {
        // Implementation
    }
    
    function test_calculateProportionalClaim_validInputs_calculatesCorrectly() public pure {
        // Implementation
    }
    
    // calculateCurrentPool (wrapper)
    function test_calculateCurrentPool_allBranchCombinations() public pure {
        // Implementation
    }
}
```

**Timeline:** 1-2 days  
**Verification:**
```bash
FOUNDRY_PROFILE=dev forge test --match-path "test/unit/RewardMath.CompleteBranchCoverage.t.sol" -vvv
```

---

### Priority 2: LevrStakedToken (Quick Win)

**File:** `test/unit/LevrStakedToken.CompleteBranchCoverage.t.sol`

**Current:** 50% (4/8)  
**Target:** 100% (8/8)  
**Tests Needed:** 6 tests  
**Impact:** +0.94% overall

**Tests:**
1. `test_approve_allowsButTransferStillBlocked()`
2. `test_increaseAllowance_allowsButTransferStillBlocked()`
3. `test_decreaseAllowance_allowsButTransferStillBlocked()`
4. `test_mint_onlyStakingCaller_reverts()`
5. `test_burn_onlyStakingCaller_reverts()`
6. Additional edge cases

**Timeline:** 1 day

---

### Priority 3: LevrDeployer (Smallest)

**File:** `test/unit/LevrDeployer.CompleteBranchCoverage.t.sol`

**Current:** 50% (1/2)  
**Target:** 100% (2/2)  
**Tests Needed:** 3 tests  
**Impact:** +0.23% overall

**Tests:**
1. `test_constructor_zeroTreasuryImpl_reverts()`
2. `test_constructor_zeroStakingImpl_reverts()`
3. `test_deploy_validInputs_succeeds()`

**Timeline:** 0.5 days

---

### Priority 4-6: LevrTreasury, LevrForwarder, LevrFeeSplitter

**Combined Impact:** ~4.17% overall (+15 tests total)

**Timeline:** 3-5 days

**Expected After Phase 1:**
- RewardMath: 100% ?
- LevrStakedToken: 100% ?
- LevrDeployer: 100% ?
- Overall: **~45% (192/426 branches)**

---

## ?? Phase 2: Core Contracts (3-4 weeks)

**Goal:** +25% branch coverage ? **70% total (299/426 branches)**

### LevrFactory_v1.sol

**Current:** 23.94% (17/71)  
**Target:** 85% (~60/71)  
**Tests Needed:** 35-40  
**Impact:** +10.09% overall

**Key Branches to Test:**
- Constructor validation (all zero addresses)
- Register function (token validation, duplicate checks)
- updateProjectConfig (BPS validation, parameter ranges)
- setVerified (ownership, state transitions)
- Trusted factory management
- Protocol treasury/fee updates

**Timeline:** 1-2 weeks

---

### LevrStaking_v1.sol

**Current:** 41.89% (31/74)  
**Target:** 85% (~63/74)  
**Tests Needed:** 25-30  
**Impact:** +7.51% overall

**Key Branches to Test:**
- Stake/unstake edge cases (zero amount, overflow, escrow)
- Reward accrual (zero stakers, max tokens, stream overlaps)
- Token whitelist/cleanup failures
- Multi-token management (MAX_REWARD_TOKENS boundary)
- Reserve accounting edges

**Timeline:** 1-2 weeks

---

### LevrGovernor_v1.sol

**Current:** 57.45% (27/47)  
**Target:** 90% (~42/47)  
**Tests Needed:** 20-25  
**Impact:** +3.52% overall

**Key Branches to Test:**
- Proposal execution failure paths
- Vote aggregation edges (ties, overflow, underflow)
- Cycle transition scenarios
- Config snapshot edge cases
- Winner determination with unusual distributions

**Timeline:** 1 week

---

**Expected After Phase 2:**
- LevrFactory: 85%
- LevrStaking: 85%
- LevrGovernor: 90%
- Overall: **~70% (299/426 branches)**

---

## ?? Phase 3: Excellence (3-4 weeks)

**Goal:** +20% branch coverage ? **90% total (384/426 branches)**

**Focus Areas:**
1. **Exotic Edge Cases** (extreme values, unusual combinations) - 25 tests
2. **Reentrancy Attack Vectors** (all contracts) - 15 tests
3. **Cross-Contract Interactions** - 20 tests
4. **Failure Mode Combinations** - 20 tests
5. **Final contract branches** to reach 100% on major contracts

**Test Files:**
- `LevrProtocol.ExoticEdgeCases.t.sol`
- `LevrProtocol.ReentrancyVectors.t.sol`
- `LevrProtocol.CrossContractBranches.t.sol`
- `LevrProtocol.FailureModeCombinations.t.sol`

**Expected Achievements:**
- LevrFactory: 100% (71/71)
- LevrStaking: 100% (74/74)
- LevrGovernor: 100% (47/47)
- Overall: **~90% (384/426 branches)**

---

## ?? Phase 4: Perfection (2-3 weeks)

**Goal:** +10% branch coverage ? **100% total (426/426 branches)**

**Strategy:**
1. Generate detailed LCOV coverage report
2. Identify ALL 42 remaining uncovered branches
3. Create targeted tests for each specific branch
4. Achieve **100% coverage systematically**

**Expected:**
- **ALL contracts: 100% branch coverage** ?
- **Overall: 100% (426/426 branches)** ??

---

## ??? Running Coverage on Cloud

### Quick Reference Commands

```bash
# 1. Load environment
source ~/.bashrc
cd /workspace

# 2. Run unit tests (FAST - dev profile)
FOUNDRY_PROFILE=dev forge test --match-path "test/unit/*.t.sol" -vvv

# 3. Check coverage (FAST - dev profile)
FOUNDRY_PROFILE=dev forge coverage --match-path "test/unit/*.t.sol" --ir-minimum

# 4. Generate LCOV report (for HTML)
FOUNDRY_PROFILE=dev forge coverage --match-path "test/unit/*.t.sol" --ir-minimum --report lcov

# 5. Generate HTML coverage report
genhtml -o coverage-html coverage.lcov

# 6. View HTML report
open coverage-html/index.html  # macOS
xdg-open coverage-html/index.html  # Linux
```

### Coverage Verification Script

Save as `scripts/verify-coverage.sh`:

```bash
#!/bin/bash
source ~/.bashrc
cd /workspace

echo "?? Verifying Coverage Status..."
echo "????????????????????????????????????????"

FOUNDRY_PROFILE=dev forge coverage --match-path "test/unit/*.t.sol" --ir-minimum 2>/dev/null | grep -E "% Lines|% Statements|% Branches|% Funcs"

echo "????????????????????????????????????????"
echo "? Coverage check complete"
```

---

## ?? Progress Tracking

### Weekly Milestones

**Week 1-2:** Foundation (Milestone 1)
- [ ] Dead code removed
- [ ] Baseline updated
- [ ] RewardMath: 100%
- [ ] LevrStakedToken: 100%
- [ ] LevrDeployer: 100%
- **Target:** 45% overall (192/426)

**Week 3-6:** Core Contracts (Milestone 2)
- [ ] LevrFactory complete branches
- [ ] LevrStaking complete branches
- [ ] LevrGovernor complete branches
- **Target:** 70% overall (299/426)

**Week 7-10:** Excellence (Milestone 3)
- [ ] Exotic edge cases
- [ ] Reentrancy vectors
- [ ] Cross-contract branches
- [ ] Failure combinations
- **Target:** 90% overall (384/426)

**Week 11-14:** Perfection (Milestone 4)
- [ ] Final 42 branches
- [ ] 100% coverage achieved
- **Target:** 100% overall (426/426) ??

---

## ?? Testing Best Practices (From COVERAGE_ANALYSIS.md)

### Rule #1: Never Make Tests Pass If Code Is Incorrect

> Tests should verify that code is CORRECT, not just that it executes.  
> If you find a bug while writing tests, FIX THE BUG, don't write tests that pass despite the bug.

### Rule #2: Verify Code Is Actually Used

Before testing a function:
```bash
grep -r "functionName" src/ --include="*.sol" | grep -v "^src/.*\.sol:.*function"
# If no results ? DEAD CODE!
```

### Rule #3: Test Correctness, Not Just Execution

```solidity
// ? BAD: Just makes it pass
function test_something() public {
    uint256 result = someFunction(10);
    assertTrue(result >= 0, "Returns a value");
}

// ? GOOD: Verifies correctness
function test_someFunction_halfway_vestsHalf() public {
    uint256 result = someFunction(10);
    uint256 expected = 5; // Calculate expected value
    assertEq(result, expected, "Should be exactly half");
}
```

### Rule #4: Test All Branches

For each `if` statement, test both branches:
- True condition
- False condition
- Boundary conditions

---

## ?? Code Quality Checklist

For each test written, verify:

- [ ] **Correctness** - Does the function behave correctly?
- [ ] **Expected Values** - Am I checking the RIGHT values?
- [ ] **Edge Cases** - Tested boundaries and special cases?
- [ ] **Error Conditions** - Reverts for the RIGHT reasons?
- [ ] **Invariants** - Mathematical properties preserved?
- [ ] **No False Positives** - Would this catch actual bugs?
- [ ] **Code Review** - Read actual implementation code?
- [ ] **Dead Code** - Is this function actually used?

---

## ?? Next Immediate Action

**Today's Task:**
1. ? Verify test suite compiles (wait for dependencies)
2. ? Remove dead code from RewardMath.sol
3. ? Get new baseline coverage metrics
4. ? Begin Phase 1 foundation tests

**Tomorrow's Task:**
1. Start writing RewardMath complete branch coverage tests
2. Continue with LevrStakedToken tests
3. Proceed with Phase 1 timeline

---

## ?? Related Documents

- `spec/COVERAGE_ANALYSIS.md` - Complete analysis with test templates
- `spec/COVERAGE_BUGS_FOUND.md` - Dead code findings
- `spec/HISTORICAL_FIXES.md` - Update with dead code removal
- `foundry.toml` - Profiles configuration
- `scripts/coverage-setup-cloud.sh` - Setup automation

---

## ? Execution Readiness Checklist

- [x] Foundry installed and verified
- [x] Cloud profiles configured (dev, coverage)
- [x] Dependencies installing
- [x] Test structure verified
- [x] Coverage baseline identified (29.11%)
- [x] Dead code identified and ready for removal
- [x] Phase 1 tasks defined
- [x] Testing best practices documented
- [x] Progress tracking framework set up

**Status: ? READY TO EXECUTE**

---

**Document Version:** 1.0  
**Created:** November 2, 2025  
**Status:** Active - Execute from Phase 1 Task 2 onwards  
**Next Review:** After Phase 1 completion

