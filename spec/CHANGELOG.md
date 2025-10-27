# Changelog - Levr V1

**Purpose:** Track major features, fixes, and architectural changes  
**Format:** Reverse chronological (newest first)

---

## [1.3.0] - October 27, 2025 - Token-Agnostic Governance

### Summary

Governance and treasury upgraded to support multi-token operations. Proposals can now specify any ERC20 token, enabling WETH donations, multi-token treasury management, and diversified reward strategies.

### Changes

**Governance:**

- ✅ Added `token` field to `Proposal` struct
- ✅ Updated `proposeBoost(address token, uint256 amount)`
- ✅ Updated `proposeTransfer(address token, address recipient, uint256 amount, string description)`
- ✅ Added token validation (non-zero address check)
- ✅ Added balance check for `proposal.token` at creation AND execution
- ✅ Updated `ProposalCreated` event with `address indexed token` parameter

**Treasury:**

- ✅ Updated `transfer(address token, address to, uint256 amount)`
- ✅ Updated `applyBoost(address token, uint256 amount)`
- ✅ Added zero address validation for token parameter

**Breaking Changes:**

- ⚠️ Function signatures changed (all tests updated)
- Migration: Add `address(underlying)` as first parameter to existing calls

### Use Cases Enabled

1. **WETH Support** - Accept and distribute WETH via governance
2. **Multi-Token Treasury** - Manage multiple ERC20 tokens
3. **Reward Diversification** - Boost staking with any supported token

### Test Coverage

- ✅ 296/296 tests updated and passing
- ✅ All governance unit tests
- ✅ All governance E2E tests
- ✅ All treasury tests
- ✅ Zero address validation
- ✅ Multi-token scenarios

**Files Modified:** 5 source files, 15 test files

**Documentation:** See [TOKEN_AGNOSTIC_MIGRATION_SUMMARY.md](./archive/TOKEN_AGNOSTIC_MIGRATION_SUMMARY.md) for detailed migration guide

---

## [1.2.0] - October 27, 2025 - Fee Splitter Per-Project Architecture

### Summary

Refactored fee splitter from monolithic to per-project architecture. Each project gets its own dedicated `LevrFeeSplitter_v1` instance, eliminating shared balance issues.

### The Problem

**Monolithic design had:**

- ❌ Shared token balances across all projects
- ❌ Project A's WETH could go to Project B
- ❌ No way to distinguish which tokens belong to which project

### The Solution

**Per-project architecture provides:**

- ✅ Each project gets dedicated splitter instance
- ✅ No shared balances
- ✅ Simpler code (no project mappings)
- ✅ Optional deployment (no factory changes required)
- ✅ Backward compatible

### Architecture Changes

**Before (Monolithic):**

```solidity
contract LevrFeeSplitter_v1 {
    mapping(address clankerToken => SplitConfig[]) private _projectSplits;

    function configureSplits(address clankerToken, SplitConfig[] calldata splits);
    function distribute(address clankerToken, address rewardToken);
}
```

**After (Per-Project):**

```solidity
contract LevrFeeSplitter_v1 {
    address public immutable clankerToken; // Set once in constructor
    SplitConfig[] private _splits;

    function configureSplits(SplitConfig[] calldata splits); // No clankerToken param!
    function distribute(address rewardToken); // No clankerToken param!
}

contract LevrFeeSplitterFactory_v1 {
    mapping(address clankerToken => address feeSplitter) public splitters;

    function deploy(address clankerToken) external returns (address splitter);
    function deployDeterministic(address clankerToken, bytes32 salt) external;
}
```

### Migration

**Old API:**

```solidity
feeSplitter.configureSplits(clankerToken, splits);
feeSplitter.distribute(clankerToken, WETH);
```

**New API:**

```solidity
address splitter = factory.getSplitter(clankerToken);
LevrFeeSplitter_v1(splitter).configureSplits(splits);
LevrFeeSplitter_v1(splitter).distribute(WETH);
```

### Benefits

- ✅ No token mixing between projects
- ✅ Simpler logic (no mappings)
- ✅ Optional deployment
- ✅ CREATE2 support (deterministic addresses)
- ✅ Direct claims safe

### New Components

- `LevrFeeSplitterFactory_v1.sol` - Factory contract
- `ILevrFeeSplitterFactory_v1.sol` - Factory interface

### Files Modified

- `LevrFeeSplitter_v1.sol` - Refactored to per-project
- `ILevrFeeSplitter_v1.sol` - Updated signatures

**Documentation:** See [FEE_SPLITTER_REFACTOR.md](./archive/FEE_SPLITTER_REFACTOR.md) for detailed refactoring info

---

## [1.1.0] - October 26-27, 2025 - Critical Governance Fixes

### Summary

Fixed 4 critical governance bugs discovered via systematic user flow analysis. Implemented comprehensive snapshot mechanism and cycle reset logic.

### Bugs Fixed

**[NEW-C-1] Quorum Manipulation via Supply Increase**

- Issue: Supply read at execution, not snapshotted
- Fix: Added `totalSupplySnapshot` to proposals
- Impact: Prevented governance DOS attacks

**[NEW-C-2] Quorum Manipulation via Supply Decrease**

- Issue: Same as C-1, reverse direction
- Fix: Same snapshot mechanism
- Impact: Prevented proposal revival attacks

**[NEW-C-3] Config Manipulation Changes Winner**

- Issue: Config read at execution, not snapshotted
- Fix: Added `quorumBpsSnapshot` and `approvalBpsSnapshot`
- Impact: Prevented winner manipulation

**[NEW-C-4] Active Proposal Count Never Resets**

