// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.12;

import "../interfaces/ICoreBorrow.sol";

/// @title AngleRegistry
/// @author Angle Core Team
contract AngleRegistry {
    ICoreBorrow public coreBorrow;
    mapping(address => mapping(address => bytes32)) public registry;

    error NotGovernorOrGuardian();
    error ZeroAddress();

    constructor(ICoreBorrow _coreBorrow) {
        if (address(_coreBorrow) == address(0)) revert ZeroAddress();
        coreBorrow = _coreBorrow;
    }

    function getMarketId(address quoteToken, address baseToken) external view returns (bytes32) {
        return registry[quoteToken][baseToken];
    }

    function setRegistryEntry(
        address quoteToken,
        address baseToken,
        bytes32 marketId
    ) external {
        if (coreBorrow.isGovernorOrGuardian(msg.sender)) revert NotGovernorOrGuardian();
        registry[quoteToken][baseToken] = marketId;
    }
}
