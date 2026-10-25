// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title IReferencePrice — off-pool reference price a hook compares the pool against
/// @notice One quote per symbol, expressed as a Uniswap sqrtPriceX96 so it compares directly
///         with `getSlot0`. Hooks treat a quote older than their `maxAge` as absent.
interface IReferencePrice {
    /// @param symbol  Tape symbol, e.g. `bytes32("ALFA")`
    /// @return sqrtPriceX96  sqrt(token1/token0) in Q64.96, 0 when no quote exists
    /// @return updatedAt     unix time of the quote, 0 when no quote exists
    function latest(bytes32 symbol) external view returns (uint160 sqrtPriceX96, uint64 updatedAt);
}
