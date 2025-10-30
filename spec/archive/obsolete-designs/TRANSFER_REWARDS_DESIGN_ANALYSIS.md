# Transfer Rewards Design - Analysis & Solutions

**Date:** 2025-01-10  
**Problem:** Auto-claim on transfer sends rewards to contracts (e.g., Uniswap pools)  
**Status:** DESIGN DECISION REQUIRED

---

## 🎯 The Problem

### Current Implementation Issue

**Scenario: Alice sells staked tokens on Uniswap**

```
Initial State:
├─ Alice: 1000 staked tokens
├─ Alice earned: 500 WETH rewards (accumulated)
└─ Uniswap pool: Ready to buy

Alice sells on Uniswap:
1. Transfer: Alice → Uniswap pool
2. Auto-claim triggers
3. 500 WETH sent to Uniswap pool address ❌
4. Rewards distributed to LP holders (not Alice!)

Result: Alice LOSES 500 WETH she earned ❌
```

**This is UNACCEPTABLE for users!**

---

## 💡 Solution Options

### Option 1: No Auto-Claim, Debt Transfers with Tokens ✅

**Concept:** Rewards "belong" to whoever holds the tokens, debt transfers with balance

**How It Works:**

```solidity
// NO auto-claim on transfer
// Debt stays proportional to balance

Transfer: Alice (1000 tokens, debt=0, 500 claimable) → Bob (500 tokens)

After transfer:
├─ Alice: 500 tokens
│   ├─ Old debt: 0
│   ├─ New debt: (500 * accPerShare) / ACC_SCALE
│   └─ Claimable: 0 (debt updated, lost unclaimed rewards)
│
└─ Bob: 500 tokens
    ├─ Old debt: 0
    ├─ New debt: (500 * accPerShare) / ACC_SCALE
    └─ Claimable: 0 (starts fresh)

Problem: Alice still loses rewards! ❌
```

**Verdict:** ❌ Doesn't solve the problem

---

### Option 2: Claim Before Transfer (User Responsibility) ⭐

**Concept:** Users must manually claim before transferring

**How It Works:**

```solidity
// Remove auto-claim from transfer callback
// Just update debt without settling

function onTokenTransfer(address from, address to, uint256 amount) external {
    // NO _settleAll() call

    // Calculate balances
    uint256 senderNewBalance = senderOldBalance - amount;
    uint256 receiverNewBalance = receiverOldBalance + amount;

    // Update VP
    // Update debt for NEW balances
    _updateDebtAll(from, senderNewBalance);
    _updateDebtAll(to, receiverNewBalance);
}
```

**User Experience:**

```
Alice wants to sell on Uniswap:
1. Alice calls claimRewards() first ← Manual step
2. Alice receives her 500 WETH ✓
3. Alice sells tokens on Uniswap
4. Uniswap receives tokens but 0 rewards ✓
```

**Pros:**

- ✅ User keeps their earned rewards
- ✅ Simple implementation
- ✅ No rewards sent to contracts
- ✅ User has full control

**Cons:**

- ❌ Extra transaction required (gas cost)
- ❌ User might forget to claim first
- ❌ If they forget, they LOSE rewards

**What happens if user forgets:**

```
Alice forgets to claim, sells on Uniswap:
├─ Transfer happens
├─ Alice debt updated: (500 * accPerShare)
├─ Alice accumulated: (500 * accPerShare)
├─ Alice claimable: accumulated - debt = 0
└─ Alice LOSES her 500 WETH ❌

Her old rewards are lost because debt was reset!
```

**Verdict:** ❌ Too risky - users will forget and lose funds

---

### Option 3: "Frozen" Claimable Until User Claims ⭐⭐

**Concept:** Snapshot claimable at transfer time, preserve it

**How It Works:**

