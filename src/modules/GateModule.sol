// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {IAllowlist} from "../interfaces/IAllowlist.sol";
import {ModuleBase} from "./ModuleBase.sol";

event AllowlistSet(PoolId indexed poolId, address allowlist);
event GatesSet(PoolId indexed poolId, bool gateSwaps, bool gateLiquidity);

error NotEligible(address account);

/// @title GateModule — eligibility gate on swaps and new liquidity
/// @notice Refuses accounts the pool's allowlist does not approve. The checked account is read from
///         `hookData` when it is exactly 20 bytes (`abi.encodePacked(address)`), otherwise `tx.origin`.
///         See EligibilityGateHook for the limitation this implies. Removing liquidity is never gated.
abstract contract GateModule is ModuleBase {
    using PoolIdLibrary for PoolKey;

    struct GateConfig {
        IAllowlist allowlist;
        bool gateSwaps;
        bool gateLiquidity;
    }

    mapping(PoolId => GateConfig) public gateConfigOf;

    // ------------------------------------------------------------------ operator

    /// @notice Point the pool at a different allowlist.
    function setAllowlist(PoolKey calldata key, IAllowlist allowlist) external onlyOperator(key.toId()) {
        gateConfigOf[key.toId()].allowlist = allowlist;
        emit AllowlistSet(key.toId(), address(allowlist));
    }

    /// @notice Choose which operations are gated.
    function setGates(PoolKey calldata key, bool gateSwaps, bool gateLiquidity) external onlyOperator(key.toId()) {
        GateConfig storage c = gateConfigOf[key.toId()];
        c.gateSwaps = gateSwaps;
        c.gateLiquidity = gateLiquidity;
        emit GatesSet(key.toId(), gateSwaps, gateLiquidity);
    }

    // ------------------------------------------------------------------ status

    /// @notice Would `account` pass this pool's gate right now? A pool the gate does not apply to
    ///         answers true; a gated pool without an allowlist answers false.
    function isEligible(PoolKey calldata key, address account) external view returns (bool) {
        PoolId id = key.toId();
        if (!_gateActive(id)) return true;
        return _allowed(id, account);
    }

    // ------------------------------------------------------------------ internal

    /// @dev Defaults at bind time: both gates on; until an allowlist is set nobody is eligible.
    function _gateInit(PoolId id) internal {
        GateConfig storage c = gateConfigOf[id];
        c.gateSwaps = true;
        c.gateLiquidity = true;
    }

    /// @dev Whether the gate applies to this pool. Standalone: bound. NeoHook: bound + toggled on.
    function _gateActive(PoolId id) internal view virtual returns (bool) {
        return _isBound(id);
    }

    /// @dev Gate a swap (when `gateSwaps`); reverts NotEligible.
    function _gateSwapCheck(PoolId id, bytes calldata hookData) internal view {
        if (gateConfigOf[id].gateSwaps) _gateCheck(id, hookData);
    }

    /// @dev Gate new liquidity (when `gateLiquidity`); reverts NotEligible.
    function _gateLiquidityCheck(PoolId id, bytes calldata hookData) internal view {
        if (gateConfigOf[id].gateLiquidity) _gateCheck(id, hookData);
    }

    function _gateCheck(PoolId id, bytes calldata hookData) internal view {
        address who = _subject(hookData);
        if (!_allowed(id, who)) revert NotEligible(who);
    }

    /// @dev The account to check: hookData of exactly 20 bytes, otherwise tx.origin.
    function _subject(bytes calldata hookData) internal view returns (address) {
        if (hookData.length == 20) return address(bytes20(hookData));
        return tx.origin;
    }

    function _allowed(PoolId id, address account) internal view returns (bool) {
        IAllowlist list = gateConfigOf[id].allowlist;
        if (address(list) == address(0)) return false; // no list: nobody is eligible
        return list.isAllowed(account);
    }
}
