# Making Levr V1 Contracts Upgradeable

## Why Upgradeability is Critical

**Your mainnet deployment has a critical bug.** Without upgradeability:
- ❌ Must deploy new contracts
- ❌ Must migrate all users
- ❌ Lose contract addresses
- ❌ Stuck funds remain stuck forever

**With upgradeability:**
- ✅ Fix bugs in-place
- ✅ Keep same addresses
- ✅ Preserve all state
- ✅ No user migration needed

## Recommended Pattern: UUPS (Universal Upgradeable Proxy Standard)

### Why UUPS?

1. **Gas Efficient** - Upgrade logic in implementation, not proxy
2. **Battle-Tested** - OpenZeppelin's standard implementation
3. **Simpler** - Less complexity than Transparent or Diamond patterns
4. **Future-Proof** - Industry standard, well-documented

### UUPS vs Transparent Proxy

| Feature | UUPS | Transparent |
|---------|------|-------------|
| Upgrade logic | Implementation | Proxy |
| Gas cost | Lower | Higher |
| Admin calls | From implementation | Separate admin |
| Complexity | Medium | Higher |
| **Recommendation** | ✅ **Use This** | Only if needed |

## How UUPS Works

```
User → Proxy (holds state) → Implementation (logic)
                ↓
            delegatecall
```

**Key Concepts:**
1. **Proxy** - Minimal contract that holds state and forwards calls
2. **Implementation** - Your actual contract code (upgradeable)
3. **Storage** - Lives in proxy, MUST maintain layout across upgrades
4. **Upgrade** - Points proxy to new implementation address

## Implementation Steps

### Step 1: Add OpenZeppelin Upgradeable Contracts

```bash
cd packages/levr-sdk/contracts
forge install OpenZeppelin/openzeppelin-contracts-upgradeable
```

Update `remappings.txt`:
```
@openzeppelin/contracts-upgradeable/=lib/openzeppelin-contracts-upgradeable/contracts/
```

### Step 2: Convert LevrStaking_v1 to Upgradeable

**Key Changes:**

1. **Extend upgradeable base contracts**
```solidity
import {Initializable} from '@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol';
import {UUPSUpgradeable} from '@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol';
import {ReentrancyGuardUpgradeable} from '@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol';

contract LevrStaking_v1 is
    ILevrStaking_v1,
    Initializable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable,
    ERC2771ContextBase
{
```

2. **Disable initializers in constructor**
```solidity
/// @custom:oz-upgrades-unsafe-allow constructor
constructor(address trustedForwarder) ERC2771ContextBase(trustedForwarder) {
    _disableInitializers();
}
```

3. **Make initialize() use initializer modifier**
```solidity
function initialize(
    address underlying_,
    address stakedToken_,
    address treasury_,
    address factory_
) external initializer {  // Changed from external
    // ... validation ...
    
    __ReentrancyGuard_init();
    __UUPSUpgradeable_init();
    
    // ... rest of initialization ...
}
```

4. **Add upgrade authorization**
```solidity
/// @notice Authorize upgrade (only factory owner can upgrade)
function _authorizeUpgrade(address newImplementation) internal view override {
    address factoryOwner = ILevrFactory_v1(factory).owner();
    require(_msgSender() == factoryOwner, 'ONLY_FACTORY_OWNER');
}
```

5. **Change ReentrancyGuard to ReentrancyGuardUpgradeable**
```solidity
// Before
modifier nonReentrant { ... }

// After  
// Use from ReentrancyGuardUpgradeable (already included)
```

### Step 3: Update Factory to Deploy Proxies

