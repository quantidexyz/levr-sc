# New Security Findings - October 30, 2025
## Claude Code Audit - New Issues Only

**Note:** This document contains ONLY new findings. Previously identified and fixed issues are documented in:
- `CRITICAL_BUG_ANALYSIS.md`
- `EXTERNAL_AUDIT_0.md` + `EXTERNAL_AUDIT_0_FIXES.md`
- `ADERYN_ANALYSIS.md`

---

## Summary

| Severity | Finding | Status |
|----------|---------|--------|
| MEDIUM | Staked Token Transfer Design Inconsistency | ⚠️ Needs Clarification |
| MEDIUM | Reward Token Slot DoS (minimal protection) | ⚠️ Needs Mitigation |
| MEDIUM | Trusted Forwarder Configuration Risk | ⚠️ Needs Verification |
| LOW | Missing Explicit Division-by-Zero Checks | ℹ️ Defense-in-Depth |
| LOW | Missing Invariant Assertions | ℹ️ Debug Aid |
| INFO | Token Compatibility Documentation Needed | 📋 Documentation |

---

## MEDIUM-1: Staked Token Transfer Design Inconsistency

### Severity: MEDIUM (Design Clarity)
### Status: ⚠️ **REQUIRES TEAM DECISION**

### Issue

**Code vs Documentation Mismatch:**

**Current Code** (`src/LevrStakedToken_v1.sol:51`):
```solidity
require(from == address(0) || to == address(0), 'STAKED_TOKENS_NON_TRANSFERABLE');
```
This **BLOCKS all transfers** (only minting/burning allowed).

**Documentation** (`spec/EXTERNAL_AUDIT_0_FIXES.md:23-41`):
```markdown
### Solution: Balance-Based Design
- Modified `LevrStakedToken_v1._update()` to call staking callbacks during transfers
- Receiver's VP is recalculated using weighted average formula
- 21 transfer tests passing ✅
```
This describes transfers as **ENABLED with VP preservation**.

### Evidence

Looking at `EXTERNAL_AUDIT_0_FIXES.md`, the external audit specifically fixed "Staked Token Transferability" and:
1. Added transfer callback functions to staking contract
2. Created 21 tests for transfer scenarios
3. Documented VP preservation mechanism
4. Marked as "✅ FIXED"

However, the current `LevrStakedToken_v1.sol` still contains the transfer blocking code.

### Potential Explanations

1. **Design Reversal:** Transfers were enabled during audit, then intentionally disabled again
2. **Incomplete Implementation:** Transfer callbacks added but blocking code not removed
3. **Documentation Error:** Transfers were never actually enabled despite audit docs

### Impact

**If transfers should be BLOCKED (current code):**
- ✅ Simpler contract logic
- ✅ Prevents accidental reward loss
- ✅ Prevents VP manipulation attempts
- ❌ No secondary market for staked positions
- ❌ Reduced DeFi composability
- ⚠️ **Unused dead code:** Transfer callback functions in staking contract serve no purpose

**If transfers should be ENABLED (audit docs):**
- ✅ Secondary market support
- ✅ Enhanced composability
- ❌ More complex attack surface
- ⚠️ **Current code blocks functionality**

### Recommendation

**Option A: Keep Transfers Blocked (Current Behavior)**
```solidity
// 1. Keep line 51 in LevrStakedToken_v1.sol as-is

// 2. Remove unused transfer callback functions from LevrStaking_v1.sol:
// - onTokenTransfer()
// - onTokenTransferReceiver()
// - calcNewStakeStartTime() (if only used for transfers)
// - calcNewUnstakeStartTime() (if only used for transfers)

// 3. Update EXTERNAL_AUDIT_0_FIXES.md to reflect design reversal

// 4. Add comment explaining decision
/// @notice Staked tokens are non-transferable to prevent VP manipulation
/// and simplify reward accounting. Users must unstake to transfer.
```

