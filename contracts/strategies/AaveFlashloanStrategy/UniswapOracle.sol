// SPDX-License-Identifier: MIT

pragma solidity 0.8.7;

import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import "@uniswap/v3-core/contracts/libraries/FixedPoint96.sol";
import "./UniswapOracleMath.sol";

/// @title UniswapUtils
/// @author Angle Core Team
/// @notice Utility contract that is used in the Uniswap module contract
contract UniswapUtils is OracleMath {
    /// @notice Gets a quote for an amount of in-currency using UniswapV3 TWAP and converts this
    /// amount to out-currency
    /// @param quoteAmount The amount to convert in the out-currency
    /// @param pool UniswapV3 pool to query
    /// @param isUniMultiplied Whether the rate corresponding to the Uniswap pool should be multiplied or divided
    /// @return The value of the `quoteAmount` expressed in out-currency
    function _readUniswapPool(
        uint256 quoteAmount,
        IUniswapV3Pool pool,
        uint32 twapPeriod,
        uint8 isUniMultiplied
    ) internal view returns (uint256) {
        uint32[] memory secondAgos = new uint32[](2);

        secondAgos[0] = twapPeriod;
        secondAgos[1] = 0;

        (int56[] memory tickCumulatives, ) = pool.observe(secondAgos);
        int56 tickCumulativesDelta = tickCumulatives[1] - tickCumulatives[0];

        int24 timeWeightedAverageTick = int24(tickCumulativesDelta / int32(twapPeriod));

        // Always round to negative infinity
        if (tickCumulativesDelta < 0 && (tickCumulativesDelta % int56(int32(twapPeriod)) != 0))
            timeWeightedAverageTick--;

        // Computing the `quoteAmount` from the ticks obtained from Uniswap
        return _getQuoteAtTick(timeWeightedAverageTick, quoteAmount, isUniMultiplied);
    }
}

/// @title ModuleUniswapMulti
/// @author Angle Core Team
/// @notice Module Contract that is going to be used to help compute Uniswap prices
/// @dev This contract will help for an oracle using multiple UniswapV3 pools
/// @dev An oracle using Uniswap is either going to be a `ModuleUniswapSingle` or a `ModuleUniswapMulti`
contract UniswapOracle is UniswapUtils {
    /// @notice Uniswap pools, the order of the pools to arrive to the final price should be respected
    IUniswapV3Pool[] public circuitUniswap;
    /// @notice Whether the rate obtained with each pool should be multiplied or divided to the current amount
    uint8[] public circuitUniIsMultiplied;

    /// @notice Constructor for an oracle using multiple Uniswap pool
    /// @param _circuitUniswap Path of the Uniswap pools
    /// @param _circuitUniIsMultiplied Whether we should multiply or divide by this rate in the path
    /// @param observationLength Number of observations that each pool should have stored
    constructor(
        IUniswapV3Pool[] memory _circuitUniswap,
        uint8[] memory _circuitUniIsMultiplied,
        uint16 observationLength
    ) {
        uint256 circuitUniLength = _circuitUniswap.length;
        require(circuitUniLength > 0, "103");
        require(circuitUniLength == _circuitUniIsMultiplied.length, "104");

        circuitUniswap = _circuitUniswap;
        circuitUniIsMultiplied = _circuitUniIsMultiplied;

        for (uint256 i = 0; i < circuitUniLength; i++) {
            circuitUniswap[i].increaseObservationCardinalityNext(observationLength);
        }
    }

    /// @notice Reads Uniswap current block oracle rate
    /// @param quoteAmount The amount in the in-currency base to convert using the Uniswap oracle
    /// @return The value of the oracle of the initial amount is then expressed in the decimal from
    /// the end currency
    function quoteUniswap(uint256 quoteAmount, uint32 twapPeriod) public view returns (uint256) {
        for (uint256 i = 0; i < circuitUniswap.length; i++) {
            quoteAmount = _readUniswapPool(quoteAmount, circuitUniswap[i], twapPeriod, circuitUniIsMultiplied[i]);
        }
        // The decimal here is the one from the end currency
        return quoteAmount;
    }
}
