// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from 'forge-std/Test.sol';
import {LevrStaking_v1} from '../../src/LevrStaking_v1.sol';
import {LevrStakedToken_v1} from '../../src/LevrStakedToken_v1.sol';
import {LevrFactory_v1} from '../../src/LevrFactory_v1.sol';
import {ILevrFactory_v1} from '../../src/interfaces/ILevrFactory_v1.sol';
import {MockERC20} from '../mocks/MockERC20.sol';

/**
 * @title Staked Token Non-Transferable Tests
 * @notice Verifies that staked tokens cannot be transferred between users
 * @dev Simplified design: Tokens are non-transferable to avoid complex VP/reward accounting
 */
contract LevrStakedToken_NonTransferableTest is Test {
    LevrFactory_v1 factory;
    LevrStaking_v1 staking;
    LevrStakedToken_v1 stakedToken;
    MockERC20 underlying;

    address alice = address(0x1111);
    address bob = address(0x2222);

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

        staking = new LevrStaking_v1(address(0));
        stakedToken = new LevrStakedToken_v1('Staked', 'sUND', 18, address(underlying), address(staking));

        vm.prank(address(factory));
        staking.initialize(address(underlying), address(stakedToken), address(this), address(factory));

        underlying.mint(alice, 10000 ether);
        underlying.mint(bob, 10000 ether);
    }

    /// @notice Test that transfers are blocked
    function test_stakedToken_transferBlocked() public {
        vm.startPrank(alice);
        underlying.approve(address(staking), 1000 ether);
        staking.stake(1000 ether);

        // Try to transfer - should revert
        vm.expectRevert('STAKED_TOKENS_NON_TRANSFERABLE');
        stakedToken.transfer(bob, 500 ether);
    }

    /// @notice Test that transferFrom is also blocked
    function test_stakedToken_transferFromBlocked() public {
        vm.startPrank(alice);
        underlying.approve(address(staking), 1000 ether);
        staking.stake(1000 ether);

        // Approve bob
        stakedToken.approve(bob, 500 ether);

        // Bob tries transferFrom - should revert
        vm.startPrank(bob);
        vm.expectRevert('STAKED_TOKENS_NON_TRANSFERABLE');
        stakedToken.transferFrom(alice, bob, 500 ether);
    }

    /// @notice Test that mint still works (staking)
    function test_stakedToken_mintWorks() public {
        vm.startPrank(alice);
        underlying.approve(address(staking), 1000 ether);
        staking.stake(1000 ether);

        assertEq(stakedToken.balanceOf(alice), 1000 ether);
    }

    /// @notice Test that burn still works (unstaking)
    function test_stakedToken_burnWorks() public {
        vm.startPrank(alice);
        underlying.approve(address(staking), 1000 ether);
        staking.stake(1000 ether);

        staking.unstake(400 ether, alice);

        assertEq(stakedToken.balanceOf(alice), 600 ether);
    }
}