```solidity
// Add new mapping to track frozen claimable
mapping(address => mapping(address => uint256)) private _frozenClaimable;

function onTokenTransfer(address from, address to, uint256 amount) external {
    _settleStreamingAll();

    // Calculate sender's current claimable BEFORE debt update
    uint256 senderOldBalance = balanceOf(from);
    uint256 senderAccumulated = (senderOldBalance * accPerShare) / ACC_SCALE;
    uint256 senderDebt = _rewardDebt[from][token];
    uint256 senderClaimable = senderAccumulated - senderDebt;

    // FREEZE sender's claimable (they can claim later)
    _frozenClaimable[from][token] += senderClaimable;

    // Update debt for new balances
    _updateDebtAll(from, senderNewBalance);
    _updateDebtAll(to, receiverNewBalance);
}

function claimRewards(address[] calldata tokens, address to) external {
    for (each token) {
        // Claim frozen amount + current claimable
        uint256 frozen = _frozenClaimable[msg.sender][token];
        uint256 current = calculateCurrentClaimable();
        uint256 total = frozen + current;

        _frozenClaimable[msg.sender][token] = 0;
        // Transfer total to user
    }
}
```

**User Experience:**

```
Alice sells on Uniswap:
1. Transfer happens (no auto-claim)
2. Alice's 500 WETH "frozen" in _frozenClaimable
3. Uniswap receives tokens but 0 rewards
4. Later, Alice calls claimRewards()
5. Alice receives her frozen 500 WETH ✓
```

**Pros:**

- ✅ User keeps their earned rewards
- ✅ No extra transaction required before transfer
- ✅ Works with Uniswap/DEXs
- ✅ User claims when they want

**Cons:**

- ❌ Additional storage (new mapping)
- ❌ More complex accounting
- ❌ Higher gas on transfer (snapshot calculation)
- ❌ Need to iterate all tokens to freeze

**Verdict:** ✅ Solves the problem but adds complexity

---

### Option 4: Claimable Belongs to Token Holder (Proportional Split) ⭐⭐⭐

**Concept:** Debt doesn't reset on transfer, scales proportionally

**How It Works:**

```solidity
function onTokenTransfer(address from, address to, uint256 amount) external {
    _settleStreamingAll();

    // Get OLD balances and debts
    uint256 senderOldBalance = balanceOf(from);
    uint256 receiverOldBalance = balanceOf(to);

    // Calculate proportion being transferred
    uint256 proportion = (amount * 1e18) / senderOldBalance;

    // Transfer DEBT proportionally with tokens
    for (each reward token) {
        int256 senderOldDebt = _rewardDebt[from][token];
        int256 debtToTransfer = (senderOldDebt * proportion) / 1e18;

        _rewardDebt[from][token] -= debtToTransfer;
        _rewardDebt[to][token] += debtToTransfer;
    }

    // Update VP
    // NO need to update debt again (already transferred)
}
```

**Example:**

```
Before Transfer:
├─ Alice: 1000 tokens, debt=0, accumulated=500, claimable=500 WETH
└─ Bob: 0 tokens, debt=0

Transfer: Alice → Bob (500 tokens = 50%)

Debt Transfer:
├─ Alice old debt: 0
├─ Debt to transfer: 0 * 50% = 0
├─ Alice new debt: 0
└─ Bob new debt: 0 + 0 = 0

After Transfer:
├─ Alice: 500 tokens, debt=0
│   ├─ Accumulated: (500 * accPerShare)
│   └─ Claimable: (500 * accPerShare) - 0 = 250 WETH ✓
│
└─ Bob: 500 tokens, debt=0
    ├─ Accumulated: (500 * accPerShare)
    └─ Claimable: (500 * accPerShare) - 0 = 250 WETH ✓

Total claimable: 250 + 250 = 500 WETH ✓ (preserved!)
```

**But wait, there's an issue!**

If `accPerShare` increases AFTER Alice staked but BEFORE transfer:

```
Alice stakes at T0 when accPerShare = 0
Rewards accrue, accPerShare = 1000
Alice has: accumulated = 1000 * 1000 = 1M, debt = 0, claimable = 1M

Transfer 50% to Bob:
├─ Alice: 500 tokens, debt = 0
│   └─ Claimable: (500 * 1000) - 0 = 500k (LOST 500k!) ❌
└─ Bob: 500 tokens, debt = 0
    └─ Claimable: (500 * 1000) - 0 = 500k (FREE rewards!) ❌
```

