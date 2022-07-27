// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.12;

import "../savingsRate/BaseStrategy4626.sol";

/// @title Angle Strategy ERC4626
/// @author Angle Protocol
contract Strategy4626 is BaseStrategy4626 {
    uint256 public count;

    function estimatedAPR() external view override returns (uint256) {
        return count;
    }

    /// @notice Returns the amount of underlying tokens that idly sit in the Vault.
    /// @return The amount of underlying tokens that sit idly in the Vault.
    function availableBalance() public view returns (uint256) {
        return IERC20(asset()).balanceOf(address(this));
    }

    function _prepareReturn(uint256 _debtOutstanding) internal override returns (uint256 _profit, uint256 _loss) {}

    function _adjustPosition() internal override {}

    function _liquidatePosition(uint256) internal override returns (uint256 _liquidatedAmount, uint256 _loss) {
        count += 1;
        return (0, 0);
    }

    function _liquidateAllPositions() internal override returns (uint256 _amountFreed) {
        count += 1;
        return 0;
    }

    function _protectedTokens() internal view override returns (address[] memory) {
        count;
        address[] memory protected = new address[](0);
        return protected;
    }
}
