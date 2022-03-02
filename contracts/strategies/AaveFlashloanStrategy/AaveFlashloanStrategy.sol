// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.7;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/interfaces/IERC3156FlashBorrower.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import "./AaveLibraries.sol";
import "./AaveInterfaces.sol";
import "./UniswapInterfaces.sol";
import "../BaseStrategy.sol";
import "./UniswapOracle.sol";

import "hardhat/console.sol";

contract AaveFlashloanStrategy is BaseStrategy, IERC3156FlashBorrower {
    using SafeERC20 for IERC20;
    using Address for address;

    // AAVE protocol address
    IProtocolDataProvider private _protocolDataProvider; // 0x057835Ad21a177dbdd3090bB1CAE03EaCF78Fc6d
    IAaveIncentivesController private _incentivesController; // 0xd784927Ff2f95ba542BfC824c8a8a98F3495f6b5
    ILendingPool private _lendingPool; // 0x7d2768dE32b0b80b7a3454c06BdAc94A69DDc7A9

    // Token addresses
    address private _aave; // 0x7Fc66500c84A76Ad7e9c93437bFc5Ac33E2DDaE9
    IStakedAave private _stkAave; // 0x4da27a545c0c5B758a6BA100e3a049001de870f5
    address private immutable _weth; // 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2
    address private _dai; // 0x6B175474E89094C44Da98b954EedeAC495271d0F

    // struct FlashMintLibParams {
    //     address lender;
    //     address adai;
    // }
    // FlashMintLib public flashMintlib;

    // Supply and borrow tokens
    IAToken public aToken;
    IVariableDebtToken public debtToken;

    // represents stkAave cooldown status
    // 0 = no cooldown or past withdraw period
    // 1 = claim period
    // 2 = cooldown initiated, future claim period
    enum CooldownStatus {None, Claim, Initiated}

    // SWAP routers
    IUni private _UNI_V2_ROUTER; // 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D
    IUni private _SUSHI_V2_ROUTER; // 0xd9e1cE17f2641f24aE83637ab66a2cca9C378B9F
    ISwapRouter private _UNI_V3_ROUTER; // 0xE592427A0AEce92De3Edee1F18E0157C05861564

    // OPS State Variables
    uint256 private constant _DEFAULT_COLLAT_TARGET_MARGIN = 0.02 ether;
    uint256 private constant _DEFAULT_COLLAT_MAX_MARGIN = 0.005 ether;
    uint256 private constant _LIQUIDATION_WARNING_THRESHOLD = 0.01 ether;

    uint256 public maxBorrowCollatRatio; // The maximum the aave protocol will let us borrow
    uint256 public targetCollatRatio; // The LTV we are levering up to
    uint256 public maxCollatRatio; // Closest to liquidation we'll risk
    uint256 public daiBorrowCollatRatio; // Used for flashmint

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

    // TODO: get a referral code from AAVE
    // https://docs.aave.com/developers/v/1.0/integrating-aave/referral-program
    uint16 private constant _referral = 7; // Yearn's aave referral code

    uint256 private constant _MAX_BPS = 1e4;
    uint256 private constant _BPS_WAD_RATIO = 1e14;
    uint256 private constant _COLLATERAL_RATIO_PRECISION = 1 ether;
    uint256 private constant _PESSIMISM_FACTOR = 1000;
    uint256 private _DECIMALS;

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
        address protocolDataProvider_,
        address incentivesController_,
        address lendingPool_,
        address[] memory _tokens, // dai, aave, stkAave, weth
        address[] memory _routers // uniV2Router, univ3Router, sushiV2Router,
        // FlashMintLibParams memory _flashMintLibParams
    ) BaseStrategy(_poolManager, _rewards, governorList, guardian) {
        require(address(aToken) == address(0));
        require(protocolDataProvider_ != address(0));

        _protocolDataProvider = IProtocolDataProvider(protocolDataProvider_);
        _incentivesController = IAaveIncentivesController(incentivesController_);
        _lendingPool = ILendingPool(lendingPool_);

        _UNI_V2_ROUTER = IUni(_routers[0]);
        _SUSHI_V2_ROUTER = IUni(_routers[2]);
        _UNI_V3_ROUTER = ISwapRouter(_routers[1]);

        _dai = _tokens[0];
        _aave = _tokens[1];
        _stkAave = IStakedAave(_tokens[2]);
        _weth = _tokens[3];

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

        // flashMintlib = new FlashMintLib(_flashMintLibParams.lender, _tokens[3], _tokens[0], _flashMintLibParams.adai, protocolDataProvider_, lendingPool_);

        // Set aave tokens
        (address _aToken, , address _debtToken) = IProtocolDataProvider(protocolDataProvider_).getReserveTokensAddresses(address(want));
        aToken = IAToken(_aToken);
        debtToken = IVariableDebtToken(_debtToken);

        // Let collateral targets
        (uint256 ltv, uint256 liquidationThreshold) = _getProtocolCollatRatios(address(want));
        targetCollatRatio = liquidationThreshold - _DEFAULT_COLLAT_TARGET_MARGIN;
        maxCollatRatio = liquidationThreshold - _DEFAULT_COLLAT_MAX_MARGIN;
        maxBorrowCollatRatio = ltv - _DEFAULT_COLLAT_MAX_MARGIN;
        (uint256 daiLtv, ) = _getProtocolCollatRatios(_tokens[0]);
        daiBorrowCollatRatio = daiLtv - _DEFAULT_COLLAT_MAX_MARGIN;

        _DECIMALS = wantBase;

        // approve spend aave spend
        _approveMaxSpend(address(want), lendingPool_);
        _approveMaxSpend(address(aToken), lendingPool_);

        // approve flashloan spend
        if (address(want) != _tokens[0]) {
            _approveMaxSpend(_tokens[0], lendingPool_);
        }
        // _approveMaxSpend(_tokens[0], _flashMintLibParams.lender);
        _approveMaxSpend(_tokens[0], FlashMintLib.LENDER);

        // approve swap router spend
        _approveMaxSpend(_tokens[2], _routers[1]);
        _approveMaxSpend(_tokens[1], _routers[0]);
        _approveMaxSpend(_tokens[1], _routers[2]);
        _approveMaxSpend(_tokens[1], _routers[1]);
    }

    // SETTERS
    function setCollateralTargets(
        uint256 _targetCollatRatio,
        uint256 _maxCollatRatio,
        uint256 _maxBorrowCollatRatio,
        uint256 _daiBorrowCollatRatio
    ) external onlyRole(GUARDIAN_ROLE) {
        (uint256 ltv, uint256 liquidationThreshold) =
            _getProtocolCollatRatios(address(want));
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

    function setIsFlashMintActive(bool _isFlashMintActive)
        external
        onlyRole(GUARDIAN_ROLE)
    {
        isFlashMintActive = _isFlashMintActive;
    }

    function setWithdrawCheck(bool _withdrawCheck) external onlyRole(GUARDIAN_ROLE) {
        withdrawCheck = _withdrawCheck;
    }

    function setMinsAndMaxs(
        uint256 _minWant,
        uint256 _minRatio,
        uint8 _maxIterations
    ) external onlyRole(GUARDIAN_ROLE) {
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

        uint256 pendingRewards =
            _incentivesController.getRewardsBalance(
                _getAaveAssets(),
                address(this)
            );
        uint256 stkAaveDiscountFactor = _MAX_BPS - maxStkAavePriceImpactBps;
        uint256 combinedStkAave = ((pendingRewards + stkAaveBalance) * stkAaveDiscountFactor) / _MAX_BPS;

        return _tokenToWant(_aave, aaveBalance + combinedStkAave);
    }

    function _prepareReturn(uint256 _debtOutstanding)
        internal
        override
        returns (
            uint256 _profit,
            uint256 _loss,
            uint256 _debtPayment
        )
    {
        // claim & sell rewards
        _claimAndSellRewards();

        // account for profit / losses
        uint256 totalDebt = poolManager.strategies(address(this)).totalStrategyDebt;

        // Assets immediately convertable to want only
        uint256 supply = getCurrentSupply();
        uint256 totalAssets = _balanceOfWant() + supply;
        console.log("supply: %s / totalAssets: %s", supply, totalAssets);

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
        
        console.log("*_prepareReturn* supply %s / totalAssets %s", supply, totalAssets);
        console.log("*_prepareReturn* _profit %s / _loss %s", _profit , _loss );
        console.log("*_prepareReturn* _debtPayment %s / _debtOutstanding %s", _debtPayment, _debtOutstanding);
    }

    function _adjustPosition() internal override {
        uint256 _debtOutstanding = poolManager.debtOutstanding();

        if (_alreadyAdjusted) {
            _alreadyAdjusted = false; // reset for next time
            return;
        }

        uint256 wantBalance = _balanceOfWant();
        console.log("*_adjustPosition* wantBalance %s / _debtOutstanding %s", wantBalance, _debtOutstanding);
        // deposit available want as collateral
        if (
            wantBalance > _debtOutstanding &&
            wantBalance - _debtOutstanding > minWant
        ) {
            _depositCollateral(wantBalance - _debtOutstanding);
            // we update the value
            wantBalance = _balanceOfWant();
        }
        console.log("wantBalance2 %s", wantBalance);
        // check current position
        uint256 currentCollatRatio = getCurrentCollatRatio();

        console.log("currentCollatRatio %s < targetCollatRatio %s", currentCollatRatio, targetCollatRatio);

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

    function _liquidatePosition(uint256 _amountNeeded)
        internal
        override
        returns (uint256 _liquidatedAmount, uint256 _loss)
    {
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

    // harvestTrigger is external, therefore this function cannot exist
    // function tendTrigger() public view override returns (bool) {
    //     if (harvestTrigger()) {
    //         //harvest takes priority
    //         return false;
    //     }
    //     // pull the liquidation liquidationThreshold from aave to be extra safu
    //     (, uint256 liquidationThreshold) =
    //         _getProtocolCollatRatios(address(want));

    //     uint256 currentCollatRatio = getCurrentCollatRatio();

    //     if (currentCollatRatio >= liquidationThreshold) {
    //         return true;
    //     }

    //     return (liquidationThreshold - currentCollatRatio <= _LIQUIDATION_WARNING_THRESHOLD);
    // }

    function _liquidateAllPositions()
        internal
        override
        returns (uint256 _amountFreed)
    {
        (_amountFreed, ) = _liquidatePosition(type(uint256).max);
    }

    function _protectedTokens()
        internal
        view
        override
        returns (address[] memory)
    {}

    //emergency function that we can use to deleverage manually if something is broken
    function manualDeleverage(uint256 amount) external onlyRole(GUARDIAN_ROLE) {
        _withdrawCollateral(amount);
        _repayWant(amount);
    }

    //emergency function that we can use to deleverage manually if something is broken
    function manualReleaseWant(uint256 amount) external onlyRole(GUARDIAN_ROLE) {
        _withdrawCollateral(amount);
    }

    // emergency function that we can use to sell rewards if something is broken
    function manualClaimAndSellRewards() external onlyRole(GUARDIAN_ROLE) {
        _claimAndSellRewards();
    }

    // INTERNAL ACTIONS

    function _claimAndSellRewards() internal returns (uint256) {
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
        if (
            cooldownStkAave &&
            stkAaveBalance > 0 &&
            cooldownStatus == CooldownStatus.None
        ) {
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

    function _freeFunds(uint256 amountToFree) internal returns (uint256) {
        if (amountToFree == 0) return 0;

        (uint256 deposits, uint256 borrows) = getCurrentPosition();

        uint256 realAssets = deposits - borrows;
        uint256 amountRequired = Math.min(amountToFree, realAssets);
        uint256 newSupply = realAssets - amountRequired;
        uint256 newBorrow = _getBorrowFromSupply(newSupply, targetCollatRatio);

        // repay required amount
        _leverDownTo(newBorrow, borrows);

        return _balanceOfWant();
    }

    function _leverMax() internal {
        (uint256 deposits, uint256 borrows) = getCurrentPosition();

        // NOTE: decimals should cancel out
        uint256 realSupply = deposits - borrows;
        uint256 newBorrow = _getBorrowFromSupply(realSupply, targetCollatRatio);
        uint256 totalAmountToBorrow = newBorrow - borrows;

        if (isFlashMintActive) {
            // The best approach is to lever up using regular method, then finish with flash loan
            totalAmountToBorrow = totalAmountToBorrow - _leverUpStep(totalAmountToBorrow);

            if (totalAmountToBorrow > minWant) {
                totalAmountToBorrow = totalAmountToBorrow - _leverUpFlashLoan(totalAmountToBorrow);
            }
        } else {
            for (
                uint8 i = 0;
                i < maxIterations && totalAmountToBorrow > minWant;
                i++
            ) {
                totalAmountToBorrow = totalAmountToBorrow - _leverUpStep(totalAmountToBorrow);
            }
        }
    }

    function _leverUpFlashLoan(uint256 amount) internal returns (uint256) {
        (uint256 deposits, uint256 borrows) = getCurrentPosition();
        uint256 depositsToMeetLtv =
            _getDepositFromBorrow(borrows, maxBorrowCollatRatio);
        uint256 depositsDeficitToMeetLtv = 0;
        if (depositsToMeetLtv > deposits) {
            depositsDeficitToMeetLtv = depositsToMeetLtv - deposits;
        }
        return
            FlashMintLib.doFlashMint(
                false,
                amount,
                address(want),
                daiBorrowCollatRatio,
                depositsDeficitToMeetLtv
            );
    }

    function _leverUpStep(uint256 amount) internal returns (uint256) {
        if (amount == 0) {
            return 0;
        }

        uint256 wantBalance = _balanceOfWant();

        // calculate how much borrow can I take
        (uint256 deposits, uint256 borrows) = getCurrentPosition();
        uint256 canBorrow = _getBorrowFromDeposit(deposits + wantBalance, maxBorrowCollatRatio);

        if (canBorrow <= borrows) {
            return 0;
        }
        canBorrow = canBorrow - borrows;

        if (canBorrow < amount) {
            amount = canBorrow;
        }

        // deposit available want as collateral
        _depositCollateral(wantBalance);

        // borrow available amount
        _borrowWant(amount);

        return amount;
    }

    function _leverDownTo(uint256 newAmountBorrowed, uint256 currentBorrowed)
        internal
    {
        if (currentBorrowed > newAmountBorrowed) {
            uint256 totalRepayAmount = currentBorrowed- newAmountBorrowed;

            if (isFlashMintActive) {
                totalRepayAmount = totalRepayAmount - _leverDownFlashLoan(totalRepayAmount);
            }

            uint256 _maxCollatRatio = maxCollatRatio;

            for (
                uint8 i = 0;
                i < maxIterations && totalRepayAmount > minWant;
                i++
            ) {
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
        uint256 targetDeposit =
            _getDepositFromBorrow(borrows, _targetCollatRatio);
        if (targetDeposit > deposits) {
            uint256 toDeposit = targetDeposit - deposits;
            if (toDeposit > minWant) {
                _depositCollateral(Math.min(toDeposit, _balanceOfWant()));
            }
        } else {
            _withdrawExcessCollateral(_targetCollatRatio);
        }
    }

    function _leverDownFlashLoan(uint256 amount) internal returns (uint256) {
        if (amount <= minWant) return 0;
        (, uint256 borrows) = getCurrentPosition();
        if (amount > borrows) {
            amount = borrows;
        }
        return
            FlashMintLib.doFlashMint(
                true,
                amount,
                address(want),
                daiBorrowCollatRatio,
                0
            );
    }

    function _withdrawExcessCollateral(uint256 collatRatio)
        internal
        returns (uint256 amount)
    {
        (uint256 deposits, uint256 borrows) = getCurrentPosition();
        uint256 theoDeposits = _getDepositFromBorrow(borrows, collatRatio);
        if (deposits > theoDeposits) {
            uint256 toWithdraw = deposits - theoDeposits;
            return _withdrawCollateral(toWithdraw);
        }
    }

    function _depositCollateral(uint256 amount) internal returns (uint256) {
        if (amount == 0) return 0;
        _lendingPool.deposit(address(want), amount, address(this), _referral);
        return amount;
    }

    function _withdrawCollateral(uint256 amount) internal returns (uint256) {
        if (amount == 0) return 0;
        _lendingPool.withdraw(address(want), amount, address(this));
        return amount;
    }

    function _repayWant(uint256 amount) internal returns (uint256) {
        if (amount == 0) return 0;
        return _lendingPool.repay(address(want), amount, 2, address(this));
    }

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

    function onFlashLoan(
        address initiator,
        address token,
        uint256 amount,
        uint256 fee,
        bytes calldata data
    ) external override returns (bytes32) {
        require(msg.sender == FlashMintLib.LENDER);
        require(initiator == address(this));
        (bool deficit, uint256 amountWant) = abi.decode(data, (bool, uint256));

        return
            FlashMintLib.loanLogic(deficit, amountWant, amount, address(want));
    }

    function getCurrentPosition()
        public
        view
        returns (uint256 deposits, uint256 borrows)
    {
        deposits = _balanceOfAToken();
        borrows = _balanceOfDebtToken();
    }

    function getCurrentCollatRatio()
        public
        view
        returns (uint256 currentCollatRatio)
    {
        (uint256 deposits, uint256 borrows) = getCurrentPosition();

        if (deposits > 0) {
            currentCollatRatio = (borrows * _COLLATERAL_RATIO_PRECISION) / deposits;
        }
    }

    function getCurrentSupply() public view returns (uint256) {
        (uint256 deposits, uint256 borrows) = getCurrentPosition();
        return deposits - borrows;
    }

    // conversions
    function _tokenToWant(address token, uint256 amount)
        internal
        view
        returns (uint256)
    {
        if (amount == 0 || address(want) == token) {
            return amount;
        }

        // KISS: just use a v2 router for quotes which aren't used in critical logic
        IUni router =
            swapRouter == SwapRouter.SushiV2 ? _SUSHI_V2_ROUTER : _UNI_V2_ROUTER;
        uint256[] memory amounts =
            router.getAmountsOut(
                amount,
                _getTokenOutPathV2(token, address(want))
            );

        return amounts[amounts.length - 1];
    }

    function _checkCooldown() internal view returns (CooldownStatus) {
        uint256 cooldownStartTimestamp =
            IStakedAave(_stkAave).stakersCooldowns(address(this));
        uint256 COOLDOWN_SECONDS = IStakedAave(_stkAave).COOLDOWN_SECONDS();
        uint256 UNSTAKE_WINDOW = IStakedAave(_stkAave).UNSTAKE_WINDOW();
        uint256 nextClaimStartTimestamp = cooldownStartTimestamp + COOLDOWN_SECONDS;

        if (cooldownStartTimestamp == 0) {
            return CooldownStatus.None;
        }
        if (
            block.timestamp > nextClaimStartTimestamp &&
            block.timestamp <= nextClaimStartTimestamp + UNSTAKE_WINDOW
        ) {
            return CooldownStatus.Claim;
        }
        if (block.timestamp < nextClaimStartTimestamp) {
            return CooldownStatus.Initiated;
        }
    }

    function _getTokenOutPathV2(address _token_in, address _token_out)
        internal
        view
        returns (address[] memory _path)
    {
        bool is_weth =
            _token_in == address(_weth) || _token_out == address(_weth);
        _path = new address[](is_weth ? 2 : 3);
        _path[0] = _token_in;

        if (is_weth) {
            _path[1] = _token_out;
        } else {
            _path[1] = address(_weth);
            _path[2] = _token_out;
        }
    }

    function _getTokenOutPathV3(address _token_in, address _token_out)
        internal
        view
        returns (bytes memory _path)
    {
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
    }

    function _sellAAVEForWant(uint256 amountIn, uint256 minOut) internal {
        if (amountIn == 0) {
            return;
        }
        if (swapRouter == SwapRouter.UniV3) {
            _UNI_V3_ROUTER.exactInput(
                ISwapRouter.ExactInputParams(
                    _getTokenOutPathV3(address(_aave), address(want)),
                    address(this),
                    block.timestamp,
                    amountIn,
                    minOut
                )
            );
        } else {
            IUni router =
                swapRouter == SwapRouter.UniV2
                    ? _UNI_V2_ROUTER
                    : _SUSHI_V2_ROUTER;
            router.swapExactTokensForTokens(
                amountIn,
                minOut,
                _getTokenOutPathV2(address(_aave), address(want)),
                address(this),
                block.timestamp
            );
        }
    }

    function _sellSTKAAVEToAAVE(uint256 amountIn, uint256 minOut) internal {
        // Swap Rewards in UNIV3
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

    function _getAaveAssets() internal view returns (address[] memory assets) {
        assets = new address[](2);
        assets[0] = address(aToken);
        assets[1] = address(debtToken);
    }

    function _getProtocolCollatRatios(address token)
        internal
        view
        returns (uint256 ltv, uint256 liquidationThreshold)
    {
        (, ltv, liquidationThreshold, , , , , , , ) = _protocolDataProvider.getReserveConfigurationData(token);
        // convert bps to wad
        ltv = ltv * _BPS_WAD_RATIO;
        liquidationThreshold = liquidationThreshold * _BPS_WAD_RATIO;
    }

    function _getBorrowFromDeposit(uint256 deposit, uint256 collatRatio)
        internal
        pure
        returns (uint256)
    {
        return (deposit * collatRatio) / _COLLATERAL_RATIO_PRECISION;
    }

    function _getDepositFromBorrow(uint256 borrow, uint256 collatRatio)
        internal
        pure
        returns (uint256)
    {
        return (borrow * _COLLATERAL_RATIO_PRECISION) / collatRatio;
    }

    function _getBorrowFromSupply(uint256 supply, uint256 collatRatio)
        internal
        pure
        returns (uint256)
    {
        return (supply * collatRatio) / (_COLLATERAL_RATIO_PRECISION - collatRatio);
    }

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

    function estimatedAPR(UniswapOracle oracle) public view {
        (,,uint256 debtTokenTotalSupply, uint256 liquidityRate, uint256 variableBorrowRate,,,,,) = _protocolDataProvider.getReserveData(address(want));
        (uint256 deposits, uint256 borrows) = getCurrentPosition();
        uint256 yearlyRewardsATokenInUSDC;
        uint256 yearlyRewardsDebtTokenInUSDC;
        {
            uint256 stkAavePriceToUSDC = oracle.quoteUniswap(1 ether, 60);
            console.log("prix %s", stkAavePriceToUSDC);
            (uint256 emissionPerSecondAToken,,) = (aToken.getIncentivesController()).assets(address(aToken));
            (uint256 emissionPerSecondDebtToken,,) = (debtToken.getIncentivesController()).assets(address(debtToken));
            uint256 yearlyEmissionsAToken = emissionPerSecondAToken * 60 * 60 * 24 * 365; // BASE: 18
            uint256 yearlyEmissionsDebtToken = emissionPerSecondDebtToken * 60 * 60 * 24 * 365; // BASE: 18
            yearlyRewardsATokenInUSDC = (deposits * yearlyEmissionsAToken * stkAavePriceToUSDC / aToken.totalSupply()); // BASE 24
            yearlyRewardsDebtTokenInUSDC = (borrows * yearlyEmissionsDebtToken * stkAavePriceToUSDC / debtTokenTotalSupply); // BASE 24
            console.log("yearlyEmissions A %s", yearlyEmissionsAToken);
            console.log("yearlyEmissions Debt %s", yearlyEmissionsDebtToken);
            console.log("rewards A %s", yearlyRewardsATokenInUSDC);
            console.log("rewards Debt %s", yearlyRewardsDebtTokenInUSDC);
        }

        console.log("deposits %s / borrows %s", deposits, borrows);
        console.log("liquidityRate %s", liquidityRate);
        console.log("variableBorrowRate %s", variableBorrowRate);

        console.log("%s", liquidityRate * deposits);
        console.log("%s", variableBorrowRate * borrows);
        console.log("%s", yearlyRewardsATokenInUSDC + yearlyRewardsDebtTokenInUSDC);
        console.log("%s", (yearlyRewardsATokenInUSDC + yearlyRewardsDebtTokenInUSDC) * 10**3);
        // liquidityRate: BASE 27 (ray)
        // variableBorrowRate BASE 27 (ray)
        uint256 totalRewardsinUSDC = (liquidityRate * deposits) + ((yearlyRewardsATokenInUSDC + yearlyRewardsDebtTokenInUSDC) * 10**(27+6-24)) - (variableBorrowRate * borrows);
        console.log("totalRewardsinUSDC %s %s", totalRewardsinUSDC, totalRewardsinUSDC / 10**27);

        // console.log("allowance %s", IERC20(address(_stkAave)).allowance(address(this), address(_UNI_V3_ROUTER)));
        // console.log("balance %s", IERC20(address(_stkAave)).balanceOf(address(this)));
    }

    struct SCalculateBorrow {
        int256 slope1;
        int256 slope2;
        int256 r0;
        int256 totalStableDebt;
        int256 totalVariableDebt;
        int256 uOptimal;
        int256 totalDeposits;
        int256 reserveFactor;
        int256 stableBorrowRate;
        int256 rewardDeposit;
        int256 rewardBorrow;
        int256 poolManagerAssets;
    }

    int256 BASE_RAY = 10 ** 27;

    // borrow must be in BASE token (6 for USDC)
    function calculateInterest(int256 borrow, SCalculateBorrow memory parameters) public view returns(int256 interests) {
        int256 newUtilization = (parameters.totalStableDebt + parameters.totalVariableDebt + borrow) * BASE_RAY / (parameters.totalDeposits + borrow); // BASE ray / parameters.totalDeposits=(availableLiquidity + totalStableDebt + totalVariableDebt)

        if (newUtilization < parameters.uOptimal) {
            interests = parameters.r0 + parameters.slope1 * newUtilization / parameters.uOptimal;
        } else {
            interests = parameters.r0 + parameters.slope1 + parameters.slope2 * (newUtilization - parameters.uOptimal) / (BASE_RAY - parameters.uOptimal);
        }
        return interests;
    }

    // return value "interests" in BASE ray
    function calculateInterestPrime(int256 borrow, SCalculateBorrow memory parameters) public view returns(int256 interests) {
        int256 newUtilization = (parameters.totalStableDebt + parameters.totalVariableDebt + borrow) * BASE_RAY / (parameters.totalDeposits + borrow); // BASE ray (availableLiquidity + totalStableDebt + totalVariableDebt)

        // uint256 uprime = (parameters.totalDeposits - parameters.totalStableDebt - parameters.totalVariableDebt) * 10**(6*2) * BASE_RAY / ((parameters.totalDeposits + borrow) ** 2); // BASE ray
        int256 uprime = (parameters.totalDeposits - parameters.totalStableDebt - parameters.totalVariableDebt) * BASE_RAY / (parameters.totalDeposits + borrow); // BASE ray
        uprime = uprime * BASE_RAY / (parameters.totalDeposits + borrow); // BASE ray
        if (newUtilization < parameters.uOptimal) {
            interests = parameters.slope1 * uprime / parameters.uOptimal;
        } else {
            interests = parameters.slope2 * uprime / (BASE_RAY - parameters.uOptimal);
        }

        return interests;
    }

    // return value "interests" in BASE ray
    function calculateInterestPrime2(int256 borrow, SCalculateBorrow memory parameters) public view returns(int256 interests) {
        int256 newUtilization = (parameters.totalStableDebt + parameters.totalVariableDebt + borrow) * BASE_RAY / (parameters.totalDeposits + borrow); // BASE ray (availableLiquidity + totalStableDebt + totalVariableDebt)

        // uint256 uprime = 2 * ((parameters.totalDeposits - parameters.totalStableDebt - parameters.totalVariableDebt) *  10**(6*3) * BASE_RAY) / ((parameters.totalDeposits + borrow) ** 3); // BASE ray
        int256 uprime = -2 * (parameters.totalDeposits - parameters.totalStableDebt - parameters.totalVariableDebt) * (BASE_RAY) / (parameters.totalDeposits + borrow); // BASE ray
        uprime = uprime * BASE_RAY / (parameters.totalDeposits + borrow); // BASE ray
        uprime = uprime * BASE_RAY / (parameters.totalDeposits + borrow); // BASE ray
        if (newUtilization < parameters.uOptimal) {
            interests = parameters.slope1 * uprime / parameters.uOptimal;
        } else {
            interests = parameters.slope2 * uprime / (BASE_RAY - parameters.uOptimal);
        }
        return interests;
    }

    function revenue(int256 borrow, SCalculateBorrow memory parameters) public view returns(int256) {
        int256 newRate = calculateInterest(borrow, parameters);
        int256 poolManagerFund = parameters.poolManagerAssets;
        int256 newPoolDeposit = borrow + poolManagerFund;
        int256 newCompDeposit = borrow + parameters.totalDeposits;
        int256 newCompBorrowVariable = borrow + parameters.totalVariableDebt;

        int256 f1 = newPoolDeposit * (BASE_RAY - parameters.reserveFactor) / newCompDeposit;
        int256 f2 = (parameters.totalStableDebt * parameters.stableBorrowRate  + newCompBorrowVariable * newRate) / BASE_RAY;
        
        int256 earnings = (f1 * f2) / BASE_RAY;
        int256 cost = (borrow * newRate) / BASE_RAY;
        int256 rewards = borrow / (parameters.totalStableDebt + newCompBorrowVariable) * parameters.rewardBorrow + (poolManagerFund+borrow)/newCompDeposit * parameters.rewardDeposit;
        return  earnings + rewards - cost;
    }

    struct SRevenuePrimeVars {
        int256 newRate;
        int256 newRatePrime;
        int256 poolManagerFund;
        int256 newPoolDeposit;
        int256 newCompDeposit;
        int256 newCompBorrowVariable;
        int256 newCompBorrow;
    }
    function revenuePrimeVars(int256 borrow, SCalculateBorrow memory parameters) public view returns(SRevenuePrimeVars memory) {
        int256 newRate = calculateInterest(borrow, parameters);
        int256 newRatePrime = calculateInterestPrime(borrow, parameters);

        int256 poolManagerFund = parameters.poolManagerAssets;
        int256 newPoolDeposit = borrow + poolManagerFund;
        int256 newCompDeposit = borrow + parameters.totalDeposits;
        int256 newCompBorrowVariable = borrow + parameters.totalVariableDebt;
        int256 newCompBorrow = newCompBorrowVariable + parameters.totalStableDebt;
        return SRevenuePrimeVars({
            newRate: newRate,
            newRatePrime: newRatePrime,
            poolManagerFund: poolManagerFund,
            newPoolDeposit: newPoolDeposit,
            newCompDeposit: newCompDeposit,
            newCompBorrowVariable: newCompBorrowVariable,
            newCompBorrow: newCompBorrow
        });
    }

    function revenuePrime(int256 borrow, SCalculateBorrow memory parameters) public view returns(int256) {
        SRevenuePrimeVars memory vars = revenuePrimeVars(borrow, parameters);

        int256 f1 = vars.newPoolDeposit * (BASE_RAY - parameters.reserveFactor) / vars.newCompDeposit;
        int256 f2 = (parameters.totalStableDebt * parameters.stableBorrowRate + vars.newCompBorrowVariable * vars.newRate) / BASE_RAY;

        int256 f1prime = (parameters.totalDeposits - vars.poolManagerFund) * (BASE_RAY - parameters.reserveFactor) / vars.newCompDeposit;
        f1prime = f1prime * BASE_RAY / vars.newCompDeposit;
        int256 f2prime = (vars.newRate * BASE_RAY + vars.newCompBorrowVariable * vars.newRatePrime) / BASE_RAY;
        int256 f3prime = (vars.newRate * BASE_RAY + borrow * vars.newRatePrime) / BASE_RAY;
        
        // int256 f4prime = parameters.rewardBorrow * (parameters.totalStableDebt + parameters.totalVariableDebt) / vars.newCompBorrow**2 + parameters.rewardDeposit * (parameters.totalDeposits - vars.poolManagerFund) / vars.newPoolDeposit**2;
        int256 f4prime1 = parameters.rewardBorrow * (parameters.totalStableDebt + parameters.totalVariableDebt) / vars.newCompBorrow;
        f4prime1 = f4prime1 * BASE_RAY / vars.newCompBorrow;
        int256 f4prime2 = parameters.rewardDeposit * (parameters.totalDeposits - vars.poolManagerFund) / vars.newPoolDeposit;
        f4prime2 = f4prime2 * BASE_RAY / vars.newPoolDeposit;
        
        return ((f1prime*f2 + f2prime*f1) / BASE_RAY) - f3prime + (f4prime1+f4prime2);
    }

    function revenuePrime2(int256 borrow, SCalculateBorrow memory parameters) public view returns(int256) {
        int256 newRatePrime2 = calculateInterestPrime2(borrow, parameters);
        SRevenuePrimeVars memory vars = revenuePrimeVars(borrow, parameters);

        int256 derivate;
        {
            int256 f1 = vars.newPoolDeposit * (BASE_RAY - parameters.reserveFactor) / vars.newCompDeposit;
            int256 f2 = (parameters.totalStableDebt * parameters.stableBorrowRate + vars.newCompBorrowVariable * vars.newRate) / BASE_RAY;
            int256 f1prime = (parameters.totalDeposits - vars.poolManagerFund) * (BASE_RAY - parameters.reserveFactor) / vars.newCompDeposit;
            f1prime = f1prime * BASE_RAY / vars.newCompDeposit;
            int256 f2prime = (vars.newRate * BASE_RAY + vars.newCompBorrowVariable * vars.newRatePrime) / BASE_RAY;

            int256 f1prime2nd = - (parameters.totalDeposits - vars.poolManagerFund) * (BASE_RAY - parameters.reserveFactor) * 2 / (vars.newCompDeposit);
            f1prime2nd = f1prime2nd * (BASE_RAY) / (vars.newCompDeposit);
            f1prime2nd = f1prime2nd * (BASE_RAY) / (vars.newCompDeposit);

            int256 f2prime2nd = ((vars.newRatePrime * BASE_RAY + vars.newRatePrime * BASE_RAY) + (vars.newCompBorrowVariable) * newRatePrime2) / (BASE_RAY);
            int256 f3prime2nd = ((vars.newRatePrime * BASE_RAY + vars.newRatePrime * BASE_RAY) + (borrow) * newRatePrime2) / (BASE_RAY);

            // int256 f4prime2nd = parameters.rewardBorrow * (parameters.totalStableDebt + parameters.totalVariableDebt) * 2/ vars.newCompBorrow**3 + parameters.rewardDeposit * (parameters.totalDeposits - vars.poolManagerFund) * 2 / vars.newPoolDeposit**3;
            int256 f4prime2nd1 = - (parameters.rewardBorrow) * (parameters.totalStableDebt + parameters.totalVariableDebt) * 2 / (vars.newCompBorrow);
            f4prime2nd1 = f4prime2nd1 * (BASE_RAY) / (vars.newCompBorrow);
            f4prime2nd1 = f4prime2nd1 * (BASE_RAY) / (vars.newCompBorrow);
            int256 f4prime2nd2 = (parameters.rewardDeposit) * (parameters.totalDeposits - vars.poolManagerFund) * 2 / (vars.newPoolDeposit);
            f4prime2nd2 = f4prime2nd2 * (BASE_RAY) / (vars.newPoolDeposit);
            f4prime2nd2 = f4prime2nd2 * (BASE_RAY) / (vars.newPoolDeposit);
            
            derivate = f1prime2nd * (f2) + (f1prime * f2prime) + (f2prime * f1prime) + f2prime2nd*(f1) - f3prime2nd * (BASE_RAY) - (f4prime2nd1 + f4prime2nd2) * (BASE_RAY);
        }

        return derivate / (BASE_RAY);
    }

    function revenue3D(int256 borrow, int256 rewards, SCalculateBorrow memory parameters) public view returns(int256) {
        int256 newRate = calculateInterest(borrow, parameters);
        int256 poolManagerFund = parameters.poolManagerAssets;
        int256 newPoolDeposit = borrow + poolManagerFund;
        int256 newCompDeposit = borrow + parameters.totalDeposits;
        int256 newCompBorrowVariable = borrow + parameters.totalVariableDebt;

        int256 earnings = newPoolDeposit * (BASE_RAY - parameters.reserveFactor) * (parameters.totalStableDebt * parameters.stableBorrowRate  + newCompBorrowVariable * newRate) / newCompDeposit;
        int256 cost = (borrow * newRate) / BASE_RAY;
        rewards = borrow * rewards / BASE_RAY;
        return  earnings + rewards - cost;
    }

    function abs(int256 x) private pure returns (int256) {
        return x >= 0 ? x : -x;
    }

    function computeAlpha(int256 count) private view returns(int256) {
        return 5000;
    }

    function gradientDescent(int256 _borrow, int256 tolerance, SCalculateBorrow memory parameters) public view returns(int256 borrow, int256 count) {
        int256 grad = tolerance + 1;
        count = 0;
        borrow = _borrow;
        while (abs(grad) > tolerance) {
            grad = - revenuePrime(borrow, parameters);
            int256 alpha = computeAlpha(count);
            borrow = borrow - alpha * grad;
            count +=1;
        }
    }

    function newtonRaphson(int256 _borrow, int256 epsilon, int256 tolerance, SCalculateBorrow memory parameters) public view returns(int256 borrow, int256 count) {
        int256 grad = tolerance + 1;
        int256 grad2nd = grad;
        count = 0;
        int256 borrowInit = _borrow;
        borrow = _borrow;
        while (abs(grad2nd) > tolerance && (count == 0 || abs(borrowInit - borrow) > tolerance)) {
            grad = - revenuePrime(borrow, parameters);
            grad2nd = - revenuePrime2(borrow, parameters);
            borrowInit = borrow;
            borrow = borrowInit - grad * BASE_RAY / grad2nd;
            count +=1;
        }
    }

    function calculateBorrow() public view {
        (, uint256 totalStableDebt, uint256 totalVariableDebt, uint256 liquidityRate, uint256 variableBorrowRate, uint256 stableBorrowRate,,,,) = _protocolDataProvider.getReserveData(address(want));
        (,,,, uint256 reserveFactor,,,,,) = _protocolDataProvider.getReserveConfigurationData(address(want));
        IReserveInterestRateStrategy interestRateStrategyAddress = IReserveInterestRateStrategy((_lendingPool.getReserveData(address(want))).interestRateStrategyAddress);
        
        (uint256 emissionPerSecondAToken,,) = (aToken.getIncentivesController()).assets(address(aToken));
        (uint256 emissionPerSecondDebtToken,,) = (debtToken.getIncentivesController()).assets(address(debtToken));

        // SCalculateBorrow memory parameters = SCalculateBorrow({
        //     slope1: interestRateStrategyAddress.variableRateSlope1(), // ray
        //     slope2: interestRateStrategyAddress.variableRateSlope2(), // ray
        //     r0: interestRateStrategyAddress.baseVariableBorrowRate(), // ray
        //     totalStableDebt: totalStableDebt * 10**21, // ray / base USDC: 6 
        //     totalVariableDebt: totalVariableDebt * 10**21, // ray / base USDC: 6 
        //     uOptimal: interestRateStrategyAddress.OPTIMAL_UTILIZATION_RATE(), // ray
        //     totalDeposits: aToken.totalSupply() * 10**21, // ray / base USDC: 6 
        //     reserveFactor: reserveFactor * 10**23, // ray / reserveFactor: base 4
        //     stableBorrowRate: stableBorrowRate, // ray
        //     rewardDeposit: emissionPerSecondAToken * 10**9, // ray / emissionPerSecondAToken: base 18 (stkAave)
        //     rewardBorrow: emissionPerSecondDebtToken * 10**9, // ray / emissionPerSecondDebtToken: base 18 (stkAave)
        //      poolManagerAssets: poolManager.getTotalAsset() * 10**21
        // });
        SCalculateBorrow memory parameters = SCalculateBorrow({
            slope1: 40000000000000000000000000,
            slope2: 600000000000000000000000000,
            r0: 0,
            totalStableDebt: 12952786073367000000000000000000000,
            totalVariableDebt: 1350219982386577000000000000000000000,
            uOptimal: 900000000000000000000000000,
            totalDeposits: 2327880275443382000000000000000000000,
            reserveFactor: 100000000000000000000000000,
            stableBorrowRate: 103013007441955644227054734,
            rewardDeposit: 1903258773510960000000000,
            rewardBorrow: 3806517547021920000000000,
            poolManagerAssets: 168439706352281000000000000000000000
        });
        
        // console.log("%s", interestRateStrategyAddress.variableRateSlope1());
        // console.log("%s", interestRateStrategyAddress.variableRateSlope2());
        // console.log("%s", interestRateStrategyAddress.baseVariableBorrowRate());
        // console.log("%s", totalStableDebt * 10**21);
        // console.log("%s", totalVariableDebt * 10**21);
        // console.log("%s", interestRateStrategyAddress.OPTIMAL_UTILIZATION_RATE());
        // console.log("%s", aToken.totalSupply() * 10**21);
        // console.log("%s", reserveFactor * 10**23);
        // console.log("%s", stableBorrowRate);
        // console.log("%s", emissionPerSecondAToken * 10**9);
        // console.log("%s", emissionPerSecondDebtToken * 10**9);


        console.log("interests");
        console.logInt(calculateInterest(BASE_RAY * 0, parameters));
        console.logInt(calculateInterest(BASE_RAY * 1, parameters));
        console.logInt(calculateInterest(BASE_RAY * 5, parameters));
        console.logInt(calculateInterest(BASE_RAY * 10, parameters));
        console.logInt(calculateInterest(BASE_RAY * 100, parameters));
        console.logInt(calculateInterest(BASE_RAY * 1000, parameters));
        console.logInt(calculateInterest(BASE_RAY * 58749, parameters));
        console.logInt(calculateInterest(BASE_RAY * 100000, parameters));
        console.logInt(calculateInterest(BASE_RAY * 3089873, parameters));
        console.logInt(calculateInterest(BASE_RAY * 28746827, parameters));

        console.log("interests prime");
        console.logInt(calculateInterestPrime(BASE_RAY * 0, parameters));
        console.logInt(calculateInterestPrime(BASE_RAY * 1, parameters));
        console.logInt(calculateInterestPrime(BASE_RAY * 5, parameters));
        console.logInt(calculateInterestPrime(BASE_RAY * 10, parameters));
        console.logInt(calculateInterestPrime(BASE_RAY * 100, parameters));
        console.logInt(calculateInterestPrime(BASE_RAY * 1000, parameters));
        console.logInt(calculateInterestPrime(BASE_RAY * 58749, parameters));
        console.logInt(calculateInterestPrime(BASE_RAY * 100000, parameters));
        console.logInt(calculateInterestPrime(BASE_RAY * 3089873, parameters));
        console.logInt(calculateInterestPrime(BASE_RAY * 28746827, parameters));
        
        console.log("interests prime 2");
        console.logInt(calculateInterestPrime2(BASE_RAY * 0, parameters));
        console.logInt(calculateInterestPrime2(BASE_RAY * 1, parameters));
        console.logInt(calculateInterestPrime2(BASE_RAY * 5, parameters));
        console.logInt(calculateInterestPrime2(BASE_RAY * 10, parameters));
        console.logInt(calculateInterestPrime2(BASE_RAY * 100, parameters));
        console.logInt(calculateInterestPrime2(BASE_RAY * 1000, parameters));
        console.logInt(calculateInterestPrime2(BASE_RAY * 58749, parameters));
        console.logInt(calculateInterestPrime2(BASE_RAY * 100000, parameters));
        console.logInt(calculateInterestPrime2(BASE_RAY * 3089873, parameters));
        console.logInt(calculateInterestPrime2(BASE_RAY * 28746827, parameters));

        console.log("revenue");
        console.logInt(revenue(BASE_RAY * 0, parameters));
        console.logInt(revenue(BASE_RAY * 1, parameters));
        console.logInt(revenue(BASE_RAY * 5, parameters));
        console.logInt(revenue(BASE_RAY * 10, parameters));
        console.logInt(revenue(BASE_RAY * 100, parameters));
        console.logInt(revenue(BASE_RAY * 1000, parameters));
        console.logInt(revenue(BASE_RAY * 58749, parameters));
        console.logInt(revenue(BASE_RAY * 100000, parameters));
        console.logInt(revenue(BASE_RAY * 3089873, parameters));
        console.logInt(revenue(BASE_RAY * 28746827, parameters));

        console.log("revenuePrime");
        console.logInt(revenuePrime(BASE_RAY * 0, parameters));
        console.logInt(revenuePrime(BASE_RAY * 1, parameters));
        console.logInt(revenuePrime(BASE_RAY * 5, parameters));
        console.logInt(revenuePrime(BASE_RAY * 10, parameters));
        console.logInt(revenuePrime(BASE_RAY * 100, parameters));
        console.logInt(revenuePrime(BASE_RAY * 1000, parameters));
        console.logInt(revenuePrime(BASE_RAY * 58749, parameters));
        console.logInt(revenuePrime(BASE_RAY * 100000, parameters));
        console.logInt(revenuePrime(BASE_RAY * 3089873, parameters));
        console.logInt(revenuePrime(BASE_RAY * 28746827, parameters));

        console.log("revenue prime 2");
        console.logInt(revenuePrime2(BASE_RAY * 0, parameters));
        console.logInt(revenuePrime2(BASE_RAY * 1, parameters));
        console.logInt(revenuePrime2(BASE_RAY * 5, parameters));
        console.logInt(revenuePrime2(BASE_RAY * 10, parameters));
        console.logInt(revenuePrime2(BASE_RAY * 100, parameters));
        console.logInt(revenuePrime2(BASE_RAY * 1000, parameters));
        console.logInt(revenuePrime2(BASE_RAY * 58749, parameters));
        console.logInt(revenuePrime2(BASE_RAY * 100000, parameters));
        console.logInt(revenuePrime2(BASE_RAY * 3089873, parameters));
        console.logInt(revenuePrime2(BASE_RAY * 28746827, parameters));

        int256 epsilon = 10**(27-4);
        int256 tolerance = 10**(27-8);
        // gradientDescent(BASE_RAY * 100, epsilon, parameters);
        (int b, int count) = newtonRaphson(168439706352281000000000000000000000, epsilon, tolerance, parameters);
        console.log("newtonRaphson");
        console.logInt(b);
        console.logInt(count);

        // uint256 borrow = BASE_RAY * 0;
        // computeInterestRate
        // uint256 interests = calculateInterest(borrow, parameters);
        // uint256 interests2 = calculateInterestPrime(borrow, parameters);
        // uint256 interests3 = calculateInterestPrime2(borrow, parameters);
        // console.log("interests %s %s", interests, variableBorrowRate);
        // console.log("interests2 %s", interests2);
        // console.log("interests3 %s", interests3);
        // console.log("revenue %s", revenue(borrow, parameters));
        // console.log("revenuePrime %s", revenuePrime(borrow, parameters));
        // console.logInt(revenuePrime2(0, parameters));
    }

    // function test() public {
    //     console.log("balance before %s", want.balanceOf(address(this)));
    //     console.log("balance before %s", aToken.balanceOf(address(this)));
    //     _depositCollateral(99*1e6);
    //     console.log("balance after %s", want.balanceOf(address(this)));
    //     console.log("balance after %s", aToken.balanceOf(address(this)));
    // }
}