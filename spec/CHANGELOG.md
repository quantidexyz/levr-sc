# CHANGELOG

All notable changes to the Levr V1 protocol are documented here.

---

## [SECURITY] - 2025-11-04 - Critical Factory Validation Bypass Fix

**Status:** ✅ Complete - Security vulnerability fixed and verified

### 🔐 Security Enhancement

#### Summary

Fixed critical security bypass in `LevrFactory_v1.register()` where Clanker factory validation could be completely bypassed if whitelisted factory addresses had no code deployed.

**Severity:** CRITICAL  
**Impact:** Complete bypass of Clanker factory validation allowing unauthorized token registration  
**Status:** ✅ FIXED

#### Changes Made

**Source Code:**
- ✅ **Removed `extcodesize` assembly check** from `LevrFactory_v1.sol:register()`
- ✅ **Removed `hasDeployedFactory` boolean variable** (simplified validation logic)
- ✅ **Simplified validation check** - Now always enforces: `if (!validFactory) revert TokenNotTrusted()`
- ✅ **Code reduction:** -8 lines of vulnerable code

**Test Infrastructure:**
- ✅ **Created `test/mocks/MockClankerFactory.sol`** - Mock Clanker factory for unit tests
  - Supports "permissive mode" for broad test coverage
  - Can register tokens for strict validation testing
  - Auto-used in unit tests, real factory on forks
- ✅ **Updated `test/utils/LevrFactoryDeployHelper.sol`**
  - Auto-detects unit test vs fork mode
  - Deploys mock factory for unit tests
  - Uses real Clanker factory for fork tests

**Before (VULNERABLE):**
```solidity
for (uint256 i; i < _trustedClankerFactories.length; ++i) {
    address factory = _trustedClankerFactories[i];
    
    uint256 size;
    assembly { size := extcodesize(factory) }
    if (size == 0) continue;  // ❌ BYPASS
    
    hasDeployedFactory = true;
    // ... validation ...
}
if (hasDeployedFactory && !validFactory) revert TokenNotTrusted();
// ❌ Never reverts if all factories have no code
```

**After (SECURE):**
```solidity
for (uint256 i; i < _trustedClankerFactories.length; ++i) {
    address factory = _trustedClankerFactories[i];
    
    try IClanker(factory).tokenDeploymentInfo(clankerToken) returns (...) {
        if (info.token == clankerToken) {
            validFactory = true;
            break;
        }
    } catch {}  // ✅ Gracefully handles non-contracts
}
if (!validFactory) revert TokenNotTrusted();  // ✅ Always enforces
```

#### Test Results

- ✅ **768 unit tests passed** - All existing functionality preserved
- ✅ **51 e2e tests passed** - End-to-end flows verified
- ✅ **819 total tests** - Complete test coverage maintained
- ✅ **11 validation tests** in `LevrFactory.ClankerValidation.t.sol` verify security

#### Security Impact

**Attack Vectors Eliminated:**
1. ✅ Pre-deployment bypass (admin adds factory before deployment)
2. ✅ Self-destruct attack (attacker destroys whitelisted factory)
3. ✅ Race condition (factory has no code during upgrade)

**Benefits:**
- ✅ **Simpler, more secure code** - Removed unnecessary complexity
- ✅ **No bypass paths** - Validation always enforces
- ✅ **Easier to audit** - Clearer intent, fewer variables
- ✅ **Better test coverage** - Mock infrastructure enables comprehensive testing

#### Lessons Learned

1. **Don't add special-case handling for already-handled cases** - `try-catch` handles non-contracts
2. **Simpler is safer** - Removing code improved security
3. **Always validate** - `if (!valid)` is bulletproof vs `if (cond && !valid)`
4. **Test infrastructure matters** - Mock contracts enable comprehensive security testing

#### Documentation Updates

- ✅ Updated `spec/AUDIT.md` - Added [C-3] critical finding
- ✅ Updated `spec/HISTORICAL_FIXES.md` - Added comprehensive analysis
- ✅ Updated `spec/CHANGELOG.md` - This entry

#### Related Files

- **Fixed:** `src/LevrFactory_v1.sol` (lines 91-107)
- **Created:** `test/mocks/MockClankerFactory.sol`
- **Updated:** `test/utils/LevrFactoryDeployHelper.sol`
- **Documentation:** `spec/AUDIT.md` ([C-3]), `spec/HISTORICAL_FIXES.md`

