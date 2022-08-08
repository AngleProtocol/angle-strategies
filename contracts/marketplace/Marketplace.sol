// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.12;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

import "../interfaces/IOracle.sol";

/// @title Marketplace
/// @author Angle Core Team
/// @notice A permissionless contract for token exchanges using an oracle and variable discounts
/*
Inspiration: https://github.com/OlympusDAO/olympus-contracts/blob/main/contracts/BondDepository.sol
// TODO 
- make it compatible with events
*/
contract Marketplace is ReentrancyGuard {
    using SafeERC20 for IERC20;
    using Address for address;

    uint256 public constant BASE_PARAMS = 10**9;
    uint256 public constant BASE_ORACLE = 10**18;

    // ================================ Structs ====================================

    /// @notice Order data
    struct Order {
        // Amount of tokens brought for the order
        uint256 amount;
        // Time at which the order was created
        uint256 updateTimestamp;
        // Owner of the order which can amend it or remove it
        address owner;
    }

    /// @notice Parameters of a given market: all these parameters are immutable except for the `privilegedAddress` one
    struct MarketParams {
        // Oracle contract used to price the base tokens in value of quote tokens: if 1 ETH = 2000 EUR, then
        // oracle = 2000 * BASE_ORACLE
        // This should be an external trusted contract and if this oracle came to fail, then the whole associated market
        // could fail, as such it's important to place the right safeguards in the corresponding oracle contract
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

    /// @notice Current market status indicators
    struct MarketStatus {
        // Current orders waiting to be filled: elements are never erased from this list, and so current live
        // orders are stored in the [firstIndex,lastIndex[ interval
        Order[] orders;
        // Current oracle value (potentially discounted or increased with a premium)
        uint256 oracleValue;
        // Index in the orders list of the first valid order
        uint64 firstIndex;
        // First non valid index in the orders list
        uint64 lastIndex;
        // Whether orders are buy orders or sell orders: both cannot coexist at the same time
        // = 1 if orders are buy orders, 0 otherwise
        uint64 buyOrSell;
        // Timestamp at which the market start getting more buy than sell orders (or conversely)
        uint64 inversionTimestamp;
    }

    /// @notice All the data about a market
    struct Market {
        // In a ETH/agEUR pair, quote token is agEUR
        IERC20 quoteToken;
        // In a ETH/agEUR pair, base token is ETH
        IERC20 baseToken;
        // Market parameters
        MarketParams params;
        // Market status indicators
        MarketStatus status;
    }

    // =============================== Mappings ====================================

    /// @notice Maps a `marketId` to its associated parameters and data
    mapping(bytes32 => Market) public markets;

    /// @notice Nonces for the different market creator
    mapping(address => uint256) public nonces;

    /// @notice Maps a token to 10**(token decimals): we store it here in a mapping to avoid calling token contracts
    /// everytime we interact with a token
    mapping(IERC20 => uint256) public tokenMetadata;

    // ================================ Errors =====================================

    error InvalidParameters();
    error NotAllowed();
    error NoOpenOrder();
    error TooEarly();
    error TooManyOpenOrders();
    error TooSmallOrder();
    error TooSmallAmountOut();

    // ================================ Events =====================================

    event MarketCreated(
        address indexed quoteToken,
        address indexed baseToken,
        address indexed sender,
        uint256 senderNonce,
        bytes32 marketId
    );
    event OracleValueUpdated(bytes32 marketId, uint256 oracleValue);
    event OrderUpdated(bytes32 marketId, address indexed creator, uint256 amount, uint256 orderId, uint64 buyOrSell);

    /// @notice Constructor of the contract
    /// @dev This is a completely permissionless immutable contract so there's no parameter needed
    /// when deploying it
    constructor() {}

    // ============================== View functions ===============================

    /// @notice Returns the list of all the open orders of a market and whether these orders are buy or sell
    /// orders
    /// @return Order list
    /// @return 1 if the orders are buy orders, 0 otherwise
    /// @dev There can only be buy orders or sell orders, but never both at the same time
    function getOpenOrders(bytes32 marketId) external view returns (Order[] memory, uint64) {
        Market memory market = markets[marketId];
        Order[] memory openOrders = new Order[](market.status.lastIndex - market.status.firstIndex);
        for (uint256 i = market.status.firstIndex; i < market.status.lastIndex; i++) {
            openOrders[i] = market.status.orders[i];
        }
        return (openOrders, market.status.buyOrSell);
    }

    /// Whether it's true, the orderId and whether this order is a buy or sell order
    /// @notice Checks whether `owner` has an open order on `marketId`
    /// @return Whether the `owner` address has an open order or not
    /// @return In case the address has an open order, the ID of the order, that is to say the index
    /// in the list of orders associated to the market of the order. If there's no open order, value returned
    /// will be `type(uint64).max`
    /// @return 1 if the order is a buy order, 0 if it's a sell
    /// @dev An address can only have one open order in a market
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
        (bool openOrder, uint64 orderId) = _hasOpenOrder(market, owner);
        return (openOrder, orderId, market.status.buyOrSell);
    }

    /// @notice Gets the sum of the amounts of all the buy orders in the market
    /// @dev Amount returned will be 0 if there's no buy orders in the market
    function getBuyOrderAmount(bytes32 marketId) external view returns (uint256 amount) {
        Market memory market = markets[marketId];
        if (market.status.buyOrSell == 1) {
            amount = _getOrderAmount(market);
        }
    }

    /// @notice Gets the sum of the amounts of all the sell orders in the market
    /// @dev Amount returned will be 0 if there's no sell orders in the market
    function getSellOrderAmount(bytes32 marketId) external view returns (uint256 amount) {
        Market memory market = markets[marketId];
        if (market.status.buyOrSell == 0) {
            amount = _getOrderAmount(market);
        }
    }

    /// @notice Gets the sum of all the orders in the market and if these orders are buy orders or sell orders
    function getOrderAmount(bytes32 marketId) external view returns (uint256 amount, uint64 buyOrSell) {
        Market memory market = markets[marketId];
        amount = _getOrderAmount(market);
        buyOrSell = market.status.buyOrSell;
    }

    /// @notice Computes the current price in the market `marketId`
    /// @dev This takes into account of the oracle value as well as the discount/premium on this price
    /// based on the imbalance between buy and sell orders
    function computeMarketPrice(bytes32 marketId) external view returns (uint256) {
        Market memory market = markets[marketId];
        return _computeMarketPrice(market);
    }

    // ============================ Market Interaction =============================

    /// @notice Places on order on a market and either executes it or places it on the waiting list
    /// @param marketId Id of the market on which the order should be placed
    /// @param buyOrSell Should be 1 if for a buy order, 0 for a sell order
    /// @param amount Amount of tokens to bring to acquire the desired token: for instance if the market is ETH/USDC
    /// and I place a buy order, then if `amount = 10**6`, I am bringing 1 USDC to buy ETH
    /// @param onBehalfOf For who this order is placed: this is the address which will receive the token bought through this contract
    /// @param minAmountOut For taker orders (orders that execute other orders), this serves as a slippage protection. For instance,
    /// if the market is ETH/USDC and there are pending orders to sell ETH, and I am making an order to buy ETH, then if `minAmountOut = 10**18`,
    /// then the function will revert if I get less than 1 ETH from my order
    /// @return Whether the order was fully executed: if I bring 1 USDC, but given current market conditions I can only buy ETH using 0.5 USDC
    /// then it's considered that the order is not fully executed
    /// @return Amount of tokens obtained from the order execution
    /// @return Id of the order in the contract if my order has not been fully executed and still pending in the contract
    /// @dev This function checks
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

        // Handling the case with no open orders
        if (market.status.inversionTimestamp == 0) {
            uint64 orderId;
            // If the first order is meant for the market's privileged address, then we insert the order at the first index
            // of the orders array
            if (onBehalfOf == market.params.privilegedAddress) {
                orderId = 0;
            } else {
                // Otherwise, we add an empty order at the zero index
                orderId = 1;
                market.status.orders.push(Order({ amount: 0, updateTimestamp: 0, owner: address(0) }));
            }
            market.status.inversionTimestamp = uint64(block.timestamp);

            {
                uint256 oracleValue = market.params.oracle.latestAnswer();
                market.status.oracleValue = oracleValue;
                // emit OracleValueUpdated(marketId, oracleValue);
            }

            market.status.buyOrSell = buyOrSell;
            market.status.orders[orderId] = Order({
                amount: amount,
                updateTimestamp: block.timestamp,
                owner: onBehalfOf
            });
            market.status.firstIndex = orderId;
            market.status.lastIndex = orderId + 1;

            // emit OrderUpdated(marketId, onBehalfOf, amount, orderId, buyOrSell);
            return (false, 0, orderId);
        } else if (market.status.buyOrSell == buyOrSell) {
            // If the order is placed in the same direction as the current state of the market, we just add the order
            // to the order list

            // In this case, this is a maker order, and if the caller expects the order to be executed (`minAmountOut > 0`),
            // then the function should revert
            if (minAmountOut > 0) revert TooSmallAmountOut();
            (bool openOrder, uint64 orderId) = _hasOpenOrder(market, onBehalfOf);
            if (openOrder) {
                // If the address has an open order, we simply increase this address's order amount
                amount += market.status.orders[orderId].amount;
                market.status.orders[orderId].amount = amount;
                // emit OrderUpdated(marketId, onBehalfOf, amount, orderId, buyOrSell);
            } else {
                if (onBehalfOf == market.params.privilegedAddress) {
                    // If the address is the privileged address (and has no prior order), we add it in the first position
                    // in the array
                    orderId = market.status.firstIndex - 1;
                    if (market.status.lastIndex - orderId == market.params.maxOrders) revert TooManyOpenOrders();
                    market.status.orders[orderId] = Order({
                        amount: amount,
                        updateTimestamp: block.timestamp,
                        owner: onBehalfOf
                    });
                    market.status.firstIndex = orderId;
                } else {
                    // If the order is not for the privileged address, we add the order in the order array
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
                // emit OrderUpdated(marketId, onBehalfOf, amount, orderId, buyOrSell);
            }
            return (false, 0, orderId);
        } else {
            // If the order is a taker order (placed in the other direction than the market's current orders), then
            // we fill the pending orders one by one till there's not enough left or no open order left

            // Getting the oracle value, that is to say how much of `quoteToken` you can get with 1 `baseToken` in base 18
            uint256 marketPrice = _computeMarketPrice(market);

            // This is the total amount that the order will be able to buy of the desired token
            uint256 totalAmountToGet;
            if (buyOrSell == 1)
                totalAmountToGet =
                    (amount * tokenMetadata[tokenToReceive] * BASE_ORACLE) /
                    (marketPrice * tokenMetadata[tokenToSend]);
            else
                totalAmountToGet =
                    (amount * tokenMetadata[tokenToReceive] * marketPrice) /
                    (BASE_ORACLE * tokenMetadata[tokenToSend]);

            Order memory lastOrder;
            uint256 leftoverAmount = totalAmountToGet;
            // Iterating over the list of existing orders
            for (uint256 i = market.status.firstIndex; i < market.status.lastIndex; i++) {
                lastOrder = market.status.orders[i];
                if (lastOrder.amount > leftoverAmount) {
                    // In this case order is completely filled
                    if (minAmountOut > totalAmountToGet) revert TooSmallAmountOut();

                    // Reusing the amount variable
                    amount = lastOrder.amount - leftoverAmount;
                    market.status.orders[i].amount = amount;
                    // The new first order in the market is this one
                    market.status.firstIndex = uint64(i);
                    tokenToReceive.safeTransfer(onBehalfOf, totalAmountToGet);
                    tokenToSend.safeTransfer(lastOrder.owner, amount);
                    // emit OrderUpdated(marketId, lastOrder.owner, amount, i, 1 - buyOrSell);
                    return (true, totalAmountToGet, type(uint256).max);
                } else {
                    leftoverAmount -= lastOrder.amount;
                    tokenToSend.safeTransfer(lastOrder.owner, lastOrder.amount);
                    // emit OrderUpdated(marketId, lastOrder.owner, 0, i, 1 - buyOrSell);
                }
            }
            // At this point, it means that we have finished processing all the orders and that an inversion took place
            // We need to add what's left of the order in the order's list

            // This is the amount of the order we've filled
            amount = totalAmountToGet - leftoverAmount;
            if (minAmountOut > amount) revert TooSmallAmountOut();

            market.status.inversionTimestamp = uint64(block.timestamp);
            {
                uint256 oracleValue = market.params.oracle.latestAnswer();
                market.status.oracleValue = oracleValue;
                // emit OracleValueUpdated(marketId, oracleValue);
            }

            // Updating the market's status
            market.status.buyOrSell = buyOrSell;

            uint64 orderId = onBehalfOf == market.params.privilegedAddress ? 0 : 1;
            market.status.firstIndex = orderId;
            market.status.lastIndex = orderId + 1;

            // We're reusing the `totalAmountToGet` variable to compute the amount that needs to be left in the order
            // If we're buying, then we need to convert here an amount of `baseToken` to `quoteToken`
            // TODO: check rounding here
            if (buyOrSell == 1)
                totalAmountToGet =
                    (leftoverAmount * tokenMetadata[tokenToSend] * marketPrice) /
                    (BASE_ORACLE * tokenMetadata[tokenToReceive]);
            else
                totalAmountToGet =
                    (leftoverAmount * tokenMetadata[tokenToSend] * BASE_ORACLE) /
                    (marketPrice * tokenMetadata[tokenToReceive]);
            market.status.orders[orderId] = Order({
                amount: totalAmountToGet,
                updateTimestamp: block.timestamp,
                owner: onBehalfOf
            });

            // emit OrderUpdated(marketId, onBehalfOf,totalAmountToGet, orderId, buyOrSell);
            tokenToSend.safeTransfer(onBehalfOf, amount);
            return (false, amount, orderId);
        }
    }

    /// @notice Transfers an order from a market to another address
    /// @param marketId Market on which the order needs to be transferred
    /// @param to Address to which the order should be transferred
    /// @dev No need to specify an orderId as this function automatically fetches the order of the `msg.sender` on the market given
    /// @dev The privileged address of a market cannot transfer its orders
    function transferOrder(bytes32 marketId, address to) external {
        Market storage market = markets[marketId];
        (bool openOrder, uint64 orderId) = _hasOpenOrder(market, msg.sender);
        if (!openOrder) revert NoOpenOrder();

        if (market.status.orders[orderId].owner == market.params.privilegedAddress) revert NotAllowed();
        market.status.orders[orderId].owner = to;
        // emit OrderUpdated(marketId, to, market.status.orders[orderId].amount, orderId, market.status.buyOrSell);
    }

    /// @notice Removes an order from `msg.sender` in a market with `marketId` and sends the corresponding funds to the `to` address
    /// @dev This function reverts if it is called too soon after the order is created
    function removeOrder(bytes32 marketId, address to) external nonReentrant {
        Market storage market = markets[marketId];
        (bool openOrder, uint64 orderId) = _hasOpenOrder(market, msg.sender);
        if (!openOrder) revert NoOpenOrder();

        if (block.timestamp - market.status.orders[orderId].updateTimestamp < market.params.withdrawDeadline)
            revert TooEarly();

        if (market.status.orders[orderId].owner == market.params.privilegedAddress) {
            market.status.firstIndex += 1;
        } else {
            // If there is an open order the last index is necessarily greater than 1
            uint64 lastIndex = market.status.lastIndex - 1;
            // Need to loop in order not to break the first arrived first served logic
            for (uint256 i = orderId; i < lastIndex; i++) {
                market.status.orders[i] = market.status.orders[i + 1];
            }
            market.status.lastIndex = lastIndex;
        }
        uint256 amount = market.status.orders[orderId].amount;
        uint64 buyOrSell = market.status.buyOrSell;
        if (buyOrSell == 1) market.quoteToken.safeTransfer(to, amount);
        else market.baseToken.safeTransfer(to, amount);
        // emit OrderUpdated(marketId, msg.sender, 0, orderId, buyOrSell);
    }

    /// @notice Reduces the size of an order of `msg.sender` on `marketId` by `amount` and sends the associated
    /// funds to the `to` address
    /// @dev This function reverts if it makes the size of the order too small
    function reduceOrder(
        bytes32 marketId,
        address to,
        uint256 amount
    ) external nonReentrant {
        Market storage market = markets[marketId];
        (bool openOrder, uint64 orderId) = _hasOpenOrder(market, msg.sender);
        if (!openOrder) revert NoOpenOrder();

        uint256 orderAmount = market.status.orders[orderId].amount - amount;
        uint64 buyOrSell = market.status.buyOrSell;
        if (
            (buyOrSell == 1 && (orderAmount < market.params.minBuyOrder)) ||
            (buyOrSell == 0 && (orderAmount < market.params.minSellOrder))
        ) revert TooSmallOrder();
        market.status.orders[orderId].amount = orderAmount;
        if (buyOrSell == 1) market.quoteToken.safeTransfer(to, amount);
        else market.baseToken.safeTransfer(to, amount);
        // emit OrderUpdated(marketId, msg.sender, orderAmount, orderId, buyOrSell);
    }

    // ============================ Market Management ==============================

    /// @notice Creates a new market in the contract with parameters `params`
    /// @param quoteToken Quote token of the market
    /// @param baseToken Base token of the market
    /// @param params Parameters of the market: except for the privileged address, all these parameters are immutable
    /// @return marketId Id of the created market
    /// @dev All Ids are uniquely generated from the `msg.sender` address, the addresses of the quote and base token as well
    /// as from a nonce.
    function createMarket(
        address quoteToken,
        address baseToken,
        MarketParams memory params
    ) external returns (bytes32 marketId) {
        if (quoteToken == address(0) || baseToken == address(0) || quoteToken == baseToken) revert InvalidParameters();
        uint256 senderNonce = nonces[msg.sender];
        marketId = keccak256(abi.encodePacked(address(quoteToken), address(baseToken), msg.sender, senderNonce));
        nonces[msg.sender] += 1;
        Market storage market = markets[marketId];
        market.quoteToken = IERC20(quoteToken);
        market.baseToken = IERC20(baseToken);
        market.params = params;
        if (tokenMetadata[IERC20(quoteToken)] == 0)
            tokenMetadata[IERC20(quoteToken)] = 10**(IERC20Metadata(quoteToken).decimals());
        if (tokenMetadata[IERC20(baseToken)] == 0)
            tokenMetadata[IERC20(baseToken)] = 10**(IERC20Metadata(baseToken).decimals());
        emit MarketCreated(quoteToken, baseToken, msg.sender, senderNonce, marketId);
    }

    /// @notice Resets the market price of the market `marketId` when either:
    /// 1: The current oracle value is too high with respect to the contract's market price, there are buy orders pending
    /// 2: The current oracle value is too small with respect to the contract's market price, there are sell orders pending
    function resetMarketPrice(bytes32 marketId) external {
        Market storage market = markets[marketId];
        uint256 currentMarketPrice = _computeMarketPrice(market);
        uint256 oracleValue = market.params.oracle.latestAnswer();
        uint256 buyOrSell = market.status.buyOrSell;
        if (
            (buyOrSell == 1 && oracleValue > currentMarketPrice) || (buyOrSell == 0 && oracleValue < currentMarketPrice)
        ) {
            market.status.oracleValue = oracleValue;
            market.status.inversionTimestamp = uint64(block.timestamp);
            emit OracleValueUpdated(marketId, oracleValue);
        }
    }

    /// @notice Allows an address with a privileged role on a market to transfer it to another `to` address
    /// @dev A privileged address calling this function cannot have an open order
    function transferMarketPrivilege(bytes32 marketId, address to) external {
        Market storage market = markets[marketId];
        (bool openOrder, ) = _hasOpenOrder(market, msg.sender);
        if (market.params.privilegedAddress != msg.sender || openOrder) revert NotAllowed();
        market.params.privilegedAddress = to;
    }

    // ============================ Internal Functions =============================

    /// @notice Gets the sum of all open orders on a market
    function _getOrderAmount(Market memory market) internal pure returns (uint256 amount) {
        for (uint256 i = market.status.firstIndex; i < market.status.lastIndex; i++) {
            amount += market.status.orders[i].amount;
        }
    }

    /// @notice Checks whether an `owner` address on a `market` has an open order and if yes returns the associated `orderId`
    function _hasOpenOrder(Market memory market, address owner) internal pure returns (bool openOrder, uint64 orderId) {
        orderId = type(uint64).max;
        for (uint256 i = market.status.firstIndex; i < market.status.lastIndex; i++) {
            if (market.status.orders[i].owner == owner) {
                orderId = uint64(i);
                openOrder = true;
                break;
            }
        }
    }

    /// @notice Computes the current price in a market `market` based on the oracle value stored, the
    /// market's last inversion timestamp and the discount/premium increase rates
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
}
