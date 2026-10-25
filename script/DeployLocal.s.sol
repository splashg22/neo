// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {HookMiner} from "v4-periphery/src/utils/HookMiner.sol";

import {Tape} from "../src/Tape.sol";
import {ITape} from "../src/interfaces/ITape.sol";
import {CorporateActionHook} from "../src/CorporateActionHook.sol";
import {NeoHook} from "../src/NeoHook.sol";
import {MockERC20} from "../src/test/MockERC20.sol";

/// @notice Stands up a complete local environment on Anvil:
///         PoolManager, Tape, CorporateActionHook, NeoHook (the composite hook, deployed but not bound
///         to the sample pool), a tokenized-stock mock (ALFA) and a quote mock (USDG), one pool hooked
///         to CorporateActionHook with liquidity, an attester for ALFA, and three posted events.
///         Writes app/deployments.local.json for the console.
///
///         anvil &  then  forge script script/DeployLocal.s.sol --rpc-url http://127.0.0.1:8545 --broadcast
contract DeployLocal is Script {
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    // Anvil default accounts
    uint256 constant DEPLOYER_KEY = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80; // #0
    uint256 constant ATTESTER_KEY = 0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d; // #1
    uint256 constant OPERATOR_KEY = 0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a; // #2
    bytes32 constant ALFA = bytes32("ALFA");

    PoolManager manager;
    PoolModifyLiquidityTest lpRouter;
    PoolSwapTest swapRouter;
    Tape tape;
    CorporateActionHook hook;
    NeoHook neoHook;
    MockERC20 t0;
    MockERC20 t1;
    PoolKey key;

    function run() external {
        vm.startBroadcast(DEPLOYER_KEY);
        _core();
        _hook();
        _neoHook();
        _pool();
        vm.stopBroadcast();

        vm.startBroadcast(OPERATOR_KEY);
        hook.bind(key, ALFA);
        vm.stopBroadcast();

        vm.startBroadcast(DEPLOYER_KEY);
        _post(ITape.Event(ALFA, ITape.Kind.Dividend, uint64(block.timestamp + 7 days), 24, 1));
        _post(ITape.Event(ALFA, ITape.Kind.Split, uint64(block.timestamp + 14 days), 40_000, 2));
        _post(ITape.Event(ALFA, ITape.Kind.Halt, uint64(block.timestamp), 1, 3));
        vm.stopBroadcast();

        _write();
    }

    function _core() internal {
        manager = new PoolManager(vm.addr(DEPLOYER_KEY));
        lpRouter = new PoolModifyLiquidityTest(IPoolManager(address(manager)));
        swapRouter = new PoolSwapTest(IPoolManager(address(manager)));
        tape = new Tape(vm.addr(DEPLOYER_KEY), 45, 0.01 ether, 0.02 ether);
        tape.setAttester(ALFA, vm.addr(ATTESTER_KEY));
    }

    function _hook() internal {
        uint160 flags = uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG);
        bytes memory ctorArgs = abi.encode(IPoolManager(address(manager)), ITape(address(tape)));
        (address expected, bytes32 salt) =
            HookMiner.find(CREATE2_DEPLOYER, flags, type(CorporateActionHook).creationCode, ctorArgs);
        hook = new CorporateActionHook{salt: salt}(IPoolManager(address(manager)), ITape(address(tape)));
        require(address(hook) == expected, "hook address mismatch");
    }

    function _neoHook() internal {
        uint160 flags = uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG);
        bytes memory ctorArgs = abi.encode(IPoolManager(address(manager)), ITape(address(tape)));
        (address expected, bytes32 salt) = HookMiner.find(CREATE2_DEPLOYER, flags, type(NeoHook).creationCode, ctorArgs);
        neoHook = new NeoHook{salt: salt}(IPoolManager(address(manager)), ITape(address(tape)));
        require(address(neoHook) == expected, "neoHook address mismatch");
    }

    function _pool() internal {
        MockERC20 a = new MockERC20("ALFA Stock Token", "ALFA", 18);
        MockERC20 b = new MockERC20("USDG", "USDG", 18);
        (t0, t1) = address(a) < address(b) ? (a, b) : (b, a);
        address me = vm.addr(DEPLOYER_KEY);
        t0.mint(me, 1_000_000 ether);
        t1.mint(me, 1_000_000 ether);
        t0.approve(address(lpRouter), type(uint256).max);
        t1.approve(address(lpRouter), type(uint256).max);
        t0.approve(address(swapRouter), type(uint256).max);
        t1.approve(address(swapRouter), type(uint256).max);
        key = PoolKey({
            currency0: Currency.wrap(address(t0)),
            currency1: Currency.wrap(address(t1)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        manager.initialize(key, 79228162514264337593543950336); // 1:1
        lpRouter.modifyLiquidity(
            key, ModifyLiquidityParams({tickLower: -600, tickUpper: 600, liquidityDelta: 1_000e18, salt: 0}), ""
        );
    }

    function _post(ITape.Event memory e) internal {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ATTESTER_KEY, tape.digestOf(e));
        tape.post{value: 0.01 ether}(e, abi.encodePacked(r, s, v));
    }

    function _write() internal {
        string memory j = "d";
        vm.serializeUint(j, "chainId", block.chainid);
        vm.serializeAddress(j, "poolManager", address(manager));
        vm.serializeAddress(j, "lpRouter", address(lpRouter));
        vm.serializeAddress(j, "swapRouter", address(swapRouter));
        vm.serializeAddress(j, "tape", address(tape));
        vm.serializeAddress(j, "hook", address(hook));
        vm.serializeAddress(j, "neoHook", address(neoHook));
        vm.serializeAddress(j, "token0", address(t0));
        vm.serializeAddress(j, "token1", address(t1));
        vm.serializeAddress(j, "attester", vm.addr(ATTESTER_KEY));
        vm.serializeAddress(j, "operator", vm.addr(OPERATOR_KEY));
        vm.serializeAddress(j, "reviewer", vm.addr(DEPLOYER_KEY));
        string memory out = vm.serializeString(j, "symbol", "ALFA");
        vm.writeJson(out, "app/deployments.local.json");
        console.log("PoolManager", address(manager));
        console.log("Tape", address(tape));
        console.log("CorporateActionHook", address(hook));
        console.log("NeoHook", address(neoHook));
    }
}