---

## [CONSOLIDATION] - 2025-11-03 - Consolidation Records Archived with Proper Naming

**Status:** ✅ Complete - Consolidation records organized in archive/consolidations/

### 🗂️ Consolidation Record Organization

#### Overview

Archived consolidation records moved to `archive/consolidations/` with standardized naming convention for chronological sorting by recency.

**What Changed:**

- **Archived:** 2 consolidation records with new naming convention
  - `CONSOLIDATION_PHASE_3_NOV_03_2025.md` → `archive/consolidations/CONSOLIDATION_2025_11_03_PHASE_3.md`
  - `CONSOLIDATION_NOV_03_2025.md` → `archive/consolidations/CONSOLIDATION_2025_11_03_PHASE_1.md`
- **Naming Convention:** `CONSOLIDATION_YYYY_MM_DD_PHASE_N.md` for automatic chronological sorting
- **Result:** Active spec/ root reduced from 13 to 11 files (consolidation records now in archive)

**Archive consolidations/ Structure:**

```
archive/consolidations/
├── CONSOLIDATION_2025_11_03_PHASE_3.md  ← Newest (audit details archival)
├── CONSOLIDATION_2025_11_03_PHASE_1.md  (coverage/whitelist consolidation)
├── CONSOLIDATION_NOV_03_FOLLOWUP_2025.md
├── CONSOLIDATION_NOV_01_2025.md
├── CONSOLIDATION_OCT30_2025.md
└── [older consolidation records]
```

**Active Spec Files (11 total - essential documentation only):**

| Category | Files |
|----------|-------|
| **Audit & Security** | AUDIT_STATUS.md, AUDIT.md |
| **Protocol Reference** | GOV.md, FEE_SPLITTER.md, USER_FLOWS.md, MULTISIG.md |
| **History & Quality** | HISTORICAL_FIXES.md, TESTING.md |
| **Planning & Navigation** | README.md, CHANGELOG.md, FUTURE_ENHANCEMENTS.md |

**Benefits:**

- ✅ All consolidation history preserved and organized
- ✅ Active spec/ root cleaned to 11 essential files
- ✅ Naming convention enables automatic sorting by recency
- ✅ Clear separation: active documentation vs. historical records
- ✅ Ready for archive/consolidations/ use as specified in spec.mdc

---

## [CONSOLIDATION] - 2025-11-03 - Documentation Organization & Archive Structure

**Status:** ✅ Complete - Spec folder optimized from 24 → 13 active files

### 🗂️ Documentation Consolidation

#### Overview

Comprehensive consolidation of specification documentation following base.mdc guidelines. Reduced spec/ root from 24 active files to 13 essential files while preserving all content in organized archive structure.

**What Changed:**

- **Archived:** 3 consolidation records + 23 detailed audit reports → `archive/audits/` with subdirectories
- **Consolidated:** Analysis files moved to `archive/findings/implementation-analysis/`
- **Reorganized:** Archive structure with subdirectories by type (audits, findings, testing, consolidations)
- **Updated:** Navigation docs (README.md, AUDIT_STATUS.md) to reflect new structure
- **Preserved:** 100% of content - nothing lost, just reorganized

**New Archive Structure:**

```
archive/
├── consolidations/         (8 files - consolidation records)
├── audits/
│   ├── EXTERNAL_AUDIT_2_COMPLETE.md
│   ├── EXTERNAL_AUDIT_3_ACTIONS.md
│   ├── EXTERNAL_AUDIT_4_COMPLETE.md
│   ├── audit-2-details/    (8 detailed technical reports)
│   ├── audit-3-details/    (15 detailed technical reports)
│   └── audit-4-details/    (existing structure)
├── findings/
│   ├── COMPARATIVE_AUDIT.md
│   └── implementation-analysis/
│       ├── CONTRACT_SIZE_FIX.md
│       └── ACCOUNTING_ANALYSIS.md
├── testing/
├── obsolete-designs/
└── README.md               (Archive navigation)
```

**Active Files (13 total - optimized from 24):**

