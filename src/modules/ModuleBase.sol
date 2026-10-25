// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ImmutableState} from "v4-periphery/src/base/ImmutableState.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {ITape} from "../interfaces/ITape.sol";

/// @notice Tri-state answer to "can this pool trade right now?". Unknown is never Ok.
enum TradeStatus {
    Unknown, // no data source: no attester, no fresh reference price
    Ok, // nothing blocks trading
    Refused // halted, awaiting acknowledgement, outside the band, nobody eligible
}

error Halted(bytes32 symbol);
error NotOperator();
error AlreadyBound();

/// @title ModuleBase — state every NEO hook module shares
/// @notice One pool binding (symbol + operator) per pool, the Tape, the pool manager, and the
///         tri-state TradeStatus. Modules extend this and keep their own per-pool config next to it,
///         so a hook can inherit one module (the standalone hooks) or all of them (NeoHook) while
///         the pool is bound exactly once.
/// @dev Extends `ImmutableState` for `poolManager` without calling its constructor; the concrete
///      hook's `BaseHook(manager)` does that.
///      Errors, events and types the modules raise are declared at file level (above and in each
///      module file) rather than as contract members: Solidity does not let a derived contract
///      re-declare an inherited error, nor reach an inherited one as `Derived.Err`, and the standalone
///      hooks must keep exposing `Hook.Err` for their ABI and tests. Same signature, same selector.
abstract contract ModuleBase is ImmutableState {
    ITape public immutable tape;

    /// @notice Tape symbol a pool is bound to; zero for an unbound pool.
    mapping(PoolId => bytes32) public symbolOf;
    /// @notice The pool's operator: the first caller of `bind`.
    mapping(PoolId => address) public operatorOf;

    constructor(ITape tape_) {
        tape = tape_;
    }

    modifier onlyOperator(PoolId id) {
        if (msg.sender != operatorOf[id]) revert NotOperator();
        _;
    }

    /// @dev First caller becomes the pool's operator. Does not emit: the hook emits its own Bound.
    function _bindPool(PoolId id, bytes32 symbol) internal {
        if (operatorOf[id] != address(0)) revert AlreadyBound();
        operatorOf[id] = msg.sender;
        symbolOf[id] = symbol;
    }

    /// @dev True once `bind` has run for the pool.
    function _isBound(PoolId id) internal view returns (bool) {
        return operatorOf[id] != address(0);
    }
}
