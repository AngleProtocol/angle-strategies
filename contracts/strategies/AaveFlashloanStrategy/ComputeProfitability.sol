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
        int256 poolManagerAssets;
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

    function _revenuePrimes(int256 borrow, SCalculateBorrow memory parameters)
        internal
        pure
        returns (
            int256 revenue,
            int256 revenuePrime,
            int256 revenurPrime2nd
        )
    {
        (int256 newRate, int256 newRatePrime, int256 newRatePrime2) = _calculateInterestPrimes(borrow, parameters);

        // precomputed values
        int256 poolManagerFund = parameters.poolManagerAssets;
        int256 newPoolDeposit = borrow + poolManagerFund;
        int256 newCompDeposit = borrow + parameters.totalDeposits;
        int256 newCompBorrowVariable = borrow + parameters.totalVariableDebt;
        int256 newCompBorrow = newCompBorrowVariable + parameters.totalStableDebt;

        // derivate 0
        int256 proportionStrat = (newPoolDeposit * (_BASE_RAY - parameters.reserveFactor)) / newCompDeposit;
        int256 poolYearlyRevenue = (parameters.totalStableDebt *
            parameters.stableBorrowRate +
            newCompBorrowVariable *
            newRate) / _BASE_RAY;

        int256 earnings = (proportionStrat * poolYearlyRevenue) / _BASE_RAY;
        int256 cost = (borrow * newRate) / _BASE_RAY;
        int256 rewards = (borrow * parameters.rewardBorrow) /
            (newCompBorrowVariable) +
            (newPoolDeposit * parameters.rewardDeposit) /
            newCompDeposit;

        // 1st derivate
        int256 proportionStratPrime = ((parameters.totalDeposits - poolManagerFund) *
            (_BASE_RAY - parameters.reserveFactor)) / newCompDeposit;
        proportionStratPrime = (proportionStratPrime * _BASE_RAY) / newCompDeposit;
        int256 poolYearlyRevenuePrime = (newRate * _BASE_RAY + newCompBorrowVariable * newRatePrime) / _BASE_RAY;
        int256 costPrime = (newRate * _BASE_RAY + borrow * newRatePrime) / _BASE_RAY;
        int256 rewardBorrowPrime = (parameters.rewardBorrow * (parameters.totalVariableDebt)) / newCompBorrowVariable;
        rewardBorrowPrime = (rewardBorrowPrime * _BASE_RAY) / newCompBorrowVariable;
        int256 rewardDepositPrime = (parameters.rewardDeposit * (parameters.totalDeposits - poolManagerFund)) /
            newCompDeposit;
        rewardDepositPrime = (rewardDepositPrime * _BASE_RAY) / newCompDeposit;

        // 2nd derivate
        int256 proportionStratPrime2nd = (-2 * (proportionStratPrime * (_BASE_RAY))) / (newCompDeposit);
        int256 poolYearlyRevenuePrime2nd = ((2 * newRatePrime * _BASE_RAY) + (newCompBorrowVariable) * newRatePrime2) /
            _BASE_RAY;
        int256 costPrime2nd = ((2 * newRatePrime * _BASE_RAY) + borrow * newRatePrime2) / _BASE_RAY;
        int256 rewardBorrowPrime2nd = (-2 * rewardBorrowPrime * _BASE_RAY) / newCompBorrowVariable;
        int256 rewardDeposit2nd = (-2 * rewardDepositPrime * _BASE_RAY) / newCompDeposit;

        revenue = earnings + rewards - cost;
        revenuePrime =
            ((proportionStratPrime * poolYearlyRevenue + poolYearlyRevenuePrime * proportionStrat) / _BASE_RAY) +
            rewardBorrowPrime +
            rewardDepositPrime -
            costPrime;
        revenurPrime2nd =
            (proportionStratPrime2nd *
                poolYearlyRevenue +
                proportionStratPrime *
                poolYearlyRevenuePrime +
                poolYearlyRevenuePrime *
                proportionStratPrime +
                poolYearlyRevenuePrime2nd *
                proportionStrat +
                (rewardBorrowPrime2nd + rewardDeposit2nd) *
                (_BASE_RAY) -
                costPrime2nd *
                (_BASE_RAY)) /
            (_BASE_RAY);
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

        (int256 y, , ) = _revenuePrimes(0, parameters);
        (int256 revenueWithBorrow, , ) = _revenuePrimes(_BASE_RAY, parameters);
        if (revenueWithBorrow <= y) {
            return (0, 1);
        }

        while (count < maxCount && (count == 0 || _abs((borrowInit - borrow) / borrowInit) > tolerance)) {
            (, grad, grad2nd) = _revenuePrimes(borrow, parameters);
            borrowInit = borrow;
            borrow = borrowInit - (grad * _BASE_RAY) / grad2nd;
            count += 1;
        }

        (int256 x, , ) = _revenuePrimes(borrow, parameters);
        if (x <= y) {
            borrow = 0;
        }

        // int256 collatRatio = (borrow * _BASE_RAY) / (parameters.poolManagerAssets + borrow);
        // if (collatRatio > parameters.maxCollatRatio) {
        //     borrow = parameters.maxCollatRatio * parameters.poolManagerAssets / (_BASE_RAY - parameters.maxCollatRatio);
        // }
    }

    function computeProfitability(SCalculateBorrow memory parameters) external pure returns (int256 borrow) {
        int256 tolerance = 10**(27 - 2); // 1%
        (borrow, ) = _newtonRaphson(parameters.poolManagerAssets, tolerance, parameters);
    }
}
