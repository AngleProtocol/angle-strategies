// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.17;

import "../../BaseTest.test.sol";
import { OracleMath } from "../../../../contracts/utils/OracleMath.sol";
import { PoolManager } from "../../../../contracts/mock/MockPoolManager2.sol";
import { OptimizerAPRGreedyStrategy } from "../../../../contracts/strategies/OptimizerAPR/OptimizerAPRGreedyStrategy.sol";
import { GenericEulerStaker, IERC20, IEulerStakingRewards, IEuler, IEulerEToken, IEulerDToken, IGenericLender, AggregatorV3Interface, IUniswapV3Pool } from "../../../../contracts/strategies/OptimizerAPR/genericLender/euler/GenericEulerStaker.sol";

interface IMinimalLiquidityGauge {
    // solhint-disable-next-line
    function add_reward(address rewardToken, address distributor) external;
}

contract GenericEulerStakerTest is BaseTest, OracleMath {
    using stdStorage for StdStorage;

    address internal _hacker = address(uint160(uint256(keccak256(abi.encodePacked("hacker")))));

    IERC20 internal constant _TOKEN = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    IERC20 internal constant _EUL = IERC20(0xd9Fcd98c322942075A5C3860693e9f4f03AAE07b);
    IEulerStakingRewards internal constant _STAKER = IEulerStakingRewards(0xE5aFE81e63f0A52a3a03B922b30f73B8ce74D570);
    IEuler private constant _euler = IEuler(0x27182842E098f60e3D576794A5bFFb0777E025d3);
    IEulerEToken internal constant _eUSDC = IEulerEToken(0xEb91861f8A4e1C12333F42DCE8fB0Ecdc28dA716);
    IEulerDToken internal constant _dUSDC = IEulerDToken(0x84721A3dB22EB852233AEAE74f9bC8477F8bcc42);
    IUniswapV3Pool private constant _POOL = IUniswapV3Pool(0xB003DF4B243f938132e8CAdBEB237AbC5A889FB4);
    uint8 private constant _IS_UNI_MULTIPLIED = 0;
    AggregatorV3Interface private constant _CHAINLINK =
        AggregatorV3Interface(0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419);

    uint8 internal constant _DECIMAL_REWARD = 18;
    uint8 internal constant _DECIMAL_TOKEN = 6;
    uint256 internal constant _U_OPTIMAL = 8 * 10**17;
    uint256 internal constant _SLOPE1 = 4 * 10**16;
    uint256 internal constant _SLOPE2 = 96 * 10**16;
    uint256 internal constant _ONE_MINUS_RESERVE = 75 * 10**16;

    PoolManager public manager;
    OptimizerAPRGreedyStrategy public stratImplementation;
    OptimizerAPRGreedyStrategy public strat;
    GenericEulerStaker public lenderImplementation;
    GenericEulerStaker public lender;
    uint256 public maxTokenAmount = 10**(_DECIMAL_TOKEN + 6);
    uint256 public minTokenAmount = 10**(_DECIMAL_TOKEN - 1);

    uint256 public constant WITHDRAW_LENGTH = 30;
    uint256 public constant REWARDS_LENGTH = 30;

    function setUp() public override {
        _ethereum = vm.createFork(vm.envString("ETH_NODE_URI_ETH_FOUNDRY"), 16220173);
        vm.selectFork(_ethereum);

        super.setUp();

        address[] memory keeperList = new address[](1);
        address[] memory governorList = new address[](1);
        keeperList[0] = _KEEPER;
        governorList[0] = _GOVERNOR;

        manager = new PoolManager(address(_TOKEN), _GOVERNOR, _GUARDIAN);
        stratImplementation = new OptimizerAPRGreedyStrategy();
        strat = OptimizerAPRGreedyStrategy(
            deployUpgradeable(
                address(stratImplementation),
                abi.encodeWithSelector(strat.initialize.selector, address(manager), _GOVERNOR, _GUARDIAN, keeperList)
            )
        );
        vm.prank(_GOVERNOR);
        manager.addStrategy(address(strat), 10**9);

        lenderImplementation = new GenericEulerStaker();
        lender = GenericEulerStaker(
            deployUpgradeable(
                address(lenderImplementation),
                abi.encodeWithSelector(
                    lender.initialize.selector,
                    address(strat),
                    "Euler lender staker USDC",
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

    function testDepositStratSuccess(uint256 amount) public {
        amount = bound(amount, 1, maxTokenAmount);
        deal(address(_TOKEN), address(strat), amount);
        vm.prank(_KEEPER);
        strat.harvest();
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

    function testWithdawAllSuccess(uint256 amount) public {
        amount = bound(amount, minTokenAmount, maxTokenAmount);
        deal(address(_TOKEN), address(lender), amount);
        vm.prank(_KEEPER);
        lender.deposit();
        vm.prank(_KEEPER);
        lender.withdrawAll();
        assertEq(_TOKEN.balanceOf(address(lender)), 0);
        assertApproxEqAbs(_eUSDC.balanceOf(address(lender)), 0, 10**(18 - 6));
        uint256 balanceInUnderlying = _eUSDC.convertBalanceToUnderlying(
            IERC20(address(_STAKER)).balanceOf(address(lender))
        );
        assertApproxEqAbs(_TOKEN.balanceOf(address(strat)), amount, 1 wei);
        assertApproxEqAbs(balanceInUnderlying, 0, 1 wei);
        assertApproxEqAbs(lender.underlyingBalanceStored(), 0, 1 wei);
    }

    function testEmergencyWithdawSuccess(uint256 amount, uint256 propWithdraw) public {
        amount = bound(amount, minTokenAmount, maxTokenAmount);
        propWithdraw = bound(propWithdraw, 1, BASE_PARAMS);
        uint256 toWithdraw = (amount * propWithdraw) / BASE_PARAMS;
        if (toWithdraw >= amount - 1) toWithdraw = amount - 1;
        if (toWithdraw < minTokenAmount - 1) toWithdraw = minTokenAmount - 1;
        deal(address(_TOKEN), address(lender), amount);
        vm.prank(_KEEPER);
        lender.deposit();
        vm.prank(_GUARDIAN);
        lender.emergencyWithdraw(toWithdraw);
        assertEq(_TOKEN.balanceOf(address(lender)), 0);
        assertApproxEqAbs(_eUSDC.balanceOf(address(lender)), 0, 10**(18 - 6));
        uint256 balanceInUnderlying = _eUSDC.convertBalanceToUnderlying(
            IERC20(address(_STAKER)).balanceOf(address(lender))
        );
        assertApproxEqAbs(_TOKEN.balanceOf(address(manager)), toWithdraw, 1 wei);
        assertApproxEqAbs(balanceInUnderlying, amount - toWithdraw, 1 wei);
        assertApproxEqAbs(lender.underlyingBalanceStored(), amount - toWithdraw, 1 wei);
    }

    function testMultiWithdrawSuccess(
        uint256[WITHDRAW_LENGTH] memory amounts,
        uint256[WITHDRAW_LENGTH] memory isDepositWithdrawBorrow,
        uint64[WITHDRAW_LENGTH] memory elapseTime
    ) public {
        // remove all staking rewards
        vm.warp(block.timestamp + 86400 * 7 * 2);

        uint256 depositedBalance;
        for (uint256 i = 1; i < amounts.length; ++i) {
            isDepositWithdrawBorrow[i] = bound(isDepositWithdrawBorrow[i], 0, 2);
            if (isDepositWithdrawBorrow[i] == 1 && depositedBalance == 0) isDepositWithdrawBorrow[i] = 0;
            if (isDepositWithdrawBorrow[i] == 0) {
                uint256 amount = bound(amounts[i], 1, maxTokenAmount);
                deal(address(_TOKEN), address(strat), amount);
                vm.prank(_KEEPER);
                strat.harvest();
                depositedBalance += amount;
            } else if (isDepositWithdrawBorrow[i] == 1) {
                uint256 propWithdraw = bound(amounts[i], 1, 10**9);
                uint256 toWithdraw = (propWithdraw * depositedBalance) / BASE_PARAMS;
                if (toWithdraw < minTokenAmount) toWithdraw = minTokenAmount;
                if (toWithdraw > depositedBalance) toWithdraw = depositedBalance;
                vm.prank(_KEEPER);
                lender.withdraw(toWithdraw);
                depositedBalance -= toWithdraw;
            } else if (isDepositWithdrawBorrow[i] == 2) {
                uint256 amount = bound(amounts[i], 1, maxTokenAmount);
                uint256 toBorrow = amount / 2;
                deal(address(_TOKEN), address(_BOB), amount);
                vm.startPrank(_BOB);
                _TOKEN.approve(address(_euler), amount);
                _eUSDC.deposit(0, amount);
                if (toBorrow > 0) _dUSDC.borrow(0, toBorrow);
                vm.stopPrank();
            }
            uint256 nativeAPR = lender.apr();
            assertEq(_TOKEN.balanceOf(address(lender)), 0);
            assertApproxEqAbs(lender.nav(), depositedBalance, 1 wei);
            assertApproxEqAbs(lender.underlyingBalanceStored(), depositedBalance, 1 wei);

            // advance in time for rewards to be taken into account
            elapseTime[i] = uint64(bound(elapseTime[i], 1, 86400 * 7));
            vm.warp(block.timestamp + elapseTime[i]);

            uint256 estimatedNewBalance = depositedBalance +
                (depositedBalance * nativeAPR * elapseTime[i]) /
                (365 days * BASE_TOKENS);
            uint256 tol = (estimatedNewBalance / 10**5 > 1) ? estimatedNewBalance / 10**5 : 1;
            assertApproxEqAbs(lender.nav(), estimatedNewBalance, tol);

            // to not have accumulating errors
            depositedBalance = lender.nav();
        }
    }

    // =============================== VIEW FUNCTIONS ==============================

    function testAPRSuccess() public {
        uint256 apr = lender.apr();
        uint256 supplyAPR = _computeSupplyAPR(0);
        uint256 stakingAPR = 18884 * 10**12;
        // elpase to not have staking incentives anymore
        vm.warp(block.timestamp + 86400 * 7 * 4);
        vm.roll(block.number + 1);
        uint256 aprWithoutIncentives = lender.apr();
        assertApproxEqAbs(supplyAPR + stakingAPR, apr, 10**15);
        assertApproxEqAbs(supplyAPR, aprWithoutIncentives, 10**15);
    }

    function testAPRIncentivesSuccess(uint256 amount, uint256 rewardAmount) public {
        rewardAmount = bound(rewardAmount, 10**18, 10**(18 + 4));
        vm.warp(block.timestamp + 86400 * 7 * 4);
        _depositRewards(rewardAmount);

        amount = bound(amount, minTokenAmount, maxTokenAmount);
        uint256 contractEstimatedAPR = _stakingApr(amount);
        deal(address(_TOKEN), address(_ALICE), amount);
        vm.startPrank(_ALICE);
        _TOKEN.approve(address(_euler), amount);
        _eUSDC.deposit(0, amount);
        uint256 eTokenAMount = _eUSDC.balanceOf(_ALICE);
        IERC20(address(_eUSDC)).approve(address(_STAKER), eTokenAMount);
        _STAKER.stake(eTokenAMount);
        vm.stopPrank();

        uint256 totalSupply = _STAKER.totalSupply();
        uint256 eulRoughPrice = 4015000000000000000;
        // rewards last 2 weeks
        uint256 incentivesAPR = (rewardAmount * 53 * eulRoughPrice) / totalSupply / 2;
        assertApproxEqAbs(contractEstimatedAPR, incentivesAPR, 10**15);
    }

    function testAPRNoStakingSuccess(uint256 amount) public {
        // elpase to not have staking incentives anymore
        vm.warp(block.timestamp + 86400 * 7 * 2);

        amount = bound(amount, 1, maxTokenAmount);
        deal(address(_TOKEN), address(lender), amount);
        uint256 supplyAPR = _computeSupplyAPR(amount);
        vm.prank(_KEEPER);
        lender.deposit();
        uint256 apr = lender.apr();
        assertApproxEqAbs(apr, supplyAPR, 5 * 10**14);
    }

    function testAPRWithDepositsSuccess(uint256 amount, uint256 rewardAmount) public {
        rewardAmount = bound(rewardAmount, 10**18, 10**(18 + 4));
        amount = bound(amount, 1, maxTokenAmount);
        deal(address(_TOKEN), address(lender), amount);
        uint256 supplyAPR = _computeSupplyAPR(amount);
        vm.prank(_KEEPER);
        lender.deposit();

        // elpase to not have staking incentives anymore
        vm.warp(block.timestamp + 86400 * 7 * 2);
        _depositRewards(rewardAmount);
        uint256 totalSupply = _STAKER.totalSupply();
        uint256 eulRoughPrice = 4015000000000000000;
        // rewards last 2 weeks
        uint256 incentivesAPR = (rewardAmount * 53 * eulRoughPrice) / totalSupply / 2;
        uint256 aprWithIncentives = lender.apr();
        // incentives APR are tough to estimate (because of the price) which is why the .3% margin
        assertApproxEqAbs(aprWithIncentives, supplyAPR + incentivesAPR, 3 * 10**15);
    }

    // ================================== REWARDS ==================================

    function testRewardsSuccess(uint256 amount) public {
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

    function testMultiRewardsSuccess(
        uint256[REWARDS_LENGTH] memory amounts,
        uint256[REWARDS_LENGTH] memory isDepositWithdrawBorrow,
        uint64[REWARDS_LENGTH] memory elapseTime
    ) public {
        vm.warp(block.timestamp + 86400 * 7 * 2);

        uint256 depositedBalance;
        uint256 lastReward;
        for (uint256 i = 1; i < amounts.length; ++i) {
            isDepositWithdrawBorrow[i] = bound(isDepositWithdrawBorrow[i], 0, 3);
            if (isDepositWithdrawBorrow[i] == 3 && _STAKER.periodFinish() > block.timestamp)
                isDepositWithdrawBorrow[i] = 2;
            if (isDepositWithdrawBorrow[i] == 1 && depositedBalance == 0) isDepositWithdrawBorrow[i] = 0;
            if (isDepositWithdrawBorrow[i] == 0) {
                uint256 amount = bound(amounts[i], minTokenAmount * 100, maxTokenAmount);
                deal(address(_TOKEN), address(lender), amount);
                vm.prank(_KEEPER);
                lender.deposit();
                depositedBalance += amount;
            } else if (isDepositWithdrawBorrow[i] == 1) {
                uint256 propWithdraw = bound(amounts[i], 1, 10**9);
                uint256 toWithdraw = (propWithdraw * depositedBalance) / BASE_PARAMS;
                if (toWithdraw < minTokenAmount) toWithdraw = minTokenAmount;
                if (toWithdraw > depositedBalance) toWithdraw = depositedBalance;
                vm.prank(_KEEPER);
                lender.withdraw(toWithdraw);
                depositedBalance -= toWithdraw;
            } else if (isDepositWithdrawBorrow[i] == 2) {
                uint256 amount = bound(amounts[i], 1, maxTokenAmount);
                uint256 toBorrow = amount / 2;
                deal(address(_TOKEN), address(_BOB), amount);
                vm.startPrank(_BOB);
                _TOKEN.approve(address(_euler), amount);
                _eUSDC.deposit(0, amount);
                if (toBorrow > 0) _dUSDC.borrow(0, toBorrow);
                vm.stopPrank();
            } else {
                uint256 amount = bound(amounts[i], 10**(18 + 2), 10**(18 + 4));
                _depositRewards(amount);
                lastReward = amount;
            }
            uint256 beginning = block.timestamp;
            // advance in time for rewards to be taken into account
            elapseTime[i] = uint64(bound(elapseTime[i], 1, 86400 * 7));
            elapseTime[i] = 86400 * 14;
            vm.warp(block.timestamp + elapseTime[i]);
            {
                uint256 totSupply = _STAKER.totalSupply();
                uint256 periodFinish = _STAKER.periodFinish();
                if (totSupply > 0 && periodFinish > beginning) {
                    uint256 toClaim = (_STAKER.balanceOf(address(lender)) * lastReward * (periodFinish - beginning)) /
                        (totSupply * (14 days));
                    uint256 prevBalance = _EUL.balanceOf(address(lender));
                    lender.claimRewards();
                    assertApproxEqAbs(_EUL.balanceOf(address(lender)) - prevBalance, toClaim, toClaim / 10**12);
                } else lender.claimRewards();
            }
            depositedBalance = lender.nav();
        }
    }

    // ================================== INTERNAL =================================

    function _depositRewards(uint256 amount) internal {
        deal(address(_EUL), address(_STAKER), amount + _EUL.balanceOf(address(_STAKER)));
        vm.prank(0xA9839D52E964d0ed0d6D546c27D2248Fac610c43);
        _STAKER.notifyRewardAmount(amount);
    }

    function _computeSupplyAPR(uint256 amount) internal view returns (uint256 apr) {
        uint256 totalBorrows = _dUSDC.totalSupply();
        // Total supply is current supply + added liquidity
        uint256 totalSupply = _eUSDC.totalSupplyUnderlying() + amount;
        uint256 futureUtilisationRate = (totalBorrows * 1e18) / totalSupply;
        uint256 borrowAPY;
        if (_U_OPTIMAL >= futureUtilisationRate) borrowAPY = (_SLOPE1 * futureUtilisationRate) / _U_OPTIMAL;
        else borrowAPY = _SLOPE1 + (_SLOPE2 * (futureUtilisationRate - _U_OPTIMAL)) / (10**18 - _U_OPTIMAL);
        apr = (borrowAPY * totalBorrows * _ONE_MINUS_RESERVE) / (totalSupply * 10**18);
    }

    /// @notice Get stakingAPR after staking an additional `amount`
    /// @param amount Virtual amount to be staked
    function _stakingApr(uint256 amount) internal view returns (uint256 apr) {
        uint256 periodFinish = _STAKER.periodFinish();
        if (periodFinish <= block.timestamp) return 0;
        uint256 newTotalSupply = _STAKER.totalSupply() + _eUSDC.convertUnderlyingToBalance(amount);
        // APRs are in 1e18 and a 5% penalty on the EUL price is taken to avoid overestimations
        // `_estimatedEulToWant()` and eTokens are in base 18
        apr = (_estimatedEulToWant(_STAKER.rewardRate() * (365 days)) * 1 ether) / newTotalSupply;
    }

    /// @notice Estimates the amount of `want` we will get out by swapping it for EUL
    /// @param quoteAmount The amount to convert in the out-currency
    /// @return The value of the `quoteAmount` expressed in out-currency
    /// @dev Uses both Uniswap TWAP and Chainlink spot price
    function _estimatedEulToWant(uint256 quoteAmount) internal view returns (uint256) {
        uint32[] memory secondAgos = new uint32[](2);

        uint32 twapPeriod = 1 minutes;
        secondAgos[0] = twapPeriod;
        secondAgos[1] = 0;

        (IUniswapV3Pool pool, uint8 isUniMultiplied) = (IUniswapV3Pool(0xB003DF4B243f938132e8CAdBEB237AbC5A889FB4), 0);
        (int56[] memory tickCumulatives, ) = pool.observe(secondAgos);
        int56 tickCumulativesDelta = tickCumulatives[1] - tickCumulatives[0];

        int24 timeWeightedAverageTick = int24(tickCumulativesDelta / int32(twapPeriod));

        // Always round to negative infinity
        if (tickCumulativesDelta < 0 && (tickCumulativesDelta % int56(int32(twapPeriod)) != 0))
            timeWeightedAverageTick--;

        // Computing the `quoteAmount` from the ticks obtained from Uniswap
        uint256 amountInETH = _getQuoteAtTick(timeWeightedAverageTick, quoteAmount, isUniMultiplied);

        (, int256 ethPriceUSD, , , ) = AggregatorV3Interface(0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419)
            .latestRoundData();
        // ethPriceUSD is in base 8
        return (uint256(ethPriceUSD) * amountInETH) / 1e8;
    }
}
