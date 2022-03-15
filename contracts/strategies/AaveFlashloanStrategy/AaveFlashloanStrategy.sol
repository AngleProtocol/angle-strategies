// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.7;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/interfaces/IERC3156FlashBorrower.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

import "./AaveLibraries.sol";
import "./AaveInterfaces.sol";
import "./UniswapInterfaces.sol";
import "../BaseStrategy.sol";
import "./ComputeProfitability.sol";

import "hardhat/console.sol";

contract AaveFlashloanStrategy is BaseStrategy, IERC3156FlashBorrower {
    using SafeERC20 for IERC20;
    using Address for address;

    // AAVE protocol address
    IProtocolDataProvider private constant _protocolDataProvider = IProtocolDataProvider(0x057835Ad21a177dbdd3090bB1CAE03EaCF78Fc6d);
    IAaveIncentivesController private constant _incentivesController = IAaveIncentivesController(0xd784927Ff2f95ba542BfC824c8a8a98F3495f6b5);
    ILendingPool private constant _lendingPool = ILendingPool(0x7d2768dE32b0b80b7a3454c06BdAc94A69DDc7A9);
    IReserveInterestRateStrategy private immutable _interestRateStrategyAddress;

    // Token addresses
    address private constant _aave = 0x7Fc66500c84A76Ad7e9c93437bFc5Ac33E2DDaE9;
    IStakedAave private constant _stkAave = IStakedAave(0x4da27a545c0c5B758a6BA100e3a049001de870f5);
    address private constant _weth = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address private constant _dai = 0x6B175474E89094C44Da98b954EedeAC495271d0F;

    // Supply and borrow tokens
    IAToken public aToken;
    IVariableDebtToken public debtToken;

    // represents stkAave cooldown status
    // 0 = no cooldown or past withdraw period
    // 1 = claim period
    // 2 = cooldown initiated, future claim period
    enum CooldownStatus {None, Claim, Initiated}

    // SWAP routers
    IUni private constant _UNI_V2_ROUTER = IUni(0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D);
    IUni private constant _SUSHI_V2_ROUTER = IUni(0xd9e1cE17f2641f24aE83637ab66a2cca9C378B9F);
    ISwapRouter private constant _UNI_V3_ROUTER = ISwapRouter(0xE592427A0AEce92De3Edee1F18E0157C05861564);

    // OPS State Variables
    uint256 private constant _DEFAULT_COLLAT_TARGET_MARGIN = 0.02 ether;
    uint256 private constant _DEFAULT_COLLAT_MAX_MARGIN = 0.005 ether;
    uint256 private constant _LIQUIDATION_WARNING_THRESHOLD = 0.01 ether;

    uint256 public maxBorrowCollatRatio; // The maximum the aave protocol will let us borrow
    uint256 public targetCollatRatio; // The LTV we are levering up to
    uint256 public maxCollatRatio; // Closest to liquidation we'll risk
    uint256 public daiBorrowCollatRatio; // Used for flashmint

    bool public automaticallyComputeCollatRatio = true;

    uint8 public maxIterations;
    bool public isFlashMintActive;
    bool public withdrawCheck;

    uint256 public minWant;
    uint256 public minRatio;
    uint256 public minRewardToSell;

    enum SwapRouter {UniV2, SushiV2, UniV3}
    SwapRouter public swapRouter = SwapRouter.UniV2; // only applied to aave => want, stkAave => aave always uses v3

    bool public sellStkAave;
    bool public cooldownStkAave;
    uint256 public maxStkAavePriceImpactBps;

    uint24 public stkAaveToAaveSwapFee;
    uint24 public aaveToWethSwapFee;
    uint24 public wethToWantSwapFee;

    bool private _alreadyAdjusted; // Signal whether a position adjust was done in prepareReturn

    // TODO: get a referral code from AAVE https://docs.aave.com/developers/v/1.0/integrating-aave/referral-program
    uint16 private constant _referral = 0;

    uint256 private constant _MAX_BPS = 1e4;
    uint256 private constant _BPS_WAD_RATIO = 1e14;
    uint256 private constant _COLLATERAL_RATIO_PRECISION = 1 ether;
    uint256 private constant _PESSIMISM_FACTOR = 1000; // 10%
    uint256 private _DECIMALS;

    ComputeProfitability public immutable computeProfitability;
    AggregatorV3Interface public constant chainlinkOracle = AggregatorV3Interface(0x547a514d5e3769680Ce22B2361c10Ea13619e8a9);

    int256 public lendingPoolVariableRateSlope1; // base 27 (ray)
    int256 public lendingPoolVariableRateSlope2; // base 27 (ray)
    int256 public lendingPoolBaseVariableBorrowRate; // base 27 (ray)
    int256 public lendingPoolOptimalUtilizationRate; // base 27 (ray)
    int256 public aaveReserveFactor; // base 27 (ray)

    /// @notice Constructor of the `Strategy`
    /// @param _poolManager Address of the `PoolManager` lending to this strategy
    /// @param _rewards  The token given to reward keepers.
    /// @param governorList List of addresses with governor privilege
    /// @param guardian Address of the guardian
    constructor(
        address _poolManager,
        IERC20 _rewards,
        address[] memory governorList,
        address guardian,
        ComputeProfitability _computeProfitability
    ) BaseStrategy(_poolManager, _rewards, governorList, guardian) {
        require(address(aToken) == address(0));

        computeProfitability = _computeProfitability;

        // initialize operational state
        maxIterations = 6;
        isFlashMintActive = true;
        withdrawCheck = false;

        // mins
        minWant = 100;
        minRatio = 0.005 ether;
        minRewardToSell = 1e15;

        // reward params
        swapRouter = SwapRouter.UniV2;
        sellStkAave = true;
        cooldownStkAave = false;
        maxStkAavePriceImpactBps = 500;

        stkAaveToAaveSwapFee = 3000;
        aaveToWethSwapFee = 3000;
        wethToWantSwapFee = 3000;

        _alreadyAdjusted = false;

        IReserveInterestRateStrategy interestRateStrategyAddress_ = IReserveInterestRateStrategy((_lendingPool.getReserveData(address(want))).interestRateStrategyAddress);
        _interestRateStrategyAddress = interestRateStrategyAddress_;
        (,,,, uint256 reserveFactor,,,,,) = _protocolDataProvider.getReserveConfigurationData(address(want));
        lendingPoolVariableRateSlope1 = int256(interestRateStrategyAddress_.variableRateSlope1());
        lendingPoolVariableRateSlope2 = int256(interestRateStrategyAddress_.variableRateSlope2());
        lendingPoolBaseVariableBorrowRate = int256(interestRateStrategyAddress_.baseVariableBorrowRate());
        lendingPoolOptimalUtilizationRate = int256(interestRateStrategyAddress_.OPTIMAL_UTILIZATION_RATE());
        aaveReserveFactor = int256(reserveFactor * 10**23);

        // Set aave tokens
        (address _aToken, , address _debtToken) = _protocolDataProvider.getReserveTokensAddresses(address(want));
        aToken = IAToken(_aToken);
        debtToken = IVariableDebtToken(_debtToken);

        // Let collateral targets
        (uint256 ltv, uint256 liquidationThreshold) = _getProtocolCollatRatios(address(want));
        targetCollatRatio = liquidationThreshold - _DEFAULT_COLLAT_TARGET_MARGIN;
        maxCollatRatio = liquidationThreshold - _DEFAULT_COLLAT_MAX_MARGIN;
        maxBorrowCollatRatio = ltv - _DEFAULT_COLLAT_MAX_MARGIN;
        (uint256 daiLtv, ) = _getProtocolCollatRatios(_dai);
        daiBorrowCollatRatio = daiLtv - _DEFAULT_COLLAT_MAX_MARGIN;

        _DECIMALS = wantBase;

        // approve spend aave spend
        _approveMaxSpend(address(want), address(_lendingPool));
        _approveMaxSpend(address(aToken), address(_lendingPool));

        // approve flashloan spend
        if (address(want) != _dai) {
            _approveMaxSpend(_dai, address(_lendingPool));
        }
        _approveMaxSpend(_dai, FlashMintLib.LENDER);

        // approve swap router spend
        _approveMaxSpend(address(_stkAave), address(_UNI_V3_ROUTER));
        _approveMaxSpend(_aave, address(_UNI_V2_ROUTER));
        _approveMaxSpend(_aave, address(_SUSHI_V2_ROUTER));
        _approveMaxSpend(_aave, address(_UNI_V3_ROUTER));
    }

    // SETTERS
    function setCollateralTargets(
        uint256 _targetCollatRatio,
        uint256 _maxCollatRatio,
        uint256 _maxBorrowCollatRatio,
        uint256 _daiBorrowCollatRatio
    ) external onlyRole(GUARDIAN_ROLE) {
        (uint256 ltv, uint256 liquidationThreshold) = _getProtocolCollatRatios(address(want));
        (uint256 daiLtv, ) = _getProtocolCollatRatios(_dai);
        require(_targetCollatRatio < liquidationThreshold);
        require(_maxCollatRatio < liquidationThreshold);
        require(_targetCollatRatio < _maxCollatRatio);
        require(_maxBorrowCollatRatio < ltv);
        require(_daiBorrowCollatRatio < daiLtv);

        targetCollatRatio = _targetCollatRatio;
        maxCollatRatio = _maxCollatRatio;
        maxBorrowCollatRatio = _maxBorrowCollatRatio;
        daiBorrowCollatRatio = _daiBorrowCollatRatio;
    }

    function setIsFlashMintActive(bool _isFlashMintActive) external onlyRole(GUARDIAN_ROLE) {
        isFlashMintActive = _isFlashMintActive;
    }

    function setWithdrawCheck(bool _withdrawCheck) external onlyRole(GUARDIAN_ROLE) {
        withdrawCheck = _withdrawCheck;
    }

    function setMinsAndMaxs(uint256 _minWant, uint256 _minRatio, uint8 _maxIterations) external onlyRole(GUARDIAN_ROLE) {
        require(_minRatio < maxBorrowCollatRatio);
        require(_maxIterations > 0 && _maxIterations < 16);
        minWant = _minWant;
        minRatio = _minRatio;
        maxIterations = _maxIterations;
    }

    function setRewardBehavior(
        SwapRouter _swapRouter,
        bool _sellStkAave,
        bool _cooldownStkAave,
        uint256 _minRewardToSell,
        uint256 _maxStkAavePriceImpactBps,
        uint24 _stkAaveToAaveSwapFee,
        uint24 _aaveToWethSwapFee,
        uint24 _wethToWantSwapFee
    ) external onlyRole(GUARDIAN_ROLE) {
        require(
            _swapRouter == SwapRouter.UniV2 ||
            _swapRouter == SwapRouter.SushiV2 ||
            _swapRouter == SwapRouter.UniV3
        );
        require(_maxStkAavePriceImpactBps <= _MAX_BPS);
        swapRouter = _swapRouter;
        sellStkAave = _sellStkAave;
        cooldownStkAave = _cooldownStkAave;
        minRewardToSell = _minRewardToSell;
        maxStkAavePriceImpactBps = _maxStkAavePriceImpactBps;
        stkAaveToAaveSwapFee = _stkAaveToAaveSwapFee;
        aaveToWethSwapFee = _aaveToWethSwapFee;
        wethToWantSwapFee = _wethToWantSwapFee;
    }

    /// @notice Retrieves lending pool rates for `want`. Those variables are mostly used in `computeMostProfitableBorrow`
    /// @dev No access control needed because they fetch the values from Aave directly. If it changes there, it will need to be updated here too
    function setAavePoolVariables() external {
        (,,,, uint256 reserveFactor,,,,,) = _protocolDataProvider.getReserveConfigurationData(address(want));
        
        lendingPoolVariableRateSlope1 = int256(_interestRateStrategyAddress.variableRateSlope1());
        lendingPoolVariableRateSlope2 = int256(_interestRateStrategyAddress.variableRateSlope2());
        lendingPoolBaseVariableBorrowRate = int256(_interestRateStrategyAddress.baseVariableBorrowRate());
        lendingPoolOptimalUtilizationRate = int256(_interestRateStrategyAddress.OPTIMAL_UTILIZATION_RATE());
        aaveReserveFactor = int256(reserveFactor * 10**23);
    }

    /// @notice Decide whether `targetCollatRatio` should be computed automatically or manually
    function setAutomaticallyComputeCollatRatio(bool _automaticallyComputeCollatRatio) external onlyRole(GUARDIAN_ROLE) {
        automaticallyComputeCollatRatio = _automaticallyComputeCollatRatio;
    }

    function estimatedTotalAssets() public view override returns (uint256) {
        uint256 balanceExcludingRewards = _balanceOfWant() + getCurrentSupply();

        // if we don't have a position, don't worry about rewards
        if (balanceExcludingRewards < minWant) {
            return balanceExcludingRewards;
        }

        uint256 rewards = (estimatedRewardsInWant() * (_MAX_BPS - _PESSIMISM_FACTOR)) / _MAX_BPS;
        return balanceExcludingRewards + rewards;
    }

    function estimatedRewardsInWant() public view returns (uint256) {
        uint256 aaveBalance = _balanceOfAave();
        uint256 stkAaveBalance = _balanceOfStkAave();

        uint256 pendingRewards = _incentivesController.getRewardsBalance(_getAaveAssets(), address(this));
        uint256 combinedStkAave = ((pendingRewards + stkAaveBalance) * (_MAX_BPS - maxStkAavePriceImpactBps)) / _MAX_BPS;
        
        return estimatedAAVEToWant(aaveBalance + combinedStkAave) * (_MAX_BPS - _PESSIMISM_FACTOR) / _MAX_BPS;
    }

    /// @notice Frees up profit plus `_debtOutstanding`.
    /// @param _debtOutstanding Amount to withdraw
    /// @return _profit Profit freed by the call
    /// @return _loss Loss discovered by the call
    /// @return _debtPayment Amount freed to reimburse the debt
    /// @dev If `_debtOutstanding` is more than we can free we get as much as possible.
    function _prepareReturn(uint256 _debtOutstanding) internal override returns (uint256 _profit, uint256 _loss, uint256 _debtPayment) {
        // claim & sell rewards
        _claimAndSellRewards();

        // account for profit / losses
        uint256 totalDebt = poolManager.strategies(address(this)).totalStrategyDebt;

        // Assets immediately convertable to want only
        uint256 supply = getCurrentSupply();
        uint256 totalAssets = _balanceOfWant() + supply;

        if (totalDebt > totalAssets) {
            // we have losses
            _loss = totalDebt - totalAssets;
        } else {
            // we have profit
            _profit = totalAssets - totalDebt;
        }

        // free funds to repay debt + profit to the strategy
        uint256 amountAvailable = _balanceOfWant();
        uint256 amountRequired = _debtOutstanding + _profit;

        if (amountRequired > amountAvailable) {
            // we need to free funds
            // we dismiss losses here, they cannot be generated from withdrawal
            // but it is possible for the strategy to unwind full position
            (amountAvailable, ) = _liquidatePosition(amountRequired);

            // Don't do a redundant adjustment in adjustPosition
            _alreadyAdjusted = true;

            if (amountAvailable >= amountRequired) {
                _debtPayment = _debtOutstanding;
                // profit remains unchanged unless there is not enough to pay it
                if (amountRequired - _debtPayment < _profit) {
                    _profit = amountRequired - _debtPayment;
                }
            } else {
                // we were not able to free enough funds
                if (amountAvailable < _debtOutstanding) {
                    // available funds are lower than the repayment that we need to do
                    _profit = 0;
                    _debtPayment = amountAvailable;
                    // we dont report losses here as the strategy might not be able to return in this harvest
                    // but it will still be there for the next harvest
                } else {
                    // NOTE: amountRequired is always equal or greater than _debtOutstanding
                    // important to use amountRequired just in case amountAvailable is > amountAvailable
                    _debtPayment = _debtOutstanding;
                    _profit = amountAvailable - _debtPayment;
                }
            }
        } else {
            _debtPayment = _debtOutstanding;
            // profit remains unchanged unless there is not enough to pay it
            if (amountRequired - _debtPayment < _profit) {
                _profit = amountRequired - _debtPayment;
            }
        }
    }

    /// @notice Function called by harvest() to adjust the position
    /// @dev It computes the optimal collateral ratio and adjusts deposits/borrows accordingly
    function _adjustPosition() internal override {
        uint256 _debtOutstanding = poolManager.debtOutstanding();

        if (_alreadyAdjusted) {
            _alreadyAdjusted = false; // reset for next time
            return;
        }

        uint256 wantBalance = _balanceOfWant();
        // deposit available want as collateral
        if (wantBalance > _debtOutstanding && wantBalance - _debtOutstanding > minWant) {
            _depositCollateral(wantBalance - _debtOutstanding);
            // we update the value
            wantBalance = _balanceOfWant();
        }

        if (automaticallyComputeCollatRatio) {
            _computeOptimalCollatRatio();
        }

        // check current position
        uint256 currentCollatRatio = getCurrentCollatRatio();

        // Either we need to free some funds OR we want to be max levered
        if (_debtOutstanding > wantBalance) {
            // we should free funds
            uint256 amountRequired = _debtOutstanding - wantBalance;

            // NOTE: vault will take free funds during the next harvest
            _freeFunds(amountRequired);
        } else if (currentCollatRatio < targetCollatRatio) {
            // we should lever up
            if (targetCollatRatio - currentCollatRatio > minRatio) {
                // we only act on relevant differences
                _leverMax();
            }
        } else if (currentCollatRatio > targetCollatRatio) {
            if (currentCollatRatio - targetCollatRatio > minRatio) {
                (uint256 deposits, uint256 borrows) = getCurrentPosition();
                uint256 newBorrow =
                    _getBorrowFromSupply(
                        deposits - borrows,
                        targetCollatRatio
                    );
                _leverDownTo(newBorrow, borrows);
            }
        }
    }

    /// @notice Withdraws `_amountNeeded` of `want` from Aave
    /// @param _amountNeeded Amount of `want` to free
    /// @return _liquidatedAmount Amount of `want` available
    /// @return _loss Difference between `_amountNeeded` and what is actually available
    function _liquidatePosition(uint256 _amountNeeded) internal override returns (uint256 _liquidatedAmount, uint256 _loss) {
        // NOTE: Maintain invariant `want.balanceOf(this) >= _liquidatedAmount`
        // NOTE: Maintain invariant `_liquidatedAmount + _loss <= _amountNeeded`
        uint256 wantBalance = _balanceOfWant();
        if (wantBalance > _amountNeeded) {
            // if there is enough free want, let's use it
            return (_amountNeeded, 0);
        }

        // we need to free funds
        uint256 amountRequired = _amountNeeded - wantBalance;
        _freeFunds(amountRequired);

        uint256 freeAssets = _balanceOfWant();
        if (_amountNeeded > freeAssets) {
            _liquidatedAmount = freeAssets;
            uint256 diff = _amountNeeded - _liquidatedAmount;
            if (diff <= minWant) {
                _loss = diff;
            }
        } else {
            _liquidatedAmount = _amountNeeded;
        }

        if (withdrawCheck) {
            require(_amountNeeded == _liquidatedAmount + _loss); // dev: withdraw safety check
        }
    }

    /// @notice Withdraw as much as we can from Aave
    /// @return _amountFreed Amount successfully freed
    function _liquidateAllPositions() internal override returns (uint256 _amountFreed) {
        (_amountFreed, ) = _liquidatePosition(type(uint256).max);
    }

    function _protectedTokens() internal view override returns (address[] memory) {}

    /// @notice Emergency function that we can use to deleverage manually if something is broken
    /// @param amount Amount of `want` to withdraw/repay
    function manualDeleverage(uint256 amount) external onlyRole(GUARDIAN_ROLE) {
        _withdrawCollateral(amount);
        _repayWant(amount);
    }

    /// @notice Emergency function that we can use to deleverage manually if something is broken
    /// @param amount Amount of `want` to withdraw
    function manualReleaseWant(uint256 amount) external onlyRole(GUARDIAN_ROLE) {
        _withdrawCollateral(amount);
    }

    /// @notice Emergency function that we can use to sell rewards if something is broken
    function manualClaimAndSellRewards() external onlyRole(GUARDIAN_ROLE) {
        _claimAndSellRewards();
    }

    // INTERNAL ACTIONS

    /// @notice Claim earned stkAAVE and swap them for `want`
    /// @dev stkAAVE require a "cooldown" period of 10 days before being claimed
    function _claimAndSellRewards() internal {
        uint256 stkAaveBalance = _balanceOfStkAave();
        CooldownStatus cooldownStatus;
        if (stkAaveBalance > 0) {
            cooldownStatus = _checkCooldown(); // don't check status if we have no stkAave
        }

        // If it's the claim period claim
        if (stkAaveBalance > 0 && cooldownStatus == CooldownStatus.Claim) {
            // redeem AAVE from stkAave
            _stkAave.claimRewards(address(this), type(uint256).max);
            _stkAave.redeem(address(this), stkAaveBalance);
        }

        // claim stkAave from lending and borrowing, this will reset the cooldown
        _incentivesController.claimRewards(
            _getAaveAssets(),
            type(uint256).max,
            address(this)
        );

        stkAaveBalance = _balanceOfStkAave();

        // request start of cooldown period, if there's no cooldown in progress
        if (cooldownStkAave && stkAaveBalance > 0 && cooldownStatus == CooldownStatus.None) {
            _stkAave.cooldown();
        }

        // Always keep 1 wei to get around cooldown clear
        if (sellStkAave && stkAaveBalance >= minRewardToSell + 1) {
            uint256 minAAVEOut = (stkAaveBalance * (_MAX_BPS - maxStkAavePriceImpactBps)) / _MAX_BPS;
            _sellSTKAAVEToAAVE(stkAaveBalance - 1, minAAVEOut);
        }

        // sell AAVE for want
        uint256 aaveBalance = _balanceOfAave();
        if (aaveBalance >= minRewardToSell) {
            _sellAAVEForWant(aaveBalance, 0);
        }
    }

    /// @notice Reduce exposure by withdrawing funds and repaying debt
    /// @param amountToFree Amount of `want` to withdraw/repay
    /// @return balance Current balance of `want`
    function _freeFunds(uint256 amountToFree) internal returns (uint256) {
        if (amountToFree == 0) return 0;

        (uint256 deposits, uint256 borrows) = getCurrentPosition();

        uint256 realAssets = deposits - borrows;
        uint256 newBorrow = _getBorrowFromSupply(realAssets - Math.min(amountToFree, realAssets), targetCollatRatio);

        // repay required amount
        _leverDownTo(newBorrow, borrows);

        return _balanceOfWant();
    }

    /// @notice Get exposure up to `targetCollatRatio`
    function _leverMax() internal {
        (uint256 deposits, uint256 borrows) = getCurrentPosition();
        uint256 totalAmountToBorrow = _getBorrowFromSupply(deposits - borrows, targetCollatRatio) - borrows;

        if (isFlashMintActive) {
            // The best approach is to lever up using regular method, then finish with flash loan
            totalAmountToBorrow = totalAmountToBorrow - _leverUpStep(totalAmountToBorrow);

            if (totalAmountToBorrow > minWant) {
                totalAmountToBorrow = totalAmountToBorrow - _leverUpFlashLoan(totalAmountToBorrow);
            }
        } else {
            for (uint8 i = 0; i < maxIterations && totalAmountToBorrow > minWant; i++) {
                totalAmountToBorrow = totalAmountToBorrow - _leverUpStep(totalAmountToBorrow);
            }
        }
    }

    /// @notice Use a flashloan to increase our exposure in `want` on Aave
    /// @param amount Amount we will deposit and borrow on Aave
    /// @return amount Actual amount deposited/borrowed
    /// @dev Amount returned should equal `amount` but can be lower if we try to flashloan more than `maxFlashLoan` authorized
    function _leverUpFlashLoan(uint256 amount) internal returns (uint256) {
        (uint256 deposits, uint256 borrows) = getCurrentPosition();
        uint256 depositsToMeetLtv = _getDepositFromBorrow(borrows, maxBorrowCollatRatio);
        uint256 depositsDeficitToMeetLtv = 0;
        if (depositsToMeetLtv > deposits) {
            depositsDeficitToMeetLtv = depositsToMeetLtv - deposits;
        }
        return FlashMintLib.doFlashMint(false, amount, address(want), daiBorrowCollatRatio, depositsDeficitToMeetLtv);
    }

    /// @notice Increase exposure in `want`
    /// @param amount Amount of `want` to borrow
    /// @return amount Amount of `want` that was borrowed
    function _leverUpStep(uint256 amount) internal returns (uint256) {
        if (amount == 0) {
            return 0;
        }

        uint256 wantBalance = _balanceOfWant();

        (uint256 deposits, uint256 borrows) = getCurrentPosition();
        uint256 canBorrow = _getBorrowFromDeposit(deposits + wantBalance, maxBorrowCollatRatio);

        if (canBorrow <= borrows) {
            return 0;
        }
        canBorrow = canBorrow - borrows;

        if (canBorrow < amount) {
            amount = canBorrow;
        }

        _depositCollateral(wantBalance);
        _borrowWant(amount);

        return amount;
    }

    /// @notice Reduce our exposure to `want` on Aave
    /// @param newAmountBorrowed Total amount we want to be borrowing
    /// @param currentBorrowed Amount currently borrowed
    function _leverDownTo(uint256 newAmountBorrowed, uint256 currentBorrowed) internal {
        if (currentBorrowed > newAmountBorrowed) {
            uint256 totalRepayAmount = currentBorrowed - newAmountBorrowed;

            if (isFlashMintActive) {
                totalRepayAmount = totalRepayAmount - _leverDownFlashLoan(totalRepayAmount);
            }

            uint256 _maxCollatRatio = maxCollatRatio;

            // in case the flashloan didn't repay the entire amount we have to repay it "manually"
            // by withdrawing a bit of collateral and then repaying the debt with it
            for (uint8 i = 0; i < maxIterations && totalRepayAmount > minWant; i++) {
                _withdrawExcessCollateral(_maxCollatRatio);
                uint256 toRepay = totalRepayAmount;
                uint256 wantBalance = _balanceOfWant();
                if (toRepay > wantBalance) {
                    toRepay = wantBalance;
                }
                uint256 repaid = _repayWant(toRepay);
                totalRepayAmount = totalRepayAmount - repaid;
            }
        }

        // deposit back to get targetCollatRatio (we always need to leave this in this ratio)
        (uint256 deposits, uint256 borrows) = getCurrentPosition();
        uint256 _targetCollatRatio = targetCollatRatio;
        uint256 targetDeposit = _getDepositFromBorrow(borrows, _targetCollatRatio);
        if (targetDeposit > deposits) {
            uint256 toDeposit = targetDeposit - deposits;
            if (toDeposit > minWant) {
                _depositCollateral(Math.min(toDeposit, _balanceOfWant()));
            }
        } else {
            _withdrawExcessCollateral(_targetCollatRatio);
        }
    }

    /// @notice Use a flashloan to reduce our exposure in `want` on Aave
    /// @param amount Amount we will need to withdraw and repay to Aave
    /// @return amount Actual amount repaid
    /// @dev Amount returned should equal `amount` but can be lower if we try to flashloan more than `maxFlashLoan` authorized
    /// @dev `amount` will be withdrawn from deposits and then used to repay borrows
    function _leverDownFlashLoan(uint256 amount) internal returns (uint256) {
        if (amount <= minWant) return 0;
        (, uint256 borrows) = getCurrentPosition();
        if (amount > borrows) {
            amount = borrows;
        }
        return FlashMintLib.doFlashMint(true, amount, address(want), daiBorrowCollatRatio, 0);
    }

    /// @notice Adjusts the deposits based on the wanted collateral ratio (does not touch the borrow)
    /// @param collatRatio Collateral ratio to target
    function _withdrawExcessCollateral(uint256 collatRatio) internal returns (uint256 amount) {
        (uint256 deposits, uint256 borrows) = getCurrentPosition();
        uint256 theoDeposits = _getDepositFromBorrow(borrows, collatRatio);
        if (deposits > theoDeposits) {
            uint256 toWithdraw = deposits - theoDeposits;
            return _withdrawCollateral(toWithdraw);
        }
    }

    /// @notice Deposit `want` tokens in Aave and start earning interests
    /// @param amount Amount to be deposited
    /// @return amount The amount deposited
    function _depositCollateral(uint256 amount) internal returns (uint256) {
        if (amount == 0) return 0;
        _lendingPool.deposit(address(want), amount, address(this), _referral);
        return amount;
    }

    /// @notice Withdraw `want` tokens from Aave
    /// @param amount Amount to be withdrawn
    /// @return amount The amount withdrawn
    function _withdrawCollateral(uint256 amount) internal returns (uint256) {
        if (amount == 0) return 0;
        _lendingPool.withdraw(address(want), amount, address(this));
        return amount;
    }

    /// @notice Repay what we borrowed of `want` from Aave
    /// @param amount Amount to repay
    /// @return amount The amount repaid
    /// @dev `interestRateMode` is set to variable rate (2)
    function _repayWant(uint256 amount) internal returns (uint256) {
        if (amount == 0) return 0;
        return _lendingPool.repay(address(want), amount, 2, address(this));
    }

    /// @notice Borrow `want` from Aave
    /// @param amount Amount of `want` we are borrowing
    /// @return amount The amount borrowed
    /// @dev The third variable is the `interestRateMode`
    /// @dev set at 2 which means we will get a variable interest rate on our borrowed tokens
    function _borrowWant(uint256 amount) internal returns (uint256) {
        if (amount == 0) return 0;
        _lendingPool.borrow(address(want), amount, 2, _referral, address(this));
        return amount;
    }

    // INTERNAL VIEWS
    function _balanceOfWant() internal view returns (uint256) {
        return want.balanceOf(address(this));
    }

    function _balanceOfAToken() internal view returns (uint256) {
        return aToken.balanceOf(address(this));
    }

    function _balanceOfDebtToken() internal view returns (uint256) {
        return debtToken.balanceOf(address(this));
    }

    function _balanceOfAave() internal view returns (uint256) {
        return IERC20(_aave).balanceOf(address(this));
    }

    function _balanceOfStkAave() internal view returns (uint256) {
        return IERC20(address(_stkAave)).balanceOf(address(this));
    }

    /// @notice Flashload callback, as defined by EIP-3156
    /// @notice We check that the call is coming from the DAI lender and then execute the load logic
    /// @dev If everything went smoothly, will return `keccak256("ERC3156FlashBorrower.onFlashLoan")`
    function onFlashLoan(address initiator, address, uint256 amount, uint256, bytes calldata data) external override returns (bytes32) {
        require(msg.sender == FlashMintLib.LENDER);
        require(initiator == address(this));
        (bool deficit, uint256 amountWant) = abi.decode(data, (bool, uint256));

        return FlashMintLib.loanLogic(deficit, amountWant, amount, address(want));
    }

    /// @notice Get the current position we are in: amount deposited and borrowed
    function getCurrentPosition() public view returns (uint256 deposits, uint256 borrows) {
        deposits = _balanceOfAToken();
        borrows = _balanceOfDebtToken();
    }

    /// @notice Gets the current collateral ratio based on deposits and borrows
    function getCurrentCollatRatio() public view returns (uint256 currentCollatRatio) {
        (uint256 deposits, uint256 borrows) = getCurrentPosition();

        if (deposits > 0) {
            currentCollatRatio = (borrows * _COLLATERAL_RATIO_PRECISION) / deposits;
        }
    }

    /// @notice Gets the current supply deposited in Aave
    function getCurrentSupply() public view returns (uint256) {
        (uint256 deposits, uint256 borrows) = getCurrentPosition();
        return deposits - borrows;
    }

    /// @notice Estimate the amount of `want` we will get out by swapping it for AAVE
    /// @param amount Amount of AAVE we want to exchange (in base 18)
    /// @return amount Amount of `want` we are getting. We include a `_PESSIMISM_FACTOR` to account for slippage
    /// @dev Uses Chainlink spot price. Return value will be in base of `want` (6 for USDC)
    function estimatedAAVEToWant(uint256 amount) public view returns(uint256) {
        (, int256 stkAavePriceUSD,,,) = chainlinkOracle.latestRoundData(); // stkAavePriceUSD is in base 8
        return uint256(stkAavePriceUSD) * amount * _DECIMALS / (1e8 * 1e18);
    }

    /// @notice Verifies the cooldown status for earned stkAAVE
    function _checkCooldown() internal view returns (CooldownStatus) {
        uint256 cooldownStartTimestamp = IStakedAave(_stkAave).stakersCooldowns(address(this));
        uint256 COOLDOWN_SECONDS = IStakedAave(_stkAave).COOLDOWN_SECONDS();
        uint256 UNSTAKE_WINDOW = IStakedAave(_stkAave).UNSTAKE_WINDOW();
        uint256 nextClaimStartTimestamp = cooldownStartTimestamp + COOLDOWN_SECONDS;

        if (cooldownStartTimestamp == 0) {
            return CooldownStatus.None;
        }
        if (block.timestamp > nextClaimStartTimestamp && block.timestamp <= nextClaimStartTimestamp + UNSTAKE_WINDOW) {
            return CooldownStatus.Claim;
        }
        if (block.timestamp < nextClaimStartTimestamp) {
            return CooldownStatus.Initiated;
        }
    }

    /// @notice Get swap path for UniswapV2/Sushiswap router
    /// @param _token_in Token we are selling
    /// @param _token_out Token we are buying
    function _getTokenOutPathV2(address _token_in, address _token_out) internal pure returns (address[] memory _path) {
        bool is_weth = _token_in == address(_weth) || _token_out == address(_weth);
        _path = new address[](is_weth ? 2 : 3);
        _path[0] = _token_in;

        if (is_weth) {
            _path[1] = _token_out;
        } else {
            _path[1] = address(_weth);
            _path[2] = _token_out;
        }
    }

    /// @notice Swap AAVE (previously swapped from stkAAVE) to `want` token on `swapRouter` (UniswapV2, UniswapV3 or Sushiswap)
    /// @param amountIn Amount of AAVE to sell
    /// @param minOut Minimum amount of `want` we expect to get out
    function _sellAAVEForWant(uint256 amountIn, uint256 minOut) internal {
        if (amountIn == 0) {
            return;
        }
        if (swapRouter == SwapRouter.UniV3) {
            bytes memory _path;
            if (address(want) == _weth) {
                _path = abi.encodePacked(
                    address(_aave),
                    aaveToWethSwapFee,
                    address(_weth)
                );
            } else {
                _path = abi.encodePacked(
                    address(_aave),
                    aaveToWethSwapFee,
                    address(_weth),
                    wethToWantSwapFee,
                    address(want)
                );
            }

            _UNI_V3_ROUTER.exactInput(
                ISwapRouter.ExactInputParams(
                    _path,
                    address(this),
                    block.timestamp,
                    amountIn,
                    minOut
                )
            );
        } else {
            IUni router = swapRouter == SwapRouter.UniV2 ? _UNI_V2_ROUTER : _SUSHI_V2_ROUTER;
            router.swapExactTokensForTokens(
                amountIn,
                minOut,
                _getTokenOutPathV2(address(_aave), address(want)),
                address(this),
                block.timestamp
            );
        }
    }

    /// @notice Swap incentive rewards (stkAAVE) to AAVE on UniswapV3
    /// @param amountIn Amount of stkAAVE to sell
    /// @param minOut Minimum amount of AAVE we expect to get out
    function _sellSTKAAVEToAAVE(uint256 amountIn, uint256 minOut) internal {
        // NOTE: Unoptimized, can be frontrun and most importantly this pool is low liquidity
        _UNI_V3_ROUTER.exactInputSingle(
            ISwapRouter.ExactInputSingleParams(
                address(_stkAave),
                address(_aave),
                stkAaveToAaveSwapFee,
                address(this),
                block.timestamp,
                amountIn, // wei
                minOut,
                0
            )
        );
    }

    /// @notice Get the deposit and debt token for our `want` token
    function _getAaveAssets() internal view returns (address[] memory assets) {
        assets = new address[](2);
        assets[0] = address(aToken);
        assets[1] = address(debtToken);
    }

    /// @notice Get Aave ratios for a token in order to compute later our collateral ratio
    /// @param token Address of the token for which to check the ratios (usually `want` token)
    /// @dev `getReserveConfigurationData` returns values in base 4. So here `ltv` and `liquidationThreshold` are returned in base 18
    function _getProtocolCollatRatios(address token) internal view returns (uint256 ltv, uint256 liquidationThreshold) {
        (, ltv, liquidationThreshold, , , , , , , ) = _protocolDataProvider.getReserveConfigurationData(token);
        // convert bps to wad
        ltv = ltv * _BPS_WAD_RATIO;
        liquidationThreshold = liquidationThreshold * _BPS_WAD_RATIO;
    }

    /// @notice Get target borrow amount based on deposit and collateral ratio
    /// @param deposit Current total deposited on Aave
    /// @param collatRatio Collateral ratio to target
    function _getBorrowFromDeposit(uint256 deposit, uint256 collatRatio) internal pure returns (uint256) {
        return (deposit * collatRatio) / _COLLATERAL_RATIO_PRECISION;
    }

    /// @notice Get target deposit amount based on borrow and collateral ratio
    /// @param borrow Current total borrowed on Aave
    /// @param collatRatio Collateral ratio to target
    function _getDepositFromBorrow(uint256 borrow, uint256 collatRatio) internal pure returns (uint256) {
        return (borrow * _COLLATERAL_RATIO_PRECISION) / collatRatio;
    }

    /// @notice Computes the optimal collateral ratio based on current interests and incentives on Aave
    /// @notice It modifies the state by updating the `targetCollatRatio`
    function _computeOptimalCollatRatio() internal returns(uint256) {
        uint256 borrow = computeMostProfitableBorrow();
        uint256 _collatRatio = (borrow * _COLLATERAL_RATIO_PRECISION) / (estimatedTotalAssets() + borrow);
        uint256 _maxCollatRatio = maxCollatRatio;
        if (_collatRatio > _maxCollatRatio) {
            _collatRatio = _maxCollatRatio;
        }
        targetCollatRatio = _collatRatio;
        return _collatRatio;
    }

    /// @notice Get target borrow amount based on supply (deposits - borrow) and collateral ratio
    /// @param supply = deposits - borrows. The supply is what is "actually" deposited in Aave
    /// @param collatRatio Collateral ratio to target
    function _getBorrowFromSupply(uint256 supply, uint256 collatRatio) internal pure returns (uint256) {
        return (supply * collatRatio) / (_COLLATERAL_RATIO_PRECISION - collatRatio);
    }

    /// @notice Approve `spender` maxuint of `token`
    /// @param token Address of token to approve
    /// @param spender Address of spender to approve
    function _approveMaxSpend(address token, address spender) internal {
        IERC20(token).safeApprove(spender, type(uint256).max);
    }

    /// @notice Adds a new guardian address and echoes the change to the contracts
    /// that interact with this collateral `PoolManager`
    /// @param _guardian New guardian address
    /// @dev This internal function has to be put in this file because `AccessControl` is not defined
    /// in `PoolManagerInternal`
    function addGuardian(address _guardian) external override onlyRole(POOLMANAGER_ROLE) {
        // Granting the new role
        // Access control for this contract
        _grantRole(GUARDIAN_ROLE, _guardian);
    }

    /// @notice Revokes the guardian role and propagates the change to other contracts
    /// @param guardian Old guardian address to revoke
    function revokeGuardian(address guardian) external override onlyRole(POOLMANAGER_ROLE) {
        _revokeRole(GUARDIAN_ROLE, guardian);
    }

    /// @notice Computes the optimal amounts to borrow based on current interest rates and incentives
    /// @dev Returns optimal `borrow` amount in base of `want`
    function computeMostProfitableBorrow() public view returns(uint256 borrow) {
        (uint256 availableLiquidity, uint256 totalStableDebt, uint256 totalVariableDebt,,,, uint256 averageStableBorrowRate,,,) = _protocolDataProvider.getReserveData(address(want));
        
        (uint256 emissionPerSecondAToken,,) = _incentivesController.assets(address(aToken));
        (uint256 emissionPerSecondDebtToken,,) = _incentivesController.assets(address(debtToken));

        uint256 stkAavePriceToUSDC = estimatedAAVEToWant(1 ether) * (_MAX_BPS - _PESSIMISM_FACTOR) / _MAX_BPS;

        ComputeProfitability.SCalculateBorrow memory parameters = ComputeProfitability.SCalculateBorrow({
            slope1: lendingPoolVariableRateSlope1,
            slope2: lendingPoolVariableRateSlope2,
            r0: lendingPoolBaseVariableBorrowRate,
            totalStableDebt: int256(totalStableDebt * (10**27 / _DECIMALS)),
            totalVariableDebt: int256(totalVariableDebt * (10**27 / _DECIMALS)),
            uOptimal: lendingPoolOptimalUtilizationRate,
            totalDeposits: int256((availableLiquidity + totalStableDebt + totalVariableDebt) * (10**27 / _DECIMALS)),
            reserveFactor: aaveReserveFactor,
            stableBorrowRate: int256(averageStableBorrowRate),
            rewardDeposit: int256(emissionPerSecondAToken * 10**9 * 60 * 60 * 24 * 365 * stkAavePriceToUSDC / 10**6),
            rewardBorrow: int256(emissionPerSecondDebtToken * 10**9 * 60 * 60 * 24 * 365 * stkAavePriceToUSDC / 10**6),
            poolManagerAssets: int256(poolManager.getTotalAsset() * (10**27 / _DECIMALS)),
            maxCollatRatio: int256(maxCollatRatio * 10**9)
        });
        
        int256 _borrow = computeProfitability.computeProfitability(parameters);
        borrow = uint256(_borrow) / (10**27 / _DECIMALS);
    }
}