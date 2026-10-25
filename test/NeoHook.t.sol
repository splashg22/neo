// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {Deployers} from "v4-core/test/utils/Deployers.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";
import {HookMiner} from "v4-periphery/src/utils/HookMiner.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {Tape} from "../src/Tape.sol";
import {ITape} from "../src/interfaces/ITape.sol";
import {IAllowlist} from "../src/interfaces/IAllowlist.sol";
import {IReferencePrice} from "../src/interfaces/IReferencePrice.sol";
import {MockAllowlist} from "../src/test/MockAllowlist.sol";
import {MockReferencePrice} from "../src/test/MockReferencePrice.sol";
import {NeoHook} from "../src/NeoHook.sol";
import {CorporateActionHook} from "../src/CorporateActionHook.sol";
import {TradeStatus, Halted, NotOperator, AlreadyBound} from "../src/modules/ModuleBase.sol";
import {AwaitingAcknowledgement} from "../src/modules/HaltModule.sol";
import {NoReference, OutsideBand} from "../src/modules/LuldModule.sol";
import {NotEligible} from "../src/modules/GateModule.sol";
import {NotDynamicFee, FeeCharged, VolFeeConfig} from "../src/modules/VolFeeModule.sol";
import {BadQuote, DividendDistributed} from "../src/modules/DividendModule.sol";

