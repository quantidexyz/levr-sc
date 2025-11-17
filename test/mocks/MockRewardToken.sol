// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {MockERC20} from './MockERC20.sol';

/**
 * @title Mock Reward Token
 * @notice Mock ERC20 token for testing fee distribution
 * @dev Simple wrapper around MockERC20 with default WETH-like naming
 */
contract MockRewardToken is MockERC20 {
    constructor() MockERC20('Mock WETH', 'MWETH') {
        // Mint initial supply to deployer
        _mint(msg.sender, 1_000_000 ether);
    }
}
