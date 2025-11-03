# Levr Protocol V1 - Comprehensive Security Audit Report

**Audit Date:** November 4, 2025
**Auditor:** AI Security Review (Independent Analysis)
**Codebase:** Levr Protocol V1 - Staking, Governance & Fee Distribution
**Commit:** Current HEAD on `test/coverage-impr` branch
**Test Coverage:** 556/556 unit tests passing (100%)

---

## Executive Summary

This security audit provides a comprehensive review of the Levr Protocol V1 smart contracts following previous audits (0, 2, 3, and 4). The protocol implements a staking and governance system with time-weighted voting, reward distribution, and treasury management.

### Audit Scope

**Core Contracts Reviewed:**
- `LevrFactory_v1.sol` - Project registration and configuration
- `LevrStaking_v1.sol` - Staking and reward distribution
- `LevrGovernor_v1.sol` - Governance and voting
- `LevrTreasury_v1.sol` - Treasury management
- `LevrStakedToken_v1.sol` - Non-transferable staked tokens
- `LevrFeeSplitter_v1.sol` - Fee distribution
- `RewardMath.sol` - Mathematical reward calculations

### Overall Security Posture

**Strengths:**
- ✅ Comprehensive reentrancy protection using OpenZeppelin's `ReentrancyGuard`
- ✅ SafeERC20 for all token interactions
- ✅ Non-transferable staked tokens prevent vote buying
- ✅ Time-weighted voting prevents flash loan governance attacks
- ✅ Config snapshots prevent mid-vote manipulation
- ✅ Checks-effects-interactions pattern consistently applied
- ✅ Extensive test coverage (556 unit tests, 100% passing)
- ✅ Previous audit findings addressed

**Areas of Concern:**
- ⚠️ Complex voting power calculation vulnerable to precision loss
- ⚠️ Adaptive quorum system has potential edge cases
- ⚠️ Whitelist management lacks timelocks
- ⚠️ Centralization risks from factory owner powers
- ⚠️ Gas optimization opportunities in loops

---

## Findings Summary

| Severity | Count | Status |
|----------|-------|--------|
| CRITICAL | 0 | N/A |
| HIGH | 3 | 🔍 Review Required |
| MEDIUM | 5 | ⚠️ Recommended Fixes |
| LOW | 7 | 📝 Optional Improvements |
| INFO | 4 | 💡 Best Practices |
| **TOTAL** | **19** | - |

---

## Critical Findings

### None Identified

The protocol demonstrates strong security fundamentals with no critical vulnerabilities discovered during this audit. Previous critical issues from Audits 0-4 have been addressed.

---

## High Severity Findings

### [H-1] Voting Power Precision Loss in Weighted Average Calculation

**Location:** `LevrStaking_v1.sol:676-683`

**Description:**
The `_onStakeNewTimestamp()` function calculates weighted average voting power using integer division, which can lead to precision loss when staking small amounts relative to existing balance.

```solidity
// Current code
uint256 newTimeAccumulated = (oldBalance * timeAccumulated) / newTotalBalance;
newStartTime = block.timestamp - newTimeAccumulated;
```

**Impact:**
- Users lose small amounts of accumulated voting power on each stake
- Compounds over many staking operations
- Affects governance participation unfairly

**Proof of Concept:**
```solidity
// Example: User has 100 tokens staked for 10 days
// oldBalance = 100e18, timeAccumulated = 10 days = 864000 seconds
// User stakes 1 wei more
// newTotalBalance = 100e18 + 1
// newTimeAccumulated = (100e18 * 864000) / (100e18 + 1)
//                    = 863999.999... → truncates to 863999
// Lost: 1 second of accumulation per wei staked
```

**Recommendation:**
1. Add minimum stake amount to prevent dust attacks
2. Consider using higher precision (e.g., 1e27 instead of 1e18) for intermediate calculations
3. Document expected precision loss in NatSpec

**Status:** 🔍 Acknowledged - Trade-off between precision and gas cost

---

### [H-2] Adaptive Quorum Manipulation via Stake Dilution

**Location:** `LevrGovernor_v1.sol:422-446`