**Option B: Enable Transfers (Match Audit Docs)**
```solidity
// 1. Remove require() at line 51 in LevrStakedToken_v1.sol

// 2. Verify transfer callback functions work correctly

// 3. Re-run the 21 transfer tests from EXTERNAL_AUDIT_0

// 4. Update security documentation
```

### Action Items

- [ ] **TEAM DECISION REQUIRED:** Should staked tokens be transferable?
- [ ] If blocked: Remove dead code and update docs
- [ ] If enabled: Remove blocking require and verify tests
- [ ] Document decision in protocol specification

---

## MEDIUM-2: Reward Token Slot DoS Attack

### Severity: MEDIUM (Availability)
### Status: ⚠️ **PARTIALLY MITIGATED, NEEDS IMPROVEMENT**

### Issue

**Attack Scenario:**
```
Attacker Goal: Prevent legitimate reward tokens (WETH, USDC) from being added

Attack Steps:
1. Send dust amounts (1 wei) of 50 different worthless tokens to staking contract
2. Call accrueRewards() for each token → auto-registers each one
3. maxRewardTokens = 50 reached
4. Legitimate tokens cannot be added → DOS

Cost: Gas fees only (no token cost with 1 wei amounts)
Impact: Protocol reward distribution disrupted
```

### Current Code

**Location:** `src/LevrStaking_v1.sol:_ensureRewardToken()` (lines 633-671)

**Current Protection 1: Max Token Limit**
```solidity
// Line 642-656
uint16 maxRewardTokens = ILevrFactory_v1(factory).maxRewardTokens();
uint256 nonWhitelistedCount = 0;
for (uint256 i = 0; i < _rewardTokens.length; i++) {
    if (!_tokenState[_rewardTokens[i]].whitelisted) {
        nonWhitelistedCount++;
    }
}
require(nonWhitelistedCount < maxRewardTokens, "MAX_REWARD_TOKENS_REACHED");
```

**Current Protection 2: Whitelist Bypass**
```solidity
// Lines 252-277
function whitelistToken(address token) external {
    address tokenAdmin = IClankerToken(underlying).admin();
    require(_msgSender() == tokenAdmin, "ONLY_TOKEN_ADMIN");
    tokenState.whitelisted = true;  // Exempt from limit
}
```

**Current Protection 3: Cleanup Function**
```solidity
// Lines 284-318
function cleanupFinishedRewardToken(address token) external {
    require(_streamEnd > 0 && block.timestamp >= _streamEnd, "STREAM_NOT_FINISHED");
    require(tokenState.reserve == 0, "REWARDS_STILL_PENDING");
    // Remove token, free up slot
}
```

### Why Current Protections Are Insufficient

1. **Whitelist requires admin action** - Reactive, not preventive
2. **Cleanup only works after stream ends** - Can't remove during active stream
3. **No minimum value threshold** - 1 wei tokens accepted
4. **No priority mechanism** - Can't replace low-value with high-value tokens

### Attack Timeline

```
Time T0: Attacker fills 50 slots with dust
Time T1: Protocol wants to add WETH rewards → BLOCKED
Time T2: Admin whitelists WETH → Works (mitigation)
Time T3: Protocol wants to add USDC → Still blocked (49/50 slots filled with dust)
```

**Issue:** Admin must whitelist EVERY legitimate token reactively.

### Recommended Fix

**Add Minimum Reward Threshold:**

```solidity
// Add to LevrStaking_v1.sol
uint256 public constant MIN_REWARD_AMOUNT = 1e15;  // 0.001 tokens (18 decimals)

function _creditRewards(address token, uint256 amount) internal {
    // Add minimum check BEFORE ensureRewardToken()
    require(amount >= MIN_REWARD_AMOUNT, "REWARD_TOO_SMALL");

    RewardTokenState storage tokenState = _ensureRewardToken(token);
    // ... rest of function
}
```

**Rationale:**
- 0.001 tokens = $0.001 - $10 depending on token
- Makes attack expensive (need meaningful amounts of 50 tokens)
- Doesn't affect legitimate rewards (always > 0.001)
- Simple to implement, minimal gas overhead

