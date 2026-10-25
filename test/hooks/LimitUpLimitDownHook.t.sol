// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "v4-core/test/utils/Deployers.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";
import {HookMiner} from "v4-periphery/src/utils/HookMiner.sol";

import {Tape} from "../../src/Tape.sol";
import {ITape} from "../../src/interfaces/ITape.sol";
import {IReferencePrice} from "../../src/interfaces/IReferencePrice.sol";
import {MockReferencePrice} from "../../src/test/MockReferencePrice.sol";
import {LimitUpLimitDownHook} from "../../src/hooks/LimitUpLimitDownHook.sol";

contract LimitUpLimitDownHookTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;

    Tape tape;
    MockReferencePrice oracle;
    LimitUpLimitDownHook hook;
    PoolKey poolKey;
    PoolId poolId;

    address reviewer = makeAddr("reviewer");
    uint256 attesterKey = 0xA11CE;
    address poster = makeAddr("poster");
    address operator = makeAddr("operator");
    bytes32 constant ALFA = bytes32("ALFA");
    uint64 constant WINDOW = 1 days;

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        tape = new Tape(reviewer, WINDOW, 0, 0);
        vm.prank(reviewer);
        tape.setAttester(ALFA, vm.addr(attesterKey));
        oracle = new MockReferencePrice();

        uint160 flags = uint160(Hooks.BEFORE_SWAP_FLAG);
        bytes memory ctorArgs = abi.encode(manager, tape);
        (address hookAddr, bytes32 salt) =
            HookMiner.find(address(this), flags, type(LimitUpLimitDownHook).creationCode, ctorArgs);
        hook = new LimitUpLimitDownHook{salt: salt}(manager, tape);
        assertEq(address(hook), hookAddr, "mined address must match");

        (poolKey, poolId) = initPool(currency0, currency1, IHooks(address(hook)), 3000, SQRT_PRICE_1_1);
        modifyLiquidityRouter.modifyLiquidity(poolKey, LIQUIDITY_PARAMS, ZERO_BYTES);

        vm.startPrank(operator);
        hook.bind(poolKey, ALFA);
        hook.setOracle(poolKey, IReferencePrice(address(oracle)));
        vm.stopPrank();

        vm.warp(1_000_000);
        _quote(SQRT_PRICE_1_1, uint64(vm.getBlockTimestamp()));
    }

    // ------------------------------------------------------------------ helpers

    function _quote(uint160 sqrtPrice, uint64 at) internal {
        oracle.set(ALFA, sqrtPrice, at);
    }

    function _finalize(ITape.Kind kind, uint64 effective, uint256 value, uint64 nonce) internal {
        ITape.Event memory e = ITape.Event({symbol: ALFA, kind: kind, effective: effective, value: value, nonce: nonce});
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(attesterKey, tape.digestOf(e));
        vm.prank(poster);
        bytes32 id = tape.post(e, abi.encodePacked(r, s, v));
        vm.warp(vm.getBlockTimestamp() + WINDOW);
        tape.finalize(id);
    }

    function _swap() internal {
        swap(poolKey, true, -1e15, ZERO_BYTES);
    }

    function _expectHookRevert(bytes memory inner) internal {
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.beforeSwap.selector,
                inner,
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
    }

    // ------------------------------------------------------------------ tests

    function test_permissionsAreInAddress() public view {
        uint160 mask = uint160(address(hook)) & Hooks.ALL_HOOK_MASK;
        assertEq(mask, uint160(Hooks.BEFORE_SWAP_FLAG));
    }

    function test_inBandPasses() public {
        (bool ok, uint256 bps) = hook.priceBps(poolKey);
        assertTrue(ok);
        assertApproxEqAbs(bps, 10_000, 1);
        _swap();
    }

    function test_edgeOfBandPasses() public {
        // reference 5% above pool: ratio ~ 9524 bps, inside the default 1000 bps band
        _quote(uint160((uint256(SQRT_PRICE_1_1) * 10247) / 10000), uint64(vm.getBlockTimestamp())); // sqrt(1.05)
        (, uint256 bps) = hook.priceBps(poolKey);
        assertGt(bps, 9000);
        assertLt(bps, 10_000);
        _swap();
    }

    function test_haltedReverts() public {
        _finalize(ITape.Kind.Halt, uint64(vm.getBlockTimestamp()), 1, 1);
        _quote(SQRT_PRICE_1_1, uint64(vm.getBlockTimestamp()));
        _expectHookRevert(abi.encodeWithSelector(LimitUpLimitDownHook.Halted.selector, ALFA));
        _swap();
    }

    function test_staleOracleReverts() public {
        _quote(SQRT_PRICE_1_1, uint64(vm.getBlockTimestamp() - 15 minutes - 1));
        _expectHookRevert(abi.encodeWithSelector(LimitUpLimitDownHook.NoReference.selector, ALFA));
        _swap();

        // exactly maxAge old is still fresh
        _quote(SQRT_PRICE_1_1, uint64(vm.getBlockTimestamp() - 15 minutes));
        _swap();
    }

    function test_missingOracleReverts() public {
        _quote(0, 0);
        _expectHookRevert(abi.encodeWithSelector(LimitUpLimitDownHook.NoReference.selector, ALFA));
        _swap();
    }

    function test_outsideBandReverts_belowReference() public {
        // reference is 2x the pool: pool/ref = 0.5 => ~5000 bps
        _quote(SQRT_PRICE_2_1, uint64(vm.getBlockTimestamp()));
        (, uint256 bps) = hook.priceBps(poolKey);
        assertApproxEqAbs(bps, 5000, 1);
        _expectHookRevert(abi.encodeWithSelector(LimitUpLimitDownHook.OutsideBand.selector, ALFA, bps, 1000));
        _swap();
    }

    function test_outsideBandReverts_aboveReference() public {
        // reference is half the pool: pool/ref = 2 => ~20000 bps
        _quote(SQRT_PRICE_1_2, uint64(vm.getBlockTimestamp()));
        (, uint256 bps) = hook.priceBps(poolKey);
        assertApproxEqAbs(bps, 20_000, 1);
        _expectHookRevert(abi.encodeWithSelector(LimitUpLimitDownHook.OutsideBand.selector, ALFA, bps, 1000));
        _swap();
    }

    function test_widerBandAdmitsSameQuote() public {
        _quote(SQRT_PRICE_2_1, uint64(vm.getBlockTimestamp()));
        vm.prank(operator);
        hook.setBand(poolKey, 6000);
        _swap();
    }

    function test_operatorOnlySetters() public {
        vm.expectRevert(LimitUpLimitDownHook.NotOperator.selector);
        hook.setBand(poolKey, 500);
        vm.expectRevert(LimitUpLimitDownHook.NotOperator.selector);
        hook.setOracle(poolKey, IReferencePrice(address(0)));
        vm.expectRevert(LimitUpLimitDownHook.NotOperator.selector);
        hook.setMaxAge(poolKey, 1 hours);

        vm.startPrank(operator);
        hook.setBand(poolKey, 500);
        hook.setMaxAge(poolKey, 1 hours);
        vm.stopPrank();
        (,,, uint256 band, uint64 maxAge) = hook.configOf(poolId);
        assertEq(band, 500);
        assertEq(maxAge, 1 hours);
    }

    function test_setMaxAgeChangesStaleness() public {
        _quote(SQRT_PRICE_1_1, uint64(vm.getBlockTimestamp() - 30 minutes));
        _expectHookRevert(abi.encodeWithSelector(LimitUpLimitDownHook.NoReference.selector, ALFA));
        _swap();
        vm.prank(operator);
        hook.setMaxAge(poolKey, 1 hours);
        _swap();
    }

    function test_bindOnce() public {
        vm.expectRevert(LimitUpLimitDownHook.AlreadyBound.selector);
        hook.bind(poolKey, ALFA);
    }

    function test_unboundPoolIsInert() public {
        (PoolKey memory k,) = initPool(currency0, currency1, IHooks(address(hook)), 500, SQRT_PRICE_1_1);
        modifyLiquidityRouter.modifyLiquidity(k, LIQUIDITY_PARAMS, ZERO_BYTES);
        _quote(0, 0);
        swap(k, true, -1e15, ZERO_BYTES);
    }

    function test_labelIsReadable() public view {
        assertGt(bytes(hook.label()).length, 40);
    }

    // ------------------------------------------------------------------ tradeStatus

    function test_status_ok() public view {
        (LimitUpLimitDownHook.TradeStatus st, bytes32 r, uint256 bps) = hook.tradeStatus(poolKey);
        assertEq(uint8(st), uint8(LimitUpLimitDownHook.TradeStatus.Ok));
        assertEq(r, bytes32("ok"));
        assertApproxEqAbs(bps, 10_000, 1);
    }

    function test_status_unknownWhenStale() public {
        _quote(SQRT_PRICE_1_1, uint64(vm.getBlockTimestamp() - 1 days));
        (LimitUpLimitDownHook.TradeStatus st, bytes32 r,) = hook.tradeStatus(poolKey);
        assertEq(uint8(st), uint8(LimitUpLimitDownHook.TradeStatus.Unknown));
        assertEq(r, bytes32("no-reference"));
    }

    function test_status_refusedOutsideBand_andHalted() public {
        _quote(SQRT_PRICE_2_1, uint64(vm.getBlockTimestamp()));
        (LimitUpLimitDownHook.TradeStatus st, bytes32 r,) = hook.tradeStatus(poolKey);
        assertEq(uint8(st), uint8(LimitUpLimitDownHook.TradeStatus.Refused));
        assertEq(r, bytes32("outside-band"));

        _finalize(ITape.Kind.Halt, uint64(vm.getBlockTimestamp()), 1, 1);
        (st, r,) = hook.tradeStatus(poolKey);
        assertEq(uint8(st), uint8(LimitUpLimitDownHook.TradeStatus.Refused));
        assertEq(r, bytes32("halted"));
    }
}