**Description:**
The adaptive quorum mechanism uses `min(snapshotSupply, currentSupply)` to prevent dilution attacks. However, this can be gamed:

```solidity
uint256 effectiveSupply = currentSupply < snapshotSupply ? currentSupply : snapshotSupply;
```

**Attack Scenario:**
1. Attacker proposes a malicious proposal
2. After proposal snapshot, attacker unstakes massively (reducing currentSupply)
3. This reduces effective quorum requirement
4. Attacker's remaining votes now have higher relative weight
5. Malicious proposal passes with fewer absolute votes

**Impact:**
- Governance manipulation
- Malicious proposals can pass with artificially lowered quorum

**Recommendation:**
1. Use `max(snapshotSupply, currentSupply)` instead of `min()`
2. Add minimum absolute quorum floor that cannot be diluted
3. Consider time-lock period after proposal creation before unstaking affects quorum

**Status:** ⚠️ **CRITICAL** - Requires immediate review and potential redesign

**Reference:** Similar to Audit 4's CRITICAL-2 finding

---

### [H-3] Token Admin Can Manipulate Rewards via Whitelist

**Location:** `LevrStaking_v1.sol:228-263` (whitelistToken), `LevrStaking_v1.sol:266-298` (unwhitelistToken)

**Description:**
Token admin has immediate, unrestricted power to whitelist/unwhitelist reward tokens without timelock.

**Attack Scenarios:**
1. **Griefing:** Admin unwhitelists token with pending rewards (requires 0 balance, but timing attack possible)
2. **Manipulation:** Admin whitelists malicious ERC20 contract that:
   - Reverts on transfer (DoS attack on claims)
   - Has fee-on-transfer behavior (accounting mismatch)
   - Tracks claiming addresses (privacy violation)

**Impact:**
- User funds at risk if malicious token whitelisted
- Distribution failures if token removed at wrong time

**Recommendation:**
1. Add timelock to whitelist changes (24-48 hours)
2. Implement 2-step whitelist process (propose → execute)
3. Add admin multisig requirement for whitelist changes
4. Consider using factory-level whitelist instead of per-project

**Status:** ⚠️ Recommended - Add governance or timelock

---

## Medium Severity Findings

### [M-1] Centralized Factory Owner Has Excessive Powers

**Location:** `LevrFactory_v1.sol` (various `onlyOwner` functions)

**Description:**
Factory owner can:
- Update global config affecting all projects
- Add/remove trusted Clanker factories
- Verify/unverify projects (giving them override powers)
- Update initial whitelist for new projects

**Impact:**
- Single point of failure
- Rug pull risk if owner key compromised
- Censorship risk (can prevent project registration)

**Recommendation:**
1. Implement multisig for factory owner (3-of-5 minimum)
2. Add timelock to sensitive operations (48-72 hours)
3. Consider transitioning to DAO governance
4. Emit events for all admin actions (already done ✅)

**Status:** ⚠️ Recommended - See `spec/MULTISIG.md` for deployment plan

---

### [M-2] First Staker Stream Restart Can Be Gamed

**Location:** `LevrStaking_v1.sol:112-132`

**Description:**
When first staker joins after `_totalStaked == 0`, all paused streams restart. This creates MEV opportunity:

```solidity
if (isFirstStaker) {
    // Restart all paused streams
    for (uint256 i = 0; i < len; i++) {
        if (rtState.streamTotal > 0) {
            _resetStreamForToken(rt, rtState.streamTotal);
        }
    }
}
```

**Attack Scenario:**
1. Protocol has large unvested rewards from previous cycle
2. All stakers unstake, bringing `_totalStaked` to 0
3. Attacker front-runs next staker to be "first" and capture more rewards

**Impact:**
- Unfair reward distribution to first staker after pause
- MEV extraction opportunity

**Mitigation:**
The protocol already uses vesting to mitigate this (rewards stream over time), reducing impact.

**Recommendation:**
1. Document this behavior clearly for users
2. Consider small minimum stake requirement that can't be fully unstaked
3. Monitor for suspicious stake/unstake patterns

**Status:** ⚠️ Acknowledged - Vesting design already mitigates

---

### [M-3] Unbounded Loop in `_settleAllPools()`