```solidity
import {ERC1967Proxy} from '@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol';

contract LevrFactory_v1 {
    // Store implementation addresses (deployed once, reused for all projects)
    address public stakingImplementation;
    address public treasuryImplementation;
    address public governorImplementation;
    
    constructor(...) {
        // Deploy implementations once
        stakingImplementation = address(new LevrStaking_v1(trustedForwarder_));
        treasuryImplementation = address(new LevrTreasury_v1(address(this), trustedForwarder_));
        governorImplementation = address(new LevrGovernor_v1(...));
    }
    
    function prepareForDeployment() external returns (address treasury, address staking) {
        address deployer = _msgSender();
        
        // Deploy proxies, not implementations
        bytes memory treasuryInit = abi.encodeWithSelector(
            LevrTreasury_v1.initialize.selector,
            address(0), // governor (set later)
            address(0)  // underlying (set later)
        );
        treasury = address(new ERC1967Proxy(treasuryImplementation, treasuryInit));
        
        bytes memory stakingInit = abi.encodeWithSelector(
            LevrStaking_v1.initialize.selector,
            address(0), // underlying (set later)
            address(0), // stakedToken (set later)
            treasury,
            address(this)
        );
        staking = address(new ERC1967Proxy(stakingImplementation, stakingInit));
        
        // ... store prepared contracts ...
    }
}
```

### Step 4: Storage Layout Safety

**CRITICAL:** Storage layout MUST NOT change between upgrades!

**❌ UNSAFE - Changes storage layout:**
```solidity
// V1
contract MyContract {
    uint256 public value1;
    uint256 public value2;
}

// V2 - WRONG!
contract MyContract {
    uint256 public value2;  // Swapped order
    uint256 public value1;
}
```

**✅ SAFE - Append only:**
```solidity
// V1
contract MyContract {
    uint256 public value1;
    uint256 public value2;
}

// V2 - Correct!
contract MyContract {
    uint256 public value1;  // Same position
    uint256 public value2;  // Same position
    uint256 public value3;  // NEW - appended at end
}
```

**Use OpenZeppelin's storage layout validator:**
```bash
npx @openzeppelin/upgrades-core validate --contract LevrStaking_v1
```

## Upgrading Your Mainnet Deployment

### Option A: Deploy New Proxy System (Recommended)

Since your current contracts aren't upgradeable, you need to:

1. **Deploy new upgradeable versions** with proxies
2. **Pause old contracts** (if possible)
3. **Rescue stuck funds** from old via treasury injection
4. **Migrate users** to new contracts with incentives
5. **Deprecate old contracts**

### Option B: Wrapper Pattern (Quick Fix)

Create an upgradeable wrapper around existing contracts:

```solidity
contract LevrStakingWrapper_v1 is UUPSUpgradeable {
    LevrStaking_v1 public immutable oldStaking;
    
    constructor(address oldStaking_) {
        oldStaking = LevrStaking_v1(oldStaking_);
        _disableInitializers();
    }
    
    function initialize() external initializer {
        __UUPSUpgradeable_init();
    }
    
    // Delegate to old contract, but add rescue functions
    function rescueStuckRewards(address token, uint256 amount) external onlyOwner {
        // Inject tokens to unstick them
        IERC20(token).transferFrom(treasury, address(oldStaking), amount);
        oldStaking.accrueRewards(token);
    }
    
    // Proxy all other calls to old contract
    fallback() external {
        _delegate(address(oldStaking));
    }
}
```

## Complete Upgradeable Implementation Example

Here's the complete pattern for one contract:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Initializable} from '@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol';
import {UUPSUpgradeable} from '@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol';
import {ReentrancyGuardUpgradeable} from '@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol';
import {OwnableUpgradeable} from '@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol';

