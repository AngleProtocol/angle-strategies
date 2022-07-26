// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.12;

import "./BaseSavingsRate.sol";
import "./SavingsRateStorage.sol";

/// @title SavingsRate
/// @author Angle Protocol
/// @notice Contract for yield aggregator vaults which can connect to multiple ERC4626 strategies
/// @notice In this implementation, share price is not the same for all depositors as some may bet a boost
/// on their rewards while others do not
contract SavingsRate is BaseSavingsRate, SavingsRateStorage {
    using SafeERC20 for IERC20;
    using Address for address;
    using MathUpgradeable for uint256;

    /// @notice Initializes the SavingsRate contract
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
        totalUnderlyingHeld = managedAssets() - vestingProfit;
    }

    /// @inheritdoc BaseSavingsRate
    function sharePrice() external view override returns (uint256) {
        return previewRedeem(decimals());
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
    /// @dev This function is specific for implementations of savings rate contracts where a boost is given to
    /// some addresses and not all users are equivalent
    function previewWithdraw(address owner, uint256 assets) public view returns (uint256 shares) {
        uint256 ownerReward = _claimableRewardsOf(owner);
        // Function will revert if we cannot get enough assets
        (, uint256 fees) = _computeWithdrawalFees(assets);
        uint256 assetsTrueCost = assets + fees;
        if (ownerReward < assetsTrueCost) {
            shares = _convertToShares(assetsTrueCost - ownerReward, MathUpgradeable.Rounding.Up);
        }
    }

    /// @notice Implementation of the `previewRedeem` function for a specific `owner`
    /// @dev This function could return a number of assets greater than what a `redeem` call would give
    /// in case the strategy faces a loss
    function previewRedeem(address owner, uint256 shares) public view returns (uint256) {
        uint256 ownerReward = _claimableRewardsOf(owner);
        uint256 ownerShares = balanceOf(owner);
        if (ownerReward == 0 || ownerShares == 0) {
            (uint256 assets, ) = _computeRedemptionFees(shares);
            return assets;
        } else {
            uint256 ownerRewardShares = (ownerReward * shares) / ownerShares;
            uint256 assetsPlusFees = _convertToAssets(shares, MathUpgradeable.Rounding.Down) + ownerRewardShares;
            return assetsPlusFees - assetsPlusFees.mulDiv(withdrawFee, BASE_PARAMS, MathUpgradeable.Rounding.Up);
        }
    }

    // ====================== External permissionless functions =============================

    /// @inheritdoc ERC4626Upgradeable
    function withdraw(
        uint256 assets,
        address receiver,
        address owner
    ) public virtual override returns (uint256) {
        uint256 ownerReward = _checkpointRewards(owner);
        (, uint256 loss) = _beforeWithdraw(assets);
        // Function will revert if we cannot get enough assets
        (, uint256 fees) = _computeWithdrawalFees(assets + loss);
        uint256 assetsTrueCost = assets + loss + fees;
        uint256 shares;
        if (ownerReward < assetsTrueCost) {
            shares = _convertToShares(assetsTrueCost - ownerReward, MathUpgradeable.Rounding.Up);
            delete rewardBalances[owner];
        } else {
            rewardBalances[owner] -= assets;
        }
        _handleProtocolGain(fees);
        // Function reverts if there is not enough available in the contract
        _withdraw(_msgSender(), receiver, owner, assets, shares);
        // `vestingProfit` needs to be updated after `handleProtocolGain` otherwise too many shares would be minted
        if (ownerReward < assetsTrueCost) {
            vestingProfit -= ownerReward;
        } else {
            vestingProfit -= assets;
        }
        return shares;
    }

    /// @inheritdoc ERC4626Upgradeable
    function redeem(
        uint256 shares,
        address receiver,
        address owner
    ) public virtual override returns (uint256) {
        // The owner accumulated 5 of assets in rewards
        uint256 ownerReward = _checkpointRewards(owner);
        // It has in total 100 shares
        uint256 ownerShares = balanceOf(owner);
        // In assets this means that if the owner wants the redeem 10 shares (that is to say 10% of its shares), we'll fetch
        // 10% of its earned assets
        uint256 ownerRewardShares = (ownerReward * shares) / ownerShares;
        // Total amount claimable from 10 shares is then assuming that we had 100 shares and 100 of assets in the beginning
        // 10.5
        uint256 assetsPlusFees = _convertToAssets(shares, MathUpgradeable.Rounding.Down) + ownerRewardShares;
        // In fact the owner will get less from that since fees are taken
        uint256 fees =  assetsPlusFees.mulDiv(withdrawFee, BASE_PARAMS, MathUpgradeable.Rounding.Up);
        // This is the real amount of assets that will need to be obtained
        uint256 assets = assetsPlusFees - fees;
        // But now: we need to make this available
        (, uint256 loss) = _beforeWithdraw(assets);
        // Once we're good on that we can do our accounting:
        rewardBalances[owner] -= ownerRewardShares;
        // Loss is at the expense of the user
        _withdraw(_msgSender(), receiver, owner, assets - loss, shares);
        vestingProfit -= ownerRewardShares;
        return assets - loss;
    }

    /// @notice Checkpoints earned rewards and update working balances
    /// @return rewardBalance `msg.sender` reward balance at the end of the function
    function checkpoint() external returns (uint256) {
        return _checkpoint();
    }

    /// @notice Internal version of the checkpoint function
    function _checkpoint() internal returns (uint256 rewardBalance) {
        rewardBalance = _checkpointRewards(msg.sender);
        uint256 votingTotal = IERC20(address(votingEscrow)).totalSupply();
        _updateLiquidityLimit(msg.sender, balanceOf(msg.sender), totalSupply(), votingTotal);

    }

    /// @notice Claims rewards and mints corresponding shares
    function checkpointAndRebalance() external returns(uint256 shares) {
        uint256 rewardBalance = _checkpoint();
        shares = _convertToShares(rewardBalance, MathUpgradeable.Rounding.Down);
        _mint(msg.sender, shares);
        delete rewardBalances[msg.sender];
        vestingProfit -= rewardBalance;
    }

    /// @notice Helper to estimate claimble rewards for a specific user
    /// @param from Address to estimate rewards from
    /// @return amount `from` reward balance if it gets updated
    function claimableRewardsOf(address from) external view returns (uint256) {
        return _claimableRewardsOf(from);
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
        _checkpointRewards(addr);
        _updateLiquidityLimit(addr, balanceOf(addr), totalSupply, votingTotal);
    }

    // ============================== Governance functions ===================================

    /// @notice Sets a new `tokenLessProduction` parameter that dictates the boost for veANGLE holders
    /// @param _tokenlessProduction New `tokenlessProduction` parameter
    /// @dev Not as easy --> we need to update everyones boost, if we lower the max boost then nobody is going to call it
    /// Therefore after the tx passed for all users governance should call `governanceKick`
    function setTokenlessProduction(uint256 _tokenlessProduction) external onlyGovernor {
        // This parameter cannot be over 100%
        if (_tokenlessProduction >= BASE_PARAMS) revert InvalidParameter();
        tokenlessProduction = _tokenlessProduction;

        emit TokenlessProductionUpdated(msg.sender, _tokenlessProduction);
    }

    /// @notice Update working balances when there is an update on the tokenless production parameters
    /// @param addrs List of address to update balances of
    /// @dev Governance should make sure to call it on all owners
    function governanceKick(address[] memory addrs) external onlyGovernor {
        uint256 totalSupply = totalSupply();
        uint256 votingTotal = IERC20(address(votingEscrow)).totalSupply();

        for (uint256 i = 0; i < addrs.length; i++) {
            _checkpointRewards(addrs[i]);
            _updateLiquidityLimit(addrs[i], balanceOf(addrs[i]), totalSupply, votingTotal);
        }
    }

    // =========================== Internal functions ==============================

    /// @notice Claims earned rewards
    /// @param from Address to claim for
    /// @return currentRewardBalance Amount of rewards that can now be claimed by the
    function _checkpointRewards(address from) internal returns (uint256 currentRewardBalance) {
        currentRewardBalance = rewardBalances[from];
        if (from != address(0)) {
            uint256 totalSupply = workingSupply;
            uint256 userBalance = workingBalances[from];
            uint256 _integral = integral;
            uint256 _lastUpdate = Math.min(block.timestamp, periodFinish);
            uint256 duration = _lastUpdate - lastUpdate;

            if (duration != 0) {
                lastUpdate = uint64(_lastUpdate);
                if (totalSupply != 0) {
                    _integral += (duration * rewardRate * 10**18) / totalSupply;
                    integral = _integral;
                }
            }
            uint256 userIntegralFor = integralFor[from];
            if (userIntegralFor < _integral) {
                integralFor[from] = _integral;
                currentRewardBalance += (userBalance * (_integral - userIntegralFor)) / 10**18;
                rewardBalances[from] = currentRewardBalance;
            }
            lastTimeOf[from] = block.timestamp;
        }
    }

    /// @notice Propagates a user side gain
    /// @param gain Gain to propagate
    function _handleUserGain(uint256 gain) internal override {
        uint256 _periodFinish = periodFinish;
        uint64 _vestingPeriod = vestingPeriod;
        if (block.timestamp >= _periodFinish) {
            rewardRate = gain / _vestingPeriod;
        } else {
            uint256 remaining = _periodFinish - block.timestamp;
            uint256 leftover = remaining * rewardRate;
            rewardRate = (gain + leftover) / _vestingPeriod;
        }
        lastUpdate = uint64(block.timestamp);
        periodFinish = uint64(block.timestamp) + _vestingPeriod;
        vestingProfit += gain;
    }

    // No need for specific user handling in case of a loss: share price is decreasing for everyone

    /// @notice Helper to estimate claimable rewards for a specific user
    /// @param from Address to check rewards from
    /// @return amount `from` reward balance if it gets updated
    function _claimableRewardsOf(address from) internal view override returns (uint256) {
        uint256 totalSupply = workingSupply;
        uint256 userBalance = workingBalances[from];
        uint256 _integral = integral;
        if (totalSupply != 0) {
            uint256 _lastUpdate = Math.min(block.timestamp, periodFinish);
            uint256 duration = _lastUpdate - lastUpdate;
            _integral += (duration * rewardRate * 10**18) / totalSupply;
        }
        uint256 userIntegralFor = integralFor[from];
        return (userBalance * (_integral - userIntegralFor)) / 10**18 + rewardBalances[from];
    }

    /// @inheritdoc ERC20Upgradeable
    /// @dev In case of normal transfers, you are also transferring a portion of your rewards equivalent to the portion
    /// of your shares balance
    function _beforeTokenTransfer(
        address from,
        address to,
        uint256 amount
    ) internal override {
        _checkpointRewards(to);
        uint256 fromRewardBalance = _checkpointRewards(from);
        if (from != address(0) && to != address(0)) {
            uint256 proportion = (amount * fromRewardBalance) / balanceOf(from);
            rewardBalances[from] -= proportion;
            rewardBalances[to] += proportion;
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
