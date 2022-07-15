// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.12;

import "../interfaces/ICoreBorrow.sol";
import "../interfaces/IVotingEscrowBoost.sol";
import "../interfaces/IVotingEscrow.sol";

/// @title VaultStorage
/// @author Angle Core Team
/// @dev Variables, references, parameters and events needed in the `VaultManager` contract
contract SavingsRateStorage {
    // =============================== References ==================================

    /// @notice Reference to the veANGLE
    IVotingEscrow internal votingEscrow;

    /// @notice Reference to the veANGLE
    IVotingEscrowBoost internal veBoostProxy;

    // =============================== Parameters ==================================
    /// @dev This parameter will adapt the max boost achievable
    /// If set to 40% Maximum boost will be 2.5
    uint256 public tokenlessProduction;

    // =============================== Variables ===================================

    /// @notice Boosting params
    uint256 public workingSupply;

    /// @notice Rewards (in asset) claimable by depositors
    uint256 public claimableRewards;
    /// @notice Used to track rewards accumulated by all depositors of the reactor
    uint256 public rewardsAccumulator;
    /// @notice Tracks rewards already claimed by all depositors
    uint256 public claimedRewardsAccumulator;
    /// @notice Last time rewards were claimed in the reactor
    uint256 public lastTime;
    /// @notice Maps an address to the last time it claimed its rewards
    mapping(address => uint256) public lastTimeOf;
    /// @notice Maps an address to a quantity depending on time and shares of the reactors used
    /// to compute the rewards an address can claim
    mapping(address => uint256) public rewardsAccumulatorOf;

    // ================================ Mappings ===================================

    /// @notice Users shares balances taking into account the veBoost
    mapping(address => uint256) public workingBalances;

    /// @notice Users claimable rewards balances
    mapping(address => uint256) public rewardBalances;

    // =============================== Events ======================================

    event TokenlessProductionUpdated(address indexed user, uint256 tokenlessProduction);

    // =============================== Errors ======================================

    error KickNotAllowed();
    error KickNotNeeded();
}
