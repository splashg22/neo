// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IERC20Minimal} from "v4-core/src/interfaces/external/IERC20Minimal.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {CurrencySettler} from "v4-core/test/utils/CurrencySettler.sol";
import {ITape} from "../interfaces/ITape.sol";

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
///         Permissions (low 14 bits of this contract's address): BEFORE_SWAP only. The swap is used
///         purely as a trigger; the hook never alters swap amounts or fees.
contract DividendPassThroughHook is BaseHook {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using CurrencySettler for Currency;

    ITape public immutable tape;

    mapping(PoolId => bytes32) public symbolOf;
    mapping(PoolId => address) public operatorOf;
    /// @notice The non-stock side of the pool: the currency dividends are paid in.
    mapping(PoolId => Currency) public quoteOf;
    /// @notice Quote tokens held by this hook for the pool's next dividend flush.
    mapping(PoolId => uint256) public escrowOf;
    /// @dev keccak256(abi.encode(effective, value)) of the dividend last flushed for this pool
    mapping(PoolId => bytes32) public flushed;

    event Bound(PoolId indexed poolId, bytes32 symbol, Currency quote, address operator);
    event Deposited(PoolId indexed poolId, address from, uint256 amount, uint256 escrow);
    event DividendDistributed(PoolId indexed poolId, uint64 effective, uint256 amount);

    error AlreadyBound();
    error NotBound();
    error BadQuote();
    error ZeroAmount();
    error BadValue();
    error TransferFailed();

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
        if (operatorOf[id] != address(0)) revert AlreadyBound();
        if (!(quote == key.currency0 || quote == key.currency1)) revert BadQuote();
        operatorOf[id] = msg.sender;
        symbolOf[id] = symbol;
        quoteOf[id] = quote;
        emit Bound(id, symbol, quote, msg.sender);
    }

    // ------------------------------------------------------------------ escrow

    /// @notice Escrow quote tokens for the pool's next dividend. Anyone may deposit.
    /// @dev For an ERC-20 quote the caller must have approved this hook; `msg.value` must be 0.
    ///      For a native quote, `msg.value` must equal `amount`.
    function deposit(PoolKey calldata key, uint256 amount) external payable {
        PoolId id = key.toId();
        if (operatorOf[id] == address(0)) revert NotBound();
        if (amount == 0) revert ZeroAmount();
        Currency quote = quoteOf[id];
        if (quote.isAddressZero()) {
            if (msg.value != amount) revert BadValue();
        } else {
            if (msg.value != 0) revert BadValue();
            if (!IERC20Minimal(Currency.unwrap(quote)).transferFrom(msg.sender, address(this), amount)) {
                revert TransferFailed();
            }
        }
        uint256 escrow = escrowOf[id] + amount;
        escrowOf[id] = escrow;
        emit Deposited(id, msg.sender, amount, escrow);
    }

    // ------------------------------------------------------------------ status

    /// @notice Whether the next swap on this pool would flush a dividend, without sending one.
    /// @return ready     true if a swap right now would donate the escrow
    /// @return reason    "unbound" | "no-escrow" | "no-dividend" | "not-yet" | "flushed" | "no-liquidity" | "ready"
    /// @return effective pay date of the Tape's current dividend (0 if none)
    /// @return amount    escrow that would be donated
    function pendingDividend(PoolKey calldata key)
        external
        view
        returns (bool ready, bytes32 reason, uint64 effective, uint256 amount)
    {
        PoolId id = key.toId();
        bytes32 sym = symbolOf[id];
        if (sym == bytes32(0)) return (false, "unbound", 0, 0);
        amount = escrowOf[id];
        (ITape.Kind kind, uint64 eff, uint256 value) = tape.action(sym);
        if (kind != ITape.Kind.Dividend) return (false, "no-dividend", 0, amount);
        effective = eff;
        if (amount == 0) return (false, "no-escrow", eff, 0);
        if (block.timestamp < eff) return (false, "not-yet", eff, amount);
        if (flushed[id] == keccak256(abi.encode(eff, value))) return (false, "flushed", eff, amount);
        if (poolManager.getLiquidity(id) == 0) return (false, "no-liquidity", eff, amount);
        return (true, "ready", eff, amount);
    }

    // ------------------------------------------------------------------ hooks

    /// @dev The manager is unlocked while it runs a swap, so `donate` is callable here. The donate
    ///      leaves this hook with a negative delta in the quote currency, which is paid from the
    ///      hook's own balance (sync / transfer / settle) before returning.
    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        _flush(key);
        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    // ------------------------------------------------------------------ internal

    function _flush(PoolKey calldata key) internal {
        PoolId id = key.toId();
        bytes32 sym = symbolOf[id];
        if (sym == bytes32(0)) return; // unbound pool: hook is inert
        uint256 escrow = escrowOf[id];
        if (escrow == 0) return;
        (ITape.Kind kind, uint64 effective, uint256 value) = tape.action(sym);
        if (kind != ITape.Kind.Dividend || block.timestamp < effective) return;
        bytes32 h = keccak256(abi.encode(effective, value));
        if (flushed[id] == h) return;
        // donate reverts when nobody is in range; keep the escrow for a later swap instead
        if (poolManager.getLiquidity(id) == 0) return;

        flushed[id] = h;
        escrowOf[id] = 0;
        Currency quote = quoteOf[id];
        bool quoteIs0 = quote == key.currency0;
        poolManager.donate(key, quoteIs0 ? escrow : 0, quoteIs0 ? 0 : escrow, "");
        quote.settle(poolManager, address(this), escrow, false);
        emit DividendDistributed(id, effective, escrow);
    }
}
