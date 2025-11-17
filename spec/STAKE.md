# Staking Protocol Reference

**Version:** v1.0  
**Updated:** November 3, 2025  
**Status:** Production Ready  
**Contracts:** `LevrStaking_v1`, `LevrStakedToken_v1`

---

## Overview

The Levr staking protocol enables token holders to stake project tokens and earn multi-token rewards via a **pool-based reward distribution system**. Users receive `LevrStakedToken_v1` (1:1 receipt token) representing their stake, which generates **time-weighted governance voting power** and accumulates a **proportional share of all accrued rewards**.

**Key Design Principles:**

- ✅ **Single underlying token** - each staking pool represents one project's tokens
- ✅ **Multi-token rewards** - support unlimited reward tokens (ERC-20 compatible)
- ✅ **Pool-based distribution** - proportional sharing based on stake percentage
- ✅ **Linear vesting** - rewards stream linearly over configurable windows per token
- ✅ **Non-transferable stakes** - staked tokens (sTokens) represent non-transferable positions
- ✅ **Whitelist-protected** - reward tokens must be whitelisted to prevent spam/DoS

---

## Architecture

### Core Components

```
LevrStaking_v1 (Main)
├── Stake/Unstake Logic
│   ├── Escrow (underlying balance tracking)
│   └── VP Calculation (time-weighted voting power)
│
├── Multi-Token Reward System
│   ├── Pool-Based Distribution
│   ├── Linear Streaming Vesting
│   └── Whitelist Management
│
└── Treasury Integration
    ├── Accrue from Treasury
    └── Reward Distribution
```

### Supporting Contracts

| Contract               | Purpose                                                       |
| ---------------------- | ------------------------------------------------------------- |
| **LevrStakedToken_v1** | ERC-20 receipt token (non-transferable) - voting power source |
| **LevrFactory_v1**     | Global config, reward token whitelist, streaming parameters   |
| **LevrTreasury_v1**    | Holds project funds; treasury can push rewards to staking     |
| **RewardMath**         | Pure math library for vesting and proportional calculations   |

---

## Core Mechanics

### 1. Staking

**Action:** User deposits underlying tokens → receives sToken 1:1

```solidity
function stake(uint256 amount) external
```

**What Happens:**

1. **Settle all reward pools** - accrue all pending rewards first
2. **Handle first staker** - restart paused streams if staking resumes
3. **Measure actual receipt** - accounts for fee-on-transfer tokens
4. **Update voting power** - weighted timestamp preserves existing VP
5. **Mint sToken** - 1:1 ratio to underlying amount
6. **Escrow update** - track underlying in escrow

**Voting Power Calculation (First Stake):**

```
If stakeStartTime = 0:
  stakeStartTime = block.timestamp
```

**Voting Power Calculation (Top-up):**

```
newStartTime = (existingBalance × existingStartTime + newAmount × now) / (existingBalance + newAmount)
Result: Weighted average preserves accumulated VP
```

**Why Weighted Average:**

- First stake at T=0, gets 100 days of VP
- Top-up at T=50 with same amount → should keep ~75 days VP
- Weighted calculation preserves this perfectly

---

### 2. Unstaking

**Action:** User burns sToken and receives underlying

```solidity
function unstake(uint256 amount, address to)
  external returns (uint256 newVotingPower)
```

**What Happens:**

1. **Auto-claim all rewards** - prevents accidental reward loss
2. **Burn sToken** - reduce user's balance
3. **Update escrow** - reduce underlying reserve
4. **Transfer underlying** - send to recipient address
5. **Reduce voting power** - proportional reduction for partial unstake
6. **Return new VP** - useful for UI/predictions

**Voting Power on Partial Unstake:**

```
If unstaking 50% of 100 units after 100 days:
  Remaining: 50 units, ~50 days accumulated
  newStartTime adjusted to reflect remaining VP
```

**Auto-Claim Safety:**

Why auto-claim on unstake?

- ✅ Prevents accidental reward loss when unstaking
- ✅ User gets final rewards automatically
- ✅ Reduces confusion about claiming separately

---

### 3. Reward Distribution

The reward system uses **pool-based proportional distribution**:

```
User's Reward Share = (userBalance / totalStaked) × availablePool
```

**Key Properties:**

- ✅ **Mathematically perfect** - sum of all claims exactly equals pool
- ✅ **Simple and efficient** - O(1) calculation per user
- ✅ **No individual tracking** - no per-user reward accounting
- ✅ **Snapshot at claim** - rewards reflect current pool state

