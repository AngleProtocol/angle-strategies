// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.12;

import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import { IStakedAave, IReserveInterestRateStrategy } from "../../../interfaces/external/aave/IAave.sol";
import "../../../interfaces/external/aave/IAaveToken.sol";
import "../../../interfaces/external/aave/IProtocolDataProvider.sol";
import "../../../interfaces/external/aave/ILendingPool.sol";
import "./GenericAaveUpgradeable.sol";

/// @title GenericAaveFraxStaker
/// @author  Angle Core Team
/// @notice Allow to stake aFRAX on FRAX contracts to earn their incentives
contract GenericAaveFraxStaker is GenericAaveUpgradeable {
    using SafeERC20 for IERC20;
    using Address for address;

    // // ==================== References to contracts =============================
    // AggregatorV3Interface public constant oracle = AggregatorV3Interface(0x547a514d5e3769680Ce22B2361c10Ea13619e8a9);
    // address public constant oneInch = 0x1111111254fb6c44bAC0beD2854e76F90643097d;

    // // // ========================== Aave Protocol Addresses ==========================

    // address private constant _aave = 0x7Fc66500c84A76Ad7e9c93437bFc5Ac33E2DDaE9;
    // IStakedAave private constant _stkAave = IStakedAave(0x4da27a545c0c5B758a6BA100e3a049001de870f5);
    // IAaveIncentivesController private constant _incentivesController =
    //     IAaveIncentivesController(0xd784927Ff2f95ba542BfC824c8a8a98F3495f6b5);
    // ILendingPool private constant _lendingPool = ILendingPool(0x7d2768dE32b0b80b7a3454c06BdAc94A69DDc7A9);
    // IProtocolDataProvider private constant _protocolDataProvider =
    //     IProtocolDataProvider(0x057835Ad21a177dbdd3090bB1CAE03EaCF78Fc6d);

    // ==================== Parameters =============================

    error Test();

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
        address[] memory keeperList
    ) external {
        initializeBase(_strategy, name, _isIncentivised, governorList, guardian, keeperList);
    }

    // ========================= Virtual Functions ===========================

    function _stake(uint256 amount) internal virtual;

    function _unstake(uint256 amount) internal virtual;

    function _stakedBalance() internal virtual;
}
