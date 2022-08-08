// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.12;

import "../interfaces/ICoreBorrow.sol";

/// @title AngleRegistry
/// @author Angle Core Team
/// @notice Registry controlled by the Angle DAO of `marketId` associated to specific quote and base token pairs
/// for the Marketplace contract
contract AngleRegistry {
    /// @notice CoreBorrow contract which stores access control rights on the protocol
    ICoreBorrow public coreBorrow;
    /// @notice Mapping between a quote token, a base token and an associated marketId
    mapping(address => mapping(address => bytes32)) public registry;

    error NotGovernorOrGuardian();
    error ZeroAddress();

    constructor(ICoreBorrow _coreBorrow) {
        if (address(_coreBorrow) == address(0)) revert ZeroAddress();
        coreBorrow = _coreBorrow;
    }

    /// @notice Gets the marketId associated to the `quoteToken`, `baseToken` pair considered as "official"
    /// by the Angle DAO
    function getMarketId(address quoteToken, address baseToken) external view returns (bytes32) {
        return registry[quoteToken][baseToken];
    }

    /// @notice Writes a new entry in the registry
    /// @dev Only a guardian or governor address of the protocol can call this function
    function setRegistryEntry(
        address quoteToken,
        address baseToken,
        bytes32 marketId
    ) external {
        if (coreBorrow.isGovernorOrGuardian(msg.sender)) revert NotGovernorOrGuardian();
        registry[quoteToken][baseToken] = marketId;
    }
}