- Issue: Count global across cycles
- Fix: Reset counts in `_startNewCycle()`
- Impact: Prevented permanent gridlock

### Implementation

**Added to Proposal struct:**

- `uint256 totalSupplySnapshot`
- `uint16 quorumBpsSnapshot`
- `uint16 approvalBpsSnapshot`

**Updated functions:**

- `_propose()` - Capture snapshots
- `_meetsQuorum()` - Use snapshots
- `_meetsApproval()` - Use snapshots
- `_startNewCycle()` - Reset counts

### Test Coverage

- ✅ 18 snapshot edge case tests
- ✅ 4 count reset tests
- ✅ 20 additional governance edge cases
- ✅ 66 total governance tests (100% passing)

**Files Modified:** 2 files, ~20 lines changed

---

## [1.0.1] - October 24, 2025 - ProposalState Enum Fix

### Summary

Fixed critical enum ordering bug that caused UI to display incorrect proposal states.

### Bug

- `Succeeded` and `Defeated` were in wrong order
- Proposals meeting quorum/approval showed as "Defeated"
- Execute button hidden in UI

### Fix

Reordered enum values:

```solidity
enum ProposalState {
    Pending,    // 0
    Active,     // 1
    Succeeded,  // 2 ✅ Fixed
    Defeated,   // 3 ✅ Fixed
    Executed    // 4
}
```

### Impact

- ✅ UI now shows correct states
- ✅ Execute button appears for succeeded proposals
- ✅ No false "defeated" status

**Test:** `test_SingleProposalStateConsistency_MeetsQuorumAndApproval()` ✅

---

## [1.0.0] - October 9-23, 2025 - Initial Production Release

### Critical Fixes (C-1, C-2)

**[C-1] PreparedContracts Reuse Attack**

- Added `delete _preparedContracts[caller]` after registration
- Added `nonReentrant` modifier to `register()`

**[C-2] Initialization Protection**

- Changed generic `revert()` to `revert AlreadyInitialized()`
- Added `OnlyFactory()` check

### High Severity Fixes (H-1, H-2, H-3)

**[H-1] Reentrancy on Register**

- Added `nonReentrant` modifier to `register()`

**[H-2] VP Snapshot Complexity**

- Removed entire VP snapshot system
- Simplified to time-weighted VP (natural anti-gaming)

**[H-3] Treasury Approval Not Revoked**

- Added `approve(staking, 0)` after `applyBoost()`

### Medium Severity Fixes (M-1 through M-6)

**[M-2] Streaming Rewards Lost When No Stakers**

- Added early return when `_totalStaked == 0`
- Stream pauses instead of consuming time

**[M-3] Failed Governance Cycle Recovery**

- Added public `startNewCycle()` function
- Enables manual and auto recovery

**[M-6] No Treasury Balance Validation**

- Added balance check before execution
- Mark insufficient proposals as defeated

**[M-1, M-4, M-5] By Design**

- Enhanced documentation for intentional behavior

### Fee Splitter Security (Oct 23, 2025)

**[FS-C-1] Auto-Accrual Revert**

- Wrapped `accrueRewards()` in try/catch
- Distribution continues even if accrual fails

**[FS-H-1] Duplicate Receivers**

- Added nested loop duplicate detection
- Prevents gaming attacks

**[FS-H-2] Unbounded Receiver Array**

- Added `MAX_RECEIVERS = 20` constant
- Prevents gas bomb DOS

**[FS-M-1] Dust Accumulation**

- Implemented `recoverDust()` function
- Admin can recover rounding dust

### Test Coverage

- ✅ 139 tests passing at initial release
- ✅ All critical/high/medium issues tested
- ✅ Industry comparison tests added
- ✅ Edge case coverage comprehensive

---

## Migration Guide Between Versions

### 1.2.0 → 1.3.0 (Token-Agnostic)

**Code Changes:**

```solidity
// OLD
governor.proposeBoost(1000 ether);
governor.proposeTransfer(alice, 500 ether, "Send");
treasury.transfer(alice, 100 ether);
treasury.applyBoost(1000 ether);

// NEW
governor.proposeBoost(address(underlying), 1000 ether);
governor.proposeTransfer(address(underlying), alice, 500 ether, "Send");
treasury.transfer(address(underlying), alice, 100 ether);
treasury.applyBoost(address(underlying), 1000 ether);

// NEW CAPABILITY
governor.proposeBoost(WETH_ADDRESS, 1000 ether); // WETH support!
```

### 1.1.0 → 1.2.0 (Fee Splitter Refactor)

**Code Changes:**

```solidity
// OLD (Monolithic)
feeSplitter.configureSplits(clankerToken, splits);
feeSplitter.distribute(clankerToken, WETH);

// NEW (Per-Project)
address splitter = factory.getSplitter(clankerToken);
LevrFeeSplitter_v1(splitter).configureSplits(splits);
LevrFeeSplitter_v1(splitter).distribute(WETH);
```

---

## Version Summary

| Version | Date            | Key Changes                | Breaking?           |
| ------- | --------------- | -------------------------- | ------------------- |
| 1.3.0   | Oct 27, 2025    | Token-agnostic governance  | ⚠️ Yes (signatures) |
| 1.2.0   | Oct 27, 2025    | Fee splitter per-project   | ⚠️ Yes (deployment) |
| 1.1.0   | Oct 26-27, 2025 | Governance snapshot fixes  | ✅ No               |
| 1.0.1   | Oct 24, 2025    | ProposalState enum fix     | ✅ No               |
| 1.0.0   | Oct 9-23, 2025  | Initial production release | N/A                 |

---

**Maintained by:** Levr Protocol Team  
**Format:** [Keep a Changelog](https://keepachangelog.com/)
