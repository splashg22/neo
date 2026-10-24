// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {HookMiner} from "v4-periphery/src/utils/HookMiner.sol";
import {Tape} from "../src/Tape.sol";
import {ITape} from "../src/interfaces/ITape.sol";
import {CorporateActionHook} from "../src/CorporateActionHook.sol";

/// @notice Deploys the Tape and CorporateActionHook against the chain's Uniswap v4 PoolManager.
///
///   forge script script/Deploy.s.sol --rpc-url $RPC_URL --broadcast
///
/// env: PRIVATE_KEY, REVIEWER (defaults to deployer), POOL_MANAGER (defaults to the shared
///      Robinhood Chain address, same on mainnet 4663 and testnet 46630), DISPUTE_WINDOW (s),
///      POST_BOND (wei), CHALLENGE_BOND (wei), ATTESTER + SYMBOL (optional first attester).
/// Writes app/deployments.<chainid>.json for the console and the MCP server.
contract Deploy is Script {
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    address constant ROBINHOOD_POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;

    uint256 pk;
    address deployer;
    address reviewer;
    IPoolManager manager;
    uint64 window;
    uint256 postBond;
    uint256 challengeBond;
    address attester;
    string symbol;
    Tape tape;
    CorporateActionHook hook;

    function run() external {
        _env();
        require(address(manager).code.length > 0, "no PoolManager at POOL_MANAGER");
        vm.startBroadcast(pk);
        _deploy();
        vm.stopBroadcast();
        _write();
    }

    function _env() internal {
        pk = vm.envUint("PRIVATE_KEY");
        deployer = vm.addr(pk);
        manager = IPoolManager(vm.envOr("POOL_MANAGER", ROBINHOOD_POOL_MANAGER));
        reviewer = vm.envOr("REVIEWER", deployer);
        window = uint64(vm.envOr("DISPUTE_WINDOW", uint256(1 days)));
        postBond = vm.envOr("POST_BOND", uint256(0.001 ether));
        challengeBond = vm.envOr("CHALLENGE_BOND", uint256(0.002 ether));
        attester = vm.envOr("ATTESTER", address(0));
        symbol = vm.envOr("SYMBOL", string(""));
    }

    function _deploy() internal {
        tape = new Tape(reviewer, window, postBond, challengeBond);
        if (attester != address(0) && bytes(symbol).length > 0) {
            require(reviewer == deployer, "attester can only be set when deployer is reviewer");
            tape.setAttester(bytes32(bytes(symbol)), attester);
        }
        uint160 flags = uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG);
        bytes memory ctorArgs = abi.encode(manager, ITape(address(tape)));
        (address expected, bytes32 salt) =
            HookMiner.find(CREATE2_DEPLOYER, flags, type(CorporateActionHook).creationCode, ctorArgs);
        hook = new CorporateActionHook{salt: salt}(manager, ITape(address(tape)));
        require(address(hook) == expected, "hook address mismatch");
    }

    function _write() internal {
        string memory j = "d";
        vm.serializeUint(j, "chainId", block.chainid);
        vm.serializeAddress(j, "poolManager", address(manager));
        vm.serializeAddress(j, "tape", address(tape));
        vm.serializeAddress(j, "hook", address(hook));
        vm.serializeAddress(j, "reviewer", reviewer);
        vm.serializeAddress(j, "deployer", deployer);
        vm.serializeUint(j, "disputeWindow", window);
        vm.serializeUint(j, "postBond", postBond);
        vm.serializeUint(j, "challengeBond", challengeBond);
        vm.serializeUint(j, "block", block.number);
        string memory out = vm.serializeString(j, "symbol", symbol);
        vm.writeJson(out, string.concat("app/deployments.", vm.toString(block.chainid), ".json"));
        console.log("chain", block.chainid);
        console.log("Tape", address(tape));
        console.log("CorporateActionHook", address(hook));
    }
}
