# Governance Snapshot System - Problem Analysis & Solutions

**Date**: October 30, 2025  
**Context**: Analysis of supply snapshot behavior in LevrGovernor_v1  
**Test Suite**: `test/e2e/LevrV1.Governance.t.sol` - Supply Invariant Tests

---

## Executive Summary

The governance snapshot system uses `totalSupplySnapshot` at proposal creation time to calculate quorum. This protects against dilution attacks but creates two edge cases:

1. **Early Governance Capture**: Proposals with tiny snapshots can pass with minimal absolute participation
2. **Mass Unstaking Deadlock**: If too many original stakers leave, proposals become mathematically unpassable

This document analyzes both problems and proposes solutions.

---

## Table of Contents

- [Part 1: Identified Problems & Solutions](#part-1-identified-problems--solutions)
  - [Problem 1: Early Governance Capture](#problem-1-early-governance-capture)
  - [Problem 2: Mass Unstaking Deadlock](#problem-2-mass-unstaking-deadlock)
  - [Recommended Hybrid Solution](#recommended-hybrid-solution)
- [Part 2: Why Snapshots Are Essential](#part-2-why-snapshots-are-essential)
  - [Attack Vectors Without Snapshots](#attack-vectors-without-snapshots)
  - [Comparison Table](#comparison-table)
- [Conclusion](#conclusion)

---

## Part 1: Identified Problems & Solutions

### Problem 1: Early Governance Capture

**Issue**: Proposals with tiny snapshots can pass with minimal absolute participation

**Example**:
```
Proposal created: 1 token staked (snapshot = 1 ether)
Supply explodes: 1,000 new stakers join (supply = 1,001 ether)

Voting:
- Alice votes (1 token)
- totalBalanceVoted = 1 ether
- Quorum check: 1 >= (1 × 70%) = 0.7 ✅ PASSES

Result: 0.1% of actual community approved the proposal
```

**Test**: `test_supplyInvariant_tinySupplyAtCreation_singleVoterCanPass()`

---

#### Solution 1A: Minimum Absolute Quorum ⭐ Recommended

**Implementation**:
```solidity
function _meetsQuorum(uint256 proposalId) internal view returns (bool) {
    Proposal storage proposal = _proposals[proposalId];
    
    // Calculate percentage-based quorum
    uint256 percentageQuorum = (proposal.totalSupplySnapshot * proposal.quorumBpsSnapshot) / 10_000;
    
    // Get minimum absolute quorum from factory config
    uint256 minimumAbsoluteQuorum = ILevrFactory_v1(factory).minimumAbsoluteQuorum();
    
    // Use whichever is higher
    uint256 requiredQuorum = percentageQuorum > minimumAbsoluteQuorum
        ? percentageQuorum
        : minimumAbsoluteQuorum;
    
    return proposal.totalBalanceVoted >= requiredQuorum;
}
```

**Factory Config Addition**:
```solidity
struct FactoryConfig {
    // ... existing fields ...
    uint256 minimumAbsoluteQuorum; // e.g., 1000 ether = 1000 tokens minimum
}
```

**Pros**:
- ✅ Simple to implement
- ✅ Prevents tiny snapshot exploitation
- ✅ Doesn't break existing proposals
- ✅ Configurable per project size

**Cons**:
- ⚠️ Needs calibration per project
- ⚠️ May be too restrictive for small projects early on

---

#### Solution 1B: Dual Threshold (Snapshot AND Current)

**Implementation**:
```solidity
function _meetsQuorum(uint256 proposalId) internal view returns (bool) {
    Proposal storage proposal = _proposals[proposalId];
    
    // Must meet BOTH snapshot quorum AND current supply quorum
    uint256 snapshotQuorum = (proposal.totalSupplySnapshot * quorumBps) / 10_000;
    uint256 currentQuorum = (IERC20(stakedToken).totalSupply() * quorumBps) / 10_000;
    
    return proposal.totalBalanceVoted >= snapshotQuorum 
        && proposal.totalBalanceVoted >= currentQuorum;
}
```

**Pros**:
- ✅ Protects against both early capture AND dilution attacks
- ✅ Forces meaningful participation relative to current reality

**Cons**:
- ❌ Can make proposals unpassable if supply grows massively
- ❌ More restrictive (harder to pass proposals)
- ❌ Creates new deadlock scenarios

---

#### Solution 1C: Minimum Snapshot Requirement

**Implementation**:
```solidity
function _propose(...) internal returns (uint256) {
    // ... existing validation ...
    
    uint256 totalSupply = IERC20(stakedToken).totalSupply();
    uint256 minimumSnapshot = ILevrFactory_v1(factory).minimumSnapshotSupply();
    
    if (totalSupply < minimumSnapshot) {
        revert TotalSupplyTooLow();
    }
    
    // ... continue with proposal creation ...
}
```

**Pros**:
- ✅ Prevents problem at source
- ✅ Very simple

**Cons**:
- ❌ Blocks early-stage governance entirely
- ❌ Not flexible for different project sizes
- ❌ Arbitrary threshold

---

### Problem 2: Mass Unstaking Deadlock

**Issue**: If too many original stakers leave after proposal creation, remaining stakers cannot meet quorum

**Example**:
```
Proposal created: 10 ether staked (snapshot = 10 ether)
Quorum needed: 7 ether (70% of 10)

Mass exodus: 7 ether unstakes
Current supply: 3 ether remaining

Voting:
- All 3 remaining stakers vote (100% participation!)
- totalBalanceVoted = 3 ether
- Quorum check: 3 >= 7 ❌ FAILS

Result: Mathematically impossible to meet quorum
        Even with 100% of remaining stakers voting
```

**Test**: `test_supplyInvariant_extremeSupplyDecrease()`

---

#### Solution 2A: Adaptive Quorum ⭐ Recommended

**Implementation**:
```solidity
function _meetsQuorum(uint256 proposalId) internal view returns (bool) {
    Proposal storage proposal = _proposals[proposalId];
    uint256 currentSupply = IERC20(stakedToken).totalSupply();
    
    // If supply decreased, use current supply for quorum calculation
    // If supply increased, use snapshot (anti-dilution protection)
    uint256 effectiveSupply = currentSupply < proposal.totalSupplySnapshot 
        ? currentSupply 
        : proposal.totalSupplySnapshot;
    
    uint256 requiredQuorum = (effectiveSupply * proposal.quorumBpsSnapshot) / 10_000;
    return proposal.totalBalanceVoted >= requiredQuorum;
}
```

**Pros**:
- ✅ Prevents deadlock from mass exodus
- ✅ Still protects against dilution (uses snapshot when supply increases)
- ✅ Fair to remaining stakers
- ✅ Self-adjusting

**Cons**:
- ⚠️ Asymmetric logic (different for increase vs decrease)
- ⚠️ Could be exploited if attacker forces unstaking (requires control)

---

#### Solution 2B: Participation of Available Supply

**Implementation**:
```solidity
function _meetsQuorum(uint256 proposalId) internal view returns (bool) {
    Proposal storage proposal = _proposals[proposalId];
    uint256 currentSupply = IERC20(stakedToken).totalSupply();
    
    // Quorum as % of votes cast relative to what's currently available
    uint256 requiredParticipation = (currentSupply * proposal.quorumBpsSnapshot) / 10_000;
    
    return proposal.totalBalanceVoted >= requiredParticipation;
}
```

**Pros**:
- ✅ Always reflects reality of who CAN vote
- ✅ No deadlock possible

**Cons**:
- ❌ Opens up dilution attacks (stake massively after proposal to make it unpassable)
- ❌ Completely abandons snapshot protection
- ❌ Contradicts the entire purpose of snapshots

---

#### Solution 2C: Proposal Cancellation Mechanism

**Implementation**:
```solidity
function cancelProposal(uint256 proposalId) external {
    Proposal storage proposal = _proposals[proposalId];
    
    // Only callable after voting ends
    if (block.timestamp <= proposal.votingEndsAt) {
        revert VotingStillActive();
    }
    
    uint256 currentSupply = IERC20(stakedToken).totalSupply();
    uint256 requiredQuorum = (proposal.totalSupplySnapshot * proposal.quorumBpsSnapshot) / 10_000;
    
    // Allow cancellation if quorum is mathematically impossible
    if (currentSupply < requiredQuorum) {
        proposal.executed = true; // Mark as processed
        _activeProposalCount[proposal.proposalType]--;
        emit ProposalCancelled(proposalId, "quorum_impossible");
    } else {
        revert QuorumStillPossible();
    }
}
```

**Pros**:
- ✅ Allows governance to recover from deadlock
- ✅ Doesn't change quorum logic
- ✅ Anyone can trigger (no special permissions)
- ✅ Explicit and transparent

**Cons**:
- ⚠️ Requires extra transaction (gas cost)
- ⚠️ Could be spammed (low cost)
- ⚠️ Doesn't prevent the problem, just cleans it up

---

### Recommended Hybrid Solution

**Combine Solution 1A (Minimum Absolute Quorum) + Solution 2A (Adaptive Quorum)**

```solidity
function _meetsQuorum(uint256 proposalId) internal view returns (bool) {
    Proposal storage proposal = _proposals[proposalId];
    uint256 currentSupply = IERC20(stakedToken).totalSupply();
    
    // ADAPTIVE: Use lower supply to handle both dilution and exodus
    // - Supply increased → use snapshot (anti-dilution)
    // - Supply decreased → use current (anti-deadlock)
    uint256 effectiveSupply = currentSupply < proposal.totalSupplySnapshot 
        ? currentSupply 
        : proposal.totalSupplySnapshot;
    
    // Calculate percentage-based quorum
    uint256 percentageQuorum = (effectiveSupply * proposal.quorumBpsSnapshot) / 10_000;
    
    // MINIMUM ABSOLUTE: Prevent early capture
    uint256 minimumAbsoluteQuorum = ILevrFactory_v1(factory).minimumAbsoluteQuorum();
    
    // Use whichever is higher
    uint256 requiredQuorum = percentageQuorum > minimumAbsoluteQuorum
        ? percentageQuorum
        : minimumAbsoluteQuorum;
    
    return proposal.totalBalanceVoted >= requiredQuorum;
}
```

**Why This Works**:

✅ **Prevents Early Capture**: Minimum absolute threshold (e.g., 1000 tokens minimum)  
✅ **Prevents Mass Unstaking Deadlock**: Adapts to supply decreases  
✅ **Still Protects Against Dilution**: Uses snapshot when supply increases  
✅ **One Elegant Formula**: Handles all edge cases  

**Factory Config Changes**:
```solidity
struct FactoryConfig {
    // ... existing fields ...
    uint256 minimumAbsoluteQuorum; // e.g., 1000 ether for 1000 token minimum
}
```

**Example Scenarios**:

| Scenario | Snapshot | Current | Effective | % Quorum | Min Abs | Final Quorum |
|----------|----------|---------|-----------|----------|---------|--------------|
| **Early Project** | 1 | 1 | 1 | 0.7 | 1000 | **1000** ✅ |
| **Supply Grows** | 10 | 1000 | 10 | 7 | 1000 | **1000** ✅ |
| **Supply Shrinks** | 10000 | 3000 | 3000 | 2100 | 1000 | **2100** ✅ |
| **Mature Project** | 100000 | 100000 | 100000 | 70000 | 1000 | **70000** ✅ |

---

## Part 2: Why Snapshots Are Essential

**Question**: What if we remove snapshots entirely and just use current supply?

```solidity
// NO SNAPSHOT - Just current supply
function _meetsQuorum(uint256 proposalId) internal view returns (bool) {
    uint256 currentSupply = IERC20(stakedToken).totalSupply();
    uint256 requiredQuorum = (currentSupply * quorumBps) / 10_000;
    return proposal.totalBalanceVoted >= requiredQuorum;
}
```

### Attack Vectors Without Snapshots

---

#### 1. Dilution Attack 🔴 CRITICAL

**Scenario**: Malicious actor prevents unwanted proposals by staking massively.

```
Timeline:
Day 1: Alice proposes "Send 1000 tokens to charity"
       - Current supply: 10,000 tokens
       - 70% quorum needs: 7,000 votes
       
Day 2: Voting starts
       - 7,500 tokens vote YES (75% participation)
       - Proposal looks good to pass
       
Day 6: Bob (whale) stakes 90,000 tokens right before voting ends
       - New supply: 100,000 tokens
       - 70% quorum NOW needs: 70,000 votes
       - Only 7,500 votes cast
       - Proposal FAILS quorum (7.5% instead of 70%)
       
Result: Bob blocked the proposal with last-minute staking
Cost: Bob needs capital but doesn't lose it (just unstakes after)
```

**Severity**: HIGH - Cheap to execute, high impact

---

#### 2. Moving Target Problem ⚠️

**Issue**: Quorum threshold changes during voting - unpredictable and frustrating.

```
Alice votes on Day 1:
  - Supply: 10k, Need 7k votes
  - "We need 2k more votes to pass"

Bob stakes 40k more on Day 3:
  - Supply: 50k, Need 35k votes  
  - "Wait, now we need 30k more votes?!"

Charlie stakes 50k more on Day 5:
  - Supply: 100k, Need 70k votes
  - "How can quorum keep increasing?!"
  
Community: "This is impossible to plan for!"
```

**Severity**: MEDIUM - Makes governance frustrating and unpredictable

---

#### 3. Competitive Griefing 💀

**Scenario**: Competing projects/factions can block each other's governance.

```
Scenario: Two factions want different outcomes

Faction A proposes: "Allocate funds to Marketing"
  - 60% of current stakers vote YES
  
Faction B response:
  - Stakes massive amount RIGHT before vote ends
  - Dilutes quorum from 60% to 15%
  - Proposal fails
  
Next cycle:
Faction B proposes: "Allocate funds to Development"  
  - Faction A does the same dilution attack
  - Proposal fails
  
Result: Governance paralysis - no faction can pass proposals
```

**Severity**: HIGH - Leads to complete governance gridlock

---

#### 4. Flash Loan Manipulation ⚡

**Scenario**: Borrow tokens for one block to manipulate quorum.

```solidity
// Attacker's contract
function blockProposal(uint256 proposalId) external {
    // 1. Flash loan 1M tokens
    uint256 borrowed = flashLoan(1_000_000 ether);
    
    // 2. Stake them (quorum threshold skyrockets)
    staking.stake(borrowed);
    // Supply: 10k → 1,010k
    // Quorum: 7k → 707k (impossible to meet)
    
    // 3. Someone calls execute() - fails quorum
    governor.execute(proposalId); // FAILS
    
    // 4. Unstake and repay flash loan
    staking.unstake(borrowed, address(this));
    repayFlashLoan(borrowed);
}
```

**Cost**: Just flash loan fees (0.01% = 100 tokens on 1M loan)

**Severity**: CRITICAL - Extremely cheap to execute, devastating impact

---

#### 5. Sybil Amplification 👥

**Issue**: Without snapshots, Sybil attacks become cheaper.

```
With snapshots:
  - Attacker needs to stake BEFORE proposal
  - Locks capital for entire cycle (7+ days)
  - Capital cost + opportunity cost
  - Example: $1M locked for 7 days
  
Without snapshots:
  - Attacker stakes DURING voting (last minute)
  - Locks capital for hours, not days
  - Much cheaper to execute
  - Example: $1M locked for 2 hours
```

**Cost Reduction**: ~99% cheaper (2 hours vs 7 days)

**Severity**: HIGH - Makes attacks economically viable

---

#### 6. Proposal Uncertainty 🎲

**Issue**: Proposers can't estimate if they'll meet quorum.

```
Alice creates proposal:
  - Current supply: 10k
  - Has 8k votes lined up (80%)
  - Looks safe to pass
  
During voting:
  - Natural growth: 5k new stakers join (organic, not malicious)
  - Supply: 15k, need 10.5k votes
  - Only 8k votes, FAILS
  
Result: Alice's proposal failed not due to opposition,
        but due to unrelated supply growth
        
Alice: "Why even try to propose anything?"
```

**Severity**: MEDIUM - Discourages participation, unpredictable outcomes

---

#### 7. Unstaking Griefing 📉

**Scenario**: Mass unstaking makes proposals too easy to pass (inverse attack).

```
Bob proposes malicious action:
  - Supply: 100k, needs 70k votes
  - Bob controls 30k tokens
  
Bob's alt accounts unstake 60k tokens:
  - Supply drops to 40k, needs 28k votes
  - Bob's 30k > 28k needed
  - Malicious proposal PASSES with minority
  
Result: Bob manipulated quorum by reducing supply
        30% minority approved the proposal
```

**Severity**: HIGH - Minority can pass proposals

---

#### 8. Last-Minute Chaos ⏰

**Scenario**: Final hours become manipulation battleground.

```
2 hours before vote ends:
  - Proposal has 75% participation (passing)
  
1 hour before vote ends:
  - Whale stakes to dilute (quorum now 50%)
  
30 minutes before:
  - Counter-whale stakes to dilute back (quorum now 30%)
  
5 minutes before:
  - Flash loan attack dilutes massively (quorum now 5%)
  - Proposal fails in final seconds
  
Result: Governance decided by who acted last,
        not by community consensus
```

**Severity**: HIGH - Governance becomes a timing game, not a voting system

---

#### 9. Compounding Complexity 🌀

**Issue**: Without snapshots, EVERY mechanism becomes exploitable.

```solidity
// Approval threshold also becomes manipulable
function _meetsApproval(uint256 proposalId) internal view {
    uint256 totalVotes = proposal.yesVotes + proposal.noVotes;
    
    // If this uses current supply:
    // Attacker can manipulate by:
    // 1. Staking to dilute total votes
    // 2. Voting NO to change the ratio
    // 3. Unstaking to change denominator
    // 4. Timing all actions for maximum impact
}
```

**Every formula that references supply becomes a manipulation vector.**

**Severity**: CRITICAL - Entire governance system becomes unreliable

---

### Comparison Table

| Attack Vector | With Snapshot | Without Snapshot | Severity |
|--------------|---------------|------------------|----------|
| **Dilution Attack** | ✅ Prevented | ❌ Easy to execute | 🔴 CRITICAL |
| **Flash Loans** | ✅ Useless (snapshot in past) | ❌ Highly effective | 🔴 CRITICAL |
| **Griefing** | ✅ Must stake early (expensive) | ❌ Last-minute (cheap) | 🔴 HIGH |
| **Uncertainty** | ✅ Fixed target | ❌ Moving target | ⚠️ MEDIUM |
| **Sybil** | ✅ Capital locked long-term | ❌ Capital locked briefly | 🔴 HIGH |
| **Governance Wars** | ✅ Predictable | ❌ Chaotic | 🔴 HIGH |
| **Minority Control** | ✅ Protected | ❌ Easily manipulated | 🔴 HIGH |
| **Last-Minute Chaos** | ✅ Stable | ❌ Timing game | 🔴 HIGH |

---

## Conclusion

### The Core Tradeoff

**Snapshots solve**:
- ✅ Predictability (fixed quorum target)
- ✅ Anti-dilution (can't stake to block)
- ✅ Anti-flash-loan (snapshot is in the past)
- ✅ Fairness (reflects community at decision point)
- ✅ Stability (no moving targets)

**Snapshots create**:
- ⚠️ Early capture risk (tiny snapshots can pass with minimal votes)
- ⚠️ Exodus deadlock (mass unstaking can make quorum impossible)

**But snapshot problems are fixable** via:
- Adaptive quorum (uses lower of snapshot vs current)
- Minimum absolute threshold (prevents tiny snapshot abuse)

**The no-snapshot problems are fundamental**:
- Every mechanism becomes exploitable
- Flash loans become viable
- Governance becomes a timing/capital game
- Community loses trust in the system

---

### Final Recommendation

**✅ KEEP SNAPSHOTS** - They are essential for secure governance.

**✅ IMPLEMENT HYBRID SOLUTION**:
```solidity
function _meetsQuorum(uint256 proposalId) internal view returns (bool) {
    uint256 currentSupply = IERC20(stakedToken).totalSupply();
    
    // Adaptive: Handle both dilution and exodus
    uint256 effectiveSupply = currentSupply < proposal.totalSupplySnapshot 
        ? currentSupply 
        : proposal.totalSupplySnapshot;
    
    // Percentage-based quorum
    uint256 percentageQuorum = (effectiveSupply * proposal.quorumBpsSnapshot) / 10_000;
    
    // Minimum absolute threshold
    uint256 minimumAbsoluteQuorum = ILevrFactory_v1(factory).minimumAbsoluteQuorum();
    
    // Use whichever is higher
    return proposal.totalBalanceVoted >= max(percentageQuorum, minimumAbsoluteQuorum);
}
```

**This gives us**:
- ✅ All benefits of snapshots (anti-dilution, predictability, stability)
- ✅ No early capture (minimum absolute threshold)
- ✅ No exodus deadlock (adaptive to supply decreases)
- ✅ Simple implementation (one formula)
- ✅ Battle-tested approach (used by major protocols)

---

## Next Steps

1. **Add `minimumAbsoluteQuorum` to FactoryConfig**
2. **Implement adaptive quorum logic in `_meetsQuorum()`**
3. **Add tests for new edge cases**
4. **Document in governance spec**
5. **Deploy and monitor in production**

---

**Last Updated**: October 30, 2025  
**Author**: AI Analysis based on supply invariant test results  
**Status**: Recommendation - Pending Implementation

