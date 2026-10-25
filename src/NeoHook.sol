// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {ITape} from "./interfaces/ITape.sol";
import {ModuleBase, TradeStatus} from "./modules/ModuleBase.sol";
import {HaltModule} from "./modules/HaltModule.sol";
import {GateModule} from "./modules/GateModule.sol";
import {LuldModule} from "./modules/LuldModule.sol";
import {VolFeeModule, VolFeeConfig, NotDynamicFee} from "./modules/VolFeeModule.sol";
import {DividendModule} from "./modules/DividendModule.sol";

/// @title NeoHook — every NEO module behind one hook address
/// @notice A v4 pool can have exactly one hook, so this contract carries all five NEO modules and
///         lets each pool's operator switch them on and off independently:
///
///         - halt      corporate-action halt (CorporateActionHook): refuses swaps and new liquidity
///                     while the Tape says the stock is halted, and from a split or rename until the
///                     operator acknowledges it
///         - luld      limit up / limit down (LimitUpLimitDownHook): refuses swaps without a fresh
///                     reference price or with the pool price outside the band around it
///         - gate      eligibility gate (EligibilityGateHook): refuses swaps and new liquidity from
///                     accounts the allowlist does not approve (trader from 20-byte hookData, else tx.origin)
///         - volFee    volatility fee (VolatilityFeeHook): overrides the LP fee from recent tick moves
///                     and around corporate actions; needs a dynamic-fee pool
///         - dividend  dividend pass-through (DividendPassThroughHook): donates escrowed cash to
///                     in-range LPs on the first swap at or after the pay date
///
///         Before a swap the enabled modules run in this order: halt, gate, luld, dividend flush
///         (never reverts), volFee (sets the fee). Before adding liquidity: halt, then gate. Removing
///         liquidity is never blocked. Each module's checks, storage and operator setters are the same
///         code the standalone hooks run (src/modules/); the one difference is that `luld` on its own
///         does not refuse a halted symbol here, since that is the `halt` module's job.
///
///         Permissions (low 14 bits of this contract's address): BEFORE_SWAP | AFTER_SWAP | BEFORE_ADD_LIQUIDITY.
contract NeoHook is BaseHook, HaltModule, GateModule, LuldModule, VolFeeModule, DividendModule {
    using PoolIdLibrary for PoolKey;
    using LPFeeLibrary for uint24;

    /// @notice Which modules a pool runs.
    struct Modules {
        bool halt;
        bool luld;
        bool gate;
        bool volFee;
        bool dividend;
    }

    mapping(PoolId => Modules) public modulesOf;

    event Bound(PoolId indexed poolId, bytes32 symbol, Currency quote, address operator, Modules modules);
    event ModulesSet(PoolId indexed poolId, Modules modules);

    constructor(IPoolManager manager, ITape tape_) BaseHook(manager) ModuleBase(tape_) {}

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: true,
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
        return "One hook, five switchable modules per pool: refuses trading while the stock is halted or a "
            "split/rename is unacknowledged, while no fresh reference price exists or the pool price is outside "
            "the band, and from accounts not on the allowlist; sets the swap fee from volatility; pays escrowed "
            "dividends to in-range LPs. Never blocks removing liquidity.";
    }

    // ------------------------------------------------------------------ operator

    /// @notice Bind a pool to a Tape symbol and choose its modules. First caller becomes the operator.
    /// @param key    the pool
    /// @param symbol Tape symbol of the stock side, e.g. bytes32("ALFA")
    /// @param quote  the pool currency dividends are paid in; must be `key.currency0` or `key.currency1`
    /// @param m      modules to enable; `volFee` requires a dynamic-fee pool (reverts NotDynamicFee)
    /// @dev Every module's defaults are written at bind so any of them can be switched on later:
    ///      band ±10% / 15 min max age (set an oracle first), both gates on with no allowlist (nobody
    ///      eligible until one is set), fee 0.05% base / 1% max / window 8 / +20 bps for 1 h around actions.
    function bind(PoolKey calldata key, bytes32 symbol, Currency quote, Modules calldata m) external {
        PoolId id = key.toId();
        _bindPool(id, symbol);
        _luldInit(id);
        _gateInit(id);
        _volFeeInit(id);
        _dividendInit(key, quote);
        _setModules(key, m);
        emit Bound(id, symbol, quote, msg.sender, m);
    }

    /// @notice Switch modules on or off. Module configuration survives being switched off.
    function setModules(PoolKey calldata key, Modules calldata m) external onlyOperator(key.toId()) {
        _setModules(key, m);
    }

    /// @notice Replace the volatility-fee parameters. Symbol and operator in `cfg` are ignored.
    function setConfig(PoolKey calldata key, VolFeeConfig calldata cfg) external onlyOperator(key.toId()) {
        _volFeeSetConfig(key.toId(), cfg);
    }

    // ------------------------------------------------------------------ status

    /// @notice The pool's volatility-fee parameters together with its binding.
    function volFeeConfigOf(PoolId id) external view returns (VolFeeConfig memory) {
        return _config(id);
    }

    /// @notice What a swap would meet right now, without sending one, for whoever sends it.
    /// @return status  Unknown / Ok / Refused. Unknown is never Ok.
    /// @return reason  "unbound" | "no-attester" | "halted" | "awaiting-ack" | "no-reference" |
    ///                 "outside-band" | "no-allowlist" | "ok"
    /// @return effective for "awaiting-ack": when the action took effect; otherwise 0
    function tradeStatus(PoolKey calldata key)
        external
        view
        returns (TradeStatus status, bytes32 reason, uint64 effective)
    {
        return _tradeStatus(key.toId(), address(0));
    }

    /// @notice `tradeStatus` for a named account: adds "not-eligible" when the gate would refuse it.
    function tradeStatusFor(PoolKey calldata key, address account)
        external
        view
        returns (TradeStatus status, bytes32 reason, uint64 effective)
    {
        return _tradeStatus(key.toId(), account);
    }

    // ------------------------------------------------------------------ hooks

    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata, bytes calldata hookData)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId id = key.toId();
        Modules memory m = modulesOf[id]; // all false for an unbound pool: inert
        bytes32 sym = symbolOf[id];
        if (m.halt) _haltCheck(id, sym);
        if (m.gate) _gateSwapCheck(id, hookData);
        if (m.luld) _luldCheck(id, sym);
        if (m.dividend) _dividendFlush(key);
        uint24 fee = m.volFee ? _volFeeBefore(id) | LPFeeLibrary.OVERRIDE_FEE_FLAG : 0;
        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, fee);
    }

    function _afterSwap(address, PoolKey calldata key, SwapParams calldata, BalanceDelta, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        PoolId id = key.toId();
        if (modulesOf[id].volFee) _volFeeAfter(id);
        return (BaseHook.afterSwap.selector, 0);
    }

    function _beforeAddLiquidity(address, PoolKey calldata key, ModifyLiquidityParams calldata, bytes calldata hookData)
        internal
        view
        override
        returns (bytes4)
    {
        PoolId id = key.toId();
        Modules memory m = modulesOf[id];
        if (m.halt) _haltCheck(id, symbolOf[id]);
        if (m.gate) _gateLiquidityCheck(id, hookData);
        return BaseHook.beforeAddLiquidity.selector;
    }

    // ------------------------------------------------------------------ module switches

    function _haltActive(PoolId id) internal view override returns (bool) {
        return modulesOf[id].halt;
    }

    function _luldActive(PoolId id) internal view override returns (bool) {
        return modulesOf[id].luld;
    }

    function _gateActive(PoolId id) internal view override returns (bool) {
        return modulesOf[id].gate;
    }

    function _volFeeActive(PoolId id) internal view override returns (bool) {
        return modulesOf[id].volFee;
    }

    function _dividendActive(PoolId id) internal view override returns (bool) {
        return modulesOf[id].dividend;
    }

    // ------------------------------------------------------------------ internal

    function _setModules(PoolKey calldata key, Modules calldata m) internal {
        if (m.volFee && !key.fee.isDynamicFee()) revert NotDynamicFee();
        modulesOf[key.toId()] = m;
        emit ModulesSet(key.toId(), m);
    }

    function _tradeStatus(PoolId id, address account)
        internal
        view
        returns (TradeStatus status, bytes32 reason, uint64 effective)
    {
        if (!_isBound(id)) return (TradeStatus.Ok, "unbound", 0);
        Modules memory m = modulesOf[id];
        bytes32 sym = symbolOf[id];
        if (m.halt) {
            (status, reason, effective) = _haltStatus(id, sym);
            if (status != TradeStatus.Ok) return (status, reason, effective);
        }
        if (m.luld) {
            (status, reason,) = _luldStatus(id);
            if (status != TradeStatus.Ok) return (status, reason, 0);
        }
        if (m.gate && gateConfigOf[id].gateSwaps) {
            if (address(gateConfigOf[id].allowlist) == address(0)) return (TradeStatus.Refused, "no-allowlist", 0);
            if (account != address(0) && !_allowed(id, account)) return (TradeStatus.Refused, "not-eligible", 0);
        }
        return (TradeStatus.Ok, "ok", 0);
    }
}
