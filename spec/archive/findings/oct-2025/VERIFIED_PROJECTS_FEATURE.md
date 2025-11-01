# Verified Projects Feature Design

## Overview

This feature introduces the ability for the factory owner to verify projects, allowing verified projects to override factory configuration parameters (except protocol fee BPS) with their own custom settings.

**Implementation Status:** ✅ Complete

**Key Design Decisions:**

- Uses **optional address parameter** for config getters (pass `address(0)` for default, or `clankerToken` for project-specific)
- Calling contracts pass their `underlying` token address to get project-specific config
- **No reverse lookup needed** - simple, gas-efficient direct parameter approach
- Shared validation logic for factory and project configs
- Removed immutable `clankerFactory` in favor of trusted factories array
- Multiple Clanker factory support via try-catch loop
- **Security:** Requires at least one trusted factory for registrations (no allow-all mode)

## Objectives

1. Allow factory owner to verify/unverify projects
2. Enable verified projects to set custom configuration parameters
3. Maintain backwards compatibility - existing contracts continue fetching config the same way
4. Apply same validation logic to project config updates as factory config updates
5. Automatically initialize project override config with current factory config when verified

## Architecture

### Data Structures

#### Updated Project Struct

```solidity
struct Project {
    address treasury;
    address governor;
    address staking;
    address stakedToken;
    bool verified;  // NEW: Verification status
}
```

#### Project Override Config Storage

```solidity
// Maps clankerToken => custom config for verified projects
mapping(address => FactoryConfig) private _projectOverrideConfig;
```

#### Project Config Struct

A subset of FactoryConfig excluding protocolFeeBps:

```solidity
struct ProjectConfig {
    uint32 streamWindowSeconds;
    // Governance parameters
    uint32 proposalWindowSeconds;
    uint32 votingWindowSeconds;
    uint16 maxActiveProposals;
    uint16 quorumBps;
    uint16 approvalBps;
    uint16 minSTokenBpsToSubmit;
    uint16 maxProposalAmountBps;
    uint16 minimumQuorumBps;
    // Staking parameters
    uint16 maxRewardTokens;
}
```

### Core Functions

#### 1. Verification Management (Factory Owner Only)

**`verifyProject(address clankerToken)`**

- Validates project exists
- Sets `_projects[clankerToken].verified = true`
- Initializes `_projectOverrideConfig[clankerToken]` with current factory config
- Emits `ProjectVerified(clankerToken)` event

**`unverifyProject(address clankerToken)`**

- Validates project exists and is verified
- Sets `_projects[clankerToken].verified = false`
- Deletes `_projectOverrideConfig[clankerToken]` to free storage
- Emits `ProjectUnverified(clankerToken)` event

#### 2. Config Override Management (Project Admin Only)

**`updateProjectConfig(address clankerToken, ProjectConfig calldata cfg)`**

- Validates caller is token admin (same check as register)
- Validates project is verified
- Applies same validation logic as `_applyConfig` (excluding protocolFeeBps)
- Updates `_projectOverrideConfig[clankerToken]`
- Preserves protocolFeeBps from current override config
- Emits `ProjectConfigUpdated(clankerToken)` event

#### 3. Config Getters (Enhanced)

All existing config getters are enhanced to support project-specific configs:

**Signature:**

```solidity
// Single getter with optional parameter:
function quorumBps(address clankerToken) external view returns (uint16);
// - Pass address(0) for default factory config
// - Pass clankerToken for project-specific config (if verified)
```

**Implementation Pattern:**

```solidity
function quorumBps(address clankerToken) external view override returns (uint16) {
    if (clankerToken != address(0) && _projects[clankerToken].verified) {
        return _projectOverrideConfig[clankerToken].quorumBps;
    }
    return _quorumBps;  // Default factory config
}
```

### Contract Updates

#### Calling Contracts (Governor, Staking, Treasury)

Contracts pass their `underlying` token address to get project-specific config:

