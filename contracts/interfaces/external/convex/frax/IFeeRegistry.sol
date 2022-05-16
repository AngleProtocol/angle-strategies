// SPDX-License-Identifier: MIT
pragma solidity 0.8.12;

interface IFeeRegistry {
    function totalFees() external view returns (uint256);
}
