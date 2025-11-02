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

/// @title Critical Logic Bug Tests for Governor
/// @notice Tests for subtle logic bugs similar to the staking midstream accrual issue
/// @dev Focus on "obvious in hindsight" edge cases around state synchronization
contract LevrGovernor_CriticalLogicBugs_Test is Test, LevrFactoryDeployHelper {
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
    address internal protocolTreasury = address(0xDEAD);

    function setUp() public {
        underlying = new MockERC20('Token', 'TKN');

        ILevrFactory_v1.FactoryConfig memory cfg = ILevrFactory_v1.FactoryConfig({
            protocolFeeBps: 0,
            streamWindowSeconds: 3 days,
            protocolTreasury: protocolTreasury,
            proposalWindowSeconds: 2 days,
            votingWindowSeconds: 5 days,
            maxActiveProposals: 10,
            quorumBps: 7000, // 70%
            approvalBps: 5100, // 51%
            minSTokenBpsToSubmit: 100, // 1%
            maxProposalAmountBps: 5000, // 50%
            minimumQuorumBps: 25 // 0.25% minimum quorum
        });

        (factory, forwarder, levrDeployer) = deployFactoryWithDefaultClanker(cfg, address(this));

        factory.prepareForDeployment();
        ILevrFactory_v1.Project memory project = factory.register(address(underlying));

        governor = LevrGovernor_v1(project.governor);
        treasury = LevrTreasury_v1(payable(project.treasury));
        staking = LevrStaking_v1(project.staking);
        sToken = LevrStakedToken_v1(project.stakedToken);

        // Fund treasury
        underlying.mint(address(treasury), 100_000 ether);
    }

    /// @notice CRITICAL BUG: Quorum can be manipulated by staking after voting
    /// @dev Total supply is checked at EXECUTION time, not at vote snapshot time
    function test_CRITICAL_quorumManipulation_viaSupplyIncrease() public {
        console2.log('\n=== CRITICAL: Quorum Manipulation via Supply Increase ===');

        // Setup: Alice and Bob stake
        underlying.mint(alice, 1000 ether);
        vm.startPrank(alice);
        underlying.approve(address(staking), type(uint256).max);
        staking.stake(500 ether);
        vm.stopPrank();

        underlying.mint(bob, 1000 ether);
        vm.startPrank(bob);
        underlying.approve(address(staking), type(uint256).max);
        staking.stake(300 ether);
        vm.stopPrank();

        // Total supply = 800 sTokens
        // Quorum requirement = 70% of 800 = 560 sTokens
        console2.log('Initial total supply:', sToken.totalSupply() / 1e18);
        console2.log('Quorum requirement (70%):', ((sToken.totalSupply() * 7000) / 10000) / 1e18);

        // Wait for VP to accumulate
        vm.warp(block.timestamp + 10 days);

        // Alice creates proposal
        vm.prank(alice);
        uint256 pid = governor.proposeBoost(address(underlying), 1000 ether);

        // Advance to voting
        vm.warp(block.timestamp + 2 days + 1);

        // Alice and Bob vote (800 sTokens total)
        vm.prank(alice);
        governor.vote(pid, true);

        vm.prank(bob);
        governor.vote(pid, true);

        console2.log('Votes cast: 800 sTokens');
        console2.log('Quorum met at voting time: 800 >= 560');

        // Proposal should meet quorum now
        ILevrGovernor_v1.Proposal memory proposal = governor.getProposal(pid);
        assertTrue(proposal.meetsQuorum, 'Should meet quorum after voting');

        // ATTACK: Charlie stakes 1000 more tokens AFTER voting ends
        vm.warp(block.timestamp + 5 days + 1); // Past voting window

        underlying.mint(charlie, 2000 ether);
        vm.startPrank(charlie);
        underlying.approve(address(staking), type(uint256).max);
        staking.stake(1000 ether);
        vm.stopPrank();

        // Total supply now = 1800 sTokens
        // New quorum requirement = 70% of 1800 = 1260 sTokens
        console2.log('\nAfter Charlie stakes:');
        console2.log('New total supply:', sToken.totalSupply() / 1e18);
        console2.log(
            'New quorum requirement (70%):',
            ((sToken.totalSupply() * 7000) / 10000) / 1e18
        );
        console2.log('Actual votes: 800 sTokens');

        // Check if proposal still meets quorum
        proposal = governor.getProposal(pid);

        if (!proposal.meetsQuorum) {
            console2.log('\nBUG CONFIRMED: Proposal no longer meets quorum!');
            console2.log('800 votes < 1260 required (44.4% < 70%)');
            console2.log('Proposal was executable, now is not!');

            // Try to execute - FIX [OCT-31-CRITICAL-1]: no longer reverts
            // OLD: vm.expectRevert(ILevrGovernor_v1.ProposalNotSucceeded.selector);
            governor.execute(pid);
            
            // Verify marked as executed
            assertTrue(governor.getProposal(pid).executed, 'Proposal should be executed');

            console2.log('CRITICAL: Supply manipulation can block proposal execution!');
        } else {
            console2.log(
                '\nNo bug: Quorum still met (this means the implementation is safer than expected)'
            );
        }
    }

    /// @notice Test: Can quorum be manipulated by unstaking to lower requirements?
    function test_quorumManipulation_viaSupplyDecrease() public {
        console2.log('\n=== Quorum Manipulation via Supply Decrease ===');

        // Setup: Multiple stakers
        underlying.mint(alice, 1000 ether);
        vm.startPrank(alice);
        underlying.approve(address(staking), type(uint256).max);
        staking.stake(300 ether);
        vm.stopPrank();

        underlying.mint(bob, 1000 ether);
        vm.startPrank(bob);
        underlying.approve(address(staking), type(uint256).max);
        staking.stake(200 ether);
        vm.stopPrank();

        underlying.mint(charlie, 2000 ether);
        vm.startPrank(charlie);
        underlying.approve(address(staking), type(uint256).max);
        staking.stake(1000 ether);
        vm.stopPrank();

        // Total supply = 1500 sTokens
        // Quorum = 70% = 1050 sTokens
        console2.log('Initial total supply:', sToken.totalSupply() / 1e18);

        vm.warp(block.timestamp + 10 days);

        // Alice creates proposal
        vm.prank(alice);
        uint256 pid = governor.proposeBoost(address(underlying), 1000 ether);

        vm.warp(block.timestamp + 2 days + 1);

        // Only Alice and Bob vote (500 sTokens) - NOT enough for quorum (need 1050)
        vm.prank(alice);
        governor.vote(pid, true);

        vm.prank(bob);
        governor.vote(pid, true);

        console2.log('Votes cast: 500 sTokens');
        console2.log('Quorum required: 1050 sTokens');
        console2.log('Quorum met: false (500 < 1050)');

        // Wait for voting to end
        vm.warp(block.timestamp + 5 days + 1);

        // Check quorum - should NOT meet
        ILevrGovernor_v1.Proposal memory proposal = governor.getProposal(pid);
        assertFalse(proposal.meetsQuorum, 'Should NOT meet quorum');

        // MANIPULATION: Charlie unstakes to lower total supply
        vm.prank(charlie);
        staking.unstake(900 ether, charlie);

        // Total supply now = 600 sTokens
        // New quorum = 70% of 600 = 420 sTokens
        console2.log('\nAfter Charlie unstakes:');
        console2.log('New total supply:', sToken.totalSupply() / 1e18);
        console2.log('New quorum requirement:', ((sToken.totalSupply() * 7000) / 10000) / 1e18);

        // Check if proposal now meets quorum
        proposal = governor.getProposal(pid);

        if (proposal.meetsQuorum) {
            console2.log('\nBUG CONFIRMED: Proposal NOW meets quorum!');
            console2.log('500 votes >= 420 required (83% >= 70%)');
            console2.log('Charlie can manipulate quorum by unstaking!');

            // This is actually beneficial manipulation (helps proposal pass)
            // But it's still a logic bug that supply changes affect quorum
        } else {
            console2.log('\nNo bug: Quorum calculation is snapshot-based');
        }
    }

    /// @notice Test: Can winner determination be manipulated by config changes?
    function test_winnerDetermination_configManipulation() public {
        console2.log('\n=== Winner Determination via Config Changes ===');

        // Setup stakers
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
        uint256 pid2 = governor.proposeTransfer(
            address(underlying),
            charlie,
            500 ether,
            'transfer'
        );

        vm.warp(block.timestamp + 2 days + 1);

        // Proposal 1: 60% yes, 40% no
        vm.prank(alice);
        governor.vote(pid1, true); // 500 yes

        vm.startPrank(bob);
        underlying.mint(bob, 500 ether);
        underlying.approve(address(staking), type(uint256).max);
        staking.stake(333 ether); // Bob increases stake
        vm.warp(block.timestamp + 1); // Small time for VP
        governor.vote(pid1, false); // ~333 no
        vm.stopPrank();

        // Proposal 2: 100% yes
        // (only Alice votes)
        vm.prank(alice);
        governor.vote(pid2, true); // 500 yes

        console2.log('Proposal 1 votes: ~60% yes');
        console2.log('Proposal 2 votes: 100% yes');
        console2.log('Current approval threshold: 51%');

        vm.warp(block.timestamp + 5 days + 1);

        // Both should meet approval at 51% threshold
        console2.log('\nWinner before config change:', governor.getWinner(1));

        // Factory owner changes approval requirement to 70%
        ILevrFactory_v1.FactoryConfig memory newCfg = ILevrFactory_v1.FactoryConfig({
            protocolFeeBps: 0,
            streamWindowSeconds: 3 days,
            protocolTreasury: protocolTreasury,
            proposalWindowSeconds: 2 days,
            votingWindowSeconds: 5 days,
            maxActiveProposals: 10,
            quorumBps: 7000,
            approvalBps: 7000, // Changed from 5100 to 7000 (70%)
            minSTokenBpsToSubmit: 100,
            maxProposalAmountBps: 5000,
            minimumQuorumBps: 25 // 0.25% minimum quorum
        });

        factory.updateConfig(newCfg);

        console2.log('\nConfig updated: approval threshold now 70%');
        console2.log('Proposal 1: 60% yes < 70% - NO LONGER MEETS APPROVAL');
        console2.log('Proposal 2: 100% yes >= 70% - STILL MEETS APPROVAL');

        // Winner should change!
        uint256 newWinner = governor.getWinner(1);
        console2.log('Winner after config change:', newWinner);

        if (newWinner != pid1) {
            console2.log('\nBUG CONFIRMED: Config change affected winner determination!');
            console2.log('Proposal 1 was leading, but config change made it invalid');
        }
    }

    /// @notice Test: Precision loss in voting power calculation
    function test_votingPower_precisionLoss() public {
        console2.log('\n=== Voting Power Precision Loss ===');

        // Stake very small amount
        underlying.mint(alice, 100 ether);
        vm.startPrank(alice);
        underlying.approve(address(staking), type(uint256).max);
        staking.stake(1 wei); // Minimum stake
        vm.stopPrank();

        console2.log('Alice staked: 1 wei');

        // Wait various time periods
        uint256[] memory timePeriods = new uint256[](5);
        timePeriods[0] = 1; // 1 second
        timePeriods[1] = 1 hours;
        timePeriods[2] = 1 days;
        timePeriods[3] = 7 days;
        timePeriods[4] = 365 days;

        for (uint256 i = 0; i < timePeriods.length; i++) {
            vm.warp(block.timestamp + timePeriods[i]);
            uint256 vp = staking.getVotingPower(alice);
            console2.log('After', timePeriods[i], 'seconds, VP:', vp);
        }

        // VP = (balance * timeStaked) / (1e18 * 86400)
        // For 1 wei: (1 * time) / (1e18 * 86400)
        // This will be 0 for any time < 1e18 * 86400 seconds (way longer than universe age)
        console2.log('\nPrecision loss: 1 wei stake has 0 VP even after 1 year');
    }
}
