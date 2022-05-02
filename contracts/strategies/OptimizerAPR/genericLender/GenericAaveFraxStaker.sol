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

    error NoLockedLiquidity();
    error TooSmallStakingPeriod();

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
    }

    // ========================= Virtual Functions ===========================

    /// @notice Allow the lender to stake its aTokens in an external staking contract
    /// @param amount Amount of aToken wanted to be stake
    /// @dev If there is an existent locker already on Frax staking contract (keckId != null) --> then add to it
    /// otherwise (first time w deposit or last action was a withdraw) we need to create a new locker
    /// @dev Currently there is no additional reward to stake more than the minimum period as there is no multiplier
    /// @dev We can have a multiplier if we ask for someone boosting power by let it (address_delegator) call `proxyToggleStaker(address(this))`
    /// and then call with this contract `stakerSetVeFXSProxy(address_delegator)`
    function _stake(uint256 amount) internal override returns (uint256 stakedAmount) {
        uint256 liquidityIndex = _lendingPool.getReserveData(address(want)).liquidityIndex;

        if (kekId == bytes32(0)) {
            kekId = aFraxStakingContract.stakeLocked(amount, stakingPeriod);
            lastLiquidity = amount;
        } else {
            aFraxStakingContract.lockAdditional(kekId, amount);
            lastLiquidity = (lastLiquidity * liquidityIndex) / lastAaveLiquidityIndex + amount;
        }
        lastAaveLiquidityIndex = liquidityIndex;
        stakedAmount = amount;
    }

    function _unstake(uint256 amount) internal override returns (uint256 withdrawnAmount) {
        if (kekId == bytes32(0)) revert NoLockedLiquidity();

        uint256 liquidityIndex = _lendingPool.getReserveData(address(want)).liquidityIndex;
        withdrawnAmount = aFraxStakingContract.withdrawLocked(kekId, address(this));
        if (amount <= withdrawnAmount) {
            // too much has been withdrawn we must create back a locker
            lastLiquidity = withdrawnAmount - amount;
            kekId = aFraxStakingContract.stakeLocked(lastLiquidity, stakingPeriod);
            withdrawnAmount = amount;
        } else {
            // this means we lost some funds in the process
            lastLiquidity = 0;
            delete kekId;
        }
        lastAaveLiquidityIndex = liquidityIndex;
    }

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

    /// @notice Permisionless function to update the minimum staking period as dictated by Frax contracts
    function setLockTime(uint256 _stakingPeriod) external onlyRole(GUARDIAN_ROLE) {
        stakingPeriod = _stakingPeriod;
    }
}
