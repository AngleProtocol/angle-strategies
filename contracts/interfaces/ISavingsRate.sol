// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.12;

import "@openzeppelin/contracts-upgradeable/interfaces/IERC4626Upgradeable.sol";

/// @title IStrategyERC4626
/// @author Angle Core Team
/// @notice Interface for the `Strategy4626` contract
/// @dev Strategies invested in supports the ERC4626 interfaces and has some added features
interface ISavingsRate is IERC4626Upgradeable {
    function estimatedAPR() external view returns (uint256);

    function isVault() external;

    function report() external;
}