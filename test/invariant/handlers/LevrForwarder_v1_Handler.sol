// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {CommonBase} from 'forge-std/Base.sol';
import {StdUtils} from 'forge-std/StdUtils.sol';

import {ILevrForwarder_v1} from '../../../src/interfaces/ILevrForwarder_v1.sol';
import {LevrForwarder_v1} from '../../../src/LevrForwarder_v1.sol';
import {ERC2771Target_Mock} from '../../mocks/ERC2771Target_Mock.sol';
import {PlainReceiver_Mock} from '../../mocks/PlainReceiver_Mock.sol';

/// @notice Handler exercising LevrForwarder_v1 behaviors for invariant testing
contract LevrForwarder_v1_Handler is CommonBase, StdUtils {
    LevrForwarder_v1 public immutable forwarder;
    ERC2771Target_Mock public immutable trustedTarget;
    PlainReceiver_Mock public immutable plainTarget;

    uint256 internal _ghostSuccessfulCallEntries;
    uint256 internal _ghostSuccessfulResultEntries;

    constructor() {
        forwarder = new LevrForwarder_v1('LevrForwarder_Invariant');
        trustedTarget = new ERC2771Target_Mock(address(forwarder));
        plainTarget = new PlainReceiver_Mock();
    }

    /// @notice Execute a simple multicall against the trusted target
    function executeTrusted(uint256 valueSeed, bytes calldata payload) external {
        uint256 value = bound(valueSeed, 0, 5 ether);
        vm.deal(address(this), value);

        ILevrForwarder_v1.SingleCall[] memory calls = new ILevrForwarder_v1.SingleCall[](1);
        calls[0] = ILevrForwarder_v1.SingleCall({
            target: address(trustedTarget),
            allowFailure: false,
            value: value,
            callData: abi.encodeWithSelector(ERC2771Target_Mock.execute.selector, payload)
        });

        try forwarder.executeMulticall{value: value}(calls) returns (
            ILevrForwarder_v1.Result[] memory results
        ) {
            _ghostSuccessfulCallEntries += calls.length;
            _ghostSuccessfulResultEntries += results.length;
        } catch {}
    }

    /// @notice Execute a multicall that mixes trusted target with executeTransaction
    function executeMixed(uint256 firstValueSeed, uint256 secondValueSeed) external {
        uint256 firstValue = bound(firstValueSeed, 0, 2 ether);
        uint256 secondValue = bound(secondValueSeed, 0, 2 ether);
        uint256 total = firstValue + secondValue;
        vm.deal(address(this), total);

        ILevrForwarder_v1.SingleCall[] memory calls = new ILevrForwarder_v1.SingleCall[](2);
        calls[0] = ILevrForwarder_v1.SingleCall({
            target: address(trustedTarget),
            allowFailure: false,
            value: firstValue,
            callData: abi.encodeWithSelector(ERC2771Target_Mock.execute.selector, bytes('mixed'))
        });

        calls[1] = ILevrForwarder_v1.SingleCall({
            target: address(forwarder),
            allowFailure: false,
            value: secondValue,
            callData: abi.encodeWithSelector(
                LevrForwarder_v1.executeTransaction.selector,
                address(plainTarget),
                abi.encodeWithSelector(PlainReceiver_Mock.callMe.selector, bytes('plain'))
            )
        });

        try forwarder.executeMulticall{value: total}(calls) returns (
            ILevrForwarder_v1.Result[] memory results
        ) {
            _ghostSuccessfulCallEntries += calls.length;
            _ghostSuccessfulResultEntries += results.length;
        } catch {}
    }

    /// @notice Force deposit ETH into the forwarder and withdraw it back out
    function forceDepositAndWithdraw(uint256 amountSeed) external {
        uint256 amount = bound(amountSeed, 0, 1 ether);
        if (amount == 0) return;

        vm.deal(address(this), amount);
        new ForceSend{value: amount}(payable(address(forwarder)));

        try forwarder.withdrawTrappedETH() {
            // No-op, withdrawal success ensures balance reset
        } catch {}
    }

    function ghostSuccessfulCallEntries() external view returns (uint256) {
        return _ghostSuccessfulCallEntries;
    }

    function ghostSuccessfulResultEntries() external view returns (uint256) {
        return _ghostSuccessfulResultEntries;
    }

    receive() external payable {}
}

contract ForceSend {
    constructor(address payable target) payable {
        selfdestruct(target);
    }
}