contract LevrStaking_v1_UUPS is
    Initializable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable,
    OwnableUpgradeable
{
    // === Storage (V1) ===
    // NEVER change order, only append!
    
    address public underlying;
    address public stakedToken;
    address public treasury;
    address public factory;
    
    // ... all other storage variables in EXACT same order ...
    
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }
    
    function initialize(
        address underlying_,
        address stakedToken_,
        address treasury_,
        address factory_,
        address owner_
    ) external initializer {
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();
        __Ownable_init(owner_);
        
        underlying = underlying_;
        stakedToken = stakedToken_;
        treasury = treasury_;
        factory = factory_;
    }
    
    /// @notice Authorize upgrade (only owner)
    function _authorizeUpgrade(address) internal view override onlyOwner {}
    
    /// @notice Get implementation version
    function version() external pure returns (uint256) {
        return 1;
    }
    
    // === All your existing functions here ===
    // (with the FIXED _creditRewards and _calculateUnvested)
}
```

## Upgrade Process

### 1. Deploy New Implementation

```solidity
// Deploy new fixed implementation
LevrStaking_v2 newImpl = new LevrStaking_v2(trustedForwarder);

// Proxy address (your existing mainnet contract)
address proxyAddress = 0x...;
```

### 2. Upgrade via Factory Owner

```solidity
// Only factory owner can do this
LevrStaking_v1_UUPS proxy = LevrStaking_v1_UUPS(proxyAddress);
proxy.upgradeToAndCall(address(newImpl), "");
```

### 3. Verify Upgrade

```solidity
// Check version
uint256 ver = proxy.version(); // Should be 2

// Check state preserved
uint256 stake = proxy.totalStaked(); // Should match pre-upgrade
```

## Testing Upgrades

```solidity
import {ERC1967Proxy} from '@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol';

contract UpgradeTest is Test {
    function test_upgradePreservesState() public {
        // Deploy V1 implementation
        LevrStaking_v1_UUPS implV1 = new LevrStaking_v1_UUPS(forwarder);
        
        // Deploy proxy pointing to V1
        bytes memory initData = abi.encodeWithSelector(
            LevrStaking_v1_UUPS.initialize.selector,
            underlying,
            stakedToken,
            treasury,
            factory,
            owner
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(implV1), initData);
        LevrStaking_v1_UUPS staking = LevrStaking_v1_UUPS(address(proxy));
        
        // Use V1
        alice.stake(1000e18);
        vm.warp(block.timestamp + 1 days);
        
        uint256 stakeV1 = staking.totalStaked();
        uint256 vpV1 = staking.getVotingPower(alice);
        
        // Deploy V2 implementation (with bug fix)
        LevrStaking_v2_UUPS implV2 = new LevrStaking_v2_UUPS(forwarder);
        
        // Upgrade
        vm.prank(owner);
        staking.upgradeToAndCall(address(implV2), "");
        
        // Verify state preserved
        assertEq(staking.totalStaked(), stakeV1);
        assertEq(staking.getVotingPower(alice), vpV1);
        assertEq(staking.version(), 2);
        
        // Test new functionality works
        staking.accrueRewards(underlying); // Uses fixed version
    }
}
```

## Rescuing Stuck Funds After Upgrade

Once upgraded to V2 with the fix, you can rescue stuck funds:

### Step 1: Add Rescue Function in V2

```solidity
contract LevrStaking_v2_UUPS is LevrStaking_v1_UUPS {
    /// @notice Rescue stuck rewards from V1 bug
    /// @dev Can only be called by factory owner, one-time operation
    bool public stuckRewardsRescued;
    
    function rescueStuckRewards(address token) external onlyOwner {
        require(!stuckRewardsRescued, "ALREADY_RESCUED");
        
        // Calculate stuck amount
        uint256 balance = IERC20(token).balanceOf(address(this));
        uint256 escrow = _escrowBalance[token];
        uint256 reserve = _rewardReserve[token];
        uint256 stuck = balance - escrow - reserve;
        
        if (stuck > 0) {
            // Add stuck amount to reserve and stream it
            _creditRewards(token, stuck);
            emit StuckRewardsRescued(token, stuck);
        }
        
        stuckRewardsRescued = true;
    }
    
    function version() external pure override returns (uint256) {
        return 2;
    }
}
```

### Step 2: Execute Rescue

```solidity
// After upgrading to V2
LevrStaking_v2_UUPS staking = LevrStaking_v2_UUPS(proxyAddress);

