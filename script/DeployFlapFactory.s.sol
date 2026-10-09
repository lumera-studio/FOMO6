// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;
import {Script} from "forge-std/Script.sol";
import {FOMO6FlapFactory} from "../src/FOMO6FlapFactory.sol";

contract DeployFlapFactory is Script {
    function run() external returns (FOMO6FlapFactory f) {
        require(block.chainid == 97, "BSC Testnet only");
        address recipient = vm.envAddress("POST_SETTLEMENT_RECIPIENT");
        vm.startBroadcast();
        f = new FOMO6FlapFactory(recipient);
        vm.stopBroadcast();
    }
}
