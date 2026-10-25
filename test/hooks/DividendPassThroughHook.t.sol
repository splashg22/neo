// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "v4-core/test/utils/Deployers.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";
import {HookMiner} from "v4-periphery/src/utils/HookMiner.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {Tape} from "../../src/Tape.sol";
import {ITape} from "../../src/interfaces/ITape.sol";
import {DividendPassThroughHook} from "../../src/hooks/DividendPassThroughHook.sol";

contract DividendPassThroughHookTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    Tape tape;
    DividendPassThroughHook hook;
    PoolKey poolKey;
    PoolId poolId;

    address reviewer = makeAddr("reviewer");
    uint256 attesterKey = 0xA11CE;
    address poster = makeAddr("poster");
    address operator = makeAddr("operator");
    bytes32 constant ALFA = bytes32("ALFA");
    uint64 constant WINDOW = 1 days;
    uint256 constant ESCROW = 5e17;

    /// @dev currency1 plays the quote (cash) side; currency0 is the stock.
    Currency quote;

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();
        quote = currency1;

        tape = new Tape(reviewer, WINDOW, 0, 0);
        vm.prank(reviewer);
        tape.setAttester(ALFA, vm.addr(attesterKey));

        uint160 flags = uint160(Hooks.BEFORE_SWAP_FLAG);
        bytes memory ctorArgs = abi.encode(manager, tape);
        (address hookAddr, bytes32 salt) =
            HookMiner.find(address(this), flags, type(DividendPassThroughHook).creationCode, ctorArgs);
        hook = new DividendPassThroughHook{salt: salt}(manager, tape);
        assertEq(address(hook), hookAddr, "mined address must match");

        (poolKey, poolId) = initPool(currency0, currency1, IHooks(address(hook)), 3000, SQRT_PRICE_1_1);
        modifyLiquidityRouter.modifyLiquidity(poolKey, LIQUIDITY_PARAMS, ZERO_BYTES);

        vm.prank(operator);
        hook.bind(poolKey, ALFA, quote);

        MockERC20(Currency.unwrap(quote)).approve(address(hook), type(uint256).max);
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

    /// @dev stock in, cash out: swap fees accrue in currency0, so any currency1 fee growth is the dividend
    function _swap() internal {
        swap(poolKey, true, -1e15, ZERO_BYTES);
    }

    function _hookQuoteBalance() internal view returns (uint256) {
        return quote.balanceOf(address(hook));
    }

    function _feeGrowth1() internal view returns (uint256 g1) {
        (, g1) = manager.getFeeGrowthGlobals(poolId);
    }

    /// @dev collect the LP's accrued fees (zero-delta modifyLiquidity) and return how much quote it got
    function _collectQuote() internal returns (uint256) {
        uint256 before = quote.balanceOf(address(this));
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({
                tickLower: LIQUIDITY_PARAMS.tickLower,
                tickUpper: LIQUIDITY_PARAMS.tickUpper,
                liquidityDelta: 0,
                salt: 0
            }),
            ZERO_BYTES
        );
        return quote.balanceOf(address(this)) - before;
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

    function test_bind_rejectsForeignQuote_andRebind() public {
        (PoolKey memory k,) = initPool(currency0, currency1, IHooks(address(hook)), 500, SQRT_PRICE_1_1);
        vm.expectRevert(DividendPassThroughHook.BadQuote.selector);
        hook.bind(k, ALFA, Currency.wrap(makeAddr("other")));

        hook.bind(k, ALFA, currency0);
        vm.expectRevert(DividendPassThroughHook.AlreadyBound.selector);
        hook.bind(k, ALFA, currency0);
    }

    function test_deposit_escrowsQuoteTokens() public {
        vm.expectEmit(true, false, false, true);
        emit DividendPassThroughHook.Deposited(poolId, address(this), ESCROW, ESCROW);
        hook.deposit(poolKey, ESCROW);
        assertEq(hook.escrowOf(poolId), ESCROW);
        assertEq(_hookQuoteBalance(), ESCROW);

        hook.deposit(poolKey, ESCROW);
        assertEq(hook.escrowOf(poolId), 2 * ESCROW);
        assertEq(_hookQuoteBalance(), 2 * ESCROW);
    }

    function test_deposit_reverts() public {
        vm.expectRevert(DividendPassThroughHook.ZeroAmount.selector);
        hook.deposit(poolKey, 0);

        (PoolKey memory unbound,) = initPool(currency0, currency1, IHooks(address(hook)), 500, SQRT_PRICE_1_1);
        vm.expectRevert(DividendPassThroughHook.NotBound.selector);
        hook.deposit(unbound, 1);

        vm.deal(address(this), 1 ether);
        vm.expectRevert(DividendPassThroughHook.BadValue.selector);
        hook.deposit{value: 1}(poolKey, 1);
    }

    function test_noDonateBeforePayDate() public {
        hook.deposit(poolKey, ESCROW);
        _finalize(ITape.Kind.Dividend, uint64(vm.getBlockTimestamp() + 3 days), 125, 1);

        (bool ready, bytes32 reason,,) = hook.pendingDividend(poolKey);
        assertFalse(ready);
        assertEq(reason, bytes32("not-yet"));

        uint256 g1 = _feeGrowth1();
        _swap();
        assertEq(hook.escrowOf(poolId), ESCROW, "escrow untouched");
        assertEq(_hookQuoteBalance(), ESCROW, "tokens still in hook");
        assertEq(_feeGrowth1(), g1, "no quote fee growth");
    }

    function test_noDonateForNonDividendAction() public {
        hook.deposit(poolKey, ESCROW);
        _finalize(ITape.Kind.Split, uint64(vm.getBlockTimestamp()), 40_000, 1);
        _swap();
        assertEq(hook.escrowOf(poolId), ESCROW);
        assertEq(_hookQuoteBalance(), ESCROW);
    }

    function test_firstSwapAfterPayDate_donatesToLPs() public {
        hook.deposit(poolKey, ESCROW);
        uint64 eff = uint64(vm.getBlockTimestamp() + 3 days);
        _finalize(ITape.Kind.Dividend, eff, 125, 1);
        vm.warp(eff);

        (bool ready, bytes32 reason, uint64 pendingEff, uint256 amount) = hook.pendingDividend(poolKey);
        assertTrue(ready);
        assertEq(reason, bytes32("ready"));
        assertEq(pendingEff, eff);
        assertEq(amount, ESCROW);

        uint256 g1Before = _feeGrowth1();
        uint256 managerBefore = quote.balanceOf(address(manager));

        vm.expectEmit(true, false, false, true);
        emit DividendPassThroughHook.DividendDistributed(poolId, eff, ESCROW);
        _swap();

        assertEq(hook.escrowOf(poolId), 0, "escrow cleared");
        assertEq(_hookQuoteBalance(), 0, "hook paid the manager");
        assertGt(_feeGrowth1(), g1Before, "quote fee growth rose");
        // the manager now holds the escrow plus whatever the swap paid out in quote
        assertGe(quote.balanceOf(address(manager)) + 1e15, managerBefore + ESCROW);

        // the sole LP collects its fees: all of the quote side is the dividend
        uint256 got = _collectQuote();
        assertApproxEqAbs(got, ESCROW, 1, "LP received the dividend");

        (ready, reason,,) = hook.pendingDividend(poolKey);
        assertFalse(ready);
        assertEq(reason, bytes32("no-escrow"));
    }

    function test_sameDividendNeverDonatedTwice() public {
        hook.deposit(poolKey, ESCROW);
        uint64 eff = uint64(vm.getBlockTimestamp());
        _finalize(ITape.Kind.Dividend, eff, 125, 1);
        _swap();
        assertEq(_hookQuoteBalance(), 0);

        // a late top-up for the same (effective, value) stays in escrow
        hook.deposit(poolKey, ESCROW);
        (bool ready, bytes32 reason,,) = hook.pendingDividend(poolKey);
        assertFalse(ready);
        assertEq(reason, bytes32("flushed"));
        uint256 g1 = _feeGrowth1();
        _swap();
        _swap();
        assertEq(hook.escrowOf(poolId), ESCROW, "not flushed again");
        assertEq(_hookQuoteBalance(), ESCROW);
        assertEq(_feeGrowth1(), g1);

        // a new dividend (different effective) flushes the waiting escrow
        uint64 eff2 = uint64(vm.getBlockTimestamp() + 30 days);
        _finalize(ITape.Kind.Dividend, eff2, 130, 2);
        vm.warp(eff2);
        vm.expectEmit(true, false, false, true);
        emit DividendPassThroughHook.DividendDistributed(poolId, eff2, ESCROW);
        _swap();
        assertEq(_hookQuoteBalance(), 0);
        assertApproxEqAbs(_collectQuote(), 2 * ESCROW, 2, "LP got both dividends");
    }

    function test_noLiquidityKeepsEscrow() public {
        hook.deposit(poolKey, ESCROW);
        _finalize(ITape.Kind.Dividend, uint64(vm.getBlockTimestamp()), 125, 1);
        modifyLiquidityRouter.modifyLiquidity(poolKey, REMOVE_LIQUIDITY_PARAMS, ZERO_BYTES);

        (bool ready, bytes32 reason,,) = hook.pendingDividend(poolKey);
        assertFalse(ready);
        assertEq(reason, bytes32("no-liquidity"));

        // liquidity comes back; the next swap pays out
        modifyLiquidityRouter.modifyLiquidity(poolKey, LIQUIDITY_PARAMS, ZERO_BYTES);
        _swap();
        assertEq(_hookQuoteBalance(), 0);
        assertApproxEqAbs(_collectQuote(), ESCROW, 1);
    }

    function test_unboundPoolIsInert() public {
        (PoolKey memory k,) = initPool(currency0, currency1, IHooks(address(hook)), 500, SQRT_PRICE_1_1);
        modifyLiquidityRouter.modifyLiquidity(k, LIQUIDITY_PARAMS, ZERO_BYTES);
        _finalize(ITape.Kind.Dividend, uint64(vm.getBlockTimestamp()), 125, 1);
        swap(k, true, -1e15, ZERO_BYTES);
        (bool ready, bytes32 reason,,) = hook.pendingDividend(k);
        assertFalse(ready);
        assertEq(reason, bytes32("unbound"));
    }

    function test_hookRevertsWrapAsHookCallFailed() public {
        // the hook's only external dependency in the swap path is the Tape; a reverting Tape
        // surfaces through the manager as CustomRevert.WrappedError around beforeSwap
        hook.deposit(poolKey, ESCROW);
        vm.mockCallRevert(
            address(tape), abi.encodeWithSelector(ITape.action.selector, ALFA), abi.encodeWithSignature("Boom()")
        );
        _expectHookRevert(abi.encodeWithSignature("Boom()"));
        _swap();
    }
}
