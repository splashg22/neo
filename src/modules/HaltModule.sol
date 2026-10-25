// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {ITape} from "../interfaces/ITape.sol";
import {ModuleBase, TradeStatus, Halted} from "./ModuleBase.sol";

event Acknowledged(PoolId indexed poolId, bytes32 actionHash);

error AwaitingAcknowledgement(bytes32 symbol, ITape.Kind kind, uint64 effective);

/// @title HaltModule — corporate-action halt (the CorporateActionHook logic)
/// @notice Refuses while the Tape says the stock is halted, and from the moment a split or rename
///         takes effect until the pool's operator acknowledges it.
abstract contract HaltModule is ModuleBase {
    using PoolIdLibrary for PoolKey;

    /// @dev hash of the (kind, effective, value) the operator last acknowledged for this pool
    mapping(PoolId => bytes32) public acknowledged;

    /// @notice Operator confirms the pool has been re-priced / migrated for the current action.
    function acknowledge(PoolKey calldata key) external onlyOperator(key.toId()) {
        PoolId id = key.toId();
        (ITape.Kind kind, uint64 effective, uint256 value) = tape.action(symbolOf[id]);
        bytes32 h = keccak256(abi.encode(kind, effective, value));
        acknowledged[id] = h;
        emit Acknowledged(id, h);
    }

    /// @dev Whether the halt check applies to this pool. Standalone: bound. NeoHook: bound + toggled on.
    function _haltActive(PoolId id) internal view virtual returns (bool) {
        return _isBound(id);
    }

    /// @dev Revert Halted / AwaitingAcknowledgement when the Tape blocks trading for `sym`.
    function _haltCheck(PoolId id, bytes32 sym) internal view {
        if (tape.isHalted(sym)) revert Halted(sym);
        (ITape.Kind kind, uint64 effective, uint256 value) = tape.action(sym);
        if ((kind == ITape.Kind.Split || kind == ITape.Kind.Rename) && block.timestamp >= effective) {
            if (acknowledged[id] != keccak256(abi.encode(kind, effective, value))) {
                revert AwaitingAcknowledgement(sym, kind, effective);
            }
        }
    }

    /// @dev Status view of `_haltCheck`. reason: "no-attester" | "halted" | "awaiting-ack" | "ok"
    function _haltStatus(PoolId id, bytes32 sym)
        internal
        view
        returns (TradeStatus status, bytes32 reason, uint64 effective)
    {
        if (!tape.hasAttester(sym)) return (TradeStatus.Unknown, "no-attester", 0);
        if (tape.isHalted(sym)) return (TradeStatus.Refused, "halted", 0);
        (ITape.Kind kind, uint64 eff, uint256 value) = tape.action(sym);
        if ((kind == ITape.Kind.Split || kind == ITape.Kind.Rename) && block.timestamp >= eff) {
            if (acknowledged[id] != keccak256(abi.encode(kind, eff, value))) {
                return (TradeStatus.Refused, "awaiting-ack", eff);
            }
        }
        return (TradeStatus.Ok, "ok", 0);
    }
}
