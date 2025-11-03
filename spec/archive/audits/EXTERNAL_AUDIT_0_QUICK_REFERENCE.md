# EXTERNAL_AUDIT_0: Quick Test Reference

**3 Critical Test Files | 37 Total Tests | All Audit Findings Covered**

---

## 🎯 Quick Test Execution

```bash
# Run ALL external audit tests
forge test -vvv -k "EXTERNAL_AUDIT_0"

# Run by severity
forge test -vvv -k "EXTERNAL_AUDIT_0_LevrStakedToken"        # CRITICAL-1 (12 tests)
forge test -vvv -k "EXTERNAL_AUDIT_0_LevrStakingVotingPower" # HIGH-1 (14 tests)
forge test -vvv -k "EXTERNAL_AUDIT_0_LevrGovernor"           # MEDIUM-1 (11 tests)

# Run specific critical test
forge test -vvv -k "test_stakedToken_attackScenario"
forge test -vvv -k "test_stakingVotingPower_99_9percent"
forge test -vvv -k "test_governor_failedExecution_cycle"
```

---

## 📁 Test Files Location

```
test/unit/
├── EXTERNAL_AUDIT_0.LevrStakedToken_TransferRestriction.t.sol      (12 tests)
├── EXTERNAL_AUDIT_0.LevrStaking_VotingPowerPrecision.t.sol         (14 tests)
└── EXTERNAL_AUDIT_0.LevrGovernor_ExecutionSuccess.t.sol            (11 tests)
```

---

## 🔴 CRITICAL-1: Staked Token Transfer Restriction

**File:** `test/unit/EXTERNAL_AUDIT_0.LevrStakedToken_TransferRestriction.t.sol`

**Issue:** Staked tokens can be transferred, desynchronizing internal accounting

**Key Tests:**

- `test_stakedToken_attackScenario_desyncAccountingAndTokenBalance` ⭐
- `test_stakedToken_transferBlocked`
- `test_stakedToken_approvalDoesntBypassRestriction`

**Expected After Fix:**

- All transfers blocked ✅
- Mint/burn operations work ✅
- Approvals cannot bypass restrictions ✅

```bash
forge test -vvv --match-contract "EXTERNAL_AUDIT_0_LevrStakedTokenTransferRestrictionTest"
```

---

## 🟠 HIGH-1: Voting Power Precision Loss

**File:** `test/unit/EXTERNAL_AUDIT_0.LevrStaking_VotingPowerPrecision.t.sol`

**Issue:** 99%+ unstakes can round voting power to zero

**Key Tests:**

- `test_stakingVotingPower_99_9percentUnstake_precisionLoss` ⭐
- `test_stakingVotingPower_1weiRemaining_precisionBoundary`
- `test_stakingVotingPower_multiplePartialUnstakes`

**Expected After Fix:**

- 99.9% unstake preserves VP > 0 ✅
- 1 wei remaining has non-zero VP ✅
- Mathematical precision maintained ✅

```bash
forge test -vvv --match-contract "EXTERNAL_AUDIT_0_LevrStakingVotingPowerPrecisionTest"
```

---

## 🟡 MEDIUM-1: Proposal Execution Success Tracking

**File:** `test/unit/EXTERNAL_AUDIT_0.LevrGovernor_ExecutionSuccess.t.sol`

**Issue:** Proposals marked executed even if transfer fails

**Key Tests:**

- `test_governor_failedExecution_cycleStillAdvances` ⭐
- `test_governor_successfulExecution_tokensActuallyTransferred`
- `test_governor_mixedResults_failThenSuccess`

**Expected After Fix:**

- Cycle advances on failure ✅
- Successful transfers happen ✅
- Failed transfers don't happen ✅

```bash
forge test -vvv --match-contract "EXTERNAL_AUDIT_0_LevrGovernorExecutionSuccessTest"
```

---

## 📊 Test Coverage Matrix

```
Test File                          | Tests | Critical | Pass | Fail |
-----------------------------------|-------|----------|------|------|
LevrStakedToken_TransferRestriction | 12    | Yes      |  🟡  | 🟡   |
LevrStaking_VotingPowerPrecision    | 14    | Yes      |  🟡  | 🟡   |
LevrGovernor_ExecutionSuccess       | 11    | No       |  ✅  | ?    |
TOTAL                              | 37    |          |      |      |

Legend:
🟡 = Expected to fail until fix implemented
✅ = Should pass
? = May fail based on treasury state
```

---

## ✅ Pre-Deployment Checklist

```
Before Implementing Fixes:
□ Run: forge test -vvv -k "EXTERNAL_AUDIT_0"
□ Some tests will fail (expected)
□ Review failures vs audit report

After Implementing Fixes:
□ Implement CRITICAL-1 transfer blocking
□ Implement HIGH-1 precision fix
□ Implement MEDIUM-1 success tracking
□ Run: forge test -vvv -k "EXTERNAL_AUDIT_0"
□ All 37 tests should pass ✅
□ No regression in existing tests
```

---

## 🔍 Important Test Details

### CRITICAL-1 Key Points

- Tests desync attack scenario from audit (lines 47-101 of audit report)
- Verifies fix prevents permanent fund loss
- Tests blocking at transfer & transferFrom levels

### HIGH-1 Key Points

- Tests mathematical boundary: (time × 1 wei) / 1000 ether
- Includes console.log() for precision inspection
- Demonstrates fix preserves VP with minimum time floor

### MEDIUM-1 Key Points

- Tests DOS protection: governance continues despite malicious tokens
- Verifies cycle advancement on execution failure
- Tests both success and failure paths

---

## 📖 Related Documentation

**Primary:** `spec/EXTERNAL_AUDIT_0.md` (2698 lines)

- Full audit findings with severity ratings
- Detailed PoC code for each issue
- Recommended fixes with implementation details

**Tests Guide:** `spec/EXTERNAL_AUDIT_0_TESTS.md`

- Complete test documentation
- Test setup and strategy
- Mathematical validation approach

**General:** `spec/TESTING.md`

- Testing rules and patterns
- Test utilities documentation

---

## 🚀 Quick Start

```solidity
// Example: How tests verify CRITICAL-1 fix

function test_stakedToken_transferBlocked() public {
    vm.startPrank(alice);
    underlying.approve(address(staking), 1000 ether);
    staking.stake(1000 ether);

    // This should revert with "STAKED_TOKENS_NON_TRANSFERABLE"
    vm.expectRevert();
    stakedToken.transfer(bob, 1000 ether);
}
```

---

## 📞 Troubleshooting

**Tests failing before fixes implemented?** ✅ Expected!

**Tests passing without fixes?** ⚠️ Review test logic

**Gas issues?** Use `--gas-report` flag:

```bash
forge test -vvv -k "EXTERNAL_AUDIT_0" --gas-report
```

**Need specific test output?**

```bash
# Get full trace
forge test -vvv -k "test_specific_name"

# Get coverage
forge coverage --match-contract "EXTERNAL_AUDIT_0"
```

---

## 🎯 Test Impact Assessment

| Aspect          | Impact                       | Priority    |
| --------------- | ---------------------------- | ----------- |
| Security        | Blocks permanent fund loss   | 🔴 CRITICAL |
| User Experience | Prevents unexpected behavior | 🟠 HIGH     |
| Governance      | Ensures stability            | 🟡 MEDIUM   |
| Performance     | Minimal impact (~1% gas)     | 🟢 LOW      |

---

**Last Updated:** October 28, 2025
**Test Count:** 37 (12 + 14 + 11)
**Estimated Run Time:** ~2-3 minutes (full suite)