### Alternative/Additional Mitigations

**Option A: Increase maxRewardTokens**
```solidity
// In factory config
maxRewardTokens = 100;  // Instead of 50
```
- Makes attack 2x more expensive
- Doesn't solve fundamental issue
- Increases gas costs for settlement loops

**Option B: Token Replacement Logic**
```solidity
// Allow replacing lowest-value token with higher-value token
function replaceRewardToken(address oldToken, address newToken) external {
    require(tokenState[oldToken].reserve < tokenState[newToken].reserve);
    // Replace oldToken with newToken
}
```
- More complex implementation
- Requires accurate token value comparison
- Could be combined with minimum threshold

**Option C: Admin-Only Reward Token Addition**
```solidity
function addRewardToken(address token) external {
    require(_msgSender() == tokenAdmin, "ONLY_ADMIN");
    // Only admin can add tokens
}
```
- Most restrictive
- Breaks token-agnostic design
- Not recommended

### Recommended Implementation

**Priority: HIGH**

```diff
// src/LevrStaking_v1.sol

+ uint256 public constant MIN_REWARD_AMOUNT = 1e15;

  function _creditRewards(address token, uint256 amount) internal {
+     require(amount >= MIN_REWARD_AMOUNT, "REWARD_TOO_SMALL");
      RewardTokenState storage tokenState = _ensureRewardToken(token);
      // ... rest of function
  }
```

**Testing:**
```solidity
// test/unit/LevrStakingV1.RewardTokenDoS.t.sol
function test_revertWhen_rewardBelowMinimum() external {
    vm.expectRevert("REWARD_TOO_SMALL");
    staking.accrueRewards(dustToken, 1);  // 1 wei
}

function test_attackScenario_slotDoS_mitigated() external {
    // Try to fill slots with dust → Should fail
    for (uint i = 0; i < 50; i++) {
        address dustToken = address(uint160(i + 1000));
        vm.expectRevert("REWARD_TOO_SMALL");
        // Send 1 wei and try to accrue
    }
}
```

### Impact Assessment

**Before Mitigation:**
- Attack Cost: ~$50 in gas fees
- Impact: Protocol reward distribution blocked
- Recovery: Manual whitelisting by admin (reactive)

**After Mitigation:**
- Attack Cost: 50 × 0.001 tokens × price = $50-$500 + gas
- Impact: Economic attack becomes unprofitable
- Recovery: Not needed (attack prevented)

### Related Code

This finding relates to but is distinct from:
- **Aderyn L-11:** Token limit check exists (not a new finding)
- **External Audit:** Token-agnostic design (this is a weakness of that design)

---

## MEDIUM-3: Trusted Forwarder Configuration Risk

### Severity: MEDIUM (Deployment Configuration)
### Status: ⚠️ **NEEDS VERIFICATION**

### Issue

**Pattern:** All contracts inherit `ERC2771ContextBase` for meta-transaction support.

**Location:** Every main contract (Staking, Governor, Treasury, Factory, StakedToken)

**Code:**
```solidity
contract LevrStaking_v1 is ERC2771ContextBase {
    constructor(address trustedForwarder) ERC2771ContextBase(trustedForwarder) {}

    function _msgSender() internal view override returns (address) {
        return ERC2771ContextBase._msgSender();
    }
}
```

### The Risk

**If trusted forwarder is compromised or malicious:**

```
1. Attacker controls trustedForwarder contract
2. Forwarder can claim ANY address as _msgSender()
3. Attacker calls: staking.stake(amount) with _msgSender() = victimAddress
4. Victim's tokens are staked without their real signature
5. Same for voting, unstaking, claiming, etc.
```

**Critical Impact:**
- ✅ Impersonate any user
- ✅ Steal rewards (claim to attacker address)
- ✅ Manipulate governance (vote as any user)
- ✅ Drain staked positions

### Why This Matters

