# Unfixed Audit Findings - Test Status

**Date:** October 26, 2025  
**Purpose:** Track test coverage for all unfixed critical bugs from audit.md  
**Status:** All critical bugs have comprehensive failing tests

---

## Critical Unfixed Findings (4 Total)

### ✅ [NEW-C-1] Quorum Manipulation via Supply Increase

**Test File:** `test/unit/LevrGovernor_CriticalLogicBugs.t.sol`  
**Test Function:** `test_CRITICAL_quorumManipulation_viaSupplyIncrease()`  
**Test Status:** ✅ **PASSING** (demonstrates bug exists)

**Bug Confirmed By Test:**

```
BUG CONFIRMED: Proposal no longer meets quorum!
800 votes < 1260 required (44.4% < 70%)
Proposal was executable, now is not!
CRITICAL: Supply manipulation can block proposal execution!
```

**Scenario:**

1. Total supply = 800 sTokens at voting time
2. Quorum requirement = 70% of 800 = 560 sTokens
3. Proposal gets 800 votes (meets quorum) ✅
4. **ATTACK:** Charlie stakes 1000 tokens AFTER voting ends
5. New total supply = 1800 sTokens
6. New quorum requirement = 70% of 1800 = 1260 sTokens
7. Proposal now has 800 < 1260 (FAILS quorum) ❌

**Root Cause:** Total supply checked at EXECUTION time, not at proposal creation/voting snapshot time

**Fix Required:** Snapshot totalSupply at proposal creation (add to Proposal struct)

---

### ✅ [NEW-C-2] Quorum Manipulation via Supply Decrease

**Test File:** `test/unit/LevrGovernor_CriticalLogicBugs.t.sol`  
**Test Function:** `test_quorumManipulation_viaSupplyDecrease()`  
**Test Status:** ✅ **PASSING** (demonstrates bug exists)

**Bug Confirmed By Test:**

```
BUG CONFIRMED: Proposal NOW meets quorum!
500 votes >= 420 required (83% >= 70%)
Charlie can manipulate quorum by unstaking!
```

**Scenario:**

1. Total supply = 1500 sTokens at voting time
2. Quorum requirement = 70% of 1500 = 1050 sTokens
3. Proposal gets 500 votes (FAILS quorum) ❌
4. **ATTACK:** Charlie unstakes 900 tokens AFTER voting ends
5. New total supply = 600 sTokens
6. New quorum requirement = 70% of 600 = 420 sTokens
7. Proposal now has 500 >= 420 (MEETS quorum) ✅

**Root Cause:** Same as NEW-C-1 - total supply checked at execution, not snapshotted

**Fix Required:** Snapshot totalSupply at proposal creation (same fix as NEW-C-1)

---

### ✅ [NEW-C-3] Config Changes Affect Winner Determination

**Test File:** `test/unit/LevrGovernor_CriticalLogicBugs.t.sol`  
**Test Function:** `test_winnerDetermination_configManipulation()`  
**Test Status:** ✅ **PASSING** (demonstrates bug exists)

**Bug Confirmed By Test:**

```
BUG CONFIRMED: Config change affected winner determination!
Proposal 1 was leading, but config change made it invalid
```

**Scenario:**

1. Two proposals created with approval threshold = 51%
2. Proposal 1: 60% yes votes (meets 51% threshold) ✅
3. Proposal 2: 100% yes votes (meets 51% threshold) ✅
4. **ATTACK:** Factory owner changes approval threshold to 70%
5. Proposal 1: 60% < 70% (NO LONGER meets approval) ❌
6. Proposal 2: 100% >= 70% (still meets approval) ✅
7. Winner changes from Proposal 1 to Proposal 2

**Root Cause:** `quorumBps` and `approvalBps` read from factory at EXECUTION time, not snapshotted

**Fix Required:** Snapshot quorumBps and approvalBps at proposal creation (add to Proposal struct)

---

### ✅ [NEW-C-4] Active Proposal Count Never Resets Between Cycles

**Test Files:** `test/unit/LevrGovernor_ActiveCountGridlock.t.sol` (4 tests)  
**Test Status:** ✅ **ALL 4 PASSING** (all demonstrate bug exists)

#### Test 1: `test_activeProposalCount_acrossCycles_isGlobal()`

**Bug Confirmed By Test:**

```
NO - Count still = 2
BUG CONFIRMED: Count is GLOBAL across cycles
BLOCKED: Cannot create new proposal in cycle 2
BUG CONFIRMED: Defeated proposals from cycle 1 block cycle 2
```

**Scenario:**

