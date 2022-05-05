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

    // // ========================== Protocol Addresses ==========================

    AggregatorV3Interface public constant oracleFXS = AggregatorV3Interface(0x6Ebc52C8C1089be9eB3945C4350B68B8E4C2233f);
    IFraxUnifiedFarmTemplate private constant aFraxStakingContract =
        IFraxUnifiedFarmTemplate(0x02577b426F223A6B4f2351315A19ecD6F357d65c);
    uint256 private constant FRAX_IDX = 0;

    // ==================== Parameters =============================

    // hash representing the position on Frax staker
    bytes32 public kekId;
    // used to track the current liquidity (staked + interests)
    uint256 public lastAaveReserveNormalizedIncome;
    // Last liquidity recorded on Frax staking contract
    uint256 private lastLiquidity;
    // Last time a staker has been created
    uint256 public lastCreatedStake;
    // Minimum staking period
    uint256 public minStakingPeriod;
    uint256 private constant minStakingAmount = 1000 * 1e18; // 100 aFrax
    uint256 public stakingPeriod;

    error NoLockedLiquidity();
    error TooSmallStakingPeriod();
    error StakingPeriodTooSmall();
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
        minStakingPeriod = aFraxStakingContract.lock_time_min();
        if (_stakingPeriod < minStakingPeriod) revert TooSmallStakingPeriod();
        stakingPeriod = _stakingPeriod;
        minStakingPeriod = 86400;

        lastAaveReserveNormalizedIncome = _lendingPool.getReserveNormalizedIncome(address(want));
        IERC20(address(_aToken)).safeApprove(address(aFraxStakingContract), type(uint256).max);
    }

    // ========================= External Functions ===========================

    /// @notice Permisionless function to claim rewards, reward tokens are directly sent to the contract and keeper/governance
    /// can handle them via a `sweep` or a `sellRewards` call
    function claimRewardsExternal() external returns (uint256[] memory) {
        return aFraxStakingContract.getReward(address(this));
    }

    /// @notice Permisionless function to update the minimum staking period as dictated by Frax contracts
    function setMinLockTime() external {
        minStakingPeriod = aFraxStakingContract.lock_time_min();
    }

    // ========================= Governance Functions ===========================

    /// @notice Function to update the staking period
    function setLockTime(uint256 _stakingPeriod) external onlyRole(GUARDIAN_ROLE) {
        if (_stakingPeriod < minStakingPeriod) revert StakingPeriodTooSmall();
        stakingPeriod = _stakingPeriod;
    }

    /// @notice Function to set a proxy on the staking contract to have a delegation on their boosting
    /// @dev We can have a multiplier if we ask for someone with boosting power
    /// @dev Can only be called after Frax governance called `aFraxStakingContract.toggleValidVeFXSProxy(proxy)`
    /// and proxy called `aFraxStakingContract.proxyToggleStaker(address(this))`
    function setProxyBoost(address proxy) external onlyRole(GUARDIAN_ROLE) {
        aFraxStakingContract.stakerSetVeFXSProxy(proxy);
    }

    /// @notice Change allowance on aFRAX for the staking contract.
    /// @param amount Amount to allow
    function changeAllowance(uint256 amount) external onlyRole(GUARDIAN_ROLE) {
        uint256 currentAllowance = _aToken.allowance(address(this), address(aFraxStakingContract));
        if (currentAllowance < amount) {
            IERC20(address(_aToken)).safeIncreaseAllowance(address(aFraxStakingContract), amount - currentAllowance);
        } else if (currentAllowance > amount) {
            IERC20(address(_aToken)).safeDecreaseAllowance(address(aFraxStakingContract), currentAllowance - amount);
        }
    }

    // ========================= Virtual Functions ===========================

    /// @notice Allow the lender to stake its aTokens in the external staking contract
    /// @param amount Amount of aToken wanted to be stake
    /// @dev If there is an existent locker already on Frax staking contract (keckId != null) --> then add to it
    /// otherwise (first time w deposit or last action was a withdraw) we need to create a new locker
    /// @dev Currently there is no additional reward to stake more than the minimum period as there is no multiplier
    function _stake(uint256 amount) internal override returns (uint256 stakedAmount) {
        uint256 reserveNormalizedIncome = _lendingPool.getReserveNormalizedIncome(address(want));

        if (kekId == bytes32(0)) {
            kekId = aFraxStakingContract.stakeLocked(amount, stakingPeriod);
            lastLiquidity = amount;
            lastCreatedStake = block.timestamp;
        } else {
            aFraxStakingContract.lockAdditional(kekId, amount);
            lastLiquidity = (lastLiquidity * reserveNormalizedIncome) / lastAaveReserveNormalizedIncome + amount;
        }

        lastAaveReserveNormalizedIncome = reserveNormalizedIncome;
        stakedAmount = amount;
    }

    /// @notice Allow the lender to unstake its aTokens from the external staking contract
    /// @param amount Amount of aToken wanted to be unstake
    /// @dev If minimum staking period is not finished the function will revert / we can also
    /// want to continue the process by just returning availableAmount=0 instead
    /// @dev We suppose there is no loss on staking contract --> only if the funds get hacked
    function _unstake(uint256 amount) internal override returns (uint256 freedAmount) {
        if (kekId == bytes32(0)) revert NoLockedLiquidity();
        if (block.timestamp - lastCreatedStake < stakingPeriod) revert UnstakedTooSoon();

        uint256 reserveNormalizedIncome = _lendingPool.getReserveNormalizedIncome(address(want));
        freedAmount = aFraxStakingContract.withdrawLocked(kekId, address(this));

        // can set a min amount to stake back
        if (amount + minStakingAmount < freedAmount) {
            // too much has been withdrawn we must create back a locker
            lastLiquidity = freedAmount - amount;
            kekId = aFraxStakingContract.stakeLocked(lastLiquidity, stakingPeriod);

            // - 1 because there values are rounded when transfering aTokens so we may end up with
            // with a little bit less, instead of making multiple call just play it safe and withdraw 1 in all cases
            freedAmount = amount - 1;
            lastCreatedStake = block.timestamp;
        } else {
            lastLiquidity = 0;
            lastCreatedStake = 0;
            delete kekId;
        }

        lastAaveReserveNormalizedIncome = reserveNormalizedIncome;
    }

    /// @notice Get current staked Frax balance (counting interest receive since last update)
    function _stakedBalance() internal view override returns (uint256 amount) {
        uint256 reserveNormalizedIncome = _lendingPool.getReserveNormalizedIncome(address(want));
        return (lastLiquidity * reserveNormalizedIncome) / lastAaveReserveNormalizedIncome;
    }

    /// @notice Get stakingAPR after staking an additional `amount`
    /// @param amount Virtual amount to be staked
    function _stakingApr(uint256 amount) internal view override returns (uint256 apr) {
        // These computations are made possible only because there will be only one staker
        (uint256 oldCombinedWeight, uint256 newVefxsMultiplier, uint256 newCombinedWeight) = aFraxStakingContract
            .calcCurCombinedWeight(address(this));

        uint256 newBalance;
        // if we didn't stake we need and we don't have anything to give, then stakingApr can only be 0
        if (lastLiquidity == 0 && amount == 0) return 0;
        // if we didn't stake we need an extra info on the multiplier per staking period
        // otherwise we reverse engineer the function
        else if (lastLiquidity == 0) {
            newBalance = amount;
            newCombinedWeight =
                (newBalance * (aFraxStakingContract.lockMultiplier(stakingPeriod) + newVefxsMultiplier)) /
                1 ether;
        } else {
            newBalance = (_stakedBalance() + amount);
            newCombinedWeight = (newBalance * newCombinedWeight) / lastLiquidity;
        }

        // if we arrive up until here the totalCombinedWeight can only be non null
        uint256 totalCombinedWeight = aFraxStakingContract.totalCombinedWeight() +
            newCombinedWeight -
            oldCombinedWeight;

        uint256 rewardRate = (newCombinedWeight * aFraxStakingContract.rewardRates(FRAX_IDX) * 1 ether) /
            (totalCombinedWeight * 1 ether);

        // APRs are in 1e18 and 95% of estimated APR to avoid overestimations
        apr = (_estimatedFXSToWant(rewardRate) * _SECONDS_IN_YEAR * 9500 * 1 ether) / 10000 / newBalance;
    }

    // ========================= Internal Functions ===========================

    /// @notice Estimate the amount of `want` we will get out by swapping it for FXS
    /// @param amount Amount of FXS we want to exchange (in base 18)
    /// @return swappedAmount Amount of `want` we are getting but in a gloabl base 18
    /// @dev Uses Chainlink spot price. Return value will be in base 18
    function _estimatedFXSToWant(uint256 amount) internal view returns (uint256) {
        (, int256 fxsPriceUSD, , , ) = oracleFXS.latestRoundData(); // fxsPriceUSD is in base 8
        return (uint256(fxsPriceUSD) * amount) / 1e8;
    }
}