| Category | Files | Examples |
| -------- | ----- | -------- |
| **Audit & Security** | 4 | AUDIT.md, AUDIT_STATUS.md, EXTERNAL_AUDIT_3_ACTIONS.md*, EXTERNAL_AUDIT_4_COMPLETE.md* |
| **Protocol & Governance** | 4 | GOV.md, FEE_SPLITTER.md, USER_FLOWS.md, MULTISIG.md |
| **History & Reference** | 2 | HISTORICAL_FIXES.md, TESTING.md |
| **Planning & Navigation** | 3 | README.md, CHANGELOG.md, FUTURE_ENHANCEMENTS.md |

**Note:** *Items marked with * are now in `archive/audits/` but links preserved for easy access

**Files Modified:**

- `spec/README.md` - Updated with consolidation status
- `spec/AUDIT_STATUS.md` - Updated file path references to archive
- `spec/CONSOLIDATION_NOV_03_FOLLOWUP_2025.md` - Consolidation summary (created)
- `spec/CONSOLIDATION_PHASE_3_NOV_03_2025.md` - Phase 3 details (created)
- Multiple archived files moved to `spec/archive/` with new organization

**Benefits:**

✅ **37.5% reduction in active files** (24 → 13)  
✅ **Single source of truth** for each topic  
✅ **Organized archive** with clear subdirectories  
✅ **No content loss** - all preserved in archive  
✅ **Better navigation** - clearer active vs. reference distinction  
✅ **Sustainable growth** - room for 7-8 more active files before next consolidation

**Navigation Updates:**

- All internal links updated to reflect new paths
- `archive/audits/` contains all detailed audit reports
- `archive/findings/` contains analysis documents
- `archive/consolidations/` contains consolidation records
- README.md points to archive for historical details

---

## [1.5.0] - 2025-11-02 - Whitelist-Only Reward Token System

**Status:** ✅ Complete - All 531 tests passing (480 unit + 51 E2E)

### 🎯 Security Enhancement: Mandatory Reward Token Whitelisting

#### Overview

Replaced the optional `maxRewardTokens` limit with a mandatory whitelist-only system for reward tokens. All reward tokens (except the underlying token, which is auto-whitelisted) must be explicitly whitelisted by the token admin before they can be used for staking rewards or fee distribution.

**What Changed:**

- **Removed** `maxRewardTokens` configuration parameter from `FactoryConfig` and `ProjectConfig`
- **Added** `updateInitialWhitelist(address[] tokens)` and `getInitialWhitelist()` to factory
- **Added** `unwhitelistToken(address token)` to staking contract
- **Enhanced** `whitelistToken` with state corruption prevention checks
- **Protected** underlying token from being unwhitelisted (immutably whitelisted)
- **Modified** `initialize()` to accept `address[] initialWhitelistedTokens` parameter
- **Enforced** whitelist checks in all reward accrual and distribution paths
- **Deployment** Factory initialized with WETH in initial whitelist for all chains
- **CRITICAL:** Protocol fee override protection - projects always use current factory `protocolFeeBps`
- **Consistency:** Stream window validation changed from `>= 1 day` to `> 0` (matches other windows)

**Why This Matters:**

1. **Security:** Prevents unvetted tokens from being added as rewards
2. **Control:** Project admins explicitly approve each reward token
3. **Inheritance:** New projects inherit factory's initial whitelist (e.g., WETH)
4. **Flexibility:** Projects can extend their whitelist beyond the initial set
5. **Protection:** Cannot unwhitelist tokens with pending rewards (prevents fund loss)

**Architecture:**

```solidity
// Factory stores initial whitelist (e.g., [WETH])
address[] private _initialWhitelistedTokens;

// Projects inherit on deployment
function register(address clankerToken) external {
    // ... deploy contracts ...
    staking.initialize(
        underlying,
        stakedToken,
        treasury,
        factory,
        _initialWhitelistedTokens  // Inherited + underlying (auto)
    );
}

// Project admins can extend whitelist
function whitelistToken(address token) external {
    require(token != underlying, 'CANNOT_MODIFY_UNDERLYING');
    require(_msgSender() == tokenAdmin, 'ONLY_TOKEN_ADMIN');
    require(!tokenState.whitelisted, 'ALREADY_WHITELISTED');

    // Prevent state corruption if token was previously used
    if (tokenState.exists) {
        require(
            tokenState.availablePool == 0 && tokenState.streamTotal == 0,
            'CANNOT_WHITELIST_WITH_PENDING_REWARDS'
        );
    }
    // ... whitelist token ...
}

// Unwhitelisting protected
function unwhitelistToken(address token) external {
    require(token != underlying, 'CANNOT_UNWHITELIST_UNDERLYING');
    require(_msgSender() == tokenAdmin, 'ONLY_TOKEN_ADMIN');

    _settlePoolForToken(token);
    require(
        tokenState.availablePool == 0 && tokenState.streamTotal == 0,
        'CANNOT_UNWHITELIST_WITH_PENDING_REWARDS'
    );
    // ... unwhitelist token ...
}
```

