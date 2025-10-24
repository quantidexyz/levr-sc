// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from 'forge-std/Test.sol';
import {console2} from 'forge-std/console2.sol';
import {LevrFeeSplitter_v1} from '../../src/LevrFeeSplitter_v1.sol';
import {LevrFeeSplitterFactory_v1} from '../../src/LevrFeeSplitterFactory_v1.sol';
import {LevrFactory_v1} from '../../src/LevrFactory_v1.sol';
import {LevrForwarder_v1} from '../../src/LevrForwarder_v1.sol';
import {LevrStaking_v1} from '../../src/LevrStaking_v1.sol';
import {ILevrFeeSplitter_v1} from '../../src/interfaces/ILevrFeeSplitter_v1.sol';
import {ILevrFactory_v1} from '../../src/interfaces/ILevrFactory_v1.sol';
import {ILevrStaking_v1} from '../../src/interfaces/ILevrStaking_v1.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {ERC20} from '@openzeppelin/contracts/token/ERC20/ERC20.sol';

/**
 * @title Mock Clanker Token
 * @notice Mock token for testing that tracks admin
 */
contract MockClankerToken is ERC20 {
    address public admin;

    constructor(address admin_) ERC20('Mock Clanker', 'MCLK') {
        admin = admin_;
        _mint(msg.sender, 1_000_000 ether);
    }
}

/**
 * @title Mock Reward Token
 * @notice Mock ERC20 for testing fee distribution
 */
