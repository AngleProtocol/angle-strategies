// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.12;

import "../vault/BaseStrategy4626.sol";

/// @title Angle Strategy ERC4626
/// @author Angle Protocol
contract Strategy4626 is BaseStrategy4626 {
    function estimatedAPR() external view returns (uint256) {
        return 0;
    }

    function poolManager() external view returns (address) {
        return address(0);
    }

    /// @notice Calculates the total amount of underlying tokens the Vault holds.
    /// @return totalUnderlyingHeld The total amount of underlying tokens the Vault holds.
    /// @dev Important to not take into account lockedProfit otherwise there could be attacks on
    /// the vault. Someone could artificially make a strategy have large profit, to deposit and withdraw
    /// and earn free money.
    /// @dev Need to be cautious on when to use `totalAssets()` and totalDebt. As when investing the money
    /// it is better to use the full balance. But need to make sure that there isn't any flaws by using 2 dufferent balances
    function totalAssets() public view override returns (uint256 totalUnderlyingHeld) {
        // for a non mock contract, where the funds are invested we would look at the current
        // used capital + float instead
        totalUnderlyingHeld = availableBalance() - lockedProfit();
    }

    /// @notice Returns the amount of underlying tokens that idly sit in the Vault.
    /// @return The amount of underlying tokens that sit idly in the Vault.
    function availableBalance() public view returns (uint256) {
        return asset.balanceOf(address(this));
    }

    /// @notice Calculates the current amount of locked profit.
    /// @return The current amount of locked profit.
    function lockedProfit() public view returns (uint256) {
        // Get the last harvest and harvest delay.
        uint256 previousHarvest = lastHarvest;
        uint256 harvestInterval = harvestDelay;

        unchecked {
            // If the harvest delay has passed, there is no locked profit.
            // Cannot overflow on human timescales since harvestInterval is capped.
            if (block.timestamp >= previousHarvest + harvestInterval) return 0;

            // Get the maximum amount we could return.
            uint256 maximumLockedProfit = maxLockedProfit;

            // Compute how much profit remains locked based on the last harvest and harvest delay.
            // It's impossible for the previous harvest to be in the future, so this will never underflow.
            return maximumLockedProfit - (maximumLockedProfit * (block.timestamp - previousHarvest)) / harvestInterval;
        }
    }
}
