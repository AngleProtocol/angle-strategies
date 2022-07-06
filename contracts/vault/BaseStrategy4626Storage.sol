// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.12;

import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20TokenizedVaultUpgradeable.sol";
import "./Vault.sol";

/// @title Angle Base Strategy ERC4626 Storage
/// @author Angle Protocol
contract BaseStrategy4626Storage is ERC20TokenizedVaultUpgradeable {
    uint256 internal constant BASE_PARAMS = 10**9;

    Vault public vault;

    /// @notice The period in seconds during which multiple harvests can occur
    /// regardless if they are taking place before the harvest delay has elapsed.
    /// @dev Long harvest windows open the Vault up to profit distribution slowdown attacks.
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

    event Harvest(address indexed user, address indexed strategy);
    event HarvestDelayUpdated(address indexed user, uint64 newHarvestDelay);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() initializer {}
}
