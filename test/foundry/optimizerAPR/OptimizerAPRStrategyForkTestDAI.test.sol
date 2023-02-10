// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.12;

import "../BaseTest.test.sol";
import { CErc20I, CTokenI } from "../../../contracts/interfaces/external/compound/CErc20I.sol";
import { IComptroller } from "../../../contracts/interfaces/external/compound/IComptroller.sol";
import { PoolManager, IStrategy } from "../../../contracts/mock/MockPoolManager2.sol";
import { OptimizerAPRStrategy } from "../../../contracts/strategies/OptimizerAPR/OptimizerAPRStrategy.sol";
import { OptimizerAPRGreedyStrategy } from "../../../contracts/strategies/OptimizerAPR/OptimizerAPRGreedyStrategy.sol";
import { GenericAaveNoStaker, IERC20, IERC20Metadata, IGenericLender } from "../../../contracts/strategies/OptimizerAPR/genericLender/aave/GenericAaveNoStaker.sol";
import { GenericCompoundUpgradeable } from "../../../contracts/strategies/OptimizerAPR/genericLender/compound/GenericCompoundUpgradeable.sol";
import { GenericEuler, IEulerStakingRewards, IEuler, IEulerEToken, IEulerDToken, IGenericLender, AggregatorV3Interface } from "../../../contracts/strategies/OptimizerAPR/genericLender/euler/GenericEulerStaker.sol";

