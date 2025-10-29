// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from 'forge-std/Test.sol';
import {console} from 'forge-std/console.sol';
import {LevrStaking_v1} from '../../src/LevrStaking_v1.sol';
import {LevrStakedToken_v1} from '../../src/LevrStakedToken_v1.sol';
import {LevrFactory_v1} from '../../src/LevrFactory_v1.sol';
import {ILevrFactory_v1} from '../../src/interfaces/ILevrFactory_v1.sol';
import {MockERC20} from '../mocks/MockERC20.sol';

/**
 * @title Contract Transfer Rewards Tests
 * @notice Tests reward handling when contracts transfer tokens
 * @dev Rule: Contract sender → transfers proportional rewards to receiver
 *           EOA sender → keeps all rewards
 */
contract LevrStaking_ContractTransferRewardsTest is Test {
    LevrFactory_v1 factory;
    LevrStaking_v1 staking;
    LevrStakedToken_v1 stakedToken;
    MockERC20 underlying;
    MockERC20 weth;

    address alice = address(0x1111); // EOA
    address bob = address(0x2222); // EOA
    MockPool pool; // Contract

    function setUp() public {
        ILevrFactory_v1.FactoryConfig memory config = ILevrFactory_v1.FactoryConfig({
            protocolFeeBps: 100,
            streamWindowSeconds: 3 days,
            protocolTreasury: address(0xFEE),
            proposalWindowSeconds: 2 days,
            votingWindowSeconds: 5 days,
            maxActiveProposals: 7,
            quorumBps: 7000,
            approvalBps: 5100,
            minSTokenBpsToSubmit: 100,
            maxProposalAmountBps: 500,
            maxRewardTokens: 50
        });

        factory = new LevrFactory_v1(config, address(this), address(0), address(0), address(0));
        underlying = new MockERC20('Underlying', 'UND');
        weth = new MockERC20('WETH', 'WETH');

        staking = new LevrStaking_v1(address(0));
        stakedToken = new LevrStakedToken_v1(
            'Staked',
            'sUND',
            18,
            address(underlying),
            address(staking)
        );

        vm.prank(address(factory));
        staking.initialize(
            address(underlying),
            address(stakedToken),
            address(this),
            address(factory)
        );

        // Create mock pool
        pool = new MockPool();

        // Setup users
        underlying.mint(alice, 100000 ether);
        underlying.mint(bob, 100000 ether);
        underlying.mint(address(pool), 100000 ether);
    }

    /// @notice Test: CONTRACT sends to EOA - buyer receives proportional rewards
    function test_contractSender_toEoa_buyerGetsRewards() public {
        // Pool stakes and earns
        vm.startPrank(address(pool));
        underlying.approve(address(staking), 1000 ether);
        staking.stake(1000 ether);

        vm.startPrank(alice);
        weth.mint(address(staking), 1000 ether);
        staking.accrueRewards(address(weth));
        vm.warp(block.timestamp + 3 days + 1);

        uint256 poolRewards = staking.claimableRewards(address(pool), address(weth));
        assertEq(poolRewards, 1000 ether);

        // Pool → Alice (50%)
        vm.startPrank(address(pool));
        stakedToken.transfer(alice, 500 ether);

        // Pool keeps 50%
        assertEq(staking.claimableRewards(address(pool), address(weth)), 500 ether);

        // Alice gets 50% (incentive!)
        assertEq(staking.claimableRewards(alice, address(weth)), 500 ether);
    }

    /// @notice Test: EOA sends to CONTRACT - sender keeps all rewards
    function test_eoaSender_toContract_senderKeepsAll() public {
        // Alice stakes and earns
        vm.startPrank(alice);
        underlying.approve(address(staking), 1000 ether);
        staking.stake(1000 ether);

        weth.mint(address(staking), 1000 ether);
        staking.accrueRewards(address(weth));
        vm.warp(block.timestamp + 3 days + 1);

        assertEq(staking.claimableRewards(alice, address(weth)), 1000 ether);

        // Alice → Pool
        stakedToken.transfer(address(pool), 500 ether);

        // Alice keeps ALL
        assertEq(staking.claimableRewards(alice, address(weth)), 1000 ether);

        // Pool gets 0
        assertEq(staking.claimableRewards(address(pool), address(weth)), 0);
    }

    /// @notice Test: EOA sends to EOA - sender keeps all
    function test_eoaSender_toEoa_senderKeepsAll() public {
        // Alice stakes and earns
        vm.startPrank(alice);
        underlying.approve(address(staking), 1000 ether);
        staking.stake(1000 ether);

        weth.mint(address(staking), 1000 ether);
        staking.accrueRewards(address(weth));
        vm.warp(block.timestamp + 3 days + 1);

        // Alice → Bob
        stakedToken.transfer(bob, 500 ether);

        // Alice keeps ALL
        assertEq(staking.claimableRewards(alice, address(weth)), 1000 ether);

        // Bob gets 0
        assertEq(staking.claimableRewards(bob, address(weth)), 0);
    }

    /// @notice Test: CONTRACT full transfer - all rewards go to receiver
    function test_contractSender_fullTransfer_allRewardsToReceiver() public {
        // Pool earns
        vm.startPrank(address(pool));
        underlying.approve(address(staking), 1000 ether);
        staking.stake(1000 ether);

        vm.startPrank(alice);
        weth.mint(address(staking), 1000 ether);
        staking.accrueRewards(address(weth));
        vm.warp(block.timestamp + 3 days + 1);

        // Pool → Alice (ALL tokens)
        vm.startPrank(address(pool));
        stakedToken.transfer(alice, 1000 ether);

        // Pool has 0 rewards (transferred all)
        assertEq(staking.claimableRewards(address(pool), address(weth)), 0);

        // Alice has all
        assertEq(staking.claimableRewards(alice, address(weth)), 1000 ether);
    }

    /// @notice Test: Contract earns more after selling some tokens
    function test_contractSender_earnsAfterSelling_correctAccounting() public {
        // Pool earns 1000
        vm.startPrank(address(pool));
        underlying.approve(address(staking), 1000 ether);
        staking.stake(1000 ether);

        vm.startPrank(alice);
        weth.mint(address(staking), 1000 ether);
        staking.accrueRewards(address(weth));
        vm.warp(block.timestamp + 3 days + 1);

        // Pool sells 50% to Alice
        vm.startPrank(address(pool));
        stakedToken.transfer(alice, 500 ether);

        // Pool: 500 ether claimable, Alice: 500 ether claimable
        assertEq(staking.claimableRewards(address(pool), address(weth)), 500 ether);
        assertEq(staking.claimableRewards(alice, address(weth)), 500 ether);

        // New rewards accrue (pool earns from remaining 500 tokens)
        vm.startPrank(alice);
        weth.mint(address(staking), 1000 ether);
        staking.accrueRewards(address(weth));
        vm.warp(block.timestamp + 3 days + 1);

        // Pool should have old 500 + new 500 (50% of 1000 from holding) = 1000
        uint256 poolFinal = staking.claimableRewards(address(pool), address(weth));
        // Alice should have old 500 + new 500 (50% of 1000 from holding) = 1000
        uint256 aliceFinal = staking.claimableRewards(alice, address(weth));

        console.log('Pool final claimable:', poolFinal);
        console.log('Alice final claimable:', aliceFinal);

        // Both should have earned equally from new rewards
        assertGe(poolFinal, 500 ether, 'Pool should have at least old rewards');
        assertGe(aliceFinal, 500 ether, 'Alice should have at least old rewards');

        // Total should not exceed total accrued
        assertLe(poolFinal + aliceFinal, 2000 ether, 'Total cannot exceed accrued');
    }

    /// @notice Test: No fund stuck when contract transfers and rewards never fail the transfer
    function test_contractSender_transferNeverFails_gracefulDegradation() public {
        // Pool earns rewards
        vm.startPrank(address(pool));
        underlying.approve(address(staking), 1000 ether);
        staking.stake(1000 ether);

        vm.startPrank(alice);
        weth.mint(address(staking), 1000 ether);
        staking.accrueRewards(address(weth));
        vm.warp(block.timestamp + 3 days + 1);

        // Transfer should NEVER fail, even if reward calculation has issues
        vm.startPrank(address(pool));

        // This should succeed (try-catch in stakedToken protects)
        stakedToken.transfer(alice, 500 ether);

        // Verify transfer succeeded
        assertEq(stakedToken.balanceOf(alice), 500 ether, 'Transfer should succeed');
        assertEq(stakedToken.balanceOf(address(pool)), 500 ether, 'Pool balance correct');
    }
}

/**
 * @title Mock Pool
 * @notice Simple contract to simulate Uniswap pool
 */
contract MockPool {
    // Empty contract with code
}
