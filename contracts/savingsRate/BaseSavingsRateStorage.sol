// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.12;

import "../interfaces/ICoreBorrow.sol";
import "../interfaces/IStrategy4626.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts-upgradeable/interfaces/IERC20MetadataUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
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
    /// TODO add `minDebtPerHarvest` and `maxDebtPerHarvest`? need to check as yarn
}

/// @title VaultStorage
/// @author Angle Core Team
/// @dev Variables, references, parameters and events needed in the `VaultManager` contract
contract BaseSavingsRateStorage is ERC4626Upgradeable {
    /// @notice The maximum number of elements allowed on the withdrawal stack.
    /// @dev Needed to prevent denial of service attacks by queue operators.
    uint256 internal constant MAX_WITHDRAWAL_STACK_SIZE = 32;

    uint256 internal constant BASE_PARAMS = 10**9;

    // =============================== References ==================================

    /// @notice CoreBorrow used to get governance addresses
    ICoreBorrow public coreBorrow;

    // =============================== Parameters ==================================
    // Unless specified otherwise, parameters of this contract are expressed in `BASE_PARAMS`

    /// @notice The share of profit going to the protocol.
    /// @dev Should be lower than `BASE_PARAM`.
    uint256 public protocolFee;

    /// @notice The share of profit going to the creator.
    /// @dev Should be lower than `BASE_PARAM`.
    uint256 public strategistFee;

    /// @notice Address to redirect protocol revenues
    address public surplusManager;

    // =============================== Variables ===================================

    /// @notice The total amount of underlying tokens held in strategies at the time of the last harvest/deposit/withdraw.
    uint256 public totalDebt;

    /// @notice Proportion of the funds managed dedicated to strategies
    /// Has to be between 0 and `BASE_PARAMS`
    uint256 public debtRatio;

    /// @notice An ordered array of strategies representing the withdrawal stack.
    /// @dev The stack is processed in descending order, meaning the last index will be withdrawn from first.
    /// @dev Strategies that are untrusted, duplicated, or have no balance are filtered out when encountered at
    /// withdrawal time, not validated upfront, meaning the stack may not reflect the "true" set used for withdrawals.
    IStrategy4626[] public withdrawalStack;

    /// @notice List of the current strategies
    IStrategy4626[] public strategyList;

    /// @notice Unpaid loss from the protocol
    uint256 public protocolLoss;

    // ================================ Mappings ===================================

    /// The struct `StrategyParams` is defined in the interface `IPoolManager`
    /// @notice Mapping between the address of a strategy contract and its corresponding details
    mapping(IStrategy4626 => StrategyParams) public strategies;

    // =============================== Events ======================================

    event ProtocolFeeUpdated(address indexed user, uint256 protocolFee);
    event StrategistFeeUpdated(address indexed user, uint256 strategistFee);
    event Harvest(address indexed user, IStrategy4626[] strategies);
    event WithdrawalStackSet(address indexed user, IStrategy4626[] replacedWithdrawalStack);
    event FeesClaimed(address indexed user, uint256 rvTokenAmount);
    event StrategyAdded(address indexed strategy, uint256 debtRatio);
    event StrategyRevoked(address indexed strategy);
    event UpdatedDebtRatio(address indexed strategy, uint256 debtRatio);
    event StrategyReported(
        address indexed strategy,
        uint256 gain,
        uint256 loss,
        uint256 debtPayment,
        uint256 totalDebt
    );

    // =============================== Errors ======================================

    error NotGovernor();
    error NotGovernorOrGuardian();
    error NotStrategy();
    error StrategyDoesNotExist();
    error WrongStrategyToken();
    error StrategyAlreadyAdded();
    error DebtRatioTooHigh();
    error StrategyInUse();
    error StrategyDebtUnpaid();
    error RevokeStrategyImpossible();
    error StratgyLowOnCash();
    error ProtocolFeeTooHigh();
    error WithdrawalStackTooDeep();
    error LossShouldbe0();
    error SlippageProtection();
    error IncompatibleLengths();
    error WithdrawLimit();

    /// TODO need to count number of slot used
    uint256[50] private __gapBaseSavingsRate;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() initializer {}
}
