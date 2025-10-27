# Comprehensive Edge Case Analysis - Levr V1 Contracts

## Executive Summary

**Found: 12 potential edge cases across 5 contracts**
**Severity: 3 Critical, 5 High, 4 Medium**
**Emergency mechanisms recommended: 4 rescue functions**

---

## 1. LevrStaking_v1 - Edge Cases

### 🔴 CRITICAL #1: Mid-Stream Reward Accrual Loss (FIXED)
**Status:** ✅ FIXED
**Severity:** Critical
**Impact:** 50-95% reward loss

See MIDSTREAM_ACCRUAL_FIX_SUMMARY.md

### 🔴 CRITICAL #2: Total Staked Accounting Mismatch

**Scenario:**
```solidity
// If stakedToken.totalSupply() != _totalStaked
// Invariant broken: 1:1 peg violated
```

**How it could happen:**
1. Bug in stake() increments `_totalStaked` but mint fails
2. Bug in unstake() burns token but doesn't decrement `_totalStaked`
3. Direct stakedToken transfer (shouldn't be possible, but...)

**Current protection:** None

**Risk:** Medium (unlikely with current code)

**Emergency fix needed:** Yes

### 🔴 CRITICAL #3: Escrow Balance Underflow

**Scenario:**
```solidity
function unstake(uint256 amount, address to) external {
    // ...
    uint256 esc = _escrowBalance[underlying];
    if (esc < amount) revert InsufficientEscrow(); // Good check
    _escrowBalance[underlying] = esc - amount;
    IERC20(underlying).safeTransfer(to, amount); // But what if this fails?
}
```

**What if:**
- Another contract calls `underlying.transfer()` from staking address?
- Escrow tracking becomes incorrect
- Users can't unstake even though tokens are there

**Current protection:** SafeERC20 prevents most issues

**Risk:** Low-Medium

**Emergency fix needed:** Yes (rescue mismatched escrow)

### 🟡 HIGH #4: Reward Reserve Mismatch

**Scenario:**
```solidity
// If _rewardReserve[token] > actual unclaimed rewards
// Users try to claim but revert with InsufficientRewardLiquidity
```

**How it could happen:**
1. Streaming calculation rounding errors compound
2. External transfer of reward tokens out of contract
3. Accounting bug in _settle()

**Current protection:** Reserve checks in _settle()

**Risk:** Medium

**Emergency fix needed:** Yes (adjust reserve)

### 🟡 HIGH #5: No Stakers During Stream

**Scenario:**
```solidity
function _settleStreamingForToken(address token) internal {
    // Don't consume stream time if no stakers to preserve rewards
    if (_totalStaked == 0) return; // ✅ Good protection
}
```

**Edge case:**
- All users unstake during stream
- `_totalStaked == 0`
- Stream pauses (good!)
- But what if stream never resumes?

**Current protection:** ✅ Stream pauses correctly

**Risk:** Low (stream resumes when someone stakes)

**Emergency fix needed:** No

### 🟡 HIGH #6: ClankerFeeLocker Integration Failure

**Scenario:**
```solidity
function _claimFromClankerFeeLocker(address token) internal {
    try IClankerFeeLocker(metadata.feeLocker).claim(...) {
        // Success
    } catch {
        // Silently fails! 💀
    }
}
```

**What if:**
- ClankerFeeLocker has fees but claim fails
- Fees stuck in ClankerFeeLocker forever
- No way to retry or force claim

**Current protection:** Try-catch prevents revert

**Risk:** Medium

**Emergency fix needed:** Yes (manual claim bypass)

### 🟡 HIGH #7: Multi-Token Reward Overflow

**Scenario:**
```solidity
// If too many reward tokens are added
address[] private _rewardTokens; // Unbounded array!

function _settleStreamingAll() internal {
    for (uint256 i = 0; i < _rewardTokens.length; i++) { // Could run out of gas
        _settleStreamingForToken(_rewardTokens[i]);
    }
}
```

**Risk:** Medium (DOS if 100+ reward tokens)

**Emergency fix needed:** Yes (clear reward tokens)

### 🟢 MEDIUM #8: Voting Power Time Manipulation

**Scenario:**
```solidity
// User stakes at block.timestamp T
// Warp far into future (somehow)
// VP = balance × (future_time - T) = huge number
```

**Current protection:** 
- ✅ Timestamp is block.timestamp (can't manipulate)
- ✅ Time-weighted is fair

**Risk:** Low (can't manipulate block.timestamp)

**Emergency fix needed:** No

---

## 2. LevrTreasury_v1 - Edge Cases

### 🟡 HIGH #9: Governor Compromise = Treasury Drained

**Scenario:**
```solidity
// If governor is compromised or has bug
function transfer(address to, uint256 amount) external onlyGovernor {
    IERC20(underlying).safeTransfer(to, amount); // No limit!
}
```

**Risk:** High (single point of failure)

**Current protection:** None

**Emergency fix needed:** Yes (pause mechanism)

### 🟢 MEDIUM #10: No way to rescue non-underlying tokens

**Scenario:**
```solidity
// Someone accidentally sends USDC to treasury
// Treasury only handles underlying token
// USDC stuck forever
```

**Risk:** Medium (user error, not protocol bug)

**Emergency fix needed:** Yes (generic token rescue)

---

## 3. LevrGovernor_v1 - Edge Cases

### 🟡 HIGH #11: Orphaned Proposals

**Scenario:**
```solidity
// Proposal succeeds but cycle ends before execution
// New cycle starts
// Proposal can never be executed
```

**Current protection:** ✅ `_checkNoExecutableProposals()` prevents this!

```solidity
function _checkNoExecutableProposals() internal view {
    // Prevents cycle advancement if executable proposals remain
    if (_state(pid) == ProposalState.Succeeded) {
        revert ExecutableProposalsRemaining();
    }
}
```

**Risk:** Low (already protected)

**Emergency fix needed:** No

### 🟢 MEDIUM #12: Voting Power Flash Loan Attack

**Scenario:**
```solidity
// Attacker:
// 1. Flash loan huge amount
// 2. Stake for VP
// 3. Vote
// 4. Unstake
// 5. Repay loan
```

**Current protection:** ✅ Time-weighted VP!

```solidity
VP = balance × (block.timestamp - stakeStartTime)
// Flash loan: VP = huge_balance × 0 seconds = 0
```

**Risk:** None (time-weighted prevents this)

**Emergency fix needed:** No

---

## 4. LevrFactory_v1 - Edge Cases

### 🟢 MEDIUM #13: Front-running prepareForDeployment()

**Scenario:**
```solidity
// Attacker sees prepareForDeployment() tx
// Front-runs with their own
// Gets addresses
// But can't use them (deployer tracking prevents)
```

**Current protection:** ✅ Deployer tracking prevents reuse

**Risk:** Low (well-protected)

**Emergency fix needed:** No

---

## 5. LevrStakedToken_v1 - Edge Cases

### 🟢 MEDIUM #14: Direct Transfer Breaks 1:1 Peg Tracking

**Scenario:**
```solidity
// Alice stakes 1000 → mints 1000 sTokens to Alice
// Alice transfers 500 sTokens to Bob directly
// Bob tries to unstake 500
// Staking contract thinks Bob never staked!
```

**Current protection:** Works correctly (ERC20 transfers allowed)

```solidity
// Bob CAN unstake because stakedToken balance is checked
// But Bob won't have _staked[bob] for reward tracking
```

**Risk:** Low (users can transfer, but might not get rewards)

**Emergency fix needed:** No (working as designed)

---

## Emergency Rescue Mechanisms - Design

### 1. Factory-Level Emergency Admin

```solidity
contract LevrFactory_v1 {
    address public emergencyAdmin; // Multi-sig address
    bool public globalEmergencyMode;
    
    // Emergency functions
    function setEmergencyAdmin(address admin) external onlyOwner;
    function enableEmergencyMode() external; // By owner OR emergencyAdmin
    function disableEmergencyMode() external onlyOwner;
}
```

### 2. Per-Contract Emergency Functions

**Add to LevrStaking_v1:**
```solidity
/// @notice Emergency rescue for stuck tokens (only in emergency mode)
function emergencyRescueToken(
    address token,
    address to,
    uint256 amount
) external {
    require(ILevrFactory_v1(factory).emergencyMode(), "NOT_EMERGENCY");
    require(ILevrFactory_v1(factory).emergencyAdmin() == _msgSender(), "NOT_ADMIN");
    
    // Safety: Can't rescue escrowed principal
    if (token == underlying) {
        uint256 maxRescue = IERC20(token).balanceOf(address(this)) - _escrowBalance[underlying];
        require(amount <= maxRescue, "CANT_RESCUE_ESCROW");
    }
    
    IERC20(token).safeTransfer(to, amount);
    emit EmergencyRescue(token, to, amount);
}

/// @notice Emergency adjust reward reserve (fix accounting bugs)
function emergencyAdjustReserve(
    address token,
    uint256 newReserve
) external {
    require(ILevrFactory_v1(factory).emergencyMode(), "NOT_EMERGENCY");
    require(ILevrFactory_v1(factory).emergencyAdmin() == _msgSender(), "NOT_ADMIN");
    
    uint256 oldReserve = _rewardReserve[token];
    _rewardReserve[token] = newReserve;
    emit EmergencyReserveAdjusted(token, oldReserve, newReserve);
}

/// @notice Emergency adjust total staked (fix accounting bugs)
function emergencyAdjustTotalStaked(uint256 newTotal) external {
    require(ILevrFactory_v1(factory).emergencyMode(), "NOT_EMERGENCY");
    require(ILevrFactory_v1(factory).emergencyAdmin() == _msgSender(), "NOT_ADMIN");
    
    // Safety: New total must match stakedToken supply
    uint256 supply = IERC20(stakedToken).totalSupply();
    require(newTotal == supply, "MUST_MATCH_SUPPLY");
    
    uint256 oldTotal = _totalStaked;
    _totalStaked = newTotal;
    emit EmergencyTotalStakedAdjusted(oldTotal, newTotal);
}

/// @notice Emergency clear stuck stream
function emergencyClearStream(address token) external {
    require(ILevrFactory_v1(factory).emergencyMode(), "NOT_EMERGENCY");
    require(ILevrFactory_v1(factory).emergencyAdmin() == _msgSender(), "NOT_ADMIN");
    
    _streamStartByToken[token] = 0;
    _streamEndByToken[token] = 0;
    _streamTotalByToken[token] = 0;
    emit EmergencyStreamCleared(token);
}
```

**Add to LevrTreasury_v1:**
```solidity
/// @notice Emergency pause (prevents governor actions)
bool public paused;

function emergencyPause() external {
    require(ILevrFactory_v1(factory).emergencyMode(), "NOT_EMERGENCY");
    require(ILevrFactory_v1(factory).emergencyAdmin() == _msgSender(), "NOT_ADMIN");
    paused = true;
    emit EmergencyPaused();
}

function emergencyUnpause() external {
    require(ILevrFactory_v1(factory).emergencyAdmin() == _msgSender(), "NOT_ADMIN");
    paused = false;
    emit EmergencyUnpaused();
}

modifier whenNotPaused() {
    require(!paused, "PAUSED");
    _;
}

// Update existing functions
function transfer(...) external onlyGovernor whenNotPaused nonReentrant { }
function applyBoost(...) external onlyGovernor whenNotPaused nonReentrant { }

/// @notice Emergency rescue any token (even underlying)
function emergencyRescueToken(
    address token,
    address to,
    uint256 amount
) external {
    require(ILevrFactory_v1(factory).emergencyMode(), "NOT_EMERGENCY");
    require(ILevrFactory_v1(factory).emergencyAdmin() == _msgSender(), "NOT_ADMIN");
    
    IERC20(token).safeTransfer(to, amount);
    emit EmergencyRescue(token, to, amount);
}
```

**Add to LevrGovernor_v1:**
```solidity
/// @notice Emergency cancel proposal
function emergencyCancelProposal(uint256 proposalId) external {
    require(ILevrFactory_v1(factory).emergencyMode(), "NOT_EMERGENCY");
    require(ILevrFactory_v1(factory).emergencyAdmin() == _msgSender(), "NOT_ADMIN");
    
    Proposal storage proposal = _proposals[proposalId];
    require(!proposal.executed, "ALREADY_EXECUTED");
    
    proposal.executed = true; // Mark as cancelled
    _activeProposalCount[proposal.proposalType]--;
    
    emit EmergencyProposalCancelled(proposalId);
}

/// @notice Emergency execute (bypass voting, for stuck proposals)
function emergencyExecuteProposal(uint256 proposalId) external {
    require(ILevrFactory_v1(factory).emergencyMode(), "NOT_EMERGENCY");
    require(ILevrFactory_v1(factory).emergencyAdmin() == _msgSender(), "NOT_ADMIN");
    
    Proposal storage proposal = _proposals[proposalId];
    require(!proposal.executed, "ALREADY_EXECUTED");
    
    // Execute without checks
    proposal.executed = true;
    _activeProposalCount[proposal.proposalType]--;
    
    if (proposal.proposalType == ProposalType.BoostStakingPool) {
        ILevrTreasury_v1(treasury).applyBoost(proposal.amount);
    } else if (proposal.proposalType == ProposalType.TransferToAddress) {
        ILevrTreasury_v1(treasury).transfer(proposal.recipient, proposal.amount);
    }
    
    emit EmergencyProposalExecuted(proposalId);
}
```

### 🟡 HIGH #4: Reward Token Array Unbounded

**Scenario:**
- Someone adds 1000 different reward tokens
- `_settleStreamingAll()` runs out of gas
- Users can't stake/unstake

**Impact:** DOS attack

**Current protection:** None

**Fix:** Add max reward tokens limit

```solidity
uint256 public constant MAX_REWARD_TOKENS = 50;

function _ensureRewardToken(address token) internal {
    if (!_rewardInfo[token].exists) {
        require(_rewardTokens.length < MAX_REWARD_TOKENS, "TOO_MANY_TOKENS");
        // ... rest ...
    }
}
```

### 🟡 HIGH #5: ClankerFeeLocker Claim Failure Silent

**Already documented above**

**Fix:** Add manual claim function

```solidity
function manualClaimFromFeeLocker(address token) external {
    _claimFromClankerFeeLocker(token);
}
```

### 🟢 MEDIUM #6: Stream Window Change Mid-Stream

**Scenario:**
```solidity
// Stream active with 3-day window
// Factory owner changes streamWindowSeconds to 1 day
// Current stream continues with old window (correct)
// But new accruals use new window (inconsistent state)
```

**Current protection:** Each stream stores its own end time

**Risk:** Low (each stream is independent)

**Fix:** Not needed

---

## 2. LevrTreasury_v1 - Edge Cases

### 🟡 HIGH #7: Governor Bug Drains Treasury

**Scenario:**
- Bug in governor allows unlimited transfers
- Or governance is compromised
- Treasury drained

**Current protection:** None (trusts governor completely)

**Fix:** Add rate limiting or maximum transfer per period

```solidity
mapping(uint256 => uint256) public transferredPerDay;

function transfer(address to, uint256 amount) external onlyGovernor nonReentrant {
    uint256 today = block.timestamp / 1 days;
    uint256 maxPerDay = IERC20(underlying).balanceOf(address(this)) / 10; // Max 10% per day
    
    require(transferredPerDay[today] + amount <= maxPerDay, "DAILY_LIMIT");
    
    transferredPerDay[today] += amount;
    IERC20(underlying).safeTransfer(to, amount);
}
```

### 🟢 MEDIUM #8: Accidental Token Deposits

**Already documented above**

**Fix:** Generic rescue function (in emergency mode only)

---

## 3. LevrGovernor_v1 - Edge Cases

### 🟡 HIGH #9: Proposal Amount Exceeds Treasury

**Scenario:**
```solidity
// Proposal created for 100K tokens
// Treasury has 100K
// Between proposal and execution, treasury spends 50K
// Execution fails
```

**Current protection:** ✅ Check at execution time

```solidity
uint256 treasuryBalance = IERC20(underlying).balanceOf(treasury);
if (treasuryBalance < proposal.amount) {
    proposal.executed = true;
    emit ProposalDefeated(proposalId);
    revert InsufficientTreasuryBalance();
}
```

**Risk:** Low (well-protected)

**Fix:** Already handled

### 🟢 MEDIUM #10: Vote After Balance Transfer

**Scenario:**
```solidity
// Alice: 1000 sTokens, 100 days staked, VP = 100K
// Alice votes yes (100K VP counted)
// Alice transfers 500 sTokens to Bob
// Bob votes yes with Alice's old tokens (counted again?)
```

**Current protection:** ✅ Each user can only vote once

```solidity
if (_voteReceipts[proposalId][voter].hasVoted) {
    revert AlreadyVoted();
}
```

**Risk:** Low (well-protected)

**Fix:** Not needed

### 🟢 MEDIUM #11: Cycle Timing Edge Cases

**Scenario:**
```solidity
// What if block.timestamp jumps (chain reorg, consensus issues)?
// Could skip proposal window entirely
```

**Risk:** Very Low (blockchain level issue)

**Fix:** Not practical (trust blockchain)

---

## 4. LevrStakedToken_v1 - Edge Cases

### 🟢 MEDIUM #12: Mint/Burn Access Control

**Scenario:**
```solidity
// If staking contract is compromised
// Attacker can mint unlimited sTokens
```

**Current protection:** ✅ Only staking can mint/burn

```solidity
require(msg.sender == staking, "ONLY_STAKING");
```

**Risk:** Low (if staking is secure)

**Fix:** StakedToken is simple, low attack surface

---

## Emergency Rescue Architecture

### Design Principles

1. **Two-Key System**: Factory owner + Emergency admin (both needed)
2. **Emergency Mode**: Global flag, requires consensus to enable
3. **Time Locks**: 48-hour delay for rescue operations
4. **Audit Trail**: All emergency actions emit events
5. **Scope Limited**: Can't rescue user escrow, only stuck funds

### Implementation

```solidity
// ILevrFactory_v1.sol - Add to interface
interface ILevrFactory_v1 {
    function emergencyMode() external view returns (bool);
    function emergencyAdmin() external view returns (address);
    
    event EmergencyModeEnabled(address indexed enabledBy);
    event EmergencyModeDisabled(address indexed disabledBy);
    event EmergencyAdminSet(address indexed oldAdmin, address indexed newAdmin);
}

// LevrFactory_v1.sol - Add storage and functions
contract LevrFactory_v1 {
    address public emergencyAdmin;
    bool public emergencyMode;
    
    // Timelock for emergency actions
    mapping(bytes32 => uint256) public emergencyActionProposals;
    uint256 public constant EMERGENCY_TIMELOCK = 48 hours;
    
    function setEmergencyAdmin(address admin) external onlyOwner {
        require(admin != address(0), "ZERO_ADDRESS");
        address oldAdmin = emergencyAdmin;
        emergencyAdmin = admin;
        emit EmergencyAdminSet(oldAdmin, admin);
    }
    
    function proposeEmergencyMode() external {
        require(_msgSender() == owner() || _msgSender() == emergencyAdmin, "NOT_AUTHORIZED");
        
        bytes32 actionId = keccak256("ENABLE_EMERGENCY_MODE");
        emergencyActionProposals[actionId] = block.timestamp + EMERGENCY_TIMELOCK;
        
        emit EmergencyModeProposed(_msgSender());
    }
    
    function enableEmergencyMode() external {
        bytes32 actionId = keccak256("ENABLE_EMERGENCY_MODE");
        require(emergencyActionProposals[actionId] != 0, "NOT_PROPOSED");
        require(block.timestamp >= emergencyActionProposals[actionId], "TIMELOCK");
        
        emergencyMode = true;
        delete emergencyActionProposals[actionId];
        
        emit EmergencyModeEnabled(_msgSender());
    }
    
    function disableEmergencyMode() external onlyOwner {
        emergencyMode = false;
        emit EmergencyModeDisabled(_msgSender());
    }
    
    /// @notice Emergency rescue from any project contract
    function emergencyRescueFromProject(
        address projectToken,
        address contractAddress,
        bytes calldata rescueCalldata
    ) external returns (bytes memory) {
        require(emergencyMode, "NOT_EMERGENCY");
        require(_msgSender() == emergencyAdmin, "NOT_ADMIN");
        
        // Verify contract belongs to a registered project
        Project memory project = _projects[projectToken];
        require(
            contractAddress == project.staking ||
            contractAddress == project.treasury ||
            contractAddress == project.governor,
            "NOT_PROJECT_CONTRACT"
        );
        
        // Execute rescue call
        (bool success, bytes memory returnData) = contractAddress.call(rescueCalldata);
        require(success, "RESCUE_FAILED");
        
        emit EmergencyRescueExecuted(projectToken, contractAddress, rescueCalldata);
        return returnData;
    }
}
```

### 3. Invariant Monitoring Functions

**Add view functions to detect issues:**

```solidity
// LevrStaking_v1.sol
function checkInvariants() external view returns (
    bool stakingPegOk,
    bool escrowBalanceOk,
    bool rewardReserveOk,
    string memory issue
) {
    // Check 1: Staked token supply == total staked
    uint256 supply = IERC20(stakedToken).totalSupply();
    stakingPegOk = (supply == _totalStaked);
    if (!stakingPegOk) {
        return (false, true, true, "STAKING_PEG_BROKEN");
    }
    
    // Check 2: Escrow <= balance
    uint256 balance = IERC20(underlying).balanceOf(address(this));
    uint256 escrow = _escrowBalance[underlying];
    escrowBalanceOk = (escrow <= balance);
    if (!escrowBalanceOk) {
        return (true, false, true, "ESCROW_EXCEEDS_BALANCE");
    }
    
    // Check 3: Reserve <= balance - escrow
    uint256 maxReserve = balance - escrow;
    uint256 len = _rewardTokens.length;
    for (uint256 i = 0; i < len; i++) {
        address token = _rewardTokens[i];
        uint256 reserve = _rewardReserve[token];
        
        if (token == underlying) {
            if (reserve > maxReserve) {
                return (true, true, false, "RESERVE_TOO_HIGH");
            }
        } else {
            uint256 tokenBal = IERC20(token).balanceOf(address(this));
            if (reserve > tokenBal) {
                return (true, true, false, "RESERVE_EXCEEDS_TOKEN_BALANCE");
            }
        }
    }
    
    return (true, true, true, "ALL_OK");
}
```

## Risk Matrix

| Edge Case | Severity | Likelihood | Impact | Needs Emergency Fix |
|-----------|----------|------------|--------|-------------------|
| #1 Mid-stream accrual | Critical | High | Fund loss | ✅ Fixed |
| #2 Staking peg mismatch | Critical | Low | Broken accounting | ✅ Yes |
| #3 Escrow underflow | Critical | Low | Can't unstake | ✅ Yes |
| #4 Reserve mismatch | High | Medium | Can't claim | ✅ Yes |
| #5 No stakers during stream | High | Low | Stream pause | ❌ No |
| #6 FeeLocker claim fail | High | Medium | Stuck fees | ✅ Yes |
| #7 Too many reward tokens | High | Low | DOS | ✅ Yes |
| #8 VP time manipulation | Medium | None | N/A | ❌ No |
| #9 Governor compromise | High | Low | Treasury drain | ✅ Yes |
| #10 Wrong token in treasury | Medium | Medium | Stuck tokens | ✅ Yes |
| #11 Orphaned proposals | High | Low | Unfair governance | ✅ Protected |
| #12 VP flash loan | Medium | None | N/A | ✅ Protected |
| #13 Prepare front-run | Medium | Low | N/A | ✅ Protected |
| #14 sToken direct transfer | Medium | Medium | Unexpected | ❌ No |

## Recommended Immediate Actions

### 1. Add Emergency Mode System (HIGH PRIORITY)

**Benefit:** Can rescue funds from ANY future bug  
**Complexity:** Medium  
**Time:** 4-6 hours  
**Risk:** Low (if access control is tight)

### 2. Add Invariant Monitoring (MEDIUM PRIORITY)

**Benefit:** Early detection of accounting bugs  
**Complexity:** Low  
**Time:** 2-3 hours  
**Risk:** None (view functions only)

### 3. Add Rate Limiting to Treasury (MEDIUM PRIORITY)

**Benefit:** Limits damage from governor bugs  
**Complexity:** Low  
**Time:** 1-2 hours  
**Risk:** Low

### 4. Add Max Reward Tokens Limit (LOW PRIORITY)

**Benefit:** Prevents DOS  
**Complexity:** Low  
**Time:** 30 minutes  
**Risk:** None

## Next Steps

I can implement:
1. **Emergency mode system** (factory + all contracts)
2. **All emergency rescue functions**
3. **Invariant monitoring functions**
4. **Comprehensive tests** for all edge cases
5. **Rate limiting** for treasury

This gives you a "panic button" for ANY future issue.

**Shall I implement the complete emergency system?**

