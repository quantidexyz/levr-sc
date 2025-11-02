# Whitelist-Only Reward Token System - Implementation Summary

**Date:** November 2, 2025  
**Version:** v1.5.0  
**Status:** ✅ Complete - All 531 tests passing (480 unit + 51 E2E)

---

## Overview

Implemented a mandatory whitelist-only system for reward tokens in the Levr V1 protocol. This replaces the optional `maxRewardTokens` limit with explicit whitelisting requirements for all reward tokens.

## Key Changes

### 1. Factory Initial Whitelist

**New Storage:**

```solidity
address[] private _initialWhitelistedTokens;
```

**New Functions:**

- `updateInitialWhitelist(address[] tokens)` - Owner can set factory's initial whitelist
- `getInitialWhitelist()` - Returns current initial whitelist

**Deployment:**

- Factory initialized with WETH in `_initialWhitelistedTokens`
- Projects deployed via factory inherit this whitelist

### 2. Staking Contract Changes

**Enhanced Initialization:**

```solidity
function initialize(
    address underlying_,
    address stakedToken_,
    address treasury_,
    address factory_,
    address[] memory initialWhitelistedTokens  // NEW
) external
```

- Underlying token: Auto-whitelisted, immutable
- Initial whitelist: Inherited from factory (e.g., WETH)
- Additional tokens can be whitelisted later by token admin

**New Function:**

```solidity
function unwhitelistToken(address token) external nonReentrant {
    require(token != underlying, 'CANNOT_UNWHITELIST_UNDERLYING');
    require(_msgSender() == tokenAdmin, 'ONLY_TOKEN_ADMIN');

    _settlePoolForToken(token);
    require(
        tokenState.availablePool == 0 && tokenState.streamTotal == 0,
        'CANNOT_UNWHITELIST_WITH_PENDING_REWARDS'
    );

    tokenState.whitelisted = false;
    emit TokenUnwhitelisted(token);
}
```

**Enhanced `whitelistToken`:**

```solidity
function whitelistToken(address token) external nonReentrant {
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

    // ... whitelist logic ...
}
```

**Strict Enforcement in `_ensureRewardToken`:**

```solidity
function _ensureRewardToken(address token) internal view returns (...) {
    require(tokenState.exists, 'TOKEN_NOT_WHITELISTED');
    require(tokenState.whitelisted, 'TOKEN_NOT_WHITELISTED');
    // ...
}
```

### 3. Fee Splitter Changes

**Added Whitelist Checks:**

```solidity
function distribute(address clankerToken, address rewardToken) external {
    require(
        ILevrStaking_v1(staking).isTokenWhitelisted(rewardToken),
        'TOKEN_NOT_WHITELISTED'
    );
    // ... distribution logic ...
}

function _distributeSingle(...) internal {
    require(
        ILevrStaking_v1(staking).isTokenWhitelisted(rewardToken),
        'TOKEN_NOT_WHITELISTED'
    );
    // ... distribution logic ...
}
```

### 4. Removed Logic

**Deleted from all contracts:**

- `maxRewardTokens` from `FactoryConfig`
- `maxRewardTokens` from `ProjectConfig`
- `maxRewardTokens(address)` getter function
- All `maxRewardTokens` validation logic

## Security Protections

### 1. Underlying Token Immutability

- `CANNOT_MODIFY_UNDERLYING`: Cannot call `whitelistToken(underlying)`
- `CANNOT_UNWHITELIST_UNDERLYING`: Cannot call `unwhitelistToken(underlying)`

### 2. Reward State Integrity

- `CANNOT_WHITELIST_WITH_PENDING_REWARDS`: Prevents re-whitelisting token with active rewards
- `CANNOT_UNWHITELIST_WITH_PENDING_REWARDS`: Prevents unwhitelisting token with claimable rewards

### 3. Access Control

- `ONLY_TOKEN_ADMIN`: Only underlying token admin can whitelist/unwhitelist tokens

### 4. Cleanup Safety

- `CANNOT_REMOVE_WHITELISTED`: Must unwhitelist before cleanup

## Test Coverage

### New Test File: `test/unit/LevrWhitelist.t.sol` (15 tests)

**Factory Initial Whitelist:**

