// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.17;

import "../../contracts/external/ProxyAdmin.sol";
import "../../contracts/external/TransparentUpgradeableProxy.sol";

contract MainnetConstants {
    address public constant GOVERNOR = 0xdC4e6DFe07EFCa50a197DF15D9200883eF4Eb1c8;
    address public constant GUARDIAN = 0x0C2553e4B9dFA9f83b1A6D3EAB96c4bAaB42d430;
    address public constant PROXY_ADMIN = 0x1D941EF0D3Bba4ad67DBfBCeE5262F4CEE53A32b;
    address public constant PROXY_ADMIN_GUARDIAN = 0xD9F1A8e00b0EEbeDddd9aFEaB55019D55fcec017;
    address public constant CORE_BORROW = 0x5bc6BEf80DA563EBf6Df6D6913513fa9A7ec89BE;

    address public constant KEEPER_MULTICALL = 0xa0062b7A5e494d569059E2f1A98B5f6C99BFAAfe;
    address public constant KEEPER = 0xcC617C6f9725eACC993ac626C7efC6B96476916E;

    address public constant ANGLE_ROUTER = 0x4579709627CA36BCe92f51ac975746f431890930;
    address public constant ONE_INCH = 0x1111111254EEB25477B68fb85Ed929f73A960582;
    address public constant UNI_V3_ROUTER = 0xE592427A0AEce92De3Edee1F18E0157C05861564;
    address public constant ANGLE_HELPER = 0x1B17ac6B8371D63E030C5981891d5FBb3E4e068E;

    // AGEUR Mainnet treasury
    address public constant AGEUR_TREASURY = 0x8667DBEBf68B0BFa6Db54f550f41Be16c4067d60;
    address public constant AGEUR = 0x1a7e4e63778B4f12a199C062f3eFdD288afCBce8;

    // Collateral addresses
    address public constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    address public constant FRAX = 0x853d955aCEf822Db058eb8505911ED77F175b99e;
    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address public constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    uint256 public constant BASE_TOKENS = 10**18;
    uint64 public constant BASE_PARAMS = 10**9;

    function deployUpgradeable(address implementation, bytes memory data) public returns (address) {
        return address(new TransparentUpgradeableProxy(implementation, PROXY_ADMIN, data));
    }
}