**Problem:** Bob gets rewards he didn't earn! ❌

**Verdict:** ❌ Creates unfair reward distribution

---

### Option 5: Debt Transfers with Balance ⭐⭐⭐⭐

**Concept:** Transfer BOTH balance and proportional debt

**How It Works:**

```solidity
function onTokenTransfer(address from, address to, uint256 amount) external {
    _settleStreamingAll();

    uint256 senderOldBalance = balanceOf(from);
    uint256 receiverOldBalance = balanceOf(to);

    // Calculate what proportion is being transferred
    uint256 transferProportion = (amount * ACC_SCALE) / senderOldBalance;

    for (each reward token) {
        uint256 acc = _rewardInfo[token].accPerShare;

        // Calculate sender's current claimable
        int256 senderOldDebt = _rewardDebt[from][token];
        uint256 senderAccumulated = (senderOldBalance * acc) / ACC_SCALE;
        int256 senderClaimable = int256(senderAccumulated) - senderOldDebt;

        // Transfer proportional claimable as debt adjustment
        int256 claimableToTransfer = (senderClaimable * int256(transferProportion)) / int256(ACC_SCALE);

        // Sender keeps proportional claimable
        uint256 senderNewBalance = senderOldBalance - amount;
        _rewardDebt[from][token] = int256((senderNewBalance * acc) / ACC_SCALE) -
                                   (senderClaimable - claimableToTransfer);

        // Receiver gets transferred claimable added to their account
        uint256 receiverNewBalance = receiverOldBalance + amount;
        int256 receiverOldDebt = _rewardDebt[to][token];
        uint256 receiverOldAccumulated = (receiverOldBalance * acc) / ACC_SCALE;
        int256 receiverOldClaimable = int256(receiverOldAccumulated) - receiverOldDebt;

        _rewardDebt[to][token] = int256((receiverNewBalance * acc) / ACC_SCALE) -
                                 receiverOldClaimable - claimableToTransfer;
    }

    // Update VP
}
```

**Example:**

```
Before:
├─ Alice: 1000 tokens, debt=0, accumulated=1000, claimable=1000 WETH
└─ Bob: 0 tokens

Transfer 500 tokens (50%):
├─ Claimable to transfer: 1000 * 50% = 500 WETH
│
├─ Alice keeps: 500 tokens
│   └─ Claimable: 500 WETH (50% of original) ✓
│
└─ Bob receives: 500 tokens
    └─ Claimable: 500 WETH (transferred from Alice) ✓

When Alice sells on Uniswap:
├─ Uniswap pool receives: 500 tokens + 500 WETH claimable
└─ Alice keeps: 500 WETH claimable for herself ✓
```

**Pros:**

- ✅ Rewards transfer with tokens
- ✅ No user action required
- ✅ Works with DEXs/contracts
- ✅ Fair distribution (proportional)
- ✅ Tradeable "reward-bearing" tokens

**Cons:**

- ❌ Complex debt accounting
- ❌ Higher gas on transfers
- ❌ Need to iterate all reward tokens
- ❌ Uniswap pool WILL accumulate rewards over time

---

### Option 6: Claimable Snapshot (Claim Separately) ⭐⭐⭐⭐⭐

**Concept:** Rewards stay with original earner, receiver starts fresh

**How It Works:**

