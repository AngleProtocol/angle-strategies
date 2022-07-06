// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.12;

import "../interfaces/ICoreBorrow.sol";
import "../interfaces/IStrategy4626.sol";
import "../interfaces/IVotingEscrowBoost.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts-upgradeable/interfaces/IERC20MetadataUpgradeable.sol";
// TODO changed to ERC4626 when the package is updated
// The only difference is that the `_deposit` and the `_withdraw` will be internal virtual instead of private
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20TokenizedVaultUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/utils/Address.sol";

// Struct for the parameters associated to a strategy interacting with a collateral `PoolManager`
// contract
struct StrategyParams {
    // Timestamp of last report made by this strategy
    // It is also used to check if a strategy has been initialized
    uint256 lastReport;
    // Total amount the strategy is expected to have
    uint256 totalStrategyDebt;
    // The share of the total assets in the `PoolManager` contract that the `strategy` can access to.
    uint256 debtRatio;
}

/// @title VaultStorage
/// @author Angle Core Team
/// @dev Variables, references, parameters and events needed in the `VaultManager` contract
contract VaultStorage is ERC20TokenizedVaultUpgradeable {
    /// @notice The maximum number of elements allowed on the withdrawal stack.
    /// @dev Needed to prevent denial of service attacks by queue operators.
    uint256 internal constant MAX_WITHDRAWAL_STACK_SIZE = 32;

    uint256 internal constant BASE_PARAMS = 10**9;

    // =============================== References ==================================

    /// @notice CoreBorrow used to get governance addresses
    ICoreBorrow public coreBorrow;

    /// @notice Reference to the veANGLE
    IERC20 internal votingEscrow;

    /// @notice Reference to the veANGLE
    IVotingEscrowBoost internal veBoostProxy;

    // =============================== Parameters ==================================
    // Unless specified otherwise, parameters of this contract are expressed in `BASE_PARAMS`

    /// @notice The percentage of profit recognized each harvest to reserve as fees.
    /// @dev A fixed point number where 1e18 represents 100% and 0 represents 0%.
    uint256 public feePercent;

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

    uint256 public tokenlessProduction;

    // =============================== Variables ===================================

    uint256 public baseUnit;

    /// @notice The total amount of underlying tokens held in strategies at the time of the last harvest.
    /// @dev Includes maxLockedProfit, must be correctly subtracted to compute available/free holdings.
    uint256 public totalDebt;

    /// @notice Proportion of the funds managed dedicated to strategies
    /// Has to be between 0 and `BASE_PARAMS`
    uint256 public debtRatio;

    /// @notice A timestamp representing when the first harvest in the most recent harvest window occurred.
    /// @dev May be equal to lastHarvest if there was/has only been one harvest in the most last/current window.
    uint64 public lastHarvestWindowStart;

    /// @notice A timestamp representing when the most recent harvest occurred.
    uint64 public lastHarvest;

    /// @notice The amount of locked profit at the end of the last harvest.
    uint256 public maxLockedProfit;

    /// @notice An ordered array of strategies representing the withdrawal stack.
    /// @dev The stack is processed in descending order, meaning the last index will be withdrawn from first.
    /// @dev Strategies that are untrusted, duplicated, or have no balance are filtered out when encountered at
    /// withdrawal time, not validated upfront, meaning the stack may not reflect the "true" set used for withdrawals.
    IStrategy4626[] public withdrawalStack;

    /// @notice List of the current strategies
    IStrategy4626[] public strategyList;

    /// @notice Unpaid loss from the protocol
    uint256 public protocolLoss;

    /// @notice Unpaid loss from users
    uint256 public usersLoss;

    /// @notice Boosting params
    uint256 public workingSupply;

    /// @notice Rewards (in asset) claimable by depositors
    uint256 public claimableRewards;
    /// @notice Used to track rewards accumulated by all depositors of the reactor
    uint256 public rewardsAccumulator;
    /// @notice Tracks rewards already claimed by all depositors
    uint256 public claimedRewardsAccumulator;
    /// @notice Last time rewards were claimed in the reactor
    uint256 public lastTime;
    /// @notice Maps an address to the last time it claimed its rewards
    mapping(address => uint256) public lastTimeOf;
    /// @notice Maps an address to a quantity depending on time and shares of the reactors used
    /// to compute the rewards an address can claim
    mapping(address => uint256) public rewardsAccumulatorOf;

    // ================================ Mappings ===================================

    /// The struct `StrategyParams` is defined in the interface `IPoolManager`
    /// @notice Mapping between the address of a strategy contract and its corresponding details
    mapping(IStrategy4626 => StrategyParams) public strategies;

    mapping(address => uint256) public workingBalances;

    // =============================== Events ======================================

    event FeePercentUpdated(address indexed user, uint256 newFeePercent);
    event HarvestWindowUpdated(address indexed user, uint128 newHarvestWindow);
    event HarvestDelayUpdated(address indexed user, uint64 newHarvestDelay);
    event HarvestDelayUpdateScheduled(address indexed user, uint64 newHarvestDelay);
    event TargetFloatPercentUpdated(address indexed user, uint256 newTargetFloatPercent);
    event Harvest(address indexed user, IStrategy4626[] strategies);
    event StrategyDeposit(address indexed user, IStrategy4626 indexed strategy, uint256 underlyingAmount);
    event StrategyWithdrawal(address indexed user, IStrategy4626 indexed strategy, uint256 underlyingAmount);
    event StrategyTrusted(address indexed user, IStrategy4626 indexed strategy);
    event StrategyDistrusted(address indexed user, IStrategy4626 indexed strategy);

    event WithdrawalStackPushed(address indexed user, IStrategy4626 indexed pushedStrategy);
    event WithdrawalStackPopped(address indexed user, IStrategy4626 indexed poppedStrategy);
    event WithdrawalStackSet(address indexed user, IStrategy4626[] replacedWithdrawalStack);
    event WithdrawalStackIndexReplaced(
        address indexed user,
        uint256 index,
        IStrategy4626 indexed replacedStrategy,
        IStrategy4626 indexed replacementStrategy
    );
    event WithdrawalStackIndexReplacedWithTip(
        address indexed user,
        uint256 index,
        IStrategy4626 indexed replacedStrategy,
        IStrategy4626 indexed previousTipStrategy
    );
    event WithdrawalStackIndexesSwapped(
        address indexed user,
        uint256 index1,
        uint256 index2,
        IStrategy4626 indexed newStrategy1,
        IStrategy4626 indexed newStrategy2
    );

    event FeesClaimed(address indexed user, uint256 rvTokenAmount);
    event Initialized(address indexed user);

    event StrategyAdded(address indexed strategy, uint256 debtRatio);
    event StrategyRevoked(address indexed strategy);
    event UpdatedDebtRatio(address indexed strategy, uint256 debtRatio);

    // =============================== Errors ======================================

    error NotGovernor();
    error NotGovernorOrGuardian();
    error NotStrategy();
    error StrategyDoesNotExist();
    error WrongStrategyToken();
    error StrategyAlreadyAdded();
    error WrongPoolmanagerForStrategy();
    error DebtRatioTooHigh();
    error StrategyInUse();
    error StrategyDebtUnpaid();
    error revokeStrategyImpossible();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() initializer {}
}
