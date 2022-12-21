// SPDX-License-Identifier: GPL-3.0

pragma solidity ^0.8.17;

import "../../../../interfaces/external/euler/IEulerStakingRewards.sol";
import "../../../../interfaces/external/uniswap/IUniswapV3Pool.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import "./GenericEuler.sol";
import "../../../../utils/OracleMath.sol";

/// @title GenericEulerStaker
/// @author  Angle Core Team
/// @notice `GenericEuler` with staking to earn EUL incentives
abstract contract GenericEulerStaker is GenericEuler, OracleMath {
    using SafeERC20 for IERC20;
    using Address for address;

    // ================================= CONSTANTS =================================
    uint256 internal constant _SECONDS_IN_YEAR = 365 days;

    uint32 internal constant _TWAP_PERIOD = 1 minutes;

    // ================================ CONSTRUCTOR ================================

    /// @notice Wrapper built on top of the `initializeEuler` method to initialize the contract
    function _initializeStaker(
        address _strategy,
        string memory _name,
        address[] memory governorList,
        address guardian,
        address[] memory keeperList
    ) internal {
        initializeEuler(_strategy, _name, governorList, guardian, keeperList);
        IERC20(address(eToken)).safeApprove(address(_eulerStakingContract()), type(uint256).max);
    }

    // ============================= EXTERNAL FUNCTION =============================

    /// @notice Claim earned EUL
    function claimRewards() external {
        _eulerStakingContract().getReward();
    }

    // ============================= VIRTUAL FUNCTIONS =============================

    /// @notice Implementation of the `_stake` function to stake eToken in the Euler staking contract
    function _stake(uint256 amount) internal override returns (uint256) {
        _eulerStakingContract().stake(amount);
        return amount;
    }

    /// @notice Implementation of the `_unstake` function
    function _unstake(uint256 amount, uint256 rate) internal override returns (uint256) {
        // TODO Possible that with rounding we don't have a balance large enough?
        // just test whether the staked balance is strictly smaller than amount `amountInEToken``
        // and take a lower bound?
        if (rate == 0) {
            // choose large underlying amount to not have a null exchange rate
            uint256 fakeUnderlyingAmount = 10**20;
            uint256 amountInEToken = eToken.convertUnderlyingToBalance(fakeUnderlyingAmount);
            rate = (fakeUnderlyingAmount * 10**18) / amountInEToken;
        }
        uint256 maxAmountEToken = _eulerStakingContract().balanceOf(address(this));
        uint256 upperBoundEToken = (amount * 10**18 + (rate - 1)) / rate;
        // uint256 upperBoundEToken = eToken.convertUnderlyingToBalance(amount) + 1;
        if (upperBoundEToken > maxAmountEToken) upperBoundEToken = maxAmountEToken;
        _eulerStakingContract().withdraw(upperBoundEToken);
        return upperBoundEToken;
    }

    /// @notice Get current staked balance
    /// @return amount Lower bound on balance staked
    /// @return rate Exchange rate eToken<>Token
    function _stakedBalance() internal view override returns (uint256 amount, uint256 rate) {
        uint256 amountInEToken = _eulerStakingContract().balanceOf(address(this));
        uint256 fakeBalanceAmount = 10**27;
        amount = eToken.convertBalanceToUnderlying(fakeBalanceAmount);
        rate = (amount * 10**18) / fakeBalanceAmount;
        console.log("amount staker ", (amountInEToken * rate) / 10**18);
        amount = (amountInEToken * rate - (rate - 1)) / 10**18;
        console.log("lower bound amount staker ", amount, rate);
    }

    /// @notice Get stakingAPR after staking an additional `amount`
    /// @param amount Virtual amount to be staked
    function _stakingApr(uint256 amount) internal view override returns (uint256 apr) {
        uint256 newTotalSupply = _eulerStakingContract().totalSupply() + amount;
        // APRs are in 1e18 and a 5% penalty on the EUL price is taken to avoid overestimations
        // `_estimatedEulToWant()` and eTokens are in base 18
        apr =
            (_estimatedEulToWant(_eulerStakingContract().rewardRate() * _SECONDS_IN_YEAR) * 9500 * 1 ether) /
            10000 /
            newTotalSupply;
    }

    // ============================= INTERNAL FUNCTIONS ============================

    /// @notice Estimates the amount of `want` we will get out by swapping it for EUL
    /// @param quoteAmount The amount to convert in the out-currency
    /// @return The value of the `quoteAmount` expressed in out-currency
    /// @dev Uses both Uniswap TWAP and Chainlink spot price
    function _estimatedEulToWant(uint256 quoteAmount) internal view returns (uint256) {
        uint32[] memory secondAgos = new uint32[](2);

        secondAgos[0] = _TWAP_PERIOD;
        secondAgos[1] = 0;

        (IUniswapV3Pool pool, uint8 isUniMultiplied) = _poolAndMultiply();
        (int56[] memory tickCumulatives, ) = pool.observe(secondAgos);
        int56 tickCumulativesDelta = tickCumulatives[1] - tickCumulatives[0];

        int24 timeWeightedAverageTick = int24(tickCumulativesDelta / int32(_TWAP_PERIOD));

        // Always round to negative infinity
        if (tickCumulativesDelta < 0 && (tickCumulativesDelta % int56(int32(_TWAP_PERIOD)) != 0))
            timeWeightedAverageTick--;

        // Computing the `quoteAmount` from the ticks obtained from Uniswap
        uint256 amountInETH = _getQuoteAtTick(timeWeightedAverageTick, quoteAmount, isUniMultiplied);

        (, int256 ethPriceUSD, , , ) = _chainlinkOracleEUL().latestRoundData();
        // ethPriceUSD is in base 8
        return (uint256(ethPriceUSD) * amountInETH) / 1e8;
    }

    // ============================= VIRTUAL FUNCTIONS =============================

    /// @notice Return pool used as oracle and whether we should multiply or divide to get the price
    function _eulerStakingContract() internal view virtual returns (IEulerStakingRewards);

    /// @notice Return pool used as oracle and whether we should multiply or divide to get the price
    function _poolAndMultiply() internal view virtual returns (IUniswapV3Pool, uint8) {
        return (IUniswapV3Pool(0xB003DF4B243f938132e8CAdBEB237AbC5A889FB4), 0);
    }

    /// @notice Return Chainlink oracle used to price the out token of the Uniswap pool
    function _chainlinkOracleEUL() internal view virtual returns (AggregatorV3Interface) {
        return AggregatorV3Interface(0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419);
    }
}
