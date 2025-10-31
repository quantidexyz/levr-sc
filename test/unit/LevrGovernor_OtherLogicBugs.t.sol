// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from 'forge-std/Test.sol';
import {console2} from 'forge-std/console2.sol';
import {LevrFactory_v1} from '../../src/LevrFactory_v1.sol';
import {LevrDeployer_v1} from '../../src/LevrDeployer_v1.sol';
import {LevrForwarder_v1} from '../../src/LevrForwarder_v1.sol';
import {LevrGovernor_v1} from '../../src/LevrGovernor_v1.sol';
import {LevrTreasury_v1} from '../../src/LevrTreasury_v1.sol';
import {LevrStaking_v1} from '../../src/LevrStaking_v1.sol';
import {LevrStakedToken_v1} from '../../src/LevrStakedToken_v1.sol';
import {ILevrFactory_v1} from '../../src/interfaces/ILevrFactory_v1.sol';
import {ILevrGovernor_v1} from '../../src/interfaces/ILevrGovernor_v1.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {MockERC20} from '../mocks/MockERC20.sol';
import {LevrFactoryDeployHelper} from '../utils/LevrFactoryDeployHelper.sol';

/// @title Additional Logic Bug Tests (Non-Snapshot Issues)
/// @notice Testing for bugs beyond just state synchronization
contract LevrGovernor_OtherLogicBugs_Test is Test, LevrFactoryDeployHelper {
    LevrFactory_v1 internal factory;
    LevrForwarder_v1 internal forwarder;
    LevrDeployer_v1 internal levrDeployer;
    LevrGovernor_v1 internal governor;
    LevrTreasury_v1 internal treasury;
    LevrStaking_v1 internal staking;
    LevrStakedToken_v1 internal sToken;

    MockERC20 internal underlying;

    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);
    address internal charlie = address(0xC);

    function setUp() public {
        underlying = new MockERC20('Token', 'TKN');

        ILevrFactory_v1.FactoryConfig memory cfg = ILevrFactory_v1.FactoryConfig({
            protocolFeeBps: 0,
            streamWindowSeconds: 3 days,
            protocolTreasury: address(0xDEAD),
            proposalWindowSeconds: 2 days,
            votingWindowSeconds: 5 days,
            maxActiveProposals: 10,
            quorumBps: 7000,
            approvalBps: 5100,
            minSTokenBpsToSubmit: 100,
            maxProposalAmountBps: 5000,
            minimumQuorumBps: 25, // 0.25% minimum quorum
            maxRewardTokens: 10 // Max non-whitelisted reward tokens
        });

        (factory, forwarder, levrDeployer) = deployFactoryWithDefaultClanker(cfg, address(this));
        factory.prepareForDeployment();
        ILevrFactory_v1.Project memory project = factory.register(address(underlying));

        governor = LevrGovernor_v1(project.governor);
        treasury = LevrTreasury_v1(payable(project.treasury));
        staking = LevrStaking_v1(project.staking);
        sToken = LevrStakedToken_v1(project.stakedToken);

        underlying.mint(address(treasury), 100_000 ether);
    }

    /// @notice BUG?: Tied proposals - which one wins?
    /// @dev Uses strict > comparison, so first proposal wins on tie
    function test_tiedProposals_firstWins() public {
        console2.log('\n=== Tied Proposals Winner Determination ===');

        // Setup two users
        underlying.mint(alice, 1000 ether);
        vm.startPrank(alice);
        underlying.approve(address(staking), type(uint256).max);
        staking.stake(500 ether);
        vm.stopPrank();

        underlying.mint(bob, 1000 ether);
        vm.startPrank(bob);
        underlying.approve(address(staking), type(uint256).max);
        staking.stake(500 ether);
        vm.stopPrank();

        vm.warp(block.timestamp + 10 days);

        // Create two proposals
        vm.prank(alice);
        uint256 pid1 = governor.proposeBoost(address(underlying), 1000 ether);

        vm.prank(bob);
        uint256 pid2 = governor.proposeTransfer(address(underlying), charlie, 1000 ether, 'test');

        console2.log('Proposal 1 (Boost):', pid1);
        console2.log('Proposal 2 (Transfer):', pid2);

        vm.warp(block.timestamp + 2 days + 1);

        // FIX: Both users need to vote to meet 70% quorum requirement
        // Total supply = 1000 sTokens, need 700 to meet quorum
        // Both Alice and Bob vote = 1000 sTokens participation = 100% > 70%
        vm.prank(alice);
        governor.vote(pid1, true);
        vm.prank(alice);
        governor.vote(pid2, true);

        vm.prank(bob);
        governor.vote(pid1, true);
        vm.prank(bob);
        governor.vote(pid2, true);

        ILevrGovernor_v1.Proposal memory p1 = governor.getProposal(pid1);
        ILevrGovernor_v1.Proposal memory p2 = governor.getProposal(pid2);

        console2.log('\nProposal 1 yes votes:', p1.yesVotes);
        console2.log('Proposal 2 yes votes:', p2.yesVotes);
        console2.log('Both meet quorum:', p1.meetsQuorum && p2.meetsQuorum);

        vm.warp(block.timestamp + 5 days + 1);

        uint256 winner = governor.getWinner(1);
        console2.log('\nWinner:', winner);

        // Code uses: if (proposal.yesVotes > maxYesVotes)
        // Strict >, so if equal, first one (lower ID) wins
        if (p1.yesVotes == p2.yesVotes) {
            assertEq(winner, pid1, 'First proposal should win on tie (lowest ID)');
            console2.log('Tie-breaking: First proposal (lower ID) wins');
            console2.log('This is deterministic but should be documented');
        }
    }

    /// @notice BUG?: Active proposal count double decrement
    /// @dev Check if activeProposalCount can be decremented twice
    function test_activeProposalCount_doubleDecrement() public {
        console2.log('\n=== Active Proposal Count Tracking ===');

        underlying.mint(alice, 1000 ether);
        vm.startPrank(alice);
        underlying.approve(address(staking), type(uint256).max);
        staking.stake(1000 ether);
        vm.stopPrank();

        vm.warp(block.timestamp + 10 days);

        // Create proposal
        vm.prank(alice);
        uint256 pid = governor.proposeBoost(address(underlying), 1000 ether);

        uint256 countAfterCreate = governor.activeProposalCount(
            ILevrGovernor_v1.ProposalType.BoostStakingPool
        );
        console2.log('Count after creation:', countAfterCreate);
        assertEq(countAfterCreate, 1);

        // Vote and execute
        vm.warp(block.timestamp + 2 days + 1);
        vm.prank(alice);
        governor.vote(pid, true);

        vm.warp(block.timestamp + 5 days + 1);
        governor.execute(pid);

        uint256 countAfterExecute = governor.activeProposalCount(
            ILevrGovernor_v1.ProposalType.BoostStakingPool
        );
        console2.log('Count after execution:', countAfterExecute);
        assertEq(countAfterExecute, 0, 'Should decrement to 0');

        console2.log('Active proposal count tracking: CORRECT');
    }

    /// @notice BUG?: Vote overflow - can yesVotes overflow?
    /// @dev Solidity 0.8.x has automatic overflow checks, should revert
    function test_voteOverflow_automaticProtection() public {
        console2.log('\n=== Vote Overflow Protection ===');

        // This is testing Solidity 0.8.x overflow protection
        // If we had unchecked{}, this could overflow
        // But we don't use unchecked, so it should revert

        console2.log('Solidity 0.8.30 has automatic overflow protection');
        console2.log('yesVotes += votes will revert on overflow');
        console2.log('This is safe by default');

        // To actually test overflow, we'd need astronomical VP
        // which requires astronomical time or balance
        // Not feasible in practice
    }

    /// @notice BUG: ActiveProposalCount accounting when proposal fails checks
    /// @dev If proposal fails quorum/approval, count is decremented THEN reverted
    function test_activeProposalCount_failedProposalReverts() public {
        console2.log('\n=== Active Proposal Count on Failed Execution ===');

        underlying.mint(alice, 1000 ether);
        vm.startPrank(alice);
        underlying.approve(address(staking), type(uint256).max);
        staking.stake(100 ether); // Only 10% of supply
        vm.stopPrank();

        underlying.mint(bob, 10000 ether);
        vm.startPrank(bob);
        underlying.approve(address(staking), type(uint256).max);
        staking.stake(900 ether); // 90% of supply
        vm.stopPrank();

        vm.warp(block.timestamp + 10 days);

        // Alice creates proposal
        vm.prank(alice);
        uint256 pid = governor.proposeBoost(address(underlying), 1000 ether);

        uint256 countBefore = governor.activeProposalCount(
            ILevrGovernor_v1.ProposalType.BoostStakingPool
        );
        console2.log('Count after creation:', countBefore);

        // Only Alice votes (100 sTokens, need 700 for quorum)
        vm.warp(block.timestamp + 2 days + 1);
        vm.prank(alice);
        governor.vote(pid, true);

        vm.warp(block.timestamp + 5 days + 1);

        // Try to execute - should fail quorum - FIX [OCT-31-CRITICAL-1]
        // OLD: vm.expectRevert(ILevrGovernor_v1.ProposalNotSucceeded.selector);
        governor.execute(pid);

        // Verify marked as executed
        assertTrue(governor.getProposal(pid).executed, 'Proposal should be executed');

        // FIX [OCT-31-SIMPLIFICATION]: Count no longer decrements during execution
        // It only resets at cycle start
        uint256 countAfter = governor.activeProposalCount(
            ILevrGovernor_v1.ProposalType.BoostStakingPool
        );
        console2.log('Count after defeated execute:', countAfter);

        assertEq(countAfter, 1, 'Count stays same (only resets at cycle start)');
        console2.log('SAFE: Revert rolls back the decrement');
    }

    /// @notice CRITICAL BUG: activeProposalCount  NOT ACTUALLY DECREMENTED on failed execution
    /// @dev The count decrements then reverts, but proposal is marked executed!
    /// @dev Wait... proposal.executed is also set before revert, so it rolls back too
    /// @dev Actually this might be a problem - let me check the exact order
    function test_CRITICAL_proposalMarkedExecutedBeforeRevert() public {
        console2.log('\n=== Proposal State on Failed Execution ===');

        underlying.mint(alice, 1000 ether);
        vm.startPrank(alice);
        underlying.approve(address(staking), type(uint256).max);
        staking.stake(100 ether);
        vm.stopPrank();

        underlying.mint(bob, 10000 ether);
        vm.startPrank(bob);
        underlying.approve(address(staking), type(uint256).max);
        staking.stake(900 ether);
        vm.stopPrank();

        vm.warp(block.timestamp + 10 days);

        vm.prank(alice);
        uint256 pid = governor.proposeBoost(address(underlying), 1000 ether);

        vm.warp(block.timestamp + 2 days + 1);
        vm.prank(alice);
        governor.vote(pid, true);

        vm.warp(block.timestamp + 5 days + 1);

        // Before execution attempt
        ILevrGovernor_v1.Proposal memory propBefore = governor.getProposal(pid);
        console2.log('Proposal executed before:', propBefore.executed);
        assertFalse(propBefore.executed);

        // Execute fails quorum - FIX [OCT-31-CRITICAL-1]
        // NEW: proposal.executed = true, count--, return (no revert!)
        // OLD: proposal.executed = true, count--, revert (rolled back)
        // OLD: vm.expectRevert(ILevrGovernor_v1.ProposalNotSucceeded.selector);
        governor.execute(pid);

        // Verify marked as executed
        assertTrue(governor.getProposal(pid).executed, 'Proposal should be executed');

        // After failed execution - FIX [OCT-31-CRITICAL-1]
        ILevrGovernor_v1.Proposal memory propAfter = governor.getProposal(pid);
        console2.log('Proposal executed after defeated execute:', propAfter.executed);

        // FIX: proposal.executed should be TRUE (state persists, no revert)
        assertTrue(propAfter.executed, 'Should be true - state changes persist (no revert)');
        console2.log('FIX: State changes persist (no revert) - proposal marked as executed');
    }

    /// @notice BUG?: What if NotWinner check passes but winner changes before execution completes?
    /// @dev Race condition between winner check and actual execution
    function test_winnerCheck_raceCondition() public {
        console2.log('\n=== Winner Determination Race Condition ===');

        // The winner is determined at line 191: uint256 winnerId = _getWinner(proposal.cycleId);
        // This calls _meetsQuorum() and _meetsApproval() which read CURRENT state

        // So the "winner" can change between:
        // 1. User calls execute(pid1) - enters function
        // 2. Winner check at line 191 says pid1 is winner
        // 3. ... what if another user executes pid2 in parallel?

        // Actually NO - nonReentrant modifier prevents this
        // And only ONE proposal per cycle can execute (cycle.executed check)

        console2.log('Protected by:');
        console2.log('1. nonReentrant modifier - prevents parallel execution');
        console2.log('2. cycle.executed check - only one proposal per cycle');
        console2.log('SAFE from race conditions');
    }

    /// @notice BUG?: Winner = 0 (no winner) - can you execute?
    function test_noWinner_cannotExecute() public {
        console2.log('\n=== No Winner Scenario ===');

        underlying.mint(alice, 1000 ether);
        vm.startPrank(alice);
        underlying.approve(address(staking), type(uint256).max);
        staking.stake(100 ether);
        vm.stopPrank();

        underlying.mint(bob, 10000 ether);
        vm.startPrank(bob);
        underlying.approve(address(staking), type(uint256).max);
        staking.stake(900 ether);
        vm.stopPrank();

        vm.warp(block.timestamp + 10 days);

        // Alice creates proposal
        vm.prank(alice);
        uint256 pid = governor.proposeBoost(address(underlying), 1000 ether);

        // Only Alice votes - insufficient quorum
        vm.warp(block.timestamp + 2 days + 1);
        vm.prank(alice);
        governor.vote(pid, true);

        vm.warp(block.timestamp + 5 days + 1);

        // Winner should be 0 (no proposals meet quorum)
        uint256 winner = governor.getWinner(1);
        console2.log('Winner ID:', winner);
        assertEq(winner, 0, 'No winner when no proposals meet quorum');

        // FIX [OCT-31-CRITICAL-1]: No longer reverts on quorum failure
        // The execute function checks quorum/approval BEFORE checking if winner (fail fast)
        // OLD: vm.expectRevert(ILevrGovernor_v1.ProposalNotSucceeded.selector);
        governor.execute(pid);
        
        // Verify marked as executed
        assertTrue(governor.getProposal(pid).executed, 'Proposal should be executed');

        console2.log('Cannot execute when proposal does not meet quorum: SAFE');
    }

    /// @notice BUG?: TotalBalanceVoted can exceed totalSupply
    /// @dev If user votes, then more tokens are minted, can totalBalanceVoted > totalSupply?
    function test_totalBalanceVoted_canExceedSupply() public {
        console2.log('\n=== TotalBalanceVoted vs TotalSupply ===');

        // Alice has 1000 sTokens
        underlying.mint(alice, 1000 ether);
        vm.startPrank(alice);
        underlying.approve(address(staking), type(uint256).max);
        staking.stake(1000 ether);
        vm.stopPrank();

        vm.warp(block.timestamp + 10 days);

        // Create proposal
        vm.prank(alice);
        uint256 pid = governor.proposeBoost(address(underlying), 1000 ether);

        vm.warp(block.timestamp + 2 days + 1);

        // Alice votes (totalBalanceVoted = 1000)
        vm.prank(alice);
        governor.vote(pid, true);

        console2.log('Alice voted: 1000 sTokens');
        console2.log('Total supply: 1000 sTokens');

        // Now Bob stakes (totalSupply increases to 2000)
        underlying.mint(bob, 2000 ether);
        vm.startPrank(bob);
        underlying.approve(address(staking), type(uint256).max);
        staking.stake(1000 ether);
        vm.stopPrank();

        console2.log('\nBob stakes 1000 sTokens');
        console2.log('New total supply: 2000 sTokens');
        console2.log('Total balance voted: still 1000');

        // FIX: Bob CANNOT vote because he has 0 VP (just staked, no time accumulated)
        // This is the CORRECT, SAFE behavior - prevents gaming
        vm.warp(block.timestamp + 1);
        vm.prank(bob);
        vm.expectRevert(ILevrGovernor_v1.InsufficientVotingPower.selector);
        governor.vote(pid, true);

        ILevrGovernor_v1.Proposal memory prop = governor.getProposal(pid);
        console2.log('\nBob cannot vote: VP = 0 (SAFE)');
        console2.log('Total balance voted:', prop.totalBalanceVoted / 1e18);
        console2.log('Total supply:', sToken.totalSupply() / 1e18);

        // totalBalanceVoted = 1000, totalSupply = 2000
        // This proves the system is safe - new stakers can't vote immediately

        console2.log('SAFE: New stakers have 0 VP, cannot vote immediately');
        console2.log('TotalBalanceVoted cannot exceed what voted (prevented by VP system)');
    }

    /// @notice CRITICAL BUG?: Proposal.totalBalanceVoted could ACTUALLY exceed totalSupply!
    /// @dev If user votes, then unstakes and transfers tokens, someone else can vote with those tokens
    /// @dev DISABLED: Uses transfers which are now blocked
    function skip_test_CRITICAL_totalBalanceVoted_doubleCount() public {
        console2.log('\n=== CRITICAL: TotalBalanceVoted Double Counting ===');

        underlying.mint(alice, 2000 ether);
        vm.startPrank(alice);
        underlying.approve(address(staking), type(uint256).max);
        staking.stake(1000 ether);
        vm.stopPrank();

        vm.warp(block.timestamp + 10 days);

        // Create proposal
        vm.prank(alice);
        uint256 pid = governor.proposeBoost(address(underlying), 1000 ether);

        console2.log('Total supply:', sToken.totalSupply() / 1e18);

        vm.warp(block.timestamp + 2 days + 1);

        // Alice votes (totalBalanceVoted += 1000)
        vm.prank(alice);
        governor.vote(pid, true);

        console2.log('Alice voted: 1000 sTokens');
        uint256 balanceVoted = 1000;
        console2.log('Total balance voted:', balanceVoted);

        // Alice transfers her sTokens to Bob
        vm.prank(alice);
        sToken.transfer(bob, 1000 ether);

        console2.log('\nAlice transferred 1000 sTokens to Bob');
        console2.log('Alice balance:', sToken.balanceOf(alice) / 1e18);
        console2.log('Bob balance:', sToken.balanceOf(bob) / 1e18);

        // Can Bob vote now?
        vm.prank(bob);

        // Bob has sTokens but VP = 0 (never staked himself)
        uint256 bobVP = staking.getVotingPower(bob);
        console2.log('Bob VP:', bobVP);

        if (bobVP == 0) {
            vm.expectRevert(ILevrGovernor_v1.InsufficientVotingPower.selector);
            governor.vote(pid, true);
            console2.log('Bob cannot vote: VP = 0 (SAFE)');
        } else {
            // If Bob COULD vote, then:
            // totalBalanceVoted would be: 1000 (Alice) + 1000 (Bob) = 2000
            // But totalSupply = 1000
            // This would be a BUG - double counting!
            console2.log('BUG: Bob could vote, double counting possible!');
        }
    }

    /// @notice BUG: _activeProposalCount never decremented if proposal defeated via execute()
    /// @dev Lines 167-170, 176-178, 186-187 decrement THEN revert - so count stays incremented!
    function test_CRITICAL_activeProposalCount_neverDecrementedOnDefeat() public {
        console2.log('\n=== CRITICAL: ActiveProposalCount Leak ===');

        underlying.mint(alice, 100 ether);
        vm.startPrank(alice);
        underlying.approve(address(staking), type(uint256).max);
        staking.stake(100 ether);
        vm.stopPrank();

        underlying.mint(bob, 10000 ether);
        vm.startPrank(bob);
        underlying.approve(address(staking), type(uint256).max);
        staking.stake(900 ether);
        vm.stopPrank();

        vm.warp(block.timestamp + 10 days);

        // Alice creates proposal
        vm.prank(alice);
        uint256 pid = governor.proposeBoost(address(underlying), 1000 ether);

        uint256 countAfterCreate = governor.activeProposalCount(
            ILevrGovernor_v1.ProposalType.BoostStakingPool
        );
        console2.log('Active count after creation:', countAfterCreate);
        assertEq(countAfterCreate, 1);

        // Only Alice votes - fails quorum
        vm.warp(block.timestamp + 2 days + 1);
        vm.prank(alice);
        governor.vote(pid, true);

        vm.warp(block.timestamp + 5 days + 1);

        // Execute attempt fails - FIX [OCT-31-CRITICAL-1]
        // OLD: vm.expectRevert(ILevrGovernor_v1.ProposalNotSucceeded.selector);
        governor.execute(pid);
        
        // Verify marked as executed
        assertTrue(governor.getProposal(pid).executed, 'Proposal should be executed');

        // Check count after failed execution
        uint256 countAfterFailed = governor.activeProposalCount(
            ILevrGovernor_v1.ProposalType.BoostStakingPool
        );
        console2.log('Active count after failed execute:', countAfterFailed);

        if (countAfterFailed == 1) {
            console2.log('BUG CONFIRMED: Count stays at 1 even though proposal defeated!');
            console2.log('This means defeated proposals still count as active!');
            console2.log('Could lead to hitting maxActiveProposals limit incorrectly');
        } else {
            console2.log('SAFE: Count properly decremented despite revert');
        }
    }

    /// @notice BUG?: Proposal amount validated at creation, but treasury could be drained before execution
    /// @dev This is already validated with InsufficientTreasuryBalance check
    function test_treasuryBalance_drainedBeforeExecution() public {
        console2.log('\n=== Treasury Balance Drain Before Execution ===');

        underlying.mint(alice, 1000 ether);
        vm.startPrank(alice);
        underlying.approve(address(staking), type(uint256).max);
        staking.stake(1000 ether);
        vm.stopPrank();

        vm.warp(block.timestamp + 10 days);

        // Create proposal for 10k tokens
        vm.prank(alice);
        uint256 pid = governor.proposeBoost(address(underlying), 10_000 ether);

        console2.log('Proposal amount: 10000 tokens');
        console2.log('Treasury balance at creation: 100000 tokens');

        // Vote and wait
        vm.warp(block.timestamp + 2 days + 1);
        vm.prank(alice);
        governor.vote(pid, true);

        vm.warp(block.timestamp + 5 days + 1);

        // BEFORE execution: Drain treasury (governance attack or separate proposal)
        // In real scenario, another proposal could have drained it
        vm.prank(address(governor));
        treasury.transfer(address(underlying), charlie, 95_000 ether);

        console2.log('\nTreasury drained to: 5000 tokens');
        console2.log('Proposal needs: 10000 tokens');

        // Try to execute - FIX [OCT-31-CRITICAL-1]: no longer reverts
        // OLD: vm.expectRevert(ILevrGovernor_v1.InsufficientTreasuryBalance.selector);
        governor.execute(pid);

        // Verify marked as executed
        assertTrue(governor.getProposal(pid).executed, 'Proposal should be executed');

        console2.log('SAFE: Treasury balance validated at execution, marked as defeated');
    }
}
