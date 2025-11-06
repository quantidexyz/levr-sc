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

### 1. Stake Dilution Attack (HIGH)

**File:** `SHERLOCK_STAKE_DILUTION.md`  
**Status:** 🔴 CONFIRMED (2/2 tests FAILING)  
**Severity:** HIGH - Complete reward pool drainage  

**Summary:** Flash loan attack drains 90%+ of reward pool via instant dilution without settling existing rewards.

**Test File:** `test/unit/sherlock/LevrStakingDilution.t.sol`  
**Test Status:** 2/2 tests FAILING (proves vulnerability exists)

**Quick Facts:**
- Alice loses 90% of rewards in flash loan attack
- Attack ROI: ~1,111x on flash loan fees  
- Zero capital required, single transaction, repeatable
- Fix: Add 4 lines to `stake()` (minimal gas impact)

**Everything you need is in the main file** - analysis, test results, fix, comparison to other protocols.

---

## Test Execution

To run Sherlock audit tests:

```bash
# All Sherlock tests
FOUNDRY_PROFILE=dev forge test --match-path "test/unit/sherlock/*.t.sol" -vvv

# Specific issue
FOUNDRY_PROFILE=dev forge test --match-test "test_FlashLoanDilutionAttack" -vv
```

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
└── SHERLOCK_[ISSUE_NAME].md            # Self-sufficient issue analysis
                                        # ↳ Contains: analysis, tests, fix, context

test/unit/sherlock/
└── [IssueClass].t.sol                  # POC tests (referenced in issue .md)
```

**Each SHERLOCK_*.md file contains:**
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
- **REJECTED** - Tests prove issue is invalid (tests PASS with current code)
- **FIXED** - Vulnerability patched and verified (tests now PASS)
- **ARCHIVED** - Completed issue moved to `spec/archive/audits/sherlock/`

---

**Last Updated:** November 6, 2025  
**Maintainer:** Development Team

