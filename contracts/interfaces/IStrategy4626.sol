// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.12;

import "@openzeppelin/contracts-upgradeable/interfaces/IERC4626Upgradeable.sol";

/// @title IStrategyERC4626
/// @author Angle Core Team
/// @notice Interface for `Strategy4626` contracts
/// @dev This interface only contains functions of the `Strategy4626` which are called by other contracts
/// of this module
interface IStrategy4626 is IERC4626Upgradeable {
    /// @notice Estimates the APR provided by the strategy
    function estimatedAPR() external view returns (uint256);

    /// @notice Checks whether the `msg.sender` is an approved savings rate contract or not
    function isSavingsRate() external view returns (bool);

    /// @notice Estimate redeemable assets from an owner
    function ownerRedeemableAssets(address owner) external view returns (uint256);

    /// @notice Prepares a return of the strategy to one of the savings rate contract plugged to the strategy
    /// @param _callerDebtOutstanding Amount of `asset` owed by the strategy to the savings rate contract:
    /// it will be 0 if the Strategy is not past the configured debt limit,
    /// otherwise its value will be how far past the debt limit the Strategy is.
    /// @return profit Profit made by the strategy
    /// @return loss Loss made by the strategy
    /// @dev In the rare case the Strategy is in emergency shutdown, this will exit the Strategy's position.
    /// @dev When `report()` is called, the Strategy reports to the corresponding savings rate contract,
    /// so in some cases `harvest()` must be called in order to take in profits,
    /// to borrow newly available funds from the vaults, or
    /// otherwise adjust its position. In other cases `harvest()` must be
    /// called to report to the vaults on the Strategy's position, especially if
    /// any losses have occurred.
    /// @dev The returned values must be taken cautiously as they are aggregated for all the savings rate contracts
    /// which interact with this strategy
    function report(uint256 _callerDebtOutstanding) external returns (uint256, uint256);

    /// @notice Added function to the interface to have the possibility to feed external parameters
    function deposit(
        uint256 assets,
        address receiver,
        bytes memory data
    ) external returns (uint256 shares);

    function withdraw(
        uint256 assets,
        address receiver,
        address owner,
        bytes memory data
    ) external returns (uint256 _loss);
}
