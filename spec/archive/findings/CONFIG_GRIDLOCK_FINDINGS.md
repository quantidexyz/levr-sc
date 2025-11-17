# Factory Config Gridlock Analysis

**Date:** October 27, 2025  
**Purpose:** Test if factory config changes can break processes, cleanups, or cause gridlocks  
**Test Coverage:** 15 new tests (all passing)  
**Status:** ✅ COMPLETE

---

## Executive Summary

Comprehensive testing of factory config changes revealed **3 potential gridlock scenarios** and **validated 12 safe behaviors**.

### Key Findings

✅ **GOOD NEWS:**

- Active streams unaffected by config changes
- Cleanup operations independent of config
- Existing proposals protected by snapshots
- Recovery mechanisms work despite config changes
- Most extreme values handled gracefully

⚠️ **FINDINGS:**

- **CRITICAL:** Invalid BPS values (>10000) can create permanent gridlocks
- **MEDIUM:** maxActiveProposals = 0 blocks ALL proposals
- **LOW:** maxRewardTokens = 0 blocks non-whitelisted tokens (whitelisted still work)

---

## Test Results Summary

**Total Tests:** 15/15 passing (100%)

| Category                     | Tests | Result      |
| ---------------------------- | ----- | ----------- |
| Config during cleanup        | 1     | ✅ SAFE     |
| Config during active streams | 2     | ✅ SAFE     |
| Extreme config values        | 5     | ⚠️ 3 ISSUES |
| Config during voting         | 2     | ✅ SAFE     |
| Recovery with config changes | 2     | ✅ SAFE     |
| Whitelist interaction        | 2     | ✅ SAFE     |
| Stream window changes        | 1     | ✅ SAFE     |

---

## Critical Findings

### FINDING 1: Invalid BPS Values Cause Permanent Gridlocks

**Severity:** CRITICAL  
**Test:** `test_config_invalidBps_causesImpossibleProposals()`

**Problem:**

Factory allows setting `quorumBps` or `approvalBps` to values > 10000 (>100%). When these invalid values are snapshotted in proposals, the proposals become mathematically impossible to execute.

**Example:**

```solidity
// Factory owner sets quorumBps = 15000 (150%)
factory.updateConfig(config);

// Proposal created, snapshots quorumBps = 15000
governor.proposeBoost(token, amount);

// Result: Proposal requires 150% participation (impossible!)
// Even with 100% voting, proposal fails quorum
// Cannot execute, cannot start new cycle (proposal still "executable")
```

**Impact:**

- Proposals become mathematically impossible to execute
- Cannot recover without treasury refill or time-based invalidation
- Factory owner error can lock governance

**Current Protection:** NONE - Factory accepts any uint16 value

**Recommendation:**

```solidity
// In LevrFactory_v1._applyConfig()
function _applyConfig(FactoryConfig memory cfg) internal {
    require(cfg.quorumBps <= 10000, 'INVALID_QUORUM_BPS');
    require(cfg.approvalBps <= 10000, 'INVALID_APPROVAL_BPS');
    require(cfg.minSTokenBpsToSubmit <= 10000, 'INVALID_MIN_STAKE_BPS');
    require(cfg.maxProposalAmountBps <= 10000, 'INVALID_MAX_PROPOSAL_BPS');
    // ... existing validation
}
```

**Priority:** HIGH - Easy fix, prevents serious gridlock

---

### FINDING 2: maxActiveProposals = 0 Blocks ALL Proposals

**Severity:** MEDIUM  
**Test:** `test_config_maxActiveProposalsZero_blocksProposals()`

**Problem:**

Setting `maxActiveProposals = 0` blocks all proposal creation (both types).

**Impact:**

- Complete governance freeze
- No proposals can be created
- Recovery: Factory owner must fix config

**Current Protection:** NONE

**Recommendation:**

