// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "v4-core/test/utils/Deployers.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {HookMiner} from "v4-periphery/src/utils/HookMiner.sol";

import {Tape} from "../../src/Tape.sol";
import {ITape} from "../../src/interfaces/ITape.sol";
import {VolatilityFeeHook} from "../../src/hooks/VolatilityFeeHook.sol";

contract VolatilityFeeHookTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;

    Tape tape;
    VolatilityFeeHook hook;
    PoolKey poolKey;
    PoolId poolId;

    address reviewer = makeAddr("reviewer");
    uint256 attesterKey = 0xA11CE;
    address poster = makeAddr("poster");
    address operator = makeAddr("operator");
    bytes32 constant ALFA = bytes32("ALFA");
    uint64 constant WINDOW = 1 days;

    uint24 constant BASE = 500;
    uint24 constant MAX = 10_000;

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        tape = new Tape(reviewer, WINDOW, 0, 0);
        vm.prank(reviewer);
        tape.setAttester(ALFA, vm.addr(attesterKey));

        uint160 flags = uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG);
        bytes memory ctorArgs = abi.encode(manager, tape);
        (address hookAddr, bytes32 salt) =
            HookMiner.find(address(this), flags, type(VolatilityFeeHook).creationCode, ctorArgs);
        hook = new VolatilityFeeHook{salt: salt}(manager, tape);
        assertEq(address(hook), hookAddr, "mined address must match");

        (poolKey, poolId) =
            initPool(currency0, currency1, IHooks(address(hook)), LPFeeLibrary.DYNAMIC_FEE_FLAG, SQRT_PRICE_1_1);
        modifyLiquidityRouter.modifyLiquidity(poolKey, LIQUIDITY_PARAMS, ZERO_BYTES);

        vm.prank(operator);
        hook.bind(poolKey, ALFA);
        vm.warp(1_000_000);
    }

    // ------------------------------------------------------------------ helpers

    function _finalize(ITape.Kind kind, uint64 effective, uint256 value, uint64 nonce) internal {
        ITape.Event memory e = ITape.Event({symbol: ALFA, kind: kind, effective: effective, value: value, nonce: nonce});
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(attesterKey, tape.digestOf(e));
        vm.prank(poster);
        bytes32 id = tape.post(e, abi.encodePacked(r, s, v));
        vm.warp(vm.getBlockTimestamp() + WINDOW);
        tape.finalize(id);
    }

    function _swap(bool zeroForOne, int256 amount) internal returns (BalanceDelta) {
        return swap(poolKey, zeroForOne, amount, ZERO_BYTES);
    }

    // ------------------------------------------------------------------ tests

    function test_permissionsAreInAddress() public view {
        uint160 mask = uint160(address(hook)) & Hooks.ALL_HOOK_MASK;
        assertEq(mask, uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG));
    }

    function test_firstSwapChargesBaseFee() public {
        assertEq(hook.currentFee(poolKey), BASE);
        assertEq(hook.ewmaOf(poolId), 0);

        vm.expectEmit(true, false, false, true, address(hook));
        emit VolatilityFeeHook.FeeCharged(poolId, BASE);
        _swap(true, -1e15);

        // the swap moved the tick, so the EWMA is now non-zero and the next fee is higher
        assertGt(hook.ewmaOf(poolId), 0);
        assertGt(hook.currentFee(poolKey), BASE);
    }

    function test_feeRisesWithVolatility_andIsCapped() public {
        uint24 last = hook.currentFee(poolKey);
        // alternating swaps inside the liquidity range: each moves the tick ~20
        for (uint256 i = 0; i < 6; i++) {
            _swap(i % 2 == 0, -1e15);
            uint24 f = hook.currentFee(poolKey);
            assertGe(f, last, "fee should not fall while every swap moves the price");
            assertLe(f, MAX);
            last = f;
        }
        assertGt(last, BASE);

        // much larger moves: fee saturates at maxFee and never exceeds it
        for (uint256 i = 0; i < 6; i++) {
            _swap(i % 2 == 0, -1e16);
            assertLe(hook.currentFee(poolKey), MAX);
        }
        assertEq(hook.currentFee(poolKey), MAX);
    }

    function test_higherFeeGivesLessOutput() public {
        // same-size swap, before and after volatility was observed: higher fee => less out
        BalanceDelta first = _swap(true, -1e15);
        for (uint256 i = 0; i < 4; i++) _swap(i % 2 == 1, -1e15); // ends with a oneForZero swap
        // bring price back near where it started so the comparison is fair-ish
        BalanceDelta later = _swap(true, -1e15);
        assertGt(hook.currentFee(poolKey), BASE);
        assertLt(later.amount1(), first.amount1(), "later swap paid a higher fee");
    }

    function test_eventWithinWindowBumpsFee() public {
        uint64 eff = uint64(vm.getBlockTimestamp() + 3 days);
        _finalize(ITape.Kind.Dividend, eff, 24, 1);

        assertFalse(hook.inEventWindow(poolKey));
        assertEq(hook.currentFee(poolKey), BASE);

        vm.warp(eff - 30 minutes); // before, inside the 1-hour window
        assertTrue(hook.inEventWindow(poolKey));
        assertEq(hook.currentFee(poolKey), BASE + 20 * 100);

        vm.warp(eff + 1 hours); // after, at the edge
        assertTrue(hook.inEventWindow(poolKey));
        assertEq(hook.currentFee(poolKey), BASE + 20 * 100);

        vm.warp(eff + 1 hours + 1);
        assertFalse(hook.inEventWindow(poolKey));
        assertEq(hook.currentFee(poolKey), BASE);

        vm.warp(eff);
        vm.expectEmit(true, false, false, true, address(hook));
        emit VolatilityFeeHook.FeeCharged(poolId, BASE + 20 * 100);
        _swap(true, -1e15);
    }

    function test_eventBumpAppliesOnTopOfCap() public {
        for (uint256 i = 0; i < 6; i++) _swap(i % 2 == 0, -1e16);
        assertEq(hook.currentFee(poolKey), MAX);
        // _finalize warps forward by WINDOW, so this lands the split exactly on the new "now"
        _finalize(ITape.Kind.Split, uint64(vm.getBlockTimestamp() + WINDOW), 40_000, 1);
        assertTrue(hook.inEventWindow(poolKey));
        assertEq(hook.currentFee(poolKey), MAX + 20 * 100);
    }

    function test_poolMustBeDynamicFee() public {
        (PoolKey memory k,) = initPool(currency0, currency1, IHooks(address(hook)), 3000, SQRT_PRICE_1_1);
        vm.expectRevert(VolatilityFeeHook.NotDynamicFee.selector);
        hook.bind(k, ALFA);
    }

    function test_unboundPoolIsInert() public {
        // different tick spacing so this is a distinct pool from the bound one
        (PoolKey memory k,) =
            initPool(currency0, currency1, IHooks(address(hook)), LPFeeLibrary.DYNAMIC_FEE_FLAG, 10, SQRT_PRICE_1_1);
        modifyLiquidityRouter.modifyLiquidity(k, LIQUIDITY_PARAMS, ZERO_BYTES);
        assertEq(hook.currentFee(k), 0);
        swap(k, true, -1e15, ZERO_BYTES);
        assertEq(hook.ewmaOf(k.toId()), 0);
    }

    function test_setConfigOperatorOnly_andValidated() public {
        VolatilityFeeHook.Config memory cfg = VolatilityFeeHook.Config({
            symbol: bytes32(0),
            operator: address(0),
            baseFee: 1000,
            maxFee: 5000,
            feePerTick: 1,
            window: 4,
            eventBumpBps: 5,
            eventBumpSeconds: 10 minutes
        });
        vm.expectRevert(VolatilityFeeHook.NotOperator.selector);
        hook.setConfig(poolKey, cfg);

        vm.prank(operator);
        hook.setConfig(poolKey, cfg);
        assertEq(hook.currentFee(poolKey), 1000);
        (bytes32 sym, address op,, uint24 maxFee,, uint32 window,,) = hook.configOf(poolId);
        assertEq(sym, ALFA);
        assertEq(op, operator);
        assertEq(maxFee, 5000);
        assertEq(window, 4);

        cfg.window = 0;
        vm.prank(operator);
        vm.expectRevert(VolatilityFeeHook.BadConfig.selector);
        hook.setConfig(poolKey, cfg);

        cfg.window = 4;
        cfg.baseFee = 6000; // above maxFee
        vm.prank(operator);
        vm.expectRevert(VolatilityFeeHook.BadConfig.selector);
        hook.setConfig(poolKey, cfg);
    }

    function test_bindOnce() public {
        vm.expectRevert(VolatilityFeeHook.AlreadyBound.selector);
        hook.bind(poolKey, ALFA);
    }

    function test_labelIsReadable() public view {
        assertGt(bytes(hook.label()).length, 40);
    }
}
