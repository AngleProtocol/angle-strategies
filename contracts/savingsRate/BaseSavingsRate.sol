// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.12;

import "./BaseSavingsRateStorage.sol";

/// @title BaseSavingsRate
/// @author Angle Protocol
/// @notice Base contract for yield aggregator vaults which can connect to multiple ERC4626 strategies
/// @dev This base contract can be used for savings rate contracts that give a boost in yield to some addresses
/// as well as for contracts that do not handle such boosts
// TODO:
// - add support for deposit and withdrawal fee: with a function for deposit and withdrawal fee
// - make sure it works perfect for normal contract with no boost everywhere
// - way to price the token easily for the strategy so that it can be easily integrated
abstract contract BaseSavingsRate is BaseSavingsRateStorage {
    using SafeERC20 for IERC20;
    using Address for address;
    using MathUpgradeable for uint256;

    /// @notice Initializes the contract
    /// @param _coreBorrow Reference to the `CoreBorrow` contract
    /// @param _token Asset of the vault
    /// @param suffixName Suffix to add to the token name for the symbol and name of the vault
    function _initialize(
        ICoreBorrow _coreBorrow,
        IERC20MetadataUpgradeable _token,
        address _surplusManager,
        string memory suffixName
    ) internal initializer {
        if (address(_coreBorrow) == address(0) || _surplusManager == address(0)) revert ZeroAddress();
        __ERC20_init_unchained(
            string(abi.encodePacked("Angle ", _token.name(), " ", suffixName, " Savings Rate")),
            string(abi.encodePacked("agsr-", _token.symbol(), "-", suffixName))
        );
        __ERC4626_init_unchained(_token);
        coreBorrow = _coreBorrow;
        surplusManager = _surplusManager;
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

    // ============================== View functions ===============================

    /// @notice Gets the full withdrawal stack.
    /// @return An ordered array of strategies representing the withdrawal stack.
    /// @dev Helper for UIs
    function getWithdrawalStack() external view returns (IStrategy4626[] memory) {
        return withdrawalStack;
    }

    /// @notice Returns the list of all AMOs supported by this contract
    /// @dev Helper for UIs
    function getStrategyList() external view returns (IStrategy4626[] memory) {
        return strategyList;
    }

    /// @notice Returns this savings rate contract's directly available reserve of collateral (not including what has been lent)
    function getBalance() public view returns (uint256) {
        return IERC20(asset()).balanceOf(address(this));
    }

    /// @notice Returns this contract's managed assets
    function managedAssets() public view virtual returns (uint256);

    /// @notice Provides an estimated Annual Percentage Rate for base depositors on this contract
    /// @dev This function is an estimation and is made for external use only
    /// @dev If the strategy is currently vesting some rewards then we compute the APR based on the
    /// accumulated rewards, otherwise we simply look at the estimated APR of all the strategies
    function estimatedAPR() external view returns (uint256 apr) {
        uint256 maximumLockedProfit = maxLockedProfit;
        if (maximumLockedProfit != 0)
            apr = (maximumLockedProfit * 3600 * 24 * 365 * BASE_PARAMS) / (vestingPeriod * managedAssets());
        else {
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
    }

    /// @inheritdoc ERC4626Upgradeable
    /// @dev The amount returned here will be underestimated if the balance of the vault is inferior than the
    /// asset value of the owner's shares
    /// @dev The reason for this is that the ERC4626 interface states that the max withdrawal
    /// amount can be underestimated and we only consider the `asset` balance directly available in the contract
    /// to avoid anticipating potential withdrawals from strategies
    function maxWithdraw(address owner) public view override returns (uint256) {
        uint256 maxAsset = _convertToAssets(balanceOf(owner), MathUpgradeable.Rounding.Down) +
            _claimableRewardsOf(owner);
        return Math.min(maxAsset, getBalance());
    }

    /// @inheritdoc ERC4626Upgradeable
    /// @dev Like for `maxWithdraw`, this function underestimates the amount of shares `owner` can actually
    /// redeem
    function maxRedeem(address owner) public view virtual override returns (uint256) {
        uint256 shares = balanceOf(owner);
        if (shares == 0) return 0;
        uint256 contractBalance = getBalance();
        uint256 assets = _convertToAssets(shares, MathUpgradeable.Rounding.Down);
        uint256 reward = _claimableRewardsOf(owner);
        // If there is enough asset in the contract for the rewards plus the asset value of the shares,
        // then the `owner` can withdraw all its shares
        if (contractBalance > reward + assets) return shares;
        // In the other case, the `owner` may only be able to redeem a certain proportion of its shares.
        // If there are only 5 agEUR available and I have 20 shares worth 10 agEUR in the contract,
        // then my max redemption amount is 10 shares
        else return shares.mulDiv(contractBalance, reward + assets, MathUpgradeable.Rounding.Down);
    }

    /// @inheritdoc ERC4626Upgradeable
    /// @dev In case the savings rate contract gives different yield to different addresses
    /// (based on their veANGLE balance for instance), the output of this function depends on the `msg.sender`
    function previewWithdraw(uint256 assets) public view override returns (uint256) {
        return previewWithdraw(msg.sender, assets);
    }

    /// @inheritdoc ERC4626Upgradeable
    /// @dev Like `previewWithdraw`, this function also depends on the `msg.sender`
    function previewRedeem(uint256 shares) public view override returns (uint256) {
        return previewRedeem(msg.sender, shares);
    }


    /// @notice Allows an on-chain or off-chain user to simulate the effects of their withdrawal
    /// at the current block, given current on-chain conditions and for a chosen address
    /// @dev This function is made for implementations of savings rate contracts where a boost is given to
    /// some addresses and not all users are equivalent
    function previewWithdraw(address owner, uint256 assets) public view returns (uint256) {
        // If there is no boost, this should be independent of the owner
        uint256 ownerReward = _claimableRewardsOf(owner);
        if (ownerReward == 0) return _convertToShares(assets, MathUpgradeable.Rounding.Up);
        else {
            // If there is a boost, let's say you brought 10 of assets, got 20 shares and then earned 1 of asset, then
            // to get back 2 of assets in this case where shares are not the same for everyone you need to burn:
            // 2 * 20 / (12)
            uint256 ownerShares = balanceOf(owner);
            uint256 ownerAssets = _convertToAssets(ownerShares, MathUpgradeable.Rounding.Down);
            return assets.mulDiv(ownerShares, ownerReward + ownerAssets, MathUpgradeable.Rounding.Up);
        }
    }

    /// @notice Implementation of the `previewRedeem` function for a specific `owner`
    /// @dev This function could return a number of assets greater than what a `redeem` call would give
    /// in case the strategy faces a loss
    function previewRedeem(address owner, uint256 shares) public view returns (uint256) {
        uint256 ownerTotalShares = balanceOf(owner);
        uint256 ownerReward = _claimableRewardsOf(owner);
        uint256 ownerRewardShares = (ownerReward * shares) / ownerTotalShares;
        return _convertToAssets(shares, MathUpgradeable.Rounding.Down) + ownerRewardShares;
    }

    /// @notice Computes the current amount of locked profit
    /// @return The current amount of locked profit
    function lockedProfit() public view returns (uint256) {
        // Get the last gain and vesting delay.
        uint256 previousGain = lastGain;
        uint256 vestingInterval = vestingPeriod;

        unchecked {
            // If the harvest delay has passed, there is no locked profit.
            // Cannot overflow on human timescales since harvestInterval is capped.
            if (block.timestamp >= previousGain + vestingInterval) return 0;

            // Get the maximum amount we could return.
            uint256 maximumLockedProfit = maxLockedProfit;

            // Compute how much profit remains locked based on the last harvest and harvest delay.
            // It's impossible for the previous harvest to be in the future, so this will never underflow.
            return maximumLockedProfit - (maximumLockedProfit * (block.timestamp - previousGain)) / vestingInterval;
        }
    }

    // ====================== External permissionless functions ====================

    /**
     * @dev Deposit/mint common workflow
     */
    /// @dev can't use the _afterTokenDeposit because we don't have access to 'assets' but only 'shares'
    function _deposit(
        address caller,
        address receiver,
        uint256 assets,
        uint256 shares
    ) internal override {
        // If _asset is ERC777, `transferFrom` can trigger a reenterancy BEFORE the transfer happens through the
        // `tokensToSend` hook. On the other hand, the `tokenReceived` hook, that is triggered after the transfer,
        // calls the savingsRate, which is assumed not malicious.
        //
        // Conclusion: we need to do the transfer before we mint so that any reentrancy would happen before the
        // assets are transfered and before the shares are minted, which is a valid state.
        // slither-disable-next-line reentrancy-no-eth
        SafeERC20Upgradeable.safeTransferFrom(IERC20Upgradeable(asset()), caller, address(this), assets);
        _mint(receiver, shares);

        emit Deposit(caller, receiver, assets, shares);
    }

    /// @inheritdoc ERC4626Upgradeable
    function mint(uint256 shares, address receiver) public virtual override returns (uint256) {
        if (shares > maxMint(receiver)) revert TooHighDeposit();
        

        uint256 assets = previewMint(shares);
        _deposit(_msgSender(), receiver, assets, shares);

        return assets;
    }

    /// @notice To deposit directly rewards onto the contract
    function notifyRewardAmount(uint256 amount) external virtual;

    /// @notice Harvests a set of strategies, recognizing any profits or losses and adjusting
    /// the strategies position.
    /// @param strategiesToHarvest List of strategies to harvest
    function harvest(IStrategy4626[] memory strategiesToHarvest) public {
        // Warning: `totalAssets` could be manipulated by flashloan attacks.
        // It may allow external users to transfer funds into strategy or remove funds
        // from the strategy. Yet, as it does not impact the profit or loss and as attackers
        // have no interest in making such txs to have a direct profit, we let it as is.
        // The only issue is if the strategy is compromised; in this case governance
        // should revoke the strategy
        uint256 managedAssets_ = managedAssets();
        uint256 debtOutstanding;
        for (uint256 i = 0; i < strategiesToHarvest.length; i++) {
            if (strategies[strategiesToHarvest[i]].lastReport == 0) revert InvalidStrategy();
            debtOutstanding = _debtOutstanding(strategiesToHarvest[i], managedAssets_);
            strategiesToHarvest[i].report(debtOutstanding);
        }
        _checkpointPnL(strategiesToHarvest);
        _adjustStrategiesPositions(strategiesToHarvest, managedAssets_);
    }

    /// @notice Updates the profit and loss made on all the strategies
    /// @dev The only possibility to acknowledge a loss is if one of the strategy incurred
    /// a loss and this strategy was harvested by another vault
    function accumulate() external {
        IStrategy4626[] memory activeStrategies = strategyList;
        _checkpointPnL(activeStrategies);
    }

    // =========================== Governance functions ============================

    /// @notice Adds a strategy to the vault
    /// @param strategy Address of the strategy to add
    /// @param _debtRatio Share of the total assets that the strategy has access to
    /// @dev Multiple checks are made in this call: for instance, the contract must not already belong to this savings rate contract
    /// and the underlying token of the strategy has to be consistent with the savings rate contract
    /// @dev This function is a `governor` function and not a `guardian` one because a `guardian` could add a strategy
    /// enabling the withdrawal of the funds of the protocol
    /// @dev The `_debtRatio` should be expressed in `BASE_PARAMS`
    function addStrategy(IStrategy4626 strategy, uint256 _debtRatio) external onlyGovernor {
        StrategyParams storage params = strategies[strategy];
        IERC20 asset = IERC20(asset());
        if (params.lastReport != 0 || !strategy.isVault() || address(asset) != strategy.asset())
            revert InvalidStrategy();
        // Add strategy to approved strategies
        params.lastReport = block.timestamp;
        params.totalStrategyDebt = 0;
        params.debtRatio = _debtRatio;

        // Update global parameters
        debtRatio += _debtRatio;
        emit StrategyAdded(address(strategy), debtRatio);
        emit UpdatedDebtRatio(address(strategy), debtRatio);
        strategyList.push(strategy);
        asset.safeApprove(address(strategy), type(uint256).max);
    }

    /// @notice Modifies the funds a strategy has access to
    /// @param strategy The address of the Strategy
    /// @param _debtRatio The share of the total assets that the strategy has access to
    /// @dev The update has to be such that the `debtRatio` does not exceeds the 100% threshold
    /// as this `vault` cannot lend collateral that it doesn't not own
    function updateStrategyDebtRatio(IStrategy4626 strategy, uint256 _debtRatio) external onlyGovernorOrGuardian {
        StrategyParams storage params = strategies[strategy];
        if (params.lastReport == 0) revert InvalidStrategy();
        debtRatio = debtRatio + _debtRatio - params.debtRatio;
        if (debtRatio > BASE_PARAMS) revert DebtRatioTooHigh();
        params.debtRatio = _debtRatio;
        emit UpdatedDebtRatio(address(strategy), debtRatio);
    }

    /// @notice Revokes a strategy
    /// @param strategy The address of the strategy to revoke
    /// @dev This should only be called after the following happened in order: the `strategy.debtRatio` has been set to 0,
    /// `harvest` has been called enough times to recover all capital gain/losses.
    function revokeStrategy(IStrategy4626 strategy) external onlyGovernorOrGuardian {
        StrategyParams storage params = strategies[strategy];
        if (params.lastReport == 0) revert InvalidStrategy();
        if (params.debtRatio != 0 || params.totalStrategyDebt != 0) revert StrategyInUse();
        uint256 strategyListLength = strategyList.length;
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
        IERC20(asset()).safeApprove(address(strategy), 0);
    }

    /// @notice Setter for parameters encoded as uint64
    /// @param param Value for the parameter
    /// @param what Parameter to change
    /// @dev This function performs the required checks when updating a parameter
    function setUint64(uint64 param, bytes32 what) external onlyGovernorOrGuardian {
        if (what == "VP") {
            if (param == 0 || param > 365 days) revert InvalidParameter();
            vestingPeriod = param;
        } else {
            if (param > BASE_PARAMS) revert InvalidParameter();
            if (what == "PF") protocolFee = param;
            else if (what == "WL") maxWithdrawalLoss = param;
            else if (what == "DF") depositFee = param;
            else if (what == "WF") withdrawFee = param;
            else revert InvalidParameterType();
        }
        emit FiledUint64(param, what);
    }

    /// @notice Sets a new withdrawal stack
    /// @param newStack The new withdrawal stack
    /// @dev If any strategy is not recognized by the `vault` the tx will revert.
    function setWithdrawalStack(IStrategy4626[] calldata newStack) external onlyGovernorOrGuardian {
        // Ensure the new stack is not larger than the maximum stack size.
        if (newStack.length > MAX_WITHDRAWAL_STACK_SIZE) revert WithdrawalStackTooDeep();
        for (uint256 i = 0; i < newStack.length; i++) {
            if (strategies[newStack[i]].lastReport > 0) revert InvalidStrategy();
        }
        // Replace the withdrawal stack.
        withdrawalStack = newStack;
        emit WithdrawalStackSet(msg.sender, newStack);
    }

    /// @notice Sets the `surplusManager` address
    function setSurplusManager(address _surplusManager) external onlyGovernorOrGuardian {
        if (_surplusManager == address(0)) revert ZeroAddress();
        surplusManager = _surplusManager;
        emit SurplusManagerUpdated(_surplusManager);
    }

    /// @notice Changes allowance of a set of tokens to addresses
    /// @param tokens Tokens to change allowance for
    /// @param spenders Addresses to approve
    /// @param amounts Approval amounts for each address
    /// @dev You can only change allowance for a strategy
    function changeAllowance(
        IERC20[] calldata tokens,
        address[] calldata spenders,
        uint256[] calldata amounts
    ) external onlyGovernorOrGuardian {
        if (tokens.length != amounts.length || spenders.length != amounts.length || tokens.length == 0)
            revert IncompatibleLengths();
        for (uint256 i = 0; i < spenders.length; i++) {
            if (strategies[IStrategy4626(spenders[i])].lastReport == 0) revert InvalidStrategy();
            _changeAllowance(tokens[i], spenders[i], amounts[i]);
        }
    }

    /// @notice Allows to recover any ERC20 token, except the asset controlled by the strategy
    /// @param tokenAddress Address of the token to recover
    /// @param to Address of the contract to send collateral to
    /// @param amountToRecover Amount of collateral to transfer
    function recoverERC20(
        address tokenAddress,
        address to,
        uint256 amountToRecover
    ) external onlyGovernor {
        // Cannot recover stablecoin if badDebt or tap into the surplus buffer
        if (tokenAddress == asset()) revert InvalidToken();
        IERC20(tokenAddress).safeTransfer(to, amountToRecover);
        emit Recovered(tokenAddress, to, amountToRecover);
    }

    // ========================== Internal functions ===============================

    /// @notice Tells a strategy how much it owes to this contract
    /// @param strategy Strategy to consider in the call
    /// @param _managedAssets Amount of `asset` controlled by the savings rate contract
    /// @return Amount of token a strategy owes to this contract based on its debt ratio and the total assets managed
    function _debtOutstanding(IStrategy4626 strategy, uint256 _managedAssets) internal view returns (uint256) {
        if (_managedAssets == 0) _managedAssets = managedAssets();
        StrategyParams storage params = strategies[strategy];
        uint256 target = (_managedAssets * params.debtRatio) / BASE_PARAMS;
        if (target > params.totalStrategyDebt) return 0;
        return (params.totalStrategyDebt - target);
    }

    /// @notice Reports the gains or loss made by a strategy
    /// @param strategiesToAdjust List of strategies to adjust their positions
    /// @param managedAssets_ Total `asset` amount controlled by the contract
    /// @dev This is the main contact point where this contract interacts with the strategies: it can either invest
    /// or divest from a strategy
    function _adjustStrategiesPositions(IStrategy4626[] memory strategiesToAdjust, uint256 managedAssets_) internal {
        uint256 positiveChangedDebt;
        uint256 negativeChangedDebt;

        for (uint256 i = 0; i < strategiesToAdjust.length; i++) {
            StrategyParams storage params = strategies[strategiesToAdjust[i]];
            uint256 target = (managedAssets_ * params.debtRatio) / BASE_PARAMS;
            if (target > params.totalStrategyDebt) {
                // If the strategy has some credit left, tokens can be transferred to this strategy
                uint256 available = Math.min(target - params.totalStrategyDebt, getBalance());
                if (available > 0) {
                    params.totalStrategyDebt = params.totalStrategyDebt + available;
                    positiveChangedDebt += available;
                    strategiesToAdjust[i].deposit(available, address(this));
                }
            } else {
                uint256 available = Math.min(
                    params.totalStrategyDebt - target,
                    IERC20(asset()).balanceOf(address(strategiesToAdjust[i]))
                );
                if (available > 0) {
                    params.totalStrategyDebt = params.totalStrategyDebt - available;
                    negativeChangedDebt += available;
                    strategiesToAdjust[i].withdraw(available, address(this), address(this));
                }
            }
        }
        totalDebt = totalDebt + positiveChangedDebt - negativeChangedDebt;
    }

    /// @notice Accumulates profit/loss from strategies and distributes it to the vault's stakeholders
    /// @param activeStrategies Strategy list to consider
    /// @dev It accrues totalProfitLossAccrued, by looking at the difference between what can be
    /// withdrawn from the strategy and the last checkpoint on the strategy debt
    /// @dev Profits are linearly vested while losses are directly slashed from the vault's capital
    function _checkpointPnL(IStrategy4626[] memory activeStrategies) internal {
        // First looking at the profit or loss from the strategies
        int256 totalProfitLossAccrued;
        for (uint256 i = 0; i < activeStrategies.length; i++) {
            // Get the strategy at the current index.
            IStrategy4626 strategy = activeStrategies[i];
            StrategyParams storage params = strategies[strategy];
            uint256 debtLastCheckpoint = params.totalStrategyDebt;
            uint256 balanceThisHarvest = strategy.maxWithdraw(address(this));

            params.lastReport = block.timestamp;
            // Update the strategy's stored balance. Cast overflow is unrealistic.
            params.totalStrategyDebt = balanceThisHarvest;

            // Update the total profit/loss accrued since last harvest.
            // To overflow this would ask enormous debt amounts which are in base of asset
            totalProfitLossAccrued += int256(balanceThisHarvest) - int256(debtLastCheckpoint);
        }
        // Then distributing this profit or loss to users
        if (totalProfitLossAccrued > 0) {
            // Compute fees as the fee percent multiplied by the profit.
            uint256 feesAccrued = uint256(totalProfitLossAccrued).mulDiv(
                uint256(protocolFee),
                1e9,
                MathUpgradeable.Rounding.Up
            );
            _handleProtocolGain(feesAccrued);
            _handleUserGain(uint256(totalProfitLossAccrued) - feesAccrued);
        } else {
            uint256 feesDebt = uint256(-totalProfitLossAccrued).mulDiv(
                uint256(protocolFee),
                1e9,
                MathUpgradeable.Rounding.Down
            );
            _handleProtocolLoss(feesDebt);
            _handleUserLoss(uint256(-totalProfitLossAccrued) - feesDebt);
        }
    }

    /// @notice Propagates a protocol gain by minting yield bearing tokens to the address in charge of the surplus
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

    /// @notice Propagates a protocol loss
    /// @param loss Loss to propagate
    /// @dev This functions burns the yield bearing tokens owned by the governance if it is not enough to support
    /// the bad debt
    function _handleProtocolLoss(uint256 loss) internal {
        address surplusOwner = surplusManager;
        uint256 surplusOwnerSharesBalance = balanceOf(surplusOwner);
        uint256 claimableProtocolRewards = _convertToAssets(surplusOwnerSharesBalance, MathUpgradeable.Rounding.Down);
        if (claimableProtocolRewards > loss) {
            _burn(surplusOwner, _convertToShares(loss, MathUpgradeable.Rounding.Up));
        } else {
            protocolLoss += loss - claimableProtocolRewards;
            _burn(surplusOwner, surplusOwnerSharesBalance);
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
    /// @dev This function is irrelevant if the savings rate contract does not implement boosts for some addresses
    function _claimableRewardsOf(address from) internal view virtual returns (uint256 amount);

    /// @notice If a user needs to withdraw more than what is freely available on the contract
    /// we need to free funds from the strategies in the order given by the withdrawalStack
    /// @param value Amount needed to be withdrawn
    /// @return Actual asset amount that can be withdrawn
    /// @return totalLoss Losses incurred when withdrawing from the strategies
    /// @dev Any loss incurred during the withdrawal will be fully at the expense of the caller
    function _beforeWithdraw(uint256 value) internal returns (uint256, uint256) {
        uint256 vaultBalance = getBalance();
        if (value > vaultBalance) {
            uint256 totalLoss;
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
                // NOTE: Don't withdraw more than the debt so that strategy can still
                //      continue to work based on the profits it has
                // NOTE: This means that user will lose out on any profits that each
                //      Strategy in the queue would return on next harvest, benefiting others
                amountNeeded = Math.min(amountNeeded, params.totalStrategyDebt);
                // Nothing to withdraw from this Strategy, try the next one
                if (amountNeeded == 0) continue;

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
                params.totalStrategyDebt -= (withdrawn + loss);
                newTotalDebt -= (withdrawn + loss);
            }
            // NOTE: This loss protection is put in place to revert if losses from
            // withdrawing are more than what is considered acceptable.
            if (totalLoss > (maxWithdrawalLoss * value) / BASE_PARAMS) revert SlippageProtection();

            totalDebt = newTotalDebt;

            // NOTE: We have withdrawn everything possible out of the withdrawal queue
            //      but we still don't have enough to fully pay them back, so adjust
            //      to the total amount we've freed up through forced withdrawals
            if (value > vaultBalance) {
                value = vaultBalance;
            }
            return (value, totalLoss);
        } else return (vaultBalance, 0);
    }

    /// @notice Changes allowance to an address for a token
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
