// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.12;

import "./VaultStorage.sol";

/// @title Angle Vault
/// @author Angle Protocol
/// @notice Yield aggregator vault which can connect multiple ERC4626 strategies
/// @notice Integrate boosting mecanism on the yield
contract Vault is VaultStorage {
    using SafeERC20 for IERC20;
    using Address for address;
    using MathUpgradeable for uint256;

    function initialize(ICoreBorrow _coreBorrow, IERC20MetadataUpgradeable _token) external initializer {
        __ERC20_init(
            // Angle token Wrapper
            string(abi.encodePacked("Angle ", _token.name(), " Wrapper")),
            string(abi.encodePacked("aw", _token.symbol()))
        );
        __ERC20TokenizedVault_init(_token);
        coreBorrow = _coreBorrow;
        baseUnit = 10**_token.decimals();
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
    modifier onlyStrategy() {
        if (strategies[IStrategy4626(msg.sender)].lastReport == 0) revert NotStrategy();
        _;
    }

    // ============================== external ===================================

    /// @notice Harvest a set of trusted strategies.
    /// @dev Will always revert if called outside of an active
    /// harvest window or before the harvest delay has passed.
    /// @dev Do not allow partial accumulation (on a sub set of strategies)
    /// to limit risks on only acknowledging profit
    /// TODO doesn't looks like it is suited for general strategies
    /// There is no real harvest, it is just querying balanceOfUnderlying(),
    /// which in general can be maipulated. Curve example you can move the price
    /// to fake a profit. You won't have access directly to it, but you need to wait for
    /// mutliple blocks for the lockedProfit to go to 0. (if nobody calls the harvest between then )
    /// what if there is a loss, it decrease the strategies balance but not the lockedProfit.
    /// if an attacker make the profit goes to 10, calling harvest --> totalAssets = oldTotalAssets
    /// but lockedProfit = 10. Then another harvest takes place and there is a loss of 10. totalAssets = oldTotalAssets
    // and lockedProfit is still 10 --> 10 has been created out of thin air
    function accumulate() external {
        // Used to store the total profit/loss accrued by the strategies.
        /// TODO actually loss shouldn't happen here, but at harvest time by decreasing the debt
        /// and decreasing the total assets available (which will be taken into account in maxWithdraw() and totalStrategyDebt)
        int256 totalProfitLossAccrued;

        // Used to store the new total strategy holdings after harvesting.
        uint256 newTotalDebt = totalDebt;

        IStrategy4626[] memory activeStrategies = strategyList;

        // Will revert if any of the specified strategies are untrusted.
        for (uint256 i = 0; i < activeStrategies.length; i++) {
            // Get the strategy at the current index.
            IStrategy4626 strategy = activeStrategies[i];

            // Get the strategy's previous and current balance.
            uint256 debtLastHarvest = strategies[strategy].totalStrategyDebt;
            strategies[strategy].lastReport = block.timestamp;
            // strategy should be carefully design and not take into account unrealized profit/loss
            // it should be designed like this contract: previousDebt + unlocked profit/loss after an harvest in the sub contract
            // If we would consider the expected value, this function could be manipulated by artificially creating false profit/loss.
            uint256 balanceThisHarvest = strategy.maxWithdraw(address(this));

            // Update the strategy's stored balance. Cast overflow is unrealistic.
            strategies[strategy].totalStrategyDebt = balanceThisHarvest;

            // Increase/decrease newTotalDebt based on the profit/loss registered.
            // We cannot wrap the subtraction in parenthesis as it would underflow if the strategy had a loss.
            newTotalDebt = newTotalDebt + balanceThisHarvest - debtLastHarvest;

            // Update the total profit/loss accrued since last harvest.
            // To overflow this would asks enormous debt amounts which are in base of asset
            totalProfitLossAccrued += int256(balanceThisHarvest) - int256(debtLastHarvest);
        }

        if (totalProfitLossAccrued > 0) {
            // Compute fees as the fee percent multiplied by the profit.
            uint256 feesAccrued = uint256(totalProfitLossAccrued).mulDiv(
                feePercent,
                1e18,
                MathUpgradeable.Rounding.Down
            );
            _handleProtocolGain(feesAccrued);
            // safe as the first term is positive and the second one must be smaller
            _handleUserGain(uint256(totalProfitLossAccrued) - feesAccrued);
        } else {
            uint256 feesDebt = uint256(-totalProfitLossAccrued).mulDiv(feePercent, 1e18, MathUpgradeable.Rounding.Down);
            _handleProtocolLoss(feesDebt);
            // safe as the first term is negative and the second one must be smaller in absolute value
            _handleUserLoss(uint256(-totalProfitLossAccrued) - feesDebt);
        }

        // Set strategy holdings to our new total.
        totalDebt = newTotalDebt;
    }

    /// @notice Claims earned rewards
    /// @param from Address to claim for
    /// @return Amount claimed
    function claim(address from) external returns (uint256) {
        _updateAccumulator(from);
        return _claim(from);
    }

    // ===================== Internal functions ==========================

    /// @notice Propagates a gain to the claimable rewards
    /// @param gain Gain to propagate
    function _handleProtocolGain(uint256 gain) internal {
        uint256 currentLossVariable = protocolLoss;
        if (currentLossVariable >= gain) {
            protocolLoss -= gain;
        } else {
            // If we accrued any fees, mint an equivalent amount of rvTokens.
            // Authorized users can claim the newly minted rvTokens via claimFees.
            _mint(address(this), _convertToShares(gain - currentLossVariable, MathUpgradeable.Rounding.Down));
            protocolLoss = 0;
        }
    }

    /// @notice Propagates a loss to the claimable rewards and/or currentLoss
    /// @param loss Loss to propagate
    function _handleProtocolLoss(uint256 loss) internal {
        uint256 claimableRewards = maxWithdraw(address(this));
        if (claimableRewards >= loss) {
            _burn(address(this), _convertToShares(loss, MathUpgradeable.Rounding.Down));
        } else {
            protocolLoss += loss - claimableRewards;
            _burn(address(this), balanceOf(address(this)));
        }
    }

    /// @notice Propagates a gain to the claimable rewards
    /// @param gain Gain to propagate
    function _handleUserGain(uint256 gain) internal {
        uint256 currentLossVariable = usersLoss;
        if (currentLossVariable >= gain) {
            usersLoss -= gain;
        } else {
            maxLockedProfit = (lockedProfit() + gain - currentLossVariable);
            protocolLoss = 0;
        }
    }

    /// @notice Propagates a loss to the claimable rewards and/or currentLoss
    /// @param loss Loss to propagate
    function _handleUserLoss(uint256 loss) internal {
        usersLoss += loss;
    }

    /// @notice Claims rewards earned by a user
    /// @param from Address to claim rewards from
    /// @return amount Amount claimed by the user
    /// @dev Function will revert if there has been no mint
    function _claim(address from) internal returns (uint256 amount) {
        amount = (claimableRewards * rewardsAccumulatorOf[from]) / (rewardsAccumulator - claimedRewardsAccumulator);
        uint256 amountAvailable = getBalance();
        // If we cannot pull enough from the strat then `claim` has no effect
        if (amountAvailable >= amount) {
            claimedRewardsAccumulator += rewardsAccumulatorOf[from];
            rewardsAccumulatorOf[from] = 0;
            lastTimeOf[from] = block.timestamp;
            claimableRewards -= amount;
            IERC20(asset()).transfer(from, amount);
        }
    }

    /// @notice Calculate limits which depend on the amount of ANGLE token per-user.
    /// Effectively it calculates working balances to apply amplification of ANGLE production by ANGLE
    /// @param addr User address
    /// @param userShares User's amount of liquidity
    /// @param totalShares Total amount of liquidity
    function _updateLiquidityLimit(
        address addr,
        uint256 userShares,
        uint256 totalShares
    ) internal {
        // To be called after totalSupply is updated
        uint256 votingBalance = veBoostProxy.adjusted_balance_of(addr);
        uint256 votingTotal = votingEscrow.totalSupply();

        uint256 lim = (userShares * tokenlessProduction) / 100;
        if (votingTotal > 0) lim += (((totalShares * votingBalance) / votingTotal) * (100 - tokenlessProduction)) / 100;

        lim = Math.min(userShares, lim);
        uint256 oldBal = workingBalances[addr];
        workingBalances[addr] = lim;
        uint256 _workingSupply = workingSupply + lim - oldBal;
        workingSupply = _workingSupply;
    }

    /// @notice Updates global and `msg.sender` accumulator and rewards share
    /// @param from Address balance changed
    function _updateAccumulator(address from) internal {
        rewardsAccumulator += (block.timestamp - lastTime) * workingSupply;
        lastTime = block.timestamp;

        // This will be 0 on the first deposit since the balance is initialized later
        rewardsAccumulatorOf[from] += (block.timestamp - lastTimeOf[from]) * workingBalances[from];
        lastTimeOf[from] = block.timestamp;
    }

    /// @notice Internal function for `deposit` and `mint`
    /// @dev This function takes `usedAssets` and `looseAssets` as parameters to avoid repeated external calls

    function _deposit(
        address caller,
        address receiver,
        uint256 assets,
        uint256 shares
    ) private override {
        IERC20(asset()).safeTransferFrom(caller, address(this), assets);
        _updateAccumulator(receiver);
        _mint(receiver, shares);

        emit Deposit(caller, receiver, assets, shares);
    }

    /// @notice Internal function for `redeem` and `withdraw`
    /// @dev This function takes `usedAssets` and `looseAssets` as parameters to avoid repeated external calls
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

        _updateAccumulator(owner);
        _burn(owner, shares);

        emit Withdraw(caller, receiver, owner, assets, shares);

        IERC20(asset()).safeTransfer(receiver, assets);
    }

    /// TODO need to check if it works when transferring, because right now it first burn and mint and then
    /// call the _afterTokenTransfer
    function _afterTokenTransfer(
        address from,
        address to,
        uint256 amount
    ) internal override {
        _claim(from);
        uint256 totalSupply_ = totalSupply();
        if (from != address(0)) _updateLiquidityLimit(from, balanceOf(from), totalSupply_);
        if (to != address(0)) _updateLiquidityLimit(to, balanceOf(to), totalSupply_);
    }

    // ===================== Strategy related functions ==========================

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

    /// @notice Modifies the funds a strategy has access to
    /// @param strategy The address of the Strategy
    /// @param _debtRatio The share of the total assets that the strategy has access to
    /// @dev The update has to be such that the `debtRatio` does not exceeds the 100% threshold
    /// as this `PoolManager` cannot lend collateral that it doesn't not own.
    /// @dev `_debtRatio` is stored as a uint256 but as any parameter of the protocol, it should be expressed
    /// in `BASE_PARAMS`
    function updateStrategyDebtRatio(IStrategy4626 strategy, uint256 _debtRatio) external onlyGovernorOrGuardian {
        _updateStrategyDebtRatio(strategy, _debtRatio);
    }

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

        if (params.lastReport != 0) revert StrategyAlreadyAdded();
        if (address(this) != IStrategy4626(strategy).poolManager()) revert WrongPoolmanagerForStrategy();
        // Using current code, this condition should always be verified as in the constructor
        // of the strategy the `want()` is set to the token of this `PoolManager`
        if (asset() != strategy.asset()) revert WrongStrategyToken();
        require(debtRatio + _debtRatio <= BASE_PARAMS, "76");

        // Add strategy to approved strategies
        params.lastReport = 1;
        params.totalStrategyDebt = 0;
        params.debtRatio = _debtRatio;

        // Update global parameters
        debtRatio += _debtRatio;
        emit StrategyAdded(address(strategy), debtRatio);

        strategyList.push(strategy);
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
        if (params.lastReport != 0 && strategyListLength >= 1) revert revokeStrategyImpossible();
        // It has already been checked whether the strategy was a valid strategy
        for (uint256 i = 0; i < strategyListLength - 1; i++) {
            if (strategyList[i] == strategy) {
                strategyList[i] = strategyList[strategyListLength - 1];
                break;
            }
        }

        strategyList.pop();

        delete strategies[strategy];

        emit StrategyRevoked(address(strategy));
    }

    // ============================== Getters ===================================

    /// @notice Gets the full withdrawal stack.
    /// @return An ordered array of strategies representing the withdrawal stack.
    /// @dev This is provided because Solidity converts public arrays into index getters,
    /// but we need a way to allow external contracts and users to access the whole array.
    function getWithdrawalStack() external view returns (IStrategy4626[] memory) {
        return withdrawalStack;
    }

    /// @notice Calculates the total amount of underlying tokens the Vault holds.
    /// @return totalUnderlyingHeld The total amount of underlying tokens the Vault holds.
    /// @dev Important to not take into account lockedProfit otherwise there could be attacks on
    /// the vault. Someone could artificially make a strategy have large profit, to deposit and withdraw
    /// and earn free money.
    /// @dev Need to be cautious on when to use `totalAssets()` and `balanceOf(address(this))`. As when investing the money
    /// it is better to use the full balance. But need to make sure that there isn't any flaws by using 2 dufferent balances
    function totalAssets() public view override returns (uint256 totalUnderlyingHeld) {
        totalUnderlyingHeld = totalDebt + getBalance();
    }

    /// @notice Returns this `PoolManager`'s reserve of collateral (not including what has been lent)
    function getBalance() public view returns (uint256) {
        return IERC20(asset()).balanceOf(address(this));
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

    // ============================== Guardian ===================================

    /// @notice Claims fees accrued from harvests.
    /// @param awTokenAmount The amount of rvTokens to claim.
    /// @dev Accrued fees are measured as rvTokens held by the Vault.
    function claimFees(uint256 awTokenAmount) external onlyGovernor {
        emit FeesClaimed(msg.sender, awTokenAmount);

        // Transfer the provided amount of awTokens to the caller.
        _transfer(address(this), msg.sender, awTokenAmount);
    }

    // ============================== Governance ===================================

    /// @notice Sets a new withdrawal stack.
    /// @param newStack The new withdrawal stack.
    /// @dev Strategies that are untrusted, duplicated, or have no balance are
    /// filtered out when encountered at withdrawal time, not validated upfront.
    function setWithdrawalStack(IStrategy4626[] calldata newStack) external onlyGovernor {
        // Ensure the new stack is not larger than the maximum stack size.
        require(newStack.length <= MAX_WITHDRAWAL_STACK_SIZE, "STACK_TOO_BIG");

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
        require(newFeePercent <= 1e18, "FEE_TOO_HIGH");

        // Update the fee percentage.
        feePercent = newFeePercent;

        emit FeePercentUpdated(msg.sender, newFeePercent);
    }

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

    /*///////////////////////////////////////////////////////////////
                          RECIEVE ETHER LOGIC
    //////////////////////////////////////////////////////////////*/

    /// @dev Required for the Vault to receive unwrapped ETH.
    receive() external payable {}
}
