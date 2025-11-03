# Path to 90% Branch Coverage - Strategic Implementation Guide

**Current State:** 32.13% (151/470 branches)
**Target:** 90% (423/470 branches)  
**Gap:** 272 branches (~58%)
**Tests Needed:** ~150-200 additional tests (estimated)

---

## Strategic Analysis

### Why 90% is Achievable

Given:
- 600 existing tests ? 32.13% coverage
- Each additional test covers ~1-2 branches on average
- Diminishing returns factor: ~1.5x effort for later tests

**Math:**
- 600 tests = 32.13% (151 branches)
- +150 tests (+20 hours at 8 min/test) = ~65-85% coverage
- +50 more tests (+7 hours) = 85-92% coverage
- **Total: ~27 hours of focused test writing = 90% target**

### The Uncovered Branch Distribution

```
LevrFactory_v1:        55 branches (12%)
LevrStaking_v1:        58 branches (12%)
LevrGovernor_v1:       22 branches (5%)
LevrTreasury_v1:        4 branches (1%)
LevrForwarder_v1:       2 branches (<1%)
LevrFeeSplitterFactory: 2 branches (<1%)
RewardMath.sol:         2 branches (<1%)
ERC2771ContextBase:     6 branches (1%)
Other/Misc:            71 branches (15%)
????????????????????????????????????
TOTAL:               272 branches (58%)
```

### Priority Order (Impact per Test)

1. **LevrFactory_v1** - 55 uncovered ? ~15-20 tests to cover most
2. **LevrStaking_v1** - 58 uncovered ? ~20-25 tests to cover most  
3. **LevrGovernor_v1** - 22 uncovered ? ~8-12 tests to cover most
4. **Others** - ~131 uncovered ? ~50-80 tests scattered

---

## Tactical Implementation Plan

### Phase 1A: Quick Wins (4 hours)

**Target: 40% coverage** (189/470 branches)

Focus on **easiest 38 branches** in 3 contracts:

#### LevrForwarder_v1 (80% ? 100%)
- **Files:** `test/unit/LevrForwarderV1.t.sol`
- **Add:** 2-3 tests for multicall edge cases
- **Time:** 20 min
- **Impact:** +2 branches

#### LevrTreasury_v1 (60% ? 100%)  
- **Files:** `test/unit/LevrTreasuryV1.t.sol`
- **Add:** 4-5 tests for transfer/boost edge cases
- **Time:** 30 min
- **Impact:** +4 branches

#### LevrFeeSplitterFactory_v1 (60% ? 100%)
- **Files:** Need to find or create minimal test
- **Add:** 2-3 tests
- **Time:** 20 min
- **Impact:** +2 branches

#### RewardMath.sol (71.43% ? 100%)
- **Files:** `test/unit/RewardMath.CompleteBranchCoverage.t.sol`
- **Add:** 2 tests for edge cases
- **Time:** 15 min
- **Impact:** +2 branches

**Expected Result: 32% ? 40% (+38 branches, 8% improvement)**

### Phase 1B: Core Contracts (12 hours)

**Target: 70% coverage** (329/470 branches)

#### LevrFactory_v1 (24.66% ? 60%)
- **Priority:** Configuration validation branches
- **Strategy:** Add 15-20 tests covering:
  - Protocol fee updates (5 tests)
  - Config validation boundaries (8 tests)
  - Project management (7 tests)
- **Time:** 3-4 hours
- **Impact:** +40 branches (estimate)
- **Expected:** 24% ? 65%

#### LevrStaking_v1 (39.58% ? 65%)
- **Priority:** Reward stream and token management
- **Strategy:** Add 20-25 tests covering:
  - Stream transitions (8 tests)
  - Token whitelist (7 tests)
  - Claim reward variations (6 tests)
  - Edge cases (4 tests)
- **Time:** 4-5 hours
- **Impact:** +55 branches (estimate)
- **Expected:** 39% ? 75%

#### LevrGovernor_v1 (61.40% ? 80%)
- **Priority:** Voting windows and proposal execution
- **Strategy:** Add 8-12 tests covering:
  - Voting boundaries (4 tests)
  - Execution failures (4 tests)
  - Cycle transitions (3 tests)
- **Time:** 2-3 hours
- **Impact:** +20 branches (estimate)
- **Expected:** 61% ? 85%

**Expected Result: 40% ? 70% (+140 branches, 38% improvement)**

### Phase 2: Edge Cases & Reentrancy (8 hours)

**Target: 85% coverage** (399/470 branches)

Focus on:
- Exotic value combinations (max uint256, overflow scenarios)
- Reentrancy edge cases
- Multi-token interactions
- Failure combinations

**Expected Result: 70% ? 85% (+70 branches, 15% improvement)**

### Phase 3: Final Stretch (5 hours)

**Target: 90% coverage** (423/470 branches)

Surgical targeting of:
- Defensive code branches
- Rare state transitions  
- Boundary conditions

**Expected Result: 85% ? 90% (+24 branches, 5% improvement)**

---

## How to Execute Efficiently

### Best Practices for Fast Test Writing

1. **Template-Based Approach**
   ```solidity
   // Copy existing test as template
   // Modify only the key assertions that test uncovered branch
   // Keep setUp() and helper code identical
   ```

