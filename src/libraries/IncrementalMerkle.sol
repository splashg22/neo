// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title IncrementalMerkle — append-only keccak Merkle tree of fixed depth
/// @notice Same construction as the beacon-chain deposit contract: leaves are appended left to
///         right, empty subtrees are the precomputed zero hashes, and the root is recomputed from
///         the stored left-branch frontier on every insert. Proofs are ordinary ordered sibling
///         paths (not sorted pairs), so `verify` walks `index` bit by bit.
library IncrementalMerkle {
    uint256 internal constant DEPTH = 20;

    error TreeFull();

    struct Tree {
        bytes32[DEPTH] branch;
        bytes32[DEPTH] zeros;
        uint256 count;
    }

    function init(Tree storage t) internal {
        bytes32 z = bytes32(0);
        for (uint256 i = 0; i < DEPTH; i++) {
            t.zeros[i] = z;
            z = keccak256(abi.encodePacked(z, z));
        }
    }

    function insert(Tree storage t, bytes32 leaf) internal {
        uint256 index = t.count;
        if (index >= (1 << DEPTH)) revert TreeFull();
        t.count = index + 1;
        bytes32 node = leaf;
        for (uint256 i = 0; i < DEPTH; i++) {
            if (index & 1 == 0) {
                t.branch[i] = node;
                return;
            }
            node = keccak256(abi.encodePacked(t.branch[i], node));
            index >>= 1;
        }
    }

    function root(Tree storage t) internal view returns (bytes32 node) {
        uint256 index = t.count;
        for (uint256 i = 0; i < DEPTH; i++) {
            if (index & 1 == 1) {
                node = keccak256(abi.encodePacked(t.branch[i], node));
            } else {
                node = keccak256(abi.encodePacked(node, t.zeros[i]));
            }
            index >>= 1;
        }
    }

    function verify(bytes32 leaf, uint256 index, bytes32[] calldata proof, bytes32 expected)
        internal
        pure
        returns (bool)
    {
        if (proof.length != DEPTH) return false;
        bytes32 node = leaf;
        for (uint256 i = 0; i < DEPTH; i++) {
            if (index & 1 == 1) {
                node = keccak256(abi.encodePacked(proof[i], node));
            } else {
                node = keccak256(abi.encodePacked(node, proof[i]));
            }
            index >>= 1;
        }
        return node == expected;
    }
}
