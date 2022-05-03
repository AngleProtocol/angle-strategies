// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.12;

import "./GenericAaveUpgradeable.sol";

/// @title GenericAaveFraxStaker
/// @author  Angle Core Team
/// @notice Allow to stake aFRAX on FRAX contracts to earn their incentives
contract GenericAaveNoStaker is GenericAaveUpgradeable {
    // ============================= Constructor =============================

    /// @notice Initializer of the `GenericAave`
    /// @param _strategy Reference to the strategy using this lender
    /// @param governorList List of addresses with governor privilege
    /// @param keeperList List of addresses with keeper privilege
    /// @param guardian Address of the guardian
    function initialize(
        address _strategy,
        string memory name,
        bool _isIncentivised,
        address[] memory governorList,
        address guardian,
        address[] memory keeperList
    ) external {
        initializeBase(_strategy, name, _isIncentivised, governorList, guardian, keeperList);
    }

    // ========================= Virtual Functions ===========================

    function _stake(uint256) internal override returns (uint256) {}

    function _unstake(uint256 amount) internal pure override returns (uint256) {
        return amount;
    }

    /// @notice Get current staked Frax balance (counting interest receive since last update)
    function _stakedBalance() internal pure override returns (uint256) {
        return 0;
    }

    /// @notice Get stakingAPR after staking an additional `amount`
    function _stakingApr(uint256) internal pure override returns (uint256) {
        return 0;
    }
}
