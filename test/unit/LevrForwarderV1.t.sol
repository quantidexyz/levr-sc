// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from 'forge-std/Test.sol';
import {LevrForwarder_v1} from '../../src/LevrForwarder_v1.sol';
import {ILevrForwarder_v1} from '../../src/interfaces/ILevrForwarder_v1.sol';
import {LevrTreasury_v1} from '../../src/LevrTreasury_v1.sol';
import {LevrStaking_v1} from '../../src/LevrStaking_v1.sol';
import {MockERC20} from '../mocks/MockERC20.sol';

/// @notice Unit tests for LevrForwarder_v1 security
/// @dev Tests security of executeTransaction and prevents address impersonation attacks
contract LevrForwarderV1_UnitTest is Test {
    LevrForwarder_v1 internal forwarder;
    LevrTreasury_v1 internal treasury;
    MockERC20 internal token;

    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);
    address internal attacker = address(0xBAD);
    address internal governor = address(0x6000001);

    function setUp() public {
        // Deploy forwarder (test contract becomes deployer)
        forwarder = new LevrForwarder_v1('LevrForwarder_v1');

        // Deploy token
        token = new MockERC20('Token', 'TKN');

        // Deploy treasury (uses forwarder)
        treasury = new LevrTreasury_v1(address(this), address(forwarder));

        // Initialize treasury with governor
        treasury.initialize(governor, address(token));

        // Fund treasury
        token.mint(address(treasury), 1000 ether);
    }

    // Allow test contract to receive ETH (for withdrawTrappedETH test)
    receive() external payable {}

    /// @notice Test that direct calls to executeTransaction are blocked
    function test_executeTransaction_revertsWhenCalledDirectly() public {
        // Attacker tries to call executeTransaction directly to impersonate governor
        bytes memory data = abi.encodeCall(treasury.transfer, (attacker, 100 ether));

        // Attempt direct call (should fail)
        vm.prank(attacker);
        vm.expectRevert(ILevrForwarder_v1.OnlyMulticallCanExecuteTransaction.selector);
        forwarder.executeTransaction(address(treasury), data);
    }

    /// @notice Test that executeTransaction works via multicall
    function test_executeTransaction_worksViaMulticall() public {
        // Create a multicall that includes executeTransaction
        ILevrForwarder_v1.SingleCall[] memory calls = new ILevrForwarder_v1.SingleCall[](1);

        // Call executeTransaction on the forwarder (calling itself)
        bytes memory innerData = abi.encodeCall(
            forwarder.executeTransaction,
            (address(token), abi.encodeCall(token.balanceOf, (address(treasury))))
        );

        calls[0] = ILevrForwarder_v1.SingleCall({
            target: address(forwarder),
            allowFailure: false,
            value: 0,
            callData: innerData
        });

        // Execute via multicall (should work)
        vm.prank(alice);
        ILevrForwarder_v1.Result[] memory results = forwarder.executeMulticall(calls);

        // Verify it succeeded
        assertTrue(results[0].success);
    }

    /// @notice Test that attacker cannot impersonate addresses via crafted calldata
    function test_cannotImpersonateAddress_viaCraftedCalldata() public {
        // Attacker crafts calldata with fake governor address appended
        bytes memory maliciousData = abi.encodePacked(
            abi.encodeCall(treasury.transfer, (attacker, 100 ether)),
            governor // Fake sender appended (last 20 bytes)
        );

        // Attempt to call treasury with malicious data
        vm.prank(attacker);
        vm.expectRevert(ILevrForwarder_v1.OnlyMulticallCanExecuteTransaction.selector);
        forwarder.executeTransaction(address(treasury), maliciousData);

        // Verify treasury balance unchanged
        assertEq(token.balanceOf(address(treasury)), 1000 ether);
        assertEq(token.balanceOf(attacker), 0);
    }

    /// @notice Test that legitimate multicall with ERC2771 appending works correctly
    function test_legitimateMulticall_withERC2771Appending() public {
        // Alice wants to query treasury via multicall (treasury trusts the forwarder)
        ILevrForwarder_v1.SingleCall[] memory calls = new ILevrForwarder_v1.SingleCall[](1);

        calls[0] = ILevrForwarder_v1.SingleCall({
            target: address(treasury),
            allowFailure: false,
            value: 0,
            callData: abi.encodeCall(treasury.underlying, ())
        });

        // Execute from alice (multicall will append alice's address via ERC2771)
        vm.prank(alice);
        ILevrForwarder_v1.Result[] memory results = forwarder.executeMulticall(calls);

        // Verify it succeeded
        assertTrue(results[0].success);

        // Decode the result
        address underlying = abi.decode(results[0].returnData, (address));
        assertEq(underlying, address(token));
    }

    /// @notice Test that only executeTransaction selector is allowed on self
    function test_forbidsOtherSelectorsOnSelf() public {
        // Try to call executeMulticall recursively (should fail)
        ILevrForwarder_v1.SingleCall[] memory innerCalls = new ILevrForwarder_v1.SingleCall[](0);

        ILevrForwarder_v1.SingleCall[] memory calls = new ILevrForwarder_v1.SingleCall[](1);
        calls[0] = ILevrForwarder_v1.SingleCall({
            target: address(forwarder),
            allowFailure: false,
            value: 0,
            callData: abi.encodeCall(forwarder.executeMulticall, (innerCalls))
        });

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                ILevrForwarder_v1.ForbiddenSelectorOnSelf.selector,
                ILevrForwarder_v1.executeMulticall.selector
            )
        );
        forwarder.executeMulticall(calls);
    }

    /// @notice Test that governor can still use normal ERC2771 flow
    function test_governor_canUseNormalERC2771Flow() public {
        // This test verifies that legitimate ERC2771 flows still work
        // Governor calls treasury.transfer via normal multicall (with address appending)

        ILevrForwarder_v1.SingleCall[] memory calls = new ILevrForwarder_v1.SingleCall[](1);
        calls[0] = ILevrForwarder_v1.SingleCall({
            target: address(treasury),
            allowFailure: false,
            value: 0,
            callData: abi.encodeCall(treasury.transfer, (alice, 100 ether))
        });

        // Execute from governor
        vm.prank(governor);
        ILevrForwarder_v1.Result[] memory results = forwarder.executeMulticall(calls);

        // Verify transfer succeeded
        assertTrue(results[0].success);
        assertEq(token.balanceOf(alice), 100 ether);
        assertEq(token.balanceOf(address(treasury)), 900 ether);
    }

    /// @notice SECURITY FIX #1: Value mismatch is now blocked
    function test_securityFix_valueMismatchBlocked() public {
        // User sends 10 ETH but only forwards 5 ETH via executeTransaction
        ILevrForwarder_v1.SingleCall[] memory calls = new ILevrForwarder_v1.SingleCall[](1);
        calls[0] = ILevrForwarder_v1.SingleCall({
            target: address(forwarder),
            allowFailure: false,
            value: 5 ether, // Only forward 5 ETH to alice
            callData: abi.encodeCall(forwarder.executeTransaction, (address(alice), ''))
        });

        // Send 10 ETH - should revert with ValueMismatch!
        vm.deal(attacker, 10 ether);
        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(ILevrForwarder_v1.ValueMismatch.selector, 10 ether, 5 ether)
        );
        forwarder.executeMulticall{value: 10 ether}(calls);
    }

    /// @notice VULNERABILITY: Insufficient ETH causes failures
    function test_VULNERABILITY_insufficientEthCausesFailures() public {
        // Try to forward more ETH than sent via executeTransaction
        ILevrForwarder_v1.SingleCall[] memory calls = new ILevrForwarder_v1.SingleCall[](2);
        calls[0] = ILevrForwarder_v1.SingleCall({
            target: address(forwarder),
            allowFailure: false,
            value: 1 ether,
            callData: abi.encodeCall(forwarder.executeTransaction, (address(alice), ''))
        });
        calls[1] = ILevrForwarder_v1.SingleCall({
            target: address(forwarder),
            allowFailure: false, // Don't allow failure
            value: 1 ether, // Try to forward 1 more ETH (doesn't exist!)
            callData: abi.encodeCall(forwarder.executeTransaction, (address(alice), ''))
        });

        // Only send 1 ETH
        vm.deal(attacker, 1 ether);
        vm.prank(attacker);

        // Second call should fail due to insufficient balance
        vm.expectRevert(); // Will revert with CallFailed
        forwarder.executeMulticall{value: 1 ether}(calls);
    }

    /// @notice SECURITY FIX #2: Reentrancy is now blocked
    function test_securityFix_reentrancyBlocked() public {
        // Deploy a malicious contract that tries to reenter via executeTransaction
        MaliciousReentrancy malicious = new MaliciousReentrancy(address(forwarder));

        // Fund the attacker
        vm.deal(attacker, 10 ether);

        // Create call to malicious contract via executeTransaction
        ILevrForwarder_v1.SingleCall[] memory calls = new ILevrForwarder_v1.SingleCall[](1);
        calls[0] = ILevrForwarder_v1.SingleCall({
            target: address(forwarder),
            allowFailure: false,
            value: 1 ether,
            callData: abi.encodeCall(
                forwarder.executeTransaction,
                (address(malicious), abi.encodeWithSignature('attack()'))
            )
        });

        // Execute - malicious contract tries to reenter but it's blocked!
        vm.prank(attacker);
        forwarder.executeMulticall{value: 1 ether}(calls);

        // ✅ Reentrancy was blocked - counter NOT incremented!
        assertEq(malicious.reentrancyCount(), 0);
    }

    /// @notice SECURITY FIX #3: Deployer can withdraw accidentally trapped ETH
    function test_securityFix_deployerCanWithdrawTrappedETH() public {
        // Simulate ETH accidentally sent to forwarder (e.g., via selfdestruct)
        vm.deal(address(forwarder), 10 ether);

        // Verify ETH is trapped
        assertEq(address(forwarder).balance, 10 ether);
        uint256 deployerBalanceBefore = address(this).balance;

        // Deployer can withdraw the trapped ETH (test contract is deployer)
        forwarder.withdrawTrappedETH();

        // Verify ETH was recovered by deployer
        assertEq(address(forwarder).balance, 0);
        assertEq(address(this).balance, deployerBalanceBefore + 10 ether);
    }

    /// @notice Test that non-deployer cannot withdraw trapped ETH
    function test_withdrawTrappedETH_onlyDeployer() public {
        // Simulate ETH accidentally sent to forwarder
        vm.deal(address(forwarder), 10 ether);

        // Alice tries to withdraw (should fail)
        vm.prank(alice);
        vm.expectRevert(ILevrForwarder_v1.OnlyDeployer.selector);
        forwarder.withdrawTrappedETH();

        // Verify ETH still trapped
        assertEq(address(forwarder).balance, 10 ether);
    }

    /// @notice Test withdrawTrappedETH reverts when no ETH
    function test_withdrawTrappedETH_revertsWhenNoETH() public {
        // Forwarder has no ETH
        assertEq(address(forwarder).balance, 0);

        // Should revert with NoETHToWithdraw
        vm.expectRevert(ILevrForwarder_v1.NoETHToWithdraw.selector);
        forwarder.withdrawTrappedETH();
    }

    /// @notice Test that value validation works correctly with exact match
    function test_valueMismatch_exactMatchWorks() public {
        // Create calls with exact value match
        ILevrForwarder_v1.SingleCall[] memory calls = new ILevrForwarder_v1.SingleCall[](2);
        calls[0] = ILevrForwarder_v1.SingleCall({
            target: address(forwarder),
            allowFailure: false,
            value: 3 ether,
            callData: abi.encodeCall(forwarder.executeTransaction, (address(alice), ''))
        });
        calls[1] = ILevrForwarder_v1.SingleCall({
            target: address(forwarder),
            allowFailure: false,
            value: 2 ether,
            callData: abi.encodeCall(forwarder.executeTransaction, (address(bob), ''))
        });

        // Send exact amount (3 + 2 = 5 ETH)
        vm.deal(attacker, 5 ether);
        vm.prank(attacker);
        forwarder.executeMulticall{value: 5 ether}(calls);

        // Verify ETH was distributed correctly
        assertEq(alice.balance, 3 ether);
        assertEq(bob.balance, 2 ether);
        assertEq(address(forwarder).balance, 0); // No ETH trapped!
    }
}

/// @notice Malicious contract that reenters executeMulticall
contract MaliciousReentrancy {
    address public forwarder;
    uint256 public reentrancyCount;

    constructor(address _forwarder) {
        forwarder = _forwarder;
    }

    function attack() external payable {
        // Try to reenter executeMulticall via executeTransaction
        ILevrForwarder_v1.SingleCall[] memory calls = new ILevrForwarder_v1.SingleCall[](1);
        calls[0] = ILevrForwarder_v1.SingleCall({
            target: address(forwarder),
            allowFailure: true,
            value: 0,
            callData: abi.encodeCall(
                ILevrForwarder_v1(forwarder).executeTransaction,
                (address(this), abi.encodeWithSignature('increment()'))
            )
        });

        // This will succeed - no reentrancy guard!
        try ILevrForwarder_v1(forwarder).executeMulticall(calls) {
            reentrancyCount++;
        } catch {}
    }

    function increment() external {
        // Successfully reentered!
    }

    receive() external payable {}
}
