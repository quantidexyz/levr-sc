# Levr Protocol User Flows - Comprehensive Map

**Date:** October 26, 2025  
**Purpose:** Complete mapping of all user interactions to systematically identify edge cases  
**Status:** Living Document

---

## Table of Contents

1. [Project Registration Flows](#project-registration-flows)
2. [Staking Flows](#staking-flows)
3. [Governance Flows](#governance-flows)
4. [Treasury Flows](#treasury-flows)
5. [Fee Splitter Flows](#fee-splitter-flows)
6. [Forwarder Flows](#forwarder-flows)
7. [Cross-Contract Flows](#cross-contract-flows)

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

- ❓ What if Treasury.initialize() is called twice?
- ❓ What if Staking.initialize() is called twice?
- ❓ What if register() is called twice for same token?
- ❓ What if prepared contracts are used for multiple tokens?
- ❓ What if someone else tries to use prepared contracts?

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
- ❓ What if deployer logic doesn't validate zero addresses properly?

---

## Staking Flows

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
2. ⏭️ For each flow category, create systematic tests
3. ⏭️ Focus on state synchronization (Category A) first
4. ⏭️ Test boundary conditions (Category B)
5. ⏭️ Test ordering dependencies (Category C)
6. ⏭️ Document all findings in audit.md
7. ⏭️ Implement fixes for all CRITICAL bugs
8. ⏭️ Retest after fixes

---

**Methodology:** This document uses a systematic approach to ensure NO edge cases are missed by:

1. Mapping ALL user flows
2. Identifying state changes for each flow
3. Categorizing edge cases by pattern
4. Prioritizing by criticality
5. Testing systematically

This is superior to ad-hoc testing as it ensures comprehensive coverage.
