# EXTERNAL_AUDIT_0: Security Fixes & Implementation Options

**Date:** October 28, 2025
**Audit:** EXTERNAL_AUDIT_0.md (2,698 lines)
**Status:** Test Suite Ready - Awaiting Fix Implementation
**Test Suite:** 26 tests created (15 passing, 11 failing as expected)

---

## 📋 Overview

This document provides **multiple implementation options** for each audit finding. Choose the approach that best fits your security model and implementation timeline.

**Test Files Location:**

- `test/unit/EXTERNAL_AUDIT_0.LevrStakedToken_TransferRestriction.t.sol` (12 tests)
- `test/unit/EXTERNAL_AUDIT_0.LevrStaking_VotingPowerPrecision.t.sol` (14 tests)

**Archive Documentation:**

- `spec/archive/EXTERNAL_AUDIT_0_IMPLEMENTATION_SUMMARY.md` - Detailed roadmap
- `spec/archive/EXTERNAL_AUDIT_0_TESTS.md` - Test documentation
- `spec/archive/EXTERNAL_AUDIT_0_QUICK_REFERENCE.md` - Quick commands
- `spec/archive/EXTERNAL_AUDIT_0_INDEX.md` - Navigation guide

---

## 🔴 CRITICAL-1: Staked Token Transferability

**Severity:** CRITICAL (CVSS 9.0)  
**Impact:** Permanent loss of user funds  
**Test Status:** 3/12 passing (9 failing - vulnerability confirmed)  
**Current Status:** Transfers ARE allowed (bug exists)

### Problem Summary

Staked tokens can be transferred, causing desynchronization between:

- Internal accounting: `_staked[user]` in LevrStaking_v1
- Token balance: ERC20 balance in LevrStakedToken_v1

**Attack Scenario:**

```
1. Alice stakes 1000 tokens
   → _staked[Alice] = 1000
   → stakedToken.balanceOf(Alice) = 1000

2. Alice transfers to Bob
   → stakedToken transfers 1000 to Bob
   → _staked[Alice] UNCHANGED = 1000 ❌
   → stakedToken.balanceOf(Alice) = 0
   → stakedToken.balanceOf(Bob) = 1000

3. Result: Alice's 1000 underlying tokens PERMANENTLY LOCKED
   → Alice cannot unstake (token balance = 0)
   → Bob cannot unstake (never staked)
```

### Fix Option 1: Block All Transfers (RECOMMENDED) ⭐

**Approach:** Make staked tokens non-transferable  
**Complexity:** Low  
**Gas Impact:** Minimal  
**Time to Implement:** 30 minutes

```solidity
// File: src/LevrStakedToken_v1.sol
// Add this override to the LevrStakedToken_v1 contract

/// @notice Override _update to block transfers
/// @dev Staked tokens represent a position in the staking contract.
///      Transferring them would desync internal accounting.
function _update(
    address from,
    address to,
    uint256 value
) internal virtual override {
    // Allow minting (from == address(0)) and burning (to == address(0))
    // Block all other transfers
    require(
        from == address(0) || to == address(0),
        "STAKED_TOKENS_NON_TRANSFERABLE"
    );
    super._update(from, to, value);
}
```

**Pros:**

- ✅ Simple (5 lines of code)
- ✅ Eliminates vulnerability entirely
- ✅ No additional gas costs
- ✅ Standard pattern for staking tokens
- ✅ No edge cases or complications

**Cons:**

- ❌ Users cannot transfer staked tokens
- ❌ Limited composability with other protocols

**Testing:**

```bash
forge test --match-contract "EXTERNAL_AUDIT_0_LevrStakedToken" -vvv
# Expected: All 12 tests PASS ✅
```

---

### Fix Option 2: Hook-Based Transfer Sync

**Approach:** Update internal accounting on transfers  
**Complexity:** High  
**Gas Impact:** Significant  
**Time to Implement:** 8+ hours

