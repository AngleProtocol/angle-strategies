// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.12;

import "./BaseStrategy4626Storage.sol";

/// @title BaseStrategy4626
/// @author Angle Core Team
/// @notice Base contract for strategies meant to interact with Angle savings rate contracts
// TODO: not sure of the flow with totalStrategyHoldings`: we could look at the immediately available balance and
// have a totalInvestedAmount: in `_adjustPosition` we just need to change amountInvested or divested. This prevents us
// from having to update on deposit and withdraw -> not sure though whether this solution is better
abstract contract BaseStrategy4626 is IStrategy4626, BaseStrategy4626Storage  {
    using SafeERC20 for IERC20;

    /// @notice Initializes the `BaseStrategyERC4626` contract
    /// @param _savingsRate List of associated savings rate contracts
    /// @param _coreBorrow `CoreBorrow` address for access control
    /// @param _asset Asset controlled by the strategy
    function _initialize(
        ISavingsRate[] memory _savingsRate,
        ICoreBorrow _coreBorrow,
        address _asset
    ) internal initializer {
        __ERC4626_init(IERC20MetadataUpgradeable(_asset));
        if (address(_coreBorrow) == address(0)) revert ZeroAddress();
        coreBorrow = _coreBorrow;
        for (uint256 i = 0; i < _savingsRate.length; i++) {
            if (_savingsRate[i].asset() != _asset) revert InvalidSavingsRate();
            savingsRate[_savingsRate[i]] = true;
            emit SavingsRateActivated(address(_savingsRate[i]));
        }
        savingsRateList = _savingsRate;
    }

    /// @notice Checks whether the `msg.sender` has the governor role or not
    modifier onlyGovernor() {
        if (!coreBorrow.isGovernor(msg.sender)) revert NotGovernor();
        _;
    }

    /// @notice Checks whether the `msg.sender` has the governor role or the guardian role
    modifier onlyGovernorOrGuardian() {
        if (!coreBorrow.isGovernorOrGuardian(msg.sender)) revert NotGovernorOrGuardian();
        _;
    }

    /// @notice Checks whether the `msg.sender` is a savings rate contract or not
    modifier onlySavingsRate() {
        if (!savingsRate[ISavingsRate(msg.sender)]) revert NotSavingsRate();
        _;
    }

    // ============================ View functions =================================

    /// @notice Provides an indication of whether this strategy is currently "active"
    /// in that it is managing an active position, or will manage a position in
    /// the future. This should correlate to `harvest()` activity, so that Harvest
    /// events can be tracked externally by indexing agents.
    /// @return True if the strategy is actively managing a position.
    function isActive() public view returns (bool) {
        return totalAssets() > 0;
    }

    /// @inheritdoc IStrategy4626
    function isSavingsRate() external view returns(bool) {
        return savingsRate[ISavingsRate(msg.sender)];
    }

    /// @notice Returns the list of savings rate contracts which are plugged to the strategy
    function savingsRateActive() external view returns (ISavingsRate[] memory) {
        return savingsRateList;
    }

    /// @notice Computes the total amount of underlying tokens the SavingsRate holds
    function totalAssets() public view virtual override(ERC4626Upgradeable, IERC4626Upgradeable) returns (uint256) {
        return totalStrategyHoldings;
    }

    // =========================== View virtual functions ==========================

    /// @inheritdoc IStrategy4626
    function estimatedAPR() external view virtual returns (uint256);

    // =========================== External functions ==============================

    /// @inheritdoc ERC4626Upgradeable
    /// @return _loss Any realized losses
    /// @dev Contrarily to what is stated in the base ERC4626 interface, this function just returns
    /// a loss
    function withdraw(
        uint256 assets,
        address receiver,
        address owner
    ) public virtual override(ERC4626Upgradeable, IERC4626Upgradeable) returns (uint256 _loss) {
        // Need to free at least `assets` from the strat
        (, _loss) = _liquidatePosition(assets);
        if (assets + _loss > maxWithdraw(owner)) revert TooHighWithdraw();
        uint256 shares = previewWithdraw(assets + _loss);
        _withdraw(_msgSender(), receiver, owner, assets, _loss, shares);
    }

    /// @inheritdoc ERC4626Upgradeable
    /// @dev Currently not used by `SavingsRate` contracts but still need the implementation to take losses into account
    /// @dev Contrarily to what is stated in the base ERC4626 interface, this function just returns
    /// a loss
    function redeem(
        uint256 shares,
        address receiver,
        address owner
    ) public virtual override(ERC4626Upgradeable, IERC4626Upgradeable) returns (uint256 _loss) {
        if (shares > maxRedeem(owner)) revert TooHighWithdraw();

        uint256 assets = previewRedeem(shares);
        // We need to free up to `assets`
        (, _loss) = _liquidatePosition(assets);

        // Should send `assets - _loss`, but should acknowledge `assets` as withdrawn from the strat
        // TODO: need to make sure that we always assets > loss after liquidatePosition
        _withdraw(_msgSender(), receiver, owner, assets - _loss, _loss, shares);
    }

    // ================================ Setters ====================================

    /// @notice Activates emergency exit. Once activated, the Strategy will exit its
    /// position upon the next harvest, letting capital sitting idle for all related vaults to
    /// withdraw their positions
    /// @dev This should only be called when all `savingsRate`'s set their debt ratio to 0,
    /// @dev This function can only be called once by the `savingsRate` contract
    function setEmergencyExit() external onlyGovernorOrGuardian {
        emergencyExit = true;
        emit EmergencyExitActivated();
    }

    /// @notice Add a vault to the whitelist, allowed to interact with the strategy
    /// @param saving_ The saving rate to add
    /// @dev This may only be called by the governance or guardians as not any users
    /// should be able to use the strategy
    function addSavingsRate(ISavingsRate saving_) external onlyGovernorOrGuardian {
        if (savingsRate[saving_] || saving_.asset() != asset()) revert InvalidSavingsRate();
        savingsRate[saving_] = true;
        savingsRateList.push(saving_);
        emit SavingsRateActivated(address(saving_));
    }

    /// @notice Revokes a strategy
    /// @param saving_ The saving rate to revoke
    /// @dev This should only be called after all funds has been removed from the strategy by the savings rate
    /// contract
    function revokeSavingsRate(ISavingsRate saving_) external onlyGovernorOrGuardian {
        if (!savingsRate[saving_] || balanceOf(address(saving_)) != 0) revert InvalidSavingsRate();

        ISavingsRate[] memory savingsRateMem = savingsRateList;
        uint256 savingsRateListLength = savingsRateMem.length;
        for (uint256 i = 0; i < savingsRateListLength - 1; i++) {
            if (savingsRateMem[i] == saving_) {
                savingsRateList[i] = savingsRateList[savingsRateListLength - 1];
                break;
            }
        }
        savingsRateList.pop();
        delete savingsRate[saving_];
        emit SavingsRateRevoked(address(saving_));
    }

    // ============================ Internal Functions =============================

    /// @inheritdoc IStrategy4626
    function report(uint256 _callerDebtOutstanding) public onlySavingsRate returns (uint256 profit, uint256 loss) {
        uint256 currentDebt = totalStrategyHoldings;

        if (emergencyExit) {
            // Free up as much capital as possible
            uint256 amountFreed = _liquidateAllPositions();
            if (amountFreed < currentDebt) {
                loss = currentDebt - amountFreed;
            } else if (amountFreed > currentDebt) {
                profit = amountFreed - currentDebt;
            }
        } else {
            // Free up returns for savingsRate to pull
            (profit, loss) = _prepareReturn(_callerDebtOutstanding);
        }
        emit Harvested(profit, loss, _callerDebtOutstanding, msg.sender);
        // It won't revert as long as there are enough funds to cover for the losses
        totalStrategyHoldings += profit - loss;
    }

    /// @inheritdoc ERC4626Upgradeable
    /// @dev This function is overriden from the base implementation to take into account updates in the `totalStrategyHoldings`
    /// and only allow some addresses to deposit
    function _deposit(
        address caller,
        address receiver,
        uint256 assets,
        uint256 shares
    ) internal override onlySavingsRate {
        SafeERC20Upgradeable.safeTransferFrom(IERC20Upgradeable(asset()), caller, address(this), assets);
        _mint(receiver, shares);
        totalStrategyHoldings += assets;
        emit Deposit(caller, receiver, assets, shares);
    }

    /// @notice Burns `shares` from `owner` after a request from `caller`, and sends `assets` to `receiver`
    /// while reporting a loss of `loss` from the strategy
    function _withdraw(
        address caller,
        address receiver,
        address owner,
        uint256 assets,
        uint256 loss,
        uint256 shares
    ) internal onlySavingsRate {
        if (caller != owner) {
            _spendAllowance(owner, caller, shares);
        }
        _burn(owner, shares);
        totalStrategyHoldings -= (assets + loss);
        SafeERC20Upgradeable.safeTransfer(IERC20Upgradeable(asset()), receiver, assets);
        emit Withdraw(caller, receiver, owner, assets, shares);
    }

    /// @inheritdoc ERC20Upgradeable
    function _afterTokenTransfer(
        address from,
        address,
        uint256
    ) internal override {
        // mint, check if free returns are left, and re-invest them
        // TODO should the strategy reinvest and adjust its position on burn (to==address(0)): like when the savings rate pulls
        // back funds you may want to withdraw them
        if (from == address(0)) _adjustPosition();
    }

    // ========================== Internal virtual Functions =======================

    /// @notice Performs any Strategy unwinding or other calls necessary to capture the
    /// "free return" this Strategy has generated since the last time its core
    /// position(s) were adjusted. Examples include unwrapping extra rewards.
    /// This call is only used during "normal operation" of a Strategy, and
    /// should be optimized to minimize losses as much as possible.
    ///
    /// This method returns any realized profits and/or realized losses
    /// incurred, and should return the total amounts of profits/losses
    /// payments (in `want` tokens) for the strategy's accounting in the total assets
    ///
    /// `_debtOutstanding` will be 0 if the Strategy is not past the configured
    /// debt limit, otherwise its value will be how far past the debt limit
    /// the Strategy is. The Strategy's debt limit is configured in the Manager.
    ///
    /// `_debt` Represent the vault previous liabilities to its lenders a.k.a `savings`.
    ///
    /// NOTE: `_debtPayment` should be less than or equal to `_debtOutstanding`.
    ///       It is okay for it to be less than `_debtOutstanding`, as that
    ///       should only used as a guide for how much is left to pay back.
    ///       Payments should be made to minimize loss from slippage, debt,
    ///       withdrawal fees, etc.
    ///
    function _prepareReturn(uint256 _debtOutstanding) internal virtual returns (uint256 _profit, uint256 _loss);

    /// @notice Performs any adjustments to the core position(s) of this Strategy given
    /// what change the Manager made in the "investable capital" available to the
    /// Strategy. Note that all "free capital" in the Strategy after the report
    /// was made is available for reinvestment. Also note that this number
    /// could be 0, and you should handle that scenario accordingly.
    function _adjustPosition() internal virtual;

    /// @notice Liquidates up to `_amountNeeded` of `want` of this strategy's positions,
    /// irregardless of slippage. Any excess will be re-invested with `_adjustPosition()`.
    /// This function should return the amount of `want` tokens made available by the
    /// liquidation. If there is a difference between them, `_loss` indicates whether the
    /// difference is due to a realized loss, or if there is some other sitution at play
    /// (e.g. locked funds) where the amount made available is less than what is needed.
    ///
    /// NOTE: The invariant `_liquidatedAmount + _loss <= _amountNeeded` should always be maintained
    function _liquidatePosition(uint256 _amountNeeded)
        internal
        virtual
        returns (uint256 _liquidatedAmount, uint256 _loss);

    /// @notice Liquidates everything and returns the amount that got freed.
    /// This function is used during emergency exit instead of `_prepareReturn()` to
    /// liquidate all of the Strategy's positions back to the Manager.
    function _liquidateAllPositions() internal virtual returns (uint256 _amountFreed);

    /// @notice Override this to add all tokens/tokenized positions this contract
    /// manages on a *persistent* basis (e.g. not just for swapping back to
    /// want ephemerally).
    ///
    /// NOTE: Do *not* include `want`, already included in `sweep` below.
    ///
    /// Example:
    /// ```
    ///    function _protectedTokens() internal override view returns (address[] memory) {
    ///      address[] memory protected = new address[](3);
    ///      protected[0] = tokenA;
    ///      protected[1] = tokenB;
    ///      protected[2] = tokenC;
    ///      return protected;
    ///    }
    /// ```
    function _protectedTokens() internal view virtual returns (address[] memory);
}
