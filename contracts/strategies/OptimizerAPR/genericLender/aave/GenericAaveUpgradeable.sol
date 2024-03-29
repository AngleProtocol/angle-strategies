// SPDX-License-Identifier: GPL-3.0

pragma solidity ^0.8.12;

import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import { DataTypes, IStakedAave, IReserveInterestRateStrategy } from "../../../../interfaces/external/aave/IAave.sol";
import { IProtocolDataProvider } from "../../../../interfaces/external/aave/IProtocolDataProvider.sol";
import { ILendingPool } from "../../../../interfaces/external/aave/ILendingPool.sol";
import { IAaveIncentivesController } from "../../../../interfaces/external/aave/IAaveIncentivesController.sol";
import { IAToken, IVariableDebtToken } from "../../../../interfaces/external/aave/IAaveToken.sol";
import "./../GenericLenderBaseUpgradeable.sol";

/// @title GenericAave
/// @author Forked from https://github.com/Grandthrax/yearnV2-generic-lender-strat/blob/master/contracts/GenericLender/GenericAave.sol
/// @notice A contract to lend any supported ERC20 to Aave and potentially stake them in an external staking contract
/// @dev This contract is just a base implementation which can be overriden depending on the staking contract on which to stake
/// or not the aTokens
abstract contract GenericAaveUpgradeable is GenericLenderBaseUpgradeable {
    using SafeERC20 for IERC20;
    using Address for address;

    // ================================= REFERENCES ================================

    // solhint-disable-next-line
    AggregatorV3Interface private constant oracle = AggregatorV3Interface(0x547a514d5e3769680Ce22B2361c10Ea13619e8a9);

    // solhint-disable-next-line
    address private constant _aave = 0x7Fc66500c84A76Ad7e9c93437bFc5Ac33E2DDaE9;
    // solhint-disable-next-line
    IStakedAave private constant _stkAave = IStakedAave(0x4da27a545c0c5B758a6BA100e3a049001de870f5);
    // solhint-disable-next-line
    IAaveIncentivesController private constant _incentivesController =
        IAaveIncentivesController(0xd784927Ff2f95ba542BfC824c8a8a98F3495f6b5);
    // solhint-disable-next-line
    ILendingPool internal constant _lendingPool = ILendingPool(0x7d2768dE32b0b80b7a3454c06BdAc94A69DDc7A9);
    // solhint-disable-next-line
    IProtocolDataProvider private constant _protocolDataProvider =
        IProtocolDataProvider(0x057835Ad21a177dbdd3090bB1CAE03EaCF78Fc6d);

    // ================================= CONSTANTS =================================

    uint256 internal constant _SECONDS_IN_YEAR = 365 days;
    uint256 public cooldownSeconds;
    uint256 public unstakeWindow;
    bool public cooldownStkAave;
    bool public isIncentivised;
    IAToken internal _aToken;

    uint256[47] private __gapAaveLender;

    // =================================== EVENT ===================================

    event IncentivisedUpdated(bool _isIncentivised);

    // ================================ CONSTRUCTOR ================================

    /// @notice Initializer of the `GenericAave`
    /// @param _strategy Reference to the strategy using this lender
    /// @param name Name of the lender
    /// @param _isIncentivised Whether the corresponding token is incentivized on Aave or not
    /// @param governorList List of addresses with governor privilege
    /// @param guardian Address of the guardian
    /// @param keeperList List of addresses with keeper privilege
    function initializeAave(
        address _strategy,
        string memory name,
        bool _isIncentivised,
        address[] memory governorList,
        address guardian,
        address[] memory keeperList,
        address oneInch_
    ) public {
        _initialize(_strategy, name, governorList, guardian, keeperList, oneInch_);

        _setAavePoolVariables();
        if (_isIncentivised && address(_aToken.getIncentivesController()) == address(0)) revert PoolNotIncentivized();
        isIncentivised = _isIncentivised;
        cooldownStkAave = true;
        IERC20(address(want)).safeApprove(address(_lendingPool), type(uint256).max);
        // Approve swap router spend
        IERC20(address(_stkAave)).safeApprove(oneInch_, type(uint256).max);
        IERC20(address(_aave)).safeApprove(oneInch_, type(uint256).max);
    }

    // ============================= EXTERNAL FUNCTIONS ============================

    /// @inheritdoc IGenericLender
    function deposit() external override onlyRole(STRATEGY_ROLE) {
        uint256 balance = want.balanceOf(address(this));
        // Aave doesn't allow null deposits
        if (balance == 0) return;
        _deposit(balance);
        // We don't stake balance but the whole aTokenBalance
        // if some dust has been kept idle
        _stake(_balanceAtoken());
    }

    /// @inheritdoc IGenericLender
    function withdraw(uint256 amount) external override onlyRole(STRATEGY_ROLE) returns (uint256) {
        return _withdraw(amount);
    }

    /// @inheritdoc IGenericLender
    function emergencyWithdraw(uint256 amount) external override onlyRole(GUARDIAN_ROLE) {
        _unstake(amount);
        _lendingPool.withdraw(address(want), amount, address(this));
        want.safeTransfer(address(poolManager), want.balanceOf(address(this)));
    }

    /// @inheritdoc IGenericLender
    function withdrawAll() external override onlyRole(STRATEGY_ROLE) returns (bool) {
        uint256 invested = _nav();
        uint256 returned = _withdraw(invested);
        return returned >= invested;
    }

    /// @notice Claim earned stkAAVE
    /// @dev stkAAVE require a "cooldown" period of 10 days before being claimed
    function claimRewards() external onlyRole(KEEPER_ROLE) {
        _claimRewards();
    }

    /// @notice Triggers the cooldown on Aave for this contract
    function cooldown() external onlyRole(KEEPER_ROLE) {
        _stkAave.cooldown();
    }

    /// @notice Retrieves lending pool variables like the `COOLDOWN_SECONDS` or the `UNSTAKE_WINDOW` on Aave
    /// @dev No access control is needed here because values are fetched from Aave directly
    /// @dev We expect the values concerned not to be modified often
    function setAavePoolVariables() external {
        _setAavePoolVariables();
    }

    // ================================== SETTERS ==================================

    /// @notice Toggle isIncentivised state, to let know the lender if it should harvest aave rewards
    function toggleIsIncentivised() external onlyRole(GUARDIAN_ROLE) {
        isIncentivised = !isIncentivised;
    }

    /// @notice Toggle cooldownStkAave state, which allow or not to call the coolDown stkAave each time rewards are claimed
    function toggleCooldownStkAave() external onlyRole(GUARDIAN_ROLE) {
        cooldownStkAave = !cooldownStkAave;
    }

    // ========================== EXTERNAL VIEW FUNCTIONS ==========================

    /// @inheritdoc GenericLenderBaseUpgradeable
    function underlyingBalanceStored() public view override returns (uint256 balance) {
        balance = _balanceAtoken() + _stakedBalance();
    }

    /// @inheritdoc IGenericLender
    function aprAfterDeposit(int256 amount) external view override returns (uint256) {
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

        uint256 newLiquidity = availableLiquidity;
        if (amount >= 0) newLiquidity += uint256(amount);
        else newLiquidity -= uint256(-amount);

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
        uint256 stakingApr = _stakingApr(amount);

        return newLiquidityRate / 1e9 + incentivesRate + stakingApr; // divided by 1e9 to go from Ray to Wad
    }

    // ============================= INTERNAL FUNCTIONS ============================

    /// @notice Internal version of the `claimRewards` function
    function _claimRewards() internal returns (uint256 stkAaveBalance) {
        stkAaveBalance = _balanceOfStkAave();
        // If it's the claim period claim
        if (stkAaveBalance != 0 && _checkCooldown() == 1) {
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
        if (cooldownStkAave && stkAaveBalance != 0 && _checkCooldown() == 0) {
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
    /// @return amount Amount of `want` we are getting
    /// @dev Uses Chainlink spot price. Return value will be in base of `want` (6 for USDC)
    function _estimatedStkAaveToWant(uint256 amount) internal view returns (uint256) {
        (, int256 aavePriceUSD, , , ) = oracle.latestRoundData(); // stkAavePriceUSD is in base 8
        // `aavePriceUSD` is in base 8, so ultimately we need to divide by `1e(18+8)
        return (uint256(aavePriceUSD) * amount * wantBase) / 1e26;
    }

    /// @notice See `apr`
    function _apr() internal view override returns (uint256) {
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
        uint256 stakingApr = _stakingApr(0);

        return liquidityRate / 10**9 + incentivesRate + stakingApr;
    }

    /// @notice Calculates APR from Liquidity Mining Program
    /// @param totalLiquidity Total liquidity available in the pool
    function _incentivesRate(uint256 totalLiquidity) internal view returns (uint256) {
        // Only returns != 0 if the incentives are in place at the moment.
        // It will fail if `isIncentivised` is set to true but there are no incentives
        if (isIncentivised && block.timestamp < _incentivesController.getDistributionEnd() && totalLiquidity != 0) {
            uint256 _emissionsPerSecond;
            (, _emissionsPerSecond, ) = _incentivesController.getAssetData(address(_aToken));
            if (_emissionsPerSecond != 0) {
                uint256 emissionsInWant = _estimatedStkAaveToWant(_emissionsPerSecond); // amount of emissions in want
                uint256 incentivesRate = (emissionsInWant * _SECONDS_IN_YEAR * 1e18) / totalLiquidity; // APRs are in 1e18

                return (incentivesRate * 9500) / 10000; // 95% of estimated APR to avoid overestimations
            }
        }
        return 0;
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

        // Not state changing but OK because of previous call
        uint256 liquidity = want.balanceOf(address(_aToken));

        if (liquidity > 1) {
            uint256 toWithdraw = amount - looseBalance;
            if (toWithdraw <= liquidity) {
                //we can take all
                uint256 freedAmount = _unstake(toWithdraw);
                _lendingPool.withdraw(address(want), freedAmount, address(this));
            } else {
                //take all we can
                uint256 freedAmount = _unstake(liquidity);
                _lendingPool.withdraw(address(want), freedAmount, address(this));
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
    /// the strategy should claim the stkAave
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

    /// @inheritdoc GenericLenderBaseUpgradeable
    function _protectedTokens() internal view override returns (address[] memory) {
        address[] memory protected = new address[](2);
        protected[0] = address(want);
        protected[1] = address(_aToken);
        return protected;
    }

    // ============================= VIRTUAL FUNCTIONS =============================

    /// @notice Allows the lender to stake its aTokens in an external staking contract
    /// @param amount Amount of aTokens to stake
    /// @return Amount of aTokens actually staked
    function _stake(uint256 amount) internal virtual returns (uint256);

    /// @notice Allows the lender to unstake its aTokens from an external staking contract
    /// @param amount Amount of aToken to unstake
    /// @return Amount of aTokens actually unstaked
    function _unstake(uint256 amount) internal virtual returns (uint256);

    /// @notice Gets the amount of aTokens currently staked
    function _stakedBalance() internal view virtual returns (uint256);

    /// @notice Gets the APR from staking additional `amount` of aTokens in the associated staking
    /// contract
    /// @param amount Virtual amount to be staked
    function _stakingApr(int256 amount) internal view virtual returns (uint256);
}