```solidity
// File: src/LevrStakedToken_v1.sol

interface ILevrStakingCallback {
    function onTokenTransfer(
        address from,
        address to,
        uint256 amount
    ) external;
}

function _update(
    address from,
    address to,
    uint256 value
) internal virtual override {
    // Notify staking contract of transfer
    if (from != address(0) && to != address(0) && staking != address(0)) {
        try ILevrStakingCallback(staking).onTokenTransfer(from, to, value) {}
        catch {}
    }
    super._update(from, to, value);
}
```

```solidity
// File: src/LevrStaking_v1.sol

function onTokenTransfer(
    address from,
    address to,
    uint256 amount
) external onlyStakedToken nonReentrant {
    require(amount > 0, "ZERO_AMOUNT");

    // Validate sufficient balance
    require(_staked[from] >= amount, "INSUFFICIENT_STAKE");

    // Transfer internal accounting
    _staked[from] -= amount;
    _staked[to] += amount;

    // Transfer reward debt
    uint256 debtFrom = _rewardDebt[from][address(underlying)];
    uint256 proportionalDebt = (debtFrom * amount) / _staked[from];
    _rewardDebt[from][address(underlying)] -= proportionalDebt;
    _rewardDebt[to][address(underlying)] += proportionalDebt;

    // Update start times proportionally
    // ... complex logic for stakeStartTime ...
}
```

**Pros:**

- ✅ Allows token transfers
- ✅ Maintains accounting consistency
- ✅ Enables composability

**Cons:**

- ❌ Very complex implementation
- ❌ Many edge cases (partial transfers, multiple stakeholders)
- ❌ Higher gas costs
- ❌ Risk of bugs in callback logic
- ❌ Requires extensive testing
- ❌ Harder to maintain

**Not Recommended:** This approach introduces significant complexity with little benefit.

---

### Fix Option 3: Whitelist Pattern

**Approach:** Only allow transfers to whitelisted addresses  
**Complexity:** Medium  
**Gas Impact:** Moderate  
**Time to Implement:** 2-3 hours

```solidity
// File: src/LevrStakedToken_v1.sol

mapping(address => bool) public whitelistedTransferDestinations;
address public transferWhitelist Admin;

modifier onlyWhitelistAdmin() {
    require(msg.sender == transferWhitelistAdmin, "ONLY_ADMIN");
    _;
}

function setWhitelistDestination(address destination, bool allowed)
    external onlyWhitelistAdmin
{
    whitelistedTransferDestinations[destination] = allowed;
}

function _update(
    address from,
    address to,
    uint256 value
) internal virtual override {
    // Allow minting/burning
    if (from == address(0) || to == address(0)) {
        super._update(from, to, value);
        return;
    }

    // Allow whitelisted destinations
    require(
        whitelistedTransferDestinations[to],
        "TRANSFER_NOT_WHITELISTED"
    );

    super._update(from, to, value);
}
```

**Pros:**

- ✅ Flexible - can enable specific transfers
- ✅ Moderate complexity
- ✅ Allows bridging, cross-chain scenarios

**Cons:**

- ❌ Still requires careful accounting management
- ❌ Admin governance overhead
- ❌ Risk if whitelist misconfigured
- ❌ Doesn't fully prevent misuse

**Not Recommended:** Option 1 is simpler and safer.

---

## 🟠 HIGH-1: Voting Power Precision Loss

**Severity:** HIGH (CVSS 6.5)  
**Impact:** Loss of voting power on large unstakes  
**Test Status:** 12/14 passing (2 failing - precision loss confirmed)  
**Current Status:** 99.9% unstakes result in VP = 0

### Problem Summary

Formula for recalculating VP after partial unstake:

```
newTimeAccumulated = (timeAccumulated * remainingBalance) / originalBalance
```

**Precision Loss Case:**

```
Initial: 1000 tokens staked for 365 days
Unstake: 999 tokens (99.9%)
Remaining: 1 token

Calculation:
- timeAccumulated = 31,536,000 seconds (365 days)
- remainingBalance = 1
- originalBalance = 1000
- newTimeAccumulated = (31,536,000 * 1) / 1000 = 31,536
- But in token-day normalization: VP = 0 (rounds to zero)

Result: User loses ALL voting power ❌
```