**ERC2771 trustedForwarder is:**
- Set during deployment (immutable)
- **NO VALIDATION** in constructor
- **NO TIMELOCK** or governance control
- **SINGLE POINT OF FAILURE**

### Current State

**No explicit validation found in codebase for:**
- ❌ Is forwarder address a valid contract?
- ❌ Is forwarder audited/trusted?
- ❌ Can forwarder be updated/upgraded?
- ❌ What happens if forwarder is compromised?

### Recommended Mitigations

#### **Option 1: Use OpenZeppelin MinimalForwarder (Recommended)**

```solidity
// Deploy OpenZeppelin's audited forwarder
import {MinimalForwarder} from "@openzeppelin/contracts/metatx/MinimalForwarder.sol";

// In deployment script
MinimalForwarder forwarder = new MinimalForwarder();
LevrFactory factory = new LevrFactory(config, owner, address(forwarder), ...);
```

**Benefits:**
- ✅ Audited by OpenZeppelin
- ✅ Standard implementation
- ✅ Well-tested
- ✅ No custom vulnerability risk

#### **Option 2: Validate Forwarder in Constructor**

```solidity
constructor(address trustedForwarder) ERC2771ContextBase(trustedForwarder) {
    // Validate forwarder is a contract
    require(trustedForwarder.code.length > 0, "FORWARDER_NOT_CONTRACT");

    // Optional: Validate it implements expected interface
    require(
        IForwarder(trustedForwarder).supportsInterface(type(IForwarder).interfaceId),
        "INVALID_FORWARDER"
    );
}
```

#### **Option 3: Add Forwarder Disable Mechanism**

```solidity
// Add to each contract
bool public forwarderEnabled = true;

function disableForwarder() external onlyOwner {
    forwarderEnabled = false;
}

function _msgSender() internal view override returns (address) {
    if (!forwarderEnabled) {
        return msg.sender;  // Bypass forwarder
    }
    return ERC2771ContextBase._msgSender();
}
```

**Use case:** Emergency disable if forwarder compromised

#### **Option 4: Don't Use Meta-Transactions**

```solidity
// If meta-transactions not needed, remove ERC2771:
contract LevrStaking_v1 is ReentrancyGuard {  // Remove ERC2771ContextBase
    // Use msg.sender directly
}
```

**Benefits:**
- ✅ Eliminates risk entirely
- ✅ Simpler code
- ❌ Loses gasless transaction support

### Deployment Checklist

**Before deploying with trusted forwarder:**

- [ ] Verify forwarder contract address
- [ ] Confirm forwarder is audited (preferably OpenZeppelin)
- [ ] Test forwarder on testnet
- [ ] Document forwarder upgrade policy (if upgradeable)
- [ ] Plan emergency response if forwarder compromised
- [ ] Consider if meta-transactions are actually needed

**If meta-transactions not needed:**
- [ ] Remove ERC2771ContextBase inheritance
- [ ] Replace `_msgSender()` with `msg.sender`
- [ ] Remove trustedForwarder from constructors
- [ ] Reduce attack surface

### Impact Assessment

**Risk Level:** MEDIUM
- **Likelihood:** LOW (if OpenZeppelin forwarder used)
- **Impact:** CRITICAL (full protocol compromise)
- **Mitigation:** Easy (use audited forwarder)

**Recommendation:** Use OpenZeppelin MinimalForwarder OR remove meta-transaction support entirely.

---

## LOW-1: Missing Explicit Division-by-Zero Checks

### Severity: LOW (Defense-in-Depth)
### Status: ℹ️ **CURRENTLY PROTECTED, BUT COULD BE MORE EXPLICIT**

### Issue

**Multiple division operations rely on upstream checks:**

#### Location 1: RewardMath.sol:96
```solidity
function calculateAccPerShare(...) internal pure returns (uint256 newAcc) {
    if (vestAmount == 0 || totalStaked == 0) return currentAcc;
    return currentAcc + (vestAmount * ACC_SCALE) / totalStaked;
    //                                            ^^^^^^^^^^^^
    //                                            Protected by if-check above
}
```

