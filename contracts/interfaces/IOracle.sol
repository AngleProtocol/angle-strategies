// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.12;

/// @title IOracle
interface IOracle {
    /// @notice Returns the value of a base token in quote token in base 18
    function read() external view returns (uint256);
}