---

### 4. Multi-Token Rewards

**State Per Reward Token:**

```solidity
struct RewardTokenState {
  uint256 availablePool;      // Current claimable rewards
  uint256 streamTotal;        // Total amount vesting
  uint64 lastUpdate;          // Last vesting settlement
  uint64 streamStart;         // Stream start time (per-token)
  uint64 streamEnd;           // Stream end time (per-token)
  bool exists;                // Token registered
  bool whitelisted;           // Token whitelisted
}
```

**Flow:**

1. **Accrue** - rewards transferred into staking contract
2. **Credit to Pool** - convert unaccounted rewards into streaming
3. **Vest** - rewards linearly stream over window
4. **Claim** - user claims proportional share

---

### 5. Linear Vesting

**Streaming Window (Per Token):**

Configured per underlying token via factory:

```
streamWindowSeconds = 7 days (604800 seconds) - default
Can be overridden by verified projects
```

**Vesting Formula:**

```
vested = (streamTotal × (currentTime - streamStart)) / (streamEnd - streamStart)
```

**Example Timeline:**

```
T=0:    Rewards added, streamStart=0, streamEnd=7d, streamTotal=700
T=3.5d: Vested = 700 × 0.5 = 350 (in pool, claimable)
T=7d:   Vested = 700 × 1.0 = 700 (all in pool, stream complete)
T=8d:   Stream ended, rate = 0 (no new vesting)
```

**Sliding Window (CRITICAL-3 Fix):**

Each reward token has its own start/end window to prevent global stream collision attacks:

```
Underlying:   [start=0,   end=7d]
Reward Token: [start=0.5s, end=7.5d]  ← Isolated window
```

---

## Key Features

### Multi-Token Reward Support

**Whitelist System:**

Only whitelisted tokens can be reward tokens:

```solidity
function whitelistToken(address token) external
function unwhitelistToken(address token) external
```

**Who Can Whitelist:**

- `underlying` token - **ALWAYS whitelisted** (special case)
- Other tokens - **Token admin only** (via `IClankerToken.admin()`)

**Whitelist Rules:**

| Action                           | Allowed | Reason                         |
| -------------------------------- | ------- | ------------------------------ |
| Whitelist new token              | Yes     | Add new reward token           |
| Whitelist existing token         | No      | Would duplicate                |
| Whitelist with pending rewards   | No      | Prevents state corruption      |
| Unwhitelist underlying           | No      | Revenue protection             |
| Unwhitelist with pending rewards | No      | Would make rewards unclaimable |
| Remove finished token            | Yes     | Cleanup after zero rewards     |

**Reward Token Protection:**

```solidity
// Underlying token ALWAYS whitelisted (in escrow)
_tokenState[underlying].whitelisted = true  // PERMANENT

// Other tokens require active whitelist
// Cannot unwhitelist if rewards pending
require(availablePool == 0 && streamTotal == 0, "Pending Rewards")
```

---

### Voting Power (Time-Weighted)

**Purpose:** Governance voting power based on stake duration

**Formula:**

```
VP = (stakeBalance × timeStaked) / (PRECISION × SECONDS_PER_DAY)
where:
  stakeBalance = user's sToken balance
  timeStaked = block.timestamp - stakeStartTime
  PRECISION = 1e18
  SECONDS_PER_DAY = 86400
```

**Examples:**

```
100 tokens staked for 1 day   = (100 × 86400) / (1e18 × 86400) = 100 VP
100 tokens staked for 10 days = (100 × 864000) / (1e18 × 86400) = 1000 VP
50 tokens staked for 20 days  = (50 × 1728000) / (1e18 × 86400) = 1000 VP
```

**Key Properties:**

- ✅ Longer stakes have more voting power
- ✅ Top-ups preserve accumulated VP
- ✅ Unstakes proportionally reduce VP
- ✅ VP grows every block (time-continuous)

---

### Escrow Tracking

**Purpose:** Separate user principal from rewards

**Per-Token Escrow:**

```
escrowBalance[token] = totalUnderlyingDepositedByAllUsers
```

**Usage:**

- ✅ Track how much underlying is reserved
- ✅ Validate unstake doesn't exceed escrow
- ✅ Separate from reward pools
- ✅ Ensure sufficient liquidity for unstakes

**Invariant:**

```
escrowBalance[underlying] <= IERC20(underlying).balanceOf(staking)
(escrow + pools <= contract balance)
```

---

### Treasury Integration

**Reward Accrual from Treasury:**

