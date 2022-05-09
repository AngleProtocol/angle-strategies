// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.12;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/Address.sol";

import "../../../external/AccessControlUpgradeable.sol";

import "../../../interfaces/IGenericLender.sol";
import "../../../interfaces/IPoolManager.sol";
import "../../../interfaces/IStrategy.sol";

/// @title GenericLenderBaseUpgradeable
/// @author Forked from https://github.com/Grandthrax/yearnV2-generic-lender-strat/tree/master/contracts/GenericLender
/// @notice A base contract to build contracts that lend assets to protocols
abstract contract GenericLenderBaseUpgradeable is IGenericLender, AccessControlUpgradeable {
    using SafeERC20 for IERC20;

    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");
    bytes32 public constant STRATEGY_ROLE = keccak256("STRATEGY_ROLE");
    bytes32 public constant KEEPER_ROLE = keccak256("KEEPER_ROLE");

    // ======================= References to contracts =============================

    address private constant oneInch = 0x1111111254fb6c44bAC0beD2854e76F90643097d;

    // ========================= References and Parameters =========================

    string public override lenderName;
    /// @notice Reference to the protocol's collateral poolManager
    IPoolManager public poolManager;
    /// @notice Reference to the `Strategy`
    address public override strategy;
    /// @notice Reference to the token lent
    IERC20 public want;

    // ================================ Errors =====================================

    error ErrorSwap();
    error IncompatibleLengths();
    error ProtectedToken();
    error TooSmallAmount();

    // ================================ Initializer ================================

    /// @notice Initalizer of the `GenericLenderBase`
    /// @param _strategy Reference to the strategy using this lender
    /// @param _name Name of the lender
    /// @param governorList List of addresses with governor privilege
    /// @param guardian Address of the guardian
    /// @param keeperList List of keeper addresses
    function _initialize(
        address _strategy,
        string memory _name,
        address[] memory governorList,
        address guardian,
        address[] memory keeperList
    ) internal initializer {
        strategy = _strategy;
        // The corresponding `PoolManager` is inferred from the `Strategy`
        poolManager = IPoolManager(IStrategy(strategy).poolManager());
        want = IERC20(poolManager.token());
        lenderName = _name;

        _setupRole(GUARDIAN_ROLE, address(poolManager));
        for (uint256 i = 0; i < governorList.length; i++) {
            _setupRole(GUARDIAN_ROLE, governorList[i]);
        }

        _setupRole(KEEPER_ROLE, guardian);
        for (uint256 i = 0; i < keeperList.length; i++) {
            _setupRole(KEEPER_ROLE, keeperList[i]);
        }

        _setRoleAdmin(KEEPER_ROLE, GUARDIAN_ROLE);

        _setupRole(GUARDIAN_ROLE, guardian);
        _setupRole(STRATEGY_ROLE, _strategy);
        _setRoleAdmin(GUARDIAN_ROLE, STRATEGY_ROLE);
        _setRoleAdmin(STRATEGY_ROLE, GUARDIAN_ROLE);

        want.safeApprove(_strategy, type(uint256).max);
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() initializer {}

    // ============================ Governance Functions ===========================

    /// @notice Override this to add all tokens/tokenized positions this contract
    /// manages on a *persistent* basis (e.g. not just for swapping back to
    /// want ephemerally).
    ///
    /// Example:
    /// ```
    ///    function _protectedTokens() internal override view returns (address[] memory) {
    ///      address[] memory protected = new address[](3);
    ///      protected[0] = tokenA;
    ///      protected[1] = tokenB;
    ///      protected[2] = tokenC;
    ///      return protected;
    ///    }
    /// ```
    function _protectedTokens() internal view virtual returns (address[] memory);

    /// @notice
    /// Removes tokens from this Strategy that are not the type of tokens
    /// managed by this Strategy. This may be used in case of accidentally
    /// sending the wrong kind of token to this Strategy.
    ///
    /// Tokens will be sent to `governance()`.
    ///
    /// This will fail if an attempt is made to sweep `want`, or any tokens
    /// that are protected by this Strategy.
    ///
    /// This may only be called by governance.
    /// @param _token The token to transfer out of this poolManager.
    /// @param to Address to send the tokens to.
    /// @dev
    /// Implement `_protectedTokens()` to specify any additional tokens that
    /// should be protected from sweeping in addition to `want`.
    function sweep(address _token, address to) external override onlyRole(GUARDIAN_ROLE) {
        address[] memory __protectedTokens = _protectedTokens();
        for (uint256 i = 0; i < __protectedTokens.length; i++)
            if (_token == __protectedTokens[i]) revert ProtectedToken();

        IERC20(_token).safeTransfer(to, IERC20(_token).balanceOf(address(this)));
    }

    /// @notice Changes allowance of a set of tokens to addresses
    /// @param tokens Addresses of the tokens for which approvals should be made
    /// @param spenders Addresses to approve
    /// @param amounts Approval amounts for each address
    function changeAllowance(
        IERC20[] calldata tokens,
        address[] calldata spenders,
        uint256[] calldata amounts
    ) external onlyRole(GUARDIAN_ROLE) {
        if (tokens.length != spenders.length || tokens.length != amounts.length) revert IncompatibleLengths();
        for (uint256 i = 0; i < tokens.length; i++) {
            uint256 currentAllowance = tokens[i].allowance(address(this), address(spenders[i]));
            if (currentAllowance < amounts[i]) {
                IERC20(address(tokens[i])).safeIncreaseAllowance(address(spenders[i]), amounts[i] - currentAllowance);
            } else if (currentAllowance > amounts[i]) {
                IERC20(address(tokens[i])).safeDecreaseAllowance(address(spenders[i]), currentAllowance - amounts[i]);
            }
        }
    }

    /// @notice Swap earned _stkAave or Aave for `want` through 1Inch
    /// @param minAmountOut Minimum amount of `want` to receive for the swap to happen
    /// @param payload Bytes needed for 1Inch API
    /// @dev In the case of a contract lending to Aave, tokens swapped should typically be: _stkAave -> `want` or Aave -> `want`
    function sellRewards(uint256 minAmountOut, bytes memory payload) external onlyRole(KEEPER_ROLE) {
        //solhint-disable-next-line
        (bool success, bytes memory result) = oneInch.call(payload);
        if (!success) _revertBytes(result);

        uint256 amountOut = abi.decode(result, (uint256));
        if (amountOut < minAmountOut) revert TooSmallAmount();
    }

    /// @notice Internal function used for error handling
    function _revertBytes(bytes memory errMsg) internal pure {
        if (errMsg.length > 0) {
            //solhint-disable-next-line
            assembly {
                revert(add(32, errMsg), mload(errMsg))
            }
        }
        revert ErrorSwap();
    }
}
