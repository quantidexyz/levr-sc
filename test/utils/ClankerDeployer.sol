// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IClanker} from "../../src/interfaces/external/IClanker.sol";

/// @notice Test utility to deploy a zero-supply Clanker ERC20 via the Clanker factory on fork.
contract ClankerDeployer {
    function deployZeroSupply(
        address clankerFactory,
        address tokenAdmin,
        string memory name,
        string memory symbol
    ) external returns (address token) {
        require(clankerFactory != address(0), "NO_FACTORY");
        if (tokenAdmin == address(0)) tokenAdmin = msg.sender;
        IClanker.TokenConfig memory cfg = IClanker.TokenConfig({
            tokenAdmin: tokenAdmin,
            name: name,
            symbol: symbol,
            salt: keccak256(
                abi.encodePacked(name, symbol, block.timestamp, tokenAdmin)
            ),
            image: "",
            metadata: "",
            context: "test",
            originatingChainId: block.chainid
        });
        token = IClanker(clankerFactory).deployTokenZeroSupply(cfg);
    }
}