1. ✅ `test_factory_initialWhitelist_storedCorrectly` - Factory stores and returns initial whitelist
2. ✅ `test_factory_updateInitialWhitelist_succeeds` - Owner can update whitelist
3. ✅ `test_factory_updateInitialWhitelist_onlyOwner` - Non-owner cannot update
4. ✅ `test_factory_updateInitialWhitelist_rejectsZeroAddress` - Zero address validation

**Project Inheritance:** 5. ✅ `test_project_inheritsFactoryWhitelist` - Projects inherit factory whitelist 6. ✅ `test_project_extendsInheritedWhitelist` - Projects can extend whitelist

**Underlying Protection:** 7. ✅ `test_underlying_cannotWhitelistAgain` - Cannot whitelist underlying 8. ✅ `test_underlying_cannotUnwhitelist` - Cannot unwhitelist underlying

**Reward State Protection:** 9. ✅ `test_whitelist_rejectsTokenWithPendingRewards` - Cannot unwhitelist with active stream 10. ✅ `test_unwhitelist_rejectsTokenWithPoolRewards` - Cannot unwhitelist with vested pool

**Lifecycle:** 11. ✅ `test_whitelist_completeLifecycle` - Complete whitelist → accrue → claim → unwhitelist → cleanup → re-whitelist 12. ✅ `test_whitelist_cannotWhitelistTwice` - Duplicate whitelist rejection 13. ✅ `test_whitelist_onlyTokenAdmin` - Access control for whitelisting 14. ✅ `test_unwhitelist_onlyTokenAdmin` - Access control for unwhitelisting

**Integration:** 15. ✅ `test_multiProject_independentWhitelists` - Projects maintain independent whitelists

### New Test File: `test/unit/LevrFactory_VerifiedProjects.t.sol` (15 tests)

**Protocol Fee Protection (CRITICAL):**

1. ✅ `test_projectConfig_cannotOverrideProtocolFee` - Verified projects cannot override protocol fee
2. ✅ `test_factoryProtocolFeeChange_appliesToAllProjects` - Fee changes sync to all projects
3. ✅ `test_projectConfigUpdate_alwaysUsesCurrentFactoryProtocolFee` - Runtime sync to factory
4. ✅ `test_multipleProjects_cannotOverrideProtocolFeeIndependently` - All projects use same fee
5. ✅ `test_protocolFee_cannotBeAvoided` - No config combination bypasses protocol fee
6. ✅ `test_factoryOwner_canAlwaysChangeProtocolFee` - Factory owner maintains control

**Protocol Treasury Protection:** 7. ✅ `test_projectConfig_cannotOverrideProtocolTreasury` - Projects cannot override treasury 8. ✅ `test_protocolTreasury_cannotBeOverridden` - Treasury changes sync to all projects

**Verified Project Features:** 9. ✅ `test_verifiedProject_canOverrideGovernanceParams` - Can customize governance settings 10. ✅ `test_unverifiedProject_cannotUpdateConfig` - Only verified projects can update config 11. ✅ `test_projectConfig_onlyTokenAdmin` - Only token admin can update config 12. ✅ `test_projectConfig_validationPreventsGridlock` - Invalid configs rejected

**Config Resolution:** 13. ✅ `test_configResolution_verifiedVsUnverified` - Correct config resolution 14. ✅ `test_unverify_removesCustomConfig` - Unverify removes overrides 15. ✅ `test_factoryProtocolFeeUpdate_syncsToVerifiedProjects` - Fee updates sync correctly

### Updated Test Files

**All test files updated to use new whitelist system:**

- `test/unit/LevrStakingV1.t.sol` - Added `whitelistRewardToken()` calls
- `test/unit/LevrStakingV1.Accounting.t.sol` - Use `initializeStakingWithRewardTokens()`
- `test/unit/LevrStaking_GlobalStreamingMidstream.t.sol` - Use whitelist helpers
- `test/unit/LevrStaking_StuckFunds.t.sol` - Updated for whitelist-only
- `test/unit/LevrStakingV1.AprSpike.t.sol` - Use whitelist helpers
- `test/unit/LevrFeeSplitterV1.t.sol` - Whitelist tokens in setUp
- `test/unit/LevrFeeSplitter_MissingEdgeCases.t.sol` - Whitelist dynamically created tokens
- `test/unit/LevrFactory_ConfigGridlock.t.sol` - Removed `maxRewardTokens` tests
- `test/unit/LevrAllContracts_EdgeCases.t.sol` - Use `_whitelistRewardToken()` helper
- `test/unit/LevrTokenAgnosticDOS.t.sol` - Removed `maxRewardTokens` tests
- `test/unit/LevrStaking.FeeOnTransfer.t.sol` - Use `_whitelistRewardToken()` helper
- `test/unit/LevrExternalAudit4.Validation.t.sol` - Fixed stream window configuration
- `test/e2e/LevrV1.StuckFundsRecovery.t.sol` - Whitelist all reward tokens

