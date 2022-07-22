// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.12;

import "./BaseSavingsRateStorage.sol";

/// @title Angle Vault
/// @author Angle Protocol
/// @notice Yield aggregator vault which can connect multiple ERC4626 strategies
/// @notice Integrate boosting mecanism on the yield
abstract contract BaseSavingsRate is BaseSavingsRateStorage {
    using SafeERC20 for IERC20;
    using Address for address;
    using MathUpgradeable for uint256;

    function _initialize(
        ICoreBorrow _coreBorrow,
        IERC20MetadataUpgradeable _token,
        string memory suffixName
    ) internal initializer {
        __ERC20_init_unchained(
            // Angle token Wrapper
            string(abi.encodePacked("Angle ", _token.name(), " Wrapper")),
            string(abi.encodePacked("aw", _token.symbol(), " ", suffixName))
        );
        __ERC4626_init_unchained(_token);
        coreBorrow = _coreBorrow;
    }

    /// @notice Checks whether the `msg.sender` has the governor role or not
    modifier onlyGovernor() {
        if (!coreBorrow.isGovernor(msg.sender)) revert NotGovernor();
        _;
    }

    /// @notice Checks whether the `msg.sender` has the governor or guarian role or not
    modifier onlyGovernorOrGuardian() {
        if (!coreBorrow.isGovernorOrGuardian(msg.sender)) revert NotGovernorOrGuardian();
        _;
    }

    /// @notice Checks whether the `msg.sender` is a strategy
    modifier onlyStrategy() {
        if (strategies[IStrategy4626(msg.sender)].lastReport == 0) revert NotStrategy();
        _;
    }

    // ============================== View functions ===================================

    /// @notice Gets the full withdrawal stack.
    /// @return An ordered array of strategies representing the withdrawal stack.
    /// @dev This is provided because Solidity converts public arrays into index getters,
    /// but we need a way to allow external contracts and users to access the whole array.
    function getWithdrawalStack() external view returns (IStrategy4626[] memory) {
        return withdrawalStack;
    }

    /// @notice Returns the list of all AMOs supported by this contract
    function getStrategyList() external view returns (IStrategy4626[] memory) {
        return strategyList;
    }

    /// @notice Returns this `vault`'s directly available reserve of collateral (not including what has been lent)
    function getBalance() public view returns (uint256) {
        return IERC20(asset()).balanceOf(address(this));
    }

    /// @notice Returns this `vault`'s directly available reserve of collateral (not including what has been lent)
    function managedAssets() public view virtual returns (uint256);

    /// @notice Provides an estimated Annual Percentage Rate for SLPs based on lending to other protocols
    /// @dev This function is an estimation and is made for external use only
    /// @dev This does not take into account transaction fees which accrue to SLPs too
    /// @dev This can be manipulated by a flash loan attack (SLP deposit/ withdraw) via `_getTotalAsset`
    /// when entering you should make sure this hasn't be called by a flash loan and look
    /// at a mean of past APR.
    function estimatedAPR() external view returns (uint256 apr) {
        apr = 0;
        uint256 protocolFee_ = protocolFee;
        IStrategy4626[] memory strategyListMem = strategyList;

        for (uint256 i = 0; i < strategyListMem.length; i++) {
            apr =
                apr +
                (strategies[strategyListMem[i]].debtRatio * IStrategy4626(strategyListMem[i]).estimatedAPR()) /
                BASE_PARAMS;
        }
        apr = (apr * (BASE_PARAMS - protocolFee_)) / BASE_PARAMS;
    }

    /// @notice Tells a strategy how much it owes to this `vault`
    /// @param strategy Strategy to consider in the call
    /// @param _managedAssets `asset` available for strategies - you can also set it to 0 to recompute it
    /// @return Amount of token a strategy has to reimburse
    /// @dev Manipulating `_getTotalAsset` with a flashloan will only
    /// result in tokens being transferred at the cost of the caller
    function debtOutstanding(IStrategy4626 strategy, uint256 _managedAssets) internal view returns (uint256) {
        if (_managedAssets == 0) _managedAssets = managedAssets();

        StrategyParams storage params = strategies[strategy];

        uint256 target = (_managedAssets * params.debtRatio) / BASE_PARAMS;

        if (target > params.totalStrategyDebt) return 0;

        return (params.totalStrategyDebt - target);
    }

    /** @dev See {IERC4262-maxWithdraw}. */
    function maxWithdraw(address owner) public view override returns (uint256) {
        uint256 maxAsset = _convertToAssets(balanceOf(owner), MathUpgradeable.Rounding.Down) +
            _claimableRewardsOf(owner);
        // To fit in the interface, we consider only the `want` balance directly available
        // The interface state to underestimate the withdrawal amount, but this come at the cost
        // to be far from optimal in the estimation
        return Math.min(maxAsset, getBalance());
    }

    /** @dev See {IERC4262-maxRedeem}. */
    function maxRedeem(address owner) public view virtual override returns (uint256) {
        uint256 contractBalance = getBalance();
        uint256 shares = balanceOf(owner);

        if (shares == 0) return 0;

        uint256 assets = _convertToAssets(shares, MathUpgradeable.Rounding.Down);
        uint256 reward = _claimableRewardsOf(owner);
        // To fit in the interface, we consider only the `want` balance directly available
        // The interface state to underestimate the withdrawal amount, but this come at the cost
        // to be far from optimal in the estimation
        if (contractBalance > reward + assets) {
            return shares;
        } else if (contractBalance > reward) {
            // total supply can only be > 0 as the owner have shares
            uint256 totalSupply_ = totalSupply();
            uint256 totalAssets_ = totalAssets();
            uint256 shareBase = 10**decimals();
            uint256 proportionAssetPerShare = shareBase.mulDiv(totalAssets_, totalSupply_, MathUpgradeable.Rounding.Up);
            uint256 proportionReward = shareBase.mulDiv(reward, shares, MathUpgradeable.Rounding.Up);
            uint256 maxShares = contractBalance.mulDiv(
                shareBase,
                proportionAssetPerShare + proportionReward,
                MathUpgradeable.Rounding.Down
            );
            return maxShares;
        } else {
            return 0;
        }
    }

    /** @dev See {IERC4262-previewWithdraw}. */
    function previewWithdraw(uint256 assets) public view override returns (uint256) {
        return previewWithdraw(msg.sender, assets);
    }

    /** @dev See {IERC4262-previewRedeem}. */
    function previewRedeem(uint256 shares) public view override returns (uint256) {
        return previewRedeem(msg.sender, shares);
    }

    /** @dev See {IERC4262-previewWithdraw}. */
    function previewWithdraw(address owner, uint256 assets) public view returns (uint256) {
        uint256 ownerReward = _claimableRewardsOf(owner);
        /// TODO doesn't follow interfaces as this returns a number of shares <= what will be burnt through a `withdraw`
        /// because impossible to the know the losses we will incur.
        /// If there could be a slippage factor given by the user it would make it possible to find a lower bound
        if (assets >= ownerReward) {
            return _convertToShares(assets - ownerReward, MathUpgradeable.Rounding.Up);
        } else {
            return 0;
        }
    }

    /** @dev See {IERC4262-previewRedeem}. */
    function previewRedeem(address owner, uint256 shares) public view returns (uint256) {
        uint256 ownerTotalShares = balanceOf(owner);
        uint256 ownerReward = _claimableRewardsOf(owner);
        uint256 ownerRewardShares = (ownerReward * shares) / ownerTotalShares;
        /// TODO doesn't follow interfaces as this returns a number of assets > what will be sent through a `redeem`
        /// as it doesn't take into account a loss
        return _convertToAssets(shares, MathUpgradeable.Rounding.Down) + ownerRewardShares;
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

    // ====================== External permissionless functions =============================

    /// @notice To deposit directly rewards onto the contract
    /// TODO not a fan it looks weird to have the equivalent of a strategy here
    /// while we can just do a dumb strategy and link it to this country, so that they all have the same interface
    function notifyRewardAmount(uint256 amount) external virtual;

    /// @notice Harvests  a set of strategies, recognizing any profits or losses and adjusting
    /// the strategyies position.
    /// @param strategiesToHarvest List of strategies to harvest
    /// @dev Let the process of `report` and `adjustPosition`, because coupling both in a generic manner
    /// is not obvious
    /// TODO we can have another function to do everything except the report phase (which acknowledge profit/loss on one strategy) and free funds if needed
    /// because if the strategies got harvested on other vaults, report can be useless and expensive
    /// If doing it we can group the function with the 2 belows into 1, with an enum for instance
    function harvest(IStrategy4626[] memory strategiesToHarvest) public {
        uint256 managedAssets_ = managedAssets();
        uint256 _debtOutstanding;
        for (uint256 i = 0; i < strategiesToHarvest.length; i++) {
            if (strategies[strategiesToHarvest[i]].lastReport == 0) revert StrategyDoesNotExist();
            _debtOutstanding = debtOutstanding(strategiesToHarvest[i], managedAssets_);
            strategiesToHarvest[i].report(_debtOutstanding);
        }

        int256 totalProfitLossAccrued = _updateMultiStrategiesBalances(strategiesToHarvest);
        _accumulate(totalProfitLossAccrued);
        adjustPosition(strategiesToHarvest, managedAssets_);

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

    /// @notice Update distributable rewards made from all strategies
    /// @dev Do not allow partial accumulation (on a sub set of strategies)
    /// to limit risks on only acknowledging profits
    /// TODO It can actually be done via harvesting specific strategies
    /// @dev The only possibility to acknowledge a loss is if one of the strategy incurred
    /// a loss and this strategy was harvested by another vault
    function accumulate() external {
        IStrategy4626[] memory activeStrategies = strategyList;
        int256 totalProfitLossAccrued = _updateMultiStrategiesBalances(activeStrategies);
        _accumulate(totalProfitLossAccrued);
    }

    // ============================== Governance functions ===================================

    /// @notice Adds a strategy to the `PoolManager`
    /// @param strategy The address of the strategy to add
    /// @param _debtRatio The share of the total assets that the strategy has access to
    /// @dev Multiple checks are made. For instance, the contract must not already belong to the `PoolManager`
    /// and the underlying token of the strategy has to be consistent with the `PoolManager` contracts
    /// @dev This function is a `governor` function and not a `guardian` one because a `guardian` could add a strategy
    /// enabling the withdraw of the funds of the protocol
    /// @dev The `_debtRatio` should be expressed in `BASE_PARAMS`
    function addStrategy(IStrategy4626 strategy, uint256 _debtRatio) external onlyGovernor {
        StrategyParams storage params = strategies[strategy];
        IERC20 asset = IERC20(asset());

        if (params.lastReport != 0) revert StrategyAlreadyAdded();
        strategy.isVault();
        // Using current code, this condition should always be verified as in the constructor
        // of the strategy the `want()` is set to the token of this `PoolManager`
        if (address(asset) != strategy.asset()) revert WrongStrategyToken();
        if (debtRatio + _debtRatio > BASE_PARAMS) revert DebtRatioTooHigh();

        // Add strategy to approved strategies
        params.lastReport = 1;
        params.totalStrategyDebt = 0;
        params.debtRatio = _debtRatio;

        // Update global parameters
        debtRatio += _debtRatio;
        emit StrategyAdded(address(strategy), debtRatio);

        asset.safeApprove(address(strategy), type(uint256).max);

        strategyList.push(strategy);
    }

    /// @notice Sets a new withdrawal stack.
    /// @param newStack The new withdrawal stack.
    /// @dev If any strategy is not recognized by the `vault` the tx will revert.
    function setWithdrawalStack(IStrategy4626[] calldata newStack) external onlyGovernor {
        // Ensure the new stack is not larger than the maximum stack size.
        if (newStack.length > MAX_WITHDRAWAL_STACK_SIZE) revert WithdrawalStackTooDeep();

        for (uint256 i = 0; i < newStack.length; i++) {
            if (strategies[newStack[i]].lastReport > 0) revert StrategyDoesNotExist();
        }

        // Replace the withdrawal stack.
        withdrawalStack = newStack;

        emit WithdrawalStackSet(msg.sender, newStack);
    }

    /// @notice Sets a new share of revenues going to the protocol.
    /// @param protocolFee_ the new protocolFee.
    function setProtocolFee(uint256 protocolFee_) external onlyGovernor {
        // A fee percentage over 100% doesn't make sense.
        if (protocolFee_ >= BASE_PARAMS) revert ProtocolFeeTooHigh();
        // Update the fee percentage.
        protocolFee = protocolFee_;

        emit ProtocolFeeUpdated(msg.sender, protocolFee_);
    }

    /// @notice Sets a new share of revenues going to the strategist.
    /// @param strategistFee_ the new strategistFee.
    function setStrategistFee(uint256 strategistFee_) external onlyGovernor {
        // A fee percentage over 100% doesn't make sense.
        if (strategistFee_ >= BASE_PARAMS) revert ProtocolFeeTooHigh();
        // Update the fee percentage.
        strategistFee = strategistFee_;

        emit StrategistFeeUpdated(msg.sender, strategistFee_);
    }

    /// @notice Sets a new harvest delay.
    /// @param newHarvestDelay The new harvest delay to set.
    /// @dev If the current harvest delay is 0, meaning it has not
    /// been set before, it will be updated immediately, otherwise
    /// it will be scheduled to take effect after the next harvest.
    function setHarvestDelay(uint64 newHarvestDelay) external onlyGovernorOrGuardian {
        // A harvest delay of 0 makes harvests vulnerable to sandwich attacks.
        if (newHarvestDelay == 0 || newHarvestDelay > 365 days) revert WrongHarvestDelay();

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

    // ========================== Governance or Guardian functions ==============================

    /// @notice Modifies the funds a strategy has access to
    /// @param strategy The address of the Strategy
    /// @param _debtRatio The share of the total assets that the strategy has access to
    /// @dev The update has to be such that the `debtRatio` does not exceeds the 100% threshold
    /// as this `vault` cannot lend collateral that it doesn't not own.
    /// @dev `_debtRatio` is stored as a uint256 but as any parameter of the protocol, it should be expressed
    /// in `BASE_PARAMS`
    function updateStrategyDebtRatio(IStrategy4626 strategy, uint256 _debtRatio) external onlyGovernorOrGuardian {
        _updateStrategyDebtRatio(strategy, _debtRatio);
    }

    /// @notice Revokes a strategy
    /// @param strategy The address of the strategy to revoke
    /// @dev This should only be called after the following happened in order: the `strategy.debtRatio` has been set to 0,
    /// `harvest` has been called enough times to recover all capital gain/losses.
    function revokeStrategy(IStrategy4626 strategy) external onlyGovernorOrGuardian {
        StrategyParams storage params = strategies[strategy];

        if (params.debtRatio != 0) revert StrategyInUse();
        if (params.totalStrategyDebt != 0) revert StrategyDebtUnpaid();
        uint256 strategyListLength = strategyList.length;
        if (params.lastReport != 0 && strategyListLength >= 1) revert RevokeStrategyImpossible();
        // It has already been checked whether the strategy was a valid strategy
        for (uint256 i = 0; i < strategyListLength - 1; i++) {
            if (strategyList[i] == strategy) {
                strategyList[i] = strategyList[strategyListLength - 1];
                break;
            }
        }

        strategyList.pop();
        IERC20(asset()).safeApprove(address(strategy), 0);

        delete strategies[strategy];

        emit StrategyRevoked(address(strategy));
    }

    /// @notice Changes allowance of a set of tokens to addresses
    /// @param spenders Addresses to approve
    /// @param amounts Approval amounts for each address
    function changeAllowance(
        IERC20[] calldata tokens,
        address[] calldata spenders,
        uint256[] calldata amounts
    ) external onlyGovernorOrGuardian {
        if (tokens.length != amounts.length && spenders.length != amounts.length) revert IncompatibleLengths();
        for (uint256 i = 0; i < spenders.length; i++) {
            if (strategies[IStrategy4626(spenders[i])].lastReport == 0) revert StrategyDoesNotExist();
            _changeAllowance(tokens[i], spenders[i], amounts[i]);
        }
    }

    // ========================== Strategy functions ==============================

    /// @notice Reports the gains or loss made by a strategy
    /// @param strategyToAdjust List of strategies to adjust their positions
    /// @param managedAssets_ Total `asset` amount available
    /// @dev This is the main contact point where the strategy interacts with the `vault`
    /// @dev The strategy reports back what it has free, then the `vault` contract "decides"
    /// whether to take some back or give it more. Note that the most it can
    /// take is `gain + _debtPayment`, and the most it can give is all of the
    /// remaining reserves. Anything outside of those bounds is abnormal behavior.
    function adjustPosition(IStrategy4626[] memory strategyToAdjust, uint256 managedAssets_) internal {
        uint256 positiveChangedDebt;
        uint256 negativeChangedDebt;

        for (uint256 i = 0; i < strategyToAdjust.length; i++) {
            // Losses are generally not well taken into account
            uint256 maxWithdrawal = strategyToAdjust[i].maxWithdraw(address(this));

            StrategyParams storage params = strategies[strategyToAdjust[i]];
            // Warning: `totalAssets` could be manipulated by flashloan attacks.
            // It may allow external users to transfer funds into strategy or remove funds
            // from the strategy. Yet, as it does not impact the profit or loss and as attackers
            // have no interest in making such txs to have a direct profit, we let it as is.
            // The only issue is if the strategy is compromised; in this case governance
            // should revoke the strategy
            // We add `claimableRewards` to take into account all funds in the vault +
            // Otherwise there would be a discrepancy between the strategies `totalStrategyDebt`
            // and the target
            uint256 target = (managedAssets_ * params.debtRatio) / BASE_PARAMS;
            if (target > params.totalStrategyDebt) {
                // If the strategy has some credit left, tokens can be transferred to this strategy
                uint256 available = Math.min(target - params.totalStrategyDebt, getBalance());
                params.totalStrategyDebt = params.totalStrategyDebt + available;
                positiveChangedDebt += available;
                if (available > 0) {
                    strategyToAdjust[i].deposit(available, address(this));
                }
            } else {
                uint256 available = Math.min(params.totalStrategyDebt - target, maxWithdrawal);
                params.totalStrategyDebt = params.totalStrategyDebt - available;
                negativeChangedDebt += available;
                if (available > 0) {
                    uint256 withdrawLoss = strategyToAdjust[i].withdraw(available, address(this), address(this));
                    // TODO There won't be loss here because the funds should be already free
                    // useless to let in prod, but useful for testing purpose
                    if (withdrawLoss != 0) revert LossShouldbe0();
                }
            }
        }
        totalDebt = totalDebt + positiveChangedDebt - negativeChangedDebt;
    }

    // ===================== Internal functions ==========================

    /// @notice Accumulate profit/loss from strategies.
    /// @param activeStrategies Strategy list to consider
    /// @dev It accrues totalProfitLossAccrued, by looking at the difference between what can be
    /// withdrawn from the strategy and the last checkpoint on the strategy debt
    /// @dev Profits are linearly vested while losses are directly slashed to the `vault` capital
    function _updateMultiStrategiesBalances(IStrategy4626[] memory activeStrategies)
        internal
        returns (int256 totalProfitLossAccrued)
    {
        for (uint256 i = 0; i < activeStrategies.length; i++) {
            // Get the strategy at the current index.
            IStrategy4626 strategy = activeStrategies[i];

            StrategyParams storage params = strategies[strategy];
            uint256 debtLastCheckpoint = params.totalStrategyDebt;
            params.lastReport = block.timestamp;
            // strategy should be carefully design and not take into account unrealized profit
            // If we would consider the expected value and not the vested value,
            // the function could be manipulated by artificially creating false profit/loss.
            uint256 balanceThisHarvest = strategy.maxWithdraw(address(this));

            // Update the strategy's stored balance. Cast overflow is unrealistic.
            params.totalStrategyDebt = balanceThisHarvest;

            // Update the total profit/loss accrued since last harvest.
            // To overflow this would asks enormous debt amounts which are in base of asset
            totalProfitLossAccrued += int256(balanceThisHarvest) - int256(debtLastCheckpoint);
        }
    }

    /// @notice Distribute profit/loss to the users and protocol.
    /// @param totalProfitLossAccrued Profit or Loss made in between the 2 calls to `_accumulate`
    /// @dev It accrues totalProfitLossAccrued, by looking at the difference between what can be
    /// withdraw from the strategy and the last checkpoint on the strategy debt
    /// @dev Profits are directly distributed to the user/protocol because all strategies should
    /// linearly vest the rewards themselves
    /// @dev User losses are directly slashed from the capital brought by users
    /// Protocol losses first remove earned interest and keep track of bad debt to impact future gains
    function _accumulate(int256 totalProfitLossAccrued) internal {
        if (totalProfitLossAccrued > 0) {
            // Compute fees as the fee percent multiplied by the profit.
            uint256 feesAccrued = uint256(totalProfitLossAccrued).mulDiv(
                protocolFee,
                1e18,
                MathUpgradeable.Rounding.Down
            );
            _handleProtocolGain(feesAccrued);
            _handleUserGain(uint256(totalProfitLossAccrued) - feesAccrued);
        } else {
            uint256 feesDebt = uint256(-totalProfitLossAccrued).mulDiv(
                protocolFee,
                1e18,
                MathUpgradeable.Rounding.Down
            );
            _handleProtocolLoss(feesDebt);
            _handleUserLoss(uint256(-totalProfitLossAccrued) - feesDebt);
        }
    }

    /// @notice Propagates a protocol gain by minting yield bearing tokens
    /// @param gain Gain to propagate
    function _handleProtocolGain(uint256 gain) internal {
        uint256 currentLossVariable = protocolLoss;
        if (currentLossVariable >= gain) {
            protocolLoss -= gain;
        } else {
            // If we accrued any fees, mint an equivalent amount of yield bearing tokens.
            _mint(surplusManager, _convertToShares(gain - currentLossVariable, MathUpgradeable.Rounding.Down));
            protocolLoss = 0;
        }
    }

    /// @notice Propagates a Protocol loss
    /// @param loss Loss to propagate
    /// @dev Burning yield bearing tokens owned by the governance
    /// if it is not enough keep track of the bad debt
    function _handleProtocolLoss(uint256 loss) internal {
        address surplusOwner = surplusManager;
        uint256 claimableProtocolRewards = _convertToAssets(balanceOf(surplusManager), MathUpgradeable.Rounding.Down);
        if (claimableProtocolRewards >= loss) {
            _burn(surplusOwner, _convertToShares(loss, MathUpgradeable.Rounding.Down));
        } else {
            protocolLoss += loss - claimableProtocolRewards;
            _burn(surplusOwner, balanceOf(address(this)));
        }
    }

    /// @notice Propagates a user side gain
    /// @param gain Gain to propagate
    function _handleUserGain(uint256 gain) internal virtual;

    /// @notice Propagates a user side loss
    /// @param loss Loss to propagate
    function _handleUserLoss(uint256 loss) internal virtual;

    /// @notice Helper to estimate claimble rewards for a specific user
    /// @param from Address to check rewards from
    /// @return amount `from` reward balance if it gets updated
    function _claimableRewardsOf(address from) internal view virtual returns (uint256 amount);

    /// @notice If the user need to withdraw more than what is freely available on the contract
    /// we need to free funds from the strategies in the stack withdrawal order
    /// @param value Amount needed to be withdrawn
    /// @return the actual assets that can be withdrawn
    /// @return totalLoss Losses incurred when withdrawing from the strategies
    /// @dev Any loss incurred during the withdrawal will be fully at the expense of the caller
    function _beforeWithdraw(uint256 value) internal returns (uint256, uint256 totalLoss) {
        // TODO do we add slippage on this (this would break the interface) or we can have a gov slippage
        // but less modular
        uint256 maxLoss;

        uint256 vaultBalance = getBalance();
        if (value > vaultBalance) {
            IStrategy4626[] memory withdrawalStackMemory = withdrawalStack;

            uint256 newTotalDebt = totalDebt;
            // We need to go get some from our strategies in the withdrawal stack
            // NOTE: This performs forced withdrawals from each Strategy. During
            //      forced withdrawal, a Strategy may realize a loss. That loss
            //      is reported back to the Vault, and will affect the amount
            //      of tokens that the withdrawer receives for their shares. They
            //      can optionally specify the maximum acceptable loss (in BPS)
            //      to prevent excessive losses on their withdrawals (which may
            //      happen in certain edge cases where Strategies realize a loss)
            for (uint256 i = 0; i < withdrawalStackMemory.length; i++) {
                IStrategy4626 strategy = withdrawalStackMemory[i];
                // We've exhausted the queue
                if (address(strategy) == address(0)) break;

                // We're done withdrawing
                if (value <= vaultBalance) break;
                uint256 amountNeeded = value - vaultBalance;

                StrategyParams storage params = strategies[strategy];
                // NOTE: Don't withdraw more than the debt so that Strategy can still
                //      continue to work based on the profits it has
                // NOTE: This means that user will lose out on any profits that each
                //      Strategy in the queue would return on next harvest, benefiting others
                amountNeeded = Math.min(amountNeeded, params.totalStrategyDebt);
                // Nothing to withdraw from this Strategy, try the next one
                if (amountNeeded == 0) continue;

                // Force withdraw amount from each Strategy in the order set by governance
                uint256 loss = strategy.withdraw(amountNeeded, address(this), address(this));

                uint256 newVaultBalance = getBalance();
                uint256 withdrawn = newVaultBalance - vaultBalance;
                vaultBalance = newVaultBalance;

                // NOTE: Withdrawer incurs any losses from liquidation
                if (loss > 0) {
                    value = value > loss ? (value - loss) : 0;
                    totalLoss += loss;
                }

                // Reduce the Strategy's debt by the amount withdrawn ("realized returns")
                // NOTE: This doesn't add to returns as it's not earned by "normal means"
                params.totalStrategyDebt -= withdrawn + loss;
                newTotalDebt -= withdrawn + loss;
            }

            totalDebt = newTotalDebt;

            // NOTE: We have withdrawn everything possible out of the withdrawal queue
            //      but we still don't have enough to fully pay them back, so adjust
            //      to the total amount we've freed up through forced withdrawals
            if (value > vaultBalance) {
                value = vaultBalance;
            }

            // NOTE: This loss protection is put in place to revert if losses from
            //       withdrawing are more than what is considered acceptable.
            if (totalLoss > (maxLoss * value) / BASE_PARAMS) revert SlippageProtection();

            return (value, totalLoss);
        }
    }

    /// @notice Internal version of `updateStrategyDebtRatio`
    /// @dev Updates the debt ratio for a strategy
    function _updateStrategyDebtRatio(IStrategy4626 strategy, uint256 _debtRatio) internal {
        StrategyParams storage params = strategies[strategy];
        if (params.lastReport == 0) revert StrategyDoesNotExist();
        debtRatio = debtRatio + _debtRatio - params.debtRatio;
        if (debtRatio > BASE_PARAMS) revert DebtRatioTooHigh();
        params.debtRatio = _debtRatio;
        emit UpdatedDebtRatio(address(strategy), debtRatio);
    }

    /// @notice Changes allowance of a set of tokens to addresses
    /// @param token ERC20 token to perform the approval on
    /// @param spender Address to approve
    /// @param amount Approval amount
    function _changeAllowance(
        IERC20 token,
        address spender,
        uint256 amount
    ) internal {
        uint256 currentAllowance = token.allowance(address(this), address(spender));
        if (currentAllowance < amount) {
            token.safeIncreaseAllowance(address(spender), amount - currentAllowance);
        } else if (currentAllowance > amount) {
            token.safeDecreaseAllowance(address(spender), currentAllowance - amount);
        }
    }
}