// SPDX-License-Identifier: MIT

pragma solidity 0.8.7;

contract ComputeProfitability {
    struct SCalculateBorrow {
        int256 slope1;
        int256 slope2;
        int256 r0;
        int256 totalStableDebt;
        int256 totalVariableDebt;
        int256 uOptimal;
        int256 totalDeposits;
        int256 reserveFactor;
        int256 stableBorrowRate;
        int256 rewardDeposit;
        int256 rewardBorrow;
        int256 poolManagerAssets;
        int256 maxCollatRatio;
    }

    int256 private constant _BASE_RAY = 10 ** 27;

    function computeUtilization(int256 borrow, SCalculateBorrow memory parameters) public view returns(int256) {
        return (parameters.totalStableDebt + parameters.totalVariableDebt + borrow) * _BASE_RAY / (parameters.totalDeposits + borrow);
    }

    // borrow must be in BASE token (6 for USDC)
    function calculateInterest(int256 borrow, SCalculateBorrow memory parameters) public view returns(int256 interests) {
        int256 newUtilization = computeUtilization(borrow, parameters);

        if (newUtilization < parameters.uOptimal) {
            interests = parameters.r0 + parameters.slope1 * newUtilization / parameters.uOptimal;
        } else {
            interests = parameters.r0 + parameters.slope1 + parameters.slope2 * (newUtilization - parameters.uOptimal) / (_BASE_RAY - parameters.uOptimal);
        }
        return interests;
    }

    function computeUprime(int256 borrow, SCalculateBorrow memory parameters) public view returns(int256) {
        return (parameters.totalDeposits - parameters.totalStableDebt - parameters.totalVariableDebt) * _BASE_RAY / (parameters.totalDeposits + borrow);
    }

    // return value "interests" in BASE ray
    function calculateInterestPrime(int256 borrow, SCalculateBorrow memory parameters) public view returns(int256 interests) {
        int256 uprime = computeUprime(borrow, parameters);
        uprime = uprime * _BASE_RAY / (parameters.totalDeposits + borrow);
        if (computeUtilization(borrow, parameters) < parameters.uOptimal) {
            interests = parameters.slope1 * uprime / parameters.uOptimal;
        } else {
            interests = parameters.slope2 * uprime / (_BASE_RAY - parameters.uOptimal);
        }

        return interests;
    }

    // return value "interests" in BASE ray
    function calculateInterestPrime2(int256 borrow, SCalculateBorrow memory parameters) public view returns(int256 interests) {
        int256 uprime = -2 * computeUprime(borrow, parameters); // BASE ray
        uprime = uprime * _BASE_RAY / (parameters.totalDeposits + borrow);
        uprime = uprime * _BASE_RAY / (parameters.totalDeposits + borrow);
        if (computeUtilization(borrow, parameters) < parameters.uOptimal) {
            interests = parameters.slope1 * uprime / parameters.uOptimal;
        } else {
            interests = parameters.slope2 * uprime / (_BASE_RAY - parameters.uOptimal);
        }
        return interests;
    }

    function revenue(int256 borrow, SCalculateBorrow memory parameters) public view returns(int256) {
        int256 newRate = calculateInterest(borrow, parameters);
        int256 poolManagerFund = parameters.poolManagerAssets;
        int256 newPoolDeposit = borrow + poolManagerFund;
        int256 newCompDeposit = borrow + parameters.totalDeposits;
        int256 newCompBorrowVariable = borrow + parameters.totalVariableDebt;

        int256 f1 = newPoolDeposit * (_BASE_RAY - parameters.reserveFactor) / newCompDeposit;
        int256 f2 = (parameters.totalStableDebt * parameters.stableBorrowRate  + newCompBorrowVariable * newRate) / _BASE_RAY;
        
        int256 earnings = (f1 * f2) / _BASE_RAY;
        int256 cost = (borrow * newRate) / _BASE_RAY;
        int256 rewards = borrow * parameters.rewardBorrow / (newCompBorrowVariable + parameters.totalStableDebt) + newPoolDeposit * parameters.rewardDeposit / newCompDeposit;
        return  earnings + rewards - cost;
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

    function revenuePrime(int256 borrow, SCalculateBorrow memory parameters, SRevenuePrimeVars memory vars) public view returns(int256) {
        int256 f3prime = (vars.newRate * _BASE_RAY + borrow * vars.newRatePrime) / _BASE_RAY;
        
        int256 f4prime = parameters.rewardBorrow * (parameters.totalStableDebt + parameters.totalVariableDebt) / vars.newCompBorrow;
        f4prime = f4prime * _BASE_RAY / vars.newCompBorrow;
        int256 f5prime = parameters.rewardDeposit * (parameters.totalDeposits - vars.poolManagerFund) / vars.newCompDeposit;
        f5prime = f5prime * _BASE_RAY / vars.newCompDeposit;
        
        return ((vars.f1prime * vars.f2 + vars.f2prime * vars.f1) / _BASE_RAY) - f3prime + f4prime + f5prime;
    }

    function revenuePrime2(int256 borrow, SCalculateBorrow memory parameters, SRevenuePrimeVars memory vars) public view returns(int256) {
        int256 newRatePrime2 = calculateInterestPrime2(borrow, parameters);

        int256 derivate;
        {
            int256 f1prime2nd = - (parameters.totalDeposits - vars.poolManagerFund) * (_BASE_RAY - parameters.reserveFactor) * 2 / (vars.newCompDeposit);
            f1prime2nd = f1prime2nd * (_BASE_RAY) / (vars.newCompDeposit);
            f1prime2nd = f1prime2nd * (_BASE_RAY) / (vars.newCompDeposit);

            int256 f2prime2nd = ((vars.newRatePrime * _BASE_RAY + vars.newRatePrime * _BASE_RAY) + (vars.newCompBorrowVariable) * newRatePrime2) / (_BASE_RAY);
            int256 f3prime2nd = ((vars.newRatePrime * _BASE_RAY + vars.newRatePrime * _BASE_RAY) + (borrow) * newRatePrime2) / (_BASE_RAY);

            int256 f4prime2nd = - (parameters.rewardBorrow) * (parameters.totalStableDebt + parameters.totalVariableDebt) * 2 / (vars.newCompBorrow);
            f4prime2nd = f4prime2nd * (_BASE_RAY) / (vars.newCompBorrow);
            f4prime2nd = f4prime2nd * (_BASE_RAY) / (vars.newCompBorrow);
            int256 f5prime2nd = - (parameters.rewardDeposit) * (parameters.totalDeposits - vars.poolManagerFund) * 2 / (vars.newCompDeposit);
            f5prime2nd = f5prime2nd * (_BASE_RAY) / (vars.newCompDeposit);
            f5prime2nd = f5prime2nd * (_BASE_RAY) / (vars.newCompDeposit);
            
            derivate = f1prime2nd * vars.f2 + vars.f1prime * vars.f2prime + vars.f2prime * vars.f1prime + f2prime2nd*vars.f1 - f3prime2nd * (_BASE_RAY) + (f4prime2nd + f5prime2nd) * (_BASE_RAY);
        }

        return derivate / (_BASE_RAY);
    }

    function _abs(int256 x) private pure returns (int256) {
        return x >= 0 ? x : -x;
    }

    function revenuePrimeVars(int256 borrow, SCalculateBorrow memory parameters) public view returns(SRevenuePrimeVars memory) {
        int256 newRate = calculateInterest(borrow, parameters);
        int256 newRatePrime = calculateInterestPrime(borrow, parameters);

        int256 poolManagerFund = parameters.poolManagerAssets;
        int256 newPoolDeposit = borrow + poolManagerFund;
        int256 newCompDeposit = borrow + parameters.totalDeposits;
        int256 newCompBorrowVariable = borrow + parameters.totalVariableDebt;

        int256 f1 = newPoolDeposit * (_BASE_RAY - parameters.reserveFactor) / newCompDeposit;
        int256 f2 = (parameters.totalStableDebt * parameters.stableBorrowRate + newCompBorrowVariable * newRate) / _BASE_RAY;

        int256 f1prime = (parameters.totalDeposits - poolManagerFund) * (_BASE_RAY - parameters.reserveFactor) / newCompDeposit;
        f1prime = f1prime * _BASE_RAY / newCompDeposit;
        int256 f2prime = (newRate * _BASE_RAY + newCompBorrowVariable * newRatePrime) / _BASE_RAY;

        return SRevenuePrimeVars({
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

    function newtonRaphson(int256 _borrow, int256 tolerance, SCalculateBorrow memory parameters) public view returns(int256 borrow, int256 count) {
        int256 grad;
        int256 grad2nd;

        int maxCount = 30;
        count = 0;
        int256 borrowInit = _borrow;
        borrow = _borrow;
        
        int y = revenue(0, parameters);

        if (revenue(_BASE_RAY, parameters) <= y) {
            return (0, 1);
        }

        while (count < maxCount && (count == 0 || _abs((borrowInit - borrow) / borrowInit) > tolerance)) {
            SRevenuePrimeVars memory vars = revenuePrimeVars(borrow, parameters);
            grad = - revenuePrime(borrow, parameters, vars);
            grad2nd = - revenuePrime2(borrow, parameters, vars);
            borrowInit = borrow;
            borrow = borrowInit - grad * _BASE_RAY / grad2nd;
            count +=1;
        }

        int x = revenue(borrow, parameters);
        if (x <= y) {
            borrow = 0;
        }

        int256 collatRatio = (borrow * _BASE_RAY) / (parameters.poolManagerAssets + borrow);
        if (collatRatio > parameters.maxCollatRatio) {
            borrow = parameters.maxCollatRatio * parameters.poolManagerAssets / (_BASE_RAY - parameters.maxCollatRatio);
        }
    }

    function computeProfitability(SCalculateBorrow memory parameters) public view returns(int256 borrow) {
        int256 tolerance = 10**(27-2); // 1%
        (borrow, ) = newtonRaphson(parameters.poolManagerAssets, tolerance, parameters);
    }
}