### Test Helpers

**New functions in `test/utils/LevrFactoryDeployHelper.sol`:**

```solidity
// Initialize staking with multiple pre-whitelisted reward tokens
function initializeStakingWithRewardTokens(
    LevrStaking_v1 staking,
    address underlying,
    address stakedToken,
    address treasury,
    address factory,
    address[] memory rewardTokens  // Pre-whitelist these tokens
) internal

// Convenience wrapper for single token
function initializeStakingWithRewardToken(
    LevrStaking_v1 staking,
    address underlying,
    address stakedToken,
    address treasury,
    address factory,
    address rewardToken  // Single token to whitelist
) internal

// Whitelist dynamically created tokens (for use in tests)
function whitelistRewardToken(
    LevrStaking_v1 staking,
    address token,
    address tokenAdmin
) internal
```

**Mock WETH Deployment:**

- Automatically deploys `MockERC20` at hardcoded Base WETH address
- Address: `0x4200000000000000000000000000000000000006`
- Uses `vm.etch` and `deployCodeTo` for deployment

## Documentation Updates

### 1. CHANGELOG.md

- Added v1.5.0 entry with complete implementation details
- Documented all breaking changes
- Provided migration notes for existing deployments

### 2. TESTING.md

- Updated test count: 516 tests (465 unit + 51 E2E)
- Added `LevrFactoryDeployHelper` documentation section
- Documented all three helper functions with usage examples
- Added recommended test pattern examples

### 3. USER_FLOWS.md

- Added Flow 2B: Reward Token Whitelisting
- Documented initial whitelist inheritance
- Documented whitelist extension by project admin
- Documented unwhitelisting requirements
- Listed all security protections
- Added whitelist-only enforcement code examples

### 4. FEE_SPLITTER.md

- Added whitelist requirement notes to `distribute()` documentation
- Added whitelist requirement notes to `distributeBatch()` documentation
- Clarified behavior differences (revert vs skip for non-whitelisted tokens)

## Migration Guide

### For Factory Deployments

**Before (v1.4.0):**

```solidity
factory = new LevrFactory_v1(
    config,
    owner,
    trustedForwarder,
    levrDeployer
);
```

**After (v1.5.0):**

```solidity
address[] memory initialWhitelist = new address[](1);
initialWhitelist[0] = WETH_ADDRESS;

factory = new LevrFactory_v1(
    config,
    owner,
    trustedForwarder,
    levrDeployer,
    initialWhitelist  // NEW parameter
);
```

### For Test Files

**Before (v1.4.0):**

```solidity
function setUp() public {
    staking.initialize(underlying, stakedToken, treasury, factory);

    // Could use any token without whitelisting
    rewardToken.mint(address(staking), 100 ether);
    staking.accrueRewards(address(rewardToken));
}
```

**After (v1.5.0):**

```solidity
function setUp() public {
    // Option 1: Whitelist during initialization
    address[] memory rewardTokens = new address[](1);
    rewardTokens[0] = address(weth);
    initializeStakingWithRewardTokens(
        staking, underlying, stakedToken, treasury, factory, rewardTokens
    );

    // WETH ready to use immediately
    weth.mint(address(staking), 100 ether);
    staking.accrueRewards(address(weth));
}

function test_dynamicToken() public {
    // Option 2: Whitelist dynamically
    MockERC20 dai = new MockERC20('DAI', 'DAI');
    whitelistRewardToken(staking, address(dai), tokenAdmin);

    dai.mint(address(staking), 100 ether);
    staking.accrueRewards(address(dai));
}
```

## Breaking Changes

### ❌ Removed Functions

- `factory.maxRewardTokens(address)` - No longer exists

### ❌ Changed Behavior

- Cannot accrue rewards for non-whitelisted tokens (reverts with `TOKEN_NOT_WHITELISTED`)
- Fee splitter rejects distribution of non-whitelisted tokens
- All deployment scripts must initialize factory with `initialWhitelistedTokens` array

### ⚠️ Required Actions