**Security Protections:**

1. **Underlying Immutability:** `CANNOT_MODIFY_UNDERLYING` prevents whitelisting/unwhitelisting underlying
2. **State Integrity:** `CANNOT_WHITELIST_WITH_PENDING_REWARDS` prevents re-whitelisting with active rewards
3. **Fund Protection:** `CANNOT_UNWHITELIST_WITH_PENDING_REWARDS` prevents unwhitelisting with claimable rewards
4. **Access Control:** Only token admin can whitelist/unwhitelist tokens
5. **Cleanup Safety:** Must unwhitelist before cleanup to prevent accidental removal
6. **Revenue Security:** Projects cannot override `protocolFeeBps` or `protocolTreasury` (factory-controlled)

**Files Modified:**

- `src/interfaces/ILevrFactory_v1.sol` - Added whitelist management functions, removed `maxRewardTokens`
- `src/LevrFactory_v1.sol` - Whitelist storage and passing to projects
- `src/interfaces/ILevrDeployer_v1.sol` - Added `initialWhitelistedTokens` parameter
- `src/LevrDeployer_v1.sol` - Pass whitelist to staking initialization
- `src/interfaces/ILevrStaking_v1.sol` - Added `unwhitelistToken`, updated `initialize`
- `src/LevrStaking_v1.sol` - Whitelist-only enforcement, state protection
- `src/LevrFeeSplitter_v1.sol` - Added whitelist checks before distribution
- `script/DeployLevr.s.sol` - Initialize factory with WETH whitelist
- `script/DeployLevrFactoryDevnet.s.sol` - Initialize factory with WETH whitelist
- `test/utils/LevrFactoryDeployHelper.sol` - Added `initializeStakingWithRewardTokens` helpers
- `test/mocks/MockStaking.sol` - Updated to match new signatures
- All test files - Updated to whitelist tokens before use

**Test Coverage:**

- ✅ 15 new whitelist system tests (`LevrWhitelist.t.sol`)
  - Factory initial whitelist management
  - Project inheritance of factory whitelist
  - Underlying token protection
  - Reward state corruption prevention
  - Complete whitelist lifecycle
  - Multi-project independent whitelists
- ✅ 15 new verified project tests (`LevrFactory_VerifiedProjects.t.sol`)
  - Protocol fee override protection (CRITICAL)
  - Protocol treasury override protection
  - Factory fee changes sync to all projects
  - Multi-project protocol fee independence
  - Config validation and gridlock prevention
- ✅ All 480 unit tests passing (30 new + 450 updated)
- ✅ All 51 E2E tests updated and passing
- ✅ Test helpers: `initializeStakingWithRewardTokens()`, `whitelistRewardToken()`

**Migration Notes:**

For existing deployments upgrading to this version:

1. Factory owner must call `updateInitialWhitelist([WETH, ...])` with desired default tokens
2. Existing projects with non-whitelisted reward tokens must whitelist them via `whitelistToken()`
3. Tokens with pending rewards cannot be unwhitelisted until rewards are claimed
4. Underlying token is automatically whitelisted and cannot be modified

**Breaking Changes:**

- ❌ `maxRewardTokens(address)` getter removed from factory
- ❌ Cannot accrue rewards for non-whitelisted tokens (will revert with `TOKEN_NOT_WHITELISTED`)
- ❌ Fee splitter will reject distribution of non-whitelisted tokens
- ⚠️ All deployment scripts must initialize factory with `initialWhitelistedTokens` array

---

## [1.4.0] - 2025-10-31 - Verified Projects Feature

**Status:** ✅ Complete - All 487 tests passing (436 unit + 51 E2E)

### 🎯 New Feature: Verified Project Config Overrides

#### Overview

Factory owner can now verify trusted projects, allowing them to customize governance and staking parameters (except protocol fee BPS) independently from the global factory defaults.

