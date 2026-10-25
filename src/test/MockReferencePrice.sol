// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IReferencePrice} from "../interfaces/IReferencePrice.sol";

/// @dev Local-chain stand-in for a reference price feed. Anyone can set; not for production.
contract MockReferencePrice is IReferencePrice {
    struct Quote {
        uint160 sqrtPriceX96;
        uint64 updatedAt;
    }

    mapping(bytes32 => Quote) public quotes;

    /// @notice Set the quote for a symbol.
    function set(bytes32 symbol, uint160 sqrtPriceX96, uint64 updatedAt) external {
        quotes[symbol] = Quote(sqrtPriceX96, updatedAt);
    }

    /// @inheritdoc IReferencePrice
    function latest(bytes32 symbol) external view returns (uint160 sqrtPriceX96, uint64 updatedAt) {
        Quote memory q = quotes[symbol];
        return (q.sqrtPriceX96, q.updatedAt);
    }
}
