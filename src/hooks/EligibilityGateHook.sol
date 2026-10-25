// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {ITape} from "../interfaces/ITape.sol";
import {IAllowlist} from "../interfaces/IAllowlist.sol";
import {ModuleBase} from "../modules/ModuleBase.sol";
import {GateModule} from "../modules/GateModule.sol";

/// @title EligibilityGateHook — only allowlisted accounts may swap or add liquidity
/// @notice A pool bound by its operator refuses swaps and new liquidity from accounts the pool's
///         allowlist does not approve. Removing liquidity is never blocked: LPs can always leave.
///
///         Who is checked. The pool manager hands hooks the *router* as `sender`, not the trader, so
///         the hook reads the trader from `hookData`: when it is exactly 20 bytes
///         (`abi.encodePacked(address trader)`) that address is checked. Otherwise the hook falls back
///         to `tx.origin`. Limitation: a router that forwards arbitrary hookData lets a caller name any
///         address, so this gate only holds against routers that either set hookData to the real
///         trader themselves or pass none (in which case the EOA that signed the transaction is
///         checked). Pair it with a trusted router for anything stronger than a convenience gate.
///
///         The gate logic lives in `GateModule`; this contract is the standalone hook around it.
///
///         Permissions (low 14 bits of this contract's address): BEFORE_SWAP | BEFORE_ADD_LIQUIDITY.
contract EligibilityGateHook is BaseHook, GateModule {
    using PoolIdLibrary for PoolKey;

    event Bound(PoolId indexed poolId, bytes32 symbol, address operator);
    event AllowlistSet(PoolId indexed poolId, address allowlist);
    event GatesSet(PoolId indexed poolId, bool gateSwaps, bool gateLiquidity);

    error NotEligible(address account);
    error NotOperator();
    error AlreadyBound();

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
        return "Refuses swaps and new liquidity from accounts the pool's allowlist does not approve. "
            "The trader is read from hookData (20 bytes) or else tx.origin. Never blocks removing liquidity.";
    }

    // ------------------------------------------------------------------ operator

    /// @notice Bind a pool to a Tape symbol. First caller becomes the pool's operator. Both gates
    ///         start enabled; until the operator sets an allowlist nobody is eligible.
    function bind(PoolKey calldata key, bytes32 symbol) external {
        PoolId id = key.toId();
        _bindPool(id, symbol);
        _gateInit(id);
        emit Bound(id, symbol, msg.sender);
    }

    // ------------------------------------------------------------------ status

    /// @notice The pool's binding and gate configuration in one view.
    function configOf(PoolId id)
        external
        view
        returns (bytes32 symbol, address operator, IAllowlist allowlist, bool gateSwaps, bool gateLiquidity)
    {
        GateConfig storage c = gateConfigOf[id];
        return (symbolOf[id], operatorOf[id], c.allowlist, c.gateSwaps, c.gateLiquidity);
    }

    // ------------------------------------------------------------------ hooks

    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata, bytes calldata hookData)
        internal
        view
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId id = key.toId();
        if (_gateActive(id)) _gateSwapCheck(id, hookData);
        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    function _beforeAddLiquidity(address, PoolKey calldata key, ModifyLiquidityParams calldata, bytes calldata hookData)
        internal
        view
        override
        returns (bytes4)
    {
        PoolId id = key.toId();
        if (_gateActive(id)) _gateLiquidityCheck(id, hookData);
        return BaseHook.beforeAddLiquidity.selector;
    }
}
