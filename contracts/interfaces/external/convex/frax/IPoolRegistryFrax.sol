// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.17;

interface IPoolRegistryFrax {
    //clone a new user vault
    function vaultMap(uint256 _pid, address _user) external view returns (address);
}
