// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @notice Minimal Merkle helper for airdrop tests.
/// Assumes leaf encoding is keccak256(abi.encode(recipient, allocatedAmount)).
/// For a single-leaf tree, the root equals the leaf and the proof is empty.
library MerkleAirdropHelper {
    // ClankerAirdrop leaf: keccak256(bytes.concat(keccak256(abi.encode(recipient, allocatedAmount))))
    function computeClankerLeaf(
        address recipient,
        uint256 allocatedAmount
    ) internal pure returns (bytes32) {
        return
            keccak256(
                bytes.concat(keccak256(abi.encode(recipient, allocatedAmount)))
            );
    }

    function singleLeafRoot(
        address recipient,
        uint256 allocatedAmount
    ) internal pure returns (bytes32) {
        return computeClankerLeaf(recipient, allocatedAmount);
    }
}
