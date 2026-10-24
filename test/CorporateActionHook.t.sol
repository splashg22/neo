// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "v4-core/test/utils/Deployers.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";
import {HookMiner} from "v4-periphery/src/utils/HookMiner.sol";

import {Tape} from "../src/Tape.sol";
import {ITape} from "../src/interfaces/ITape.sol";
import {CorporateActionHook} from "../src/CorporateActionHook.sol";

contract CorporateActionHookTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;

    Tape tape;
    CorporateActionHook hook;
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

        uint160 flags = uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG);
        bytes memory ctorArgs = abi.encode(manager, tape);
        (address hookAddr, bytes32 salt) =
            HookMiner.find(address(this), flags, type(CorporateActionHook).creationCode, ctorArgs);
        hook = new CorporateActionHook{salt: salt}(manager, tape);
        assertEq(address(hook), hookAddr, "mined address must match");

        (poolKey, poolId) = initPool(currency0, currency1, IHooks(address(hook)), 3000, SQRT_PRICE_1_1);
        modifyLiquidityRouter.modifyLiquidity(poolKey, LIQUIDITY_PARAMS, ZERO_BYTES);

        vm.prank(operator);
        hook.bind(poolKey, ALFA);
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
        assertEq(mask, uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG));
    }

    function test_swapsWorkWhenNothingHappened() public {
        _swap();
    }

    function test_haltBlocksSwap_andLiftUnblocks() public {
        _finalize(ITape.Kind.Halt, uint64(vm.getBlockTimestamp()), 1, 1);
        _expectHookRevert(abi.encodeWithSelector(CorporateActionHook.Halted.selector, ALFA));
        _swap();

        _finalize(ITape.Kind.Halt, uint64(vm.getBlockTimestamp()), 0, 2);
        _swap();
    }

    function test_haltBlocksAddLiquidity_butNotRemove() public {
        _finalize(ITape.Kind.Halt, uint64(vm.getBlockTimestamp()), 1, 1);

        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.beforeAddLiquidity.selector,
                abi.encodeWithSelector(CorporateActionHook.Halted.selector, ALFA),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        modifyLiquidityRouter.modifyLiquidity(poolKey, LIQUIDITY_PARAMS, ZERO_BYTES);

        // LPs can always leave
        modifyLiquidityRouter.modifyLiquidity(poolKey, REMOVE_LIQUIDITY_PARAMS, ZERO_BYTES);
    }

    function test_splitBlocksUntilAcknowledged() public {
        uint64 eff = uint64(vm.getBlockTimestamp() + 3 days);
        _finalize(ITape.Kind.Split, eff, 40_000, 1);

        // before the effective time the pool trades normally
        _swap();

        vm.warp(eff);
        _expectHookRevert(
            abi.encodeWithSelector(CorporateActionHook.AwaitingAcknowledgement.selector, ALFA, ITape.Kind.Split, eff)
        );
        _swap();

        vm.prank(operator);
        hook.acknowledge(poolKey);
        _swap();
    }

    function test_acknowledgeOnlyOperator() public {
        vm.expectRevert(CorporateActionHook.NotOperator.selector);
        hook.acknowledge(poolKey);
    }

    function test_dividendNeverBlocks() public {
        _finalize(ITape.Kind.Dividend, uint64(vm.getBlockTimestamp()), 24, 1);
        _swap();
    }

    function test_unboundPoolIsInert() public {
        (PoolKey memory k,) = initPool(currency0, currency1, IHooks(address(hook)), 500, SQRT_PRICE_1_1);
        modifyLiquidityRouter.modifyLiquidity(k, LIQUIDITY_PARAMS, ZERO_BYTES);
        _finalize(ITape.Kind.Halt, uint64(vm.getBlockTimestamp()), 1, 1);
        swap(k, true, -1e15, ZERO_BYTES); // ALFA is halted but this pool isn't bound
    }

    function test_labelIsReadable() public view {
        assertGt(bytes(hook.label()).length, 40);
    }

    // ------------------------------------------------------------------ tradeStatus

    function _status() internal view returns (CorporateActionHook.TradeStatus st, bytes32 reason, uint64 eff) {
        return hook.tradeStatus(poolKey);
    }

    function test_status_okWhenNothingHappened() public view {
        (CorporateActionHook.TradeStatus st, bytes32 r,) = _status();
        assertEq(uint8(st), uint8(CorporateActionHook.TradeStatus.Ok));
        assertEq(r, bytes32("ok"));
    }

    function test_status_refusedWhileHalted_thenOk() public {
        _finalize(ITape.Kind.Halt, uint64(vm.getBlockTimestamp()), 1, 1);
        (CorporateActionHook.TradeStatus st, bytes32 r,) = _status();
        assertEq(uint8(st), uint8(CorporateActionHook.TradeStatus.Refused));
        assertEq(r, bytes32("halted"));
        _finalize(ITape.Kind.Halt, uint64(vm.getBlockTimestamp()), 0, 2);
        (st,,) = _status();
        assertEq(uint8(st), uint8(CorporateActionHook.TradeStatus.Ok));
    }

    function test_status_refusedAwaitingAck_untilAcknowledged() public {
        uint64 eff = uint64(vm.getBlockTimestamp() + 3 days);
        _finalize(ITape.Kind.Split, eff, 40_000, 1);
        (CorporateActionHook.TradeStatus st,,) = _status();
        assertEq(uint8(st), uint8(CorporateActionHook.TradeStatus.Ok), "not yet effective");
        vm.warp(eff);
        bytes32 r; uint64 e;
        (st, r, e) = _status();
        assertEq(uint8(st), uint8(CorporateActionHook.TradeStatus.Refused));
        assertEq(r, bytes32("awaiting-ack"));
        assertEq(e, eff);
        vm.prank(operator);
        hook.acknowledge(poolKey);
        (st,,) = _status();
        assertEq(uint8(st), uint8(CorporateActionHook.TradeStatus.Ok));
    }

    function test_status_unknownWithoutAttester() public {
        (PoolKey memory k,) = initPool(currency0, currency1, IHooks(address(hook)), 500, SQRT_PRICE_1_1);
        hook.bind(k, bytes32("NOATT"));
        (CorporateActionHook.TradeStatus st, bytes32 r,) = hook.tradeStatus(k);
        assertEq(uint8(st), uint8(CorporateActionHook.TradeStatus.Unknown));
        assertEq(r, bytes32("no-attester"));
    }

    function test_status_unboundIsOk() public {
        (PoolKey memory k,) = initPool(currency0, currency1, IHooks(address(hook)), 500, SQRT_PRICE_1_1);
        (CorporateActionHook.TradeStatus st, bytes32 r,) = hook.tradeStatus(k);
        assertEq(uint8(st), uint8(CorporateActionHook.TradeStatus.Ok));
        assertEq(r, bytes32("unbound"));
    }

    function test_statusMatchesSwapOutcome() public {
        _finalize(ITape.Kind.Halt, uint64(vm.getBlockTimestamp()), 1, 1);
        (CorporateActionHook.TradeStatus st,,) = _status();
        assertEq(uint8(st), uint8(CorporateActionHook.TradeStatus.Refused));
        _expectHookRevert(abi.encodeWithSelector(CorporateActionHook.Halted.selector, ALFA));
        _swap();
    }
}
