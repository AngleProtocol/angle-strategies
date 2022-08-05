// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.12;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

import "../interfaces/IOracle.sol";

/// @title Marketplace
/// @author Angle Core Team
/*
Inspiration: https://github.com/OlympusDAO/olympus-contracts/blob/main/contracts/BondDepository.sol
// TODO 
- view functions to get the addressable market size as well as the registry
- max order handling -> difference between first index and last index
- check if possible or not to drain funds from other markets
// TODO specify that oracle contract -> safeguards should be placed there
*/
contract Marketplace is ReentrancyGuard {
    using SafeERC20 for IERC20;
    using Address for address;

    uint256 public constant BASE_PARAMS = 10**9;
    uint256 public constant BASE_ORACLE = 10**18;

    struct Order {
        // Amount of tokens brought for the order
        uint256 amount;
        // Time at which the order was created
        uint256 updateTimestamp;
        // Owner of the order which can amend it or remove it
        address owner;
    }

    struct OrderFillingData {
        uint256 marketPrice;
        uint256 totalAmountToGet;
        uint256 leftoverAmount;
        Order lastOrder;
    }

    /// @notice Parameters of a given market: all these parameters are mutable
    struct MarketParams {
        // Oracle contract used to price the tokens
        IOracle oracle;
        // Privileged address of the market which will be able to be matched first
        address privilegedAddress;
        // Timeline to withdraw an order after it's been posted
        uint64 withdrawDeadline;
        // Max number of orders that can be processed in the market
        uint64 maxOrders;
        // Per second increase of the discount if there are more sell orders than buy orders
        uint64 discountIncreaseRate;
        // Per second increase of the premium if there are more sell orders than buy orders
        uint64 premiumIncreaseRate;
        // Maximum discount that can be given on the market price when there are more sell orders than buy orders
        uint64 maxDiscount;
        // Maximum premium that can be given on the market price when there are more sell orders than buy orders
        uint64 maxPremium;
        // Minimum size of a buy order
        uint256 minBuyOrder;
        // Minimum size of a sell order
        uint256 minSellOrder;
    }

    struct MarketStatus {
        uint64 firstIndex;
        uint64 lastIndex;
        uint64 buyOrSell;
        uint64 inversionTimestamp;
        uint256 oracleValue;
        Order[] orders;
    }

    struct Market {
        IERC20 quoteToken;
        IERC20 baseToken;
        MarketParams params;
        MarketStatus status;
    }

    mapping(bytes32 => Market) public markets;
    mapping(bytes32 => mapping(address => uint8)) public approvedParticipants;
    // Nonces for the different market creator
    mapping(address => uint256) public nonces;

    mapping(IERC20 => uint256) public tokenMetadata;

    error InvalidTokens();
    error InvalidMarket();
    error InvalidParam();
    error NotApproved();
    error NotAllowed();
    error NoOpenOrder();
    error TooEarly();
    error TooManyOpenOrders();
    error TooSmallOrder();
    error TooSmallAmountOut();

    event MarketCreated(
        address indexed quoteToken,
        address indexed baseToken,
        address indexed sender,
        uint256 senderNonce,
        bytes32 marketId
    );
    event OracleValueUpdated(bytes32 marketId, uint256 oracleValue);
    event OrderUpdated(bytes32 marketId, address indexed creator, uint256 amount, uint256 orderId, uint64 buyOrSell);

    constructor() {}

    function getOpenOrders(bytes32 marketId) external view returns (Order[] memory, uint64) {
        Market memory market = markets[marketId];
        Order[] memory openOrders = new Order[](market.status.lastIndex - market.status.firstIndex);
        for (uint256 i = market.status.firstIndex; i < market.status.lastIndex; i++) {
            openOrders[i] = market.status.orders[i];
        }
        return (openOrders, market.status.buyOrSell);
    }

    /// Whether it's true, the orderId and whether this order is a buy or sell order
    function hasOpenOrder(bytes32 marketId, address owner)
        external
        view
        returns (
            bool,
            uint64,
            uint64
        )
    {
        Market memory market = markets[marketId];
        (uint256 openOrder, uint64 orderId) = _hasOpenOrder(market, owner);
        return (openOrder == 1, orderId, market.status.buyOrSell);
    }

    function getBuyOrderAmount(bytes32 marketId) external view returns (uint256 amount) {
        Market memory market = markets[marketId];
        if (market.status.buyOrSell == 1) {
            amount = _getOrderAmount(market);
        }
    }

    function getSellOrderAmount(bytes32 marketId) external view returns (uint256 amount) {
        Market memory market = markets[marketId];
        if (market.status.buyOrSell == 0) {
            amount = _getOrderAmount(market);
        }
    }

    function getOrderAmount(bytes32 marketId) external view returns (uint256 amount) {
        Market memory market = markets[marketId];
        amount = _getOrderAmount(market);
    }

    function _getOrderAmount(Market memory market) internal pure returns (uint256 amount) {
        for (uint256 i = market.status.firstIndex; i < market.status.lastIndex; i++) {
            amount += market.status.orders[i].amount;
        }
    }

    function _hasOpenOrder(Market memory market, address owner)
        internal
        pure
        returns (uint256 openOrder, uint64 orderId)
    {
        for (uint256 i = market.status.firstIndex; i < market.status.lastIndex; i++) {
            if (market.status.orders[i].owner == owner) {
                orderId = uint64(i);
                openOrder = 1;
                break;
            }
        }
    }

    function createMarket(
        address quoteToken,
        address baseToken,
        MarketParams memory params
    ) external returns (bytes32 marketId) {
        if (quoteToken == address(0) || baseToken == address(0) || quoteToken == baseToken) revert InvalidTokens();
        uint256 senderNonce = nonces[msg.sender];
        marketId = keccak256(abi.encodePacked(address(quoteToken), address(baseToken), msg.sender, senderNonce));
        nonces[msg.sender] += 1;
        Market storage market = markets[marketId];
        if (address(market.quoteToken) != address(0)) revert InvalidMarket();
        market.quoteToken = IERC20(quoteToken);
        market.baseToken = IERC20(baseToken);
        market.params = params;
        if (tokenMetadata[IERC20(quoteToken)] == 0)
            tokenMetadata[IERC20(quoteToken)] = 10**(IERC20Metadata(quoteToken).decimals());
        if (tokenMetadata[IERC20(baseToken)] == 0)
            tokenMetadata[IERC20(baseToken)] = 10**(IERC20Metadata(baseToken).decimals());
        emit MarketCreated(quoteToken, baseToken, msg.sender, senderNonce, marketId);
    }

    function placeOrder(
        bytes32 marketId,
        uint64 buyOrSell,
        uint256 amount,
        address onBehalfOf,
        uint256 minAmountOut
    )
        external
        nonReentrant
        returns (
            bool,
            uint256,
            uint256
        )
    {
        Market storage market = markets[marketId];
        IERC20 tokenToSend;
        IERC20 tokenToReceive;
        if (buyOrSell == 1) {
            tokenToSend = market.quoteToken;
            tokenToReceive = market.baseToken;
            if (amount < market.params.minBuyOrder) revert TooSmallOrder();
        } else {
            tokenToSend = market.baseToken;
            tokenToReceive = market.quoteToken;
            if (amount < market.params.minSellOrder) revert TooSmallOrder();
        }
        // If the market is invalid, then the `tokenToSend` address is null and this function should revert
        tokenToSend.safeTransferFrom(msg.sender, address(this), amount);
        // If there are no open orders
        if (market.status.inversionTimestamp == 0) {
            uint64 firstIndex;
            if (msg.sender == market.params.privilegedAddress) {
                firstIndex = 0;
            } else {
                firstIndex = 1;
                market.status.orders.push(Order({ amount: 0, updateTimestamp: 0, owner: address(0) }));
            }
            market.status.inversionTimestamp = uint64(block.timestamp);
            market.status.buyOrSell = buyOrSell;
            market.status.orders[firstIndex] = Order({
                amount: amount,
                updateTimestamp: block.timestamp,
                owner: onBehalfOf
            });
            market.status.lastIndex = firstIndex + 1;
            market.status.firstIndex = firstIndex;
            // Reusing the minAmountOut variable for the stack size
            minAmountOut = market.params.oracle.latestAnswer();
            market.status.oracleValue = minAmountOut;
            emit OracleValueUpdated(marketId, minAmountOut);
            emit OrderUpdated(marketId, onBehalfOf, amount, firstIndex, buyOrSell);
            return (false, 0, firstIndex);
        } else if (market.status.buyOrSell == buyOrSell) {
            // If the order is placed in the same direction as the current state of the market, we just add the order
            if (minAmountOut > 0) revert TooSmallAmountOut();
            uint64 orderId;
            // Reusing the `minAmountOut` variable in this case
            (minAmountOut, orderId) = _hasOpenOrder(market, onBehalfOf);
            if (minAmountOut == 1) {
                amount += market.status.orders[orderId].amount;
                market.status.orders[orderId].amount = amount;
                emit OrderUpdated(marketId, onBehalfOf, amount, orderId, buyOrSell);
                return (false, 0, orderId);
            } else {
                if (msg.sender == market.params.privilegedAddress) {
                    orderId = market.status.firstIndex - 1;
                    if (market.status.lastIndex - orderId == market.params.maxOrders) revert TooManyOpenOrders();
                    market.status.orders[orderId] = Order({
                        amount: amount,
                        updateTimestamp: block.timestamp,
                        owner: onBehalfOf
                    });
                    market.status.firstIndex = orderId;
                } else {
                    orderId = market.status.lastIndex;
                    if (orderId + 1 - market.status.firstIndex == market.params.maxOrders) revert TooManyOpenOrders();
                    if (market.status.orders.length == orderId)
                        market.status.orders.push(
                            Order({ amount: amount, updateTimestamp: block.timestamp, owner: onBehalfOf })
                        );
                    else
                        market.status.orders[orderId] = Order({
                            amount: amount,
                            updateTimestamp: block.timestamp,
                            owner: onBehalfOf
                        });
                    market.status.lastIndex = orderId + 1;
                }
                emit OrderUpdated(marketId, onBehalfOf, amount, orderId, buyOrSell);
                return (false, 0, orderId);
            }
        } else {
            OrderFillingData memory orderFilling;
            orderFilling.marketPrice = _computeMarketPrice(market);
            // If we're buying as oracle returns value of baseToken denominated in
            if (buyOrSell == 1)
                orderFilling.totalAmountToGet =
                    (amount * tokenMetadata[tokenToReceive] * BASE_ORACLE) /
                    (orderFilling.marketPrice * tokenMetadata[tokenToSend]);
            else
                orderFilling.totalAmountToGet =
                    (amount * tokenMetadata[tokenToReceive] * orderFilling.marketPrice) /
                    (BASE_ORACLE * tokenMetadata[tokenToSend]);
            // Look if we're filling the orders
            // Order memory orderProcessed;
            orderFilling.leftoverAmount = orderFilling.totalAmountToGet;
            for (uint256 i = market.status.firstIndex; i < market.status.lastIndex; i++) {
                Order memory orderProcessed = market.status.orders[i];
                if (orderProcessed.amount > orderFilling.leftoverAmount) {
                    if (minAmountOut > orderFilling.totalAmountToGet) revert TooSmallAmountOut();
                    // In this case order is filled and we're good
                    // Reusing the amount variable
                    amount = orderProcessed.amount - orderFilling.leftoverAmount;
                    market.status.orders[i].amount = amount;
                    market.status.firstIndex = uint64(i);
                    tokenToReceive.safeTransfer(onBehalfOf, orderFilling.totalAmountToGet);
                    tokenToSend.safeTransfer(orderProcessed.owner, amount);
                    emit OrderUpdated(marketId, orderProcessed.owner, amount, i, 1 - buyOrSell);
                    return (true, orderFilling.totalAmountToGet, type(uint256).max);
                } else {
                    orderFilling.leftoverAmount -= orderProcessed.amount;
                    tokenToSend.safeTransfer(orderProcessed.owner, orderProcessed.amount);
                    emit OrderUpdated(marketId, orderProcessed.owner, 0, i, 1 - buyOrSell);
                }
            }
            // This is the amount of the order we've filled
            amount = orderFilling.totalAmountToGet - orderFilling.leftoverAmount;
            if (minAmountOut > amount) revert TooSmallAmountOut();
            // If we leave the for loop, then this means that we have finished processing all the orders and that an inversion took place
            market.status.inversionTimestamp = uint64(block.timestamp);
            {
                uint256 oracleValue = market.params.oracle.latestAnswer();
                market.status.oracleValue = oracleValue;
                emit OracleValueUpdated(marketId, oracleValue);
            }

            // New status is that of the person
            market.status.buyOrSell = buyOrSell;
            
            uint64 indexId = msg.sender == market.params.privilegedAddress ? 0 : 1;
            market.status.firstIndex = indexId;
            market.status.lastIndex = indexId + 1;

            // We're reusing the totalAmountToGet variable to compute the amount that needs to be left in the order
            // If we're buying, then we need to convert here an amount of base tokens to quoteTokens
            if (buyOrSell == 1)
                orderFilling.totalAmountToGet =
                    (orderFilling.leftoverAmount * tokenMetadata[tokenToSend] * orderFilling.marketPrice) /
                    (BASE_ORACLE * tokenMetadata[tokenToReceive]);
            else
                orderFilling.totalAmountToGet =
                    (orderFilling.leftoverAmount * tokenMetadata[tokenToSend] * BASE_ORACLE) /
                    (orderFilling.marketPrice * tokenMetadata[tokenToReceive]);
            market.status.orders[indexId] = Order({
                amount: orderFilling.totalAmountToGet,
                updateTimestamp: block.timestamp,
                owner: onBehalfOf
            });
            
            emit OrderUpdated(marketId, onBehalfOf,orderFilling.totalAmountToGet, indexId, buyOrSell);
            tokenToSend.safeTransfer(onBehalfOf, amount);
            return (false, amount, indexId);
        }
    }

    function transferOrder(bytes32 marketId, address to) external {
        Market storage market = markets[marketId];
        (uint256 openOrder, uint64 orderId) = _hasOpenOrder(market, msg.sender);
        if (openOrder == 0) revert NoOpenOrder();
        // Privileged address cannot transfer order
        if (market.status.orders[orderId].owner == market.params.privilegedAddress) revert NotAllowed();
        market.status.orders[orderId].owner = to;
        emit OrderUpdated(marketId, to, market.status.orders[orderId].amount, orderId, market.status.buyOrSell);
    }

    function removeOrder(bytes32 marketId, address to) external nonReentrant {
        Market storage market = markets[marketId];
        (uint256 openOrder, uint64 orderId) = _hasOpenOrder(market, msg.sender);
        if (block.timestamp - market.status.orders[orderId].updateTimestamp < market.params.withdrawDeadline)
            revert TooEarly();
        if (openOrder == 0) revert NoOpenOrder();
        // If there is an open order the last index is necessarily greater than 1
        if (market.status.orders[orderId].owner == market.params.privilegedAddress) {
            market.status.firstIndex += 1;
        } else {
            uint64 lastIndex = market.status.lastIndex - 1;
            // Need to loop in order not to break the first arrived first served logic
            for (uint256 i = orderId; i < lastIndex - 1; i++) {
                market.status.orders[i] = market.status.orders[i + 1];
            }
            market.status.lastIndex = lastIndex;
        }
        uint256 amount = market.status.orders[orderId].amount;
        if (market.status.buyOrSell == 1) {
            market.quoteToken.safeTransfer(to, amount);
        } else {
            market.baseToken.safeTransfer(to, amount);
        }
        emit OrderUpdated(marketId, msg.sender, 0, orderId, market.status.buyOrSell);
    }

    function increaseOrder(bytes32 marketId, uint256 amount) external nonReentrant {
        Market storage market = markets[marketId];
        (uint256 openOrder, uint64 orderId) = _hasOpenOrder(market, msg.sender);
        if (openOrder == 0) revert NoOpenOrder();
        uint64 buyOrSell = market.status.buyOrSell;
        if (buyOrSell == 1) market.quoteToken.safeTransferFrom(msg.sender, address(this), amount);
        else market.baseToken.safeTransferFrom(msg.sender, address(this), amount);
        uint256 orderAmount = market.status.orders[orderId].amount + amount;
        emit OrderUpdated(marketId, msg.sender, orderAmount, orderId, buyOrSell);
    }

    function reduceOrder(bytes32 marketId, uint256 amount) external nonReentrant {
        Market storage market = markets[marketId];
        (uint256 openOrder, uint64 orderId) = _hasOpenOrder(market, msg.sender);
        if (openOrder == 0) revert NoOpenOrder();
        uint256 orderAmount = market.status.orders[orderId].amount - amount;
        uint64 buyOrSell = market.status.buyOrSell;
        if (
            (buyOrSell == 1 && (orderAmount < market.params.minBuyOrder)) ||
            (buyOrSell == 0 && (orderAmount < market.params.minSellOrder))
        ) revert TooSmallOrder();
        market.status.orders[orderId].amount = orderAmount;
        if (buyOrSell == 1) market.quoteToken.safeTransfer(msg.sender, amount);
        else market.baseToken.safeTransfer(msg.sender, amount);
        emit OrderUpdated(marketId, msg.sender, orderAmount, orderId, buyOrSell);
    }

    function computeMarketPrice(bytes32 marketId) external view returns (uint256) {
        Market memory market = markets[marketId];
        return _computeMarketPrice(market);
    }

    function _computeMarketPrice(Market memory market) internal view returns (uint256 marketPrice) {
        uint256 elapsed = market.status.inversionTimestamp == 0
            ? 0
            : block.timestamp - market.status.inversionTimestamp;
        marketPrice = market.status.oracleValue;
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

    function resetMarketPrice(bytes32 marketId) external {
        Market storage market = markets[marketId];
        uint256 currentMarketPrice = _computeMarketPrice(market);
        uint256 oracleValue = market.params.oracle.latestAnswer();
        uint256 buyOrSell = market.status.buyOrSell;
        if (
            (buyOrSell == 1 && oracleValue > currentMarketPrice) || (buyOrSell == 0 && oracleValue < currentMarketPrice)
        ) {
            market.status.oracleValue = oracleValue;
            emit OracleValueUpdated(marketId, oracleValue);
        }
    }

    function transferPrivilegedOwnership(bytes32 marketId, address to) external {
        Market storage market = markets[marketId];
        // You cannot have open order when transferring ownership
        (uint256 openOrder, ) = _hasOpenOrder(market, msg.sender);
        if (market.params.privilegedAddress != msg.sender || openOrder == 1) revert NotAllowed();
        market.params.privilegedAddress = to;
    }
}