**What Changed:**

- Added `verified` boolean to `Project` struct
- Added `ProjectConfig` struct (subset of FactoryConfig without protocolFeeBps)
- Added `verifyProject()` and `unverifyProject()` owner functions
- Added `updateProjectConfig()` for verified project admins
- Enhanced all config getters with optional `address clankerToken` parameter
- Removed immutable `clankerFactory` field from constructor


**Why This Matters:**

Premium/trusted projects can now set their own:

- Governance windows (proposal/voting duration)
- Quorum and approval thresholds
- Proposal limits and staking requirements
- Reward streaming windows
- Max reward token limits

This enables:

- Faster governance for established projects (shorter windows)
- Stricter requirements for high-value treasuries (higher quorum)
- Flexible staking parameters for different token economics
- Protocol still receives standard fee (protocolFeeBps not overridable)

**Security:**

- Only factory owner can verify/unverify projects
- Only token admin can update their project's config
- Same validation rules apply (no gridlock configs)
- Protocol fee BPS cannot be overridden (revenue protection)
- Factory removal doesn't break existing projects (tested)
- Requires ≥1 trusted Clanker factory for registrations

**Architecture:**

```solidity
// Config getter with optional parameter
function quorumBps(address clankerToken) external view returns (uint16);
// Pass address(0) for global default
// Pass project token for project-specific config (if verified)

// Unified internal config update
_updateConfig(cfg, address(0), true);      // Factory config
_updateConfig(cfg, clankerToken, false);   // Project config
```

**Files Modified:**

- `src/interfaces/ILevrFactory_v1.sol` - New structs, events, functions
- `src/LevrFactory_v1.sol` - Core implementation with modular config system
- `src/LevrGovernor_v1.sol` - Pass `underlying` to factory getters
- `src/LevrStaking_v1.sol` - Pass `underlying` to factory getters
- `script/DeployLevr.s.sol` - Add Clanker factory after deployment
- `script/DeployLevrFactoryDevnet.s.sol` - Add Clanker factory after deployment
- `test/unit/LevrFactory_TrustedFactoryRemoval.t.sol` (NEW) - 9 safety tests
- Multiple test files - Updated for new signatures

**Test Coverage:**

- ✅ 9 factory removal safety tests (staking/governance/treasury continue working)
- ✅ 14 Clanker validation tests (updated)
- ✅ All 436 unit tests passing
- ✅ All 51 E2E tests passing
- ✅ **Total: 487/487 tests passing**

**Gas Optimization:**

- No reverse lookup mapping needed
- Simple conditional check + single SLOAD for verified projects
- Contracts access `underlying` from immutable storage (zero gas)
- Optional parameter approach is gas-efficient

**Documentation:**

- `spec/VERIFIED_PROJECTS_FEATURE.md` - Complete design and implementation guide
- `spec/CHANGELOG.md` - This entry
- `spec/GOV.md` - Updated with verified projects section
- `spec/USER_FLOWS.md` - Updated with admin verification flows

---

## [1.3.0] - 2025-10-30 - Audit 3 Phase 1: Security Hardening & Risk Mitigation

**Status:** ✅ Phase 1 Complete - 4 Critical/High Fixes + 10 Pre-existing Test Fixes

### 🔴 CRITICAL Security Fixes

#### [C-1] Unchecked Clanker Token Trust - RESOLVED ✅

**Severity:** CRITICAL  
**Status:** Implemented & Tested  
**Tests Added:** 11 comprehensive test cases

**What Changed:**

- Added `_trustedClankerFactories` array for supporting multiple Clanker versions
- Added factory-side verification via `IClanker.tokenDeploymentInfo()` (ungameable)
- Added `addTrustedClankerFactory()` and `removeTrustedClankerFactory()` owner functions
- Added `getTrustedClankerFactories()` and `isTrustedClankerFactory()` query functions

**Security Issue:**
Factory was accepting ANY token claiming to be from Clanker without verifying the factory itself. Attackers could create fake tokens that lied about their origin.

**Why This Fix Works:**

- Verification happens INSIDE the trusted factory, not via the token's claims
- Factory maintains a list of deployed tokens via `tokenDeploymentInfo()`
- Token can't lie about being deployed because factory has the record
- Supports multiple Clanker versions (v1, v2, etc.)

