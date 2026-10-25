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
import {IAllowlist} from "../../src/interfaces/IAllowlist.sol";
import {MockAllowlist} from "../../src/test/MockAllowlist.sol";
import {EligibilityGateHook} from "../../src/hooks/EligibilityGateHook.sol";

contract EligibilityGateHookTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;

    Tape tape;
    MockAllowlist allowlist;
    EligibilityGateHook hook;
    PoolKey poolKey;
    PoolId poolId;

    address reviewer = makeAddr("reviewer");
    address operator = makeAddr("operator");
    address alice = makeAddr("alice"); // allowed
    address mallory = makeAddr("mallory"); // not allowed
    bytes32 constant ALFA = bytes32("ALFA");

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        tape = new Tape(reviewer, 1 days, 0, 0);
        allowlist = new MockAllowlist();
        allowlist.set(alice, true);

        uint160 flags = uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG);
        bytes memory ctorArgs = abi.encode(manager, tape);
        (address hookAddr, bytes32 salt) =
            HookMiner.find(address(this), flags, type(EligibilityGateHook).creationCode, ctorArgs);
        hook = new EligibilityGateHook{salt: salt}(manager, tape);
        assertEq(address(hook), hookAddr, "mined address must match");

        (poolKey, poolId) = initPool(currency0, currency1, IHooks(address(hook)), 3000, SQRT_PRICE_1_1);
        // seed liquidity before the gate is armed
        modifyLiquidityRouter.modifyLiquidity(poolKey, LIQUIDITY_PARAMS, ZERO_BYTES);

        vm.startPrank(operator);
        hook.bind(poolKey, ALFA);
        hook.setAllowlist(poolKey, IAllowlist(address(allowlist)));
        vm.stopPrank();
    }

    // ------------------------------------------------------------------ helpers

    function _swapAs(address trader) internal {
        swap(poolKey, true, -1e15, abi.encodePacked(trader));
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

    function _notEligible(address who) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(EligibilityGateHook.NotEligible.selector, who);
    }

    // ------------------------------------------------------------------ tests

    function test_permissionsAreInAddress() public view {
        uint160 mask = uint160(address(hook)) & Hooks.ALL_HOOK_MASK;
        assertEq(mask, uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG));
    }

    function test_allowedViaHookDataPasses() public {
        _swapAs(alice);
    }

    function test_disallowedViaHookDataReverts() public {
        _expectHookRevert(IHooks.beforeSwap.selector, _notEligible(mallory));
        _swapAs(mallory);
    }

    function test_emptyHookDataUsesTxOrigin() public {
        // msg.sender stays this contract (it holds the tokens); only tx.origin changes
        vm.prank(address(this), alice);
        swap(poolKey, true, -1e15, ZERO_BYTES);

        vm.prank(address(this), mallory);
        _expectHookRevert(IHooks.beforeSwap.selector, _notEligible(mallory));
        swap(poolKey, true, -1e15, ZERO_BYTES);
    }

    function test_hookDataOfOtherLengthUsesTxOrigin() public {
        bytes memory padded = abi.encode(alice); // 32 bytes: not the 20-byte form
        vm.prank(address(this), mallory);
        _expectHookRevert(IHooks.beforeSwap.selector, _notEligible(mallory));
        swap(poolKey, true, -1e15, padded);
    }

    function test_addLiquidityGated_removeNever() public {
        _expectHookRevert(IHooks.beforeAddLiquidity.selector, _notEligible(mallory));
        modifyLiquidityRouter.modifyLiquidity(poolKey, LIQUIDITY_PARAMS, abi.encodePacked(mallory));

        modifyLiquidityRouter.modifyLiquidity(poolKey, LIQUIDITY_PARAMS, abi.encodePacked(alice));

        // LPs can always leave, even when not on the list
        modifyLiquidityRouter.modifyLiquidity(poolKey, REMOVE_LIQUIDITY_PARAMS, abi.encodePacked(mallory));
    }

    function test_operatorCanSwapAllowlist() public {
        MockAllowlist other = new MockAllowlist();
        other.set(mallory, true);

        vm.expectRevert(EligibilityGateHook.NotOperator.selector);
        hook.setAllowlist(poolKey, IAllowlist(address(other)));

        vm.prank(operator);
        hook.setAllowlist(poolKey, IAllowlist(address(other)));

        _swapAs(mallory);
        _expectHookRevert(IHooks.beforeSwap.selector, _notEligible(alice));
        _swapAs(alice);
    }

    function test_gatesCanBeTurnedOff() public {
        vm.expectRevert(EligibilityGateHook.NotOperator.selector);
        hook.setGates(poolKey, false, true);

        vm.prank(operator);
        hook.setGates(poolKey, false, true);
        _swapAs(mallory); // swaps open
        _expectHookRevert(IHooks.beforeAddLiquidity.selector, _notEligible(mallory));
        modifyLiquidityRouter.modifyLiquidity(poolKey, LIQUIDITY_PARAMS, abi.encodePacked(mallory));
    }

    function test_noAllowlistMeansNobody() public {
        vm.prank(operator);
        hook.setAllowlist(poolKey, IAllowlist(address(0)));
        assertFalse(hook.isEligible(poolKey, alice));
        _expectHookRevert(IHooks.beforeSwap.selector, _notEligible(alice));
        _swapAs(alice);
    }

    function test_isEligibleView() public view {
        assertTrue(hook.isEligible(poolKey, alice));
        assertFalse(hook.isEligible(poolKey, mallory));
    }

    function test_unboundPoolIsInert() public {
        (PoolKey memory k,) = initPool(currency0, currency1, IHooks(address(hook)), 500, SQRT_PRICE_1_1);
        modifyLiquidityRouter.modifyLiquidity(k, LIQUIDITY_PARAMS, abi.encodePacked(mallory));
        swap(k, true, -1e15, abi.encodePacked(mallory));
        assertTrue(hook.isEligible(k, mallory));
    }

    function test_bindOnce() public {
        vm.expectRevert(EligibilityGateHook.AlreadyBound.selector);
        hook.bind(poolKey, ALFA);
    }

    function test_labelIsReadable() public view {
        assertGt(bytes(hook.label()).length, 40);
    }
}
