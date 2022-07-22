// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.12;

import "./BaseSavingsRate.sol";
import "./SavingsRateStorage.sol";

/// @title Angle Vault
/// @author Angle Protocol
/// @notice Yield aggregator vault which can connect multiple ERC4626 strategies
/// @notice Integrate boosting mecanism on the yield
contract SavingsRateNoBoost is BaseSavingsRate {
    using SafeERC20 for IERC20;
    using Address for address;
    using MathUpgradeable for uint256;

    function initialize(
        ICoreBorrow _coreBorrow,
        IERC20MetadataUpgradeable _token,
        string memory suffixName
    ) external {
        _initialize(_coreBorrow, _token, suffixName);
    }

    // ============================== View functions ===================================

    /// @notice Calculates the total amount of underlying tokens the Vault holds.
    /// @return totalUnderlyingHeld The total amount of underlying tokens the Vault holds.
    /// @dev Need to be cautious on when to use `totalAssets()` and `totalDebt + getBalance()`. As when investing the money
    /// it is better to use the full balance. But we shouldn't count the rewards twice (in the rewards and in the shares)
    function totalAssets() public view override returns (uint256 totalUnderlyingHeld) {
        totalUnderlyingHeld = totalDebt + getBalance() - lockedProfit();
    }

    /// @notice Returns this `vault`'s directly available reserve of collateral (not including what has been lent)
    function managedAssets() public view override returns (uint256) {
        return totalDebt + getBalance();
    }

    // ====================== External permissionless functions =============================

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

    /// @notice To deposit directly rewards onto the contract
    /// @dev You can just transfer the token without calling this function as it will be counted in the `totalAssets` via getBalnce()
    function notifyRewardAmount(uint256 amount) external override {
        SafeERC20Upgradeable.safeTransferFrom(IERC20Upgradeable(asset()), msg.sender, address(this), amount);
        // Update max unlocked profit based on any remaining locked profit plus new profit.
        maxLockedProfit = (lockedProfit() + amount);
    }

    // ===================== Internal functions ==========================

    /// @notice Propagates a user side gain
    /// @param gain Gain to propagate
    function _handleUserGain(uint256 gain) internal override {
        // loss is directly removed from the totalHoldings
        // Update max unlocked profit based on any remaining locked profit plus new profit.
        maxLockedProfit = (lockedProfit() + gain);

        totalDebt += gain;
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
