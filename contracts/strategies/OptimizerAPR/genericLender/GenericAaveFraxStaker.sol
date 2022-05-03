// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.12;

import "../../../interfaces/external/frax/IFraxUnifiedFarmTemplate.sol";
import "./GenericAaveUpgradeable.sol";

/// @title GenericAaveFraxStaker
/// @author  Angle Core Team
/// @notice Allow to stake aFRAX on FRAX contracts to earn their incentives
contract GenericAaveFraxStaker is GenericAaveUpgradeable {
    using SafeERC20 for IERC20;
    using Address for address;

    // // ========================== Aave Protocol Addresses ==========================

    IFraxUnifiedFarmTemplate private constant aFraxStakingContract =
        IFraxUnifiedFarmTemplate(0x02577b426F223A6B4f2351315A19ecD6F357d65c);

    // ==================== Parameters =============================

    // hash representing the position on Frax staker
    bytes32 kekId;
    // used to track the current liquidity (staked + interests)
    uint256 lastAaveLiquidityIndex;
    // Last liquidity recorded on Frax staking contract
    uint256 lastLiquidity;
    // Minimum staking period
    uint256 minStakingPeriod = 86400; // a day
    uint256 stakingPeriod;
    uint256 lastCreatedStake;

    error NoLockedLiquidity();
    error TooSmallStakingPeriod();
    error UnstakedTooSoon();

    // ============================= Constructor =============================

    /// @notice Initializer of the `GenericAave`
    /// @param _strategy Reference to the strategy using this lender
    /// @param governorList List of addresses with governor privilege
    /// @param keeperList List of addresses with keeper privilege
    /// @param guardian Address of the guardian
    function initialize(
        address _strategy,
        string memory name,
        bool _isIncentivised,
        address[] memory governorList,
        address guardian,
        address[] memory keeperList,
        uint256 _stakingPeriod
    ) external {
        initializeBase(_strategy, name, _isIncentivised, governorList, guardian, keeperList);
        if (_stakingPeriod < minStakingPeriod) revert TooSmallStakingPeriod();
        IERC20(address(_aToken)).safeApprove(address(aFraxStakingContract), type(uint256).max);
    }

    // ========================= Virtual Functions ===========================

    /// @notice Allow the lender to stake its aTokens in the external staking contract
    /// @param amount Amount of aToken wanted to be stake
    /// @dev If there is an existent locker already on Frax staking contract (keckId != null) --> then add to it
    /// otherwise (first time w deposit or last action was a withdraw) we need to create a new locker
    /// @dev Currently there is no additional reward to stake more than the minimum period as there is no multiplier
    function _stake(uint256 amount) internal override returns (uint256 stakedAmount) {
        uint256 liquidityIndex = _lendingPool.getReserveData(address(want)).liquidityIndex;

        if (kekId == bytes32(0)) {
            kekId = aFraxStakingContract.stakeLocked(amount, stakingPeriod);
            lastLiquidity = amount;
            lastCreatedStake = block.timestamp;
        } else {
            aFraxStakingContract.lockAdditional(kekId, amount);
            lastLiquidity = (lastLiquidity * liquidityIndex) / lastAaveLiquidityIndex + amount;
        }
        lastAaveLiquidityIndex = liquidityIndex;
        stakedAmount = amount;
    }

    /// @notice Allow the lender to unstake its aTokens from the external staking contract
    /// @param amount Amount of aToken wanted to be unstake
    /// @dev If minimum staking period is not finished the function will revert / we can also
    /// want to continue the process by just returning availableAmount=0 instead
    /// In case of loss we don't report it to the lender / but this should never
    function _unstake(uint256 amount) internal override returns (uint256 availableAmount) {
        if (kekId == bytes32(0)) revert NoLockedLiquidity();
        if (block.timestamp - lastCreatedStake > stakingPeriod) revert UnstakedTooSoon();

        uint256 liquidityIndex = _lendingPool.getReserveData(address(want)).liquidityIndex;
        availableAmount = aFraxStakingContract.withdrawLocked(kekId, address(this));
        // can set a min amount to stake back
        if (amount < availableAmount) {
            // too much has been withdrawn we must create back a locker
            lastLiquidity = availableAmount - amount;
            kekId = aFraxStakingContract.stakeLocked(lastLiquidity, stakingPeriod);
            availableAmount = amount;
            lastCreatedStake = block.timestamp;
        } else {
            // this means we lost some funds in the process this shouldn't be possible and most surely to be deleted
            lastLiquidity = 0;
            lastCreatedStake = 0;
            delete kekId;
        }
        lastAaveLiquidityIndex = liquidityIndex;
    }

    /// @notice Get current staked Frax balance (counting interest receive since last update)
    function _stakedBalance() internal view override returns (uint256 amount) {
        uint256 liquidityIndex = _lendingPool.getReserveData(address(want)).liquidityIndex;
        return (lastLiquidity * liquidityIndex) / lastAaveLiquidityIndex;
    }

    /// @notice Permisionless function to claim rewards, reward tokens are directly sent to the contract and keeper/governance
    /// can handle them via a `sweep` or a `sellRewards` call
    function claimRewardsExternal() external returns (uint256[] memory) {
        return aFraxStakingContract.getReward(address(this));
    }

    /// @notice Permisionless function to update the minimum staking period as dictated by Frax contracts
    function setMinLockTime() external {
        minStakingPeriod = aFraxStakingContract.lock_time_min();
    }

    /// @notice Function to update the staking period
    function setLockTime(uint256 _stakingPeriod) external onlyRole(GUARDIAN_ROLE) {
        stakingPeriod = _stakingPeriod;
    }

    /// @notice Function to set a proxy on the staking contract to have a delegation on their boosting
    /// @dev We can have a multiplier if we ask for someone with boosting power
    /// @dev Can only be called after Frax governance called `aFraxStakingContract.toggleValidVeFXSProxy(proxy)`
    /// and proxy called `aFraxStakingContract.proxyToggleStaker(address(this))`
    function setProxyBoost(address proxy) external onlyRole(GUARDIAN_ROLE) {
        aFraxStakingContract.stakerSetVeFXSProxy(proxy);
    }
}
