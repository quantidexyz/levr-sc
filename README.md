# Levr Protocol v1 — Smart Contracts

**Time-weighted governance for token projects.** A modular system that enables projects to deploy treasury, staking, and governance infrastructure with gasless meta-transaction support.

[![Tests](https://img.shields.io/badge/tests-57/57%20passing-brightgreen)](https://github.com/quantidexyz/levr-sc/actions)
[![Security Audit](https://img.shields.io/badge/audit-complete-green)](specs/audit.md)
[![Foundry](https://img.shields.io/badge/built%20with-Foundry-FFDC00)](https://getfoundry.sh/)

## Overview

Levr Protocol v1 provides token projects with:

- **⏰ Time-Weighted Governance**: Voting power = staked balance × time staked (rewards long-term commitment)
- **🏦 Treasury Management**: Governor-controlled fund management with boost-to-staking capabilities
- **🔄 Meta-Transaction Support**: Gasless interactions via ERC2771 forwarder
- **📊 Modular Architecture**: Factory deploys per-project contracts (treasury, staking, governor, stakedToken)

**✨ All contracts support gasless transactions** - Users can stake, vote, and claim rewards without holding ETH.

## Architecture

```
LevrFactory_v1 (uses pre-deployed ERC2771Forwarder)
  ↓ prepareForDeployment() → (treasury, staking)
  ↓ register(clankerToken) → Project{treasury, governor, staking, stakedToken}
    ├─ Treasury: Holds project funds, controlled by governor
    ├─ Governor: Time-weighted governance with cycle-based proposals
    ├─ Staking: Escrows tokens, tracks time for VP, manages rewards
    └─ StakedToken: 1:1 receipt token, governance weight source

All contracts extend ERC2771ContextBase → support meta-transactions
```

## Contracts

### Core Contracts

| Contract               | Purpose                           | Key Features                                                          |
| ---------------------- | --------------------------------- | --------------------------------------------------------------------- |
| **LevrFactory_v1**     | Registry & deployment coordinator | Project registration, config management, meta-tx support              |
| **LevrStaking_v1**     | Token escrow with time tracking   | Multi-token rewards, time-weighted VP, proportional unstake reduction |
| **LevrGovernor_v1**    | Governance with cycle management  | Proposal types, VP-weighted voting, winner selection                  |
| **LevrTreasury_v1**    | Asset custody                     | Governor-controlled transfers, boost-to-staking                       |
| **LevrStakedToken_v1** | 1:1 staked representation         | ERC20 receipt token for governance participation                      |
| **LevrForwarder_v1**   | Meta-transaction relay            | ERC2771 forwarder with multicall support                              |

### Base Contracts

- **ERC2771ContextBase**: Eliminates code duplication for meta-transaction support across all user-facing contracts

## Key Features

### ⏰ Time-Weighted Governance

- **Voting Power**: VP = staked balance × time staked (seconds)
- **Anti-Gaming**: Proportional VP reduction on partial unstake prevents manipulation
- **Dual Thresholds**: Quorum (balance participation) + Approval (VP voting)
- **Cycle Management**: Manual governance cycles with proposal/voting windows

### 🏦 Treasury Operations

- **Proposal Types**: Boost staking rewards or transfer to recipient
- **Governor Control**: All treasury actions require governance approval
- **Boost Mechanism**: Treasury can boost staking rewards for community incentives

### 🔄 Meta-Transactions

- **Gasless Interactions**: Users can stake/vote/claim without ETH
- **Multicall Support**: Execute multiple operations in one transaction
- **Forwarder Architecture**: Shared forwarder across all projects

### 📊 Reward System

- **Manual Accrual**: Explicit `accrueRewards()` calls prevent unexpected behavior
- **Multi-Token**: Support for multiple reward token types
- **Streaming**: Linear reward vesting over configurable windows
- **Clanker Integration**: Automatic claiming from ClankerFeeLocker

## Quick Start

### Prerequisites

- [Foundry](https://getfoundry.sh/) - Ethereum development toolkit
- Node.js (for testing utilities)

### Installation

```bash
# Install dependencies
forge install

# Build contracts
forge build

# Run tests (57 tests, all passing)
forge test -vvv
```

### Local Development

```bash
# Start local node
anvil

# Deploy to local network
forge script script/DeployLevrFactoryDevnet.s.sol --chain-id 31337 --broadcast
```

## Deployment Flow

### Complete Workflow

```solidity
// 1. Deploy forwarder FIRST
LevrForwarder_v1 forwarder = new LevrForwarder_v1("LevrForwarder_v1");

// 2. Define guardrails for governance overrides
ILevrFactory_v1.ConfigBounds memory bounds = ILevrFactory_v1.ConfigBounds({
    minStreamWindowSeconds: 1 days,
    minProposalWindowSeconds: 6 hours,
    minVotingWindowSeconds: 2 days,
    minQuorumBps: 2000,
    minApprovalBps: 5000,
    minMinSTokenBpsToSubmit: 100,
    minMinimumQuorumBps: 25
});

// 3. Deploy factory with forwarder, deployer logic, and whitelist
LevrFactory_v1 factory = new LevrFactory_v1(
    config,
    bounds,
    owner,
    address(forwarder),
    address(levrDeployer),
    initialWhitelist
);

// 4. Prepare (get addresses before Clanker exists)
(address treasury, address staking) = factory.prepareForDeployment();

// 5. Deploy Clanker token (use treasury/staking addresses)

// 6. Register (as tokenAdmin)
ILevrFactory_v1.Project memory project = factory.register(clankerToken);
```

## Governance Cycle

```
1. Factory owner starts cycle → governor.startNewCycle()
   ├─ Proposal window: Users propose (requires min staked balance)
   └─ Voting window: Users vote with time-weighted VP

2. Users stake → Accumulate VP (balance × time staked)

3. Proposal window (2 days default)
   ├─ proposeBoost(amount) → Treasury → Staking reward pool
   └─ proposeTransfer(recipient, amount, description) → Treasury → Recipient

4. Voting window (5 days default)
   ├─ Vote yes/no with VP weight
   ├─ Must meet quorum (% of total supply voted)
   └─ Must meet approval (% yes votes of total VP cast)

5. Execution (anyone can call)
   ├─ Select winner: Highest VP yes votes among eligible proposals
   └─ Execute ONE proposal per cycle
```

## Configuration

### Factory Config

```solidity
struct FactoryConfig {
  uint16 protocolFeeBps;           // Protocol fee (basis points)
  uint32 streamWindowSeconds;      // Reward streaming window (≥1 day)
  address protocolTreasury;        // Protocol treasury address
  // Governance parameters
  uint32 proposalWindowSeconds;    // Proposal submission duration
  uint32 votingWindowSeconds;      // Voting window duration
  uint16 maxActiveProposals;       // Max concurrent proposals per type
  uint16 quorumBps;                // Min participation threshold (7000 = 70%)
  uint16 approvalBps;              // Min approval threshold (5100 = 51%)
  uint16 minSTokenBpsToSubmit;     // Min % of supply to propose (100 = 1%)
  uint16 maxProposalAmountBps;     // Max treasury spend per proposal
  uint16 minimumQuorumBps;         // Minimum quorum floor (adaptive safety)
}
```

### Defaults (Recommended)

- `proposalWindowSeconds`: 2 days
- `votingWindowSeconds`: 5 days
- `maxActiveProposals`: 7 per type
- `quorumBps`: 7000 (70%)
- `approvalBps`: 5100 (51%)
- `minSTokenBpsToSubmit`: 100 (1%)
- `streamWindowSeconds`: 3 days

## Testing

### Test Coverage

- **310+ total tests** (100% pass rate) - Unit, E2E, edge cases, and integration
- **Unit Tests** (125+ tests): Individual contract security and functionality
- **E2E Tests** (50+ tests): Full protocol flows and integration
- **Edge Case Tests** (85+ tests): Boundary conditions and attack scenarios
- **Industry Comparison Tests** (50+ tests): Validation against known vulnerabilities

### Run Tests

```bash
# All tests
forge test

# Verbose output with gas tracking
forge test -vvv --gas-report

# Specific test file
forge test --match-path test/e2e/LevrV1.Governance.t.sol

# Run with fork for integration tests
forge test --fork-url $RPC_URL
```

### Test Structure

```
test/
├── e2e/
│   ├── LevrV1.Governance.t.sol      # Governance E2E tests
│   ├── LevrV1.Staking.t.sol         # Staking E2E tests
│   ├── LevrV1.Registration.t.sol    # Registration tests
│   └── LevrV1.StuckFundsRecovery.t.sol # Recovery scenarios
└── unit/
    ├── LevrFactory*.t.sol            # Factory unit tests
    ├── LevrStaking*.t.sol            # Staking unit tests (40+ tests)
    ├── LevrGovernor*.t.sol           # Governor tests (66+ tests)
    ├── LevrTreasury*.t.sol           # Treasury tests
    ├── LevrStakedToken*.t.sol        # Staked token tests
    ├── LevrFeeSplitter*.t.sol        # Fee splitter tests (74 tests)
    └── Levr*.t.sol                   # Integration & edge cases
```

## Security

### Audit Status

✅ **All critical, high, and medium severity issues resolved**

- **2 Critical** issues fixed (state cleanup, initialization protection)
- **3 High** severity issues fixed (reentrancy, governance simplification, approval management)
- **5 Medium** severity issues resolved (streaming, cycle recovery, design clarifications)

**Audit Report**: [specs/audit.md](specs/audit.md)

### Key Protections

- **Reentrancy Guards**: All external functions protected
- **Access Control**: Factory-only initialization, governor-controlled treasury
- **Anti-Gaming**: Time-weighted VP with proportional unstake reduction
- **Input Validation**: Comprehensive zero-address and bounds checking
- **Meta-Transaction Security**: Signature verification and nonce management

### Invariants

- StakedToken supply == total underlying staked
- Reward reserves >= pending claims
- One project per clankerToken
- Prepared contracts only usable by deployer

## Gas Costs (Approximate)

- **Factory Deployment**: ~2.8M gas
- **Project Registration**: ~4.2M gas
- **Stake Operation**: ~180K gas
- **Vote Operation**: ~95K gas
- **Claim Rewards**: ~85K gas (multi-token)

## Usage Examples

### Gasless Staking

```solidity
// Users sign meta-transactions, relayers execute
LevrForwarder_v1 forwarder = LevrForwarder_v1(factory.trustedForwarder());

// Gasless stake request
ERC2771Forwarder.ForwardRequestData memory request = ERC2771Forwarder.ForwardRequestData({
  from: user,
  to: address(staking),
  value: 0,
  gas: 300000,
  deadline: uint48(block.timestamp + 1 hours),
  data: abi.encodeWithSelector(LevrStaking_v1.stake.selector, amount),
  signature: userSignature
});

// Relayer executes (pays gas)
forwarder.execute(request);
```

### Multicall Operations

```solidity
// Execute multiple operations in ONE transaction
ILevrForwarder_v1.SingleCall[] memory calls = new ILevrForwarder_v1.SingleCall[](2);

// Stake tokens
calls[0] = ILevrForwarder_v1.SingleCall({
  target: address(staking),
  allowFailure: false,
  callData: abi.encodeWithSelector(LevrStaking_v1.stake.selector, amount)
});

// Vote on proposal
calls[1] = ILevrForwarder_v1.SingleCall({
  target: address(governor),
  allowFailure: false,
  callData: abi.encodeWithSelector(LevrGovernor_v1.vote.selector, proposalId, true)
});

// Execute as user (multicall extracts user from msg.sender)
forwarder.executeMulticall(calls);
```

### Governance Participation

```solidity
// 1. Stake tokens (accumulate VP over time)
staking.stake(amount);

// 2. Propose treasury action (if eligible)
governor.proposeBoost(boostAmount);

// 3. Vote with time-weighted VP
governor.vote(proposalId, true); // VP = balance × time staked

// 4. Execute winning proposal (anyone can call)
governor.execute(proposalId);
```

## Documentation

- **Protocol Guide**: [spec/GOV.md](spec/GOV.md) - Complete governance mechanics
- **Security Audit**: [spec/AUDIT.md](spec/AUDIT.md) - Full security assessment & findings
- **Audit Status**: [spec/AUDIT_STATUS.md](spec/AUDIT_STATUS.md) - Current audit progress
- **API Reference**: Inline NatSpec documentation in all contracts
- **Historical Fixes**: [spec/HISTORICAL_FIXES.md](spec/HISTORICAL_FIXES.md) - Past bugs and lessons learned
- **Detailed Reports**: [spec/archive/audits/](spec/archive/audits/) - Complete audit technical reports

## Contributing

### Development Workflow

1. **Fork** the repository
2. **Create** a feature branch
3. **Write tests** for new functionality
4. **Implement** changes with comprehensive error handling
5. **Run full test suite** (`forge test -vvv`)
6. **Submit** pull request with detailed description

### Code Standards

- **Security First**: All external functions use reentrancy guards
- **Meta-Transaction Support**: Use `_msgSender()` instead of `msg.sender`
- **Custom Errors**: Prefer custom errors over require strings for gas efficiency
- **Comprehensive Testing**: Every feature must have corresponding tests
- **Documentation**: All functions include NatSpec comments

## License

MIT

---

**Built with ❤️ for the Web3 community** | **Time-weighted governance for fair, committed participation**
