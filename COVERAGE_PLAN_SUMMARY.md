# Coverage Analysis Plan - Executive Summary

**Date:** November 2, 2025  
**Status:** ? **ENVIRONMENT SETUP COMPLETE - READY TO EXECUTE**  
**Branch:** `cursor/setup-forge-cloud-env-for-coverage-analysis-7154`  
**Commit:** `7050c92` - Setup Forge cloud environment

---

## ?? Mission

Improve Levr's test coverage from **29.11% (124/426 branches)** to **100% (426/426 branches)** through systematic 4-phase testing plan.

**Key Facts:**
- **Current Coverage:** 29.11% branch coverage (124/426 branches)
- **Target Coverage:** 100% branch coverage (426/426 branches)
- **Coverage Gap:** 302 branches to test (+70.89% improvement)
- **Estimated Timeline:** 10-14 weeks (~3.5 months)
- **Estimated New Tests:** ~300 tests (556 existing + 300 new = 856 total)

---

## ? What's Been Completed

### 1. Cloud Environment Setup ?

**Foundry Installation:**
```
? Installed: forge 1.4.3-stable
? SHA: fa9f934bda 2025-10-22
? Platform: Cloud-ready
```

**Profiles Configured:**
```toml
[profile.default]   # Production with IR (via_ir = true)
[profile.dev]       # Fast development (via_ir = false) - 20x faster
[profile.coverage]  # Cloud optimized (via_ir = false)
```

**Environment Files:**
- ? `.env.forge-cloud` - Configuration template
- ? `.forge-cloud-env` - Environment marker
- ? `scripts/coverage-setup-cloud.sh` - Automation script
- ? Updated `foundry.toml` with coverage profile

### 2. Comprehensive Documentation ?

**Three Key Documents Created:**

1. **`spec/COVERAGE_EXECUTION_PLAN.md`** (Complete Roadmap)
   - 4-phase execution plan
   - Task breakdown with timelines
   - Ready-to-use test templates
   - Progress tracking framework
   - Testing best practices

2. **`spec/COVERAGE_ANALYSIS.md`** (Detailed Analysis)
   - Contract-by-contract breakdown
   - Branch coverage analysis
   - Missing branch identification
   - Testing best practices
   - 100% coverage roadmap

3. **`spec/COVERAGE_BUGS_FOUND.md`** (Issues Tracker)
   - Dead code identified: `calculateUnvested()`
   - Historical context and bugs
   - Recommended removal action
   - Impact analysis

### 3. Dependencies ?

```
? lib/openzeppelin-contracts/  Downloaded
? lib/universal-router/        Downloaded
? 556 existing tests           Ready
? All compilation working      Verified
```

### 4. Baseline Metrics ?

Established and documented:
- **Lines:** 53.52% (1041/1945)
- **Statements:** 54.46% (1130/2075)
- **Branches:** 29.11% (124/426) ? PRIMARY FOCUS
- **Functions:** 65.62% (168/256)

---

## ?? 4-Phase Execution Plan

### Phase 1: Foundation (1-2 weeks)
**Target:** 45% coverage (192/426 branches) | **Gain:** +68 branches

**Tasks:**
1. Remove dead code from RewardMath.sol (+67.5% for that contract)
2. RewardMath: 12.50% ? 100% (12 tests)
3. LevrStakedToken: 50% ? 100% (6 tests)
4. LevrDeployer: 50% ? 100% (3 tests)
5. LevrTreasury edge cases (12 tests)
6. LevrForwarder remaining branches (8 tests)
7. LevrFeeSplitter remaining branches (12 tests)
8. Other foundation work (15 tests)

**Total Tests:** ~70 new tests

---

### Phase 2: Core Contracts (3-4 weeks)
**Target:** 70% coverage (299/426 branches) | **Gain:** +107 branches

**Tasks:**
1. LevrFactory: 23.94% ? 85% (35-40 tests)
2. LevrStaking: 41.89% ? 85% (25-30 tests)
3. LevrGovernor: 57.45% ? 90% (20-25 tests)

**Total Tests:** ~80-95 new tests

---

### Phase 3: Excellence (3-4 weeks)
**Target:** 90% coverage (384/426 branches) | **Gain:** +85 branches

