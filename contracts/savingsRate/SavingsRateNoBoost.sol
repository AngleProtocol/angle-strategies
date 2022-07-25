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

    /// @inheritdoc BaseSavingsRate
    function notifyRewardAmount(uint256 amount) external override {
        SafeERC20Upgradeable.safeTransferFrom(IERC20Upgradeable(asset()), msg.sender, address(this), amount);
        _handleUserGain(amount);
    }

    // ============================ Internal functions =============================
    
    /// @inheritdoc BaseSavingsRate
    /// @dev This function is useless in settings when there are no boosts
    function _claimableRewardsOf(address) internal pure override returns (uint256) {
        return 0;
    }
}
