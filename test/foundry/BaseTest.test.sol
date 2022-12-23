// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.17;

import { Test, stdMath, StdStorage, stdStorage } from "forge-std/Test.sol";
import "../../contracts/external/ProxyAdmin.sol";
import "../../contracts/external/TransparentUpgradeableProxy.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { console } from "forge-std/console.sol";

contract BaseTest is Test {
    ProxyAdmin public proxyAdmin;

    address internal constant _GOVERNOR = 0xdC4e6DFe07EFCa50a197DF15D9200883eF4Eb1c8;
    address internal constant _GUARDIAN = 0x0C2553e4B9dFA9f83b1A6D3EAB96c4bAaB42d430;
    address internal constant _KEEPER = address(uint160(uint256(keccak256(abi.encodePacked("_keeper")))));
    address internal constant _ANGLE = 0x31429d1856aD1377A8A0079410B297e1a9e214c2;
    address internal constant _GOVERNOR_POLYGON = 0xdA2D2f638D6fcbE306236583845e5822554c02EA;

    address internal constant _ALICE = address(uint160(uint256(keccak256(abi.encodePacked("_alice")))));
    address internal constant _BOB = address(uint160(uint256(keccak256(abi.encodePacked("_bob")))));
    address internal constant _CHARLIE = address(uint160(uint256(keccak256(abi.encodePacked("_charlie")))));
    address internal constant _DYLAN = address(uint160(uint256(keccak256(abi.encodePacked("_dylan")))));

    uint256 internal _ethereum;
    uint256 internal _polygon;

    uint256 public constant BASE_PARAMS = 10**9;
    uint256 public constant BASE_TOKENS = 10**18;
    uint256 public constant BASE_STAKER = 10**36;

    function setUp() public virtual {
        proxyAdmin = new ProxyAdmin();
        vm.label(_GOVERNOR, "Governor");
        vm.label(_GUARDIAN, "Guardian");
        vm.label(_ALICE, "Alice");
        vm.label(_BOB, "Bob");
        vm.label(_CHARLIE, "Charlie");
        vm.label(_DYLAN, "Dylan");
    }

    function deployUpgradeable(address implementation, bytes memory data) public returns (address) {
        return address(new TransparentUpgradeableProxy(implementation, address(proxyAdmin), data));
    }
}
