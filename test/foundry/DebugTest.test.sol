// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.17;

import "./BaseTest.test.sol";
import { IEuler, IEulerMarkets, IEulerEToken, IEulerDToken } from "../../contracts/interfaces/external/euler/IEuler.sol";
import { IReserveInterestRateStrategy } from "../../contracts/interfaces/external/aave/IAave.sol";

interface IBaseIRM {
    function baseRate() external view returns (uint256);

    function kink() external view returns (uint256);

    function slope1() external view returns (uint256);

    function slope2() external view returns (uint256);
}

contract DebugTest is BaseTest {
    using stdStorage for StdStorage;

    function setUp() public override {
        _ethereum = vm.createFork(vm.envString("ETH_NODE_URI_ETH_FOUNDRY"));
        vm.selectFork(_ethereum);

        super.setUp();
    }

    // ================================== DEPOSIT ==================================

    function testEuler() public {
        IEuler _euler = IEuler(0x27182842E098f60e3D576794A5bFFb0777E025d3);
        IEulerEToken eToken = IEulerEToken(0xEb91861f8A4e1C12333F42DCE8fB0Ecdc28dA716);
        IEulerMarkets _markets = IEulerMarkets(0x3520d5a913427E6F0D6A83E07ccD4A4da316e4d3);
        IBaseIRM moduleImpl = IBaseIRM(_euler.moduleIdToImplementation(2000500));
        console.log("moduleImpl ", address(moduleImpl));
        console.log("baseRate ", moduleImpl.baseRate());
        console.log("kink ", moduleImpl.kink());
        console.log("slope1 ", moduleImpl.slope1());
        console.log("slope2 ", moduleImpl.slope2());
        console.log("reserve factor", _markets.reserveFee(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48));
        console.log("totalSuplly ", eToken.totalSupplyUnderlying());
    }

    // function testAave() public {
    //     IReserveInterestRateStrategy ir = IReserveInterestRateStrategy(0x27182842E098f60e3D576794A5bFFb0777E025d3);
    //     console.log("baseRate ", ir.baseVariableBorrowRate());
    //     // console.log("kink ", ir.kink());
    //     console.log("slope1 ", ir.variableRateSlope1());
    //     console.log("slope2 ", ir.variableRateSlope1());
    // }
}