---

### Fix Option 1: Precision Scaling (RECOMMENDED) ⭐

**Approach:** Scale calculations to prevent premature rounding  
**Complexity:** Low  
**Gas Impact:** Minimal  
**Time to Implement:** 2 hours

```solidity
// File: src/LevrStaking_v1.sol

/// @notice Calculate new stakeStartTime after partial unstake
/// @dev Preserves voting power with precision scaling and minimum floor
function _onUnstakeNewTimestamp(
    uint256 unstakeAmount
) internal view returns (uint256 newStartTime) {
    address staker = _msgSender();
    uint256 currentStartTime = stakeStartTime[staker];

    if (currentStartTime == 0) return 0;

    uint256 remainingBalance = _staked[staker];
    if (remainingBalance == 0) return 0;

    uint256 originalBalance = remainingBalance + unstakeAmount;
    uint256 timeAccumulated = block.timestamp - currentStartTime;

    // Calculate with precision scaling
    uint256 newTimeAccumulated;

    // Check for overflow before multiplication
    if (timeAccumulated <= type(uint256).max / remainingBalance) {
        // Safe to multiply first for better precision
        newTimeAccumulated = (timeAccumulated * remainingBalance) / originalBalance;
    } else {
        // Divide first to prevent overflow, accept some precision loss
        newTimeAccumulated = (remainingBalance / originalBalance) * timeAccumulated;
    }

    // Apply minimum time floor for non-zero stakes
    // Ensures at least 1 second is preserved to prevent complete loss
    if (newTimeAccumulated == 0 && remainingBalance > 0 && timeAccumulated > 0) {
        // Minimum: 1 second per full token remaining
        uint256 minTime = remainingBalance / 1e18;
        if (minTime == 0) minTime = 1;
        newTimeAccumulated = minTime;
    }

    newStartTime = block.timestamp - newTimeAccumulated;
}
```

**Pros:**

- ✅ Simple, minimal code changes
- ✅ Prevents complete VP loss
- ✅ Maintains proportionality
- ✅ No additional gas in normal cases
- ✅ Handles overflow edge cases

**Cons:**

- ❌ Minimum floor is somewhat arbitrary
- ❌ Very small dust amounts might get 1 second

**Testing:**

```bash
forge test --match-contract "EXTERNAL_AUDIT_0_LevrStakingVotingPower" -vvv
# Expected: All 14 tests PASS ✅

# Key test passes:
# test_stakingVotingPower_99_9percentUnstake_precisionLoss ✅
# test_stakingVotingPower_1weiRemaining_precisionBoundary ✅
```

---

### Fix Option 2: Rational Number Library

**Approach:** Use high-precision arithmetic (257-bit intermediate)  
**Complexity:** Medium  
**Gas Impact:** Moderate  
**Time to Implement:** 4+ hours

```solidity
// File: src/LevrStaking_v1.sol

/// @notice Calculate with ultra-high precision
function _onUnstakeNewTimestamp(
    uint256 unstakeAmount
) internal view returns (uint256 newStartTime) {
    address staker = _msgSender();
    uint256 currentStartTime = stakeStartTime[staker];

    if (currentStartTime == 0) return 0;

    uint256 remainingBalance = _staked[staker];
    if (remainingBalance == 0) return 0;

    uint256 originalBalance = remainingBalance + unstakeAmount;
    uint256 timeAccumulated = block.timestamp - currentStartTime;

    // Use 256-bit intermediate with bit shifting to preserve precision
    // numerator = timeAccumulated * remainingBalance * 2^64
    // denominator = originalBalance
    // result = numerator / denominator / 2^64

    unchecked {
        // Preserve 64 bits of precision
        uint256 scaled = (timeAccumulated * remainingBalance) << 64;
        uint256 newTimeAccumulated = scaled / originalBalance >> 64;

        newStartTime = block.timestamp - newTimeAccumulated;
    }
}
```

**Pros:**

- ✅ Maximum precision preservation
- ✅ No arbitrary minimums
- ✅ Mathematically clean

