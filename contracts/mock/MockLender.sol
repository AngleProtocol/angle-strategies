// SPDX-License-Identifier: GPL-3.0

pragma solidity ^0.8.12;

import "./../strategies/OptimizerAPR/genericLender/GenericLenderBaseUpgradeable.sol";

/// @title GenericEuler
/// @author Angle Core Team
/// @notice Simple supplier to Euler markets
contract MockLender is GenericLenderBaseUpgradeable {
    using SafeERC20 for IERC20;
    using Address for address;

    uint256 private constant _BPS = 10**4;

    uint256 public r0;
    uint256 public slope1;
    uint256 public totalBorrow;
    uint256 public biasSupply;
    uint256 public propWithdrawable;

    // ================================ CONSTRUCTOR ================================

    /// @notice Initializer of the `GenericEuler`
    /// @param _strategy Reference to the strategy using this lender
    /// @param governorList List of addresses with governor privilege
    /// @param keeperList List of addresses with keeper privilege
    /// @param guardian Address of the guardian
    function initialize(
        address _strategy,
        string memory _name,
        address[] memory governorList,
        address guardian,
        address[] memory keeperList,
        address oneInch_,
        uint256 _propWithdrawable
    ) public {
        _initialize(_strategy, _name, governorList, guardian, keeperList, oneInch_);
        propWithdrawable = _propWithdrawable;
    }

    function setPropWithdrawable(uint256 _propWithdrawable) external {
        propWithdrawable = _propWithdrawable;
    }

    // ======================== EXTERNAL STRATEGY FUNCTIONS ========================

    /// @inheritdoc IGenericLender
    function deposit() external view override onlyRole(STRATEGY_ROLE) {
        want.balanceOf(address(this));
    }

    /// @inheritdoc IGenericLender
    function withdraw(uint256 amount) external override onlyRole(STRATEGY_ROLE) returns (uint256) {
        return _withdraw(amount);
    }

    /// @inheritdoc IGenericLender
    function withdrawAll() external override onlyRole(STRATEGY_ROLE) returns (bool) {
        uint256 invested = _nav();
        uint256 returned = _withdraw(invested);
        return returned >= invested;
    }

    // ========================== EXTERNAL VIEW FUNCTIONS ==========================

    /// @inheritdoc GenericLenderBaseUpgradeable
    function underlyingBalanceStored() public pure override returns (uint256) {
        return 0;
    }

    /// @inheritdoc IGenericLender
    function aprAfterDeposit(int256 amount) external view override returns (uint256) {
        return _aprAfterDeposit(amount);
    }

    // ================================= GOVERNANCE ================================

    /// @inheritdoc IGenericLender
    function emergencyWithdraw(uint256 amount) external override onlyRole(GUARDIAN_ROLE) {
        want.safeTransfer(address(poolManager), amount);
    }

    // ============================= INTERNAL FUNCTIONS ============================

    /// @inheritdoc GenericLenderBaseUpgradeable
    function _apr() internal view override returns (uint256) {
        return _aprAfterDeposit(0);
    }

    /// @notice Internal version of the `aprAfterDeposit` function
    function _aprAfterDeposit(int256 amount) internal view returns (uint256 supplyAPY) {
        uint256 totalSupply = want.balanceOf(address(this));
        if (amount >= 0) totalSupply += uint256(amount);
        else totalSupply -= uint256(-amount);
        if (totalSupply > 0) supplyAPY = _computeAPYs(totalSupply);
    }

    /// @notice Computes APYs based on the interest rate, reserve fee, borrow
    /// @param totalSupply Interest rate paid per second by borrowers
    /// @return supplyAPY The annual percentage yield received as a supplier with current settings
    function _computeAPYs(uint256 totalSupply) internal view returns (uint256 supplyAPY) {
        // All rates are in base 18 on Angle strategies
        supplyAPY = r0 + (slope1 * totalBorrow) / (totalSupply + biasSupply);
    }

    /// @notice See `withdraw`
    function _withdraw(uint256 amount) internal returns (uint256) {
        uint256 looseBalance = want.balanceOf(address(this));
        uint256 total = looseBalance;

        if (amount > total) {
            // Can't withdraw more than we own
            amount = total;
        }

        // Limited in what we can withdraw
        amount = (amount * propWithdrawable) / _BPS;
        want.safeTransfer(address(strategy), amount);
        return amount;
    }

    /// @notice Internal version of the `setEulerPoolVariables`
    function setLenderPoolVariables(
        uint256 _r0,
        uint256 _slope1,
        uint256 _totalBorrow,
        uint256 _biasSupply
    ) external {
        r0 = _r0;
        slope1 = _slope1;
        totalBorrow = _totalBorrow;
        biasSupply = _biasSupply;
    }

    // ============================= VIRTUAL FUNCTIONS =============================

    /// @inheritdoc IGenericLender
    function hasAssets() external view override returns (bool) {
        return _nav() > 0;
    }

    function _protectedTokens() internal pure override returns (address[] memory) {
        return new address[](0);
    }
}
