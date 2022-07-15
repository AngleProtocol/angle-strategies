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
        IVotingEscrow _votingEscrow,
        IVotingEscrowBoost _veBoostProxy
    ) external {
        _initialize(_coreBorrow, _token);
        votingEscrow = _votingEscrow;
        veBoostProxy = _veBoostProxy;
    }

    // ============================== View functions ===================================

    /// @notice Calculates the total amount of underlying tokens the Vault holds.
    /// @return totalUnderlyingHeld The total amount of underlying tokens the Vault holds.
    /// @dev Need to be cautious on when to use `totalAssets()` and `totalDebt + getBalance()`. As when investing the money
    /// it is better to use the full balance. But we shouldn't count the rewards twice (in the rewards and in the shares)
    function totalAssets() public view override returns (uint256 totalUnderlyingHeld) {
        totalUnderlyingHeld = totalDebt + getBalance() - claimableRewards;
    }

    /// @notice Returns this `vault`'s directly available reserve of collateral (not including what has been lent)
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
    function notifyRewardAmount(uint256 amount) external override {
        SafeERC20Upgradeable.safeTransferFrom(IERC20Upgradeable(asset()), msg.sender, address(this), amount);
        claimableRewards += amount;
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

    /// @notice Sets a new fee percentage.
    /// @param tokenlessProduction_ The new tokenlessProduction, which efectively set the boost in `_updateLiquidityLimit`
    /// TODO not as easy --> we need to update everyones boost, if we lower the max boost then nobody is going to call it
    function setTokenlessProduction(uint256 tokenlessProduction_) external onlyGovernor {
        // A fee percentage over 100% doesn't make sense.
        if (tokenlessProduction_ >= BASE_PARAMS) revert ProtocolFeeTooHigh();
        // Update the fee percentage.
        tokenlessProduction = tokenlessProduction_;

        emit TokenlessProductionUpdated(msg.sender, tokenlessProduction_);
    }

    // ===================== Internal functions ==========================

    /// @notice Propagates a user side gain
    /// @param gain Gain to propagate
    function _handleUserGain(uint256 gain) internal override {
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
    function _claim(address from) internal override returns (uint256) {
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
        if (from != address(0)) _updateLiquidityLimit(from, balanceOf(from), totalSupply_);
        if (to != address(0)) _updateLiquidityLimit(to, balanceOf(to), totalSupply_);
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
}