```solidity
// In LevrFactory_v1._applyConfig()
require(cfg.maxActiveProposals > 0, 'MAX_ACTIVE_PROPOSALS_ZERO');
```

**Priority:** MEDIUM - Prevents accidental governance freeze

---

### FINDING 3: maxRewardTokens = 0 Blocks Non-Whitelisted Tokens

**Severity:** LOW  
**Test:** `test_config_maxRewardTokensZero_breaksStaking()`

**Problem:**

Setting `maxRewardTokens = 0` blocks all non-whitelisted reward tokens. However, whitelisted tokens (including underlying) still work.

**Impact:**

- Cannot add new reward tokens
- Whitelisted tokens unaffected
- Not a complete gridlock

**Current Protection:** Whitelist system bypasses limit

**Recommendation:**

```solidity
// In LevrFactory_v1._applyConfig()
require(cfg.maxRewardTokens > 0, 'MAX_REWARD_TOKENS_ZERO');
```

**Priority:** LOW - Has workaround (whitelist), but should validate

---

## Safe Behaviors Validated

### ✅ SAFE: Cleanup Operations Independent of Config

**Test:** `test_config_maxRewardTokens_doesNotBreakCleanup()`

**Finding:**  
Cleanup operations use actual stream end times and reserve states, NOT config values. Config changes don't break cleanup.

**Code:** `cleanupFinishedRewardToken()` checks:

- `streamEnd > 0 && block.timestamp >= streamEnd` (actual time)
- `_rewardReserve[token] == 0` (actual state)
- NOT dependent on `maxRewardTokens` config

**Result:** ✅ Cleanup always works if conditions met

---

### ✅ SAFE: Active Streams Unaffected by Config

**Test:** `test_config_streamWindow_doesNotBreakActiveStreams()`

**Finding:**  
Active reward streams store their own end times. Changing `streamWindowSeconds` doesn't affect active streams, only new accruals.

**Code:**

- Stream end time stored in `_streamEndByToken[token]` at accrual time
- Not re-read from config
- New accruals use new config

**Result:** ✅ Active streams complete normally despite config changes

---

### ✅ SAFE: Existing Proposals Protected by Snapshots

**Test:** `test_config_changeDuringVoting_doesNotBreakExecution()`

**Finding:**  
Proposals snapshot config values at creation. Config changes during voting/execution don't affect existing proposals.

**Code:**

- `quorumBpsSnapshot`, `approvalBpsSnapshot` captured at creation
- Used in `_meetsQuorum()` and `_meetsApproval()`
- Config changes only affect NEW proposals

**Result:** ✅ Existing proposals immune to config manipulation

---

### ✅ SAFE: Cycle Recovery Works Despite Config Changes

**Test:** `test_config_cycleRecovery_afterVotingEnds()`

**Finding:**  
`startNewCycle()` works regardless of config changes, as long as no executable proposals remain.

**Result:** ✅ Recovery mechanisms robust against config changes

---

### ✅ SAFE: minSTokenBpsToSubmit Doesn't Affect Existing Proposals

**Test:** `test_config_minStakeIncrease_doesNotAffectExistingProposals()`

**Finding:**  
Min stake checked at proposal CREATION only. Existing proposals votable/executable even if proposer no longer meets new minimum.

**Result:** ✅ Existing proposals grandfathered, new proposals use new rules

---

### ✅ SAFE: Whitelist System Bypasses maxRewardTokens

**Test:** `test_config_maxTokensChange_doesNotAffectWhitelist()`

**Finding:**  
Whitelisted tokens don't count toward `maxRewardTokens` limit, regardless of limit value.

**Result:** ✅ Critical tokens (WETH, underlying) always work

---

### ✅ SAFE: New Accruals Use New Config

**Test:** `test_config_streamWindowChange_affectsNewAccrualsOnly()`

**Finding:**  
Stream window changes apply to NEW accruals only. Active streams complete with their original window.

