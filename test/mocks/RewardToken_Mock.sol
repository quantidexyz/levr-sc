// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {ERC20_Mock} from './ERC20_Mock.sol';

/**
 * @title Reward Token Mock
 * @notice Mock ERC20 token for testing fee distribution
 * @dev Simple wrapper around ERC20_Mock with default WETH-like naming
 */
contract RewardToken_Mock is ERC20_Mock {
    constructor() ERC20_Mock('Mock WETH', 'MWETH') {
        // Mint initial supply to deployer
        _mint(msg.sender, 1_000_000 ether);
    }
}
