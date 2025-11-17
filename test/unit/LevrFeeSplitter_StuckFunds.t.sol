// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test, console2} from 'forge-std/Test.sol';
import {LevrFeeSplitter_v1} from '../../src/LevrFeeSplitter_v1.sol';
import {ILevrFeeSplitter_v1} from '../../src/interfaces/ILevrFeeSplitter_v1.sol';
import {ILevrFactory_v1} from '../../src/interfaces/ILevrFactory_v1.sol';
import {MockERC20} from '../mocks/MockERC20.sol';
import {MockClankerToken} from '../mocks/MockClankerToken.sol';

/**
 * @title LevrFeeSplitter_StuckFunds Test Suite
 * @notice Tests for stuck-funds scenarios in fee splitter contract
 * @dev Tests scenarios from USER_FLOWS.md Flow 26
 */
contract LevrFeeSplitter_StuckFundsTest is Test {
    LevrFeeSplitter_v1 internal feeSplitter;
    MockClankerToken internal clankerToken;
    MockERC20 internal weth;

    address internal tokenAdmin;
    address internal staking;
    address internal receiver1;
    address internal receiver2;

    // Mock factory
    function getProjectContracts(
        address /* clankerToken */
    ) external view returns (ILevrFactory_v1.Project memory) {
        return
            ILevrFactory_v1.Project({
                treasury: address(0),
                governor: address(0),
                staking: staking,
                stakedToken: address(0),
                verified: false
            });
    }


    function setUp() public {
        tokenAdmin = makeAddr('tokenAdmin');
        staking = makeAddr('staking');
        receiver1 = makeAddr('receiver1');
        receiver2 = makeAddr('receiver2');

        clankerToken = new MockClankerToken('Clanker', 'CLK', tokenAdmin);
        weth = new MockERC20('WETH', 'WETH');

        feeSplitter = new LevrFeeSplitter_v1(address(clankerToken), address(this), address(0));
    }

    // ============ Flow 26: Fee Splitter Stuck Funds Tests ============

    /// @notice Test that self-send configuration is allowed
    function test_selfSend_configurationAllowed() public {
        console2.log('\n=== Flow 26: Self-Send Configuration Allowed ===');

        // Configure splits with splitter as receiver
        ILevrFeeSplitter_v1.SplitConfig[] memory splits = new ILevrFeeSplitter_v1.SplitConfig[](3);
        splits[0] = ILevrFeeSplitter_v1.SplitConfig({receiver: staking, bps: 4000});
        splits[1] = ILevrFeeSplitter_v1.SplitConfig({receiver: address(feeSplitter), bps: 3000});
        splits[2] = ILevrFeeSplitter_v1.SplitConfig({receiver: receiver1, bps: 3000});

        vm.prank(tokenAdmin);
        feeSplitter.configureSplits(splits);

        console2.log('Configured with 30% to splitter itself');

        // Verify configuration accepted
        ILevrFeeSplitter_v1.SplitConfig[] memory configured = feeSplitter.getSplits();
        assertEq(configured.length, 3, 'All 3 splits configured');
        assertEq(configured[1].receiver, address(feeSplitter), 'Splitter is receiver');
        assertEq(configured[1].bps, 3000, '30% to splitter');

        console2.log('SUCCESS: Self-send configuration allowed (recoverable via recoverDust)');
    }

    /// @notice Test recovery of stuck funds via recoverDust
    function test_recoverDust_retrievesStuckFunds() public {
        console2.log('\n=== Flow 26: Recover Stuck Funds ===');

        // Configure
        ILevrFeeSplitter_v1.SplitConfig[] memory splits = new ILevrFeeSplitter_v1.SplitConfig[](1);
        splits[0] = ILevrFeeSplitter_v1.SplitConfig({receiver: staking, bps: 10000});

        vm.prank(tokenAdmin);
        feeSplitter.configureSplits(splits);

        // Simulate stuck funds (e.g., from self-send or direct transfer)
        weth.mint(address(feeSplitter), 500 ether);

        uint256 stuck = weth.balanceOf(address(feeSplitter));
        console2.log('Stuck amount:', stuck);

        // Recover
        vm.prank(tokenAdmin);
        feeSplitter.recoverDust(address(weth), receiver1);

        uint256 recovered = weth.balanceOf(receiver1);
        console2.log('Recovered amount:', recovered);

        assertEq(recovered, 500 ether, 'Should recover all stuck funds');
        assertEq(weth.balanceOf(address(feeSplitter)), 0, 'Splitter empty');

        console2.log('SUCCESS: Stuck funds recovered via recoverDust');
    }

    /// @notice Test that only token admin can recover dust
    function test_recoverDust_onlyTokenAdmin() public {
        console2.log('\n=== Flow 26: Only Token Admin Can Recover ===');

        // Configure
        ILevrFeeSplitter_v1.SplitConfig[] memory splits = new ILevrFeeSplitter_v1.SplitConfig[](1);
        splits[0] = ILevrFeeSplitter_v1.SplitConfig({receiver: staking, bps: 10000});

        vm.prank(tokenAdmin);
        feeSplitter.configureSplits(splits);

        // Create dust
        weth.mint(address(feeSplitter), 10 ether);

        // Non-admin tries to recover
        vm.prank(receiver1);
        vm.expectRevert();
        feeSplitter.recoverDust(address(weth), receiver1);

        // Admin succeeds
        vm.prank(tokenAdmin);
        feeSplitter.recoverDust(address(weth), tokenAdmin);

        assertEq(weth.balanceOf(tokenAdmin), 10 ether, 'Admin recovered dust');

        console2.log('SUCCESS: Only token admin can recover dust');
    }

    /// @notice Test rounding dust recovery
    function test_roundingDust_recovery() public {
        console2.log('\n=== Flow 26: Rounding Dust Recovery ===');

        // Configure splits
        ILevrFeeSplitter_v1.SplitConfig[] memory splits = new ILevrFeeSplitter_v1.SplitConfig[](3);
        splits[0] = ILevrFeeSplitter_v1.SplitConfig({receiver: staking, bps: 3333});
        splits[1] = ILevrFeeSplitter_v1.SplitConfig({receiver: receiver1, bps: 3333});
        splits[2] = ILevrFeeSplitter_v1.SplitConfig({receiver: receiver2, bps: 3334});

        vm.prank(tokenAdmin);
        feeSplitter.configureSplits(splits);

        // Simulate small dust
        weth.mint(address(feeSplitter), 10 wei);

        // Recover
        vm.prank(tokenAdmin);
        feeSplitter.recoverDust(address(weth), tokenAdmin);

        assertEq(weth.balanceOf(tokenAdmin), 10 wei, 'Dust recovered');
        assertEq(weth.balanceOf(address(feeSplitter)), 0, 'Splitter empty');

        console2.log('SUCCESS: Rounding dust recovered');
    }

    /// @notice Test dust recovery calculation
    function test_recoverDust_calculation() public {
        console2.log('\n=== Flow 26: Dust Recovery Calculation ===');

        // Configure
        ILevrFeeSplitter_v1.SplitConfig[] memory splits = new ILevrFeeSplitter_v1.SplitConfig[](1);
        splits[0] = ILevrFeeSplitter_v1.SplitConfig({receiver: staking, bps: 10000});

        vm.prank(tokenAdmin);
        feeSplitter.configureSplits(splits);

        // Add balance
        weth.mint(address(feeSplitter), 100 ether);

        // Recover
        vm.prank(tokenAdmin);
        feeSplitter.recoverDust(address(weth), tokenAdmin);

        uint256 recovered = weth.balanceOf(tokenAdmin);
        console2.log('Recovered amount:', recovered);

        assertEq(recovered, 100 ether, 'Recovered all balance');

        console2.log('SUCCESS: Dust recovery calculation works');
    }

    /// @notice Test that fee splitter allows any receiver configuration (validation is permissive)
    /// @dev This validates actual contract behavior - validation checks BPS sum, not receiver types
    function test_validation_allowsAnyReceiver_includingSplitterItself() public {
        console2.log('\n=== Flow 26: Validation Behavior - Permissive Receiver Check ===');

        // Test 1: Splitter as receiver is allowed
        ILevrFeeSplitter_v1.SplitConfig[] memory splits1 = new ILevrFeeSplitter_v1.SplitConfig[](1);
        splits1[0] = ILevrFeeSplitter_v1.SplitConfig({receiver: address(feeSplitter), bps: 10000});

        vm.prank(tokenAdmin);
        feeSplitter.configureSplits(splits1);

        assertEq(feeSplitter.getSplits().length, 1, 'Configuration accepted');
        console2.log('Splitter as receiver: ALLOWED');

        // Test 2: Any address as receiver is allowed (even address(0) would pass some checks)
        ILevrFeeSplitter_v1.SplitConfig[] memory splits2 = new ILevrFeeSplitter_v1.SplitConfig[](2);
        splits2[0] = ILevrFeeSplitter_v1.SplitConfig({receiver: staking, bps: 5000});
        splits2[1] = ILevrFeeSplitter_v1.SplitConfig({receiver: receiver1, bps: 5000});

        vm.prank(tokenAdmin);
        feeSplitter.configureSplits(splits2);

        assertEq(feeSplitter.getSplits().length, 2, 'Any valid receiver accepted');
        console2.log('Any receiver: ALLOWED');

        // Test 3: Only BPS sum and zero-address are validated
        ILevrFeeSplitter_v1.SplitConfig[] memory splits3 = new ILevrFeeSplitter_v1.SplitConfig[](1);
        splits3[0] = ILevrFeeSplitter_v1.SplitConfig({receiver: address(0), bps: 10000});

        vm.prank(tokenAdmin);
        vm.expectRevert(); // Should revert for zero address
        feeSplitter.configureSplits(splits3);

        console2.log('Zero address: BLOCKED (validation works)');
        console2.log('SUCCESS: Validation checks BPS sum and zero-address, not receiver logic');
    }
}
