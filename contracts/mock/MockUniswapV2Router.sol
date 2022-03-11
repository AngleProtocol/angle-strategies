// SPDX-License-Identifier: GPL-3.0

pragma solidity ^0.8.7;

import "../interfaces/external/uniswap/IUniswapRouter.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Mock contract to get access to the price of a token
contract MockUniswapV2Router is IUniswapV2Router {
    using SafeERC20 for IERC20;
    uint256 public price;

    constructor(uint256 _price) {
        price = _price;
    }

    function getAmountsOut(uint256 amountIn, address[] calldata) external view override returns (uint256[] memory) {
        uint256[] memory result = new uint256[](1);
        // Assumes same basis between want and COMP or AAVE (like 18)
        // And price should be a small amount like 10 -> a price of 10
        result[0] = price * amountIn;
        return result;
    }

    function setPrice(uint256 _price) external {
        price = _price;
    }

    function swapExactTokensForTokens(
        uint256 swapAmount,
        uint256 minAmount,
        address[] calldata path,
        address,
        uint256
    ) external override {
        IERC20(path[0]).safeTransferFrom(msg.sender, address(this), swapAmount);
        require(swapAmount * price >= minAmount, "15");
        IERC20(path[path.length - 1]).safeTransfer(msg.sender, swapAmount * price);
    }
}
