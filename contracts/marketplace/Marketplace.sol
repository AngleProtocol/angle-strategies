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
- transfer order, withdraw order
- view functions to get the addressable market size as well as the registry
- max order handling -> difference between first index and last index
*/
contract Marketplace is ReentrancyGuard {
    using SafeERC20 for IERC20;
    using Address for address;

    uint256 public constant BASE_PARAMS = 10**9;
    uint256 public constant BASE_ORACLE = 10**18;

    struct Order {
        // Amount of tokens brought for the order
        uint256 amount;
        // Owner of the order which can amend it or remove it
        address owner;
    }

    /// @notice Parameters of a given market: all these parameters are mutable
    struct MarketParams {
        // Oracle contract used to price the tokens
        IOracle oracle;
        // Owner of the market
        address owner;
        // = 1 if orders can be posted permissionlessly in the market, 0 otherwise
        uint64 permissionless;
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
        Order[] orders;
    }

    struct Market {
        IERC20 quoteToken;
        IERC20 baseToken;
        MarketParams params;
        MarketStatus status;
    }

    mapping(bytes32 => Market) public markets;

    mapping(bytes32 => mapping(uint256 => Order)) public orders;
    mapping(bytes32 => mapping(address => uint8)) public approvedParticipants;

    mapping(IERC20 => uint256) public tokenMetadata;

    uint256 public marketIdCount;

    error InvalidTokens();
    error InvalidMarket();
    error InvalidParam();
    error NotApproved();
    error NotOwner();
    error TooManyOpenOrders();
    error TooSmallOrder();

    event MarketCreated(address indexed quoteToken, address indexed baseToken, address indexed owner, address sender);
    event OrderUpdated(bytes32 marketId, address indexed creator, uint256 amount, uint256 orderId, uint64 buyOrSell);
    event SetMarketUintParam(bytes32 marketId, uint256 param, bytes32 what);
    event SetMarketAddressParam(bytes32 marketId, address indexed param, bytes32 what);
    event ToggledApprovedMarketParticipant(bytes32 marketId, address indexed participant, uint8 newStatus);

    constructor() {}

    modifier onlyOwner(bytes32 marketId) {
        if (markets[marketId].params.owner != msg.sender) revert NotOwner();
        _;
    }

    
    function getOpenOrders(bytes32 marketId) external view returns(Order[] memory, uint64) {
        Market memory market = markets[marketId];
        Order[] memory openOrders = new Order[](market.status.lastIndex - market.status.firstIndex);
        for(uint256 i=market.status.firstIndex; i< market.status.lastIndex; i++) {
            openOrders[i] = market.status.orders[i];
        }
        return (openOrders, market.status.buyOrSell);
    }


    /// Whether it's true and whether this order is a buy or sell order
    function hasOpenOrder(bytes32 marketId, address owner) external view returns(bool, uint256) {
        Market memory market = markets[marketId];
        return _hasOpenOrder(market, owner);
    }

    function getBuyOrderAmount(bytes32 marketId) external view returns(uint256 amount) {
        Market memory market = markets[marketId];
        if(market.status.buyOrSell == 1){
            amount = _getOrderAmount(market);
        }
    }

    function getSellOrderAmount(bytes32 marketId) external view returns(uint256 amount) {
        Market memory market = markets[marketId];
        if(market.status.buyOrSell == 0){
            amount = _getOrderAmount(market);
        }
    }

    function getOrderAmount(bytes32 marketId) external view returns(uint256 amount) {
        Market memory market = markets[marketId];
        amount = _getOrderAmount(market);
    }

    function _getOrderAmount(Market memory market) internal pure returns(uint256 amount) {
        for(uint256 i = market.status.firstIndex; i<market.status.lastIndex; i++) {
            amount += market.status.orders[i].amount;
        }
    }

    function _hasOpenOrder(Market memory market, address owner) internal pure returns(bool openOrder, uint256 orderId) {
        for(uint256 i=market.status.firstIndex;i< market.status.lastIndex; i++) {
            if(market.status.orders[i].owner == owner) {
                orderId = i;
                openOrder = true;
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
        marketId = keccak256(abi.encodePacked(address(quoteToken), address(baseToken), params.owner, msg.sender));
        Market storage market = markets[marketId];
        if (address(market.quoteToken) != address(0)) revert InvalidMarket();
        market.quoteToken = IERC20(quoteToken);
        market.baseToken = IERC20(baseToken);
        market.params = params;
        if (tokenMetadata[IERC20(quoteToken)] == 0)
            tokenMetadata[IERC20(quoteToken)] = 10**(IERC20Metadata(quoteToken).decimals());
        if (tokenMetadata[IERC20(baseToken)] == 0)
            tokenMetadata[IERC20(baseToken)] = 10**(IERC20Metadata(baseToken).decimals());
        emit MarketCreated(quoteToken, baseToken, params.owner, msg.sender);
    }


    function placeOrder(
        bytes32 marketId,
        uint64 buyOrSell,
        uint256 amount,
        address onBehalfOf
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
        if (address(market.quoteToken) != address(0)) revert InvalidMarket();
        if(market.params.permissionless == 0 && approvedParticipants[marketId][msg.sender] == 0) revert NotApproved();
        IERC20 tokenToSend;
        IERC20 tokenToReceive;
        if (buyOrSell == 1) {
            tokenToSend = market.quoteToken;
            tokenToReceive = market.baseToken;
            if (amount > market.params.minBuyOrder) revert TooSmallOrder();
        } else {
            tokenToSend = market.baseToken;
            tokenToReceive = market.quoteToken;
            if (amount > market.params.minSellOrder) revert TooSmallOrder();
        }
        tokenToSend.safeTransferFrom(msg.sender, address(this), amount);
        // If there are no open orders
        if (market.status.inversionTimestamp == 0) {
            market.status.inversionTimestamp = uint64(block.timestamp);
            market.status.buyOrSell = buyOrSell;
            market.status.orders[0] = Order({ amount: amount, owner: onBehalfOf });
            market.status.lastIndex = 1;
            emit OrderUpdated(marketId, onBehalfOf, amount, 0, buyOrSell);
            return (false, 0, 0);
        }
        // If the order is placed in the same direction as the current state of the market, we just add the order
        if (market.status.buyOrSell == buyOrSell) {
            (bool openOrder, uint256 orderId) = _hasOpenOrder(market, onBehalfOf);
            if(openOrder) {
                uint256 newOrderAmount = market.status.orders[orderId].amount + amount;
                market.status.orders[orderId].amount = newOrderAmount;
                emit OrderUpdated(marketId, onBehalfOf, newOrderAmount, orderId, buyOrSell);
                return(false,0, orderId);
            } else {
                uint64 lastIndex = market.status.lastIndex;
                if (lastIndex +1 - market.status.firstIndex == market.params.maxOrders) revert TooManyOpenOrders();
                market.status.orders[lastIndex] = Order({ amount: amount, owner: onBehalfOf });
                market.status.lastIndex = lastIndex+1;
                emit OrderUpdated(marketId, onBehalfOf, amount, lastIndex, buyOrSell);
                return (false, 0, lastIndex);
            }
        } else {
            uint256 marketPrice = _computeMarketPrice(market);
            uint256 amountToGet;
            // If we're buying as oracle returns value of baseToken denominated in
            if (buyOrSell == 1)
                amountToGet =
                    (amount * tokenMetadata[tokenToReceive] * BASE_ORACLE) /
                    (marketPrice * tokenMetadata[tokenToSend]);
            else
                amountToGet =
                    (amount * tokenMetadata[tokenToReceive] * marketPrice) /
                    (BASE_ORACLE * tokenMetadata[tokenToSend]);
            // Look if we're filling the orders
            uint64 firstIndex = market.status.firstIndex;
            Order memory orderProcessed;
            uint256 leftoverAmount = amountToGet;
            for (uint256 i = firstIndex; i < market.status.lastIndex; i++) {
                orderProcessed = market.status.orders[i];
                if (orderProcessed.amount > leftoverAmount) {
                    // In this case order is filled and we're good
                    uint256 orderAmount = orderProcessed.amount - leftoverAmount;
                    market.status.orders[i].amount = orderAmount;
                    market.status.firstIndex = uint64(i);
                    tokenToReceive.safeTransfer(onBehalfOf, amountToGet);
                    tokenToSend.safeTransfer(orderProcessed.owner, orderAmount);
                    emit OrderUpdated(marketId, orderProcessed.owner, orderAmount, i, 1-buyOrSell);
                    return (true, amountToGet, type(uint256).max);
                } else {
                    leftoverAmount -= orderProcessed.amount;
                    tokenToSend.safeTransfer(orderProcessed.owner, orderProcessed.amount);
                    emit OrderUpdated(marketId, orderProcessed.owner, 0, i, 1-buyOrSell);
                }
            }
            uint256 amountToSend = amountToGet - leftoverAmount;
            // If we leave the for loop, then this means that we have finished processing all the orders and that an inversion took place
            market.status.inversionTimestamp = uint64(block.timestamp);
            // New status is that of the person
            market.status.buyOrSell = buyOrSell;
            market.status.firstIndex = 0;
            market.status.lastIndex = 1;
            // We're reusing the amountToGet variable to compute the amount that needs to be left in the order
            // If we're buying, then we need to convert here an amount of base tokens to quoteTokens
            if (buyOrSell == 1)
                amountToGet =
                    (amountToSend * tokenMetadata[tokenToSend] * marketPrice) /
                    (BASE_ORACLE * tokenMetadata[tokenToReceive]);
            else
                amountToGet =
                    (amountToSend * tokenMetadata[tokenToSend] * BASE_ORACLE) /
                    (marketPrice * tokenMetadata[tokenToReceive]);
            market.status.orders[0] = Order({ amount: amountToGet, owner: onBehalfOf });
            emit OrderUpdated(marketId, onBehalfOf, amountToGet, 0, buyOrSell);
            tokenToSend.safeTransfer(onBehalfOf, amountToSend);
            return (false, amountToSend, 0);
        }
    }

    function transferOrder(bytes32 marketId, uint256 orderId) external {

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
        if (what == "PR") market.params.permissionless = uint64(param);
        else if(what == "MO") market.params.maxOrders = uint64(param);
        else if (what == "DIR") market.params.discountIncreaseRate = uint64(param);
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
        emit SetMarketAddressParam(marketId, param, what);
    }

    function toggleApprovedMarketParticipant(bytes32 marketId, address participant) external {
        Market storage market = markets[marketId];
        if (market.params.owner != msg.sender) revert NotOwner();
        uint8 approvalStatus = approvedParticipants[marketId][participant];
        approvedParticipants[marketId][participant] = 1-approvalStatus;
        // We remove all the pending orders 
        if(approvalStatus == 1) {
            (bool openOrder, uint256 orderId) = _hasOpenOrder(market, participant);
            // If there is an open order the last index is necessarily greater than 1
            if(openOrder) {
                // In this case we break the first arrived first server logic
                uint64 lastIndex = market.status.lastIndex - 1;
                market.status.orders[orderId] = market.status.orders[lastIndex];
                market.status.lastIndex = lastIndex;
                if(market.status.buyOrSell == 1) {
                    market.quoteToken.safeTransfer(participant, market.status.orders[orderId].amount);
                } else {
                    market.baseToken.safeTransfer(participant, market.status.orders[orderId].amount);
                }
            }
        }
        emit ToggledApprovedMarketParticipant(marketId, participant, 1-approvalStatus);

    }
}
