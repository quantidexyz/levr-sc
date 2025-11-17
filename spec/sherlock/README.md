# Sherlock Audit Issues

**Purpose:** Track and validate findings from Sherlock audit contests  
**Created:** November 6, 2025

---

## Documentation Approach

**Each `.md` file in this directory is SELF-SUFFICIENT** - containing all information needed to understand, validate, and fix a specific issue:

✅ **Complete Analysis** - Vulnerability details, root cause, attack mechanism  
✅ **Test Results** - POC tests with actual failure output  
✅ **Proposed Fix** - Implementation-ready solution with code diffs  
✅ **Context** - Protocol comparison, profitability analysis

**NO scattered documentation** - everything for one issue is in ONE file.

---

## Active Issues

### 1. Stake Dilution Attack (HIGH) ✅ FIXED

**File:** `SHERLOCK_STAKE_DILUTION.md`  
**Status:** ✅ FIXED (2/2 tests PASSING)  
**Severity:** HIGH - Complete reward pool drainage

**Summary:** Flash loan attack drains 90%+ of reward pool via instant dilution without settling existing rewards.

**Test File:** `test/unit/sherlock/LevrStakingDilution.t.sol`  
**Test Status:** 2/2 tests PASSING (vulnerability FIXED)

**Quick Facts:**

- Was: Alice loses 90% of rewards in flash loan attack
- Fix: Cumulative reward accounting (MasterChef pattern)
- Implementation: ~40 lines (accRewardPerShare + rewardDebt)
- Status: Deployed and verified

**Everything you need is in the main file** - analysis, test results, fix, comparison to other protocols.

---

### 2. Multiple Claims Draining Pool (HIGH) ✅ ALREADY FIXED

**File:** `SHERLOCK_MULTIPLE_CLAIMS.md`  
**Status:** ✅ NO ACTION NEEDED (3/3 tests PASSING)  
**Severity:** HIGH - Reward pool drainage via repeated claims

**Summary:** Users can call `claimRewards()` multiple times to drain pool before other stakers claim their share.

**Test File:** `test/unit/sherlock/LevrStakingMultipleClaims.t.sol`  
**Test Status:** 3/3 tests PASSING (vulnerability does NOT exist)

**Quick Facts:**

- Same root cause as stake dilution (pool-based distribution)
- Same fix prevents BOTH attacks (debt accounting)
- Fix was already in place when this issue was reported
- Tests confirm: second claim returns 0 (debt blocks re-claim)

**Everything you need is in the main file** - analysis, test results, verification that fix prevents attack.

---

## Test Execution

To run Sherlock audit tests:

```bash
# All Sherlock tests
FOUNDRY_PROFILE=dev forge test --match-path "test/unit/sherlock/*.t.sol" -vvv

# Stake dilution tests
FOUNDRY_PROFILE=dev forge test --match-path "test/unit/sherlock/LevrStakingDilution.t.sol" -vv

# Multiple claims tests
FOUNDRY_PROFILE=dev forge test --match-path "test/unit/sherlock/LevrStakingMultipleClaims.t.sol" -vv
```

**Expected Results (as of Nov 6, 2025):**

- Dilution tests: 2/2 PASSING ✅ (vulnerability FIXED)
- Multiple claims tests: 3/3 PASSING ✅ (vulnerability DOES NOT EXIST)

---

## Workflow

1. **Issue Received** → Create `SHERLOCK_[ISSUE_NAME].md` test plan
2. **Create POC** → Write test in `test/unit/sherlock/[IssueClass].t.sol`
3. **Execute Tests** → Run tests with `-vvv` for detailed output
4. **Document Results** → Update test plan with findings
5. **Validate** → Confirm or reject vulnerability
6. **Fix (if confirmed)** → Implement fix and create verification tests
7. **Archive** → Move to `spec/archive/audits/sherlock/` when complete

---

## File Structure

```
spec/sherlock/
├── README.md                           # Index and workflow guide
├── SHERLOCK_STAKE_DILUTION.md          # Flash loan dilution attack (FIXED)
└── SHERLOCK_MULTIPLE_CLAIMS.md         # Multiple claims attack (ALREADY FIXED)

test/unit/sherlock/
├── LevrStakingDilution.t.sol          # Dilution POC tests (2/2 PASSING)
└── LevrStakingMultipleClaims.t.sol    # Multiple claims POC tests (3/3 PASSING)
```

**Each SHERLOCK\_\*.md file contains:**

1. Executive Summary (impact, status, quick facts)
2. Vulnerability Details (root cause, attack mechanism)
3. Test Results (POC output, actual failures)
4. Proposed Fix (code diff, gas analysis, edge cases)
5. Protocol Comparison (how others solve this)
6. Next Steps (implementation plan)

**Everything in ONE place** - no hunting across multiple files.

---

## Status Definitions

- **VALIDATING** - Tests being written, vulnerability analysis in progress
- **CONFIRMED** - Vulnerability validated (tests FAILING as expected)
- **REJECTED** - Tests prove issue is invalid (tests PASS - never was vulnerable)
- **FIXED** - Vulnerability was real, now patched and verified (tests now PASS)
- **NO ACTION NEEDED** - Issue reported, but fix already in place (tests PASS)
- **ARCHIVED** - Completed issue moved to `spec/archive/audits/sherlock/`

---

**Last Updated:** November 6, 2025  
**Maintainer:** Development Team  
**Active Issues:** 2 (both resolved via debt accounting)  
**Test Status:** 5/5 tests PASSING ✅