```solidity
// In Governor/Staking/Treasury:
uint16 quorum = ILevrFactory_v1(factory).quorumBps(underlying);
```

**Gas Efficiency:**

- No reverse lookup mapping needed
- Single conditional check and mapping read
- Contracts already have `underlying` in immutable storage (zero gas cost to access)

### Data Flow

```
┌─────────────────────────────────────────────────────────────┐
│ Factory Owner                                                 │
│  └─> verifyProject(token)                                    │
│       └─> Sets verified = true                               │
│       └─> Copies current factory config to override map     │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│ Project Admin (Token Admin)                                  │
│  └─> updateProjectConfig(token, customConfig)               │
│       └─> Validates project is verified                     │
│       └─> Applies validation (same as factory config)       │
│       └─> Updates _projectOverrideConfig[token]             │
│       └─> Preserves protocolFeeBps (not overridable)        │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│ Governance / Staking / Treasury Contracts                    │
│  └─> ILevrFactory_v1(factory).quorumBps(underlying)         │
│       └─> Factory checks if project verified                │
│       └─> Returns override config if verified               │
│       └─> Returns default config if not verified            │
└─────────────────────────────────────────────────────────────┘
```

## Critical Finding: Factory Removal Safety

### Question: Does removing a Clanker factory break existing projects?

**Answer: NO - Existing projects continue to function normally.**

**Test Results (9 comprehensive tests):**

- ✅ Staking operations work (stake/unstake) after factory removal
- ✅ Governance operations work (propose/vote/execute) after factory removal
- ✅ Treasury operations work (transfer/boost) after factory removal
- ✅ Reward distribution works (accrue/claim) after factory removal
- ✅ New registrations are **blocked** when no trusted factories (security)
- ✅ Re-adding factory restores registration capability
- ✅ Multiple factories: removing one doesn't affect others
- ✅ `getClankerMetadata` fails gracefully (returns non-existent)

**Why It's Safe:**

1. **Project contracts are independent** - they don't depend on Clanker factory
2. **Registration happens once** - factory is only used during `register()` call
3. **Config resolution uses reverse lookup** - `_contractToToken` mapping persists
4. **No ongoing dependencies** - Clanker factory not used for operations

**Security Requirement:**

- Factory now **requires at least one trusted Clanker factory** for registrations
- Prevents accidental allow-all mode if all factories removed
- Owner must explicitly add at least one factory before allowing registrations

## Security Considerations

### Access Control

1. **Verification**: Only factory owner can verify/unverify projects
2. **Config Updates**: Only token admin can update config for their verified project
3. **Immutable Protocol Fee**: Projects cannot override protocolFeeBps (protocol revenue protection)

### Validation

1. **Same validation rules** apply to project config updates as factory config updates
2. **Config gridlock prevention** rules apply (quorum ≤ 100%, no zero values, etc.)
3. **Project existence** checked before verification
4. **Verification status** checked before allowing config updates

### State Cleanup

1. When unverifying a project, delete override config to free storage and prevent gas griefing
2. Verification status is stored in Project struct for O(1) lookup

## Events

```solidity
event ProjectVerified(address indexed clankerToken);
event ProjectUnverified(address indexed clankerToken);
event ProjectConfigUpdated(address indexed clankerToken);
```

## Backwards Compatibility

### Existing Deployments

For contracts already deployed (Governor, Staking, Treasury):

- Old parameterless getters still work (return default factory config)
- No breaking changes to existing functionality
- Projects remain unverified by default

### Migration Path

For new deployments or upgrades:

1. Deploy updated contracts that pass `underlying` to factory getters
2. Factory owner verifies trusted projects
3. Project admins customize their configs

### Interface Compatibility

The interface maintains backwards compatibility by:

1. Keeping existing getters: `quorumBps() returns (uint16)`
2. Adding overloaded getters: `quorumBps(address) returns (uint16)`
3. Solidity function overloading ensures both work simultaneously

## Gas Optimization

