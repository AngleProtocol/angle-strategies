// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.17;

import "../BaseTest.test.sol";
import { CErc20I, CTokenI } from "../../../contracts/interfaces/external/compound/CErc20I.sol";
import { IComptroller } from "../../../contracts/interfaces/external/compound/IComptroller.sol";
import { PoolManager, IStrategy } from "../../../contracts/mock/MockPoolManager2.sol";
import { OptimizerAPRStrategy } from "../../../contracts/strategies/OptimizerAPR/OptimizerAPRStrategy.sol";
import { OptimizerAPRGreedyStrategy } from "../../../contracts/strategies/OptimizerAPR/OptimizerAPRGreedyStrategy.sol";
import { GenericAaveNoStaker, IERC20, IERC20Metadata, IGenericLender } from "../../../contracts/strategies/OptimizerAPR/genericLender/aave/GenericAaveNoStaker.sol";
import { GenericCompoundUpgradeable } from "../../../contracts/strategies/OptimizerAPR/genericLender/compound/GenericCompoundUpgradeable.sol";
import { GenericEulerStaker, IEulerStakingRewards, IEuler, IEulerEToken, IEulerDToken, IGenericLender, AggregatorV3Interface, IUniswapV3Pool } from "../../../contracts/strategies/OptimizerAPR/genericLender/euler/GenericEulerStaker.sol";

