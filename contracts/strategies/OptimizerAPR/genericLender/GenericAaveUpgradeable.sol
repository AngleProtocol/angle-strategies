// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.12;

import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import { IStakedAave, IReserveInterestRateStrategy } from "../../../interfaces/external/aave/IAave.sol";
import "../../../interfaces/external/aave/IAaveToken.sol";
import "../../../interfaces/external/aave/IProtocolDataProvider.sol";
import "../../../interfaces/external/aave/ILendingPool.sol";
import "./GenericLenderBaseUpgradeable.sol";

struct AaveReferences {
    IAToken _aToken;
    IProtocolDataProvider _protocolDataProvider;
    IStakedAave _stkAave;
    address _aave;
}

/// @title GenericAave
/// @author Forked from https://github.com/Grandthrax/yearnV2-generic-lender-strat/blob/master/contracts/GenericLender/GenericAave.sol
/// @notice A contract to lend any ERC20 to Aave
abstract contract GenericAaveUpgradeable is GenericLenderBaseUpgradeable {
    using SafeERC20 for IERC20;
    using Address for address;

    // ==================== References to contracts =============================
    AggregatorV3Interface public constant oracle = AggregatorV3Interface(0x547a514d5e3769680Ce22B2361c10Ea13619e8a9);
    address public constant oneInch = 0x1111111254fb6c44bAC0beD2854e76F90643097d;

    // // ========================== Aave Protocol Addresses ==========================

    address private constant _aave = 0x7Fc66500c84A76Ad7e9c93437bFc5Ac33E2DDaE9;
    IStakedAave private constant _stkAave = IStakedAave(0x4da27a545c0c5B758a6BA100e3a049001de870f5);
    IAaveIncentivesController private constant _incentivesController =
        IAaveIncentivesController(0xd784927Ff2f95ba542BfC824c8a8a98F3495f6b5);
    ILendingPool internal constant _lendingPool = ILendingPool(0x7d2768dE32b0b80b7a3454c06BdAc94A69DDc7A9);
    IProtocolDataProvider private constant _protocolDataProvider =
        IProtocolDataProvider(0x057835Ad21a177dbdd3090bB1CAE03EaCF78Fc6d);

    // ==================== Parameters =============================
    uint256 public cooldownSeconds;
    uint256 public unstakeWindow;
    uint256 public wantBase;
    bool public cooldownStkAave;
    bool public isIncentivised;
    IAToken internal _aToken;

    bytes32 public constant KEEPER_ROLE = keccak256("KEEPER_ROLE");
    uint256 internal constant _SECONDS_IN_YEAR = 365 days;

    event IncentivisedUpdated(bool _isIncentivised);

    error PoolNotIncentivized();
    error TooSmallAmount();
    error ErrorSwap();

    // ============================= Constructor =============================

    /// @notice Initializer of the `GenericAave`
    /// @param _strategy Reference to the strategy using this lender
    /// @param governorList List of addresses with governor privilege
    /// @param keeperList List of addresses with keeper privilege
    /// @param guardian Address of the guardian
    function initializeBase(
        address _strategy,
        string memory name,
        bool _isIncentivised,
        address[] memory governorList,
        address guardian,
        address[] memory keeperList
    ) public {
        _initialize(_strategy, name, governorList, guardian);

        _setupRole(KEEPER_ROLE, guardian);
        for (uint256 i = 0; i < keeperList.length; i++) {
            _setupRole(KEEPER_ROLE, keeperList[i]);
        }

        _setRoleAdmin(KEEPER_ROLE, GUARDIAN_ROLE);

        _setAavePoolVariables();
        if (_isIncentivised && address(_aToken.getIncentivesController()) == address(0)) revert PoolNotIncentivized();
        isIncentivised = _isIncentivised;
        cooldownStkAave = true;
        IERC20(address(want)).safeApprove(address(_lendingPool), type(uint256).max);
        wantBase = 10**IERC20Metadata(address(want)).decimals();
    }

    // ============================= External Functions =============================

    /// @notice Deposits the current balance to the lending platform
    function deposit() external override onlyRole(STRATEGY_ROLE) {
        uint256 balance = want.balanceOf(address(this));
        _deposit(balance);
        _stake(balance);
    }

    /// @notice Withdraws a given amount from lender
    /// @param amount Amount to withdraw
    /// @return Amount actually withdrawn
    function withdraw(uint256 amount) external override onlyRole(STRATEGY_ROLE) returns (uint256) {
        return _withdraw(amount);
    }

    /// @notice Withdraws as much as possible in case of emergency and sends it to the `PoolManager`
    /// @param amount Amount to withdraw
    /// @dev Does not check if any error occurs or if the amount withdrawn is correct
    function emergencyWithdraw(uint256 amount) external override onlyRole(GUARDIAN_ROLE) {
        uint256 availableAmount = _unstake(amount);
        _lendingPool.withdraw(address(want), availableAmount, address(this));
        want.safeTransfer(address(poolManager), want.balanceOf(address(this)));
    }

    /// @notice Withdraws as much as possible
    function withdrawAll() external override onlyRole(STRATEGY_ROLE) returns (bool) {
        uint256 invested = _nav();
        uint256 returned = _withdraw(invested);
        return returned >= invested;
    }

    function claimRewards() external onlyRole(KEEPER_ROLE) {
        _claimRewards();
    }

    /// @notice Swap earned _stkAave or Aave for `want` through 1Inch
    /// @param minAmountOut Minimum amount of `want` to receive for the swap to happen
    /// @param payload Bytes needed for 1Inch API. Tokens swapped should be: _stkAave -> `want` or Aave -> `want`
    function sellRewards(uint256 minAmountOut, bytes memory payload) external onlyRole(KEEPER_ROLE) {
        //solhint-disable-next-line
        (bool success, bytes memory result) = oneInch.call(payload);
        if (!success) _revertBytes(result);

        uint256 amountOut = abi.decode(result, (uint256));
        if (amountOut < minAmountOut) revert TooSmallAmount();
    }

    /// @notice Retrieves lending pool variables for `want`. Those variables are mostly used in the function
    /// to compute the optimal borrow amount
    /// @dev No access control needed because they fetch the values from Aave directly.
    /// If it changes there, it will need to be updated here too
    /// @dev We expect the values concerned not to be often modified
    function setAavePoolVariables() external {
        _setAavePoolVariables();
    }

    // ============================= External Setter Functions =============================

    /// @notice Toggle isIncentivised state, to let know the lender if it should harvest aave rewards
    function toggleIsIncentivised() external onlyRole(GUARDIAN_ROLE) {
        isIncentivised = !isIncentivised;
    }

    /// @notice Toggle cooldownStkAave state, which allow or not to call the coolDown
    function toggleCooldownStkAave() external onlyRole(GUARDIAN_ROLE) {
        cooldownStkAave = !cooldownStkAave;
    }

    // ============================= External View Functions =============================

    /// @notice Checks if assets are currently managed by this contract
    function hasAssets() external view override returns (bool) {
        return _nav() > 0;
    }

    /// @notice Returns the current total of assets managed
    function nav() external view override returns (uint256) {
        return _nav();
    }

    /// @notice Returns the current balance of aTokens
    function underlyingBalanceStored() public view returns (uint256 balance) {
        balance = _balanceAtoken();
        balance += _stakedBalance();
    }

    /// @notice Returns an estimation of the current Annual Percentage Rate
    function apr() external view override returns (uint256) {
        return _apr();
    }

    /// @notice Returns an estimation of the current Annual Percentage Rate weighted by a factor
    function weightedApr() external view override returns (uint256) {
        uint256 a = _apr();
        return a * _nav();
    }

    // TODO to be adapted for staking
    /// @notice Returns an estimation of the current Annual Percentage Rate after a new deposit
    /// @param extraAmount The amount to add to the lending platform
    function aprAfterDeposit(uint256 extraAmount) external view override returns (uint256) {
        // i need to calculate new supplyRate after Deposit (when deposit has not been done yet)
        DataTypes.ReserveData memory reserveData = _lendingPool.getReserveData(address(want));

        (
            uint256 availableLiquidity,
            uint256 totalStableDebt,
            uint256 totalVariableDebt,
            ,
            ,
            ,
            uint256 averageStableBorrowRate,
            ,
            ,

        ) = _protocolDataProvider.getReserveData(address(want));

        uint256 newLiquidity = availableLiquidity + extraAmount;

        (, , , , uint256 reserveFactor, , , , , ) = _protocolDataProvider.getReserveConfigurationData(address(want));

        (uint256 newLiquidityRate, , ) = IReserveInterestRateStrategy(reserveData.interestRateStrategyAddress)
            .calculateInterestRates(
                address(want),
                newLiquidity,
                totalStableDebt,
                totalVariableDebt,
                averageStableBorrowRate,
                reserveFactor
            );
        uint256 incentivesRate = _incentivesRate(newLiquidity + totalStableDebt + totalVariableDebt); // total supplied liquidity in Aave v2

        return newLiquidityRate / 1e9 + incentivesRate; // divided by 1e9 to go from Ray to Wad
    }

    // ========================= Internal Functions ===========================

    /// @notice Claim earned stkAAVE (only called at `harvest`)
    /// @dev stkAAVE require a "cooldown" period of 10 days before being claimed
    function _claimRewards() internal returns (uint256 stkAaveBalance) {
        stkAaveBalance = _balanceOfStkAave();
        uint256 cooldownStatus;
        if (stkAaveBalance > 0) {
            cooldownStatus = _checkCooldown(); // don't check status if we have no _stkAave
        }

        // If it's the claim period claim
        if (stkAaveBalance > 0 && cooldownStatus == 1) {
            // redeem AAVE from _stkAave
            _stkAave.claimRewards(address(this), type(uint256).max);
            _stkAave.redeem(address(this), stkAaveBalance);
        }

        address[] memory claimOnTokens = new address[](1);
        claimOnTokens[0] = address(_aToken);
        // claim _stkAave from lending and borrowing, this will reset the cooldown
        _incentivesController.claimRewards(claimOnTokens, type(uint256).max, address(this));

        stkAaveBalance = _balanceOfStkAave();

        // request start of cooldown period, if there's no cooldown in progress
        if (cooldownStkAave && stkAaveBalance > 0 && _checkCooldown() == 0) {
            _stkAave.cooldown();
        }
    }

    /// @notice Returns the `StkAAVE` balance
    function _balanceOfStkAave() internal view returns (uint256) {
        return IERC20(address(_stkAave)).balanceOf(address(this));
    }

    /// @notice Returns the `aToken` balance
    function _balanceAtoken() internal view returns (uint256) {
        return _aToken.balanceOf(address(this));
    }

    /// @notice Estimate the amount of `want` we will get out by swapping it for AAVE
    /// @param amount Amount of AAVE we want to exchange (in base 18)
    /// @return amount Amount of `want` we are getting. We include a discount to account for slippage equal to 9000
    /// @dev Uses Chainlink spot price. Return value will be in base of `want` (6 for USDC)
    function _estimatedStkAaveToWant(uint256 amount) internal view returns (uint256) {
        (, int256 aavePriceUSD, , , ) = oracle.latestRoundData(); // stkAavePriceUSD is in base 8
        // `aavePriceUSD` is in base 8, so ultimately we need to divide by `1e(18+8)
        return (uint256(aavePriceUSD) * amount * wantBase) / 1e26;
    }

    /// @notice See `apr`
    function _apr() internal view returns (uint256) {
        (
            uint256 availableLiquidity,
            uint256 totalStableDebt,
            uint256 totalVariableDebt,
            uint256 liquidityRate,
            ,
            ,
            ,
            ,
            ,

        ) = _protocolDataProvider.getReserveData(address(want));
        uint256 incentivesRate = _incentivesRate(availableLiquidity + totalStableDebt + totalVariableDebt); // total supplied liquidity in Aave v2

        return liquidityRate / 10**9 + incentivesRate;
    }

    /// @notice Calculates APR from Liquidity Mining Program
    /// @param totalLiquidity Total liquidity available in the pool
    /// @dev At Angle, compared with Yearn implementation, we have decided to add a check
    /// about the `totalLiquidity` before entering the `if` branch
    function _incentivesRate(uint256 totalLiquidity) internal view returns (uint256) {
        // only returns != 0 if the incentives are in place at the moment.
        // it will fail if the isIncentivised is set to true but there is no incentives
        if (isIncentivised && block.timestamp < _incentivesController.getDistributionEnd() && totalLiquidity > 0) {
            uint256 _emissionsPerSecond;
            (, _emissionsPerSecond, ) = _incentivesController.getAssetData(address(_aToken));
            if (_emissionsPerSecond > 0) {
                uint256 emissionsInWant = _estimatedStkAaveToWant(_emissionsPerSecond); // amount of emissions in want
                uint256 incentivesRate = (emissionsInWant * _SECONDS_IN_YEAR * 1e18) / totalLiquidity; // APRs are in 1e18

                return (incentivesRate * 9500) / 10000; // 95% of estimated APR to avoid overestimations
            }
        }
        return 0;
    }

    /// @notice See `nav`
    function _nav() internal view returns (uint256) {
        return want.balanceOf(address(this)) + underlyingBalanceStored();
    }

    /// @notice See `withdraw`
    function _withdraw(uint256 amount) internal returns (uint256) {
        uint256 stakedBalance = _stakedBalance();
        uint256 balanceUnderlying = _balanceAtoken();
        uint256 looseBalance = want.balanceOf(address(this));
        uint256 total = stakedBalance + balanceUnderlying + looseBalance;

        if (amount > total) {
            //cant withdraw more than we own
            amount = total;
        }

        if (looseBalance >= amount) {
            want.safeTransfer(address(strategy), amount);
            return amount;
        }

        //not state changing but OK because of previous call
        uint256 liquidity = want.balanceOf(address(_aToken));

        if (liquidity > 1) {
            uint256 toWithdraw = amount - looseBalance;

            if (toWithdraw <= liquidity) {
                //we can take all
                uint256 availableAmount = _unstake(toWithdraw);
                _lendingPool.withdraw(address(want), availableAmount, address(this));
            } else {
                //take all we can
                uint256 availableAmount = _unstake(liquidity);
                _lendingPool.withdraw(address(want), availableAmount, address(this));
            }
        }
        looseBalance = want.balanceOf(address(this));
        want.safeTransfer(address(strategy), looseBalance);
        return looseBalance;
    }

    /// @notice See `deposit`
    function _deposit(uint256 amount) internal {
        ILendingPool lp = _lendingPool;
        // NOTE: Checks if allowance is enough and acts accordingly
        // allowance might not be enough if
        //     i) initial allowance has been used (should take years)
        //     ii) _lendingPool contract address has changed (Aave updated the contract address)
        if (want.allowance(address(this), address(lp)) < amount) {
            IERC20(address(want)).safeApprove(address(lp), 0);
            IERC20(address(want)).safeApprove(address(lp), type(uint256).max);
        }
        lp.deposit(address(want), amount, address(this), 0);
    }

    /// @notice Internal version of the `_setAavePoolVariables`
    function _setAavePoolVariables() internal {
        (address aToken, , ) = _protocolDataProvider.getReserveTokensAddresses(address(want));
        _aToken = IAToken(aToken);
        cooldownSeconds = IStakedAave(_stkAave).COOLDOWN_SECONDS();
        unstakeWindow = IStakedAave(_stkAave).UNSTAKE_WINDOW();
    }

    /// @notice Verifies the cooldown status for earned stkAAVE
    /// @return cooldownStatus Status of the coolDown: if it is 0 then there is no cooldown Status, if it is 1 then
    /// the strategy should claim
    function _checkCooldown() internal view returns (uint256 cooldownStatus) {
        uint256 cooldownStartTimestamp = IStakedAave(_stkAave).stakersCooldowns(address(this));
        uint256 nextClaimStartTimestamp = cooldownStartTimestamp + cooldownSeconds;
        if (cooldownStartTimestamp == 0) {
            return 0;
        }
        if (block.timestamp > nextClaimStartTimestamp && block.timestamp <= nextClaimStartTimestamp + unstakeWindow) {
            return 1;
        }
        if (block.timestamp < nextClaimStartTimestamp) {
            return 2;
        }
    }

    /// @notice Specifies the token managed by this contract during normal operation
    function _protectedTokens() internal view override returns (address[] memory) {
        address[] memory protected = new address[](2);
        protected[0] = address(want);
        protected[1] = address(_aToken);
        return protected;
    }

    /// @notice Internal function used for error handling
    function _revertBytes(bytes memory errMsg) internal pure {
        if (errMsg.length > 0) {
            //solhint-disable-next-line
            assembly {
                revert(add(32, errMsg), mload(errMsg))
            }
        }
        revert ErrorSwap();
    }

    // ========================= Virtual Functions ===========================

    function _stake(uint256 amount) internal virtual returns (uint256 stakedAmount);

    function _unstake(uint256 amount) internal virtual returns (uint256 withdrawnAmount);

    function _stakedBalance() internal view virtual returns (uint256);
}
