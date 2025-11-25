// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @notice Helper mock whose initialize functions always revert
contract RevertingInitializer_Mock {
    error RevertingInitializerTriggered();

    function initialize(address, address) external pure {
        revert RevertingInitializerTriggered();
    }

    function initialize(address, address, address, address[] memory) external pure {
        revert RevertingInitializerTriggered();
    }

    function initialize(address, address, address, address) external pure {
        revert RevertingInitializerTriggered();
    }

    function initialize(string memory, string memory, uint8, address, address) external pure {
        revert RevertingInitializerTriggered();
    }
}

/// @notice Mock token that reverts when queried for metadata (name/symbol/decimals)
contract RevertingMetadataToken_Mock {
    error MetadataQueryFailed();

    function name() external pure returns (string memory) {
        revert MetadataQueryFailed();
    }

    function symbol() external pure returns (string memory) {
        revert MetadataQueryFailed();
    }

    function decimals() external pure returns (uint8) {
        revert MetadataQueryFailed();
    }
}
