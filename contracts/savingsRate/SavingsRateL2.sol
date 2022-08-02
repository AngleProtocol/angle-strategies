// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.12;

import "./SavingsRate.sol";

/// @title SavingsRateNoBoost
/// @author Angle Core Team
/// @notice Contract for yield aggregator vaults which can connect to multiple ERC4626 strategies
/// @notice In this implementation there's no boost given to owners of the shares of the contract
contract SavingsRateL2 is SavingsRate {
    using SafeERC20 for IERC20;
    using Address for address;
    using MathUpgradeable for uint256;

    /// @notice Initializes the `SavingsRateNoBoost` contract
    function initializeL2(
        ICoreBorrow _coreBorrow,
        IERC20MetadataUpgradeable _token,
        address _surplusManager,
        string memory suffixName
    ) external {
        _initialize(_coreBorrow, _token, _surplusManager, suffixName);
    }

    // ============================== Internal functions ===============================

    /// @inheritdoc ERC20Upgradeable
    /// @dev This will allow to harvest at each mint, there will be no idle capital if debt ratio = BASE_PARAMS
    /// and therefore when withdrawing the user will be forced to take the loss
    /// @dev Partially true because the user can call the `harvest` function to incure the loss to the whole vault
    /// And even if we withdraw the `external version of `harvest`it could call deposit wit a small amount to let the loss be supported by everyone
    /// @dev Solution is either to make incure the loss to the depositor too, or to not report yet and only do the adjustPosition (I think the last option could work,
    /// and it seems the best option)
    function _afterTokenTransfer(
        address from,
        address,
        uint256
    ) internal override {
        // Only in the case of a mint
        if (from == address(0)) {
            IStrategy4626[] memory activeStrategies = strategyList;
            harvest(activeStrategies);
        }
    }
}
