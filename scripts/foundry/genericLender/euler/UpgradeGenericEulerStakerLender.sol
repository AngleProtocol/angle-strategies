// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.17;

import "forge-std/Script.sol";
import "../../MainnetConstants.s.sol";
import { GenericEulerStaker } from "../../../../contracts/strategies/OptimizerAPR/genericLender/euler/GenericEulerStaker.sol";

contract DeployGenericEulerStakerImplementation is Script, MainnetConstants {
    uint256 internal constant _BASE_TOKEN = 10**18;
    uint256 internal constant _BASE_APR = 10**18;
    uint64 internal constant _BPS = 10**4;

    GenericEulerStaker public lenderEulerImplementation;

    error ZeroAdress();

    function run() external {
        // vm.createSelectFork("mainnet");
        uint256 deployerPrivateKey = vm.deriveKey(vm.envString("MNEMONIC_MAINNET"), 0);
        vm.startBroadcast(deployerPrivateKey);

        lenderEulerImplementation = new GenericEulerStaker();
        console.log(
            "Successfully deployed Euler implementation strategy at the address: ",
            address(lenderEulerImplementation)
        );

        vm.stopBroadcast();
    }
}
