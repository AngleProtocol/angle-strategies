// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.12;

import "./BaseStrategy4626Storage.sol";

/// @title Angle Base Strategy ERC4626
/// @author Angle Protocol
abstract contract BaseStrategy4626 is BaseStrategy4626Storage {
    using SafeERC20 for IERC20;

    /// @notice Constructor of the `BaseStrategyERC4626`
    function _initialize(Vault _vault, address[] memory keepers) internal initializer {
        vault = _vault;
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
    modifier onlyVault() {
        if (address(vault) != msg.sender) revert NotVault();
        _;
    }

    // /// @notice Withdraws `_amountNeeded` to `poolManager`.
    // /// @param _amountNeeded How much `want` to withdraw.
    // /// @return _loss Any realized losses
    // /// @dev This may only be called by the `PoolManager`
    // function withdraw(uint256 _amountNeeded) external override onlyVault returns (uint256 _loss) {
    //     uint256 amountFreed;
    //     // Liquidate as much as possible `want` (up to `_amountNeeded`)
    //     (amountFreed, _loss) = _liquidatePosition(_amountNeeded);
    //     // Send it directly back (NOTE: Using `msg.sender` saves some gas here)
    //     IERC20(asset()).safeTransfer(msg.sender, amountFreed);
    //     // NOTE: Reinvest anything leftover on next `harvest`
    // }

    /** @dev See {IERC4262-withdraw} */
    function withdraw(
        uint256 assets,
        address receiver,
        address owner
    ) public override onlyVault returns (uint256 _loss) {
        require(assets <= maxWithdraw(owner), "ERC20TokenizedVault: withdraw more than max");

        uint256 shares = previewWithdraw(assets);
        _withdraw(_msgSender(), receiver, owner, assets, shares);

        return shares;
    }

    /// @notice Harvests the Strategy, recognizing any profits or losses and adjusting
    /// the Strategy's position.
    /// @dev Let the process of `report` and `adjustPosition`, because coupling both in a generic manner
    /// is not obvious
    function harvest() external {
        // If this is the first harvest after the last window:
        if (block.timestamp >= lastHarvest + harvestDelay) {
            // Set the harvest window's start timestamp.
            // Cannot overflow 64 bits on human timescales.
            lastHarvestWindowStart = uint64(block.timestamp);
        } else {
            // We know this harvest is not the first in the window so we need to ensure it's within it.
            require(block.timestamp <= lastHarvestWindowStart + harvestWindow, "BAD_HARVEST_TIME");
        }

        (uint256 gain, uint256 loss, uint256 debtPayment) = _report();

        // TODO to put in the report (and so make it virtual) because it should impact the
        // globalAssets -> remove loss add gain
        // loss was directly removed from the totalHoldings
        // Update max unlocked profit based on any remaining locked profit plus new profit.
        maxLockedProfit = (lockedProfit() + gain);

        // Check if free returns are left, and re-invest them
        _adjustPosition();

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

            emit HarvestDelayUpdated(msg.sender, newHarvestDelay);
        }
    }

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
    function _report()
        internal
        returns (
            uint256 profit,
            uint256 loss,
            uint256 debtPayment
        )
    {
        uint256 debtOutstanding = vault.debtOutstanding(address(this));
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
            // Free up returns for vault to pull
            (profit, loss, debtPayment) = _prepareReturn(debtOutstanding);
        }
        emit Harvested(profit, loss, debtPayment, debtOutstanding);

        totalStrategyHoldings += profit - loss - debtPayment;

        // Allows vault to take up to the "harvested" balance of this contract,
        // which is the amount it has earned since the last time it reported to
        // the Manager.
        vault.report(profit, loss, debtPayment);
    }

    /// @notice Calculates the total amount of underlying tokens the Vault holds.
    /// @return totalUnderlyingHeld The total amount of underlying tokens the Vault holds.
    /// @dev Important to not take into account lockedProfit otherwise there could be attacks on
    /// the vault. Someone could artificially make a strategy have large profit, to deposit and withdraw
    /// and earn free money.
    /// @dev Need to be cautious on when to use `totalAssets()` and totalDebt. As when investing the money
    /// it is better to use the full balance. But need to make sure that there isn't any flaws by using 2 dufferent balances
    function totalAssets() public view override returns (uint256 totalUnderlyingHeld) {
        totalUnderlyingHeld = totalStrategyHoldings - lockedProfit();
    }

    /// @notice Calculates the current amount of locked profit.
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

    // ============================ Setters =============================

    /// @notice Sets a new harvest window.
    /// @param newHarvestWindow The new harvest window.
    /// @dev The Vault's harvestDelay must already be set before calling.
    function setHarvestWindow(uint128 newHarvestWindow) external onlyGovernor {
        // A harvest window longer than the harvest delay doesn't make sense.
        require(newHarvestWindow <= harvestDelay, "WINDOW_TOO_LONG");

        // Update the harvest window.
        harvestWindow = newHarvestWindow;

        emit HarvestWindowUpdated(msg.sender, newHarvestWindow);
    }

    /// @notice Sets a new harvest delay.
    /// @param newHarvestDelay The new harvest delay to set.
    /// @dev If the current harvest delay is 0, meaning it has not
    /// been set before, it will be updated immediately, otherwise
    /// it will be scheduled to take effect after the next harvest.
    function setHarvestDelay(uint64 newHarvestDelay) external onlyGovernor {
        // A harvest delay of 0 makes harvests vulnerable to sandwich attacks.
        require(newHarvestDelay != 0, "DELAY_CANNOT_BE_ZERO");

        // A harvest delay longer than 1 year doesn't make sense.
        require(newHarvestDelay <= 365 days, "DELAY_TOO_LONG");

        // If the harvest delay is 0, meaning it has not been set before:
        if (harvestDelay == 0) {
            // We'll apply the update immediately.
            harvestDelay = newHarvestDelay;

            emit HarvestDelayUpdated(msg.sender, newHarvestDelay);
        } else {
            // We'll apply the update next harvest.
            nextHarvestDelay = newHarvestDelay;

            emit HarvestDelayUpdateScheduled(msg.sender, newHarvestDelay);
        }
    }

    /// @notice Activates emergency exit. Once activated, the Strategy will exit its
    /// position upon the next harvest, depositing all funds into the Manager as
    /// quickly as is reasonable given on-chain conditions.
    /// @dev This may only be called by the `PoolManager`, because when calling this the `PoolManager` should at the same
    /// time update the debt ratio
    /// @dev This function can only be called once by the `PoolManager` contract
    /// @dev See `poolManager.setEmergencyExit()` and `harvest()` for further details.
    function setEmergencyExit() external onlyVault {
        emergencyExit = true;
        emit EmergencyExitActivated();
    }

    // ============================ Internal Functions =============================

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
    ) private override onlyVault {
        // If _asset is ERC777, `transferFrom` can trigger a reenterancy BEFORE the transfer happens through the
        // `tokensToSend` hook. On the other hand, the `tokenReceived` hook, that is triggered after the transfer,
        // calls the vault, which is assumed not malicious.
        //
        // Conclusion: we need to do the transfer before we mint so that any reentrancy would happen before the
        // assets are transfered and before the shares are minted, which is a valid state.
        // slither-disable-next-line reentrancy-no-eth
        SafeERC20Upgradeable.safeTransferFrom(IERC20Upgradeable(asset()), caller, address(this), assets);
        _mint(receiver, shares);
        totalStrategyHoldings += assets;

        emit Deposit(caller, receiver, assets, shares);
    }

    // TODO withdraw function will not be exactly at ERC4626 format. We will make the withdraw output the loss made at harvest time

    /**
     * @dev Withdraw/redeem common workflow
     */
    function _withdraw(
        address caller,
        address receiver,
        address owner,
        uint256 assets,
        uint256 shares
    ) private override {
        if (caller != owner) {
            _spendAllowance(owner, caller, shares);
        }

        // If _asset is ERC777, `transfer` can trigger trigger a reentrancy AFTER the transfer happens through the
        // `tokensReceived` hook. On the other hand, the `tokensToSend` hook, that is triggered before the transfer,
        // calls the vault, which is assumed not malicious.
        //
        // Conclusion: we need to do the transfer after the burn so that any reentrancy would happen after the
        // shares are burned and after the assets are transfered, which is a valid state.
        _burn(owner, shares);
        SafeERC20Upgradeable.safeTransfer(IERC20Upgradeable(asset()), receiver, assets);
        totalStrategyHoldings -= assets;

        emit Withdraw(caller, receiver, owner, assets, shares);
    }

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

    // ============================ Virtual Functions =============================

    function estimatedAPR() external view virtual returns (uint256);
}