```solidity
function accrueFromTreasury(
  address token,
  uint256 amount,
  bool pullFromTreasury
) external
```

**Two Modes:**

1. **Pull Mode** (pullFromTreasury = true)
   - Treasury calls this function
   - Transfers tokens from treasury → staking
   - Auto-detects actual amount received (for fee-on-transfer)
   - Credits difference to pool

2. **Push Mode** (pullFromTreasury = false)
   - External caller triggers accrual
   - Requires tokens already in staking contract
   - Caller specifies amount to credit
   - Treasury doesn't need to be called

---

## Advanced Topics

### Proportional Reward Claims

**Problem:** How to distribute rewards fairly when new stakes arrive?

**Solution (Pool-Based):**

```
User Claim = (userStakedBalance / totalStakedBalance) × currentAvailablePool
```

**Why This Works:**

- ✅ **Snapshot property** - each user gets proportional share at claim time
- ✅ **Perfect accounting** - sum of all claims exactly equals pool (no rounding loss)
- ✅ **No double-claiming** - once claimed, reward leaves pool
- ✅ **Fair to all** - early/late stakers claim proportional to stake size

**Example:**

```
Pool = 1000 tokens
User A: 500 stake (50%)  → claims 500
User B: 500 stake (50%)  → claims 500
Total claims = 1000 ✓ (perfect)

After User B unstakes:
Pool = 500 tokens (User A's claim pending)
User A: 1000 stake (100%) → claims 500 (100% of remaining pool)
```

---

### Fee-on-Transfer Token Handling

**Problem:** Some ERC-20 tokens charge a fee on transfer

**Solution:** Measure actual received amount

```solidity
uint256 balanceBefore = IERC20(underlying).balanceOf(address(this));
IERC20(underlying).safeTransferFrom(staker, address(this), amount);
uint256 actualReceived = IERC20(underlying).balanceOf(address(this)) - balanceBefore;

// Use actualReceived instead of amount
_escrowBalance[underlying] += actualReceived;
_totalStaked += actualReceived;
ILevrStakedToken_v1(stakedToken).mint(staker, actualReceived);
```

**Applies to:**

- ✅ Stake transfers (to contract)
- ✅ Reward accruals (from treasury)
- ✅ Any `safeTransferFrom` into staking

---

### Stream Resetting

**When Streams Reset:**

1. **First staker after pause** - new rewards need new stream window
2. **New rewards arrive** - schedule vesting period

**Reset Logic:**

```solidity
function _resetStreamForToken(address token, uint256 amount) internal {
  streamStart = block.timestamp
  streamEnd = block.timestamp + streamWindowSeconds
  streamTotal = amount
  lastUpdate = streamStart
  availablePool = 0  // Will vest over window
}
```

**Why Restart on First Stake:**

- If no stakers, rewards shouldn't vest (no one to claim)
- When first user stakes, resume vesting from that point
- Prevents waste of vesting time when paused

---

### Access Control

| Function             | Caller                  | Protection                      |
| -------------------- | ----------------------- | ------------------------------- |
| `stake`              | Any                     | None (public)                   |
| `unstake`            | User (owner of sToken)  | Checks sToken balance           |
| `claimRewards`       | Any (on behalf of user) | Checks reward amount            |
| `accrueRewards`      | Any                     | None (anyone can trigger)       |
| `accrueFromTreasury` | Treasury or external    | `pullFromTreasury` mode matters |
| `whitelistToken`     | Token admin             | `IClankerToken.admin()`         |
| `unwhitelistToken`   | Token admin             | `IClankerToken.admin()`         |
| `initialize`         | Factory only            | Checks `msg.sender == factory`  |

---

## State Variables & Storage

### User-Level State

```solidity
mapping(address => uint256) stakeStartTime
  ↓ Time when user first staked (for VP calculation)

mapping(address => uint256) _escrowBalance[underlying]
  ↓ User's underlying tokens escrowed (via sToken balance)
```

### Global State

```solidity
uint256 _totalStaked
  ↓ Total sToken supply (represents total underlying locked)

address[] _rewardTokens
  ↓ Array of all registered reward tokens

mapping(address => RewardTokenState) _tokenState
  ↓ Per-token state (pools, streams, whitelist)
```

### Immutable Addresses

```solidity
address underlying       ← Project token being staked
address stakedToken     ← sToken receipt contract
address treasury        ← Treasury (reward source)
address factory         ← Factory (config source)
```

---

## Common Operations

### Staking Flow (User)

