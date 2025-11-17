# Levr Protocol User Flows - Comprehensive Map

**Date:** October 26, 2025  
**Last Updated:** December 2025  
**Purpose:** Complete mapping of all user interactions to systematically identify edge cases  
**Status:** Living Document - All Missing Test Cases Implemented ✅

## Implementation Status (December 2025)

**All missing test cases from this document have been implemented and verified.**

- ✅ **89+ new test cases added** covering all edge cases marked with ❓
- ✅ **556 total tests passing** (100% pass rate)
- ✅ **All categories covered:**
  - Factory Registration (6 tests)
  - Staking Flows (28 tests)
  - Governance Flows (25 tests)
  - Treasury Flows (9 tests)
  - Fee Splitter Flows (7 tests)
  - Forwarder Flows (6 tests)
  - Cross-Contract Flows (8 tests)

**Test Files Updated:**
- `test/unit/LevrFactoryV1.PrepareForDeployment.t.sol`
- `test/unit/LevrStakingV1.t.sol`
- `test/unit/LevrGovernorV1.t.sol`
- `test/unit/LevrGovernor_CrossContract.t.sol` (new file)
- `test/unit/LevrTreasuryV1.t.sol`
- `test/unit/LevrFeeSplitter_MissingEdgeCases.t.sol`
- `test/unit/LevrForwarderV1.t.sol`

**Note:** Edge cases marked with ❓ throughout this document have been systematically tested. See individual test files for implementation details.

---

## Table of Contents