contract NeoHookTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;

    Tape tape;
    MockReferencePrice oracle;
    MockAllowlist allowlist;
    NeoHook hook;

    /// @dev dynamic-fee pool: can run every module
    PoolKey dyn;
    PoolId dynId;
    /// @dev static-fee pool: everything but volFee
    PoolKey stat;
    PoolId statId;

    address reviewer = makeAddr("reviewer");
    uint256 attesterKey = 0xA11CE;
    address poster = makeAddr("poster");
    address operator = makeAddr("operator");
    address alice = makeAddr("alice"); // allowed
    address mallory = makeAddr("mallory"); // not allowed
    bytes32 constant ALFA = bytes32("ALFA");
    uint64 constant WINDOW = 1 days;
    uint24 constant BASE = 500;
    uint256 constant ESCROW = 5e17;
    uint160 constant FLAGS = uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG);

    Currency quote;

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();
        quote = currency1;

        tape = new Tape(reviewer, WINDOW, 0, 0);
        vm.prank(reviewer);
        tape.setAttester(ALFA, vm.addr(attesterKey));
        oracle = new MockReferencePrice();
        allowlist = new MockAllowlist();
        allowlist.set(alice, true);

        bytes memory ctorArgs = abi.encode(manager, tape);
        (address hookAddr, bytes32 salt) = HookMiner.find(address(this), FLAGS, type(NeoHook).creationCode, ctorArgs);
        hook = new NeoHook{salt: salt}(manager, tape);
        assertEq(address(hook), hookAddr, "mined address must match");

        (dyn, dynId) =
            initPool(currency0, currency1, IHooks(address(hook)), LPFeeLibrary.DYNAMIC_FEE_FLAG, SQRT_PRICE_1_1);
        modifyLiquidityRouter.modifyLiquidity(dyn, LIQUIDITY_PARAMS, ZERO_BYTES);
        (stat, statId) = initPool(currency0, currency1, IHooks(address(hook)), 3000, SQRT_PRICE_1_1);
        modifyLiquidityRouter.modifyLiquidity(stat, LIQUIDITY_PARAMS, ZERO_BYTES);

        MockERC20(Currency.unwrap(quote)).approve(address(hook), type(uint256).max);

        vm.warp(1_000_000);
        _quote(SQRT_PRICE_1_1);
    }

    // ------------------------------------------------------------------ helpers

    function _m(bool halt, bool luld, bool gate, bool volFee, bool dividend)
        internal
        pure
        returns (NeoHook.Modules memory)
    {
        return NeoHook.Modules({halt: halt, luld: luld, gate: gate, volFee: volFee, dividend: dividend});
    }

    function _all() internal pure returns (NeoHook.Modules memory) {
        return _m(true, true, true, true, true);
    }

    function _bind(PoolKey memory k, NeoHook.Modules memory m) internal {
        vm.prank(operator);
        hook.bind(k, ALFA, quote, m);
    }

    /// @dev bind with every module on and both data sources wired
    function _bindAll(PoolKey memory k) internal {
        vm.startPrank(operator);
        hook.bind(k, ALFA, quote, _all());
        hook.setOracle(k, IReferencePrice(address(oracle)));
        hook.setAllowlist(k, IAllowlist(address(allowlist)));
        vm.stopPrank();
    }

    function _quote(uint160 sqrtPrice) internal {
        oracle.set(ALFA, sqrtPrice, uint64(vm.getBlockTimestamp()));
    }

    function _finalize(ITape.Kind kind, uint64 effective, uint256 value, uint64 nonce) internal {
        ITape.Event memory e = ITape.Event({symbol: ALFA, kind: kind, effective: effective, value: value, nonce: nonce});
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(attesterKey, tape.digestOf(e));
        vm.prank(poster);
        bytes32 id = tape.post(e, abi.encodePacked(r, s, v));
        vm.warp(vm.getBlockTimestamp() + WINDOW);
        tape.finalize(id);
        _quote(SQRT_PRICE_1_1); // finalize moved the clock: keep the reference fresh
    }

    function _swapAs(PoolKey memory k, address trader) internal {
        swap(k, true, -1e15, abi.encodePacked(trader));
    }

    function _expectHookRevert(bytes4 hookSelector, bytes memory inner) internal {
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                hookSelector,
                inner,
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
    }

    function _expectSwapRevert(bytes memory inner) internal {
        _expectHookRevert(IHooks.beforeSwap.selector, inner);
    }

    function _status(PoolKey memory k) internal view returns (TradeStatus st, bytes32 reason, uint64 eff) {
        return hook.tradeStatus(k);
    }

    function _assertStatus(PoolKey memory k, TradeStatus want, bytes32 reason) internal view {
        (TradeStatus st, bytes32 r,) = _status(k);
        assertEq(uint8(st), uint8(want), "status");
        assertEq(r, reason, "reason");
    }

    // ------------------------------------------------------------------ deployment / binding

    function test_permissionsAreInAddress() public view {
        uint160 mask = uint160(address(hook)) & Hooks.ALL_HOOK_MASK;
        assertEq(mask, FLAGS);
    }

    function test_labelIsReadable() public view {
        assertGt(bytes(hook.label()).length, 40);
    }

    function test_bind_firstCallerIsOperator_andOnce() public {
        _bind(dyn, _all());
        assertEq(hook.operatorOf(dynId), operator);
        assertEq(hook.symbolOf(dynId), ALFA);
        assertEq(Currency.unwrap(hook.quoteOf(dynId)), Currency.unwrap(quote));
        (bool halt, bool luld, bool gate, bool volFee, bool dividend) = hook.modulesOf(dynId);
        assertTrue(halt && luld && gate && volFee && dividend);

        vm.expectRevert(AlreadyBound.selector);
        hook.bind(dyn, ALFA, quote, _all());
    }

    function test_bind_volFeeNeedsDynamicFeePool() public {
        vm.expectRevert(NotDynamicFee.selector);
        hook.bind(stat, ALFA, quote, _m(false, false, false, true, false));

        _bind(stat, _m(true, false, false, false, false));
        vm.prank(operator);
        vm.expectRevert(NotDynamicFee.selector);
        hook.setModules(stat, _m(true, false, false, true, false));
    }

    function test_bind_rejectsForeignQuote() public {
        vm.expectRevert(BadQuote.selector);
        hook.bind(dyn, ALFA, Currency.wrap(makeAddr("other")), _all());
    }

    function test_setModules_operatorOnly() public {
        _bind(dyn, _m(true, false, false, false, false));
        vm.expectRevert(NotOperator.selector);
        hook.setModules(dyn, _all());

        vm.prank(operator);
        hook.setModules(dyn, _all());
        (,, bool gate,,) = hook.modulesOf(dynId);
        assertTrue(gate);
    }

    function test_moduleSetters_operatorOnly() public {
        _bind(dyn, _all());
        vm.expectRevert(NotOperator.selector);
        hook.setOracle(dyn, IReferencePrice(address(oracle)));
        vm.expectRevert(NotOperator.selector);
        hook.setBand(dyn, 500);
        vm.expectRevert(NotOperator.selector);
        hook.setMaxAge(dyn, 1 hours);
        vm.expectRevert(NotOperator.selector);
        hook.setAllowlist(dyn, IAllowlist(address(allowlist)));
        vm.expectRevert(NotOperator.selector);
        hook.setGates(dyn, false, false);
        vm.expectRevert(NotOperator.selector);
        hook.acknowledge(dyn);
    }

    function test_unboundPoolIsInert() public {
        _finalize(ITape.Kind.Halt, uint64(vm.getBlockTimestamp()), 1, 1);
        _swapAs(stat, mallory); // halted symbol, no allowlist, no oracle: nothing applies
        assertEq(hook.currentFee(stat), 0);
        _assertStatus(stat, TradeStatus.Ok, "unbound");
    }

    // ------------------------------------------------------------------ halt alone

    function test_haltAlone_blocksSwapAndAddLiquidity_untilLifted() public {
        _bind(stat, _m(true, false, false, false, false));
        _swapAs(stat, mallory); // no gate: anyone trades

        _finalize(ITape.Kind.Halt, uint64(vm.getBlockTimestamp()), 1, 1);
        _expectSwapRevert(abi.encodeWithSelector(Halted.selector, ALFA));
        _swapAs(stat, alice);
        _expectHookRevert(IHooks.beforeAddLiquidity.selector, abi.encodeWithSelector(Halted.selector, ALFA));
        modifyLiquidityRouter.modifyLiquidity(stat, LIQUIDITY_PARAMS, ZERO_BYTES);
        // LPs can always leave
        modifyLiquidityRouter.modifyLiquidity(stat, REMOVE_LIQUIDITY_PARAMS, ZERO_BYTES);

        _finalize(ITape.Kind.Halt, uint64(vm.getBlockTimestamp()), 0, 2);
        _swapAs(stat, alice);
    }

    function test_haltAlone_splitBlocksUntilAcknowledged() public {
        _bind(stat, _m(true, false, false, false, false));
        uint64 eff = uint64(vm.getBlockTimestamp() + 3 days);
        _finalize(ITape.Kind.Split, eff, 40_000, 1);
        _swapAs(stat, alice); // not yet effective

        vm.warp(eff);
        _expectSwapRevert(abi.encodeWithSelector(AwaitingAcknowledgement.selector, ALFA, ITape.Kind.Split, eff));
        _swapAs(stat, alice);

        vm.prank(operator);
        hook.acknowledge(stat);
        _swapAs(stat, alice);
    }

    // ------------------------------------------------------------------ luld alone

    function test_luldAlone_inBandPasses_outsideAndStaleRevert() public {
        _bind(stat, _m(false, true, false, false, false));
        vm.prank(operator);
        hook.setOracle(stat, IReferencePrice(address(oracle)));
        _swapAs(stat, mallory);

        // reference is 2x the pool: ~5000 bps (the first swap nudged the pool), outside the 1000 bps band
        _quote(SQRT_PRICE_2_1);
        (, uint256 bps) = hook.priceBps(stat);
        assertApproxEqAbs(bps, 5000, 50);
        _expectSwapRevert(abi.encodeWithSelector(OutsideBand.selector, ALFA, bps, 1000));
        _swapAs(stat, mallory);

        vm.prank(operator);
        hook.setBand(stat, 6000);
        _swapAs(stat, mallory);

        oracle.set(ALFA, SQRT_PRICE_1_1, uint64(vm.getBlockTimestamp() - 16 minutes));
        _expectSwapRevert(abi.encodeWithSelector(NoReference.selector, ALFA));
        _swapAs(stat, mallory);

        vm.prank(operator);
        hook.setMaxAge(stat, 1 hours);
        _swapAs(stat, mallory);
    }

    // ------------------------------------------------------------------ gate alone

    function test_gateAlone_allowedPasses_disallowedReverts_removeNever() public {
        _bind(stat, _m(false, false, true, false, false));
        _expectSwapRevert(abi.encodeWithSelector(NotEligible.selector, alice));
        _swapAs(stat, alice); // no allowlist yet: nobody

        vm.prank(operator);
        hook.setAllowlist(stat, IAllowlist(address(allowlist)));
        _swapAs(stat, alice);
        _expectSwapRevert(abi.encodeWithSelector(NotEligible.selector, mallory));
        _swapAs(stat, mallory);

        // empty hookData falls back to tx.origin
        vm.prank(address(this), mallory);
        _expectSwapRevert(abi.encodeWithSelector(NotEligible.selector, mallory));
        swap(stat, true, -1e15, ZERO_BYTES);

        _expectHookRevert(IHooks.beforeAddLiquidity.selector, abi.encodeWithSelector(NotEligible.selector, mallory));
        modifyLiquidityRouter.modifyLiquidity(stat, LIQUIDITY_PARAMS, abi.encodePacked(mallory));
        modifyLiquidityRouter.modifyLiquidity(stat, LIQUIDITY_PARAMS, abi.encodePacked(alice));
        modifyLiquidityRouter.modifyLiquidity(stat, REMOVE_LIQUIDITY_PARAMS, abi.encodePacked(mallory));

        assertTrue(hook.isEligible(stat, alice));
        assertFalse(hook.isEligible(stat, mallory));
        vm.prank(operator);
        hook.setGates(stat, false, true);
        _swapAs(stat, mallory);
    }

    // ------------------------------------------------------------------ volFee alone

    function test_volFeeAlone_chargesBaseThenRises() public {
        _bind(dyn, _m(false, false, false, true, false));
        assertEq(hook.currentFee(dyn), BASE);

        vm.expectEmit(true, false, false, true, address(hook));
        emit FeeCharged(dynId, BASE);
        _swapAs(dyn, mallory);

        assertGt(hook.ewmaOf(dynId), 0);
        assertGt(hook.currentFee(dyn), BASE);

        // a configured cap holds
        uint24 cap = 2000;
        vm.prank(operator);
        hook.setConfig(dyn, _cfg(1000, cap, 50, 2));
        for (uint256 i = 0; i < 6; i++) {
            swap(dyn, i % 2 == 0, -1e16, ZERO_BYTES);
        }
        assertEq(hook.currentFee(dyn), cap);
    }

    function test_volFeeAlone_dividendEventBumpsFee() public {
        _bind(dyn, _m(false, false, false, true, false));
        uint64 eff = uint64(vm.getBlockTimestamp() + 3 days);
        _finalize(ITape.Kind.Dividend, eff, 24, 1);
        assertFalse(hook.inEventWindow(dyn));
        vm.warp(eff);
        assertTrue(hook.inEventWindow(dyn));
        assertEq(hook.currentFee(dyn), BASE + 20 * 100);
    }

    // ------------------------------------------------------------------ dividend alone

    function test_dividendAlone_flushesOnceAtPayDate() public {
        _bind(stat, _m(false, false, false, false, true));
        hook.deposit(stat, ESCROW);
        assertEq(hook.escrowOf(statId), ESCROW);

        uint64 eff = uint64(vm.getBlockTimestamp() + 3 days);
        _finalize(ITape.Kind.Dividend, eff, 125, 1);
        (bool ready, bytes32 reason,,) = hook.pendingDividend(stat);
        assertFalse(ready);
        assertEq(reason, bytes32("not-yet"));
        _swapAs(stat, mallory);
        assertEq(quote.balanceOf(address(hook)), ESCROW, "not before pay date");

        vm.warp(eff);
        vm.expectEmit(true, false, false, true, address(hook));
        emit DividendDistributed(statId, eff, ESCROW);
        _swapAs(stat, mallory);
        assertEq(quote.balanceOf(address(hook)), 0, "hook paid the manager");
        assertEq(hook.escrowOf(statId), 0);

        hook.deposit(stat, ESCROW);
        _swapAs(stat, mallory);
        assertEq(hook.escrowOf(statId), ESCROW, "same dividend never flushed twice");
    }

    // ------------------------------------------------------------------ all five together

    function test_fullStack_onOneDynamicPool() public {
        _bindAll(dyn);

        // 1. halted: refused before anything else is looked at
        _finalize(ITape.Kind.Halt, uint64(vm.getBlockTimestamp()), 1, 1);
        _expectSwapRevert(abi.encodeWithSelector(Halted.selector, ALFA));
        _swapAs(dyn, alice);

        // 2. halt lifted, but the pool sits outside the band
        _finalize(ITape.Kind.Halt, uint64(vm.getBlockTimestamp()), 0, 2);
        _quote(SQRT_PRICE_2_1);
        (, uint256 bps) = hook.priceBps(dyn);
        _expectSwapRevert(abi.encodeWithSelector(OutsideBand.selector, ALFA, bps, 1000));
        _swapAs(dyn, alice);

        // 3. oracle fixed; a trader who is not on the list is refused
        _quote(SQRT_PRICE_1_1);
        _expectSwapRevert(abi.encodeWithSelector(NotEligible.selector, mallory));
        _swapAs(dyn, mallory);

        // 4. an allowed trader swaps and pays the volatility fee
        _assertStatus(dyn, TradeStatus.Ok, "ok");
        vm.expectEmit(true, false, false, true, address(hook));
        emit FeeCharged(dynId, BASE);
        _swapAs(dyn, alice);
        assertGt(hook.ewmaOf(dynId), 0);

        // 5. a deposited dividend is flushed on the first swap at the pay date
        hook.deposit(dyn, ESCROW);
        uint64 eff = uint64(vm.getBlockTimestamp() + 3 days);
        _finalize(ITape.Kind.Dividend, eff, 125, 3);
        vm.warp(eff);
        _quote(SQRT_PRICE_1_1);
        (bool ready,,,) = hook.pendingDividend(dyn);
        assertTrue(ready);
        vm.expectEmit(true, false, false, true, address(hook));
        emit DividendDistributed(dynId, eff, ESCROW);
        _swapAs(dyn, alice);
        assertEq(quote.balanceOf(address(hook)), 0);
        assertEq(hook.escrowOf(dynId), 0);
    }

    function test_fullStack_addLiquidityHaltThenGate_removeNever() public {
        _bindAll(dyn);
        _expectHookRevert(IHooks.beforeAddLiquidity.selector, abi.encodeWithSelector(NotEligible.selector, mallory));
        modifyLiquidityRouter.modifyLiquidity(dyn, LIQUIDITY_PARAMS, abi.encodePacked(mallory));
        modifyLiquidityRouter.modifyLiquidity(dyn, LIQUIDITY_PARAMS, abi.encodePacked(alice));

        _finalize(ITape.Kind.Halt, uint64(vm.getBlockTimestamp()), 1, 1);
        _expectHookRevert(IHooks.beforeAddLiquidity.selector, abi.encodeWithSelector(Halted.selector, ALFA));
        modifyLiquidityRouter.modifyLiquidity(dyn, LIQUIDITY_PARAMS, abi.encodePacked(alice));
        modifyLiquidityRouter.modifyLiquidity(dyn, REMOVE_LIQUIDITY_PARAMS, abi.encodePacked(mallory));
    }

    function test_disablingModuleStopsItsCheck() public {
        _bindAll(dyn);
        _expectSwapRevert(abi.encodeWithSelector(NotEligible.selector, mallory));
        _swapAs(dyn, mallory);

        vm.prank(operator);
        hook.setModules(dyn, _m(true, true, false, true, true));
        _swapAs(dyn, mallory);

        // volFee off: no override, no FeeCharged, currentFee reads 0
        vm.prank(operator);
        hook.setModules(dyn, _m(true, true, false, false, true));
        assertEq(hook.currentFee(dyn), 0);
        vm.recordLogs();
        _swapAs(dyn, mallory);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            assertTrue(logs[i].topics[0] != FeeCharged.selector, "no FeeCharged while volFee is off");
        }

        // halt off: a halted symbol trades
        _finalize(ITape.Kind.Halt, uint64(vm.getBlockTimestamp()), 1, 1);
        _expectSwapRevert(abi.encodeWithSelector(Halted.selector, ALFA));
        _swapAs(dyn, mallory);
        vm.prank(operator);
        hook.setModules(dyn, _m(false, true, false, false, true));
        _swapAs(dyn, mallory);

        // luld off: a stale reference no longer matters
        oracle.set(ALFA, 0, 0);
        _expectSwapRevert(abi.encodeWithSelector(NoReference.selector, ALFA));
        _swapAs(dyn, mallory);
        vm.prank(operator);
        hook.setModules(dyn, _m(false, false, false, false, true));
        _swapAs(dyn, mallory);
    }

    // ------------------------------------------------------------------ tradeStatus

    function test_status_combinesModules() public {
        _bind(dyn, _all());
        _assertStatus(dyn, TradeStatus.Unknown, "no-reference"); // halt ok, luld has no oracle

        vm.prank(operator);
        hook.setOracle(dyn, IReferencePrice(address(oracle)));
        _assertStatus(dyn, TradeStatus.Refused, "no-allowlist"); // gated with no list: nobody

        vm.prank(operator);
        hook.setAllowlist(dyn, IAllowlist(address(allowlist)));
        _assertStatus(dyn, TradeStatus.Ok, "ok");
        (TradeStatus st, bytes32 r,) = hook.tradeStatusFor(dyn, mallory);
        assertEq(uint8(st), uint8(TradeStatus.Refused));
        assertEq(r, bytes32("not-eligible"));
        (st, r,) = hook.tradeStatusFor(dyn, alice);
        assertEq(uint8(st), uint8(TradeStatus.Ok));

        _quote(SQRT_PRICE_2_1);
        _assertStatus(dyn, TradeStatus.Refused, "outside-band");
        _quote(SQRT_PRICE_1_1);

        uint64 eff = uint64(vm.getBlockTimestamp() + 3 days);
        _finalize(ITape.Kind.Split, eff, 40_000, 1);
        _assertStatus(dyn, TradeStatus.Ok, "ok");
        vm.warp(eff);
        _quote(SQRT_PRICE_1_1);
        (st, r, eff) = _status(dyn);
        assertEq(uint8(st), uint8(TradeStatus.Refused));
        assertEq(r, bytes32("awaiting-ack"));
        assertEq(eff, uint64(vm.getBlockTimestamp()));
        vm.prank(operator);
        hook.acknowledge(dyn);
        _assertStatus(dyn, TradeStatus.Ok, "ok");

        _finalize(ITape.Kind.Halt, uint64(vm.getBlockTimestamp()), 1, 2);
        _assertStatus(dyn, TradeStatus.Refused, "halted");
        _expectSwapRevert(abi.encodeWithSelector(Halted.selector, ALFA));
        _swapAs(dyn, alice);
    }

    function test_status_unknownWithoutAttester_haltOnly() public {
        vm.prank(operator);
        hook.bind(stat, bytes32("NOATT"), quote, _m(true, false, false, false, false));
        _assertStatus(stat, TradeStatus.Unknown, "no-attester");
    }

    function test_status_disabledModulesAreNotConsulted() public {
        _bind(stat, _m(false, false, false, false, true)); // dividend only: nothing can refuse
        _finalize(ITape.Kind.Halt, uint64(vm.getBlockTimestamp()), 1, 1);
        _assertStatus(stat, TradeStatus.Ok, "ok");
    }

    // ------------------------------------------------------------------ gas

    /// @dev Warm second swap through NeoHook with all five modules on, versus the same swap through
    ///      the single CorporateActionHook. Printed with -vv.
    function test_gas_fullStackVsSingleHook() public {
        _bindAll(dyn);
        _swapAs(dyn, alice); // warm storage
        uint256 g0 = gasleft();
        _swapAs(dyn, alice);
        uint256 neoGas = g0 - gasleft();

        (address caAddr, bytes32 salt) = HookMiner.find(
            address(this),
            uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG),
            type(CorporateActionHook).creationCode,
            abi.encode(manager, tape)
        );
        CorporateActionHook ca = new CorporateActionHook{salt: salt}(manager, tape);
        assertEq(address(ca), caAddr);
        (PoolKey memory k,) = initPool(currency0, currency1, IHooks(address(ca)), 3000, SQRT_PRICE_1_1);
        modifyLiquidityRouter.modifyLiquidity(k, LIQUIDITY_PARAMS, ZERO_BYTES);
        vm.prank(operator);
        ca.bind(k, ALFA);
        swap(k, true, -1e15, ZERO_BYTES);
        g0 = gasleft();
        swap(k, true, -1e15, ZERO_BYTES);
        uint256 caGas = g0 - gasleft();

        // NeoHook halt-only on a static pool: the like-for-like comparison
        _bind(stat, _m(true, false, false, false, false));
        swap(stat, true, -1e15, ZERO_BYTES);
        g0 = gasleft();
        swap(stat, true, -1e15, ZERO_BYTES);
        uint256 neoHaltGas = g0 - gasleft();

        console.log("swap gas, NeoHook all five modules:", neoGas);
        console.log("swap gas, NeoHook halt only:       ", neoHaltGas);
        console.log("swap gas, CorporateActionHook:     ", caGas);
        assertGt(neoGas, caGas);
    }

    // ------------------------------------------------------------------ util

    function _cfg(uint24 base, uint24 max, uint24 perTick, uint32 window) internal pure returns (VolFeeConfig memory) {
        return VolFeeConfig({
            symbol: bytes32(0),
            operator: address(0),
            baseFee: base,
            maxFee: max,
            feePerTick: perTick,
            window: window,
            eventBumpBps: 20,
            eventBumpSeconds: 1 hours
        });
    }
}
