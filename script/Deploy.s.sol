// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {HookMiner} from "v4-periphery/src/utils/HookMiner.sol";
import {Tape} from "../src/Tape.sol";
import {ITape} from "../src/interfaces/ITape.sol";
import {CorporateActionHook} from "../src/CorporateActionHook.sol";

/// @notice forge script script/Deploy.s.sol --rpc-url $RPC_URL --broadcast
/// env: PRIVATE_KEY, POOL_MANAGER, REVIEWER, DISPUTE_WINDOW (s), POST_BOND (wei), CHALLENGE_BOND (wei)
contract Deploy is Script {
    // CREATE2 deployer proxy present on most EVM chains (Robinhood Chain included via Arbitrum Orbit tooling)
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        IPoolManager manager = IPoolManager(vm.envAddress("POOL_MANAGER"));
        address reviewer = vm.envAddress("REVIEWER");
        uint64 window = uint64(vm.envOr("DISPUTE_WINDOW", uint256(1 days)));
        uint256 postBond = vm.envOr("POST_BOND", uint256(0.05 ether));
        uint256 challengeBond = vm.envOr("CHALLENGE_BOND", uint256(0.1 ether));

        vm.startBroadcast(pk);
        Tape tape = new Tape(reviewer, window, postBond, challengeBond);
        console.log("Tape", address(tape));

        uint160 flags = uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG);
        bytes memory ctorArgs = abi.encode(manager, ITape(address(tape)));
        (address expected, bytes32 salt) =
            HookMiner.find(CREATE2_DEPLOYER, flags, type(CorporateActionHook).creationCode, ctorArgs);
        CorporateActionHook hook = new CorporateActionHook{salt: salt}(manager, ITape(address(tape)));
        require(address(hook) == expected, "hook address mismatch");
        console.log("CorporateActionHook", address(hook));
        vm.stopBroadcast();
    }
}
