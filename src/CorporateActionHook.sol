// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {ITape} from "./interfaces/ITape.sol";

/// @title CorporateActionHook — the first NEO hook
/// @notice A pool bound to a stock symbol refuses swaps and new liquidity while the Tape says the
///         stock is halted, and from the moment a split or rename takes effect until the pool's
///         operator acknowledges it (after re-pricing or migrating liquidity). Removing liquidity is
///         never blocked: LPs can always leave.
///
///         Permissions (low 14 bits of this contract's address): BEFORE_SWAP | BEFORE_ADD_LIQUIDITY.
contract CorporateActionHook is BaseHook {
    using PoolIdLibrary for PoolKey;

    ITape public immutable tape;

    mapping(PoolId => bytes32) public symbolOf;
    mapping(PoolId => address) public operatorOf;
    /// @dev hash of the (kind, effective, value) the operator last acknowledged for this pool
    mapping(PoolId => bytes32) public acknowledged;

    /// @notice Tri-state answer to "can this pool trade right now?". Unknown is never Ok.
    enum TradeStatus {
        Unknown, // bound to a symbol the Tape has no attester for: no data source
        Ok, // nothing on the Tape blocks trading
        Refused // halted, or a split/rename is in effect and not yet acknowledged
    }

    event Bound(PoolId indexed poolId, bytes32 symbol, address operator);
    event Acknowledged(PoolId indexed poolId, bytes32 actionHash);

    error Halted(bytes32 symbol);
    error AwaitingAcknowledgement(bytes32 symbol, ITape.Kind kind, uint64 effective);
    error NotOperator();
    error AlreadyBound();

    constructor(IPoolManager manager, ITape tape_) BaseHook(manager) {
        tape = tape_;
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: true,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    /// @notice Human-readable manifest, registered alongside the address so wallets can show it.
    function label() external pure returns (string memory) {
        return "Refuses swaps and new liquidity while the stock is halted, and from a split or rename "
            "until the pool operator acknowledges it. Never blocks removing liquidity.";
    }

    // ------------------------------------------------------------------ operator

    /// @notice Bind a pool to a Tape symbol. First caller becomes the pool's operator.
    function bind(PoolKey calldata key, bytes32 symbol) external {
        PoolId id = key.toId();
        if (operatorOf[id] != address(0)) revert AlreadyBound();
        operatorOf[id] = msg.sender;
        symbolOf[id] = symbol;
        emit Bound(id, symbol, msg.sender);
    }

    /// @notice Operator confirms the pool has been re-priced / migrated for the current action.
    function acknowledge(PoolKey calldata key) external {
        PoolId id = key.toId();
        if (msg.sender != operatorOf[id]) revert NotOperator();
        (ITape.Kind kind, uint64 effective, uint256 value) = tape.action(symbolOf[id]);
        bytes32 h = keccak256(abi.encode(kind, effective, value));
        acknowledged[id] = h;
        emit Acknowledged(id, h);
    }

    // ------------------------------------------------------------------ status

    /// @notice What a swap would meet right now, without sending one.
    /// @return status  Unknown / Ok / Refused
    /// @return reason  "unbound" | "no-attester" | "halted" | "awaiting-ack" | "ok"
    /// @return effective  for Refused by a corporate action: when it took effect; otherwise 0
    function tradeStatus(PoolKey calldata key)
        external
        view
        returns (TradeStatus status, bytes32 reason, uint64 effective)
    {
        PoolId id = key.toId();
        bytes32 sym = symbolOf[id];
        if (sym == bytes32(0)) return (TradeStatus.Ok, "unbound", 0);
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

    // ------------------------------------------------------------------ hooks

    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata, bytes calldata)
        internal
        view
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        _check(key.toId());
        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    function _beforeAddLiquidity(address, PoolKey calldata key, ModifyLiquidityParams calldata, bytes calldata)
        internal
        view
        override
        returns (bytes4)
    {
        _check(key.toId());
        return BaseHook.beforeAddLiquidity.selector;
    }

    // ------------------------------------------------------------------ internal

    function _check(PoolId id) internal view {
        bytes32 sym = symbolOf[id];
        if (sym == bytes32(0)) return; // unbound pool: hook is inert
        if (tape.isHalted(sym)) revert Halted(sym);
        (ITape.Kind kind, uint64 effective, uint256 value) = tape.action(sym);
        if ((kind == ITape.Kind.Split || kind == ITape.Kind.Rename) && block.timestamp >= effective) {
            if (acknowledged[id] != keccak256(abi.encode(kind, effective, value))) {
                revert AwaitingAcknowledgement(sym, kind, effective);
            }
        }
    }
}
