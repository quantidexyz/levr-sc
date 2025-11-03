# Final Execution Plan to Reach 90% Branch Coverage

**Current State:** 32.13% (151/470)
**Target:** 90% (423/470)
**Gap:** 272 branches
**Estimated Time:** 25-30 focused hours

---

## Executive Summary

We have completed Phase 0 (analysis and planning). The path to 90% is clear and achievable:

### Baseline
- ? 600 passing tests
- ? 32.13% branch coverage
- ? All documentation and strategic plans complete
- ? LCOV report generated for precise branch identification

### Next Steps
To reach 90%, follow this systematic approach:

1. **Phase 1A (2 hours): Quick Wins** ? 32% ? 40%
2. **Phase 1B (12 hours): Core Contracts** ? 40% ? 70%  
3. **Phase 2 (8 hours): Edge Cases** ? 70% ? 85%
4. **Phase 3 (3 hours): Final Stretch** ? 85% ? 90%

---

## How to Execute

### Critical Success Factor: Interface Awareness

**Problem Encountered:** Contracts' public function signatures differ from documentation. Creating new test files led to compilation errors.

**Solution:** Modify EXISTING test files that already compile successfully, rather than creating new ones.

### Files to Modify (In Priority Order)

1. **test/unit/LevrFactoryV1.PrepareForDeployment.t.sol** (currently 1-21 tests)
   - Add: 20-25 tests for configuration validation branches
   - Estimated coverage gain: +35 branches
   - Time: 3-4 hours
   
2. **test/unit/LevrStakingV1.Accounting.t.sol** (currently 27 tests)
   - Add: 30-35 tests for reward stream and token branches
   - Estimated coverage gain: +50 branches
   - Time: 4-5 hours

3. **test/unit/LevrGovernor_MissingEdgeCases.t.sol** (currently 20 tests)
   - Add: 10-15 tests for voting and execution branches
   - Estimated coverage gain: +20 branches
   - Time: 2-3 hours

4. **test/unit/LevrTreasuryV1.t.sol** (currently ~10 tests)
   - Add: 5-8 tests for transfer and boost branches
   - Estimated coverage gain: +6 branches
   - Time: 1 hour

5. **test/unit/LevrForwarderV1.t.sol** (currently ~20 tests)
   - Add: 2-3 tests for multicall edge cases
   - Estimated coverage gain: +2 branches
   - Time: 30 min

### Test Writing Template

Use this pattern for each new test (copy-paste from existing tests in the same file):

```solidity
/// @notice Test [specific branch condition]
function test_[contract]_[condition]_[expectedBehavior]() public {
    // Setup (reuse from existing setUp() or helper functions)
    // ... any setup needed ...
    
    // Execute (call function with specific parameters to hit uncovered branch)
    // ... single function call that exercises the branch ...
    
    // Assert (verify the expected behavior)
    // ... single assertion verifying the branch was exercised correctly ...
}
```

### Key Principles

1. **One test = One branch** (minimum)
   - Each test should exercise exactly one previously-uncovered branch
   - Not full feature coverage, just branch coverage

2. **Reuse existing patterns**
   - Copy test structure from existing tests in the same file
   - Maintain the same style and conventions
   - Use existing helpers and mocks

3. **Batch in groups of 10-15**
   - Write 10-15 tests
   - Run: `FOUNDRY_PROFILE=dev forge test -vvv`
   - Verify they pass
   - Run coverage: `forge coverage --ir-minimum`
   - Commit with coverage percentage
   - Repeat

---

## Implementation Schedule

### Day 1 (4-5 hours): Phase 1A  + Start Phase 1B

```bash
# Phase 1A: Quick Wins
# 1. Add 2-3 tests to LevrForwarderV1.t.sol
# 2. Add 5-8 tests to LevrTreasuryV1.t.sol
# Expected: 32% ? 40%

# Phase 1B Start: Add 15-20 factory tests
# Expected: 40% ? 50%

# After each batch: commit with message "test: Add [N] tests - [OLD]%?[NEW]%"
```

### Day 2-3 (12-15 hours): Complete Phase 1B

