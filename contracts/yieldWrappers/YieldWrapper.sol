// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.12;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import "../interfaces/ICoreBorrow.sol";
import "../interfaces/IERC4626.sol";
import "../external/ERC4626Upgradeable.sol";

import { SafeCastLib } from "@rari-capital/solmate/src/utils/SafeCastLib.sol";
import { FixedPointMathLib } from "@rari-capital/solmate/src/utils/FixedPointMathLib.sol";

/// @title Rari Vault (rvToken)
/// @author Transmissions11 and JetJadeja
/// @notice Flexible, minimalist, and gas-optimized yield
/// aggregator for earning interest on any ERC20 token.
contract YieldWrapper is ERC4626Upgradeable {
    using SafeCastLib for uint256;
    using SafeERC20 for IERC20;
    using FixedPointMathLib for uint256;

    // ============================= Constants =====================================

    /// @notice The maximum number of elements allowed on the withdrawal stack.
    /// @dev Needed to prevent denial of service attacks by queue operators.
    uint256 internal constant MAX_WITHDRAWAL_STACK_SIZE = 32;

    // ============================= References ====================================

    ICoreBorrow public coreBorrow;
    uint256 public baseUnit;

    // ============================= Errors ========================================

    error NotGovernor();
    error NotGovernorOrGuardian();

    /*///////////////////////////////////////////////////////////////
                                IMMUTABLES
    //////////////////////////////////////////////////////////////*/

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() initializer {}

    function initialize(ICoreBorrow _coreBorrow, IERC20Metadata _token) external initializer {
        __ERC4626_init(
            _token,
            // Angle agEUR Wrapper
            string(abi.encodePacked("Angle ", _token.name(), " Wrapper")),
            // awagEUR
            string(abi.encodePacked("aw", _token.symbol()))
        );
        coreBorrow = _coreBorrow;
        baseUnit = 10**_token.decimals();
    }

    /// @notice Checks whether the `msg.sender` has the governor role or not
    modifier onlyGovernor() {
        if (!coreBorrow.isGovernor(msg.sender)) revert NotGovernor();
        _;
    }

    /// @notice Checks whether the `msg.sender` has the governor role or not
    modifier onlyGovernorOrGuardian() {
        if (!coreBorrow.isGovernorOrGuardian(msg.sender)) revert NotGovernorOrGuardian();
        _;
    }

    /*///////////////////////////////////////////////////////////////
                           FEE CONFIGURATION
    //////////////////////////////////////////////////////////////*/

    /// @notice The percentage of profit recognized each harvest to reserve as fees.
    /// @dev A fixed point number where 1e18 represents 100% and 0 represents 0%.
    uint256 public feePercent;

    /// @notice Emitted when the fee percentage is updated.
    /// @param user The authorized user who triggered the update.
    /// @param newFeePercent The new fee percentage.
    event FeePercentUpdated(address indexed user, uint256 newFeePercent);

    /// @notice Sets a new fee percentage.
    /// @param newFeePercent The new fee percentage.
    function setFeePercent(uint256 newFeePercent) external onlyGovernorOrGuardian {
        // A fee percentage over 100% doesn't make sense.
        require(newFeePercent <= 1e18, "FEE_TOO_HIGH");

        // Update the fee percentage.
        feePercent = newFeePercent;

        emit FeePercentUpdated(msg.sender, newFeePercent);
    }

    /*///////////////////////////////////////////////////////////////
                        HARVEST CONFIGURATION
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when the harvest window is updated.
    /// @param user The authorized user who triggered the update.
    /// @param newHarvestWindow The new harvest window.
    event HarvestWindowUpdated(address indexed user, uint128 newHarvestWindow);

    /// @notice Emitted when the harvest delay is updated.
    /// @param user The authorized user who triggered the update.
    /// @param newHarvestDelay The new harvest delay.
    event HarvestDelayUpdated(address indexed user, uint64 newHarvestDelay);

    /// @notice Emitted when the harvest delay is scheduled to be updated next harvest.
    /// @param user The authorized user who triggered the update.
    /// @param newHarvestDelay The scheduled updated harvest delay.
    event HarvestDelayUpdateScheduled(address indexed user, uint64 newHarvestDelay);

    /// @notice The period in seconds during which multiple harvests can occur
    /// regardless if they are taking place before the harvest delay has elapsed.
    /// @dev Long harvest windows open the Vault up to profit distribution slowdown attacks.
    uint128 public harvestWindow;

    /// @notice The period in seconds over which locked profit is unlocked.
    /// @dev Cannot be 0 as it opens harvests up to sandwich attacks.
    uint64 public harvestDelay;

    /// @notice The value that will replace harvestDelay next harvest.
    /// @dev In the case that the next delay is 0, no update will be applied.
    uint64 public nextHarvestDelay;

    /// @notice Sets a new harvest window.
    /// @param newHarvestWindow The new harvest window.
    /// @dev The Vault's harvestDelay must already be set before calling.
    function setHarvestWindow(uint128 newHarvestWindow) external {
        // A harvest window longer than the harvest delay doesn't make sense.
        require(newHarvestWindow <= harvestDelay, "WINDOW_TOO_LONG");

        // Update the harvest window.
        harvestWindow = newHarvestWindow;

        emit HarvestWindowUpdated(msg.sender, newHarvestWindow);
    }

    /// @notice Sets a new harvest delay.
    /// @param newHarvestDelay The new harvest delay to set.
    /// @dev If the current harvest delay is 0, meaning it has not
    /// been set before, it will be updated immediately, otherwise
    /// it will be scheduled to take effect after the next harvest.
    function setHarvestDelay(uint64 newHarvestDelay) external onlyGovernor {
        // A harvest delay of 0 makes harvests vulnerable to sandwich attacks.
        require(newHarvestDelay != 0, "DELAY_CANNOT_BE_ZERO");

        // A harvest delay longer than 1 year doesn't make sense.
        require(newHarvestDelay <= 365 days, "DELAY_TOO_LONG");

        // If the harvest delay is 0, meaning it has not been set before:
        if (harvestDelay == 0) {
            // We'll apply the update immediately.
            harvestDelay = newHarvestDelay;

            emit HarvestDelayUpdated(msg.sender, newHarvestDelay);
        } else {
            // We'll apply the update next harvest.
            nextHarvestDelay = newHarvestDelay;

            emit HarvestDelayUpdateScheduled(msg.sender, newHarvestDelay);
        }
    }

    /*///////////////////////////////////////////////////////////////
                       TARGET FLOAT CONFIGURATION
    //////////////////////////////////////////////////////////////*/

    /// @notice The desired percentage of the Vault's holdings to keep as float.
    /// @dev A fixed point number where 1e18 represents 100% and 0 represents 0%.
    uint256 public targetFloatPercent;

    /// @notice Emitted when the target float percentage is updated.
    /// @param user The authorized user who triggered the update.
    /// @param newTargetFloatPercent The new target float percentage.
    event TargetFloatPercentUpdated(address indexed user, uint256 newTargetFloatPercent);

    /// @notice Set a new target float percentage.
    /// @param newTargetFloatPercent The new target float percentage.
    function setTargetFloatPercent(uint256 newTargetFloatPercent) external onlyGovernor {
        // A target float percentage over 100% doesn't make sense.
        require(newTargetFloatPercent <= 1e18, "TARGET_TOO_HIGH");

        // Update the target float percentage.
        targetFloatPercent = newTargetFloatPercent;

        emit TargetFloatPercentUpdated(msg.sender, newTargetFloatPercent);
    }

    /*///////////////////////////////////////////////////////////////
                          STRATEGY STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @notice The total amount of underlying tokens held in strategies at the time of the last harvest.
    /// @dev Includes maxLockedProfit, must be correctly subtracted to compute available/free holdings.
    uint256 public totalStrategyHoldings;

    /// @dev Packed struct of strategy data.
    /// @param trusted Whether the strategy is trusted.
    /// @param balance The amount of underlying tokens held in the strategy.
    struct StrategyData {
        // Used to determine if the Vault will operate on a strategy.
        bool trusted;
        uint64 debtRatio;
        // Used to determine profit and loss during harvests of the strategy.
        uint256 balance;
    }

    /// @notice Maps strategies to data the Vault holds on them.
    mapping(address => StrategyData) public getStrategyData;

    /*///////////////////////////////////////////////////////////////
                             HARVEST STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @notice A timestamp representing when the first harvest in the most recent harvest window occurred.
    /// @dev May be equal to lastHarvest if there was/has only been one harvest in the most last/current window.
    uint64 public lastHarvestWindowStart;

    /// @notice A timestamp representing when the most recent harvest occurred.
    uint64 public lastHarvest;

    /// @notice The amount of locked profit at the end of the last harvest.
    uint256 public maxLockedProfit;

    /*///////////////////////////////////////////////////////////////
                        WITHDRAWAL STACK STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @notice An ordered array of strategies representing the withdrawal stack.
    /// @dev The stack is processed in descending order, meaning the last index will be withdrawn from first.
    /// @dev Strategies that are untrusted, duplicated, or have no balance are filtered out when encountered at
    /// withdrawal time, not validated upfront, meaning the stack may not reflect the "true" set used for withdrawals.
    address[] public withdrawalStack;

    /// @notice Gets the full withdrawal stack.
    /// @return An ordered array of strategies representing the withdrawal stack.
    /// @dev This is provided because Solidity converts public arrays into index getters,
    /// but we need a way to allow external contracts and users to access the whole array.
    function getWithdrawalStack() external view returns (address[] memory) {
        return withdrawalStack;
    }

    /*///////////////////////////////////////////////////////////////
                        DEPOSIT/WITHDRAWAL LOGIC
    //////////////////////////////////////////////////////////////*/

    function afterDeposit(uint256, uint256) internal override {}

    function beforeWithdraw(uint256 assets, uint256) internal override {
        // Retrieve underlying tokens from strategies/float.
        retrieveUnderlying(assets);
    }

    /// @dev Retrieves a specific amount of underlying tokens held in strategies and/or float.
    /// @dev Only withdraws from strategies if needed and maintains the target float percentage if possible.
    /// @param underlyingAmount The amount of underlying tokens to retrieve.
    function retrieveUnderlying(uint256 underlyingAmount) internal {
        // Get the Vault's floating balance.
        uint256 float = totalFloat();

        // If the amount is greater than the float, withdraw from strategies.
        if (underlyingAmount > float) {
            // Compute the amount needed to reach our target float percentage.
            uint256 floatMissingForTarget = (totalAssets() - underlyingAmount).mulWadDown(targetFloatPercent);

            // Compute the bare minimum amount we need for this withdrawal.
            uint256 floatMissingForWithdrawal = underlyingAmount - float;

            // Pull enough to cover the withdrawal and reach our target float percentage.
            pullFromWithdrawalStack(floatMissingForWithdrawal + floatMissingForTarget);
        }
    }

    /*///////////////////////////////////////////////////////////////
                        VAULT ACCOUNTING LOGIC
    //////////////////////////////////////////////////////////////*/

    /// @notice Calculates the total amount of underlying tokens the Wrapper holds.
    /// @return totalUnderlyingHeld The total amount of underlying tokens the Wrapper holds.
    function totalAssets() public view override returns (uint256 totalUnderlyingHeld) {
        unchecked {
            // Cannot underflow as locked profit can't exceed total strategy holdings.
            totalUnderlyingHeld = totalStrategyHoldings - lockedProfit();
        }

        // Include our floating balance in the total.
        totalUnderlyingHeld += totalFloat();
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

    /// @notice Returns the amount of underlying tokens that idly sit in the Vault.
    /// @return The amount of underlying tokens that sit idly in the Vault.
    function totalFloat() public view returns (uint256) {
        return asset.balanceOf(address(this));
    }

    /*///////////////////////////////////////////////////////////////
                             HARVEST LOGIC
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted after a successful harvest.
    /// @param user The authorized user who triggered the harvest.
    /// @param strategies The trusted strategies that were harvested.
    event Harvest(address indexed user, address[] strategies);

    /// @notice Harvest a set of trusted strategies.
    /// @param strategies The trusted strategies to harvest.
    /// @dev Will always revert if called outside of an active
    /// harvest window or before the harvest delay has passed.
    function harvest(address[] calldata strategies) external onlyGovernor {
        // If this is the first harvest after the last window:
        if (block.timestamp >= lastHarvest + harvestDelay) {
            // Set the harvest window's start timestamp.
            // Cannot overflow 64 bits on human timescales.
            lastHarvestWindowStart = uint64(block.timestamp);
        } else {
            // We know this harvest is not the first in the window so we need to ensure it's within it.
            require(block.timestamp <= lastHarvestWindowStart + harvestWindow, "BAD_HARVEST_TIME");
        }

        // Get the Vault's current total strategy holdings.
        uint256 oldTotalStrategyHoldings = totalStrategyHoldings;

        // Used to store the total profit accrued by the strategies.
        uint256 totalProfitAccrued;

        // Used to store the new total strategy holdings after harvesting.
        uint256 newTotalStrategyHoldings = oldTotalStrategyHoldings;

        // Will revert if any of the specified strategies are untrusted.
        for (uint256 i = 0; i < strategies.length; i++) {
            // Get the strategy at the current index.
            address strategy = strategies[i];

            // If an untrusted strategy could be harvested a malicious user could use
            // a fake strategy that over-reports holdings to manipulate the exchange rate.
            require(getStrategyData[strategy].trusted, "UNTRUSTED_STRATEGY");

            // Get the strategy's previous and current balance.
            uint256 balanceLastHarvest = getStrategyData[strategy].balance;
            // uint256 balanceThisHarvest = strategy.balanceOfUnderlying(address(this));
            uint256 balanceThisHarvest = IERC4626(strategy).maxWithdraw(address(this));

            // Update the strategy's stored balance. Cast overflow is unrealistic.
            getStrategyData[strategy].balance = balanceThisHarvest;

            // Increase/decrease newTotalStrategyHoldings based on the profit/loss registered.
            // We cannot wrap the subtraction in parenthesis as it would underflow if the strategy had a loss.
            newTotalStrategyHoldings = newTotalStrategyHoldings + balanceThisHarvest - balanceLastHarvest;

            unchecked {
                // Update the total profit accrued while counting losses as zero profit.
                // Cannot overflow as we already increased total holdings without reverting.
                totalProfitAccrued += balanceThisHarvest > balanceLastHarvest
                    ? balanceThisHarvest - balanceLastHarvest // Profits since last harvest.
                    : 0; // If the strategy registered a net loss we don't have any new profit.
            }
        }

        // Compute fees as the fee percent multiplied by the profit.
        uint256 feesAccrued = totalProfitAccrued.mulDivDown(feePercent, 1e18);

        // If we accrued any fees, mint an equivalent amount of rvTokens.
        // Authorized users can claim the newly minted rvTokens via claimFees.
        _mint(address(this), feesAccrued.mulDivDown(baseUnit, convertToAssets(baseUnit)));

        // Update max unlocked profit based on any remaining locked profit plus new profit.
        maxLockedProfit = (lockedProfit() + totalProfitAccrued - feesAccrued);

        // Set strategy holdings to our new total.
        totalStrategyHoldings = newTotalStrategyHoldings;

        // Update the last harvest timestamp.
        // Cannot overflow on human timescales.
        lastHarvest = uint64(block.timestamp);

        emit Harvest(msg.sender, strategies);

        // Get the next harvest delay.
        uint64 newHarvestDelay = nextHarvestDelay;

        // If the next harvest delay is not 0:
        if (newHarvestDelay != 0) {
            // Update the harvest delay.
            harvestDelay = newHarvestDelay;

            // Reset the next harvest delay.
            nextHarvestDelay = 0;

            emit HarvestDelayUpdated(msg.sender, newHarvestDelay);
        }
    }

    /*///////////////////////////////////////////////////////////////
                    STRATEGY DEPOSIT/WITHDRAWAL LOGIC
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted after the Vault deposits into a strategy contract.
    /// @param user The authorized user who triggered the deposit.
    /// @param strategy The strategy that was deposited into.
    /// @param underlyingAmount The amount of underlying tokens that were deposited.
    event StrategyDeposit(address indexed user, address indexed strategy, uint256 underlyingAmount);

    /// @notice Emitted after the Vault withdraws funds from a strategy contract.
    /// @param user The authorized user who triggered the withdrawal.
    /// @param strategy The strategy that was withdrawn from.
    /// @param underlyingAmount The amount of underlying tokens that were withdrawn.
    event StrategyWithdrawal(address indexed user, address indexed strategy, uint256 underlyingAmount);

    /// @notice Deposit a specific amount of float into a trusted strategy.
    /// @param strategy The trusted strategy to deposit into.
    /// @param underlyingAmount The amount of underlying tokens in float to deposit.
    function depositIntoStrategy(address strategy, uint256 underlyingAmount) external onlyGovernor {
        // A strategy must be trusted before it can be deposited into.
        require(getStrategyData[strategy].trusted, "UNTRUSTED_STRATEGY");

        // Increase totalStrategyHoldings to account for the deposit.
        totalStrategyHoldings += underlyingAmount;

        unchecked {
            // Without this the next harvest would count the deposit as profit.
            // Cannot overflow as the balance of one strategy can't exceed the sum of all.
            getStrategyData[strategy].balance += underlyingAmount;
        }

        emit StrategyDeposit(msg.sender, strategy, underlyingAmount);

        // Approve underlyingAmount to the strategy so we can deposit.
        asset.safeApprove(address(strategy), underlyingAmount);

        // Deposit into the strategy and revert if it returns an error code.
        require(IERC4626(address(strategy)).mint(underlyingAmount, address(this)) == 0, "MINT_FAILED");
    }

    /// @notice Withdraw a specific amount of underlying tokens from a strategy.
    /// @param strategy The strategy to withdraw from.
    /// @param underlyingAmount  The amount of underlying tokens to withdraw.
    /// @dev Withdrawing from a strategy will not remove it from the withdrawal stack.
    function withdrawFromStrategy(address strategy, uint256 underlyingAmount) external onlyGovernor {
        // A strategy must be trusted before it can be withdrawn from.
        require(getStrategyData[strategy].trusted, "UNTRUSTED_STRATEGY");

        // Without this the next harvest would count the withdrawal as a loss.
        getStrategyData[strategy].balance -= underlyingAmount;

        unchecked {
            // Decrease totalStrategyHoldings to account for the withdrawal.
            // Cannot underflow as the balance of one strategy will never exceed the sum of all.
            totalStrategyHoldings -= underlyingAmount;
        }

        emit StrategyWithdrawal(msg.sender, strategy, underlyingAmount);

        // Withdraw from the strategy and revert if it returns an error code.
        require(IERC4626(strategy).withdraw(underlyingAmount, address(this), address(this)) == 0, "REDEEM_FAILED");
    }

    /*///////////////////////////////////////////////////////////////
                      STRATEGY TRUST/DISTRUST LOGIC
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when a strategy is set to trusted.
    /// @param user The authorized user who trusted the strategy.
    /// @param strategy The strategy that became trusted.
    event StrategyTrusted(address indexed user, address indexed strategy);

    /// @notice Emitted when a strategy is set to untrusted.
    /// @param user The authorized user who untrusted the strategy.
    /// @param strategy The strategy that became untrusted.
    event StrategyDistrusted(address indexed user, address indexed strategy);

    /// @notice Stores a strategy as trusted, enabling it to be harvested.
    /// @param strategy The strategy to make trusted.
    function trustStrategy(address strategy) external onlyGovernor {
        // Ensure the strategy accepts the correct underlying token.
        // require(ERC20Strategy(address(strategy)).underlying() == asset, "WRONG_asset");

        // Store the strategy as trusted.
        getStrategyData[strategy].trusted = true;

        emit StrategyTrusted(msg.sender, strategy);
    }

    /// @notice Stores a strategy as untrusted, disabling it from being harvested.
    /// @param strategy The strategy to make untrusted.
    function distrustStrategy(address strategy) external onlyGovernor {
        // Store the strategy as untrusted.
        getStrategyData[strategy].trusted = false;

        emit StrategyDistrusted(msg.sender, strategy);
    }

    /*///////////////////////////////////////////////////////////////
                         WITHDRAWAL STACK LOGIC
    //////////////////////////////////////////////////////////////*/

    /// @dev Withdraw a specific amount of underlying tokens from strategies in the withdrawal stack.
    /// @param underlyingAmount The amount of underlying tokens to pull into float.
    /// @dev Automatically removes depleted strategies from the withdrawal stack.
    function pullFromWithdrawalStack(uint256 underlyingAmount) internal {
        // We will update this variable as we pull from strategies.
        uint256 amountLeftToPull = underlyingAmount;

        // We'll start at the tip of the stack and traverse backwards.
        uint256 currentIndex = withdrawalStack.length - 1;

        // Iterate in reverse so we pull from the stack in a "last in, first out" manner.
        // Will revert due to underflow if we empty the stack before pulling the desired amount.
        for (; ; currentIndex--) {
            // Get the strategy at the current stack index.
            address strategy = withdrawalStack[currentIndex];

            // Get the balance of the strategy before we withdraw from it.
            uint256 strategyBalance = getStrategyData[strategy].balance;

            // If the strategy is currently untrusted or was already depleted:
            if (!getStrategyData[strategy].trusted || strategyBalance == 0) {
                // Remove it from the stack.
                withdrawalStack.pop();


                // Move onto the next strategy.
                continue;
            }

            // We want to pull as much as we can from the strategy, but no more than we need.
            uint256 amountToPull = strategyBalance > amountLeftToPull ? amountLeftToPull : strategyBalance;

            unchecked {
                // Compute the balance of the strategy that will remain after we withdraw.
                // Cannot underflow as we cap the amount to pull at the strategy's balance.
                uint256 strategyBalanceAfterWithdrawal = strategyBalance - amountToPull;

                // Without this the next harvest would count the withdrawal as a loss.
                getStrategyData[strategy].balance = strategyBalanceAfterWithdrawal;

                // Adjust our goal based on how much we can pull from the strategy.
                // Cannot underflow as we cap the amount to pull at the amount left to pull.
                amountLeftToPull -= amountToPull;

                emit StrategyWithdrawal(msg.sender, strategy, amountToPull);

                // Withdraw from the strategy and revert if returns an error code.
                require(IERC4626(strategy).withdraw(underlyingAmount, address(this), address(this)) == 0, "REDEEM_FAILED");

                // If we fully depleted the strategy:
                if (strategyBalanceAfterWithdrawal == 0) {
                    // Remove it from the stack.
                    withdrawalStack.pop();
                }
            }

            // If we've pulled all we need, exit the loop.
            if (amountLeftToPull == 0) break;
        }

        unchecked {
            // Account for the withdrawals done in the loop above.
            // Cannot underflow as the balances of some strategies cannot exceed the sum of all.
            totalStrategyHoldings -= underlyingAmount;
        }

    }

    // TODO

    /*///////////////////////////////////////////////////////////////
                             FEE CLAIM LOGIC
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted after fees are claimed.
    /// @param user The authorized user who claimed the fees.
    /// @param rvTokenAmount The amount of rvTokens that were claimed.
    event FeesClaimed(address indexed user, uint256 rvTokenAmount);

    /// @notice Claims fees accrued from harvests.
    /// @param rvTokenAmount The amount of rvTokens to claim.
    /// @dev Accrued fees are measured as rvTokens held by the Vault.
    function claimFees(uint256 rvTokenAmount) external onlyGovernor {
        emit FeesClaimed(msg.sender, rvTokenAmount);

        // Transfer the provided amount of rvTokens to the caller.
        IERC20(address(this)).safeTransfer(msg.sender, rvTokenAmount);
    }


}