#### Location 2: LevrStaking_v1.sol:510
```solidity
function rewardRatePerSecond(address token) external view returns (uint256) {
    if (end == 0 || end <= start) return 0;
    uint256 window = end - start;
    return total / window;  // Protected by if-check above
    //            ^^^^^^
}
```

#### Location 3: LevrGovernor_v1.sol:859
```solidity
function getVotingPower(address user) external view returns (uint256) {
    return (balance * timeStaked) / (1e18 * 86400);
    //                              ^^^^^^^^^^^^^^^^^
    //                              Constant denominator (never zero)
}
```

### Current Protection Status

✅ **All divisions are currently protected:**
- RewardMath: if-check before division
- rewardRatePerSecond: if-check before division
- getVotingPower: constant denominator

### Why Add Explicit Checks?

**Defense-in-Depth Principle:**
```solidity
// Current: Relies on caller/upstream check
if (totalStaked == 0) return currentAcc;  // Line 95
return currentAcc + (vestAmount * ACC_SCALE) / totalStaked;  // Line 96

// Recommended: Explicit check at point of use
require(totalStaked != 0, "DIVISION_BY_ZERO");  // Explicit
return currentAcc + (vestAmount * ACC_SCALE) / totalStaked;
```

**Benefits:**
1. **Fail-fast:** Error at exact location
2. **Self-documenting:** Clear invariant requirement
3. **Bug detection:** Catches upstream logic errors
4. **Audit clarity:** No need to verify upstream checks

**Costs:**
- Minimal gas (~100 gas per check)
- Slightly more code

### Recommended Implementation

**Priority: LOW (Current code is safe)**

```diff
// src/libraries/RewardMath.sol

function calculateAccPerShare(...) internal pure returns (uint256 newAcc) {
    if (vestAmount == 0 || totalStaked == 0) return currentAcc;
+   require(totalStaked != 0, "DIVISION_BY_ZERO");  // Explicit check
    return currentAcc + (vestAmount * ACC_SCALE) / totalStaked;
}

function calculateVestedAmount(...) internal pure returns (uint256, uint64) {
    // ...
    uint256 duration = end - start;
+   require(duration != 0, "ZERO_DURATION");
    if (duration == 0 || total == 0) return (0, to);
    vested = (total * (to - from)) / duration;
}
```

```diff
// src/LevrStaking_v1.sol

function rewardRatePerSecond(address token) external view returns (uint256) {
    if (end == 0 || end <= start) return 0;
    uint256 window = end - start;
+   require(window != 0, "ZERO_WINDOW");
    return total / window;
}
```

### Testing

```solidity
// test/unit/RewardMath.DivisionSafety.t.sol
function test_calculateAccPerShare_revertsOnZeroStaked() {
    vm.expectRevert("DIVISION_BY_ZERO");
    RewardMath.calculateAccPerShare(1e18, 100e18, 0);
}

function test_rewardRatePerSecond_revertsOnZeroWindow() {
    // Manipulate state to bypass upstream check (shouldn't be possible)
    // Verify explicit check catches it
}
```

---

## LOW-2: Missing Invariant Assertions

### Severity: LOW (Debug Aid)
### Status: ℹ️ **GOOD TO HAVE**

### Issue

**Key invariants are not explicitly asserted in code.**

### Identified Invariants

#### Invariant 1: Escrow Balance Equals Total Staked
```solidity
// Should always be true:
_escrowBalance[underlying] == _totalStaked
```

**Current State:** Maintained by logic, but not asserted

**Recommended:**
```solidity
function stake(uint256 amount) external nonReentrant {
    // ... staking logic ...

    // Development assertion (removed in production or use with DEBUG flag)
    assert(_escrowBalance[underlying] == _totalStaked);
}

function unstake(uint256 amount, address to) external nonReentrant {
    // ... unstaking logic ...

    assert(_escrowBalance[underlying] == _totalStaked);
}
```

