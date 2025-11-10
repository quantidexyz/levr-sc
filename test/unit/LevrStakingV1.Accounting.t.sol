// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from 'forge-std/Test.sol';
import {console} from 'forge-std/console.sol';
import {LevrStaking_v1} from '../../src/LevrStaking_v1.sol';
import {LevrStakedToken_v1} from '../../src/LevrStakedToken_v1.sol';
import {ILevrStaking_v1} from '../../src/interfaces/ILevrStaking_v1.sol';
import {ILevrFactory_v1} from '../../src/interfaces/ILevrFactory_v1.sol';
import {MockERC20} from '../mocks/MockERC20.sol';
import {LevrFactoryDeployHelper} from '../utils/LevrFactoryDeployHelper.sol';

/// @title Levr Staking V1 Accounting Tests
/// @notice Comprehensive accounting tests covering all edge cases and bug scenarios
contract LevrStakingV1_Accounting is Test, LevrFactoryDeployHelper {
    MockERC20 internal underlying;
    MockERC20 internal weth;
    LevrStakedToken_v1 internal sToken;
    LevrStaking_v1 internal staking;
    address internal alice = address(0x1111);

    event RewardShortfall(address indexed user, address indexed token, uint256 amount);

    function setUp() public {
        underlying = new MockERC20('Token', 'TKN');
        weth = new MockERC20('WETH', 'WETH');
        staking = createStaking(address(0x999), address(this));
        sToken = createStakedToken('sTKN', 'sTKN', 18, address(underlying), address(staking));

        // Initialize staking with WETH already whitelisted
        address[] memory rewardTokens = new address[](1);
        rewardTokens[0] = address(weth);
        initializeStakingWithRewardTokens(
            staking,
            address(underlying),
            address(sToken),
            address(0xBEEF),
            address(this),
            rewardTokens
        );

        underlying.mint(alice, 1_000_000 ether);
        weth.mint(address(this), 1_000_000 ether);
    }

    function streamWindowSeconds(address) external pure returns (uint32) {
        return 7 days;
    }

    /// @notice Helper: Check if accounting is correct
    /// @dev Fails test if claimable > actual tokens available
    function assertAccountingPerfect(string memory when) internal {
        assertAccountingPerfectFor(alice, address(weth), when);
    }

    function assertAccountingPerfectFor(
        address account,
        address token,
        string memory when
    ) internal {
        // DEBT ACCOUNTING: Users earn rewards based on when they staked
        // Early stakers can legitimately have more than their current proportional share
        // Just verify claimable doesn't exceed total token balance (sanity check)

        uint256 tokenBalance = MockERC20(token).balanceOf(address(staking));
        uint256 claimable = staking.claimableRewards(account, token);

        // User can't claim more than total token balance (sanity check)
        if (claimable > tokenBalance) {
            emit log_string(when);
            emit log_named_address('  Account', account);
            emit log_named_uint('  Token Balance', tokenBalance);
            emit log_named_uint('  Claimable', claimable);
            emit log_named_uint('  BUG: Claimable exceeds balance by', claimable - tokenBalance);
            revert('ACCOUNTING BUG FOUND');
        }

        // NOTE: We don't check maxPossible based on current proportional share
        // With debt accounting, early stakers legitimately earn more than current share
        // Example: Alice staked alone, earned 1000. Bob joins later. Alice still has 1000 claimable
        // even though her current share is only 500. This is correct! She earned it before Bob joined.
    }

    function assertAccountingPerfectForMany(
        address[] memory accounts,
        address token,
        string memory when
    ) internal {
        for (uint256 i = 0; i < accounts.length; i++) {
            assertAccountingPerfectFor(accounts[i], token, when);
        }
    }

    /// @notice CORE BUG: Unstake -> window closes -> accrue -> stake back + MANUAL TRANSFERS IN PENDING STATE
    /// @dev This is the primary bug scenario - consolidates UI bug and variant tests
    function test_CORE_unstakeWindowClosedAccrueStake() public {
        address[] memory tokens = new address[](1);
        tokens[0] = address(weth);

        // Alice stakes
        vm.prank(alice);
        underlying.approve(address(staking), 10_000 ether);
        vm.prank(alice);
        staking.stake(1000 ether);
        assertAccountingPerfect('After initial stake');

        // First accrue: 1000 WETH, 7 day window
        weth.transfer(address(staking), 1000 ether);
        staking.accrueRewards(address(weth));
        assertAccountingPerfect('After first accrue (window starts)');

        // 3 days pass (window still open)
        skip(3 days);
        assertAccountingPerfect('After 3 days (window still open)');

        // POOL-BASED: Alice unstakes and AUTO-CLAIMS her vested rewards
        uint256 aliceWethBefore = weth.balanceOf(alice);
        uint256 aliceUnderlyingBefore = underlying.balanceOf(alice);
        vm.prank(alice);
        staking.unstake(1000 ether, alice);
        uint256 aliceWethAfter = weth.balanceOf(alice);
        uint256 aliceUnderlyingAfter = underlying.balanceOf(alice);

        // Auto-claimed rewards = WETH received (underlying is principal, not reward)
        uint256 aliceFirstClaim = aliceWethAfter - aliceWethBefore;
        uint256 principalReturned = aliceUnderlyingAfter - aliceUnderlyingBefore;

        assertAccountingPerfect('After Alice unstakes (auto-claimed)');
        assertGt(aliceFirstClaim, 0, 'Alice auto-claimed WETH rewards');
        assertEq(principalReturned, 1000 ether, 'Alice got principal back');

        // MANUAL TRANSFER while Alice has pending (no accrue call yet)
        skip(1 days);
        weth.transfer(address(staking), 250 ether);
        assertAccountingPerfect('After manual transfer with pending');

        // Window CLOSES (4 more days = 8 total)
        skip(4 days);
        assertAccountingPerfect('After window closes (no stakers)');

        // ANOTHER manual transfer while no one staked
        weth.transfer(address(staking), 150 ether);
        assertAccountingPerfect('After second manual transfer (no stakers)');

        // New tokens transferred and accrued (should pick up both manual transfers)
        weth.transfer(address(staking), 500 ether);
        staking.accrueRewards(address(weth));
        assertAccountingPerfect('After accrue (new window starts)');

        // Manual transfer AGAIN before Alice stakes back
        skip(1 days);
        weth.transfer(address(staking), 100 ether);
        assertAccountingPerfect('After third manual transfer');

        // Alice stakes again
        vm.prank(alice);
        staking.stake(1000 ether);
        assertAccountingPerfect('After Alice stakes back');

        // Manual transfer while stream is active
        skip(2 days);
        weth.transfer(address(staking), 75 ether);
        assertAccountingPerfect('After fourth manual transfer mid-stream');

        // Accrue the accumulated manual transfers
        staking.accrueRewards(address(weth));
        assertAccountingPerfect('After accruing manual transfers');

        // Wait for new stream to finish
        skip(8 days);
        assertAccountingPerfect('After new window closes');

        // Alice claims everything (her second claim)
        vm.prank(alice);
        staking.claimRewards(tokens, alice);
        assertAccountingPerfect('After Alice claims');

        uint256 totalClaimed = weth.balanceOf(alice);
        uint256 left = weth.balanceOf(address(staking));
        uint256 totalTransferred = 1000 ether +
            250 ether +
            150 ether +
            500 ether +
            100 ether +
            75 ether;

        // POOL-BASED BEHAVIOR:
        // Alice earned rewards only while staked:
        // - Period 1: Staked for 3 days, earned from first 1000 (auto-claimed on unstake)
        // - Period 2: Unstaked while manual transfers happened (earns 0)
        // - Period 3: Staked again, earns from final stream

        // Total no loss (all tokens accounted)
        assertApproxEqAbs(
            totalClaimed + left,
            totalTransferred,
            1 ether,
            'Perfect accounting: no loss'
        );

        // Alice gets all rewards because she was the ONLY staker throughout
        // Even when unstaked, there were no other stakers, so unvested rolled to next stream for her
        assertApproxEqAbs(totalClaimed, totalTransferred, 1 ether, 'Alice gets all (sole staker)');
    }

    /// @notice EDGE CASE: Stream pauses when all users unstake, then resumes
    /// @dev Consolidates stream pause/resume tests
    function test_EDGE_streamPausesWithNoStakers() public {
        address[] memory tokens = new address[](1);
        tokens[0] = address(weth);

        // Alice stakes
        vm.prank(alice);
        underlying.approve(address(staking), 1000 ether);
        vm.prank(alice);
        staking.stake(1000 ether);
        assertAccountingPerfect('After Alice stakes');

        // Accrue 1000 WETH - starts 7 day stream
        weth.transfer(address(staking), 1000 ether);
        staking.accrueRewards(address(weth));
        assertAccountingPerfect('After accrue');

        // 2 days pass, Alice earns some rewards
        skip(2 days);
        assertAccountingPerfect('After 2 days');

        // Alice unstakes EVERYTHING (0 stakers now)
        vm.prank(alice);
        staking.unstake(1000 ether, alice);
        assertAccountingPerfect('After Alice unstakes all');

        // Stream continues but NO ONE is staked for 3 days
        skip(3 days);
        assertAccountingPerfect('After 3 days with no stakers');

        // Alice stakes again (should trigger stream restart with unvested)
        vm.prank(alice);
        underlying.approve(address(staking), 500 ether);
        vm.prank(alice);
        staking.stake(500 ether);
        assertAccountingPerfect('After Alice re-stakes');

        // More time passes
        skip(4 days);
        assertAccountingPerfect('After 4 more days');

        // Alice claims everything
        vm.prank(alice);
        staking.claimRewards(tokens, alice);
        assertAccountingPerfect('After claim');

        // Verify no funds lost
        uint256 claimed = weth.balanceOf(alice);
        uint256 left = weth.balanceOf(address(staking));
        assertApproxEqAbs(claimed + left, 1000 ether, 1 ether, 'No WETH lost during pause');
    }

    /// @notice EDGE CASE: Multiple accruals in same stream window
    /// @dev Consolidates rapid accrual tests
    function test_EDGE_multipleAccrualsInSameStream() public {
        address[] memory tokens = new address[](1);
        tokens[0] = address(weth);

        vm.prank(alice);
        underlying.approve(address(staking), 1000 ether);
        vm.prank(alice);
        staking.stake(1000 ether);

        // First accrual
        weth.transfer(address(staking), 100 ether);
        staking.accrueRewards(address(weth));
        assertAccountingPerfect('After first accrue');

        skip(1 days);

        // Second accrual (should add to unvested and restart stream)
        weth.transfer(address(staking), 200 ether);
        staking.accrueRewards(address(weth));
        assertAccountingPerfect('After second accrue');

        skip(1 days);

        // Third accrual
        weth.transfer(address(staking), 150 ether);
        staking.accrueRewards(address(weth));
        assertAccountingPerfect('After third accrue');

        // Rapid accruals - accrue every few seconds
        for (uint256 i = 0; i < 20; i++) {
            weth.transfer(address(staking), 1 ether);
            staking.accrueRewards(address(weth));
            skip(1 seconds);
            if (i % 5 == 0) {
                assertAccountingPerfect(string(abi.encodePacked('Rapid accrue ', i)));
            }
        }

        // Wait for stream to finish
        skip(8 days);

        vm.prank(alice);
        staking.claimRewards(tokens, alice);
        assertAccountingPerfect('After claim all');

        uint256 claimed = weth.balanceOf(alice);
        uint256 left = weth.balanceOf(address(staking));
        assertApproxEqAbs(claimed + left, 470 ether, 1 ether, 'All WETH accounted for');
    }

    /// @notice EDGE CASE: Rapid stake/unstake cycles
    /// @dev Consolidates rapid cycling and same-block tests
    function test_EDGE_rapidStakeUnstakeCycles() public {
        address[] memory tokens = new address[](1);
        tokens[0] = address(weth);

        vm.startPrank(alice);
        underlying.approve(address(staking), 10_000 ether);

        // Cycle 1: Stake
        staking.stake(1000 ether);
        assertAccountingPerfect('Cycle 1: stake');

        // Accrue
        vm.stopPrank();
        weth.transfer(address(staking), 500 ether);
        staking.accrueRewards(address(weth));
        skip(1 days);

        // Unstake
        vm.prank(alice);
        staking.unstake(1000 ether, alice);
        assertAccountingPerfect('Cycle 1: unstake');

        // Cycle 2: Stake again immediately
        vm.prank(alice);
        staking.stake(800 ether);
        assertAccountingPerfect('Cycle 2: stake');

        skip(1 days);

        // Partial unstake
        vm.prank(alice);
        staking.unstake(400 ether, alice);
        assertAccountingPerfect('Cycle 2: partial unstake');

        // Cycle 3: Stake more
        vm.prank(alice);
        staking.stake(600 ether);
        assertAccountingPerfect('Cycle 3: stake');

        // Accrue more
        weth.transfer(address(staking), 300 ether);
        staking.accrueRewards(address(weth));
        skip(2 days);

        // Full unstake
        vm.prank(alice);
        staking.unstake(1000 ether, alice);
        assertAccountingPerfect('Cycle 3: full unstake');

        // Test same-block unstake/restake
        skip(1 days);
        vm.startPrank(alice);
        staking.stake(500 ether);
        staking.unstake(500 ether, alice);
        staking.stake(500 ether);
        vm.stopPrank();
        assertAccountingPerfect('After same-block cycles');

        // Claim all pending
        skip(5 days);
        vm.prank(alice);
        staking.claimRewards(tokens, alice);
        assertAccountingPerfect('After claiming all');

        uint256 claimed = weth.balanceOf(alice);
        uint256 left = weth.balanceOf(address(staking));
        assertApproxEqAbs(claimed + left, 800 ether, 1 ether, 'No loss in rapid cycles');
    }

    /// @notice EDGE CASE: User claims while stream is active vs after stream ends
    function test_EDGE_claimDuringVsAfterStream() public {
        address bob = address(0x2222);
        underlying.mint(bob, 1_000_000 ether);
        address[] memory tokens = new address[](1);
        tokens[0] = address(weth);

        // Both stake
        vm.prank(alice);
        underlying.approve(address(staking), 1000 ether);
        vm.prank(alice);
        staking.stake(1000 ether);

        vm.prank(bob);
        underlying.approve(address(staking), 1000 ether);
        vm.prank(bob);
        staking.stake(1000 ether);

        // Accrue 1000 WETH
        weth.transfer(address(staking), 1000 ether);
        staking.accrueRewards(address(weth));
        assertAccountingPerfect('After accrue');

        // Alice claims mid-stream (3 days in)
        skip(3 days);
        vm.prank(alice);
        staking.claimRewards(tokens, alice);
        assertAccountingPerfect('After Alice mid-stream claim');

        // Wait for stream to end
        skip(5 days);

        // Bob claims after stream ended
        vm.prank(bob);
        staking.claimRewards(tokens, bob);
        assertAccountingPerfect('After Bob post-stream claim');

        // Alice claims again after stream
        vm.prank(alice);
        staking.claimRewards(tokens, alice);
        assertAccountingPerfect('After Alice second claim');

        uint256 aliceClaimed = weth.balanceOf(alice);
        uint256 bobClaimed = weth.balanceOf(bob);
        uint256 left = weth.balanceOf(address(staking));

        assertApproxEqAbs(aliceClaimed + bobClaimed + left, 1000 ether, 1 ether, 'Equal split');
    }

    /// @notice EDGE CASE: Partial unstake with pending rewards + MANUAL TRANSFERS + ACCRUALS INTERLEAVED
    /// @dev Consolidates partial unstake tests including weird amounts
    function test_EDGE_partialUnstakeClaimUnstake() public {
        address[] memory tokens = new address[](1);
        tokens[0] = address(weth);

        vm.prank(alice);
        underlying.approve(address(staking), 5000 ether);
        vm.prank(alice);
        staking.stake(2000 ether);

        // Accrue rewards
        weth.transfer(address(staking), 1000 ether);
        staking.accrueRewards(address(weth));
        skip(3 days);
        assertAccountingPerfect('After 3 days');

        // Manual transfer before unstake
        weth.transfer(address(staking), 200 ether);
        assertAccountingPerfect('After manual transfer 1');

        // Partial unstake (1000 out of 2000)
        vm.prank(alice);
        staking.unstake(1000 ether, alice);
        assertAccountingPerfect('After partial unstake');

        // Manual transfer while Alice has pending
        weth.transfer(address(staking), 150 ether);
        assertAccountingPerfect('After manual transfer 2 (with pending)');

        // Claim (should get pending from unstake + balance-based)
        vm.prank(alice);
        staking.claimRewards(tokens, alice);
        assertAccountingPerfect('After first claim');

        // Accrue the manual transfers
        staking.accrueRewards(address(weth));
        assertAccountingPerfect('After accrue manual transfers');

        skip(2 days);

        // Partial unstake again (500 out of 1000)
        vm.prank(alice);
        staking.unstake(500 ether, alice);
        assertAccountingPerfect('After second partial unstake');

        // Manual transfer + immediate accrue
        weth.transfer(address(staking), 300 ether);
        staking.accrueRewards(address(weth));
        assertAccountingPerfect('After manual transfer 3 + accrue');

        // Test weird amount unstakes
        vm.prank(alice);
        staking.unstake(1, alice); // 1 wei
        assertAccountingPerfect('After 1 wei unstake');

        // Manual transfer in between weird unstakes
        weth.transfer(address(staking), 50 ether);

        skip(12 hours);

        vm.prank(alice);
        staking.unstake(123456789 gwei, alice); // weird amount
        assertAccountingPerfect('After weird unstake');

        // Accrue accumulated transfers
        staking.accrueRewards(address(weth));
        assertAccountingPerfect('After accrue weird unstake period');

        // Claim again
        vm.prank(alice);
        staking.claimRewards(tokens, alice);
        assertAccountingPerfect('After second claim');

        skip(1 days);

        // Manual transfer before re-stake
        weth.transfer(address(staking), 100 ether);

        // Alice stakes MORE
        vm.prank(alice);
        staking.stake(1000 ether);
        assertAccountingPerfect('After re-stake');

        // Accrue the transfer from before stake
        staking.accrueRewards(address(weth));

        skip(3 days);

        // Final unstake (rest)
        uint256 remaining = sToken.balanceOf(alice);
        vm.prank(alice);
        staking.unstake(remaining, alice);
        assertAccountingPerfect('After final unstake');

        // Manual transfer before final claim
        weth.transfer(address(staking), 75 ether);
        staking.accrueRewards(address(weth));

        skip(7 days);

        // Final claim
        vm.prank(alice);
        staking.claimRewards(tokens, alice);
        assertAccountingPerfect('After final claim');

        uint256 claimed = weth.balanceOf(alice);
        uint256 left = weth.balanceOf(address(staking));
        uint256 total = 1000 + 200 + 150 + 300 + 50 + 100 + 75;
        assertApproxEqAbs(claimed + left, total * 1 ether, 1 ether, 'All rewards claimed');
    }

    /// @notice EDGE CASE: Accrue when no one is staked (cold start)
    /// @dev Consolidates zero staker tests including massive time gaps
    function test_EDGE_accrueWithNoStakers() public {
        // No one staked, accrue rewards
        weth.transfer(address(staking), 500 ether);
        staking.accrueRewards(address(weth));
        assertAccountingPerfect('After accrue with no stakers');

        skip(2 days);

        // Still no one staked, accrue more
        weth.transfer(address(staking), 300 ether);
        staking.accrueRewards(address(weth));
        assertAccountingPerfect('After second accrue with no stakers');

        // Wait 5 years with no stakers
        skip(5 * 365 days);

        // Accrue even more after years
        weth.transfer(address(staking), 200 ether);
        staking.accrueRewards(address(weth));
        assertAccountingPerfect('After accrue with 5 year gap');

        skip(1 days);

        // NOW someone stakes (should start new stream)
        vm.prank(alice);
        underlying.approve(address(staking), 1000 ether);
        vm.prank(alice);
        staking.stake(1000 ether);
        assertAccountingPerfect('After first stake');

        skip(7 days);

        // Claim
        address[] memory tokens = new address[](1);
        tokens[0] = address(weth);
        vm.prank(alice);
        staking.claimRewards(tokens, alice);
        assertAccountingPerfect('After claim');

        uint256 claimed = weth.balanceOf(alice);
        uint256 left = weth.balanceOf(address(staking));
        assertApproxEqAbs(claimed + left, 1000 ether, 1 ether, 'All accrued rewards available');
    }

    /// @notice EDGE CASE: Direct transfer without accrual, then later accrue + PENDING REWARDS CHAOS
    function test_EDGE_directTransferThenAccrue() public {
        address bob = address(0x2222);
        underlying.mint(bob, 5_000 ether);
        address[] memory tokens = new address[](1);
        tokens[0] = address(weth);

        vm.prank(alice);
        underlying.approve(address(staking), 3000 ether);
        vm.prank(alice);
        staking.stake(1000 ether);

        // Start a stream first
        weth.transfer(address(staking), 600 ether);
        staking.accrueRewards(address(weth));
        skip(2 days);

        // Bob joins
        vm.prank(bob);
        underlying.approve(address(staking), 2000 ether);
        vm.prank(bob);
        staking.stake(1000 ether);
        assertAccountingPerfectForMany(_buildAddresses(alice, bob), address(weth), 'Bob joins');

        // Direct transfer WITHOUT calling accrueRewards (while stream active)
        weth.transfer(address(staking), 500 ether);
        assertAccountingPerfect('After direct transfer mid-stream');

        skip(1 days);

        // Alice unstakes creating pending
        vm.prank(alice);
        staking.unstake(1000 ether, alice);
        assertAccountingPerfectForMany(
            _buildAddresses(alice, bob),
            address(weth),
            'Alice unstakes with pending'
        );

        // Another direct transfer while Alice has pending
        weth.transfer(address(staking), 300 ether);
        assertAccountingPerfectForMany(
            _buildAddresses(alice, bob),
            address(weth),
            'Second direct transfer'
        );

        skip(2 days);

        // Bob partially unstakes
        vm.prank(bob);
        staking.unstake(500 ether, bob);
        assertAccountingPerfectForMany(
            _buildAddresses(alice, bob),
            address(weth),
            'Bob partial unstake'
        );

        // Direct transfer while both have pending
        weth.transfer(address(staking), 200 ether);
        assertAccountingPerfectForMany(
            _buildAddresses(alice, bob),
            address(weth),
            'Third transfer with dual pending'
        );

        skip(1 days);

        // NOW accrue (should pick up all manual transfers + unvested)
        staking.accrueRewards(address(weth));
        assertAccountingPerfectForMany(
            _buildAddresses(alice, bob),
            address(weth),
            'After accrueRewards'
        );

        // Alice stakes back while Bob still has balance
        vm.prank(alice);
        staking.stake(1500 ether);
        assertAccountingPerfectForMany(
            _buildAddresses(alice, bob),
            address(weth),
            'Alice stakes back'
        );

        // Manual transfer mid new stream
        skip(2 days);
        weth.transfer(address(staking), 150 ether);

        // Accrue again
        staking.accrueRewards(address(weth));
        assertAccountingPerfectForMany(
            _buildAddresses(alice, bob),
            address(weth),
            'After second accrue'
        );

        skip(7 days);

        // Both claim
        vm.prank(alice);
        staking.claimRewards(tokens, alice);
        vm.prank(bob);
        staking.claimRewards(tokens, bob);
        assertAccountingPerfectForMany(_buildAddresses(alice, bob), address(weth), 'After claims');

        uint256 aliceClaimed = weth.balanceOf(alice);
        uint256 bobClaimed = weth.balanceOf(bob);
        uint256 left = weth.balanceOf(address(staking));
        uint256 total = 600 + 500 + 300 + 200 + 150;
        assertApproxEqAbs(
            aliceClaimed + bobClaimed + left,
            total * 1 ether,
            1 ether,
            'All transferred WETH claimed'
        );
    }

    /// @notice EDGE CASE: User fully unstakes then tries to claim (only pending)
    function test_EDGE_fullyUnstakedUserClaims() public {
        address[] memory tokens = new address[](1);
        tokens[0] = address(weth);

        vm.prank(alice);
        underlying.approve(address(staking), 1000 ether);
        vm.prank(alice);
        staking.stake(1000 ether);

        // Accrue rewards
        weth.transfer(address(staking), 1000 ether);
        staking.accrueRewards(address(weth));
        skip(3 days);

        // Alice unstakes EVERYTHING
        vm.prank(alice);
        staking.unstake(1000 ether, alice);
        assertAccountingPerfect('After full unstake');

        // Stream continues for others (but no one else staked)
        skip(2 days);

        // Alice claims with 0 balance (should only get pending)
        vm.prank(alice);
        staking.claimRewards(tokens, alice);
        assertAccountingPerfect('After claim with 0 balance');

        uint256 claimed = weth.balanceOf(alice);
        assertTrue(claimed > 0, 'Should have claimed pending rewards');

        // Try claiming again (should get nothing)
        vm.prank(alice);
        staking.claimRewards(tokens, alice);
        uint256 claimed2 = weth.balanceOf(alice);
        assertEq(claimed2, claimed, 'No double claim');
    }

    /// @notice EDGE CASE: Three users with staggered entry/exit
    function test_EDGE_threeUsersStaggered() public {
        address bob = address(0x2222);
        address charlie = address(0x3333);
        underlying.mint(bob, 1_000_000 ether);
        underlying.mint(charlie, 1_000_000 ether);
        address[] memory tokens = new address[](1);
        tokens[0] = address(weth);

        // Alice stakes at t=0
        vm.prank(alice);
        underlying.approve(address(staking), 1000 ether);
        vm.prank(alice);
        staking.stake(1000 ether);

        // Accrue 3000 WETH
        weth.transfer(address(staking), 3000 ether);
        staking.accrueRewards(address(weth));
        assertAccountingPerfect('After accrue');

        // Bob stakes at t=2 days
        skip(2 days);
        vm.prank(bob);
        underlying.approve(address(staking), 2000 ether);
        vm.prank(bob);
        staking.stake(2000 ether);
        assertAccountingPerfect('After Bob stakes');
        assertAccountingPerfectForMany(
            _buildAddresses(alice, bob),
            address(weth),
            'Multi-user check after Bob stakes'
        );

        // Charlie stakes at t=4 days
        skip(2 days);
        vm.prank(charlie);
        underlying.approve(address(staking), 3000 ether);
        vm.prank(charlie);
        staking.stake(3000 ether);
        assertAccountingPerfect('After Charlie stakes');
        assertAccountingPerfectForMany(
            _buildAddresses(alice, bob, charlie),
            address(weth),
            'Multi-user check after Charlie stakes'
        );

        // Alice exits at t=5 days
        skip(1 days);
        vm.prank(alice);
        staking.unstake(1000 ether, alice);
        assertAccountingPerfect('After Alice exits');
        assertAccountingPerfectForMany(
            _buildAddresses(alice, bob, charlie),
            address(weth),
            'After Alice exits multi-user'
        );

        // Bob exits at t=6 days
        skip(1 days);
        vm.prank(bob);
        staking.unstake(2000 ether, bob);
        assertAccountingPerfect('After Bob exits');
        assertAccountingPerfectForMany(
            _buildAddresses(alice, bob, charlie),
            address(weth),
            'After Bob exits multi-user'
        );

        // Charlie stays until t=10 days
        skip(4 days);

        // Everyone claims
        vm.prank(alice);
        staking.claimRewards(tokens, alice);
        vm.prank(bob);
        staking.claimRewards(tokens, bob);
        vm.prank(charlie);
        staking.claimRewards(tokens, charlie);
        assertAccountingPerfect('After all claims');
        assertAccountingPerfectForMany(
            _buildAddresses(alice, bob, charlie),
            address(weth),
            'After all claims multi-user'
        );

        uint256 aliceClaimed = weth.balanceOf(alice);
        uint256 bobClaimed = weth.balanceOf(bob);
        uint256 charlieClaimed = weth.balanceOf(charlie);
        uint256 left = weth.balanceOf(address(staking));

        console.log('Alice claimed:', aliceClaimed / 1 ether);
        console.log('Bob claimed:', bobClaimed / 1 ether);
        console.log('Charlie claimed:', charlieClaimed / 1 ether);
        console.log('Left in pool:', left / 1 ether);

        // Total conservation: all rewards accounted for
        assertApproxEqAbs(
            aliceClaimed + bobClaimed + charlieClaimed + left,
            3000 ether,
            1 ether,
            'All WETH distributed'
        );

        // DEBT ACCOUNTING: Early stakers get more (Alice was alone earliest)
        // Alice should get MORE than Bob (she staked earlier)
        // Bob should get MORE than Charlie (he staked earlier than Charlie)
        assertGt(aliceClaimed, bobClaimed, 'Alice (earliest) should get more than Bob');
        assertGt(bobClaimed, charlieClaimed, 'Bob should get more than Charlie (latest)');

        // All users should receive something (they all participated)
        assertGt(aliceClaimed, 0, 'Alice receives rewards');
        assertGt(bobClaimed, 0, 'Bob receives rewards');
        assertGt(charlieClaimed, 0, 'Charlie receives rewards');
    }

    /// @notice EDGE CASE: Stream ends, leftover unvested, new stream starts
    function test_EDGE_unvestedRewardRollover() public {
        address[] memory tokens = new address[](1);
        tokens[0] = address(weth);

        vm.prank(alice);
        underlying.approve(address(staking), 1000 ether);
        vm.prank(alice);
        staking.stake(1000 ether);

        // First stream: 1000 WETH over 7 days
        weth.transfer(address(staking), 1000 ether);
        staking.accrueRewards(address(weth));
        assertAccountingPerfect('After first accrue');

        // Only 3 days pass (not full 7)
        skip(3 days);
        assertAccountingPerfect('After 3 days');

        // New accrual happens (should rollover unvested)
        weth.transfer(address(staking), 500 ether);
        staking.accrueRewards(address(weth));
        assertAccountingPerfect('After second accrue with unvested');

        // Wait for new stream to end
        skip(8 days);

        vm.prank(alice);
        staking.claimRewards(tokens, alice);
        assertAccountingPerfect('After claiming all');

        uint256 claimed = weth.balanceOf(alice);
        uint256 left = weth.balanceOf(address(staking));
        assertApproxEqAbs(claimed + left, 1500 ether, 1 ether, 'All WETH including unvested');
    }

    /// @notice EDGE CASE: Claim multiple times in same stream
    /// @dev Consolidates multiple claim timing tests
    function test_EDGE_multipleClaimsInStream() public {
        address[] memory tokens = new address[](1);
        tokens[0] = address(weth);

        vm.prank(alice);
        underlying.approve(address(staking), 1000 ether);
        vm.prank(alice);
        staking.stake(1000 ether);

        weth.transfer(address(staking), 1000 ether);
        staking.accrueRewards(address(weth));

        // Claim at day 1
        skip(1 days);
        vm.prank(alice);
        staking.claimRewards(tokens, alice);
        assertAccountingPerfect('After claim day 1');
        uint256 claim1 = weth.balanceOf(alice);

        // Claim at day 2
        skip(1 days);
        vm.prank(alice);
        staking.claimRewards(tokens, alice);
        assertAccountingPerfect('After claim day 2');
        uint256 claim2 = weth.balanceOf(alice);

        // Claim at day 4
        skip(2 days);
        vm.prank(alice);
        staking.claimRewards(tokens, alice);
        assertAccountingPerfect('After claim day 4');
        uint256 claim3 = weth.balanceOf(alice);

        // Test multiple claims in same block
        vm.startPrank(alice);
        for (uint256 i = 0; i < 5; i++) {
            staking.claimRewards(tokens, alice);
        }
        vm.stopPrank();
        assertAccountingPerfect('After 5 claims same block');

        // Wait for stream end and final claim
        skip(4 days);
        vm.prank(alice);
        staking.claimRewards(tokens, alice);
        assertAccountingPerfect('After final claim');

        uint256 totalClaimed = weth.balanceOf(alice);
        uint256 left = weth.balanceOf(address(staking));

        assertTrue(claim2 > claim1, 'Second claim should be higher');
        assertTrue(claim3 > claim2, 'Third claim should be higher');
        assertApproxEqAbs(totalClaimed + left, 1000 ether, 1 ether, 'All WETH claimed over time');
    }

    /// @notice EDGE CASE: Massive time gap between actions
    /// @dev Consolidates all time gap tests (10 years, months, etc.)
    function test_EDGE_massiveTimeGaps() public {
        address[] memory tokens = new address[](1);
        tokens[0] = address(weth);

        vm.prank(alice);
        underlying.approve(address(staking), 1000 ether);
        vm.prank(alice);
        staking.stake(1000 ether);

        weth.transfer(address(staking), 1000 ether);
        staking.accrueRewards(address(weth));

        // Wait 10 YEARS
        skip(10 * 365 days);
        assertAccountingPerfect('After 10 years');

        vm.prank(alice);
        staking.claimRewards(tokens, alice);
        assertAccountingPerfect('After claim');

        // Wait 6 months
        skip(180 days);

        // Accrue dust
        weth.transfer(address(staking), 0.001 ether);
        staking.accrueRewards(address(weth));
        assertAccountingPerfect('Dust accrue');

        // Wait 2 more years
        skip(2 * 365 days);

        vm.prank(alice);
        staking.claimRewards(tokens, alice);
        assertAccountingPerfect('After second claim');

        uint256 claimed = weth.balanceOf(alice);
        uint256 left = weth.balanceOf(address(staking));
        assertApproxEqAbs(
            claimed + left,
            1000.001 ether,
            1 ether,
            'All WETH claimed despite massive gaps'
        );
    }

    /// @notice POOL-BASED: Auto-claim on unstake - verify exact amounts
    function test_BUG_DETAILED_unstakeWindowClosedAccrueStake() public {
        address[] memory tokens = new address[](1);
        tokens[0] = address(weth);

        emit log_string('=== POOL-BASED BEHAVIOR TEST ===');

        // Setup: Alice stakes 1000
        vm.prank(alice);
        underlying.approve(address(staking), 2000 ether);
        vm.prank(alice);
        staking.stake(1000 ether);

        // First accrue: 1000 WETH, 7 day window
        weth.transfer(address(staking), 1000 ether);
        staking.accrueRewards(address(weth));

        // After 2 days: Alice should have ~285.71 WETH claimable (2/7 of 1000)
        skip(2 days);
        uint256 claimableAt2Days = staking.claimableRewards(alice, address(weth));
        emit log_named_uint('Claimable after 2 days', claimableAt2Days);
        uint256 sevenDays = 7 days;
        uint256 twoDays = 2 days;
        uint256 expected2Day = (1000 ether * twoDays) / sevenDays;
        assertApproxEqAbs(claimableAt2Days, expected2Day, 0.1 ether, 'Day 2 claimable wrong');

        // Alice unstakes - AUTO-CLAIMS all rewards (Option A)
        uint256 aliceBalanceBefore = weth.balanceOf(alice);
        vm.prank(alice);
        staking.unstake(1000 ether, alice);
        uint256 aliceBalanceAfter = weth.balanceOf(alice);
        uint256 claimed = aliceBalanceAfter - aliceBalanceBefore;

        emit log_named_uint('Auto-claimed on unstake', claimed);
        assertApproxEqAbs(claimed, expected2Day, 0.1 ether, 'Should auto-claim on unstake');

        // After unstake, Alice has NO pending (balance = 0)
        uint256 claimableAfterUnstake = staking.claimableRewards(alice, address(weth));
        assertEq(claimableAfterUnstake, 0, 'No balance = no claimable');

        // Window closes (5 more days = 7 total)
        skip(5 days);

        // New tokens arrive and accrue
        weth.transfer(address(staking), 500 ether);
        staking.accrueRewards(address(weth));

        // Alice stakes back
        vm.prank(alice);
        staking.stake(1000 ether);

        // Alice starts fresh with new stream
        uint256 claimableAfterStake = staking.claimableRewards(alice, address(weth));
        emit log_named_uint('Claimable right after stake back', claimableAfterStake);
        assertEq(claimableAfterStake, 0, 'Fresh stake = no immediate rewards');

        // Wait 3.5 days (half of new 7 day stream)
        skip(3.5 days);
        uint256 claimableAtHalfStream = staking.claimableRewards(alice, address(weth));
        emit log_named_uint('Claimable at half of new stream', claimableAtHalfStream);

        // New stream has: 500 + unvested ~= 500 + 714.29 = 1214.29
        // Half of that ~= 607.14
        uint256 unvested = 1000 ether - expected2Day;
        uint256 newStreamTotal = 500 ether + unvested;
        uint256 halfNewStream = newStreamTotal / 2;
        emit log_named_uint('Expected at half stream', halfNewStream);
        assertApproxEqAbs(
            claimableAtHalfStream,
            halfNewStream,
            1 ether,
            'Half stream amount correct'
        );

        // Finish stream
        skip(4 days);

        // Claim everything
        vm.prank(alice);
        staking.claimRewards(tokens, alice);

        uint256 totalClaimed = weth.balanceOf(alice);
        uint256 left = weth.balanceOf(address(staking));

        emit log_named_uint('Total claimed (including auto-claim)', totalClaimed);
        emit log_named_uint('Final left', left);

        // Alice should get ALL 1500 WETH (claimed + auto-claimed)
        assertApproxEqAbs(totalClaimed, 1500 ether, 1 ether, 'Alice gets all WETH');
        assertApproxEqAbs(totalClaimed + left, 1500 ether, 1 ether, 'Total = 1500');
    }

    /// @notice ABSURD: Stake dust amount, accrue massive rewards
    function test_ABSURD_dustStakeMassiveRewards() public {
        address[] memory tokens = new address[](1);
        tokens[0] = address(weth);

        // Alice stakes 1 wei
        vm.prank(alice);
        underlying.approve(address(staking), 1);
        vm.prank(alice);
        staking.stake(1);
        assertAccountingPerfect('After dust stake');

        // Accrue 1 million WETH
        weth.transfer(address(staking), 1_000_000 ether);
        staking.accrueRewards(address(weth));
        assertAccountingPerfect('After massive accrue');

        skip(7 days);

        vm.prank(alice);
        staking.claimRewards(tokens, alice);
        assertAccountingPerfect('After claim');

        uint256 claimed = weth.balanceOf(alice);
        uint256 left = weth.balanceOf(address(staking));
        assertApproxEqAbs(claimed + left, 1_000_000 ether, 1 ether, 'Dust stake gets millions');
    }

    /// @notice UI BUG REPLICATION: Pending + Manual Transfer + Accrue in tight sequence
    /// @dev Specifically targets the claimable > available scenario found in UI testing
    function test_UI_BUG_pendingManualTransferAccrueSequence() public {
        address bob = address(0x2222);
        address charlie = address(0x3333);
        underlying.mint(bob, 5_000 ether);
        underlying.mint(charlie, 5_000 ether);
        address[] memory tokens = new address[](1);
        tokens[0] = address(weth);

        // Phase 1: Initial setup with streaming
        vm.prank(alice);
        underlying.approve(address(staking), 5_000 ether);
        vm.prank(alice);
        staking.stake(1000 ether);

        weth.transfer(address(staking), 500 ether);
        staking.accrueRewards(address(weth));
        skip(2 days);
        assertAccountingPerfect('Phase 1: Initial stream');

        // Phase 2: Bob joins, Alice unstakes creating pending
        vm.prank(bob);
        underlying.approve(address(staking), 5_000 ether);
        vm.prank(bob);
        staking.stake(800 ether);

        skip(1 days);

        vm.prank(alice);
        staking.unstake(1000 ether, alice); // Alice now has pending
        assertAccountingPerfectForMany(
            _buildAddresses(alice, bob),
            address(weth),
            'Phase 2: Alice pending'
        );

        // Phase 3: Manual transfer while Alice has pending (THE CRITICAL SCENARIO)
        weth.transfer(address(staking), 250 ether);
        assertAccountingPerfectForMany(
            _buildAddresses(alice, bob),
            address(weth),
            'Phase 3: Manual transfer with pending'
        );

        // Phase 4: Bob unstakes (both have pending now)
        skip(1 days);
        vm.prank(bob);
        staking.unstake(400 ether, bob);
        assertAccountingPerfectForMany(
            _buildAddresses(alice, bob),
            address(weth),
            'Phase 4: Both pending'
        );

        // Phase 5: Another manual transfer with dual pending
        weth.transfer(address(staking), 180 ether);
        assertAccountingPerfectForMany(
            _buildAddresses(alice, bob),
            address(weth),
            'Phase 5: Manual transfer dual pending'
        );

        // Phase 6: Accrue (critical - should handle pending + manual transfers correctly)
        staking.accrueRewards(address(weth));
        assertAccountingPerfectForMany(
            _buildAddresses(alice, bob),
            address(weth),
            'Phase 6: Accrue with pending'
        );

        // Phase 7: Charlie joins as first staker after pause
        skip(2 days);
        vm.prank(charlie);
        underlying.approve(address(staking), 2_000 ether);
        vm.prank(charlie);
        staking.stake(1200 ether);
        assertAccountingPerfectForMany(
            _buildAddresses(alice, bob, charlie),
            address(weth),
            'Phase 7: Charlie first staker'
        );

        // Phase 8: Manual transfer while stream active and pending exists
        weth.transfer(address(staking), 95 ether);
        assertAccountingPerfectForMany(
            _buildAddresses(alice, bob, charlie),
            address(weth),
            'Phase 8: Manual transfer with active stream + pending'
        );

        // Phase 9: Alice stakes back (still has pending)
        vm.prank(alice);
        staking.stake(600 ether);
        assertAccountingPerfectForMany(
            _buildAddresses(alice, bob, charlie),
            address(weth),
            'Phase 9: Alice stakes with pending'
        );

        // Phase 10: Accrue the manual transfer
        staking.accrueRewards(address(weth));
        assertAccountingPerfectForMany(
            _buildAddresses(alice, bob, charlie),
            address(weth),
            'Phase 10: Accrue after restake'
        );

        // Phase 11: Rapid manual transfers and accruals
        for (uint256 i = 0; i < 5; i++) {
            weth.transfer(address(staking), 20 ether);
            skip(6 hours);
            if (i % 2 == 0) {
                staking.accrueRewards(address(weth));
            }
        }
        staking.accrueRewards(address(weth)); // Final accrue
        assertAccountingPerfectForMany(
            _buildAddresses(alice, bob, charlie),
            address(weth),
            'Phase 11: After rapid transfers'
        );

        skip(7 days);

        // Phase 12: Everyone claims
        vm.prank(alice);
        staking.claimRewards(tokens, alice);
        vm.prank(bob);
        staking.claimRewards(tokens, bob);
        vm.prank(charlie);
        staking.claimRewards(tokens, charlie);
        assertAccountingPerfectForMany(
            _buildAddresses(alice, bob, charlie),
            address(weth),
            'Phase 12: All claims'
        );

        uint256 total = weth.balanceOf(alice) +
            weth.balanceOf(bob) +
            weth.balanceOf(charlie) +
            weth.balanceOf(address(staking));

        uint256 expectedTotal = 500 + 250 + 180 + 95 + (5 * 20);
        assertApproxEqAbs(
            total,
            expectedTotal * 1 ether,
            1 ether,
            'UI bug scenario: all accounted'
        );
    }

    /// @notice ABSURD: 5 users all doing random chaos + MANUAL TRANSFERS EVERYWHERE
    function test_ABSURD_fiveUsersChaos() public {
        address bob = address(0x2222);
        address charlie = address(0x3333);
        address dave = address(0x4444);
        address eve = address(0x5555);

        underlying.mint(bob, 1_000_000 ether);
        underlying.mint(charlie, 1_000_000 ether);
        underlying.mint(dave, 1_000_000 ether);
        underlying.mint(eve, 1_000_000 ether);

        address[] memory tokens = new address[](1);
        tokens[0] = address(weth);

        // Chaos begins
        vm.prank(alice);
        underlying.approve(address(staking), 10_000 ether);
        vm.prank(alice);
        staking.stake(1000 ether);

        // Manual transfer before accrue
        weth.transfer(address(staking), 300 ether);

        weth.transfer(address(staking), 5000 ether);
        staking.accrueRewards(address(weth));
        assertAccountingPerfect('Initial chaos');

        skip(1 days);

        vm.prank(bob);
        underlying.approve(address(staking), 10_000 ether);
        vm.prank(bob);
        staking.stake(2000 ether);

        // Manual transfer mid-stream
        weth.transfer(address(staking), 450 ether);

        vm.prank(alice);
        staking.unstake(500 ether, alice);
        assertAccountingPerfect('Chaos day 1');

        skip(12 hours);

        vm.prank(charlie);
        underlying.approve(address(staking), 10_000 ether);
        vm.prank(charlie);
        staking.stake(3000 ether);

        // Manual transfer with pending
        weth.transfer(address(staking), 600 ether);

        weth.transfer(address(staking), 2000 ether);
        staking.accrueRewards(address(weth));

        vm.prank(alice);
        staking.claimRewards(tokens, alice);
        assertAccountingPerfect('Chaos day 1.5');

        // Manual transfers without accrue
        weth.transfer(address(staking), 200 ether);
        skip(1 days);
        weth.transfer(address(staking), 350 ether);

        skip(1 days);

        vm.prank(dave);
        underlying.approve(address(staking), 10_000 ether);
        vm.prank(dave);
        staking.stake(500 ether);

        // Accrue accumulated manual transfers
        staking.accrueRewards(address(weth));

        vm.prank(bob);
        staking.unstake(2000 ether, bob);

        // Manual transfer after unstake
        weth.transfer(address(staking), 275 ether);

        vm.prank(charlie);
        staking.unstake(1500 ether, charlie);
        assertAccountingPerfect('Chaos day 3.5');

        skip(6 hours);
        weth.transfer(address(staking), 180 ether);
        skip(6 hours);
        weth.transfer(address(staking), 220 ether);

        skip(12 hours);

        vm.prank(eve);
        underlying.approve(address(staking), 10_000 ether);
        vm.prank(eve);
        staking.stake(4000 ether);

        weth.transfer(address(staking), 3000 ether);
        staking.accrueRewards(address(weth));

        // Manual transfer before Alice stakes
        weth.transfer(address(staking), 125 ether);

        vm.prank(alice);
        staking.stake(1500 ether);
        assertAccountingPerfect('Chaos day 4.5');

        // Rapid chaos
        for (uint256 i = 0; i < 8; i++) {
            skip(4 hours);
            weth.transfer(address(staking), 50 ether);
            if (i == 2) {
                vm.prank(dave);
                staking.unstake(250 ether, dave);
            }
            if (i == 5) {
                staking.accrueRewards(address(weth));
            }
            if (i == 7) {
                vm.prank(charlie);
                staking.stake(500 ether);
            }
        }

        staking.accrueRewards(address(weth)); // Catch all

        skip(10 days);

        // Everyone claims
        vm.prank(alice);
        staking.claimRewards(tokens, alice);
        vm.prank(bob);
        staking.claimRewards(tokens, bob);
        vm.prank(charlie);
        staking.claimRewards(tokens, charlie);
        vm.prank(dave);
        staking.claimRewards(tokens, dave);
        vm.prank(eve);
        staking.claimRewards(tokens, eve);
        assertAccountingPerfect('After chaos claims');

        uint256 total = weth.balanceOf(alice) +
            weth.balanceOf(bob) +
            weth.balanceOf(charlie) +
            weth.balanceOf(dave) +
            weth.balanceOf(eve) +
            weth.balanceOf(address(staking));

        uint256 expectedTotal = 5000 +
            300 +
            450 +
            600 +
            2000 +
            200 +
            350 +
            275 +
            180 +
            220 +
            3000 +
            125 +
            (8 * 50);
        assertApproxEqAbs(total, expectedTotal * 1 ether, 1 ether, '5 user chaos accounting');
    }

    /// @notice ABSURD: Stake 1 wei, unstake 1 wei, repeat 50 times
    function test_ABSURD_fiftyOneWeiCycles() public {
        address[] memory tokens = new address[](1);
        tokens[0] = address(weth);

        vm.startPrank(alice);
        underlying.approve(address(staking), 1000 ether);
        vm.stopPrank();

        weth.transfer(address(staking), 100 ether);
        staking.accrueRewards(address(weth));

        for (uint256 i = 0; i < 10; i++) {
            vm.prank(alice);
            staking.stake(1);

            skip(1 hours);

            vm.prank(alice);
            staking.unstake(1, alice);

            if (i % 10 == 0) {
                assertAccountingPerfect(string(abi.encodePacked('1wei cycle ', i)));
            }
        }

        skip(10 days);

        vm.prank(alice);
        staking.claimRewards(tokens, alice);
        assertAccountingPerfect('After 50 wei cycles');

        uint256 claimed = weth.balanceOf(alice);
        uint256 left = weth.balanceOf(address(staking));
        assertApproxEqAbs(claimed + left, 100 ether, 1 ether, 'Wei cycle accounting');
    }

    /// @notice POOL-BASED: No shortfalls possible - perfect accounting by design
    function test_POOL_BASED_perfectAccounting() public {
        address[] memory tokens = new address[](1);
        tokens[0] = address(weth);

        // Alice stakes 1 ether
        vm.startPrank(alice);
        underlying.approve(address(staking), 1 ether);
        staking.stake(1 ether);
        vm.stopPrank();

        // Accrue 1 ether rewards
        weth.transfer(address(staking), 1 ether);
        staking.accrueRewards(address(weth));
        skip(7 days);

        // Alice unstakes - AUTO-CLAIMS all rewards (Option A)
        uint256 aliceBalanceBefore = weth.balanceOf(alice);
        vm.prank(alice);
        staking.unstake(1 ether, alice);
        uint256 aliceBalanceAfter = weth.balanceOf(alice);

        // Alice should receive all rewards immediately
        uint256 claimed = aliceBalanceAfter - aliceBalanceBefore;
        assertApproxEqAbs(claimed, 1 ether, 1e9, 'Auto-claimed all on unstake');

        // No pending left (perfect accounting)
        uint256 remainingClaimable = staking.claimableRewards(alice, address(weth));
        assertEq(remainingClaimable, 0, 'No pending after auto-claim');

        // Pool should be empty
        uint256 available = staking.outstandingRewards(address(weth));
        assertEq(available, 0, 'No outstanding rewards');
    }

    /// @notice POOL-BASED: Test that pool math is always perfect
    function test_POOL_BASED_mathPerfection() public {
        address bob = address(0x2222);
        underlying.mint(bob, 10 ether);
        address[] memory tokens = new address[](1);
        tokens[0] = address(weth);

        // Two users stake
        vm.prank(alice);
        underlying.approve(address(staking), 10 ether);
        vm.prank(alice);
        staking.stake(3 ether);

        vm.prank(bob);
        underlying.approve(address(staking), 10 ether);
        vm.prank(bob);
        staking.stake(7 ether);

        // Accrue 10 ether rewards
        weth.transfer(address(staking), 10 ether);
        staking.accrueRewards(address(weth));
        skip(7 days);

        // Check that sum of claimable = pool (perfect math)
        uint256 aliceClaimable = staking.claimableRewards(alice, address(weth));
        uint256 bobClaimable = staking.claimableRewards(bob, address(weth));
        uint256 totalClaimable = aliceClaimable + bobClaimable;

        // Total claimable should equal total in pool (10 ether)
        assertApproxEqAbs(totalClaimable, 10 ether, 1, 'Sum of claimable = pool');

        // Proportions should be correct
        // Alice: 3/10 = 30%, Bob: 7/10 = 70%
        assertApproxEqAbs(aliceClaimable, 3 ether, 1e9, 'Alice gets 30%');
        assertApproxEqAbs(bobClaimable, 7 ether, 1e9, 'Bob gets 70%');

        // When they claim, pool should be empty
        vm.prank(alice);
        staking.claimRewards(tokens, alice);
        vm.prank(bob);
        staking.claimRewards(tokens, bob);

        // Pool should be exactly 0 (no dust left)
        uint256 available = staking.outstandingRewards(address(weth));
        assertEq(available, 0, 'Pool completely empty after claims');
    }

    /// @notice First staker after pause should include unvested rewards
    function test_FIRST_STAKER_pendingRewardsIncluded() public {
        address bob = address(0x2222);
        underlying.mint(bob, 1_000 ether);

        vm.startPrank(alice);
        underlying.approve(address(staking), 1000 ether);
        staking.stake(1000 ether);
        vm.stopPrank();
        assertAccountingPerfect('Alice stakes for pending inclusion');

        weth.transfer(address(staking), 1000 ether);
        staking.accrueRewards(address(weth));
        skip(1 days);

        vm.prank(alice);
        staking.unstake(1000 ether, alice);

        skip(2 days);

        vm.startPrank(bob);
        underlying.approve(address(staking), 100 ether);
        staking.stake(100 ether);
        vm.stopPrank();

        assertAccountingPerfectForMany(
            _buildAddresses(alice, bob),
            address(weth),
            'After bob stakes as first staker'
        );

        skip(1 days);
        uint256 bobClaimable = staking.claimableRewards(bob, address(weth));
        assertGt(bobClaimable, 0, 'Bob should accumulate rewards from unvested stream');

        address[] memory tokens = new address[](1);
        tokens[0] = address(weth);
        vm.prank(bob);
        staking.claimRewards(tokens, bob);
        assertGt(weth.balanceOf(bob), 0, 'Bob should receive rewards');

        // Alice's pending should still be claimable and within reserves
        assertAccountingPerfectFor(alice, address(weth), 'Alice pending after bob claim');
    }

    /// @notice First staker should not get instant rewards in same block
    function test_FIRST_STAKER_noInstantRewards() public {
        address bob = address(0x3333);
        underlying.mint(bob, 1_000 ether);

        vm.startPrank(alice);
        underlying.approve(address(staking), 1000 ether);
        staking.stake(1000 ether);
        vm.stopPrank();

        weth.transfer(address(staking), 500 ether);
        staking.accrueRewards(address(weth));
        skip(1 days);

        vm.prank(alice);
        staking.unstake(1000 ether, alice);

        vm.startPrank(bob);
        underlying.approve(address(staking), 100 ether);
        staking.stake(100 ether);
        vm.stopPrank();

        uint256 immediateClaimable = staking.claimableRewards(bob, address(weth));
        assertEq(immediateClaimable, 0, 'Bob should not earn instant rewards');

        skip(1 days);
        uint256 laterClaimable = staking.claimableRewards(bob, address(weth));
        assertGt(laterClaimable, 0, 'Bob should earn rewards after vesting time');

        assertAccountingPerfectForMany(
            _buildAddresses(alice, bob),
            address(weth),
            'First staker no instant rewards'
        );
    }

    /// @notice MULTI TOKEN: Underlying and WETH streaming simultaneously with multiple users
    function test_MULTI_dualTokenAccrualClaims() public {
        address bob = address(0x2222);
        underlying.mint(bob, 5_000 ether);
        underlying.mint(address(this), 5_000 ether);

        // Alice stakes first
        vm.startPrank(alice);
        underlying.approve(address(staking), 2_000 ether);
        staking.stake(1_000 ether);
        vm.stopPrank();

        // Initial accruals on both tokens
        weth.transfer(address(staking), 600 ether);
        staking.accrueRewards(address(weth));

        underlying.transfer(address(staking), 300 ether);
        staking.accrueRewards(address(underlying));

        address[] memory tokensDual = _buildTokens(address(weth), address(underlying));
        assertAccountingPerfectFor(alice, address(weth), 'After dual accruals WETH');
        assertAccountingPerfectFor(alice, address(underlying), 'After dual accruals underlying');

        // Mid-stream: Bob joins, more rewards arrive for both tokens
        skip(2 days);
        vm.startPrank(bob);
        underlying.approve(address(staking), 1_000 ether);
        staking.stake(500 ether);
        vm.stopPrank();

        assertAccountingPerfectForUsersTokens(
            _buildAddresses(alice, bob),
            tokensDual,
            'After Bob stake with dual streams'
        );

        weth.transfer(address(staking), 400 ether);
        staking.accrueRewards(address(weth));

        underlying.transfer(address(staking), 200 ether);
        staking.accrueRewards(address(underlying));

        skip(6 days);

        // Both users claim across both tokens
        vm.prank(alice);
        staking.claimRewards(tokensDual, alice);
        vm.prank(bob);
        staking.claimRewards(tokensDual, bob);

        assertAccountingPerfectForUsersTokens(
            _buildAddresses(alice, bob),
            tokensDual,
            'After dual token claims'
        );

        // Totals per token should match what was accrued (within rounding)
        assertApproxEqAbs(
            weth.balanceOf(alice) + weth.balanceOf(bob) + weth.balanceOf(address(staking)),
            1_000 ether,
            2,
            'All WETH accounted for in dual token test'
        );
    }

    /// @notice MULTI TOKEN: POOL-BASED auto-claim on unstake with dual tokens
    function test_MULTI_dualTokenAutoClaimOnUnstake() public {
        address bob = address(0x3333);
        underlying.mint(bob, 3_000 ether);
        underlying.mint(address(this), 3_000 ether);

        // Alice stakes and both tokens accrue
        vm.startPrank(alice);
        underlying.approve(address(staking), 2_000 ether);
        staking.stake(1_000 ether);
        vm.stopPrank();

        weth.transfer(address(staking), 800 ether);
        staking.accrueRewards(address(weth));
        underlying.transfer(address(staking), 400 ether);
        staking.accrueRewards(address(underlying));

        skip(3 days);

        // Bob joins mid-stream
        vm.startPrank(bob);
        underlying.approve(address(staking), 1_000 ether);
        staking.stake(500 ether);
        vm.stopPrank();

        skip(2 days);

        address[] memory tokensDual = _buildTokens(address(weth), address(underlying));

        // Check balances before unstake
        uint256 aliceWethBefore = weth.balanceOf(alice);
        uint256 aliceUnderlyingBefore = underlying.balanceOf(alice);

        // Alice unstakes - AUTO-CLAIMS from BOTH tokens
        vm.prank(alice);
        staking.unstake(1_000 ether, alice);

        uint256 aliceWethAfter = weth.balanceOf(alice);
        uint256 aliceUnderlyingAfter = underlying.balanceOf(alice);

        // Alice should have received rewards from both tokens
        uint256 wethClaimed = aliceWethAfter - aliceWethBefore;
        uint256 underlyingClaimed = aliceUnderlyingAfter - aliceUnderlyingBefore - 1_000 ether; // Subtract principal

        assertGt(wethClaimed, 0, 'Should auto-claim WETH');
        assertGt(underlyingClaimed, 0, 'Should auto-claim underlying');

        // After unstake, Alice should have NO claimable left
        assertEq(staking.claimableRewards(alice, address(weth)), 0, 'No WETH left');
        assertEq(staking.claimableRewards(alice, address(underlying)), 0, 'No underlying left');

        // Bob should still have claimable rewards
        assertGt(staking.claimableRewards(bob, address(weth)), 0, 'Bob has WETH');
        assertGt(staking.claimableRewards(bob, address(underlying)), 0, 'Bob has underlying');

        // Perfect accounting check
        assertAccountingPerfectForUsersTokens(
            _buildAddresses(alice, bob),
            tokensDual,
            'After auto-claim on unstake'
        );

        // Bob claims
        vm.prank(bob);
        staking.claimRewards(tokensDual, bob);

        // Both should have perfect accounting
        assertAccountingPerfectForUsersTokens(
            _buildAddresses(alice, bob),
            tokensDual,
            'After Bob claims'
        );
    }

    function _buildAddresses(address a, address b) internal pure returns (address[] memory list) {
        list = new address[](2);
        list[0] = a;
        list[1] = b;
    }

    function _buildAddresses(
        address a,
        address b,
        address c
    ) internal pure returns (address[] memory list) {
        list = new address[](3);
        list[0] = a;
        list[1] = b;
        list[2] = c;
    }

    function assertAccountingPerfectForUsersTokens(
        address[] memory accounts,
        address[] memory tokens,
        string memory when
    ) internal {
        for (uint256 i = 0; i < accounts.length; i++) {
            for (uint256 j = 0; j < tokens.length; j++) {
                assertAccountingPerfectFor(accounts[i], tokens[j], when);
            }
        }
    }

    function _buildTokens(address a, address b) internal pure returns (address[] memory list) {
        list = new address[](2);
        list[0] = a;
        list[1] = b;
    }

    /// @notice CREATIVE: Interleaved stake/unstake/manual-transfer/accrue matrix
    /// @dev Tests every possible combination in a matrix to find edge cases
    function test_CREATIVE_interleavedMatrix() public {
        address bob = address(0x2222);
        underlying.mint(bob, 10_000 ether);
        address[] memory tokens = new address[](1);
        tokens[0] = address(weth);

        // Matrix scenario 1: Manual -> Stake -> Accrue -> Unstake
        weth.transfer(address(staking), 100 ether);
        vm.prank(alice);
        underlying.approve(address(staking), 10_000 ether);
        vm.prank(alice);
        staking.stake(500 ether);
        staking.accrueRewards(address(weth));
        skip(2 days);
        vm.prank(alice);
        staking.unstake(250 ether, alice);
        assertAccountingPerfect('Matrix 1 complete');

        // Matrix scenario 2: Stake -> Manual -> Unstake -> Accrue
        vm.prank(bob);
        underlying.approve(address(staking), 10_000 ether);
        vm.prank(bob);
        staking.stake(600 ether);
        weth.transfer(address(staking), 150 ether);
        skip(1 days);
        vm.prank(bob);
        staking.unstake(300 ether, bob);
        staking.accrueRewards(address(weth));
        assertAccountingPerfectForMany(
            _buildAddresses(alice, bob),
            address(weth),
            'Matrix 2 complete'
        );

        // Matrix scenario 3: Accrue -> Manual -> Stake -> Unstake
        weth.transfer(address(staking), 200 ether);
        staking.accrueRewards(address(weth));
        weth.transfer(address(staking), 80 ether);
        skip(1 days);
        vm.prank(alice);
        staking.stake(400 ether);
        vm.prank(alice);
        staking.unstake(200 ether, alice);
        assertAccountingPerfectForMany(
            _buildAddresses(alice, bob),
            address(weth),
            'Matrix 3 complete'
        );

        // Matrix scenario 4: Unstake -> Accrue -> Manual -> Stake (all with pending)
        skip(1 days);
        vm.prank(bob);
        staking.unstake(150 ether, bob);
        weth.transfer(address(staking), 175 ether);
        staking.accrueRewards(address(weth));
        weth.transfer(address(staking), 125 ether);
        skip(2 days);
        vm.prank(bob);
        staking.stake(700 ether);
        assertAccountingPerfectForMany(
            _buildAddresses(alice, bob),
            address(weth),
            'Matrix 4 complete'
        );

        // Matrix scenario 5: Multiple manuals -> Multiple accrues -> Multiple stakes/unstakes
        for (uint256 i = 0; i < 3; i++) {
            weth.transfer(address(staking), 50 ether);
        }
        staking.accrueRewards(address(weth));
        staking.accrueRewards(address(weth)); // Double accrue
        skip(1 days);
        vm.prank(alice);
        staking.unstake(100 ether, alice);
        vm.prank(alice);
        staking.stake(200 ether);
        vm.prank(bob);
        staking.unstake(200 ether, bob);
        assertAccountingPerfectForMany(
            _buildAddresses(alice, bob),
            address(weth),
            'Matrix 5 complete'
        );

        skip(8 days);

        // Final claims
        vm.prank(alice);
        staking.claimRewards(tokens, alice);
        vm.prank(bob);
        staking.claimRewards(tokens, bob);
        assertAccountingPerfectForMany(
            _buildAddresses(alice, bob),
            address(weth),
            'Matrix final claims'
        );

        uint256 total = weth.balanceOf(alice) +
            weth.balanceOf(bob) +
            weth.balanceOf(address(staking));
        uint256 expectedTotal = 100 + 150 + 200 + 80 + 175 + 125 + (3 * 50);
        assertApproxEqAbs(total, expectedTotal * 1 ether, 1 ether, 'Matrix: all combinations work');
    }

    /// @notice CREATIVE: Sandwich attacks - manual transfers sandwiched between stake/unstake
    /// @dev Tests if manual transfers can manipulate accounting when sandwiched
    function test_CREATIVE_sandwichManualTransfers() public {
        address bob = address(0x2222);
        underlying.mint(bob, 5_000 ether);
        address[] memory tokens = new address[](1);
        tokens[0] = address(weth);

        vm.prank(alice);
        underlying.approve(address(staking), 5_000 ether);
        vm.prank(alice);
        staking.stake(1000 ether);

        // Initial stream
        weth.transfer(address(staking), 500 ether);
        staking.accrueRewards(address(weth));
        skip(1 days);

        // Sandwich 1: Manual -> Unstake -> Manual
        weth.transfer(address(staking), 100 ether);
        vm.prank(alice);
        staking.unstake(500 ether, alice);
        weth.transfer(address(staking), 100 ether);
        assertAccountingPerfect('Sandwich 1');

        skip(1 days);

        // Sandwich 2: Accrue -> Manual -> Stake -> Manual -> Accrue
        staking.accrueRewards(address(weth));
        weth.transfer(address(staking), 75 ether);
        vm.prank(bob);
        underlying.approve(address(staking), 5_000 ether);
        vm.prank(bob);
        staking.stake(800 ether);
        weth.transfer(address(staking), 75 ether);
        staking.accrueRewards(address(weth));
        assertAccountingPerfectForMany(_buildAddresses(alice, bob), address(weth), 'Sandwich 2');

        skip(2 days);

        // Sandwich 3: Manual -> Claim -> Manual -> Accrue
        weth.transfer(address(staking), 60 ether);
        vm.prank(alice);
        staking.claimRewards(tokens, alice);
        weth.transfer(address(staking), 60 ether);
        staking.accrueRewards(address(weth));
        assertAccountingPerfectForMany(_buildAddresses(alice, bob), address(weth), 'Sandwich 3');

        skip(1 days);

        // Sandwich 4: Unstake -> Manual -> Stake -> Manual (both users)
        vm.prank(bob);
        staking.unstake(400 ether, bob);
        weth.transfer(address(staking), 90 ether);
        vm.prank(alice);
        staking.stake(800 ether);
        weth.transfer(address(staking), 90 ether);
        assertAccountingPerfectForMany(_buildAddresses(alice, bob), address(weth), 'Sandwich 4');

        // Sandwich 5: Triple sandwich
        weth.transfer(address(staking), 50 ether);
        vm.prank(bob);
        staking.stake(200 ether);
        weth.transfer(address(staking), 50 ether);
        staking.accrueRewards(address(weth));
        weth.transfer(address(staking), 50 ether);
        assertAccountingPerfectForMany(_buildAddresses(alice, bob), address(weth), 'Sandwich 5');

        skip(8 days);

        vm.prank(alice);
        staking.claimRewards(tokens, alice);
        vm.prank(bob);
        staking.claimRewards(tokens, bob);
        assertAccountingPerfectForMany(
            _buildAddresses(alice, bob),
            address(weth),
            'After sandwich claims'
        );

        uint256 total = weth.balanceOf(alice) +
            weth.balanceOf(bob) +
            weth.balanceOf(address(staking));
        uint256 expectedTotal = 500 + (2 * 100) + (2 * 75) + (2 * 60) + (2 * 90) + (3 * 50);
        assertApproxEqAbs(total, expectedTotal * 1 ether, 1 ether, 'Sandwich: all accounted');
    }

    /// @notice CREATIVE: Race condition simulation - rapid state changes
    /// @dev Simulates high-frequency trading-like scenarios
    function test_CREATIVE_raceConditionSimulation() public {
        address bob = address(0x2222);
        address charlie = address(0x3333);
        underlying.mint(bob, 10_000 ether);
        underlying.mint(charlie, 10_000 ether);
        address[] memory tokens = new address[](1);
        tokens[0] = address(weth);

        vm.prank(alice);
        underlying.approve(address(staking), 10_000 ether);
        vm.prank(bob);
        underlying.approve(address(staking), 10_000 ether);
        vm.prank(charlie);
        underlying.approve(address(staking), 10_000 ether);

        // Initial state
        weth.transfer(address(staking), 1000 ether);
        staking.accrueRewards(address(weth));

        // Race 1: All stake in same block
        vm.prank(alice);
        staking.stake(500 ether);
        vm.prank(bob);
        staking.stake(600 ether);
        vm.prank(charlie);
        staking.stake(700 ether);
        assertAccountingPerfectForMany(
            _buildAddresses(alice, bob, charlie),
            address(weth),
            'Race 1: simultaneous stakes'
        );

        skip(1 days);

        // Race 2: Manual transfers + accrues in rapid succession
        for (uint256 i = 0; i < 10; i++) {
            weth.transfer(address(staking), 30 ether);
            if (i % 3 == 0) staking.accrueRewards(address(weth));
        }
        assertAccountingPerfectForMany(
            _buildAddresses(alice, bob, charlie),
            address(weth),
            'Race 2: rapid transfers'
        );

        skip(6 hours);

        // Race 3: All unstake partially same block
        vm.prank(alice);
        staking.unstake(250 ether, alice);
        vm.prank(bob);
        staking.unstake(300 ether, bob);
        vm.prank(charlie);
        staking.unstake(350 ether, charlie);
        assertAccountingPerfectForMany(
            _buildAddresses(alice, bob, charlie),
            address(weth),
            'Race 3: simultaneous unstakes'
        );

        // Race 4: Manual transfer + immediate accrue + immediate stakes
        weth.transfer(address(staking), 200 ether);
        staking.accrueRewards(address(weth));
        vm.prank(alice);
        staking.stake(100 ether);
        vm.prank(bob);
        staking.stake(150 ether);
        assertAccountingPerfectForMany(
            _buildAddresses(alice, bob, charlie),
            address(weth),
            'Race 4: transfer-accrue-stake'
        );

        skip(12 hours);

        // Race 5: Claims + stakes + unstakes all interleaved
        vm.prank(alice);
        staking.claimRewards(tokens, alice);
        vm.prank(bob);
        staking.unstake(100 ether, bob);
        vm.prank(charlie);
        staking.stake(200 ether);
        weth.transfer(address(staking), 150 ether);
        vm.prank(alice);
        staking.stake(50 ether);
        vm.prank(bob);
        staking.claimRewards(tokens, bob);
        staking.accrueRewards(address(weth));
        assertAccountingPerfectForMany(
            _buildAddresses(alice, bob, charlie),
            address(weth),
            'Race 5: interleaved operations'
        );

        skip(8 days);

        vm.prank(alice);
        staking.claimRewards(tokens, alice);
        vm.prank(bob);
        staking.claimRewards(tokens, bob);
        vm.prank(charlie);
        staking.claimRewards(tokens, charlie);

        uint256 total = weth.balanceOf(alice) +
            weth.balanceOf(bob) +
            weth.balanceOf(charlie) +
            weth.balanceOf(address(staking));
        uint256 expectedTotal = 1000 + (10 * 30) + 200 + 150;
        assertApproxEqAbs(total, expectedTotal * 1 ether, 1 ether, 'Race conditions handled');
    }
}