// Rescue stuck rewards
staking.rescueStuckRewards(underlyingToken);
// This makes stuck rewards available to users over next 3-day stream
```

## Storage Layout Validation

**Before ANY upgrade, validate storage:**

```bash
# Install validator
npm install --save-dev @openzeppelin/upgrades-core

# Validate storage layout
npx @openzeppelin/upgrades-core validate \
  --contract LevrStaking_v1_UUPS \
  --reference LevrStaking_v2_UUPS
```

**Manual Check:**
```solidity
// V1 storage
address public underlying;        // slot 0
address public stakedToken;       // slot 1
address public treasury;          // slot 2
address public factory;           // slot 3
// ... continue numbering ...

// V2 storage - MUST keep same order!
address public underlying;        // slot 0 ✅ Same
address public stakedToken;       // slot 1 ✅ Same
address public treasury;          // slot 2 ✅ Same
address public factory;           // slot 3 ✅ Same
// ... same order ...
bool public stuckRewardsRescued;  // NEW slot ✅ Appended at end
```

## Deployment Script for Upgradeable System

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Script} from 'forge-std/Script.sol';
import {ERC1967Proxy} from '@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol';
import {LevrFactory_v1_UUPS} from '../src/LevrFactory_v1_UUPS.sol';
import {LevrStaking_v1_UUPS} from '../src/LevrStaking_v1_UUPS.sol';
import {LevrTreasury_v1_UUPS} from '../src/LevrTreasury_v1_UUPS.sol';
import {LevrGovernor_v1_UUPS} from '../src/LevrGovernor_v1_UUPS.sol';

contract DeployUpgradeableSystem is Script {
    function run() external {
        vm.startBroadcast();
        
        // 1. Deploy forwarder
        address forwarder = address(new LevrForwarder_v1("LevrForwarder_v1"));
        
        // 2. Deploy implementation contracts (logic only)
        address stakingImpl = address(new LevrStaking_v1_UUPS(forwarder));
        address treasuryImpl = address(new LevrTreasury_v1_UUPS(address(0), forwarder));
        address governorImpl = address(new LevrGovernor_v1_UUPS(...));
        
        // 3. Deploy factory (which will use these implementations)
        LevrFactory_v1_UUPS factory = new LevrFactory_v1_UUPS(
            config,
            owner,
            forwarder,
            clankerFactory,
            levrDeployer,
            stakingImpl,
            treasuryImpl,
            governorImpl
        );
        
        vm.stopBroadcast();
        
        console.log("Factory:", address(factory));
        console.log("Staking Impl:", stakingImpl);
        console.log("Treasury Impl:", treasuryImpl);
        console.log("Governor Impl:", governorImpl);
    }
}
```

## Migration Path for Existing Mainnet

### Timeline

**Week 1: Prepare**
1. Deploy upgradeable system on testnet
2. Test thoroughly (all existing tests + upgrade tests)
3. Audit upgrade mechanisms
4. Prepare migration announcement

**Week 2: Deploy**
1. Deploy upgradeable implementations on mainnet
2. Deploy new factory with proxy support
3. Keep old system running

**Week 3: Migrate**
1. Announce migration with incentives (bonus rewards)
2. Users move to new contracts voluntarily
3. Monitor adoption

**Week 4+: Deprecate**
1. Once 90%+ migrated, sunset old contracts
2. Use treasury to rescue any remaining stuck funds
3. Distribute final rewards

### Migration Incentives

**Bonus for early adopters:**
```solidity
// In new upgradeable staking
mapping(address => bool) public migrated;

function migrat eFromOld(uint256 amount) external {
    // Unstake from old
    oldStaking.unstake(amount, address(this));
    
    // Stake in new (user's balance increases)
    _stake(_msgSender(), amount);
    
    // Bonus: 5% extra rewards for migrating
    if (!migrated[_msgSender()]) {
        _creditMigrationBonus(_msgSender(), amount * 5 / 100);
        migrated[_msgSender()] = true;
    }
}
```

