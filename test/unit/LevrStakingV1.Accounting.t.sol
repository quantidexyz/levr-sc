// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from 'forge-std/Test.sol';
import {LevrStaking_v1} from '../../src/LevrStaking_v1.sol';
import {LevrStakedToken_v1} from '../../src/LevrStakedToken_v1.sol';
import {ILevrStaking_v1} from '../../src/interfaces/ILevrStaking_v1.sol';
import {ILevrFactory_v1} from '../../src/interfaces/ILevrFactory_v1.sol';
import {MockERC20} from '../mocks/MockERC20.sol';

/// @title Levr Staking V1 Accounting Tests
/// @notice Comprehensive accounting tests covering all edge cases and bug scenarios
contract LevrStakingV1_Accounting is Test {
    MockERC20 internal underlying;
    MockERC20 internal weth;
    LevrStakedToken_v1 internal sToken;
    LevrStaking_v1 internal staking;
    address internal alice = address(0x1111);

    event RewardShortfall(address indexed user, address indexed token, uint256 amount);

    function setUp() public {
        underlying = new MockERC20('Token', 'TKN');
        weth = new MockERC20('WETH', 'WETH');
        staking = new LevrStaking_v1(address(0));
        sToken = new LevrStakedToken_v1('sTKN', 'sTKN', 18, address(underlying), address(staking));
        staking.initialize(address(underlying), address(sToken), address(0xBEEF), address(this));
        underlying.mint(alice, 1_000_000 ether);
        weth.mint(address(this), 1_000_000 ether);
    }

    function streamWindowSeconds() external pure returns (uint32) {
        return 7 days;
    }
    function maxRewardTokens() external pure returns (uint16) {
        return 50;
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
        uint256 tokenBalance = MockERC20(token).balanceOf(address(staking));
        (uint256 unaccounted, ) = staking.outstandingRewards(token);
        uint256 reserve = tokenBalance > unaccounted ? tokenBalance - unaccounted : 0;
        uint256 claimable = staking.claimableRewards(account, token);

        if (claimable > reserve) {
            emit log_string(when);
            emit log_named_address('  Account', account);
            emit log_named_uint('  Token Balance', tokenBalance);
            emit log_named_uint('  Unaccounted', unaccounted);
            emit log_named_uint('  Reserve', reserve);
            emit log_named_uint('  Claimable', claimable);
            emit log_named_uint('  BUG: Claimable exceeds reserve by', claimable - reserve);
            revert('ACCOUNTING BUG FOUND');
        }
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

    /// @notice CORE BUG: Unstake -> window closes -> accrue -> stake back
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

        // Alice unstakes while window is STILL OPEN
        vm.prank(alice);
        staking.unstake(1000 ether, alice);
        assertAccountingPerfect('After Alice unstakes (window still open)');

        // Window CLOSES (5 more days = 8 total)
        skip(5 days);
        assertAccountingPerfect('After window closes (no stakers)');

        // New tokens transferred and accrued
        weth.transfer(address(staking), 500 ether);
        staking.accrueRewards(address(weth));
        assertAccountingPerfect('After accrue (new window starts)');

        // Alice stakes again
        vm.prank(alice);
        staking.stake(1000 ether);
        assertAccountingPerfect('After Alice stakes back');

        // Wait for new stream to finish
        skip(8 days);
        assertAccountingPerfect('After new window closes');

        // Alice claims everything
        vm.prank(alice);
        staking.claimRewards(tokens, alice);
        assertAccountingPerfect('After Alice claims');

        uint256 claimed = weth.balanceOf(alice);
        uint256 left = weth.balanceOf(address(staking));
        uint256 total = 1000 ether + 500 ether;

        // Alice should get ALL 1500 WETH (she was sole staker)
        assertApproxEqAbs(claimed + left, total, 1 ether, 'Perfect accounting: no loss');
        assertApproxEqAbs(claimed, 1500 ether, 1 ether, 'Alice gets all rewards');
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

    /// @notice EDGE CASE: Partial unstake with pending rewards, then claim, then unstake more
    /// @dev Consolidates partial unstake tests including weird amounts
    function test_EDGE_partialUnstakeClaimUnstake() public {
        address[] memory tokens = new address[](1);
        tokens[0] = address(weth);

        vm.prank(alice);
        underlying.approve(address(staking), 2000 ether);
        vm.prank(alice);
        staking.stake(2000 ether);

        // Accrue rewards
        weth.transfer(address(staking), 1000 ether);
        staking.accrueRewards(address(weth));
        skip(3 days);
        assertAccountingPerfect('After 3 days');

        // Partial unstake (1000 out of 2000)
        vm.prank(alice);
        staking.unstake(1000 ether, alice);
        assertAccountingPerfect('After partial unstake');

        // Claim (should get pending from unstake + balance-based)
        vm.prank(alice);
        staking.claimRewards(tokens, alice);
        assertAccountingPerfect('After first claim');

        skip(2 days);

        // Partial unstake again (500 out of 1000)
        vm.prank(alice);
        staking.unstake(500 ether, alice);
        assertAccountingPerfect('After second partial unstake');

        // Test weird amount unstakes
        vm.prank(alice);
        staking.unstake(1, alice); // 1 wei
        assertAccountingPerfect('After 1 wei unstake');

        skip(1 days);

        vm.prank(alice);
        staking.unstake(123456789 gwei, alice); // weird amount
        assertAccountingPerfect('After weird unstake');

        // Claim again
        vm.prank(alice);
        staking.claimRewards(tokens, alice);
        assertAccountingPerfect('After second claim');

        skip(3 days);

        // Final unstake (rest)
        uint256 remaining = sToken.balanceOf(alice);
        vm.prank(alice);
        staking.unstake(remaining, alice);
        assertAccountingPerfect('After final unstake');

        // Final claim
        vm.prank(alice);
        staking.claimRewards(tokens, alice);
        assertAccountingPerfect('After final claim');

        uint256 claimed = weth.balanceOf(alice);
        uint256 left = weth.balanceOf(address(staking));
        assertApproxEqAbs(claimed + left, 1000 ether, 1 ether, 'All rewards claimed');
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

    /// @notice EDGE CASE: Direct transfer without accrual, then later accrue
    function test_EDGE_directTransferThenAccrue() public {
        address[] memory tokens = new address[](1);
        tokens[0] = address(weth);

        vm.prank(alice);
        underlying.approve(address(staking), 1000 ether);
        vm.prank(alice);
        staking.stake(1000 ether);

        // Direct transfer WITHOUT calling accrueRewards
        weth.transfer(address(staking), 500 ether);
        assertAccountingPerfect('After direct transfer');

        skip(2 days);

        // Another direct transfer
        weth.transfer(address(staking), 300 ether);
        assertAccountingPerfect('After second direct transfer');

        skip(1 days);

        // NOW accrue (should pick up both transfers)
        staking.accrueRewards(address(weth));
        assertAccountingPerfect('After accrueRewards');

        skip(7 days);

        vm.prank(alice);
        staking.claimRewards(tokens, alice);
        assertAccountingPerfect('After claim');

        uint256 claimed = weth.balanceOf(alice);
        uint256 left = weth.balanceOf(address(staking));
        assertApproxEqAbs(claimed + left, 800 ether, 1 ether, 'All transferred WETH claimed');
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

        assertApproxEqAbs(
            aliceClaimed + bobClaimed + charlieClaimed + left,
            3000 ether,
            1 ether,
            'All WETH distributed'
        );
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

    /// @notice DETAILED BUG CHECK: Verify exact amounts, not just totals
    function test_BUG_DETAILED_unstakeWindowClosedAccrueStake() public {
        address[] memory tokens = new address[](1);
        tokens[0] = address(weth);

        emit log_string('=== DETAILED BUG ANALYSIS ===');

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

        // Alice unstakes - should lock in ~285.71 WETH as pending
        vm.prank(alice);
        staking.unstake(1000 ether, alice);
        uint256 pendingAfterUnstake = staking.claimableRewards(alice, address(weth));
        emit log_named_uint('Pending after unstake', pendingAfterUnstake);
        assertApproxEqAbs(
            pendingAfterUnstake,
            expected2Day,
            0.1 ether,
            'Pending after unstake wrong'
        );

        // Window closes (5 more days = 7 total)
        skip(5 days);

        // Alice's pending should NOT change (she's unstaked)
        uint256 pendingAfterWindowClose = staking.claimableRewards(alice, address(weth));
        emit log_named_uint('Pending after window closes', pendingAfterWindowClose);
        assertEq(
            pendingAfterWindowClose,
            pendingAfterUnstake,
            'Pending changed after window closed!'
        );

        // New tokens arrive and accrue
        weth.transfer(address(staking), 500 ether);
        staking.accrueRewards(address(weth));

        // Alice's pending should STILL not change (not staked yet)
        uint256 pendingAfterNewAccrue = staking.claimableRewards(alice, address(weth));
        emit log_named_uint('Pending after new accrue', pendingAfterNewAccrue);
        assertEq(pendingAfterNewAccrue, pendingAfterUnstake, 'Pending changed after new accrue!');

        // Alice stakes back
        vm.prank(alice);
        staking.stake(1000 ether);

        // Alice should still have her old pending + start earning from new stream
        uint256 claimableAfterStake = staking.claimableRewards(alice, address(weth));
        emit log_named_uint('Claimable right after stake back', claimableAfterStake);
        assertApproxEqAbs(
            claimableAfterStake,
            pendingAfterUnstake,
            0.1 ether,
            'Lost pending on restake!'
        );

        // Wait 3.5 days (half of new 7 day stream)
        skip(3.5 days);
        uint256 claimableAtHalfStream = staking.claimableRewards(alice, address(weth));
        emit log_named_uint('Claimable at half of new stream', claimableAtHalfStream);

        // Should be: old pending (~285.71) + half of 500 (250) + unvested from first stream (~714.29)
        // But unvested should have been added to new stream, so total new stream is 500 + 714.29 = 1214.29
        // Half of that is 607.14
        // Total: 285.71 + 607.14 = 892.85
        uint256 unvested = 1000 ether - expected2Day; // ~714.29
        uint256 newStreamTotal = 500 ether + unvested; // ~1214.29
        uint256 halfNewStream = newStreamTotal / 2; // ~607.14
        uint256 expectedTotal = pendingAfterUnstake + halfNewStream; // ~892.85
        emit log_named_uint('Expected at half stream', expectedTotal);
        assertApproxEqAbs(
            claimableAtHalfStream,
            expectedTotal,
            1 ether,
            'Wrong amount at half stream'
        );

        // Finish stream
        skip(4 days);

        // Claim everything
        vm.prank(alice);
        staking.claimRewards(tokens, alice);

        uint256 claimed = weth.balanceOf(alice);
        uint256 left = weth.balanceOf(address(staking));

        emit log_named_uint('Final claimed', claimed);
        emit log_named_uint('Final left', left);
        emit log_named_uint('Total', claimed + left);

        // Alice should get ALL 1500 WETH (she was sole staker entire time)
        assertApproxEqAbs(claimed, 1500 ether, 1 ether, 'Alice should get all WETH');
        assertApproxEqAbs(claimed + left, 1500 ether, 1 ether, 'Total should be 1500');
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

    /// @notice ABSURD: 5 users all doing random chaos
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

        weth.transfer(address(staking), 5000 ether);
        staking.accrueRewards(address(weth));
        assertAccountingPerfect('Initial chaos');

        skip(1 days);

        vm.prank(bob);
        underlying.approve(address(staking), 10_000 ether);
        vm.prank(bob);
        staking.stake(2000 ether);

        vm.prank(alice);
        staking.unstake(500 ether, alice);
        assertAccountingPerfect('Chaos day 1');

        skip(12 hours);

        vm.prank(charlie);
        underlying.approve(address(staking), 10_000 ether);
        vm.prank(charlie);
        staking.stake(3000 ether);

        weth.transfer(address(staking), 2000 ether);
        staking.accrueRewards(address(weth));

        vm.prank(alice);
        staking.claimRewards(tokens, alice);
        assertAccountingPerfect('Chaos day 1.5');

        skip(2 days);

        vm.prank(dave);
        underlying.approve(address(staking), 10_000 ether);
        vm.prank(dave);
        staking.stake(500 ether);

        vm.prank(bob);
        staking.unstake(2000 ether, bob);

        vm.prank(charlie);
        staking.unstake(1500 ether, charlie);
        assertAccountingPerfect('Chaos day 3.5');

        skip(1 days);

        vm.prank(eve);
        underlying.approve(address(staking), 10_000 ether);
        vm.prank(eve);
        staking.stake(4000 ether);

        weth.transfer(address(staking), 3000 ether);
        staking.accrueRewards(address(weth));

        vm.prank(alice);
        staking.stake(1500 ether);
        assertAccountingPerfect('Chaos day 4.5');

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

        assertApproxEqAbs(total, 10_000 ether, 1 ether, '5 user chaos accounting');
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

        for (uint256 i = 0; i < 50; i++) {
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

    /// @notice Shortfall scenario: claimable > available should emit RewardShortfall and keep pending
    function test_SHORTFALL_claimableExceedsReserveHandled() public {
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
        skip(3.5 days);

        // Unstake to record pending rewards
        vm.prank(alice);
        staking.unstake(1 ether, alice);

        uint256 claimable = staking.claimableRewards(alice, address(weth));
        assertGt(claimable, 0, 'Pending rewards should exist');

        // Drain half the reserve to simulate mismatch discovered in UI
        uint256 balanceBefore = weth.balanceOf(address(staking));
        uint256 targetBalance = claimable / 2;
        if (balanceBefore > targetBalance) {
            vm.prank(address(staking));
            weth.transfer(address(0xDEAD), balanceBefore - targetBalance);
        }

        uint256 availableNow = weth.balanceOf(address(staking));
        assertLt(availableNow, claimable, 'Available should be lower than claimable');
        uint256 shortfall = claimable - availableNow;

        vm.expectEmit(true, true, false, true);
        emit RewardShortfall(alice, address(weth), shortfall);

        vm.prank(alice);
        staking.claimRewards(tokens, alice);

        assertEq(weth.balanceOf(alice), availableNow, 'Should receive available amount');
        uint256 remainingClaimable = staking.claimableRewards(alice, address(weth));
        assertApproxEqAbs(
            remainingClaimable,
            shortfall,
            1e9,
            'Pending updated to shortfall amount'
        );
    }

    /// @notice Shortfall scenario with multiple partial claims and refills
    function test_SHORTFALL_multiplePartialClaims() public {
        address[] memory tokens = new address[](1);
        tokens[0] = address(weth);

        vm.startPrank(alice);
        underlying.approve(address(staking), 1 ether);
        staking.stake(1 ether);
        vm.stopPrank();

        weth.transfer(address(staking), 1 ether);
        staking.accrueRewards(address(weth));
        skip(7 days);

        vm.prank(alice);
        staking.unstake(1 ether, alice);

        // Drain reserve to 0.1 ether
        uint256 contractBalance = weth.balanceOf(address(staking));
        if (contractBalance > 0.1 ether) {
            vm.prank(address(staking));
            weth.transfer(address(0xBEEF), contractBalance - 0.1 ether);
        }

        // First claim: should receive what remains (0.1 ether)
        vm.prank(alice);
        staking.claimRewards(tokens, alice);
        assertEq(weth.balanceOf(alice), 0.1 ether, 'First partial claim should transfer 0.1 ETH');

        // Refill with 0.2 ether and claim again
        weth.transfer(address(staking), 0.2 ether);
        vm.prank(alice);
        staking.claimRewards(tokens, alice);
        assertEq(weth.balanceOf(alice), 0.3 ether, 'Second claim totals 0.3 ETH');

        // Refill remaining balance and final claim
        uint256 remaining = staking.claimableRewards(alice, address(weth));
        weth.transfer(address(staking), remaining);
        vm.prank(alice);
        staking.claimRewards(tokens, alice);
        assertApproxEqAbs(weth.balanceOf(alice), 1 ether, 1e9, 'All pending claimed over time');
        assertEq(
            staking.claimableRewards(alice, address(weth)),
            0,
            'No pending left after refills'
        );
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

    /// @notice MULTI TOKEN: WETH shortfall while underlying stream continues
    function test_MULTI_dualTokenShortfallWhileStreaming() public {
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

        // Alice exits creating pending rewards on both tokens
        vm.prank(alice);
        staking.unstake(1_000 ether, alice);

        // WETH shortfall occurs (drain contract liquidity without updating reserve)
        uint256 wethClaimable = staking.claimableRewards(alice, address(weth));
        uint256 wethBalance = weth.balanceOf(address(staking));
        uint256 targetBalance = wethClaimable / 3; // leave one-third available
        if (wethBalance > targetBalance) {
            vm.prank(address(staking));
            weth.transfer(address(0xDEAD), wethBalance - targetBalance);
        }

        address[] memory tokensDual = _buildTokens(address(weth), address(underlying));

        // Claim should emit RewardShortfall for WETH while underlying remains available
        uint256 shortfall = staking.claimableRewards(alice, address(weth)) -
            weth.balanceOf(address(staking));
        vm.expectEmit(true, true, false, true);
        emit RewardShortfall(alice, address(weth), shortfall);
        vm.prank(alice);
        staking.claimRewards(tokensDual, alice);

        // At this point reserve < pending for WETH (by design). We only restore invariants after refill.

        // Refill the WETH shortfall and ensure remaining pending is payable
        weth.transfer(address(staking), shortfall);
        vm.prank(alice);
        staking.claimRewards(tokensDual, alice);

        uint256 bobOutstandingWeth = staking.claimableRewards(bob, address(weth));
        if (bobOutstandingWeth > 0) {
            weth.transfer(address(staking), bobOutstandingWeth);
            vm.prank(bob);
            staking.claimRewards(tokensDual, bob);
        }

        assertAccountingPerfectForUsersTokens(
            _buildAddresses(alice, bob),
            tokensDual,
            'After shortfall refill and final claim'
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
}