contract OptimizerAPRStrategyDAIForkTest is BaseTest {
    using stdStorage for StdStorage;

    uint256 internal constant _BASE_TOKEN = 10**18;
    uint256 internal constant _BASE_APR = 10**18;
    uint64 internal constant _BPS = 10**4;
    IERC20 public token = IERC20(0x6B175474E89094C44Da98b954EedeAC495271d0F);
    PoolManager public manager = PoolManager(0xc9daabC677F3d1301006e723bD21C60be57a5915);
    OptimizerAPRGreedyStrategy internal _oldStrat =
        OptimizerAPRGreedyStrategy(0xFd04BcE2Cd25fC69f30813f0342Bf0C0B5e22461);
    GenericAaveNoStaker internal _oldLenderAave = GenericAaveNoStaker(0xa30b7A2caC38c4AA10A607e76B1912c883A413a4);
    GenericCompoundUpgradeable internal _oldLenderCompound =
        GenericCompoundUpgradeable(payable(0x07D174dF93bC8e90709846a69D571afCf587f507));
    GenericEuler internal _oldLenderEuler = GenericEuler(payable(0x7Eda38822327AFd7B6150Bef6F18a70E491ce5dA));

    IComptroller internal constant _COMPTROLLER = IComptroller(0x3d9819210A31b4961b30EF54bE2aeD79B9c9Cd3B);
    IERC20 internal constant _COMP = IERC20(0xc00e94Cb662C3520282E6f5717214004A7f26888);
    CErc20I internal _cDAI = CErc20I(0x5d3a536E4D6DbD6114cc1Ead35777bAB948E3643);
    // solhint-disable-next-line
    IERC20 private constant _aave = IERC20(0x7Fc66500c84A76Ad7e9c93437bFc5Ac33E2DDaE9);
    // solhint-disable-next-line
    IERC20 private constant _stkAave = IERC20(0x4da27a545c0c5B758a6BA100e3a049001de870f5);
    IEuler private constant _EULER = IEuler(0x27182842E098f60e3D576794A5bFFb0777E025d3);
    uint256 internal constant _PROP_INVESTED = 95 * 10**7;

    uint256 public marginAmount;
    uint8 internal _decimalToken;
    OptimizerAPRStrategy public stratImplementation;
    OptimizerAPRStrategy public strat;
    GenericCompoundUpgradeable public lenderCompoundImplementation;
    GenericCompoundUpgradeable public lenderCompound;
    GenericAaveNoStaker public lenderAaveImplementation;
    GenericAaveNoStaker public lenderAave;
    GenericEuler public lenderEulerImplementation;
    GenericEuler public lenderEuler;

    uint256 public constant BACKTEST_LENGTH = 30;
    uint256 public constant IMPROVE_LENGTH = 2;

    function setUp() public override {
        super.setUp();

        _ethereum = vm.createFork(vm.envString("ETH_NODE_URI_ETH_FOUNDRY"), 16583523);
        vm.selectFork(_ethereum);

        _decimalToken = IERC20Metadata(address(token)).decimals();
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
                        address(_cDAI),
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
        lenderEulerImplementation = new GenericEuler();
        lenderEuler = GenericEuler(
            deployUpgradeable(
                address(lenderEulerImplementation),
                abi.encodeWithSelector(
                    lenderEulerImplementation.initializeEuler.selector,
                    address(strat),
                    "lender Euler",
                    governorList,
                    _GUARDIAN,
                    keeperList,
                    _1INCH_V5
                )
            )
        );

        vm.startPrank(_GOVERNOR);
        manager.updateStrategyDebtRatio(address(_oldStrat), 0);
        vm.stopPrank();
    }

    // =============================== MIGRATE FUNDS ===============================

    function testMigrationFundsSuccess() public {
        {
            // do a claimComp first and sell the rewards
            address[] memory holders = new address[](1);
            CTokenI[] memory cTokens = new CTokenI[](1);
            holders[0] = address(_oldLenderCompound);
            cTokens[0] = CTokenI(address(_cDAI));
            _COMPTROLLER.claimComp(holders, cTokens, true, true);
            uint256 compReward = _COMP.balanceOf(address(_oldLenderCompound));
            console.log("compReward ", compReward);
            vm.prank(0xcC617C6f9725eACC993ac626C7efC6B96476916E);
            // TODO when selling simulate back at current block how many rewards we received
            _oldLenderCompound.sellRewards(
                0,
                hex"2e95b6c8000000000000000000000000c00e94cb662c3520282e6f5717214004a7f268880000000000000000000000000000000000000000000000000116b20422ca09f90000000000000000000000000000000000000000000000003b013a5d10fb007b0000000000000000000000000000000000000000000000000000000000000080000000000000000000000000000000000000000000000000000000000000000200000000000000003b6d034059f7a66a2fbcaf203cee71359b51142238f85b7880000000000000003b6d0340a478c2975ab1ea89e8196811f51a7b7ade33eb11cfee7c08"
            );

            // do a claimRewards first and sell the rewards
            vm.prank(0xcC617C6f9725eACC993ac626C7efC6B96476916E);
            _oldLenderAave.claimRewards();
            // there shouldn't be any
            uint256 stkAaveOldLender = _stkAave.balanceOf(address(_oldLenderAave));
            uint256 aaveOldLender = _aave.balanceOf(address(_oldLenderAave));
            assertEq(stkAaveOldLender, 15573012500895913369);
            assertEq(aaveOldLender, 0);
        }
        // Update the rate so that we have the true rate and we don't underestimate the rate on chain
        _cDAI.accrueInterest();
        // remove funds from previous strat
        vm.startPrank(_GOVERNOR);
        // It would have been more efficient but it doesn't account for profits
        // _oldStrat.safeRemoveLender(address(_oldLenderAave));
        // _oldStrat.forceRemoveLender(address(_oldLenderCompound));
        _oldStrat.harvest();
        manager.withdrawFromStrategy(IStrategy(address(_oldStrat)), token.balanceOf(address(_oldStrat)));
        strat.addLender(IGenericLender(address(lenderCompound)));
        strat.addLender(IGenericLender(address(lenderAave)));
        strat.addLender(IGenericLender(address(lenderEuler)));
        manager.addStrategy(address(strat), _PROP_INVESTED);
        vm.stopPrank();

        // There shouldn't be any funds left on the old strat
        assertEq(token.balanceOf(address(_oldLenderCompound)), 0);
        assertApproxEqAbs(_cDAI.balanceOf(address(_oldLenderCompound)), 0, 10**_decimalToken);
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
}
