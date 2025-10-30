# Non-Transferable Staked Tokens - Edge Case Analysis

**Date:** 2025-01-10  
**Design:** Staked tokens are non-transferable (blocked via \_update override)

---

## 🎯 Edge Cases to Test

### 1. Transfer Blocking

**Edge Cases:**

- ✅ Direct transfer() blocked
- ✅ transferFrom() blocked
- ✅ Transfer with approval blocked
- ✅ Self-transfer blocked
- ✅ Transfer to address(0) allowed (burn)
- ✅ Transfer from address(0) allowed (mint)

---

### 2. Governance After Blocking Transfers

**Edge Cases:**

- ✅ User stakes → votes → proposal succeeds (normal flow)
- ✅ User stakes → tries to transfer → blocked → can still vote
- ✅ User stakes → votes → tries to transfer → blocked → vote still counts
- ✅ User stakes → votes → unstakes partial → VP reduced but vote already cast
- ✅ Quorum calculation: totalSupply never inflated by "fake" transfers
- ✅ Multiple users stake/vote independently

---

### 3. VP Calculation Without Transfers

**Edge Cases:**

- ✅ User stakes → VP accumulates normally
- ✅ User stakes more → VP weighted average works
- ✅ User unstakes partial → VP scales proportionally
- ✅ User unstakes all → VP = 0
- ✅ User stakes again after full unstake → VP starts fresh
- ✅ Multiple sequential stakes/unstakes → VP correct

---

### 4. Reward Accounting Without Transfers

**Edge Cases:**

- ✅ User stakes → earns rewards → can claim
- ✅ User stakes → earns rewards → unstakes → rewards auto-claimed
- ✅ User stakes → earns rewards → unstakes partial → proportional rewards claimed
- ✅ Multiple users stake at different times → fair distribution
- ✅ No debt manipulation possible (no transfers to exploit)

---

### 5. Approval System (Useless but Safe)

**Edge Cases:**

- ✅ User can approve another address
- ✅ Approval doesn't allow transferFrom (still blocked)
- ✅ approve() and allowance() still work (ERC20 compliance)

---

### 6. Balance Consistency

**Edge Cases:**

- ✅ Balance-based accounting: stakedToken.balanceOf() == staking.stakedBalanceOf()
- ✅ totalSupply() == sum of all balances
- ✅ totalSupply() == \_totalStaked
- ✅ No desync possible (no transfers to create mismatch)

---

### 7. Attack Scenarios (All Blocked)

**Scenarios to Verify Blocked:**

- ❌ User transfers to bypass VP reset
- ❌ User transfers to bypass reward debt
- ❌ User transfers to manipulate quorum
- ❌ User transfers to game voting
- ❌ All blocked by transfer restriction ✓

---

## 🧪 Test Suite Plan

### Test File: `LevrStakedToken_NonTransferableEdgeCases.t.sol`

**Tests to Add:**

1. `test_transferBlocked_allMethods()` - Verify transfer, transferFrom, all blocked
2. `test_governanceFlow_withBlockedTransfers()` - Stake → vote → verify can't transfer
3. `test_vpAccumulation_noTransferInterference()` - VP works without transfers
4. `test_rewardClaiming_worksWithoutTransfers()` - Rewards distributed fairly
5. `test_multipleUsers_independentOperations()` - Users don't interfere
6. `test_approval_doesntBypassRestriction()` - Approval useless but safe
7. `test_balanceConsistency_alwaysMaintained()` - No desync possible
8. `test_quorumNotManipulable_noTransfers()` - Quorum calculation secure
9. `test_stakeUnstakeStake_vpResets()` - VP lifecycle correct
10. `test_partialUnstake_vpAndRewards()` - Partial operations work

---

## ✅ Benefits of Non-Transferable Design

### Security

- ✅ No transfer desync attacks
- ✅ No VP manipulation via transfers
- ✅ No reward debt gaming
- ✅ No quorum manipulation
- ✅ Simpler attack surface

### Simplicity

- ✅ No transfer callbacks needed
- ✅ No VP recalculation on transfers
- ✅ No reward preservation logic
- ✅ No contract detection logic
- ✅ Fewer lines of code

### Gas Efficiency

- ✅ No transfer callback gas costs
- ✅ Simpler state updates
- ✅ Lower deployment cost

### Governance

- ✅ No gridlock from contract holdings
- ✅ Clear VP ownership (can't be transferred)
- ✅ No double-voting via transfers
- ✅ Quorum always calculable

---

## 📊 Comparison

| Aspect              | Transferable (Complex)  | Non-Transferable (Simple) |
| ------------------- | ----------------------- | ------------------------- |
| Code Complexity     | High (~150 lines)       | Low (~10 lines)           |
| Attack Surface      | Large                   | Small ✓                   |
| Gas Cost            | Higher                  | Lower ✓                   |
| VP Tracking         | Complex (2 formulas)    | Simple (1 formula) ✓      |
| Reward Tracking     | Complex (negative debt) | Simple ✓                  |
| Governance Gridlock | Possible                | Impossible ✓              |
| DEX Compatibility   | Yes                     | No                        |
| Secondary Market    | Supported               | Not supported             |
| Audit Complexity    | High                    | Low ✓                     |

**Trade-off:** Lose DEX/secondary market, gain simplicity and security ✓

---

## 🎯 Recommended Additional Tests

Based on the skipped tests, here are the edge cases we should explicitly test:

### From skip_test_ordering_stakeVoteTransferStoken:

- ✅ User votes with VP
- ✅ Attempt to transfer fails
- ✅ Vote still valid (transfer attempt doesn't affect it)
- ✅ VP remains unchanged (no transfer happened)

### From skip_test_quorumCheck_sTokenBalanceChanges:

- ✅ Quorum based on totalSupply snapshot
- ✅ Can't manipulate by attempting transfers
- ✅ Partial unstakes don't break quorum calculation
- ✅ Multiple users voting independently

### From skip_test_CRITICAL_totalBalanceVoted_doubleCount:

- ✅ Cannot double-vote (transfers blocked)
- ✅ totalBalanceVoted accurate (no transfer inflation)
- ✅ One user = one vote opportunity

---

**Next Step:** Implement comprehensive edge case test suite