**Result:** ✅ Clean separation of old vs new behavior

---

### ✅ SAFE: maxProposalAmountBps = 0 Removes Limit

**Test:** `test_config_maxProposalAmountZero_allowsAnyAmount()`

**Finding:**  
Setting `maxProposalAmountBps = 0` allows proposals for any amount (no limit). This is by design.

**Code:** `if (maxProposalBps > 0)` check means 0 bypasses validation

**Result:** ✅ Zero means "no limit" (intentional)

---

### ✅ SAFE: Zero Proposal Window Works (Immediate Voting)

**Test:** `test_config_zeroWindows_preventsProposals()`

**Finding:**  
Setting `proposalWindowSeconds = 0` creates cycles where voting starts immediately. Not a gridlock, just unusual.

**Result:** ✅ Works, but creates instant voting (likely unintended)

---

### ✅ PROTECTED: Minimum Stream Window Enforced

**Test:** `test_config_minimumStreamWindow_validation()`

**Finding:**  
Factory enforces `streamWindowSeconds >= 1 days` (86400 seconds). Cannot set shorter windows.

**Code:** `require(cfg.streamWindowSeconds >= 1 days, 'STREAM_WINDOW_TOO_SHORT');`

**Result:** ✅ Prevents gaming with very short windows

---

## Recommended Validation Additions

### Priority 1: BPS Range Validation (CRITICAL)

**Add to `LevrFactory_v1._applyConfig()`:**

```solidity
function _applyConfig(FactoryConfig memory cfg) internal {
    // CRITICAL: Validate BPS values are <= 100%
    require(cfg.quorumBps <= 10000, 'INVALID_QUORUM_BPS');
    require(cfg.approvalBps <= 10000, 'INVALID_APPROVAL_BPS');
    require(cfg.minSTokenBpsToSubmit <= 10000, 'INVALID_MIN_STAKE_BPS');
    require(cfg.maxProposalAmountBps <= 10000, 'INVALID_MAX_PROPOSAL_BPS');
    require(cfg.protocolFeeBps <= 10000, 'INVALID_PROTOCOL_FEE_BPS');

    // Existing validation
    require(cfg.streamWindowSeconds >= 1 days, 'STREAM_WINDOW_TOO_SHORT');
    // ... rest of function
}
```

**Benefit:** Prevents governance gridlock from invalid BPS  
**Complexity:** Trivial (5 lines)  
**Time:** 10 minutes

---

### Priority 2: Zero Value Validation (MEDIUM)

**Add to `LevrFactory_v1._applyConfig()`:**

```solidity
// Prevent accidental zero values that break functionality
require(cfg.maxActiveProposals > 0, 'MAX_ACTIVE_PROPOSALS_ZERO');
require(cfg.maxRewardTokens > 0, 'MAX_REWARD_TOKENS_ZERO');
require(cfg.proposalWindowSeconds > 0, 'PROPOSAL_WINDOW_ZERO');
require(cfg.votingWindowSeconds > 0, 'VOTING_WINDOW_ZERO');
```

**Benefit:** Prevents accidental governance/staking freeze  
**Complexity:** Trivial (4 lines)  
**Time:** 5 minutes

---

## Summary of Config Interactions

### Config Parameters by Impact

| Parameter               | Affects Active?  | Affects Cleanup? | Can Gridlock? | Validation  |
| ----------------------- | ---------------- | ---------------- | ------------- | ----------- |
| `quorumBps`             | ❌ No (snapshot) | ❌ No            | ✅ YES        | ⚠️ NONE     |
| `approvalBps`           | ❌ No (snapshot) | ❌ No            | ✅ YES        | ⚠️ NONE     |
| `streamWindowSeconds`   | ❌ No            | ❌ No            | ❌ No         | ✅ >= 1 day |
| `maxActiveProposals`    | ❌ No            | ❌ No            | ✅ YES        | ⚠️ NONE     |
| `maxRewardTokens`       | ❌ No            | ❌ No            | ⚠️ PARTIAL    | ⚠️ NONE     |
| `minSTokenBpsToSubmit`  | ❌ No            | ❌ No            | ❌ No         | ⚠️ NONE     |
| `maxProposalAmountBps`  | ❌ No            | ❌ No            | ❌ No         | ⚠️ NONE     |
| `proposalWindowSeconds` | ❌ No (snapshot) | ❌ No            | ⚠️ UNUSUAL    | ⚠️ NONE     |
| `votingWindowSeconds`   | ❌ No (snapshot) | ❌ No            | ❌ No         | ⚠️ NONE     |