**Files Modified:**

- `src/LevrFactory_v1.sol` - Added factory validation logic
- `src/interfaces/ILevrFactory_v1.sol` - Added events and function signatures
- `test/unit/LevrFactory.ClankerValidation.t.sol` (NEW) - 11 comprehensive tests
- `test/mocks/MockERC20.sol` - Made admin() virtual for test inheritance

**Test Coverage:**

- ✅ Rejects tokens from untrusted factories
- ✅ Accepts tokens from different trusted factories
- ✅ Owner can add/remove factories
- ✅ Only owner can manage factories
- ✅ Works correctly with 0 factories configured

#### [C-2] Fee-on-Transfer Token Handling - RESOLVED ✅

**Severity:** CRITICAL  
**Status:** Implemented & Tested  
**Tests Added:** 4 comprehensive test cases

**What Changed:**

- Added balance checking before/after `safeTransferFrom()`
- Use `actualReceived` for ALL accounting (not the amount parameter)
- Proper ordering: transfer → calculate VP → mint shares

**Security Issue:**
Tokens with transfer fees (like USDT on some chains) would cause accounting errors. If a user staked 100 tokens and the contract only received 99 (due to 1% fee), the escrow would become insolvent when users tried to unstake.

**Why This Fix Works:**

- Measures actual balance received after transfer
- Ensures voting power calculated correctly
- Prevents escrow shortfall on unstake
- Maintains reward accuracy

**Files Modified:**

- `src/LevrStaking_v1.sol` - Added actual balance measurement
- `test/unit/LevrStaking.FeeOnTransfer.t.sol` (NEW) - 4 tests with mock fee token

**Test Coverage:**

- ✅ Staking with fee-on-transfer token (1% fee)
- ✅ Multiple stakes with correct accounting
- ✅ Unstaking without shortfall
- ✅ Rewards work correctly with fee tokens

### 🟠 HIGH Priority Security Fixes

#### [H-2] Competitive Proposal Winner Manipulation - RESOLVED ✅

**Severity:** HIGH  
**Status:** Implemented & Tested

**What Changed:**

- Changed winner selection from absolute YES votes to approval ratio
- Winner is now proposal with highest `yesVotes / (yesVotes + noVotes)` percentage

**Security Issue:**
In competitive governance where multiple proposals compete, attackers could manipulate the winner by voting NO on good proposals. Even with 99% YES votes, if an attacker votes heavily NO on one proposal while abstaining on another, the absolute vote counts could be manipulated.

**Why This Fix Works:**

- Measures actual approval percentage (quality of proposal)
- Prevents NO vote manipulation
- Fairer selection for competitive proposals
- Requires proposals to meet both quorum AND approval thresholds

**Files Modified:**

- `src/LevrGovernor_v1.sol` - Updated `_getWinner()` function

**Test Coverage:**

- ✅ Existing attack scenario test still passes

#### [H-4] Multisig Deployment & Ownership Transfer - RESOLVED ✅

**Severity:** HIGH  
**Status:** Documented & Scripted

**What Changed:**

- Created comprehensive Gnosis Safe 3-of-5 deployment guide
- Created ownership transfer script for factory
- Documented signer roles and geographic distribution
- Documented emergency procedures

**Why This Matters:**

- Multi-signature ownership prevents single point of failure
- 3-of-5 threshold balances security and operations
- Clear procedures for critical owner functions
- Geo-distributed signers improve liveness

**Files Created:**

- `spec/MULTISIG.md` - Complete deployment & operation guide
- `script/TransferFactoryOwnership.s.sol` - Automated transfer script

### 🎁 BONUS: Pre-existing Test Failures Fixed

#### FeeSplitter Logic Bug (9 tests fixed)

**Root Cause:** After AUDIT 2 removed external calls, `pendingFees()` function was returning current balance instead of pending fees (which should be 0)

**The Bug:**

```
recoverDust() = balance - pendingFees()
             = balance - balance
             = 0 ❌ Nothing recoverable!
```

**The Fix:**

- Removed `pendingFees()` function (users can query balance off-chain)
- Removed `pendingFeesInclBalance()` function
- Updated `recoverDust()` to recover entire balance as dust
- Simplified contract logic

**Files Modified:**

