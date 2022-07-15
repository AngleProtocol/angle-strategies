// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.12;

import "./BaseStrategy4626Storage.sol";

/// @title Angle Base Strategy ERC4626
/// @author Angle Protocol
abstract contract BaseStrategy4626 is BaseStrategy4626Storage {
    using SafeERC20 for IERC20;

    /// @notice Constructor of the `BaseStrategyERC4626`
    function _initialize(SavingsRate[] memory _savingsRate, address[] memory keepers) internal initializer {
        savingsRate = savingsRate;
    }

    /// @notice Checks whether the `msg.sender` has the governor role or not
    modifier onlyGovernor() {
        if (!coreBorrow.isGovernor(msg.sender)) revert NotGovernor();
        _;
    }

    /// @notice Checks whether the `msg.sender` has the governor role or not
    modifier onlyGovernorOrGuardian() {
        if (!coreBorrow.isGovernorOrGuardian(msg.sender)) revert NotGovernorOrGuardian();
        _;
    }

    /// @notice Checks whether the `msg.sender` has the governor role or not
    modifier onlySavingsRate() {
        // List should be small (less than 5) so looping is not an issue
        SavingsRate[] memory savingsRateMem = savingsRate;
        bool inList;
        for (uint256 i = 0; i < savingsRateMem.length; i++) {
            if (address(savingsRateMem[i]) != msg.sender) {
                inList = true;
                continue;
            }
        }
        if (!inList) revert NotSavingsRate();
        _;
    }

    // ============================ View functions =================================

    /// @notice Provides an indication of whether this strategy is currently "active"
    /// in that it is managing an active position, or will manage a position in
    /// the future. This should correlate to `harvest()` activity, so that Harvest
    /// events can be tracked externally by indexing agents.
    /// @return True if the strategy is actively managing a position.
    function isActive() public view returns (bool) {
        return estimatedTotalAssets() > 0;
    }

    /// @notice Revert if the caller is not a whitelisted savingsRate
    function isSavingsRate() public view onlySavingsRate {}

    /// @notice Computes the total amount of underlying tokens the SavingsRate holds.
    /// @return totalUnderlyingHeld The total amount of underlying tokens the SavingsRate holds.
    /// @dev Important to not take into account lockedProfit otherwise there could be attacks on
    /// the savingsRate. Someone could artificially make a strategy have large profit, to deposit and withdraw
    /// and earn free money.
    /// @dev Need to be cautious on when to use `totalAssets()` and totalStrategyHoldings. As when investing the money
    /// it is better to use the full balance.
    function totalAssets() public view override returns (uint256 totalUnderlyingHeld) {
        totalUnderlyingHeld = totalStrategyHoldings - lockedProfit();
    }

    /// @notice Computes the current amount of locked profit.
    /// @return The current amount of locked profit.
    function lockedProfit() public view returns (uint256) {
        // Get the last harvest and harvest delay.
        uint256 previousHarvest = lastHarvest;
        uint256 harvestInterval = harvestDelay;

        unchecked {
            // If the harvest delay has passed, there is no locked profit.
            // Cannot overflow on human timescales since harvestInterval is capped.
            if (block.timestamp >= previousHarvest + harvestInterval) return 0;

            // Get the maximum amount we could return.
            uint256 maximumLockedProfit = maxLockedProfit;

            // Compute how much profit remains locked based on the last harvest and harvest delay.
            // It's impossible for the previous harvest to be in the future, so this will never underflow.
            return maximumLockedProfit - (maximumLockedProfit * (block.timestamp - previousHarvest)) / harvestInterval;
        }
    }

    // ============================ View virtual functions =================================

    /// @notice Provides an accurate estimate for the total amount of assets
    /// (principle + return) that this Strategy is currently managing,
    /// denominated in terms of `want` tokens.
    /// This total should be "realizable" e.g. the total value that could
    /// *actually* be obtained from this Strategy if it were to divest its
    /// entire position based on current on-chain conditions.
    /// @return The estimated total assets in this Strategy.
    /// @dev Care must be taken in using this function, since it relies on external
    /// systems, which could be manipulated by the attacker to give an inflated
    /// (or reduced) value produced by this function, based on current on-chain
    /// conditions (e.g. this function is possible to influence through
    /// flashloan attacks, oracle manipulations, or other DeFi attack
    /// mechanisms).
    function estimatedTotalAssets() public view virtual returns (uint256);

    function estimatedAPR() external view virtual returns (uint256);

    // ============================ External functions =================================

    /** @dev See {IERC4262-withdraw} */
    /// @return _loss Any realized losses
    function withdraw(
        uint256 assets,
        address receiver,
        address owner
    ) public override returns (uint256 _loss) {
        uint256 amountFreed;
        // Liquidate as much as possible `want` (up to `assets`)
        (amountFreed, _loss) = _liquidatePosition(assets);

        require(assets + _loss <= maxWithdraw(owner), "ERC20TokenizedVault: withdraw more than max");

        uint256 shares = previewWithdraw(assets + _loss);
        _withdraw(_msgSender(), receiver, owner, assets, _loss, shares);

        return shares;
    }

    /** @dev See {IERC4262-redeem} */
    /// @dev Currently not used by savingsRates
    function redeem(
        uint256 shares,
        address receiver,
        address owner
    ) public virtual override returns (uint256 _loss) {
        require(shares <= maxRedeem(owner), "ERC20TokenizedVault: redeem more than max");

        uint256 assets = previewRedeem(shares);
        uint256 amountFreed;
        // Liquidate as much as possible `want` (up to `assets`)
        (amountFreed, _loss) = _liquidatePosition(assets);

        // Should send `assets - _loss`, but should acknowledge `assets` as withdrawn from the strat
        _withdraw(_msgSender(), receiver, owner, assets - _loss, _loss, shares);

        return assets - _loss;
    }

    // ============================ Setters =============================

    /// @notice Activates emergency exit. Once activated, the Strategy will exit its
    /// position upon the next harvest, depositing all funds into the Manager as
    /// quickly as is reasonable given on-chain conditions.
    /// @dev This may only be called by the `savingsRate`'s, because when calling this the `savingsRate` should at the same
    /// time update the debt ratio
    /// @dev This function can only be called once by the `savingsRate` contract
    /// @dev See `savingsRate.setEmergencyExit()` and `harvest()` for further details.
    function setEmergencyExit() external onlySavingsRate {
        emergencyExit = true;
        emit EmergencyExitActivated();
    }

    // ============================ Internal Functions =============================

    /// @notice PrepareReturn the Strategy, recognizing any profits or losses
    /// @dev In the rare case the Strategy is in emergency shutdown, this will exit
    /// the Strategy's position.
    /// @dev  When `_report()` is called, the Strategy reports to the Manager (via
    /// `poolManager.report()`), so in some cases `harvest()` must be called in order
    /// to take in profits, to borrow newly available funds from the Manager, or
    /// otherwise adjust its position. In other cases `harvest()` must be
    /// called to report to the Manager on the Strategy's position, especially if
    /// any losses have occurred.
    /// @dev As keepers may directly profit from this function, there may be front-running problems with miners bots,
    /// we may have to put an access control logic for this function to only allow white-listed addresses to act
    /// as keepers for the protocol
    /// TODO can be done better(?), like right now they report to all SavingsRates but this seems too much
    function _report()
        public
        onlySavingsRate
        returns (
            uint256 profit,
            uint256 loss,
            uint256 debtPayment
        )
    {
        // If this is the first harvest after the last window:
        if (block.timestamp >= lastHarvest + harvestDelay) {
            // Set the harvest window's start timestamp.
            // Cannot overflow 64 bits on human timescales.
            lastHarvestWindowStart = uint64(block.timestamp);
        } else {
            // We know this harvest is not the first in the window so we need to ensure it's within it.
            require(block.timestamp <= lastHarvestWindowStart + harvestWindow, "BAD_HARVEST_TIME");
        }

        SavingsRate[] memory savingsRateMem = savingsRate;

        uint256 debtOutstanding;
        for (uint256 i = 0; i < savingsRateMem.length; i++) {
            debtOutstanding += savingsRateMem[i].debtOutstanding(address(this));
        }

        if (emergencyExit) {
            // Free up as much capital as possible
            uint256 amountFreed = _liquidateAllPositions();
            if (amountFreed < debtOutstanding) {
                loss = debtOutstanding - amountFreed;
            } else if (amountFreed > debtOutstanding) {
                profit = amountFreed - debtOutstanding;
            }
            debtPayment = debtOutstanding - loss;
        } else {
            // Free up returns for savingsRate to pull
            (profit, loss, debtPayment) = _prepareReturn(debtOutstanding);
        }
        emit Harvested(profit, loss, debtPayment, debtOutstanding);
        totalStrategyHoldings += profit - loss - debtPayment;

        // loss is directly removed from the totalHoldings
        // Update max unlocked profit based on any remaining locked profit plus new profit.
        maxLockedProfit = (lockedProfit() + profit);

        // Update the last harvest timestamp.
        // Cannot overflow on human timescales.
        lastHarvest = uint64(block.timestamp);

        // Get the next harvest delay.
        uint64 newHarvestDelay = nextHarvestDelay;

        // If the next harvest delay is not 0:
        if (newHarvestDelay != 0) {
            // Update the harvest delay.
            harvestDelay = newHarvestDelay;

            // Reset the next harvest delay.
            nextHarvestDelay = 0;
        }
    }

    /// @dev can't use the _afterTokenDeposit because we don't have access to 'assets' but only 'shares'
    /// We can if we are using a less gas friendly implementation by making inverse computation to get back 'assets'
    /// TODO test both way
    /**
     * @dev Deposit/mint common workflow
     */
    /// @dev can't use the _afterTokenDeposit because we don't have access to 'assets' but only 'shares'
    function _deposit(
        address caller,
        address receiver,
        uint256 assets,
        uint256 shares
    ) internal override onlySavingsRate {
        // If _asset is ERC777, `transferFrom` can trigger a reenterancy BEFORE the transfer happens through the
        // `tokensToSend` hook. On the other hand, the `tokenReceived` hook, that is triggered after the transfer,
        // calls the savingsRate, which is assumed not malicious.
        //
        // Conclusion: we need to do the transfer before we mint so that any reentrancy would happen before the
        // assets are transfered and before the shares are minted, which is a valid state.
        // slither-disable-next-line reentrancy-no-eth
        SafeERC20Upgradeable.safeTransferFrom(IERC20Upgradeable(asset()), caller, address(this), assets);
        _mint(receiver, shares);
        totalStrategyHoldings += assets;

        emit Deposit(caller, receiver, assets, shares);
    }

    /**
     * @dev Withdraw/redeem common workflow
     */
    function _withdraw(
        address caller,
        address receiver,
        address owner,
        uint256 assets,
        uint256 loss,
        uint256 shares
    ) private onlySavingsRate {
        if (caller != owner) {
            _spendAllowance(owner, caller, shares);
        }

        // If _asset is ERC777, `transfer` can trigger trigger a reentrancy AFTER the transfer happens through the
        // `tokensReceived` hook. On the other hand, the `tokensToSend` hook, that is triggered before the transfer,
        // calls the savingsRate, which is assumed not malicious.
        //
        // Conclusion: we need to do the transfer after the burn so that any reentrancy would happen after the
        // shares are burned and after the assets are transfered, which is a valid state.
        _burn(owner, shares);
        SafeERC20Upgradeable.safeTransfer(IERC20Upgradeable(asset()), receiver, assets);
        totalStrategyHoldings -= assets + loss;

        emit Withdraw(caller, receiver, owner, assets, shares);
    }

    /** @dev See {ERC20Upgradeable-_afterTokenTransfer} */
    function _afterTokenTransfer(
        address from,
        address to,
        uint256
    ) internal override {
        // mint, check if free returns are left, and re-invest them
        if (from == address(0)) _adjustPosition();
    }

    // ============================ Internal virtual Functions =============================

    /// @notice Performs any Strategy unwinding or other calls necessary to capture the
    /// "free return" this Strategy has generated since the last time its core
    /// position(s) were adjusted. Examples include unwrapping extra rewards.
    /// This call is only used during "normal operation" of a Strategy, and
    /// should be optimized to minimize losses as much as possible.
    ///
    /// This method returns any realized profits and/or realized losses
    /// incurred, and should return the total amounts of profits/losses/debt
    /// payments (in `want` tokens) for the Manager's accounting (e.g.
    /// `want.balanceOf(this) >= _debtPayment + _profit`).
    ///
    /// `_debtOutstanding` will be 0 if the Strategy is not past the configured
    /// debt limit, otherwise its value will be how far past the debt limit
    /// the Strategy is. The Strategy's debt limit is configured in the Manager.
    ///
    /// NOTE: `_debtPayment` should be less than or equal to `_debtOutstanding`.
    ///       It is okay for it to be less than `_debtOutstanding`, as that
    ///       should only used as a guide for how much is left to pay back.
    ///       Payments should be made to minimize loss from slippage, debt,
    ///       withdrawal fees, etc.
    ///
    /// See `poolManager.debtOutstanding()`.
    function _prepareReturn(uint256 _debtOutstanding)
        internal
        virtual
        returns (
            uint256 _profit,
            uint256 _loss,
            uint256 _debtPayment
        );

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
