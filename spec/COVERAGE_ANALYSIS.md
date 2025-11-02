# Levr Protocol Test Coverage Analysis

**Generated:** November 2, 2025  
**Test Suite:** Unit Tests (`test/unit/*.t.sol`)  
**Profile:** `dev` (with `--ir-minimum` for coverage)  
**Total Tests:** 556 tests across 41 test suites  
**Test Result:** ✅ 556 passed, 0 failed

**🎯 Mission: Achieve 100% branch coverage (426/426 branches)**  
**📍 Current: 29.11% (124/426 branches)**  
**📈 Gap: 302 branches to test**  
**⏱️ Timeline: 10-14 weeks**

---

## 📋 Table of Contents

1. [🚀 Quick Start Guide](#-quick-start-guide) - Start improving coverage today
2. [Executive Summary](#executive-summary) - Current metrics and targets
3. [Core Contracts Coverage Analysis](#core-contracts-coverage-analysis) - Detailed breakdown
4. [Phase 1: Foundation Tests](#phase-1-quick-wins-estimated-15-branch-coverage) - RewardMath, StakedToken, Deployer (45%)
5. [Phase 2: Core Contract Tests](#phase-2-core-contracts-estimated-25-branch-coverage) - Factory, Staking, Governor (70%)
6. [Phase 3: Excellence Tests](#phase-3-achieving-excellence-estimated-20-branch-coverage) - Exotic edges, reentrancy (90%)
7. [Phase 4: Perfection](#phase-4-perfection-estimated-10-branch-coverage) - Final 10% to 100%
8. [Test File Organization](#test-file-organization-recommendations) - Structure and naming
9. [Automated Coverage Tracking](#automated-coverage-tracking) - CI/CD integration
10. [Branch Coverage Roadmap](#branch-coverage-roadmap-to-100) - Milestone plan
11. [Quick Reference](#quick-reference-tests-to-write) - Immediate action items
12. [Conclusion](#conclusion) - Path forward and next steps

---

## 🚀 Quick Start Guide

**Want to start improving coverage immediately?** Follow these steps:

### Step 1: Verify Current Coverage (30 seconds)

```bash
cd /Users/anon/Desktop/mguleryuz/levr/packages/levr-sdk/contracts
FOUNDRY_PROFILE=dev forge coverage --match-path "test/unit/*.t.sol" --ir-minimum
```

### Step 2: Start with Highest Priority (Today)

Create the RewardMath complete branch coverage test file:

```bash
# Create new test file
touch test/unit/RewardMath.CompleteBranchCoverage.t.sol

# Copy the template from Phase 1 section below
# Run tests to verify
FOUNDRY_PROFILE=dev forge test --match-path "test/unit/RewardMath.CompleteBranchCoverage.t.sol" -vvv
```

### Step 3: Follow the Roadmap

1. **Week 1-2:** Foundation (RewardMath → LevrStakedToken → LevrDeployer → LevrTreasury)
2. **Week 3-6:** Core Contracts (LevrFactory → LevrStaking → LevrGovernor)
3. **Week 7-10:** Excellence (exotic edges → reentrancy → cross-contract)
4. **Week 11-14:** Perfection (final 10% → 100% 🎯)

### Step 4: Track Your Progress

```bash
# After each test file completion, run coverage
FOUNDRY_PROFILE=dev forge coverage --match-path "test/unit/*.t.sol" --ir-minimum

# Watch the branch coverage percentage increase!
```

**Expected Progress:**

- Day 1: RewardMath 12.5% → 100% (+1.64% overall)
- Week 1: 29% → 35% (+6% overall)
- Week 2: 35% → 45% (+10% overall)
- Month 1: 45% → 70% (+25% overall)
- Month 2: 70% → 90% (+20% overall)
- Month 3: 90% → 100% (+10% overall) 🎯

---

## Executive Summary

### Overall Coverage Metrics

| Metric         | Current Coverage     | Target   | Gap Analysis      |
| -------------- | -------------------- | -------- | ----------------- |
| **Lines**      | 53.52% (1041/1945)   | **100%** | **46.48% gap**    |
| **Statements** | 54.46% (1130/2075)   | **100%** | **45.54% gap**    |
| **Branches**   | **29.11% (124/426)** | **100%** | **🔴 70.89% gap** |
| **Functions**  | 65.62% (168/256)     | **100%** | **34.38% gap**    |

### Critical Finding

**Branch coverage is 24.41 percentage points lower than line coverage** (29.11% vs 53.52%), indicating that while we test main code paths, we're missing critical edge cases, error conditions, and conditional branches.

**To achieve 100% branch coverage:** We need to increase from 29.11% to **100%**, which requires testing **302 additional branches** (currently 124/426 covered, need all 426/426).

### Why 100% Branch Coverage?

For a DeFi protocol handling real user funds:

- ✅ **Every code path must be tested** - No untested edge cases in production
- ✅ **Security confidence** - All error conditions and attack vectors verified
- ✅ **Audit readiness** - Comprehensive test coverage reduces audit findings
- ✅ **Upgrade safety** - Future changes can be validated against complete test suite
- ✅ **Production confidence** - Know exactly how the protocol behaves in all scenarios

---

## Core Contracts Coverage Analysis

### 🔴 CRITICAL: Contracts Requiring Immediate Attention

#### 1. LevrFactory_v1.sol

```
Lines:      92.24% (202/219) ✅ Excellent
Statements: 90.91% (200/220) ✅ Excellent
Branches:   23.94% (17/71)   🔴 CRITICAL
Functions:  97.06% (33/34)   ✅ Excellent
```

**Analysis:**

- **54 untested branches** out of 71 total
- High function/line coverage but missing edge cases
- **Priority branches to test:**
  - Factory owner privilege checks (ownership transfers)
  - Protocol fee boundary conditions (0%, max%)
  - Project registration edge cases (duplicate tokens, invalid configurations)
  - Trusted factory management edge cases
  - Config validation branches (impossible values)
  - Emergency/recovery scenarios

**Recommended Test Files:**

- `LevrFactory.EdgeCases.t.sol` - Focus on validation branches
- `LevrFactory.OwnershipTransitions.t.sol` - Test ownership edge cases
- `LevrFactory.ProtocolFeeEdgeCases.t.sol` - Boundary testing

---

#### 2. LevrGovernor_v1.sol

```
Lines:      90.78% (187/206) ✅ Very Good
Statements: 90.30% (214/237) ✅ Very Good
Branches:   57.45% (27/47)   ⚠️ MODERATE
Functions:  95.83% (23/24)   ✅ Excellent
```

**Analysis:**

- **20 untested branches** out of 47 total
- Better than factory but still missing critical paths
- **Priority branches to test:**
  - Proposal execution failure paths (insufficient balance, token transfer revert)
  - Vote aggregation edge cases (overflow, underflow, ties with 4+ proposals)
  - Cycle transition edge cases (no proposals, all defeated)
  - Config snapshot edge cases (zero values, max values)
  - Winner determination with unusual vote distributions
  - Quorum/approval boundary conditions

**Existing Strong Coverage:**

- ✅ Snapshot immutability (18 tests in `LevrGovernor_SnapshotEdgeCases.t.sol`)
- ✅ Attack scenarios (5 tests in `LevrGovernorV1.AttackScenarios.t.sol`)
- ✅ Edge cases (20 tests in `LevrGovernor_MissingEdgeCases.t.sol`)

**Gap Areas:**

- ❌ Proposal type-specific failure modes
- ❌ Multiple concurrent proposal failures
- ❌ Cycle recovery with various failure combinations

**Recommended Test Files:**

- `LevrGovernor.ProposalFailureModes.t.sol` - Test all failure branches
- `LevrGovernor.VoteAggregationEdges.t.sol` - Overflow/underflow/ties
- `LevrGovernor.CycleRecoveryScenarios.t.sol` - Complex recovery paths

---

#### 3. LevrStaking_v1.sol

```
Lines:      93.33% (280/300) ✅ Excellent
Statements: 92.20% (331/359) ✅ Excellent
Branches:   41.89% (31/74)   🔴 CRITICAL
Functions:  93.55% (29/31)   ✅ Excellent
```

**Analysis:**

- **43 untested branches** out of 74 total (largest gap)
- Complex contract with many conditionals
- **Priority branches to test:**
  - Reward accrual edge cases (zero stakers, max stakers)
  - Token whitelist/cleanup failure modes
  - Multi-token stream overlaps and conflicts
  - Escrow balance edge cases (insufficient balance scenarios)
  - Stream window boundary conditions (very short, very long)
  - Weighted average calculation edge cases
  - Zero/dust amount handling
  - MAX_REWARD_TOKENS boundary (exactly at limit, over limit)

**Existing Strong Coverage:**

- ✅ Accounting precision (27 tests in `LevrStakingV1.Accounting.t.sol`)
- ✅ Global streaming (9 tests in `LevrStaking_GlobalStreamingMidstream.t.sol`)
- ✅ Core functionality (65 tests in `LevrStakingV1.t.sol`)

**Gap Areas:**

- ❌ Token cleanup failure scenarios
- ❌ Whitelist + stream interaction edge cases
- ❌ Multiple reward token limit enforcement
- ❌ Reserve accounting edge cases

**Recommended Test Files:**

- `LevrStaking.TokenManagementEdges.t.sol` - Whitelist/cleanup branches
- `LevrStaking.MultiTokenStreamConflicts.t.sol` - Stream overlap edge cases
- `LevrStaking.ReserveAccountingEdges.t.sol` - Balance/reserve boundary tests
- `LevrStaking.WeightedAverageExtreme.t.sol` - Extreme calculation scenarios

---

#### 4. LevrTreasury_v1.sol

```
Lines:      89.66% (26/29)  ✅ Very Good
Statements: 75.00% (27/36)  ⚠️ MODERATE
Branches:   40.00% (4/10)   🔴 CRITICAL
Functions:  85.71% (6/7)    ✅ Very Good
```

**Analysis:**

- **6 untested branches** out of 10 total
- Smaller contract but critical security component
- **Priority branches to test:**
  - Transfer failure scenarios (revert on transfer, insufficient balance)
  - Boost failure scenarios (staking contract revert, accrual failure)
  - Zero address validation branches
  - Reentrancy protection branches (attack scenarios)
  - Governor authorization edge cases

**Gap Areas:**

- ❌ Boost execution failures
- ❌ Transfer to malicious contracts
- ❌ Approval reset edge cases

**Recommended Test Files:**

- `LevrTreasury.TransferFailures.t.sol` - All transfer failure modes
- `LevrTreasury.BoostFailures.t.sol` - Boost execution edge cases
- `LevrTreasury.ReentrancyEdges.t.sol` - Attack vectors

---

#### 5. LevrFeeSplitter_v1.sol

```
Lines:      93.58% (102/109) ✅ Excellent
Statements: 92.42% (122/132) ✅ Excellent
Branches:   73.33% (22/30)   ⚠️ GOOD (but improvable)
Functions:  100.00% (14/14)  ✅ Perfect
```

**Analysis:**

- **8 untested branches** out of 30 total
- Best branch coverage of core contracts
- **Priority branches to test:**
  - Distribution failure modes (receiver revert, out of gas)
  - RecoverDust edge cases (zero dust, massive dust)
  - Configuration validation branches (extreme BPS values)
  - Batch distribution edge cases (very large arrays, empty array)

**Existing Strong Coverage:**

- ✅ 54 tests in `LevrFeeSplitter_MissingEdgeCases.t.sol`
- ✅ Core functionality (20 tests in `LevrFeeSplitterV1.t.sol`)

**Recommended Test Files:**

- `LevrFeeSplitter.DistributionFailures.t.sol` - Receiver revert scenarios
- `LevrFeeSplitter.ExtremeConfigurations.t.sol` - Boundary validation

---

#### 6. LevrForwarder_v1.sol

```
Lines:      86.05% (37/43)  ✅ Very Good
Statements: 88.00% (44/50)  ✅ Very Good
Branches:   80.00% (8/10)   ✅ Excellent
Functions:  71.43% (5/7)    ⚠️ MODERATE
```

**Analysis:**

- **2 untested branches** out of 10 total (best branch coverage!)
- **2 untested functions** out of 7 total
- **Priority items to test:**
  - Multicall failure modes (all combinations of allowFailure)
  - Value mismatch edge cases
  - Gas limit scenarios

**Recommended Test Files:**

- `LevrForwarder.MulticallFailureCombinations.t.sol` - Test all failure modes
- `LevrForwarder.GasLimitEdges.t.sol` - Gas exhaustion scenarios

---

#### 7. LevrStakedToken_v1.sol

```
Lines:      100.00% (18/18)  ✅ Perfect
Statements: 100.00% (13/13)  ✅ Perfect
Branches:   50.00% (4/8)     🔴 CRITICAL
Functions:  100.00% (5/5)    ✅ Perfect
```

**Analysis:**

- **4 untested branches** out of 8 total
- Perfect line coverage but missing half of branches
- **Priority branches to test:**
  - Transfer blocking in all scenarios (approve, transferFrom, various edge cases)
  - Mint/burn authorization edge cases
  - Decimal handling edge cases

**Existing Coverage:**

- ✅ 16 tests in `LevrStakedToken_NonTransferableEdgeCases.t.sol`
- ✅ 4 tests in `LevrStakedToken_NonTransferable.t.sol`

**Recommended Test Files:**

- `LevrStakedToken.TransferBlockingComplete.t.sol` - Test all transfer methods
- `LevrStakedToken.AuthorizationEdges.t.sol` - Mint/burn auth edge cases

---

#### 8. LevrDeployer_v1.sol

```
Lines:      100.00% (13/13)  ✅ Perfect
Statements: 91.67% (11/12)   ✅ Excellent
Branches:   50.00% (1/2)     🔴 CRITICAL
Functions:  100.00% (3/3)    ✅ Perfect
```

**Analysis:**

- **1 untested branch** out of 2 total
- Simple contract, easy to achieve full coverage
- **Priority branches to test:**
  - Constructor validation (zero address scenarios)
  - Deployment failure modes

**Recommended Test Files:**

- `LevrDeployer.ValidationEdges.t.sol` - Complete validation testing

---

#### 9. RewardMath.sol (Library)

```
Lines:      81.82% (27/33)  ✅ Very Good
Statements: 84.00% (42/50)  ✅ Very Good
Branches:   12.50% (1/8)    🔴 CRITICAL (WORST)
Functions:  100.00% (4/4)   ✅ Perfect
```

**Analysis:**

- **7 untested branches** out of 8 total (WORST branch coverage)
- Critical math library with complex edge cases
- **Priority branches to test:**
  - Division by zero protection (all functions)
  - Overflow/underflow scenarios
  - Zero input handling (accPerShare, totalStaked, duration, etc.)
  - Extreme value combinations (max uint256, dust amounts)
  - Precision loss scenarios

**Existing Coverage:**

- ✅ 4 tests in `RewardMath.DivisionSafety.t.sol` (but limited)

**Recommended Test Files:**

- `RewardMath.BranchCoverage.t.sol` - Systematic branch testing
- `RewardMath.ExtremeValues.t.sol` - Boundary and overflow tests
- `RewardMath.ZeroHandling.t.sol` - All zero-value scenarios
- `RewardMath.PrecisionEdges.t.sol` - Precision loss edge cases

---

## Untested/Low Coverage Areas

### Scripts (0% coverage - expected)

```
script/DeployLevr.s.sol                    0.00%
script/DeployLevrFactoryDevnet.s.sol       0.00%
script/DeployLevrFeeSplitter.s.sol         0.00%
script/ExampleDeploy.s.sol                 0.00%
script/TransferFactoryOwnership.s.sol      0.00%
```

**Note:** Scripts are deployment artifacts and typically not unit tested. Consider integration/e2e tests for deployment flows.

---

### Test Utilities (Low coverage - expected)

```
test/utils/BaseForkTest.sol                0.00%
test/utils/ClankerDeployer.sol             0.00%
test/utils/SwapV4Helper.sol                0.00%
test/utils/MerkleAirdropHelper.sol         0.00%
test/utils/LevrFactoryDeployHelper.sol     81.82%
```

**Note:** Test utilities are helpers and don't need coverage. Focus on core contracts.

---

## Detailed Branch Coverage Improvement Plan

### Phase 1: Quick Wins (Estimated +15% branch coverage)

**Target:** Increase branch coverage from 29.11% to ~45%

#### 1.1 RewardMath Library (HIGHEST PRIORITY)

**Current:** 12.50% branches (1/8)  
**Target:** 100% branches (8/8)  
**Impact:** +1.64% overall branch coverage

**Required Tests:**

```solidity
// test/unit/RewardMath.CompleteBranchCoverage.t.sol
contract RewardMath_CompleteBranchCoverage_Test is Test {
    // Test EVERY branch in EVERY function

    // calculateVestedAmount branches:
    // - if (duration == 0) return 0;
    // - if (elapsed >= duration) return total;
    // - else return (total * elapsed) / duration;

    // calculateUnvested branches:
    // - if (current >= streamEnd) return 0;
    // - if (current <= streamStart) return streamTotal;
    // - else calculation

    // calculateProportionalClaim branches:
    // - if (totalStaked == 0) return 0;
    // - if (accPerShare == 0) return 0;
    // - else calculation

    // calculateCurrentPool branches:
    // - vested amount calculation
    // - currentPool = unvested + vested
}
```

**Specific Tests Needed:**

1. ✅ `test_calculateVestedAmount_zeroDuration_returnsZero()`
2. ✅ `test_calculateVestedAmount_elapsedEqualsOrExceedsDuration_returnsTotal()`
3. ✅ `test_calculateVestedAmount_partialElapsed_returnsProportional()`
4. ❌ `test_calculateUnvested_currentAtOrBeforeStreamStart_returnsStreamTotal()`
5. ❌ `test_calculateUnvested_currentAtOrAfterStreamEnd_returnsZero()`
6. ❌ `test_calculateUnvested_currentMidstream_returnsUnvested()`
7. ❌ `test_calculateProportionalClaim_zeroTotalStaked_returnsZero()`
8. ❌ `test_calculateProportionalClaim_zeroAccPerShare_returnsZero()`
9. ❌ `test_calculateProportionalClaim_validInputs_returnsCorrectClaim()`
10. ❌ `test_calculateCurrentPool_allCombinations()` (stream states × pool states)

---

#### 1.2 LevrStakedToken_v1.sol

**Current:** 50.00% branches (4/8)  
**Target:** 100% branches (8/8)  
**Impact:** +0.94% overall branch coverage

**Required Tests:**

```solidity
// test/unit/LevrStakedToken.TransferBlockingComplete.t.sol
contract LevrStakedToken_TransferBlockingComplete_Test {
    // Test EVERY transfer-blocking scenario:

    function test_transfer_blocked() public { /* ✅ exists */ }
    function test_transferFrom_blocked() public { /* ✅ exists */ }

    // NEW TESTS NEEDED:
    function test_approve_allowsApprovalButTransferStillBlocked() public {
        // Approve should succeed but transferFrom should fail
    }

    function test_increaseAllowance_allowsIncreaseButTransferStillBlocked() public {
        // Test ERC20 optional increase/decrease
    }

    function test_decreaseAllowance_allowsDecreaseButTransferStillBlocked() public {
        // Test ERC20 optional increase/decrease
    }

    function test_mint_onlyFromStaking_otherwiseReverts() public {
        // ✅ Test auth branches
    }

    function test_burn_onlyFromStaking_otherwiseReverts() public {
        // ✅ Test auth branches
    }
}
```

---

#### 1.3 LevrDeployer_v1.sol

**Current:** 50.00% branches (1/2)  
**Target:** 100% branches (2/2)  
**Impact:** +0.23% overall branch coverage

**Required Tests:**

```solidity
// test/unit/LevrDeployer.ValidationComplete.t.sol
contract LevrDeployer_ValidationComplete_Test {
    function test_constructor_zeroTreasuryImpl_reverts() public {
        // Test both branches of treasury validation
    }

    function test_constructor_zeroStakingImpl_reverts() public {
        // Test both branches of staking validation
    }

    function test_constructor_validImpls_succeeds() public {
        // ✅ Already tested
    }
}
```

---

#### 1.4 LevrTreasury_v1.sol

**Current:** 40.00% branches (4/10)  
**Target:** 80.00% branches (8/10)  
**Impact:** +0.94% overall branch coverage

**Required Tests:**

```solidity
// test/unit/LevrTreasury.CompleteBranchCoverage.t.sol
contract LevrTreasury_CompleteBranchCoverage_Test {
    // TRANSFER BRANCHES:
    function test_transfer_tokenZeroAddress_reverts() public { /* ✅ exists */ }
    function test_transfer_toZeroAddress_reverts() public { /* ✅ exists */ }
    function test_transfer_amountExceedsBalance_reverts() public { /* ✅ exists */ }
    function test_transfer_onlyGovernor() public { /* ✅ exists */ }

    // NEW TESTS NEEDED:
    function test_transfer_maliciousTokenReturnsFalse_handled() public {
        // Test SafeERC20 handling of non-standard tokens
    }

    function test_transfer_normalExecution_succeeds() public {
        // ✅ Already tested in integration
    }

    // BOOST BRANCHES:
    function test_boost_amountZero_noOp() public { /* ✅ exists */ }

    function test_boost_stakingAccrueReverts_handled() public {
        // NEW: Test when staking.accrueFromTreasury reverts
    }

    function test_boost_insufficientBalance_reverts() public {
        // NEW: Test when treasury doesn't have enough tokens
    }

    function test_boost_normalExecution_succeeds() public {
        // ✅ Already tested
    }
}
```

---

### Phase 2: Core Contract Branches (Estimated +25% branch coverage)

**Target:** Increase from ~45% to ~70%

#### 2.1 LevrFactory_v1.sol

**Current:** 23.94% branches (17/71)  
**Target:** 85.00% branches (~60/71)  
**Impact:** +10.09% overall branch coverage

**Required Tests (organized by function):**

```solidity
// test/unit/LevrFactory.CompleteBranchCoverage.t.sol

contract LevrFactory_CompleteBranchCoverage_Test {

    // === CONSTRUCTOR BRANCHES ===
    function test_constructor_allZeroAddresses_revert() public {
        // Test: deployer == 0, weth == 0, protocolTreasury == 0
    }

    // === REGISTER BRANCHES ===
    function test_register_tokenZeroAddress_reverts() public {
        // if (token == address(0)) revert ZeroAddress();
    }

    function test_register_alreadyRegistered_reverts() public {
        // ✅ Already tested
    }

    function test_register_preparedContractsFromDifferentCaller_reverts() public {
        // ✅ Already tested
    }

    function test_register_noPreparedContracts_reverts() public {
        // ✅ Already tested
    }

    function test_register_invalidClankerToken_reverts() public {
        // Test when token doesn't match Clanker factory metadata
    }

    function test_register_noTrustedFactories_reverts() public {
        // ✅ Already tested in ClankerValidation
    }

    // === UPDATE PROJECT CONFIG BRANCHES ===
    function test_updateProjectConfig_notTokenAdmin_reverts() public {
        // ✅ Already tested
    }

    function test_updateProjectConfig_projectNotVerified_reverts() public {
        // ✅ Already tested
    }

    function test_updateProjectConfig_invalidQuorum_reverts() public {
        // if (quorumBps > 10000) revert InvalidBps();
    }

    function test_updateProjectConfig_invalidApproval_reverts() public {
        // if (approvalBps > 10000) revert InvalidBps();
    }

    function test_updateProjectConfig_zeroProposalWindow_reverts() public {
        // ✅ Already tested in ConfigGridlock
    }

    function test_updateProjectConfig_zeroVotingWindow_reverts() public {
        // if (votingWindowSeconds == 0) revert InvalidConfig();
    }

    function test_updateProjectConfig_maxActiveProposalsZero_reverts() public {
        // ✅ Already tested in ConfigGridlock
    }

    function test_updateProjectConfig_maxProposalAmountBpsOverMax_reverts() public {
        // if (maxProposalAmountBps > 10000) revert InvalidBps();
    }

    // === SET VERIFIED BRANCHES ===
    function test_setVerified_onlyOwner() public {
        // if (msg.sender != owner) revert OnlyOwner();
    }

    function test_setVerified_tokenZeroAddress_reverts() public {
        // if (token == address(0)) revert ZeroAddress();
    }

    function test_setVerified_tokenNotRegistered_reverts() public {
        // if (project.staking == address(0)) revert TokenNotRegistered();
    }

    function test_setVerified_alreadyVerifiedToTrue_noOp() public {
        // if (verified && project.verified) no state change
    }

    function test_setVerified_alreadyUnverifiedToFalse_noOp() public {
        // if (!verified && !project.verified) no state change
    }

    function test_setVerified_verifyRemovesCustomConfig() public {
        // When setting verified = false, config should reset
    }

    // === TRUSTED CLANKER FACTORY BRANCHES ===
    function test_addTrustedClankerFactory_onlyOwner() public {
        // ✅ Already tested
    }

    function test_addTrustedClankerFactory_zeroAddress_reverts() public {
        // ✅ Already tested
    }

    function test_addTrustedClankerFactory_alreadyTrusted_reverts() public {
        // ✅ Already tested
    }

    function test_removeTrustedClankerFactory_onlyOwner() public {
        // ✅ Already tested
    }

    function test_removeTrustedClankerFactory_notTrusted_reverts() public {
        // ✅ Already tested
    }

    // === UPDATE PROTOCOL TREASURY BRANCHES ===
    function test_updateProtocolTreasury_onlyOwner() public {
        // if (msg.sender != owner) revert OnlyOwner();
    }

    function test_updateProtocolTreasury_zeroAddress_reverts() public {
        // if (newTreasury == address(0)) revert ZeroAddress();
    }

    function test_updateProtocolTreasury_sameAsOld_noOp() public {
        // if (newTreasury == protocolTreasury) no state change
    }

    // === UPDATE PROTOCOL FEE BRANCHES ===
    function test_updateProtocolFee_onlyOwner() public {
        // ✅ Already tested
    }

    function test_updateProtocolFee_exceedsMax_reverts() public {
        // if (feeBps > 10000) revert InvalidBps();
    }

    function test_updateProtocolFee_sameAsOld_noOp() public {
        // if (feeBps == protocolFeeBps) no state change
    }

    // === UPDATE INITIAL WHITELIST BRANCHES ===
    function test_updateInitialWhitelist_onlyOwner() public {
        // ✅ Already tested
    }

    function test_updateInitialWhitelist_zeroAddress_reverts() public {
        // ✅ Already tested
    }

    function test_updateInitialWhitelist_emptyArray_allowed() public {
        // Test if (tokens.length == 0) branch
    }

    function test_updateInitialWhitelist_duplicateTokens_allowed() public {
        // Test if duplicates are filtered or cause issues
    }

    // === GET PROJECTS BRANCHES ===
    function test_getProjects_offsetBeyondTotal_returnsEmpty() public {
        // ✅ Already tested
    }

    function test_getProjects_limitZero_returnsEmpty() public {
        // ✅ Already tested
    }

    function test_getProjects_limitExceedsRemaining_returnsPartial() public {
        // ✅ Already tested
    }

    // === COMPUTE DETERMINISTIC ADDRESS BRANCHES ===
    function test_computeDeterministicAddress_consistentResults() public {
        // Test pure function with various inputs
    }
}
```

**Total New Tests for Factory:** ~35-40 tests

---

#### 2.2 LevrStaking_v1.sol

**Current:** 41.89% branches (31/74)  
**Target:** 85.00% branches (~63/74)  
**Impact:** +7.51% overall branch coverage

**Required Tests:**

```solidity
// test/unit/LevrStaking.CompleteBranchCoverage.t.sol

contract LevrStaking_CompleteBranchCoverage_Test {

    // === STAKE BRANCHES ===
    function test_stake_amountZero_reverts() public {
        // if (amount == 0) revert ZeroAmount();
    }

    function test_stake_firstStaker_initializesCorrectly() public {
        // ✅ Already tested
    }

    function test_stake_subsequentStaker_weightedAverageWorks() public {
        // ✅ Already tested
    }

    function test_stake_duringActiveStream_accountingCorrect() public {
        // ✅ Already tested
    }

    function test_stake_overflowInWeightedAverage_reverts() public {
        // Test when (oldBalance * oldTime + newBalance * newTime) overflows
    }

    function test_stake_insufficientAllowance_reverts() public {
        // SafeERC20 should handle this
    }

    function test_stake_insufficientBalance_reverts() public {
        // SafeERC20 should handle this
    }

    // === UNSTAKE BRANCHES ===
    function test_unstake_amountZero_reverts() public {
        // if (amount == 0) revert ZeroAmount();
    }

    function test_unstake_amountExceedsBalance_reverts() public {
        // ✅ Already tested
    }

    function test_unstake_toZeroAddress_reverts() public {
        // ✅ Already tested
    }

    function test_unstake_insufficientEscrow_reverts() public {
        // ✅ Already tested
    }

    function test_unstake_fullUnstake_resetsTime() public {
        // ✅ Already tested
    }

    function test_unstake_partialUnstake_adjustsTime() public {
        // ✅ Already tested
    }

    function test_unstake_autoClaimsRewards() public {
        // Test internal _claimForUser call
    }

    function test_unstake_lastStakerExit_preservesStream() public {
        // ✅ Already tested
    }

    // === ACCRUE REWARDS BRANCHES ===
    function test_accrueRewards_tokenZeroAddress_reverts() public {
        // if (token == address(0)) revert ZeroAddress();
    }

    function test_accrueRewards_amountZero_reverts() public {
        // if (amount == 0) revert ZeroAmount();
    }

    function test_accrueRewards_notWhitelisted_reverts() public {
        // if (!_whitelisted[token]) revert TokenNotWhitelisted();
    }

    function test_accrueRewards_exceedsMaxRewardTokens_reverts() public {
        // ✅ Already tested in LevrTokenAgnosticDOS
    }

    function test_accrueRewards_newToken_initializesStream() public {
        // if (!_rewardTokenActive[token]) initialize
    }

    function test_accrueRewards_existingToken_extendsStream() public {
        // ✅ Already tested
    }

    function test_accrueRewards_zeroStakers_preservesRewards() public {
        // ✅ Already tested
    }

    function test_accrueRewards_midstream_preservesUnvested() public {
        // ✅ Already tested
    }

    function test_accrueRewards_pastStreamEnd_startsNewStream() public {
        // ✅ Already tested
    }

    // === ACCRUE FROM TREASURY BRANCHES ===
    function test_accrueFromTreasury_tokenZeroAddress_reverts() public {
        // if (token == address(0)) revert ZeroAddress();
    }

    function test_accrueFromTreasury_amountZero_noOp() public {
        // if (amount == 0) return;
    }

    function test_accrueFromTreasury_pullsAndAccrues() public {
        // ✅ Already tested
    }

    function test_accrueFromTreasury_pullFails_reverts() public {
        // Test SafeERC20 revert handling
    }

    // === CLAIM BRANCHES ===
    function test_claim_emptyTokenArray_noOp() public {
        // ✅ Already tested
    }

    function test_claim_userBalanceZero_reverts() public {
        // if (userBalance == 0) revert InsufficientBalance();
    }

    function test_claim_tokenNotActive_skips() public {
        // if (!_rewardTokenActive[token]) continue;
    }

    function test_claim_noPendingRewards_skips() public {
        // if (pending == 0) continue;
    }

    function test_claim_insufficientReserve_reverts() public {
        // ✅ Already tested
    }

    function test_claim_multipleTokens_success() public {
        // ✅ Already tested
    }

    function test_claim_transferFails_reverts() public {
        // Test SafeERC20 handling
    }

    // === WHITELIST TOKEN BRANCHES ===
    function test_whitelistToken_onlyTokenAdmin() public {
        // ✅ Already tested
    }

    function test_whitelistToken_zeroAddress_reverts() public {
        // if (token == address(0)) revert ZeroAddress();
    }

    function test_whitelistToken_alreadyWhitelisted_reverts() public {
        // ✅ Already tested
    }

    function test_whitelistToken_underlyingToken_reverts() public {
        // ✅ Already tested
    }

    // === UNWHITELIST TOKEN BRANCHES ===
    function test_unwhitelistToken_onlyTokenAdmin() public {
        // ✅ Already tested
    }

    function test_unwhitelistToken_notWhitelisted_reverts() public {
        // if (!_whitelisted[token]) revert TokenNotWhitelisted();
    }

    function test_unwhitelistToken_underlyingToken_reverts() public {
        // ✅ Already tested
    }

    function test_unwhitelistToken_hasPendingRewards_reverts() public {
        // ✅ Already tested
    }

    function test_unwhitelistToken_hasPoolRewards_reverts() public {
        // ✅ Already tested
    }

    // === CLEANUP TOKEN BRANCHES ===
    function test_cleanupToken_notWhitelisted_succeeds() public {
        // ✅ Already tested
    }

    function test_cleanupToken_whitelisted_reverts() public {
        // ✅ Already tested
    }

    function test_cleanupToken_hasRewards_reverts() public {
        // ✅ Already tested
    }

    function test_cleanupToken_finishedToken_freesSlot() public {
        // ✅ Already tested
    }

    // === CREDIT REWARDS BRANCHES ===
    function test_creditRewards_tokenZeroAddress_reverts() public {
        // if (token == address(0)) revert ZeroAddress();
    }

    function test_creditRewards_amountZero_reverts() public {
        // if (amount == 0) revert ZeroAmount();
    }

    function test_creditRewards_belowMinimum_reverts() public {
        // ✅ Already tested in RewardTokenDoS
    }

    function test_creditRewards_notWhitelisted_reverts() public {
        // Same as accrueRewards
    }

    function test_creditRewards_manualTransfer_works() public {
        // ✅ Already tested
    }
}
```

**Total New Tests for Staking:** ~25-30 tests

---

#### 2.3 LevrGovernor_v1.sol

**Current:** 57.45% branches (27/47)  
**Target:** 90.00% branches (~42/47)  
**Impact:** +3.52% overall branch coverage

**Required Tests:**

```solidity
// test/unit/LevrGovernor.CompleteBranchCoverage.t.sol

contract LevrGovernor_CompleteBranchCoverage_Test {

    // === PROPOSE BOOST BRANCHES ===
    function test_proposeBoost_tokenZeroAddress_reverts() public {
        // if (token == address(0)) revert ZeroAddress();
    }

    function test_proposeBoost_amountZero_reverts() public {
        // if (amount == 0) revert ZeroAmount();
    }

    function test_proposeBoost_exceedsMaxProposalAmount_reverts() public {
        // ✅ Already tested
    }

    function test_proposeBoost_insufficientVP_reverts() public {
        // if (vp < minVp) revert InsufficientVotingPower();
    }

    function test_proposeBoost_alreadyProposedThisType_reverts() public {
        // ✅ Already tested in governor tests
    }

    function test_proposeBoost_exceedsMaxActiveProposals_reverts() public {
        // ✅ Already tested
    }

    function test_proposeBoost_cycleNotActive_autoStarts() public {
        // ✅ Already tested
    }

    // === PROPOSE TRANSFER BRANCHES ===
    function test_proposeTransfer_tokenZeroAddress_reverts() public {
        // Similar to proposeBoost
    }

    function test_proposeTransfer_toZeroAddress_reverts() public {
        // if (to == address(0)) revert ZeroAddress();
    }

    function test_proposeTransfer_amountZero_reverts() public {
        // if (amount == 0) revert ZeroAmount();
    }

    function test_proposeTransfer_allOtherBranchesSameAsBoost() public {
        // Test all shared branches
    }

    // === VOTE BRANCHES ===
    function test_vote_proposalNotInVotingWindow_reverts() public {
        // if (block.timestamp < votingStart || block.timestamp > votingEnd) revert
    }

    function test_vote_alreadyVoted_reverts() public {
        // ✅ Already tested
    }

    function test_vote_zeroVP_reverts() public {
        // ✅ Already tested
    }

    function test_vote_invalidSupport_reverts() public {
        // if (support > 1) revert InvalidSupport();
    }

    function test_vote_votingEnded_reverts() public {
        // Test exact boundary
    }

    function test_vote_votingNotStarted_reverts() public {
        // Test exact boundary
    }

    // === EXECUTE BRANCHES ===
    function test_execute_cycleAlreadyExecuted_reverts() public {
        // if (cycle.executed) revert AlreadyExecuted();
    }

    function test_execute_votingNotEnded_reverts() public {
        // if (block.timestamp <= cycle.votingEndsAt) revert VotingNotEnded();
    }

    function test_execute_noWinner_reverts() public {
        // ✅ Already tested
    }

    function test_execute_winnerFailsQuorum_defeatsAndEmitsEvent() public {
        // ✅ Already tested in DefeatHandling
    }

    function test_execute_winnerFailsApproval_defeatsAndEmitsEvent() public {
        // ✅ Already tested
    }

    function test_execute_treasoryInsufficientBalance_defeatsAndEmitsEvent() public {
        // ✅ Already tested
    }

    function test_execute_boostTransferFails_defeatsAndEmitsEvent() public {
        // Test when treasury.applyBoost reverts
    }

    function test_execute_transferFails_defeatsAndEmitsEvent() public {
        // Test when treasury.transfer reverts
    }

    function test_execute_success_autoStartsNextCycle() public {
        // ✅ Already tested
    }

    // === START NEW CYCLE BRANCHES ===
    function test_startNewCycle_executableProposalExists_reverts() public {
        // ✅ Already tested
    }

    function test_startNewCycle_votingNotEnded_reverts() public {
        // if (block.timestamp <= cycle.votingEndsAt) revert VotingNotEnded();
    }

    function test_startNewCycle_firstCycle_succeeds() public {
        // Test cycle ID = 0 initialization
    }

    function test_startNewCycle_permissionless_anyoneCanCall() public {
        // ✅ Already tested
    }

    // === DETERMINE WINNER BRANCHES ===
    function test_determineWinner_noProposals_returnsZero() public {
        // ✅ Already tested
    }

    function test_determineWinner_tieBreaking_lowestIdWins() public {
        // ✅ Already tested
    }

    function test_determineWinner_multipleProposalsVariousVotes() public {
        // ✅ Already tested
    }

    // === UPDATE GOVERNANCE CONFIG BRANCHES ===
    function test_updateGovernanceConfig_onlyOwner() public {
        // if (msg.sender != owner) revert OnlyOwner();
    }

    function test_updateGovernanceConfig_invalidQuorum_reverts() public {
        // if (quorumBps > 10000) revert InvalidBps();
    }

    function test_updateGovernanceConfig_invalidApproval_reverts() public {
        // if (approvalBps > 10000) revert InvalidBps();
    }

    function test_updateGovernanceConfig_zeroProposalWindow_reverts() public {
        // ✅ Already tested
    }

    function test_updateGovernanceConfig_zeroVotingWindow_reverts() public {
        // if (votingWindowSeconds == 0) revert InvalidConfig();
    }

    function test_updateGovernanceConfig_maxActiveProposalsZero_reverts() public {
        // ✅ Already tested
    }
}
```

**Total New Tests for Governor:** ~20-25 tests

---

### Phase 3: Achieving Excellence (Estimated +20% branch coverage)

**Target:** Increase from ~70% to ~90%

This phase focuses on:

1. **Exotic edge cases** (extreme values, unusual combinations)
2. **Reentrancy scenarios** (attack vectors)
3. **Integration-level branch coverage** (cross-contract interactions)
4. **Failure mode combinations** (multiple failures at once)
5. **All remaining untested branches** (systematic completion)

**Recommended Test Files:**

```
test/unit/LevrProtocol.ExoticEdgeCases.t.sol
test/unit/LevrProtocol.ReentrancyVectors.t.sol
test/unit/LevrProtocol.FailureModeCombinations.t.sol
test/unit/LevrProtocol.CrossContractBranches.t.sol
```

---

### Phase 4: Perfection (Estimated +10% branch coverage)

**Target:** Achieve 100% branch coverage (426/426 branches)

This phase focuses on:

1. **The final 10%** - Most difficult/obscure branches
2. **Contract-specific edge cases** that require complex setup
3. **Extreme boundary conditions** (max uint256, overflow scenarios)
4. **Multi-step failure scenarios** (cascading failures)
5. **Every single remaining untested branch** systematically

**Strategy:**

1. Generate coverage report after Phase 3
2. Identify ALL remaining uncovered branches
3. Create one test file per contract with remaining gaps
4. Systematically test each branch until 100% achieved

**Required Test Files:**

```
test/unit/LevrFactory.Final10Percent.t.sol
test/unit/LevrStaking.Final10Percent.t.sol
test/unit/LevrGovernor.Final10Percent.t.sol
test/unit/LevrFeeSplitter.Final10Percent.t.sol
test/unit/LevrTreasury.Final10Percent.t.sol
test/unit/LevrForwarder.Final10Percent.t.sol
test/unit/AllContracts.CompletelyExhausitve.t.sol
```

---

## Test File Organization Recommendations

### Current Test Structure (Good)

```
test/unit/
├── Contract-Specific Tests
│   ├── LevrFactoryV1.PrepareForDeployment.t.sol (21 tests)
│   ├── LevrFactoryV1.Security.t.sol (5 tests)
│   ├── LevrFactory_ConfigGridlock.t.sol (15 tests)
│   ├── LevrFactory_VerifiedProjects.t.sol (15 tests)
│   ├── LevrFactory.ClankerValidation.t.sol (14 tests)
│   ├── LevrFactory_TrustedFactoryRemoval.t.sol (9 tests)
│   └── ... (more)
│
├── Cross-Contract Tests
│   ├── LevrAllContracts_EdgeCases.t.sol (14 tests)
│   ├── LevrComparativeAudit.t.sol (14 tests)
│   ├── LevrGovernor_CrossContract.t.sol (8 tests)
│   └── ... (more)
│
└── Specialized Tests
    ├── LevrAderynFindings.t.sol (17 tests)
    ├── LevrExternalAudit4.Validation.t.sol (6 tests)
    ├── RewardMath.DivisionSafety.t.sol (4 tests)
    └── ... (more)
```

### Recommended New Test Files

```
test/unit/
├── Coverage-Focused Tests (NEW)
│   ├── LevrFactory.CompleteBranchCoverage.t.sol        (35-40 tests)
│   ├── LevrGovernor.CompleteBranchCoverage.t.sol       (20-25 tests)
│   ├── LevrStaking.CompleteBranchCoverage.t.sol        (25-30 tests)
│   ├── LevrTreasury.CompleteBranchCoverage.t.sol       (10-12 tests)
│   ├── LevrFeeSplitter.CompleteBranchCoverage.t.sol    (8-10 tests)
│   ├── LevrForwarder.CompleteBranchCoverage.t.sol      (5-8 tests)
│   ├── LevrStakedToken.CompleteBranchCoverage.t.sol    (6-8 tests)
│   ├── LevrDeployer.CompleteBranchCoverage.t.sol       (3-4 tests)
│   └── RewardMath.CompleteBranchCoverage.t.sol         (10-12 tests)
│
├── Failure Mode Tests (NEW)
│   ├── LevrFactory.FailureModes.t.sol
│   ├── LevrGovernor.FailureModes.t.sol
│   ├── LevrStaking.FailureModes.t.sol
│   └── LevrTreasury.FailureModes.t.sol
│
└── Integration Branch Tests (NEW)
    ├── LevrProtocol.CrossContractBranches.t.sol
    └── LevrProtocol.FailureModeCombinations.t.sol
```

---

## Automated Coverage Tracking

### Recommended CI/CD Integration

```yaml
# .github/workflows/coverage.yml
name: Coverage Report

on:
  push:
    branches: [main, develop]
  pull_request:
    branches: [main, develop]

jobs:
  coverage:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3

      - name: Install Foundry
        uses: foundry-rs/foundry-toolchain@v1

      - name: Run coverage
        run: |
          FOUNDRY_PROFILE=dev forge coverage --match-path "test/unit/*.t.sol" --ir-minimum --report summary > coverage.txt
          cat coverage.txt

      - name: Check branch coverage threshold (100% target)
        run: |
          BRANCH_COV=$(grep "% Branches" coverage.txt | awk '{print $4}' | sed 's/%//' | head -1)
          echo "Current branch coverage: $BRANCH_COV%"

          # Enforce 100% branch coverage on main
          if [ "${{ github.ref }}" == "refs/heads/main" ]; then
            if (( $(echo "$BRANCH_COV < 100.0" | bc -l) )); then
              echo "❌ BLOCKED: Branch coverage $BRANCH_COV% is below 100% requirement for main branch"
              exit 1
            fi
            echo "✅ SUCCESS: 100% branch coverage achieved!"
          else
            # For PRs, check coverage doesn't decrease
            # (implement coverage comparison with base branch here)
            echo "⚠️ PR coverage check: $BRANCH_COV%"
            if (( $(echo "$BRANCH_COV < 29.11" | bc -l) )); then
              echo "❌ BLOCKED: Coverage decreased from baseline (29.11%)"
              exit 1
            fi
          fi

      - name: Generate LCOV report
        if: always()
        run: |
          FOUNDRY_PROFILE=dev forge coverage --match-path "test/unit/*.t.sol" --ir-minimum --report lcov

      - name: Upload coverage to Codecov
        if: always()
        uses: codecov/codecov-action@v3
        with:
          files: ./lcov.info
          flags: unit-tests
          name: levr-coverage

      - name: Coverage summary comment on PR
        if: github.event_name == 'pull_request'
        uses: actions/github-script@v6
        with:
          script: |
            const fs = require('fs');
            const coverage = fs.readFileSync('coverage.txt', 'utf8');
            const branchMatch = coverage.match(/(\d+\.\d+)% \(\d+\/\d+\).*Branches/);
            const branchCov = branchMatch ? branchMatch[1] : 'unknown';

            const body = `## 📊 Coverage Report

            **Branch Coverage:** ${branchCov}%
            **Target:** 100%
            **Gap:** ${(100 - parseFloat(branchCov)).toFixed(2)}%

            ${parseFloat(branchCov) >= 100 ? '✅ **100% COVERAGE ACHIEVED!** 🎉' : '⚠️ Additional coverage needed'}

            <details>
            <summary>Full Coverage Report</summary>

            \`\`\`
            ${coverage}
            \`\`\`
            </details>`;

            github.rest.issues.createComment({
              issue_number: context.issue.number,
              owner: context.repo.owner,
              repo: context.repo.repo,
              body: body
            });
```

### Progressive Coverage Enforcement

For gradual rollout, use milestone-based thresholds:

```yaml
# .github/workflows/coverage-progressive.yml
- name: Check milestone-based coverage threshold
  run: |
    BRANCH_COV=$(grep "% Branches" coverage.txt | awk '{print $4}' | sed 's/%//' | head -1)
    CURRENT_DATE=$(date +%s)

    # Milestone 1: 45% by Week 2
    MILESTONE_1_DATE=$(date -d "2025-11-16" +%s)  # Nov 16, 2025
    # Milestone 2: 70% by Week 6
    MILESTONE_2_DATE=$(date -d "2025-12-14" +%s)  # Dec 14, 2025
    # Milestone 3: 90% by Week 10
    MILESTONE_3_DATE=$(date -d "2026-01-11" +%s)  # Jan 11, 2026
    # Milestone 4: 100% by Week 14
    MILESTONE_4_DATE=$(date -d "2026-02-08" +%s)  # Feb 8, 2026

    REQUIRED_COV=29.11  # Baseline

    if [ $CURRENT_DATE -ge $MILESTONE_4_DATE ]; then
      REQUIRED_COV=100.0
      echo "📅 Milestone 4: Enforcing 100% coverage"
    elif [ $CURRENT_DATE -ge $MILESTONE_3_DATE ]; then
      REQUIRED_COV=90.0
      echo "📅 Milestone 3: Enforcing 90% coverage"
    elif [ $CURRENT_DATE -ge $MILESTONE_2_DATE ]; then
      REQUIRED_COV=70.0
      echo "📅 Milestone 2: Enforcing 70% coverage"
    elif [ $CURRENT_DATE -ge $MILESTONE_1_DATE ]; then
      REQUIRED_COV=45.0
      echo "📅 Milestone 1: Enforcing 45% coverage"
    fi

    if (( $(echo "$BRANCH_COV < $REQUIRED_COV" | bc -l) )); then
      echo "❌ Coverage $BRANCH_COV% is below required $REQUIRED_COV%"
      exit 1
    fi

    echo "✅ Coverage $BRANCH_COV% meets requirement of $REQUIRED_COV%"
```

### Coverage Monitoring Script

```bash
#!/bin/bash
# scripts/coverage-check.sh

echo "Running coverage analysis..."
FOUNDRY_PROFILE=dev forge coverage --match-path "test/unit/*.t.sol" --ir-minimum > coverage.txt

echo ""
echo "=== COVERAGE SUMMARY ==="
grep "% Lines\|% Statements\|% Branches\|% Funcs" coverage.txt | head -4

echo ""
echo "=== CONTRACTS BELOW 80% BRANCH COVERAGE ==="
awk '/src\/.*\.sol/ {
  if ($4 != "100.00%" && $4 != "-") {
    cov = $4
    sub(/%/, "", cov)
    if (cov < 80) {
      print $1 "\t" $4
    }
  }
}' coverage.txt

echo ""
echo "=== PRIORITY: CONTRACTS BELOW 50% BRANCH COVERAGE ==="
awk '/src\/.*\.sol/ {
  if ($4 != "100.00%" && $4 != "-") {
    cov = $4
    sub(/%/, "", cov)
    if (cov < 50) {
      print "🔴 " $1 "\t" $4
    }
  }
}' coverage.txt
```

---

## Branch Coverage Roadmap to 100%

### Milestone 1: Foundation (Target: 45% branch coverage)

**Timeline:** 1-2 weeks  
**Estimated Tests:** ~70 new tests  
**Branches to Cover:** +68 branches (124 → 192/426)

**Focus Areas:**

1. ✅ RewardMath library (12 tests) - **HIGHEST PRIORITY** - +7 branches
2. ✅ LevrStakedToken (6 tests) - +4 branches
3. ✅ LevrDeployer (3 tests) - +1 branch
4. ✅ LevrTreasury core branches (12 tests) - +6 branches
5. ✅ LevrForwarder remaining branches (8 tests) - +2 branches
6. ✅ LevrFeeSplitter remaining branches (12 tests) - +8 branches
7. ✅ ERC2771ContextBase coverage (5 tests) - Complete coverage

**Success Criteria:**

- ✅ RewardMath: **100% branch coverage (8/8)**
- ✅ LevrStakedToken: **100% branch coverage (8/8)**
- ✅ LevrDeployer: **100% branch coverage (2/2)**
- ✅ LevrTreasury: **80% branch coverage (8/10)**
- ✅ LevrForwarder: **100% branch coverage (10/10)**
- ✅ LevrFeeSplitter: **100% branch coverage (30/30)**
- ✅ Overall: **45% (192/426 branches)**

---

### Milestone 2: Core Contracts (Target: 70% branch coverage)

**Timeline:** 3-4 weeks  
**Estimated Tests:** ~100 new tests  
**Branches to Cover:** +107 branches (192 → 299/426)

**Focus Areas:**

1. ✅ LevrFactory validation branches (40 tests) - +43 branches (17 → 60/71)
2. ✅ LevrStaking validation branches (35 tests) - +32 branches (31 → 63/74)
3. ✅ LevrGovernor failure modes (25 tests) - +15 branches (27 → 42/47)
4. ✅ Remaining LevrTreasury branches (8 tests) - +2 branches (8 → 10/10)

**Success Criteria:**

- ✅ LevrFactory: **85% branch coverage (60/71)**
- ✅ LevrStaking: **85% branch coverage (63/74)**
- ✅ LevrGovernor: **90% branch coverage (42/47)**
- ✅ LevrTreasury: **100% branch coverage (10/10)**
- ✅ Overall: **70% (299/426 branches)**

---

### Milestone 3: Excellence (Target: 90% branch coverage)

**Timeline:** 3-4 weeks  
**Estimated Tests:** ~80 new tests  
**Branches to Cover:** +85 branches (299 → 384/426)

**Focus Areas:**

1. ✅ Exotic edge cases (extreme values, unusual combinations) - 25 tests
2. ✅ Reentrancy attack vectors (all contracts) - 15 tests
3. ✅ Cross-contract interaction branches - 20 tests
4. ✅ Failure mode combinations - 20 tests
5. ✅ LevrFactory remaining branches - +11 branches (60 → 71/71)
6. ✅ LevrStaking remaining branches - +11 branches (63 → 74/74)
7. ✅ LevrGovernor remaining branches - +5 branches (42 → 47/47)

**Success Criteria:**

- ✅ LevrFactory: **100% branch coverage (71/71)**
- ✅ LevrStaking: **100% branch coverage (74/74)**
- ✅ LevrGovernor: **100% branch coverage (47/47)**
- ✅ All core contracts: **100% branch coverage**
- ✅ Overall: **90% (384/426 branches)**

---

### Milestone 4: Perfection (Target: 100% branch coverage)

**Timeline:** 2-3 weeks  
**Estimated Tests:** ~50 new tests  
**Branches to Cover:** +42 branches (384 → 426/426) - **EVERY REMAINING BRANCH**

**Focus Areas:**

1. ✅ Scripts (if testable in isolation) - Coverage for deployment logic
2. ✅ Mock contracts (if branches exist) - Complete mock coverage
3. ✅ Test utilities (if they contain logic) - Helper function coverage
4. ✅ Base contracts (ERC2771ContextBase, etc.) - 100% coverage
5. ✅ **Absolutely every remaining uncovered branch** - Systematic completion

**Strategy:**

```bash
# After Milestone 3, generate detailed coverage report
FOUNDRY_PROFILE=dev forge coverage --match-path "test/unit/*.t.sol" --ir-minimum --report lcov

# Use lcov to identify EXACT uncovered branches
genhtml -o coverage-html coverage.lcov
# Open coverage-html/index.html and inspect every red/yellow line

# Create targeted tests for each remaining branch
# No branch left untested!
```

**Success Criteria:**

- ✅ **ALL contracts: 100% branch coverage**
- ✅ **RewardMath: 100% (8/8)** ✅
- ✅ **LevrFactory_v1: 100% (71/71)** ✅
- ✅ **LevrStaking_v1: 100% (74/74)** ✅
- ✅ **LevrGovernor_v1: 100% (47/47)** ✅
- ✅ **LevrTreasury_v1: 100% (10/10)** ✅
- ✅ **LevrFeeSplitter_v1: 100% (30/30)** ✅
- ✅ **LevrForwarder_v1: 100% (10/10)** ✅
- ✅ **LevrStakedToken_v1: 100% (8/8)** ✅
- ✅ **LevrDeployer_v1: 100% (2/2)** ✅
- ✅ **LevrFeeSplitterFactory_v1: 100% (5/5)** ✅
- ✅ **ERC2771ContextBase: 100% (0/0 or complete)** ✅
- ✅ **Overall: 100% (426/426 branches)** 🎯 **TARGET ACHIEVED**

---

### Total Estimated Effort for 100% Coverage

**Timeline:** 10-14 weeks (2.5-3.5 months)  
**Total New Tests:** ~300 tests (556 existing + 300 new = 856 total tests)  
**Total Branches to Cover:** +302 branches (124 existing → 426 total)

**Weekly Targets:**

- Week 1-2: +68 branches (45% total)
- Week 3-6: +107 branches (70% total)
- Week 7-10: +85 branches (90% total)
- Week 11-14: +42 branches (**100% total**) 🎯

---

## Quick Reference: Tests to Write

### Immediate Priority (Week 1)

**File:** `test/unit/RewardMath.CompleteBranchCoverage.t.sol`

- [ ] `test_calculateVestedAmount_zeroDuration_returnsZero()`
- [ ] `test_calculateVestedAmount_elapsedAtOrExceedsDuration_returnsTotal()`
- [ ] `test_calculateVestedAmount_partialElapsed_returnsProportional()`
- [ ] `test_calculateUnvested_currentBeforeStreamStart_returnsStreamTotal()`
- [ ] `test_calculateUnvested_currentAtStreamStart_returnsStreamTotal()`
- [ ] `test_calculateUnvested_currentAfterStreamEnd_returnsZero()`
- [ ] `test_calculateUnvested_currentAtStreamEnd_returnsZero()`
- [ ] `test_calculateUnvested_currentMidstream_returnsUnvested()`
- [ ] `test_calculateProportionalClaim_zeroTotalStaked_returnsZero()`
- [ ] `test_calculateProportionalClaim_zeroAccPerShare_returnsZero()`
- [ ] `test_calculateProportionalClaim_validInputs_calculatesCorrectly()`
- [ ] `test_calculateCurrentPool_allBranchCombinations()`

**Expected Impact:** +1.64% overall branch coverage

---

**File:** `test/unit/LevrStakedToken.CompleteBranchCoverage.t.sol`

- [ ] `test_approve_allowsApprovalButTransferStillBlocked()`
- [ ] `test_increaseAllowance_allowsIncreaseButTransferStillBlocked()`
- [ ] `test_decreaseAllowance_allowsDecreaseButTransferStillBlocked()`
- [ ] `test_mint_nonStakingCaller_reverts()`
- [ ] `test_burn_nonStakingCaller_reverts()`
- [ ] `test_transfer_multipleScenarios_allBlocked()`

**Expected Impact:** +0.94% overall branch coverage

---

**File:** `test/unit/LevrDeployer.CompleteBranchCoverage.t.sol`

- [ ] `test_constructor_zeroTreasuryImpl_reverts()`
- [ ] `test_constructor_zeroStakingImpl_reverts()`
- [ ] `test_deploy_validInputs_succeeds()`

**Expected Impact:** +0.23% overall branch coverage

---

### High Priority (Week 2-3)

**File:** `test/unit/LevrTreasury.CompleteBranchCoverage.t.sol` (12 tests)
**File:** `test/unit/LevrFactory.CompleteBranchCoverage.t.sol` (35-40 tests)
**File:** `test/unit/LevrStaking.CompleteBranchCoverage.t.sol` (25-30 tests)

---

### Medium Priority (Week 4-6)

**File:** `test/unit/LevrGovernor.CompleteBranchCoverage.t.sol` (20-25 tests)
**File:** `test/unit/LevrFeeSplitter.CompleteBranchCoverage.t.sol` (8-10 tests)
**File:** `test/unit/LevrForwarder.CompleteBranchCoverage.t.sol` (5-8 tests)

---

## Conclusion

**Current State:**

- ✅ 556 tests passing
- ✅ 53.52% line coverage
- ❌ 29.11% branch coverage (needs **100%** - requires 302 more branches)

**Path Forward to 100% Coverage:**

1. **Milestone 1** (2 weeks): +68 branches → **45% total** (192/426)
2. **Milestone 2** (4 weeks): +107 branches → **70% total** (299/426)
3. **Milestone 3** (4 weeks): +85 branches → **90% total** (384/426)
4. **Milestone 4** (3 weeks): +42 branches → **100% total** (426/426) 🎯

**Total Estimated Effort:** 10-14 weeks (2.5-3.5 months), ~300 new tests, ~856 total tests

**Key Insight:** The low branch coverage (29.11%) indicates we're testing happy paths but missing:

- ❌ Error conditions (revert cases)
- ❌ Edge cases (zero values, max values, boundary conditions)
- ❌ Validation failures (invalid inputs, unauthorized access)
- ❌ Attack scenarios (reentrancy, manipulation attempts)
- ❌ Extreme values (overflow, underflow, precision loss)
- ❌ Failure mode combinations (cascading failures)

**Why 100% Branch Coverage Matters for Levr:**

1. **Security** 🔐
   - Every possible code path is tested and verified
   - No hidden attack vectors in untested branches
   - Comprehensive validation of all error conditions
   - Confidence that protocol handles all scenarios correctly

2. **Audit Readiness** 📋
   - Auditors can verify test coverage matches all code paths
   - Reduces "untested code path" findings
   - Demonstrates thorough security considerations
   - Shows commitment to code quality

3. **Production Confidence** 🚀
   - Know exactly how protocol behaves in ALL scenarios
   - No surprises with edge cases in production
   - Validated handling of extreme conditions
   - Complete understanding of system behavior

4. **Upgrade Safety** 🔄
   - Future changes validated against complete test suite
   - Breaking changes immediately caught
   - Regression testing with full coverage
   - Safe refactoring with confidence

5. **DeFi Standards** 💎
   - Leading DeFi protocols target 95-100% coverage
   - User funds demand highest testing standards
   - Competitive advantage in security
   - Professional engineering practices

**By achieving 100% branch coverage, Levr will:**

- ✅ **Have every code path tested** (426/426 branches)
- ✅ **Maximize security confidence** (no untested attack vectors)
- ✅ **Be audit-ready** (comprehensive test coverage)
- ✅ **Enable safe upgrades** (complete regression testing)
- ✅ **Set industry standard** (production-grade DeFi protocol)

---

## Next Steps (Priority Order)

### Immediate (This Week)

1. ✅ **Review this coverage analysis** - Understand gaps and plan
2. ✅ **Set up automated coverage tracking** - CI/CD integration
3. ✅ **Start Milestone 1** - RewardMath library (highest priority)

### Week 1-2 (Milestone 1: Foundation)

1. Create `test/unit/RewardMath.CompleteBranchCoverage.t.sol` (12 tests)
2. Create `test/unit/LevrStakedToken.CompleteBranchCoverage.t.sol` (6 tests)
3. Create `test/unit/LevrDeployer.CompleteBranchCoverage.t.sol` (3 tests)
4. Create `test/unit/LevrTreasury.CompleteBranchCoverage.t.sol` (12 tests)
5. Create `test/unit/LevrForwarder.CompleteBranchCoverage.t.sol` (8 tests)
6. Create `test/unit/LevrFeeSplitter.CompleteBranchCoverage.t.sol` (12 tests)
7. Run coverage: Verify **45% branch coverage (192/426)**

### Week 3-6 (Milestone 2: Core Contracts)

1. Create `test/unit/LevrFactory.CompleteBranchCoverage.t.sol` (40 tests)
2. Create `test/unit/LevrStaking.CompleteBranchCoverage.t.sol` (35 tests)
3. Create `test/unit/LevrGovernor.CompleteBranchCoverage.t.sol` (25 tests)
4. Run coverage: Verify **70% branch coverage (299/426)**

### Week 7-10 (Milestone 3: Excellence)

1. Create `test/unit/LevrProtocol.ExoticEdgeCases.t.sol` (25 tests)
2. Create `test/unit/LevrProtocol.ReentrancyVectors.t.sol` (15 tests)
3. Create `test/unit/LevrProtocol.CrossContractBranches.t.sol` (20 tests)
4. Create `test/unit/LevrProtocol.FailureModeCombinations.t.sol` (20 tests)
5. Run coverage: Verify **90% branch coverage (384/426)**

### Week 11-14 (Milestone 4: Perfection)

1. Generate detailed LCOV coverage report
2. Identify ALL remaining uncovered branches (42 branches)
3. Create targeted tests for each remaining branch
4. Run final coverage: Verify **100% branch coverage (426/426)** 🎯

---

## Coverage Tracking Commands

### Generate Coverage Report

```bash
# Basic coverage (summary)
FOUNDRY_PROFILE=dev forge coverage --match-path "test/unit/*.t.sol" --ir-minimum

# Detailed coverage (lcov format for HTML report)
FOUNDRY_PROFILE=dev forge coverage --match-path "test/unit/*.t.sol" --ir-minimum --report lcov

# Generate HTML coverage report (viewable in browser)
genhtml -o coverage-html coverage.lcov
open coverage-html/index.html # macOS
# xdg-open coverage-html/index.html  # Linux
```

### Track Progress

```bash
# Run this weekly to track progress
./scripts/coverage-check.sh

# Expected output:
# Week 1-2:  45% branch coverage (192/426)
# Week 3-6:  70% branch coverage (299/426)
# Week 7-10: 90% branch coverage (384/426)
# Week 11-14: 100% branch coverage (426/426) 🎯
```

### CI/CD Integration

Set up GitHub Actions to:

- ✅ Run coverage on every PR
- ✅ Block merges if coverage decreases
- ✅ Require 100% branch coverage on main branch
- ✅ Generate coverage reports automatically
- ✅ Track coverage history over time

---

## Final Thoughts

**100% branch coverage is achievable and essential for Levr.** The systematic approach outlined in this document will:

1. **Eliminate all untested code paths** (302 branches to cover)
2. **Provide complete security confidence** (every scenario tested)
3. **Enable safe production deployment** (no hidden edge cases)
4. **Set industry-leading standards** (professional engineering)

**The journey from 29.11% to 100% branch coverage represents:**

- 🎯 **302 additional branches tested**
- 🧪 **~300 new test cases written**
- 🔒 **Complete security coverage**
- ✅ **Production-ready protocol**

Let's build the most thoroughly tested DeFi protocol. 🚀

---

**Document Version:** 1.0  
**Last Updated:** November 2, 2025  
**Next Review:** After each milestone completion  
**Target Achievement:** 100% branch coverage (426/426 branches)
