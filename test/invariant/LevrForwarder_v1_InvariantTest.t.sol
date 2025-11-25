// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {StdInvariant} from 'forge-std/StdInvariant.sol';
import {Test} from 'forge-std/Test.sol';

import {LevrForwarder_v1} from '../../src/LevrForwarder_v1.sol';
import {LevrForwarder_v1_Handler} from './handlers/LevrForwarder_v1_Handler.sol';

contract LevrForwarder_v1_InvariantTest is StdInvariant, Test {
    LevrForwarder_v1_Handler internal _handler;
    LevrForwarder_v1 internal _forwarder;

    function setUp() public {
        _handler = new LevrForwarder_v1_Handler();
        _forwarder = _handler.forwarder();

        targetContract(address(_handler));
    }

    /// @notice Forwarder should not retain ETH between operations
    function invariant_forwarderBalanceZero() public view {
        assertEq(address(_forwarder).balance, 0, 'Forwarder unexpectedly holds ETH');
    }

    /// @notice Deployer is immutable and must remain the handler address
    function invariant_deployerImmutable() public view {
        assertEq(_forwarder.deployer(), address(_handler), 'Deployer address changed');
    }

    /// @notice Successful results must match total requested call entries
    function invariant_resultsMatchCalls() public view {
        assertEq(
            _handler.ghostSuccessfulCallEntries(),
            _handler.ghostSuccessfulResultEntries(),
            'Result count mismatch call count'
        );
    }
}
