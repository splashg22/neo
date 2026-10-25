// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "v4-core/src/libraries/FixedPoint96.sol";
import {ITape} from "../interfaces/ITape.sol";
import {IReferencePrice} from "../interfaces/IReferencePrice.sol";

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
///         Permissions (low 14 bits of this contract's address): BEFORE_SWAP.
contract LimitUpLimitDownHook is BaseHook {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint256 internal constant BPS = 10_000;
    uint256 internal constant DEFAULT_BAND_BPS = 1000; // 10%
    uint64 internal constant DEFAULT_MAX_AGE = 15 minutes;

    ITape public immutable tape;

    struct Config {
        bytes32 symbol;
        address operator;
        IReferencePrice oracle;
        uint256 bandBps;
        uint64 maxAge;
    }

    mapping(PoolId => Config) public configOf;

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
        return "Refuses swaps while the stock is halted, while no fresh reference price exists, or while "
            "the pool price is more than the band away from the reference price. Never touches liquidity.";
    }

    // ------------------------------------------------------------------ operator

    modifier onlyOperator(PoolId id) {
        if (msg.sender != configOf[id].operator) revert NotOperator();
        _;
    }

    /// @notice Bind a pool to a Tape symbol. First caller becomes the pool's operator. Band and max
    ///         age start at their defaults; the operator must `setOracle` before swaps can pass.
    function bind(PoolKey calldata key, bytes32 symbol) external {
        PoolId id = key.toId();
        Config storage c = configOf[id];
        if (c.operator != address(0)) revert AlreadyBound();
        c.operator = msg.sender;
        c.symbol = symbol;
        c.bandBps = DEFAULT_BAND_BPS;
        c.maxAge = DEFAULT_MAX_AGE;
        emit Bound(id, symbol, msg.sender);
    }

    /// @notice Set the half-width of the band in bps (1000 = ±10%). Must be below 100%.
    function setBand(PoolKey calldata key, uint256 bandBps) external onlyOperator(key.toId()) {
        if (bandBps == 0 || bandBps >= BPS) revert BadBand();
        configOf[key.toId()].bandBps = bandBps;
        emit BandSet(key.toId(), bandBps);
    }

    /// @notice Set the reference price feed.
    function setOracle(PoolKey calldata key, IReferencePrice oracle) external onlyOperator(key.toId()) {
        configOf[key.toId()].oracle = oracle;
        emit OracleSet(key.toId(), address(oracle));
    }

    /// @notice Set how old a reference quote may be before it counts as absent.
    function setMaxAge(PoolKey calldata key, uint64 maxAge) external onlyOperator(key.toId()) {
        configOf[key.toId()].maxAge = maxAge;
        emit MaxAgeSet(key.toId(), maxAge);
    }

    // ------------------------------------------------------------------ status

    /// @notice Pool price as a fraction of the reference price, in bps (10_000 = equal).
    /// @return ok   false when no fresh reference exists
    /// @return bps  the ratio; type(uint256).max when the ratio does not fit
    function priceBps(PoolKey calldata key) external view returns (bool ok, uint256 bps) {
        Config storage c = configOf[key.toId()];
        (bool fresh, uint160 ref) = _reference(c);
        if (!fresh) return (false, 0);
        (uint160 pool,,,) = poolManager.getSlot0(key.toId());
        return (true, _ratioBps(pool, ref));
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
        Config storage c = configOf[id];
        if (c.symbol == bytes32(0)) return (TradeStatus.Ok, "unbound", 0);
        if (tape.isHalted(c.symbol)) return (TradeStatus.Refused, "halted", 0);
        (bool fresh, uint160 ref) = _reference(c);
        if (!fresh) return (TradeStatus.Unknown, "no-reference", 0);
        (uint160 pool,,,) = poolManager.getSlot0(id);
        poolBps = _ratioBps(pool, ref);
        if (poolBps < BPS - c.bandBps || poolBps > BPS + c.bandBps) {
            return (TradeStatus.Refused, "outside-band", poolBps);
        }
        return (TradeStatus.Ok, "ok", poolBps);
    }

    // ------------------------------------------------------------------ hooks

    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata, bytes calldata)
        internal
        view
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId id = key.toId();
        Config storage c = configOf[id];
        bytes32 sym = c.symbol;
        if (sym != bytes32(0)) {
            if (tape.isHalted(sym)) revert Halted(sym);
            (bool fresh, uint160 ref) = _reference(c);
            if (!fresh) revert NoReference(sym);
            (uint160 pool,,,) = poolManager.getSlot0(id);
            uint256 bps = _ratioBps(pool, ref);
            if (bps < BPS - c.bandBps || bps > BPS + c.bandBps) revert OutsideBand(sym, bps, c.bandBps);
        }
        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    // ------------------------------------------------------------------ internal

    /// @dev Fresh reference price, or (false, 0) when the oracle is unset, returns 0, or is older than maxAge.
    function _reference(Config storage c) internal view returns (bool fresh, uint160 sqrtPriceX96) {
        if (address(c.oracle) == address(0)) return (false, 0);
        (uint160 p, uint64 updatedAt) = c.oracle.latest(c.symbol);
        if (p == 0 || updatedAt == 0) return (false, 0);
        if (block.timestamp > updatedAt && block.timestamp - updatedAt > c.maxAge) return (false, 0);
        return (true, p);
    }

    /// @dev (pool / ref)^2 * 1e4, computed from the two sqrt prices. Saturates instead of overflowing.
    function _ratioBps(uint160 poolSqrt, uint160 refSqrt) internal pure returns (uint256) {
        // sqrt ratio in Q96
        uint256 r = FullMath.mulDiv(poolSqrt, FixedPoint96.Q96, refSqrt);
        if (r > type(uint128).max) return type(uint256).max; // pool price > 2^64 x reference: certainly outside
        // square, then scale to bps: r^2 / 2^192 * 1e4
        uint256 sq = FullMath.mulDiv(r, r, FixedPoint96.Q96);
        return FullMath.mulDiv(sq, BPS, FixedPoint96.Q96);
    }
}
