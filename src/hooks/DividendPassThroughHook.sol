// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {ITape} from "../interfaces/ITape.sol";
import {ModuleBase} from "../modules/ModuleBase.sol";
import {DividendModule} from "../modules/DividendModule.sol";

/// @title DividendPassThroughHook — pays a stock's cash dividend to the pool's LPs
/// @notice The issuer (or its custodian) deposits quote tokens into this hook as escrow. The first
///         swap at or after the pay date of a finalized `Dividend` on the Tape flushes the escrow into
///         the pool with `poolManager.donate`, so it accrues to in-range liquidity as fees. Each
///         `(effective, value)` dividend is flushed at most once.
///
///         What this does and does not do, plainly: `donate` credits whoever has in-range liquidity
///         at the moment of the flush, which is the first swap after the pay date, not the record
///         date. An LP who left between record date and pay date receives nothing; one who joined
///         after the record date is paid. It is also exposed to just-in-time liquidity around the
///         flushing swap (see the note on `IPoolManager.donate`). A record-date snapshot of
///         positions is future work.
///
///         The escrow and flush logic live in `DividendModule`; this contract is the standalone hook.
///
///         Permissions (low 14 bits of this contract's address): BEFORE_SWAP only. The swap is used
///         purely as a trigger; the hook never alters swap amounts or fees.
contract DividendPassThroughHook is BaseHook, DividendModule {
    using PoolIdLibrary for PoolKey;

    event Bound(PoolId indexed poolId, bytes32 symbol, Currency quote, address operator);
    event Deposited(PoolId indexed poolId, address from, uint256 amount, uint256 escrow);
    event DividendDistributed(PoolId indexed poolId, uint64 effective, uint256 amount);

    error AlreadyBound();
    error NotBound();
    error BadQuote();
    error ZeroAmount();
    error BadValue();
    error TransferFailed();

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
        return "Holds the issuer's cash dividend in escrow and pays it to the pool's in-range liquidity "
            "providers on the first swap at or after the pay date. Never blocks trading or liquidity.";
    }

    // ------------------------------------------------------------------ operator

    /// @notice Bind a pool to a Tape symbol and name its quote currency. First caller becomes operator.
    /// @param key    the pool
    /// @param symbol Tape symbol of the stock side, e.g. bytes32("ALFA")
    /// @param quote  the pool currency dividends are paid in; must be `key.currency0` or `key.currency1`
    function bind(PoolKey calldata key, bytes32 symbol, Currency quote) external {
        PoolId id = key.toId();
        _bindPool(id, symbol);
        _dividendInit(key, quote);
        emit Bound(id, symbol, quote, msg.sender);
    }

    // ------------------------------------------------------------------ hooks

    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (_dividendActive(key.toId())) _dividendFlush(key);
        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }
}
