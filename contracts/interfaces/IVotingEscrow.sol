// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.12;

/// @title IVotingEscrow
/// @author Angle Core Team
/// @notice Interface for the `VotingEscrow` contract
interface IVotingEscrow {
    //solhint-disable-next-line
    function user_point_epoch(address user) external view returns (uint256);

    //solhint-disable-next-line
    function user_point_history__ts(address user, uint256 epoch) external view returns (uint256);
}
