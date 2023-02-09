// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.17;

import "forge-std/Script.sol";
import "./MainnetConstants.s.sol";
import { IAngleHelper } from "../../contracts/interfaces/IAngleHelper.sol";
import { CErc20I, CTokenI } from "../../contracts/interfaces/external/compound/CErc20I.sol";
import { IComptroller } from "../../contracts/interfaces/external/compound/IComptroller.sol";
import { PoolManager, IStrategy } from "../../contracts/mock/MockPoolManager2.sol";
import { OptimizerAPRStrategy } from "../../contracts/strategies/OptimizerAPR/OptimizerAPRStrategy.sol";
import { GenericAaveNoStaker, IERC20, IERC20Metadata, IGenericLender } from "../../contracts/strategies/OptimizerAPR/genericLender/aave/GenericAaveNoStaker.sol";
import { GenericCompoundUpgradeable } from "../../contracts/strategies/OptimizerAPR/genericLender/compound/GenericCompoundUpgradeable.sol";
import { GenericEulerStaker, IEulerStakingRewards, IEuler, IEulerEToken, IEulerDToken, IGenericLender, AggregatorV3Interface } from "../../contracts/strategies/OptimizerAPR/genericLender/euler/GenericEulerStaker.sol";

contract MigrationOptimizerAPRUSDC is Script, MainnetConstants {
    uint256 internal constant _BASE_TOKEN = 10**18;
    uint256 internal constant _BASE_APR = 10**18;
    uint64 internal constant _BPS = 10**4;

    IComptroller internal constant _COMPTROLLER = IComptroller(0x3d9819210A31b4961b30EF54bE2aeD79B9c9Cd3B);
    IERC20 internal constant _COMP = IERC20(0xc00e94Cb662C3520282E6f5717214004A7f26888);
    IERC20 private constant _aave = IERC20(0x7Fc66500c84A76Ad7e9c93437bFc5Ac33E2DDaE9);
    // solhint-disable-next-line
    IERC20 private constant _stkAave = IERC20(0x4da27a545c0c5B758a6BA100e3a049001de870f5);
    IEuler private constant _EULER = IEuler(0x27182842E098f60e3D576794A5bFFb0777E025d3);
    AggregatorV3Interface private constant _CHAINLINK =
        AggregatorV3Interface(0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419);
    uint256 internal constant _PROP_INVESTED = 95 * 10**7;

    // TODO Change on collateral
    IERC20 public token = IERC20(USDC);
    PoolManager public manager = PoolManager(0xe9f183FC656656f1F17af1F2b0dF79b8fF9ad8eD);
    CErc20I internal _cToken = CErc20I(0x39AA39c021dfbaE8faC545936693aC917d5E7563);
    // solhint-disable-next-line
    IEulerStakingRewards internal constant _STAKER = IEulerStakingRewards(0xE5aFE81e63f0A52a3a03B922b30f73B8ce74D570);

    uint256 public marginAmount;
    uint8 internal _decimalToken;
    string internal _tokenSymbol;
    OptimizerAPRStrategy public stratImplementation;
    OptimizerAPRStrategy public strat;
    GenericCompoundUpgradeable public lenderCompoundImplementation;
    GenericCompoundUpgradeable public lenderCompound;
    GenericAaveNoStaker public lenderAaveImplementation;
    GenericAaveNoStaker public lenderAave;
    GenericEulerStaker public lenderEulerImplementation;
    GenericEulerStaker public lenderEuler;

    error ZeroAdress();

    function run() external {
        // vm.createSelectFork("mainnet");
        uint256 deployerPrivateKey = vm.deriveKey(vm.envString("MNEMONIC_MAINNET"), 0);
        vm.startBroadcast(deployerPrivateKey);

        if (address(token) == address(0) || address(_cToken) == address(0) || address(manager) == address(0))
            revert ZeroAdress();

        // _decimalToken = IERC20Metadata(address(token)).decimals();
        // _tokenSymbol = IERC20Metadata(address(token)).symbol();
        // marginAmount = 10**(_decimalToken + 1);

        address[] memory keeperList = new address[](2);
        address[] memory governorList = new address[](1);
        keeperList[0] = KEEPER;
        keeperList[1] = KEEPER_MULTICALL;
        governorList[0] = GOVERNOR;

        console.log(string.concat("Compound Lender ", _tokenSymbol, " v2"));
        console.log(string.concat("Aave Lender ", _tokenSymbol, " v2"));
        console.log(string.concat("Euler Staker Lender ", _tokenSymbol));

        stratImplementation = new OptimizerAPRStrategy();
        // strat = OptimizerAPRStrategy(
        //     deployUpgradeable(
        //         address(stratImplementation),
        //         abi.encodeWithSelector(strat.initialize.selector, address(manager), GOVERNOR, GUARDIAN, keeperList)
        //     )
        // );

        // console.log("Successfully deployed OptimizerAPR strategy at the address: ", address(strat));

        // lenderCompoundImplementation = new GenericCompoundUpgradeable();
        // lenderCompound = GenericCompoundUpgradeable(
        //     payable(
        //         deployUpgradeable(
        //             address(lenderCompoundImplementation),
        //             abi.encodeWithSelector(
        //                 lenderCompoundImplementation.initialize.selector,
        //                 address(strat),
        //                 string.concat("Compound Lender ", _tokenSymbol, " v2"),
        //                 address(_cToken),
        //                 governorList,
        //                 GUARDIAN,
        //                 keeperList,
        //                 ONE_INCH
        //             )
        //         )
        //     )
        // );

        // console.log("Successfully deployed Generic Compound strategy at the address: ", address(lenderCompound));

        // lenderAaveImplementation = new GenericAaveNoStaker();
        // lenderAave = GenericAaveNoStaker(
        //     deployUpgradeable(
        //         address(lenderAaveImplementation),
        //         abi.encodeWithSelector(
        //             lenderAaveImplementation.initialize.selector,
        //             address(strat),
        //             string.concat("Aave Lender ", _tokenSymbol, " v2"),
        //             false,
        //             governorList,
        //             GUARDIAN,
        //             keeperList,
        //             ONE_INCH
        //         )
        //     )
        // );

        // console.log("Successfully deployed Generic Aave strategy at the address: ", address(lenderAave));

        // lenderEulerImplementation = new GenericEulerStaker();
        // lenderEuler = GenericEulerStaker(
        //     deployUpgradeable(
        //         address(lenderEulerImplementation),
        //         abi.encodeWithSelector(
        //             lenderEulerImplementation.initialize.selector,
        //             address(strat),
        //             string.concat("Euler Staker Lender ", _tokenSymbol),
        //             governorList,
        //             GUARDIAN,
        //             keeperList,
        //             ONE_INCH,
        //             _STAKER,
        //             _CHAINLINK
        //         )
        //     )
        // );

        // console.log("Successfully deployed Euler strategy at the address: ", address(lenderEuler));

        // TODO check out OptimizerAPRStrategyForkTest for the needed op
        vm.stopBroadcast();
    }
}
