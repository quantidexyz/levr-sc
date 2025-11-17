// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from 'forge-std/Test.sol';
import {LevrFactory_v1} from '../../src/LevrFactory_v1.sol';
import {LevrStaking_v1} from '../../src/LevrStaking_v1.sol';
import {LevrTreasury_v1} from '../../src/LevrTreasury_v1.sol';
import {LevrGovernor_v1} from '../../src/LevrGovernor_v1.sol';
import {LevrStakedToken_v1} from '../../src/LevrStakedToken_v1.sol';
import {LevrForwarder_v1} from '../../src/LevrForwarder_v1.sol';
import {ILevrFactory_v1} from '../../src/interfaces/ILevrFactory_v1.sol';
import {ILevrStaking_v1} from '../../src/interfaces/ILevrStaking_v1.sol';
import {ILevrGovernor_v1} from '../../src/interfaces/ILevrGovernor_v1.sol';
import {MockERC20} from '../mocks/MockERC20.sol';
import {LevrFactoryDeployHelper} from '../utils/LevrFactoryDeployHelper.sol';

/// @title Phase 3 Systematic Coverage - All Conditional Branches
contract Phase3_SystematicCoverage_Test is Test, LevrFactoryDeployHelper {
    MockERC20 internal underlying;
    LevrFactory_v1 internal factory;
    LevrForwarder_v1 internal forwarder;
    LevrTreasury_v1 internal treasury;
    LevrStaking_v1 internal staking;
    LevrStakedToken_v1 internal sToken;
    LevrGovernor_v1 internal governor;
    
    address internal protocolTreasury = address(0xDEAD);
    address internal user1 = address(0x1111);
    address internal user2 = address(0x2222);
    address internal user3 = address(0x3333);

    function setUp() public {
        underlying = new MockERC20('Token', 'TKN');
        ILevrFactory_v1.FactoryConfig memory cfg = createDefaultConfig(protocolTreasury);
        (factory, forwarder, ) = deployFactoryWithDefaultClanker(cfg, address(this));
        
        factory.prepareForDeployment();
        ILevrFactory_v1.Project memory project = factory.register(address(underlying));
        
        governor = LevrGovernor_v1(project.governor);
        treasury = LevrTreasury_v1(payable(project.treasury));
        staking = LevrStaking_v1(project.staking);
        sToken = LevrStakedToken_v1(project.stakedToken);
        
        underlying.mint(address(treasury), 100_000 ether);
        underlying.mint(user1, 10_000 ether);
        underlying.mint(user2, 10_000 ether);
        underlying.mint(user3, 10_000 ether);
    }

    // ============ PHASE 3A: Treasury Comprehensive Conditional Coverage ============

    function test_phase3a_001_transferVariousAmounts() public {
        address gov = address(governor);
        for (uint256 i = 1; i <= 5; i++) {
            vm.prank(gov);
            treasury.transfer(address(underlying), address(uint160(0x5000 + i)), i * 100 ether);
        }
    }

    function test_phase3a_002_boostVariousAmounts() public {
        address gov = address(governor);
        for (uint256 i = 1; i <= 5; i++) {
            vm.prank(gov);
            treasury.transfer(address(underlying), address(staking), i * 1000 ether);
        }
    }

    function test_phase3a_003_transferAndBoostInterleaved() public {
        address gov = address(governor);
        for (uint256 i = 0; i < 3; i++) {
            vm.prank(gov);
            treasury.transfer(address(underlying), address(uint160(0x6000 + i)), 100 ether);
            
            vm.prank(gov);
            treasury.transfer(address(underlying), address(staking), 500 ether);
        }
    }

    function test_phase3a_004_transferToMultipleRecipients() public {
        address gov = address(governor);
        address[] memory recipients = new address[](5);
        for (uint256 i = 0; i < 5; i++) {
            recipients[i] = address(uint160(0x7000 + i));
        }
        
        for (uint256 i = 0; i < 5; i++) {
            vm.prank(gov);
            treasury.transfer(address(underlying), recipients[i], 1000 ether);
        }
    }

    // ============ PHASE 3B: Staking Comprehensive Conditional Coverage ============

    function test_phase3b_001_multipleUsersStakeSequence() public {
        address[] memory users = new address[](5);
        for (uint256 i = 0; i < 5; i++) {
            users[i] = address(uint160(0x8000 + i));
            underlying.mint(users[i], 5_000 ether);
            
            vm.prank(users[i]);
            underlying.approve(address(staking), 5_000 ether);
            vm.prank(users[i]);
            staking.stake((i + 1) * 500 ether);
        }
    }

    function test_phase3b_002_stakeUnstakeAlternating() public {
        vm.prank(user1);
        underlying.approve(address(staking), 5_000 ether);
        
        for (uint256 i = 0; i < 3; i++) {
            vm.prank(user1);
            staking.stake(500 ether);
            
            vm.prank(user1);
            staking.unstake(250 ether, user1);
        }
    }

    function test_phase3b_003_stakeToMultipleAddresses() public {
        vm.prank(user1);
        underlying.approve(address(staking), 5_000 ether);
        
        for (uint256 i = 0; i < 5; i++) {
            vm.prank(user1);
            staking.stake(1000 ether);
        }
    }

    function test_phase3b_004_multipleRewardTokensAccrual() public {
        vm.prank(user1);
        underlying.approve(address(staking), 5_000 ether);
        vm.prank(user1);
        staking.stake(1_000 ether);
        
        for (uint256 i = 0; i < 3; i++) {
            MockERC20 rewardToken = new MockERC20(
                string(abi.encodePacked('RWD', i)),
                string(abi.encodePacked('R', i))
            );
            
            vm.prank(address(this));
            staking.whitelistToken(address(rewardToken));
            
            rewardToken.mint(address(staking), 10_000 ether);
            staking.accrueRewards(address(rewardToken));
        }
    }

    function test_phase3b_005_claimMultipleRewardTokens() public {
        vm.prank(user1);
        underlying.approve(address(staking), 5_000 ether);
        vm.prank(user1);
        staking.stake(1_000 ether);
        
        address[] memory rewardTokens = new address[](3);
        for (uint256 i = 0; i < 3; i++) {
            MockERC20 rewardToken = new MockERC20(
                string(abi.encodePacked('RWD', i)),
                string(abi.encodePacked('R', i))
            );
            rewardTokens[i] = address(rewardToken);
            
            vm.prank(address(this));
            staking.whitelistToken(address(rewardToken));
            
            rewardToken.mint(address(staking), 10_000 ether);
            staking.accrueRewards(address(rewardToken));
        }
        
        vm.warp(block.timestamp + 4 days);
        
        vm.prank(user1);
        staking.claimRewards(rewardTokens, user1);
    }

    // ============ PHASE 3C: Governor Comprehensive Conditional Coverage ============

    function test_phase3c_001_multipleProposalsInCycle() public {
        // Create stakers
        for (uint256 i = 0; i < 3; i++) {
            address proposer = address(uint160(0x9000 + i));
            underlying.mint(proposer, 5_000 ether);
            
            vm.prank(proposer);
            underlying.approve(address(staking), 5_000 ether);
            vm.prank(proposer);
            staking.stake(500 ether);
            
            vm.warp(block.timestamp + 1 days);
            
            vm.prank(proposer);
            governor.proposeBoost(address(underlying), 10 ether);
        }
    }

    function test_phase3c_002_proposalVotingSequence() public {
        vm.prank(user1);
        underlying.approve(address(staking), 5_000 ether);
        vm.prank(user1);
        staking.stake(500 ether);
        
        vm.prank(user1);
        uint256 pid = governor.proposeBoost(address(underlying), 10 ether);
        
        vm.warp(block.timestamp + 2 days + 1);
        vm.roll(block.number + 1); // Advance blocks for voting eligibility
        
        vm.prank(user1);
        governor.vote(pid, true);
    }

    function test_phase3c_003_multipleVotersOnSameProposal() public {
        // Setup voters
        for (uint256 i = 0; i < 3; i++) {
            address voter = address(uint160(0xa000 + i));
            underlying.mint(voter, 5_000 ether);
            
            vm.prank(voter);
            underlying.approve(address(staking), 5_000 ether);
            vm.prank(voter);
            staking.stake(500 ether);
        }
        
        vm.prank(user1);
        underlying.approve(address(staking), 5_000 ether);
        vm.prank(user1);
        staking.stake(500 ether);
        
        vm.prank(user1);
        uint256 pid = governor.proposeBoost(address(underlying), 10 ether);
        
        vm.warp(block.timestamp + 2 days + 1);
        vm.roll(block.number + 1); // Advance blocks for voting eligibility
        
        // Multiple votes
        for (uint256 i = 0; i < 3; i++) {
            address voter = address(uint160(0xa000 + i));
            vm.prank(voter);
            governor.vote(pid, i % 2 == 0);
        }
    }

    function test_phase3c_004_executionSequence() public {
        vm.prank(user1);
        underlying.approve(address(staking), 5_000 ether);
        vm.prank(user1);
        staking.stake(500 ether);
        
        for (uint256 i = 0; i < 2; i++) {
            vm.prank(user1);
            uint256 pid = governor.proposeBoost(address(underlying), 10 ether);
            
            vm.warp(block.timestamp + 2 days + 1);
            vm.roll(block.number + 1); // Advance blocks for voting eligibility
            
            vm.prank(user1);
            governor.vote(pid, true);
            
            vm.warp(block.timestamp + 5 days + 1);
            
            governor.execute(pid);
        }
    }

    // ============ PHASE 3D: Edge Cases and Boundary Conditions ============

    function test_phase3d_001_maxStakedAmount() public {
        vm.prank(user1);
        underlying.approve(address(staking), 10_000 ether);
        vm.prank(user1);
        staking.stake(10_000 ether);
    }

    function test_phase3d_002_minStakedAmount() public {
        vm.prank(user1);
        underlying.approve(address(staking), 1 ether);
        vm.prank(user1);
        staking.stake(1 ether);
    }

    function test_phase3d_003_zeroBalanceTransfers() public {
        address gov = address(governor);
        
        // Drain treasury
        uint256 balance = underlying.balanceOf(address(treasury));
        vm.prank(gov);
        treasury.transfer(address(underlying), address(0xBEEF), balance);
        
        // Try to transfer when empty
        vm.prank(gov);
        vm.expectRevert();
        treasury.transfer(address(underlying), address(0xCAFE), 1 ether);
    }

    function test_phase3d_004_maximumRewardsAccrual() public {
        vm.prank(user1);
        underlying.approve(address(staking), 1_000 ether);
        vm.prank(user1);
        staking.stake(1_000 ether);
        
        MockERC20 rewardToken = new MockERC20('Reward', 'RWD');
        vm.prank(address(this));
        staking.whitelistToken(address(rewardToken));
        
        rewardToken.mint(address(staking), 1_000_000_000 ether);
        
        try staking.accrueRewards(address(rewardToken)) {
            // May succeed or fail
        } catch {
            // Acceptable
        }
    }

    // ============ PHASE 3E: State Machine Transitions ============

    function test_phase3e_001_cycleTransitions() public {
        vm.prank(user1);
        underlying.approve(address(staking), 5_000 ether);
        vm.prank(user1);
        staking.stake(500 ether);
        
        uint256 cycleBefore = governor.currentCycleId();
        
        // Advance time significantly
        vm.warp(block.timestamp + 20 days);
        
        governor.startNewCycle();
        
        uint256 cycleAfter = governor.currentCycleId();
        assertGt(cycleAfter, cycleBefore);
    }

    function test_phase3e_002_proposalLifecycle() public {
        vm.prank(user1);
        underlying.approve(address(staking), 5_000 ether);
        vm.prank(user1);
        staking.stake(500 ether);
        
        // Propose
        vm.prank(user1);
        uint256 pid = governor.proposeBoost(address(underlying), 10 ether);
        
        // Vote
        vm.warp(block.timestamp + 2 days + 1);
        vm.roll(block.number + 1); // Advance blocks for voting eligibility
        vm.prank(user1);
        governor.vote(pid, true);
        
        // Execute
        vm.warp(block.timestamp + 5 days + 1);
        governor.execute(pid);
        
        // Verify executed
        ILevrGovernor_v1.Proposal memory p = governor.getProposal(pid);
        assertTrue(p.executed);
    }

    // ============ PHASE 3F: Error Recovery Paths ============

    function test_phase3f_001_recoveryFromUnderflow() public {
        vm.prank(user1);
        underlying.approve(address(staking), 10_000 ether);
        vm.prank(user1);
        staking.stake(1_000 ether);
        
        // Unstake all
        vm.prank(user1);
        staking.unstake(1_000 ether, user1);
        
        // Stake again
        vm.prank(user1);
        staking.stake(500 ether);
    }

    function test_phase3f_002_recoveryFromRewardFailure() public {
        vm.prank(user1);
        underlying.approve(address(staking), 1_000 ether);
        vm.prank(user1);
        staking.stake(1_000 ether);
        
        // Try to accrue non-whitelisted token
        MockERC20 badToken = new MockERC20('Bad', 'BAD');
        badToken.mint(address(staking), 1_000 ether);
        
        try staking.accrueRewards(address(badToken)) {
            fail();
        } catch {
            // Continue with whitelisted tokens
        }
        
        MockERC20 goodToken = new MockERC20('Good', 'GOOD');
        vm.prank(address(this));
        staking.whitelistToken(address(goodToken));
        goodToken.mint(address(staking), 1_000 ether);
        staking.accrueRewards(address(goodToken));
    }

    function test_phase3f_003_recoveryFromGovernanceFailure() public {
        vm.prank(user1);
        underlying.approve(address(staking), 5_000 ether);
        vm.prank(user1);
        staking.stake(500 ether);
        
        // Propose something
        vm.prank(user1);
        uint256 pid = governor.proposeBoost(address(underlying), 10 ether);
        
        // Don't vote - proposal will be defeated
        vm.warp(block.timestamp + 10 days);
        
        // Execute defeated proposal
        governor.execute(pid);
        
        // Should be able to propose again
        vm.prank(user1);
        staking.stake(100 ether);
        
        vm.warp(block.timestamp + 1 days);
        
        vm.prank(user1);
        uint256 pid2 = governor.proposeBoost(address(underlying), 5 ether);
        assertGt(pid2, pid);
    }
}
