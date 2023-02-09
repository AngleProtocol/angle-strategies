// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.12;

import "../BaseTest.test.sol";
import { PoolManager, IStrategy } from "../../../contracts/mock/MockPoolManager2.sol";
import { OptimizerAPRStrategy, LendStatus } from "../../../contracts/strategies/OptimizerAPR/OptimizerAPRStrategy.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract OptimizerAPRUpgradeTest is BaseTest {
    using stdStorage for StdStorage;

    uint256 internal constant _BASE_TOKEN = 10**18;
    uint256 internal constant _BASE_APR = 10**18;
    uint64 internal constant _BPS = 10**4;
    address public constant KEEPER_MULTICALL = 0xa0062b7A5e494d569059E2f1A98B5f6C99BFAAfe;
    address public constant KEEPER = 0xcC617C6f9725eACC993ac626C7efC6B96476916E;
    address public constant PROXY_ADMIN = 0x1D941EF0D3Bba4ad67DBfBCeE5262F4CEE53A32b;

    /// @notice Role for `PoolManager` only - keccak256("POOLMANAGER_ROLE")
    bytes32 public constant POOLMANAGER_ROLE = 0x5916f72c85af4ac6f7e34636ecc97619c4b2085da099a5d28f3e58436cfbe562;
    /// @notice Role for guardians and governors - keccak256("GUARDIAN_ROLE")
    bytes32 public constant GUARDIAN_ROLE = 0x55435dd261a4b9b3364963f7738a7a662ad9c84396d64be3365284bb7f0a5041;
    /// @notice Role for keepers - keccak256("KEEPER_ROLE")
    bytes32 public constant KEEPER_ROLE = 0xfc8737ab85eb45125971625a9ebdb75cc78e01d5c1fa80c4c6e5203f47bc4fab;
    IERC20 public token = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    PoolManager public manager = PoolManager(0xe9f183FC656656f1F17af1F2b0dF79b8fF9ad8eD);
    OptimizerAPRStrategy internal _strat = OptimizerAPRStrategy(0xBfa4459868C60da9edd835F0be684EDeC054557b);
    OptimizerAPRStrategy internal _oldStratimpl = OptimizerAPRStrategy(0xa693aBabF230397B3e6385ff7eE09607f562af8c);

    uint256 public marginAmount;
    uint8 internal constant _decimalToken = 6;
    OptimizerAPRStrategy public newStratImpl;

    function setUp() public override {
        super.setUp();

        _ethereum = vm.createFork(vm.envString("ETH_NODE_URI_ETH_FOUNDRY"), 16586662);
        vm.selectFork(_ethereum);

        address[] memory keeperList = new address[](1);
        address[] memory governorList = new address[](1);
        keeperList[0] = _KEEPER;
        governorList[0] = _GOVERNOR;

        newStratImpl = new OptimizerAPRStrategy();
    }

    // =============================== MIGRATE FUNDS ===============================

    function testUpgrade() public {
        _checksProxy(_strat);

        vm.startPrank(PROXY_ADMIN);
        TransparentUpgradeableProxy(payable(address(_strat))).upgradeTo(address(newStratImpl));
        vm.stopPrank();

        _checksProxy(_strat);
    }

    function _checksProxy(OptimizerAPRStrategy strat) public {
        assertEq(address(strat.poolManager()), address(manager));
        assertEq(address(strat.want()), address(token));
        assertEq(strat.wantBase(), 10**_decimalToken);
        assertEq(strat.debtThreshold(), 100 * 10**18);
        assertEq(strat.withdrawalThreshold(), 1000 * 10**_decimalToken);
        assertFalse(strat.emergencyExit());
        assertEq(strat.lentTotalAssets(), 0);
        assertEq(strat.estimatedTotalAssets(), 0);
        assertEq(strat.numLenders(), 0);
        assertEq(strat.estimatedAPR(), 0);
        // LendStatus[] memory status = strat.lendStatuses();
        // assertEq(status[0].name, "Compound Lender USDC v2");
        // assertEq(status[1].name, "Aave Lender USDC v2");
        // assertEq(status[2].name, "Euler Staker Lender USDC");
        // assertEq(status[0].assets, 0);
        // assertEq(status[1].assets, 0);
        // assertEq(status[2].assets, 0);
        // assertGt(status[0].rate, 0);
        // assertGt(status[1].rate, 0);
        // assertGt(status[2].rate, 0);
        assertTrue(strat.hasRole(GUARDIAN_ROLE, _GUARDIAN));
        assertTrue(strat.hasRole(GUARDIAN_ROLE, _GOVERNOR));
        assertTrue(strat.hasRole(POOLMANAGER_ROLE, address(manager)));
        assertTrue(strat.hasRole(KEEPER_ROLE, KEEPER));
        assertTrue(strat.hasRole(KEEPER_ROLE, KEEPER_MULTICALL));
        assertEq(strat.getRoleAdmin(GUARDIAN_ROLE), POOLMANAGER_ROLE);
        assertEq(strat.getRoleAdmin(POOLMANAGER_ROLE), POOLMANAGER_ROLE);
        assertEq(strat.getRoleAdmin(KEEPER_ROLE), GUARDIAN_ROLE);
        assertEq(token.allowance(address(strat), address(manager)), type(uint256).max);

        // dummy test
        assertFalse(strat.hasRole(GUARDIAN_ROLE, address(manager)));
    }
}