### Gridlock Risk Matrix

| Config Value                  | Gridlock Type             | Severity | Recovery                |
| ----------------------------- | ------------------------- | -------- | ----------------------- |
| `quorumBps > 10000`           | Permanent (impossible)    | CRITICAL | Treasury refill or None |
| `approvalBps > 10000`         | Permanent (impossible)    | CRITICAL | Treasury refill or None |
| `maxActiveProposals = 0`      | Complete (no proposals)   | MEDIUM   | Fix config              |
| `maxRewardTokens = 0`         | Partial (non-whitelisted) | LOW      | Whitelist               |
| `proposalWindowSeconds = 0`   | Unusual (instant voting)  | LOW      | Works but odd           |
| `streamWindowSeconds < 1 day` | Prevented by validation   | NONE     | N/A                     |

---

## Detailed Findings

### 1. Invalid Quorum BPS (>10000) Creates Impossible Proposals

**Test:** `test_config_invalidBps_causesImpossibleProposals()`

**Scenario:**

```
Factory sets quorumBps = 15000 (150%)
→ Proposal snapshots this value
→ Quorum check: totalBalanceVoted >= (totalSupply * 15000) / 10000
→ With 1000 supply: Need 1500 votes (impossible!)
→ Even 100% participation (1000 votes) fails
→ Proposal cannot execute
→ Cycle cannot advance (proposal still "executable")
→ Permanent gridlock
```

**Recovery:** None without time-based proposal invalidation

---

### 2. maxActiveProposals = 0 Blocks All Proposals

**Test:** `test_config_maxActiveProposalsZero_blocksProposals()`

**Scenario:**

```
Factory sets maxActiveProposals = 0
→ Any propose() call checks: activeCount < maxActive
→ 0 < 0 = false
→ All proposals blocked
→ Governance completely frozen
```

**Recovery:** Factory owner fixes config

---

### 3. maxRewardTokens = 0 Blocks Non-Whitelisted

**Test:** `test_config_maxRewardTokensZero_breaksStaking()`

**Scenario:**

```
Factory sets maxRewardTokens = 0
→ Non-whitelisted tokens: 0 < 0 = false (blocked)
→ Whitelisted tokens: Skip check (work fine)
→ Underlying always works (whitelisted at index 0)
```

**Recovery:** Whitelist important tokens

---

### 4. Stream Window Minimum Enforced

**Test:** `test_config_minimumStreamWindow_validation()`

**Finding:**  
Factory enforces `streamWindowSeconds >= 1 days` at line 222 of LevrFactory_v1.sol.

**Protection:** ✅ Prevents gaming with very short windows

---

### 5. Uint16.max BPS Also Creates Gridlock

**Test:** `test_config_bpsOverflow_uint16Max()`

**Scenario:**

```
quorumBps = 65535 (uint16.max = 655.35%)
→ Requires (1000 * 65535) / 10000 = 6553.5 tokens
→ Only 1000 tokens exist
→ Mathematically impossible
```

**Same issue as Finding 1, extreme case**

---

### 6. Impossible BPS Snapshot Cannot Be Fixed Post-Creation

**Test:** `test_config_impossibleBps_snapshotProtects()`