**Focus Areas:**
1. Exotic edge cases (extreme values, unusual combinations) - 25 tests
2. Reentrancy attack vectors (all contracts) - 15 tests
3. Cross-contract interactions - 20 tests
4. Failure mode combinations - 20 tests
5. Final contract branches to 100% - 5 tests

**Total Tests:** ~85 new tests

---

### Phase 4: Perfection (2-3 weeks)
**Target:** 100% coverage (426/426 branches) | **Gain:** +42 branches

**Approach:**
1. Generate detailed LCOV coverage report
2. Identify remaining 42 uncovered branches
3. Create targeted tests for each specific branch
4. Achieve 100% systematically

**Total Tests:** ~50 new tests

---

## ?? Key Contracts - Current Status

| Contract | Lines | Branches | Target | Gap |
|----------|-------|----------|--------|-----|
| LevrFactory_v1 | 92.24% | 23.94% | 100% | -76.06% |
| LevrGovernor_v1 | 90.78% | 57.45% | 100% | -42.55% |
| LevrStaking_v1 | 93.33% | 41.89% | 100% | -58.11% |
| LevrTreasury_v1 | 89.66% | 40.00% | 100% | -60.00% |
| LevrFeeSplitter_v1 | 93.58% | 73.33% | 100% | -26.67% |
| LevrForwarder_v1 | 86.05% | 80.00% | 100% | -20.00% |
| LevrStakedToken_v1 | 100.00% | 50.00% | 100% | -50.00% |
| LevrDeployer_v1 | 100.00% | 50.00% | 100% | -50.00% |
| RewardMath | 81.82% | 12.50% | 100% | -87.50% |

---

## ??? Quick Start Commands

### Verify Everything Works
```bash
source ~/.bashrc
cd /workspace
FOUNDRY_PROFILE=dev forge test --match-path "test/unit/*.t.sol" -vvv
```

### Check Current Coverage
```bash
FOUNDRY_PROFILE=dev forge coverage --match-path "test/unit/*.t.sol" --ir-minimum
```

### Generate HTML Report
```bash
FOUNDRY_PROFILE=dev forge coverage --match-path "test/unit/*.t.sol" --ir-minimum --report lcov
genhtml -o coverage-html coverage.lcov
open coverage-html/index.html
```

---

## ?? Critical Finding: Dead Code in RewardMath

**Issue:** `calculateUnvested()` function is dead code with historical bugs

**Evidence:**
- 35 lines of unused code
- Contains bug from October 2025 (16.67% fund loss scenario)
- Never called in production (verified by grep)
- Taking up 87.5% of uncovered branches in RewardMath

**Recommendation:** Remove immediately

**Impact of Removal:**
- RewardMath coverage: 12.50% ? ~80% (+67.5%)
- Overall coverage: 29.11% ? ~30.75% (+1.64%)
- Reduced attack surface
- More accurate coverage metrics

**Status:** Ready to execute

---

## ?? Essential Documentation

**Start Here:**
1. `spec/COVERAGE_EXECUTION_PLAN.md` - Main roadmap
2. `spec/COVERAGE_ANALYSIS.md` - Detailed breakdown
3. `spec/COVERAGE_BUGS_FOUND.md` - Issues and findings

**For Code Quality:**
- Best practices in `spec/COVERAGE_ANALYSIS.md` (Section: Test Writing Best Practices)
- Golden Rule: Never make tests pass if code is incorrect
- Always verify code is actually used before testing

---

## ?? Testing Best Practices Summary

### Rule 1: Correctness First
> Tests should verify code is CORRECT, not just that it executes.

### Rule 2: Verify Production Use
```bash
# Before testing a function, verify it's used:
grep -r "functionName" src/ --include="*.sol" | grep -v "^src/.*\.sol:.*function"
# No results = dead code, don't test it!
```

### Rule 3: Test All Branches
- For each `if` statement, test both branches
- Test boundary conditions
- Test zero values and max values
- Test error conditions

### Rule 4: Verify Mathematical Properties
- Check invariants hold (e.g., vested + unvested = total)
- Verify calculations are correct
- Test overflow/underflow scenarios

---

## ?? Progress Tracking

### Weekly Targets

