# External Audit 2 - Implementation Action Guide

## Instructions for AI Model to Fix All Issues

**Date Created:** October 30, 2025
**Purpose:** Guide a cheaper AI model to fix all issues found in external-2 audit
**Status:** Ready for implementation

---

## 📋 Table of Contents

1. [Codebase Structure Overview](#codebase-structure-overview)
2. [Critical Findings - MUST FIX IMMEDIATELY](#critical-findings---must-fix-immediately)
3. [High Severity Findings](#high-severity-findings)
4. [Medium Severity Findings](#medium-severity-findings)
5. [Low Severity Findings](#low-severity-findings)
6. [Test Files to Create](#test-files-to-create)
7. [Implementation Order](#implementation-order)
8. [Verification Checklist](#verification-checklist)

---

## 🗂️ Codebase Structure Overview

### Source Code Files

```
src/
├── LevrStaking_v1.sol              # Main staking contract (MOST CHANGES HERE)
├── LevrStakedToken_v1.sol          # Staked token (ERC20)
├── LevrGovernor_v1.sol             # Governance contract
├── LevrTreasury_v1.sol             # Treasury contract
├── LevrFactory_v1.sol              # Factory for deployments
├── LevrDeployer_v1.sol             # Deployer helper
├── LevrForwarder_v1.sol            # Meta-transaction forwarder
├── LevrFeeSplitter_v1.sol          # Fee splitter
├── LevrFeeSplitterFactory_v1.sol   # Fee splitter factory
├── libraries/
│   └── RewardMath.sol              # Reward calculation library (CRITICAL FIX)
├── base/
│   └── ERC2771ContextBase.sol      # Meta-transaction base
└── interfaces/
    ├── ILevrStaking_v1.sol
    ├── ILevrGovernor_v1.sol
    ├── ILevrStakedToken_v1.sol
    └── ... (other interfaces)
```

### Test File Structure

```
test/
├── unit/                           # Unit tests for individual contracts
│   ├── LevrStakingV1.t.sol
│   ├── LevrGovernorV1.t.sol
│   ├── LevrStakedTokenV1.t.sol
│   └── ... (32 test files)
├── e2e/                            # End-to-end integration tests
│   ├── LevrV1.Staking.t.sol
│   ├── LevrV1.Governance.t.sol
│   └── ... (6 test files)
├── mocks/                          # Mock contracts for testing
└── utils/                          # Test utilities
```

---

## 🔴 CRITICAL FINDINGS - MUST FIX IMMEDIATELY

### CRITICAL-1: Unvested Rewards Loss in Paused Active Streams

**Severity:** CRITICAL
**Impact:** 16-67% permanent fund loss
**Source:** `spec/external-2/CRITICAL_FINDINGS_POST_OCT29_CHANGES.md` Lines 14-226

#### Location to Fix

- **File:** `src/libraries/RewardMath.sol`
- **Lines:** 83-88

#### Current Buggy Code

```solidity
// Stream still active - calculate unvested based on elapsed time
uint256 elapsed = current - start;
uint256 vested = (total * elapsed) / duration;

// Return unvested portion
return total > vested ? total - vested : 0;
```

#### Problem Explanation

When a stream is paused (totalStaked = 0) but still active (current < streamEnd), the calculation incorrectly uses `current - start` instead of accounting for the pause. This causes unvested rewards to be calculated incorrectly, leading to permanent fund loss.

**Example:**

- Stream starts at T0 with 1000 WETH for 3 days
- At T0+1day: User unstakes all → totalStaked = 0, streaming pauses
- At T0+1.5days: New user stakes (first staker)
- Bug: calculates 1.5 days of vesting (500 WETH vested, 500 unvested)
- Correct: should be 1 day of vesting (333 WETH vested, 667 unvested)
- **Result: 167 WETH permanently lost!**

#### Fix to Implement

```solidity
// File: src/libraries/RewardMath.sol
// Replace lines 83-88 with:

// Stream still active - use last update if stream paused
// If last < current, stream is paused at 'last' (totalStaked = 0)
// Only vest up to pause point, not current time
uint64 effectiveTime = last < current ? last : current;
uint256 elapsed = effectiveTime > start ? effectiveTime - start : 0;
uint256 vested = (total * elapsed) / duration;

return total > vested ? total - vested : 0;
```

#### Test to Create

- **File:** `test/unit/LevrStakingV1.PausedStreamFirstStaker.t.sol` (NEW FILE)
- **Content:** See test code in CRITICAL_FINDINGS_POST_OCT29_CHANGES.md lines 269-359

---

### CRITICAL-2: Reentrancy in External Token Calls

**Severity:** CRITICAL
**Impact:** Fund loss, state corruption
**Source:** `spec/external-2/security-vulnerability-analysis.md` Lines 24-96

#### Location to Fix

- **File:** `src/LevrStaking_v1.sol`
- **Function:** `_claimFromClankerFeeLocker()`
- **Lines:** 602-645

#### Current Issue

External calls to `IClankerLpLocker` and `IClankerFeeLocker` happen before state is fully settled, allowing potential reentrancy attacks.

#### Fix to Implement

**Step 1:** Add balance verification

```solidity
// File: src/LevrStaking_v1.sol
// In function _claimFromClankerFeeLocker(address token)

function _claimFromClankerFeeLocker(address token) internal nonReentrant {
    // ADD THIS: Store balance before external calls
    uint256 balanceBefore = IERC20(token).balanceOf(address(this));

    // Existing code for metadata checks...
    ClankerTokenMetadata memory metadata = IClankerToken(underlying).metadata();

    // Existing LP locker collection
    if (metadata.lpLocker != address(0)) {
        try IClankerLpLocker(metadata.lpLocker).collectRewards(underlying) {
            // Successfully collected from LP locker
        } catch {
            // Ignore errors from LP locker
        }
    }

    // Existing fee locker claim
    if (availableFees > 0) {
        IClankerFeeLocker(metadata.feeLocker).claim(
            address(this),
            token
        );
    }

    // ADD THIS: Verify balance increased as expected
    uint256 balanceAfter = IERC20(token).balanceOf(address(this));
    require(balanceAfter >= balanceBefore, "BALANCE_MISMATCH");
}
```

**Step 2:** Ensure CEI (Checks-Effects-Interactions) pattern is followed

- State changes should happen BEFORE external calls
- Already has `nonReentrant` modifier - this is good

#### Test to Create

- **File:** `test/unit/LevrStakingV1.ReentrancyAttack.t.sol` (NEW FILE)
- Include test with malicious LP locker that attempts reentrancy

---

### CRITICAL-3: Stream Reset Timing Manipulation

**Severity:** CRITICAL
**Impact:** Front-running, unfair reward distribution
**Source:** `spec/external-2/security-vulnerability-analysis.md` Lines 99-187

#### Location to Fix

- **File:** `src/LevrStaking_v1.sol`
- **Function:** `stake()`
- **Lines:** 98-110

#### Current Issue

First staker can reset streams immediately, allowing front-running attacks where attacker stakes 1 wei before a large staker to capture disproportionate rewards.

#### Fix to Implement

**Step 1:** Add minimum stake amount

```solidity
// File: src/LevrStaking_v1.sol
// Add near top of contract with other constants

uint256 public constant MIN_STAKE_AMOUNT = 1000 * 1e18; // 1000 tokens minimum
```

**Step 2:** Add minimum stake check in stake() function

```solidity
// File: src/LevrStaking_v1.sol
// In stake() function, add after line 90 (after parameter validation)

function stake(uint256 amount) external nonReentrant {
    if (amount == 0) revert ZeroAmount();

    // ADD THIS:
    require(amount >= MIN_STAKE_AMOUNT, "AMOUNT_TOO_SMALL");

    // Rest of function...
}
```

**Step 3:** Add stream warmup period

```solidity
// File: src/LevrStaking_v1.sol
// Add constant:

uint256 public constant STREAM_WARMUP = 1 hours;

// Modify the first staker logic (lines 98-110):
if (isFirstStaker) {
    uint256 len = _rewardTokens.length;
    for (uint256 i = 0; i < len; i++) {
        address rt = _rewardTokens[i];
        uint256 available = _availableUnaccountedRewards(rt);
        if (available > 0) {
            // ADD: Credit rewards with warmup delay
            _creditRewardsWithDelay(rt, available, STREAM_WARMUP);
        }
    }
}

// ADD NEW FUNCTION:
function _creditRewardsWithDelay(address token, uint256 amount, uint256 delay) internal {
    RewardTokenState storage tokenState = _ensureRewardToken(token);

    _settleStreamingForToken(token);
    uint256 unvested = _calculateUnvested(token);

    // Reset stream starting AFTER warmup period
    uint32 window = ILevrFactory_v1(factory).streamWindowSeconds();
    _streamStart = uint64(block.timestamp + delay);
    _streamEnd = _streamStart + window;

    tokenState.streamTotal = amount + unvested;
    tokenState.lastUpdate = _streamStart;
    tokenState.reserve += amount;

    emit RewardsAccrued(token, amount, tokenState.accPerShare);
}
```

#### Test to Create

- **File:** `test/unit/LevrStakingV1.FirstStakerAttack.t.sol` (NEW FILE)
- Test front-running scenario
- Test minimum stake enforcement
- Test warmup period

---

### CRITICAL-4: Integer Precision Loss in Reward Calculations

**Severity:** CRITICAL
**Impact:** Permanent fund lockup, dust accumulation
**Source:** `spec/external-2/security-vulnerability-analysis.md` Lines 190-272

#### Location to Fix

- **File:** `src/libraries/RewardMath.sol`
- **Lines:** Multiple functions

#### Current Issue

Using 1e18 precision (ACC_SCALE) can lead to significant rounding errors with small stakes, causing permanent fund lockup.

#### Fix to Implement

**Option 1: Higher Precision (RECOMMENDED)**

```solidity
// File: src/libraries/RewardMath.sol
// Change line 9:

// OLD:
uint256 internal constant ACC_SCALE = 1e18;

// NEW:
uint256 internal constant ACC_SCALE = 1e27; // Higher precision
```

**Option 2: Minimum Stake Amount (Already covered in CRITICAL-3)**
This is already addressed by adding MIN_STAKE_AMOUNT.

**Combined Approach (BEST):**

- Increase ACC_SCALE to 1e27
- Enforce MIN_STAKE_AMOUNT of 1000 tokens
- This combination prevents both small stake attacks and reduces precision loss

#### Test to Create

- **File:** `test/unit/LevrStakingV1.PrecisionLoss.t.sol` (NEW FILE)
- Test with small stakes (if they pass MIN_STAKE_AMOUNT)
- Test accumulated rounding errors over many operations
- Verify dust doesn't accumulate

---

## 🟠 HIGH SEVERITY FINDINGS

### HIGH-1: Unbounded Loop in \_settleStreamingAll()

**Severity:** HIGH
**Impact:** DOS attack via gas exhaustion
**Source:** `spec/external-2/security-vulnerability-analysis.md` Lines 277-340

#### Location to Fix

- **File:** `src/LevrStaking_v1.sol`
- **Function:** `_settleStreamingAll()`
- **Lines:** 798-803

#### Current Code

```solidity
function _settleStreamingAll() internal {
    uint256 len = _rewardTokens.length;
    for (uint256 i = 0; i < len; i++) {
        _settleStreamingForToken(_rewardTokens[i]);
    }
}
```

#### Problem

With 50+ reward tokens, gas cost can exceed block limits.

#### Fix to Implement

**Option 1: Add max tokens limit (RECOMMENDED)**

```solidity
// File: src/LevrStaking_v1.sol
// Add constant:

uint256 public constant MAX_TOKENS_PER_SETTLE = 20;

function _settleStreamingAll() internal {
    uint256 len = _rewardTokens.length;
    require(len <= MAX_TOKENS_PER_SETTLE, "TOO_MANY_TOKENS");

    for (uint256 i = 0; i < len; i++) {
        _settleStreamingForToken(_rewardTokens[i]);
    }
}
```

**Option 2: Lazy settlement (more complex)**
Only settle tokens that are being claimed, not all tokens.

#### Test to Create

- **File:** `test/unit/LevrStakingV1.TokenDoS.t.sol` (NEW FILE)
- Test with max number of tokens
- Test gas consumption
- Test DOS scenario

---

### HIGH-2: Unchecked Return Values from External Calls

**Severity:** HIGH
**Impact:** State corruption from failed external calls
**Source:** `spec/external-2/security-vulnerability-analysis.md` Lines 343-400

#### Location to Fix

- **File:** `src/LevrStaking_v1.sol`
- **Lines:** 620-643

#### Fix to Implement

```solidity
// File: src/LevrStaking_v1.sol
// Add event at top of contract:

event ClaimFailed(address indexed locker, address indexed token, string reason);

// Modify _claimFromClankerFeeLocker function:

function _claimFromClankerFeeLocker(address token) internal {
    // ... metadata checks ...

    uint256 balanceBefore = IERC20(token).balanceOf(address(this));

    if (metadata.lpLocker != address(0)) {
        try IClankerLpLocker(metadata.lpLocker).collectRewards(underlying) {
            // Verify balance increased
            uint256 balanceAfter = IERC20(token).balanceOf(address(this));
            if (balanceAfter <= balanceBefore) {
                emit ClaimFailed(metadata.lpLocker, token, "NO_BALANCE_INCREASE");
            }
        } catch (bytes memory reason) {
            emit ClaimFailed(metadata.lpLocker, token, string(reason));
        }
    }

    // ... rest of function ...
}
```

#### Test to Create

- Update existing tests to verify events are emitted on failure

---

### HIGH-3: Access Control Bypass via Meta-Transactions

**Severity:** HIGH
**Impact:** Complete authorization bypass if forwarder is malicious
**Source:** `spec/external-2/security-vulnerability-analysis.md` Lines 403-461

#### Location to Fix

- **File:** Multiple files (all contracts with ERC2771ContextBase)
- **Files to modify:**
  - `src/LevrStaking_v1.sol`
  - `src/LevrGovernor_v1.sol`
  - `src/LevrTreasury_v1.sol`
  - `src/LevrFactory_v1.sol`
  - `src/LevrStakedToken_v1.sol`

#### Fix to Implement

**Step 1: Add forwarder validation in constructors**

```solidity
// File: src/LevrStaking_v1.sol (and all other contracts)
// In constructor:

constructor(address trustedForwarder) ERC2771ContextBase(trustedForwarder) {
    require(trustedForwarder != address(0), "ZERO_FORWARDER");

    // Verify forwarder is a contract
    require(trustedForwarder.code.length > 0, "FORWARDER_NOT_CONTRACT");
}
```

**Step 2: Document which forwarder to use**
Use OpenZeppelin's MinimalForwarder (already audited).

**Step 3: Add to deployment scripts**
Verify forwarder address before deployment.

#### Test to Create

- **File:** `test/unit/LevrForwarderV1.Security.t.sol` (ALREADY EXISTS - update it)
- Test zero address rejection
- Test non-contract rejection
- Test with valid forwarder

---

### HIGH-4: Reward Theft via Token Whitelisting

**Severity:** HIGH
**Impact:** Compromised admin can whitelist malicious tokens
**Source:** `spec/external-2/security-vulnerability-analysis.md` Lines 464-541

#### Location to Fix

- **File:** `src/LevrStaking_v1.sol`
- **Function:** `whitelistToken()`
- **Lines:** 269-294

#### Fix to Implement

**Option 1: Add timelock (RECOMMENDED)**

```solidity
// File: src/LevrStaking_v1.sol
// Add state variables:

mapping(address => uint256) public whitelistRequestTime;
uint256 public constant WHITELIST_TIMELOCK = 7 days;
mapping(address => bool) public whitelistPending;

// Add event:
event WhitelistRequested(address indexed token, uint256 executeAfter);
event WhitelistExecuted(address indexed token);

// Replace whitelistToken with two-step process:

function requestWhitelistToken(address token) external {
    if (token == address(0)) revert ZeroAddress();

    address tokenAdmin = IClankerToken(underlying).admin();
    require(_msgSender() == tokenAdmin, "ONLY_TOKEN_ADMIN");

    whitelistRequestTime[token] = block.timestamp;
    whitelistPending[token] = true;

    emit WhitelistRequested(token, block.timestamp + WHITELIST_TIMELOCK);
}

function executeWhitelistToken(address token) external nonReentrant {
    require(whitelistPending[token], "NO_PENDING_REQUEST");
    require(
        block.timestamp >= whitelistRequestTime[token] + WHITELIST_TIMELOCK,
        "TIMELOCK_NOT_EXPIRED"
    );

    // Validate token is ERC20
    require(_isValidToken(token), "INVALID_TOKEN");

    RewardTokenState storage tokenState = _tokenState[token];
    if (tokenState.exists) revert TokenAlreadyExists();

    tokenState.whitelisted = true;
    tokenState.exists = true;

    whitelistPending[token] = false;

    emit WhitelistExecuted(token);
}

function _isValidToken(address token) internal view returns (bool) {
    try IERC20(token).totalSupply() returns (uint256 supply) {
        return supply > 0;
    } catch {
        return false;
    }
}
```

#### Test to Create

- **File:** `test/unit/LevrStakingV1.WhitelistSecurity.t.sol` (NEW FILE)
- Test timelock enforcement
- Test token validation
- Test malicious token rejection

---

### HIGH-5: Voting Power Manipulation via Flash Loans

**Severity:** HIGH
**Impact:** Flash loans can game governance voting
**Source:** `spec/external-2/security-vulnerability-analysis.md` Lines 544-653

#### Location to Fix

- **File:** `src/LevrGovernor_v1.sol`
- **Function:** `getVotingPower()`
- **Lines:** 884-898

#### Fix to Implement

**Implement checkpoint-based voting:**

```solidity
// File: src/LevrGovernor_v1.sol
// Add structs and state:

struct Checkpoint {
    uint64 fromBlock;
    uint192 votes;
}

mapping(address => Checkpoint[]) public checkpoints;
uint256 public constant MIN_VOTING_DELAY = 1 days;

// Add function to write checkpoints (called when stake changes):
function _writeCheckpoint(address user, uint192 newVotes) internal {
    uint256 nCheckpoints = checkpoints[user].length;

    if (nCheckpoints > 0 && checkpoints[user][nCheckpoints - 1].fromBlock == block.number) {
        // Update current block checkpoint
        checkpoints[user][nCheckpoints - 1].votes = newVotes;
    } else {
        // Create new checkpoint
        checkpoints[user].push(Checkpoint({
            fromBlock: uint64(block.number),
            votes: newVotes
        }));
    }
}

// Replace getVotingPower with getPriorVotes:
function getPriorVotes(address account, uint256 blockNumber) external view returns (uint192) {
    require(blockNumber < block.number, "NOT_YET_DETERMINED");
    require(block.number - blockNumber >= MIN_VOTING_DELAY, "TOO_RECENT");

    uint256 nCheckpoints = checkpoints[account].length;
    if (nCheckpoints == 0) return 0;

    // Most recent checkpoint
    if (checkpoints[account][nCheckpoints - 1].fromBlock <= blockNumber) {
        return checkpoints[account][nCheckpoints - 1].votes;
    }

    // Binary search for checkpoint
    // ... (implement binary search) ...
}
```

**IMPORTANT:** This also requires updating `LevrStaking_v1.sol` to call `_writeCheckpoint()` in the governor whenever balance changes.

#### Test to Create

- **File:** `test/unit/LevrGovernorV1.FlashLoanAttack.t.sol` (NEW FILE)
- Test flash loan voting attempt
- Test checkpoint system
- Test minimum delay enforcement

---

## 🟡 MEDIUM SEVERITY FINDINGS

### MEDIUM-1: Staked Token Transfer Design Inconsistency

**Severity:** MEDIUM
**Impact:** Design clarity, potential dead code
**Source:** `spec/external-2/NEW_SECURITY_FINDINGS_OCT_2025.md` Lines 24-116

#### Location to Check

- **File:** `src/LevrStakedToken_v1.sol`
- **Line:** 51

#### Current Code

```solidity
require(from == address(0) || to == address(0), 'STAKED_TOKENS_NON_TRANSFERABLE');
```

This BLOCKS all transfers (only minting/burning allowed).

#### Decision Required

**IMPORTANT:** Check with team on design intent. Then choose one:

**Option A: Keep Transfers Blocked**

- Keep line 51 as-is
- Remove unused transfer callback functions from `LevrStaking_v1.sol`
- Update documentation to reflect non-transferability

**Option B: Enable Transfers**

- Remove line 51 `require` statement
- Verify transfer callback functions work
- Re-run transfer tests

#### Action

1. **DO NOT MAKE CHANGES** until team confirms intent
2. Document decision in `spec/CHANGELOG.md`
3. Update `spec/AUDIT.md` with final decision

---

### MEDIUM-2: Reward Token Slot DoS Attack

**Severity:** MEDIUM
**Impact:** Protocol reward distribution blocked
**Source:** `spec/external-2/NEW_SECURITY_FINDINGS_OCT_2025.md` Lines 119-285

#### Location to Fix

- **File:** `src/LevrStaking_v1.sol`
- **Function:** `_creditRewards()`

#### Problem

Attacker can fill all 50 reward token slots with 1 wei of dust tokens, blocking legitimate reward tokens.

#### Fix to Implement

```solidity
// File: src/LevrStaking_v1.sol
// Add constant near top:

uint256 public constant MIN_REWARD_AMOUNT = 1e15; // 0.001 tokens (18 decimals)

// Add check in _creditRewards function (before _ensureRewardToken call):

function _creditRewards(address token, uint256 amount) internal {
    // ADD THIS:
    require(amount >= MIN_REWARD_AMOUNT, "REWARD_TOO_SMALL");

    RewardTokenState storage tokenState = _ensureRewardToken(token);
    // ... rest of function
}
```

#### Test to Create

- **File:** `test/unit/LevrStakingV1.RewardTokenDoS.t.sol` (NEW FILE)
- Test rejection of dust amounts
- Test DoS attack scenario is prevented
- Test legitimate rewards still work

---

### MEDIUM-3: Trusted Forwarder Configuration Risk

**Severity:** MEDIUM
**Impact:** Deployment configuration error
**Source:** `spec/external-2/NEW_SECURITY_FINDINGS_OCT_2025.md` Lines 306-455

#### Already Covered

This is similar to HIGH-3. Ensure:

1. Constructor validation (covered above)
2. Use OpenZeppelin MinimalForwarder
3. Document in deployment scripts

---

### MEDIUM-4: Missing Event Emission in Critical State Changes

**Severity:** MEDIUM
**Impact:** Difficulty monitoring contract health
**Source:** `spec/external-2/security-vulnerability-analysis.md` Lines 688-712

#### Location to Fix

- **File:** `src/LevrStaking_v1.sol`
- **Lines:** 733, 750 (debt updates)

#### Fix to Implement

```solidity
// File: src/LevrStaking_v1.sol
// Add events near top:

event DebtIncreased(address indexed user, address indexed token, int256 amount);
event DebtUpdated(address indexed user, address indexed token, int256 newDebt);

// In _increaseDebtForAll function (around line 733):
for (uint256 i = 0; i < len; i++) {
    address rt = _rewardTokens[i];
    uint256 accumulated = RewardMath.calculateAccumulated(...);
    _userRewards[account][rt].debt += int256(accumulated);

    // ADD THIS:
    emit DebtIncreased(account, rt, int256(accumulated));
}

// In _settle function (around line 750):
_userRewards[account][rt].debt = int256(accumulated);

// ADD THIS:
emit DebtUpdated(account, rt, int256(accumulated));
```

#### Test Updates

- Update existing tests to check for event emissions

---

### MEDIUM-5: Lack of Pause Mechanism

**Severity:** MEDIUM
**Impact:** Cannot stop operations during emergency
**Source:** `spec/external-2/security-vulnerability-analysis.md` Lines 715-743

#### Location to Fix

- **File:** `src/LevrStaking_v1.sol`

#### Fix to Implement

```solidity
// File: src/LevrStaking_v1.sol
// Add import:
import "@openzeppelin/contracts/security/Pausable.sol";

// Update contract declaration:
contract LevrStaking_v1 is ERC2771ContextBase, ReentrancyGuard, Pausable {

    // ... existing code ...

    // Add whenNotPaused to critical functions:

    function stake(uint256 amount) external nonReentrant whenNotPaused {
        // ... existing code
    }

    function unstake(uint256 amount, address to) external nonReentrant whenNotPaused {
        // ... existing code
    }

    function claimRewards(
        address[] memory tokens,
        address to
    ) external nonReentrant whenNotPaused {
        // ... existing code
    }

    // Add pause/unpause functions:
    function emergencyPause() external {
        address governor = ILevrFactory_v1(factory).governor();
        require(_msgSender() == governor, "ONLY_GOVERNANCE");
        _pause();
    }

    function emergencyUnpause() external {
        address governor = ILevrFactory_v1(factory).governor();
        require(_msgSender() == governor, "ONLY_GOVERNANCE");
        _unpause();
    }
}
```

#### Test to Create

- **File:** `test/unit/LevrStakingV1.EmergencyPause.t.sol` (NEW FILE)
- Test pause/unpause functionality
- Test operations blocked when paused
- Test governance-only access

---

### MEDIUM-6: Potential Reward Reserve Depletion

**Severity:** MEDIUM
**Impact:** Users cannot unstake if rewards cannot be paid
**Source:** `spec/external-2/security-vulnerability-analysis.md` Lines 746-767

#### Location to Fix

- **File:** `src/LevrStaking_v1.sol`
- **Function:** `_settle()`
- **Lines:** 783-786

#### Current Code

```solidity
if (tokenState.reserve < balanceBasedClaimable)
    revert InsufficientRewardLiquidity();
```

#### Fix to Implement

**Allow unstaking even if rewards can't be paid:**

```solidity
// File: src/LevrStaking_v1.sol
// Replace the revert with graceful handling:

if (tokenState.reserve < balanceBasedClaimable) {
    // Transfer what's available, mark rest as pending
    uint256 available = tokenState.reserve;
    uint256 shortfall = balanceBasedClaimable - available;

    _userRewards[account][rt].pending += shortfall;
    tokenState.reserve = 0;

    if (available > 0) {
        IERC20(rt).safeTransfer(to, available);
        emit RewardsPaid(account, rt, available);
    }

    emit RewardShortfall(account, rt, shortfall);
} else {
    // Normal path - full payment
    tokenState.reserve -= balanceBasedClaimable;
    IERC20(rt).safeTransfer(to, balanceBasedClaimable);
    emit RewardsPaid(account, rt, balanceBasedClaimable);
}
```

**Also add event:**

```solidity
event RewardShortfall(address indexed user, address indexed token, uint256 amount);
```

#### Test to Create

- **File:** `test/unit/LevrStakingV1.RewardReserveDepletion.t.sol` (NEW FILE)
- Test unstake when reserve insufficient
- Test pending rewards accumulation
- Test claiming pending when reserve refilled

---

## 🟢 LOW SEVERITY FINDINGS

### LOW-1: Missing Explicit Division-by-Zero Checks

**Severity:** LOW
**Impact:** Defense-in-depth improvement
**Source:** `spec/external-2/NEW_SECURITY_FINDINGS_OCT_2025.md` Lines 458-574

#### Location to Fix

- **File:** `src/libraries/RewardMath.sol`
- Multiple functions

#### Fix to Implement

```solidity
// File: src/libraries/RewardMath.sol

function calculateAccPerShare(...) internal pure returns (uint256 newAcc) {
    if (vestAmount == 0 || totalStaked == 0) return currentAcc;

    // ADD THIS:
    require(totalStaked != 0, "DIVISION_BY_ZERO");

    return currentAcc + (vestAmount * ACC_SCALE) / totalStaked;
}

function calculateVestedAmount(...) internal pure returns (uint256, uint64) {
    // ... existing code ...
    uint256 duration = end - start;

    // ADD THIS:
    require(duration != 0, "ZERO_DURATION");

    if (duration == 0 || total == 0) return (0, to);
    vested = (total * (to - from)) / duration;
}
```

#### Test to Create

- **File:** `test/unit/RewardMath.DivisionSafety.t.sol` (NEW FILE)
- Test zero checks trigger correctly
- Test edge cases

---

### LOW-2: Floating Pragma

**Severity:** LOW
**Impact:** Compiler version inconsistency
**Source:** `spec/external-2/security-vulnerability-analysis.md` Lines 772-783

#### Location to Fix

- **File:** All `.sol` files
- **Line:** pragma declaration (usually line 2)

#### Fix to Implement

```solidity
// Change from:
pragma solidity ^0.8.30;

// To:
pragma solidity 0.8.30;
```

**Files to update:**

- `src/LevrStaking_v1.sol`
- `src/LevrGovernor_v1.sol`
- `src/LevrTreasury_v1.sol`
- `src/LevrFactory_v1.sol`
- `src/LevrStakedToken_v1.sol`
- `src/LevrDeployer_v1.sol`
- `src/LevrForwarder_v1.sol`
- `src/LevrFeeSplitter_v1.sol`
- `src/LevrFeeSplitterFactory_v1.sol`
- `src/libraries/RewardMath.sol`
- `src/base/ERC2771ContextBase.sol`
- All interface files in `src/interfaces/`

#### No Test Needed

This is a compiler directive change.

---

### LOW-3: Magic Numbers in Code

**Severity:** LOW
**Impact:** Code readability
**Source:** `spec/external-2/security-vulnerability-analysis.md` Lines 785-799

#### Location to Fix

- **File:** Multiple files
- **Lines:** Various

#### Fix to Implement

```solidity
// File: src/LevrStaking_v1.sol and src/LevrGovernor_v1.sol
// Add constants near top:

uint256 public constant SECONDS_PER_DAY = 86400;
uint256 public constant BASIS_POINTS = 10_000;
uint256 public constant PRECISION = 1e18;

// Then replace magic numbers:
// Replace 86400 with SECONDS_PER_DAY
// Replace 10000 with BASIS_POINTS
// Replace 1e18 with PRECISION
```

#### No Test Needed

This is a code style improvement.

---

## 📝 TEST FILES TO CREATE

### New Test Files Required

1. **test/unit/LevrStakingV1.PausedStreamFirstStaker.t.sol**
   - Purpose: Test CRITICAL-1 fix
   - Tests paused stream → first staker scenario
   - Tests unvested calculation correctness

2. **test/unit/LevrStakingV1.ReentrancyAttack.t.sol**
   - Purpose: Test CRITICAL-2 fix
   - Tests reentrancy protection in external calls
   - Tests balance verification

3. **test/unit/LevrStakingV1.FirstStakerAttack.t.sol**
   - Purpose: Test CRITICAL-3 fix
   - Tests front-running prevention
   - Tests minimum stake enforcement
   - Tests warmup period

4. **test/unit/LevrStakingV1.PrecisionLoss.t.sol**
   - Purpose: Test CRITICAL-4 fix
   - Tests rounding error accumulation
   - Tests with different ACC_SCALE values

5. **test/unit/LevrStakingV1.TokenDoS.t.sol**
   - Purpose: Test HIGH-1 fix
   - Tests gas limits with many tokens
   - Tests max token enforcement

6. **test/unit/LevrStakingV1.WhitelistSecurity.t.sol**
   - Purpose: Test HIGH-4 fix
   - Tests timelock enforcement
   - Tests token validation

7. **test/unit/LevrGovernorV1.FlashLoanAttack.t.sol**
   - Purpose: Test HIGH-5 fix
   - Tests checkpoint voting system
   - Tests flash loan prevention

8. **test/unit/LevrStakingV1.RewardTokenDoS.t.sol**
   - Purpose: Test MEDIUM-2 fix
   - Tests dust rejection
   - Tests minimum reward amount

9. **test/unit/LevrStakingV1.EmergencyPause.t.sol**
   - Purpose: Test MEDIUM-5 fix
   - Tests pause/unpause mechanism
   - Tests governance-only access

10. **test/unit/LevrStakingV1.RewardReserveDepletion.t.sol**
    - Purpose: Test MEDIUM-6 fix
    - Tests graceful handling of insufficient reserves
    - Tests pending rewards mechanism

11. **test/unit/RewardMath.DivisionSafety.t.sol**
    - Purpose: Test LOW-1 fix
    - Tests division by zero protection

### Existing Test Files to Update

1. **test/unit/LevrForwarderV1.t.sol**
   - Add tests for constructor validation (HIGH-3)

2. **test/unit/LevrStakingV1.t.sol**
   - Add tests for event emissions (MEDIUM-4)
   - Add tests for new constants

3. **test/e2e/LevrV1.Staking.t.sol**
   - Update to test with new minimum stake amounts
   - Update to test new ACC_SCALE precision

---

## 🔢 IMPLEMENTATION ORDER

Implement fixes in this order to minimize conflicts:

### Phase 1: Library & Core Fixes (Week 1)

1. ✅ **CRITICAL-1**: Fix RewardMath.sol unvested calculation
2. ✅ **CRITICAL-4**: Increase ACC_SCALE to 1e27
3. ✅ **LOW-1**: Add explicit division checks
4. ✅ **LOW-2**: Fix floating pragma in all files
5. ✅ **LOW-3**: Replace magic numbers with constants

### Phase 2: Staking Contract Security (Week 1-2)

6. ✅ **CRITICAL-2**: Add reentrancy protection & balance verification
7. ✅ **CRITICAL-3**: Add minimum stake & warmup period
8. ✅ **HIGH-1**: Add max tokens limit
9. ✅ **HIGH-2**: Add external call verification & events
10. ✅ **MEDIUM-2**: Add minimum reward amount
11. ✅ **MEDIUM-4**: Add comprehensive events
12. ✅ **MEDIUM-5**: Add pause mechanism
13. ✅ **MEDIUM-6**: Fix reserve depletion handling

### Phase 3: Access Control & Governance (Week 2)

14. ✅ **HIGH-3**: Add forwarder validation
15. ✅ **HIGH-4**: Add whitelist timelock
16. ✅ **HIGH-5**: Implement checkpoint voting

### Phase 4: Testing (Week 2-3)

17. ✅ Create all new test files
18. ✅ Update existing test files
19. ✅ Run full test suite: `forge test -vvv`
20. ✅ Verify test coverage: `forge coverage`

### Phase 5: Documentation (Week 3)

21. ✅ Update `spec/AUDIT.md` with fixes
22. ✅ Update `spec/CHANGELOG.md`
23. ✅ Update `spec/HISTORICAL_FIXES.md`
24. ✅ Update README.md if needed

---

## ✅ VERIFICATION CHECKLIST

After implementing all fixes, verify:

### Code Quality

- [ ] All files use `pragma solidity 0.8.30;` (no caret)
- [ ] No magic numbers remain (all replaced with constants)
- [ ] All functions have NatSpec comments
- [ ] No compiler warnings

### Security Fixes

- [ ] RewardMath.sol uses effectiveTime for paused streams
- [ ] ACC_SCALE is 1e27
- [ ] MIN_STAKE_AMOUNT is 1000 \* 1e18
- [ ] STREAM_WARMUP is 1 hour
- [ ] MIN_REWARD_AMOUNT is 1e15
- [ ] MAX_TOKENS_PER_SETTLE is 20
- [ ] Pausable is implemented
- [ ] Checkpoint voting is implemented
- [ ] Whitelist has 7-day timelock
- [ ] All external calls verify balances
- [ ] All state changes emit events

### Testing

- [ ] All 11 new test files created
- [ ] All existing tests still pass
- [ ] Run: `forge test -vvv` - all tests pass
- [ ] Run: `forge coverage` - coverage > 95%
- [ ] Run specific critical tests:
  - `forge test --match-test test_CRITICAL -vvv`
  - `forge test --match-test test_pausedStream -vvv`
  - `forge test --match-test test_reentrancy -vvv`

### Gas Optimization

- [ ] Check gas usage with many tokens: should revert if > MAX_TOKENS_PER_SETTLE
- [ ] Verify stake() gas cost with 20 tokens < 2M gas
- [ ] Verify unstake() gas cost with 20 tokens < 2M gas

### Integration

- [ ] LevrStaking_v1 calls governor's \_writeCheckpoint() on stake/unstake
- [ ] Governor's getPriorVotes() works correctly
- [ ] Factory deploys contracts with validated forwarder
- [ ] All contracts properly initialized via factory

### Documentation

- [ ] AUDIT.md updated with "EXTERNAL_AUDIT_2 - COMPLETED"
- [ ] CHANGELOG.md lists all changes
- [ ] HISTORICAL_FIXES.md documents bugs fixed
- [ ] Each fix references this document

---

## 📚 KEY CONCEPTS FOR AI MODEL

### Understanding the Staking System

**Core Mechanism:**

1. Users stake `underlying` token → get `stakedToken` (ERC20)
2. Fees accumulate in contract
3. Fees are "streamed" over time (default 7 days)
4. Rewards accrue per share: `accPerShare` increases as stream vests
5. User claimable = (balance × accPerShare / ACC_SCALE) - debt

**Key Variables:**

- `_totalStaked`: Total amount of underlying staked
- `_escrowBalance[underlying]`: Tracks staked principal (separate from rewards)
- `_streamStart` / `_streamEnd`: Global stream window
- `tokenState.accPerShare`: Accumulated rewards per share for each token
- `tokenState.reserve`: Total rewards reserved for distribution
- `userRewards.debt`: Prevents double-claiming
- `userRewards.pending`: Rewards from previous unstakes

**Critical Invariants:**

1. `_escrowBalance[underlying] == _totalStaked` (always)
2. `sum(all_claimable) <= tokenState.reserve` (always)
3. `accPerShare` never decreases (always)
4. When `totalStaked == 0`, streaming pauses

### Understanding the Bug in CRITICAL-1

**The Paused Stream Bug:**

When `totalStaked` becomes 0, streaming PAUSES. The `lastUpdate` timestamp marks when pausing occurred.

**Scenario:**

```
T0: Stream starts (1000 tokens, 3 days)
T1 (1 day later): User unstakes all → totalStaked = 0
    - lastUpdate = T1
    - 333 tokens vested so far
    - 667 tokens should remain unvested
T2 (1.5 days later): New user stakes (first staker)
    - current time = T0 + 1.5 days
    - streamEnd = T0 + 3 days
    - current < streamEnd → stream "still active"
```

**Buggy Code calculates:**

```solidity
elapsed = current - start = 1.5 days
vested = (1000 * 1.5) / 3 = 500 tokens
unvested = 1000 - 500 = 500 tokens ❌ WRONG
```

**Correct calculation should be:**

```solidity
effectiveTime = min(last, current) = T1 (lastUpdate when paused)
elapsed = effectiveTime - start = 1 day
vested = (1000 * 1) / 3 = 333 tokens
unvested = 1000 - 333 = 667 tokens ✓ CORRECT
```

**Result of bug:** 167 tokens permanently lost!

### Understanding Checkpoint Voting

**Problem:** Flash loans allow instant voting power manipulation.

**Solution:** Checkpoints record voting power at each block.

- Voting uses power from PAST block (e.g., proposal start block)
- Flash loan in current block doesn't affect past voting power
- Minimum delay (1 day) ensures checkpoints are stable

**Implementation:**

1. When stake/unstake happens, write checkpoint for that user
2. Checkpoint records: block number + voting power at that block
3. When voting, look up checkpoint from proposal start block
4. Flash loan can't manipulate historical checkpoints

---

## 🚨 IMPORTANT REMINDERS

### For the AI Model Implementing Fixes:

1. **Read the full context** of each file before making changes
2. **Preserve existing functionality** - don't break working code
3. **Follow existing code style** - match indentation, naming, etc.
4. **Add comments** explaining WHY fixes were made
5. **Run tests after each change** - don't accumulate errors
6. **Check imports** - add OpenZeppelin imports where needed
7. **Emit events** for all state changes
8. **Use SafeERC20** for all token transfers
9. **Add NatSpec** comments for new functions
10. **Reference this document** in code comments: `// Fix for EXTERNAL_AUDIT_2_ACTIONS.md CRITICAL-1`

### Testing Commands

```bash
# Run all tests
forge test -vvv

# Run specific test file
forge test --match-path test/unit/LevrStakingV1.PausedStreamFirstStaker.t.sol -vvv

# Run tests matching pattern
forge test --match-test test_CRITICAL -vvv

# Check coverage
forge coverage

# Check gas usage
forge test --gas-report
```

### Common Pitfalls to Avoid

1. **Don't change function signatures** without updating interfaces
2. **Don't remove existing events** - only add new ones
3. **Don't change storage layout** - order matters for upgrades
4. **Don't add storage variables** in middle of existing ones
5. **Don't break existing tests** - fix them or understand why they fail
6. **Don't skip the warmup period** - it's critical for security
7. **Don't use low MIN_STAKE_AMOUNT** - keep it at 1000 tokens minimum
8. **Don't forget to update interfaces** when adding new functions

---

## 📞 Questions / Clarifications

If you encounter issues while implementing:

1. **Check spec/HISTORICAL_FIXES.md** - similar issues may have been fixed before
2. **Check spec/AUDIT.md** - may have context on design decisions
3. **Check test files** - existing tests show expected behavior
4. **Check interfaces** - function signatures must match
5. **Ask for clarification** if design intent is unclear (like MEDIUM-1)

---

**END OF IMPLEMENTATION GUIDE**

This document contains all information needed to fix every issue found in External Audit 2.
Follow the implementation order, verify each fix with tests, and update documentation.

**Expected Timeline:** 3-4 weeks for complete implementation and testing.

**Success Criteria:**

- All CRITICAL fixes implemented and tested
- All HIGH fixes implemented and tested
- All MEDIUM fixes implemented and tested
- All LOW fixes implemented
- All tests passing
- Test coverage > 95%
- Gas usage within limits
- Documentation updated
