// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ERC2771Context} from '@openzeppelin/contracts/metatx/ERC2771Context.sol';

contract ERC2771Target_Mock is ERC2771Context {
    event Executed(address sender, uint256 value, bytes data);

    bool public shouldRevert;

    constructor(address forwarder) ERC2771Context(forwarder) {}

    function setShouldRevert(bool flag) external {
        shouldRevert = flag;
    }

    function execute(bytes calldata payload) external payable {
        if (shouldRevert) revert('target revert');
        emit Executed(_msgSender(), msg.value, payload);
    }

    function isTrustedForwarder(address forwarder) public view override returns (bool) {
        return forwarder == trustedForwarder();
    }
}