```bash
# Continue adding tests to:
# - LevrFactoryV1 (aim for 20-25 tests total)
# - LevrStakingV1 (aim for 30-35 tests total)
# - LevrGovernor (aim for 10-15 tests total)
# Expected: 50% ? 70%
```

### Day 4-5 (8-10 hours): Phase 2

```bash
# Add exotic edge cases:
# - Extreme values (max uint256, zero amounts, etc.)
# - Rare state transitions
# - Multi-token combinations
# Expected: 70% ? 85%
```

### Day 6 (3-4 hours): Phase 3

```bash
# Final stretch:
# - Defensive code branches  
# - Last remaining edge cases
# - Boundary conditions
# Expected: 85% ? 90%
```

---

## Validation at Each Stage

After each batch of tests:

```bash
# Run tests (should all pass)
FOUNDRY_PROFILE=dev forge test --match-path "test/unit/*.t.sol" -vvv

# Check coverage
FOUNDRY_PROFILE=dev forge coverage --match-path "test/unit/*.t.sol" --ir-minimum

# Commit progress
git commit -m "test: Add [N] tests for [contract] - [OLD]%?[NEW]% coverage"
```

---

## Expected Coverage Progression

| Milestone | Tests | Coverage | Branch Count |
|-----------|-------|----------|--------------|
| Start | 600 | 32.13% | 151/470 |
| Phase 1A Done | 615 | 40% | 188/470 |
| Phase 1B Done | 675 | 70% | 329/470 |
| Phase 2 Done | 715 | 85% | 399/470 |
| Phase 3 Done | 730 | 90% | 423/470 |

---

## Common Issues & Solutions

### Issue: Tests Won't Compile

**Solution:** Don't create new contracts/files. Add functions to existing test contracts using the same patterns that already work.

### Issue: Coverage Doesn't Improve

**Solution:** Verify the branch is actually being exercised:
- Add `console.log()` statements
- Run coverage with LCOV report
- Check exact line numbers of uncovered branches

### Issue: Tests Fail

**Solution:** Likely wrong function signatures or parameters
- Copy an existing passing test in the same file
- Modify only the parts necessary to hit the different branch
- Run with `-vvv` to see exact error

---

## When Done

After reaching 90%:

1. ? Verify all tests pass: `forge test`
2. ? Verify coverage ? 90%: `forge coverage --ir-minimum`
3. ? Final commit: `git commit -m "test: Achieve 90% branch coverage"`
4. ? Summary: Update COVERAGE_STATUS_NOV_2025.md
5. ? Report: Document results and time spent

---

## Key Files Reference

**Documentation:**
- `COVERAGE_PATH_TO_90_PERCENT.md` - Strategic overview
- `COVERAGE_EXECUTION_STATUS.md` - Quick reference
- `COVERAGE_STATUS_NOV_2025.md` - Detailed analysis

**Test Files (Modify These):**
- `test/unit/LevrFactoryV1.PrepareForDeployment.t.sol`
- `test/unit/LevrStakingV1.Accounting.t.sol`
- `test/unit/LevrGovernor_MissingEdgeCases.t.sol`
- `test/unit/LevrTreasuryV1.t.sol`
- `test/unit/LevrForwarderV1.t.sol`

**Tracking:**
- LCOV report: `lcov.info` (regenerate as needed)
- Coverage data: from `forge coverage` command

---

## Success Criteria

- ? 90% or higher branch coverage achieved
- ? 700+ tests passing (started with 600)
- ? No linting errors introduced
- ? All changes committed to git
- ? Execution time < 30 hours

---

## TL;DR - Start Here

1. Read `COVERAGE_PATH_TO_90_PERCENT.md` for strategy
2. Open `test/unit/LevrFactoryV1.PrepareForDeployment.t.sol`
3. Copy an existing test function
4. Modify it to test an uncovered branch from `lcov.info`
5. Run: `forge test && forge coverage --ir-minimum`
6. See coverage increase
7. Commit: `git commit -m "test: Add N tests - X%?Y%"`
8. Repeat until 90%

**Estimated Time to 90%: 25-30 focused hours**

---

**Document Created:** November 3, 2025
**Status:** Ready for implementation
**Next Action:** Begin Phase 1A (add first 10-15 tests)
