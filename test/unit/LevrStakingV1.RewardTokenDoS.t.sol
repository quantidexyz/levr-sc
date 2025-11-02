// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from 'forge-std/Test.sol';
import {LevrStaking_v1} from '../../src/LevrStaking_v1.sol';
import {LevrStakedToken_v1} from '../../src/LevrStakedToken_v1.sol';
import {ILevrFactory_v1} from '../../src/interfaces/ILevrFactory_v1.sol';
import {MockERC20} from '../mocks/MockERC20.sol';

/// @title LevrStakingV1.RewardTokenDoS Test
/// @notice Tests MEDIUM-2 fix: Minimum reward amount validation
/// @dev Verifies that dust amounts are rejected to prevent DoS attacks
contract LevrStakingV1_RewardTokenDoS_Test is Test {
    MockERC20 internal underlying;
    MockERC20 internal rewardToken;
    LevrStakedToken_v1 internal sToken;
    LevrStaking_v1 internal staking;
    address internal treasury = address(0xBEEF);
    address internal attacker = address(0xDEAD);

    function setUp() public {
        underlying = new MockERC20('Token', 'TKN');
        rewardToken = new MockERC20('Reward', 'RWD');
        staking = new LevrStaking_v1(address(0));
        sToken = new LevrStakedToken_v1(
            'Staked Token',
            'sTKN',
            18,
            address(underlying),
            address(staking)
        );
        staking.initialize(
            address(underlying),
            address(sToken),
            treasury,
            address(this),
            new address[](0)
        );

        underlying.mint(address(this), 10_000 ether);
        rewardToken.mint(address(this), 10_000 ether);
    }

    function streamWindowSeconds(address) external pure returns (uint32) {
        return 7 days;
    }

    function getClankerMetadata(
        address
    ) external pure returns (ILevrFactory_v1.ClankerMetadata memory) {
        return
            ILevrFactory_v1.ClankerMetadata({
                feeLocker: address(0),
                lpLocker: address(0),
                hook: address(0),
                exists: false
            });
    }

    /// @notice MEDIUM-2: Test that dust amounts are rejected
    function test_creditRewards_rejectsDustAmounts() public {
        // Whitelist reward token first
        staking.whitelistToken(address(rewardToken));

        // Stake to enable reward accrual
        underlying.approve(address(staking), 100 ether);
        staking.stake(100 ether);

        // Try to accrue dust amount (less than MIN_REWARD_AMOUNT = 1e15)
        uint256 dustAmount = 1e14; // 0.0001 tokens
        rewardToken.transfer(address(staking), dustAmount);

        // Should revert with REWARD_TOO_SMALL
        vm.expectRevert('REWARD_TOO_SMALL');
        staking.accrueFromTreasury(address(rewardToken), dustAmount, false);
    }

    /// @notice MEDIUM-2: Test that minimum amount is accepted
    function test_creditRewards_acceptsMinimumAmount() public {
        // Whitelist reward token first
        staking.whitelistToken(address(rewardToken));

        // Stake to enable reward accrual
        underlying.approve(address(staking), 100 ether);
        staking.stake(100 ether);

        // Accrue exactly MIN_REWARD_AMOUNT = 1e15
        uint256 minAmount = 1e15;
        rewardToken.transfer(address(staking), minAmount);
        staking.accrueFromTreasury(address(rewardToken), minAmount, false);

        // Should succeed
    }

    /// @notice MEDIUM-2: Test that legitimate amounts are accepted
    function test_creditRewards_acceptsLegitimateAmounts() public {
        // Whitelist reward token first
        staking.whitelistToken(address(rewardToken));

        // Stake to enable reward accrual
        underlying.approve(address(staking), 100 ether);
        staking.stake(100 ether);

        // Accrue normal amount - use pullFromTreasury to avoid available check
        uint256 legit = 1000 ether;
        rewardToken.transfer(treasury, legit);
        vm.prank(treasury);
        rewardToken.approve(address(staking), legit);

        vm.prank(treasury);
        staking.accrueFromTreasury(address(rewardToken), legit, true);

        // Verify call succeeded without reverting
        assertTrue(true, 'Should accept legitimate amounts');
    }

    /// @notice MEDIUM-2: Test DoS attack scenario is prevented
    function test_dosAttack_preventedByMinimumAmount() public {
        // Stake to have some rewards available
        underlying.approve(address(staking), 100 ether);
        staking.stake(100 ether);

        // Test first 5 tokens (enough to demonstrate the protection)
        for (uint256 i = 0; i < 5; i++) {
            // Create a dust token
            MockERC20 dustToken = new MockERC20('Dust', 'DUST');
            dustToken.mint(address(this), 1e14);
            dustToken.transfer(address(staking), 1e14);

            // Whitelist the token (attacker could do this as token admin)
            staking.whitelistToken(address(dustToken));

            // Try to accrueFromTreasury with dust - should revert with REWARD_TOO_SMALL
            vm.expectRevert('REWARD_TOO_SMALL');
            staking.accrueFromTreasury(address(dustToken), 1e14, false);
        }

        // Verify legitimate token can still be added
        MockERC20 legit = new MockERC20('Legit', 'LEG');
        legit.mint(address(this), 1000 ether);
        legit.transfer(address(staking), 1000 ether);

        // Whitelist and accrue legitimate token
        staking.whitelistToken(address(legit));
        staking.accrueFromTreasury(address(legit), 1000 ether, false);
    }
}