1. Cycle 1: Create 2 boost proposals (maxActiveProposals = 2)
2. Both proposals fail quorum
3. Start Cycle 2
4. Active count STILL = 2 (never reset)
5. Cannot create new proposals in Cycle 2 (maxActiveProposals reached)

---

#### Test 2: `test_activeProposalCount_allProposalsFail_permanentGridlock()`

**Bug Confirmed By Test:**

```
[CRITICAL BUG CONFIRMED]
activeProposalCount never resets
Defeated proposals permanently consume slots
Eventually hits maxActiveProposals
NO RECOVERY MECHANISM
```

**Scenario:**

1. Cycle 1: Create 2 proposals, nobody votes (both defeated)
2. Start Cycle 2
3. Active count STILL = 2
4. **PERMANENT GRIDLOCK:** Cannot create ANY proposals in Cycle 2 or any future cycles

---

#### Test 3: `test_activeProposalCount_recoveryViaSuccessfulProposal()`

**Bug Confirmed By Test:**

```
BUG: Count still = 1 even though proposal 2 defeated
CONCLUSION: Count is GLOBAL, defeated proposals DO block new ones!
```

**Scenario:**

1. Cycle 1: Create 2 proposals
2. Proposal 1 succeeds and executes (count decrements to 1)
3. Proposal 2 fails quorum but count STAYS at 1
4. Cycle 2: Can only create 1 more proposal (permanently limited)

---

#### Test 4: `test_REALISTIC_organicGridlock_scenario()`

**Bug Confirmed By Test:**

```
[PERMANENT GRIDLOCK CONFIRMED]
Boost proposals are PERMANENTLY BLOCKED
No recovery mechanism exists
This proposal type is DEAD FOREVER
```

**Scenario:**

1. Over multiple cycles, proposals fail organically (normal governance)
2. Eventually activeProposalCount reaches maxActiveProposals
3. Governance for that proposal type PERMANENTLY BLOCKED

---

**Root Cause:** `_activeProposalCount` is a GLOBAL mapping that never resets when `_startNewCycle()` is called

**Fix Required:** Reset count in `_startNewCycle()`:

```solidity
function _startNewCycle() internal {
    // ... existing code ...

    // FIX [NEW-C-4]: Reset counts - proposals are scoped to cycles
    _activeProposalCount[ProposalType.BoostStakingPool] = 0;
    _activeProposalCount[ProposalType.TransferToAddress] = 0;

    // ... rest of function
}
```

---

## Medium Unfixed Finding (1 Total)

### ✅ [NEW-M-1] Voting Power Precision Loss for Small Stakes

**Test File:** `test/unit/LevrGovernor_CriticalLogicBugs.t.sol`  
**Test Function:** `test_votingPower_precisionLoss()`  
**Test Status:** ✅ **PASSING** (demonstrates issue exists)

**Confirmed By Test:**

```
Precision loss: 1 wei stake has 0 VP even after 1 year
```

**Issue:** VP = (balance × timeStaked) / (1e18 × 86400) causes precision loss for stakes < ~0.000003 tokens

**Severity:** MEDIUM (by design trade-off, affects only dust amounts)

**Status:** ℹ️ **BY DESIGN** - Acceptable trade-off for human-readable VP numbers

---

## Additional Test Findings (Non-Bugs)

### ✅ `test_CRITICAL_activeProposalCount_neverDecrementedOnDefeat()`

**Test File:** `test/unit/LevrGovernor_OtherLogicBugs.t.sol`  
**Test Status:** ✅ **PASSING** (confirms NEW-C-4 bug from different angle)

**Confirmed:**

```
BUG CONFIRMED: Count stays at 1 even though proposal defeated!
This means defeated proposals still count as active!
Could lead to hitting maxActiveProposals limit incorrectly
```

This test confirms the same bug as NEW-C-4 by showing that failed execution attempts don't decrement the count.

---

### ✅ `test_CRITICAL_totalBalanceVoted_doubleCount()`

**Test File:** `test/unit/LevrGovernor_OtherLogicBugs.t.sol`  
**Test Status:** ✅ **PASSING** (confirms system is SAFE)

**Result:** NOT A BUG

```
Bob cannot vote: VP = 0 (SAFE)
```

The system correctly prevents double-counting by checking VP (not sToken balance) for voting.

---

### ✅ `test_CRITICAL_proposalMarkedExecutedBeforeRevert()`

**Test File:** `test/unit/LevrGovernor_OtherLogicBugs.t.sol`  
**Test Status:** ✅ **PASSING** (confirms system is SAFE)

**Result:** NOT A BUG

```
SAFE: Revert rolls back ALL state changes including proposal.executed
```

---

