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
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {ITape} from "../interfaces/ITape.sol";

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
///         Permissions (low 14 bits of this contract's address): BEFORE_SWAP | AFTER_SWAP.
contract VolatilityFeeHook is BaseHook {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using LPFeeLibrary for uint24;

    /// @dev EWMA is kept with 4 extra decimal digits of precision (ticks * 1e4).
    uint256 internal constant EWMA_SCALE = 1e4;
    /// @dev 1 bp = 100 hundredths of a bip.
    uint256 internal constant PIPS_PER_BP = 100;

    ITape public immutable tape;

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

    mapping(PoolId => Config) public configOf;
    /// @notice EWMA of |tick move per swap|, scaled by 1e4.
    mapping(PoolId => uint256) public ewmaOf;

    event Bound(PoolId indexed poolId, bytes32 symbol, address operator);
    event ConfigSet(PoolId indexed poolId, Config config);
    event FeeCharged(PoolId indexed poolId, uint24 fee);

    error NotOperator();
    error AlreadyBound();
    error NotDynamicFee();
    error BadConfig();

    constructor(IPoolManager manager, ITape tape_) BaseHook(manager) {
        tape = tape_;
    }

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

    modifier onlyOperator(PoolId id) {
        if (msg.sender != configOf[id].operator) revert NotOperator();
        _;
    }

    /// @notice Bind a dynamic-fee pool to a Tape symbol. First caller becomes the pool's operator.
    ///         Defaults: base 0.05%, max 1%, 10 pips per EWMA tick, window 8 swaps, +20 bps for 1 hour
    ///         either side of an action.
    function bind(PoolKey calldata key, bytes32 symbol) external {
        if (!key.fee.isDynamicFee()) revert NotDynamicFee();
        PoolId id = key.toId();
        Config storage c = configOf[id];
        if (c.operator != address(0)) revert AlreadyBound();
        c.operator = msg.sender;
        c.symbol = symbol;
        c.baseFee = 500;
        c.maxFee = 10_000;
        c.feePerTick = 10;
        c.window = 8;
        c.eventBumpBps = 20;
        c.eventBumpSeconds = 1 hours;
        emit Bound(id, symbol, msg.sender);
    }

    /// @notice Replace the fee parameters. Symbol and operator in `cfg` are ignored.
    function setConfig(PoolKey calldata key, Config calldata cfg) external onlyOperator(key.toId()) {
        if (cfg.window == 0 || cfg.maxFee > LPFeeLibrary.MAX_LP_FEE || cfg.baseFee > cfg.maxFee) revert BadConfig();
        Config storage c = configOf[key.toId()];
        c.baseFee = cfg.baseFee;
        c.maxFee = cfg.maxFee;
        c.feePerTick = cfg.feePerTick;
        c.window = cfg.window;
        c.eventBumpBps = cfg.eventBumpBps;
        c.eventBumpSeconds = cfg.eventBumpSeconds;
        emit ConfigSet(key.toId(), c);
    }

    // ------------------------------------------------------------------ status

    /// @notice The fee the next swap will pay, in hundredths of a bip (without the override flag).
    ///         0 for an unbound pool, meaning "the pool's own fee".
    function currentFee(PoolKey calldata key) external view returns (uint24) {
        PoolId id = key.toId();
        Config storage c = configOf[id];
        if (c.operator == address(0)) return 0;
        return _fee(id, c);
    }

    /// @notice True while the symbol's current Tape action is within `eventBumpSeconds` of now.
    function inEventWindow(PoolKey calldata key) external view returns (bool) {
        Config storage c = configOf[key.toId()];
        if (c.operator == address(0)) return false;
        return _inEventWindow(c);
    }

    // ------------------------------------------------------------------ hooks

    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId id = key.toId();
        Config storage c = configOf[id];
        if (c.operator == address(0)) return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);

        (, int24 tick,,) = poolManager.getSlot0(id);
        _storeTick(id, tick);

        uint24 fee = _fee(id, c);
        emit FeeCharged(id, fee);
        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, fee | LPFeeLibrary.OVERRIDE_FEE_FLAG);
    }

    function _afterSwap(address, PoolKey calldata key, SwapParams calldata, BalanceDelta, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        PoolId id = key.toId();
        Config storage c = configOf[id];
        if (c.operator == address(0)) return (BaseHook.afterSwap.selector, 0);

        (, int24 tickAfter,,) = poolManager.getSlot0(id);
        int24 tickBefore = _loadTick(id);
        uint256 move = uint256(uint24(tickAfter > tickBefore ? tickAfter - tickBefore : tickBefore - tickAfter));

        uint256 w = c.window;
        ewmaOf[id] = (ewmaOf[id] * (w - 1) + move * EWMA_SCALE) / w;
        return (BaseHook.afterSwap.selector, 0);
    }

    // ------------------------------------------------------------------ internal

    function _fee(PoolId id, Config storage c) internal view returns (uint24) {
        uint256 fee = uint256(c.baseFee) + (uint256(c.feePerTick) * ewmaOf[id]) / EWMA_SCALE;
        if (fee > c.maxFee) fee = c.maxFee;
        if (_inEventWindow(c)) {
            fee += uint256(c.eventBumpBps) * PIPS_PER_BP;
            if (fee > LPFeeLibrary.MAX_LP_FEE) fee = LPFeeLibrary.MAX_LP_FEE;
        }
        return uint24(fee);
    }

    function _inEventWindow(Config storage c) internal view returns (bool) {
        (ITape.Kind kind, uint64 effective,) = tape.action(c.symbol);
        if (kind == ITape.Kind.None) return false;
        uint256 now_ = block.timestamp;
        uint256 dist = now_ > effective ? now_ - effective : effective - now_;
        return dist <= c.eventBumpSeconds;
    }

    /// @dev Tick at the start of the current swap, kept in transient storage (lives for this tx only).
    function _storeTick(PoolId id, int24 tick) internal {
        bytes32 slot = PoolId.unwrap(id);
        assembly ("memory-safe") {
            tstore(slot, tick)
        }
    }

    function _loadTick(PoolId id) internal view returns (int24 tick) {
        bytes32 slot = PoolId.unwrap(id);
        assembly ("memory-safe") {
            tick := tload(slot)
        }
    }
}