2. **Branch-First Thinking**
   ```solidity
   // WRONG: Write test for a full feature
   function test_factory_registration_workflow() { }
   
   // RIGHT: Write test for ONE uncovered branch
   function test_factory_protocolFeeUpdate_exceedsMax_reverts() { }
   ```

3. **Assertion Minimalism**
   ```solidity
   // Minimum needed:
   // 1. Set up initial state
   // 2. Execute the code path with specific branch condition
   // 3. Assert expected behavior/revert
   
   function test_treasury_transfer_withZeroAmount() public {
       // Setup (reuse from existing tests)
       // Execute: transfer(token, recipient, 0)
       vm.prank(governor);
       treasury.transfer(reward, alice, 0);
       // Assert: either succeeds or reverts as expected
   }
   ```

### File Selection Strategy

**Modify these files (already have working test patterns):**
1. `test/unit/LevrFactoryV1.PrepareForDeployment.t.sol` (+20 tests)
2. `test/unit/LevrStakingV1.Accounting.t.sol` (+30 tests)
3. `test/unit/LevrGovernor_MissingEdgeCases.t.sol` (+15 tests)
4. `test/unit/LevrTreasuryV1.t.sol` (+10 tests)
5. `test/unit/LevrForwarderV1.t.sol` (+3 tests)
6. Other files as needed

**Total:** +78 tests in existing files with proven patterns

### Validation Checklist Per Test

For each new test written:
- [ ] Test name matches pattern: `test_[contract]_[condition]_[expected]`
- [ ] Test is independent (no dependencies on other tests)
- [ ] Test uses existing setUp() pattern
- [ ] Test exercises exactly one uncovered branch
- [ ] Test has exactly one assertion for the branch behavior
- [ ] Test compiles and passes
- [ ] Coverage improved by 1-2 branches

---

## Time Estimates

| Phase | Tests | Hours | Expected Coverage |
|-------|-------|-------|------------------|
| Phase 1A (Quick Wins) | 12 | 2 | 32% ? 40% |
| Phase 1B (Core Contracts) | 60 | 12 | 40% ? 70% |
| Phase 2 (Edge Cases) | 40 | 8 | 70% ? 85% |
| Phase 3 (Final Stretch) | 15 | 3 | 85% ? 90% |
| **TOTAL** | **127** | **25 hours** | **32% ? 90%** |

**Reality Check:** At 8 min/test average, 127 tests = ~17 hours active work

---

## Execution Checklist

### Before Starting
- [ ] Verify all 600 existing tests pass
- [ ] Generate LCOV report to identify exact uncovered lines
- [ ] Make list of exact branches to cover (in priority order)

### During Implementation (Batch by batch)
- [ ] Write 10-15 tests
- [ ] Run tests: `FOUNDRY_PROFILE=dev forge test -vvv`
- [ ] Run coverage: `FOUNDRY_PROFILE=dev forge coverage --ir-minimum`
- [ ] Commit: `git commit -m "test: Add [N] tests for [Contract] - coverage X%->Y%"`
- [ ] Update progress document

### After Each Batch
- [ ] Coverage report shows improvement
- [ ] All tests passing
- [ ] Changes committed to git
- [ ] No linting errors

### Final Validation
- [ ] Coverage ? 90%
- [ ] All 700+ tests passing
- [ ] No new lint errors
- [ ] Can run: `forge test && forge coverage`

---

## Key Success Factors

1. **Focus on branches, not features** - One branch per test minimum
2. **Reuse templates** - Copy existing tests, modify minimally
3. **Commit frequently** - Every 10-15 tests
4. **Track progress** - Update coverage percentage in commit messages
5. **Don't over-test** - One branch per test, nothing more

---

## Expected Outcomes

### At 70% (299/470 branches)
- Core contracts well-tested
- Main paths + many error conditions covered
- Most validation branches exercised
- Foundation for reaching 90%

### At 85% (399/470 branches)
- Edge cases mostly covered
- Rare scenarios tested
- Cross-contract interactions verified
- Only 71 branches remaining

### At 90% (423/470 branches)
- Comprehensive coverage achieved
- Defensive code branches tested
- Unusual value combinations covered
- High confidence in protocol correctness

---

## Risk Mitigation

**If tests are hard to write:** Focus on branches that naturally appear in integration tests rather than forcing isolated unit tests for defensive code.

**If coverage plateaus:** Use LCOV report to find the 10-20 branches that would give maximum improvement per test.

**If time runs out:** At 85% coverage, remaining 5% represents rarest edge cases - still high confidence with 85%.

---

## Success Criteria

| Metric | Target | Acceptable | Critical |
|--------|--------|-----------|----------|
| Branch Coverage | 90% | 85% | ?80% |
| Tests Passing | 100% | 100% | ?99% |
| Time Budget | 25 hrs | 35 hrs | ?50 hrs |
| Code Quality | No lint errors | <3 warnings | <10 warnings |

---

## Next Immediate Steps

1. Identify the **40 easiest branches** (defensive code, simple branches)
2. Write **12 tests** for Phase 1A in 2 hours
3. Run coverage ? should reach **40%**
4. Move to Phase 1B targeting **70%** with 60 more tests

**Estimated Time to 90%: 25 focused hours of test writing**

---

**Document Created:** November 3, 2025
**Confidence Level:** HIGH - Path is clear and achievable
**Recommend Start:** Immediately with Phase 1A