- `src/LevrFeeSplitter_v1.sol` - Removed obsolete functions
- `src/interfaces/ILevrFeeSplitter_v1.sol` - Updated interface
- `test/unit/LevrFeeSplitter_MissingEdgeCases.t.sol` - Fixed assertions
- `test/unit/LevrFeeSplitterV1.t.sol` - Updated balance queries
- `test/e2e/LevrV1.FeeSplitter.t.sol` - Updated balance queries

**Tests Fixed:**

- ✅ `test_splitter_recoverDust_allBalanceIsDust()` - Now passes
- ✅ `test_splitter_distributeWithoutMetadata_succeeds()` - Renamed from reverts
- ✅ 7 other FeeSplitter edge case tests - Now pass

#### VP Calculation Test Bug (1 test fixed)

**Root Cause:** Test assertion was incorrect - expected VP=0 for Charlie who had staked 50 days ago

**The Fix:**

- Corrected assertion to expect VP > 0
- Test now accurately reflects protocol behavior

**Files Modified:**

- `test/unit/LevrStakedToken_NonTransferableEdgeCases.t.sol` - Fixed assertion

### 📊 Metrics

| Metric                  | Target | Actual | Status |
| ----------------------- | ------ | ------ | ------ |
| **New Tests**           | 15     | 15     | ✅     |
| **Tests Fixed**         | 10     | 10     | ✅     |
| **Total Tests Passing** | 417+   | 459    | ✅ +42 |
| **Regressions**         | 0      | 0      | ✅     |
| **Dev Days**            | 2.5    | 2.25   | ✅ -4% |
| **Coverage**            | 97.5%+ | 98%+   | ✅     |

### ⏭️ What's Next (Post-Mainnet)

**Deferred to Phase 2:**

- **H-5:** Deployment fee for DoS protection (design decision - not needed)
- **H-6:** Emergency pause mechanism (architectural conflict - needs redesign)
- **Medium items:** M-3, M-10, M-11 (optimizations)
- **Low items:** L-1 through L-8 (nice-to-have improvements)

**Timeline:**

- ✅ Now: Ready for mainnet deployment
- ⏳ Week 2-4 post-mainnet: Review remaining items
- 🔮 V1.4+: Additional optimizations and features

---

## [1.2.0] - 2025-10-30 - External Call Security Hardening

### 🔒 CRITICAL Security Fix

#### [CRITICAL-0] Arbitrary Code Execution Prevention - RESOLVED ✅

**Status:** Fixed and Tested

**What Changed:**

- Removed all external contract calls from `LevrStaking_v1` and `LevrFeeSplitter_v1`
- Moved fee collection logic to SDK using `executeMulticall` pattern
- Updated `outstandingRewards()` interface to return single value

**Security Issue:**

External calls to Clanker LP/Fee lockers in contracts could allow arbitrary code execution if those contracts were malicious or compromised.

**Implementation Details:**

**Contract Changes:**

- Removed `_claimFromClankerFeeLocker()` from `LevrStaking_v1.sol` (69 lines)
- Removed `_getPendingFromClankerFeeLocker()` from `LevrStaking_v1.sol`
- Removed external LP/Fee locker calls from `LevrFeeSplitter_v1.sol`
- Updated `ILevrStaking_v1.outstandingRewards()`: returns `uint256 available` (was `(uint256, uint256)`)
- Removed `IClankerFeeLocker` and `IClankerLpLocker` imports from contract implementations

**SDK Changes:**

- Added `IClankerFeeLocker` and `IClankerLpLocker` ABIs
- Updated `accrueRewards()` to call `accrueAllRewards()` internally (handles fee collection)
- Updated `accrueAllRewards()` to wrap external calls in `forwarder.executeTransaction()`
- Updated `project.ts` to query pending fees from ClankerFeeLocker via multicall
- Added `getPendingFeesContracts()` helper for multicall integration
- Added `GET_FEE_LOCKER_ADDRESS()` constant

**Fee Collection Flow (Now in SDK):**

1. `forwarder.executeTransaction(lpLocker.collectRewards())` - V4 pool → fee locker
2. `forwarder.executeTransaction(feeLocker.claim())` - fee locker → staking/splitter
3. `feeSplitter.distribute()` (if configured) - splitter → receivers
4. `staking.accrueRewards()` - detects balance increase

**Benefits:**