**Location:** `LevrStaking_v1.sol:587-592`

**Description:**
Function iterates over all reward tokens without gas limit checks:

```solidity
function _settleAllPools() internal {
    uint256 len = _rewardTokens.length;
    for (uint256 i = 0; i < len; i++) {
        _settlePoolForToken(_rewardTokens[i]);
    }
}
```

**Impact:**
- If too many reward tokens accumulate, `stake()` can revert due to gas limit
- DoS attack vector if admin maliciously whitelists many tokens
- Users unable to stake/unstake

**Recommendation:**
1. Add maximum reward token limit (e.g., 20-50 tokens)
2. Consider lazy settlement (settle only when claiming specific token)
3. Add emergency pause if token array grows too large

**Current Mitigation:**
- `cleanupFinishedRewardToken()` allows removal of finished tokens ✅
- Whitelist control limits token additions ✅

**Status:** ⚠️ Low risk due to mitigations, but add hard cap recommended

---

### [M-4] Proposal Execution Try-Catch Can Silently Fail

**Location:** `LevrGovernor_v1.sol:199-213`

**Description:**
Proposal execution uses try-catch, which can mask failures:

```solidity
try this._executeProposal(...) {
    emit ProposalExecuted(proposalId, _msgSender());
} catch Error(string memory reason) {
    emit ProposalExecutionFailed(proposalId, reason);
} catch (bytes memory) {
    emit ProposalExecutionFailed(proposalId, 'execution_reverted');
}
```

**Impact:**
- Proposal marked as executed even if transfer failed
- Cycle advances without actual fund movement
- Users may not notice failure without monitoring events

**Recommendation:**
1. Add `executionSuccess` boolean to Proposal struct
2. Allow re-execution of failed proposals within same cycle
3. Improve event emission to include failure details
4. Consider reverting on failure instead of catching

**Status:** ⚠️ Design decision - Current approach prevents reverting tokens from blocking cycle

---

### [M-5] Fee-on-Transfer Token Accounting Mismatch in FeeSplitter

**Location:** `LevrFeeSplitter_v1.sol:101-143`

**Description:**
FeeSplitter distributes based on balance without checking actual received amount:

```solidity
uint256 balance = IERC20(rewardToken).balanceOf(address(this));
// ...
uint256 amount = (balance * split.bps) / BPS_DENOMINATOR;
IERC20(rewardToken).safeTransfer(split.receiver, amount);
```

If token has transfer fees, recipients receive less than calculated.

**Impact:**
- Recipients receive less than expected
- Final split may fail due to insufficient balance
- Accounting errors in distribution state

**Mitigation:**
Staking contract already handles fee-on-transfer tokens ✅ (Audit 3 C-2 fix)

**Recommendation:**
1. Apply same fix to FeeSplitter (measure before/after transfer)
2. Document that fee-on-transfer tokens are unsupported
3. Add token validation in `configureSplits()` to reject such tokens

**Status:** ⚠️ Recommended - Apply C-2 fix pattern to FeeSplitter

---

## Low Severity Findings

### [L-1] Missing Events for Critical State Changes

**Locations:**
- `LevrStaking_v1.sol:658-683` (_onStakeNewTimestamp)
- `LevrStaking_v1.sol:689-714` (_onUnstakeNewTimestamp)

**Description:**
Voting power timestamp updates don't emit events, making off-chain tracking difficult.

**Recommendation:**
Add events:
```solidity
event VotingPowerUpdated(address indexed user, uint256 oldStartTime, uint256 newStartTime, uint256 votingPower);
```

**Status:** 📝 Nice-to-have for monitoring

---

### [L-2] Lack of Zero Amount Checks in Some Functions

**Location:** `LevrFeeSplitter_v1.sol:85-96` (recoverDust)

**Description:**
`recoverDust()` doesn't revert on zero balance, wasting gas.

**Recommendation:**
```solidity
function recoverDust(address token, address to) external {
    _onlyTokenAdmin();
    if (to == address(0)) revert ZeroAddress();

    uint256 balance = IERC20(token).balanceOf(address(this));
    if (balance == 0) revert NothingToRecover(); // Add this check

    IERC20(token).safeTransfer(to, balance);
    emit DustRecovered(token, to, balance);
}
```

