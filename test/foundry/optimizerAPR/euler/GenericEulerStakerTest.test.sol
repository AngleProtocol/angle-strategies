// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.17;

import "../../BaseTest.test.sol";
import { PoolManager } from "../../../../contracts/mock/MockPoolManager2.sol";
import { OptimizerAPRStrategy } from "../../../../contracts/strategies/OptimizerAPR/OptimizerAPRStrategy.sol";
import { GenericEulerStakerUSDC, IERC20, IEulerStakingRewards, IEulerEToken, IGenericLender } from "../../../../contracts/strategies/OptimizerAPR/genericLender/euler/implementations/GenericEulerStakerUSDC.sol";

interface IMinimalLiquidityGauge {
    // solhint-disable-next-line
    function add_reward(address rewardToken, address distributor) external;
}

contract GenericEulerStakerTest is BaseTest {
    using stdStorage for StdStorage;

    address internal _hacker = address(uint160(uint256(keccak256(abi.encodePacked("hacker")))));

    IERC20 internal constant _TOKEN = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    IERC20 internal constant _EUL = IERC20(0xd9Fcd98c322942075A5C3860693e9f4f03AAE07b);
    IEulerStakingRewards internal constant _STAKER = IEulerStakingRewards(0xE5aFE81e63f0A52a3a03B922b30f73B8ce74D570);
    IEulerEToken internal constant _eUSDC = IEulerEToken(0xEb91861f8A4e1C12333F42DCE8fB0Ecdc28dA716);
    uint8 internal constant _DECIMAL_REWARD = 18;
    uint8 internal constant _DECIMAL_TOKEN = 6;

    PoolManager public manager;
    OptimizerAPRStrategy public stratImplementation;
    OptimizerAPRStrategy public strat;
    GenericEulerStakerUSDC public lenderImplementation;
    GenericEulerStakerUSDC public lender;
    uint256 public maxTokenAmount = 10**(_DECIMAL_TOKEN + 6);
    uint256 public minTokenAmount = 10**(_DECIMAL_TOKEN - 1);

    uint256 public constant WITHDRAW_LENGTH = 3;

    function setUp() public override {
        _ethereum = vm.createFork(vm.envString("ETH_NODE_URI_ETH_FOUNDRY"), 16220173);
        vm.selectFork(_ethereum);

        super.setUp();

        address[] memory keeperList = new address[](1);
        address[] memory governorList = new address[](1);
        keeperList[0] = _KEEPER;
        governorList[0] = _GOVERNOR;

        manager = new PoolManager(address(_TOKEN), _GOVERNOR, _GUARDIAN);
        stratImplementation = new OptimizerAPRStrategy();
        strat = OptimizerAPRStrategy(
            deployUpgradeable(
                address(stratImplementation),
                abi.encodeWithSelector(strat.initialize.selector, address(manager), _GOVERNOR, _GUARDIAN, keeperList)
            )
        );
        vm.prank(_GOVERNOR);
        manager.addStrategy(address(strat), 8 * 10**8);

        lenderImplementation = new GenericEulerStakerUSDC();
        lender = GenericEulerStakerUSDC(
            deployUpgradeable(
                address(lenderImplementation),
                abi.encodeWithSelector(
                    lender.initialize.selector,
                    address(strat),
                    "Euler lender staker USDC",
                    governorList,
                    _GUARDIAN,
                    keeperList
                )
            )
        );
        vm.prank(_GOVERNOR);
        strat.addLender(IGenericLender(address(lender)));
        vm.prank(_GOVERNOR);
        lender.grantRole(keccak256("STRATEGY_ROLE"), _KEEPER);
    }

    // ================================= INITIALIZE ================================

    function testInitalize() public {
        assertEq(IERC20(address(_eUSDC)).allowance(address(lender), address(_STAKER)), type(uint256).max);
    }

    // ================================== DEPOSIT ==================================

    function testDepositSuccess(uint256 amount) public {
        amount = bound(amount, 1, maxTokenAmount);
        deal(address(_TOKEN), address(lender), amount);
        vm.prank(_KEEPER);
        lender.deposit();
        assertEq(_TOKEN.balanceOf(address(lender)), 0);
        assertEq(_eUSDC.balanceOf(address(lender)), 0);
        uint256 balanceInUnderlying = _eUSDC.convertBalanceToUnderlying(
            IERC20(address(_STAKER)).balanceOf(address(lender))
        );
        assertApproxEqAbs(balanceInUnderlying, amount, 1 wei);
        assertApproxEqAbs(lender.underlyingBalanceStored(), amount, 1 wei);
    }

    // ================================== WITHDRAW =================================

    function testWithdawSuccess(uint256 amount, uint256 propWithdraw) public {
        amount = bound(amount, minTokenAmount, maxTokenAmount);
        propWithdraw = bound(propWithdraw, 1, BASE_PARAMS);
        uint256 toWithdraw = (amount * propWithdraw) / BASE_PARAMS;
        if (toWithdraw < minTokenAmount) toWithdraw = minTokenAmount;
        deal(address(_TOKEN), address(lender), amount);
        vm.prank(_KEEPER);
        lender.deposit();
        vm.prank(_KEEPER);
        lender.withdraw(toWithdraw);
        assertEq(_TOKEN.balanceOf(address(lender)), 0);
        assertApproxEqAbs(_eUSDC.balanceOf(address(lender)), 0, 10**(18 - 6));
        uint256 balanceInUnderlying = _eUSDC.convertBalanceToUnderlying(
            IERC20(address(_STAKER)).balanceOf(address(lender))
        );
        assertApproxEqAbs(_TOKEN.balanceOf(address(strat)), toWithdraw, 1 wei);
        assertApproxEqAbs(balanceInUnderlying, amount - toWithdraw, 1 wei);
        assertApproxEqAbs(lender.underlyingBalanceStored(), amount - toWithdraw, 1 wei);
    }

    // ================================== INTERNAL =================================

    function _depositRewards(uint256 amount) internal {
        deal(address(_EUL), address(_STAKER), amount + _EUL.balanceOf(address(_STAKER)));
        _STAKER.notifyRewardAmount(amount);
        vm.stopPrank();
    }
}

// // deposit amount
// 2433179688
// // eTokens staked
// 2374951696752960587574
// // withdraw amount
// 191683066
// // amount

// // lower bound amount stake in underlying
// 2433178387
// // rate
// 1024517
// // balance eToken in underlying
// 0
// // looseBalance
// 0
// // total
// 2433178387
// // hexa staked tokens
// 2374951696752960587574
// // unstake amount
// 187096032569493722408
// // actual burn amount
// 187095932569493704406
// 187095932569493704405
// // estimated amount staked after withdraw
// 18709593153581
// 18709593253581

// 18709603153582
// 18709603253582
