// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

interface IERC1363Receiver {
    function onTransferReceived(
        address operator,
        address from,
        uint256 value,
        bytes calldata data
    ) external returns (bytes4);
}

contract MockERC1363 is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function transferAndCall(
        address to,
        uint256 amount,
        bytes calldata data
    ) external returns (bool) {
        _transfer(msg.sender, to, amount);
        if (_isContract(to)) {
            try
                IERC1363Receiver(to).onTransferReceived(
                    msg.sender,
                    msg.sender,
                    amount,
                    data
                )
            returns (bytes4 retval) {
                require(
                    retval == IERC1363Receiver.onTransferReceived.selector,
                    "ERC1363: invalid receiver"
                );
            } catch {
                revert("ERC1363: receiver reverted");
            }
        }
        return true;
    }

    function _isContract(address account) internal view returns (bool) {
        return account.code.length > 0;
    }
}
