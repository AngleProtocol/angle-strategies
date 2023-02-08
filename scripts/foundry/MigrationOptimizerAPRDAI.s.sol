// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.17;

import "forge-std/Script.sol";
import "./MainnetConstants.s.sol";
import { IAngleHelper } from "../../contracts/interfaces/IAngleHelper.sol";
import { CErc20I, CTokenI } from "../../contracts/interfaces/external/compound/CErc20I.sol";
import { IComptroller } from "../../contracts/interfaces/external/compound/IComptroller.sol";
import { PoolManager, IStrategy } from "../../contracts/mock/MockPoolManager2.sol";
import { OptimizerAPRStrategy } from "../../contracts/strategies/OptimizerAPR/OptimizerAPRStrategy.sol";
import { OptimizerAPRGreedyStrategy } from "../../contracts/strategies/OptimizerAPR/OptimizerAPRGreedyStrategy.sol";
import { GenericAaveNoStaker, IERC20, IERC20Metadata, IGenericLender } from "../../contracts/strategies/OptimizerAPR/genericLender/aave/GenericAaveNoStaker.sol";
import { GenericCompoundUpgradeable } from "../../contracts/strategies/OptimizerAPR/genericLender/compound/GenericCompoundUpgradeable.sol";
import { GenericEuler, IEuler, IEulerEToken, IEulerDToken, IGenericLender, AggregatorV3Interface } from "../../contracts/strategies/OptimizerAPR/genericLender/euler/GenericEulerStaker.sol";

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
    uint256 internal constant _PROP_INVESTED = 95 * 10**7;

    OptimizerAPRStrategy public stratImplementation = OptimizerAPRStrategy(address(0));
    GenericCompoundUpgradeable public lenderCompoundImplementation =
        GenericCompoundUpgradeable(payable(0xDeEe844C6992F36ADAC59cF38d1F790B2a0313e2));
    GenericAaveNoStaker public lenderAaveImplementation =
        GenericAaveNoStaker(0x14bA0B82f1940e35Af39c364e8Fa99408881Ae30);

    // TODO Change on collateral
    IERC20 public token = IERC20(DAI);
    PoolManager public manager = PoolManager(0xc9daabC677F3d1301006e723bD21C60be57a5915);
    CErc20I internal _cToken = CErc20I(0x5d3a536E4D6DbD6114cc1Ead35777bAB948E3643);

    uint256 public marginAmount;
    uint8 internal _decimalToken;
    string internal _tokenSymbol;
    OptimizerAPRStrategy public strat;
    GenericCompoundUpgradeable public lenderCompound;
    GenericAaveNoStaker public lenderAave;
    GenericEuler public lenderEulerImplementation;
    GenericEuler public lenderEuler;

    error ZeroAddress();

    function run() external {
        // vm.createSelectFork("mainnet");
        uint256 deployerPrivateKey = vm.deriveKey(vm.envString("MNEMONIC_MAINNET"), 0);
        vm.startBroadcast(deployerPrivateKey);

        if (
            address(token) == address(0) ||
            address(_cToken) == address(0) ||
            address(manager) == address(0) ||
            address(stratImplementation) == address(0) ||
            address(stratImplementation) == address(0) ||
            address(stratImplementation) == address(0)
        ) revert ZeroAddress();

        _decimalToken = IERC20Metadata(address(token)).decimals();
        _tokenSymbol = IERC20Metadata(address(token)).symbol();
        marginAmount = 10**(_decimalToken + 1);

        address[] memory keeperList = new address[](2);
        address[] memory governorList = new address[](1);
        keeperList[0] = KEEPER;
        keeperList[1] = KEEPER_MULTICALL;
        governorList[0] = GOVERNOR;

        console.log(string.concat("Compound Lender ", _tokenSymbol, " v2"));
        console.log(string.concat("Aave Lender ", _tokenSymbol, " v2"));
        console.log(string.concat("Euler Staker Lender ", _tokenSymbol));

        strat = OptimizerAPRStrategy(
            deployUpgradeable(
                address(stratImplementation),
                abi.encodeWithSelector(strat.initialize.selector, address(manager), GOVERNOR, GUARDIAN, keeperList)
            )
        );

        console.log("Successfully deployed OptimizerAPR strategy at the address: ", address(strat));

        lenderCompound = GenericCompoundUpgradeable(
            payable(
                deployUpgradeable(
                    address(lenderCompoundImplementation),
                    abi.encodeWithSelector(
                        lenderCompoundImplementation.initialize.selector,
                        address(strat),
                        string.concat("Compound Lender ", _tokenSymbol, " v2"),
                        address(_cToken),
                        governorList,
                        GUARDIAN,
                        keeperList,
                        ONE_INCH
                    )
                )
            )
        );

        console.log("Successfully deployed Generic Compound strategy at the address: ", address(lenderCompound));

        lenderAave = GenericAaveNoStaker(
            deployUpgradeable(
                address(lenderAaveImplementation),
                abi.encodeWithSelector(
                    lenderAaveImplementation.initialize.selector,
                    address(strat),
                    string.concat("Aave Lender ", _tokenSymbol, " v2"),
                    false,
                    governorList,
                    GUARDIAN,
                    keeperList,
                    ONE_INCH
                )
            )
        );

        console.log("Successfully deployed Generic Aave strategy at the address: ", address(lenderAave));

        lenderEulerImplementation = new GenericEuler();
        lenderEuler = GenericEuler(
            deployUpgradeable(
                address(lenderEulerImplementation),
                abi.encodeWithSelector(
                    lenderEulerImplementation.initializeEuler.selector,
                    address(strat),
                    string.concat("Euler Lender ", _tokenSymbol),
                    governorList,
                    GUARDIAN,
                    keeperList,
                    ONE_INCH
                )
            )
        );

        console.log("Successfully deployed Euler strategy at the address: ", address(lenderEuler));

        // TODO check out OptimizerAPRStrategyForkTest for the needed op
        vm.stopBroadcast();
    }
}
