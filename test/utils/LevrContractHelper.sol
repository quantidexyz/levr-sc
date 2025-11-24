// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from 'forge-std/Test.sol';
import {Clones} from '@openzeppelin/contracts/proxy/Clones.sol';
import {LevrFactory_v1} from '../../src/LevrFactory_v1.sol';
import {LevrTreasury_v1} from '../../src/LevrTreasury_v1.sol';
import {LevrStaking_v1} from '../../src/LevrStaking_v1.sol';
import {LevrGovernor_v1} from '../../src/LevrGovernor_v1.sol';
import {LevrStakedToken_v1} from '../../src/LevrStakedToken_v1.sol';
import {LevrForwarder_v1} from '../../src/LevrForwarder_v1.sol';

/// @title Levr Contract Helper
/// @notice Helper for creating initialized contract instances in unit tests using clone pattern
/// @dev Provides factory methods for creating contracts matching new clone-based architecture
contract LevrContractHelper is Test {
    // Cached implementations (deployed once, reused for all clones)
    LevrTreasury_v1 internal _treasuryImpl;
    LevrStaking_v1 internal _stakingImpl;
    LevrGovernor_v1 internal _governorImpl;

    address internal _mockFactory;
    address internal _mockForwarder;

    /// @notice Initialize the helper (call in setUp)
    function initializeHelper() internal {
        _mockFactory = address(this); // Use test contract as mock factory
        _mockForwarder = address(0x999); // Mock forwarder

        // Deploy implementation contracts (tests deploy fresh stTokens per helper call)
        _treasuryImpl = new LevrTreasury_v1(_mockFactory, _mockForwarder);
        _stakingImpl = new LevrStaking_v1(_mockFactory, _mockForwarder);
        _governorImpl = new LevrGovernor_v1(_mockFactory, _mockForwarder);
    }

    /// @notice Create a staked token instance
    /// @dev Deploys new instance (not cloned)
    function createStakedToken(
        string memory name,
        string memory symbol,
        uint8 decimals,
        address underlying,
        address staking
    ) internal returns (LevrStakedToken_v1) {
        LevrStakedToken_v1 token = new LevrStakedToken_v1(_mockFactory);
        token.initialize(name, symbol, decimals, underlying, staking);
        return token;
    }

    /// @notice Create an initialized governor instance
    /// @dev Uses clone pattern: clone implementation → initialize
    function createGovernor(
        address treasury,
        address staking,
        address stakedToken,
        address underlying
    ) internal returns (LevrGovernor_v1) {
        if (address(_governorImpl) == address(0)) initializeHelper();

        address clone = Clones.clone(address(_governorImpl));
        // Only factory can initialize - use prank to initialize as factory
        vm.prank(_mockFactory);
        LevrGovernor_v1(clone).initialize(treasury, staking, stakedToken, underlying);
        return LevrGovernor_v1(clone);
    }

    /// @notice Create an initialized staking instance
    /// @dev Uses clone pattern: clone implementation → initialize
    function createStaking(
        address underlying,
        address stakedToken,
        address treasury,
        address[] memory initialWhitelist
    ) internal returns (LevrStaking_v1) {
        if (address(_stakingImpl) == address(0)) initializeHelper();

        address clone = Clones.clone(address(_stakingImpl));
        LevrStaking_v1(clone).initialize(underlying, stakedToken, treasury, initialWhitelist);
        return LevrStaking_v1(clone);
    }

    /// @notice Create an initialized treasury instance
    /// @dev Uses clone pattern: clone implementation → initialize
    function createTreasury(
        address governor,
        address underlying
    ) internal returns (LevrTreasury_v1) {
        if (address(_treasuryImpl) == address(0)) initializeHelper();

        address clone = Clones.clone(address(_treasuryImpl));
        LevrTreasury_v1(clone).initialize(governor, underlying);
        return LevrTreasury_v1(clone);
    }
}
