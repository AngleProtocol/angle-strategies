// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.12;

import "../interfaces/ICoreBorrow.sol";
import "../interfaces/IVotingEscrowBoost.sol";
import "../interfaces/IVotingEscrow.sol";

/// @title SavingsRateStorage
/// @author Angle Core Team
/// @dev Specific storage contract for additional variables needed in the `SavingsRate` contract which need a boost
contract SavingsRateStorage {

    // TODO clean events and errors
    // =============================== References ==================================

    /// @notice Reference to the veANGLE contract
    IVotingEscrow internal votingEscrow;

    /// @notice Reference to the `veBoostProxy` contract
    IVotingEscrowBoost internal veBoostProxy;

    // =============================== Parameters ==================================

    /// @dev Adapts the max boost achievable
    /// If set to 40%, Maximum boost for veANGLE holders will be 2.5
    uint256 public tokenlessProduction;

    // =============================== Variables ===================================

    /// @notice Boosting params
    uint256 public workingSupply;
    /// @notice Used to track rewards accumulated by all depositors of the contract
    uint256 public integral;
    /// @notice Maps an address to the last time it claimed its rewards
    mapping(address => uint256) public lastTimeOf;
    mapping(address => uint256) public integralFor;

    // ================================ Mappings ===================================

    /// @notice Users shares balances taking into account the veBoost
    mapping(address => uint256) public workingBalances;

    /// @notice Users claimable rewards balances
    mapping(address => uint256) public rewardBalances;

    uint256 public rewardRate;

    uint64 public periodFinish;

    // =============================== Events ======================================

    event TokenlessProductionUpdated(address indexed user, uint256 tokenlessProduction);

    // =============================== Errors ======================================

    error KickNotAllowed();
    error KickNotNeeded();
}
