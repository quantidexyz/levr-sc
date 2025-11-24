# LevrGovernor_v1

## Glossary

*   **Cycle**: A recurring period of time (composed of a Proposal Window and a Voting Window) during which proposals are submitted and voted on. Only one proposal can be executed per cycle.
*   **Proposal**: A request to either move funds from the Treasury to the Staking contract (Boost) or to an external address (Transfer).
*   **Voting Power (VP)**: A metric derived from the Staking contract representing a user's influence, calculated as `Amount Staked * Time Staked`.
*   **Quorum**: The minimum amount of "participation" required for a vote to be valid, measured as the total balance of tokens held by voters.
*   **Approval**: The minimum percentage of "Yes" votes (VP) required for a proposal to pass.
*   **Adaptive Quorum**: A mechanism that adjusts the quorum requirement based on the current token supply to prevent governance capture when supply is low.
*   **Cycle Winner**: The single proposal in a cycle that met all thresholds and received the highest approval ratio.

## Overview
`LevrGovernor_v1` manages the decision-making process for a specific project. Unlike standard DAO governance which allows many proposals to pass simultaneously, Levr uses a **Cycle-Based** approach where proposals compete against each other, and only one "winner" executes per cycle. This focuses attention and prevents governance fatigue.

## Architecture
- **Implementation**: `LevrGovernor_v1.sol`
- **Interface**: `ILevrGovernor_v1.sol`
- **Inheritance**: `ERC2771ContextBase`, `ReentrancyGuard`.
- **Dependencies**: 
    - `ILevrStaking_v1`: Source of Voting Power.
    - `ILevrTreasury_v1`: Target for execution commands.
    - `ILevrFactory_v1`: Source of configuration parameters.

## Complex Logic Explained

### 1. Cycle-Based Governance
Standard governance allows multiple proposals to pass at once. Levr forces competition:
1.  **Start**: A cycle starts automatically when a proposal is made (if no cycle is active).
2.  **Proposal Window**: Users submit proposals (e.g., "Send 5% of treasury to Staking").
3.  **Voting Window**: Users vote. Proposals must meet **Quorum** (enough people showed up) and **Approval** (enough people said Yes).
4.  **Selection**: Among proposals that passed both checks, the one with the **highest percentage of Yes votes** is the "Winner".
5.  **Execution**: The Winner is executed. This creates a state change (funds move) and ends the cycle.
6.  **Advancement**: If no proposal wins, or after the winner executes, a new cycle can begin.

### 2. Adaptive Quorum
**Problem**: In the early days of a project, the token supply might be very volatile or low. A fixed quorum might be too hard to hit (locking governance) or too easy (allowing an attacker to drain the treasury).
**Solution**:
- We take a snapshot of the supply when the proposal is created (`snapshotSupply`).
- We check the *current* supply at the time of voting (`currentSupply`).
- The "Effective Supply" used for calculation is the **smaller** of the two.
- **Result**: If supply skyrockets, we stick to the old (lower) target so the vote is still achievable. If supply crashes, we lower the target so we don't get stuck. We also enforce a hard `minimumQuorumBps` to ensure a minimum absolute participation.

### 3. Time-Weighted Voting Power
**Problem**: "Flash loan" attacks where someone borrows millions of tokens for one block, votes, and returns them.
**Solution**:
- Voting Power is not just "how many tokens you have". It is "how many tokens * how long you have held them".
- If you buy tokens and vote immediately, your "time held" is near zero, so your VP is near zero.
- See `LevrStaking_v1` for the calculation details.

### 4. Execution Safety (Anti-Griefing)
**Problem**: A malicious winner could craft a proposal that *reverts* when executed (e.g., sending to a contract that rejects funds). This would permanently jam the governance cycle because the "Winner" must execute before the cycle ends.
**Solution**:
- If execution fails, we record it.
- You cannot try to execute again immediately (must wait `EXECUTION_ATTEMPT_DELAY` = 10 mins).
- If execution fails **3 times**, the contract allows "Manual Cycle Advancement". The proposal is skipped, and a new cycle can begin. This unjams the system.

## API Reference

### State Variables
- `treasury`, `staking`, `stakedToken`, `underlying`: Addresses of project components.
- `currentCycleId`: The ID of the currently active governance cycle.

### Functions

#### Proposing
- `proposeBoost(address token, uint256 amount)`: Propose moving funds from Treasury to Staking (to distribute as rewards).
- `proposeTransfer(address token, address recipient, uint256 amount, string description)`: Propose moving funds to any address (e.g., marketing, development).

#### Voting
- `vote(uint256 proposalId, bool support)`: Cast a vote. Checks:
    - Voting window is open.
    - User hasn't voted yet.
    - User has Voting Power.
    - **Flash Loan Check**: User must have staked *before* the current block.

#### Execution
- `execute(uint256 proposalId)`: Execute the winning proposal.
    - Must be the "Winner" of the current cycle.
    - Voting must have ended.
    - Transfers funds via the Treasury.

#### Cycle Management
- `startNewCycle()`: Manually triggers the start of a new cycle if the previous one is finished/stuck.

## Events
- `ProposalCreated`, `VoteCast`, `ProposalExecuted`, `ProposalDefeated`, `ProposalExecutionFailed`, `CycleStarted`.

## Errors
- `ProposalWindowClosed`: Too late to propose.
- `NotWinner`: This proposal didn't win the cycle.
- `ExecutableProposalsRemaining`: You can't skip the cycle yet; try executing the winner first.
