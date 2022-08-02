// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.12;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import "../interfaces/ICoreBorrow.sol";
import "../interfaces/ISavingsRate.sol";
import "../interfaces/IStrategy4626.sol";

/// @title BaseStrategy4626Storage
/// @author Angle Core Team
/// @notice This is the storage file for the strategy contracts designed to interact with Angle savings rate contracts
contract BaseStrategy4626Storage is ERC4626Upgradeable {
    uint256 internal constant BASE_PARAMS = 10**9;

    /// @notice CoreBorrow used to get governance addresses
    ICoreBorrow public coreBorrow;

    /// @notice See note on `setEmergencyExit()`
    bool public emergencyExit;

    /// @notice Amount controlled by the strategy: it is updated at each deposit, withdrawal, and every time
    /// the strategy is reported to check its gains
    uint256 public totalStrategyHoldings;

    /// @notice List of all savings rate contracts that have the right to interact with this strategy
    /// It is designed as a helper for UIs
    ISavingsRate[] public savingsRateList;

    // ================================ Mapping ====================================

    /// @notice Maps a savings rate contract to whether it is initialized or not
    mapping(ISavingsRate => bool) public savingsRate;

    // ================================ Events =====================================

    event EmergencyExitActivated();
    event Harvested(uint256 profit, uint256 loss, uint256 debt, address indexed vault);
    event SavingsRateActivated(address indexed saving);
    event SavingsRateRevoked(address indexed saving);

    // ================================ Errors =====================================

    error InvalidSavingsRate();
    error NotGovernor();
    error NotGovernorOrGuardian();
    error NotSavingsRate();
    error StrategyInUse();
    error TooHighDeposit();
    error TooHighWithdraw();
    error ZeroAddress();

    // TODO update this when good
    uint256[50] private __gapBaseStrategy;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() initializer {}
}
