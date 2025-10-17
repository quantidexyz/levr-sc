// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from 'forge-std/Test.sol';
import {LevrFeeSplitter_v1} from '../../src/LevrFeeSplitter_v1.sol';
import {ILevrFeeSplitter_v1} from '../../src/interfaces/ILevrFeeSplitter_v1.sol';
import {ILevrFactory_v1} from '../../src/interfaces/ILevrFactory_v1.sol';
import {MockERC20} from '../mocks/MockERC20.sol';

/**
 * @title LevrFeeSplitterV1 Unit Tests
 * @notice Unit tests for the LevrFeeSplitter_v1 contract
 */
contract LevrFeeSplitterV1_UnitTest is Test {
    LevrFeeSplitter_v1 internal splitter;
    MockERC20 internal weth;
    MockERC20 internal clankerToken;

    address internal factory;
    address internal trustedForwarder = address(0x123);
    address internal tokenAdmin = address(0xAd1111);
    address internal staking = address(0x5a1111);
    address internal receiver1 = address(0xBEEF);
    address internal receiver2 = address(0xCAFE);

    // Mock factory functions
    function mockFactory() internal {
        factory = address(this);
    }

    function getProjectContracts(
        address /* clankerToken */
    ) external view returns (ILevrFactory_v1.Project memory) {
        return
            ILevrFactory_v1.Project({
                treasury: address(0x71111),
                governor: address(0x61111),
                staking: staking,
                stakedToken: address(0x51111)
            });
    }

    function getClankerMetadata(
        address /* clankerToken */
    ) external pure returns (ILevrFactory_v1.ClankerMetadata memory) {
        return
            ILevrFactory_v1.ClankerMetadata({
                feeLocker: address(0xF11111),
                lpLocker: address(0x1F1111),
                hook: address(0x411111),
                exists: true
            });
    }

    function setUp() public {
        mockFactory();
        weth = new MockERC20('Wrapped ETH', 'WETH');
        clankerToken = new MockERC20('Clanker Token', 'CLANK');

        splitter = new LevrFeeSplitter_v1(factory, trustedForwarder);

        // Set up mock token admin
        vm.mockCall(
            address(clankerToken),
            abi.encodeWithSignature('admin()'),
            abi.encode(tokenAdmin)
        );
    }

    // ============ Constructor Tests ============

    function test_constructor_setsFactory() public view {
        assertEq(splitter.factory(), factory, 'Factory should be set');
    }

    function test_constructor_revertsOnZeroFactory() public {
        vm.expectRevert(ILevrFeeSplitter_v1.ZeroAddress.selector);
        new LevrFeeSplitter_v1(address(0), trustedForwarder);
    }

    // ============ Split Configuration Tests ============

    function test_configureSplits_validConfiguration() public {
        ILevrFeeSplitter_v1.SplitConfig[] memory splits = new ILevrFeeSplitter_v1.SplitConfig[](2);
        splits[0] = ILevrFeeSplitter_v1.SplitConfig({receiver: staking, bps: 5000}); // 50%
        splits[1] = ILevrFeeSplitter_v1.SplitConfig({receiver: receiver1, bps: 5000}); // 50%

        vm.prank(tokenAdmin);
        splitter.configureSplits(address(clankerToken), splits);

        ILevrFeeSplitter_v1.SplitConfig[] memory stored = splitter.getSplits(address(clankerToken));
        assertEq(stored.length, 2, 'Should have 2 splits');
        assertEq(stored[0].receiver, staking, 'First receiver should be staking');
        assertEq(stored[0].bps, 5000, 'First bps should be 5000');
        assertEq(stored[1].receiver, receiver1, 'Second receiver should be receiver1');
        assertEq(stored[1].bps, 5000, 'Second bps should be 5000');
    }

    function test_configureSplits_revertsIfNotAdmin() public {
        ILevrFeeSplitter_v1.SplitConfig[] memory splits = new ILevrFeeSplitter_v1.SplitConfig[](1);
        splits[0] = ILevrFeeSplitter_v1.SplitConfig({receiver: staking, bps: 10000});

        vm.prank(address(0xBAD));
        vm.expectRevert(ILevrFeeSplitter_v1.OnlyTokenAdmin.selector);
        splitter.configureSplits(address(clankerToken), splits);
    }

    function test_configureSplits_revertsOnInvalidTotalBps() public {
        ILevrFeeSplitter_v1.SplitConfig[] memory splits = new ILevrFeeSplitter_v1.SplitConfig[](2);
        splits[0] = ILevrFeeSplitter_v1.SplitConfig({receiver: staking, bps: 5000});
        splits[1] = ILevrFeeSplitter_v1.SplitConfig({receiver: receiver1, bps: 4000}); // Total: 9000

        vm.prank(tokenAdmin);
        vm.expectRevert(ILevrFeeSplitter_v1.InvalidTotalBps.selector);
        splitter.configureSplits(address(clankerToken), splits);
    }

    function test_configureSplits_revertsOnNoReceivers() public {
        ILevrFeeSplitter_v1.SplitConfig[] memory splits = new ILevrFeeSplitter_v1.SplitConfig[](0);

        vm.prank(tokenAdmin);
        vm.expectRevert(ILevrFeeSplitter_v1.NoReceivers.selector);
        splitter.configureSplits(address(clankerToken), splits);
    }

    function test_configureSplits_revertsOnZeroAddress() public {
        ILevrFeeSplitter_v1.SplitConfig[] memory splits = new ILevrFeeSplitter_v1.SplitConfig[](1);
        splits[0] = ILevrFeeSplitter_v1.SplitConfig({receiver: address(0), bps: 10000});

        vm.prank(tokenAdmin);
        vm.expectRevert(ILevrFeeSplitter_v1.ZeroAddress.selector);
        splitter.configureSplits(address(clankerToken), splits);
    }

    function test_configureSplits_revertsOnZeroBps() public {
        ILevrFeeSplitter_v1.SplitConfig[] memory splits = new ILevrFeeSplitter_v1.SplitConfig[](1);
        splits[0] = ILevrFeeSplitter_v1.SplitConfig({receiver: staking, bps: 0});

        vm.prank(tokenAdmin);
        vm.expectRevert(ILevrFeeSplitter_v1.ZeroBps.selector);
        splitter.configureSplits(address(clankerToken), splits);
    }

    function test_configureSplits_revertsOnDuplicateStaking() public {
        ILevrFeeSplitter_v1.SplitConfig[] memory splits = new ILevrFeeSplitter_v1.SplitConfig[](3);
        splits[0] = ILevrFeeSplitter_v1.SplitConfig({receiver: staking, bps: 3000}); // 30%
        splits[1] = ILevrFeeSplitter_v1.SplitConfig({receiver: receiver1, bps: 4000}); // 40%
        splits[2] = ILevrFeeSplitter_v1.SplitConfig({receiver: staking, bps: 3000}); // 30% (duplicate!)

        vm.prank(tokenAdmin);
        vm.expectRevert(ILevrFeeSplitter_v1.DuplicateStakingReceiver.selector);
        splitter.configureSplits(address(clankerToken), splits);
    }

    function test_configureSplits_allowsMultipleReceivers() public {
        ILevrFeeSplitter_v1.SplitConfig[] memory splits = new ILevrFeeSplitter_v1.SplitConfig[](4);
        splits[0] = ILevrFeeSplitter_v1.SplitConfig({receiver: staking, bps: 4000}); // 40%
        splits[1] = ILevrFeeSplitter_v1.SplitConfig({receiver: receiver1, bps: 3000}); // 30%
        splits[2] = ILevrFeeSplitter_v1.SplitConfig({receiver: receiver2, bps: 2000}); // 20%
        splits[3] = ILevrFeeSplitter_v1.SplitConfig({receiver: address(0xDEAD), bps: 1000}); // 10%

        vm.prank(tokenAdmin);
        splitter.configureSplits(address(clankerToken), splits);

        ILevrFeeSplitter_v1.SplitConfig[] memory stored = splitter.getSplits(address(clankerToken));
        assertEq(stored.length, 4, 'Should have 4 splits');
    }

    function test_configureSplits_canReconfigure() public {
        // Initial configuration
        ILevrFeeSplitter_v1.SplitConfig[] memory splits1 = new ILevrFeeSplitter_v1.SplitConfig[](2);
        splits1[0] = ILevrFeeSplitter_v1.SplitConfig({receiver: staking, bps: 5000});
        splits1[1] = ILevrFeeSplitter_v1.SplitConfig({receiver: receiver1, bps: 5000});

        vm.prank(tokenAdmin);
        splitter.configureSplits(address(clankerToken), splits1);

        // Reconfigure
        ILevrFeeSplitter_v1.SplitConfig[] memory splits2 = new ILevrFeeSplitter_v1.SplitConfig[](2);
        splits2[0] = ILevrFeeSplitter_v1.SplitConfig({receiver: staking, bps: 8000}); // 80%
        splits2[1] = ILevrFeeSplitter_v1.SplitConfig({receiver: receiver1, bps: 2000}); // 20%

        vm.prank(tokenAdmin);
        splitter.configureSplits(address(clankerToken), splits2);

        ILevrFeeSplitter_v1.SplitConfig[] memory stored = splitter.getSplits(address(clankerToken));
        assertEq(stored[0].bps, 8000, 'Should update to 80%');
        assertEq(stored[1].bps, 2000, 'Should update to 20%');
    }

    // ============ View Function Tests ============

    function test_getTotalBps_returnsCorrectTotal() public {
        ILevrFeeSplitter_v1.SplitConfig[] memory splits = new ILevrFeeSplitter_v1.SplitConfig[](3);
        splits[0] = ILevrFeeSplitter_v1.SplitConfig({receiver: staking, bps: 4000});
        splits[1] = ILevrFeeSplitter_v1.SplitConfig({receiver: receiver1, bps: 3000});
        splits[2] = ILevrFeeSplitter_v1.SplitConfig({receiver: receiver2, bps: 3000});

        vm.prank(tokenAdmin);
        splitter.configureSplits(address(clankerToken), splits);

        assertEq(splitter.getTotalBps(address(clankerToken)), 10000, 'Total bps should be 10000');
    }

    function test_isSplitsConfigured_returnsTrueWhenValid() public {
        ILevrFeeSplitter_v1.SplitConfig[] memory splits = new ILevrFeeSplitter_v1.SplitConfig[](1);
        splits[0] = ILevrFeeSplitter_v1.SplitConfig({receiver: staking, bps: 10000});

        vm.prank(tokenAdmin);
        splitter.configureSplits(address(clankerToken), splits);

        assertTrue(
            splitter.isSplitsConfigured(address(clankerToken)),
            'Splits should be configured'
        );
    }

    function test_isSplitsConfigured_returnsFalseWhenNotConfigured() public view {
        assertFalse(
            splitter.isSplitsConfigured(address(clankerToken)),
            'Splits should not be configured'
        );
    }

    function test_getStakingAddress_returnsCorrectAddress() public view {
        assertEq(
            splitter.getStakingAddress(address(clankerToken)),
            staking,
            'Should return staking address'
        );
    }

    function test_pendingFees_returnsContractBalance() public {
        // Transfer tokens to splitter
        weth.mint(address(splitter), 1000 ether);

        assertEq(
            splitter.pendingFees(address(clankerToken), address(weth)),
            1000 ether,
            'Pending fees should match balance'
        );
    }

    function test_getDistributionState_returnsCorrectState() public view {
        ILevrFeeSplitter_v1.DistributionState memory state = splitter.getDistributionState(
            address(clankerToken),
            address(weth)
        );
        assertEq(state.totalDistributed, 0, 'Total distributed should be 0');
        assertEq(state.lastDistribution, 0, 'Last distribution should be 0');
    }

    // ============ Distribution Tests ============

    function test_distribute_revertsWhenSplitsNotConfigured() public {
        // Mock LP locker to avoid call errors
        vm.mockCall(
            address(0x1F1111),
            abi.encodeWithSignature('collectRewards(address)', address(clankerToken)),
            abi.encode()
        );

        // Add balance to splitter so it reaches the splits check
        weth.mint(address(splitter), 1000 ether);

        vm.expectRevert(ILevrFeeSplitter_v1.SplitsNotConfigured.selector);
        splitter.distribute(address(clankerToken), address(weth));
    }

    function test_distribute_returnsEarlyWhenNoBalance() public {
        // Configure splits
        ILevrFeeSplitter_v1.SplitConfig[] memory splits = new ILevrFeeSplitter_v1.SplitConfig[](1);
        splits[0] = ILevrFeeSplitter_v1.SplitConfig({receiver: staking, bps: 10000});

        vm.prank(tokenAdmin);
        splitter.configureSplits(address(clankerToken), splits);

        // Mock LP locker to do nothing
        vm.mockCall(
            address(0x1F1111),
            abi.encodeWithSignature('collectRewards(address)', address(clankerToken)),
            abi.encode()
        );

        // Should not revert, just return early
        splitter.distribute(address(clankerToken), address(weth));
    }

    function test_distribute_distributesFees() public {
        // Configure 50/50 split
        ILevrFeeSplitter_v1.SplitConfig[] memory splits = new ILevrFeeSplitter_v1.SplitConfig[](2);
        splits[0] = ILevrFeeSplitter_v1.SplitConfig({receiver: staking, bps: 5000}); // 50%
        splits[1] = ILevrFeeSplitter_v1.SplitConfig({receiver: receiver1, bps: 5000}); // 50%

        vm.prank(tokenAdmin);
        splitter.configureSplits(address(clankerToken), splits);

        // Mock LP locker
        vm.mockCall(
            address(0x1F1111),
            abi.encodeWithSignature('collectRewards(address)', address(clankerToken)),
            abi.encode()
        );

        // Transfer tokens to splitter (simulating collectRewards)
        weth.mint(address(splitter), 1000 ether);

        uint256 stakingBefore = weth.balanceOf(staking);
        uint256 receiver1Before = weth.balanceOf(receiver1);

        splitter.distribute(address(clankerToken), address(weth));

        assertEq(weth.balanceOf(staking) - stakingBefore, 500 ether, 'Staking should get 50%');
        assertEq(
            weth.balanceOf(receiver1) - receiver1Before,
            500 ether,
            'Receiver1 should get 50%'
        );
    }

    function test_distribute_emitsEvents() public {
        // Configure splits
        ILevrFeeSplitter_v1.SplitConfig[] memory splits = new ILevrFeeSplitter_v1.SplitConfig[](2);
        splits[0] = ILevrFeeSplitter_v1.SplitConfig({receiver: staking, bps: 7000}); // 70%
        splits[1] = ILevrFeeSplitter_v1.SplitConfig({receiver: receiver1, bps: 3000}); // 30%

        vm.prank(tokenAdmin);
        splitter.configureSplits(address(clankerToken), splits);

        // Mock LP locker
        vm.mockCall(
            address(0x1F1111),
            abi.encodeWithSignature('collectRewards(address)', address(clankerToken)),
            abi.encode()
        );

        // Transfer tokens to splitter
        weth.mint(address(splitter), 1000 ether);

        // Expect StakingDistribution event
        vm.expectEmit(true, true, false, true);
        emit ILevrFeeSplitter_v1.StakingDistribution(
            address(clankerToken),
            address(weth),
            700 ether
        );

        // Expect FeeDistributed events
        vm.expectEmit(true, true, true, true);
        emit ILevrFeeSplitter_v1.FeeDistributed(
            address(clankerToken),
            address(weth),
            staking,
            700 ether
        );

        vm.expectEmit(true, true, true, true);
        emit ILevrFeeSplitter_v1.FeeDistributed(
            address(clankerToken),
            address(weth),
            receiver1,
            300 ether
        );

        // Expect Distributed event
        vm.expectEmit(true, true, false, true);
        emit ILevrFeeSplitter_v1.Distributed(address(clankerToken), address(weth), 1000 ether);

        splitter.distribute(address(clankerToken), address(weth));
    }

    function test_distribute_updatesDistributionState() public {
        // Configure splits
        ILevrFeeSplitter_v1.SplitConfig[] memory splits = new ILevrFeeSplitter_v1.SplitConfig[](1);
        splits[0] = ILevrFeeSplitter_v1.SplitConfig({receiver: staking, bps: 10000});

        vm.prank(tokenAdmin);
        splitter.configureSplits(address(clankerToken), splits);

        // Mock LP locker
        vm.mockCall(
            address(0x1F1111),
            abi.encodeWithSignature('collectRewards(address)', address(clankerToken)),
            abi.encode()
        );

        // Transfer tokens to splitter
        weth.mint(address(splitter), 1000 ether);

        uint256 timestampBefore = block.timestamp;
        splitter.distribute(address(clankerToken), address(weth));

        ILevrFeeSplitter_v1.DistributionState memory state = splitter.getDistributionState(
            address(clankerToken),
            address(weth)
        );
        assertEq(state.totalDistributed, 1000 ether, 'Total distributed should be 1000 ether');
        assertEq(state.lastDistribution, timestampBefore, 'Last distribution should be set');
    }

    // ============ Batch Distribution Tests ============

    function test_distributeBatch_distributesMultipleTokens() public {
        MockERC20 usdc = new MockERC20('USDC', 'USDC');

        // Configure splits
        ILevrFeeSplitter_v1.SplitConfig[] memory splits = new ILevrFeeSplitter_v1.SplitConfig[](2);
        splits[0] = ILevrFeeSplitter_v1.SplitConfig({receiver: staking, bps: 6000}); // 60%
        splits[1] = ILevrFeeSplitter_v1.SplitConfig({receiver: receiver1, bps: 4000}); // 40%

        vm.prank(tokenAdmin);
        splitter.configureSplits(address(clankerToken), splits);

        // Mock LP locker
        vm.mockCall(
            address(0x1F1111),
            abi.encodeWithSignature('collectRewards(address)', address(clankerToken)),
            abi.encode()
        );

        // Transfer both tokens to splitter
        weth.mint(address(splitter), 1000 ether);
        usdc.mint(address(splitter), 5000 * 1e6); // 5000 USDC

        address[] memory tokens = new address[](2);
        tokens[0] = address(weth);
        tokens[1] = address(usdc);

        splitter.distributeBatch(address(clankerToken), tokens);

        // Check WETH distribution
        assertEq(weth.balanceOf(staking), 600 ether, 'Staking should get 60% of WETH');
        assertEq(weth.balanceOf(receiver1), 400 ether, 'Receiver1 should get 40% of WETH');

        // Check USDC distribution
        assertEq(usdc.balanceOf(staking), 3000 * 1e6, 'Staking should get 60% of USDC');
        assertEq(usdc.balanceOf(receiver1), 2000 * 1e6, 'Receiver1 should get 40% of USDC');
    }

    // ============ Edge Case Tests ============

    function test_configureSplits_withSingleReceiver100Percent() public {
        ILevrFeeSplitter_v1.SplitConfig[] memory splits = new ILevrFeeSplitter_v1.SplitConfig[](1);
        splits[0] = ILevrFeeSplitter_v1.SplitConfig({receiver: receiver1, bps: 10000}); // 100% to non-staking

        vm.prank(tokenAdmin);
        splitter.configureSplits(address(clankerToken), splits);

        assertTrue(splitter.isSplitsConfigured(address(clankerToken)), 'Should be configured');
    }

    function test_distribute_withManyReceivers() public {
        // Test with 10 receivers
        ILevrFeeSplitter_v1.SplitConfig[] memory splits = new ILevrFeeSplitter_v1.SplitConfig[](10);
        for (uint256 i = 0; i < 10; i++) {
            splits[i] = ILevrFeeSplitter_v1.SplitConfig({
                receiver: address(uint160(0x1000 + i)),
                bps: 1000 // 10% each
            });
        }

        vm.prank(tokenAdmin);
        splitter.configureSplits(address(clankerToken), splits);

        // Mock LP locker
        vm.mockCall(
            address(0x1F1111),
            abi.encodeWithSignature('collectRewards(address)', address(clankerToken)),
            abi.encode()
        );

        // Transfer tokens
        weth.mint(address(splitter), 1000 ether);

        splitter.distribute(address(clankerToken), address(weth));

        // Verify each receiver got 10%
        for (uint256 i = 0; i < 10; i++) {
            assertEq(
                weth.balanceOf(address(uint160(0x1000 + i))),
                100 ether,
                'Each receiver should get 10%'
            );
        }
    }
}
