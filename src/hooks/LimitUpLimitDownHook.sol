// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {ITape} from "../interfaces/ITape.sol";
import {IReferencePrice} from "../interfaces/IReferencePrice.sol";
import {ModuleBase, TradeStatus as ModuleTradeStatus} from "../modules/ModuleBase.sol";
import {LuldModule} from "../modules/LuldModule.sol";

/// @title LimitUpLimitDownHook — price bands around a reference price
/// @notice A pool bound to a stock symbol refuses swaps while the stock is halted on the Tape, while
///         no fresh reference price exists, and while the pool's price sits outside a band around that
///         reference price (default ±10%). Unknown is never ok: a missing or stale reference refuses.
///
///         The check is on the pre-swap price. A swap that starts inside the band can finish outside
///         it; the next swap is then refused until the pool is arbitraged back or the reference moves.
///         Enforcing a post-swap bound would need AFTER_SWAP (and a revert there), which this hook
///         deliberately does not take so that its permission mask stays minimal.
///
///         The band logic lives in `LuldModule`; this contract is the standalone hook around it.
///
///         Permissions (low 14 bits of this contract's address): BEFORE_SWAP.
contract LimitUpLimitDownHook is BaseHook, LuldModule {
    using PoolIdLibrary for PoolKey;

    /// @notice Tri-state answer to "can this pool trade right now?". Unknown is never Ok.
    enum TradeStatus {
        Unknown, // no fresh reference price: no data source
        Ok,
        Refused // halted or outside the band
    }

    event Bound(PoolId indexed poolId, bytes32 symbol, address operator);
    event BandSet(PoolId indexed poolId, uint256 bandBps);
    event OracleSet(PoolId indexed poolId, address oracle);
    event MaxAgeSet(PoolId indexed poolId, uint64 maxAge);

    error Halted(bytes32 symbol);
    error NoReference(bytes32 symbol);
    error OutsideBand(bytes32 symbol, uint256 poolBps, uint256 bandBps);
    error NotOperator();
    error AlreadyBound();
    error BadBand();

    constructor(IPoolManager manager, ITape tape_) BaseHook(manager) ModuleBase(tape_) {}

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
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
        return "Refuses swaps while the stock is halted, while no fresh reference price exists, or while "
            "the pool price is more than the band away from the reference price. Never touches liquidity.";
    }

    // ------------------------------------------------------------------ operator

    /// @notice Bind a pool to a Tape symbol. First caller becomes the pool's operator. Band and max
    ///         age start at their defaults; the operator must `setOracle` before swaps can pass.
    function bind(PoolKey calldata key, bytes32 symbol) external {
        PoolId id = key.toId();
        _bindPool(id, symbol);
        _luldInit(id);
        emit Bound(id, symbol, msg.sender);
    }

    // ------------------------------------------------------------------ status

    /// @notice The pool's binding and band configuration in one view.
    function configOf(PoolId id)
        external
        view
        returns (bytes32 symbol, address operator, IReferencePrice oracle, uint256 bandBps, uint64 maxAge)
    {
        LuldConfig storage c = luldConfigOf[id];
        return (symbolOf[id], operatorOf[id], c.oracle, c.bandBps, c.maxAge);
    }

    /// @notice What a swap would meet right now, without sending one.
    /// @return status  Unknown / Ok / Refused
    /// @return reason  "unbound" | "halted" | "no-reference" | "outside-band" | "ok"
    /// @return poolBps pool/reference ratio in bps when a reference exists, otherwise 0
    function tradeStatus(PoolKey calldata key)
        external
        view
        returns (TradeStatus status, bytes32 reason, uint256 poolBps)
    {
        PoolId id = key.toId();
        bytes32 sym = symbolOf[id];
        if (sym == bytes32(0)) return (TradeStatus.Ok, "unbound", 0);
        if (tape.isHalted(sym)) return (TradeStatus.Refused, "halted", 0);
        (ModuleTradeStatus st, bytes32 r, uint256 bps) = _luldStatus(id);
        return (TradeStatus(uint8(st)), r, bps);
    }

    // ------------------------------------------------------------------ hooks

    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata, bytes calldata)
        internal
        view
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId id = key.toId();
        if (_luldActive(id)) {
            bytes32 sym = symbolOf[id];
            if (tape.isHalted(sym)) revert Halted(sym);
            _luldCheck(id, sym);
        }
        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }
}
