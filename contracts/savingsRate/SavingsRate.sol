// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.12;

import "./BaseSavingsRate.sol";

/// @title SavingsRateNoBoost
/// @author Angle Core Team
/// @notice Contract for yield aggregator vaults which can connect to multiple ERC4626 strategies
/// @notice In this implementation there's no boost given to owners of the shares of the contract
contract SavingsRate is BaseSavingsRate {
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
    /// @dev This may not be the most up to date representation of a share price as the savings rate
    /// could invest in strategies which experience losses or gains thus decreasing or increasing
    /// the share price
    function sharePrice() external view override returns (uint256) {
        return previewRedeem(10**decimals());
    }

    /// @inheritdoc ERC4626Upgradeable
    /// @dev Lighter implementation for the contract with no boost
    /// @dev Computes a lower bound on shares needed to be burnt to receive `assets`.
    /// The more accurate `maxWithdraw(amount)` is on each strategies, the better the lower bound.
    /// But `maxWithdraw(amount)` can be hard to estimate and will therefore overestimate shares needed
    function previewWithdraw(uint256 assets) public view override returns (uint256) {
        uint256 withdrawableAssets = _estimateWithdrawableAssets(assets);
        // In this case there won't be enough share to withdraw the full amount
        if (assets > withdrawableAssets) return type(uint256).max;

        (uint256 shares, ) = _computeWithdrawalFees(assets);
        return shares;
    }

    /// @inheritdoc ERC4626Upgradeable
    /// @dev Lighter implementation for this contract where no boost is given
    /// @dev Computes a lower bound on assets returned for `shares` burnt.
    /// The more accurate `maxWithdraw(amount)` is on each strategies, the better the lower bound.
    function previewRedeem(uint256 shares) public view override returns (uint256) {
        (uint256 assets, ) = _computeRedemptionFees(shares);

        uint256 withdrawableAssets = _estimateWithdrawableAssets(assets);
        // In this case there won't be enough assets to withdraw the full amount
        // we are bounded by the withdrawable assets
        if (assets > withdrawableAssets) return withdrawableAssets;
        else return assets;
    }

    /// @inheritdoc ERC4626Upgradeable
    function withdraw(
        uint256 assets,
        address receiver,
        address owner
    ) public virtual override whenNotPaused returns (uint256) {
        uint256 loss = _beforeWithdraw(assets);
        // Function should withdraw if we cannot get enough assets
        (uint256 shares, uint256 fees) = _computeWithdrawalFees(assets + loss);
        /// TODO we may want to leave the opportunity for fees to stay in the protocol -> cf Alchemix
        _handleProtocolGain(fees);
        // Function reverts if there is not enough available in the contract like specified in the interface
        _withdraw(_msgSender(), receiver, owner, assets, shares);
        return shares;
    }

    /// @inheritdoc ERC4626Upgradeable
    function redeem(
        uint256 shares,
        address receiver,
        address owner
    ) public virtual override whenNotPaused returns (uint256) {
        (uint256 assets, uint256 fees) = _computeRedemptionFees(shares);
        uint256 loss = _beforeWithdraw(assets);
        _handleProtocolGain(fees);
        // Assets is always greater than loss
        _withdraw(_msgSender(), receiver, owner, assets - loss, shares);
        return assets - loss;
    }

    // ============================ Internal functions =============================

    /// @inheritdoc BaseSavingsRate
    /// @dev This function is useless in settings when there are no boosts
    function _claimableRewardsOf(address) internal pure override returns (uint256) {
        return 0;
    }
}