1. **Verification flag** in Project struct (no extra SLOAD for lookup)
2. **Single SLOAD** from override config mapping for verified projects
3. **Storage cleanup** when unverifying (SSTORE 0 refund)
4. **No iteration** - all lookups are O(1)
5. **No reverse lookup** - direct parameter approach (saves 1 SLOAD per call)
6. **Immutable underlying** - contracts access underlying at zero gas cost

## Testing Requirements

### Unit Tests

1. **Verification**
   - ✅ Owner can verify project
   - ✅ Non-owner cannot verify project
   - ✅ Cannot verify non-existent project
   - ✅ Verification initializes config with factory defaults
   - ✅ Can unverify project
   - ✅ Unverifying clears override config

2. **Config Updates**
   - ✅ Verified project admin can update config
   - ✅ Non-admin cannot update config
   - ✅ Unverified project cannot update config
   - ✅ Cannot override protocolFeeBps
   - ✅ Validation rules enforced (BPS ≤ 10000, no zeros, etc.)
   - ✅ Invalid configs rejected with proper errors

3. **Config Getters**
   - ✅ Verified project gets override config
   - ✅ Unverified project gets default config
   - ✅ Parameterless getter returns default config
   - ✅ Zero address parameter returns default config
   - ✅ Non-existent project returns default config

4. **Integration**
   - ✅ Governor uses project config when verified
   - ✅ Staking uses project config when verified
   - ✅ Treasury uses project config when verified
   - ✅ Config changes apply immediately to governance cycles
   - ✅ Config changes apply immediately to staking rewards

### E2E Tests

1. Complete flow: verify → customize → governance with custom config
2. Unverify → falls back to default config
3. Multiple projects with different configs
4. Project admin changes during verification lifecycle

## Implementation Checklist

- [x] Update `ILevrFactory_v1.sol` interface
  - [x] Add `verified` to Project struct
  - [x] Add ProjectConfig struct
  - [x] Add verification functions
  - [x] Add updateProjectConfig function
  - [x] Simplified config getters (no overloading needed)
  - [x] Add events

- [x] Update `LevrFactory_v1.sol` implementation
  - [x] Add \_projectOverrideConfig mapping
  - [x] Implement verifyProject
  - [x] Implement unverifyProject
  - [x] Implement updateProjectConfig with validation
  - [x] Implement config getters with optional clankerToken parameter
  - [x] Remove immutable clankerFactory
  - [x] Refactor getClankerMetadata to loop trusted factories
  - [x] Add NO_TRUSTED_FACTORIES requirement
  - [x] Emit events

- [x] Update calling contracts
  - [x] LevrGovernor_v1 - pass `underlying` to factory config getters
  - [x] LevrStaking_v1 - pass `underlying` to factory config getters
  - [x] LevrTreasury_v1 - no changes needed (doesn't use config getters)

- [x] Update deployment scripts
  - [x] Update `DeployLevr.s.sol` to add Clanker factory after deployment
  - [x] Update `DeployLevrFactoryDevnet.s.sol` to add Clanker factory after deployment
  - [x] Update test helpers to add Clanker factory if provided

- [x] Write comprehensive tests
  - [x] Factory removal safety tests (9 tests)
  - [x] Updated existing Clanker validation tests
  - [x] All 436 unit tests passing

- [ ] Documentation
  - [ ] Update spec/GOV.md with verified projects
  - [ ] Update spec/USER_FLOWS.md with admin flows
  - [ ] Update spec/CHANGELOG.md

## Future Enhancements

1. **Multi-sig verification**: Require multiple signatures for verification
2. **Verification tiers**: Different levels of verification with different override permissions
3. **Time-locks**: Require time delay before config changes take effect
4. **Config templates**: Pre-defined config sets for different project types
5. **Governance integration**: Allow factory governance to vote on verifications

## Notes

- Protocol fee BPS is NOT overridable to protect protocol revenue
- Verification is a privilege granted by factory owner (centralized trust)
- Config validation prevents projects from griefing themselves
- Storage cleanup on unverification prevents griefing attacks
- Backwards compatible design allows gradual migration