**Week 1-2:** Phase 1 Foundation
- Baseline: 29.11%
- Target: 45% (+68 branches)
- Status: Ready to start

**Week 3-6:** Phase 2 Core Contracts
- Target: 70% (+107 branches cumulative)
- Key: Factory, Staking, Governor

**Week 7-10:** Phase 3 Excellence
- Target: 90% (+85 branches cumulative)
- Key: Edge cases, reentrancy, cross-contract

**Week 11-14:** Phase 4 Perfection
- Target: 100% (+42 branches cumulative)
- Key: Final uncovered branches

---

## ? Environment Readiness Checklist

- [x] Foundry installed and verified
- [x] Cloud profiles configured
- [x] Dependencies downloaded
- [x] Test structure verified
- [x] Coverage baseline established
- [x] Dead code identified
- [x] Phase 1-4 tasks defined
- [x] Test templates created
- [x] Best practices documented
- [x] Scripts created and tested
- [x] Documentation complete
- [x] Git committed

**STATUS: ? READY FOR PHASE 1 EXECUTION**

---

## ?? Next Actions (Phase 1 - Week 1)

### Step 1: Remove Dead Code (1-2 hours)

```bash
# Edit src/libraries/RewardMath.sol
# Remove lines 41-83 (calculateUnvested function)

# Verify tests still pass
FOUNDRY_PROFILE=dev forge test --match-path "test/unit/*.t.sol" -vvv

# Get new baseline
FOUNDRY_PROFILE=dev forge coverage --match-path "test/unit/*.t.sol" --ir-minimum
# Expected: RewardMath 12.50% ? ~80%
# Expected: Overall 29.11% ? ~30.75%
```

### Step 2: Update Documentation (30 minutes)

- Update `spec/HISTORICAL_FIXES.md` with dead code removal
- Update `spec/COVERAGE_ANALYSIS.md` with new baseline

### Step 3: Begin Foundation Tests (Ongoing)

- Create `test/unit/RewardMath.CompleteBranchCoverage.t.sol` (12 tests)
- Create `test/unit/LevrStakedToken.CompleteBranchCoverage.t.sol` (6 tests)
- Create `test/unit/LevrDeployer.CompleteBranchCoverage.t.sol` (3 tests)
- Continue with remaining Phase 1 tests

### Step 4: Track Progress Weekly

```bash
# Weekly verification command
FOUNDRY_PROFILE=dev forge coverage --match-path "test/unit/*.t.sol" --ir-minimum | grep -E "% Branches"
```

---

## ?? Key Insights

1. **Coverage Gap is Real:** 29.11% branch coverage indicates we're testing happy paths but missing error conditions, edge cases, and attack vectors.

2. **Dead Code is a Problem:** The 87.5% of uncovered branches in RewardMath are in unused code. Removing it is faster than testing it.

3. **Quality Over Quantity:** The goal is 100% coverage of CORRECT, PRODUCTION code with PROPER tests that verify correctness.

4. **Systematic Approach Wins:** The 4-phase plan breaks 302 branches into manageable chunks. Each phase builds on the previous one.

5. **Cloud Efficiency:** Using `FOUNDRY_PROFILE=dev` makes compilation 20x faster, enabling rapid iteration.

---

## ?? Support Resources

**If you need to understand:**
- **The complete plan:** Read `spec/COVERAGE_EXECUTION_PLAN.md`
- **How to write good tests:** Read testing best practices in `spec/COVERAGE_ANALYSIS.md`
- **What's wrong with the code:** Read `spec/COVERAGE_BUGS_FOUND.md`
- **Quick commands:** Use the reference section above

---

## ?? Final Status

**Cloud Environment:** ? Ready  
**Test Suite:** ? Ready (556 tests passing)  
**Dependencies:** ? Downloaded  
**Documentation:** ? Complete  
**Dead Code:** ? Identified  
**Baseline Metrics:** ? Established  
**Phase 1 Tasks:** ? Defined  

**? READY TO BEGIN PHASE 1 EXECUTION**

---

**Document Version:** 1.0  
**Created:** November 2, 2025  
**Last Updated:** November 2, 2025  
**Next Review:** After Phase 1 completion (Week 2)

