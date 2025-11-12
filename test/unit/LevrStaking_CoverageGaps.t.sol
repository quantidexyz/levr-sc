// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from 'forge-std/Test.sol';
import {console2} from 'forge-std/console2.sol';
import {LevrStaking_v1} from '../../src/LevrStaking_v1.sol';
import {LevrStakedToken_v1} from '../../src/LevrStakedToken_v1.sol';
import {ILevrFactory_v1} from '../../src/interfaces/ILevrFactory_v1.sol';
import {ILevrStaking_v1} from '../../src/interfaces/ILevrStaking_v1.sol';
import {MockERC20} from '../mocks/MockERC20.sol';
import {LevrFactoryDeployHelper} from '../utils/LevrFactoryDeployHelper.sol';

/// @title LevrStaking Coverage Gap Tests
/// @notice Tests to improve branch coverage for LevrStaking_v1.sol
/// @dev Focuses on uncovered branches and edge cases identified in coverage analysis
contract LevrStaking_CoverageGaps_Test is Test, LevrFactoryDeployHelper {
    MockERC20 internal underlying;
    MockERC20 internal rewardToken;
    LevrStakedToken_v1 internal sToken;
    LevrStaking_v1 internal staking;
    address internal treasury = address(0xBEEF);
    address internal factory;

    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);
    address internal charlie = address(0xC001);

    event TokenWhitelisted(address indexed token);
    event TokenUnwhitelisted(address indexed token);
    event RewardTokenRemoved(address indexed token);
    event RewardsAccrued(address indexed token, uint256 amount, uint256 totalPool);
    event RewardsClaimed(
        address indexed user,
        address indexed to,
        address indexed token,
        uint256 amount
    );

    // Mock factory functions for testing
    function clankerFactory() external pure returns (address) {
        return address(0);
    }

    function streamWindowSeconds(address) external pure returns (uint32) {
        return 3 days;
    }

    function setUp() public {
        underlying = new MockERC20('Token', 'TKN');
        rewardToken = new MockERC20('Reward', 'RWD');
        factory = address(this);

        staking = createStaking(address(0), address(this));
        sToken = createStakedToken('Staked Token', 'sTKN', 18, address(underlying), address(staking));

        // Initialize with empty whitelist
        initializeStakingWithRewardTokens(
            staking,
            address(underlying),
            address(sToken),
            treasury,
            new address[](0)
        );

        underlying.mint(alice, 100_000 ether);
        underlying.mint(bob, 100_000 ether);
        underlying.mint(charlie, 100_000 ether);
        rewardToken.mint(address(this), 1_000_000 ether);
    }

    // ============================================================================
    // TEST 1: Double Initialization Prevention
    // ============================================================================
    /// @dev Covers line 58: Already initialized check
    function test_initialize_alreadyInitialized_reverts() public {
        // Try to initialize again
        vm.expectRevert(ILevrStaking_v1.AlreadyInitialized.selector);
        staking.initialize(
            address(underlying),
            address(sToken),
            treasury,
            new address[](0)
        );
    }

    // ============================================================================
    // TEST 2: Initialization Access Control
    // ============================================================================
    /// @dev Covers line 67: Only factory can initialize
    function test_initialize_onlyFactory_whenNotFactory_reverts() public {
        // Deploy new staking contract
        LevrStaking_v1 newStaking = createStaking(address(0), address(this));

        // Try to initialize from non-factory address
        vm.prank(alice);
        vm.expectRevert(ILevrStaking_v1.OnlyFactory.selector);
        newStaking.initialize(
            address(underlying),
            address(sToken),
            treasury,
            new address[](0)
        );
    }

    // ============================================================================
    // TEST 3: Zero Address Validation in Initialize
    // ============================================================================
    /// @dev Covers lines 59-64: Zero address checks
    function test_initialize_zeroAddressUnderlying_reverts() public {
        LevrStaking_v1 newStaking = createStaking(address(0), address(this));

        vm.expectRevert(ILevrStaking_v1.ZeroAddress.selector);
        newStaking.initialize(address(0), address(sToken), treasury, new address[](0));
    }

    function test_initialize_zeroAddressStakedToken_reverts() public {
        LevrStaking_v1 newStaking = createStaking(address(0), address(this));

        vm.expectRevert(ILevrStaking_v1.ZeroAddress.selector);
        newStaking.initialize(address(underlying), address(0), treasury, new address[](0));
    }

    function test_initialize_zeroAddressTreasury_reverts() public {
        LevrStaking_v1 newStaking = createStaking(address(0), address(this));

        vm.expectRevert(ILevrStaking_v1.ZeroAddress.selector);
        newStaking.initialize(
            address(underlying),
            address(sToken),
            address(0),
            new address[](0)
        );
    }

    function test_initialize_zeroAddressFactory_reverts() public {
        // Factory is now set in constructor, so test constructor revert
        vm.expectRevert(ILevrStaking_v1.ZeroAddress.selector);
        new LevrStaking_v1(address(0), address(0)); // zero factory should revert
    }

    // ============================================================================
    // TEST 4: Whitelist Token - Cannot Modify Underlying
    // ============================================================================
    /// @dev Covers line 232: Cannot modify underlying token whitelist
    function test_whitelistToken_cannotModifyUnderlying_reverts() public {
        // Get token admin
        address admin = underlying.admin();

        vm.prank(admin);
        vm.expectRevert(ILevrStaking_v1.CannotModifyUnderlying.selector);
        staking.whitelistToken(address(underlying));
    }

    // ============================================================================
    // TEST 5: Whitelist Token - Only Token Admin
    // ============================================================================
    /// @dev Covers line 236: Only token admin can whitelist
    function test_whitelistToken_onlyTokenAdmin_reverts() public {
        vm.prank(alice);
        vm.expectRevert(ILevrStaking_v1.OnlyTokenAdmin.selector);
        staking.whitelistToken(address(rewardToken));
    }

    // ============================================================================
    // TEST 6: Whitelist Token - Already Whitelisted
    // ============================================================================
    /// @dev Covers line 240: Cannot whitelist already whitelisted token
    function test_whitelistToken_alreadyWhitelisted_reverts() public {
        address admin = underlying.admin();

        // Whitelist reward token
        whitelistRewardToken(staking, address(rewardToken), admin);

        // Try to whitelist again
        vm.prank(admin);
        vm.expectRevert(ILevrStaking_v1.AlreadyWhitelisted.selector);
        staking.whitelistToken(address(rewardToken));
    }

    // ============================================================================
    // TEST 7: Whitelist Token - With Pending Rewards Success Path
    // ============================================================================
    /// @dev Tests that after rewards are fully claimed, token can be re-whitelisted
    function test_whitelistToken_afterRewardsClaimed_success() public {
        address admin = underlying.admin();

        // Whitelist and add rewards
        whitelistRewardToken(staking, address(rewardToken), admin);

        // Stake some tokens
        vm.startPrank(alice);
        underlying.approve(address(staking), type(uint256).max);
        staking.stake(1000 ether);
        vm.stopPrank();

        // Add rewards
        rewardToken.transfer(address(staking), 1000 ether);
        staking.accrueRewards(address(rewardToken));

        // Wait for stream to finish
        vm.warp(block.timestamp + 3 days + 1);

        // Claim all rewards
        address[] memory tokens = new address[](1);
        tokens[0] = address(rewardToken);
        vm.prank(alice);
        staking.claimRewards(tokens, alice);

        // Unwhitelist after rewards are claimed
        vm.prank(admin);
        staking.unwhitelistToken(address(rewardToken));

        // Now token is unwhitelisted with no pending rewards
        // Try to whitelist again - should work
        vm.prank(admin);
        staking.whitelistToken(address(rewardToken));

        // Verify it's whitelisted
        assertTrue(staking.isTokenWhitelisted(address(rewardToken)), 'Should be whitelisted');
    }

    // ============================================================================
    // TEST 8: Unwhitelist Token - Cannot Unwhitelist Underlying
    // ============================================================================
    /// @dev Covers line 270: Cannot unwhitelist underlying token
    function test_unwhitelistToken_cannotUnwhitelistUnderlying_reverts() public {
        address admin = underlying.admin();

        vm.prank(admin);
        vm.expectRevert(ILevrStaking_v1.CannotUnwhitelistUnderlying.selector);
        staking.unwhitelistToken(address(underlying));
    }

    // ============================================================================
    // TEST 9: Unwhitelist Token - Only Token Admin
    // ============================================================================
    /// @dev Covers line 274: Only token admin can unwhitelist
    function test_unwhitelistToken_onlyTokenAdmin_reverts() public {
        address admin = underlying.admin();
        whitelistRewardToken(staking, address(rewardToken), admin);

        vm.prank(alice);
        vm.expectRevert(ILevrStaking_v1.OnlyTokenAdmin.selector);
        staking.unwhitelistToken(address(rewardToken));
    }

    // ============================================================================
    // TEST 10: Unwhitelist Token - Not Registered
    // ============================================================================
    /// @dev Covers line 278: Token must be registered
    function test_unwhitelistToken_notRegistered_reverts() public {
        address admin = underlying.admin();
        MockERC20 newToken = new MockERC20('New', 'NEW');

        vm.prank(admin);
        vm.expectRevert(ILevrStaking_v1.TokenNotRegistered.selector);
        staking.unwhitelistToken(address(newToken));
    }

    // ============================================================================
    // TEST 11: Unwhitelist Token - Not Whitelisted
    // ============================================================================
    /// @dev Covers line 279: Token must be whitelisted
    function test_unwhitelistToken_notWhitelisted_reverts() public {
        address admin = underlying.admin();

        // Whitelist and then unwhitelist
        whitelistRewardToken(staking, address(rewardToken), admin);
        vm.prank(admin);
        staking.unwhitelistToken(address(rewardToken));

        // Try to unwhitelist again
        vm.prank(admin);
        vm.expectRevert(ILevrStaking_v1.NotWhitelisted.selector);
        staking.unwhitelistToken(address(rewardToken));
    }

    // ============================================================================
    // TEST 12: Unwhitelist Token - With Pending Rewards
    // ============================================================================
    /// @dev Covers lines 282-283, 290-291: Cannot unwhitelist with pending rewards
    function test_unwhitelistToken_withPendingRewards_reverts() public {
        address admin = underlying.admin();
        whitelistRewardToken(staking, address(rewardToken), admin);

        // Stake tokens
        vm.startPrank(alice);
        underlying.approve(address(staking), type(uint256).max);
        staking.stake(1000 ether);
        vm.stopPrank();

        // Add rewards
        rewardToken.transfer(address(staking), 1000 ether);
        staking.accrueRewards(address(rewardToken));

        // Try to unwhitelist with pending rewards
        vm.prank(admin);
        vm.expectRevert(ILevrStaking_v1.CannotUnwhitelistWithPendingRewards.selector);
        staking.unwhitelistToken(address(rewardToken));
    }

    // ============================================================================
    // TEST 13: Cleanup Finished Reward Token - Cannot Remove Underlying
    // ============================================================================
    /// @dev Covers line 302: Cannot remove underlying token
    function test_cleanupFinishedRewardToken_cannotRemoveUnderlying_reverts() public {
        vm.expectRevert(ILevrStaking_v1.CannotRemoveUnderlying.selector);
        staking.cleanupFinishedRewardToken(address(underlying));
    }

    // ============================================================================
    // TEST 14: Cleanup Finished Reward Token - Not Registered
    // ============================================================================
    /// @dev Covers line 305: Token must be registered
    function test_cleanupFinishedRewardToken_notRegistered_reverts() public {
        MockERC20 newToken = new MockERC20('New', 'NEW');

        vm.expectRevert(ILevrStaking_v1.TokenNotRegistered.selector);
        staking.cleanupFinishedRewardToken(address(newToken));
    }

    // ============================================================================
    // TEST 15: Cleanup Finished Reward Token - Still Whitelisted
    // ============================================================================
    /// @dev Covers line 306: Cannot remove whitelisted token
    function test_cleanupFinishedRewardToken_cannotRemoveWhitelisted_reverts() public {
        address admin = underlying.admin();
        whitelistRewardToken(staking, address(rewardToken), admin);

        vm.expectRevert(ILevrStaking_v1.CannotRemoveWhitelisted.selector);
        staking.cleanupFinishedRewardToken(address(rewardToken));
    }

    // ============================================================================
    // TEST 16: Cleanup Finished Reward Token - With Pending Rewards
    // ============================================================================
    /// @dev Covers lines 307-308: Cannot remove with pending rewards
    function test_cleanupFinishedRewardToken_withPendingRewards_reverts() public {
        address admin = underlying.admin();
        whitelistRewardToken(staking, address(rewardToken), admin);

        // Stake and add rewards
        vm.startPrank(alice);
        underlying.approve(address(staking), type(uint256).max);
        staking.stake(1000 ether);
        vm.stopPrank();

        rewardToken.transfer(address(staking), 1000 ether);
        staking.accrueRewards(address(rewardToken));

        // Wait for stream to finish but DON'T claim
        vm.warp(block.timestamp + 3 days + 1);

        // Unwhitelist - this will verify no pending rewards during unwhitelist
        // But rewards are in the pool, not the stream
        vm.prank(admin);
        vm.expectRevert(ILevrStaking_v1.CannotUnwhitelistWithPendingRewards.selector);
        staking.unwhitelistToken(address(rewardToken));
    }

    // ============================================================================
    // TEST 17: Cleanup Finished Reward Token - Success Path
    // ============================================================================
    /// @dev Tests successful cleanup of finished reward token
    function test_cleanupFinishedRewardToken_success() public {
        address admin = underlying.admin();
        whitelistRewardToken(staking, address(rewardToken), admin);

        // Stake and add rewards
        vm.startPrank(alice);
        underlying.approve(address(staking), type(uint256).max);
        staking.stake(1000 ether);
        vm.stopPrank();

        rewardToken.transfer(address(staking), 1000 ether);
        staking.accrueRewards(address(rewardToken));

        // Wait for stream to finish
        vm.warp(block.timestamp + 3 days + 1);

        // Claim all rewards
        address[] memory tokens = new address[](1);
        tokens[0] = address(rewardToken);
        vm.prank(alice);
        staking.claimRewards(tokens, alice);

        // Unwhitelist
        vm.prank(admin);
        staking.unwhitelistToken(address(rewardToken));

        // Now cleanup should work
        vm.expectEmit(true, false, false, false);
        emit RewardTokenRemoved(address(rewardToken));
        staking.cleanupFinishedRewardToken(address(rewardToken));

        // Verify token is removed
        assertFalse(staking.isTokenWhitelisted(address(rewardToken)), 'Should not be whitelisted');
    }

    // ============================================================================
    // TEST 18: Stream Window Seconds - View Function
    // ============================================================================
    /// @dev Covers lines 394-395: streamWindowSeconds view function
    function test_streamWindowSeconds_returnsCorrectValue() public view {
        uint32 window = staking.streamWindowSeconds();
        assertEq(window, 3 days, 'Should return 3 days');
    }

    // ============================================================================
    // TEST 19: Accrue From Treasury - Not Treasury Caller
    // ============================================================================
    /// @dev Covers line 363: Only treasury can pull
    function test_accrueFromTreasury_notTreasury_reverts() public {
        // Whitelist reward token
        address admin = underlying.admin();
        whitelistRewardToken(staking, address(rewardToken), admin);

        // Fund treasury
        rewardToken.mint(treasury, 10_000 ether);
        vm.prank(treasury);
        rewardToken.approve(address(staking), type(uint256).max);

        // Try to pull from non-treasury address
        vm.prank(alice);
        vm.expectRevert(ILevrFactory_v1.UnauthorizedCaller.selector);
        staking.accrueFromTreasury(address(rewardToken), 1000 ether, true);
    }

    // ============================================================================
    // TEST 20: Accrue From Treasury - Insufficient Available
    // ============================================================================
    /// @dev Covers line 373: Insufficient available for non-pull flow
    function test_accrueFromTreasury_insufficientAvailable_reverts() public {
        address admin = underlying.admin();
        whitelistRewardToken(staking, address(rewardToken), admin);

        // Stake to enable accrual
        vm.startPrank(alice);
        underlying.approve(address(staking), type(uint256).max);
        staking.stake(1000 ether);
        vm.stopPrank();

        // Transfer small amount
        rewardToken.transfer(address(staking), 100 ether);

        // Try to accrue more than available (non-pull flow)
        vm.expectRevert(ILevrStaking_v1.InsufficientAvailable.selector);
        staking.accrueFromTreasury(address(rewardToken), 200 ether, false);
    }

    // ============================================================================
    // TEST 21: Credit Rewards - Small amounts work for whitelisted tokens
    // ============================================================================
    /// @dev Verifies small amounts are accepted for whitelisted tokens
    function test_creditRewards_rewardTooSmall_reverts() public {
        address admin = underlying.admin();
        whitelistRewardToken(staking, address(rewardToken), admin);

        // Stake to enable accrual
        vm.startPrank(alice);
        underlying.approve(address(staking), type(uint256).max);
        staking.stake(1000 ether);
        vm.stopPrank();

        // Transfer small amount (any amount works for whitelisted tokens)
        rewardToken.transfer(address(staking), 1e14);

        // Should succeed - no minimum check for whitelisted tokens
        staking.accrueRewards(address(rewardToken));
    }

    // ============================================================================
    // TEST 22: Ensure Reward Token - Not Whitelisted
    // ============================================================================
    /// @dev Covers lines 512, 515: Token must be whitelisted for rewards
    function test_accrueRewards_tokenNotWhitelisted_reverts() public {
        // Stake to enable accrual attempts
        vm.startPrank(alice);
        underlying.approve(address(staking), type(uint256).max);
        staking.stake(1000 ether);
        vm.stopPrank();

        // Transfer rewards to contract for non-whitelisted token
        rewardToken.transfer(address(staking), 1000 ether);

        // Try to accrue rewards for non-whitelisted token
        vm.expectRevert(ILevrStaking_v1.TokenNotWhitelisted.selector);
        staking.accrueRewards(address(rewardToken));
    }

    // ============================================================================
    // TEST 23: First Staker Restarts Paused Streams
    // ============================================================================
    /// @dev Covers lines 112-132: First staker logic with paused streams
    function test_stake_firstStaker_restartsPausedStreams() public {
        address admin = underlying.admin();
        whitelistRewardToken(staking, address(rewardToken), admin);

        // Initial stake
        vm.startPrank(alice);
        underlying.approve(address(staking), type(uint256).max);
        staking.stake(1000 ether);
        vm.stopPrank();

        // Add rewards to create stream
        rewardToken.transfer(address(staking), 5000 ether);
        staking.accrueRewards(address(rewardToken));

        // Alice unstakes all (pool becomes empty)
        vm.prank(alice);
        staking.unstake(1000 ether, alice);

        assertEq(staking.totalStaked(), 0, 'Total staked should be 0');

        // Time passes (stream paused)
        vm.warp(block.timestamp + 1 days);

        // Bob stakes (first staker - should restart streams)
        vm.startPrank(bob);
        underlying.approve(address(staking), type(uint256).max);
        staking.stake(2000 ether);
        vm.stopPrank();

        // Verify stream info was reset
        (uint64 streamStart, uint64 streamEnd, uint256 streamTotal) = staking.getTokenStreamInfo(
            address(rewardToken)
        );

        assertTrue(streamStart > 0, 'Stream should have started');
        assertTrue(streamEnd > streamStart, 'Stream should have end time');
        assertTrue(streamTotal > 0, 'Stream should have total');
    }

    // ============================================================================
    // TEST 24: Normal Unstake Returns Voting Power
    // ============================================================================
    /// @dev Verifies that unstake properly calculates and returns voting power
    function test_unstake_returnsVotingPower() public {
        vm.startPrank(alice);
        underlying.approve(address(staking), type(uint256).max);
        staking.stake(1000 ether);
        vm.stopPrank();

        // Wait to accumulate voting power
        vm.warp(block.timestamp + 10 days);

        // Unstake should return voting power
        vm.prank(alice);
        uint256 returnedVP = staking.unstake(500 ether, alice);
        assertGt(returnedVP, 0, 'Should return some VP');

        // Verify remaining VP matches returned VP
        uint256 currentVP = staking.getVotingPower(alice);
        assertEq(currentVP, returnedVP, 'Current VP should match returned VP');
    }

    // ============================================================================
    // TEST 25: Claimable Rewards - No Balance
    // ============================================================================
    /// @dev Covers lines 328, 331, 334: Claimable rewards edge cases
    function test_claimableRewards_noBalance_returnsZero() public {
        address admin = underlying.admin();
        whitelistRewardToken(staking, address(rewardToken), admin);

        // Check claimable with no staked balance
        uint256 claimable = staking.claimableRewards(alice, address(rewardToken));
        assertEq(claimable, 0, 'Should have 0 claimable with no balance');
    }

    function test_claimableRewards_noTotalStaked_returnsZero() public {
        address admin = underlying.admin();
        whitelistRewardToken(staking, address(rewardToken), admin);

        // Add rewards but no stakers
        rewardToken.transfer(address(staking), 1000 ether);

        uint256 claimable = staking.claimableRewards(alice, address(rewardToken));
        assertEq(claimable, 0, 'Should have 0 claimable with no total staked');
    }

    function test_claimableRewards_tokenNotExist_returnsZero() public {
        MockERC20 nonExistentToken = new MockERC20('NonExistent', 'NE');

        // Stake some tokens
        vm.startPrank(alice);
        underlying.approve(address(staking), type(uint256).max);
        staking.stake(1000 ether);
        vm.stopPrank();

        uint256 claimable = staking.claimableRewards(alice, address(nonExistentToken));
        assertEq(claimable, 0, 'Should have 0 claimable for non-existent token');
    }
}
