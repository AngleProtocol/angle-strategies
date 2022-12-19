// SPDX-License-Identifier: GPL-3.0

pragma solidity ^0.8.17;

import "../GenericEulerStaker.sol";

/// @title GenericEulerStakerUSDC
/// @author  Angle Core Team
/// @notice Implements `GenericEulerStaker` for eUSDC
contract GenericEulerStakerUSDC is GenericEulerStaker {
    // ================================ CONSTRUCTOR ================================

    /// @notice Wrapper built on top of the `initializeStaker` method to initialize the contract
    function initialize(
        address _strategy,
        string memory _name,
        address[] memory governorList,
        address guardian,
        address[] memory keeperList
    ) external {
        _initializeStaker(_strategy, _name, governorList, guardian, keeperList);
    }

    // ============================= VIRTUAL FUNCTIONS =============================

    /// @notice Return pool used as oracle and whether we should multiply or divide to get the price
    function _eulerStakingContract() internal pure override returns (IEulerStakingRewards) {
        return IEulerStakingRewards(0xE5aFE81e63f0A52a3a03B922b30f73B8ce74D570);
    }
}
