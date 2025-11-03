// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from 'forge-std/Test.sol';
import {LevrFactory_v1} from '../../src/LevrFactory_v1.sol';
import {LevrStaking_v1} from '../../src/LevrStaking_v1.sol';
import {LevrTreasury_v1} from '../../src/LevrTreasury_v1.sol';
import {LevrGovernor_v1} from '../../src/LevrGovernor_v1.sol';
import {LevrForwarder_v1} from '../../src/LevrForwarder_v1.sol';
import {ILevrFactory_v1} from '../../src/interfaces/ILevrFactory_v1.sol';
import {ILevrForwarder_v1} from '../../src/interfaces/ILevrForwarder_v1.sol';
import {MockERC20} from '../mocks/MockERC20.sol';
import {LevrFactoryDeployHelper} from '../utils/LevrFactoryDeployHelper.sol';

/// @title Comprehensive Error Path Coverage Tests
/// @notice Tests all error conditions and revert paths across core contracts
contract Phase2_ErrorPaths_Test is Test, LevrFactoryDeployHelper {
    MockERC20 internal underlying;
    LevrFactory_v1 internal factory;
    LevrForwarder_v1 internal forwarder;
    LevrTreasury_v1 internal treasury;
    LevrStaking_v1 internal staking;
    LevrGovernor_v1 internal governor;
    
    address internal protocolTreasury = address(0xDEAD);
    address internal user = address(0xAAAA);

    function setUp() public {
        underlying = new MockERC20('Token', 'TKN');
        ILevrFactory_v1.FactoryConfig memory cfg = createDefaultConfig(protocolTreasury);
        (factory, forwarder, ) = deployFactoryWithDefaultClanker(cfg, address(this));
        
        factory.prepareForDeployment();
        ILevrFactory_v1.Project memory project = factory.register(address(underlying));
        
        governor = LevrGovernor_v1(project.governor);
        treasury = LevrTreasury_v1(payable(project.treasury));
        staking = LevrStaking_v1(project.staking);
        
        // Fund and setup
        underlying.mint(address(treasury), 10_000 ether);
        underlying.mint(user, 1_000 ether);
    }

    // ============ Treasury Error Paths ============
    
    function test_error_treasury_001_transferUnauthorized() public {
        vm.prank(user);
        vm.expectRevert();
        treasury.transfer(address(underlying), address(0x1234), 100 ether);
    }

    function test_error_treasury_002_transferZeroToken() public {
        address gov = address(governor);
        vm.prank(gov);
        vm.expectRevert();
        treasury.transfer(address(0), address(0x1234), 100 ether);
    }

    function test_error_treasury_003_transferZeroRecipient() public {
        address gov = address(governor);
        vm.prank(gov);
        vm.expectRevert();
        treasury.transfer(address(underlying), address(0), 100 ether);
    }

    function test_error_treasury_004_boostUnauthorized() public {
        vm.prank(user);
        vm.expectRevert();
        treasury.applyBoost(address(underlying), 100 ether);
    }

    function test_error_treasury_005_boostZeroToken() public {
        address gov = address(governor);
        vm.prank(gov);
        vm.expectRevert();
        treasury.applyBoost(address(0), 100 ether);
    }

    function test_error_treasury_006_transferExceedsBalance() public {
        address gov = address(governor);
        vm.prank(gov);
        vm.expectRevert();
        treasury.transfer(address(underlying), address(0x1234), 100_000 ether);
    }

    // ============ Staking Error Paths ============

    function test_error_staking_001_stakeZeroAmount() public {
        vm.prank(user);
        underlying.approve(address(staking), 1_000 ether);
        
        vm.prank(user);
        vm.expectRevert();
        staking.stake(0);
    }

    function test_error_staking_002_stakeWithoutApproval() public {
        vm.prank(user);
        vm.expectRevert();
        staking.stake(100 ether);
    }

    function test_error_staking_003_unstakeZeroAmount() public {
        vm.prank(user);
        underlying.approve(address(staking), 1_000 ether);
        vm.prank(user);
        staking.stake(500 ether);
        
        vm.prank(user);
        vm.expectRevert();
        staking.unstake(0, user);
    }

    function test_error_staking_004_unstakeExceedsBalance() public {
        vm.prank(user);
        underlying.approve(address(staking), 1_000 ether);
        vm.prank(user);
        staking.stake(500 ether);
        
        vm.prank(user);
        vm.expectRevert();
        staking.unstake(600 ether, user);
    }

    function test_error_staking_005_unstakeToZeroAddress() public {
        vm.prank(user);
        underlying.approve(address(staking), 1_000 ether);
        vm.prank(user);
        staking.stake(500 ether);
        
        vm.prank(user);
        vm.expectRevert();
        staking.unstake(100 ether, address(0));
    }

    function test_error_staking_006_whitelistZeroAddress() public {
        vm.expectRevert();
        staking.whitelistToken(address(0));
    }

    function test_error_staking_007_unwhitelistNonExistent() public {
        MockERC20 token = new MockERC20('Test', 'TST');
        vm.expectRevert();
        staking.unwhitelistToken(address(token));
    }

    function test_error_staking_008_accrueUnwhitelistedToken() public {
        MockERC20 rewardToken = new MockERC20('Reward', 'RWD');
        rewardToken.mint(address(staking), 1_000 ether);
        
        vm.expectRevert();
        staking.accrueRewards(address(rewardToken));
    }

    function test_error_staking_009_accrueInsufficientAmount() public {
        MockERC20 rewardToken = new MockERC20('Reward', 'RWD');
        address admin = address(this); // Admin of underlying
        
        vm.prank(admin);
        staking.whitelistToken(address(rewardToken));
        
        rewardToken.mint(address(staking), 100); // Way below MIN_REWARD_AMOUNT
        
        vm.expectRevert();
        staking.accrueRewards(address(rewardToken));
    }

    // ============ Governor Error Paths ============

    function test_error_governor_001_proposeZeroToken() public {
        vm.prank(user);
        underlying.approve(address(staking), 1_000 ether);
        vm.prank(user);
        staking.stake(200 ether);
        
        vm.prank(user);
        vm.expectRevert();
        governor.proposeBoost(address(0), 10 ether);
    }

    function test_error_governor_002_proposeTransferZeroRecipient() public {
        vm.prank(user);
        underlying.approve(address(staking), 1_000 ether);
        vm.prank(user);
        staking.stake(200 ether);
        
        vm.prank(user);
        vm.expectRevert();
        governor.proposeTransfer(address(underlying), address(0), 10 ether, 'desc');
    }

    function test_error_governor_003_proposeTransferZeroToken() public {
        vm.prank(user);
        underlying.approve(address(staking), 1_000 ether);
        vm.prank(user);
        staking.stake(200 ether);
        
        vm.prank(user);
        vm.expectRevert();
        governor.proposeTransfer(address(0), address(0x1234), 10 ether, 'desc');
    }

    function test_error_governor_004_voteBeforeVotingWindow() public {
        vm.prank(user);
        underlying.approve(address(staking), 1_000 ether);
        vm.prank(user);
        staking.stake(200 ether);
        
        vm.warp(block.timestamp + 1);
        vm.prank(user);
        uint256 pid = governor.proposeBoost(address(underlying), 10 ether);
        
        // Try to vote immediately (before voting window)
        vm.prank(user);
        vm.expectRevert();
        governor.vote(pid, true);
    }

    function test_error_governor_005_voteAfterVotingWindow() public {
        vm.prank(user);
        underlying.approve(address(staking), 1_000 ether);
        vm.prank(user);
        staking.stake(200 ether);
        
        vm.prank(user);
        uint256 pid = governor.proposeBoost(address(underlying), 10 ether);
        
        // Jump past voting window
        vm.warp(block.timestamp + 10 days);
        
        vm.prank(user);
        vm.expectRevert();
        governor.vote(pid, true);
    }

    function test_error_governor_006_voteWithoutPower() public {
        vm.prank(user);
        underlying.approve(address(staking), 1_000 ether);
        vm.prank(user);
        staking.stake(200 ether);
        
        vm.prank(user);
        uint256 pid = governor.proposeBoost(address(underlying), 10 ether);
        
        // User unstakes all
        vm.prank(user);
        staking.unstake(200 ether, user);
        
        vm.warp(block.timestamp + 2 days + 1);
        
        // Try to vote without power
        vm.prank(user);
        vm.expectRevert();
        governor.vote(pid, true);
    }

    function test_error_governor_007_voteTwice() public {
        vm.prank(user);
        underlying.approve(address(staking), 1_000 ether);
        vm.prank(user);
        staking.stake(200 ether);
        
        vm.prank(user);
        uint256 pid = governor.proposeBoost(address(underlying), 10 ether);
        
        vm.warp(block.timestamp + 2 days + 1);
        
        vm.prank(user);
        governor.vote(pid, true);
        
        // Try to vote again
        vm.prank(user);
        vm.expectRevert();
        governor.vote(pid, true);
    }

    // ============ Forwarder Error Paths ============

    function test_error_forwarder_001_executeTransactionDirectly() public {
        vm.prank(user);
        vm.expectRevert();
        forwarder.executeTransaction(address(treasury), '');
    }

    function test_error_forwarder_002_valueMismatch() public {
        ILevrForwarder_v1.SingleCall[] memory calls = new ILevrForwarder_v1.SingleCall[](1);
        calls[0] = ILevrForwarder_v1.SingleCall({
            target: address(treasury),
            allowFailure: false,
            value: 5 ether,
            callData: ''
        });
        
        vm.deal(user, 10 ether);
        vm.prank(user);
        vm.expectRevert();
        forwarder.executeMulticall{value: 10 ether}(calls);
    }

    function test_error_forwarder_003_withdrawTrappedETHNonDeployer() public {
        vm.deal(address(forwarder), 1 ether);
        
        vm.prank(user);
        vm.expectRevert();
        forwarder.withdrawTrappedETH();
    }

    function test_error_forwarder_004_withdrawTrappedETHNoFunds() public {
        vm.prank(address(this)); // Deployer
        vm.expectRevert();
        forwarder.withdrawTrappedETH();
    }
}
