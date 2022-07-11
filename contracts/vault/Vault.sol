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

    /// @notice Claims earned rewards and update working balances
    /// @return amountClaimed Earned amount
    function checkpoint() external returns (uint256 amountClaimed) {
        _updateAccumulator(msg.sender);
        amountClaimed = _claim(msg.sender);
        _updateLiquidityLimit(msg.sender, balanceOf(msg.sender), totalSupply());
    }

    /// @notice Claims earned rewards
    /// @param from Address to claim for
    /// @return Amount claimed
    function claim(address from) external returns (uint256) {
        _updateAccumulator(from);
        return _claim(from);
    }

    /// @notice External call to `accumulate()`
    /// @dev Do not allow partial accumulation (on a sub set of strategies)
    /// to limit risks on only acknowledging profit
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
        _updateAccumulator(addr);
        _claim(addr);
        _updateLiquidityLimit(addr, balanceOf(addr), totalSupply);
    }

    /// @notice Reports the gains or loss made by a strategy
    /// @param gain Amount strategy has realized as a gain on its investment since its
    /// last report, and is free to be given back to `PoolManager` as earnings
    /// @param loss Amount strategy has realized as a loss on its investment since its
    /// last report, and should be accounted for on the `PoolManager`'s balance sheet.
    /// The loss will reduce the `debtRatio`. The next time the strategy will harvest,
    /// it will pay back the debt in an attempt to adjust to the new debt limit.
    /// @param debtPayment Amount strategy has made available to cover outstanding debt
    /// @dev This is the main contact point where the strategy interacts with the `PoolManager`
    /// @dev The strategy reports back what it has free, then the `PoolManager` contract "decides"
    /// whether to take some back or give it more. Note that the most it can
    /// take is `gain + _debtPayment`, and the most it can give is all of the
    /// remaining reserves. Anything outside of those bounds is abnormal behavior.
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
            totalDebt = totalDebt + available;
            if (available > 0) {
                strategy.deposit(available, address(this));
            }
        } else {
            uint256 available = Math.min(params.totalStrategyDebt - target, debtPayment + gain);
            params.totalStrategyDebt = params.totalStrategyDebt - available;
            totalDebt = totalDebt - available;
            if (available > 0) {
                strategy.withdraw(available, address(this), address(this));
            }
        }
    }

    // ===================== Internal functions ==========================

    /// @notice Accumulate profit/loss from all sub strategies.
    /// @dev This function is only used here to distribute the linear vesting of the strategies
    /// @dev Profit are linearly vested while losses directly impacts funds
    /// TODO doesn't looks like it is suited for general strategies
    /// There is no real harvest, it is just querying balanceOfUnderlying(),
    /// which in general can be maipulated. Curve example you can move the price
    /// to fake a profit. You won't have access directly to it, but you need to wait for
    /// mutliple blocks for the lockedProfit to go to 0. (if nobody calls the harvest between then )
    /// what if there is a loss, it decrease the strategies balance but not the lockedProfit.
    /// if an attacker make the profit goes to 10, calling harvest --> totalAssets = oldTotalAssets
    /// but lockedProfit = 10. Then another harvest takes place and there is a loss of 10. totalAssets = oldTotalAssets
    // and lockedProfit is still 10 --> 10 has been created out of thin air
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

    function _updateSingleStrategyBalance(IStrategy4626 strategy, int256 totalProfitLossAccrued)
        internal
        returns (int256)
    {
        // Get the strategy's previous and current balance.
        uint256 debtLastHarvest = strategies[strategy].totalStrategyDebt;
        strategies[strategy].lastReport = block.timestamp;
        // strategy should be carefully design and not take into account unrealized profit/loss
        // it should be designed like this contract: previousDebt + unlocked profit/loss after an harvest in the sub contract
        // If we would consider the expected value, this function could be manipulated by artificially creating false profit/loss.
        uint256 balanceThisHarvest = strategy.maxWithdraw(address(this));

        // Update the strategy's stored balance. Cast overflow is unrealistic.
        strategies[strategy].totalStrategyDebt = balanceThisHarvest;

        // Update the total profit/loss accrued since last harvest.
        // To overflow this would asks enormous debt amounts which are in base of asset
        totalProfitLossAccrued += int256(balanceThisHarvest) - int256(debtLastHarvest);

        return totalProfitLossAccrued;
    }

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

    /// @notice Propagates a gain to the claimable rewards
    /// @param gain Gain to propagate
    function _handleProtocolGain(uint256 gain) internal {
        uint256 currentLossVariable = protocolLoss;
        if (currentLossVariable >= gain) {
            protocolLoss -= gain;
        } else {
            // If we accrued any fees, mint an equivalent amount of rvTokens.
            // Authorized users can claim the newly minted rvTokens via claimFees.
            // TODO Rari was doing this (allows to compound revenues but not super useful)
            _mint(address(this), _convertToShares(gain - currentLossVariable, MathUpgradeable.Rounding.Down));
            protocolLoss = 0;
        }
    }

    /// @notice Propagates a loss to the claimable rewards and/or currentLoss
    /// @param loss Loss to propagate
    function _handleProtocolLoss(uint256 loss) internal {
        uint256 claimableProtocolRewards = maxWithdraw(address(this));
        if (claimableProtocolRewards >= loss) {
            _burn(address(this), _convertToShares(loss, MathUpgradeable.Rounding.Down));
        } else {
            protocolLoss += loss - claimableProtocolRewards;
            _burn(address(this), balanceOf(address(this)));
        }
    }

    /// @notice Claims rewards earned by a user
    /// @param from Address to claim rewards from
    /// @return amount Amount claimed by the user
    /// @dev Function will revert if there has been no mint
    /// @dev when calling `_claim()` we should make sure that there is enough funds
    /// Recalling that it is called on deposits, withdraws and checkpoints
    function _claim(address from) internal returns (uint256 amount) {
        amount = (claimableRewards * rewardsAccumulatorOf[from]) / (rewardsAccumulator - claimedRewardsAccumulator);
        claimedRewardsAccumulator += rewardsAccumulatorOf[from];
        rewardsAccumulatorOf[from] = 0;
        lastTimeOf[from] = block.timestamp;
        claimableRewards -= amount;
        IERC20(asset()).transfer(from, amount);
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

    /// @dev This force claiming as we can't feed a boolean on whether or not we should claim
    /// TODO just let the `claim()` function, there could always be a router on top of it making the different
    /// calls
    function _beforeTokenTransfer(
        address from,
        address to,
        uint256
    ) internal override {
        if (from != address(0)) {
            _updateAccumulator(from);
            _claim(from);
        }
        if (to != address(0)) {
            _updateAccumulator(to);
            _claim(to);
        }
    }

    function _afterTokenTransfer(
        address from,
        address to,
        uint256
    ) internal override {
        uint256 totalSupply_ = totalSupply();
        if (from != address(0)) _updateLiquidityLimit(from, balanceOf(from), totalSupply_);
        if (to != address(0)) _updateLiquidityLimit(to, balanceOf(to), totalSupply_);
    }

    /// @notice Calculate limits which depend on the amount of ANGLE token per-user.
    /// Effectively it calculates working balances to apply amplification of ANGLE production by ANGLE
    /// @param addr User address
    /// @param userShares User's amount of liquidity
    /// @param totalShares Total amount of liquidity
    /// @dev We can add anyother metric that seems suitable to adap working balances
    /// Here we only take into account the veANGLE balances, but we can also add a parameter on
    /// locking period --> but this would break the ERC4626 interfaces --> NFT
    function _updateLiquidityLimit(
        address addr,
        uint256 userShares,
        uint256 totalShares
    ) internal {
        // To be called after totalSupply is updated
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

    // ===================== Strategy related functions ==========================

    /// @notice Tells a strategy how much it can borrow from this `PoolManager`
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
        totalUnderlyingHeld = totalDebt + getBalance() - claimableRewards;
    }

    /// @notice Returns this `PoolManager`'s reserve of collateral (not including what has been lent)
    function getBalance() public view returns (uint256) {
        return IERC20(asset()).balanceOf(address(this));
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
}
