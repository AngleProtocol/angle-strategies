// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.12;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import "../interfaces/ICoreBorrow.sol";
import "../interfaces/ISavingsRate.sol";

/// @title Angle Base Strategy ERC4626 Storage
/// @author Angle Protocol
contract BaseStrategy4626Storage is ERC4626Upgradeable {
    uint256 internal constant BASE_PARAMS = 10**9;

    ISavingsRate[] public savingsRateList;

    /// @notice CoreBorrow used to get governance addresses
    ICoreBorrow public coreBorrow;

    /// @notice See note on `setEmergencyExit()`
    bool public emergencyExit;

    /// @notice The strategy holdings
    uint256 public totalStrategyHoldings;

    // ================================ Mappings ===================================

    /// The struct `StrategyParams` is defined in the interface `IPoolManager`
    /// @notice Mapping between the address of a strategy contract and its corresponding details
    mapping(ISavingsRate => bool) public savingsRate;

    // ================================ Events ===================================

    event Harvested(uint256 profit, uint256 loss, uint256 debt, address indexed vault);
    event EmergencyExitActivated();
    event SavingsRateActivated(address indexed saving);
    event SavingsRateRevoked(address indexed saving);

    error NotGovernor();
    error NotGovernorOrGuardian();
    error NotSavingsRate();
    error SavingRateKnown();
    error SavingRateUnknown();
    error StrategyInUse();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() initializer {}
}
