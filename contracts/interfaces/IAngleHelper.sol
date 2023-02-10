// SPDX-License-Identifier: GPL-3.0

pragma solidity ^0.8.12;

struct PerpetualManagerFeeData {
    uint64[] xHAFeesDeposit;
    uint64[] yHAFeesDeposit;
    uint64[] xHAFeesWithdraw;
    uint64[] yHAFeesWithdraw;
    uint64 haBonusMalusDeposit;
    uint64 haBonusMalusWithdraw;
}

struct PerpetualManagerParamData {
    uint64 maintenanceMargin;
    uint64 maxLeverage;
    uint64 targetHAHedge;
    uint64 limitHAHedge;
    uint64 lockTime;
}

struct CollateralAddresses {
    address stableMaster;
    address poolManager;
    address perpetualManager;
    address sanToken;
    address oracle;
    address gauge;
    address feeManager;
    address[] strategies;
}

interface IAngleHelper {
    function getCollateralAddresses(address agToken, address collateral)
        external
        view
        returns (CollateralAddresses memory addresses);

    function getStablecoinAddresses() external view returns (address[] memory, address[] memory);

    function getPoolManager(address agToken, address collateral) external view returns (address poolManager);
}