**Status:** 📝 Minor gas optimization

---

### [L-3] Inconsistent Use of `_msgSender()` vs `msg.sender`

**Location:** `LevrStakedToken_v1.sol:29` and `LevrStakedToken_v1.sol:36`

**Description:**
Uses `msg.sender` directly instead of `_msgSender()` for ERC2771 compatibility.

**Current Code:**
```solidity
if (msg.sender != staking) revert ILevrStaking_v1.OnlyFactory();
```

**Impact:**
Breaks meta-transaction support if used through trusted forwarder.

**Recommendation:**
Use `_msgSender()` consistently or document why not needed.

**Status:** 📝 Consistency improvement

---

### [L-4] Magic Numbers in Code

**Locations:**
- Various uses of `10000` for BPS
- `86400` for seconds per day

**Recommendation:**
Use constants:
```solidity
uint256 public constant BPS_DENOMINATOR = 10_000;
uint256 public constant SECONDS_PER_DAY = 86400;
```

**Status:** ✅ Already implemented in most contracts

---

### [L-5] Missing Input Validation

**Location:** `LevrFactory_v1.sol:252-263` (updateInitialWhitelist)

**Description:**
No check for duplicate tokens in whitelist array.

**Recommendation:**
```solidity
function updateInitialWhitelist(address[] calldata tokens) external override onlyOwner {
    delete _initialWhitelistedTokens;

    for (uint256 i = 0; i < tokens.length; i++) {
        if (tokens[i] == address(0)) revert ZeroAddress();

        // Check for duplicates
        for (uint256 j = 0; j < i; j++) {
            if (tokens[i] == tokens[j]) revert DuplicateToken();
        }

        _initialWhitelistedTokens.push(tokens[i]);
    }

    emit InitialWhitelistUpdated(tokens);
}
```

**Status:** 📝 Input validation improvement

---

### [L-6] No Emergency Pause Mechanism

**Description:**
Contracts lack pausable functionality for emergency situations.

**Recommendation:**
1. Implement OpenZeppelin's `Pausable` for critical functions
2. Add admin function to pause staking/claiming during emergency
3. Document emergency procedures

**Status:** 📝 Emergency preparedness

---

### [L-7] Floating Pragma in Some Files

**Location:** Check all Solidity files for pragma

**Description:**
Using `^0.8.30` instead of fixed `0.8.30` can lead to inconsistent compilation.

**Recommendation:**
Lock pragma version:
```solidity
pragma solidity 0.8.30; // ✅ Good
// Not: pragma solidity ^0.8.30; // ❌ Avoid
```

**Status:** ✅ Already using fixed pragma in reviewed files

---

## Informational Findings

### [I-1] Gas Optimization: Cache Array Length

**Locations:**
- Multiple loops throughout codebase

**Recommendation:**
```solidity
// Instead of:
for (uint256 i = 0; i < _rewardTokens.length; i++)

// Use:
uint256 len = _rewardTokens.length;
for (uint256 i = 0; i < len; i++)
```

**Status:** ✅ Already implemented in most loops

---

### [I-2] Consider Using Custom Errors Everywhere

**Description:**
Mix of require strings and custom errors. Custom errors save gas.

**Recommendation:**
Replace all `require()` statements with custom errors:
```solidity
// Current: require(duration != 0, 'ZERO_DURATION');
// Better: if (duration == 0) revert ZeroDuration();
```

**Status:** 💡 Gas optimization

---

### [I-3] NatSpec Documentation Completeness

**Description:**
Some functions lack complete NatSpec (@param, @return).

**Recommendation:**
Add complete documentation for all public/external functions.

**Status:** 💡 Documentation improvement

---

### [I-4] Consider Using OpenZeppelin AccessControl

**Description:**
Custom access control could be replaced with battle-tested OZ implementation.

**Recommendation:**
```solidity
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

contract LevrFactory_v1 is AccessControl {
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant VERIFIER_ROLE = keccak256("VERIFIER_ROLE");
    // ...
}
```

**Status:** 💡 Architecture consideration for V2

---

## Architecture Review

