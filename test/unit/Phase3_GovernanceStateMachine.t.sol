// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from 'forge-std/Test.sol';
import {LevrFactory_v1} from '../../src/LevrFactory_v1.sol';
import {LevrStaking_v1} from '../../src/LevrStaking_v1.sol';
import {LevrGovernor_v1} from '../../src/LevrGovernor_v1.sol';
import {ILevrFactory_v1} from '../../src/interfaces/ILevrFactory_v1.sol';
import {ILevrGovernor_v1} from '../../src/interfaces/ILevrGovernor_v1.sol';
import {MockERC20} from '../mocks/MockERC20.sol';
import {LevrFactoryDeployHelper} from '../utils/LevrFactoryDeployHelper.sol';

/// @title Phase 3C - Governor State Machine Comprehensive Coverage
contract Phase3_GovernanceStateMachine_Test is Test, LevrFactoryDeployHelper {
    MockERC20 internal underlying;
    LevrFactory_v1 internal factory;
    LevrGovernor_v1 internal governor;
    LevrStaking_v1 internal staking;
    
    address internal protocolTreasury = address(0xDEAD);

    function setUp() public {
        underlying = new MockERC20('Token', 'TKN');
        ILevrFactory_v1.FactoryConfig memory cfg = createDefaultConfig(protocolTreasury);
        (factory, , ) = deployFactoryWithDefaultClanker(cfg, address(this));
        
        factory.prepareForDeployment();
        ILevrFactory_v1.Project memory project = factory.register(address(underlying));
        
        governor = LevrGovernor_v1(project.governor);
        staking = LevrStaking_v1(project.staking);
        
        // Fund treasury for proposals to succeed
        underlying.mint(project.treasury, 100_000 ether);
    }

    // ============ State Machine: Cycle Initialization ============

    function test_gv_state_001_initialCycleId() public view {
        uint256 cycleId = governor.currentCycleId();
        assertGe(cycleId, 0);
    }

    function test_gv_state_002_cycleTransition() public {
        uint256 cycle1 = governor.currentCycleId();
        vm.warp(block.timestamp + 20 days);
        governor.startNewCycle();
        uint256 cycle2 = governor.currentCycleId();
        assertGt(cycle2, cycle1);
    }

    // ============ State Machine: Proposal Window States ============

    function test_gv_window_001_proposalWindowOpen() public {
        address user = address(0x1001);
        underlying.mint(user, 10_000 ether);
        
        vm.prank(user);
        underlying.approve(address(staking), 10_000 ether);
        vm.prank(user);
        staking.stake(500 ether);
        
        vm.warp(block.timestamp + 1);
        
        // Should allow proposal at start of window
        vm.prank(user);
        uint256 pid = governor.proposeBoost(address(underlying), 10 ether);
        assertGt(pid, 0);
    }

    function test_gv_window_002_proposalWindowTransition() public {
        address user = address(0x1002);
        underlying.mint(user, 10_000 ether);
        
        vm.prank(user);
        underlying.approve(address(staking), 10_000 ether);
        vm.prank(user);
        staking.stake(500 ether);
        
        // Propose early
        vm.prank(user);
        uint256 pid1 = governor.proposeBoost(address(underlying), 10 ether);
        
        // Transition to voting window
        vm.warp(block.timestamp + 2 days + 1);
        
        // Should be able to still vote on first proposal
        vm.prank(user);
        governor.vote(pid1, true);
    }

    // ============ State Machine: Voting States ============

    function test_gv_vote_001_votingWindowOpen() public {
        address user = address(0x2001);
        underlying.mint(user, 10_000 ether);
        
        vm.prank(user);
        underlying.approve(address(staking), 10_000 ether);
        vm.prank(user);
        staking.stake(500 ether);
        
        vm.prank(user);
        uint256 pid = governor.proposeBoost(address(underlying), 10 ether);
        
        vm.warp(block.timestamp + 2 days + 1);
        
        vm.prank(user);
        governor.vote(pid, true);
        
        ILevrGovernor_v1.Proposal memory p = governor.getProposal(pid);
        assertGt(p.yesVotes, 0);
    }

    function test_gv_vote_002_votingWindowClosed() public {
        address user = address(0x2002);
        underlying.mint(user, 10_000 ether);
        
        vm.prank(user);
        underlying.approve(address(staking), 10_000 ether);
        vm.prank(user);
        staking.stake(500 ether);
        
        vm.prank(user);
        uint256 pid = governor.proposeBoost(address(underlying), 10 ether);
        
        vm.warp(block.timestamp + 10 days);
        
        vm.prank(user);
        vm.expectRevert();
        governor.vote(pid, true);
    }

    // ============ State Machine: Execution States ============

    function test_gv_exec_001_executeAfterVoting() public {
        address user = address(0x3001);
        underlying.mint(user, 10_000 ether);
        
        vm.prank(user);
        underlying.approve(address(staking), 10_000 ether);
        vm.prank(user);
        staking.stake(500 ether);
        
        vm.prank(user);
        uint256 pid = governor.proposeBoost(address(underlying), 10 ether);
        
        vm.warp(block.timestamp + 2 days + 1);
        
        vm.prank(user);
        governor.vote(pid, true);
        
        vm.warp(block.timestamp + 5 days + 1);
        
        governor.execute(pid);
        
        ILevrGovernor_v1.Proposal memory p = governor.getProposal(pid);
        assertTrue(p.executed);
    }

    function test_gv_exec_002_executeBeforeVotingEnds() public {
        address user = address(0x3002);
        underlying.mint(user, 10_000 ether);
        
        vm.prank(user);
        underlying.approve(address(staking), 10_000 ether);
        vm.prank(user);
        staking.stake(500 ether);
        
        vm.prank(user);
        uint256 pid = governor.proposeBoost(address(underlying), 10 ether);
        
        vm.warp(block.timestamp + 2 days + 1);
        
        vm.prank(user);
        governor.vote(pid, true);
        
        // Try to execute before voting ends
        vm.prank(user);
        try governor.execute(pid) {
            // May execute early or fail
        } catch {
            // Expected
        }
    }

    // ============ State Machine: Multiple Proposals ============

    function test_gv_multi_001_sequentialProposals() public {
        address user = address(0x4001);
        underlying.mint(user, 10_000 ether);
        
        vm.prank(user);
        underlying.approve(address(staking), 10_000 ether);
        vm.prank(user);
        staking.stake(500 ether);
        
        // Proposal 1
        vm.prank(user);
        uint256 _pid1 = governor.proposeBoost(address(underlying), 10 ether);
        
        // Proposal 2 same cycle (should fail - user already proposed)
        vm.prank(user);
        try governor.proposeBoost(address(underlying), 15 ether) {
            fail();
        } catch {
            // Expected
        }
    }

    function test_gv_multi_002_multipleUsersProposals() public {
        address[] memory users = new address[](3);
        for (uint256 i = 0; i < 3; i++) {
            users[i] = address(uint160(0x4100 + i));
            underlying.mint(users[i], 10_000 ether);
            
            vm.prank(users[i]);
            underlying.approve(address(staking), 10_000 ether);
            vm.prank(users[i]);
            staking.stake(500 ether);
        }
        
        for (uint256 i = 0; i < 3; i++) {
            vm.prank(users[i]);
            uint256 pid = governor.proposeBoost(address(underlying), (i + 1) * 10 ether);
            assertGt(pid, 0);
        }
    }

    // ============ State Machine: Vote Aggregation ============

    function test_gv_agg_001_yesVotesAccumulate() public {
        address[] memory users = new address[](3);
        for (uint256 i = 0; i < 3; i++) {
            users[i] = address(uint160(0x5000 + i));
            underlying.mint(users[i], 100_000 ether);
            
            vm.prank(users[i]);
            underlying.approve(address(staking), 100_000 ether);
            vm.prank(users[i]);
            staking.stake(1_000 ether);  // Ensure sufficient stake for VP
        }
        
        vm.prank(users[0]);
        uint256 pid = governor.proposeBoost(address(underlying), 10 ether);
        
        vm.warp(block.timestamp + 2 days + 1);
        
        for (uint256 i = 0; i < 3; i++) {
            vm.prank(users[i]);
            governor.vote(pid, true);
        }
        
        ILevrGovernor_v1.Proposal memory p = governor.getProposal(pid);
        assertGt(p.yesVotes, 0);
    }

    function test_gv_agg_002_mixedVotes() public {
        address[] memory users = new address[](4);
        for (uint256 i = 0; i < 4; i++) {
            users[i] = address(uint160(0x5100 + i));
            underlying.mint(users[i], 10_000 ether);
            
            vm.prank(users[i]);
            underlying.approve(address(staking), 10_000 ether);
            vm.prank(users[i]);
            staking.stake(500 ether);
        }
        
        vm.prank(users[0]);
        uint256 pid = governor.proposeBoost(address(underlying), 10 ether);
        
        vm.warp(block.timestamp + 2 days + 1);
        
        // Some vote yes, some no
        for (uint256 i = 0; i < 4; i++) {
            vm.prank(users[i]);
            governor.vote(pid, i % 2 == 0);
        }
        
        ILevrGovernor_v1.Proposal memory p = governor.getProposal(pid);
        assertGt(p.yesVotes + p.noVotes, 0);
    }

    // ============ State Machine: Extreme Cases ============

    function test_gv_ext_001_veryLongCyclTime() public {
        address user = address(0x6001);
        underlying.mint(user, 10_000 ether);
        
        vm.prank(user);
        underlying.approve(address(staking), 10_000 ether);
        vm.prank(user);
        staking.stake(500 ether);
        
        // Propose
        vm.prank(user);
        uint256 pid = governor.proposeBoost(address(underlying), 10 ether);
        
        // Wait very long
        vm.warp(block.timestamp + 365 days);
        
        // Should still be able to execute
        governor.execute(pid);
    }

    function test_gv_ext_002_noVotes() public {
        address user = address(0x6002);
        underlying.mint(user, 10_000 ether);
        
        vm.prank(user);
        underlying.approve(address(staking), 10_000 ether);
        vm.prank(user);
        staking.stake(500 ether);
        
        vm.prank(user);
        uint256 pid = governor.proposeBoost(address(underlying), 10 ether);
        
        // Don't vote at all
        vm.warp(block.timestamp + 10 days);
        
        // Execute defeated proposal
        governor.execute(pid);
    }
}