contract OptimizerAPRStrategyForkTest is BaseTest {
    using stdStorage for StdStorage;

    uint256 internal constant _BASE_TOKEN = 10**18;
    uint256 internal constant _BASE_APR = 10**18;
    uint64 internal constant _BPS = 10**4;
    IERC20 public token = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    PoolManager public manager = PoolManager(0xe9f183FC656656f1F17af1F2b0dF79b8fF9ad8eD);
    OptimizerAPRGreedyStrategy internal _oldStrat =
        OptimizerAPRGreedyStrategy(0x5fE0E497Ac676d8bA78598FC8016EBC1E6cE14a3);
    GenericAaveNoStaker internal _oldLenderAave = GenericAaveNoStaker(0xbe67bb1aa7baCFC5D40d963D47E11e3d382a56Bd);
    GenericCompoundUpgradeable internal _oldLenderCompound =
        GenericCompoundUpgradeable(payable(0x6D7cCd6d3E4948579891f90e98C1bb09a8c677ea));

    IComptroller internal constant _COMPTROLLER = IComptroller(0x3d9819210A31b4961b30EF54bE2aeD79B9c9Cd3B);
    IERC20 internal constant _COMP = IERC20(0xc00e94Cb662C3520282E6f5717214004A7f26888);
    CErc20I internal _cUSDC = CErc20I(0x39AA39c021dfbaE8faC545936693aC917d5E7563);
    // solhint-disable-next-line
    IERC20 private constant _aave = IERC20(0x7Fc66500c84A76Ad7e9c93437bFc5Ac33E2DDaE9);
    // solhint-disable-next-line
    IERC20 private constant _stkAave = IERC20(0x4da27a545c0c5B758a6BA100e3a049001de870f5);
    IEulerStakingRewards internal constant _STAKER = IEulerStakingRewards(0xE5aFE81e63f0A52a3a03B922b30f73B8ce74D570);
    IEuler private constant _EULER = IEuler(0x27182842E098f60e3D576794A5bFFb0777E025d3);
    IEulerEToken internal constant _EUSDC = IEulerEToken(0xEb91861f8A4e1C12333F42DCE8fB0Ecdc28dA716);
    IEulerDToken internal constant _DUSDC = IEulerDToken(0x84721A3dB22EB852233AEAE74f9bC8477F8bcc42);
    IUniswapV3Pool private constant _POOL = IUniswapV3Pool(0xB003DF4B243f938132e8CAdBEB237AbC5A889FB4);
    uint8 private constant _IS_UNI_MULTIPLIED = 0;
    AggregatorV3Interface private constant _CHAINLINK =
        AggregatorV3Interface(0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419);
    uint256 internal constant _PROP_INVESTED = 95 * 10**7;

    uint256 public maxTokenAmount;
    uint256 public minTokenAmount;
    uint256 public marginAmount;
    uint8 internal _decimalToken;
    OptimizerAPRStrategy public stratImplementation;
    OptimizerAPRStrategy public strat;
    GenericCompoundUpgradeable public lenderCompoundImplementation;
    GenericCompoundUpgradeable public lenderCompound;
    GenericAaveNoStaker public lenderAaveImplementation;
    GenericAaveNoStaker public lenderAave;
    GenericEulerStaker public lenderEulerImplementation;
    GenericEulerStaker public lenderEuler;

    uint256 public constant BACKTEST_LENGTH = 30;
    uint256 public constant IMPROVE_LENGTH = 2;

    function setUp() public override {
        super.setUp();

        _ethereum = vm.createFork(vm.envString("ETH_NODE_URI_ETH_FOUNDRY"), 16420445);
        vm.selectFork(_ethereum);

        _decimalToken = IERC20Metadata(address(token)).decimals();
        maxTokenAmount = 10**(_decimalToken + 6);
        minTokenAmount = 10**(_decimalToken - 1);
        marginAmount = 10**(_decimalToken + 1);

        address[] memory keeperList = new address[](1);
        address[] memory governorList = new address[](1);
        keeperList[0] = _KEEPER;
        governorList[0] = _GOVERNOR;

        stratImplementation = new OptimizerAPRStrategy();
        strat = OptimizerAPRStrategy(
            deployUpgradeable(
                address(stratImplementation),
                abi.encodeWithSelector(strat.initialize.selector, address(manager), _GOVERNOR, _GUARDIAN, keeperList)
            )
        );

        lenderCompoundImplementation = new GenericCompoundUpgradeable();
        lenderCompound = GenericCompoundUpgradeable(
            payable(
                deployUpgradeable(
                    address(lenderCompoundImplementation),
                    abi.encodeWithSelector(
                        lenderCompoundImplementation.initialize.selector,
                        address(strat),
                        "lender Compound",
                        address(_cUSDC),
                        governorList,
                        _GUARDIAN,
                        keeperList,
                        _1INCH_V5
                    )
                )
            )
        );
        lenderAaveImplementation = new GenericAaveNoStaker();
        lenderAave = GenericAaveNoStaker(
            deployUpgradeable(
                address(lenderAaveImplementation),
                abi.encodeWithSelector(
                    lenderAaveImplementation.initialize.selector,
                    address(strat),
                    "lender Aave",
                    false,
                    governorList,
                    _GUARDIAN,
                    keeperList,
                    _1INCH_V5
                )
            )
        );
        lenderEulerImplementation = new GenericEulerStaker();
        lenderEuler = GenericEulerStaker(
            deployUpgradeable(
                address(lenderEulerImplementation),
                abi.encodeWithSelector(
                    lenderEulerImplementation.initialize.selector,
                    address(strat),
                    "lender Euler",
                    governorList,
                    _GUARDIAN,
                    keeperList,
                    _1INCH_V5,
                    _STAKER,
                    _CHAINLINK,
                    _POOL,
                    _IS_UNI_MULTIPLIED
                )
            )
        );

        vm.startPrank(_GOVERNOR);
        strat.addLender(IGenericLender(address(lenderCompound)));
        strat.addLender(IGenericLender(address(lenderAave)));
        strat.addLender(IGenericLender(address(lenderEuler)));
        manager.updateStrategyDebtRatio(address(_oldStrat), 0);
        manager.addStrategy(address(strat), _PROP_INVESTED);
        vm.stopPrank();
    }

    // =============================== MIGRATE FUNDS ===============================

    function testMigrationFundsSuccess() public {
        {
            // do a claimComp first and sell the rewards
            address[] memory holders = new address[](1);
            CTokenI[] memory cTokens = new CTokenI[](1);
            holders[0] = address(_oldLenderCompound);
            cTokens[0] = CTokenI(address(_cUSDC));
            _COMPTROLLER.claimComp(holders, cTokens, true, true);
            uint256 compReward = _COMP.balanceOf(address(_oldLenderCompound));
            console.log("compReward ", compReward);
            vm.prank(0xcC617C6f9725eACC993ac626C7efC6B96476916E);
            // TODO when selling simulate back at current block how many rewards we received
            _oldLenderCompound.sellRewards(
                0,
                hex"7c02520000000000000000000000000053222470cdcfb8081c0e3a50fd106f0d69e63f2000000000000000000000000000000000000000000000000000000000000000600000000000000000000000000000000000000000000000000000000000000180000000000000000000000000c00e94cb662c3520282e6f5717214004a7f26888000000000000000000000000a0b86991c6218b36c1d19d4a2e9eb0ce3606eb4800000000000000000000000053222470cdcfb8081c0e3a50fd106f0d69e63f200000000000000000000000006d7ccd6d3e4948579891f90e98c1bb09a8c677ea000000000000000000000000000000000000000000000003fd86cc0b67bf0e1000000000000000000000000000000000000000000000000000000000e14eae3900000000000000000000000000000000000000000000000000000000000000040000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000003f90000000000000000000000000000000000000000000000000003bb00038d00a0860a32ec000000000000000000000000000000000000000000000003fd86cc0b67bf0e100003645520080bf510fcbf18b91105470639e9561022937712c00e94cb662c3520282e6f5717214004a7f2688895e6f48254609a6ee006f7d493c8e5fb97094cef0024b4be83d50000000000000000000000000000000000000000000000000000000000000060000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000002a000000000000000000000000056178a0d5f301baf6cf3e1cd53d9863437345bf900000000000000000000000053222470cdcfb8081c0e3a50fd106f0d69e63f2000000000000000000000000055662e225a3376759c24331a9aed764f8f0c9fbb000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000e3848506000000000000000000000000000000000000000000000003fd86cc0b67bf0e10000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000063c5773401ffffffffffffffffffffffffffffffffffffff3862771d63c576bc00000026000000000000000000000000000000000000000000000000000000000000018000000000000000000000000000000000000000000000000000000000000001e00000000000000000000000000000000000000000000000000000000000000024f47261b0000000000000000000000000a0b86991c6218b36c1d19d4a2e9eb0ce3606eb48000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000024f47261b0000000000000000000000000c00e94cb662c3520282e6f5717214004a7f268880000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000421bae301d9fe2af6c418cfff3f37a9cd0d52af754376421faedd5754993b730b6ab563cbb70cd4b6dde036dca82d2bab83eecc82dd700d5e256d65d008f937fe7ed0300000000000000000000000000000000000000000000000000000000000080a06c4eca27a0b86991c6218b36c1d19d4a2e9eb0ce3606eb481111111254fb6c44bac0bed2854e76f90643097d000000000000000000000000000000000000000000000003fd86cc0b67bf0e1000000000000000cfee7c08"
            );

            // do a claimRewards first and sell the rewards
            vm.prank(0xcC617C6f9725eACC993ac626C7efC6B96476916E);
            _oldLenderAave.claimRewards();
            // there shouldn't be any
            uint256 stkAaveOldLender = _stkAave.balanceOf(address(_oldLenderAave));
            uint256 aaveOldLender = _aave.balanceOf(address(_oldLenderAave));
            assertEq(stkAaveOldLender, 0);
            assertEq(aaveOldLender, 0);
        }
        // Update the rate so that we have the true rate and we don't underestimate the rate on chain
        _cUSDC.accrueInterest();
        // remove funds from previous strat
        vm.startPrank(_GOVERNOR);
        // It would have been more efficient but it doesn't account for profits
        // _oldStrat.safeRemoveLender(address(_oldLenderAave));
        // _oldStrat.forceRemoveLender(address(_oldLenderCompound));
        _oldStrat.harvest();
        manager.withdrawFromStrategy(IStrategy(address(_oldStrat)), token.balanceOf(address(_oldStrat)));
        vm.stopPrank();

        // There shouldn't be any funds left on the old strat
        assertEq(token.balanceOf(address(_oldLenderCompound)), 0);
        assertApproxEqAbs(_cUSDC.balanceOf(address(_oldLenderCompound)), 0, 10**_decimalToken);
        assertEq(_oldLenderCompound.nav(), 0);
        assertEq(token.balanceOf(address(_oldLenderAave)), 0);
        assertEq(_oldLenderAave.nav(), 0);
        assertEq(token.balanceOf(address(_oldStrat)), 0);
        assertEq(_oldStrat.estimatedTotalAssets(), 0);
        assertEq(_oldStrat.lentTotalAssets(), 0);

        // Then we add the new strategy
        uint64[] memory lenderShares = new uint64[](3);
        lenderShares[0] = (_BPS * 2) / 5;
        lenderShares[2] = (_BPS * 3) / 5;
        strat.harvest(abi.encode(lenderShares));
        uint256 totalAssetsInvested = (manager.getTotalAsset() * _PROP_INVESTED) / 10**9;
        assertApproxEqAbs(lenderCompound.nav(), (totalAssetsInvested * lenderShares[0]) / _BPS, marginAmount);
        assertApproxEqAbs(lenderEuler.nav(), (totalAssetsInvested * lenderShares[2]) / _BPS, marginAmount);
        assertApproxEqAbs(lenderAave.nav(), (totalAssetsInvested * lenderShares[1]) / _BPS, marginAmount);
        assertApproxEqAbs(strat.estimatedTotalAssets(), totalAssetsInvested, marginAmount);

        console.log("strat apr ", strat.estimatedAPR());
        console.log("compound apr ", lenderCompound.apr());
        console.log("aave apr ", lenderAave.apr());
        console.log("euler apr ", lenderEuler.apr());
    }

    // // ============================== DEPOSIT/WITHDRAW =============================

    // function testDepositAllSplitIn3Success(uint256 amount, uint256[3] memory borrows) public {
    //     amount = bound(amount, 1, maxTokenAmount);
    //     borrows[0] = bound(borrows[0], 1, amount);
    //     borrows[1] = bound(borrows[1], 1, amount);
    //     borrows[2] = bound(borrows[2], 1, amount);

    //     // MockLender[3] memory listLender = [lender1, lender2, lender3];
    //     lender1.setLenderPoolVariables(_BASE_APR / 100, _BASE_APR, borrows[0], 0);
    //     lender2.setLenderPoolVariables(_BASE_APR / 100, _BASE_APR, borrows[0], 0);
    //     lender3.setLenderPoolVariables(_BASE_APR / 100, _BASE_APR, borrows[0], 0);

    //     deal(address(token), address(manager), 4 * amount);
    //     uint64[] memory lenderShares = new uint64[](3);
    //     lenderShares[0] = _BPS / 2;
    //     lenderShares[1] = _BPS / 4;
    //     lenderShares[2] = _BPS / 4;
    //     strat.harvest(abi.encode(lenderShares));
    //     {
    //         uint256 estimatedAPRHalf = _computeAPY(2 * amount, borrows[0], _BASE_APR / 100, _BASE_APR, 0);
    //         uint256 estimatedAPRFourth = _computeAPY(amount, borrows[0], _BASE_APR / 100, _BASE_APR, 0);
    //         uint256 estimatedAPRGlobal = (estimatedAPRHalf + estimatedAPRFourth) / 2;
    //         assertEq(lender1.nav(), 2 * amount);
    //         assertEq(lender2.nav(), amount);
    //         assertEq(lender3.nav(), amount);
    //         assertEq(lender1.apr(), estimatedAPRHalf);
    //         assertEq(lender2.apr(), estimatedAPRFourth);
    //         assertEq(lender3.apr(), estimatedAPRFourth);
    //         assertEq(strat.estimatedTotalAssets(), 4 * amount);
    //         assertEq(strat.estimatedAPR(), estimatedAPRGlobal);
    //     }
    // }

    // function testHarvest2SharesWithLossSuccess(uint256[5] memory amounts, uint256[3] memory borrows) public {
    //     amounts[0] = bound(amounts[0], 1, maxTokenAmount);
    //     amounts[1] = bound(amounts[1], 1, maxTokenAmount);
    //     amounts[2] = bound(amounts[2], 1, maxTokenAmount);
    //     // Because in this special case my best estimate won't be better than the greedy, because the distribution
    //     // will be closer to te true optimum. This is just by chance for the greedy and the fuzzing is "searching for that chance"
    //     uint256 sumAmounts = (amounts[0] + amounts[1] + amounts[2]);

    //     borrows[0] = bound(borrows[0], 1, amounts[0]);
    //     borrows[1] = bound(borrows[1], 1, amounts[1]);
    //     borrows[2] = sumAmounts;

    //     lender1.setLenderPoolVariables(0, 0, borrows[0], 0);
    //     lender2.setLenderPoolVariables(0, 0, borrows[0], 0);
    //     lender3.setLenderPoolVariables(_BASE_APR / 100, _BASE_APR, borrows[0], 0);

    //     deal(address(token), address(manager), 4 * amounts[0]);
    //     strat.harvest();
    //     // to not withdraw what has been put on lender1 previously (because _potential is lower than highest)
    //     lender3.setLenderPoolVariables(_BASE_APR / 100, _BASE_APR + 1, borrows[0], 0);
    //     deal(address(token), address(manager), 4 * amounts[1]);
    //     strat.harvest();
    //     // make loss or gain on lenders
    //     // on lender1
    //     {
    //         int256 delta1 = _makeLossGainLender(lender1, amounts[3]);
    //         int256 delta2 = _makeLossGainLender(lender2, amounts[4]);
    //         sumAmounts = uint256(int256(4 * sumAmounts) + delta1 + delta2);

    //         // Because in this special case my best estimate won't be better than the greedy, because the distribution
    //         // will be closer to te true optimum. This is just by chance for the greedy and the fuzzing is "searching for that chance"
    //         if (
    //             ((uint256(int256(4 * amounts[0]) + delta1)) * _BPS) / sumAmounts > _BPS / 4 ||
    //             ((uint256(int256(4 * amounts[0]) + delta1)) * _BPS) / sumAmounts < (_BPS * 44) / 100
    //         ) return;

    //         // sumAmounts *= 4;
    //     }

    //     deal(address(token), address(manager), 4 * amounts[2]);
    //     lender1.setLenderPoolVariables(0, 0, borrows[2], 0);
    //     lender2.setLenderPoolVariables(_BASE_APR / 100, _BASE_APR, borrows[2], sumAmounts);
    //     lender3.setLenderPoolVariables(_BASE_APR / 100, _BASE_APR, borrows[2], 2 * sumAmounts);
    //     uint64[] memory lenderShares = new uint64[](3);
    //     lenderShares[1] = (_BPS * 3) / 4;
    //     lenderShares[2] = _BPS / 4;
    //     {
    //         uint256 estimatedAPRHintLender2 = _computeAPY(
    //             (sumAmounts * lenderShares[1]) / _BPS,
    //             borrows[2],
    //             _BASE_APR / 100,
    //             _BASE_APR,
    //             sumAmounts
    //         );

    //         uint256 estimatedAPRHintLender3 = _computeAPY(
    //             (sumAmounts * lenderShares[2]) / _BPS,
    //             borrows[2],
    //             _BASE_APR / 100,
    //             _BASE_APR,
    //             2 * sumAmounts
    //         );

    //         uint256 estimatedAPRHint = (sumAmounts *
    //             lenderShares[1] *
    //             estimatedAPRHintLender2 +
    //             sumAmounts *
    //             lenderShares[3] *
    //             estimatedAPRHintLender3) / (_BPS * sumAmounts);
    //         assertEq(lender1.nav(), 0);
    //         assertEq(lender2.nav(), (sumAmounts * lenderShares[1]) / _BPS);
    //         assertEq(lender3.nav(), (sumAmounts * lenderShares[2]) / _BPS);
    //         assertEq(lender1.apr(), 0);
    //         assertEq(lender2.apr(), estimatedAPRHintLender2);
    //         assertEq(lender3.apr(), estimatedAPRHintLender3);
    //         assertEq(strat.estimatedTotalAssets(), sumAmounts);
    //         assertEq(strat.estimatedAPR(), estimatedAPRHint);
    //     }
    // }
}
