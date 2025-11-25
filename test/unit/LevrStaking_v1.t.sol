// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from 'forge-std/Test.sol';
import {LevrStaking_v1} from '../../src/LevrStaking_v1.sol';
import {LevrStakedToken_v1} from '../../src/LevrStakedToken_v1.sol';
import {ILevrFactory_v1} from '../../src/interfaces/ILevrFactory_v1.sol';
import {ILevrStaking_v1} from '../../src/interfaces/ILevrStaking_v1.sol';
import {ERC20_Mock} from '../mocks/ERC20_Mock.sol';
import {FeeOnTransferToken_Mock} from '../mocks/FeeOnTransferToken_Mock.sol';
import {LevrFactoryDeployHelper} from '../utils/LevrFactoryDeployHelper.sol';
import {LevrStaking_v1_Exposed} from '../mocks/LevrStaking_v1_Exposed.sol';

contract LevrStaking_v1_Test is Test, LevrFactoryDeployHelper {
    struct FeeOnTransferEnv {
        LevrStaking_v1 staking;
        LevrStakedToken_v1 sToken;
        FeeOnTransferToken_Mock token;
    }
    ERC20_Mock internal _underlying;
    LevrStakedToken_v1 internal _sToken;
    LevrStaking_v1 internal _staking;
    LevrStaking_v1_Exposed internal _stakingExposed;
    address internal _treasury = address(0xBEEF);
    address internal _user = address(0xAAAA);
    address internal _admin = address(0xAD);

    function setUp() public {
        _underlying = new ERC20_Mock('Token', 'TKN');

        // Deploy normal staking for external tests
        _staking = createStaking(address(0), address(this)); // Mock forwarder as 0
        _sToken = createStakedToken(
            'Staked Token',
            'sTKN',
            18,
            address(_underlying),
            address(_staking)
        );

        initializeStakingWithRewardTokens(
            _staking,
            address(_underlying),
            address(_sToken),
            _treasury,
            new address[](0)
        );

        // Deploy exposed staking for internal tests
        _stakingExposed = new LevrStaking_v1_Exposed(address(this), address(0));
        _stakingExposed.initialize(
            address(_underlying),
            address(_sToken), // Reuse sToken or mock if needed, strict isolation might need new one
            _treasury,
            new address[](0)
        );

        // Fund user
        _underlying.mint(_user, 1_000_000 ether);
        _underlying.mint(address(this), 1_000_000 ether);
    }

    ///////////////////////////////////////////////////////////////////////////
    // Test Initialization

    /* Test: constructor */
    function test_Constructor_SetsFactory() public {
        LevrStaking_v1 s = new LevrStaking_v1(address(this), address(0));
        assertEq(s.factory(), address(this));
    }

    function test_Constructor_RevertIf_FactoryZero() public {
        vm.expectRevert(ILevrStaking_v1.ZeroAddress.selector);
        new LevrStaking_v1(address(0), address(0));
    }

    /* Test: initialize */
    function test_Initialize_SetsStateCorrectly() public {
        LevrStaking_v1 s = new LevrStaking_v1(address(this), address(0));
        address[] memory tokens = new address[](0);

        s.initialize(address(_underlying), address(_sToken), _treasury, tokens);

        assertEq(s.underlying(), address(_underlying));
        assertEq(s.stakedToken(), address(_sToken));
        assertEq(s.treasury(), _treasury);
    }

    function test_Initialize_RevertIf_AlreadyInitialized() public {
        vm.expectRevert(ILevrStaking_v1.AlreadyInitialized.selector);
        _staking.initialize(address(_underlying), address(_sToken), _treasury, new address[](0));
    }

    function test_Initialize_RevertIf_ZeroAddresses() public {
        LevrStaking_v1 s = new LevrStaking_v1(address(this), address(0));

        vm.expectRevert(ILevrStaking_v1.ZeroAddress.selector);
        s.initialize(address(0), address(_sToken), _treasury, new address[](0));

        vm.expectRevert(ILevrStaking_v1.ZeroAddress.selector);
        s.initialize(address(_underlying), address(0), _treasury, new address[](0));

        vm.expectRevert(ILevrStaking_v1.ZeroAddress.selector);
        s.initialize(address(_underlying), address(_sToken), address(0), new address[](0));
    }

    ///////////////////////////////////////////////////////////////////////////
    // Test Modifiers

    // Note: Modifiers like nonReentrant are tested implicitly via reentrancy attacks
    // or explicit reentrancy mocks if needed. For now we focus on logic.

    ///////////////////////////////////////////////////////////////////////////
    // Test External Functions

    // ========================================================================
    // External - View Functions

    /* Test: getVotingPower */

    function test_GetVotingPower_ReturnsZeroWhenUserHasNoStake() public {
        vm.roll(block.number + 1); // advance block so function is not view-only
        assertEq(_staking.getVotingPower(_user), 0);
    }

    function test_GetVotingPower_AccumulatesLinearlyWithTime() public {
        uint256 amount = 100 ether;

        vm.startPrank(_user);
        _underlying.approve(address(_staking), amount);
        _staking.stake(amount);
        vm.stopPrank();

        vm.warp(block.timestamp + 10 days);

        uint256 expected = (amount * 10 days) / (_staking.PRECISION() * _staking.SECONDS_PER_DAY());

        assertEq(_staking.getVotingPower(_user), expected);
    }

    /* Test: getTokenStreamInfo */

    function test_GetTokenStreamInfo_ReturnsLatestStreamState() public {
        ERC20_Mock rewardToken = new ERC20_Mock('Reward', 'RWD');
        whitelistRewardToken(_staking, address(rewardToken), address(this));

        uint32 window = uint32(3 days);
        uint256 rewardAmount = uint256(window) * 2 ether;
        rewardToken.mint(address(_staking), rewardAmount);

        uint256 accrueTime = block.timestamp;
        _staking.accrueRewards(address(rewardToken));
        (uint64 streamStart, uint64 streamEnd, uint256 streamTotal) = _staking.getTokenStreamInfo(
            address(rewardToken)
        );

        assertEq(streamStart, uint64(accrueTime));
        assertEq(streamEnd - streamStart, window);
        assertEq(streamTotal, rewardAmount);
    }

    /* Test: getWhitelistedTokens */

    function test_GetWhitelistedTokens_ReturnsActiveList() public {
        ERC20_Mock rewardToken = new ERC20_Mock('Reward', 'RWD');
        whitelistRewardToken(_staking, address(rewardToken), address(this));

        address[] memory tokens = _staking.getWhitelistedTokens();

        assertEq(tokens.length, 2);
        assertEq(tokens[0], address(_underlying));
        assertEq(tokens[1], address(rewardToken));
    }

    /* Test: rewardRatePerSecond */

    function test_RewardRatePerSecond_MatchesStreamAmount() public {
        ERC20_Mock rewardToken = new ERC20_Mock('Reward', 'RWD');
        whitelistRewardToken(_staking, address(rewardToken), address(this));

        uint32 window = uint32(3 days);
        uint256 rewardAmount = uint256(window) * 5 ether;
        rewardToken.mint(address(_staking), rewardAmount);

        _staking.accrueRewards(address(rewardToken));

        uint256 expectedRate = rewardAmount / window;
        assertEq(_staking.rewardRatePerSecond(address(rewardToken)), expectedRate);
    }

    /* Test: aprBps */

    function test_AprBps_ComputesAnnualizedRate() public {
        uint256 stakeAmount = 1_000_000 ether;

        vm.startPrank(_user);
        _underlying.approve(address(_staking), stakeAmount);
        _staking.stake(stakeAmount);
        vm.stopPrank();

        ERC20_Mock rewardToken = new ERC20_Mock('Reward', 'RWD');
        whitelistRewardToken(_staking, address(rewardToken), address(this));

        uint32 window = uint32(3 days);
        uint256 rewardAmount = uint256(window) * 1 ether;
        rewardToken.mint(address(_staking), rewardAmount);
        _staking.accrueRewards(address(rewardToken));

        uint256 perSecond = rewardAmount / window;
        uint256 annualRate = perSecond * 365 days;
        uint256 expectedApr = (annualRate * 10_000) / stakeAmount;

        assertEq(_staking.aprBps(), expectedApr);
    }

    // ========================================================================
    // External - Staking Actions

    /* Test: stake */

    function test_Stake_RevertIf_AmountZero() public {
        vm.prank(_user);
        vm.expectRevert(ILevrStaking_v1.InvalidAmount.selector);
        _staking.stake(0);
    }

    function test_Stake_Success_MintsStakedTokens() public {
        uint256 amount = 100 ether;

        vm.startPrank(_user);
        _underlying.approve(address(_staking), amount);

        vm.expectEmit(true, true, false, true);
        emit ILevrStaking_v1.Staked(_user, amount);

        _staking.stake(amount);
        vm.stopPrank();

        assertEq(_sToken.balanceOf(_user), amount);
        assertEq(_staking.totalStaked(), amount);
        assertEq(_staking.escrowBalance(address(_underlying)), amount);
    }

    function test_Stake_UpdatesVotingPower_WeightedAverage() public {
        uint256 amount1 = 100 ether;
        uint256 amount2 = 100 ether;

        vm.startPrank(_user);
        _underlying.approve(address(_staking), amount1 + amount2);

        // Stake 1
        _staking.stake(amount1);
        uint256 startTime1 = _staking.stakeStartTime(_user);
        assertEq(startTime1, block.timestamp);

        // Warp 10 days
        vm.warp(block.timestamp + 10 days);

        // Stake 2
        _staking.stake(amount2);
        uint256 startTime2 = _staking.stakeStartTime(_user);

        // Weighted average check
        // Time1 = 10 days * 100 = 1000
        // Total = 200
        // NewTimeAccumulated = 1000 / 200 = 5 days
        // StartTime should be Now - 5 days
        assertEq(startTime2, block.timestamp - 5 days);

        vm.stopPrank();
    }

    function test_Stake_CollectsProtocolFee() public {
        // Setup fee config
        uint16 feeBps = 500; // 5%
        address feeRecipient = address(0xFEE);
        _setMockProtocolFee(feeBps, feeRecipient);

        uint256 amount = 100 ether;
        uint256 fee = (amount * feeBps) / 10000;
        uint256 net = amount - fee;

        vm.startPrank(_user);
        _underlying.approve(address(_staking), amount);
        _staking.stake(amount);
        vm.stopPrank();

        assertEq(_underlying.balanceOf(feeRecipient), fee, 'Fee collected');
        assertEq(_sToken.balanceOf(_user), net, 'Net amount staked');
        assertEq(_staking.totalStaked(), net);
    }

    /* Test: unstake */

    function test_Unstake_RevertIf_AmountZero() public {
        vm.prank(_user);
        vm.expectRevert(ILevrStaking_v1.InvalidAmount.selector);
        _staking.unstake(0, _user);
    }

    function test_Unstake_RevertIf_ZeroRecipient() public {
        vm.prank(_user);
        vm.expectRevert(ILevrStaking_v1.ZeroAddress.selector);
        _staking.unstake(100, address(0));
    }

    function test_Unstake_RevertIf_InsufficientStake() public {
        vm.startPrank(_user);
        _underlying.approve(address(_staking), 100 ether);
        _staking.stake(100 ether);

        vm.expectRevert(ILevrStaking_v1.InsufficientStake.selector);
        _staking.unstake(101 ether, _user);
        vm.stopPrank();
    }

    function test_Unstake_Success_BurnsTokensAndReturnsUnderlying() public {
        uint256 amount = 100 ether;

        vm.startPrank(_user);
        _underlying.approve(address(_staking), amount);
        _staking.stake(amount);

        uint256 balBefore = _underlying.balanceOf(_user);
        _staking.unstake(amount, _user);
        uint256 balAfter = _underlying.balanceOf(_user);

        vm.stopPrank();

        assertEq(balAfter - balBefore, amount);
        assertEq(_sToken.balanceOf(_user), 0);
        assertEq(_staking.totalStaked(), 0);
    }

    function test_Unstake_Partial_ReducesVotingPowerProportionally() public {
        uint256 amount = 100 ether;

        vm.startPrank(_user);
        _underlying.approve(address(_staking), amount);
        _staking.stake(amount);

        vm.warp(block.timestamp + 100 days);

        // VP before: 100 * 100 = 10000 units
        uint256 vpBefore = _staking.getVotingPower(_user);

        // Unstake 50%
        _staking.unstake(50 ether, _user);

        uint256 vpAfter = _staking.getVotingPower(_user);

        // VP should be quartered (50% balance * 50% time)
        // Tolerance for rounding
        assertApproxEqRel(vpAfter, vpBefore / 4, 1e14); // 0.01% tolerance

        vm.stopPrank();
    }

    function test_Stake_FeeOnTransferToken_Mock_MintsActualReceived() public {
        FeeOnTransferEnv memory env = _setupFeeOnTransferEnv();
        uint256 amount = 100 ether;

        vm.prank(_user);
        env.staking.stake(amount);

        uint256 expectedReceived = amount - ((amount * env.token.feeBps()) / 10_000);

        assertEq(env.sToken.balanceOf(_user), expectedReceived, 'Shares should match net transfer');
        assertEq(env.staking.totalStaked(), expectedReceived, 'totalStaked tracks actual received');
        assertEq(
            env.staking.escrowBalance(address(env.token)),
            expectedReceived,
            'Escrow tracks actual received'
        );
    }

    function test_Unstake_FeeOnTransferToken_Mock_DoesNotLeaveShortfall() public {
        FeeOnTransferEnv memory env = _setupFeeOnTransferEnv();

        vm.prank(_user);
        env.staking.stake(100 ether);
        uint256 minted = env.sToken.balanceOf(_user);

        vm.prank(_user);
        env.staking.unstake(minted, _user);

        assertEq(env.staking.escrowBalance(address(env.token)), 0, 'Escrow drains fully');
        assertEq(env.sToken.balanceOf(_user), 0, 'All shares burned');
    }

    // ============ External - Rewards ============

    /* Test: claimRewards */

    function test_ClaimRewards_RevertIf_ZeroRecipient() public {
        vm.prank(_user);
        address[] memory tokens = new address[](0);
        vm.expectRevert(ILevrStaking_v1.ZeroAddress.selector);
        _staking.claimRewards(tokens, address(0));
    }

    function test_ClaimRewards_Success_DistributesRewards() public {
        // Setup reward token
        ERC20_Mock rewardToken = new ERC20_Mock('Reward', 'RWD');
        whitelistRewardToken(_staking, address(rewardToken), address(this));

        // Stake
        vm.startPrank(_user);
        _underlying.approve(address(_staking), 100 ether);
        _staking.stake(100 ether);
        vm.stopPrank();

        // Fund rewards
        rewardToken.mint(address(_staking), 1000 ether);
        _staking.accrueRewards(address(rewardToken));

        // Time passes (50% of window)
        vm.warp(block.timestamp + 1.5 days); // Default window 3 days

        // Claim
        address[] memory tokens = new address[](1);
        tokens[0] = address(rewardToken);

        vm.prank(_user);
        _staking.claimRewards(tokens, _user);

        uint256 claimed = rewardToken.balanceOf(_user);
        assertApproxEqRel(claimed, 500 ether, 1e16); // ~50%
    }

    /* Test: accrueRewards */

    function test_AccrueRewards_RevertIf_TokenNotWhitelisted() public {
        ERC20_Mock random = new ERC20_Mock('Random', 'RND');
        random.mint(address(_staking), 1000 ether);

        vm.expectRevert(ILevrStaking_v1.TokenNotWhitelisted.selector);
        _staking.accrueRewards(address(random));
    }

    function test_AccrueRewards_RevertIf_RewardTooSmall() public {
        ERC20_Mock rewardToken = new ERC20_Mock('Reward', 'RWD');
        whitelistRewardToken(_staking, address(rewardToken), address(this));

        rewardToken.mint(address(_staking), 1); // Too small

        vm.expectRevert(ILevrStaking_v1.RewardTooSmall.selector);
        _staking.accrueRewards(address(rewardToken));
    }

    function test_AccrueRewards_AllowsOnceBalanceMeetsMinimum() public {
        ERC20_Mock rewardToken = new ERC20_Mock('Reward', 'RWD');
        whitelistRewardToken(_staking, address(rewardToken), address(this));

        uint256 minAmount = _staking.MIN_REWARD_AMOUNT();

        rewardToken.mint(address(_staking), minAmount - 1);
        vm.expectRevert(ILevrStaking_v1.RewardTooSmall.selector);
        _staking.accrueRewards(address(rewardToken));

        rewardToken.mint(address(_staking), 1);
        _staking.accrueRewards(address(rewardToken));

        (, , uint256 streamTotal) = _staking.getTokenStreamInfo(address(rewardToken));
        assertEq(streamTotal, minAmount, 'Stream should equal accumulated threshold');
    }

    function test_FeeOnTransferToken_Mock_RewardsRemainClaimable() public {
        FeeOnTransferEnv memory env = _setupFeeOnTransferEnv();

        vm.prank(_user);
        env.staking.stake(100 ether);

        ERC20_Mock rewardToken = new ERC20_Mock('Reward', 'RWD');
        whitelistRewardToken(env.staking, address(rewardToken), address(this));

        rewardToken.mint(address(env.staking), 10 ether);
        env.staking.accrueRewards(address(rewardToken));

        vm.warp(block.timestamp + 3 days + 1);

        address[] memory tokens = new address[](1);
        tokens[0] = address(rewardToken);

        vm.prank(_user);
        env.staking.claimRewards(tokens, _user);

        assertGt(rewardToken.balanceOf(_user), 0, 'Rewards should be claimable');
    }

    // ============ External - Admin ============

    /* Test: whitelistToken */

    function test_WhitelistToken_RevertIf_ZeroAddress() public {
        vm.expectRevert(ILevrStaking_v1.ZeroAddress.selector);
        _staking.whitelistToken(address(0));
    }

    function test_WhitelistToken_RevertIf_Underlying() public {
        vm.expectRevert(ILevrStaking_v1.CannotModifyUnderlying.selector);
        _staking.whitelistToken(address(_underlying));
    }

    function test_WhitelistToken_RevertIf_NotTokenAdmin() public {
        ERC20_Mock rewardToken = new ERC20_Mock('Reward', 'RWD');

        vm.prank(_user);
        vm.expectRevert(ILevrStaking_v1.OnlyTokenAdmin.selector);
        _staking.whitelistToken(address(rewardToken));
    }

    function test_WhitelistToken_RevertIf_AlreadyWhitelisted() public {
        ERC20_Mock rewardToken = new ERC20_Mock('Reward', 'RWD');
        whitelistRewardToken(_staking, address(rewardToken), address(this));

        vm.expectRevert(ILevrStaking_v1.AlreadyWhitelisted.selector);
        _staking.whitelistToken(address(rewardToken));
    }

    function test_WhitelistToken_ReWhitelistAfterRewardsClaimed_Succeeds() public {
        ERC20_Mock rewardToken = new ERC20_Mock('Reward', 'RWD');
        whitelistRewardToken(_staking, address(rewardToken), address(this));

        vm.startPrank(_user);
        _underlying.approve(address(_staking), type(uint256).max);
        _staking.stake(1_000 ether);
        vm.stopPrank();

        rewardToken.mint(address(_staking), 1_000 ether);
        _staking.accrueRewards(address(rewardToken));

        vm.warp(block.timestamp + 3 days + 1);

        address[] memory tokens = new address[](1);
        tokens[0] = address(rewardToken);
        vm.prank(_user);
        _staking.claimRewards(tokens, _user);

        _staking.unwhitelistToken(address(rewardToken));

        _staking.whitelistToken(address(rewardToken));
        assertTrue(
            _staking.isTokenWhitelisted(address(rewardToken)),
            'Token should be re-whitelisted'
        );
    }

    /* Test: unwhitelistToken */

    function test_UnwhitelistToken_Success() public {
        ERC20_Mock rewardToken = new ERC20_Mock('Reward', 'RWD');
        whitelistRewardToken(_staking, address(rewardToken), address(this));

        assertTrue(_staking.isTokenWhitelisted(address(rewardToken)));

        _staking.unwhitelistToken(address(rewardToken));

        assertFalse(_staking.isTokenWhitelisted(address(rewardToken)));
    }

    function test_UnwhitelistToken_RevertIf_NotTokenAdmin() public {
        ERC20_Mock rewardToken = new ERC20_Mock('Reward', 'RWD');
        whitelistRewardToken(_staking, address(rewardToken), address(this));

        vm.prank(_user);
        vm.expectRevert(ILevrStaking_v1.OnlyTokenAdmin.selector);
        _staking.unwhitelistToken(address(rewardToken));
    }

    function test_UnwhitelistToken_RevertIf_Underlying() public {
        vm.expectRevert(ILevrStaking_v1.CannotUnwhitelistUnderlying.selector);
        _staking.unwhitelistToken(address(_underlying));
    }

    function test_UnwhitelistToken_RevertIf_PendingRewards() public {
        ERC20_Mock rewardToken = new ERC20_Mock('Reward', 'RWD');
        whitelistRewardToken(_staking, address(rewardToken), address(this));

        rewardToken.mint(address(_staking), 100 ether);
        _staking.accrueRewards(address(rewardToken));

        vm.expectRevert(ILevrStaking_v1.CannotUnwhitelistWithPendingRewards.selector);
        _staking.unwhitelistToken(address(rewardToken));
    }

    function test_UnwhitelistToken_RevertIf_NotRegistered() public {
        ERC20_Mock newToken = new ERC20_Mock('New', 'NEW');

        vm.expectRevert(ILevrStaking_v1.TokenNotRegistered.selector);
        _staking.unwhitelistToken(address(newToken));
    }

    /* Test: cleanupFinishedRewardToken */

    function test_CleanupFinishedRewardToken_RevertIf_Underlying() public {
        vm.expectRevert(ILevrStaking_v1.CannotRemoveUnderlying.selector);
        _staking.cleanupFinishedRewardToken(address(_underlying));
    }

    function test_CleanupFinishedRewardToken_RevertIf_NotRegistered() public {
        ERC20_Mock newToken = new ERC20_Mock('New', 'NEW');
        vm.expectRevert(ILevrStaking_v1.TokenNotRegistered.selector);
        _staking.cleanupFinishedRewardToken(address(newToken));
    }

    function test_CleanupFinishedRewardToken_RevertIf_StillWhitelisted() public {
        ERC20_Mock rewardToken = new ERC20_Mock('Reward', 'RWD');
        whitelistRewardToken(_staking, address(rewardToken), address(this));

        vm.expectRevert(ILevrStaking_v1.CannotRemoveWhitelisted.selector);
        _staking.cleanupFinishedRewardToken(address(rewardToken));
    }

    function test_CleanupFinishedRewardToken_Success() public {
        ERC20_Mock rewardToken = new ERC20_Mock('Reward', 'RWD');
        whitelistRewardToken(_staking, address(rewardToken), address(this));

        _staking.unwhitelistToken(address(rewardToken));

        vm.expectEmit(true, false, false, false);
        emit ILevrStaking_v1.RewardTokenRemoved(address(rewardToken));
        _staking.cleanupFinishedRewardToken(address(rewardToken));

        vm.expectRevert(ILevrStaking_v1.TokenNotRegistered.selector);
        _staking.cleanupFinishedRewardToken(address(rewardToken));
    }

    ///////////////////////////////////////////////////////////////////////////
    // Test Internal Functions

    // Note: Using exposed contract _stakingExposed

    /* Test: _onStakeNewTimestamp */

    function test_Internal_OnStakeNewTimestamp_FirstStake() public {
        vm.startPrank(_user);
        // No previous stake
        uint256 ts = _stakingExposed.exposed_onStakeNewTimestamp(100 ether);
        assertEq(ts, block.timestamp);
        vm.stopPrank();
    }

    /* Test: _availableUnaccountedRewards */

    function test_Internal_AvailableUnaccountedRewards_CalculatesCorrectly() public {
        ERC20_Mock rewardToken = new ERC20_Mock('Reward', 'RWD');
        whitelistRewardToken(_stakingExposed, address(rewardToken), address(this));

        rewardToken.mint(address(_stakingExposed), 1000 ether);

        uint256 available = _stakingExposed.exposed_availableUnaccountedRewards(
            address(rewardToken)
        );
        assertEq(available, 1000 ether);
    }

    ///////////////////////////////////////////////////////////////////////////
    // Helper Functions

    function _setupFeeOnTransferEnv() internal returns (FeeOnTransferEnv memory env) {
        env.token = new FeeOnTransferToken_Mock('Fee Token', 'FEE', 100);
        env.staking = createStaking(address(0), address(this));
        env.sToken = createStakedToken(
            'Fee Staked Token',
            'sFEE',
            18,
            address(env.token),
            address(env.staking)
        );

        initializeStakingWithRewardTokens(
            env.staking,
            address(env.token),
            address(env.sToken),
            _treasury,
            new address[](0)
        );

        env.token.mint(_user, 1_000 ether);
        env.token.mint(address(this), 1_000 ether);

        vm.prank(_user);
        env.token.approve(address(env.staking), type(uint256).max);

        return env;
    }

    // Mock override for abstract/virtual functions if needed
    function streamWindowSeconds(address) external pure returns (uint32) {
        return 3 days;
    }

    function clankerFactory() external pure returns (address) {
        return address(0);
    }
}
