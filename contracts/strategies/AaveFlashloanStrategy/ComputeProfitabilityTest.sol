// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.7;

import "./ComputeProfitability.sol";

/// @title ComputeProfitabilityTest
/// @author Angle Core Team
/// @notice Wrapper contract to ComputeProfitability for testing purpose
contract ComputeProfitabilityTest is ComputeProfitability {
    /// @notice external version of _calculateInterestPrimes
    function calculateInterestPrimes(int256 borrow, SCalculateBorrow memory parameters)
        external
        pure
        returns (
            int256,
            int256,
            int256
        )
    {
        return _calculateInterestPrimes(borrow, parameters);
    }

    /// @notice External version of _revenuePrimes
    function revenuePrimes(
        int256 borrow,
        SCalculateBorrow memory parameters,
        bool onlyRevenue
    )
        external
        pure
        returns (
            int256,
            int256,
            int256
        )
    {
        return _revenuePrimes(borrow, parameters, onlyRevenue);
    }
}