```solidity
// NO settling or debt transfer on transfer
// Just update debt for current balances

function onTokenTransfer(address from, address to, uint256 amount) external {
    _settleStreamingAll();  // Update accPerShare

    uint256 senderOldBalance = balanceOf(from);
    uint256 receiverOldBalance = balanceOf(to);
    uint256 senderNewBalance = senderOldBalance - amount;
    uint256 receiverNewBalance = receiverOldBalance + amount;

    // Update VP
    updateSenderVP();
    updateReceiverVP();

    // Update debt to CURRENT balance * accPerShare
    // This PRESERVES sender's claimable!
    for (each token) {
        uint256 acc = _rewardInfo[token].accPerShare;

        // Sender's claimable is preserved!
        // Old claimable = (oldBalance * acc) - oldDebt
        // New accumulated = (newBalance * acc)
        // We want: new claimable = old claimable
        // So: new debt = new accumulated - old claimable
        //            = (newBalance * acc) - [(oldBalance * acc) - oldDebt]
        //            = (newBalance * acc) - (oldBalance * acc) + oldDebt

        int256 oldDebt = _rewardDebt[from][token];
        uint256 oldAccumulated = (senderOldBalance * acc) / ACC_SCALE;
        uint256 newAccumulated = (senderNewBalance * acc) / ACC_SCALE;
        int256 claimable = int256(oldAccumulated) - oldDebt;

        _rewardDebt[from][token] = int256(newAccumulated) - claimable;

        // Receiver starts fresh (debt = accumulated, so claimable = 0)
        _rewardDebt[to][token] = int256((receiverNewBalance * acc) / ACC_SCALE);
    }
}
```

**Example:**

```
Before:
├─ Alice: 1000 tokens, debt=0, claimable=1000 WETH
└─ Bob: 0 tokens

Transfer 500 to Bob:
├─ Alice: 500 tokens
│   ├─ Old claimable: 1000 WETH
│   ├─ New accumulated: 500 * acc = 500k
│   ├─ New debt: 500k - 1000 WETH = -500 WETH
│   └─ Claimable: 500k - (-500 WETH) = 1000 WETH ✓ PRESERVED!
│
└─ Bob: 500 tokens
    ├─ New accumulated: 500 * acc = 500k
    ├─ New debt: 500k
    └─ Claimable: 500k - 500k = 0 ✓ (starts fresh)

Alice sells on Uniswap later:
├─ Uniswap receives: 500 tokens, 0 claimable
├─ Alice still has: 1000 WETH claimable ✓
└─ Alice claims separately: receives 1000 WETH ✓
```

**Pros:**

- ✅ Sender keeps ALL their rewards
- ✅ Receiver starts with 0 (fair)
- ✅ Works perfectly with DEXs/contracts
- ✅ No manual claim required before transfer
- ✅ Rewards and tokens trade independently

**Cons:**

- ❌ Need to iterate all reward tokens on transfer
- ❌ More complex debt calculation
- ❌ Negative debt values (might confuse auditors)

**Verdict:** ✅ This is the BEST solution!

---

### Option 7: Hybrid - Smart Contract Detection

**Concept:** Auto-claim for EOAs, preserve for contracts

**How It Works:**

```solidity
function onTokenTransfer(address from, address to, uint256 amount) external {
    _settleStreamingAll();

    // Check if receiver is a contract
    bool toIsContract = to.code.length > 0;

    if (toIsContract) {
        // Preserve sender's claimable (Option 6)
        preserveClaimableForSender();
        setReceiverDebtToZeroClaimable();
    } else {
        // Auto-claim for both (current implementation)
        _settleAll(from, from, oldBalance);
        _settleAll(to, to, oldBalance);
    }

    // Update VP and debt
}
```

**Pros:**

- ✅ Best of both worlds
- ✅ Auto-claim for normal users (convenience)
- ✅ Preserve for contracts (DEX safety)

**Cons:**

- ❌ Complex logic
- ❌ Can be gamed (transfer through EOA first)
- ❌ Contract detection not foolproof
- ❌ CREATE2 address might not have code yet

**Verdict:** ❌ Too complex, gameable

---

## 🎯 RECOMMENDED SOLUTION

### **Option 6: Claimable Preservation** ⭐⭐⭐⭐⭐

**Why This Is Best:**

1. **User Safety:** Sellers keep their earned rewards
2. **DEX Compatible:** Works perfectly with Uniswap/Sushiswap
3. **No User Action:** No manual claim needed before transfer
4. **Fair:** Receiver starts fresh, earns from transfer point
5. **Tradeable:** Tokens and rewards independent

### Implementation Details