1. Factory deployments must include `initialWhitelistedTokens` parameter
2. Projects must whitelist tokens before using them for rewards
3. Test files must use new initialization helpers or explicitly whitelist tokens

## Files Modified

### Smart Contracts

- `src/interfaces/ILevrFactory_v1.sol`
- `src/LevrFactory_v1.sol`
- `src/interfaces/ILevrDeployer_v1.sol`
- `src/LevrDeployer_v1.sol`
- `src/interfaces/ILevrStaking_v1.sol`
- `src/LevrStaking_v1.sol`
- `src/LevrFeeSplitter_v1.sol`

### Deployment Scripts

- `script/DeployLevr.s.sol`
- `script/DeployLevrFactoryDevnet.s.sol`

### Test Infrastructure

- `test/utils/LevrFactoryDeployHelper.sol`
- `test/mocks/MockStaking.sol`

### Test Files (Updated)

- All unit test files (`test/unit/*.t.sol`)
- All E2E test files (`test/e2e/*.sol`)

### Test Files (New)

- `test/unit/LevrWhitelist.t.sol` (15 new tests)

### Documentation

- `spec/CHANGELOG.md`
- `spec/TESTING.md`
- `spec/USER_FLOWS.md`
- `spec/FEE_SPLITTER.md`
- `spec/WHITELIST_IMPLEMENTATION_SUMMARY.md` (this file)

## Verification

### Test Results

```bash
# Unit tests
FOUNDRY_PROFILE=dev forge test --match-path "test/unit/*.t.sol" -vvv
# Result: 480/480 passing ✅

# E2E tests
forge test --match-path "test/e2e/*.sol" -vvv
# Result: 51/51 passing ✅

# Total: 531/531 passing ✅
```

### Linting

```bash
# No linter errors in modified files
```

## Additional Improvements

### Protocol Fee Protection (v1.5.0 Enhancement)

**Issue:** Verified projects could potentially override protocol fee in their config overrides

**Fix:** Enforced that `updateProjectConfig()` ALWAYS uses current factory `protocolFeeBps` and `protocolTreasury`

```solidity
// BEFORE: Used stored value from _projectOverrideConfig
FactoryConfig storage existingCfg = _projectOverrideConfig[clankerToken];
FactoryConfig memory fullCfg = FactoryConfig({
    protocolFeeBps: existingCfg.protocolFeeBps,  // Could be stale
    // ...
});

// AFTER: Always use current factory values
FactoryConfig memory fullCfg = FactoryConfig({
    protocolFeeBps: _protocolFeeBps,  // Always current factory value
    protocolTreasury: _protocolTreasury,  // Always current factory value
    // ... project's custom params ...
});
```

**Protection Layers:**

1. ✅ `ProjectConfig` struct excludes `protocolFeeBps` and `protocolTreasury`
2. ✅ Runtime enforcement: Always pulls from `_protocolFeeBps` state variable
3. ✅ Getter isolation: `protocolFeeBps()` has no project override logic
4. ✅ 6 comprehensive tests for protocol revenue protection

### Stream Window Validation (v1.5.0 Enhancement)

**Change:** Removed hardcoded 1-day minimum for stream window

```solidity
// BEFORE: Minimum 1 day
require(cfg.streamWindowSeconds >= 1 days, 'STREAM_WINDOW_TOO_SHORT');

// AFTER: Only require non-zero (like other time windows)
require(cfg.streamWindowSeconds > 0, 'STREAM_WINDOW_ZERO');
```

**Reason:** Consistency with other time window validations (proposal/voting windows)

**Impact:** Projects can now use very short stream windows if needed (e.g., 1 hour for testing or special cases)

## Conclusion

The whitelist-only reward token system is fully implemented, tested, and documented. All 531 tests pass, and the system provides strong security guarantees for reward token management, protocol revenue protection, and flexible project configuration.

**Key Benefits:**

1. ✅ Enhanced security (only approved tokens can be used)
2. ✅ Underlying token immutability (cannot be unwhitelisted)
3. ✅ Reward state protection (prevents fund loss)
4. ✅ Flexible project configuration (can extend factory whitelist)
5. ✅ Protocol revenue security (projects cannot override protocol fee)
6. ✅ Comprehensive test coverage (30 new tests + updates to all existing tests)
7. ✅ Well-documented (4 spec files updated + new summary + 12 adversarial scenarios)
8. ✅ Attack surface analysis (USER_FLOWS.md extended with 12 complex scenarios)
