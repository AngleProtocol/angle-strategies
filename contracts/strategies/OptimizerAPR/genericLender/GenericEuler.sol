// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.12;

import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import { IEuler, IEulerMarkets, IEulerEToken, IEulerDToken, IBaseIRM } from "../../../interfaces/external/euler/IEuler.sol";

import "../../../external/RPow.sol";
import "./GenericLenderBaseUpgradeable.sol";

/// @title GenericEuler
/// @author Angle Core Team
/// @notice Simple supplier to Euler markets
contract GenericEuler is GenericLenderBaseUpgradeable {
    using SafeERC20 for IERC20;
    using Address for address;

    IEuler private constant _euler = IEuler(0x27182842E098f60e3D576794A5bFFb0777E025d3);
    IEulerMarkets private constant _eulerMarkets = IEulerMarkets(0x3520d5a913427E6F0D6A83E07ccD4A4da316e4d3);
    uint256 private constant SECONDS_PER_YEAR = 365.2425 * 86400;
    uint256 private constant RESERVE_FEE_SCALE = 4_000_000_000;
    AggregatorV3Interface private constant oracle = AggregatorV3Interface(address(0));
    address public constant eul = address(0);

    // ======================== References to contracts ============================

    IEulerEToken public eToken;
    IEulerDToken private dToken;
    uint32 public reserveFee;
    IBaseIRM private irm;

    // =============================== Errors ======================================

    error InvalidOracleValue();

    // ============================= Constructor ===================================

    /// @notice Initializer of the `GenericEuler`
    /// @param _strategy Reference to the strategy using this lender
    /// @param governorList List of addresses with governor privilege
    /// @param keeperList List of addresses with keeper privilege
    /// @param guardian Address of the guardian
    function initialize(
        address _strategy,
        string memory _name,
        address[] memory governorList,
        address guardian,
        address[] memory keeperList
    ) external {
        _initialize(_strategy, _name, governorList, guardian, keeperList);

        eToken = IEulerEToken(_eulerMarkets.underlyingToEToken(address(want)));
        dToken = IEulerDToken(_eulerMarkets.underlyingToDToken(address(want)));

        _setEulerPoolVariables();

        want.safeApprove(address(_euler), type(uint256).max);
        // IERC20(eul).safeApprove(oneInch, type(uint256).max);
    }

    // ===================== External Strategy Functions ===========================

    /// @notice Retrieves Euler variables `reserveFee` and the `irm` - rates curve -  used for the underlying token
    /// @dev No access control is needed here because values are fetched from Euler directly
    /// @dev We expect the values concerned not to be often modified
    function setEulerPoolVariables() external {
        _setEulerPoolVariables();
    }

    // ===================== External Strategy Functions ===========================

    /// @notice Deposits the current balance of the contract to the lending platform
    function deposit() external override onlyRole(STRATEGY_ROLE) {
        uint256 balance = want.balanceOf(address(this));
        eToken.deposit(0, balance);
    }

    /// @notice Withdraws a given amount from lender
    /// @param amount The amount the caller wants to withdraw
    /// @return Amount actually withdrawn
    function withdraw(uint256 amount) external override onlyRole(STRATEGY_ROLE) returns (uint256) {
        return _withdraw(amount);
    }

    /// @notice Withdraws as much as possible from the lending platform
    /// @return Whether everything was withdrawn or not
    function withdrawAll() external override onlyRole(STRATEGY_ROLE) returns (bool) {
        uint256 invested = _nav();
        uint256 returned = _withdraw(invested);
        return returned >= invested;
    }

    // ========================== External View Functions ==========================

    /// @notice Helper function to get current balance in want
    function underlyingBalanceStored() public view override returns (uint256) {
        return eToken.balanceOfUnderlying(address(this));
    }

    /// @notice Returns an estimation of the current Annual Percentage Rate after a new deposit
    /// of `amount`
    /// @param amount Amount to add to the lending platform, and that we want to take into account
    /// in the apr computation
    function aprAfterDeposit(uint256 amount) external view override returns (uint256) {
        return _aprAfterDeposit(amount);
    }

    // ================================= Governance ================================

    /// @notice Withdraws as much as possible in case of emergency and sends it to the `PoolManager`
    /// @param amount Amount to withdraw
    /// @dev Does not check if any error occurs or if the amount withdrawn is correct
    function emergencyWithdraw(uint256 amount) external override onlyRole(GUARDIAN_ROLE) {
        eToken.withdraw(0, amount);
        want.safeTransfer(address(poolManager), want.balanceOf(address(this)));
    }

    // ============================= Internal Functions ============================

    /// @notice See `apr`
    function _apr() internal view override returns (uint256) {
        return _aprAfterDeposit(0);
    }

    /// @notice Internal version of the function `aprAfterDeposit`
    function _aprAfterDeposit(uint256 amount) internal view returns (uint256) {
        uint256 totalBorrows = dToken.totalSupply();
        // current supply + the added liquidity
        uint256 totalSupply = eToken.totalSupplyUnderlying() + amount;

        uint256 supplyAPY;
        if (totalSupply > 0) {
            uint32 futureUtilisationRate = uint32(
                (totalBorrows * (uint256(type(uint32).max) * 1e18)) / totalSupply / 1e18
            );
            uint256 interestRate = uint256(uint96(irm.computeInterestRate(address(want), futureUtilisationRate)));
            supplyAPY = _computeAPYs(interestRate, totalBorrows, totalSupply, reserveFee);
        }

        // Adding the yield from EUL
        return supplyAPY + _incentivesRate(amount);
    }

    /// @notice Compute APYs based on th interest rate, reserve fee, borrow
    /// @param borrowSPY Interest rate paid per second by borrowers
    /// @param totalBorrows Total amount borrowed on Euler of the underlying token
    /// @param totalBalancesUnderlying Total amount supplied on Euler of the underlying token
    /// @param _reserveFee Reserve fee set by governance for the underlying token
    /// @return supplyAPY The annual percentage yield received as a supplier with current settings
    function _computeAPYs(
        uint256 borrowSPY,
        uint256 totalBorrows,
        uint256 totalBalancesUnderlying,
        uint32 _reserveFee
    ) internal pure returns (uint256 supplyAPY) {
        // not useful for the moment
        // uint256 borrowAPY = (RPow.rpow(borrowSPY + 1e27, SECONDS_PER_YEAR, 10**27) - 1e27)/ 1e9;

        uint256 supplySPY = (borrowSPY * totalBorrows) / totalBalancesUnderlying;
        supplySPY = (supplySPY * (RESERVE_FEE_SCALE - _reserveFee)) / RESERVE_FEE_SCALE;
        // all rates are in base 18 on Angle strategies
        supplyAPY = (RPow.rpow(supplySPY + 1e27, SECONDS_PER_YEAR, 10**27) - 1e27) / 1e9;
    }

    /// @notice See `withdraw`
    function _withdraw(uint256 amount) internal returns (uint256) {
        uint256 balanceUnderlying = eToken.balanceOfUnderlying(address(this));
        uint256 looseBalance = want.balanceOf(address(this));
        uint256 total = balanceUnderlying + looseBalance;

        if (amount > total) {
            // Can't withdraw more than we own
            amount = total;
        }

        if (looseBalance >= amount) {
            want.safeTransfer(address(strategy), amount);
            return amount;
        }

        // Not state changing but OK because of previous call
        uint256 availableLiquidity = want.balanceOf(address(_euler));

        if (availableLiquidity > 1) {
            uint256 toWithdraw = amount - looseBalance;
            if (toWithdraw <= availableLiquidity) {
                // We can take all
                eToken.withdraw(0, toWithdraw);
            } else {
                // Take all we can
                eToken.withdraw(0, availableLiquidity);
            }
        }

        looseBalance = want.balanceOf(address(this));
        want.safeTransfer(address(strategy), looseBalance);
        return looseBalance;
    }

    /// @notice Calculates APR from Liquidity Mining Program
    /// @dev amountToAdd Amount to add to the currently supplied (for the `aprAfterDeposit` function)
    /// @dev For the moment no on chain tracking of rewards (+ only for borrowers for now)
    function _incentivesRate(uint256) internal view returns (uint256) {
        return 0;
    }

    // TODO to be added if EUL distribution goes live for supplier
    // /// @notice Estimates the value of `_amount` EUL tokens
    // /// @param _amount Amount of comp to compute the `want` price of
    // /// @dev This function uses a ChainLink oracle to easily compute the price
    // function _nativeRewardToWant(uint256 _amount) internal view returns (uint256) {
    //     if (_amount == 0) {
    //         return 0;
    //     }
    //     (uint80 roundId, int256 ratio, , , uint80 answeredInRound) = oracle.latestRoundData();
    //     if (ratio == 0 || roundId > answeredInRound) revert InvalidOracleValue();
    //     uint256 castedRatio = uint256(ratio);

    //     // Checking whether we should multiply or divide by the ratio computed
    //     return (_amount * castedRatio * wantBase) / 1e26;
    // }

    /// @notice Internal version of the `setEulerPoolVariables`
    function _setEulerPoolVariables() internal {
        uint256 interestRateModel = _eulerMarkets.interestRateModel(address(want));
        address moduleImpl = _euler.moduleIdToImplementation(interestRateModel);
        irm = IBaseIRM(moduleImpl);
        reserveFee = _eulerMarkets.reserveFee(address(want));
    }

    /// @notice Specifies the token managed by this contract during normal operation
    function _protectedTokens() internal view override returns (address[] memory) {
        address[] memory protected = new address[](2);
        protected[0] = address(want);
        protected[1] = address(eToken);
        return protected;
    }
}
