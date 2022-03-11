// SPDX-License-Identifier: GPL-3.0

pragma solidity ^0.8.7;

import "../interfaces/mock/IMockUniswapV3Pool.sol";

// Mock uniswap pool to test txs needing oracle rate
contract MockUniswapV3Pool is IMockUniswapV3Pool {
    address public immutable token0;
    address public immutable token1;

    // array of ticks
    int24[65535] public ticks;
    uint256 public idxTick;

    constructor(address inputCur, address outputCur) {
        token0 = inputCur;
        token1 = outputCur;
    }

    // start tick at 0
    function updateNextTick(int24 tick) external {
        require(idxTick < 65535, "MockUniswapPool::updateNextTick: limit idx reached");
        idxTick += 1;
        ticks[idxTick] = tick;
    }

    // we can use this function by using true ticks webscrapped from the mainnet
    // or just generate a range
    function updateAllTick(int24[65535] memory _ticks, uint256 _idxTick) external {
        idxTick = _idxTick;
        ticks = _ticks;
    }

    function observe(uint32[] calldata secondsAgos)
        external
        view
        override
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s)
    {
        // for simplicity we suppose at each seconds there is a new block
        tickCumulatives = new int56[](secondsAgos.length);
        secondsPerLiquidityCumulativeX128s = new uint160[](secondsAgos.length);
        for (uint256 i = 0; i < secondsAgos.length; i++) {
            require(idxTick - secondsAgos[i] >= 0, "MockUniswapPool::observe: looked too far");
            tickCumulatives[i] = ticks[idxTick - secondsAgos[i]];
        }
    }

    function increaseObservationCardinalityNext(uint16 observationCardinalityNext) external override {
        return;
    }
}
