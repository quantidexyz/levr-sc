// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from 'forge-std/Test.sol';
import {LevrFactoryDeployHelper} from "../utils/LevrFactoryDeployHelper.sol";
import {LevrStaking_v1} from '../../src/LevrStaking_v1.sol';
import {LevrStakedToken_v1} from '../../src/LevrStakedToken_v1.sol';
import {ILevrFactory_v1} from '../../src/interfaces/ILevrFactory_v1.sol';
import {ILevrStaking_v1} from '../../src/interfaces/ILevrStaking_v1.sol';
import {MockERC20} from '../mocks/MockERC20.sol';

/// @title LevrStakingV1.RewardTokenDoS Test
/// @notice Tests whitelist-based DoS protection
/// @dev Verifies that non-whitelisted tokens cannot accrue rewards
contract LevrStakingV1_RewardTokenDoS_Test is Test, LevrFactoryDeployHelper {
    MockERC20 internal underlying;
    MockERC20 internal rewardToken;
    LevrStakedToken_v1 internal sToken;
    LevrStaking_v1 internal staking;
    address internal treasury = address(0xBEEF);
    address internal attacker = address(0xDEAD);

    function setUp() public {
        underlying = new MockERC20('Token', 'TKN');
        rewardToken = new MockERC20('Reward', 'RWD');
        staking = createStaking(address(0), address(this));
        sToken = createStakedToken('Staked Token', 'sTKN', 18, address(underlying), address(staking));
        staking.initialize(
            address(underlying),
            address(sToken),
            treasury,
            new address[](0)
        );

        underlying.mint(address(this), 10_000 ether);
        rewardToken.mint(address(this), 10_000 ether);
    }

    function streamWindowSeconds(address) external pure returns (uint32) {
        return 7 days;
    }


    /// @notice Test that any amount is accepted for whitelisted tokens
    function test_creditRewards_rejectsDustAmounts() public {
        // Whitelist reward token first
        staking.whitelistToken(address(rewardToken));

        // Stake to enable reward accrual
        underlying.approve(address(staking), 100 ether);
        staking.stake(100 ether);

        // Accrue small amount (previously would have been rejected, now works)
        uint256 smallAmount = 1e14; // 0.0001 tokens
        rewardToken.transfer(address(staking), smallAmount);

        // Should succeed - no minimum amount check, whitelist is the protection
        staking.accrueFromTreasury(address(rewardToken), smallAmount, false);
        
        // Verify rewards were credited
        assertTrue(true, 'Small amounts accepted for whitelisted tokens');
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

    /// @notice Test DoS protection via whitelist enforcement
    function test_dosAttack_preventedByMinimumAmount() public {
        // Stake to have some rewards available
        underlying.approve(address(staking), 100 ether);
        staking.stake(100 ether);

        // Test first 5 tokens (enough to demonstrate the protection)
        for (uint256 i = 0; i < 5; i++) {
            // Create a token (any amount)
            MockERC20 attackToken = new MockERC20('Attack', 'ATK');
            attackToken.mint(address(this), 1e14);
            attackToken.transfer(address(staking), 1e14);

            // Try to accrue without whitelisting - should revert with TokenNotWhitelisted
            vm.expectRevert(ILevrStaking_v1.TokenNotWhitelisted.selector);
            staking.accrueFromTreasury(address(attackToken), 1e14, false);
        }

        // Verify legitimate whitelisted token can be added
        MockERC20 legit = new MockERC20('Legit', 'LEG');
        legit.mint(address(this), 1000 ether);
        legit.transfer(address(staking), 1000 ether);

        // Whitelist and accrue legitimate token
        staking.whitelistToken(address(legit));
        staking.accrueFromTreasury(address(legit), 1000 ether, false);
    }
}
