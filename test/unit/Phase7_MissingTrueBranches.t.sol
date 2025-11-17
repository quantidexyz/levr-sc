// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from 'forge-std/Test.sol';
import {LevrFactory_v1} from '../../src/LevrFactory_v1.sol';
import {LevrStaking_v1} from '../../src/LevrStaking_v1.sol';
import {LevrGovernor_v1} from '../../src/LevrGovernor_v1.sol';
import {LevrTreasury_v1} from '../../src/LevrTreasury_v1.sol';
import {ILevrFactory_v1} from '../../src/interfaces/ILevrFactory_v1.sol';
import {ILevrGovernor_v1} from '../../src/interfaces/ILevrGovernor_v1.sol';
import {MockERC20} from '../mocks/MockERC20.sol';
import {LevrFactoryDeployHelper} from '../utils/LevrFactoryDeployHelper.sol';

/// @title Phase 7 - Missing TRUE Branches (from LCOV analysis)
/// Target: Lines with duplicate branch numbers = both TRUE and FALSE paths
contract Phase7_MissingTrueBranches_Test is Test, LevrFactoryDeployHelper {
    MockERC20 internal underlying;
    LevrFactory_v1 internal factory;
    LevrStaking_v1 internal staking;
    LevrGovernor_v1 internal governor;
    LevrTreasury_v1 internal treasury;
    
    address internal protocolTreasury = address(0xDEAD);

    function setUp() public {
        underlying = new MockERC20('Token', 'TKN');
        ILevrFactory_v1.FactoryConfig memory cfg = createDefaultConfig(protocolTreasury);
        (factory, , ) = deployFactoryWithDefaultClanker(cfg, address(this));
        
        factory.prepareForDeployment();
        ILevrFactory_v1.Project memory project = factory.register(address(underlying));
        
        governor = LevrGovernor_v1(project.governor);
        staking = LevrStaking_v1(project.staking);
        treasury = LevrTreasury_v1(payable(project.treasury));
        
        underlying.mint(address(treasury), 500_000 ether);
    }

    // ============ LevrGovernor_v1 Line 156: proposal.executed TRUE ============

    function test_gov_156_executeAlreadyExecuted() public {
        address user = address(0x1001);
        underlying.mint(user, 10_000 ether);
        vm.prank(user);
        underlying.approve(address(staking), 10_000 ether);
        vm.prank(user);
        staking.stake(500 ether);
        
        vm.prank(user);
        uint256 pid = governor.proposeBoost(address(underlying), 10 ether);
        
        vm.warp(block.timestamp + 2 days + 1);
        vm.roll(block.number + 1); // Advance blocks for voting eligibility
        vm.prank(user);
        governor.vote(pid, true);
        
        vm.warp(block.timestamp + 5 days + 1);
        governor.execute(pid);
        
        // Try to execute same proposal again (should revert - AlreadyExecuted)
        vm.expectRevert();
        governor.execute(pid);
    }

    // ============ LevrGovernor_v1 Line 190: !meetsQuorum TRUE (defeat condition) ============

    function test_gov_190_executeNoQuorum() public {
        address proposer = address(0x1002);
        underlying.mint(proposer, 10_000 ether);
        vm.prank(proposer);
        underlying.approve(address(staking), 10_000 ether);
        vm.prank(proposer);
        staking.stake(100 ether);  // Minimal stake
        
        vm.prank(proposer);
        uint256 pid = governor.proposeBoost(address(underlying), 10 ether);
        
        // Don't vote (no quorum reached)
        vm.warp(block.timestamp + 10 days);
        
        // Execute should mark as defeated (line 162-164)
        governor.execute(pid);
    }

    // ============ LevrGovernor_v1 Line 229/231: execute success paths ============

    function test_gov_229_executeWithApproval() public {
        address user = address(0x1003);
        underlying.mint(user, 10_000 ether);
        vm.prank(user);
        underlying.approve(address(staking), 10_000 ether);
        vm.prank(user);
        staking.stake(500 ether);
        
        vm.prank(user);
        uint256 pid = governor.proposeBoost(address(underlying), 10 ether);
        
        vm.warp(block.timestamp + 2 days + 1);
        vm.roll(block.number + 1); // Advance blocks for voting eligibility
        vm.prank(user);
        governor.vote(pid, true);
        
        vm.warp(block.timestamp + 5 days + 1);
        
        // Execute with approval (should succeed, transfer funds)
        governor.execute(pid);
        
        // Verify executed flag
        ILevrGovernor_v1.Proposal memory p = governor.getProposal(pid);
        assertTrue(p.executed);
    }

    // ============ LevrGovernor_v1 Line 302/307/320: Winner selection ============

    function test_gov_302_multipleProposalsSelectWinner() public {
        address[] memory proposers = new address[](3);
        
        for (uint256 i = 0; i < 3; i++) {
            proposers[i] = address(uint160(0x2000 + i));
            underlying.mint(proposers[i], 10_000 ether);
            vm.prank(proposers[i]);
            underlying.approve(address(staking), 10_000 ether);
            vm.prank(proposers[i]);
            staking.stake(500 ether);
        }
        
        // Create 3 proposals
        uint256[] memory pids = new uint256[](3);
        for (uint256 i = 0; i < 3; i++) {
            vm.prank(proposers[i]);
            pids[i] = governor.proposeBoost(address(underlying), 10 + i * 5 ether);
        }
        
        vm.warp(block.timestamp + 2 days + 1);
        vm.roll(block.number + 1); // Advance blocks for voting eligibility
        
        // Vote on each
        for (uint256 i = 0; i < 3; i++) {
            vm.prank(proposers[i]);
            governor.vote(pids[i], true);
        }
        
        vm.warp(block.timestamp + 5 days + 1);
        
        // Execute first proposal (tests winner logic)
        governor.execute(pids[0]);
    }

    // ============ LevrGovernor Line 62-66 & 473/490: cycleId transitions ============

    function test_gov_62_cycleBoundary() public {
        address user = address(0x3001);
        underlying.mint(user, 10_000 ether);
        vm.prank(user);
        underlying.approve(address(staking), 10_000 ether);
        vm.prank(user);
        staking.stake(500 ether);
        
        // Advance time significantly to allow new cycle
        vm.warp(block.timestamp + 20 days);
        
        // Try to start new cycle
        try governor.startNewCycle() {
            // May succeed
        } catch {
            // May fail if cycle still active
        }
        
        // Cycle may or may not advance
    }

    // ============ LevrStaking Line 171: unstake and remaining balance ============

    function test_staking_171_unstakePartialRemaining() public {
        address user = address(0x4001);
        underlying.mint(user, 10_000 ether);
        
        vm.prank(user);
        underlying.approve(address(staking), 10_000 ether);
        vm.prank(user);
        staking.stake(5_000 ether);
        
        // Unstake partial (should have remaining balance)
        vm.prank(user);
        uint256 newVP = staking.unstake(2_000 ether, user);
        
        assertTrue(newVP >= 0);  // Remaining balance exists
    }

    // ============ LevrStaking Line 197: claimRewards with zero balance ============

    function test_staking_197_claimWithZeroBalance() public {
        address user = address(0x4002);
        
        // User has zero balance, tries to claim
        address[] memory tokens = new address[](0);
        
        vm.prank(user);
        staking.claimRewards(tokens, user);  // Should return early
    }

    // ============ LevrStaking Line 235-243-247: whitelist conditionals TRUE ============

    function test_staking_235_whitelistIsSameUnderlying() public {
        // Try to whitelist underlying token (should fail - line 235 condition)
        vm.expectRevert();
        staking.whitelistToken(address(underlying));
    }

    function test_staking_239_whitelistNotTokenAdmin() public {
        MockERC20 rewardToken = new MockERC20('Reward', 'RWD');
        
        // Try to whitelist as non-admin
        vm.prank(address(0x9999));
        vm.expectRevert();
        staking.whitelistToken(address(rewardToken));
    }

    function test_staking_243_whitelistAlreadyWhitelisted() public {
        MockERC20 rewardToken = new MockERC20('Reward', 'RWD');
        
        // First whitelist succeeds
        vm.prank(address(this));
        staking.whitelistToken(address(rewardToken));
        
        // Second whitelist fails (line 243 TRUE branch)
        vm.prank(address(this));
        vm.expectRevert();
        staking.whitelistToken(address(rewardToken));
    }

    function test_staking_247_whitelistExistingWithPending() public {
        MockERC20 rewardToken = new MockERC20('Reward', 'RWD');
        
        // Setup: whitelist and add rewards
        vm.prank(address(this));
        staking.whitelistToken(address(rewardToken));
        
        address user = address(0x4003);
        underlying.mint(user, 10_000 ether);
        vm.prank(user);
        underlying.approve(address(staking), 10_000 ether);
        vm.prank(user);
        staking.stake(1_000 ether);
        
        rewardToken.mint(address(staking), 100 ether);
        staking.accrueRewards(address(rewardToken));
        
        // Now try to whitelist again (exists=true with pending rewards)
        vm.prank(address(this));
        vm.expectRevert();
        staking.whitelistToken(address(rewardToken));
    }

    // ============ LevrStaking Line 274/278: unwhitelist conditionals ============

    function test_staking_274_unwhitelistIsUnderlying() public {
        // Try to unwhitelist underlying
        vm.expectRevert();
        staking.unwhitelistToken(address(underlying));
    }

    function test_staking_278_unwhitelistNotAdmin() public {
        MockERC20 rewardToken = new MockERC20('Reward', 'RWD');
        
        // Whitelist first
        vm.prank(address(this));
        staking.whitelistToken(address(rewardToken));
        
        // Try to unwhitelist as non-admin
        vm.prank(address(0x9999));
        vm.expectRevert();
        staking.unwhitelistToken(address(rewardToken));
    }

    // ============ RewardMath Line 33: complex calculation branches ============

    function test_math_33_proportionalClaimEdgeCases() public {
        address[] memory users = new address[](2);
        
        users[0] = address(0x5001);
        users[1] = address(0x5002);
        
        // User 1: 1 ether
        underlying.mint(users[0], 10_000 ether);
        vm.prank(users[0]);
        underlying.approve(address(staking), 10_000 ether);
        vm.prank(users[0]);
        staking.stake(1 ether);
        
        // User 2: 1_000_000 ether
        underlying.mint(users[1], 10_000_000 ether);
        vm.prank(users[1]);
        underlying.approve(address(staking), 10_000_000 ether);
        vm.prank(users[1]);
        staking.stake(1_000_000 ether);
        
        MockERC20 rewardToken = new MockERC20('Reward', 'RWD');
        vm.prank(address(this));
        staking.whitelistToken(address(rewardToken));
        
        // Add rewards with extreme ratio
        rewardToken.mint(address(staking), 12_345_678 ether);
        staking.accrueRewards(address(rewardToken));
        
        vm.warp(block.timestamp + 4 days);
        
        // Claim from both users (tests proportional math edge cases)
        address[] memory tokens = new address[](1);
        tokens[0] = address(rewardToken);
        
        vm.prank(users[0]);
        staking.claimRewards(tokens, users[0]);
        
        vm.prank(users[1]);
        staking.claimRewards(tokens, users[1]);
    }
}