contract MockRewardToken is ERC20 {
    constructor() ERC20('Mock WETH', 'MWETH') {
        _mint(msg.sender, 1_000_000 ether);
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/**
 * @title Mock Staking Contract
 * @notice Mock staking that can revert accrueRewards for testing
 */
contract MockStaking is ILevrStaking_v1 {
    bool public shouldRevertOnAccrue;

    function setShouldRevertOnAccrue(bool _shouldRevert) external {
        shouldRevertOnAccrue = _shouldRevert;
    }

    function accrueRewards(address) external {
        if (shouldRevertOnAccrue) {
            revert('Mock: Accrual failed');
        }
    }

    // Minimal implementation for interface compliance
    function stake(uint256) external {}
    function unstake(uint256, address) external returns (uint256) {
        return 0;
    }
    function claimRewards(address[] calldata, address) external {}
    function accrueFromTreasury(address, uint256, bool) external {}
    function outstandingRewards(address) external view returns (uint256, uint256) {
        return (0, 0);
    }
    function claimableRewards(address, address) external view returns (uint256) {
        return 0;
    }
    function stakeStartTime(address) external view returns (uint256) {
        return 0;
    }
    function getVotingPower(address) external view returns (uint256) {
        return 0;
    }
    function initialize(address, address, address, address) external {}
    function streamWindowSeconds() external view returns (uint32) {
        return 0;
    }
    function streamStart() external view returns (uint64) {
        return 0;
    }
    function streamEnd() external view returns (uint64) {
        return 0;
    }
    function rewardRatePerSecond(address) external view returns (uint256) {
        return 0;
    }
    function aprBps() external view returns (uint256) {
        return 0;
    }
    function stakedBalanceOf(address) external view returns (uint256) {
        return 0;
    }
    function totalStaked() external view returns (uint256) {
        return 0;
    }
    function escrowBalance(address) external view returns (uint256) {
        return 0;
    }
}

/**
 * @title Mock LP Locker
 * @notice Minimal mock for LP locker contract calls
 */
contract MockLpLocker {
    function collectRewards(address) external {
        // Do nothing - just needs to not revert
    }
}

/**
 * @title Mock Factory
 * @notice Mock factory for testing
 */
contract MockFactory {
    address public clankerToken;
    address public staking;
    address public lpLocker;
    bool public metadataExists;

    function setProject(address _clankerToken, address _staking, address _lpLocker) external {
        clankerToken = _clankerToken;
        staking = _staking;
        lpLocker = _lpLocker;
        metadataExists = true;
    }

    function getProjectContracts(address) external view returns (ILevrFactory_v1.Project memory) {
        return
            ILevrFactory_v1.Project({
                treasury: address(0),
                governor: address(0),
                staking: staking,
                stakedToken: address(0)
            });
    }

    function getClankerMetadata(
        address
    ) external view returns (ILevrFactory_v1.ClankerMetadata memory) {
        return
            ILevrFactory_v1.ClankerMetadata({
                feeLocker: address(0),
                lpLocker: lpLocker,
                hook: address(0),
                exists: metadataExists
            });
    }
}

/**
 * @title LevrFeeSplitterV1 Unit Tests
 * @notice Comprehensive unit tests for fee splitter security and functionality
 */
contract LevrFeeSplitterV1Test is Test {
    LevrFeeSplitter_v1 public splitter;
    MockClankerToken public clankerToken;
    MockRewardToken public rewardToken;
    MockStaking public staking;
    MockLpLocker public lpLocker;
    MockFactory public factory;
    LevrForwarder_v1 public forwarder;

    address public tokenAdmin = address(0xADDD);
    address public alice = address(0xA11CE);
    address public bob = address(0xB0B);
    address public charlie = address(0xCCC);

    function setUp() public {
        // Deploy mocks
        clankerToken = new MockClankerToken(tokenAdmin);
        rewardToken = new MockRewardToken();
        staking = new MockStaking();
        lpLocker = new MockLpLocker();
        factory = new MockFactory();
        forwarder = new LevrForwarder_v1('LevrForwarder_v1');

        // Setup factory
        factory.setProject(address(clankerToken), address(staking), address(lpLocker));

        // Deploy fee splitter
        splitter = new LevrFeeSplitter_v1(
            address(clankerToken),
            address(factory),
            address(forwarder)
        );
    }

    // ============ Split Configuration Tests (6 tests) ============

    function test_configureSplits_validConfig_succeeds() public {
        ILevrFeeSplitter_v1.SplitConfig[] memory splits = new ILevrFeeSplitter_v1.SplitConfig[](2);
        splits[0] = ILevrFeeSplitter_v1.SplitConfig({receiver: address(staking), bps: 5000});
        splits[1] = ILevrFeeSplitter_v1.SplitConfig({receiver: alice, bps: 5000});

        vm.prank(tokenAdmin);
        splitter.configureSplits(splits);

        assertTrue(splitter.isSplitsConfigured(), 'Splits should be configured');
        assertEq(splitter.getTotalBps(), 10_000, 'Total should be 10,000 bps');
    }

    function test_configureSplits_invalidTotal_reverts() public {
        ILevrFeeSplitter_v1.SplitConfig[] memory splits = new ILevrFeeSplitter_v1.SplitConfig[](2);
        splits[0] = ILevrFeeSplitter_v1.SplitConfig({receiver: address(staking), bps: 6000});
        splits[1] = ILevrFeeSplitter_v1.SplitConfig({receiver: alice, bps: 5000}); // Total 11,000

        vm.prank(tokenAdmin);
        vm.expectRevert(ILevrFeeSplitter_v1.InvalidTotalBps.selector);
        splitter.configureSplits(splits);
    }

    function test_configureSplits_zeroReceiver_reverts() public {
        ILevrFeeSplitter_v1.SplitConfig[] memory splits = new ILevrFeeSplitter_v1.SplitConfig[](2);
        splits[0] = ILevrFeeSplitter_v1.SplitConfig({receiver: address(0), bps: 5000});
        splits[1] = ILevrFeeSplitter_v1.SplitConfig({receiver: alice, bps: 5000});

        vm.prank(tokenAdmin);
        vm.expectRevert(ILevrFeeSplitter_v1.ZeroAddress.selector);
        splitter.configureSplits(splits);
    }

    function test_configureSplits_zeroBps_reverts() public {
        ILevrFeeSplitter_v1.SplitConfig[] memory splits = new ILevrFeeSplitter_v1.SplitConfig[](2);
        splits[0] = ILevrFeeSplitter_v1.SplitConfig({receiver: address(staking), bps: 0});
        splits[1] = ILevrFeeSplitter_v1.SplitConfig({receiver: alice, bps: 10_000});

        vm.prank(tokenAdmin);
        vm.expectRevert(ILevrFeeSplitter_v1.ZeroBps.selector);
        splitter.configureSplits(splits);
    }

    function test_configureSplits_duplicateReceiver_reverts() public {
        ILevrFeeSplitter_v1.SplitConfig[] memory splits = new ILevrFeeSplitter_v1.SplitConfig[](2);
        splits[0] = ILevrFeeSplitter_v1.SplitConfig({receiver: alice, bps: 5000});
        splits[1] = ILevrFeeSplitter_v1.SplitConfig({receiver: alice, bps: 5000}); // Duplicate!

        vm.prank(tokenAdmin);
        vm.expectRevert(ILevrFeeSplitter_v1.DuplicateReceiver.selector);
        splitter.configureSplits(splits);
    }

    function test_configureSplits_tooManyReceivers_reverts() public {
        // Create 21 receivers (exceeds MAX_RECEIVERS = 20)
        ILevrFeeSplitter_v1.SplitConfig[] memory splits = new ILevrFeeSplitter_v1.SplitConfig[](21);
        for (uint256 i = 0; i < 21; i++) {
            splits[i] = ILevrFeeSplitter_v1.SplitConfig({
                receiver: address(uint160(i + 1)),
                bps: 476 // 21 * 476 = 9996, close to 10000
            });
        }
        splits[20].bps = 480; // Adjust last one to total exactly 10000

        vm.prank(tokenAdmin);
        vm.expectRevert(ILevrFeeSplitter_v1.TooManyReceivers.selector);
        splitter.configureSplits(splits);
    }

    // ============ Access Control Tests (2 tests) ============

    function test_configureSplits_onlyTokenAdmin() public {
        ILevrFeeSplitter_v1.SplitConfig[] memory splits = new ILevrFeeSplitter_v1.SplitConfig[](1);
        splits[0] = ILevrFeeSplitter_v1.SplitConfig({receiver: alice, bps: 10_000});

        vm.prank(alice); // Not token admin
        vm.expectRevert(ILevrFeeSplitter_v1.OnlyTokenAdmin.selector);
        splitter.configureSplits(splits);
    }

    function test_recoverDust_onlyTokenAdmin() public {
        vm.prank(alice); // Not token admin
        vm.expectRevert(ILevrFeeSplitter_v1.OnlyTokenAdmin.selector);
        splitter.recoverDust(address(rewardToken), alice);
    }

    // ============ Distribution Logic Tests (6 tests) ============

    function test_distribute_splitsCorrectly() public {
        // Configure 60/40 split
        ILevrFeeSplitter_v1.SplitConfig[] memory splits = new ILevrFeeSplitter_v1.SplitConfig[](2);
        splits[0] = ILevrFeeSplitter_v1.SplitConfig({receiver: address(staking), bps: 6000});
        splits[1] = ILevrFeeSplitter_v1.SplitConfig({receiver: alice, bps: 4000});

        vm.prank(tokenAdmin);
        splitter.configureSplits(splits);

        // Send 1000 tokens to splitter
        rewardToken.transfer(address(splitter), 1000 ether);

        // Distribute
        splitter.distribute(address(rewardToken));

        // Verify splits
        assertEq(rewardToken.balanceOf(address(staking)), 600 ether, 'Staking should receive 60%');
        assertEq(rewardToken.balanceOf(alice), 400 ether, 'Alice should receive 40%');
    }

    function test_distribute_emitsEvents() public {
        ILevrFeeSplitter_v1.SplitConfig[] memory splits = new ILevrFeeSplitter_v1.SplitConfig[](1);
        splits[0] = ILevrFeeSplitter_v1.SplitConfig({receiver: alice, bps: 10_000});

        vm.prank(tokenAdmin);
        splitter.configureSplits(splits);

        rewardToken.transfer(address(splitter), 100 ether);

        // Expect events
        vm.expectEmit(true, true, true, true);
        emit ILevrFeeSplitter_v1.FeeDistributed(
            address(clankerToken),
            address(rewardToken),
            alice,
            100 ether
        );

        vm.expectEmit(true, true, false, true);
        emit ILevrFeeSplitter_v1.Distributed(
            address(clankerToken),
            address(rewardToken),
            100 ether
        );

        splitter.distribute(address(rewardToken));
    }

    function test_distribute_zeroBalance_returns() public {
        ILevrFeeSplitter_v1.SplitConfig[] memory splits = new ILevrFeeSplitter_v1.SplitConfig[](1);
        splits[0] = ILevrFeeSplitter_v1.SplitConfig({receiver: alice, bps: 10_000});

        vm.prank(tokenAdmin);
        splitter.configureSplits(splits);

        // No fees in splitter - should return early without revert
        splitter.distribute(address(rewardToken));

        assertEq(rewardToken.balanceOf(alice), 0, 'Alice should receive nothing');
    }

    function test_distribute_autoAccrualSuccess() public {
        ILevrFeeSplitter_v1.SplitConfig[] memory splits = new ILevrFeeSplitter_v1.SplitConfig[](1);
        splits[0] = ILevrFeeSplitter_v1.SplitConfig({receiver: address(staking), bps: 10_000});

        vm.prank(tokenAdmin);
        splitter.configureSplits(splits);

        rewardToken.transfer(address(splitter), 100 ether);

        // Expect auto-accrual success event
        vm.expectEmit(true, true, false, false);
        emit ILevrFeeSplitter_v1.AutoAccrualSuccess(address(clankerToken), address(rewardToken));

        splitter.distribute(address(rewardToken));
    }

    function test_distribute_autoAccrualFails_continuesDistribution() public {
        ILevrFeeSplitter_v1.SplitConfig[] memory splits = new ILevrFeeSplitter_v1.SplitConfig[](1);
        splits[0] = ILevrFeeSplitter_v1.SplitConfig({receiver: address(staking), bps: 10_000});

        vm.prank(tokenAdmin);
        splitter.configureSplits(splits);

        // Make staking revert on accrueRewards
        staking.setShouldRevertOnAccrue(true);

        rewardToken.transfer(address(splitter), 100 ether);

        // Expect auto-accrual failed event (but distribution should continue!)
        vm.expectEmit(true, true, false, false);
        emit ILevrFeeSplitter_v1.AutoAccrualFailed(address(clankerToken), address(rewardToken));

        // Should NOT revert - distribution completes despite accrual failure
        splitter.distribute(address(rewardToken));

        // Verify fees were still distributed
        assertEq(
            rewardToken.balanceOf(address(staking)),
            100 ether,
            'Staking should still receive fees'
        );
    }

    function test_distributeBatch_multipleTokens() public {
        MockRewardToken token2 = new MockRewardToken();

        ILevrFeeSplitter_v1.SplitConfig[] memory splits = new ILevrFeeSplitter_v1.SplitConfig[](2);
        splits[0] = ILevrFeeSplitter_v1.SplitConfig({receiver: alice, bps: 5000});
        splits[1] = ILevrFeeSplitter_v1.SplitConfig({receiver: bob, bps: 5000});

        vm.prank(tokenAdmin);
        splitter.configureSplits(splits);

        // Send two different tokens
        rewardToken.transfer(address(splitter), 1000 ether);
        token2.transfer(address(splitter), 500 ether);

        // Batch distribute
        address[] memory tokens = new address[](2);
        tokens[0] = address(rewardToken);
        tokens[1] = address(token2);

        splitter.distributeBatch(tokens);

        // Verify both distributed correctly
        assertEq(rewardToken.balanceOf(alice), 500 ether, 'Alice should get 50% of token1');
        assertEq(rewardToken.balanceOf(bob), 500 ether, 'Bob should get 50% of token1');
        assertEq(token2.balanceOf(alice), 250 ether, 'Alice should get 50% of token2');
        assertEq(token2.balanceOf(bob), 250 ether, 'Bob should get 50% of token2');
    }

    /**
     * @notice Test that simulates UI scenario: both receivers get both tokens
     * @dev This test verifies the bug found in UI testing where receivers only got one token type
     */
    function test_distributeBatch_bothReceiversGetBothTokens() public {
        // Setup: Create wrapped ETH token to simulate real scenario
        MockRewardToken wrappedETH = new MockRewardToken();

        // Configure splits: 60% staking, 40% deployer (tokenAdmin)
        ILevrFeeSplitter_v1.SplitConfig[] memory splits = new ILevrFeeSplitter_v1.SplitConfig[](2);
        splits[0] = ILevrFeeSplitter_v1.SplitConfig({receiver: address(staking), bps: 6000});
        splits[1] = ILevrFeeSplitter_v1.SplitConfig({receiver: tokenAdmin, bps: 4000});

        vm.prank(tokenAdmin);
        splitter.configureSplits(splits);

        // Simulate accumulated fees from Clanker token and wrapped ETH
        uint256 clankerFees = 1000 ether;
        uint256 wrappedETHFees = 5 ether;

        // Transfer fees to splitter (simulating fee accumulation)
        clankerToken.transfer(address(splitter), clankerFees);
        wrappedETH.transfer(address(splitter), wrappedETHFees);

        // Record balances before distribution
        uint256 stakingClankerBefore = clankerToken.balanceOf(address(staking));
        uint256 stakingWrappedETHBefore = wrappedETH.balanceOf(address(staking));
        uint256 deployerClankerBefore = clankerToken.balanceOf(tokenAdmin);
        uint256 deployerWrappedETHBefore = wrappedETH.balanceOf(tokenAdmin);

        // Distribute both tokens via batch
        address[] memory tokens = new address[](2);
        tokens[0] = address(clankerToken);
        tokens[1] = address(wrappedETH);

        splitter.distributeBatch(tokens);

        // Calculate expected amounts
        uint256 expectedStakingClanker = (clankerFees * 6000) / 10_000; // 600 ether
        uint256 expectedDeployerClanker = (clankerFees * 4000) / 10_000; // 400 ether
        uint256 expectedStakingWrappedETH = (wrappedETHFees * 6000) / 10_000; // 3 ether
        uint256 expectedDeployerWrappedETH = (wrappedETHFees * 4000) / 10_000; // 2 ether

        // ========================================
        // CRITICAL ASSERTIONS: Both receivers MUST get BOTH tokens
        // ========================================

        // Verify staking pool received BOTH tokens
        assertEq(
            clankerToken.balanceOf(address(staking)) - stakingClankerBefore,
            expectedStakingClanker,
            'Staking MUST receive Clanker token fees'
        );
        assertEq(
            wrappedETH.balanceOf(address(staking)) - stakingWrappedETHBefore,
            expectedStakingWrappedETH,
            'Staking MUST receive wrapped ETH fees'
        );

        // Verify deployer received BOTH tokens
        assertEq(
            clankerToken.balanceOf(tokenAdmin) - deployerClankerBefore,
            expectedDeployerClanker,
            'Deployer MUST receive Clanker token fees'
        );
        assertEq(
            wrappedETH.balanceOf(tokenAdmin) - deployerWrappedETHBefore,
            expectedDeployerWrappedETH,
            'Deployer MUST receive wrapped ETH fees'
        );

        // Verify splitter is empty after distribution
        assertEq(
            clankerToken.balanceOf(address(splitter)),
            0,
            'Splitter should have no Clanker tokens left'
        );
        assertEq(
            wrappedETH.balanceOf(address(splitter)),
            0,
            'Splitter should have no wrapped ETH left'
        );
    }

    /**
     * @notice Test individual distribute calls for multiple tokens (alternative to batch)
     * @dev Verifies that calling distribute separately for each token also works correctly
     */
    function test_distribute_multipleTokensSequentially_bothReceiversGetBothTokens() public {
        // Create wrapped ETH token
        MockRewardToken wrappedETH = new MockRewardToken();

        // Configure splits: 70% staking, 30% deployer
        ILevrFeeSplitter_v1.SplitConfig[] memory splits = new ILevrFeeSplitter_v1.SplitConfig[](2);
        splits[0] = ILevrFeeSplitter_v1.SplitConfig({receiver: address(staking), bps: 7000});
        splits[1] = ILevrFeeSplitter_v1.SplitConfig({receiver: tokenAdmin, bps: 3000});

        vm.prank(tokenAdmin);
        splitter.configureSplits(splits);

        // Send fees
        uint256 clankerFees = 2000 ether;
        uint256 wrappedETHFees = 10 ether;

        clankerToken.transfer(address(splitter), clankerFees);
        wrappedETH.transfer(address(splitter), wrappedETHFees);

        // Distribute each token separately
        splitter.distribute(address(clankerToken));
        splitter.distribute(address(wrappedETH));

        // Calculate expected amounts
        uint256 expectedStakingClanker = (clankerFees * 7000) / 10_000; // 1400 ether
        uint256 expectedDeployerClanker = (clankerFees * 3000) / 10_000; // 600 ether
        uint256 expectedStakingWrappedETH = (wrappedETHFees * 7000) / 10_000; // 7 ether
        uint256 expectedDeployerWrappedETH = (wrappedETHFees * 3000) / 10_000; // 3 ether

        // Verify both receivers got both tokens
        assertEq(
            clankerToken.balanceOf(address(staking)),
            expectedStakingClanker,
            'Staking MUST receive Clanker token fees (sequential)'
        );
        assertEq(
            wrappedETH.balanceOf(address(staking)),
            expectedStakingWrappedETH,
            'Staking MUST receive wrapped ETH fees (sequential)'
        );
        assertEq(
            clankerToken.balanceOf(tokenAdmin),
            expectedDeployerClanker,
            'Deployer MUST receive Clanker token fees (sequential)'
        );
        assertEq(
            wrappedETH.balanceOf(tokenAdmin),
            expectedDeployerWrappedETH,
            'Deployer MUST receive wrapped ETH fees (sequential)'
        );
    }

    // ============ Dust Recovery Tests (2 tests) ============

    function test_recoverDust_onlyRecoversDust() public {
        ILevrFeeSplitter_v1.SplitConfig[] memory splits = new ILevrFeeSplitter_v1.SplitConfig[](1);
        splits[0] = ILevrFeeSplitter_v1.SplitConfig({receiver: alice, bps: 10_000});

        vm.prank(tokenAdmin);
        splitter.configureSplits(splits);

        // Send fees to splitter
        rewardToken.transfer(address(splitter), 1000 ether);

        // Distribute the fees first (this leaves Alice with 1000 ether, splitter with 0)
        splitter.distribute(address(rewardToken));

        // Verify all fees were distributed
        assertEq(rewardToken.balanceOf(alice), 1000 ether, 'Alice should receive all fees');
        assertEq(rewardToken.balanceOf(address(splitter)), 0, 'Splitter should be empty');

        // Try to recover dust when there is none
        vm.prank(tokenAdmin);
        splitter.recoverDust(address(rewardToken), bob);

        // Bob should get nothing (no dust to recover)
        assertEq(rewardToken.balanceOf(bob), 0, 'Bob should not receive anything (no dust)');
    }

    function test_recoverDust_roundingDust_recovered() public {
        // Configure 3-way split that creates rounding dust: 3333 + 3333 + 3334 = 10000
        ILevrFeeSplitter_v1.SplitConfig[] memory splits = new ILevrFeeSplitter_v1.SplitConfig[](3);
        splits[0] = ILevrFeeSplitter_v1.SplitConfig({receiver: alice, bps: 3333});
        splits[1] = ILevrFeeSplitter_v1.SplitConfig({receiver: bob, bps: 3333});
        splits[2] = ILevrFeeSplitter_v1.SplitConfig({receiver: charlie, bps: 3334});

        vm.prank(tokenAdmin);
        splitter.configureSplits(splits);

        // Send an amount that will create rounding dust (e.g., 10 wei creates dust)
        rewardToken.transfer(address(splitter), 10);

        // Distribute
        splitter.distribute(address(rewardToken));

        // Calculate actual distribution
        // 10 * 3333 / 10000 = 3 (alice)
        // 10 * 3333 / 10000 = 3 (bob)
        // 10 * 3334 / 10000 = 3 (charlie)
        // Total distributed = 9, dust = 1
        uint256 aliceReceived = rewardToken.balanceOf(alice);
        uint256 bobReceived = rewardToken.balanceOf(bob);
        uint256 charlieReceived = rewardToken.balanceOf(charlie);
        uint256 totalDistributed = aliceReceived + bobReceived + charlieReceived;
        uint256 dust = 10 - totalDistributed;

        assertTrue(dust > 0, 'Should have rounding dust');
        assertEq(
            rewardToken.balanceOf(address(splitter)),
            dust,
            'Splitter should have dust remaining'
        );

        // Recover dust
        uint256 charlieBalanceBefore = rewardToken.balanceOf(charlie);

        vm.prank(tokenAdmin);
        splitter.recoverDust(address(rewardToken), charlie);

        // Verify dust recovered
        assertEq(
            rewardToken.balanceOf(charlie) - charlieBalanceBefore,
            dust,
            'Charlie should receive dust'
        );
        assertEq(rewardToken.balanceOf(address(splitter)), 0, 'Splitter should be empty');
    }

    // ============ View Functions Tests (2 tests) ============

    function test_pendingFeesInclBalance_includesBalance() public {
        // Send tokens directly to splitter (simulates balance)
        rewardToken.transfer(address(splitter), 500 ether);

        // Check pending includes balance
        uint256 pending = splitter.pendingFeesInclBalance(address(rewardToken));
        assertEq(pending, 500 ether, 'Should include contract balance');
    }

    function test_isSplitsConfigured_validatesTotal() public {
        // No splits configured yet
        assertFalse(splitter.isSplitsConfigured(), 'Should not be configured initially');

        // Configure valid splits
        ILevrFeeSplitter_v1.SplitConfig[] memory splits = new ILevrFeeSplitter_v1.SplitConfig[](1);
        splits[0] = ILevrFeeSplitter_v1.SplitConfig({receiver: alice, bps: 10_000});

        vm.prank(tokenAdmin);
        splitter.configureSplits(splits);

        assertTrue(splitter.isSplitsConfigured(), 'Should be configured after valid setup');
    }
}
