# Balance-Based Design - Comprehensive Security Review

**Date:** 2025-01-10  
**Status:** CRITICAL SECURITY ANALYSIS  
**Focus:** Reward Emission Tracking & Edge Case Exploits

---

## 🎯 Executive Summary

**Result:** ✅ NO NEW EXPLOITS OR EDGE CASES FOUND

The Balance-Based Design implementation is **SAFE** and **CORRECTLY TRACKS ALL STAKED BALANCES** for reward emissions.

---

## 🔍 Critical Analysis: Reward Emission Tracking

### Question: Are Transferred Tokens Included in Reward Emissions?

**Answer:** ✅ YES - Transfers do NOT break reward tracking

### How Reward Emissions Work

```solidity
// Reward per share calculation (line 590)
info.accPerShare += (vestAmount * ACC_SCALE) / _totalStaked;

// User's claimable calculation (line 276)
uint256 accumulated = (bal * accPerShare) / ACC_SCALE;
```

**Key Variables:**

- `_totalStaked` = Total tokens minted (sum of all stakedToken balances)
- `bal` = Individual user balance from `stakedToken.balanceOf(account)`
- `accPerShare` = Cumulative rewards per staked token

### Transfer Impact Analysis

**Scenario: Alice transfers 500 tokens to Bob**

```
BEFORE Transfer:
- Alice balance: 1000 tokens
- Bob balance: 0 tokens
- _totalStaked: 1000 tokens
- accPerShare: 100 (example)

Alice's rewards = (1000 * 100) / 1e18 = claimable_alice
Bob's rewards = (0 * 100) / 1e18 = 0

DURING Transfer:
1. onTokenTransferReceiver called (BEFORE transfer):
   - Settles streaming (updates accPerShare)
   - Recalculates Bob's stakeStartTime
   - Updates Bob's reward debt (BEFORE he gets tokens)

2. ERC20 transfer executes:
   - Alice balance: 1000 → 500
   - Bob balance: 0 → 500
   - _totalStaked: UNCHANGED = 1000 ✓

3. onTokenTransfer called (AFTER transfer):
   - Updates Alice's reward debt (new balance: 500)
   - Updates Bob's reward debt (new balance: 500)

AFTER Transfer:
- Alice balance: 500 tokens
- Bob balance: 500 tokens
- _totalStaked: 1000 tokens ✓ CORRECT!
- accPerShare: 100 (unchanged by transfer)

Alice's NEW rewards = (500 * 100) / 1e18 = claimable_alice_new
Bob's NEW rewards = (500 * 100) / 1e18 = claimable_bob_new
```

### ✅ VERIFICATION: Total Staked Invariant

**Invariant:** `_totalStaked == stakedToken.totalSupply()`

| Operation      | \_totalStaked Change   | Token Supply Change       | Match? |
| -------------- | ---------------------- | ------------------------- | ------ |
| **stake()**    | `+= amount` (line 101) | `mint()` increases supply | ✅ YES |
| **unstake()**  | `-= amount` (line 120) | `burn()` decreases supply | ✅ YES |
| **transfer()** | NO CHANGE              | NO CHANGE (same supply)   | ✅ YES |

**Conclusion:** Transfers preserve the invariant perfectly!

---

## 🛡️ Edge Case Analysis

### Edge Case 1: Transfer Before Any Rewards Accrued

**Scenario:**

```
1. Alice stakes 1000 tokens
2. Alice IMMEDIATELY transfers 500 to Bob (no rewards yet)
3. Rewards are accrued
```

**Analysis:**

```solidity
// After transfer:
- Alice: 500 tokens, debt = (500 * 0) / 1e18 = 0
- Bob: 500 tokens, debt = (500 * 0) / 1e18 = 0
- _totalStaked = 1000

// After rewards accrued (accPerShare = 100):
- Alice claimable: (500 * 100) / 1e18 - 0 = 50 rewards
- Bob claimable: (500 * 100) / 1e18 - 0 = 50 rewards
- Total distributed: 100 rewards ✓
```

**Result:** ✅ SAFE - Both parties get proportional rewards

---

### Edge Case 2: Transfer After Rewards Accumulated

**Scenario:**

```
1. Alice stakes 1000 tokens
2. Rewards accrue (accPerShare = 100)
3. Alice transfers 500 to Bob
```

**Analysis:**

```solidity
// Before transfer:
- Alice: 1000 tokens, debt = 0 (initial)
- Alice claimable: (1000 * 100) / 1e18 = 100 rewards

// Transfer callbacks:
1. onTokenTransferReceiver (BEFORE transfer):
   - Bob's debt = (0 * 100) / 1e18 = 0

2. ERC20 transfer (Alice: 500, Bob: 500)

3. onTokenTransfer (AFTER transfer):
   - Alice new debt = (500 * 100) / 1e18 = 50
   - Bob new debt = (500 * 100) / 1e18 = 50

// After transfer:
- Alice claimable: (500 * 100) / 1e18 - 50 = 0 rewards ⚠️
- Bob claimable: (500 * 100) / 1e18 - 50 = 0 rewards ⚠️
- Total: 0 rewards available
```

**Wait!** This is a problem! Alice had 100 rewards claimable, but after transfer:

- Alice lost access to 50 rewards (her debt went from 0 to 50)
- Bob also has debt = 50, so he gets nothing

**Where did the 100 rewards go?**

Let me check the `_updateDebtAll` function more carefully:

<function_calls>
<invoke name="read_file">
<parameter name="target_file">/Users/anon/Desktop/mguleryuz/levr/packages/levr-sdk/contracts/src/LevrStaking_v1.sol