- ✅ No arbitrary code execution risk in contracts
- ✅ External calls isolated and wrapped in secure context
- ✅ SDK maintains 100% API compatibility
- ✅ Data structure unchanged for consumers
- ✅ Single multicall transaction for gas efficiency

**Tests:**

- SDK tests: 4/4 passing ✅
- Contract tests: Updated 7 files, all passing ✅
- Integration verified with real fee collection on Anvil fork ✅

**Files Modified:**

- `src/LevrStaking_v1.sol`
- `src/LevrFeeSplitter_v1.sol`
- `src/interfaces/ILevrStaking_v1.sol`
- `test/mocks/MockStaking.sol`
- `test/e2e/LevrV1.Staking.t.sol`
- `test/e2e/LevrV1.StuckFundsRecovery.t.sol`
- `test/unit/LevrStakingV1.Accounting.t.sol`
- `test/unit/LevrStakingV1.AprSpike.t.sol`
- `test/unit/LevrStakingV1.t.sol`
- `test/unit/LevrStaking_StuckFunds.t.sol`

**SDK Files Modified:**

- `src/stake.ts`
- `src/project.ts`
- `src/constants.ts`
- `src/abis/index.ts`
- `src/abis/IClankerFeeLocker.ts` (new)
- `src/abis/IClankerLpLocker.ts` (new)
- `script/update-abis.ts`
- `test/stake.test.ts`

---

## [1.1.0] - 2025-01-10 - Balance-Based Design + Global Streaming

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

### ⚡ Performance Optimization

#### Global Streaming Implementation ✅

**What Changed:**

- Removed per-token stream time mappings
- All tokens share single global stream window
- Unvested rewards preserved on window reset

**Benefits:**

- 50% gas savings on accrueRewards (~40k gas per call)
- Simpler code (2 fewer state variables)
- Better UX (synchronized vesting)

**Tests:** 9/9 passing ✅

---

### 📊 Test Coverage

**New Tests:** 45 comprehensive tests

- 36 Balance-Based Design tests (transfer + rewards)
- 9 Global Streaming tests (midstream accruals)

**Test Results:** 416/416 passing ✅

- No regressions in existing tests
- Clean compilation, no warnings
- All edge cases thoroughly covered

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

## [1.2.0] - 2025-10-29 - Critical Bug Fixes & Design Improvements

### 🎯 CRITICAL Fixes

#### Unvested Rewards Exploit - RESOLVED ✅

**Status:** Fixed and Thoroughly Tested

**What Changed:**

- Fixed order of operations in `stake()` to update `_totalStaked` before calculating debt
- Added settlement calls in `_increaseDebtForAll()` and `_updateDebtAll()`
- Fixed `claimableRewards()` view to only calculate pending for active streams
- **Design Change:** Removed auto-claim from `unstake()` (breaking change)

**Implementation Details:**

- Modified `LevrStaking_v1.stake()` to re-order operations
- Modified `LevrStaking_v1.unstake()` to remove auto-claim behavior
- Updated debt calculation functions to settle streaming before setting debt
- Updated view function to prevent phantom rewards from ended streams

**Impact:**

- **Before:** Users could claim unvested rewards by unstaking during active stream, waiting for stream to end, then staking again
- **After:** Users can only claim rewards they actually earned while staked

**Tests:** All tests updated for new design ✅

**Breaking Change:** `unstake()` no longer auto-claims rewards. Users must call `claimRewards()` separately.

**Files Modified:**

- `src/LevrStaking_v1.sol` (multiple functions)

---

### 🔧 Design Improvements

#### RewardMath Library Addition ✅

**What Changed:**

- Created `src/libraries/RewardMath.sol` for reward calculation utilities
- Consolidates reward management logic for better maintainability

**Benefits:**

- Cleaner code organization
- Reusable reward calculation functions
- Easier to audit and test

**Files Created:**

- `src/libraries/RewardMath.sol`

---

#### Stream Reset Logic for First Staker ✅

**What Changed:**

- Enhanced stream reset logic when first staker joins
- Improved handling of zero-staker periods

**Benefits:**

- Prevents accounting inconsistencies
- Better handling of edge cases

---

### 📊 Test Coverage

**Test Results:** 418/418 passing (100%) ✅

- All Oct 29 bug fix tests added
- All existing tests updated for new design
- No regressions

---

## Previous Versions

[See git history for versions prior to 1.1.0]
