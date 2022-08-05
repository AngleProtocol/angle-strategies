// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.12;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import "../interfaces/IOracle.sol";

/// @title Marketplace
/// @author Angle Core Team
/*
Inspiration: https://github.com/OlympusDAO/olympus-contracts/blob/main/contracts/BondDepository.sol
// TODO
- reentrancy guard -> cannot work if that's the case
- permissioned toggle to participate in the market
- 
*/
contract Marketplace {
    using SafeERC20 for IERC20;
    using Address for address;

    uint256 public constant MAX_ORDER_COUNT = 20;
    uint256 public constant BASE_PARAMS = 10**9;
    uint256 public constant BASE_ORACLE = 10**18;

    struct Order {
        uint256 amount;
        address owner;
    }

    struct MarketParams {
        IOracle oracle;
        address owner;
        uint64 discountIncreaseRate;
        uint64 premiumIncreaseRate;
        uint64 maxDiscount;
        uint64 maxPremium;
        uint256 minBuyOrder;
        uint256 minSellOrder;
    }

    struct MarketStatus {
        uint64 firstIndex;
        uint64 lastIndex;
        uint64 buyOrSell;
        uint64 inversionTimestamp;
        Order[MAX_ORDER_COUNT] orders;
    }

    struct Market {
        IERC20 quoteToken;
        IERC20 baseToken;
        MarketParams params;
        MarketStatus status;
    }

    mapping(bytes32 => Market) public markets;

    mapping(bytes32 => mapping(uint256 => Order)) public orders;

    mapping(IERC20 => uint256) public tokenMetadata;

    error InvalidTokens();
    error InvalidMarket();
    error InvalidParam();
    error NotOwner();
    error TooManyOrders();
    error TooSmallOrder();

    event MarketCreated(address indexed quoteToken, address indexed baseToken, address indexed owner, address sender);
    event SetMarketUintParam(bytes32 marketId, uint256 param, bytes32 what);

    constructor() {}

    modifier onlyOwner(bytes32 marketId) {
        if (markets[marketId].params.owner != msg.sender) revert NotOwner();
        _;
    }

    // TODO get open orders, get total buy order amount, total sell order amount

    function createMarket(
        address quoteToken,
        address baseToken,
        MarketParams memory params
    ) external returns (bytes32 marketId) {
        if (quoteToken == address(0) || baseToken == address(0) || quoteToken == baseToken) revert InvalidTokens();
        marketId = keccak256(abi.encodePacked(address(quoteToken), address(baseToken), params.owner, msg.sender));
        Market storage market = markets[marketId];
        if (address(market.quoteToken) != address(0)) revert InvalidMarket();
        market.quoteToken = IERC20(quoteToken);
        market.baseToken = IERC20(baseToken);
        market.params = params;
        if(tokenMetadata[IERC20(quoteToken)] == 0) tokenMetadata[IERC20(quoteToken)] = 10**(IERC20Metadata(quoteToken).decimals());
        if(tokenMetadata[IERC20(baseToken)] == 0) tokenMetadata[IERC20(baseToken)] = 10**(IERC20Metadata(baseToken).decimals());
        emit MarketCreated(quoteToken, baseToken, params.owner, msg.sender);
    }

    function placeOrder(
        bytes32 marketId,
        uint64 buyOrSell,
        uint256 amount,
        address onBehalfOf
    )
        external
        returns (
            bool,
            uint256,
            uint256
        )
    {
        Market storage market = markets[marketId];
        if (address(market.quoteToken) != address(0)) revert InvalidMarket();
        // TODO min buy order or min sell order size
        IERC20 tokenToSend;
        IERC20 tokenToReceive;
        if(buyOrSell == 1) {
            tokenToSend = market.quoteToken;
            tokenToReceive = market.baseToken;
            if(amount > market.params.minBuyOrder) revert TooSmallOrder();
        } else {
            tokenToSend = market.baseToken;
            tokenToReceive = market.quoteToken;
            if(amount > market.params.minSellOrder) revert TooSmallOrder();
        }
        tokenToSend.safeTransferFrom(msg.sender, address(this), amount);
        // If there are no open orders    
        if (market.status.inversionTimestamp == 0) {
            market.status.inversionTimestamp = uint64(block.timestamp);
            market.status.buyOrSell = buyOrSell;
            market.status.orders[0] = Order({ amount: amount, owner: onBehalfOf });
            return (false, 0, 0);
        }
        // If the order is placed in the same direction as the current state of the market, we just add the order
        if (market.status.buyOrSell == buyOrSell) {
            uint64 lastIndex = market.status.lastIndex;
            if (lastIndex == MAX_ORDER_COUNT - 1) revert TooManyOrders();
            lastIndex += 1;
            market.status.orders[lastIndex] = Order({ amount: amount, owner: onBehalfOf });
            market.status.lastIndex = lastIndex;
            return (false, 0, lastIndex);
        } else {
            uint256 marketPrice = _computeMarketPrice(market);
            uint256 amountToGet;
            // If we're buying as oracle returns value of baseToken denominated in 
            if(buyOrSell == 1) amountToGet = amount * tokenMetadata[tokenToReceive] * BASE_ORACLE  / (marketPrice * tokenMetadata[tokenToSend]);
            else amountToGet = amount * tokenMetadata[tokenToReceive] * marketPrice / (BASE_ORACLE * tokenMetadata[tokenToSend]);
            // Look if we're filling the orders
            uint64 firstIndex = market.status.firstIndex;
            Order memory orderProcessed;
            uint256 leftoverAmount = amountToGet;
            for(uint256 i=firstIndex; i<=market.status.lastIndex; i++) {
                orderProcessed = market.status.orders[i];
                if (orderProcessed.amount > leftoverAmount) {
                    // In this case order is filled and we're good
                    uint256 orderAmount = orderProcessed.amount - leftoverAmount;
                    market.status.orders[i].amount = orderAmount;
                    market.status.firstIndex = uint64(i);
                    tokenToReceive.safeTransfer(onBehalfOf, amountToGet);
                    tokenToSend.safeTransfer(orderProcessed.owner, orderAmount);
                    return (true, amountToGet, type(uint256).max);
                } else {
                    leftoverAmount -= orderProcessed.amount;
                    tokenToSend.safeTransfer(orderProcessed.owner, orderProcessed.amount);
                }
            }
            uint256 amountToSend = amountToGet - leftoverAmount;
            // If we leave the for loop, then this means that we have finished processing all the orders and that an inversion took place
            market.status.inversionTimestamp = uint64(block.timestamp);
            // New status is that of the person
            market.status.buyOrSell = buyOrSell;
            market.status.firstIndex = 0;
            market.status.lastIndex = 0;
            // We're reusing the amountToGet variable to compute the amount that needs to be left in the order
            // If we're buying, then we need to convert here an amount of base tokens to quoteTokens
            if(buyOrSell == 1) amountToGet = amountToSend * tokenMetadata[tokenToSend] * marketPrice / (BASE_ORACLE * tokenMetadata[tokenToReceive]);
            else amountToGet = amountToSend * tokenMetadata[tokenToSend] * BASE_ORACLE  / (marketPrice * tokenMetadata[tokenToReceive]);
            market.status.orders[0] = Order({
                amount: amountToGet,
                owner: onBehalfOf
            });
            tokenToSend.safeTransfer(onBehalfOf, amountToSend);
            return(false, amountToSend,0);
        }
    }

    function computeMarketPrice(bytes32 marketId) external view returns (uint256) {
        Market memory market = markets[marketId];
        return _computeMarketPrice(market);
    }

    function _computeMarketPrice(Market memory market) internal view returns (uint256 marketPrice) {
        uint256 elapsed = market.status.inversionTimestamp == 0
            ? 0
            : block.timestamp - market.status.inversionTimestamp;
        marketPrice = market.params.oracle.read();
        if (market.status.buyOrSell == 1) {
            uint256 premium = elapsed * market.params.premiumIncreaseRate;
            premium = premium > market.params.maxPremium ? market.params.maxPremium : premium;
            marketPrice = (marketPrice * (BASE_PARAMS + premium)) / BASE_PARAMS;
        } else {
            uint256 discount = elapsed * market.params.discountIncreaseRate;
            discount = discount > market.params.maxDiscount ? market.params.maxDiscount : discount;
            marketPrice = (marketPrice * (BASE_PARAMS - discount)) / BASE_PARAMS;
        }
    }

    function setMarketUintParam(
        bytes32 marketId,
        uint256 param,
        bytes32 what
    ) external {
        Market storage market = markets[marketId];
        if (market.params.owner != msg.sender) revert NotOwner();
        if (what == "DIR") market.params.discountIncreaseRate = uint64(param);
        else if (what == "PIR") market.params.premiumIncreaseRate = uint64(param);
        else if (what == "MD") market.params.maxDiscount = uint64(param);
        else if (what == "MP") market.params.maxPremium = uint64(param);
        else if (what == "MBO") market.params.minBuyOrder = param;
        else if (what == "MSO") market.params.minSellOrder = param;
        else revert InvalidParam();
        emit SetMarketUintParam(marketId, param, what);
    }

    function setMarketAddressParam(
        bytes32 marketId,
        address param,
        bytes32 what
    ) external {
        Market storage market = markets[marketId];
        if (market.params.owner != msg.sender) revert NotOwner();
        if (what == "OW") market.params.owner = param;
        else if (what == "OR") market.params.oracle = IOracle(param);
        else revert InvalidParam();
    }
}
