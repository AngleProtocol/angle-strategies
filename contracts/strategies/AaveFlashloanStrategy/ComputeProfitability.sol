// SPDX-License-Identifier: MIT

pragma solidity 0.8.7;

import "hardhat/console.sol";

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
    }

    int256 BASE_RAY = 10 ** 27;

    function computeUtilization(int256 borrow, SCalculateBorrow memory parameters) public view returns(int256) {
        return (parameters.totalStableDebt + parameters.totalVariableDebt + borrow) * BASE_RAY / (parameters.totalDeposits + borrow);
    }

    // borrow must be in BASE token (6 for USDC)
    function calculateInterest(int256 borrow, SCalculateBorrow memory parameters) public view returns(int256 interests) {
        int256 newUtilization = computeUtilization(borrow, parameters);

        if (newUtilization < parameters.uOptimal) {
            interests = parameters.r0 + parameters.slope1 * newUtilization / parameters.uOptimal;
        } else {
            interests = parameters.r0 + parameters.slope1 + parameters.slope2 * (newUtilization - parameters.uOptimal) / (BASE_RAY - parameters.uOptimal);
        }
        return interests;
    }

    function computeUprime(int256 borrow, SCalculateBorrow memory parameters) public view returns(int256) {
        return (parameters.totalDeposits - parameters.totalStableDebt - parameters.totalVariableDebt) * BASE_RAY / (parameters.totalDeposits + borrow);
    }

    // return value "interests" in BASE ray
    function calculateInterestPrime(int256 borrow, SCalculateBorrow memory parameters) public view returns(int256 interests) {
        int256 uprime = computeUprime(borrow, parameters);
        uprime = uprime * BASE_RAY / (parameters.totalDeposits + borrow);
        if (computeUtilization(borrow, parameters) < parameters.uOptimal) {
            interests = parameters.slope1 * uprime / parameters.uOptimal;
        } else {
            interests = parameters.slope2 * uprime / (BASE_RAY - parameters.uOptimal);
        }

        return interests;
    }

    // return value "interests" in BASE ray
    function calculateInterestPrime2(int256 borrow, SCalculateBorrow memory parameters) public view returns(int256 interests) {
        int256 uprime = -2 * computeUprime(borrow, parameters); // BASE ray
        uprime = uprime * BASE_RAY / (parameters.totalDeposits + borrow);
        uprime = uprime * BASE_RAY / (parameters.totalDeposits + borrow);
        if (computeUtilization(borrow, parameters) < parameters.uOptimal) {
            interests = parameters.slope1 * uprime / parameters.uOptimal;
        } else {
            interests = parameters.slope2 * uprime / (BASE_RAY - parameters.uOptimal);
        }
        return interests;
    }

    function revenue(int256 borrow, SCalculateBorrow memory parameters) public view returns(int256) {
        int256 newRate = calculateInterest(borrow, parameters);
        int256 poolManagerFund = parameters.poolManagerAssets;
        int256 newPoolDeposit = borrow + poolManagerFund;
        int256 newCompDeposit = borrow + parameters.totalDeposits;
        int256 newCompBorrowVariable = borrow + parameters.totalVariableDebt;

        int256 f1 = newPoolDeposit * (BASE_RAY - parameters.reserveFactor) / newCompDeposit;
        int256 f2 = (parameters.totalStableDebt * parameters.stableBorrowRate  + newCompBorrowVariable * newRate) / BASE_RAY;
        
        int256 earnings = (f1 * f2) / BASE_RAY;
        int256 cost = (borrow * newRate) / BASE_RAY;
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
    function revenuePrimeVars(int256 borrow, SCalculateBorrow memory parameters) public view returns(SRevenuePrimeVars memory) {
        int256 newRate = calculateInterest(borrow, parameters);
        int256 newRatePrime = calculateInterestPrime(borrow, parameters);

        int256 poolManagerFund = parameters.poolManagerAssets;
        int256 newPoolDeposit = borrow + poolManagerFund;
        int256 newCompDeposit = borrow + parameters.totalDeposits;
        int256 newCompBorrowVariable = borrow + parameters.totalVariableDebt;

        int256 f1 = newPoolDeposit * (BASE_RAY - parameters.reserveFactor) / newCompDeposit;
        int256 f2 = (parameters.totalStableDebt * parameters.stableBorrowRate + newCompBorrowVariable * newRate) / BASE_RAY;

        int256 f1prime = (parameters.totalDeposits - poolManagerFund) * (BASE_RAY - parameters.reserveFactor) / newCompDeposit;
        f1prime = f1prime * BASE_RAY / newCompDeposit;
        int256 f2prime = (newRate * BASE_RAY + newCompBorrowVariable * newRatePrime) / BASE_RAY;

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

    function revenuePrime(int256 borrow, SCalculateBorrow memory parameters) public view returns(int256) {
        SRevenuePrimeVars memory vars = revenuePrimeVars(borrow, parameters);

        int256 f3prime = (vars.newRate * BASE_RAY + borrow * vars.newRatePrime) / BASE_RAY;
        
        int256 f4prime = parameters.rewardBorrow * (parameters.totalStableDebt + parameters.totalVariableDebt) / vars.newCompBorrow;
        f4prime = f4prime * BASE_RAY / vars.newCompBorrow;
        int256 f5prime = parameters.rewardDeposit * (parameters.totalDeposits - vars.poolManagerFund) / vars.newCompDeposit;
        f5prime = f5prime * BASE_RAY / vars.newCompDeposit;
        
        return ((vars.f1prime * vars.f2 + vars.f2prime * vars.f1) / BASE_RAY) - f3prime + f4prime + f5prime;
    }

    function revenuePrime2(int256 borrow, SCalculateBorrow memory parameters) public view returns(int256) {
        int256 newRatePrime2 = calculateInterestPrime2(borrow, parameters);
        SRevenuePrimeVars memory vars = revenuePrimeVars(borrow, parameters);

        int256 derivate;
        {
            int256 f1prime2nd = - (parameters.totalDeposits - vars.poolManagerFund) * (BASE_RAY - parameters.reserveFactor) * 2 / (vars.newCompDeposit);
            f1prime2nd = f1prime2nd * (BASE_RAY) / (vars.newCompDeposit);
            f1prime2nd = f1prime2nd * (BASE_RAY) / (vars.newCompDeposit);

            int256 f2prime2nd = ((vars.newRatePrime * BASE_RAY + vars.newRatePrime * BASE_RAY) + (vars.newCompBorrowVariable) * newRatePrime2) / (BASE_RAY);
            int256 f3prime2nd = ((vars.newRatePrime * BASE_RAY + vars.newRatePrime * BASE_RAY) + (borrow) * newRatePrime2) / (BASE_RAY);

            int256 f4prime2nd = - (parameters.rewardBorrow) * (parameters.totalStableDebt + parameters.totalVariableDebt) * 2 / (vars.newCompBorrow);
            f4prime2nd = f4prime2nd * (BASE_RAY) / (vars.newCompBorrow);
            f4prime2nd = f4prime2nd * (BASE_RAY) / (vars.newCompBorrow);
            int256 f5prime2nd = - (parameters.rewardDeposit) * (parameters.totalDeposits - vars.poolManagerFund) * 2 / (vars.newCompDeposit);
            f5prime2nd = f5prime2nd * (BASE_RAY) / (vars.newCompDeposit);
            f5prime2nd = f5prime2nd * (BASE_RAY) / (vars.newCompDeposit);
            
            derivate = f1prime2nd * vars.f2 + vars.f1prime * vars.f2prime + vars.f2prime * vars.f1prime + f2prime2nd*vars.f1 - f3prime2nd * (BASE_RAY) + (f4prime2nd + f5prime2nd) * (BASE_RAY);
        }

        return derivate / (BASE_RAY);
    }

    function abs(int256 x) private pure returns (int256) {
        return x >= 0 ? x : -x;
    }

    function computeAlpha(int256 count) private view returns(int256) {
        return 0.5 * 10**10;
    }

    function gradientDescent(int256 _borrow, int256 tolerance, SCalculateBorrow memory parameters) public view returns(int256 borrow, int256 count) {
        int256 grad = tolerance + 1;
        count = 0;
        borrow = _borrow;
        while (abs(grad) > tolerance) {
            grad = - revenuePrime(borrow, parameters);
            int256 alpha = computeAlpha(count);
            borrow = borrow - alpha * grad;
            count +=1;
        }
    }

    function newtonRaphson(int256 _borrow, int256 epsilon, int256 tolerance, SCalculateBorrow memory parameters) public view returns(int256 borrow, int256 count) {
        int256 grad = tolerance + 1;
        int256 grad2nd = grad;
        count = 0;
        int256 borrowInit = _borrow;
        borrow = _borrow;
        while (abs(grad2nd) > tolerance && (count == 0 || abs(borrowInit - borrow) > tolerance)) {
            grad = - revenuePrime(borrow, parameters);
            grad2nd = - revenuePrime2(borrow, parameters);
            borrowInit = borrow;
            borrow = borrowInit - grad * BASE_RAY / grad2nd;
            count +=1;
        }
    }

    function computeProfitability(SCalculateBorrow memory parameters) public view {
        console.log("interests");
        console.logInt(calculateInterest(BASE_RAY * 0, parameters));
        console.logInt(calculateInterest(BASE_RAY * 1, parameters));
        console.logInt(calculateInterest(BASE_RAY * 5, parameters));
        console.logInt(calculateInterest(BASE_RAY * 10, parameters));
        console.logInt(calculateInterest(BASE_RAY * 100, parameters));
        console.logInt(calculateInterest(BASE_RAY * 1000, parameters));
        console.logInt(calculateInterest(BASE_RAY * 58749, parameters));
        console.logInt(calculateInterest(BASE_RAY * 100000, parameters));
        console.logInt(calculateInterest(BASE_RAY * 3089873, parameters));
        console.logInt(calculateInterest(BASE_RAY * 28746827, parameters));

        console.log("interests prime");
        console.logInt(calculateInterestPrime(BASE_RAY * 0, parameters));
        console.logInt(calculateInterestPrime(BASE_RAY * 1, parameters));
        console.logInt(calculateInterestPrime(BASE_RAY * 5, parameters));
        console.logInt(calculateInterestPrime(BASE_RAY * 10, parameters));
        console.logInt(calculateInterestPrime(BASE_RAY * 100, parameters));
        console.logInt(calculateInterestPrime(BASE_RAY * 1000, parameters));
        console.logInt(calculateInterestPrime(BASE_RAY * 58749, parameters));
        console.logInt(calculateInterestPrime(BASE_RAY * 100000, parameters));
        console.logInt(calculateInterestPrime(BASE_RAY * 3089873, parameters));
        console.logInt(calculateInterestPrime(BASE_RAY * 28746827, parameters));
        
        console.log("interests prime 2");
        console.logInt(calculateInterestPrime2(BASE_RAY * 0, parameters));
        console.logInt(calculateInterestPrime2(BASE_RAY * 1, parameters));
        console.logInt(calculateInterestPrime2(BASE_RAY * 5, parameters));
        console.logInt(calculateInterestPrime2(BASE_RAY * 10, parameters));
        console.logInt(calculateInterestPrime2(BASE_RAY * 100, parameters));
        console.logInt(calculateInterestPrime2(BASE_RAY * 1000, parameters));
        console.logInt(calculateInterestPrime2(BASE_RAY * 58749, parameters));
        console.logInt(calculateInterestPrime2(BASE_RAY * 100000, parameters));
        console.logInt(calculateInterestPrime2(BASE_RAY * 3089873, parameters));
        console.logInt(calculateInterestPrime2(BASE_RAY * 28746827, parameters));

        console.log("revenue");
        console.logInt(revenue(BASE_RAY * 0, parameters));
        console.logInt(revenue(BASE_RAY * 1, parameters));
        console.logInt(revenue(BASE_RAY * 5, parameters));
        console.logInt(revenue(BASE_RAY * 10, parameters));
        console.logInt(revenue(BASE_RAY * 100, parameters));
        console.logInt(revenue(BASE_RAY * 1000, parameters));
        console.logInt(revenue(BASE_RAY * 58749, parameters));
        console.logInt(revenue(BASE_RAY * 100000, parameters));
        console.logInt(revenue(BASE_RAY * 3089873, parameters));
        console.logInt(revenue(BASE_RAY * 28746827, parameters));

        console.log("revenuePrime");
        console.logInt(revenuePrime(BASE_RAY * 0, parameters));
        console.logInt(revenuePrime(BASE_RAY * 1, parameters));
        console.logInt(revenuePrime(BASE_RAY * 5, parameters));
        console.logInt(revenuePrime(BASE_RAY * 10, parameters));
        console.logInt(revenuePrime(BASE_RAY * 100, parameters));
        console.logInt(revenuePrime(BASE_RAY * 1000, parameters));
        console.logInt(revenuePrime(BASE_RAY * 58749, parameters));
        console.logInt(revenuePrime(BASE_RAY * 100000, parameters));
        console.logInt(revenuePrime(BASE_RAY * 3089873, parameters));
        console.logInt(revenuePrime(BASE_RAY * 28746827, parameters));

        console.log("revenue prime 2");
        console.logInt(revenuePrime2(BASE_RAY * 0, parameters));
        console.logInt(revenuePrime2(BASE_RAY * 1, parameters));
        console.logInt(revenuePrime2(BASE_RAY * 5, parameters));
        console.logInt(revenuePrime2(BASE_RAY * 10, parameters));
        console.logInt(revenuePrime2(BASE_RAY * 100, parameters));
        console.logInt(revenuePrime2(BASE_RAY * 1000, parameters));
        console.logInt(revenuePrime2(BASE_RAY * 58749, parameters));
        console.logInt(revenuePrime2(BASE_RAY * 100000, parameters));
        console.logInt(revenuePrime2(BASE_RAY * 3089873, parameters));
        console.logInt(revenuePrime2(BASE_RAY * 28746827, parameters));

        int256 epsilon = 10**(27-12);
        int256 tolerance = 10**(27-1);
        // gradientDescent(BASE_RAY * 100, epsilon, parameters);
        (int b, int count) = newtonRaphson(168439706352281000000000000000000000, epsilon, tolerance, parameters);
        console.log("newtonRaphson");
        console.logInt(b);
        console.logInt(count);

        // uint256 borrow = BASE_RAY * 0;
        // computeInterestRate
        // uint256 interests = calculateInterest(borrow, parameters);
        // uint256 interests2 = calculateInterestPrime(borrow, parameters);
        // uint256 interests3 = calculateInterestPrime2(borrow, parameters);
        // console.log("interests %s %s", interests, variableBorrowRate);
        // console.log("interests2 %s", interests2);
        // console.log("interests3 %s", interests3);
        // console.log("revenue %s", revenue(borrow, parameters));
        // console.log("revenuePrime %s", revenuePrime(borrow, parameters));
        // console.logInt(revenuePrime2(0, parameters));
    }

    // function test() public {
    //     console.log("balance before %s", want.balanceOf(address(this)));
    //     console.log("balance before %s", aToken.balanceOf(address(this)));
    //     _depositCollateral(99*1e6);
    //     console.log("balance after %s", want.balanceOf(address(this)));
    //     console.log("balance after %s", aToken.balanceOf(address(this)));
    // }
}