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
contract GenericEulerStaker is GenericEuler, OracleMath {
    using SafeERC20 for IERC20;
    using Address for address;

    // ================================= CONSTANTS =================================
    uint256 internal constant _SECONDS_IN_YEAR = 365 days;
    uint32 internal constant _TWAP_PERIOD = 1 minutes;

    // ================================= VARIABLES =================================
    IEulerStakingRewards public eulerStakingContract;
    AggregatorV3Interface public chainlinkOracle;
    IUniswapV3Pool public pool;
    uint8 public isUniMultiplied;

    // ================================ CONSTRUCTOR ================================

    /// @notice Wrapper built on top of the `initializeEuler` method to initialize the contract
    function initialize(
        address _strategy,
        string memory _name,
        address[] memory governorList,
        address guardian,
        address[] memory keeperList,
        IEulerStakingRewards _eulerStakingContract,
        AggregatorV3Interface _chainlinkOracle,
        IUniswapV3Pool _pool,
        uint8 _isUniMultiplied
    ) external {
        initializeEuler(_strategy, _name, governorList, guardian, keeperList);
        eulerStakingContract = _eulerStakingContract;
        chainlinkOracle = _chainlinkOracle;
        pool = _pool;
        isUniMultiplied = _isUniMultiplied;
        IERC20(address(eToken)).safeApprove(address(_eulerStakingContract), type(uint256).max);
    }

    // ============================= EXTERNAL FUNCTION =============================

    /// @notice Claim earned EUL
    function claimRewards() external {
        eulerStakingContract.getReward();
    }

    // ============================= VIRTUAL FUNCTIONS =============================

    /// @inheritdoc GenericEuler
    function _stakeAll() internal override {
        eulerStakingContract.stake(eToken.balanceOf(address(this)));
    }

    /// @inheritdoc GenericEuler
    function _unstake(uint256 amount) internal override returns (uint256 eTokensUnstaked) {
        // Take an upper bound as when withdrawing from Euler there could be rounding issue
        eTokensUnstaked = eToken.convertUnderlyingToBalance(amount) + 1;
        eulerStakingContract.withdraw(eTokensUnstaked);
    }

    /// @inheritdoc GenericEuler
    function _stakedBalance() internal view override returns (uint256 amount) {
        uint256 amountInEToken = eulerStakingContract.balanceOf(address(this));
        amount = eToken.convertBalanceToUnderlying(amountInEToken);
    }

    /// @inheritdoc GenericEuler
    function _stakingApr(int256 amount) internal view override returns (uint256 apr) {
        uint256 periodFinish = eulerStakingContract.periodFinish();
        uint256 newTotalSupply = eulerStakingContract.totalSupply();
        if (amount >= 0) newTotalSupply += eToken.convertUnderlyingToBalance(uint256(amount));
        else newTotalSupply -= eToken.convertUnderlyingToBalance(uint256(-amount));
        if (periodFinish <= block.timestamp || newTotalSupply == 0) return 0;
        // APRs are in 1e18 and a 5% penalty on the EUL price is taken to avoid overestimations
        // `_estimatedEulToWant()` and eTokens are in base 18
        apr =
            (_estimatedEulToWant(eulerStakingContract.rewardRate() * _SECONDS_IN_YEAR) * 9500 * 1 ether) /
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

        (int56[] memory tickCumulatives, ) = pool.observe(secondAgos);
        int56 tickCumulativesDelta = tickCumulatives[1] - tickCumulatives[0];

        int24 timeWeightedAverageTick = int24(tickCumulativesDelta / int32(_TWAP_PERIOD));

        // Always round to negative infinity
        if (tickCumulativesDelta < 0 && (tickCumulativesDelta % int56(int32(_TWAP_PERIOD)) != 0))
            timeWeightedAverageTick--;

        // Computing the `quoteAmount` from the ticks obtained from Uniswap
        uint256 amountInBase = _getQuoteAtTick(timeWeightedAverageTick, quoteAmount, isUniMultiplied);
        return _quoteOracleEUL(amountInBase);
    }

    // ============================= VIRTUAL FUNCTIONS =============================

    /// @notice Return quote amount of the EUL amount
    function _quoteOracleEUL(uint256 amount) internal view virtual returns (uint256 quoteAmount) {
        // no stale checks are made as it is only used to estimate the staking APR
        (, int256 ethPriceUSD, , , ) = chainlinkOracle.latestRoundData();
        // ethPriceUSD is in base 8
        return (uint256(ethPriceUSD) * amount) / 1e8;
    }
}
