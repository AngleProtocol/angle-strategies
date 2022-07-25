// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.12;

import "./BaseSavingsRate.sol";
import "./SavingsRateStorage.sol";

/// @title SavingsRateNoBoost
/// @author Angle Protocol
/// @notice Contract for yield aggregator vaults which can connect to multiple ERC4626 strategies
/// @notice In this implementation there's no boost given to owners of the shares of the contract
contract SavingsRateNoBoost is BaseSavingsRate {
    using SafeERC20 for IERC20;
    using Address for address;
    using MathUpgradeable for uint256;

    /// @notice Initializes the `SavingsRateNoBoost` contract
    function initialize(
        ICoreBorrow _coreBorrow,
        IERC20MetadataUpgradeable _token,
        address _surplusManager,
        string memory suffixName
    ) external {
        _initialize(_coreBorrow, _token, _surplusManager, suffixName);
    }

    // ============================== View functions ===============================

    /// @inheritdoc ERC4626Upgradeable
    function totalAssets() public view override returns (uint256 totalUnderlyingHeld) {
        totalUnderlyingHeld = totalDebt + getBalance() - lockedProfit();
    }

    /// @inheritdoc BaseSavingsRate
    function managedAssets() public view override returns (uint256) {
        return totalDebt + getBalance();
    }

    // ====================== External permissionless functions ====================

    /** @dev See {IERC4262-withdraw} */
    function withdraw(
        uint256 assets,
        address receiver,
        address owner
    ) public virtual override returns (uint256) {
        uint256 loss;
        (assets, loss) = _beforeWithdraw(assets);

        uint256 assetsTrueCost = assets + loss;
        uint256 shares = _convertToShares(assetsTrueCost, MathUpgradeable.Rounding.Up);
        // TODO must revert if cannot withdraw exactly
        if (shares > balanceOf(owner)) revert WithdrawLimit();
        _withdraw(_msgSender(), receiver, owner, assets, shares);

        return shares;
    }

    /** @dev See {IERC4262-redeem} */
    function redeem(
        uint256 shares,
        address receiver,
        address owner
    ) public virtual override returns (uint256) {
        // TODO must revert if cannot withdraw exactly
        require(shares <= balanceOf(owner), "ERC4626: redeem more than max");
        uint256 assets = _convertToAssets(shares, MathUpgradeable.Rounding.Down);
        uint256 loss;
        uint256 freedAssets;
        (freedAssets, loss) = _beforeWithdraw(assets);
        // if we didn't suceed to withdraw enough, we need to decrease the number of shares burnt
        if (freedAssets < assets) {
            shares = _convertToShares(freedAssets, MathUpgradeable.Rounding.Up);
        }

        // `assets-loss` will never revert here because it would revert on the slippage protection in `withdraw()`
        _withdraw(_msgSender(), receiver, owner, freedAssets - loss, shares);

        return freedAssets - loss;
    }

    /// @notice To deposit directly rewards onto the contract and have them given to users
    /// @dev You can just transfer the token without calling this function as it will be counted in the `totalAssets` via getBalnce()
    function notifyRewardAmount(uint256 amount) external override {
        SafeERC20Upgradeable.safeTransferFrom(IERC20Upgradeable(asset()), msg.sender, address(this), amount);
        _handleUserGain(amount);
    }

    // ===================== Internal functions ==========================

    /// @notice Propagates a user side gain
    /// @param gain Gain to propagate
    function _handleUserGain(uint256 gain) internal override {
        maxLockedProfit = (lockedProfit() + gain);
        totalDebt += gain;
        lastGain = uint64(block.timestamp);
    }

    /// @notice Propagates a user side loss
    /// @param loss Loss to propagate
    function _handleUserLoss(uint256 loss) internal override {
        // Decrease newTotalDebt, this impacts the `totalAssets()` call --> loss directly implied when withdrawing
        totalDebt -= loss;
    }

    /// @notice Useless when there is no boost
    function _claimableRewardsOf(address) internal pure override returns (uint256) {
        return 0;
    }
}