**Cons:**

- ❌ More complex logic
- ❌ Slightly higher gas cost
- ❌ Requires careful overflow management
- ❌ Harder to audit

**Not Recommended:** Option 1 is simpler with acceptable precision.

---

### Fix Option 3: Discretized Time Buckets

**Approach:** Round time to daily buckets instead of seconds  
**Complexity:** Medium  
**Gas Impact:** Minimal  
**Time to Implement:** 3 hours

```solidity
// File: src/LevrStaking_v1.sol

uint256 constant TIME_GRANULARITY = 1 days;

function _onUnstakeNewTimestamp(
    uint256 unstakeAmount
) internal view returns (uint256 newStartTime) {
    address staker = _msgSender();
    uint256 currentStartTime = stakeStartTime[staker];

    if (currentStartTime == 0) return 0;

    uint256 remainingBalance = _staked[staker];
    if (remainingBalance == 0) return 0;

    uint256 originalBalance = remainingBalance + unstakeAmount;

    // Round to nearest day for calculation
    uint256 timeAccumulated = (block.timestamp - currentStartTime) / TIME_GRANULARITY;

    // Calculate in day units
    uint256 newTimeAccumulated = (timeAccumulated * remainingBalance) / originalBalance;

    // Convert back to seconds
    newStartTime = block.timestamp - (newTimeAccumulated * TIME_GRANULARITY);
}
```

**Pros:**

- ✅ Prevents rounding to zero naturally
- ✅ Simpler mental model
- ✅ Reduces unnecessary precision

**Cons:**

- ❌ Changes behavior significantly
- ❌ Less granular VP calculations
- ❌ May affect other parts of system

**Not Recommended:** Impacts too much behavior.

---

## 🔵 CRITICAL-1: Option 4 (NEW) - Balance-Based Design

**Approach:** Use staked token balance as the single source of truth  
**Complexity:** Low (actually simplifies code)  
**Gas Impact:** Lower (eliminates `_staked` mapping updates)  
**Time to Implement:** 3 hours  
**Key Benefit:** Transfers work freely with ZERO desync risk

### Architectural Philosophy

Instead of maintaining parallel accounting (`_staked` mapping and token balance), **eliminate the mapping entirely** and use the token balance as the sole source of truth for stake amounts.

**Why This Works:**

