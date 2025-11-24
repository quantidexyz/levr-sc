// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from 'forge-std/Test.sol';
import {LevrForwarder_v1} from '../../src/LevrForwarder_v1.sol';
import {ILevrForwarder_v1} from '../../src/interfaces/ILevrForwarder_v1.sol';
import {ERC2771Target_Mock} from '../mocks/ERC2771Target_Mock.sol';
import {PlainReceiver_Mock} from '../mocks/PlainReceiver_Mock.sol';
import {ERC2771Forwarder} from '@openzeppelin/contracts/metatx/ERC2771Forwarder.sol';
import {MessageHashUtils} from '@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol';

contract LevrForwarder_v1_Test is Test {
    bytes32 private constant _REQUEST_TYPEHASH =
        keccak256(
            'ForwardRequest(address from,address to,uint256 value,uint256 gas,uint256 nonce,uint48 deadline,bytes data)'
        );

    LevrForwarder_v1 internal _forwarder;
    ERC2771Target_Mock internal _trustedTarget;
    PlainReceiver_Mock internal _plainTarget;
    address internal _alice = makeAddr('alice');

    receive() external payable {}

    function setUp() public {
        _forwarder = new LevrForwarder_v1('LevrForwarder_v1');
        _trustedTarget = new ERC2771Target_Mock(address(_forwarder));
        _plainTarget = new PlainReceiver_Mock();
    }

    ///////////////////////////////////////////////////////////////////////////
    // executeMulticall

    function test_ExecuteMulticall_Success() public {
        vm.deal(address(this), 1 ether);

        ILevrForwarder_v1.SingleCall[] memory calls = new ILevrForwarder_v1.SingleCall[](2);
        calls[0] = ILevrForwarder_v1.SingleCall({
            target: address(_trustedTarget),
            allowFailure: false,
            value: 0.5 ether,
            callData: abi.encodeWithSelector(ERC2771Target_Mock.execute.selector, bytes('first'))
        });
        calls[1] = ILevrForwarder_v1.SingleCall({
            target: address(_forwarder),
            allowFailure: false,
            value: 0.5 ether,
            callData: abi.encodeWithSelector(
                LevrForwarder_v1.executeTransaction.selector,
                address(_plainTarget),
                abi.encodeWithSelector(PlainReceiver_Mock.callMe.selector, bytes('second'))
            )
        });

        vm.expectEmit(true, false, false, true, address(_trustedTarget));
        emit ERC2771Target_Mock.Executed(address(this), 0.5 ether, bytes('first'));

        vm.expectEmit(true, false, false, true, address(_plainTarget));
        emit PlainReceiver_Mock.PlainExecuted(address(_forwarder), 0.5 ether, bytes('second'));

        ILevrForwarder_v1.Result[] memory results = _forwarder.executeMulticall{value: 1 ether}(
            calls
        );
        assertTrue(results[0].success);
        assertTrue(results[1].success);
    }

    function test_ExecuteMulticall_RevertIf_ValueMismatch() public {
        ILevrForwarder_v1.SingleCall[] memory calls = new ILevrForwarder_v1.SingleCall[](1);
        calls[0] = ILevrForwarder_v1.SingleCall({
            target: address(_trustedTarget),
            allowFailure: false,
            value: 1 ether,
            callData: abi.encodeWithSelector(ERC2771Target_Mock.execute.selector, bytes('data'))
        });

        vm.expectRevert(
            abi.encodeWithSelector(ILevrForwarder_v1.ValueMismatch.selector, 0, 1 ether)
        );
        _forwarder.executeMulticall{value: 0}(calls);
    }

    function test_ExecuteMulticall_RevertIf_UntrustedTarget() public {
        ILevrForwarder_v1.SingleCall[] memory calls = new ILevrForwarder_v1.SingleCall[](1);
        calls[0] = ILevrForwarder_v1.SingleCall({
            target: address(_plainTarget),
            allowFailure: false,
            value: 0,
            callData: abi.encodeWithSelector(PlainReceiver_Mock.callMe.selector, bytes('payload'))
        });

        vm.expectRevert(
            abi.encodeWithSelector(
                ERC2771Forwarder.ERC2771UntrustfulTarget.selector,
                address(_plainTarget),
                address(_forwarder)
            )
        );
        _forwarder.executeMulticall(calls);
    }

    function test_ExecuteMulticall_AllowsFailureFlag() public {
        _trustedTarget.setShouldRevert(true);

        ILevrForwarder_v1.SingleCall[] memory calls = new ILevrForwarder_v1.SingleCall[](1);
        calls[0] = ILevrForwarder_v1.SingleCall({
            target: address(_trustedTarget),
            allowFailure: true,
            value: 0,
            callData: abi.encodeWithSelector(ERC2771Target_Mock.execute.selector, bytes('boom'))
        });

        ILevrForwarder_v1.Result[] memory results = _forwarder.executeMulticall(calls);
        assertFalse(results[0].success);
    }

    ///////////////////////////////////////////////////////////////////////////
    // executeTransaction

    function test_ExecuteTransaction_RevertIf_CalledDirectly() public {
        vm.expectRevert(ILevrForwarder_v1.OnlyMulticallCanExecuteTransaction.selector);
        _forwarder.executeTransaction(address(_plainTarget), '');
    }

    ///////////////////////////////////////////////////////////////////////////
    // withdrawTrappedETH

    function test_WithdrawTrappedETH_RevertIf_NotDeployer() public {
        vm.deal(address(_forwarder), 1 ether);

        vm.prank(_alice);
        vm.expectRevert(ILevrForwarder_v1.OnlyDeployer.selector);
        _forwarder.withdrawTrappedETH();
    }

    function test_WithdrawTrappedETH_RevertIf_NoBalance() public {
        vm.expectRevert(ILevrForwarder_v1.NoETHToWithdraw.selector);
        _forwarder.withdrawTrappedETH();
    }

    function test_WithdrawTrappedETH_SendsBalanceToDeployer() public {
        vm.deal(address(_forwarder), 0.25 ether);
        uint256 beforeBal = address(this).balance;

        _forwarder.withdrawTrappedETH();

        assertEq(address(this).balance, beforeBal + 0.25 ether);
        assertEq(address(_forwarder).balance, 0);
    }

    ///////////////////////////////////////////////////////////////////////////
    // createDigest

    function test_CreateDigest_ComputesEIP712Hash() public view {
        ERC2771Forwarder.ForwardRequestData memory req = ERC2771Forwarder.ForwardRequestData({
            from: address(0xBEEF),
            to: address(_plainTarget),
            value: 1,
            gas: 123_456,
            deadline: uint48(block.timestamp + 1 days),
            data: bytes('payload'),
            signature: ''
        });

        bytes32 structHash = keccak256(
            abi.encode(
                _REQUEST_TYPEHASH,
                req.from,
                req.to,
                req.value,
                req.gas,
                _forwarder.nonces(req.from),
                req.deadline,
                keccak256(req.data)
            )
        );
        bytes32 domainSeparator = keccak256(
            abi.encode(
                keccak256(
                    'EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)'
                ),
                keccak256(bytes('LevrForwarder_v1')),
                keccak256(bytes('1')),
                block.chainid,
                address(_forwarder)
            )
        );

        bytes32 expected = MessageHashUtils.toTypedDataHash(domainSeparator, structHash);
        assertEq(_forwarder.createDigest(req), expected);
    }
}