#### Invariant 2: Debt is Non-Negative
```solidity
// Debt represents claimable amount, should never be negative
_userRewards[account][token].debt >= 0
```

**Recommended:**
```solidity
function _increaseDebtForAll(address account, uint256 amount) internal {
    for (uint256 i = 0; i < len; i++) {
        _userRewards[account][rt].debt += int256(accumulated);
        assert(_userRewards[account][rt].debt >= 0);  // Sanity check
    }
}
```

#### Invariant 3: Reserve Covers Claimable
```solidity
// Reserve should always be sufficient for all claims
tokenState.reserve >= sum(all_users_claimable)
```

**Note:** Hard to assert efficiently (would need to loop all users)

### Benefits of Assertions

**Development:**
- ✅ Catches logic bugs immediately
- ✅ Documents expected invariants
- ✅ Helps during refactoring

**Production:**
- ⚠️ Assertions cost gas
- ⚠️ Could cause unexpected reverts if bug exists
- ✅ Prevents state corruption

### Recommended Approach

**Option A: Development-Only Assertions**
```solidity
// Use in development/testing, remove in production
assert(condition);
```

**Option B: DEBUG Flag**
```solidity
bool constant DEBUG = false;  // Set to false for production

if (DEBUG) {
    assert(_escrowBalance[underlying] == _totalStaked);
}
```

**Option C: Custom Error Asserts**
```solidity
// More gas-efficient than assert(), better error messages
if (_escrowBalance[underlying] != _totalStaked) {
    revert EscrowDesync();
}
```

### Priority: LOW

This is a **quality-of-life improvement** for development. Not critical for security (invariants are already maintained by logic).

---

## INFO: Token Compatibility Documentation

### Severity: INFO (Documentation)
### Status: 📋 **NEEDS DOCUMENTATION**

### Issue

**Not documented which token types are supported/unsupported.**

### Token Type Analysis

#### ✅ **Standard ERC20 Tokens**
- **Example:** Most tokens (DAI, WETH, USDC)
- **Support:** Full support via SafeERC20
- **Testing:** Extensive

#### ✅ **Non-Standard Return Values**
- **Example:** USDT (no return value on transfer)
- **Support:** Handled by SafeERC20
- **Testing:** Covered in ADERYN fixes

#### ⚠️ **Fee-on-Transfer Tokens**
- **Example:** PAXG (takes 0.02% fee on transfer)
- **Support:** Would desynchronize escrow
- **Behavior:**
  ```solidity
  // User stakes 100 tokens
  IERC20(underlying).safeTransferFrom(user, staking, 100);
  // Only 99.98 received due to fee
  _escrowBalance[underlying] += 100;  // Incorrect!
  _totalStaked += 100;

  // Future unstakes will fail (insufficient balance)
  ```
- **Recommendation:** ⚠️ **NOT RECOMMENDED**

#### ❌ **Rebasing Tokens**
- **Example:** stETH (balance changes over time)
- **Support:** Would corrupt accounting
- **Behavior:**
  ```solidity
  // User stakes 100 stETH
  _totalStaked = 100;

  // 1 week later: stETH balance becomes 101 (rebase)
  // But _totalStaked still = 100
  // Accounting permanently broken
  ```
- **Recommendation:** ❌ **NOT SUPPORTED**

#### ⚠️ **Pausable Tokens**
- **Example:** USDC (can be paused by Circle)
- **Support:** Handled gracefully
- **Behavior:**
  ```solidity
  // Token paused during execution
  try ILevrTreasury(treasury).applyBoost(token, amount) {
      emit ProposalExecuted();
  } catch {
      emit ProposalExecutionFailed();  // Graceful failure
  }
  ```
- **Recommendation:** ⚠️ **SUPPORTED BUT RISKY**

#### ⚠️ **Upgradeable Tokens**
- **Example:** USDT (proxy pattern)
- **Support:** Depends on upgrade
- **Risk:** Token logic could change post-deployment
- **Recommendation:** ⚠️ **SUPPORTED BUT MONITOR**

