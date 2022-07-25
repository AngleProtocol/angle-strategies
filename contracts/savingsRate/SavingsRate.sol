// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.12;

import "./BaseSavingsRate.sol";
import "./SavingsRateStorage.sol";

/// @title Angle Vault
/// @author Angle Protocol
/// @notice Yield aggregator vault which can connect multiple ERC4626 strategies
/// @notice Integrate boosting mecanism on the yield
contract SavingsRate is BaseSavingsRate, SavingsRateStorage {
    using SafeERC20 for IERC20;
    using Address for address;
    using MathUpgradeable for uint256;

    function initialize(
        ICoreBorrow _coreBorrow,
        IERC20MetadataUpgradeable _token,
        address _surplusManager,
        string memory suffixName,
        IVotingEscrow _votingEscrow,
        IVotingEscrowBoost _veBoostProxy,
        uint256 tokenlessProduction_
    ) external {
        _initialize(_coreBorrow, _token, _surplusManager, suffixName);
        votingEscrow = _votingEscrow;
        veBoostProxy = _veBoostProxy;
        tokenlessProduction = tokenlessProduction_;
    }

    // ============================== View functions ===================================

    /// @inheritdoc ERC4626Upgradeable
    function totalAssets() public view override returns (uint256 totalUnderlyingHeld) {
        totalUnderlyingHeld = totalDebt + getBalance() - claimableRewards;
    }

    /// @inheritdoc BaseSavingsRate
    function managedAssets() public view override returns (uint256) {
        return totalAssets() + claimableRewards;
    }

    // ====================== External permissionless functions =============================

    /** @dev See {IERC4262-withdraw} */
    function withdraw(
        uint256 assets,
        address receiver,
        address owner
    ) public virtual override returns (uint256) {
        // TODO revert when needed
        uint256 ownerReward = _claim(owner);
        uint256 loss;
        (assets, loss) = _beforeWithdraw(assets);

        uint256 shares;
        uint256 assetsTrueCost = assets + loss;
        if (ownerReward < assetsTrueCost) {
            shares = _convertToShares(assetsTrueCost - ownerReward, MathUpgradeable.Rounding.Up);
            if (shares > balanceOf(owner)) revert WithdrawLimit();
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
        // TODO revert when needed
        uint256 ownerTotalShares = balanceOf(owner);
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

        uint256 votingTotal = IERC20(address(votingEscrow)).totalSupply();
        _updateLiquidityLimit(msg.sender, balanceOf(msg.sender), totalSupply(), votingTotal);
    }

    /// @notice Helper to estimate claimble rewards for a specific user
    /// @param from Address to estimate rewards from
    /// @return amount `from` reward balance if it gets updated
    function claimableRewardsOf(address from) external view returns (uint256) {
        return _claimableRewardsOf(from);
    }

    /// @notice To deposit directly rewards onto the contract
    function notifyRewardAmount(uint256 amount) external override {
        SafeERC20Upgradeable.safeTransferFrom(IERC20Upgradeable(asset()), msg.sender, address(this), amount);
        _handleUserGain(amount);
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
        uint256 votingTotal = IERC20(address(votingEscrow)).totalSupply();
        _claim(addr);
        _updateLiquidityLimit(addr, balanceOf(addr), totalSupply, votingTotal);
    }

    // ============================== Governance functions ===================================

    /// @notice Sets a new fee percentage.
    /// @param tokenlessProduction_ The new tokenlessProduction, which efectively set the boost in `_updateLiquidityLimit`
    /// @dev Not as easy --> we need to update everyones boost, if we lower the max boost then nobody is going to call it
    /// Therefore after the tx passed for all users governance should call `governanceKick`
    function setTokenlessProduction(uint256 tokenlessProduction_) external onlyGovernor {
        // A fee percentage over 100% doesn't make sense.
        if (tokenlessProduction_ >= BASE_PARAMS) revert InvalidParameter();
        // Update the fee percentage.
        tokenlessProduction = tokenlessProduction_;

        emit TokenlessProductionUpdated(msg.sender, tokenlessProduction_);
    }

    /// @notice Update working balances when there is an update on the tokenless production parameters
    /// @param addrs List of address to update balances of
    /// @dev Governance should make sure to call it on all owners
    function governanceKick(address[] memory addrs) external onlyGovernor {
        uint256 totalSupply = totalSupply();
        uint256 votingTotal = IERC20(address(votingEscrow)).totalSupply();

        for (uint256 i = 0; i < addrs.length; i++) {
            _claim(addrs[i]);
            _updateLiquidityLimit(addrs[i], balanceOf(addrs[i]), totalSupply, votingTotal);
        }
    }

    // ===================== Internal functions ==========================

    /// @notice Propagates a user side gain
    /// @param gain Gain to propagate
    function _handleUserGain(uint256 gain) internal override {
        // loss is directly removed from the totalHoldings
        // Update max unlocked profit based on any remaining locked profit plus new profit.
        maxLockedProfit = (lockedProfit() + gain);
        claimableRewards += gain;
    }

    /// @notice Propagates a user side loss
    /// @param loss Loss to propagate
    function _handleUserLoss(uint256 loss) internal override {
        // Decrease newTotalDebt, this impacts the `totalAssets()` call --> loss directly implied when withdrawing
        totalDebt -= loss;
    }

    /// @notice Claims earned rewards
    /// @param from Address to claim for
    /// @return Transferred amount to `from`
    function _claim(address from) internal returns (uint256) {
        uint256 globalRewardsAccumulator = rewardsAccumulator + (block.timestamp - lastTime) * workingSupply;
        rewardsAccumulator = globalRewardsAccumulator;
        lastTime = block.timestamp;
        // This will be 0 on the first deposit since the balance is initialized later
        uint256 userRewardsAccumulator = (block.timestamp - lastTimeOf[from]) * workingBalances[from];
        lastTimeOf[from] = block.timestamp;
        uint256 unlockedProfit = claimableRewards - lockedProfit();
        uint256 amount = (unlockedProfit * userRewardsAccumulator) /
            (globalRewardsAccumulator - claimedRewardsAccumulator);
        claimedRewardsAccumulator += userRewardsAccumulator;
        claimableRewards -= amount;
        uint256 currentRewardBalance = rewardBalances[from];
        rewardBalances[from] = currentRewardBalance + amount;
        return currentRewardBalance + amount;
    }

    /// @notice Helper to estimate claimable rewards for a specific user
    /// @param from Address to check rewards from
    /// @return amount `from` reward balance if it gets updated
    function _claimableRewardsOf(address from) internal view override returns (uint256 amount) {
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
        uint256 votingTotal = IERC20(address(votingEscrow)).totalSupply();
        if (from != address(0)) _updateLiquidityLimit(from, balanceOf(from), totalSupply_, votingTotal);
        if (to != address(0)) _updateLiquidityLimit(to, balanceOf(to), totalSupply_, votingTotal);
    }

    /// @notice Calculate limits which depend on the amount of veANGLE token per-user.
    /// Effectively it computes a modified balance and total supply, to redirect rewards
    /// not only based on liquidity but also external factors
    /// @param addr User address
    /// @param userShares User's vault shares
    /// @param totalShares Total vault shares
    /// @param votingTotal Total supply of ve tokens
    /// @dev To be called after totalSupply is updated
    /// @dev We can add any other metric that seems suitable to adapt working balances
    /// Here we only take into account the veANGLE balances, but we can also add a parameter on
    /// locking period --> but this would break the ERC4626 interfaces --> NFT
    function _updateLiquidityLimit(
        address addr,
        uint256 userShares,
        uint256 totalShares,
        uint256 votingTotal
    ) internal {
        uint256 votingBalance = veBoostProxy.adjusted_balance_of(addr);

        uint256 lim = (userShares * tokenlessProduction) / 100;
        if (votingTotal > 0) lim += (((totalShares * votingBalance) / votingTotal) * (100 - tokenlessProduction)) / 100;

        lim = Math.min(userShares, lim);
        uint256 oldBal = workingBalances[addr];
        workingBalances[addr] = lim;
        uint256 _workingSupply = workingSupply + lim - oldBal;
        workingSupply = _workingSupply;
    }
}
