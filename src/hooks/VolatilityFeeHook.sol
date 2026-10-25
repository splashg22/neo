// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {ITape} from "../interfaces/ITape.sol";
import {ModuleBase} from "../modules/ModuleBase.sol";
import {VolFeeModule, VolFeeConfig} from "../modules/VolFeeModule.sol";

/// @title VolatilityFeeHook — LP fee that rises with realised volatility and around corporate actions
/// @notice For a dynamic-fee pool bound to a stock symbol, every swap pays
///         `baseFee + feePerTick * ewma(|tick move per swap|)`, clamped to `maxFee`, plus `eventBumpBps`
///         while the symbol's current Tape action takes effect within `eventBumpSeconds` of now (before
///         or after). The EWMA is updated after each swap from the tick before and after it. Fees are
///         in hundredths of a bip like every v4 LP fee (500 = 0.05%); the bump is in bps.
///
///         Pools must be initialised with `LPFeeLibrary.DYNAMIC_FEE_FLAG` as their fee; `bind` refuses
///         anything else. Unbound pools pay whatever fee they were initialised with.
///
///         The fee logic lives in `VolFeeModule`; this contract is the standalone hook around it.
///
///         Permissions (low 14 bits of this contract's address): BEFORE_SWAP | AFTER_SWAP.
contract VolatilityFeeHook is BaseHook, VolFeeModule {
    using PoolIdLibrary for PoolKey;
    using LPFeeLibrary for uint24;

    /// @notice Fee parameters. `symbol` and `operator` are the pool binding; `setConfig` ignores them.
    struct Config {
        bytes32 symbol;
        address operator;
        uint24 baseFee; // hundredths of a bip; 500 = 0.05%
        uint24 maxFee; // clamp, hundredths of a bip; 10_000 = 1%
        uint24 feePerTick; // hundredths of a bip added per tick of EWMA
        uint32 window; // EWMA length in swaps; alpha = 1/window
        uint24 eventBumpBps; // added while a Tape action is within eventBumpSeconds
        uint64 eventBumpSeconds;
    }

    event Bound(PoolId indexed poolId, bytes32 symbol, address operator);
    event ConfigSet(PoolId indexed poolId, Config config);
    event FeeCharged(PoolId indexed poolId, uint24 fee);

    error NotOperator();
    error AlreadyBound();
    error NotDynamicFee();
    error BadConfig();

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
            afterSwap: true,
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
        return "Sets the swap fee from recent price volatility (base fee plus a multiple of the average "
            "tick move per swap, capped), and raises it around corporate actions on the Tape. Never blocks anything.";
    }

    // ------------------------------------------------------------------ operator

    /// @notice Bind a dynamic-fee pool to a Tape symbol. First caller becomes the pool's operator.
    ///         Defaults: base 0.05%, max 1%, 10 pips per EWMA tick, window 8 swaps, +20 bps for 1 hour
    ///         either side of an action.
    function bind(PoolKey calldata key, bytes32 symbol) external {
        if (!key.fee.isDynamicFee()) revert NotDynamicFee();
        PoolId id = key.toId();
        _bindPool(id, symbol);
        _volFeeInit(id);
        emit Bound(id, symbol, msg.sender);
    }

    /// @notice Replace the fee parameters. Symbol and operator in `cfg` are ignored.
    function setConfig(PoolKey calldata key, Config calldata cfg) external onlyOperator(key.toId()) {
        _volFeeSetConfig(
            key.toId(),
            VolFeeConfig({
                symbol: cfg.symbol,
                operator: cfg.operator,
                baseFee: cfg.baseFee,
                maxFee: cfg.maxFee,
                feePerTick: cfg.feePerTick,
                window: cfg.window,
                eventBumpBps: cfg.eventBumpBps,
                eventBumpSeconds: cfg.eventBumpSeconds
            })
        );
    }

    // ------------------------------------------------------------------ status

    /// @notice The pool's binding and fee parameters in one view.
    function configOf(PoolId id)
        external
        view
        returns (
            bytes32 symbol,
            address operator,
            uint24 baseFee,
            uint24 maxFee,
            uint24 feePerTick,
            uint32 window,
            uint24 eventBumpBps,
            uint64 eventBumpSeconds
        )
    {
        VolFeeConfig memory c = _config(id);
        return (c.symbol, c.operator, c.baseFee, c.maxFee, c.feePerTick, c.window, c.eventBumpBps, c.eventBumpSeconds);
    }

    // ------------------------------------------------------------------ hooks

    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId id = key.toId();
        if (!_volFeeActive(id)) return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        uint24 fee = _volFeeBefore(id);
        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, fee | LPFeeLibrary.OVERRIDE_FEE_FLAG);
    }

    function _afterSwap(address, PoolKey calldata key, SwapParams calldata, BalanceDelta, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        PoolId id = key.toId();
        if (_volFeeActive(id)) _volFeeAfter(id);
        return (BaseHook.afterSwap.selector, 0);
    }
}
