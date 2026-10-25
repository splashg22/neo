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
///         Permissions (low 14 bits of this contract's address): BEFORE_SWAP | BEFORE_ADD_LIQUIDITY.
contract EligibilityGateHook is BaseHook {
    using PoolIdLibrary for PoolKey;

    ITape public immutable tape;

    struct Config {
        bytes32 symbol;
        address operator;
        IAllowlist allowlist;
        bool gateSwaps;
        bool gateLiquidity;
    }

    mapping(PoolId => Config) public configOf;

    event Bound(PoolId indexed poolId, bytes32 symbol, address operator);
    event AllowlistSet(PoolId indexed poolId, address allowlist);
    event GatesSet(PoolId indexed poolId, bool gateSwaps, bool gateLiquidity);

    error NotEligible(address account);
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
        return "Refuses swaps and new liquidity from accounts the pool's allowlist does not approve. "
            "The trader is read from hookData (20 bytes) or else tx.origin. Never blocks removing liquidity.";
    }

    // ------------------------------------------------------------------ operator

    modifier onlyOperator(PoolId id) {
        if (msg.sender != configOf[id].operator) revert NotOperator();
        _;
    }

    /// @notice Bind a pool to a Tape symbol. First caller becomes the pool's operator. Both gates
    ///         start enabled; until the operator sets an allowlist nobody is eligible.
    function bind(PoolKey calldata key, bytes32 symbol) external {
        PoolId id = key.toId();
        Config storage c = configOf[id];
        if (c.operator != address(0)) revert AlreadyBound();
        c.operator = msg.sender;
        c.symbol = symbol;
        c.gateSwaps = true;
        c.gateLiquidity = true;
        emit Bound(id, symbol, msg.sender);
    }

    /// @notice Point the pool at a different allowlist.
    function setAllowlist(PoolKey calldata key, IAllowlist allowlist) external onlyOperator(key.toId()) {
        configOf[key.toId()].allowlist = allowlist;
        emit AllowlistSet(key.toId(), address(allowlist));
    }

    /// @notice Choose which operations are gated.
    function setGates(PoolKey calldata key, bool gateSwaps, bool gateLiquidity) external onlyOperator(key.toId()) {
        Config storage c = configOf[key.toId()];
        c.gateSwaps = gateSwaps;
        c.gateLiquidity = gateLiquidity;
        emit GatesSet(key.toId(), gateSwaps, gateLiquidity);
    }

    // ------------------------------------------------------------------ status

    /// @notice Would `account` pass this pool's gate right now? Unbound pools and pools without an
    ///         allowlist answer false only when a gate is on; an unbound pool answers true.
    function isEligible(PoolKey calldata key, address account) external view returns (bool) {
        Config storage c = configOf[key.toId()];
        if (c.operator == address(0)) return true;
        return _allowed(c, account);
    }

    // ------------------------------------------------------------------ hooks

    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata, bytes calldata hookData)
        internal
        view
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        Config storage c = configOf[key.toId()];
        if (c.operator != address(0) && c.gateSwaps) _check(c, hookData);
        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    function _beforeAddLiquidity(address, PoolKey calldata key, ModifyLiquidityParams calldata, bytes calldata hookData)
        internal
        view
        override
        returns (bytes4)
    {
        Config storage c = configOf[key.toId()];
        if (c.operator != address(0) && c.gateLiquidity) _check(c, hookData);
        return BaseHook.beforeAddLiquidity.selector;
    }

    // ------------------------------------------------------------------ internal

    /// @dev The account to check: hookData of exactly 20 bytes, otherwise tx.origin.
    function _subject(bytes calldata hookData) internal view returns (address) {
        if (hookData.length == 20) return address(bytes20(hookData));
        return tx.origin;
    }

    function _allowed(Config storage c, address account) internal view returns (bool) {
        if (address(c.allowlist) == address(0)) return false; // no list: nobody is eligible
        return c.allowlist.isAllowed(account);
    }

    function _check(Config storage c, bytes calldata hookData) internal view {
        address who = _subject(hookData);
        if (!_allowed(c, who)) revert NotEligible(who);
    }
}
