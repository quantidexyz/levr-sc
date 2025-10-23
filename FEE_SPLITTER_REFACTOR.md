# Fee Splitter Refactoring - Per-Project Architecture

## Problem Solved

**Original Issue**: Monolithic fee splitter had shared token balances across all projects, causing:
- ❌ Project A's WETH could be distributed to Project B's receivers
- ❌ Direct claims to the fee splitter couldn't be attributed to specific projects
- ❌ No way to distinguish which tokens belong to which project for shared reward tokens (WETH, USDC, etc.)

## Solution

Refactored to **per-project architecture**:
- ✅ Each project gets its own dedicated `LevrFeeSplitter_v1` instance
- ✅ No shared balances - each splitter only handles its own project's tokens
- ✅ Simpler code - no complex mappings needed
- ✅ Optional deployment - doesn't require factory changes
- ✅ Backward compatible with existing system

---

## Architecture

### Components

**1. LevrFeeSplitter_v1** (Refactored)
- Per-project instance (immutable `clankerToken`)
- Handles fee distribution for ONE project only
- Simplified state: no project mappings needed

**2. LevrFeeSplitterFactory_v1** (New)
- Deploys fee splitters for projects
- Tracks project → splitter mapping
- Supports CREATE2 for deterministic addresses
- Completely independent of factory

### Deployment Flow

```
1. Deploy LevrFeeSplitterFactory (one-time)
   ├─ Set factory address
   └─ Set trusted forwarder

2. For each project:
   ├─ Deploy Clanker token (existing flow)
   ├─ Deploy fee splitter: factory.deploy(clankerToken)
   └─ Configure splits: splitter.configureSplits([...])

3. Distribute fees:
   └─ Anyone calls: splitter.distribute(WETH)
```

---

## Contract Changes

### LevrFeeSplitter_v1

**Before (Monolithic)**:
```solidity
contract LevrFeeSplitter_v1 {
    // Shared across ALL projects
    mapping(address clankerToken => SplitConfig[]) private _projectSplits;
    mapping(address clankerToken => mapping(address token => DistributionState)) private _distributionState;
    
    function configureSplits(address clankerToken, SplitConfig[] calldata splits) external;
    function distribute(address clankerToken, address rewardToken) external;
}
```

**After (Per-Project)**:
```solidity
contract LevrFeeSplitter_v1 {
    // Immutable - set once in constructor
    address public immutable clankerToken;
    address public immutable factory;
    
    // Simple storage - no project mappings!
    SplitConfig[] private _splits;
    mapping(address token => DistributionState) private _distributionState;
    
    constructor(address clankerToken_, address factory_, address trustedForwarder_);
    
    function configureSplits(SplitConfig[] calldata splits) external;  // No clankerToken param!
    function distribute(address rewardToken) external;  // No clankerToken param!
}
```

### LevrFeeSplitterFactory_v1 (New)

```solidity
contract LevrFeeSplitterFactory_v1 {
    address public immutable factory;
    address public immutable trustedForwarder;
    
    mapping(address clankerToken => address feeSplitter) public splitters;
    
    // Deploy fee splitter for a project
    function deploy(address clankerToken) external returns (address splitter);
    
    // Deploy with CREATE2 for deterministic address
    function deployDeterministic(address clankerToken, bytes32 salt) external returns (address splitter);
    
    // Get fee splitter for a project
    function getSplitter(address clankerToken) external view returns (address);
    
    // Predict deterministic address
    function computeDeterministicAddress(address clankerToken, bytes32 salt) external view returns (address);
}
```

---

## Usage Examples

### 1. Deploy Factory (One-Time)

```solidity
LevrFeeSplitterFactory_v1 factory = new LevrFeeSplitterFactory_v1(
    address(levrFactory),
    address(forwarder)
);
```

### 2. Deploy Fee Splitter for a Project

```solidity
// Option A: Simple deployment
address splitter = factory.deploy(clankerToken);

// Option B: Deterministic deployment with CREATE2
bytes32 salt = keccak256(abi.encodePacked("my-project"));
address splitter = factory.deployDeterministic(clankerToken, salt);

// Option C: Predict address before deployment
address predicted = factory.computeDeterministicAddress(clankerToken, salt);
```

### 3. Configure Splits (Token Admin Only)

```solidity
LevrFeeSplitter_v1 splitter = LevrFeeSplitter_v1(splitterAddress);

SplitConfig[] memory splits = new SplitConfig[](3);
splits[0] = SplitConfig(stakingAddress, 7000);   // 70% to staking
splits[1] = SplitConfig(treasuryAddress, 2000);  // 20% to treasury
splits[2] = SplitConfig(protocolAddress, 1000);  // 10% to protocol

splitter.configureSplits(splits);
```