**Finding:**  
Once a proposal snapshots invalid BPS, fixing the factory config doesn't help that proposal. The snapshot is immutable.

**Implication:**  
BPS validation MUST happen at `updateConfig()` time, not just at proposal creation.

---

## Safe Behaviors Confirmed

### ✅ Cleanup Independent of Config

**Test:** `test_config_maxRewardTokens_doesNotBreakCleanup()`

Cleanup checks:

- Actual stream end time (not config)
- Actual reserve balance (not config)
- Works regardless of `maxRewardTokens` changes

---

### ✅ Active Streams Independent of Config

**Test:** `test_config_streamWindow_doesNotBreakActiveStreams()`

Stream end time calculated once at accrual, stored permanently. Config changes don't affect active streams.

---

### ✅ Snapshots Protect Existing Proposals

**Tests:**

- `test_config_changeDuringVoting_doesNotBreakExecution()`
- `test_config_minStakeIncrease_doesNotAffectExistingProposals()`

Existing proposals use their snapshots, immune to config changes.

---

### ✅ Whitelist System Robust

**Test:** `test_config_maxTokensChange_doesNotAffectWhitelist()`

Whitelisted tokens work regardless of `maxRewardTokens` value (even 0 or 1).

---

### ✅ New Accruals Use New Config

**Test:** `test_config_streamWindowChange_affectsNewAccrualsOnly()`

Clean separation: old streams use old config, new accruals use new config.

---

### ✅ Zero maxProposalAmountBps Removes Limit

**Test:** `test_config_maxProposalAmountZero_allowsAnyAmount()`

Setting to 0 intentionally disables limit (allows any proposal amount).

---

## Recommendations

### Immediate (Before Deployment)

**1. Add BPS Validation (CRITICAL)**

```solidity
require(cfg.quorumBps <= 10000, 'INVALID_QUORUM_BPS');
require(cfg.approvalBps <= 10000, 'INVALID_APPROVAL_BPS');
```

**2. Add Zero Value Protection (MEDIUM)**

```solidity
require(cfg.maxActiveProposals > 0, 'MAX_ACTIVE_PROPOSALS_ZERO');
require(cfg.maxRewardTokens > 0, 'MAX_REWARD_TOKENS_ZERO');
```

**Total Time:** 15 minutes  
**Impact:** Prevents 3 gridlock scenarios

---

### Optional (Future Enhancement)

**3. Add Config Change Events**

```solidity
event ConfigUpdated(
    uint16 oldQuorumBps,
    uint16 newQuorumBps,
    uint16 oldApprovalBps,
    uint16 newApprovalBps
    // ... other fields
);
```

**4. Add Timelock for Config Changes**

- Prevent sudden config changes
- Give community time to react
- Standard in DeFi governance

---

## Test File

**Location:** `test/unit/LevrFactory_ConfigGridlock.t.sol`  
**Tests:** 15 (all passing)  
**Coverage:** All config parameters tested for gridlock scenarios

**Test Categories:**

- Config during cleanup: 1 test
- Config during active operations: 4 tests
- Extreme config values: 5 tests
- Recovery mechanisms: 2 tests
- Interaction tests: 3 tests

---

## Production Impact

### Current Risk

**WITHOUT Validation:**

- Factory owner error can create permanent gridlocks
- Invalid BPS most dangerous (impossible proposals)
- Zero values create complete freezes

**WITH Validation (15-minute fix):**

- ✅ Invalid BPS rejected
- ✅ Zero values rejected
- ✅ Factory owner cannot accidentally gridlock system

### Cost-Benefit

**Cost:** 15 minutes implementation + 30 minutes testing  
**Benefit:** Prevents 3 critical/medium gridlock scenarios  
**ROI:** Infinite (prevents governance death)

---

## Conclusion

**Status:** ⚠️ **VALIDATION NEEDED BEFORE DEPLOYMENT**

**Current State:**

