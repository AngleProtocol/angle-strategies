// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.12;

import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import "../interfaces/ICoreBorrow.sol";
import "./SavingsRate.sol";

/// @title Angle Base Strategy ERC4626 Storage
/// @author Angle Protocol
contract BaseStrategy4626Storage is ERC4626Upgradeable {
    uint256 internal constant BASE_PARAMS = 10**9;

    SavingsRate[] public savingsRate;

    /// @notice CoreBorrow used to get governance addresses
    ICoreBorrow public coreBorrow;

    /// @notice See note on `setEmergencyExit()`
    bool public emergencyExit;

    /// @notice The period in seconds during which multiple harvests can occur
    /// regardless if they are taking place before the harvest delay has elapsed.
    /// @dev Long harvest windows open the SavingsRate up to profit distribution slowdown attacks.
    /// TODO is this one really useful?
    uint128 public harvestWindow;

    /// @notice The period in seconds over which locked profit is unlocked.
    /// @dev Cannot be 0 as it opens harvests up to sandwich attacks.
    uint64 public harvestDelay;

    /// @notice The value that will replace harvestDelay next harvest.
    /// @dev In the case that the next delay is 0, no update will be applied.
    uint64 public nextHarvestDelay;

    /// @notice A timestamp representing when the first harvest in the most recent harvest window occurred.
    /// @dev May be equal to lastHarvest if there was/has only been one harvest in the most last/current window.
    uint64 public lastHarvestWindowStart;

    /// @notice A timestamp representing when the most recent harvest occurred.
    uint64 public lastHarvest;

    /// @notice The amount of locked profit at the end of the last harvest.
    uint256 public maxLockedProfit;

    /// @notice The strategy holdings
    uint256 public totalStrategyHoldings;

    event Harvested(uint256 profit, uint256 loss, uint256 debtPayment, uint256 debtOutstanding);
    event HarvestWindowUpdated(address indexed user, uint128 newHarvestWindow);
    event HarvestDelayUpdated(address indexed user, uint64 newHarvestDelay);
    event HarvestDelayUpdateScheduled(address indexed user, uint64 newHarvestDelay);
    event EmergencyExitActivated();

    error NotGovernor();
    error NotGovernorOrGuardian();
    error NotSavingsRate();
    error HarvestWindowTooLarge();
    error HarvestDelayNull();
    error HarvestDelayTooLarge();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() initializer {}
}
