// SPDX-License-Identifier: MIT

pragma solidity 0.8.7;

import "./AaveInterfaces.sol";

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
    }

    IReserveInterestRateStrategy private constant _interestRateStrategyAddress =
        IReserveInterestRateStrategy(0x8Cae0596bC1eD42dc3F04c4506cfe442b3E74e27);
    IProtocolDataProvider private constant _protocolDataProvider =
        IProtocolDataProvider(0x057835Ad21a177dbdd3090bB1CAE03EaCF78Fc6d);

    int256 public slope1;
    int256 public slope2;
    int256 public r0;
    int256 public uOptimal;

    constructor() {}

    function setAavePoolVariables() external {
        slope1 = int256(_interestRateStrategyAddress.variableRateSlope1());
        slope2 = int256(_interestRateStrategyAddress.variableRateSlope2());
        r0 = int256(_interestRateStrategyAddress.baseVariableBorrowRate());
        uOptimal = int256(_interestRateStrategyAddress.OPTIMAL_UTILIZATION_RATE());
    }

    int256 private constant _BASE_RAY = 10**27;

    function _computeUtilization(int256 borrow, SCalculateBorrow memory parameters) internal pure returns (int256) {
        return
            ((parameters.totalStableDebt + parameters.totalVariableDebt + borrow) * _BASE_RAY) /
            (parameters.totalDeposits + borrow);
    }

    // borrow must be in BASE token (6 for USDC)
    function _calculateInterest(int256 borrow, SCalculateBorrow memory parameters)
        internal
        view
        returns (int256 interests)
    {
        int256 newUtilization = _computeUtilization(borrow, parameters);

        if (newUtilization < uOptimal) {
            interests = r0 + (slope1 * newUtilization) / uOptimal;
        } else {
            interests = r0 + slope1 + (slope2 * (newUtilization - uOptimal)) / (_BASE_RAY - uOptimal);
        }
        return interests;
    }

    function _computeUprime(int256 borrow, SCalculateBorrow memory parameters) internal pure returns (int256) {
        return
            ((parameters.totalDeposits - parameters.totalStableDebt - parameters.totalVariableDebt) * _BASE_RAY) /
            (parameters.totalDeposits + borrow);
    }

    // return value "interests" in BASE ray
    function _calculateInterestPrime(int256 borrow, SCalculateBorrow memory parameters)
        internal
        view
        returns (int256 interests)
    {
        int256 uprime = _computeUprime(borrow, parameters);
        uprime = (uprime * _BASE_RAY) / (parameters.totalDeposits + borrow);
        if (_computeUtilization(borrow, parameters) < uOptimal) {
            interests = (slope1 * uprime) / uOptimal;
        } else {
            interests = (slope2 * uprime) / (_BASE_RAY - uOptimal);
        }

        return interests;
    }

    // return value "interests" in BASE ray
    function _calculateInterestPrime2(int256 borrow, SCalculateBorrow memory parameters)
        internal
        view
        returns (int256 interests)
    {
        int256 uprime = -2 * _computeUprime(borrow, parameters); // BASE ray
        uprime = (uprime * _BASE_RAY) / (parameters.totalDeposits + borrow);
        uprime = (uprime * _BASE_RAY) / (parameters.totalDeposits + borrow);
        if (_computeUtilization(borrow, parameters) < uOptimal) {
            interests = (slope1 * uprime) / uOptimal;
        } else {
            interests = (slope2 * uprime) / (_BASE_RAY - uOptimal);
        }
        return interests;
    }

    function _revenue(int256 borrow, SCalculateBorrow memory parameters) internal view returns (int256) {
        int256 newRate = _calculateInterest(borrow, parameters);
        int256 poolManagerFund = parameters.poolManagerAssets;
        int256 newPoolDeposit = borrow + poolManagerFund;
        int256 newCompDeposit = borrow + parameters.totalDeposits;
        int256 newCompBorrowVariable = borrow + parameters.totalVariableDebt;

        int256 f1 = (newPoolDeposit * (_BASE_RAY - parameters.reserveFactor)) / newCompDeposit;
        int256 f2 = (parameters.totalStableDebt * parameters.stableBorrowRate + newCompBorrowVariable * newRate) /
            _BASE_RAY;

        int256 earnings = (f1 * f2) / _BASE_RAY;
        int256 cost = (borrow * newRate) / _BASE_RAY;
        int256 rewards = (borrow * parameters.rewardBorrow) /
            (newCompBorrowVariable + parameters.totalStableDebt) +
            (newPoolDeposit * parameters.rewardDeposit) /
            newCompDeposit;
        return earnings + rewards - cost;
    }

    struct SRevenuePrimeVars {
        int256 newRate;
        int256 newRatePrime;
        int256 poolManagerFund;
        int256 newPoolDeposit;
        int256 newCompDeposit;
        int256 newCompBorrowVariable;
        int256 newCompBorrow;
        int256 f1;
        int256 f2;
        int256 f1prime;
        int256 f2prime;
    }

    function _revenuePrime(
        int256 borrow,
        SCalculateBorrow memory parameters,
        SRevenuePrimeVars memory vars
    ) internal pure returns (int256) {
        int256 f3prime = (vars.newRate * _BASE_RAY + borrow * vars.newRatePrime) / _BASE_RAY;

        int256 f4prime = (parameters.rewardBorrow * (parameters.totalStableDebt + parameters.totalVariableDebt)) /
            vars.newCompBorrow;
        f4prime = (f4prime * _BASE_RAY) / vars.newCompBorrow;
        int256 f5prime = (parameters.rewardDeposit * (parameters.totalDeposits - vars.poolManagerFund)) /
            vars.newCompDeposit;
        f5prime = (f5prime * _BASE_RAY) / vars.newCompDeposit;

        return ((vars.f1prime * vars.f2 + vars.f2prime * vars.f1) / _BASE_RAY) - f3prime + f4prime + f5prime;
    }

    function _revenuePrime2(
        int256 borrow,
        SCalculateBorrow memory parameters,
        SRevenuePrimeVars memory vars
    ) internal view returns (int256) {
        int256 newRatePrime2 = _calculateInterestPrime2(borrow, parameters);

        int256 derivate;
        {
            int256 f1prime2nd = (-(parameters.totalDeposits - vars.poolManagerFund) *
                (_BASE_RAY - parameters.reserveFactor) *
                2) / (vars.newCompDeposit);
            f1prime2nd = (f1prime2nd * (_BASE_RAY)) / (vars.newCompDeposit);
            f1prime2nd = (f1prime2nd * (_BASE_RAY)) / (vars.newCompDeposit);

            int256 f2prime2nd = ((vars.newRatePrime * _BASE_RAY + vars.newRatePrime * _BASE_RAY) +
                (vars.newCompBorrowVariable) *
                newRatePrime2) / (_BASE_RAY);
            int256 f3prime2nd = ((vars.newRatePrime * _BASE_RAY + vars.newRatePrime * _BASE_RAY) +
                (borrow) *
                newRatePrime2) / (_BASE_RAY);

            int256 f4prime2nd = (-(parameters.rewardBorrow) *
                (parameters.totalStableDebt + parameters.totalVariableDebt) *
                2) / (vars.newCompBorrow);
            f4prime2nd = (f4prime2nd * (_BASE_RAY)) / (vars.newCompBorrow);
            f4prime2nd = (f4prime2nd * (_BASE_RAY)) / (vars.newCompBorrow);
            int256 f5prime2nd = (-(parameters.rewardDeposit) * (parameters.totalDeposits - vars.poolManagerFund) * 2) /
                (vars.newCompDeposit);
            f5prime2nd = (f5prime2nd * (_BASE_RAY)) / (vars.newCompDeposit);
            f5prime2nd = (f5prime2nd * (_BASE_RAY)) / (vars.newCompDeposit);

            derivate =
                f1prime2nd *
                vars.f2 +
                vars.f1prime *
                vars.f2prime +
                vars.f2prime *
                vars.f1prime +
                f2prime2nd *
                vars.f1 -
                f3prime2nd *
                (_BASE_RAY) +
                (f4prime2nd + f5prime2nd) *
                (_BASE_RAY);
        }

        return derivate / (_BASE_RAY);
    }

    function _abs(int256 x) private pure returns (int256) {
        return x >= 0 ? x : -x;
    }

    function _revenuePrimeVars(int256 borrow, SCalculateBorrow memory parameters)
        internal
        view
        returns (SRevenuePrimeVars memory)
    {
        int256 newRate = _calculateInterest(borrow, parameters);
        int256 newRatePrime = _calculateInterestPrime(borrow, parameters);

        int256 poolManagerFund = parameters.poolManagerAssets;
        int256 newPoolDeposit = borrow + poolManagerFund;
        int256 newCompDeposit = borrow + parameters.totalDeposits;
        int256 newCompBorrowVariable = borrow + parameters.totalVariableDebt;

        int256 f1 = (newPoolDeposit * (_BASE_RAY - parameters.reserveFactor)) / newCompDeposit;
        int256 f2 = (parameters.totalStableDebt * parameters.stableBorrowRate + newCompBorrowVariable * newRate) /
            _BASE_RAY;

        int256 f1prime = ((parameters.totalDeposits - poolManagerFund) * (_BASE_RAY - parameters.reserveFactor)) /
            newCompDeposit;
        f1prime = (f1prime * _BASE_RAY) / newCompDeposit;
        int256 f2prime = (newRate * _BASE_RAY + newCompBorrowVariable * newRatePrime) / _BASE_RAY;

        return
            SRevenuePrimeVars({
                newRate: newRate,
                newRatePrime: newRatePrime,
                poolManagerFund: poolManagerFund,
                newPoolDeposit: newPoolDeposit,
                newCompDeposit: newCompDeposit,
                newCompBorrowVariable: newCompBorrowVariable,
                newCompBorrow: newCompBorrowVariable + parameters.totalStableDebt,
                f1: f1,
                f2: f2,
                f1prime: f1prime,
                f2prime: f2prime
            });
    }

    function _newtonRaphson(
        int256 _borrow,
        int256 tolerance,
        SCalculateBorrow memory parameters
    ) internal view returns (int256 borrow, int256 count) {
        int256 grad;
        int256 grad2nd;

        int256 maxCount = 30;
        count = 0;
        int256 borrowInit = _borrow;
        borrow = _borrow;

        int256 y = _revenue(0, parameters);

        if (_revenue(_BASE_RAY, parameters) <= y) {
            return (0, 1);
        }

        while (count < maxCount && (count == 0 || _abs((borrowInit - borrow) / borrowInit) > tolerance)) {
            SRevenuePrimeVars memory vars = _revenuePrimeVars(borrow, parameters);
            grad = -_revenuePrime(borrow, parameters, vars);
            grad2nd = -_revenuePrime2(borrow, parameters, vars);
            borrowInit = borrow;
            borrow = borrowInit - (grad * _BASE_RAY) / grad2nd;
            count += 1;
        }

        int256 x = _revenue(borrow, parameters);
        if (x <= y) {
            borrow = 0;
        }

        // int256 collatRatio = (borrow * _BASE_RAY) / (parameters.poolManagerAssets + borrow);
        // if (collatRatio > parameters.maxCollatRatio) {
        //     borrow = parameters.maxCollatRatio * parameters.poolManagerAssets / (_BASE_RAY - parameters.maxCollatRatio);
        // }
    }

    function computeProfitability(SCalculateBorrow memory parameters) external view returns (int256 borrow) {
        int256 tolerance = 10**(27 - 2); // 1%
        (borrow, ) = _newtonRaphson(parameters.poolManagerAssets, tolerance, parameters);
    }
}
