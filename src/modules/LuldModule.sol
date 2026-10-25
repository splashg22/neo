// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "v4-core/src/libraries/FixedPoint96.sol";
import {IReferencePrice} from "../interfaces/IReferencePrice.sol";
import {ModuleBase, TradeStatus} from "./ModuleBase.sol";

event BandSet(PoolId indexed poolId, uint256 bandBps);
event OracleSet(PoolId indexed poolId, address oracle);
event MaxAgeSet(PoolId indexed poolId, uint64 maxAge);

error NoReference(bytes32 symbol);
error OutsideBand(bytes32 symbol, uint256 poolBps, uint256 bandBps);
error BadBand();

/// @title LuldModule — limit up / limit down band around a reference price
/// @notice Refuses while no fresh reference price exists and while the pool's pre-swap price is
///         outside `bandBps` of the reference. Unknown is never ok: a stale reference refuses.
abstract contract LuldModule is ModuleBase {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint256 internal constant BPS = 10_000;
    uint256 internal constant DEFAULT_BAND_BPS = 1000; // 10%
    uint64 internal constant DEFAULT_MAX_AGE = 15 minutes;

    struct LuldConfig {
        IReferencePrice oracle;
        uint256 bandBps;
        uint64 maxAge;
    }

    mapping(PoolId => LuldConfig) public luldConfigOf;

    // ------------------------------------------------------------------ operator

    /// @notice Set the half-width of the band in bps (1000 = ±10%). Must be below 100%.
    function setBand(PoolKey calldata key, uint256 bandBps) external onlyOperator(key.toId()) {
        if (bandBps == 0 || bandBps >= BPS) revert BadBand();
        luldConfigOf[key.toId()].bandBps = bandBps;
        emit BandSet(key.toId(), bandBps);
    }

    /// @notice Set the reference price feed.
    function setOracle(PoolKey calldata key, IReferencePrice oracle) external onlyOperator(key.toId()) {
        luldConfigOf[key.toId()].oracle = oracle;
        emit OracleSet(key.toId(), address(oracle));
    }

    /// @notice Set how old a reference quote may be before it counts as absent.
    function setMaxAge(PoolKey calldata key, uint64 maxAge) external onlyOperator(key.toId()) {
        luldConfigOf[key.toId()].maxAge = maxAge;
        emit MaxAgeSet(key.toId(), maxAge);
    }

    // ------------------------------------------------------------------ status

    /// @notice Pool price as a fraction of the reference price, in bps (10_000 = equal).
    /// @return ok   false when no fresh reference exists
    /// @return bps  the ratio; type(uint256).max when the ratio does not fit
    function priceBps(PoolKey calldata key) external view returns (bool ok, uint256 bps) {
        PoolId id = key.toId();
        (bool fresh, uint160 ref) = _reference(id);
        if (!fresh) return (false, 0);
        (uint160 pool,,,) = poolManager.getSlot0(id);
        return (true, _ratioBps(pool, ref));
    }

    // ------------------------------------------------------------------ internal

    /// @dev Defaults at bind time: ±10%, 15 minutes. The operator must `setOracle` before swaps pass.
    function _luldInit(PoolId id) internal {
        LuldConfig storage c = luldConfigOf[id];
        c.bandBps = DEFAULT_BAND_BPS;
        c.maxAge = DEFAULT_MAX_AGE;
    }

    /// @dev Whether the band check applies to this pool. Standalone: bound. NeoHook: bound + toggled on.
    function _luldActive(PoolId id) internal view virtual returns (bool) {
        return _isBound(id);
    }

    /// @dev Revert NoReference / OutsideBand. The halt check is the caller's business.
    function _luldCheck(PoolId id, bytes32 sym) internal view {
        (bool fresh, uint160 ref) = _reference(id);
        if (!fresh) revert NoReference(sym);
        (uint160 pool,,,) = poolManager.getSlot0(id);
        uint256 bps = _ratioBps(pool, ref);
        uint256 band = luldConfigOf[id].bandBps;
        if (bps < BPS - band || bps > BPS + band) revert OutsideBand(sym, bps, band);
    }

    /// @dev Status view of `_luldCheck`. reason: "no-reference" | "outside-band" | "ok"
    function _luldStatus(PoolId id) internal view returns (TradeStatus status, bytes32 reason, uint256 poolBps) {
        (bool fresh, uint160 ref) = _reference(id);
        if (!fresh) return (TradeStatus.Unknown, "no-reference", 0);
        (uint160 pool,,,) = poolManager.getSlot0(id);
        poolBps = _ratioBps(pool, ref);
        uint256 band = luldConfigOf[id].bandBps;
        if (poolBps < BPS - band || poolBps > BPS + band) return (TradeStatus.Refused, "outside-band", poolBps);
        return (TradeStatus.Ok, "ok", poolBps);
    }

    /// @dev Fresh reference price, or (false, 0) when the oracle is unset, returns 0, or is older than maxAge.
    function _reference(PoolId id) internal view returns (bool fresh, uint160 sqrtPriceX96) {
        LuldConfig storage c = luldConfigOf[id];
        if (address(c.oracle) == address(0)) return (false, 0);
        (uint160 p, uint64 updatedAt) = c.oracle.latest(symbolOf[id]);
        if (p == 0 || updatedAt == 0) return (false, 0);
        if (block.timestamp > updatedAt && block.timestamp - updatedAt > c.maxAge) return (false, 0);
        return (true, p);
    }

    /// @dev (pool / ref)^2 * 1e4, computed from the two sqrt prices. Saturates instead of overflowing.
    function _ratioBps(uint160 poolSqrt, uint160 refSqrt) internal pure returns (uint256) {
        uint256 r = FullMath.mulDiv(poolSqrt, FixedPoint96.Q96, refSqrt);
        if (r > type(uint128).max) return type(uint256).max; // pool price > 2^64 x reference: certainly outside
        uint256 sq = FullMath.mulDiv(r, r, FixedPoint96.Q96);
        return FullMath.mulDiv(sq, BPS, FixedPoint96.Q96);
    }
}