## Quick Start: Minimal Upgradeable Version

If you want to get started FAST:

1. **Just make Staking upgradeable** (highest risk contract)
2. Keep Treasury and Governor non-upgradeable for now
3. This gives you ability to fix reward distribution bugs

**Minimal changes needed:**
- Change `ReentrancyGuard` → `ReentrancyGuardUpgradeable`
- Add `Initializable`, `UUPSUpgradeable` extends
- Add `_disableInitializers()` in constructor
- Add `__ReentrancyGuard_init()` and `__UUPSUpgradeable_init()` in initialize
- Add `_authorizeUpgrade()` function
- Update factory to deploy proxy

**Time estimate: 2-4 hours**

## Recommendations

### For Your Situation (Mainnet with Stuck Funds)

**Immediate (This Week):**
1. ✅ Apply the `_calculateUnvested()` fix to current codebase
2. Deploy to testnet and verify
3. Prepare upgrade to UUPS for Staking contract

**Short-term (Next 2 Weeks):**
1. Deploy upgradeable Staking with fix on mainnet
2. Test upgrade mechanism on testnet first
3. Keep old contracts running in parallel

**Medium-term (Next Month):**
1. Incentivize migration to new upgradeable contracts
2. Once 90% migrated, use rescue function for stuck funds
3. Distribute recovered funds to users

### For Future Projects

**Always start with UUPS from day 1:**
- Prevents this exact situation
- Industry best practice for DeFi
- Minimal gas overhead
- Peace of mind

## Security Considerations

### Upgrade Access Control

**CRITICAL:** Only factory owner should upgrade!

```solidity
function _authorizeUpgrade(address) internal view override {
    address factoryOwner = ILevrFactory_v1(factory).owner();
    require(_msgSender() == factoryOwner, 'ONLY_FACTORY_OWNER');
}
```

**Consider multi-sig:**
```solidity
// Use Gnosis Safe or similar
address public constant UPGRADE_MULTISIG = 0x...;

function _authorizeUpgrade(address) internal view override {
    require(_msgSender() == UPGRADE_MULTISIG, 'ONLY_MULTISIG');
}
```

### Timelock for Upgrades

Add 48-hour timelock for extra safety:

```solidity
mapping(address => uint256) public upgradeProposals;

function proposeUpgrade(address newImpl) external onlyOwner {
    upgradeProposals[newImpl] = block.timestamp + 48 hours;
}

function _authorizeUpgrade(address newImpl) internal view override {
    require(_msgSender() == owner(), 'ONLY_OWNER');
    require(
        upgradeProposals[newImpl] != 0 && 
        block.timestamp >= upgradeProposals[newImpl],
        'TIMELOCK_NOT_PASSED'
    );
}
```

## Testing Checklist

Before upgrading on mainnet:

- [ ] Storage layout validated (automated tool)
- [ ] All V1 tests pass on V2
- [ ] Upgrade preserves state (test with real data)
- [ ] Re-initialization prevented (initializer modifier)
- [ ] Only authorized can upgrade
- [ ] Upgrade tested on testnet fork
- [ ] Users can still interact normally after upgrade
- [ ] New features work correctly
- [ ] Gas costs compared (should be similar)
- [ ] Multiple upgrade cycles tested

## Next Steps

Would you like me to:

1. **Implement full UUPS for Staking contract** (complete working code)?
2. **Create upgrade deployment scripts**?
3. **Write comprehensive upgrade tests**?
4. **Create migration UI components**?
5. **All of the above**?

Given your mainnet situation, I recommend we prioritize #1 and #3 - get a working upgradeable Staking contract with thorough tests, then you can decide on deployment strategy.

What would you like me to build first?

