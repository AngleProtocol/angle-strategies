// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.7;

import "./AaveInterfaces.sol";

/// @title ComputeProfitability
/// @author Angle Core Team
/// @notice Helper contract to get the optimal borrow amount from a set of provided parameters from Aave
contract ComputeProfitability {
    struct SCalculateBorrow {
        int256 reserveFactor;
        int256 totalStableDebt;
        int256 totalVariableDebt;
        int256 totalDeposits;
        int256 stableBorrowRate;
        int256 rewardDeposit;
        int256 rewardBorrow;
        int256 strategyAssets;
        int256 maxCollatRatio;
        int256 slope1;
        int256 slope2;
        int256 r0;
        int256 uOptimal;
    }

    constructor() {}

    int256 private constant _BASE_RAY = 10**27;

    function _computeUtilization(int256 borrow, SCalculateBorrow memory parameters) internal pure returns (int256) {
        return
            ((parameters.totalStableDebt + parameters.totalVariableDebt + borrow) * _BASE_RAY) /
            (parameters.totalDeposits + borrow);
    }

    function _computeUprime(int256 borrow, SCalculateBorrow memory parameters) internal pure returns (int256) {
        return
            ((parameters.totalDeposits - parameters.totalStableDebt - parameters.totalVariableDebt) * _BASE_RAY) /
            (parameters.totalDeposits + borrow);
    }

    // return value "interests" in BASE ray
    function _calculateInterestPrimes(int256 borrow, SCalculateBorrow memory parameters)
        internal
        pure
        returns (
            int256 interests,
            int256 interestsPrime,
            int256 interestsPrime2
        )
    {
        int256 newUtilization = _computeUtilization(borrow, parameters);
        int256 denomUPrime = (parameters.totalDeposits + borrow);
        int256 uprime = _computeUprime(borrow, parameters);
        int256 uprime2 = -2 * uprime;
        uprime = (uprime * _BASE_RAY) / denomUPrime;
        uprime2 = (uprime2 * _BASE_RAY) / denomUPrime;
        uprime2 = (uprime2 * _BASE_RAY) / denomUPrime;
        if (newUtilization < parameters.uOptimal) {
            interests = parameters.r0 + (parameters.slope1 * newUtilization) / parameters.uOptimal;
            interestsPrime = (parameters.slope1 * uprime) / parameters.uOptimal;
            interestsPrime2 = (parameters.slope1 * uprime2) / parameters.uOptimal;
        } else {
            interests =
                parameters.r0 +
                parameters.slope1 +
                (parameters.slope2 * (newUtilization - parameters.uOptimal)) /
                (_BASE_RAY - parameters.uOptimal);
            interestsPrime = (parameters.slope2 * uprime) / (_BASE_RAY - parameters.uOptimal);
            interestsPrime2 = (parameters.slope2 * uprime2) / (_BASE_RAY - parameters.uOptimal);
        }
    }

    function _revenuePrimes(
        int256 borrow,
        SCalculateBorrow memory parameters,
        bool onlyRevenue
    )
        internal
        pure
        returns (
            int256 revenue,
            int256 revenuePrime,
            int256 revenuePrime2nd
        )
    {
        (int256 newRate, int256 newRatePrime, int256 newRatePrime2) = _calculateInterestPrimes(borrow, parameters);

        // 0 derivate
        int256 proportionStrat = ((borrow + parameters.strategyAssets) * (_BASE_RAY - parameters.reserveFactor)) /
            (borrow + parameters.totalDeposits);
        int256 poolYearlyRevenue = (parameters.totalStableDebt *
            parameters.stableBorrowRate +
            (borrow + parameters.totalVariableDebt) *
            newRate) / _BASE_RAY;

        revenue =
            (proportionStrat * poolYearlyRevenue) /
            _BASE_RAY +
            (borrow * parameters.rewardBorrow) /
            ((borrow + parameters.totalVariableDebt)) +
            ((borrow + parameters.strategyAssets) * parameters.rewardDeposit) /
            (borrow + parameters.totalDeposits) -
            (borrow * newRate) /
            _BASE_RAY;

        if (!onlyRevenue) {
            // 1st derivate
            {
                // stack too deep so computing block per block
                int256 proportionStratPrime = ((parameters.totalDeposits - parameters.strategyAssets) *
                    (_BASE_RAY - parameters.reserveFactor)) / (borrow + parameters.totalDeposits);
                proportionStratPrime = (proportionStratPrime * _BASE_RAY) / (borrow + parameters.totalDeposits);
                int256 poolYearlyRevenuePrime = (newRate *
                    _BASE_RAY +
                    (borrow + parameters.totalVariableDebt) *
                    newRatePrime) / _BASE_RAY;

                revenuePrime = ((proportionStratPrime * poolYearlyRevenue + poolYearlyRevenuePrime * proportionStrat) /
                    _BASE_RAY);

                {
                    int256 proportionStratPrime2nd = (-2 * (proportionStratPrime * (_BASE_RAY))) /
                        ((borrow + parameters.totalDeposits));
                    revenuePrime2nd =
                        2 *
                        proportionStratPrime *
                        poolYearlyRevenuePrime +
                        proportionStratPrime2nd *
                        poolYearlyRevenue;
                }
                // stack too deep
                poolYearlyRevenuePrime =
                    ((2 * newRatePrime * _BASE_RAY) + ((borrow + parameters.totalVariableDebt)) * newRatePrime2) /
                    _BASE_RAY;

                revenuePrime2nd += poolYearlyRevenuePrime * proportionStrat;
            }

            int256 costPrime = (newRate * _BASE_RAY + borrow * newRatePrime) / _BASE_RAY;
            int256 rewardBorrowPrime = (parameters.rewardBorrow * (parameters.totalVariableDebt)) /
                (borrow + parameters.totalVariableDebt);
            rewardBorrowPrime = (rewardBorrowPrime * _BASE_RAY) / (borrow + parameters.totalVariableDebt);
            int256 rewardDepositPrime = (parameters.rewardDeposit *
                (parameters.totalDeposits - parameters.strategyAssets)) / (borrow + parameters.totalDeposits);
            rewardDepositPrime = (rewardDepositPrime * _BASE_RAY) / (borrow + parameters.totalDeposits);

            revenuePrime += rewardBorrowPrime + rewardDepositPrime - costPrime;

            // 2nd derivate
            // reusing variables for the stack too deep issue
            costPrime = ((2 * newRatePrime * _BASE_RAY) + borrow * newRatePrime2) / _BASE_RAY;
            rewardBorrowPrime = (-2 * rewardBorrowPrime * _BASE_RAY) / (borrow + parameters.totalVariableDebt);
            rewardDepositPrime = (-2 * rewardDepositPrime * _BASE_RAY) / (borrow + parameters.totalDeposits);

            revenuePrime2nd =
                (revenuePrime2nd + (rewardBorrowPrime + rewardDepositPrime) * (_BASE_RAY) - costPrime * (_BASE_RAY)) /
                (_BASE_RAY);
        }
    }

    function _abs(int256 x) private pure returns (int256) {
        return x >= 0 ? x : -x;
    }

    function _newtonRaphson(
        int256 _borrow,
        int256 tolerance,
        SCalculateBorrow memory parameters
    ) internal pure returns (int256 borrow, int256 count) {
        int256 grad;
        int256 grad2nd;

        int256 maxCount = 30;
        count = 0;
        int256 borrowInit = _borrow;
        borrow = _borrow;

        (int256 y, , ) = _revenuePrimes(0, parameters, true);
        (int256 revenueWithBorrow, , ) = _revenuePrimes(_BASE_RAY, parameters, true);
        if (revenueWithBorrow <= y) {
            return (0, 1);
        }

        while (count < maxCount && (count == 0 || _abs((borrowInit - borrow) / borrowInit) > tolerance)) {
            (, grad, grad2nd) = _revenuePrimes(borrow, parameters, false);
            borrowInit = borrow;
            borrow = borrowInit - (grad * _BASE_RAY) / grad2nd;
            count += 1;
        }

        (int256 x, , ) = _revenuePrimes(borrow, parameters, true);
        if (x <= y) {
            borrow = 0;
        }
    }

    function computeProfitability(SCalculateBorrow memory parameters) external pure returns (int256 borrow) {
        int256 tolerance = 10**(27 - 2); // 1%
        (borrow, ) = _newtonRaphson(parameters.strategyAssets, tolerance, parameters);
    }
}