## Test Failures (Not Bugs - Test Issues)

### ❌ `test_noWinner_cannotExecute()` - TEST NEEDS FIX

**Test File:** `test/unit/LevrGovernor_OtherLogicBugs.t.sol`  
**Test Status:** ❌ **FAILING** (incorrect expectation)

**Issue:** Test expects `NotWinner` error, but implementation correctly throws `ProposalNotSucceeded` error

**Fix Required:** Update test expectation:

```solidity
// OLD: vm.expectRevert(ILevrGovernor_v1.NotWinner.selector);
// NEW: vm.expectRevert(ILevrGovernor_v1.ProposalNotSucceeded.selector);
```

---

### ❌ `test_tiedProposals_firstWins()` - TEST NEEDS FIX

**Test File:** `test/unit/LevrGovernor_OtherLogicBugs.t.sol`  
**Test Status:** ❌ **FAILING** (incorrect expectation)

**Issue:** Test expects tied proposals to result in first proposal winning, but both proposals fail quorum so winner = 0

**Fix Required:** Update test to account for quorum requirements

---

### ❌ `test_totalBalanceVoted_canExceedSupply()` - TEST NEEDS FIX

**Test File:** `test/unit/LevrGovernor_OtherLogicBugs.t.sol`  
**Test Status:** ❌ **FAILING** (incorrect expectation)

**Issue:** Test expects Bob to be able to vote after receiving sTokens from Alice, but Bob has 0 VP (correct behavior)

**Fix Required:** Update test to verify this is expected safe behavior

---

## Summary

### Critical Bugs (All Confirmed with Tests)

| Bug ID  | Description                                  | Test Status      | Needs Fix |
| ------- | -------------------------------------------- | ---------------- | --------- |
| NEW-C-1 | Quorum manipulation via supply increase      | ✅ PASSING (bug) | YES       |
| NEW-C-2 | Quorum manipulation via supply decrease      | ✅ PASSING (bug) | YES       |
| NEW-C-3 | Config changes affect winner determination   | ✅ PASSING (bug) | YES       |
| NEW-C-4 | Active proposal count never resets (4 tests) | ✅ PASSING (bug) | YES       |

**Total Critical Bugs Confirmed:** 4/4 (100%)

### Medium Issues

| Bug ID  | Description                        | Test Status | Status       |
| ------- | ---------------------------------- | ----------- | ------------ |
| NEW-M-1 | VP precision loss for small stakes | ✅ PASSING  | BY DESIGN OK |

### Test Issues (Not Bugs)

| Test                                     | Status     | Fix Required |
| ---------------------------------------- | ---------- | ------------ |
| `test_noWinner_cannotExecute`            | ❌ FAILING | Update test  |
| `test_tiedProposals_firstWins`           | ❌ FAILING | Update test  |
| `test_totalBalanceVoted_canExceedSupply` | ❌ FAILING | Update test  |

---

## Next Steps

### 1. Fix Source Code (Priority: CRITICAL)

Implement fixes for all 4 critical bugs:

**File:** `src/interfaces/ILevrGovernor_v1.sol`

```solidity
struct Proposal {
    // ... existing 17 fields ...
    uint256 totalSupplySnapshot;    // Snapshot of sToken supply at proposal creation
    uint16 quorumBpsSnapshot;       // Snapshot of quorum threshold at proposal creation
    uint16 approvalBpsSnapshot;     // Snapshot of approval threshold at proposal creation
}
```

**File:** `src/LevrGovernor_v1.sol`

1. In `_propose()`: Capture snapshots
2. In `_meetsQuorum()`: Use `proposal.totalSupplySnapshot` and `proposal.quorumBpsSnapshot`
3. In `_meetsApproval()`: Use `proposal.approvalBpsSnapshot`
4. In `_startNewCycle()`: Reset `_activeProposalCount` mappings

### 2. Update Test Files

Fix the 3 failing tests in `LevrGovernor_OtherLogicBugs.t.sol` to match expected behavior

### 3. Verify Fixes

Run all tests again to ensure:

- ✅ All 4 critical bug tests now FAIL (bugs are fixed)
- ✅ All test issue tests now PASS (tests corrected)
- ✅ All other tests still PASS (no regressions)

### 4. Update Audit.md

Mark all 4 critical findings as ✅ **RESOLVED** with test coverage confirmation

---

**Total Test Coverage:**

- 8 tests confirming critical bugs exist
- 3 tests confirming safe behavior
- 3 tests needing updates
- **100% coverage of all critical unfixed findings**

**Recommendation:** DO NOT DEPLOY until all 4 critical bugs are fixed and verified
