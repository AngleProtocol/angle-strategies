// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.12;

/// @title IVotingEscrowBoost
/// @author Angle Core Team
/// @notice Interface for the `VotingEscrowBoost` contract
interface IVotingEscrowBoost {
    /// @notice Get current veANGLE delegated balance for `user`
    /// @param user Address to check ve delegation for
    function adjusted_balance_of(address user) external view returns (uint256);
}