- Token balance cannot lie (enforced by ERC20)
- No way to desync internal accounting
- Transfer locks the tokens (can't extract value)
- Clean, auditable, bug-proof

### Complete Integration Specification

#### 1. DATA STRUCTURE CHANGES

**Remove:**

```solidity
// DELETE this mapping entirely
mapping(address => uint256) private _staked;
```

**Keep:**

```solidity
// Governance tracking - still needed for VP calculation
mapping(address => uint256) public stakeStartTime;

// Reward tracking - still needed
mapping(address => mapping(address => int256)) private _rewardDebt;
```

**Key Insight:** With balance-based design:

- `stakedToken.balanceOf(user)` = current stake amount
- `stakeStartTime[user]` = when stake began accumulating VP
- `_rewardDebt[user][token]` = cumulative reward adjustments (unchanged)

#### 2. VOTING POWER CALCULATION (Unchanged Formula, Changed Source)

```solidity
/// VP = (balance * time_accumulated) / (1e18 * 86400)
/// The FORMULA is identical, just sources change
function getVotingPower(address user) external view returns (uint256 votingPower) {
    uint256 startTime = stakeStartTime[user];
    if (startTime == 0) return 0;

    // CHANGE: Use token balance instead of _staked mapping
    uint256 balance = stakedToken.balanceOf(user);  // ← KEY CHANGE
    if (balance == 0) return 0;

    uint256 timeStaked = block.timestamp - startTime;

    // Formula identical to current system
    return (balance * timeStaked) / (1e18 * 86400);
}
```

**VP Calculation Logic:**

- Remains exactly the same: `balance * time / normalization`
- Same decimals handling (1e18 for token, 86400 for seconds/day)
- Same time-weighted voting power guarantee

#### 3. STAKE OPERATION

```solidity
function stake(uint256 amount) external nonReentrant {
    if (amount == 0) revert InvalidAmount();
    address staker = _msgSender();

    _settleStreamingAll();

    // Same weighted average VP logic as before
    stakeStartTime[staker] = _onStakeNewTimestamp(amount);

    IERC20(underlying).safeTransferFrom(staker, address(this), amount);
    _escrowBalance[underlying] += amount;

    // CHANGE: Mint staked tokens (was: update _staked mapping)
    ILevrStakedToken_v1(stakedToken).mint(staker, amount);

    // Update rewards using NEW balance source
    _updateDebtAll(staker, stakedToken.balanceOf(staker));  // ← Uses balance

    _totalStaked += amount;

    emit Staked(staker, amount);
}
```

**Weighted Average Logic Unchanged:**

```solidity
function _onStakeNewTimestamp(
    uint256 stakeAmount
) internal view returns (uint256 newStartTime) {
    address staker = _msgSender();
    // CHANGE: Read from token balance instead of mapping
    uint256 oldBalance = stakedToken.balanceOf(staker);  // ← WAS: _staked[staker]
    uint256 currentStartTime = stakeStartTime[staker];

    if (oldBalance == 0 || currentStartTime == 0) {
        return block.timestamp;
    }

    uint256 timeAccumulated = block.timestamp - currentStartTime;
    uint256 newTotalBalance = oldBalance + stakeAmount;

    // Formula completely unchanged
    uint256 newTimeAccumulated = (oldBalance * timeAccumulated) / newTotalBalance;

    return block.timestamp - newTimeAccumulated;
}
```

#### 4. UNSTAKE OPERATION

```solidity
function unstake(uint256 amount, address to) external nonReentrant returns (uint256 newVotingPower) {
    if (amount == 0) revert InvalidAmount();
    if (to == address(0)) revert ZeroAddress();
    address staker = _msgSender();

    // CHANGE: Use token balance instead of _staked mapping
    uint256 bal = stakedToken.balanceOf(staker);  // ← KEY CHANGE
    require(bal >= amount, "InsufficientStake");

    _settleStreamingAll();
    _settleAll(staker, to, bal);

    // Proportional time reduction - same formula
    stakeStartTime[staker] = _onUnstakeNewTimestamp(amount);

    // Calculate new VP for return value
    uint256 remainingBalance = bal - amount;  // ← Direct balance math
    uint256 newStartTime = stakeStartTime[staker];
    if (remainingBalance > 0 && newStartTime > 0) {
        uint256 timeStaked = block.timestamp - newStartTime;
        newVotingPower = (remainingBalance * timeStaked) / (1e18 * 86400);
    }

    // Update reward debt using new balance
    _updateDebtAll(staker, remainingBalance);  // ← Uses direct math, not mapping

    _totalStaked -= amount;

    // Burn and transfer
    ILevrStakedToken_v1(stakedToken).burn(staker, amount);
    IERC20(underlying).safeTransfer(to, amount);

    emit Unstaked(staker, to, amount);
    return newVotingPower;
}
```

**Proportional Time Reduction Unchanged:**

```solidity
function _onUnstakeNewTimestamp(
    uint256 unstakeAmount
) internal view returns (uint256 newStartTime) {
    address staker = _msgSender();
    uint256 currentStartTime = stakeStartTime[staker];

    if (currentStartTime == 0) return 0;

    // CHANGE: Read from token balance
    uint256 remainingBalance = stakedToken.balanceOf(staker);  // ← WAS: _staked[staker]
    if (remainingBalance == 0) return 0;

    uint256 originalBalance = remainingBalance + unstakeAmount;
    uint256 timeAccumulated = block.timestamp - currentStartTime;

    // Formula completely unchanged
    uint256 newTimeAccumulated = (timeAccumulated * remainingBalance) / originalBalance;

    return block.timestamp - newTimeAccumulated;
}
```

#### 5. TRANSFERS (THE NEW CAPABILITY)

When staked tokens are transferred, we need to handle VP for both parties:

```solidity
// In LevrStakedToken_v1.sol

/// @notice Override _update to handle VP on transfers
/// @dev Allows free transfers while maintaining VP accounting
function _update(
    address from,
    address to,
    uint256 value
) internal virtual override {
    // Allow minting and burning normally
    if (from == address(0) || to == address(0)) {
        super._update(from, to, value);
        return;
    }

    // For transfers between users:
    // Sender: Reduce stake proportionally, reduce VP start time
    // Receiver: Increase stake balance, reset/inherit VP start time

    // Option A: Receiver starts fresh (simpler, safer)
    // → Reset receiver's stakeStartTime to now
    // → Receiver gets NO inherited VP from transferred tokens
    // → Sender keeps accumulated VP for remaining tokens

    // Option B: Receiver inherits accumulated time (complex, requires calc)
    // → Transfer both balance AND proportional VP history
    // → More fair but requires careful reward debt handling

    super._update(from, to, value);
}
```

#### 6. EDGE CASES & VP HANDLING DURING TRANSFERS

**CASE 1: Simple Transfer (Sender keeps remaining stake)**

```
Initial State:
  Alice: 1000 staked for 100 days → VP = 100,000 token-days

Transfer: Alice sends 600 tokens to Bob

Post-Transfer (Option A - Receiver Starts Fresh):
  Alice: 400 staked for 100 days → VP = 40,000 token-days (proportional)
  Bob: 600 received → stakeStartTime = now → VP = 0 (starts fresh)

Why this works:
  ✓ No unfair VP inflation (transferred tokens don't get inherited VP)
  ✓ Simple calculation (just scale sender's VP)
  ✓ No rewards confusion
  ✓ Receiver can build their own VP
```

**CASE 2: Unstake After Transfer (Both parties can unstake independently)**

```
After Alice's transfer above:

Alice unstakes remaining 400:
  ✓ Uses balance-based check: balanceOf(Alice) >= 400
  ✓ Applies unstake VP reduction formula
  ✓ Receives 400 underlying tokens

Bob unstakes received 600:
  ✓ Uses balance-based check: balanceOf(Bob) >= 600
  ✓ Has 0 VP (just transferred), so VP after unstake = 0
  ✓ Receives 600 underlying tokens

Result: No fund lock ✓
```

**CASE 3: Transfer During Active Reward Stream**

```
Initial: Alice: 1000 staked, earning rewards

Transfer: Alice sends 500 to Bob

Both parties' reward debt must be adjusted:

Alice:
  ✓ Existing: _rewardDebt[Alice][token] = (1000 * accPerShare) / ACC_SCALE
  ✓ After transfer: _rewardDebt[Alice][token] = (500 * accPerShare) / ACC_SCALE
  ✓ Called in _update hook via staking contract callback

Bob:
  ✓ After transfer: _rewardDebt[Bob][token] = (500 * accPerShare) / ACC_SCALE
  ✓ Fresh reward tracking (no catch-up, starts from now)

Why this works:
  ✓ Each party's debt proportional to their balance
  ✓ No double-counting of rewards
  ✓ Reward debt syncs with balance
```

**CASE 4: Multiple Transfers in Sequence**

```
Timeline:
  Day 1: Alice stakes 1000
  Day 50: Alice transfers 400 to Bob
  Day 100: Bob transfers 200 to Charlie
  Day 150: Alice unstakes 600

State transitions:

Day 1:
  Alice: 1000 @ T=0

Day 50:
  Alice: 600 @ T=0 (VP = 600 * 50 days = 30,000)
  Bob: 400 @ T=50 (VP = 0, fresh)

Day 100:
  Alice: 600 @ T=0 (unchanged)
  Bob: 200 @ T=50 (VP = 200 * 50 = 10,000)
  Charlie: 200 @ T=100 (VP = 0, fresh)

Day 150:
  Alice unstake(600, alice):
    ✓ Balance check: balanceOf(Alice) = 600 ≥ 600 ✓
    ✓ Apply unstake formula for 100 days of accumulated time
    ✓ Receives 600 underlying
    ✓ stakeStartTime[alice] = 0 (full unstake)

Result: All parties can unstake their received balance ✓
```

#### 7. REWARD DEBT SYNCHRONIZATION

The key challenge: **Reward debt must stay synchronized with balance**

```solidity
// In staking contract - called via hook on transfer

function _syncRewardDebtOnTransfer(
    address from,
    address to,
    uint256 amount
) internal {
    // For each reward token
    for (uint i = 0; i < _rewardTokens.length; i++) {
        address token = _rewardTokens[i];
        uint256 acc = _rewardInfo[token].accPerShare;

        // Sender's debt scales with remaining balance
        uint256 senderNewBalance = stakedToken.balanceOf(from);
        _rewardDebt[from][token] = int256((senderNewBalance * acc) / ACC_SCALE);

        // Receiver's debt sets to their new balance at current accumulation
        uint256 receiverNewBalance = stakedToken.balanceOf(to);
        _rewardDebt[to][token] = int256((receiverNewBalance * acc) / ACC_SCALE);
    }
}
```

**Why Sync is Safe:**

- Debt based on current `accPerShare` (universal)
- Proportional to balance (fair)
- No "catch-up" of past rewards (only prospective)
- Prevents double-counting

#### 8. COMPLETE DATA CONSISTENCY

**Before Transfer:**

```
Invariants:
  ✓ balance + escrow = _totalStaked (sums to lock)
  ✓ _rewardDebt[user][token] ∝ balance
  ✓ stakeStartTime[user] ∈ [0, block.timestamp]
  ✓ getVotingPower(user) = (balance * time) / normalization
```

**Transfer Process:**

```
1. Settle all active streams (no in-flight rewards)
2. Adjust both parties' reward debt
3. Update sender's stakeStartTime if needed (Option B only)
4. Set receiver's stakeStartTime to now (Option A) or inherited (Option B)
5. Execute ERC20 transfer
```

**After Transfer:**

```
Invariants (all maintained):
  ✓ balance + escrow = _totalStaked
  ✓ _rewardDebt[user][token] ∝ balance
  ✓ stakeStartTime[user] ∈ [0, block.timestamp]
  ✓ getVotingPower(user) calculated from CURRENT balance
```

#### 9. MIGRATION PATH FROM `_staked` TO BALANCE-BASED

```solidity
// Step 1: Mark old mapping as deprecated
mapping(address => uint256) private _staked_DEPRECATED;

// Step 2: Implement balance-based everywhere
// - Update getVotingPower to use balanceOf
// - Update stake to mint instead of update mapping
// - Update unstake to burn instead of update mapping
// - Update all calculations to use balance

// Step 3: Run migration (one-time)
function migrate_balanceBasedStaking() external onlyFactory {
    require(!_migrated, "ALREADY_MIGRATED");

    // Verify no funds trapped
    // Total balance in staked token should equal _totalStaked
    assert(stakedToken.totalSupply() == _totalStaked);

    _migrated = true;

    // Delete _staked mapping
    // (This frees storage, gas rebate)
}

// Step 4: Remove deprecated mapping later
```

---

### RECOMMENDATION: USE OPTION 4

**Why Option 4 is Superior:**

| Aspect              | Option 1 (Block)               | Option 4 (Balance)               |
| ------------------- | ------------------------------ | -------------------------------- |
| **Complexity**      | Very Low                       | Very Low                         |
| **Gas Cost**        | Lower                          | Lower (saves mapping)            |
| **Exploit Surface** | Blocked transfers (limitation) | Transfers work, balance is truth |
| **Code Clarity**    | One dimension of truth         | Single source of truth           |
| **VP Calculation**  | Same                           | Identical                        |
| **Reward Tracking** | Same                           | Identical                        |
| **Flexibility**     | Staked tokens locked           | Transfers enabled                |
| **Edge Cases**      | None (transfers blocked)       | Well-defined rules               |

**Implementation Priority:**

1. CRITICAL-1: Implement Option 4 (Balance-Based Design)
2. HIGH-1: Implement Option 1 (Precision Scaling) - still needed for time calculations

**Total Implementation Time: ~3-4 hours**

---

## Implementation Checklist

### Before Implementation

- [ ] Review fix options thoroughly
- [ ] Choose preferred approach for each finding
- [ ] Create feature branch for fixes
- [ ] Back up current code

### CRITICAL-1 Implementation

- [ ] Choose fix option (recommended: Option 1)
- [ ] Add `_update()` override to `LevrStakedToken_v1.sol`
- [ ] Update NatSpec comments
- [ ] Run tests: `forge test --match-contract "EXTERNAL_AUDIT_0_LevrStakedToken" -vvv`
- [ ] Verify all 12 tests pass ✅
- [ ] Check for regressions in existing tests
- [ ] Document implementation choice in CHANGELOG.md

**Estimated Time:** 30 minutes + testing

### HIGH-1 Implementation

- [ ] Choose fix option (recommended: Option 1)
- [ ] Update `_onUnstakeNewTimestamp()` in `LevrStaking_v1.sol`
- [ ] Update NatSpec comments
- [ ] Run tests: `forge test --match-contract "EXTERNAL_AUDIT_0_LevrStakingVotingPower" -vvv`
- [ ] Verify all 14 tests pass ✅
- [ ] Check for regressions in existing tests
- [ ] Document implementation choice in CHANGELOG.md

**Estimated Time:** 2 hours + testing

### Post-Implementation

- [ ] Run full test suite: `forge test`
- [ ] Verify no regressions
- [ ] Update CHANGELOG.md with fix details
- [ ] Create PR with fixes
- [ ] Request code review
- [ ] Plan external audit if needed

---

## Quick Reference: Test Execution

```bash
# Run CRITICAL-1 tests
forge test --match-contract "EXTERNAL_AUDIT_0_LevrStakedToken" -vvv

# Run HIGH-1 tests
forge test --match-contract "EXTERNAL_AUDIT_0_LevrStakingVotingPower" -vvv

# Run all tests in suite
forge test --match-contract "EXTERNAL_AUDIT_0" -vvv

# Get gas report
forge test --match-contract "EXTERNAL_AUDIT_0" -vvv --gas-report

# Run with trace
forge test --match-contract "EXTERNAL_AUDIT_0_LevrStakedToken" --match-test "transferBlocked" -vvv
```

---

## Additional Resources

**Full Audit Report:**

- `spec/EXTERNAL_AUDIT_0.md` (2,698 lines)

**Archived Documentation:**

- `spec/archive/EXTERNAL_AUDIT_0_IMPLEMENTATION_SUMMARY.md`
- `spec/archive/EXTERNAL_AUDIT_0_TESTS.md`
- `spec/archive/EXTERNAL_AUDIT_0_QUICK_REFERENCE.md`
- `spec/archive/EXTERNAL_AUDIT_0_INDEX.md`

**Code Location:**

- Tests: `test/unit/EXTERNAL_AUDIT_0.LevrStakedToken_TransferRestriction.t.sol`
- Tests: `test/unit/EXTERNAL_AUDIT_0.LevrStaking_VotingPowerPrecision.t.sol`
- Fixes: `src/LevrStakedToken_v1.sol`, `src/LevrStaking_v1.sol`

---

## Timeline & Effort Estimate

| Task               | Estimate     | Priority  |
| ------------------ | ------------ | --------- |
| CRITICAL-1 fix     | 30 min       | 🔴 MUST   |
| CRITICAL-1 testing | 1 hour       | 🔴 MUST   |
| HIGH-1 fix         | 2 hours      | 🟠 SHOULD |
| HIGH-1 testing     | 2 hours      | 🟠 SHOULD |
| Regression testing | 1 hour       | 🟠 SHOULD |
| Documentation      | 30 min       | 🟡 NICE   |
| **Total**          | **~7 hours** |           |

---

**Status:** ✅ Ready for fix implementation  
**Next Action:** Choose fix options and begin implementation