#### ⚠️ **Blocklist Tokens**
- **Example:** USDC (Circle can blocklist addresses)
- **Support:** Would fail if staking contract blocklisted
- **Recommendation:** ⚠️ **SUPPORTED BUT RISKY**

### Recommended Documentation

**Add to README.md or docs/TOKEN_COMPATIBILITY.md:**

```markdown
## Supported Token Types

### ✅ Fully Supported
- Standard ERC20 (DAI, LINK, etc.)
- Non-standard returns (USDT, BNB, etc.) - handled by SafeERC20
- Pausable tokens (USDC) - graceful failure on pause
- Upgradeable tokens (USDT) - monitor for upgrades

### ⚠️ Partially Supported (Use with Caution)
- Blocklist tokens (USDC, USDT) - contract must not be blocklisted
- High-fee tokens - may desynchronize escrow over time

### ❌ Not Supported
- Fee-on-transfer tokens (PAXG, STA) - breaks escrow accounting
- Rebasing tokens (stETH, aTokens) - corrupts balance tracking
- Tokens with transfer callbacks - could cause reentrancy

### Testing Your Token

Before using a token as underlying or reward:
1. Check if it's fee-on-transfer: `balanceOf(to)` after transfer should equal `amount`
2. Check if it's rebasing: `balanceOf()` should not change without transfers
3. Check if it's pausable: Monitor for pause events
4. Test on testnet first
```

### Action Items

- [ ] Add token compatibility documentation
- [ ] Create token compatibility test suite
- [ ] Document in deployment checklist
- [ ] Consider adding `isTokenCompatible()` helper function

---

## Summary of New Findings

### Immediate Action Required (MEDIUM)

1. **Staked Token Transfer Design**
   - Decision needed: Enable or keep blocked?
   - Remove dead code if blocked
   - Priority: **HIGH**

2. **Minimum Reward Threshold**
   - Add `MIN_REWARD_AMOUNT = 1e15` check
   - Prevents DoS attack
   - Priority: **HIGH**

3. **Trusted Forwarder Verification**
   - Use OpenZeppelin MinimalForwarder
   - Or remove meta-transaction support
   - Priority: **HIGH** (deployment config)

### Code Quality Improvements (LOW)

4. **Explicit Division Checks**
   - Add to RewardMath library
   - Defense-in-depth
   - Priority: **LOW**

5. **Invariant Assertions**
   - Add for development/debugging
   - Remove in production or use DEBUG flag
   - Priority: **LOW**

### Documentation (INFO)

6. **Token Compatibility Guide**
   - Document supported/unsupported tokens
   - Add to README
   - Priority: **MEDIUM**

---

## Files Requiring Changes

### High Priority
1. `src/LevrStaking_v1.sol` - Add MIN_REWARD_AMOUNT check
2. `src/LevrStakedToken_v1.sol` - Clarify transfer design
3. Constructor args for all contracts - Verify trustedForwarder

### Low Priority
4. `src/libraries/RewardMath.sol` - Add explicit zero checks
5. `src/LevrStaking_v1.sol` - Add assertions (optional)
6. `README.md` or `docs/` - Token compatibility guide

---

## Test Coverage Needed

### New Tests
```
test/unit/LevrStakingV1.RewardTokenDoS.t.sol
- test_revertWhen_rewardBelowMinimum()
- test_attackScenario_slotDoS_mitigated()
- test_legitRewards_aboveMinimum_success()

test/unit/RewardMath.DivisionSafety.t.sol (optional)
- test_calculateAccPerShare_revertsOnZeroStaked()
- test_rewardRatePerSecond_revertsOnZeroWindow()

test/unit/TokenCompatibility.t.sol
- test_feeOnTransfer_desynchronizesEscrow()
- test_rebasing_corruptsAccounting()
- test_pausable_failsGracefully()
```

---

**END OF NEW FINDINGS REPORT**