**Key Change:**

```solidity
// Instead of:
_settleAll(from, from, oldBalance);  // ❌ Auto-claim

// Do this:
// Preserve sender's claimable by adjusting debt
int256 oldClaimable = calculateClaimable(from, token, oldBalance);
uint256 newAccumulated = (newBalance * acc) / ACC_SCALE;
_rewardDebt[from][token] = int256(newAccumulated) - oldClaimable;
```

**Effect:**

- Sender's claimable amount "frozen" at transfer time
- Sender can claim anytime (even after selling all tokens)
- Receiver starts with 0 claimable (fair - didn't earn yet)
- Receiver earns from transfer point forward

---

## 🤔 Design Considerations

### Consideration 1: Negative Debt Values

**Question:** Is negative debt okay?

**Answer:** YES - It's an accounting technique

**Example:**

```
Alice had 1000 claimable
Alice transfers all 1000 tokens
Alice newBalance = 0
Alice newAccumulated = 0
Alice debt = 0 - 1000 = -1000

When Alice claims:
claimable = 0 - (-1000) = 1000 ✓
```

**Precedent:** Many DeFi protocols use negative debt (Compound, Aave)

---

### Consideration 2: Gas Cost

**Question:** How much gas does this add?

**Answer:** ~20-30k gas per transfer (iterate all reward tokens)

**Comparison:**

- Current auto-claim: ~30k gas (settling all tokens)
- Proposed preserve: ~25k gas (debt calculation)
- **Net: Similar gas cost** ✓

---

### Consideration 3: Uniswap Pool Behavior

**With Claimable Preservation:**

```
Uniswap Pool receives staked tokens:
├─ Pool holds tokens
├─ Pool has 0 claimable initially
├─ Pool earns NEW rewards from holding
├─ LPs can claim pool's earned rewards
└─ Original seller's rewards stay with seller ✓
```

**This is CORRECT behavior!**

- Seller keeps what they earned
- Pool earns from holding
- Both parties happy ✓

---

### Consideration 4: Complexity

**Implementation Complexity:** Medium

**Lines of code:** ~50 lines (debt preservation logic)

**Audit risk:** Low (mathematical formula, well-tested)

**Maintainability:** Good (clear accounting rules)

---

## 📝 Recommendation

### ✅ IMPLEMENT OPTION 6: Claimable Preservation

**Rationale:**

1. Solves the Uniswap problem perfectly
2. Fair to all parties (seller keeps rewards, buyer starts fresh)
3. No user action required (seamless UX)
4. Gas cost similar to current implementation
5. Mathematically sound (negative debt is standard)

**Next Steps:**

1. Implement debt preservation logic
2. Add comprehensive tests (DEX scenarios)
3. Verify no reward loss/gain
4. Document the accounting model
5. Deploy

---

## 🧪 Test Cases Needed

### If We Implement Option 6

**1. Basic Claimable Preservation**

```
- Alice has rewards, transfers to Bob
- Verify Alice can still claim her rewards
- Verify Bob starts with 0 claimable
```

**2. Full Transfer After Earning**

```
- Alice earns 1000 WETH
- Alice transfers ALL tokens to Bob
- Verify Alice can claim 1000 WETH (despite 0 balance)
- Verify Bob has 0 claimable
```

**3. Uniswap Pool Scenario**

```
- Alice earns rewards
- Alice sells to Uniswap pool
- Verify Alice keeps her rewards
- Verify pool starts fresh
- Verify pool earns NEW rewards from holding
```

**4. Multiple Transfers**

```
- Alice earns 1000
- Alice → Bob (500 tokens)
- Bob → Charlie (250 tokens)
- Verify Alice keeps 1000, Bob keeps 0, Charlie starts fresh
```

**5. Negative Debt Edge Cases**

```
- Test with 0 balance but positive claimable
- Test claim with negative debt
- Verify math works correctly
```

---

**Decision Required:** Should we proceed with Option 6 (Claimable Preservation)?

**My Recommendation:** ✅ **YES** - It's the best solution for your use case