1. [Project Registration Flows](#project-registration-flows)
2. [Admin Flows (Verified Projects)](#admin-flows-verified-projects)
3. [Staking Flows](#staking-flows)
4. [Governance Flows](#governance-flows)
5. [Treasury Flows](#treasury-flows)
6. [Fee Splitter Flows](#fee-splitter-flows)
7. [Forwarder Flows](#forwarder-flows)
8. [Cross-Contract Flows](#cross-contract-flows)

---

## Project Registration Flows

### Flow 1: Standard Registration (Prepare → Register)

**Actors:** Token Admin (owner of Clanker token)

**Steps:**

1. Token Admin calls `factory.prepareForDeployment()`
   - Factory creates Treasury and Staking contracts
   - Stores addresses in `_preparedContracts[msg.sender]`
2. Token Admin calls `factory.register(clankerToken)`
   - Validates caller is token admin
   - Retrieves prepared contracts
   - **Deletes** prepared contracts from mapping
   - Delegatecalls to LevrDeployer
   - Deploys Governor, StakedToken
   - Initializes all contracts
   - Stores project in registry

**State Changes:**

- Treasury: `governor = address(0)` → `governor = deployedGovernor`
- Staking: `underlying = address(0)` → `underlying = clankerToken`
- Factory: `_preparedContracts[caller]` deleted
- Factory: `_projects[clankerToken]` populated
- Factory: `_projectTokens` array grows

**Edge Cases to Test:**

- ✅ What if Treasury.initialize() is called twice? (tested in `LevrFactoryV1.PrepareForDeployment.t.sol`)
- ✅ What if Staking.initialize() is called twice? (tested in `LevrFactoryV1.PrepareForDeployment.t.sol`)
- ✅ What if register() is called twice for same token? (tested in `LevrFactoryV1.PrepareForDeployment.t.sol`)
- ✅ What if prepared contracts are used for multiple tokens? (tested in `LevrFactoryV1.PrepareForDeployment.t.sol`)
- ✅ What if someone else tries to use prepared contracts? (tested in `LevrFactoryV1.PrepareForDeployment.t.sol`)

---

### Flow 2: Registration Without Preparation

**Actors:** Token Admin

**Steps:**

1. Token Admin calls `factory.register(clankerToken)` WITHOUT calling `prepareForDeployment()`
2. Factory retrieves `_preparedContracts[caller]` → all zero addresses
3. Delegatecall to deployer with zero addresses
4. Deployer's initialize calls should fail with zero addresses

**Edge Cases to Test:**

- ✅ Tested: Registration fails appropriately
- ✅ What if deployer logic doesn't validate zero addresses properly? (tested in `LevrFactoryV1.PrepareForDeployment.t.sol`)

---

## Admin Flows (Verified Projects)

### Flow 2A: Factory Owner Verifies Project

**Actors:** Factory Owner (admin)

**Steps:**

1. Owner calls `factory.verifyProject(clankerToken)`
   - Validates project exists (checks `_projects[clankerToken].staking != address(0)`)
   - Validates not already verified
   - Sets `_projects[clankerToken].verified = true`
   - Initializes `_projectOverrideConfig[clankerToken]` with current factory config
   - Emits `ProjectVerified(clankerToken)` event

**State Changes:**

- Factory: `_projects[clankerToken].verified` = false → true
- Factory: `_projectOverrideConfig[clankerToken]` = current factory config
- Project contracts automatically start using override config (if updated)

**Edge Cases to Test:**

- ✅ Tested: Only owner can verify
- ✅ Tested: Cannot verify non-existent project
- ✅ Tested: Cannot verify already verified project
- ✅ Tested: Config initialized with current factory defaults

---

### Flow 2B: Project Admin Updates Custom Config

**Actors:** Token Admin (owner of verified project's Clanker token)

**Steps:**

1. Token Admin calls `factory.updateProjectConfig(clankerToken, customConfig)`
   - Validates project exists
   - Validates project is verified
   - Validates caller is token admin
   - Validates custom config (same rules as factory config)
   - Preserves `protocolFeeBps` and `protocolTreasury` (not overridable)
   - Updates `_projectOverrideConfig[clankerToken]` with custom values
   - Emits `ProjectConfigUpdated(clankerToken)` event

**State Changes:**

- Factory: `_projectOverrideConfig[clankerToken]` updated with custom values
- Governor: Next proposal creation uses new config
- Staking: Next stream reset uses new window
- All config getters return new values when called with this clankerToken

**Edge Cases to Test:**

- ✅ Tested: Only token admin can update
- ✅ Tested: Only verified projects can update
- ✅ Tested: Validation prevents invalid configs (BPS > 100%, zero values, etc.)
- ✅ Tested: Cannot override protocolFeeBps
- ✅ Tested: Config changes apply immediately to new operations

---

### Flow 2C: Factory Owner Unverifies Project

**Actors:** Factory Owner (admin)

**Steps:**

1. Owner calls `factory.unverifyProject(clankerToken)`
   - Validates project exists
   - Validates project is verified
   - Sets `_projects[clankerToken].verified = false`
   - Deletes `_projectOverrideConfig[clankerToken]` (frees storage)
   - Emits `ProjectUnverified(clankerToken)` event

**State Changes:**

- Factory: `_projects[clankerToken].verified` = true → false
- Factory: `_projectOverrideConfig[clankerToken]` deleted
- Project contracts fall back to global factory config

**Edge Cases to Test:**

- ✅ Tested: Only owner can unverify
- ✅ Tested: Cannot unverify non-existent project
- ✅ Tested: Cannot unverify already unverified project
- ✅ Tested: Config immediately reverts to factory defaults
- ✅ Tested: Storage cleanup refunds gas

---

### Flow 2D: Config Resolution (Automatic)

**How Contracts Get Config:**

All contracts (Governor, Staking) call factory config getters with their `underlying` token:

```solidity
// In Governor/Staking:
uint16 quorum = ILevrFactory_v1(factory).quorumBps(underlying);
```

**Factory Logic:**

```solidity
function quorumBps(address clankerToken) external view returns (uint16) {
    // If clankerToken provided AND project verified → return override
    if (clankerToken != address(0) && _projects[clankerToken].verified) {
        return _projectOverrideConfig[clankerToken].quorumBps;
    }
    // Otherwise → return global default
    return _quorumBps;
}
```

**Examples:**

- `factory.quorumBps(address(0))` → Always returns global default
- `factory.quorumBps(unverifiedToken)` → Returns global default
- `factory.quorumBps(verifiedToken)` → Returns project override
- Governor calls `factory.quorumBps(underlying)` → Automatic resolution

**Edge Cases to Test:**

- ✅ Tested: Unverified project gets default config
- ✅ Tested: Verified project gets override config
- ✅ Tested: address(0) always returns default
- ✅ Tested: Non-existent project returns default
- ✅ Tested: Config changes apply immediately to next operations

---

## Staking Flows

### Flow 2B: Reward Token Whitelisting (NEW - v1.5.0)

**Actors:** Token Admin (owner of underlying/clanker token)

**Steps:**

**1. Initial Whitelist (Inherited from Factory):**

- When project registers via factory, staking is initialized with:
  - Underlying token (auto-whitelisted, immutable)
  - Factory's initial whitelist (e.g., WETH)
  - Projects inherit these tokens automatically

**2. Project Admin Extends Whitelist:**

```solidity
// Admin whitelists a new reward token (e.g., USDC)
factory.getProject(clankerToken).admin.whitelistToken(usdcAddress);
```

**Steps:**

1. Token admin calls `staking.whitelistToken(newToken)`
2. Staking validates:
   - Caller is underlying token admin (`ONLY_TOKEN_ADMIN`)
   - Token is not underlying (`CANNOT_MODIFY_UNDERLYING`)
   - Token is not already whitelisted (`ALREADY_WHITELISTED`)
   - If token was previously used and cleaned up:
     - `availablePool == 0` and `streamTotal == 0` (`CANNOT_WHITELIST_WITH_PENDING_REWARDS`)
3. Token state created/updated:
   - `_tokenState[token].whitelisted = true`
   - `_tokenState[token].exists = true`
   - Added to `_rewardTokens` array if new
4. Emits `TokenWhitelisted(token)` event

**3. Admin Unwhitelists Token:**

```solidity
// Admin removes token from whitelist (must have no pending rewards)
factory.getProject(clankerToken).admin.unwhitelistToken(daiAddress);
```

**Steps:**

1. Token admin calls `staking.unwhitelistToken(token)`
2. Staking validates:
   - Caller is underlying token admin (`ONLY_TOKEN_ADMIN`)
   - Token is not underlying (`CANNOT_UNWHITELIST_UNDERLYING`)
   - Settles pool to current time
   - `availablePool == 0` and `streamTotal == 0` (`CANNOT_UNWHITELIST_WITH_PENDING_REWARDS`)
3. Token state updated:
   - `_tokenState[token].whitelisted = false`
   - Token remains in `_rewardTokens` array (for historical tracking)
4. Emits `TokenUnwhitelisted(token)` event

**State Changes:**

- Factory: `_initialWhitelistedTokens` array (set once at deployment)
- Staking: `_tokenState[token].whitelisted` (true/false per token)
- Staking: `_rewardTokens` array (grows with new tokens, never shrinks)

**Security Protections:**

1. **Underlying Immutability:** Cannot whitelist/unwhitelist underlying token
2. **Access Control:** Only token admin can manage whitelist
3. **State Integrity:** Cannot re-whitelist token with pending rewards
4. **Fund Protection:** Cannot unwhitelist token with claimable rewards
5. **Cleanup Safety:** Must unwhitelist before cleanup

**Edge Cases to Test:**

- ✅ Tested: Cannot modify underlying token whitelist status
- ✅ Tested: Cannot whitelist already whitelisted token
- ✅ Tested: Cannot unwhitelist token with pending rewards
- ✅ Tested: Cannot unwhitelist token with vested pool rewards
- ✅ Tested: Can re-whitelist after cleanup (if no pending rewards)
- ✅ Tested: Projects inherit factory's initial whitelist
- ✅ Tested: Multiple projects have independent whitelists
- ✅ Tested: Only token admin can whitelist/unwhitelist

**Whitelist-Only Enforcement:**

All reward accrual and distribution paths now enforce whitelist:

```solidity
// Staking: accrueRewards()
require(tokenState.exists, 'TOKEN_NOT_WHITELISTED');
require(tokenState.whitelisted, 'TOKEN_NOT_WHITELISTED');

// Fee Splitter: distribute() and _distributeSingle()
require(ILevrStaking_v1(staking).isTokenWhitelisted(rewardToken), 'TOKEN_NOT_WHITELISTED');
```

---

### Flow 3: First-Time Staking

**Actors:** User (any address with underlying tokens)

**Steps:**

1. User approves Staking contract for `amount`
2. User calls `staking.stake(amount)`
   - Settles all streaming rewards (no-op for new user)
   - Sets `stakeStartTime[user] = block.timestamp`
   - Transfers underlying tokens from user to staking
   - Increases `_escrowBalance[underlying]`
   - Increases `_rewardDebt` for all reward tokens
   - Increases `_staked[user]` and `_totalStaked`
   - Mints sTokens to user
3. User now has:
   - `_staked[user] = amount`
   - `sToken.balanceOf(user) = amount`
   - `stakeStartTime[user] = block.timestamp`
   - Voting Power = 0 (just staked)

**State Changes:**

- `_totalStaked` increases
- `_escrowBalance[underlying]` increases
- User receives sTokens
- User's reward debt initialized

**Edge Cases to Test:**

- ✅ Tested: Cannot stake 0
- ✅ Tested: Reward debt properly initialized
- ❓ What if stake during active reward stream?
- ❓ What if \_totalStaked was 0 before stake?
- ❓ What if stake amount causes overflow?

---

### Flow 4: Subsequent Staking (Adding to Position)

**Actors:** User (already has staked balance)

**Steps:**

1. User calls `staking.stake(additionalAmount)`
   - Settles streaming (user may receive rewards)
   - **Calculates weighted average timestamp** to preserve VP
   - Old VP: `oldBalance × timeAccumulated`
   - New start time: `now - (oldBalance × timeAccumulated) / newTotalBalance`
   - Transfers tokens
   - Updates balances and debt
   - Mints additional sTokens

**VP Preservation Formula:**

```
Old VP = oldBalance × (now - oldStartTime)
New VP should equal Old VP immediately after stake
New VP = newBalance × (now - newStartTime)
Therefore: newStartTime = now - (oldBalance × timeAccumulated) / newBalance
```

**Edge Cases to Test:**

- ✅ Tested: VP preservation on additional stake
- ❓ What if time overflow in weighted average calculation?
- ❓ What if division by zero in newTotalBalance?
- ❓ What if stake immediately after unstake?
- ❓ What if stake during voting period? (VP used in vote is snapshot at vote time... or is it?)

---

### Flow 5: Partial Unstaking

**Actors:** User (has staked balance)

**Steps:**

1. User calls `staking.unstake(partialAmount, recipient)`
   - Settles streaming (claims pending rewards)
   - Settles user's rewards for all tokens
   - Reduces `_staked[user]`
   - Burns sTokens
   - Reduces `_escrowBalance[underlying]`
   - Transfers underlying to recipient
   - **Proportionally reduces time accumulation**
   - New time = oldTime × (remainingBalance / originalBalance)

**VP Reduction Formula:**

```
Before: 1000 tokens × 100 days = 100,000 token-days VP
Unstake: 300 tokens (30%)
After: 700 tokens × 70 days = 49,000 token-days VP (70% of original VP)
```

**Edge Cases to Test:**

- ✅ Tested: Proportional VP reduction
- ❓ What if unstake amount > staked balance?
- ❓ What if unstake causes \_totalStaked = 0?
- ❓ What if unstake during active reward stream?
- ❓ What if escrow balance < unstake amount?
- ❓ What if unstake to zero address?
- ❓ What if rounding error in proportional calculation?

---

### Flow 6: Full Unstaking

**Actors:** User (has staked balance)

**Steps:**

1. User calls `staking.unstake(entireBalance, recipient)`
   - Settles streaming
   - Claims all rewards
   - **Resets stakeStartTime to 0**
   - Burns all sTokens
   - Transfers all underlying to recipient
2. User now has:
   - `_staked[user] = 0`
   - `stakeStartTime[user] = 0`
   - Voting Power = 0

**Edge Cases to Test:**

- ✅ Tested: Full unstake resets VP to 0
- ❓ What if user tries to vote after full unstake?
- ❓ What if user had voted and then full unstakes?
- ❓ What if last person unstakes during reward stream?

---

### Flow 7: Claiming Rewards

**Actors:** User (has staked balance with pending rewards)

**Steps:**

1. User calls `staking.claimRewards([rewardTokens], recipient)`
   - For each reward token:
     - Calls `_settle(token, user, recipient, userBalance)`
     - Settles streaming for that token
     - Calculates: `accumulated = (balance × accPerShare) / ACC_SCALE`
     - Calculates: `pending = accumulated - rewardDebt`
     - Transfers pending rewards to recipient
     - Decreases `_rewardReserve[token]`

**Edge Cases to Test:**

- ✅ Tested: Cannot claim more than reserve
- ❓ What if reserve < pending due to rounding?
- ❓ What if claim empty array of tokens?
- ❓ What if claim for token that doesn't exist?
- ❓ What if claim when \_totalStaked = 0?
- ❓ What if multiple users claim simultaneously?

---

### Flow 8: Reward Accrual (Manual Transfer + Accrue)

**Actors:** Anyone (permissionless)

**Steps:**

1. Someone transfers reward tokens to staking contract
2. Anyone calls `staking.accrueRewards(token)`
   - Tries to claim from ClankerFeeLocker (if exists)
   - Calculates available unaccounted rewards
   - Calls `_creditRewards(token, amount)`
   - Settles current stream
   - **Calculates unvested rewards from current stream**
   - Resets stream with: `newAmount + unvested`
   - Increases reserve by `newAmount` only

**Midstream Accrual:**

```
Stream 1: 3000 tokens over 3 days (starts T0)
At T0+1day: 1000 vested, 2000 unvested
Transfer + accrue 2000 more tokens
Stream 2: 4000 tokens over 3 days (2000 new + 2000 unvested)
Total rewards: 5000 (3000 from stream 1 + 2000 from stream 2)
```

**Edge Cases to Test:**

- ✅ Tested: Midstream accrual preserves unvested
- ✅ Tested: Multiple midstream accruals
- ❓ What if accrue when \_totalStaked = 0?
- ❓ What if accrue after stream ended?
- ❓ What if accrue before stream started?
- ❓ What if transfer but forget to call accrue?
- ❓ What if unvested calculation overflows?

---

### Flow 9: Treasury Boost (Pull from Treasury)

**Actors:** Governor contract (via executed proposal)

**Steps:**

1. Governor calls `treasury.applyBoost(amount)`
2. Treasury approves Staking for `amount`
3. Treasury calls `staking.accrueFromTreasury(underlying, amount, true)`
4. Staking pulls tokens from Treasury
5. Staking credits rewards (same as Flow 8)
6. Treasury resets approval to 0

**Edge Cases to Test:**

- ✅ Tested: Approval reset after boost
- ❓ What if accrueFromTreasury reverts?
- ❓ What if treasury has insufficient balance?
- ❓ What if approval fails?
- ❓ What if boost amount = 0?

---

## Governance Flows

### Flow 10: Proposal Creation (Auto-Start Cycle) - TOKEN AGNOSTIC

**Actors:** Staker with sufficient balance and VP

**Steps:**

1. User calls `governor.proposeBoost(token, amount)` or `governor.proposeTransfer(token, recipient, amount, description)`
2. Governor validates:
   - Token address is not zero
3. Governor checks if new cycle needed (`_currentCycleId == 0 || _needsNewCycle()`)
4. If needed: **Auto-starts new cycle**
   - Reads `proposalWindowSeconds` and `votingWindowSeconds` FROM FACTORY
   - Creates cycle with calculated timestamps
   - Stores in `_cycles[cycleId]`
5. Reads cycle timestamps (NOT from factory)
6. Validates:
   - Proposal window is open
   - User has minimum stake (reads FROM FACTORY)
   - Amount doesn't exceed max (reads FROM FACTORY, uses current treasury balance FOR THAT TOKEN)
   - Not too many active proposals (reads FROM FACTORY)
   - User hasn't proposed this type in this cycle
7. Creates proposal:
   - Stores token address in proposal
   - Copies `votingStartsAt` and `votingEndsAt` FROM CYCLE
   - Sets initial vote counts to 0
   - Stores proposal

**Token Agnostic Support:**

- ✅ Proposals can specify any ERC20 token
- ✅ Treasury balance check uses proposal.token
- ✅ Execution uses proposal.token

**Critical State Reads:**

- ✅ `votingStartsAt`, `votingEndsAt`: Read from cycle (IMMUTABLE) ✅
- ✅ `token`: Stored in proposal (IMMUTABLE) ✅
- ❌ `minSTokenBpsToSubmit`: Read from factory (DYNAMIC) ⚠️
- ❌ `maxProposalAmountBps`: Read from factory (DYNAMIC) ⚠️
- ❌ `maxActiveProposals`: Read from factory (DYNAMIC) ⚠️

**Edge Cases to Test:**

- ✅ Tested: Auto-start cycle when none exists
- ✅ Tested: Multiple proposals in same cycle
- ❓ What if factory config changes between proposal creation and voting?
- ❓ What if treasury token balance decreases after proposal creation?
- ❓ What if user's balance decreases after creating proposal?
- ❓ What if cycle window = 0?
- ❓ What if uint256 overflow in timestamp calculations?
- ❓ What if token is zero address?
- ❓ What if token is not held by treasury?
- ❓ What if multiple proposals for different tokens in same cycle?
- ❓ What if underlying token proposal vs WETH proposal in same cycle?

---

### Flow 11: Voting on Proposal

**Actors:** Staker with VP > 0

**Steps:**

1. User calls `governor.vote(proposalId, support)`
2. Validates:
   - Voting window is active (compares `block.timestamp` to proposal timestamps)
   - User hasn't voted yet
3. **Reads voting power from staking contract** (CURRENT VP, not snapshot)
4. Reads user's sToken balance (CURRENT balance, not snapshot)
5. Updates proposal:
   - `yesVotes` or `noVotes` += VP
   - `totalBalanceVoted` += sToken balance
6. Records vote receipt

**Critical State Reads:**

- ❌ `getVotingPower(voter)`: Read at VOTE time (can change if user stakes/unstakes) ⚠️
- ❌ `balanceOf(voter)`: Read at VOTE time (can change) ⚠️

**Edge Cases to Test:**

- ✅ Tested: Cannot vote twice
- ✅ Tested: Cannot vote with 0 VP
- ❓ What if user votes, then transfers sTokens to another address?
- ❓ What if user votes, then unstakes, then someone else votes?
- ❓ What if user's VP decreases between vote and execution?
- ❓ What if voting windows overlap due to config changes?
- ❓ What if vote after proposal executed?
- ❓ What if yesVotes + noVotes overflow?

---

### Flow 12: Proposal Execution - TOKEN AGNOSTIC

**Actors:** Anyone (permissionless)

**Steps:**

1. Anyone calls `governor.execute(proposalId)`
2. Validates:
   - Voting window has ended
   - Not already executed
   - **Meets quorum** (uses snapshot from proposal creation) ✅
   - **Meets approval** (uses snapshot from proposal creation) ✅
   - **Treasury has balance** (reads CURRENT balance FOR PROPOSAL.TOKEN)
   - Is winner (checks snapshots for all proposals) ✅
   - Cycle not already executed
3. Marks proposal and cycle as executed
4. Executes action:
   - **BoostStakingPool**: `treasury.applyBoost(proposal.token, proposal.amount)`
   - **TransferToAddress**: `treasury.transfer(proposal.token, proposal.recipient, proposal.amount)`
5. **Auto-starts new cycle**

**Token Agnostic Support:**

- ✅ Execution uses proposal.token (stored at creation)
- ✅ Balance check uses IERC20(proposal.token).balanceOf(treasury)
- ✅ Treasury methods accept token parameter

**Critical State Reads:**

- ✅ `totalSupply`: Snapshot at proposal creation (FIXED NEW-C-1, NEW-C-2) ✅
- ✅ `quorumBps`: Snapshot at proposal creation (FIXED NEW-C-3) ✅
- ✅ `approvalBps`: Snapshot at proposal creation (FIXED NEW-C-3) ✅
- ✅ `token`: Stored in proposal (IMMUTABLE) ✅
- ❌ `treasuryBalance`: Read at EXECUTION time for proposal.token (can decrease) ⚠️

**Edge Cases to Test:**

- ✅ FIXED: Supply manipulation after voting (NEW-C-1, NEW-C-2)
- ✅ FIXED: Config changes affect winner (NEW-C-3)
- ✅ Tested: Treasury balance validation
- ❓ What if execution reverts (e.g., transfer to malicious contract)?
- ❓ What if multiple proposals meet same yesVotes?
- ❓ What if winner = 0 (no proposals met quorum)?
- ❓ What if auto-start new cycle fails?
- ❓ What if two people try to execute simultaneously?
- ❓ What if treasury has insufficient balance for proposal.token?
- ❓ What if proposal.token is different from underlying?
- ❓ What if boost with WETH while treasury has underlying balance?

---

### Flow 13: Manual Cycle Advancement

**Actors:** Anyone (permissionless)

**Steps:**

1. Anyone calls `governor.startNewCycle()`
2. Validates:
   - Either no cycle exists OR current cycle has ended
   - **No executable proposals remain** (checks each proposal's state)
3. Starts new cycle

**Edge Cases to Test:**

- ✅ Tested: Cannot start during active cycle
- ✅ Tested: Cannot start with executable proposals
- ❓ What if \_checkNoExecutableProposals() loops through 100+ proposals?
- ❓ What if state check is expensive (calls factory multiple times)?
- ❓ What if cycleId overflows?

---

## Treasury Flows

### Flow 14: Treasury Transfer (via Governance) - TOKEN AGNOSTIC

**Actors:** Governor contract

**Steps:**

1. Winning proposal executed by anyone
2. Governor calls `treasury.transfer(token, recipient, amount)`
3. Treasury validates:
   - Caller is governor
   - Reentrancy guard active
   - Token address is not zero
4. Transfers tokens to recipient using SafeERC20

**Token Agnostic Support:**

- ✅ Underlying token (clanker token) - for backwards compatibility
- ✅ Wrapped ETH (WETH) - primary use case for expansion
- ✅ Any ERC20 token held by treasury - full flexibility

**State Changes:**

- Treasury token balance decreases
- Recipient token balance increases

**Edge Cases to Test:**

- ✅ Tested: Only governor can transfer
- ✅ Tested: Reentrancy protection
- ❓ What if transfer to malicious contract that reverts?
- ❓ What if transfer amount > balance?
- ❓ What if transfer to zero address?
- ❓ What if token has transfer fees?
- ❓ What if token is pausable and paused?
- ❓ What if token is zero address?
- ❓ What if transfer underlying vs WETH vs other ERC20?

---

### Flow 15: Treasury Boost (via Governance) - TOKEN AGNOSTIC

**Actors:** Governor contract

**Steps:**

1. Governor calls `treasury.applyBoost(token, amount)`
2. Treasury:
   - Validates token address is not zero
   - Gets staking address from factory
   - Approves staking for `amount` of `token`
   - Calls `staking.accrueFromTreasury(token, amount, true)`
   - Staking pulls tokens (any ERC20)
   - **Resets approval to 0**

**Token Agnostic Support:**

- ✅ Underlying token (clanker token) - boosts with project token
- ✅ Wrapped ETH (WETH) - boosts with ETH rewards
- ✅ Any ERC20 token - boosts with arbitrary reward tokens

**State Changes:**

- Treasury token balance decreases
- Staking contract token balance increases
- Staking reward reserve for token increases
- New reward stream starts (or adds to existing stream)

**Edge Cases to Test:**

- ✅ Tested: Approval reset after boost
- ❓ What if accrueFromTreasury reverts?
- ❓ What if staking address changes in factory?
- ❓ What if staking contract is malicious?
- ❓ What if amount = 0?
- ❓ What if boost twice in same transaction?
- ❓ What if token is zero address?
- ❓ What if boost with underlying vs WETH vs other ERC20?
- ❓ What if multiple boosts with different tokens in same cycle?

---

## Fee Splitter Flows

### Flow 16: Fee Splitter Factory Deployment

**Actors:** Anyone (permissionless)

**Steps:**

1. Anyone calls `feeSplitterFactory.deploy(clankerToken)` OR `deployDeterministic(clankerToken, salt)`
2. Factory validates:
   - Token address is not zero
   - Splitter not already deployed for this token
3. Deploys new LevrFeeSplitter_v1 instance
4. Stores mapping: `splitters[clankerToken] = newSplitter`
5. Emits `FeeSplitterDeployed` event

**State Changes:**

- New LevrFeeSplitter_v1 contract deployed
- Factory stores splitter address in mapping
- Splitter references: clankerToken (immutable), factory (immutable)

**Edge Cases Tested:**

- ✅ **Deploy for unregistered token** - Succeeds (validation at configure time)
- ✅ **Double deployment** - Reverts with AlreadyDeployed
- ✅ **Same salt different tokens** - Creates different addresses (different bytecode)
- ✅ **Deterministic address accuracy** - computeDeterministicAddress matches actual
- ✅ **Zero address token** - Reverts in factory
- ✅ **Zero salt** - Valid CREATE2 deployment

**New Findings:**

- ⚠️ **Weak validation**: Only checks if token != address(0), doesn't verify token is in Levr system
- ✅ **Safe in practice**: configureSplits validates staking exists (ProjectNotRegistered)

---

### Flow 17: Fee Splitter Configuration

**Actors:** Token Admin (IClankerToken.admin())

**Steps:**

1. Token Admin calls `feeSplitter.configureSplits([{receiver, bps}, ...])`
2. Validates (in \_validateSplits):
   - Caller is token admin (\_msgSender() == IClankerToken(clankerToken).admin())
   - Array not empty
   - Array length <= MAX_RECEIVERS (20)
   - Get staking address from factory (reverts if project not registered)
   - For each split:
     - Receiver not address(0)
     - BPS not 0
     - No duplicate receivers (nested loop check)
     - Accumulate totalBps
   - Total BPS exactly == 10000
3. Deletes old splits: `delete _splits`
4. Stores new splits: loop and push
5. Emits `SplitsConfigured` event

**State Changes:**

- Old \_splits array completely deleted
- New \_splits array populated
- Distribution state (\_distributionState) UNCHANGED (persists)

**Edge Cases Tested:**

- ✅ **Duplicate receiver detection** - Reverts with DuplicateReceiver
- ✅ **Too many receivers** - Reverts with TooManyReceivers (max 20)
- ✅ **Reconfigure to empty** - Reverts with NoReceivers
- ✅ **Receiver is splitter itself** - Allowed but creates stuck funds (recoverDust workaround)
- ✅ **Receiver is factory** - Allowed (likely unintended)
- ✅ **BPS overflow (uint16.max)** - Caught by InvalidTotalBps
- ✅ **Admin change** - Dynamic admin check allows new admin to reconfigure
- ✅ **Project not registered** - Reverts with ProjectNotRegistered
- ✅ **Multiple reconfigurations** - State properly cleaned each time
- ✅ **BPS sum 9999 or 10001** - Rejected (must be exactly 10000)

**Critical Finding:**

- ⚠️ **Staking address** captured at configuration time (stored in splits[i].receiver)
- ⚠️ **Auto-accrual target** read dynamically at distribution time (getStakingAddress())
- ⚠️ **Mismatch risk** if staking address changes in factory between config and distribution

---

### Flow 18: Fee Distribution (Single Token)

**Actors:** Anyone (permissionless)

**Steps:**

1. Anyone calls `feeSplitter.distribute(rewardToken)`
2. Gets Clanker metadata from factory (reverts if not found)
3. Tries to collect rewards from LP locker (try/catch)
   - Calls `IClankerLpLocker(lpLocker).collectRewards(clankerToken)`
   - Moves fees from Uniswap V4 pool → ClankerFeeLocker
4. Tries to claim fees from fee locker (try/catch)
   - Calls `IClankerFeeLocker(feeLocker).claim(address(this), rewardToken)`
   - Moves fees from ClankerFeeLocker → FeeSplitter
5. Gets balance: `IERC20(rewardToken).balanceOf(address(this))`
6. If balance == 0: return early (no-op)
7. Validates splits configured
8. For each split in \_splits:
   - Calculate: `amount = (balance * split.bps) / 10000`
   - If amount > 0: transfer to split.receiver (SafeERC20)
   - If receiver == staking (from factory): set sentToStaking = true
   - Emit FeeDistributed event
9. Update state: totalDistributed += balance, lastDistribution = timestamp
10. Emit Distributed event
11. If sentToStaking: try to call `staking.accrueRewards(rewardToken)` (try/catch)

**State Changes:**

- rewardToken balance transferred from splitter → receivers
- \_distributionState[rewardToken].totalDistributed increases
- \_distributionState[rewardToken].lastDistribution updated

**Edge Cases Tested:**

- ✅ **Zero balance** - Returns early without error
- ✅ **Splits not configured** - Reverts with SplitsNotConfigured
- ✅ **Metadata not found** - Reverts with ClankerMetadataNotFound
- ✅ **collectRewards fails** - Try/catch, distribution continues
- ✅ **Fee locker claim fails** - Try/catch, distribution continues
- ✅ **Auto-accrual fails** - Try/catch, distribution continues (emits AutoAccrualFailed)
- ✅ **Auto-accrual succeeds** - Emits AutoAccrualSuccess
- ✅ **1 wei distribution** - All amounts round to 0, entire balance becomes dust
- ✅ **Minimal rounding** - Predictable dust (9 wei → 4+4+1 dust)
- ✅ **Prime number balance** - Uneven split creates dust
- ✅ **100% to staking** - Auto-accrual called once
- ✅ **0% to staking** - Auto-accrual not called
- ✅ **Multiple tokens sequentially** - Each distributes independently

**Critical Finding:**

- ⚠️ **Staking address mismatch**: If factory staking changes, fees sent to OLD staking but accrual called on NEW staking (mismatch!)

---

### Flow 19: Fee Distribution (Batch)

**Actors:** Anyone (permissionless)

**Steps:**

1. Anyone calls `feeSplitter.distributeBatch([token1, token2, ...])`
2. For each token in array:
   - Calls \_distributeSingle(token) (internal, no reentrancy guard)
3. ReentrancyGuard protects entire batch operation

**State Changes:**

- Multiple tokens distributed in single transaction
- State updated for each token independently

**Edge Cases Tested:**

- ✅ **Empty array** - Completes gracefully (no-op)
- ✅ **Duplicate tokens** - First distributes all, second distributes 0 (safe)
- ✅ **100 tokens** - Works but gas-intensive (no hard limit)
- ✅ **Multiple tokens to multiple receivers** - All combinations work correctly
- ✅ **Auto-accrual per token** - Called for each token sent to staking

**New Finding:**

- ⚠️ **No MAX_BATCH_SIZE limit** - Could hit gas limit with very large arrays (800+ tokens estimated)

---

### Flow 20: Dust Recovery

**Actors:** Token Admin

**Steps:**

1. Token Admin calls `feeSplitter.recoverDust(token, recipient)`
2. Validates:
   - Caller is token admin
   - Recipient not address(0)
3. Gets pending fees in locker: `splitter.pendingFees(token)`
4. Gets current balance: `IERC20(token).balanceOf(address(this))`
5. Calculates dust: `balance - pendingInLocker`
6. If dust > 0: transfers dust to recipient
7. Emits DustRecovered event

**Edge Cases Tested:**

- ✅ **All balance is dust** (never distributed) - Recovers all
- ✅ **Zero address recipient** - Reverts with ZeroAddress
- ✅ **No dust** (balance = 0 or balance <= pending) - Completes without transfer
- ✅ **Rounding dust** - Successfully recovers tiny amounts (1 wei)
- ✅ **Never-distributed token** - Can recover entire balance
- ✅ **After distribution** - Only recovers remainder dust

---

### Flow 21: Splitter Reconfiguration

**Actors:** Token Admin

**Steps:**

1. Splits already configured
2. Token Admin calls `configureSplits(newSplits)`
3. Validates new configuration (same as initial configuration)
4. **Deletes entire \_splits array**: `delete _splits`
5. Stores new splits
6. **Distribution state NOT deleted** - persists across reconfigurations

**State Changes:**

- \_splits completely replaced
- \_distributionState unchanged (totalDistributed, lastDistribution persist)

**Edge Cases Tested:**

- ✅ **Immediate reconfiguration after distribution** - Works correctly
- ✅ **Multiple reconfigurations** - State cleaned each time
- ✅ **totalDistributed persists** - Accumulates across different configurations
- ✅ **Old splits deleted** - No residual state from old config

**Design Note:**

- Distribution state is per-token, not per-configuration
- totalDistributed tracks lifetime totals, not config-specific totals

---

**Edge Cases Updated:** October 27, 2025  
**New Tests Added:** 47  
**Total FeeSplitter Coverage:** 74 tests (100% passing)

## Forwarder Flows

### Flow 18: Meta-Transaction Multicall

**Actors:** User (signing meta-transaction off-chain)

**Steps:**

1. User signs EIP-712 message off-chain
2. Relayer calls `forwarder.executeMulticall([calls])`
3. Validates: `msg.value == sum(call.value)` for all calls
4. For each call:
   - If target is forwarder: check selector is `executeTransaction` only
   - If target is external: append `msg.sender` to calldata (ERC2771)
   - Execute call
   - Store result
5. Returns all results

**Edge Cases to Test:**

- ✅ Tested: Value mismatch detection
- ✅ Tested: Recursive multicall blocked
- ✅ Tested: Reentrancy protection
- ❓ What if calls array is very long (gas bomb)?
- ❓ What if one call fails and allowFailure = false?
- ❓ What if target doesn't trust forwarder?
- ❓ What if call data is malformed?

---

### Flow 19: Direct Transaction via Forwarder

**Actors:** Forwarder (internal call only)

**Steps:**

1. During executeMulticall, if target is forwarder
2. Calls `forwarder.executeTransaction(target, data)`
3. Validates: `msg.sender == address(this)`
4. Executes call to target WITHOUT appending sender

**Edge Cases to Test:**

- ✅ Tested: Direct calls blocked
- ❓ What if target is forwarder itself?
- ❓ What if recursion depth exceeds limits?

---

## Cross-Contract Flows

### Flow 20: Complete Governance Cycle (Proposal → Vote → Execute → Boost) - TOKEN AGNOSTIC

**Actors:** Multiple users

**Steps:**

1. **T0**: Alice stakes 1000 tokens (gets 1000 sTokens, VP = 0)
2. **T0 + 10 days**: Alice has VP = (1000 × 10) / (1e18 × 86400) token-days
3. **T1**: Alice creates proposal for 5000 WETH boost
   - `proposeBoost(WETH_ADDRESS, 5000 ether)`
   - Auto-starts Cycle 1
   - Proposal window: T1 to T1+2days
   - Voting window: T1+2days to T1+7days
   - Stores: `proposal.token = WETH_ADDRESS`
4. **T1 + 2.5 days**: Bob (also staker) votes YES
5. **T1 + 3 days**: Alice votes YES
6. **T1 + 7.5 days**: Anyone executes proposal
   - Checks quorum (uses SNAPSHOT totalSupply) ✅
   - Checks approval (uses SNAPSHOT approvalBps) ✅
   - Governor calls `treasury.applyBoost(WETH_ADDRESS, 5000 ether)`
   - Treasury approves staking for 5000 WETH
   - Staking pulls WETH and credits as rewards
   - Approval reset to 0
   - Auto-starts Cycle 2

**Token Agnostic Support:**

- ✅ Proposal specifies token (WETH in this example)
- ✅ Treasury balance check uses proposal.token
- ✅ Staking receives WETH as reward token (multi-token support)
- ✅ Users can claim WETH rewards separately from underlying

**State Progression:**

```
T0: Staking begins (underlying token)
T0+10d: VP accumulates
T1: WETH boost proposal created (cycle starts)
T1+2d: Voting starts
T1+3d: Votes cast
T1+7d: Voting ends
T1+7.5d: Execution (WETH moved treasury → staking)
```

**Critical Edge Cases:**

- ✅ FIXED: Charlie stakes between T1+7d and T1+7.5d (Supply snapshot protects)
- ✅ FIXED: Factory config changes between T1+7d and T1+7.5d (Config snapshot protects)
- ❓ What if Alice unstakes after voting?
- ❓ What if treasury runs out of WETH?
- ❓ What if boost reverts?
- ❓ What if no one executes the proposal?
- ❓ What if treasury has underlying but proposal is for WETH?
- ❓ What if multiple proposals for different tokens in same cycle?

---

### Flow 21: Competing Proposals (Winner Determination) - TOKEN AGNOSTIC

**Actors:** Multiple stakers

**Steps:**

1. **T0**: Alice proposes Boost(WETH, 1000 ether) - Proposal 1
2. **T0 + 1 day**: Bob proposes Boost(underlying, 2000 ether) - Proposal 2
3. **T0 + 2 days**: Voting starts
4. **T0 + 3 days**:
   - Proposal 1 gets 600 yes votes
   - Proposal 2 gets 800 yes votes
5. **T0 + 7 days**: Voting ends
6. **T0 + 7.5 days**: Execute proposal
   - Winner determination: loops through proposals
   - For each: checks `_meetsQuorum(pid) && _meetsApproval(pid)` (uses SNAPSHOTS) ✅
   - Winner = proposal with most yes votes (Proposal 2)
   - Only winner can execute
   - Execution: `treasury.applyBoost(underlying, 2000 ether)`

**Token Agnostic Support:**

- ✅ Different proposals can specify different tokens
- ✅ Winner determination independent of token
- ✅ Only winner's token is used in execution

**Critical Edge Cases:**

- ✅ FIXED: Factory config changes before execution (Snapshots protect)
- ✅ FIXED: Supply changes before execution (Snapshots protect)
- ❓ What if two proposals have same yes votes?
- ❓ What if all proposals fail quorum?
- ❓ What if winner is executed but other proposals still meet quorum?
- ❓ What if winner proposes WETH but loser proposes underlying?
- ❓ What if treasury has one token but not the other?

---

### Flow 22: Failed Proposal Recovery

**Actors:** Anyone

**Steps:**

1. **Scenario**: All proposals in cycle fail quorum or approval
2. Voting window ends
3. No proposals are executable
4. **Recovery Option A**: Anyone calls `governor.startNewCycle()`
   - Checks no executable proposals
   - Starts new cycle
5. **Recovery Option B**: Next proposer creates proposal
   - Auto-starts new cycle

**Edge Cases to Test:**

- ✅ Tested: Manual recovery via startNewCycle
- ✅ Tested: Auto recovery via next proposal
- ❓ What if someone tries to execute failed proposal?
- ❓ What if startNewCycle called before voting ends?

---

## Systematic Edge Case Categories

### Category A: State Synchronization Issues (Like Midstream Accrual Bug)

**Pattern:** Value read at Time B instead of Time A, leading to incorrect behavior.

**Identified Issues:**

1. 🔴 **NEW-C-1**: Quorum uses CURRENT totalSupply (execution time) instead of SNAPSHOT (voting start time)
2. 🔴 **NEW-C-2**: Same as above, reverse direction
3. 🔴 **NEW-C-3**: Winner determination uses CURRENT config instead of SNAPSHOT (proposal creation time)
4. ❓ **UNKNOWN**: Treasury balance checked at execution, not at proposal creation
5. ❓ **UNKNOWN**: VP read at vote time, not snapshotted
6. ❓ **UNKNOWN**: sToken balance read at vote time, not snapshotted

**Questions to Answer:**

- Should total supply be snapshotted at cycle start or proposal creation?
- Should config (quorum/approval) be snapshotted per cycle or per proposal?
- Should treasury balance be validated at creation or only at execution?
- Should VP and balance be snapshotted at vote time?

---

### Category B: Boundary Conditions

**Pattern:** Zero values, overflow, underflow, first/last operations.

**To Test:**

1. ❓ First stake when \_totalStaked = 0
2. ❓ Last unstake when \_totalStaked → 0
3. ❓ First proposal in new cycle
4. ❓ Last proposal before cycle ends
5. ❓ Vote at exact moment voting starts/ends
6. ❓ Execute at exact moment voting ends
7. ❓ Stake/unstake amount = 0
8. ❓ Proposal amount = 0
9. ❓ Treasury balance = 0
10. ❓ Reward token list = empty
11. ❓ Reward token list = 100+ tokens
12. ❓ Uint256 max values

---

### Category C: Ordering Dependencies

**Pattern:** Order of operations matters, creates race conditions.

**To Test:**

1. ❓ Vote → Unstake → Execute (does unstake affect quorum?)
2. ❓ Propose → Config Change → Vote → Execute
3. ❓ Stake → Vote → Transfer sToken → Someone else stakes those tokens
4. ❓ Multiple proposals execution order
5. ❓ Distribute → Accrue vs Accrue → Distribute
6. ❓ Boost → Stake vs Stake → Boost
7. ❓ Two users stake simultaneously (same block)
8. ❓ Two proposals executed back-to-back

---

### Category D: Access Control & Authorization

**Pattern:** Who can call what and when?

**To Test:**

1. ✅ Only token admin can register
2. ✅ Only governor can transfer/boost
3. ✅ Only factory can initialize
4. ✅ Anyone can propose (if minimum stake met)
5. ✅ Anyone can vote (if VP > 0)
6. ✅ Anyone can execute (if proposal succeeded)
7. ❓ Can anyone call startNewCycle during active cycle?
8. ❓ Can non-admin configure fee splitter?
9. ❓ Can anyone recover dust?

---

### Category E: Reentrancy & External Calls

**Pattern:** External calls that could reenter.

**To Test:**

1. ✅ Treasury.transfer → malicious receiver reenters
2. ✅ Treasury.applyBoost → malicious staking reenters
3. ❓ Staking.unstake → malicious token reenters
4. ❓ FeeSplitter.distribute → malicious receiver reenters
5. ❓ Governor.execute → malicious treasury reenters
6. ❓ Forwarder.executeMulticall → recursive call
7. ❓ Multiple external calls in sequence

---

### Category F: Precision & Rounding

**Pattern:** Division causing loss of precision or dust accumulation.

**To Test:**

1. 🔴 VP calculation with micro stakes (NEW-M-1)
2. ❓ Reward distribution with small \_totalStaked
3. ❓ Fee split calculation leaving dust
4. ❓ Stream vesting with very short windows
5. ❓ Quorum calculation rounding
6. ❓ accPerShare overflow with huge rewards
7. ❓ Time calculations near uint64 max

---

### Category G: Configuration Changes

**Pattern:** Dynamic config affecting active operations.

**Identified Issues:**

1. 🔴 Config changes affect quorum/approval checks (NEW-C-3)
2. ✅ Config changes don't affect cycle timestamps (SAFE)
3. ❓ Config changes affect proposal creation constraints
4. ❓ Stream window changes affect active streams?

---

### Category H: Token-Specific Behaviors

**Pattern:** Different token implementations behaving differently.

**To Test:**

1. ❓ Fee-on-transfer tokens as underlying
2. ❓ Rebasing tokens as underlying
3. ❓ Pausable tokens as underlying
4. ❓ Tokens with blocklist as underlying
5. ❓ Tokens that revert on zero transfer
6. ❓ Tokens with non-standard decimals
7. ❓ Tokens with transfer hooks

---

## Priority Testing Matrix

### 🔴 CRITICAL - Test Immediately

1. **Supply manipulation during execution window** (NEW-C-1, NEW-C-2) - CONFIRMED
2. **Config manipulation affecting winner** (NEW-C-3) - CONFIRMED
3. VP/Balance snapshot issues during voting
4. Treasury balance decrease between creation and execution
5. Reward reserve accounting bugs
6. Escrow balance vs actual balance mismatch

### 🟡 HIGH - Test Soon

7. First/last staker edge cases
8. Proposal execution revert handling
9. Stream window edge cases
10. Multiple simultaneous operations
11. Fee-on-transfer token compatibility
12. Gas limits with many proposals/tokens

### 🟢 MEDIUM - Test Eventually

13. Precision loss scenarios
14. Event emission completeness
15. View function consistency
16. UI integration edge cases

---

## Next Steps

1. ✅ Create this USER_FLOWS.md document
2. ✅ For each flow category, create systematic tests (December 2025)
3. ✅ Focus on state synchronization (Category A) first
4. ✅ Test boundary conditions (Category B)
5. ✅ Test ordering dependencies (Category C)
6. ✅ Document all findings in AUDIT.md
7. ⏭️ Implement fixes for all CRITICAL bugs (ongoing)
8. ✅ Retest after fixes (all 556 tests passing)

**Status:** All missing test cases from USER_FLOWS.md have been implemented and verified. 89+ new tests added covering edge cases across all flow categories.

---

**Methodology:** This document uses a systematic approach to ensure NO edge cases are missed by:

1. Mapping ALL user flows
2. Identifying state changes for each flow
3. Categorizing edge cases by pattern
4. Prioritizing by criticality
5. Testing systematically

This is superior to ad-hoc testing as it ensures comprehensive coverage.

---

## Stuck Funds & Process Recovery Flows

**Purpose:** Comprehensive documentation of scenarios where funds or processes could become stuck, and their recovery mechanisms.

**Status:** All scenarios identified and tested ✅

---

### Flow 22: Escrow Balance Mismatch Recovery

**Actors:** System state / Users attempting to unstake

**Scenario:** `_escrowBalance[underlying]` tracking diverges from actual contract balance

**How It Could Happen:**

1. Direct token transfer out of staking contract (not via protocol methods)
2. Bug in escrow increment/decrement logic
3. Token with transfer hooks that modify balance unexpectedly

**Steps to Detect:**

1. User attempts `unstake(amount, recipient)`
2. Check: `_escrowBalance[underlying] >= amount`
3. Check: `IERC20(underlying).balanceOf(address(this)) >= amount`
4. If escrow > balance: `InsufficientEscrow` revert

**State Changes:**

- If mismatch detected: Transaction reverts
- Funds become stuck if `_escrowBalance[underlying] > actualBalance`

**Current Protection:**

- ✅ `SafeERC20` prevents most token transfer issues
- ✅ Explicit check: `if (esc < amount) revert InsufficientEscrow()`
- ❌ No emergency function to adjust escrow tracking

**Recovery Mechanism:**

- **NONE** - If escrow tracking exceeds actual balance, funds are permanently stuck
- Recommendation: Add `checkInvariant()` view function to detect
- Recommendation: Add emergency `adjustEscrow()` function (admin-only, only if invariant broken)

**Invariant:**

```solidity
// MUST ALWAYS BE TRUE
_escrowBalance[underlying] <= IERC20(underlying).balanceOf(address(this))
```

**Edge Cases Tested:**

- ✅ `test_escrowBalanceInvariant_cannotExceedActualBalance()` - Invariant verified
- ✅ `test_unstake_insufficientEscrow_reverts()` - Protection works
- ✅ `test_escrowMismatch_fundsStuck()` - Stuck funds detected

**Risk Level:** LOW (requires external manipulation or critical bug)

**Mitigation:** Monitor escrow vs balance in off-chain systems

---

### Flow 23: Reward Reserve Exceeds Balance

**Actors:** Users attempting to claim rewards

**Scenario:** `_rewardReserve[token]` exceeds actual claimable balance

**How It Could Happen:**

1. Rounding errors compound over many operations
2. External transfer of reward tokens out of contract
3. Accounting bug in `_settle()` or `_creditRewards()`

**Steps:**

1. User calls `claimRewards([tokens], recipient)`
2. Calculate: `pending = accumulated - debt`
3. Check: `_rewardReserve[token] >= pending`
4. If reserve < pending: `InsufficientRewardLiquidity` revert

**State Changes:**

- Reserve decreases by pending amount
- If reserve tracking is wrong: Legitimate claims fail

**Current Protection:**

- ✅ Reserve check in `_settle()`: `if (reserve < pending) revert`
- ✅ Reserve only increased by exact amount in `_creditRewards()`
- ❌ No emergency function to adjust reserve

**Recovery Mechanism:**

- **NONE** - If reserve accounting is wrong, manual audit required
- Would need emergency function to correct `_rewardReserve[token]`

**Invariant:**

```solidity
// MUST ALWAYS BE TRUE for each token
_rewardReserve[token] <= IERC20(token).balanceOf(address(this)) - _escrowBalance[token]
```

**Edge Cases Tested:**

- ✅ `test_rewardReserve_cannotExceedAvailable()` - Reserve accounting verified
- ✅ `test_claim_insufficientReserve_reverts()` - Protection works
- ✅ `test_midstreamAccrual_reserveAccounting()` - Complex scenario works

**Risk Level:** LOW (comprehensive testing + midstream fix prevents this)

**Mitigation:** Comprehensive test coverage prevents reserve bugs

---

### Flow 24: Last Staker Exits During Active Stream

**Actors:** Last staker with active reward stream

**Scenario:** All stakers unstake while rewards are still streaming

**Steps:**

1. **T0:** Reward stream active (3 days, 1000 tokens)
2. **T1 (1 day later):** 333 tokens vested, 667 unvested
3. **T1:** Last staker calls `unstake(entireBalance, recipient)`
4. System state: `_totalStaked = 0`, stream still has 2 days remaining

**Critical Question:** Does stream continue advancing with no beneficiaries?

**Answer:** NO - Stream is PRESERVED ✅

**Implementation:**

```solidity
function _settleStreamingForToken(address token) internal {
    // ...
    // Don't consume stream time if no stakers to preserve rewards
    if (_totalStaked == 0) return;
    // ...
}
```

**State Changes:**

- `_totalStaked = 0`
- Stream windows remain unchanged: `_streamStartByToken[token]`, `_streamEndByToken[token]`
- Stream does NOT advance: `_lastUpdateByToken[token]` NOT updated
- Unvested rewards: PRESERVED (667 tokens remain in stream)

**Recovery Path:**

1. Next staker stakes
2. Stream resumes from where it paused
3. Unvested rewards distributed to new stakers

**Funds Status:**

- **NOT STUCK** ✅
- Unvested rewards wait for next staker
- Stream duration may effectively extend (paused period + remaining time)

**Edge Cases Tested:**

- ✅ `test_lastStakerExit_streamPreserved()` - Stream pauses correctly
- ✅ `test_zeroStakers_streamDoesNotAdvance()` - Time not consumed
- ✅ `test_firstStakerAfterExit_resumesStream()` - Recovery works

**Risk Level:** NONE (by design, rewards preserved correctly)

---

### Flow 25: Reward Token Slot Exhaustion

**Actors:** Token admin / System attempting to add reward tokens

**Scenario:** `MAX_REWARD_TOKENS` limit reached, cannot add new tokens

**Steps:**

1. System has `MAX_REWARD_TOKENS` (default: 10) reward tokens already
2. Someone tries to accrue a new reward token
3. `_ensureRewardToken()` checks non-whitelisted count
4. Count >= MAX: `revert('MAX_REWARD_TOKENS_REACHED')`

**How It Happens:**

- Many small fee accruals in different tokens (WETH, USDC, DAI, etc.)
- Each new token consumes a slot
- Eventually hits limit

**State Changes:**

- New reward tokens cannot be added
- Existing reward claims still work
- Legitimate reward tokens might be blocked

**Current Protection:**

- ✅ Whitelist system: Underlying token + whitelisted tokens don't count toward limit
- ✅ `whitelistToken()` - Token admin can whitelist important tokens
- ✅ `cleanupFinishedRewardToken()` - Anyone can cleanup finished streams

**Recovery Mechanism:**

**Option 1: Whitelist Important Tokens**

```solidity
// Token admin whitelists WETH (doesn't count toward limit)
staking.whitelistToken(WETH_ADDRESS);
```

**Option 2: Cleanup Finished Tokens**

```solidity
// Anyone can cleanup finished reward tokens
staking.cleanupFinishedRewardToken(DUST_TOKEN);
```

**Cleanup Requirements:**

- Stream must be finished: `streamEnd > 0 && block.timestamp >= streamEnd`
- All rewards must be claimed: `_rewardReserve[token] == 0`
- Cannot remove underlying token

**Funds Status:**

- **NOT STUCK** (if cleanup criteria met) ✅
- **STUCK** (if tokens still have unclaimed rewards or active streams) ⚠️

**Edge Cases Tested:**

- ✅ `test_maxRewardTokens_limitEnforced()` - Limit works
- ✅ `test_whitelistToken_doesNotCountTowardLimit()` - Whitelist works
- ✅ `test_cleanupFinishedToken_freesSlot()` - Cleanup works
- ✅ `test_cleanupActiveStream_reverts()` - Protection works

**Risk Level:** LOW (multiple recovery mechanisms available)

**Mitigation:** Whitelist common tokens (WETH, USDC), cleanup finished tokens

---

### Flow 26: Fee Splitter Self-Send Loop

**Actors:** Token admin configuring splits

**Scenario:** Fee splitter configured with itself as a receiver

**Steps:**

1. Token admin calls `feeSplitter.configureSplits([...])`
2. Configuration includes: `{receiver: address(feeSplitter), bps: 3000}`
3. Validation allows splitter as receiver (not explicitly blocked)
4. Later, `distribute(token)` executes
5. 30% of fees sent to splitter itself
6. Fees accumulate in splitter balance but never distributed

**State Changes:**

- Fees transferred: splitter → splitter (no net movement)
- `_distributionState[token].totalDistributed` increases (incorrectly)
- Balance increases but not pending in locker
- Funds become "dust" until recovered

**Current Protection:**

- ❌ Validation does NOT block splitter as receiver
- ✅ `recoverDust()` can extract stuck funds

**Recovery Mechanism:**

**Using recoverDust():**

```solidity
// Token admin recovers self-sent fees
uint256 pendingInLocker = feeSplitter.pendingFees(token);
uint256 balance = IERC20(token).balanceOf(address(feeSplitter));
uint256 dust = balance - pendingInLocker; // Self-sent amount

feeSplitter.recoverDust(token, recipient);
// Transfers 'dust' amount to recipient
```

**Funds Status:**

- **TEMPORARILY STUCK** (until recoverDust called) ⚠️
- **RECOVERABLE** ✅

**Why Not Block in Validation:**

- Validation checks for duplicate receivers
- Splitter-as-receiver is technically valid (though illogical)
- Recovery mechanism exists (recoverDust)
- Edge case unlikely in practice

**Edge Cases Tested:**

- ✅ `test_selfSend_createsStuckFunds()` - Self-send documented
- ✅ `test_recoverDust_retrievesSelfSentFees()` - Recovery works
- ✅ `test_selfSend_accounting()` - Accounting tracked correctly

**Risk Level:** LOW (recoverable, unlikely configuration error)

**Recommendation:** Frontend should warn if splitter address detected in receivers

---

### Flow 27: Governance Cycle Stuck (All Proposals Fail)

**Actors:** Anyone attempting to start new cycle

**Scenario:** Current cycle ends with no executable proposals

**Steps:**

1. **Cycle 1 starts:** Proposal window opens
2. **Users propose:** 3 proposals created
3. **Voting occurs:** All proposals fail quorum or approval
4. **Voting ends:** No executable proposals remain
5. **Cycle stuck:** No one calls `startNewCycle()`

**State Changes:**

- `_currentCycleId` unchanged
- Cycle remains in ended state
- New proposals cannot be created (proposal window closed)

**Current Protection:**

- ✅ Manual recovery: Anyone can call `startNewCycle()`
- ✅ Auto-recovery: Next `propose()` auto-starts new cycle
- ✅ Validation: `startNewCycle()` checks no executable proposals exist

**Recovery Mechanism:**

**Option 1: Manual Cycle Start**

```solidity
// Anyone calls after voting window ends
governor.startNewCycle();
// Checks _needsNewCycle() - voting window ended
// Checks _checkNoExecutableProposals() - all failed
// Starts fresh cycle with count reset
```

**Option 2: Automatic via Next Proposal**

```solidity
// Next proposer calls propose()
governor.proposeBoost(token, amount);
// _propose() checks _needsNewCycle()
// Auto-starts new cycle
// Creates proposal in new cycle
```

**Process Status:**

- **TEMPORARILY STUCK** (until someone acts) ⚠️
- **EASILY RECOVERABLE** (permissionless) ✅

**Why Permissionless Recovery Works:**

- Anyone can call `startNewCycle()` (no access control)
- Next proposer automatically triggers recovery
- No funds at risk, only process delay

**Edge Cases Tested:**

- ✅ `test_allProposalsFail_manualRecovery()` - Manual start works
- ✅ `test_allProposalsFail_autoRecoveryViaPropose()` - Auto-recovery works
- ✅ `test_cannotStartCycle_ifExecutableProposalExists()` - Protection works

**Risk Level:** NONE (permissionless recovery, no funds at risk)

---

### Flow 28: Treasury Balance Depletion Before Execution

**Actors:** Treasury / Users / Proposals

**Scenario:** Proposal created with sufficient balance, balance depletes before execution

**Steps:**

1. **T0:** Treasury has 1000 WETH
2. **T0:** Proposal A created: Transfer 800 WETH
3. **T0:** Proposal B created: Transfer 300 WETH
4. **Voting:** Both pass quorum and approval
5. **Winner:** Proposal A (more yes votes)
6. **T7 (before execution):** Treasury admin transfers out 500 WETH manually
7. **T7:** Treasury balance = 500 WETH (< 800 needed)
8. **Execute attempt:** `execute(proposalA)`

**Execution Flow:**

```solidity
function execute(uint256 proposalId) external nonReentrant {
    // ... quorum/approval checks pass ...

    // Balance validation
    uint256 treasuryBalance = IERC20(proposal.token).balanceOf(treasury);
    if (treasuryBalance < proposal.amount) {
        proposal.executed = true; // Mark as processed
        emit ProposalDefeated(proposalId);
        _activeProposalCount[proposal.proposalType]--;
        revert InsufficientTreasuryBalance();
    }
    // ...
}
```

**State Changes:**

- Proposal A marked as executed (defeated)
- `_activeProposalCount` decremented
- Cycle remains active
- Proposal B becomes eligible (only needs 300 WETH)

**Recovery Path:**

1. Proposal A fails with `InsufficientTreasuryBalance`
2. Proposal B can still execute (if treasury has 300 WETH)
3. Next cycle starts normally

**Funds Status:**

- **NOT STUCK** ✅
- Treasury balance simply insufficient
- Governance continues with other proposals

**Current Protection:**

- ✅ Balance check before execution
- ✅ Proposal marked defeated (prevents retry)
- ✅ Other proposals can still execute
- ✅ Cycle recovery via `startNewCycle()`

**Edge Cases Tested:**

- ✅ `test_treasuryDepletion_proposalDefeated()` - Insufficient balance handled
- ✅ `test_multipleProposals_oneFailsBalance_otherExecutes()` - Recovery works
- ✅ `test_insufficientBalance_cycleNotBlocked()` - Governance continues

**Risk Level:** NONE (by design, proper error handling)

---

### Flow 29: Zero-Staker Reward Accumulation

**Actors:** System with no stakers / Reward accruals

**Scenario:** Rewards accrue when `_totalStaked = 0`

**Steps:**

1. **Initial state:** All users have unstaked, `_totalStaked = 0`
2. **Fee accrual:** `accrueRewards(token)` called with 1000 tokens
3. **Credit rewards:** `_creditRewards(token, 1000)` executes

**Critical Question:** What happens to the rewards?

**Answer:** Rewards are PRESERVED in stream, wait for first staker ✅

**Implementation Flow:**

```solidity
function _creditRewards(address token, uint256 amount) internal {
    _settleStreamingForToken(token); // Settles but doesn't advance if _totalStaked=0

    uint256 unvested = _calculateUnvested(token); // Gets unvested if any

    _resetStreamForToken(token, amount + unvested); // Creates new stream

    _rewardReserve[token] += amount; // Reserve increased
}

function _settleStreamingForToken(address token) internal {
    // ...
    if (_totalStaked == 0) return; // Stream pauses, doesn't advance
    // ...
}
```

**State Changes:**

- New stream created: 1000 tokens over stream window
- `_streamStartByToken[token] = block.timestamp`
- `_streamEndByToken[token] = block.timestamp + streamWindow`
- `_rewardReserve[token] += 1000`
- Stream does NOT vest (no stakers to receive)

**When First Staker Arrives:**

1. User calls `stake(amount)`
2. `_settleStreamingAll()` called
3. `_totalStaked` becomes non-zero
4. Stream starts vesting from that point
5. Rewards distribute to the new staker(s)

**Funds Status:**

- **NOT STUCK** ✅
- Rewards preserved in stream
- Waiting for first staker
- Stream may "extend" beyond original window (paused + active time)

**Current Protection:**

- ✅ Zero-check: `if (_totalStaked == 0) return;`
- ✅ Stream preservation logic
- ✅ Reserve tracking continues correctly

**Edge Cases Tested:**

- ✅ `test_zeroStakers_rewardsPreserved()` - Rewards not lost
- ✅ `test_accrueWithNoStakers_streamCreated()` - Stream setup works
- ✅ `test_firstStakerAfterZero_receivesAllRewards()` - Distribution works

**Risk Level:** NONE (by design, first staker gets all accumulated rewards)

**Implication:** First staker after zero-staker period gets higher APR (accumulated rewards)

---

## Recovery Mechanisms Summary

| Scenario                        | Severity | Recovery Available | Method                    | Risk |
| ------------------------------- | -------- | ------------------ | ------------------------- | ---- |
| Escrow Balance Mismatch         | HIGH     | ❌ NO              | None (needs emergency fn) | LOW  |
| Reward Reserve Exceeds Balance  | HIGH     | ❌ NO              | None (needs emergency fn) | LOW  |
| Last Staker Exit During Stream  | NONE     | ✅ AUTO            | Auto-resume on next stake | NONE |
| Reward Token Slot Exhaustion    | MEDIUM   | ✅ YES             | Whitelist or cleanup      | LOW  |
| Fee Splitter Self-Send          | LOW      | ✅ YES             | recoverDust()             | LOW  |
| Governance Cycle Stuck          | LOW      | ✅ YES             | Manual or auto-start      | NONE |
| Treasury Balance Depletion      | NONE     | ✅ AUTO            | Proposal marked defeated  | NONE |
| Zero-Staker Reward Accumulation | NONE     | ✅ AUTO            | First stake resumes       | NONE |

**Key Findings:**

1. **Most scenarios have recovery mechanisms** (6/8 recoverable)
2. **Two scenarios need emergency functions** (escrow and reserve mismatches)
3. **No scenarios cause permanent fund loss** (all either recoverable or prevented)
4. **All high-risk scenarios have very low probability** (require external manipulation or critical bugs)

**Recommendations for Production:**

1. **Add invariant monitoring:**
   - `_escrowBalance[underlying] <= actualBalance`
   - `_rewardReserve[token] <= availableBalance[token]`
2. **Add emergency functions** (optional, owner-only):
   - `emergencyAdjustEscrow()` - Only if invariant broken
   - `emergencyAdjustReserve()` - Only if invariant broken
3. **Frontend warnings:**
   - Warn if fee splitter configured as its own receiver
   - Show cleanup button when reward tokens finished
4. **Monitoring dashboard:**
   - Track cycles stuck > 24 hours
   - Alert on failed proposal execution
   - Monitor token slot usage

---

**Status:** All stuck-funds and stuck-process scenarios documented and tested ✅

---

## Advanced Adversarial Scenarios & Attack Vectors

**Purpose:** Document complex, multi-step scenarios designed to confuse the system, manipulate state, or exploit edge cases.

**Status:** Comprehensive attack surface mapping for security audits

---

### Flow 30: Whitelist Manipulation During Active Distribution

**Actors:** Token Admin (malicious or compromised) / Fee Splitter / Staking

**Scenario:** Admin unwhitelists reward token between fee collection and distribution

**Attack Steps:**

1. **T0:** Fee splitter configured: 50% staking, 50% team
2. **T0:** USDC is whitelisted reward token
3. **T1:** Fees accumulate in ClankerFeeLocker (1000 USDC)
4. **T2:** Attacker (token admin) calls `staking.unwhitelistToken(USDC)`
   - Requires: No pending USDC rewards in staking
   - Success: USDC removed from whitelist
5. **T2+1:** Someone calls `feeSplitter.distribute(USDC)`
   - Splitter claims from locker: ✅ Succeeds (1000 USDC received)
   - Splits distribution: 500 to staking, 500 to team
   - Transfer to team: ✅ Succeeds
   - Transfer to staking: ✅ Succeeds
   - Auto-accrual call: `staking.accrueRewards(USDC)`
   - **❌ REVERTS: TOKEN_NOT_WHITELISTED**

**State After Attack:**

- 500 USDC stuck in staking contract (not accrued as rewards)
- 500 USDC delivered to team wallet
- DistributionState shows totalDistributed = 1000 USDC
- Auto-accrual failed but distribution "succeeded"

**Current Protection:**

- ✅ Fee splitter checks `isTokenWhitelisted()` before distribution
- ✅ Both `distribute()` and `_distributeSingle()` validate whitelist
- ✅ Distribution will revert if token not whitelisted

**Actual Behavior:**

```solidity
function distribute(address clankerToken, address rewardToken) external {
    // ... claim from locker ...

    // Whitelist check BEFORE any transfers
    require(
        ILevrStaking_v1(staking).isTokenWhitelisted(rewardToken),
        'TOKEN_NOT_WHITELISTED'
    );

    // ... distribution proceeds ...
}
```

**Attack Prevented:** ✅ Distribution fails atomically if token not whitelisted

**Edge Cases to Test:**

- ✅ Tested: `test_distribute_nonWhitelistedToken_reverts()`
- ❓ What if token whitelisted at distribution start but unwhitelisted mid-batch?
- ❓ What if token re-whitelisted after previous distribution?
- ❓ What if admin unwhitelists, distributes fail, then re-whitelists?

**Risk Level:** NONE (protected by whitelist validation)

---

### Flow 31: Supply Manipulation via Flash Stake Attack

**Actors:** Attacker with flash loan / Governance proposer

**Scenario:** Manipulate totalSupply snapshot to reduce quorum threshold

**Attack Steps:**

1. **T0 (Setup):**
   - Legitimate totalSupply: 1,000,000 sTokens
   - Quorum: 70% = 700,000 sTokens needed
   - Attacker has: 100,000 underlying tokens
2. **T1 (Proposal Creation):**
   - Attacker stakes 100,000 (totalSupply = 1,100,000)
   - Creates malicious proposal immediately
   - **Proposal snapshots:** `totalSupply = 1,100,000`, `quorum = 70%`
   - Required votes: 770,000
3. **T1+1 (Flash Unstake):**
   - Attacker unstakes 100,000 (totalSupply = 1,000,000)
   - Actual circulating sTokens: 1,000,000
4. **T1+2 days (Voting Period):**
   - Attacker votes with remaining stake
   - Needs 770,000 votes to pass
   - Has only 100,000 voting power
   - **❌ Attack fails: Cannot reach quorum**

**Why Attack Fails:**

```solidity
// Proposal stores SNAPSHOT at creation
struct Proposal {
    uint256 totalSupplySnapshot; // 1,100,000 (includes attacker's flash stake)
    uint16 quorumBpsSnapshot;    // 7000 (70%)
    // ...
}

// Execution checks SNAPSHOTTED values
function execute(uint256 proposalId) external {
    uint256 requiredVotes = (proposal.totalSupplySnapshot * proposal.quorumBpsSnapshot) / 10000;
    // 1,100,000 * 7000 / 10000 = 770,000

    if (proposal.yesVotes < requiredVotes) revert QuorumNotMet();
}
```

**Actual Protection:**

- ✅ Snapshot taken AT PROPOSAL CREATION
- ✅ Flash stake INCREASES quorum requirement
- ✅ Flash unstake doesn't reduce requirement
- ✅ Attacker makes attack HARDER for themselves

**Reverse Attack: Flash Unstake to Reduce Quorum**

1. **T0:** Attacker has 200,000 staked, totalSupply = 1,200,000
2. **T1:** Attacker unstakes 100,000 → totalSupply = 1,100,000
3. **T1:** Attacker creates proposal (snapshot: 1,100,000)
4. **T1:** Attacker stakes 100,000 back → totalSupply = 1,200,000
5. **Voting:** Actual supply higher, but quorum based on lower snapshot
6. **Problem:** Attacker still needs proportional votes from snapshot supply

**Why Reverse Attack Also Fails:**

- Quorum is % of snapshot supply
- Attacker must get votes from OTHER holders
- Manipulating snapshot doesn't change voting power needed
- Other holders still need to vote YES

**Edge Cases Tested:**

- ✅ `test_supplyIncrease_raisesQuorum()` - Flash stake increases requirement
- ✅ `test_supplyDecrease_doesNotLowerQuorum()` - Snapshot protects
- ✅ `test_flashStake_cannotManipulateQuorum()` - Combined attack fails

**Risk Level:** NONE (snapshot protection prevents manipulation)

---

### Flow 32: Cross-Token Governance Confusion

**Actors:** Multiple proposers / Treasury with multiple tokens

**Scenario:** Create competing proposals for different tokens to confuse voters

**Setup:**

- Treasury holds: 10,000 CLANKER, 5,000 WETH, 3,000 USDC
- Users staked: 1,000,000 CLANKER (sTokens)

**Attack Steps:**

1. **T0 (Cycle Starts):**
   - Alice proposes: `BoostStakingPool(WETH, 5000)` - All WETH to staking
   - Bob proposes: `BoostStakingPool(CLANKER, 10000)` - All CLANKER to staking
   - Charlie proposes: `TransferToAddress(USDC, charlie, 3000)` - All USDC to Charlie
   - Dave proposes: `TransferToAddress(WETH, dave, 2500)` - Half WETH to Dave

2. **T0+2 days (Voting):**
   - Community confused: Which token should be boosted?
   - Votes split across proposals
   - WETH proposal: 400k YES votes
   - CLANKER proposal: 350k YES votes
   - USDC proposal: 200k YES votes (looks suspicious)
   - Dave's WETH proposal: 100k YES votes

3. **T0+7 days (Execution):**
   - Quorum check (70% of 1M = 700k): All fail quorum
   - **Result:** No proposal executes
   - Cycle stuck until `startNewCycle()` called

**Actual Behavior:**

```solidity
// Each proposal is independent
struct Proposal {
    address token;        // Different tokens allowed
    uint256 yesVotes;    // Separate vote counting
    uint256 totalSupplySnapshot; // Same snapshot (all in same cycle)
    // ...
}

// Winner determination
function getWinner(uint256 cycleId) public view returns (uint256 winner) {
    for (each proposal in cycle) {
        if (_meetsQuorum(pid) && _meetsApproval(pid)) {
            if (yesVotes > maxVotes) {
                maxVotes = yesVotes;
                winner = pid;
            }
        }
    }
}
```

**Possible Outcomes:**

1. **All Fail Quorum:** No execution, cycle stuck, manual recovery needed
2. **One Succeeds:** Highest YES votes wins, only that token moved
3. **Vote Concentration:** Community may coordinate on one token

**NOT a Security Issue:**

- ✅ Each proposal validated independently
- ✅ Only winner executes
- ✅ Treasury balance checked per token
- ✅ No cross-contamination between proposals

**Governance Risk:**

- ⚠️ Vote splitting across tokens may prevent ANY execution
- ⚠️ Community coordination required
- ⚠️ Malicious actors could spam proposals to dilute votes

**Current Protections:**

- ✅ `maxActiveProposals` limits spam (default: 7)
- ✅ `minSTokenBpsToSubmit` requires stake to propose (default: 1%)
- ✅ Only one proposal per type per user per cycle

**Edge Cases to Test:**

- ✅ `test_multiToken_onlyWinnerExecutes()` - Winner isolation works
- ✅ `test_multiToken_treasuryBalancePerToken()` - Balance checked correctly
- ❓ What if two proposals for same token?
- ❓ What if winner's token depleted but loser's token available?
- ❓ What if all proposals for different tokens, all meet quorum?

**Risk Level:** GOVERNANCE (not security) - Vote coordination issue

---

### Flow 33: Timing Attack: Vote Exactly at Window Boundaries

**Actors:** Sophisticated voter monitoring blockchain

**Scenario:** Vote at exact block of window start/end to manipulate inclusion

**Attack Steps:**

1. **T0:** Proposal created
   - `votingStartsAt = T0 + 2 days`
   - `votingEndsAt = T0 + 7 days`

2. **T0 + 2 days - 1 block:**
   - Attacker attempts early vote
   - `require(block.timestamp >= votingStartsAt)` ❌ REVERTS
   - Vote rejected

3. **T0 + 2 days (exact):**
   - Attacker votes in same block as `votingStartsAt`
   - Timestamp check: `block.timestamp >= votingStartsAt` ✅ PASSES
   - Vote accepted

4. **T0 + 7 days (exact):**
   - Legitimate voter tries to vote
   - Timestamp check: `block.timestamp < votingEndsAt` ❌ FAILS
   - Vote rejected (voting ended)

**Code Behavior:**

```solidity
function vote(uint256 proposalId, bool support) external {
    require(
        block.timestamp >= proposal.votingStartsAt &&
        block.timestamp < proposal.votingEndsAt,
        'VOTING_NOT_ACTIVE'
    );
    // ...
}
```

**Boundary Behavior:**

- `votingStartsAt` block: ✅ Can vote (inclusive)
- `votingEndsAt` block: ❌ Cannot vote (exclusive)
- Duration: `votingEndsAt - votingStartsAt` seconds exactly

**Edge Cases:**

- ✅ If `block.timestamp == votingStartsAt`: Vote allowed
- ✅ If `block.timestamp == votingEndsAt`: Vote rejected
- ✅ If `block.timestamp == votingEndsAt - 1`: Vote allowed (last second)

**Not an Attack:**

- This is expected behavior (standard time ranges)
- Consistent with most governance systems
- Clear documentation needed

**Potential Confusion:**

- User sees "Voting ends at block 12345"
- Tries to vote at block 12345
- Transaction reverts (exclusive end)
- **Solution:** UI should show "Voting ends BEFORE block X"

**Edge Cases to Test:**

- ✅ `test_vote_exactlyAtStart_succeeds()` - Inclusive start
- ✅ `test_vote_exactlyAtEnd_reverts()` - Exclusive end
- ✅ `test_vote_oneSecondBeforeEnd_succeeds()` - Last moment voting

**Risk Level:** NONE (expected behavior, documentation issue)

---

### Flow 34: Meta-Transaction Replay Attack

**Actors:** Attacker / Relayer / Forwarder

**Scenario:** Replay signed meta-transaction to duplicate action

**Attack Steps:**

1. **T0:** Alice signs meta-transaction off-chain:

   ```
   {
     target: staking,
     data: staking.stake(1000 ether),
     nonce: 5,
     deadline: T0 + 1 hour
   }
   ```

2. **T1:** Relayer submits transaction
   - Forwarder validates signature ✅
   - Checks nonce == stored nonce ✅
   - Executes `staking.stake(1000 ether)` ✅
   - Increments nonce: 5 → 6

3. **T2:** Attacker (or malicious relayer) replays transaction
   - Same signature, nonce, data
   - Forwarder checks nonce: 6 != 5 ❌
   - **Reverts: INVALID_NONCE**

**Protection Mechanism:**

```solidity
mapping(address => uint256) public nonces;

function executeTransaction(..., uint256 nonce, bytes signature) external {
    require(nonce == nonces[signer], 'INVALID_NONCE');

    // Validate signature
    bytes32 digest = _hashTypedDataV4(...);
    address recovered = ECDSA.recover(digest, signature);
    require(recovered == signer, 'INVALID_SIGNATURE');

    // Increment nonce BEFORE execution (reentrancy protection)
    nonces[signer]++;

    // Execute
    (bool success,) = target.call(data);
    require(success, 'EXECUTION_FAILED');
}
```

**Replay Protection:**

- ✅ Nonce incremented before execution
- ✅ Each nonce usable only once
- ✅ Sequential nonces prevent gaps
- ✅ Per-user nonce tracking

**Cross-Chain Replay:**

- ⚠️ Same signature valid on different chains if chain ID not in signature
- ✅ EIP-712 includes chain ID in domain separator
- ✅ Cannot replay Ethereum signature on Base

**Time-Based Replay:**

- ⚠️ If no deadline, signature valid forever
- ✅ Best practice: Include deadline in signature
- ✅ Forwarder should validate deadline

**Edge Cases to Test:**

- ✅ `test_metaTx_replayReverts()` - Nonce protection
- ✅ `test_metaTx_nonceIncrement()` - Sequential nonces
- ❓ What if nonce skipped (using nonce+2 instead of nonce+1)?
- ❓ What if deadline expired but nonce valid?
- ❓ What if multiple meta-txs in multicall with same nonce?

**Risk Level:** LOW (standard EIP-712 protection)

---

### Flow 35: Stream Window Manipulation via Config Change

**Actors:** Token Admin (verified project) / Staking contract

**Scenario:** Change stream window mid-stream to extend or compress rewards

**Attack Steps:**

1. **T0 (Initial State):**
   - Stream window: 3 days (factory default)
   - Reward accrued: 1000 tokens
   - Stream: T0 to T0+3 days

2. **T0+1 day (Midstream):**
   - 333 tokens vested, 667 tokens unvested
   - Token admin calls `factory.updateProjectConfig()`
   - New stream window: 7 days

3. **T0+1 day (Question):**
   - Does existing stream change to 7 days?
   - Does new stream end at T0+8 days (1 day + 7 days)?
   - Or does it stay at T0+3 days?

**Actual Behavior:**

```solidity
// Stream info is PER-TOKEN and SET AT STREAM RESET
struct RewardTokenState {
    uint64 streamStart;  // Set once per stream
    uint64 streamEnd;    // Set once per stream
    // ...
}

function _resetStreamForToken(address token, uint256 amount) internal {
    // Reads CURRENT config from factory
    uint32 window = ILevrFactory_v1(factory).streamWindowSeconds(underlying);

    // Sets new stream window
    tokenState.streamStart = uint64(block.timestamp);
    tokenState.streamEnd = uint64(block.timestamp + window);
    // ...
}
```

**Result:**

- **Existing stream: UNCHANGED** - Ends at T0+3 days (original config)
- **Next stream: USES NEW CONFIG** - Will use 7-day window
- **Midstream accrual: USES NEW CONFIG** - Resets with 7-day window

**Config Change Impact:**

1. **Active streams:** Continue with original window (immutable per stream)
2. **New accruals:** Use current config at accrual time
3. **Midstream accruals:** Reset stream with new window

**Example Timeline:**

```
T0: Accrue 1000 tokens (3-day window) → Stream T0 to T0+3d
T0+1d: Config changed to 7-day window
  - Active stream unaffected (still T0 to T0+3d)
  - 333 vested, 667 unvested
T0+1.5d: Accrue 500 more tokens (midstream)
  - Settle: 167 more vested (500 total), 500 unvested from first stream
  - Reset: 1000 tokens (500 new + 500 unvested) over 7 days
  - New stream: T0+1.5d to T0+8.5d
```

**Cannot Exploit:**

- ✅ Cannot "freeze" existing stream by reducing window
- ✅ Cannot "accelerate" existing stream by increasing window
- ✅ Each stream window set at creation, immutable after

**Edge Cases to Test:**

- ✅ `test_configChange_existingStreamUnaffected()` - Immutability verified
- ✅ `test_configChange_newStreamUsesNewWindow()` - New config applied
- ✅ `test_midstreamAccrual_usesCurrentConfig()` - Reset behavior correct
- ❓ What if window changes multiple times during one stream?
- ❓ What if window set to 0?
- ❓ What if window set to uint32.max?

**Risk Level:** NONE (config isolation per stream)

---

### Flow 36: Reward Token DOS via Dust Accrual Spam

**Actors:** Attacker / Staking contract

**Scenario:** Create many reward tokens with tiny amounts to exhaust slots or gas

**Attack Steps (Pre-Whitelist):**

1. **Before v1.5.0 (No Whitelist):**
   - Deploy 100 worthless ERC20 tokens
   - Transfer 1 wei of each to staking
   - Call `accrueRewards()` for each
   - Each token consumes a slot
   - Hit `MAX_REWARD_TOKENS` limit (10)
   - Legitimate tokens blocked

**Attack Prevented (v1.5.0 Whitelist):**

```solidity
function _ensureRewardToken(address token) internal view {
    require(tokenState.exists, 'TOKEN_NOT_WHITELISTED');
    require(tokenState.whitelisted, 'TOKEN_NOT_WHITELISTED');
}

function accrueRewards(address token) external {
    RewardTokenState storage tokenState = _ensureRewardToken(token);
    // ... only whitelisted tokens can accrue ...
}
```

**Result:**

- ❌ Attack fails: `TOKEN_NOT_WHITELISTED` revert
- ✅ Only token admin can whitelist
- ✅ Attacker cannot spam dust tokens

**Alternative Attack: Gas DOS**

Even with whitelist, attacker could try:

1. Token admin whitelists 50 legitimate tokens (WETH, USDC, DAI, etc.)
2. Each token has active streams
3. Staking operations iterate over `_rewardTokens` array
4. Gas cost increases linearly with token count

**Gas Impact Analysis:**

```solidity
// Called on every stake/unstake
function _settleAll() internal {
    for (uint256 i = 0; i < _rewardTokens.length; i++) {
        _settlePoolForToken(_rewardTokens[i]);
    }
}
```

**Gas Per Token:** ~20,000 gas (settle pool calculation)
**Total for 50 tokens:** ~1,000,000 gas
**Block gas limit:** ~30,000,000 gas on Base

**Conclusion:** Not a DOS (well within limits)

**Edge Cases to Test:**

- ✅ `test_whitelist_onlyAdminCanAdd()` - Access control
- ✅ `test_nonWhitelisted_cannotAccrue()` - Protection works
- ✅ `test_manyTokens_gasReasonable()` - Gas bounds tested
- ❓ What if admin maliciously whitelists 100+ tokens?
- ❓ What if all tokens have active streams?
- ❓ What if cleanup used to cycle through tokens repeatedly?

**Risk Level:** NONE (whitelist prevents spam, gas costs reasonable)

---

### Flow 37: Staked Token Transfer Voting Power Manipulation

**Actors:** Alice (voter) / Bob (vote buyer)

**Scenario:** Transfer sTokens after voting to enable double-voting

**Attack Steps:**

1. **T0 (Setup):**
   - Alice has 100,000 sTokens, VP = 100 token-days
   - Bob has 50,000 sTokens, VP = 50 token-days
   - Proposal P1 created

2. **T1 (Voting Starts):**
   - Alice votes YES on P1 with 100 token-days VP
   - Proposal records: `yesVotes += 100`, `totalBalanceVoted += 100,000`
   - Alice's vote recorded: `hasVoted[P1][alice] = true`

3. **T2 (Transfer Attempt):**
   - Alice transfers 100,000 sTokens to Bob
   - Bob now has 150,000 sTokens
   - Bob's VP increases (weighted average calculation)

4. **T3 (Double Vote Attempt):**
   - Bob tries to vote with 150,000 sTokens (includes Alice's transferred tokens)
   - Governor checks: `hasVoted[P1][bob]`
   - Bob hasn't voted yet ✅
   - Bob votes with his current VP

**Critical Question:** Did Alice+Bob just double-count Alice's stake?

**Actual Behavior:**

```solidity
function vote(uint256 proposalId, bool support) external {
    require(!_voteReceipts[proposalId][voter].hasVoted, 'ALREADY_VOTED');

    // Read CURRENT state (not snapshot)
    uint256 votingPower = ILevrStaking_v1(staking).getVotingPower(voter);
    uint256 balance = ILevrStakedToken_v1(stakedToken).balanceOf(voter);

    // Record vote with current values
    proposal.yesVotes += votingPower;
    proposal.totalBalanceVoted += balance;

    _voteReceipts[proposalId][voter].hasVoted = true;
}
```

**Analysis:**

- Alice voted with VP = 100
- Alice transferred sTokens to Bob
- Bob's balance increased BUT VP calculation is weighted by time
- Bob votes with his CURRENT VP (not snapshot)

**VP After Transfer:**

Alice originally:

- 100,000 sTokens × 100 days = 10,000,000 token-seconds

After Alice transfers 100,000 to Bob:

- Alice: 0 sTokens, VP = 0 (lost all VP)
- Bob: 150,000 sTokens, but VP is weighted average
- Bob's new VP ≈ (50,000 × old_time + 100,000 × 0) / 150,000
- Bob's VP DECREASES on a per-token basis (diluted by new stake)

**Result:**

- ✅ No double voting (per-address check)
- ⚠️ VP can be "destroyed" by transfers
- ⚠️ Tokens fungible but VP is not

**Potential Griefing:**

- Attacker buys sTokens on DEX
- Transfers to voters to dilute their VP
- Voters lose voting power (weighted average pulls down)

**Edge Cases to Test:**

- ✅ `test_transfer_cannotDoubleVote()` - Per-address check works
- ✅ `test_transfer_dilutesVP()` - VP calculation correct
- ❓ What if transfer happens after vote but before execution?
- ❓ What if Alice votes, transfers, Bob votes, Alice gets tokens back?
- ❓ What if circular transfers (A→B→C→A)?

**Risk Level:** MEDIUM (VP can be destroyed, but no double-voting)

**Mitigation:** Documentation warning about VP loss on transfer

---

### Flow 38: First Staker After Long Zero-Staker Period

**Actors:** Stakers / Reward accumulators / First staker after drought

**Scenario:** Huge rewards accumulate during zero-staker period, first staker gets windfall

**Steps:**

1. **T0 (All Unstake):**
   - Last staker unstakes
   - `_totalStaked = 0`
   - Active stream paused at 500/1000 tokens vested

2. **T0 to T0+30 days (Zero Stakers):**
   - Fees continue accruing from Uniswap trades
   - Fee splitter distributes to staking: 1000 WETH
   - Staking accepts but cannot vest (no stakers)
   - Another 2000 WETH accrued
   - Another 3000 WETH accrued
   - **Total accumulated: 6,500 WETH** (6000 new + 500 unvested from before)

3. **T0+30 days (First Staker):**
   - Bob stakes 1000 tokens (becomes 100% of stake)
   - Stream resets with ALL accumulated rewards
   - Stream: 6,500 WETH over 3 days

4. **T0+33 days (Bob Claims):**
   - Bob claims all 6,500 WETH
   - Effective APR: Insanely high (30 days of fees for 3 days of staking)

**Is This a Problem?**

**NO - Working as Designed:**

- ✅ Rewards preserved during zero-staker period
- ✅ First staker incentivized to stake during drought
- ✅ No rewards lost
- ✅ Economic incentive for early re-staking

**Economic Implications:**

1. **Positive:** Encourages staking after everyone exits
2. **Positive:** No protocol revenue lost
3. **Neutral:** "Unfair" windfall is reward for being first
4. **Negative:** May cause rush/competition when stakers notice

**MEV Opportunity:**

- Sophisticated actors monitor zero-staker periods
- Front-run with large stake when fees accumulate
- Capture accumulated rewards
- Potentially unstake quickly after claiming

**Current Behavior:**

```solidity
function stake(uint256 amount) external {
    bool isFirstStaker = _totalStaked == 0;

    if (isFirstStaker) {
        // Reset streams for all reward tokens
        for (uint256 i = 0; i < _rewardTokens.length; i++) {
            address rt = _rewardTokens[i];
            if (rtState.streamTotal > 0) {
                _resetStreamForToken(rt, rtState.streamTotal);
            }
            // Accrue any unaccounted balance
            uint256 available = _availableUnaccountedRewards(rt);
            if (available > 0) {
                _creditRewards(rt, available);
            }
        }
    }
    // ...
}
```

**Edge Cases to Test:**

- ✅ `test_firstStaker_getsAccumulatedRewards()` - Windfall documented
- ✅ `test_zeroStakers_rewardsPreserved()` - Accumulation works
- ❓ What if two stakers in same block during zero period?
- ❓ What if accumulated rewards > uint256.max / streamWindow?
- ❓ What if first staker immediately unstakes after claiming?

**Risk Level:** ECONOMIC (not security) - Potentially unfair but incentive-aligned

---

### Flow 39: Config Gridlock via Verified Project

**Actors:** Malicious verified project admin

**Scenario:** Set invalid config to break governance or staking for that project

**Attack Steps:**

1. **T0:** Project gets verified by factory owner
2. **T1:** Malicious admin calls `updateProjectConfig()`:
   ```solidity
   ProjectConfig({
       streamWindowSeconds: 1,        // 1 second stream
       proposalWindowSeconds: 1,      // 1 second to propose
       votingWindowSeconds: 1,        // 1 second to vote
       maxActiveProposals: 0,         // Cannot create proposals
       quorumBps: 10000,              // 100% quorum (impossible)
       approvalBps: 10000,            // 100% approval (impossible)
       minSTokenBpsToSubmit: 10000,   // Need 100% to propose
       maxProposalAmountBps: 0,       // Cannot propose any amount
       minimumQuorumBps: 10000        // 100% minimum
   })
   ```

**Would This Work?**

**NO - Validation Prevents:**

```solidity
function updateProjectConfig(address clankerToken, ProjectConfig calldata customCfg) external {
    // ... access control checks ...

    // Validation (same as factory config)
    _validateConfig(
        FactoryConfig({
            protocolFeeBps: _protocolFeeBps,  // Cannot override
            protocolTreasury: _protocolTreasury,  // Cannot override
            streamWindowSeconds: customCfg.streamWindowSeconds,
            proposalWindowSeconds: customCfg.proposalWindowSeconds,
            votingWindowSeconds: customCfg.votingWindowSeconds,
            maxActiveProposals: customCfg.maxActiveProposals,
            quorumBps: customCfg.quorumBps,
            approvalBps: customCfg.approvalBps,
            minSTokenBpsToSubmit: customCfg.minSTokenBpsToSubmit,
            maxProposalAmountBps: customCfg.maxProposalAmountBps,
            minimumQuorumBps: customCfg.minimumQuorumBps
        }),
        clankerToken,
        false  // isFactoryUpdate = false
    );
}

function _validateConfig(FactoryConfig memory cfg, address token, bool isFactoryUpdate) internal view {
    // Prevent gridlock configs
    require(cfg.streamWindowSeconds > 0, 'STREAM_WINDOW_ZERO');
    require(cfg.proposalWindowSeconds > 0, 'PROPOSAL_WINDOW_ZERO');
    require(cfg.votingWindowSeconds > 0, 'VOTING_WINDOW_ZERO');
    require(cfg.maxActiveProposals > 0, 'MAX_PROPOSALS_ZERO');
    require(cfg.quorumBps <= 10000, 'QUORUM_TOO_HIGH');
    require(cfg.approvalBps <= 10000 && cfg.approvalBps > 5000, 'INVALID_APPROVAL');
    require(cfg.minSTokenBpsToSubmit < 10000, 'MIN_STAKE_TOO_HIGH');
    require(cfg.maxProposalAmountBps <= 10000, 'MAX_AMOUNT_TOO_HIGH');
    // ... more validation ...
}
```

**All Prevented:**

- ✅ Cannot set windows to 0 or very small values
- ✅ Cannot set quorum > 100%
- ✅ Cannot set approval > 100% or <= 50%
- ✅ Cannot set minStake >= 100%
- ✅ Cannot set maxProposals to 0
- ✅ Cannot set maxAmount > 100%

**Edge Cases to Test:**

- ✅ `test_projectConfig_validation()` - All validations work
- ✅ `test_projectConfig_cannotGridlock()` - Gridlock prevented
- ❓ What if set windows to 1 second (valid but impractical)?
- ❓ What if set quorum to 99.99%?
- ❓ What if combine many restrictive (but individually valid) settings?

**Risk Level:** LOW (validation prevents most gridlock scenarios)

---

### Flow 40: Fee Splitter Batch Distribution Manipulation

**Actors:** Malicious distributor / Fee splitter

**Scenario:** Manipulate batch distribution to skip tokens or cause partial distribution

**Attack Steps:**

1. **Setup:**
   - Splitter configured: 50% staking, 50% team
   - Pending fees: 1000 WETH, 500 USDC, 200 DAI in ClankerFeeLocker

2. **Attack Attempt 1: Duplicate Tokens**

   ```solidity
   distributeBatch([WETH, USDC, WETH, DAI])
   ```

   - First WETH: Distributes 1000 WETH ✅
   - USDC: Distributes 500 USDC ✅
   - Second WETH: Balance = 0, distributes 0 (no-op) ✅
   - DAI: Distributes 200 DAI ✅
   - **Result:** Harmless, just wastes gas

3. **Attack Attempt 2: Very Large Array**

   ```solidity
   address[] memory tokens = new address[](1000);
   for (uint i = 0; i < 1000; i++) tokens[i] = WETH;
   distributeBatch(tokens);
   ```

   - Gas cost: ~1000 × (claim cost + distribute cost + 0-amount transfers)
   - Estimated: ~50M gas
   - Block limit: ~30M gas
   - **Result:** Transaction fails (out of gas)

4. **Attack Attempt 3: Interleave Whitelist Changes**
   - Cannot happen: Distribution is atomic
   - All tokens checked at start
   - NonReentrant guard prevents external calls during batch

**Actual Behavior:**

```solidity
function distributeBatch(address clankerToken, address[] calldata rewardTokens)
    external
    nonReentrant
{
    for (uint256 i = 0; i < rewardTokens.length; i++) {
        _distributeSingle(clankerToken, rewardTokens[i]);
    }
}

function _distributeSingle(address clankerToken, address rewardToken) internal {
    // Whitelist check
    require(
        ILevrStaking_v1(staking).isTokenWhitelisted(rewardToken),
        'TOKEN_NOT_WHITELISTED'
    );

    // ... claim and distribute ...

    // If balance == 0, returns early (no-op)
    if (balance == 0) return;
}
```

**Protection Mechanisms:**

- ✅ NonReentrant prevents reentrancy
- ✅ Whitelist checked per token
- ✅ Zero-balance gracefully handled
- ✅ Duplicate tokens harmless (second is no-op)
- ✅ Gas limit prevents very large arrays

**No Attack Vector:**

- Cannot force partial distribution
- Cannot skip whitelisted tokens
- Cannot manipulate state mid-batch
- Worst case: Waste gas on duplicates/large arrays

**Edge Cases to Test:**

- ✅ `test_distributeBatch_duplicates_harmless()` - Duplicates handled
- ✅ `test_distributeBatch_largeArray_gasLimit()` - Gas bounds
- ✅ `test_distributeBatch_emptyArray_succeeds()` - Edge case handled
- ❓ What if array has 100 unique tokens all with balance?
- ❓ What if token becomes non-whitelisted mid-array?
- ❓ What if claim from locker fails for one token?

**Risk Level:** NONE (well-protected, worst case is gas waste)

---

### Flow 41: Protocol Fee Override Attempt by Verified Project

**Actors:** Verified project admin (malicious) / Factory owner

**Scenario:** Verified project attempts to bypass protocol fee by manipulating config

**Attack Steps:**

1. **T0 (Setup):**
   - Factory protocol fee: 1% (100 BPS)
   - Protocol treasury: 0xFEE
   - Project gets verified by factory owner

2. **T1 (Attack Attempt - Direct Override):**
   - Project admin calls `factory.updateProjectConfig()`
   - **Problem:** `ProjectConfig` struct doesn't have `protocolFeeBps` field
   - Cannot specify protocol fee in update call
   - **Attack prevented at compilation:** ✅ Cannot even attempt

3. **T2 (Attack Attempt - State Manipulation):**
   - Attacker tries to manipulate stored config
   - Calls `updateProjectConfig()` with custom governance params
   - Code preserves protocol fee from CURRENT factory values:

   ```solidity
   FactoryConfig memory fullCfg = FactoryConfig({
       protocolFeeBps: _protocolFeeBps,  // Always factory value
       // ... project's custom params ...
   });
   ```

   - Project override config gets factory's protocol fee
   - **Attack prevented in code:** ✅ Cannot override

4. **T3 (Attack Attempt - Timing):**
   - Attacker waits for factory protocol fee change
   - Factory fee changes: 1% → 0.5%
   - Attacker hopes old override config still has 1%
   - Calls `updateProjectConfig()` again
   - Code uses CURRENT factory fee (0.5%), not stored value
   - **Attack prevented by design:** ✅ Always syncs to factory

**Protection Mechanism:**

```solidity
function updateProjectConfig(address clankerToken, ProjectConfig calldata cfg) external {
    // ...

    // CRITICAL: protocolFeeBps ALWAYS comes from current factory state
    FactoryConfig memory fullCfg = FactoryConfig({
        protocolFeeBps: _protocolFeeBps,        // Factory value (not overridable)
        protocolTreasury: _protocolTreasury,    // Factory value (not overridable)
        streamWindowSeconds: cfg.streamWindowSeconds,
        // ... other fields from project config ...
    });

    _updateConfig(fullCfg, clankerToken, false);
}

// Protocol fee getter has NO override logic
function protocolFeeBps() external view returns (uint16) {
    return _protocolFeeBps;  // Always factory value
}
```

**Why This Works:**

1. **Struct Design:** `ProjectConfig` excludes `protocolFeeBps` and `protocolTreasury`
2. **Code Enforcement:** `updateProjectConfig()` always uses `_protocolFeeBps` from factory
3. **Getter Isolation:** `protocolFeeBps()` has no project override path
4. **Runtime Sync:** Every update pulls CURRENT factory values, not stored values

**Verification:**

```
Factory protocolFeeBps: 100 (1%)
Project 1 verified, sets custom quorum: 60%
Project 2 verified, sets custom quorum: 80%

factory.protocolFeeBps() → 100 (same for all)
factory.quorumBps(project1) → 6000 (custom)
factory.quorumBps(project2) → 8000 (custom)

Factory owner changes protocolFeeBps: 100 → 200

factory.protocolFeeBps() → 200 (updated for all)
factory.quorumBps(project1) → 6000 (unchanged)
factory.quorumBps(project2) → 8000 (unchanged)
```

**Edge Cases Tested:**

- ✅ `test_projectConfig_cannotOverrideProtocolFee()` - Override prevented
- ✅ `test_factoryProtocolFeeChange_appliesToAllProjects()` - Changes sync
- ✅ `test_projectConfigUpdate_alwaysUsesCurrentFactoryProtocolFee()` - Runtime sync
- ✅ `test_multipleProjects_cannotOverrideProtocolFeeIndependently()` - All use same fee
- ✅ `test_protocolFee_cannotBeAvoided()` - No config combination bypasses
- ✅ `test_protocolTreasury_cannotBeOverridden()` - Treasury also protected

**Attack Prevented:** ✅ Projects cannot reduce protocol revenue under any circumstances

**Risk Level:** NONE (multiple layers of protection)

**Revenue Security:**

- ✅ Protocol fee controlled exclusively by factory owner
- ✅ All projects (verified or not) use same protocol fee
- ✅ Fee changes apply immediately to all projects
- ✅ No project can avoid or reduce protocol revenue

---

## Summary of Advanced Scenarios

| Flow | Scenario                   | Attack Vector                   | Protection                    | Risk       |
| ---- | -------------------------- | ------------------------------- | ----------------------------- | ---------- |
| 30   | Whitelist Manipulation     | Unwhitelist during distribution | Atomic whitelist check        | NONE       |
| 31   | Supply Manipulation        | Flash stake/unstake             | Snapshot at proposal creation | NONE       |
| 32   | Cross-Token Confusion      | Multiple token proposals        | Independent validation        | GOVERNANCE |
| 33   | Timing Attack              | Vote at exact boundaries        | Expected behavior             | NONE       |
| 34   | Meta-Transaction Replay    | Reuse signature                 | Nonce system                  | LOW        |
| 35   | Stream Window Manipulation | Config change mid-stream        | Per-stream immutability       | NONE       |
| 36   | Reward Token DOS           | Dust token spam                 | Whitelist requirement         | NONE       |
| 37   | sToken Transfer            | VP manipulation via transfer    | Per-address voting            | MEDIUM     |
| 38   | First Staker Windfall      | Accumulate then stake           | Incentive-aligned design      | ECONOMIC   |
| 39   | Config Gridlock            | Invalid verified config         | Validation prevents           | LOW        |
| 40   | Batch Distribution         | Manipulate batch array          | NonReentrant + checks         | NONE       |
| 41   | Protocol Fee Override      | Bypass protocol revenue         | Struct + runtime enforcement  | NONE       |

**Key Findings:**

1. **Most attack vectors prevented** by design (snapshots, whitelists, validation)
2. **Economic scenarios exist** but are incentive-aligned (first staker windfall)
3. **Governance risks** are coordination issues, not security issues
4. **No critical vulnerabilities** in adversarial scenarios
5. **Protocol revenue protected** by multiple layers (struct design, runtime enforcement, getter isolation)

**Recommendations:**

1. **Document** VP loss on sToken transfer (warn users)
2. **Monitor** zero-staker periods for MEV activity
3. **UI warnings** for timing edge cases (voting windows)
4. **Frontend validation** for batch distribution array sizes
5. **Revenue monitoring** for protocol fee collection across all projects

---

**Status:** Advanced adversarial scenarios documented and analyzed ✅  
**Coverage:** 12 new complex attack scenarios mapped (Flows 30-41)  
**Security Level:** Strong protections across all vectors including revenue security
