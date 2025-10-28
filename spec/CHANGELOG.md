# CHANGELOG

All notable changes to the Levr V1 protocol are documented here.

---

## [1.1.0] - 2025-01-10 - Balance-Based Design Implementation

### 🎯 CRITICAL Fixes

#### [CRITICAL-1] Staked Token Transferability - RESOLVED ✅

**Status:** Fixed and Thoroughly Tested

**What Changed:**

- Removed duplicate state tracking (`_staked` mapping)
- Staked tokens are now freely transferable
- Single source of truth: `stakedToken.balanceOf()`

**Implementation Details:**

- Modified `LevrStakedToken_v1._update()` to enable transfers via callbacks
- Added transfer semantics to `LevrStaking_v1`:
  - `onTokenTransfer()`: Syncs reward debt after transfer
  - `onTokenTransferReceiver()`: Recalculates receiver's VP using weighted average
  - `calcNewStakeStartTime()`: External VP calculation (reusable for transfers)
- Receiver's VP is preserved through weighted average formula
- Sender's VP scales proportionally with remaining balance

**Tests:** 21/21 passing ✅

- Transfer functionality (transfer, transferFrom)
- Balance synchronization
- Multiple independent users
- Dust amounts
- Multi-hop transfer chains
- VP calculation verification
- Independent unstaking for both parties

**Files Modified:**

- `src/LevrStaking_v1.sol` (added callbacks, external VP functions)
- `src/LevrStakedToken_v1.sol` (added \_update override)
- `src/interfaces/ILevrStaking_v1.sol` (added new interface methods)

---

### 🎯 HIGH Fixes

#### [HIGH-1] Voting Power Precision Loss - RESOLVED ✅

**Status:** Fixed and Thoroughly Tested

**What Changed:**

- Corrected order of operations in `_onUnstakeNewTimestamp()`
- Multiply before divide to preserve precision
- Handles 99.9% unstakes correctly

**Implementation Details:**

- Formula: `newTimeAccumulated = (timeAccumulated * remainingBalance) / originalBalance`
- Previous wrong order caused premature rounding
- New implementation preserves precision across all edge cases

**Tests:** 14/14 passing ✅

- Basic VP calculations
- 25%, 50%, 75%, 99.9% unstakes
- Multiple sequential unstakes
- Precision boundary testing (1 wei remaining)
- Multi-user consistency
- Different time periods
- VP scaling verification

**Files Modified:**

- `src/LevrStaking_v1.sol` (\_onUnstakeNewTimestamp logic corrected)

---

### 📊 Test Coverage

**New Tests:** 35 comprehensive tests for Balance-Based Design

- 21 transfer restriction tests
- 14 voting power precision tests

**Test Results:** 399/399 passing ✅

- No regressions in existing tests
- Clean compilation, no warnings
- Edge cases thoroughly covered

---

### 🔧 Design Improvements

**1. Simplified State Management**

- Eliminated dual source of truth
- Single canonical state: token balance
- Impossible to desynchronize

**2. Enhanced Functionality**

- ✅ Transfers enabled (secondary market support)
- ✅ VP preserved during transfers
- ✅ Reward debt synchronized
- ✅ Compatible with stake/unstake logic

**3. Better Security**

- ✅ Reduced attack surface
- ✅ Try-catch protection for callbacks
- ✅ Reentrancy protection maintained
- ✅ Access control verified

**4. Code Reusability**

- External VP functions usable by external contracts
- Transfer callbacks follow stake/unstake patterns
- Consistent formula application

---

### 📝 Documentation

**Updated Specifications:**

- `spec/EXTERNAL_AUDIT_0_FIXES.md` - Complete fix documentation
- `spec/CHANGELOG.md` - This file

**Test Documentation:**

- `test/unit/EXTERNAL_AUDIT_0.LevrStakedToken_TransferRestriction.t.sol`
- `test/unit/EXTERNAL_AUDIT_0.LevrStaking_VotingPowerPrecision.t.sol`

---

### ✅ Deployment Checklist

- ✅ All critical and high findings resolved
- ✅ Comprehensive test coverage (35 new tests)
- ✅ No regressions (399/399 tests pass)
- ✅ Code quality (no lint errors or warnings)
- ✅ Edge cases tested and verified
- ✅ Documentation updated
- ✅ Ready for production deployment

---

## Previous Versions

[See git history for versions prior to 1.1.0]
