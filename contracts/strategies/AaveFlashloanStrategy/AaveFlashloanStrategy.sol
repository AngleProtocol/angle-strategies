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
import "../BaseStrategyUpgradeable.sol";
import "./ComputeProfitability.sol";

// solhint-disable-next-line max-states-count
contract AaveFlashloanStrategy is BaseStrategyUpgradeable, IERC3156FlashBorrower {
    using SafeERC20 for IERC20;
    using Address for address;

    bytes32 public constant KEEPER_ROLE = keccak256("KEEPER_ROLE");

    // =========================== Constant Addresses ==============================

    /// @notice Router used for swaps
    address public constant oneInch = 0x1111111254fb6c44bAC0beD2854e76F90643097d;
    /// @notice Chainlink oracle used to fetch data
    AggregatorV3Interface public constant chainlinkOracle = AggregatorV3Interface(0x547a514d5e3769680Ce22B2361c10Ea13619e8a9);

    // ========================== Aave Protocol Addresses ==========================

    IProtocolDataProvider private constant _protocolDataProvider = IProtocolDataProvider(0x057835Ad21a177dbdd3090bB1CAE03EaCF78Fc6d);
    IAaveIncentivesController private constant _incentivesController = IAaveIncentivesController(0xd784927Ff2f95ba542BfC824c8a8a98F3495f6b5);
    ILendingPool private constant _lendingPool = ILendingPool(0x7d2768dE32b0b80b7a3454c06BdAc94A69DDc7A9);
    IReserveInterestRateStrategy private constant _interestRateStrategyAddress = IReserveInterestRateStrategy(0x8Cae0596bC1eD42dc3F04c4506cfe442b3E74e27);

    // ============================== Token Addresses ==============================

    address private constant _aave = 0x7Fc66500c84A76Ad7e9c93437bFc5Ac33E2DDaE9;
    IStakedAave private constant _stkAave = IStakedAave(0x4da27a545c0c5B758a6BA100e3a049001de870f5);
    address private constant _weth = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address private constant _dai = 0x6B175474E89094C44Da98b954EedeAC495271d0F;

    // ============================== Ops Constants ================================

    uint256 private constant _DEFAULT_COLLAT_TARGET_MARGIN = 0.02 ether;
    uint256 private constant _DEFAULT_COLLAT_MAX_MARGIN = 0.005 ether;
    uint256 private constant _LIQUIDATION_WARNING_THRESHOLD = 0.01 ether;
    uint256 private constant _BPS_WAD_RATIO = 1e14;
    uint256 private constant _COLLATERAL_RATIO_PRECISION = 1 ether;
    /// @notice Reflects a penalty on the AAVE price
    uint256 private constant _DISCOUNT_FACTOR = 9000; 
    // TODO: get a referral code from AAVE https://docs.aave.com/developers/v/1.0/integrating-aave/referral-program
    uint16 private constant _referral = 0;

    // ========================= Supply and Borrow Tokens ==========================

    IAToken public aToken;
    IVariableDebtToken public debtToken;

    // ========================= Aave Protocol Parameters ==========================
    // All these parameters are in base 27. They can be fetched at any time directly from
    // the Aave protocol if there is an update

    int256 public lendingPoolVariableRateSlope1; 
    int256 public lendingPoolVariableRateSlope2; 
    int256 public lendingPoolBaseVariableBorrowRate; 
    int256 public lendingPoolOptimalUtilizationRate;
    int256 public aaveReserveFactor;
    uint256 public cooldownSeconds;
    uint256 public unstakeWindow;

    // =============================== Parameters ==================================

    /// @notice Maximum the Aave protocol will let us borrow
    uint256 public maxBorrowCollatRatio;
    /// @notice LTV the strategy is going to lever up to
    uint256 public targetCollatRatio;
    /// @notice Closest to liquidation we'll risk
    uint256 public maxCollatRatio; 
    /// @notice Parameter used for flash mints
    uint256 public daiBorrowCollatRatio;
    /// @notice Whether the collat ratio should be automatically computed
    bool public automaticallyComputeCollatRatio;
    /// @notice Max number of iterations possible for the computation of the optimal lever
    uint8 public maxIterations;
    /// @notice Whether flash mint is active
    bool public isFlashMintActive;
    bool public withdrawCheck;
    uint256 public minWant;
    uint256 public minRatio;
    bool public cooldownStkAave;

    // =============================== Variables ===================================

    /// @notice Signal whether a position adjustment was done in `prepareReturn`
    bool private _alreadyAdjusted; 
    /// @notice Decimals of the `want` token
    uint256 private _decimals;

    // =============================== Reference ===================================

    /// @notice Library to compute the profitability of a leverage operation
    ComputeProfitability public computeProfitability;

    // =============================== Enum ========================================

    /// @notice Represents stkAave cooldown status
    // 0 = no cooldown or past withdraw period
    // 1 = claim period
    // 2 = cooldown initiated, future claim period
    enum CooldownStatus {None, Claim, Initiated}

    // ============================ Initializer ====================================

    /// @notice Constructor of the `Strategy`
    /// @param _poolManager Address of the `PoolManager` lending to this strategy
    /// @param _rewards  The token given to reward keepers
    /// @param governorList List of addresses with governor privilege
    /// @param guardian Address of the guardian
    /// @param keepers List of the addresses with keeper privilege
    /// @param _computeProfitability Reference to the contract used to compute leverage
    function initialize(
        address _poolManager,
        IERC20 _rewards,
        address[] memory governorList,
        address guardian,
        address[] memory keepers,
        ComputeProfitability _computeProfitability
    ) external {
        _initialize(_poolManager, _rewards, governorList, guardian);

        require(address(_computeProfitability) != address(0), "0");
        computeProfitability = _computeProfitability;

        // We first initialize operational state
        maxIterations = 6;
        isFlashMintActive = true;
        withdrawCheck = false;

        // Setting mins
        minWant = 100;
        minRatio = 0.005 ether;

        // Setting reward params
        cooldownStkAave = false;
        _alreadyAdjusted = false;
        automaticallyComputeCollatRatio = true;
        _setAavePoolVariables();

        // Set AAVE tokens
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

        _decimals = wantBase;

        // Performing all the different approvals possible
        _approveMaxSpend(address(want), address(_lendingPool));
        _approveMaxSpend(address(aToken), address(_lendingPool));

        // Approve flashloan spend
        if (address(want) != _dai) {
            _approveMaxSpend(_dai, address(_lendingPool));
        }
        _approveMaxSpend(_dai, FlashMintLib.LENDER);

        // Approve swap router spend
        _approveMaxSpend(address(_stkAave), oneInch);
        _approveMaxSpend(_aave, oneInch);

        for (uint256 i = 0; i < keepers.length; i++) {
            require(keepers[i] != address(0), "0");
            _setupRole(KEEPER_ROLE, keepers[i]);
        }
        _setRoleAdmin(KEEPER_ROLE, GUARDIAN_ROLE);
    }

    // ============================== Setters ======================================

    /// @notice Sets collateral targets
    function setCollateralTargets(
        uint256 _targetCollatRatio,
        uint256 _maxCollatRatio,
        uint256 _maxBorrowCollatRatio,
        uint256 _daiBorrowCollatRatio
    ) external onlyRole(GUARDIAN_ROLE) {
        (uint256 ltv, uint256 liquidationThreshold) = _getProtocolCollatRatios(address(want));
        (uint256 daiLtv, ) = _getProtocolCollatRatios(_dai);
        require(_targetCollatRatio < liquidationThreshold && _maxCollatRatio < liquidationThreshold && _targetCollatRatio < _maxCollatRatio && _maxBorrowCollatRatio < ltv && _daiBorrowCollatRatio < daiLtv, "8");

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

    function setRewardBehavior(bool _cooldownStkAave) external onlyRole(GUARDIAN_ROLE) {
        cooldownStkAave = _cooldownStkAave;
    }

    /// @notice Retrieves lending pool rates for `want`. Those variables are mostly used in `computeMostProfitableBorrow`
    /// @dev No access control needed because they fetch the values from Aave directly. If it changes there, it will need to be updated here too
    function setAavePoolVariables() external {
        _setAavePoolVariables();
    }

    /// @notice Retrieves lending pool rates for `want`. Those variables are mostly used in `computeMostProfitableBorrow`
    /// @dev No access control needed because they fetch the values from Aave directly. If it changes there, it will need to be updated here too
    function _setAavePoolVariables() internal {
        (,,,, uint256 reserveFactor,,,,,) = _protocolDataProvider.getReserveConfigurationData(address(want));
        
        lendingPoolVariableRateSlope1 = int256(_interestRateStrategyAddress.variableRateSlope1());
        lendingPoolVariableRateSlope2 = int256(_interestRateStrategyAddress.variableRateSlope2());
        lendingPoolBaseVariableBorrowRate = int256(_interestRateStrategyAddress.baseVariableBorrowRate());
        lendingPoolOptimalUtilizationRate = int256(_interestRateStrategyAddress.OPTIMAL_UTILIZATION_RATE());
        aaveReserveFactor = int256(reserveFactor * 10**23);
        cooldownSeconds = IStakedAave(_stkAave).COOLDOWN_SECONDS();
        unstakeWindow = IStakedAave(_stkAave).UNSTAKE_WINDOW();
    }

    /// @notice Decide whether `targetCollatRatio` should be computed automatically or manually
    function setAutomaticallyComputeCollatRatio(bool _automaticallyComputeCollatRatio) external onlyRole(GUARDIAN_ROLE) {
        automaticallyComputeCollatRatio = _automaticallyComputeCollatRatio;
    }

    function estimatedTotalAssets() public view override returns (uint256) {
        uint256 wantBalance = _balanceOfWant();
        return estimatedTotalAssetsExcludingRewards(wantBalance) + estimatedRewardsInWant(wantBalance);
    }

    function estimatedTotalAssetsExcludingRewards(uint256 wantBalance) public view returns (uint256) {
        if (wantBalance != 0) return  wantBalance + getCurrentSupply();
        else return _balanceOfWant() + getCurrentSupply();
    }

    function estimatedRewardsInWant(uint256 wantBalance) public view returns (uint256) { 
        if (wantBalance == 0) wantBalance = _balanceOfWant();
        // Adding the AAVE Balance to the StkAAVE Balance to the pending rewards balance       
        return estimatedAAVEToWant(wantBalance +  _balanceOfStkAave() + _incentivesController.getRewardsBalance(_getAaveAssets(), address(this)));
    }

    /// @notice Frees up profit plus `_debtOutstanding`.
    /// @param _debtOutstanding Amount to withdraw
    /// @return _profit Profit freed by the call
    /// @return _loss Loss discovered by the call
    /// @return _debtPayment Amount freed to reimburse the debt
    /// @dev If `_debtOutstanding` is more than we can free we get as much as possible.
    function _prepareReturn(uint256 _debtOutstanding) internal override returns (uint256 _profit, uint256 _loss, uint256 _debtPayment) {
        _claimRewards();

        // account for profit / losses
        uint256 totalDebt = poolManager.strategies(address(this)).totalStrategyDebt;

        // Assets immediately convertible to want only
        uint256 amountAvailable = _balanceOfWant();
        uint256 totalAssets = estimatedTotalAssetsExcludingRewards(amountAvailable);

        if (totalDebt > totalAssets) {
            // we have losses
            _loss = totalDebt - totalAssets;
        } else {
            // we have profit
            _profit = totalAssets - totalDebt;
        }

        // free funds to repay debt + profit to the strategy
        uint256 amountRequired = _debtOutstanding + _profit;

        if (amountRequired > amountAvailable) {
            // we need to free funds
            // we dismiss losses here, they cannot be generated from withdrawal
            // but it is possible for the strategy to unwind full position
            (amountAvailable, ) = _liquidatePosition(amountRequired, amountAvailable);

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
            // Updating the `wantBalance` value
            wantBalance = _balanceOfWant();
        }

        (uint256 deposits, uint256 borrows) = getCurrentPosition();
        if (automaticallyComputeCollatRatio) {
            _computeOptimalCollatRatio(wantBalance, deposits - borrows);
        }

        // check current position
        uint256 currentCollatRatio = _getCurrentCollatRatio(deposits, borrows);

        // Either we need to free some funds OR we want to be max levered
        if (_debtOutstanding > wantBalance) {
            // we should free funds
            uint256 amountRequired = _debtOutstanding - wantBalance;

            // NOTE: vault will take free funds during the next harvest
            _freeFunds(amountRequired, deposits, borrows);
        } else if (currentCollatRatio < targetCollatRatio) {
            // we should lever up
            if (targetCollatRatio - currentCollatRatio > minRatio) {
                // we only act on relevant differences
                _leverMax(deposits, borrows);
            }
        } else if (currentCollatRatio > targetCollatRatio) {
            if (currentCollatRatio - targetCollatRatio > minRatio) {
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
    function _liquidatePosition(uint256 _amountNeeded, uint256 wantBalance) internal override returns (uint256 _liquidatedAmount, uint256 _loss) {
        // NOTE: Maintain invariant `want.balanceOf(this) >= _liquidatedAmount`
        // NOTE: Maintain invariant `_liquidatedAmount + _loss <= _amountNeeded`
        if (wantBalance > _amountNeeded) {
            // if there is enough free want, let's use it
            return (_amountNeeded, 0);
        }

        // we need to free funds
        uint256 amountRequired = _amountNeeded - wantBalance;
        _freeFunds(amountRequired, 0, 0);
        // Updating the `wantBalance` variable
        wantBalance = _balanceOfWant();
        if (_amountNeeded > wantBalance) {
            _liquidatedAmount = wantBalance;
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

        (_amountFreed, ) = _liquidatePosition(type(uint256).max, _balanceOfWant());
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

    // INTERNAL ACTIONS

    /// @notice Claim earned stkAAVE (only called at `harvest`)
    /// @dev stkAAVE require a "cooldown" period of 10 days before being claimed
    function _claimRewards() internal returns(uint256 stkAaveBalance) {
        stkAaveBalance = _balanceOfStkAave();
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
    }

    function _revertBytes(bytes memory errMsg) internal pure {
        if (errMsg.length > 0) {
            //solhint-disable-next-line
            assembly {
                revert(add(32, errMsg), mload(errMsg))
            }
        }
        revert("117");
    }

    /// @notice Swap earned stkAave them for `want` through 1Inch
    /// @param minAmountOut Minimum amount of `want` to receive for the swap to happen
    /// @param payload Bytes needed for 1Inch API. Tokens swapped should be: stkAave -> `want`
    function sellRewards(uint256 minAmountOut, bytes memory payload, bool claim) external onlyRole(KEEPER_ROLE) {
        uint256 stkAaveBalance;
        if (claim) {
            stkAaveBalance = _claimRewards();
        } else {
            stkAaveBalance = _balanceOfStkAave();
        }

        (bool success, bytes memory result) = oneInch.call(payload);
        if (!success) _revertBytes(result);

        uint256 amountOut = abi.decode(result, (uint256));
        require(amountOut >= minAmountOut, "15");
    }

    /// @notice Reduce exposure by withdrawing funds and repaying debt
    /// @param amountToFree Amount of `want` to withdraw/repay
    /// @return balance Current balance of `want`
    function _freeFunds(uint256 amountToFree, uint256 deposits, uint256 borrows) internal returns (uint256) {
        if (amountToFree == 0) return 0;
        if (deposits == 0 && borrows == 0) (deposits, borrows) = getCurrentPosition();

        uint256 realAssets = deposits - borrows;
        uint256 newBorrow = _getBorrowFromSupply(realAssets - Math.min(amountToFree, realAssets), targetCollatRatio);

        // repay required amount
        _leverDownTo(newBorrow, borrows);

        return _balanceOfWant();
    }

    /// @notice Get exposure up to `targetCollatRatio`
    function _leverMax(uint256 deposits, uint256 borrows) internal {
        uint256 totalAmountToBorrow = _getBorrowFromSupply(deposits - borrows, targetCollatRatio) - borrows;

        if (isFlashMintActive) {
            // The best approach is to lever up using regular method, then finish with flash loan
            totalAmountToBorrow = totalAmountToBorrow - _leverUpStep(totalAmountToBorrow, deposits, borrows);

            if (totalAmountToBorrow > minWant) {
                totalAmountToBorrow = totalAmountToBorrow - _leverUpFlashLoan(totalAmountToBorrow);
            }
        } else {
            for (uint8 i = 0; i < maxIterations && totalAmountToBorrow > minWant; i++) {
                totalAmountToBorrow = totalAmountToBorrow - _leverUpStep(totalAmountToBorrow, deposits, borrows);
                deposits = 0;
                borrows = 0;
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
    function _leverUpStep(uint256 amount, uint256 deposits, uint256 borrows) internal returns (uint256) {
        if (amount == 0) {
            return 0;
        }
        if (deposits == 0 && borrows == 0) (deposits, borrows) = getCurrentPosition();

        uint256 wantBalance = _balanceOfWant();

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
    function getCurrentCollatRatio() public view returns (uint256) {
        (uint256 deposits, uint256 borrows) = getCurrentPosition();
        return _getCurrentCollatRatio(deposits, borrows);
    }

    function _getCurrentCollatRatio(uint256 deposits, uint256 borrows) internal view returns (uint256 currentCollatRatio) {
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
        (, int256 aavePriceUSD,,,) = chainlinkOracle.latestRoundData(); // stkAavePriceUSD is in base 8
        // `aavePriceUSD` is in base 8, and `_DISCOUNT_FACTOR` is in base 4, so ultimately we need to divide
        // by `1e(18+8+4)
        return uint256(aavePriceUSD) * amount * _decimals * _DISCOUNT_FACTOR / 1e30;
    }

    /// @notice Verifies the cooldown status for earned stkAAVE
    function _checkCooldown() internal view returns (CooldownStatus) {
        uint256 cooldownStartTimestamp = IStakedAave(_stkAave).stakersCooldowns(address(this));

        uint256 nextClaimStartTimestamp = cooldownStartTimestamp + cooldownSeconds;

        if (cooldownStartTimestamp == 0) {
            return CooldownStatus.None;
        }
        if (block.timestamp > nextClaimStartTimestamp && block.timestamp <= nextClaimStartTimestamp + unstakeWindow) {
            return CooldownStatus.Claim;
        }
        if (block.timestamp < nextClaimStartTimestamp) {
            return CooldownStatus.Initiated;
        }
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
    function _computeOptimalCollatRatio(uint256 wantBalance, uint256 currentSupply) internal returns(uint256) {
        (uint256 borrow, uint256 balanceExcludingRewards) = computeMostProfitableBorrow(wantBalance, currentSupply);
        uint256 _collatRatio = (borrow * _COLLATERAL_RATIO_PRECISION) / (balanceExcludingRewards + borrow);
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
    function computeMostProfitableBorrow(uint256 wantBalance, uint256 currentSupply) public view returns(uint256 borrow, uint256 balanceExcludingRewards) {
        if(wantBalance == 0) wantBalance = _balanceOfWant();
        // Reusing the currentSupply variable for the `balanceExcludingRewards`
        if(currentSupply == 0) balanceExcludingRewards = estimatedTotalAssetsExcludingRewards(wantBalance);
        else balanceExcludingRewards = currentSupply + wantBalance;
        (uint256 availableLiquidity, uint256 totalStableDebt, uint256 totalVariableDebt,,,, uint256 averageStableBorrowRate,,,) = _protocolDataProvider.getReserveData(address(want));
        
        (uint256 emissionPerSecondAToken,,) = _incentivesController.assets(address(aToken));
        (uint256 emissionPerSecondDebtToken,,) = _incentivesController.assets(address(debtToken));

        uint256 stkAavePriceToUSDC = estimatedAAVEToWant(1 ether);
        // This works if `_decimals < 10**27` which we should expect to be very the case for the strategies we are 
        // launching at the moment
        uint256 normalizationFactor = 10**27 / _decimals;

        // TODO double check maths here
        ComputeProfitability.SCalculateBorrow memory parameters = ComputeProfitability.SCalculateBorrow({
            slope1: lendingPoolVariableRateSlope1,
            slope2: lendingPoolVariableRateSlope2,
            r0: lendingPoolBaseVariableBorrowRate,
            totalStableDebt: int256(totalStableDebt * normalizationFactor),
            totalVariableDebt: int256(totalVariableDebt * normalizationFactor),
            uOptimal: lendingPoolOptimalUtilizationRate,
            totalDeposits: int256((availableLiquidity + totalStableDebt + totalVariableDebt) * normalizationFactor),
            reserveFactor: aaveReserveFactor,
            stableBorrowRate: int256(averageStableBorrowRate),
            rewardDeposit: int256(emissionPerSecondAToken * 10**3 * 86400 * 365 * stkAavePriceToUSDC),
            rewardBorrow: int256(emissionPerSecondDebtToken * 10**3 * 86400 * 365 * stkAavePriceToUSDC),
            poolManagerAssets: int256(balanceExcludingRewards * normalizationFactor),
            maxCollatRatio: int256(maxCollatRatio * 10**9)
        });
        
        int256 _borrow = computeProfitability.computeProfitability(parameters);
        borrow = uint256(_borrow) / normalizationFactor;
    }
}