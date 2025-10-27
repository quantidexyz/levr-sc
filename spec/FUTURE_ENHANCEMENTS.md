# Future Enhancements - Levr V1

**Purpose:** Design documentation for optional future improvements  
**Status:** Not implemented (design phase)  
**Last Updated:** October 27, 2025

---

## Table of Contents

1. [Emergency Rescue System](#emergency-rescue-system)
2. [UUPS Upgradeability](#uups-upgradeability)
3. [Optional Validations](#optional-validations)
4. [Complexity Assessment](#complexity-assessment)

---

## Emergency Rescue System

**Goal:** Never have funds stuck again, regardless of bugs  
**Complexity:** Medium  
**Time Estimate:** 12 hours  
**Status:** Designed, not implemented

### Overview

Factory-based emergency mode system with rescue functions across all contracts.

```
LevrFactory_v1 (Emergency Control Center)
  ├─ emergencyMode: bool (global kill switch)
  ├─ emergencyAdmin: address (multi-sig recommended)
  └─ Emergency functions for ALL project contracts

LevrStaking_v1
  ├─ emergencyRescueToken() - Rescue stuck tokens
  ├─ emergencyAdjustReserve() - Fix accounting
  ├─ emergencyAdjustTotalStaked() - Fix peg
  └─ emergencyClearStream() - Reset stuck streams

LevrTreasury_v1
  ├─ emergencyPause() - Stop governor actions
  ├─ emergencyUnpause() - Resume operations
  └─ emergencyRescueToken() - Rescue any token

LevrGovernor_v1
  ├─ emergencyCancelProposal() - Cancel malicious proposals
  └─ emergencyExecuteProposal() - Force execute stuck proposals
```

### Key Features

**Rescue Operations:**

- ✅ Rescue stuck tokens (protecting user escrow)
- ✅ Fix accounting bugs (reserve, totalStaked)
- ✅ Clear stuck streams
- ✅ Pause compromised contracts
- ✅ Cancel/execute proposals

**Safety Features:**

- ✅ Two-key system (owner + emergency admin)
- ✅ Global emergency mode flag
- ✅ Can't rug pull user escrow
- ✅ Only works on registered contracts
- ✅ All actions emit events (audit trail)

**Monitoring:**

- ✅ `checkInvariants()` - Auto-detect issues
- ✅ `getDebugState()` - Full state visibility

### Implementation Outline

**1. Factory Updates (~100 lines)**

```solidity
contract LevrFactory_v1 {
    address public emergencyAdmin;
    bool public emergencyMode;

    function setEmergencyAdmin(address admin) external onlyOwner;
    function enableEmergencyMode() external; // Owner or admin
    function disableEmergencyMode() external onlyOwner;

    function emergencyRescueFromContract(
        address projectToken,
        address targetContract,
        bytes calldata rescueCalldata
    ) external returns (bytes memory);
}
```

**2. Staking Emergency Functions (~80 lines)**

```solidity
function emergencyRescueToken(
    address token,
    address to,
    uint256 amount,
    string calldata reason
) external {
    require(ILevrFactory_v1(factory).emergencyMode());
    require(msg.sender == ILevrFactory_v1(factory).emergencyAdmin());

    // Safety: Can't rescue escrowed principal
    if (token == underlying) {
        uint256 maxRescue = balance - _escrowBalance[underlying];
        require(amount <= maxRescue);
    }

    IERC20(token).safeTransfer(to, amount);
}

function checkInvariants() external view returns (bool ok, string memory issue) {
    // Check staking peg
    if (IERC20(stakedToken).totalSupply() != _totalStaked) {
        return (false, "STAKING_PEG_BROKEN");
    }

    // Check escrow
    if (_escrowBalance[underlying] > IERC20(underlying).balanceOf(address(this))) {
        return (false, "ESCROW_EXCEEDS_BALANCE");
    }

    // Check reserves
    // ...

    return (true, "ALL_OK");
}
```

**3. Treasury Emergency Functions (~60 lines)**

```solidity
bool public paused;

modifier whenNotPaused() {
    require(!paused);
    _;
}

function emergencyPause() external;
function emergencyUnpause() external;
function emergencyRescueToken(address token, address to, uint256 amount) external;
```

**4. Governor Emergency Functions (~50 lines)**

```solidity
function emergencyCancelProposal(uint256 proposalId) external;
function emergencyExecuteProposal(uint256 proposalId) external;
```

### Usage Scenarios

**Scenario 1: Rescue Stuck Rewards**

```solidity
// 1. Enable emergency mode
factory.enableEmergencyMode();

// 2. Check invariants
(bool ok, string memory issue) = staking.checkInvariants();

// 3. Rescue stuck tokens to treasury
bytes memory call = abi.encodeWithSelector(
    LevrStaking_v1.emergencyRescueToken.selector,
    token, treasury, amount, "Rescuing stuck rewards"
);
factory.emergencyRescueFromContract(projectToken, staking, call);

// 4. Re-accrue
staking.accrueRewards(token);

// 5. Disable emergency mode
factory.disableEmergencyMode();
```

**Scenario 2: Pause Compromised Governor**

```solidity
// 1. Enable emergency mode
factory.enableEmergencyMode();

// 2. Pause treasury
bytes memory call = abi.encodeWithSelector(
    LevrTreasury_v1.emergencyPause.selector
);
factory.emergencyRescueFromContract(projectToken, treasury, call);

// 3. Cancel malicious proposal
// 4. Fix governor
// 5. Unpause and resume
```

### Monitoring

```typescript
// Check invariants every block
const [ok, issue] = await staking.checkInvariants()
if (!ok) {
  alert(`🚨 INVARIANT VIOLATION: ${issue}`)
}

// Get debug state
const { totalStaked, stakedTokenSupply, balance, escrow, reserve, pegOk } =
  await staking.getDebugState()
```

### Cost-Benefit

**Implementation Cost:**

- Dev time: 12 hours
- Gas cost: ~$30 one-time
- Complexity: Medium

**Benefits:**

- Can rescue ANY stuck funds
- Can fix ANY accounting bug
- Can pause compromised contracts
- Industry-standard safety
- User confidence

**ROI:** 100:1 (prevents major losses)

---

## UUPS Upgradeability

**Goal:** Fix logic bugs without redeployment  
**Complexity:** Medium-High  
**Time Estimate:** 36 hours  
**Status:** Designed, not implemented

### Overview

Implement OpenZeppelin's UUPS (Universal Upgradeable Proxy Standard) pattern to enable in-place contract upgrades.

### Architecture

```
User → Proxy (holds state) → Implementation (logic)
```

**Key Benefits:**

- ✅ Fix bugs without redeployment
- ✅ Keep same addresses forever
- ✅ Preserve all state
- ✅ No user migration

### Implementation Outline

**1. Add Dependencies**

```bash
forge install OpenZeppelin/openzeppelin-contracts-upgradeable
```

**2. Convert Contracts (~20 lines per contract)**

```solidity
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";

contract LevrStaking_v1 is
    Initializable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable,
    ERC2771ContextBase
{
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address trustedForwarder) ERC2771ContextBase(trustedForwarder) {
        _disableInitializers();
    }

    function initialize(...) external initializer {
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();
        // ... rest of initialization
    }

    function _authorizeUpgrade(address) internal view override {
        require(_msgSender() == ILevrFactory_v1(factory).owner());
    }
}
```

**3. Update Factory (~100 lines)**

```solidity
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract LevrFactory_v1 {
    address public stakingImplementation;
    address public treasuryImplementation;
    address public governorImplementation;

    constructor(...) {
        // Deploy implementations once
        stakingImplementation = address(new LevrStaking_v1(forwarder));
        // ...
    }

    function prepareForDeployment() external returns (...) {
        // Deploy proxies instead of implementations
        bytes memory init = abi.encodeWithSelector(...);
        address proxy = address(new ERC1967Proxy(stakingImplementation, init));
        // ...
    }
}
```

### Storage Layout Rules

**CRITICAL:** Storage layout MUST NOT change between upgrades!

**✅ SAFE:**

```solidity
// V1
address public value1;  // slot 0
address public value2;  // slot 1

// V2
address public value1;  // slot 0 ✅ Same
address public value2;  // slot 1 ✅ Same
address public value3;  // slot 2 ✅ New, appended
```

**❌ UNSAFE:**

```solidity
// V1
address public value1;  // slot 0
address public value2;  // slot 1

// V2
address public value2;  // slot 0 ❌ Wrong!
address public value1;  // slot 1 ❌ Wrong!
```

### Upgrade Process

```solidity
// 1. Deploy new implementation
LevrStaking_v2 newImpl = new LevrStaking_v2(forwarder);

// 2. Validate storage layout
// npx @openzeppelin/upgrades-core validate

// 3. Upgrade
proxy.upgradeToAndCall(address(newImpl), "");

// 4. Verify
assert(proxy.version() == 2);
```

### Complexity Breakdown

| Task          | Time         | Complexity      |
| ------------- | ------------ | --------------- |
| Code changes  | 8 hours      | Medium          |
| Testing       | 12 hours     | Medium-High     |
| Deployment    | 4 hours      | Medium          |
| Documentation | 4 hours      | Low             |
| Debugging     | 8 hours      | Medium          |
| **Total**     | **36 hours** | **Medium-High** |

### Challenges

**Easy:**

- Adding imports and extends
- Writing `_authorizeUpgrade()`
- Basic proxy deployment

**Medium:**

- Storage layout management
- Testing upgrade scenarios
- Proxy verification on Etherscan

**Hard:**

- ERC2771 + UUPS + ReentrancyGuard integration
- Multiple inheritance resolution
- State migration (if needed)

---

## Optional Validations

**Goal:** Prevent edge case issues  
**Complexity:** Low  
**Time Estimate:** 3 hours  
**Priority:** Optional (nice-to-have)

### 1. BPS Range Validation

**Problem:** Factory allows invalid BPS values (>10000)

**Fix:**

```solidity
// LevrFactory_v1.updateConfig()
function _validateConfig(FactoryConfig memory cfg) internal pure {
    require(cfg.quorumBps <= 10000, "INVALID_QUORUM_BPS");
    require(cfg.approvalBps <= 10000, "INVALID_APPROVAL_BPS");
    require(cfg.minSTokenBpsToSubmit <= 10000, "INVALID_MIN_STAKE_BPS");
    require(cfg.maxProposalAmountBps <= 10000, "INVALID_MAX_PROPOSAL_BPS");
}
```

**Benefit:** Prevents governance lockup from invalid config  
**Time:** 30 minutes

### 2. Fee Splitter Self-Send Prevention

**Problem:** Can configure splitter to send to itself

**Fix:**

```solidity
// LevrFeeSplitter_v1._validateSplits()
for (uint256 i = 0; i < splits.length; i++) {
    if (splits[i].receiver == address(this)) {
        revert CannotSendToSelf();
    }
}
```

**Benefit:** Prevents stuck funds  
**Workaround:** recoverDust() can fix it  
**Time:** 30 minutes

### 3. Batch Size Limit

**Problem:** No limit on distributeBatch() array size

**Fix:**

```solidity
uint256 private constant MAX_BATCH_SIZE = 100;

function distributeBatch(address[] calldata tokens) external {
    require(tokens.length <= MAX_BATCH_SIZE, "BATCH_TOO_LARGE");
    // ...
}
```

**Benefit:** Prevents gas bomb DOS  
**Practical Limit:** Block gas limit already limits this  
**Time:** 15 minutes

### 4. Zero Supply Proposal Prevention

**Problem:** Can create proposals when no one is staked

**Fix:**

```solidity
function _propose(...) internal {
    uint256 totalSupply = IERC20(stakedToken).totalSupply();
    require(totalSupply > 0, "NO_STAKERS");
    // ...
}
```

**Benefit:** Prevents wasteful proposals  
**Time:** 15 minutes

### 5. Max Reward Tokens Limit

**Problem:** Unbounded `_rewardTokens` array could cause DOS

**Fix:**

```solidity
uint256 public constant MAX_REWARD_TOKENS = 50;

function _ensureRewardToken(address token) internal {
    if (!_rewardInfo[token].exists) {
        require(_rewardTokens.length < MAX_REWARD_TOKENS, "TOO_MANY_TOKENS");
        // ...
    }
}
```

**Benefit:** Prevents DOS via gas limit  
**Time:** 30 minutes

### 6. Treasury Rate Limiting

**Problem:** Compromised governor could drain treasury

**Fix:**

```solidity
mapping(uint256 => uint256) public transferredPerDay;

function transfer(address token, address to, uint256 amount) external {
    uint256 today = block.timestamp / 1 days;
    uint256 maxDaily = IERC20(token).balanceOf(address(this)) / 10; // 10% max
    require(transferredPerDay[today] + amount <= maxDaily, "DAILY_LIMIT");

    transferredPerDay[today] += amount;
    IERC20(token).safeTransfer(to, amount);
}
```

**Benefit:** Limits damage from governor bugs  
**Time:** 1 hour

---

## Complexity Assessment

### Emergency System vs UUPS Comparison

| Feature                 | Emergency System | UUPS Upgrade |
| ----------------------- | ---------------- | ------------ |
| **Rescue stuck funds**  | ✅ Yes           | ✅ Yes       |
| **Fix accounting bugs** | ✅ Yes           | ✅ Yes       |
| **Fix logic bugs**      | ❌ No            | ✅ Yes       |
| **No redeployment**     | ❌ No            | ✅ Yes       |
| **Complexity**          | Medium           | Medium-High  |
| **Time to implement**   | 12 hours         | 36 hours     |
| **Ongoing maintenance** | Low              | Medium       |

### Recommended Approach

**Phase 1: Emergency System (12 hours)**

- Faster to implement
- Immediate safety net
- Protects against accounting bugs
- Can rescue current issues

**Phase 2: UUPS (36 hours)**

- Long-term solution
- Can fix future logic bugs
- Enterprise-grade
- No migration needed

**Total: 48 hours spread over 4-6 weeks**

### Implementation Priorities

**Priority 1: Emergency Mode System (High Value)**

- Benefit: Rescue funds from ANY future bug
- Time: 12 hours
- Risk: Low with proper access control

**Priority 2: Invariant Monitoring (Medium Value)**

- Benefit: Early detection of issues
- Time: 2 hours
- Risk: None (view functions only)

**Priority 3: UUPS Upgradeability (High Value, Long-term)**

- Benefit: Never redeploy again
- Time: 36 hours
- Risk: Medium (storage layout complexity)

**Priority 4: Optional Validations (Low Value)**

- Benefit: Prevents unlikely edge cases
- Time: 3 hours
- Risk: None

---

## Edge Cases Requiring Emergency Functions

From comprehensive analysis, these scenarios need emergency rescue:

### 1. Staking Peg Mismatch (Critical)

**Issue:** `_totalStaked` diverges from `stakedToken.totalSupply()`  
**Impact:** Users can't unstake  
**Emergency Fix:** `emergencyAdjustTotalStaked()`

### 2. Escrow Balance Underflow (Critical)

**Issue:** `_escrowBalance` > actual balance  
**Impact:** Unstake reverts  
**Emergency Fix:** `emergencyRescueToken()` for excess

### 3. Reward Reserve Mismatch (High)

**Issue:** `_rewardReserve` > claimable rewards  
**Impact:** Claims revert  
**Emergency Fix:** `emergencyAdjustReserve()`

### 4. ClankerFeeLocker Claim Failure (High)

**Issue:** Auto-claim silently fails  
**Impact:** Fees stuck in fee locker  
**Emergency Fix:** `manualClaimFromFeeLocker()` (already implemented)

### 5. Too Many Reward Tokens (High)

**Issue:** Unbounded array causes DOS  
**Impact:** Can't stake/unstake  
**Emergency Fix:** `emergencyClearStream()` or add MAX limit

### 6. Governor Compromise (High)

**Issue:** Bug allows unauthorized actions  
**Impact:** Treasury drained  
**Emergency Fix:** `emergencyPause()` on treasury

---

## UUPS Implementation Details

### Key Changes Per Contract

**Staking (~20 lines):**

- Change `ReentrancyGuard` → `ReentrancyGuardUpgradeable`
- Add `Initializable`, `UUPSUpgradeable`
- Add `_disableInitializers()` in constructor
- Add `__ReentrancyGuard_init()` in initialize
- Add `_authorizeUpgrade()` function

**Treasury (~20 lines):**

- Same pattern as Staking

**Governor (~20 lines):**

- Same pattern as Staking

**Factory (~100 lines):**

- Store implementation addresses
- Deploy proxies instead of implementations
- Initialize proxies with project data

### Storage Layout Validation

**Use OpenZeppelin validator:**

```bash
npx @openzeppelin/upgrades-core validate \
  --contract LevrStaking_v1 \
  --reference LevrStaking_v2
```

**Manual validation checklist:**

- [ ] No reordering of existing variables
- [ ] Only append new variables
- [ ] No type changes
- [ ] No deletion of variables
- [ ] Maintain inheritance order

### Testing Requirements

**25 upgrade scenario tests needed:**

- Deploy proxy tests
- State preservation tests
- Unauthorized upgrade tests
- Re-initialization prevention tests
- Storage layout validation
- Multiple upgrade cycle tests
- Integration tests post-upgrade

### Migration Paths

**For Existing Deployments:**

1. Deploy new UUPS system (new addresses)
2. Incentivize migration with bonus rewards
3. Deprecate old contracts after 90% migration

**For New Deployments:**

- Start with UUPS from day 1
- No migration needed
- Can fix any future bugs in-place

---

## Alternative Approaches

### 1. Minimal Upgradeable (Lower Complexity)

**Only make Staking upgradeable:**

- Treasury and Governor stay non-upgradeable
- Staking is most bug-prone
- Reduces work by ~40%

**Time:** 20 hours instead of 36

### 2. Emergency Functions Only (Lowest Complexity)

**Skip UUPS, only add rescue functions:**

- Can rescue funds
- Can fix accounting
- Cannot fix logic bugs
- Requires redeploy for logic fixes

**Time:** 12 hours

### 3. Wrapper Pattern (Quick Fix)

**Upgradeable wrapper around existing contracts:**

```solidity
contract LevrStakingWrapper is UUPSUpgradeable {
    LevrStaking_v1 public immutable oldStaking;

    function rescueStuckRewards(...) external onlyOwner {
        // Inject tokens to fix accounting
    }

    // Proxy other calls to old contract
}
```

**Time:** 8 hours  
**Trade-off:** Not as clean, but works

---

## Decision Framework

### Choose Emergency System If:

- ✅ Need immediate safety net
- ✅ Want to prevent stuck funds
- ✅ Have 12 hours available
- ✅ Want industry-standard protection
- ✅ UUPS can wait for later

### Choose UUPS If:

- ✅ Want to fix future logic bugs
- ✅ Have 2+ weeks available
- ✅ Want zero-migration upgrades
- ✅ Want enterprise-grade solution
- ✅ Have proxy pattern expertise

### Choose Both (Recommended) If:

- ✅ Want complete protection
- ✅ Can stage implementation
- ✅ Want best long-term solution
- ✅ Emergency system first (12h), then UUPS later (36h)

---

## Risk Matrix

| Enhancement            | Benefit | Complexity  | Time | Priority | Status          |
| ---------------------- | ------- | ----------- | ---- | -------- | --------------- |
| Emergency rescue       | High    | Medium      | 12h  | High     | Not implemented |
| UUPS upgradeability    | High    | Medium-High | 36h  | Medium   | Not implemented |
| BPS validation         | Medium  | Low         | 30m  | Low      | Not implemented |
| Max reward tokens      | Medium  | Low         | 30m  | Low      | Not implemented |
| Treasury rate limiting | Medium  | Low         | 1h   | Low      | Not implemented |
| Batch size limit       | Low     | Low         | 15m  | Low      | Not implemented |

---

## Implementation Checklist

If implementing Emergency System:

- [ ] Update ILevrFactory_v1 interface (emergency functions)
- [ ] Add emergency mode to LevrFactory_v1
- [ ] Add rescue functions to LevrStaking_v1
- [ ] Add pause/rescue to LevrTreasury_v1
- [ ] Add cancel/execute to LevrGovernor_v1
- [ ] Add checkInvariants() to all contracts
- [ ] Write 15+ comprehensive tests
- [ ] Deploy to testnet
- [ ] Set up monitoring
- [ ] Configure multi-sig emergency admin

If implementing UUPS:

- [ ] Install openzeppelin-contracts-upgradeable
- [ ] Update remappings
- [ ] Convert Staking to upgradeable
- [ ] Convert Treasury to upgradeable
- [ ] Convert Governor to upgradeable
- [ ] Update Factory for proxy deployment
- [ ] Write 25+ upgrade tests
- [ ] Validate storage layouts
- [ ] Deploy to testnet
- [ ] Test upgrade on fork
- [ ] Deploy to mainnet
- [ ] Execute test upgrade

---

## References

### Design Documents (Archived Here)

These documents are archived as they're consolidated above:

- COMPREHENSIVE_EDGE_CASE_ANALYSIS.md
- EMERGENCY_RESCUE_IMPLEMENTATION.md
- EXECUTIVE_SUMMARY.md
- SECURITY_AUDIT_REPORT.md
- UPGRADEABILITY_COMPLEXITY_ASSESSMENT.md
- UPGRADEABILITY_GUIDE.md

### Current Documentation

- **[audit.md](./audit.md)** - Security audit
- **[README.md](./README.md)** - Main entry point

---

**Status:** Designs complete, implementation optional  
**Recommendation:** Consider emergency system before scaling TVL  
**Timeline:** Can implement anytime based on needs