### Positive Patterns

1. **Separation of Concerns:** Clear separation between Factory, Staking, Governor, Treasury
2. **Upgradeability:** Proxy-like pattern via Factory for future upgrades
3. **Battle-Tested Libraries:** OpenZeppelin contracts extensively used
4. **Meta-Transactions:** ERC2771 support for gasless transactions
5. **Defensive Programming:** Extensive input validation and safety checks

### Potential Improvements

1. **Modularity:** Consider extracting reward streaming logic into separate library
2. **Access Control:** Implement role-based access instead of simple ownership
3. **Emergency Handling:** Add circuit breakers and emergency pause
4. **Time Locks:** Add time delays for sensitive admin operations

---

## Testing & Coverage

### Strengths
- ✅ 556/556 unit tests passing (100%)
- ✅ Comprehensive edge case testing
- ✅ Attack scenario testing
- ✅ Integration tests exist

### Recommendations
1. Add formal verification for critical math operations
2. Implement fuzzing tests for reward calculations
3. Add stress tests for gas limits on large arrays
4. Test multi-cycle governance scenarios

---

## Comparison with Previous Audits

### Audit 0 (Oct 2025) - 8 Findings
**Status:** ✅ All fixed

### Audit 2 (Oct 2025) - 13 Findings
**Status:** ✅ All fixed

### Audit 3 (Oct 2025) - 31 Findings
**Status:** ✅ Phase 1 complete (17 fixed), 14 remaining

### Audit 4 (Oct 2025) - 17 Findings
**Status:** ⚠️ Critical findings addressed, see AUDIT_STATUS.md

### This Audit - 19 Findings
**New Issues:** 19 (3 High, 5 Medium, 7 Low, 4 Info)
**Overlap:** Some findings echo concerns from previous audits

---

## Recommendations Priority

### Immediate (Week 1)
1. **[H-2]** Review adaptive quorum mechanism for manipulation resistance
2. **[M-3]** Add hard cap on reward token array size
3. **[L-5]** Add duplicate check in whitelist update

### Short-term (Weeks 2-4)
1. **[H-3]** Implement timelock for whitelist changes
2. **[M-1]** Deploy factory with multisig (per MULTISIG.md)
3. **[M-5]** Apply fee-on-transfer fix to FeeSplitter
4. **[L-6]** Add emergency pause mechanism

### Medium-term (Months 1-3)
1. **[H-1]** Research precision improvement options
2. **[M-2]** Monitor for first-staker gaming patterns
3. **[M-4]** Enhance proposal execution failure handling
4. **[I-4]** Evaluate AccessControl migration

### Long-term (V2 Considerations)
1. Full OpenZeppelin AccessControl integration
2. Formal verification of reward math
3. Modular architecture refactor
4. Gas optimization pass

---

## Conclusion

The Levr Protocol V1 demonstrates **strong security fundamentals** with comprehensive protections against common vulnerabilities. The development team has addressed multiple rounds of audit findings, showing commitment to security.

### Key Strengths
- Robust reentrancy protection
- Time-weighted voting prevents flash loans
- Non-transferable tokens prevent vote buying
- Extensive test coverage
- Battle-tested dependencies

### Areas for Improvement
- Adaptive quorum manipulation risk (H-2)
- Centralization concerns (M-1, H-3)
- Precision loss in voting power (H-1)
- Unbounded loops (M-3)

### Overall Assessment

**Security Rating:** 🟢 **STRONG** (with recommendations)

The protocol is suitable for mainnet deployment after addressing HIGH severity findings, particularly H-2 (adaptive quorum). Medium and Low severity findings should be addressed in subsequent updates.

### Sign-off

This audit represents a comprehensive review of the Levr Protocol V1 as of November 4, 2025. The findings and recommendations are provided to enhance the protocol's security and robustness.

**Recommended Actions:**
1. Address H-2 adaptive quorum issue before mainnet
2. Implement multisig and timelock for admin operations
3. Add hard caps on unbounded arrays
4. Continue comprehensive testing and monitoring

---

**Report Version:** 1.0
**Date:** November 4, 2025
**Auditor:** AI Security Review
**Contact:** See project repository for follow-up