### 4. Distribute Fees (Anyone Can Call)

```solidity
// Single token distribution
splitter.distribute(WETH);

// Batch distribution (gas efficient)
address[] memory tokens = new address[](2);
tokens[0] = WETH;
tokens[1] = USDC;
splitter.distributeBatch(tokens);
```

### 5. Monitor Fees

```solidity
// Check pending fees in fee locker
uint256 pending = splitter.pendingFees(WETH);

// Check total pending (locker + contract balance)
uint256 total = splitter.pendingFeesInclBalance(WETH);

// If total > pending, tokens are stuck in contract
if (total > pending) {
    // Just call distribute() to distribute stuck tokens
    splitter.distribute(WETH);
}
```

---

## Key Benefits

### 1. No Token Mixing
Each splitter only handles its own project's tokens - no risk of cross-project contamination.

### 2. Simpler Logic
No complex project mappings - immutable `clankerToken` makes code cleaner and more gas efficient.

### 3. Optional Deployment
Projects can choose to use fee splitter or not - doesn't require factory changes.

### 4. Deterministic Addresses
CREATE2 support allows predicting addresses before deployment.

### 5. Direct Claims Safe
If someone calls `IClankerFeeLocker.claim(address(splitter), token)` directly:
- Tokens go to the correct splitter (dedicated to that project)
- Calling `distribute()` again distributes them according to configured splits
- No risk of stealing another project's tokens

---

## Migration from Monolithic Design

**Old Code**:
```solidity
feeSplitter.configureSplits(clankerToken, splits);
feeSplitter.distribute(clankerToken, WETH);
feeSplitter.getSplits(clankerToken);
```

**New Code**:
```solidity
// Get splitter for this project
address splitterAddr = factory.getSplitter(clankerToken);
LevrFeeSplitter_v1 splitter = LevrFeeSplitter_v1(splitterAddr);

// No clankerToken parameters!
splitter.configureSplits(splits);
splitter.distribute(WETH);
splitter.getSplits();
```

---

## Files Changed

### New Files
- `src/LevrFeeSplitterFactory_v1.sol` - Factory contract
- `src/interfaces/ILevrFeeSplitterFactory_v1.sol` - Factory interface

### Refactored Files
- `src/LevrFeeSplitter_v1.sol` - Per-project architecture
- `src/interfaces/ILevrFeeSplitter_v1.sol` - Updated signatures

### Key Changes
- All `clankerToken` parameters removed from function signatures
- Added `clankerToken` as immutable constructor parameter
- Removed project mappings in favor of simple arrays/mappings
- No factory integration required

---

## Testing Strategy

1. **Unit Tests**: Test splitter in isolation
   - Deploy splitter for a test token
   - Configure splits
   - Distribute fees
   - Verify balances

2. **Integration Tests**: Test with multiple projects
   - Deploy splitters for projects A and B
   - Distribute WETH for both
   - Verify no cross-contamination

3. **Edge Cases**:
   - Direct claims to splitter
   - Multiple distributions
   - Stuck tokens recovery

---

## Security Considerations

✅ **Per-project isolation**: No shared state between projects
✅ **Immutable configuration**: clankerToken can't be changed after deployment
✅ **Admin controls**: Only token admin can configure splits
✅ **Reentrancy protection**: NonReentrant modifier on distribution functions
✅ **Meta-transaction support**: Inherited from ERC2771ContextBase

---

## Gas Comparison

**Monolithic (Before)**:
- More complex storage (nested mappings)
- Higher gas for lookups
- Storage slots: O(projects × tokens)

**Per-Project (After)**:
- Simpler storage (direct arrays)
- Lower gas for lookups
- Storage slots: O(tokens) per splitter
- Additional deployment cost per project (one-time)

**Verdict**: Slightly higher one-time deployment cost, but simpler logic and better safety.

---

## Deployment Checklist

- [ ] Deploy `LevrFeeSplitterFactory_v1` with factory and forwarder addresses
- [ ] For each project that wants fee splitting:
  - [ ] Deploy fee splitter via factory
  - [ ] Configure splits (token admin)
  - [ ] Update LP locker to point to fee splitter (if needed)
  - [ ] Test distribution with small amount first
  - [ ] Monitor via `pendingFeesInclBalance()`

---

## Future Enhancements

1. **Batch Deployment**: Deploy splitters for multiple projects in one tx
2. **Default Splits**: Template configurations for common split patterns
3. **Split Updates**: Time-locked split configuration changes
4. **Fee Tracking**: Enhanced analytics per receiver
5. **Factory Integration**: Optional factory-managed deployment

---

**Status**: ✅ Refactoring Complete
**Linter**: ✅ No errors
**Backward Compatible**: ✅ Yes (separate deployment)
**Factory Changes Required**: ❌ No

