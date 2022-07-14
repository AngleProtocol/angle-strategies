// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.12;

import "./SavingsRateStorage.sol";

/// @title Angle Vault
/// @author Angle Protocol
/// @notice Yield aggregator vault which can connect multiple ERC4626 strategies
/// @notice Integrate boosting mecanism on the yield
contract SavingsRate is SavingsRateStorage {
    using SafeERC20 for IERC20;
    using Address for address;
    using MathUpgradeable for uint256;

    function initialize(ICoreBorrow _coreBorrow, IERC20MetadataUpgradeable _token) external initializer {
        __ERC20_init_unchained(
            // Angle token Wrapper
            string(abi.encodePacked("Angle ", _token.name(), " Wrapper")),
            string(abi.encodePacked("aw", _token.symbol()))
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

    /// @notice Calculates the total amount of underlying tokens the Vault holds.
    /// @return totalUnderlyingHeld The total amount of underlying tokens the Vault holds.
    /// @dev Need to be cautious on when to use `totalAssets()` and `totalDebt + getBalance()`. As when investing the money
    /// it is better to use the full balance. But we shouldn't count the rewards twice (in the rewards and in the shares)
    function totalAssets() public view override returns (uint256 totalUnderlyingHeld) {
        totalUnderlyingHeld = totalDebt + getBalance() - claimableRewards;
    }

    /// @notice Returns this `vault`'s directly available reserve of collateral (not including what has been lent)
    function getBalance() public view returns (uint256) {
        return IERC20(asset()).balanceOf(address(this));
    }

    /// @notice Tells a strategy how much it can borrow from this `vault`
    /// @param strategy Strategy to consider in the call
    /// @return Amount of token a strategy has access to as a credit line
    /// @dev Since this function is a view function, there is no need to have an access control logic
    /// even though it will just be relevant for a strategy
    /// @dev Manipulating `_getTotalAsset` with a flashloan will only
    /// result in tokens being transferred at the cost of the caller
    function creditAvailable(address strategy) external view returns (uint256) {
        StrategyParams storage params = strategies[IStrategy4626(strategy)];

        uint256 target = (totalAssets() * params.debtRatio) / BASE_PARAMS;

        if (target < params.totalStrategyDebt) return 0;

        return Math.min(target - params.totalStrategyDebt, getBalance());
    }

    /// @notice Tells a strategy how much it owes to this `PoolManager`
    /// @param strategy Strategy to consider in the call
    /// @return Amount of token a strategy has to reimburse
    /// @dev Manipulating `_getTotalAsset` with a flashloan will only
    /// result in tokens being transferred at the cost of the caller
    function debtOutstanding(address strategy) external view returns (uint256) {
        StrategyParams storage params = strategies[IStrategy4626(strategy)];

        uint256 target = (totalAssets() * params.debtRatio) / BASE_PARAMS;

        if (target > params.totalStrategyDebt) return 0;

        return (params.totalStrategyDebt - target);
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
        /// TODO can we take into account possible losses? Looks hard
        if (assets >= ownerReward) {
            return _convertToShares(assets - ownerReward, MathUpgradeable.Rounding.Up);
        } else {
            return 0;
        }
    }

    /** @dev See {IERC4262-previewRedeem}. */
    function previewRedeem(address owner, uint256 shares) public view returns (uint256) {
        uint256 ownerTotalShares = maxRedeem(owner);
        uint256 ownerReward = _claimableRewardsOf(owner);
        uint256 ownerRewardShares = (ownerReward * shares) / ownerTotalShares;
        /// TODO can we take into account possible losses? Looks hard
        return _convertToAssets(shares, MathUpgradeable.Rounding.Down) + ownerRewardShares;
    }

    // ====================== External permissionless functions =============================

    /** @dev See {IERC4262-withdraw} */
    function withdraw(
        uint256 assets,
        address receiver,
        address owner
    ) public virtual override returns (uint256) {
        uint256 ownerReward = _claim(owner);
        uint256 loss;
        (assets, loss) = _beforeWithdraw(assets);

        uint256 shares;
        uint256 assetsTrueCost = assets + loss;
        if (ownerReward < assetsTrueCost) {
            require(assetsTrueCost - ownerReward <= maxWithdraw(owner), "ERC4626: withdraw more than max");
            shares = _convertToShares(assetsTrueCost - ownerReward, MathUpgradeable.Rounding.Up);
            rewardBalances[owner] -= ownerReward;
        } else {
            rewardBalances[owner] -= assets;
        }

        _withdraw(_msgSender(), receiver, owner, assets, shares);

        return shares;
    }

    /** @dev See {IERC4262-redeem} */
    function redeem(
        uint256 shares,
        address receiver,
        address owner
    ) public virtual override returns (uint256) {
        uint256 ownerTotalShares = maxRedeem(owner);
        require(shares <= ownerTotalShares, "ERC4626: redeem more than max");

        uint256 ownerReward = _claim(owner);
        uint256 ownerRewardShares = (ownerReward * shares) / ownerTotalShares;

        uint256 assets = _convertToAssets(shares, MathUpgradeable.Rounding.Down);
        uint256 loss;
        uint256 freedAssets;
        (freedAssets, loss) = _beforeWithdraw(assets + ownerRewardShares);
        // if we didn't suceed to withdraw enough, we need to decrease the number of shares burnt
        if (freedAssets < ownerRewardShares) {
            shares = 0;
            rewardBalances[owner] -= freedAssets;
        } else if (freedAssets < assets + ownerRewardShares) {
            assets = freedAssets - ownerRewardShares;
            shares = _convertToShares(assets, MathUpgradeable.Rounding.Up);
            rewardBalances[owner] -= ownerRewardShares;
        } else {
            rewardBalances[owner] -= ownerRewardShares;
        }

        // `assets-loss` will never revert here because it would revert on the slippage protection in `withdraw()`
        _withdraw(_msgSender(), receiver, owner, freedAssets - loss, shares);

        return freedAssets - loss;
    }

    /// @notice Claims earned rewards and update working balances
    /// @return rewardBalance `msg.sender` reward balance at the end of the function
    function checkpoint() external returns (uint256 rewardBalance) {
        rewardBalance = _claim(msg.sender);
        _updateLiquidityLimit(msg.sender, balanceOf(msg.sender), totalSupply());
    }

    /// @notice Helper to estimate claimble rewards for a specific user
    /// @param from Address to estimate rewards from
    /// @return amount `from` reward balance if it gets updated
    function claimableRewardsOf(address from) external view returns (uint256) {
        return _claimableRewardsOf(from);
    }

    /// @notice To deposit directly rewards onto the contract
    /// TODO not a fan it looks weird to have the equivalent of a strategy here
    /// while we can just do a dumb strategy and link it to this country, so that they all have the same interface
    function notifyRewardAmount(uint256 amount) external {
        SafeERC20Upgradeable.safeTransferFrom(IERC20Upgradeable(asset()), msg.sender, address(this), amount);
        claimableRewards += amount;
    }

    /// @notice Update distributable rewards made from all strategies
    /// @dev Do not allow partial accumulation (on a sub set of strategies)
    /// to limit risks on only acknowledging profits
    /// @dev There should never be any loss distributed calling this function as the only
    /// way to acknowledge a loss is to harvest the strategy
    /// TODO It can actually be done via harvesting specific strategies
    function accumulate() external {
        IStrategy4626[] memory activeStrategies = strategyList;
        int256 totalProfitLossAccrued = _updateMultiStrategiesBalances(activeStrategies);
        _accumulate(totalProfitLossAccrued);
    }

    /// @notice  Kick `addr` for abusing their boost
    /// Only if either they had another voting event, or their voting escrow lock expired
    /// @param addr Address to kick
    function kick(address addr) external {
        uint256 tLast = lastTimeOf[addr];
        uint256 tVe = votingEscrow.user_point_history__ts(addr, votingEscrow.user_point_epoch(addr));
        uint256 _balance = balanceOf(addr);

        if (IERC20(address(votingEscrow)).balanceOf(addr) != 0 && tVe <= tLast) revert KickNotAllowed();
        if (workingBalances[addr] <= (_balance * tokenlessProduction) / 100) revert KickNotNeeded();

        uint256 totalSupply = totalSupply();
        _claim(addr);
        _updateLiquidityLimit(addr, balanceOf(addr), totalSupply);
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

    /// @notice Sets a new fee percentage.
    /// @param newFeePercent The new fee percentage.
    function setFeePercent(uint256 newFeePercent) external onlyGovernor {
        // A fee percentage over 100% doesn't make sense.
        if (newFeePercent >= BASE_PARAMS) revert ProtocolFeeTooHigh();
        // Update the fee percentage.
        feePercent = newFeePercent;

        emit FeePercentUpdated(msg.sender, newFeePercent);
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

    /// @notice Triggers an emergency exit for a strategy and then harvests it to fetch all the funds
    /// @param strategy The address of the `Strategy`
    function setStrategyEmergencyExit(IStrategy4626 strategy) external onlyGovernorOrGuardian {
        _updateStrategyDebtRatio(strategy, 0);
        strategy.setEmergencyExit();
        strategy.harvest();
    }

    /// @notice Changes allowance of a set of tokens to addresses
    /// @param spenders Addresses to approve
    /// @param amounts Approval amounts for each address
    function changeAllowance(address[] calldata spenders, uint256[] calldata amounts) external onlyGovernorOrGuardian {
        if (spenders.length != amounts.length) revert IncompatibleLengths();
        for (uint256 i = 0; i < spenders.length; i++) {
            if (strategies[IStrategy4626(spenders[i])].lastReport == 0) revert StrategyDoesNotExist();
            _changeAllowance(spenders[i], amounts[i]);
        }
    }

    // ========================== Strategy functions ==============================

    /// @notice Reports the gains or loss made by a strategy
    /// @param gain Amount strategy has realized as a gain on its investment since its
    /// last report, and is free to be given back to `vault` as earnings
    /// @param loss Amount strategy has realized as a loss on its investment since its
    /// last report, and should be accounted for on the `vault`'s balance sheet.
    /// @param debtPayment Amount strategy has made available to cover outstanding debt
    /// @dev This is the main contact point where the strategy interacts with the `vault`
    /// @dev The strategy reports back what it has free, then the `vault` contract "decides"
    /// whether to take some back or give it more. Note that the most it can
    /// take is `gain + _debtPayment`, and the most it can give is all of the
    /// remaining reserves. Anything outside of those bounds is abnormal behavior.
    /// TODO should remove gain and loss variable as loss is useless?
    function report(
        uint256 gain,
        uint256 loss,
        uint256 debtPayment
    ) external onlyStrategy {
        IStrategy4626 strategy = IStrategy4626(msg.sender);

        if (strategy.maxWithdraw(address(this)) < gain + debtPayment) revert StratgyLowOnCash();

        int256 totalProfitLossAccrued;
        totalProfitLossAccrued = _updateSingleStrategyBalance(strategy, totalProfitLossAccrued);
        _accumulate(totalProfitLossAccrued);

        StrategyParams storage params = strategies[strategy];
        // Warning: `_getTotalAsset` could be manipulated by flashloan attacks.
        // It may allow external users to transfer funds into strategy or remove funds
        // from the strategy. Yet, as it does not impact the profit or loss and as attackers
        // have no interest in making such txs to have a direct profit, we let it as is.
        // The only issue is if the strategy is compromised; in this case governance
        // should revoke the strategy
        // We add `claimableRewards` to take into account all funds in the vault +
        // Otherwise there would be a discrepancy between the strategies `totalStrategyDebt`
        // and the target
        uint256 target = ((totalAssets() + claimableRewards) * params.debtRatio) / BASE_PARAMS;
        if (target > params.totalStrategyDebt) {
            // If the strategy has some credit left, tokens can be transferred to this strategy
            uint256 available = Math.min(target - params.totalStrategyDebt, getBalance());
            params.totalStrategyDebt = params.totalStrategyDebt + available;
            totalDebt += available;
            if (available > 0) {
                strategy.deposit(available, address(this));
            }
        } else {
            uint256 available = Math.min(params.totalStrategyDebt - target, debtPayment + gain);
            params.totalStrategyDebt = params.totalStrategyDebt - available;
            totalDebt -= available;
            if (available > 0) {
                uint256 withdrawLoss = strategy.withdraw(available, address(this), address(this));
                // TODO There will be no loss here because the funds should be already free
                // useless to let in prod, but useful for testing purpose
                if (withdrawLoss != 0) revert LossShouldbe0();
            }
        }
    }

    // ===================== Internal functions ==========================

    /// @notice Accumulate profit/loss from strategies.
    /// @param activeStrategies Strategy list to consider
    /// @dev This function is only used here to distribute the linear vesting of the strategies
    /// @dev Profits are linearly vested while losses are disctly slashed to the `vault` capital
    function _updateMultiStrategiesBalances(IStrategy4626[] memory activeStrategies)
        internal
        returns (int256 totalProfitLossAccrued)
    {
        for (uint256 i = 0; i < activeStrategies.length; i++) {
            // Get the strategy at the current index.
            IStrategy4626 strategy = activeStrategies[i];

            totalProfitLossAccrued = _updateSingleStrategyBalance(strategy, totalProfitLossAccrued);
        }
    }

    /// @notice Accumulate profit/loss for a specific strategy.
    /// @param strategy Strategy to accumulate for
    /// @dev It accrues totalProfitLossAccrued, by looking at the difference between what can be
    /// withdraw from the strategy and the last checkpoint on the strategy debt
    function _updateSingleStrategyBalance(IStrategy4626 strategy, int256 totalProfitLossAccrued)
        internal
        returns (int256)
    {
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

        return totalProfitLossAccrued;
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
                feePercent,
                1e18,
                MathUpgradeable.Rounding.Down
            );
            _handleProtocolGain(feesAccrued);
            claimableRewards += uint256(totalProfitLossAccrued) - feesAccrued;
        } else {
            uint256 feesDebt = uint256(-totalProfitLossAccrued).mulDiv(feePercent, 1e18, MathUpgradeable.Rounding.Down);
            _handleProtocolLoss(feesDebt);
            // Decrease newTotalDebt, this impacts the `totalAssets()` call --> loss directly implied when withdrawing
            totalDebt -= uint256(-totalProfitLossAccrued) - feesDebt;
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

    /// @notice Propagates a loss
    /// @param loss Loss to propagate
    /// @dev Burning yield bearing tokens owned by the governance
    /// if it is not enough keep track of the bad debt
    function _handleProtocolLoss(uint256 loss) internal {
        uint256 claimableProtocolRewards = maxWithdraw(address(this));
        if (claimableProtocolRewards >= loss) {
            _burn(address(this), _convertToShares(loss, MathUpgradeable.Rounding.Down));
        } else {
            protocolLoss += loss - claimableProtocolRewards;
            _burn(address(this), balanceOf(address(this)));
        }
    }

    /// @notice Claims earned rewards
    /// @param from Address to claim for
    /// @return Transferred amount to `from`
    function _claim(address from) internal returns (uint256) {
        _updateAccumulator(from);
        return _updateRewardBalance(from);
    }

    /// @notice Claims rewards earned by a user
    /// @param from Address to claim rewards from
    /// @return amount `from`reward balance at the end of the call
    /// @dev Function will revert if not enough funds are sitting idle on the contract
    function _updateRewardBalance(address from) internal returns (uint256 amount) {
        amount = (claimableRewards * rewardsAccumulatorOf[from]) / (rewardsAccumulator - claimedRewardsAccumulator);
        claimedRewardsAccumulator += rewardsAccumulatorOf[from];
        rewardsAccumulatorOf[from] = 0;
        lastTimeOf[from] = block.timestamp;
        claimableRewards -= amount;
        uint256 currentRewardBalance = rewardBalances[from];
        rewardBalances[from] = currentRewardBalance + amount;
        return currentRewardBalance + amount;
    }

    /// @notice Updates global and `from` accumulator and rewards share
    /// @param from Address balance changed
    function _updateAccumulator(address from) internal {
        rewardsAccumulator += (block.timestamp - lastTime) * workingSupply;
        lastTime = block.timestamp;

        // This will be 0 on the first deposit since the balance is initialized later
        rewardsAccumulatorOf[from] += (block.timestamp - lastTimeOf[from]) * workingBalances[from];
        lastTimeOf[from] = block.timestamp;
    }

    /// @notice Helper to estimate claimble rewards for a specific user
    /// @param from Address to check rewards from
    /// @return amount `from` reward balance if it gets updated
    function _claimableRewardsOf(address from) internal view returns (uint256 amount) {
        uint256 rewardsAccumulatorTmp = rewardsAccumulator + (block.timestamp - lastTime) * workingSupply;
        // This will be 0 on the first deposit since the balance is initialized later
        uint256 rewardsAccumulatorOfTmp = rewardsAccumulatorOf[from] +
            (block.timestamp - lastTimeOf[from]) *
            workingBalances[from];
        amount = (claimableRewards * rewardsAccumulatorOfTmp) / (rewardsAccumulatorTmp - claimedRewardsAccumulator);
        uint256 currentRewardBalance = rewardBalances[from];
        return currentRewardBalance + amount;
    }

    /** @dev See {ERC20Upgradeable-_beforeTokenTransfer} */
    /// @dev In the case of a burn the call has been already made
    function _beforeTokenTransfer(
        address from,
        address to,
        uint256
    ) internal override {
        if (to != address(0)) {
            _claim(to);
            if (from != address(0)) {
                _claim(from);
            }
        }
    }

    /** @dev See {ERC20Upgradeable-_afterTokenTransfer} */
    function _afterTokenTransfer(
        address from,
        address to,
        uint256
    ) internal override {
        uint256 totalSupply_ = totalSupply();
        if (from != address(0)) _updateLiquidityLimit(from, balanceOf(from), totalSupply_);
        if (to != address(0)) _updateLiquidityLimit(to, balanceOf(to), totalSupply_);
    }

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

    /// @notice Calculate limits which depend on the amount of veANGLE token per-user.
    /// Effectively it computes a modified balance and total supply, to redirect rewards
    /// not only based on liquidity but also external factors
    /// @param addr User address
    /// @param userShares User's vault shares
    /// @param totalShares Total vault shares
    /// @dev To be called after totalSupply is updated
    /// @dev We can add any other metric that seems suitable to adapt working balances
    /// Here we only take into account the veANGLE balances, but we can also add a parameter on
    /// locking period --> but this would break the ERC4626 interfaces --> NFT
    function _updateLiquidityLimit(
        address addr,
        uint256 userShares,
        uint256 totalShares
    ) internal {
        uint256 votingBalance = veBoostProxy.adjusted_balance_of(addr);
        uint256 votingTotal = IERC20(address(votingEscrow)).totalSupply();

        uint256 lim = (userShares * tokenlessProduction) / 100;
        if (votingTotal > 0) lim += (((totalShares * votingBalance) / votingTotal) * (100 - tokenlessProduction)) / 100;

        lim = Math.min(userShares, lim);
        uint256 oldBal = workingBalances[addr];
        workingBalances[addr] = lim;
        uint256 _workingSupply = workingSupply + lim - oldBal;
        workingSupply = _workingSupply;
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
    /// @param spender Address to approve
    /// @param amount Approval amount
    function _changeAllowance(address spender, uint256 amount) internal {
        IERC20 asset = IERC20(asset());
        uint256 currentAllowance = asset.allowance(address(this), address(spender));
        if (currentAllowance < amount) {
            asset.safeIncreaseAllowance(address(spender), amount - currentAllowance);
        } else if (currentAllowance > amount) {
            asset.safeDecreaseAllowance(address(spender), currentAllowance - amount);
        }
    }
}