- ✅ Most config interactions safe
- ✅ Snapshots protect existing operations
- ✅ Recovery mechanisms robust
- ⚠️ **3 gridlock scenarios from invalid config values**

**Recommendation:**

Add BPS and zero-value validation to `LevrFactory_v1._applyConfig()` before deployment:

```solidity
function _applyConfig(FactoryConfig memory cfg) internal {
    // BPS validation (CRITICAL)
    require(cfg.quorumBps <= 10000, 'INVALID_QUORUM_BPS');
    require(cfg.approvalBps <= 10000, 'INVALID_APPROVAL_BPS');
    require(cfg.minSTokenBpsToSubmit <= 10000, 'INVALID_MIN_STAKE_BPS');
    require(cfg.maxProposalAmountBps <= 10000, 'INVALID_MAX_PROPOSAL_BPS');
    require(cfg.protocolFeeBps <= 10000, 'INVALID_PROTOCOL_FEE_BPS');

    // Zero value protection (MEDIUM)
    require(cfg.maxActiveProposals > 0, 'MAX_ACTIVE_PROPOSALS_ZERO');
    require(cfg.maxRewardTokens > 0, 'MAX_REWARD_TOKENS_ZERO');
    require(cfg.proposalWindowSeconds > 0, 'PROPOSAL_WINDOW_ZERO');
    require(cfg.votingWindowSeconds > 0, 'VOTING_WINDOW_ZERO');

    // Existing validation
    require(cfg.streamWindowSeconds >= 1 days, 'STREAM_WINDOW_TOO_SHORT');

    // Apply config
    // ... rest of function
}
```

**Validation Implemented:** ✅ COMPLETE

---

**Test Coverage:** 15/15 config gridlock tests passing  
**Total Suite:** 364/364 tests passing (100%)  
**Status:** ✅ **ALL FIXES APPLIED AND VERIFIED**

### Verification Tests

**Config Gridlock Tests (15 tests - all passing):**

1. ✅ `test_config_maxRewardTokens_doesNotBreakCleanup()` - Cleanup independent of config
2. ✅ `test_config_streamWindow_doesNotBreakActiveStreams()` - Active streams safe
3. ✅ `test_config_invalidBps_causesImpossibleProposals()` - Invalid BPS rejected ✅
4. ✅ `test_config_maxRewardTokensZero_breaksStaking()` - Zero maxRewardTokens rejected ✅
5. ✅ `test_config_zeroWindows_preventsProposals()` - Zero windows rejected ✅
6. ✅ `test_config_maxActiveProposalsZero_blocksProposals()` - Zero maxActive rejected ✅
7. ✅ `test_config_changeDuringVoting_doesNotBreakExecution()` - Snapshots protect
8. ✅ `test_config_minStakeIncrease_doesNotAffectExistingProposals()` - Safe
9. ✅ `test_config_cycleRecovery_afterVotingEnds()` - Recovery works
10. ✅ `test_config_minimumStreamWindow_validation()` - >= 1 day enforced
11. ✅ `test_config_maxTokensChange_doesNotAffectWhitelist()` - Whitelist robust
12. ✅ `test_config_maxProposalAmountZero_allowsAnyAmount()` - Zero = no limit
13. ✅ `test_config_streamWindowChange_affectsNewAccrualsOnly()` - Clean separation
14. ✅ `test_config_impossibleBps_snapshotProtects()` - Barely-over BPS rejected ✅
15. ✅ `test_config_bpsOverflow_uint16Max()` - uint16.max BPS rejected ✅

**Edge Case Tests (now updated to verify validation):**

16. ✅ `test_edgeCase_invalidBps_snapshotBehavior()` - Verifies invalid BPS rejected
17. ✅ `test_edgeCase_extremeBpsValues_uint16Max()` - Verifies uint16.max BPS rejected

**All gridlock scenarios now prevented by validation** ✅  
**All tests updated to verify fixes** ✅
