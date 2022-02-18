// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.7;

contract MockAaveDataProvider {

address public immutable aToken;
address public immutable debtToken;

    constructor(address _aToken, address _debtToken) {
        aToken = _aToken;
        debtToken = _debtToken;
    }

    function getReserveTokensAddresses(address) external view returns(address _aToken, address _debtToken) {
        _aToken = aToken;
        _debtToken = debtToken;
    }

    function getReserveConfigurationData(address) external pure returns(
        uint256 decimals,
        uint256 ltv,
        uint256 liquidationThreshold,
        uint256 liquidationBonus,
        uint256 reserveFactor,
        bool usageAsCollateralEnabled,
        bool borrowingEnabled,
        bool stableBorrowRateEnabled,
        bool isActive,
        bool isFrozen
    ) {
        decimals = 18;
        ltv = 0.8 ether;
        liquidationThreshold = 1 ether;
        liquidationBonus = 1 ether;
        reserveFactor = 1 ether;
        usageAsCollateralEnabled = true;
        borrowingEnabled = true;
        stableBorrowRateEnabled = false;
        isActive = true;
        isFrozen = false;
    }
}