```
1. User calls: underlying.approve(staking, amount)
2. User calls: staking.stake(amount)
3. Events: Staked(user, amount)
4. Result: User has sToken balance, VP, reward share
```

### Claiming Rewards Flow

```
1. User calls: staking.claimRewards([token1, token2], recipientAddress)
2. For each token:
   - Settle pool (vest pending rewards)
   - Calculate: claim = (userBalance / totalStaked) × availablePool
   - Transfer reward token to recipient
   - Emit: RewardsClaimed(user, recipient, token, claim)
```

### Adding New Reward Token

```
Admin Flow:
1. Token admin calls: staking.whitelistToken(newToken)
   - Validates: no pending rewards
   - Sets: whitelisted = true
   - Event: TokenWhitelisted(newToken)

2. Treasury/SDK sends rewards:
   - Reward tokens transferred to staking
   - staking.accrueRewards(newToken) called
   - Vesting stream created

3. Users claim automatically
```

---

## Constants

| Constant            | Value           | Purpose                              |
| ------------------- | --------------- | ------------------------------------ |
| `PRECISION`         | 1e18            | Scale for VP calculations            |
| `SECONDS_PER_DAY`   | 86400           | Day conversion                       |
| `BASIS_POINTS`      | 10000           | Basis point scale (100% = 10000 BPS) |
| `MIN_REWARD_AMOUNT` | 1e15 (0.000001) | Prevent reward token slot DoS        |

---

## Error Conditions

| Error                                   | Cause                             | Solution                      |
| --------------------------------------- | --------------------------------- | ----------------------------- |
| `ZeroAddress()`                         | Invalid address passed            | Use valid contract address    |
| `InvalidAmount()`                       | Amount is 0                       | Use non-zero amount           |
| `InsufficientStake()`                   | Balance < unstake amount          | Unstake less or stake more    |
| `InsufficientEscrow()`                  | Escrow < unstake amount           | Wait for escrow replenishment |
| `AlreadyInitialized()`                  | Initialize called twice           | Initialize once only          |
| `OnlyFactory()`                         | Non-factory caller                | Use factory to initialize     |
| `CannotModifyUnderlying()`              | Attempted to modify underlying    | Underlying is protected       |
| `OnlyTokenAdmin()`                      | Non-admin tried to whitelist      | Token admin must call         |
| `AlreadyWhitelisted()`                  | Token already whitelisted         | Remove first to re-add        |
| `CannotWhitelistWithPendingRewards()`   | Whitelist has pending rewards     | Settle rewards first          |
| `CannotUnwhitelistUnderlying()`         | Tried to unwhitelist underlying   | Underlying is permanent       |
| `TokenNotRegistered()`                  | Token not in system               | Add token first               |
| `NotWhitelisted()`                      | Token not whitelisted             | Whitelist token first         |
| `CannotUnwhitelistWithPendingRewards()` | Pending rewards exist             | Settle rewards first          |
| `CannotRemoveUnderlying()`              | Tried to remove underlying        | Underlying cannot be removed  |
| `CannotRemoveWhitelisted()`             | Tried to remove whitelisted token | Unwhitelist first             |
| `RewardsStillPending()`                 | Pending rewards exist             | Settle all rewards first      |
| `RewardTooSmall()`                      | < MIN_REWARD_AMOUNT               | Use larger reward amount      |
| `TokenNotWhitelisted()`                 | Token not whitelisted for rewards | Whitelist token first         |
| `InsufficientAvailable()`               | Not enough rewards available      | Add more rewards first        |

---

## Events

```solidity
event Staked(address indexed staker, uint256 amount)
  ↓ Emitted when user stakes

event Unstaked(address indexed staker, address indexed to, uint256 amount)
  ↓ Emitted when user unstakes and receives underlying

event RewardsAccrued(address indexed token, uint256 amount, uint256 newPoolTotal)
  ↓ Emitted when rewards added to pool

event StreamReset(
  address indexed token,
  uint32 windowSeconds,
  uint64 streamStart,
  uint64 streamEnd
)
  ↓ Emitted when streaming window resets

event RewardsClaimed(
  address indexed account,
  address indexed to,
  address indexed token,
  uint256 amount
)
  ↓ Emitted when rewards claimed

event TokenWhitelisted(address indexed token)
  ↓ Emitted when token whitelisted

event TokenUnwhitelisted(address indexed token)
  ↓ Emitted when token unwhitelisted

event RewardTokenRemoved(address indexed token)
  ↓ Emitted when finished token cleaned up

event Initialized(
  address indexed underlying,
  address indexed stakedToken,
  address indexed treasury
)
  ↓ Emitted once when the factory initializes the staking module
```

