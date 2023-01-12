// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.17;

import "../BaseTest.test.sol";
import { PoolManager } from "../../../contracts/mock/MockPoolManager2.sol";
import { OptimizerAPRStrategy } from "../../../contracts/strategies/OptimizerAPR/OptimizerAPRStrategy.sol";
import { MockLender, IERC20, IGenericLender } from "../../../contracts/mock/MockLender.sol";
import { MockToken } from "../../../contracts/mock/MockToken.sol";

contract OptimizerAPRStrategyTest is BaseTest {
    using stdStorage for StdStorage;

    address internal _hacker = address(uint160(uint256(keccak256(abi.encodePacked("hacker")))));

    uint256 internal constant _BASE_TOKEN = 10**18;
    uint256 internal constant _BASE_APR = 10**18;
    uint64 internal constant _BPS = 10**4;
    uint8 internal constant _DECIMAL_TOKEN = 6;
    MockToken public token;
    PoolManager public manager;
    OptimizerAPRStrategy public stratImplementation;
    OptimizerAPRStrategy public strat;
    MockLender public lenderImplementation;
    MockLender public lender1;
    MockLender public lender2;
    MockLender public lender3;
    // just to test the old features
    PoolManager public managerTmp;
    OptimizerAPRStrategy public stratTmp;
    MockLender public lenderTmp1;
    MockLender public lenderTmp2;
    MockLender public lenderTmp3;
    uint256 public maxTokenAmount = 10**(_DECIMAL_TOKEN + 6);
    uint256 public minTokenAmount = 10**(_DECIMAL_TOKEN - 1);

    uint256 public constant BACKTEST_LENGTH = 30;
    uint256 public constant IMPROVE_LENGTH = 2;
    uint256 public constant WITHDRAW_LENGTH = 30;
    uint256 public constant REWARDS_LENGTH = 30;

    function setUp() public override {
        super.setUp();

        address[] memory keeperList = new address[](1);
        address[] memory governorList = new address[](1);
        keeperList[0] = _KEEPER;
        governorList[0] = _GOVERNOR;

        token = new MockToken("token", "token", _DECIMAL_TOKEN);
        manager = new PoolManager(address(token), _GOVERNOR, _GUARDIAN);
        stratImplementation = new OptimizerAPRStrategy();
        strat = OptimizerAPRStrategy(
            deployUpgradeable(
                address(stratImplementation),
                abi.encodeWithSelector(strat.initialize.selector, address(manager), _GOVERNOR, _GUARDIAN, keeperList)
            )
        );
        vm.prank(_GOVERNOR);
        manager.addStrategy(address(strat), 10**9);

        lenderImplementation = new MockLender();
        lender1 = MockLender(
            deployUpgradeable(
                address(lenderImplementation),
                abi.encodeWithSelector(
                    lender1.initialize.selector,
                    address(strat),
                    "lender 1",
                    governorList,
                    _GUARDIAN,
                    keeperList
                )
            )
        );
        lender2 = MockLender(
            deployUpgradeable(
                address(lenderImplementation),
                abi.encodeWithSelector(
                    lender1.initialize.selector,
                    address(strat),
                    "lender 2",
                    governorList,
                    _GUARDIAN,
                    keeperList
                )
            )
        );
        lender3 = MockLender(
            deployUpgradeable(
                address(lenderImplementation),
                abi.encodeWithSelector(
                    lender1.initialize.selector,
                    address(strat),
                    "lender 3",
                    governorList,
                    _GUARDIAN,
                    keeperList
                )
            )
        );

        vm.startPrank(_GOVERNOR);
        strat.addLender(IGenericLender(address(lender1)));
        strat.addLender(IGenericLender(address(lender2)));
        strat.addLender(IGenericLender(address(lender3)));

        managerTmp = new PoolManager(address(token), _GOVERNOR, _GUARDIAN);
        stratTmp = OptimizerAPRStrategy(
            deployUpgradeable(
                address(stratImplementation),
                abi.encodeWithSelector(strat.initialize.selector, address(managerTmp), _GOVERNOR, _GUARDIAN, keeperList)
            )
        );

        managerTmp.addStrategy(address(stratTmp), 10**9);
        lenderTmp1 = MockLender(
            deployUpgradeable(
                address(lenderImplementation),
                abi.encodeWithSelector(
                    lenderTmp1.initialize.selector,
                    address(stratTmp),
                    "lendertmp 1",
                    governorList,
                    _GUARDIAN,
                    keeperList
                )
            )
        );
        lenderTmp2 = MockLender(
            deployUpgradeable(
                address(lenderImplementation),
                abi.encodeWithSelector(
                    lenderTmp2.initialize.selector,
                    address(stratTmp),
                    "lenderTmp 2",
                    governorList,
                    _GUARDIAN,
                    keeperList
                )
            )
        );
        lenderTmp3 = MockLender(
            deployUpgradeable(
                address(lenderImplementation),
                abi.encodeWithSelector(
                    lenderTmp3.initialize.selector,
                    address(stratTmp),
                    "lenderTmp 3",
                    governorList,
                    _GUARDIAN,
                    keeperList
                )
            )
        );
        stratTmp.addLender(IGenericLender(address(lenderTmp1)));
        stratTmp.addLender(IGenericLender(address(lenderTmp2)));
        stratTmp.addLender(IGenericLender(address(lenderTmp3)));
        vm.stopPrank();
    }

    // ======================= BACKTEST PREVIOUS OPTIMIZERAPR ======================
    function testStabilityPreviouOptimizerSuccess(
        uint256[BACKTEST_LENGTH] memory amounts,
        uint256[BACKTEST_LENGTH] memory isWithdraw,
        uint32[3 * 3 * BACKTEST_LENGTH] memory paramsLender,
        uint64[BACKTEST_LENGTH] memory elapseTime
    ) public {
        for (uint256 i = 0; i < amounts.length; ++i) {
            MockLender[3] memory listLender = [lender1, lender2, lender3];
            MockLender[3] memory listLenderTmp = [lenderTmp1, lenderTmp2, lenderTmp3];
            for (uint256 k = 0; k < listLender.length; ++k) {
                listLender[k].setLenderPoolVariables(
                    paramsLender[i * 9 + k * 3],
                    paramsLender[i * 9 + k * 3 + 1],
                    paramsLender[i * 9 + k * 3 + 2]
                );
                listLenderTmp[k].setLenderPoolVariables(
                    paramsLender[i * 9 + k * 3],
                    paramsLender[i * 9 + k * 3 + 1],
                    paramsLender[i * 9 + k * 3 + 2]
                );
            }
            if (
                (isWithdraw[i] == 1 && lender1.nav() == 0) ||
                (isWithdraw[i] == 2 && lender2.nav() == 0) ||
                (isWithdraw[i] == 3 && lender3.nav() == 0)
            ) isWithdraw[i] = 0;
            if (isWithdraw[i] == 0) {
                uint256 amount = bound(amounts[i], minTokenAmount, maxTokenAmount);
                deal(address(token), address(manager), amount);
                deal(address(token), address(managerTmp), amount);
            } else if (isWithdraw[i] == 1) {
                uint256 amount = bound(amounts[i], 0, _BASE_TOKEN);
                uint256 toBurn = (amount * lender1.nav()) / _BASE_TOKEN;
                token.burn(address(lender1), toBurn);
                token.burn(address(lenderTmp1), toBurn);
            } else if (isWithdraw[i] == 2) {
                uint256 amount = bound(amounts[i], 0, _BASE_TOKEN);
                uint256 toBurn = (amount * lender2.nav()) / _BASE_TOKEN;
                token.burn(address(lender2), toBurn);
                token.burn(address(lenderTmp2), toBurn);
            } else if (isWithdraw[i] == 3) {
                uint256 amount = bound(amounts[i], 0, _BASE_TOKEN);
                uint256 toBurn = (amount * lender3.nav()) / _BASE_TOKEN;
                token.burn(address(lender3), toBurn);
                token.burn(address(lenderTmp3), toBurn);
            }
            strat.harvest();
            stratTmp.harvest();
            // advance in time for rewards to be taken into account
            elapseTime[i] = uint64(bound(elapseTime[i], 1, 86400 * 7));
            elapseTime[i] = 86400 * 14;
            vm.warp(block.timestamp + elapseTime[i]);
            {
                assertEq(lender1.nav(), lenderTmp1.nav());
                assertEq(lender2.nav(), lenderTmp2.nav());
                assertEq(lender3.nav(), lenderTmp3.nav());
                assertEq(lender1.apr(), lenderTmp1.apr());
                assertEq(lender2.apr(), lenderTmp2.apr());
                assertEq(lender3.apr(), lenderTmp3.apr());
                assertEq(strat.estimatedTotalAssets(), stratTmp.estimatedTotalAssets());
                assertEq(strat.estimatedAPR(), stratTmp.estimatedAPR());
            }
        }
    }

    // function testImprovementPreviouOptimizerSuccess(
    //     uint256[IMPROVE_LENGTH] memory amounts,
    //     uint256[IMPROVE_LENGTH] memory isWithdraw,
    //     uint32[3 * 3 * IMPROVE_LENGTH] memory paramsLender,
    //     uint64[IMPROVE_LENGTH] memory elapseTime
    // ) public {
    //     for (uint256 i = 0; i < amounts.length; ++i) {
    //         MockLender[3] memory listLender = [lender1, lender2, lender3];
    //         MockLender[3] memory listLenderTmp = [lenderTmp1, lenderTmp2, lenderTmp3];
    //         for (uint256 k = 0; k < listLender.length; ++k) {
    //             listLender[k].setLenderPoolVariables(
    //                 paramsLender[i * 9 + k * 3],
    //                 paramsLender[i * 9 + k * 3 + 1],
    //                 paramsLender[i * 9 + k * 3 + 2]
    //             );
    //             listLenderTmp[k].setLenderPoolVariables(
    //                 paramsLender[i * 9 + k * 3],
    //                 paramsLender[i * 9 + k * 3 + 1],
    //                 paramsLender[i * 9 + k * 3 + 2]
    //             );
    //         }
    //         if (
    //             (isWithdraw[i] == 1 && lender1.nav() == 0) ||
    //             (isWithdraw[i] == 2 && lender2.nav() == 0) ||
    //             (isWithdraw[i] == 3 && lender3.nav() == 0)
    //         ) isWithdraw[i] = 0;
    //         if (isWithdraw[i] == 0) {
    //             uint256 amount = bound(amounts[i], minTokenAmount, maxTokenAmount);
    //             deal(address(token), address(manager), amount);
    //             deal(address(token), address(managerTmp), amount);
    //         } else if (isWithdraw[i] == 1) {
    //             uint256 amount = bound(amounts[i], 0, _BASE_TOKEN);
    //             uint256 toBurn = (amount * lender1.nav()) / _BASE_TOKEN;
    //             token.burn(address(lender1), toBurn);
    //             token.burn(address(lenderTmp1), toBurn);
    //         } else if (isWithdraw[i] == 2) {
    //             uint256 amount = bound(amounts[i], 0, _BASE_TOKEN);
    //             uint256 toBurn = (amount * lender2.nav()) / _BASE_TOKEN;
    //             token.burn(address(lender2), toBurn);
    //             token.burn(address(lenderTmp2), toBurn);
    //         } else if (isWithdraw[i] == 3) {
    //             uint256 amount = bound(amounts[i], 0, _BASE_TOKEN);
    //             uint256 toBurn = (amount * lender3.nav()) / _BASE_TOKEN;
    //             token.burn(address(lender3), toBurn);
    //             token.burn(address(lenderTmp3), toBurn);
    //         }
    //         strat.harvest();
    //         uint64[] memory lenderShares = new uint64[](3);
    //         lenderShares[0] = 3333;
    //         lenderShares[1] = 3333;
    //         lenderShares[2] = 3334;
    //         stratTmp.harvest(abi.encode(lenderShares));
    //         // advance in time for rewards to be taken into account
    //         elapseTime[i] = uint64(bound(elapseTime[i], 1, 86400 * 7));
    //         elapseTime[i] = 86400 * 14;
    //         vm.warp(block.timestamp + elapseTime[i]);
    //         {
    //             assertLe(lender1.apr(), lenderTmp1.apr());
    //             assertLe(lender2.apr(), lenderTmp2.apr());
    //             assertLe(lender3.apr(), lenderTmp3.apr());
    //             assertLe(strat.estimatedAPR(), stratTmp.estimatedAPR());
    //         }
    //     }
    // }
    // // ================================== DEPOSIT ==================================

    function testDepositAllInOneSuccess(uint256 amount, uint256[3] memory borrows) public {
        amount = bound(amount, 1, maxTokenAmount);
        borrows[0] = bound(borrows[0], 0, amount);
        borrows[1] = bound(borrows[1], 0, amount);
        borrows[2] = bound(borrows[2], 0, amount);

        // MockLender[3] memory listLender = [lender1, lender2, lender3];
        lender1.setLenderPoolVariables(0, _BASE_APR, borrows[0]);
        lender2.setLenderPoolVariables(0, _BASE_APR / 2, borrows[0]);
        lender3.setLenderPoolVariables(0, _BASE_APR / 2, borrows[0]);

        deal(address(token), address(manager), amount);
        uint64[] memory lenderShares = new uint64[](3);
        lenderShares[0] = _BPS;
        lenderShares[1] = 0;
        lenderShares[2] = 0;
        strat.harvest(abi.encode(lenderShares));
        {
            uint256 estimatedAPR = _computeAPY(amount, borrows[0], 0, _BASE_APR);
            assertEq(lender1.nav(), amount);
            assertEq(lender2.nav(), 0);
            assertEq(lender3.nav(), 0);
            assertEq(lender1.apr(), estimatedAPR);
            assertEq(lender2.apr(), 0);
            assertEq(lender3.apr(), 0);
            assertEq(strat.estimatedTotalAssets(), amount);
            assertEq(strat.estimatedAPR(), estimatedAPR);
        }
    }

    function testDepositAllSplitIn2Success(uint256 amount, uint256[3] memory borrows) public {
        amount = bound(amount, 1, maxTokenAmount);
        borrows[0] = bound(borrows[0], 0, amount);
        borrows[1] = bound(borrows[1], 0, amount);
        borrows[2] = bound(borrows[2], 0, amount);

        // MockLender[3] memory listLender = [lender1, lender2, lender3];
        lender1.setLenderPoolVariables(_BASE_APR / 100, _BASE_APR, borrows[0]);
        lender2.setLenderPoolVariables(_BASE_APR / 100, _BASE_APR, borrows[0]);
        lender3.setLenderPoolVariables(0, _BASE_APR / 2, borrows[0]);

        deal(address(token), address(manager), 2 * amount);
        uint64[] memory lenderShares = new uint64[](3);
        lenderShares[0] = _BPS / 2;
        lenderShares[1] = _BPS / 2;
        lenderShares[2] = 0;
        strat.harvest(abi.encode(lenderShares));
        {
            uint256 estimatedAPR = _computeAPY(amount, borrows[0], _BASE_APR / 100, _BASE_APR);
            assertEq(lender1.nav(), amount);
            assertEq(lender2.nav(), amount);
            assertEq(lender3.nav(), 0);
            assertEq(lender1.apr(), estimatedAPR);
            assertEq(lender2.apr(), estimatedAPR);
            assertEq(lender3.apr(), 0);
            assertEq(strat.estimatedTotalAssets(), 2 * amount);
            assertEq(strat.estimatedAPR(), estimatedAPR);
        }
    }

    function testDepositAllSplitIn3Success(uint256 amount, uint256[3] memory borrows) public {
        amount = bound(amount, 1, maxTokenAmount);
        borrows[0] = bound(borrows[0], 0, amount);
        borrows[1] = bound(borrows[1], 0, amount);
        borrows[2] = bound(borrows[2], 0, amount);

        // MockLender[3] memory listLender = [lender1, lender2, lender3];
        lender1.setLenderPoolVariables(_BASE_APR / 100, _BASE_APR, borrows[0]);
        lender2.setLenderPoolVariables(_BASE_APR / 100, _BASE_APR, borrows[0]);
        lender3.setLenderPoolVariables(_BASE_APR / 100, _BASE_APR, borrows[0]);

        deal(address(token), address(manager), 4 * amount);
        uint64[] memory lenderShares = new uint64[](3);
        lenderShares[0] = _BPS / 2;
        lenderShares[1] = _BPS / 4;
        lenderShares[2] = _BPS / 4;
        strat.harvest(abi.encode(lenderShares));
        {
            uint256 estimatedAPRHalf = _computeAPY(2 * amount, borrows[0], _BASE_APR / 100, _BASE_APR);
            uint256 estimatedAPRFourth = _computeAPY(amount, borrows[0], _BASE_APR / 100, _BASE_APR);
            uint256 estimatedAPRGlobal = (estimatedAPRHalf + estimatedAPRFourth) / 2;
            assertEq(lender1.nav(), 2 * amount);
            assertEq(lender2.nav(), amount);
            assertEq(lender3.nav(), amount);
            assertEq(lender1.apr(), estimatedAPRHalf);
            assertEq(lender2.apr(), estimatedAPRFourth);
            assertEq(lender3.apr(), estimatedAPRFourth);
            assertEq(strat.estimatedTotalAssets(), 4 * amount);
            assertEq(strat.estimatedAPR(), estimatedAPRGlobal);
        }
    }

    function testDeposit2HopSuccess(uint256 amount, uint256[3] memory borrows) public {
        amount = bound(amount, 1, maxTokenAmount);
        borrows[0] = bound(borrows[0], 0, amount);
        borrows[1] = bound(borrows[1], 0, amount);
        borrows[2] = bound(borrows[2], 0, amount);

        // MockLender[3] memory listLender = [lender1, lender2, lender3];
        lender1.setLenderPoolVariables(_BASE_APR / 100, _BASE_APR, borrows[0]);
        lender2.setLenderPoolVariables(_BASE_APR / 100, _BASE_APR, borrows[0]);
        lender3.setLenderPoolVariables(_BASE_APR / 100, _BASE_APR, borrows[0]);

        deal(address(token), address(manager), 4 * amount);
        uint64[] memory lenderShares = new uint64[](3);
        lenderShares[0] = _BPS / 2;
        lenderShares[1] = _BPS / 4;
        lenderShares[2] = _BPS / 4;
        strat.harvest(abi.encode(lenderShares));
        {
            uint256 estimatedAPRHalf = _computeAPY(2 * amount, borrows[0], _BASE_APR / 100, _BASE_APR);
            uint256 estimatedAPRFourth = _computeAPY(amount, borrows[0], _BASE_APR / 100, _BASE_APR);
            uint256 estimatedAPRGlobal = (estimatedAPRHalf + estimatedAPRFourth) / 2;
            assertEq(lender1.nav(), 2 * amount);
            assertEq(lender2.nav(), amount);
            assertEq(lender3.nav(), amount);
            assertEq(lender1.apr(), estimatedAPRHalf);
            assertEq(lender2.apr(), estimatedAPRFourth);
            assertEq(lender3.apr(), estimatedAPRFourth);
            assertEq(strat.estimatedTotalAssets(), 4 * amount);
            assertEq(strat.estimatedAPR(), estimatedAPRGlobal);
        }
    }

    // ================================== INTERNAL =================================

    function _computeAPY(
        uint256 supply,
        uint256 borrow,
        uint256 r0,
        uint256 slope1
    ) internal pure returns (uint256) {
        return r0 + (slope1 * borrow) / supply;
    }
}
