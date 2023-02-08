// SPDX-License-Identifier: GPL-3.0

pragma solidity ^0.8.12;

interface IFeeRegistryFrax {
    function totalFees() external view returns (uint256);
}