---

## Integration Checklist

### For Projects Using Levr Staking

- [ ] Deploy LevrStaking_v1 via factory
- [ ] Initialize with underlying token, sToken, treasury
- [ ] Whitelist reward tokens (e.g., WETH)
- [ ] Transfer initial rewards to staking contract
- [ ] Call `accrueRewards` to start streaming
- [ ] Users can now stake and claim rewards

### For SDK Implementations

- [ ] Monitor `Staked` events for new stakes
- [ ] Track `RewardsClaimed` events for reward claims
- [ ] Poll `claimableRewards()` for pending rewards display
- [ ] Display `getWhitelistedTokens()` for available rewards
- [ ] Track `stakeStartTime` for VP calculation in UI
- [ ] Handle `accrueRewards` calls after treasury deposits

### For Treasury Management

- [ ] Deposit reward tokens to staking contract
- [ ] Call `accrueFromTreasury` with pullFromTreasury=true
- [ ] Monitor `RewardsAccrued` events for confirmation
- [ ] Adjust streaming window via factory if needed
- [ ] Verify escrow balance doesn't exceed total supply

---

## Examples

### Example 1: User Stakes and Earns

```
Day 0:
  User stakes 1000 ABC tokens
  → Receives 1000 sABC (1:1)
  → stakeStartTime = 0
  → VP = 0 (no time passed yet)

Day 7:
  VP = (1000 × 604800) / (1e18 × 86400) = 1000 VP
  → User can vote with 1000 voting power

Day 7 (Rewards Vest):
  Treasury deposited 700 WETH for 7-day stream
  → All 700 WETH now vested into pool
  → User owns 100% of pool (only staker)
  → User's reward = 700 WETH

User claims:
  → Receives 700 WETH
  → Pool now empty
```

### Example 2: Multiple Stakers

```
Day 0:
  User A stakes 500 ABC
  User B stakes 500 ABC
  Total staked = 1000 ABC

Day 7:
  Rewards vest: 700 WETH into pool
  Pool state: availablePool = 700 WETH

User A claims:
  Share = (500 / 1000) × 700 = 350 WETH

User B claims:
  Share = (500 / 1000) × 700 = 350 WETH

Total claimed = 350 + 350 = 700 ✓ (perfect)
```

### Example 3: Partial Unstake Preserves VP

```
Day 0:
  User stakes 100 ABC
  → stakeStartTime = 0

Day 5:
  User has VP = 500
  User unstakes 50 ABC
  → Still has 50 ABC stake
  → Remaining VP ≈ 250 (proportional)
  → Receives 50 ABC back
  → Auto-claims rewards
```

---

## FAQ

**Q: Why are staked tokens non-transferable?**

A: Transfers would break voting power accounting and reward proportionality. Each user's VP is tied to their stake history. Transfers would orphan this history.

**Q: Can I have multiple stakes?**

A: Yes. Each address can have multiple stakes tracked via their sToken balance. VP calculation uses total balance and time-weighted timestamp.

**Q: What if I stake multiple times?**

A: The first stake sets `stakeStartTime`. Additional stakes use weighted average to preserve accumulated VP.

**Q: When do rewards vest?**

A: Linearly over the streaming window (default 7 days). They're added to the pool continuously as they vest.

**Q: Can I claim rewards before staking?**

A: No. You need a sToken balance to be eligible for rewards.

**Q: What happens if I unstake with pending rewards?**

A: They're automatically claimed and sent to you along with your underlying tokens.

**Q: Can tokens be removed from the reward list?**

A: Only if all rewards are claimed (zero pending). Then `cleanupFinishedRewardToken` can remove it.

**Q: Is there a minimum stake?**

A: No explicit minimum, but rewards vest to the pool. If total staked is zero, streams pause.

---

## See Also

- **[GOV.md](GOV.md)** - Governance proposal and voting system
- **[FEE_SPLITTER.md](FEE_SPLITTER.md)** - Fee distribution to projects
- **[MULTISIG.md](MULTISIG.md)** - Gnosis Safe multisig security
- **[USER_FLOWS.md](USER_FLOWS.md)** - Complete user interaction flows
- **[AUDIT.md](AUDIT.md)** - Security audit findings

---

**Document Status:** ✅ Production Ready  
**Last Updated:** November 3, 2025  
**Maintainer:** Levr V1 Protocol Team
