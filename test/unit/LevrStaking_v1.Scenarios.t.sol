// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from 'forge-std/Test.sol';
import {LevrStaking_v1} from '../../src/LevrStaking_v1.sol';
import {LevrStakedToken_v1} from '../../src/LevrStakedToken_v1.sol';
import {ILevrStaking_v1} from '../../src/interfaces/ILevrStaking_v1.sol';
import {ERC20_Mock} from '../mocks/ERC20_Mock.sol';
import {LevrFactoryDeployHelper} from '../utils/LevrFactoryDeployHelper.sol';

contract LevrStaking_v1_Scenarios_Test is Test, LevrFactoryDeployHelper {
    ERC20_Mock internal underlying;
    LevrStakedToken_v1 internal sToken;
    LevrStaking_v1 internal staking;
    address internal treasury = address(0xBEEF);
    address internal alice = makeAddr('alice');
    address internal bob = makeAddr('bob');

    function setUp() public {
        underlying = new ERC20_Mock('Token', 'TKN');
        _setMockProtocolFee(0, address(0));

        staking = createStaking(address(0), address(this));
        sToken = createStakedToken(
            'Staked Token',
            'sTKN',
            18,
            address(underlying),
            address(staking)
        );

        initializeStakingWithRewardTokens(
            staking,
            address(underlying),
            address(sToken),
            treasury,
            new address[](0)
        );

        underlying.mint(address(this), 1_000_000 ether);
    }

    // Helper to mock factory behavior for protocol fee
    // LevrFactoryDeployHelper provides _setMockProtocolFee, but we need to ensure LevrStaking calls our helper or a mocked factory.
    // In `LevrFactoryDeployHelper`, `createStaking` deploys a new Staking contract.
    // The Staking contract calls `factory.protocolFeeBps()`.
    // `LevrFactoryDeployHelper` is the factory in this setup (passed as address(this) to createStaking).
    // It implements `protocolFeeBps()` and `protocolTreasury()`.

    function test_Scenario_MicroStakeRounding_RequiresManyTx() public {
        address feeRecipient = address(0xFEE0);
        uint16 feeBps = 100; // 1%
        _setMockProtocolFee(feeBps, feeRecipient);

        address attacker = address(0x1234);
        uint256 microAmount = 99; // amount below threshold for charging a 1% fee
        uint256 iterations = 40;
        uint256 aggregated = microAmount * iterations;

        underlying.mint(attacker, aggregated);
        vm.startPrank(attacker);
        underlying.approve(address(staking), type(uint256).max);
        for (uint256 i = 0; i < iterations; i++) {
            staking.stake(microAmount);
        }
        vm.stopPrank();

        // Verify fee avoidance (rounding down to 0)
        assertEq(underlying.balanceOf(feeRecipient), 0, 'Micro stakes avoid protocol fee');

        // Verify position accumulated
        assertEq(sToken.balanceOf(attacker), aggregated);
    }

    function test_Scenario_TimestampManipulation_NoImpact() public {
        underlying.approve(address(staking), 1000 ether);
        staking.stake(1000 ether);

        // Normal: Wait 1 day
        vm.warp(block.timestamp + 1 days);
        uint256 vpNormal = staking.getVotingPower(address(this));

        // Manipulated: Add 15 seconds (max miner manipulation)
        // Note: To test exact impact, we'd need parallel universe or reset.
        // Here we just check that small manipulation is negligible.

        // VP = (balance * time) / constant
        // 1000 * 86415 vs 1000 * 86400
        // The calculation in contract uses (balance * time) / (PRECISION * SECONDS_PER_DAY)
        // PRECISION = 1e18.
        // 1000 ether * 15 seconds = 1000e18 * 15.
        // Div by 1e18 * 86400 = (1000 * 15) / 86400 = 0.17.
        // Integer division results in 0 change.

        // Let's reset and retry with manipulation
        // We can't easily reset in same test without snapshot.
        // But we can calculate expected VP.

        assertEq(vpNormal, 1000, 'VP should be 1000 token-days');

        // Check if adding 15 seconds changes it
        vm.warp(block.timestamp + 15);
        uint256 vpManipulated = staking.getVotingPower(address(this));

        assertEq(vpManipulated, vpNormal, '15s manipulation has no impact due to precision');
    }

    function test_Scenario_FlashLoan_ZeroVotingPower() public {
        uint256 flashLoanAmount = 1_000_000 ether;
        underlying.mint(address(this), flashLoanAmount);
        underlying.approve(address(staking), flashLoanAmount);

        staking.stake(flashLoanAmount);

        // Check VP immediately
        uint256 vpSameBlock = staking.getVotingPower(address(this));
        assertEq(vpSameBlock, 0, 'Flash loan VP should be 0');

        vm.warp(block.timestamp + 1);
        uint256 vpAfter1Sec = staking.getVotingPower(address(this));
        assertLt(vpAfter1Sec, 100, 'VP after 1 sec should be negligible');
    }

    function test_Scenario_WeightedAverage_PreventsLateWhale() public {
        address earlyStaker = address(0xEAE1);
        address lateWhale = address(0xCA7E);

        underlying.mint(earlyStaker, 100 ether);
        underlying.mint(lateWhale, 10_000 ether);

        // Early staker: 100 tokens for 365 days
        vm.startPrank(earlyStaker);
        underlying.approve(address(staking), 100 ether);
        staking.stake(100 ether);
        vm.stopPrank();

        vm.warp(block.timestamp + 365 days);

        uint256 earlyVP = staking.getVotingPower(earlyStaker);
        assertEq(earlyVP, 100 * 365, 'Early staker VP');

        // Late whale stakes 100x more
        vm.startPrank(lateWhale);
        underlying.approve(address(staking), 10_000 ether);
        staking.stake(10_000 ether);
        vm.stopPrank();

        uint256 whaleVP = staking.getVotingPower(lateWhale);
        assertEq(whaleVP, 0, 'Whale VP 0 initially');

        vm.warp(block.timestamp + 1 days);
        uint256 whaleVP1Day = staking.getVotingPower(lateWhale);

        // Whale: 10,000 * 1 = 10,000
        // Early: 100 * 366 = 36,600
        assertLt(whaleVP1Day, earlyVP, 'Whale needs time to catch up');
    }

    function test_Scenario_LastStakerExit_PreservesFrozenRewards() public {
        ERC20_Mock rewardToken = _createRewardToken('Reward', 'RWD');

        _stake(alice, 1_000 ether);

        rewardToken.mint(address(staking), 1_000 ether);
        staking.accrueRewards(address(rewardToken));

        vm.warp(block.timestamp + 1 days);

        uint256 aliceRewardBefore = rewardToken.balanceOf(alice);
        vm.prank(alice);
        staking.unstake(1_000 ether, alice);
        uint256 aliceClaimed = rewardToken.balanceOf(alice) - aliceRewardBefore;

        uint256 frozenRewards = staking.outstandingRewards(address(rewardToken));

        vm.warp(block.timestamp + 2 days);
        assertApproxEqRel(
            staking.outstandingRewards(address(rewardToken)),
            frozenRewards,
            1e16,
            'Frozen rewards should not vest without stakers'
        );

        _stake(bob, 500 ether);

        vm.warp(block.timestamp + 7 days + 1);
        uint256 bobClaimed = _claimRewards(bob, address(rewardToken));

        uint256 unvested = 1_000 ether - aliceClaimed;
        assertApproxEqRel(bobClaimed, unvested, 2e16, 'Bob receives frozen rewards');
    }

    function test_Scenario_FirstStakerAfterGap_OnlyClaimsNewRewards() public {
        ERC20_Mock rewardToken = _createRewardToken('Reward', 'RWD');
        _stake(alice, 1_000 ether);

        rewardToken.mint(address(staking), 1_000 ether);
        staking.accrueRewards(address(rewardToken));

        vm.warp(block.timestamp + 1 days);
        vm.prank(alice);
        staking.unstake(1_000 ether, alice); // pauses stream

        _stake(bob, 500 ether);
        vm.warp(block.timestamp + 7 days + 1);
        _claimRewards(bob, address(rewardToken)); // Bob picks up frozen rewards

        rewardToken.mint(address(staking), 100 ether);
        staking.accrueRewards(address(rewardToken));

        vm.warp(block.timestamp + 3 days + 1);
        uint256 claimed = _claimRewards(bob, address(rewardToken));
        assertApproxEqRel(claimed, 100 ether, 0.02e18, 'Bob only receives new rewards');
    }

    function test_Scenario_MultipleClaims_ReturnZeroAfterFirst() public {
        ERC20_Mock rewardToken = _createRewardToken('Reward', 'RWD');

        _stake(alice, 1_000 ether);
        rewardToken.mint(address(staking), 1_000 ether);
        staking.accrueRewards(address(rewardToken));
        vm.warp(block.timestamp + 3 days + 1);

        uint256 firstClaim = _claimRewards(alice, address(rewardToken));
        uint256 secondClaim = _claimRewards(alice, address(rewardToken));

        assertApproxEqRel(firstClaim, 1_000 ether, 0.01e18, 'Alice receives full share');
        assertEq(secondClaim, 0, 'Debt accounting prevents double claim');
    }

    // Required mock functions for factory
    function streamWindowSeconds(address) external pure returns (uint32) {
        return 3 days;
    }

    function clankerFactory() external pure returns (address) {
        return address(0);
    }

    ///////////////////////////////////////////////////////////////////////////
    // Helper Functions

    function _stake(address user, uint256 amount) internal {
        underlying.mint(user, amount);
        vm.startPrank(user);
        underlying.approve(address(staking), type(uint256).max);
        staking.stake(amount);
        vm.stopPrank();
    }

    function _createRewardToken(
        string memory name,
        string memory symbol
    ) internal returns (ERC20_Mock token) {
        token = new ERC20_Mock(name, symbol);
        whitelistRewardToken(staking, address(token), address(this));
    }

    function _claimRewards(address user, address token) internal returns (uint256 claimed) {
        address[] memory tokens = new address[](1);
        tokens[0] = token;

        uint256 balanceBefore = ERC20_Mock(token).balanceOf(user);
        vm.prank(user);
        staking.claimRewards(tokens, user);
        claimed = ERC20_Mock(token).balanceOf(user) - balanceBefore;
    }
}
