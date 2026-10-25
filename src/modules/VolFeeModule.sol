// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {ITape} from "../interfaces/ITape.sol";
import {ModuleBase} from "./ModuleBase.sol";

/// @notice Fee parameters as presented to operators and tooling. `symbol` and `operator` are the
///         pool binding (read-only here; ignored when setting).
struct VolFeeConfig {
    bytes32 symbol;
    address operator;
    uint24 baseFee; // hundredths of a bip; 500 = 0.05%
    uint24 maxFee; // clamp, hundredths of a bip; 10_000 = 1%
    uint24 feePerTick; // hundredths of a bip added per tick of EWMA
    uint32 window; // EWMA length in swaps; alpha = 1/window
    uint24 eventBumpBps; // added while a Tape action is within eventBumpSeconds
    uint64 eventBumpSeconds;
}

event ConfigSet(PoolId indexed poolId, VolFeeConfig config);
event FeeCharged(PoolId indexed poolId, uint24 fee);

error NotDynamicFee();
error BadConfig();

/// @title VolFeeModule — LP fee that rises with realised volatility and around corporate actions
/// @notice Every swap pays `baseFee + feePerTick * ewma(|tick move per swap|)`, clamped to `maxFee`,
///         plus `eventBumpBps` while the symbol's current Tape action takes effect within
///         `eventBumpSeconds` of now. The EWMA is updated after each swap from the tick before and
///         after it. Fees are in hundredths of a bip (500 = 0.05%); the bump is in bps.
///         The pool must be a dynamic-fee pool; the hook that uses this module enforces that at bind.
abstract contract VolFeeModule is ModuleBase {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    /// @dev EWMA is kept with 4 extra decimal digits of precision (ticks * 1e4).
    uint256 internal constant EWMA_SCALE = 1e4;
    /// @dev 1 bp = 100 hundredths of a bip.
    uint256 internal constant PIPS_PER_BP = 100;

    /// @dev What is actually stored: one slot per pool.
    struct FeeParams {
        uint24 baseFee;
        uint24 maxFee;
        uint24 feePerTick;
        uint32 window;
        uint24 eventBumpBps;
        uint64 eventBumpSeconds;
    }

    mapping(PoolId => FeeParams) public volFeeParamsOf;
    /// @notice EWMA of |tick move per swap|, scaled by 1e4.
    mapping(PoolId => uint256) public ewmaOf;

    // ------------------------------------------------------------------ status

    /// @notice The fee the next swap will pay, in hundredths of a bip (without the override flag).
    ///         0 when the module does not apply to the pool, meaning "the pool's own fee".
    function currentFee(PoolKey calldata key) external view returns (uint24) {
        PoolId id = key.toId();
        if (!_volFeeActive(id)) return 0;
        return _fee(id);
    }

    /// @notice True while the symbol's current Tape action is within `eventBumpSeconds` of now.
    function inEventWindow(PoolKey calldata key) external view returns (bool) {
        PoolId id = key.toId();
        if (!_volFeeActive(id)) return false;
        return _inEventWindow(id);
    }

    // ------------------------------------------------------------------ internal

    /// @dev Defaults at bind time: base 0.05%, max 1%, 10 pips per EWMA tick, window 8 swaps,
    ///      +20 bps for 1 hour either side of an action.
    function _volFeeInit(PoolId id) internal {
        FeeParams storage p = volFeeParamsOf[id];
        p.baseFee = 500;
        p.maxFee = 10_000;
        p.feePerTick = 10;
        p.window = 8;
        p.eventBumpBps = 20;
        p.eventBumpSeconds = 1 hours;
    }

    /// @dev Replace the fee parameters (operator check is the caller's). Symbol and operator in `cfg`
    ///      are ignored. Reverts BadConfig on a zero window, a max above the v4 ceiling, or base > max.
    function _volFeeSetConfig(PoolId id, VolFeeConfig memory cfg) internal {
        if (cfg.window == 0 || cfg.maxFee > LPFeeLibrary.MAX_LP_FEE || cfg.baseFee > cfg.maxFee) revert BadConfig();
        FeeParams storage p = volFeeParamsOf[id];
        p.baseFee = cfg.baseFee;
        p.maxFee = cfg.maxFee;
        p.feePerTick = cfg.feePerTick;
        p.window = cfg.window;
        p.eventBumpBps = cfg.eventBumpBps;
        p.eventBumpSeconds = cfg.eventBumpSeconds;
        emit ConfigSet(id, _config(id));
    }

    /// @dev Whether the fee applies to this pool. Standalone: bound. NeoHook: bound + toggled on.
    function _volFeeActive(PoolId id) internal view virtual returns (bool) {
        return _isBound(id);
    }

    /// @dev Before the swap: remember the tick, compute and emit the fee (without the override flag).
    function _volFeeBefore(PoolId id) internal returns (uint24 fee) {
        (, int24 tick,,) = poolManager.getSlot0(id);
        _storeTick(id, tick);
        fee = _fee(id);
        emit FeeCharged(id, fee);
    }

    /// @dev After the swap: fold this swap's |tick move| into the EWMA.
    function _volFeeAfter(PoolId id) internal {
        (, int24 tickAfter,,) = poolManager.getSlot0(id);
        int24 tickBefore = _loadTick(id);
        uint256 move = uint256(uint24(tickAfter > tickBefore ? tickAfter - tickBefore : tickBefore - tickAfter));
        uint256 w = volFeeParamsOf[id].window;
        ewmaOf[id] = (ewmaOf[id] * (w - 1) + move * EWMA_SCALE) / w;
    }

    /// @dev The pool's binding and fee parameters as one struct.
    function _config(PoolId id) internal view returns (VolFeeConfig memory) {
        FeeParams storage p = volFeeParamsOf[id];
        return VolFeeConfig({
            symbol: symbolOf[id],
            operator: operatorOf[id],
            baseFee: p.baseFee,
            maxFee: p.maxFee,
            feePerTick: p.feePerTick,
            window: p.window,
            eventBumpBps: p.eventBumpBps,
            eventBumpSeconds: p.eventBumpSeconds
        });
    }

    function _fee(PoolId id) internal view returns (uint24) {
        FeeParams storage p = volFeeParamsOf[id];
        uint256 fee = uint256(p.baseFee) + (uint256(p.feePerTick) * ewmaOf[id]) / EWMA_SCALE;
        if (fee > p.maxFee) fee = p.maxFee;
        if (_inEventWindow(id)) {
            fee += uint256(p.eventBumpBps) * PIPS_PER_BP;
            if (fee > LPFeeLibrary.MAX_LP_FEE) fee = LPFeeLibrary.MAX_LP_FEE;
        }
        return uint24(fee);
    }

    function _inEventWindow(PoolId id) internal view returns (bool) {
        (ITape.Kind kind, uint64 effective,) = tape.action(symbolOf[id]);
        if (kind == ITape.Kind.None) return false;
        uint256 now_ = block.timestamp;
        uint256 dist = now_ > effective ? now_ - effective : effective - now_;
        return dist <= volFeeParamsOf[id].eventBumpSeconds;
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
