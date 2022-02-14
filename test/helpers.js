const { ZERO_ADDRESS, MAX_UINT256 } = require('@openzeppelin/test-helpers/src/constants');
const { BN, ether, expectEvent, expectRevert, balance, time, send } = require('@openzeppelin/test-helpers');
const { utils } = require('ethers');

function gwei(number) {
  return utils.parseUnits(number.toString(), 'gwei');
}

const chai = require('chai');
const { artifacts } = require('hardhat');
const { expect } = chai;

// use default BigNumber
chai.use(require('chai-bn')(BN));

const BASE = ether('1');
const BASE_PARAMS = new BN('1000000000');
const BASE_15 = new BN('1000000000000000');
const BASE_RATE = new BN(10 ** 2);
const BASE_ORACLE = ether('1');

const Core = artifacts.require('Core');
const AgToken = artifacts.require('AgToken');
const SanToken = artifacts.require('SanToken');
const PoolManager = artifacts.require('PoolManager');
const StableMaster = artifacts.require('StableMasterFront');
const PerpetualManager = artifacts.require('PerpetualManagerFront');
const FeeManager = artifacts.require('FeeManager');
const BondingCurve = artifacts.require('BondingCurve');
const CollateralSettlerVeANGLE = artifacts.require('CollateralSettlerVeANGLE');
const Orchestrator = artifacts.require('Orchestrator');
const OrchestratorOwnable = artifacts.require('OrchestratorOwnable');
const AngleDistributor = artifacts.require('AngleDistributor');

const GenericCompound = artifacts.require('GenericCompound');
const GenericAave = artifacts.require('GenericAave');
const Strategy = artifacts.require('Strategy');
const StrategyStETHAcc = artifacts.require('StrategyStETHAcc');

const MockOracle = artifacts.require('MockOracle');
const MockGaugeController = artifacts.require('MockGaugeController');
const MockLiquidityGauge = artifacts.require('MockLiquidityGauge');
const MockCore = artifacts.require('MockCore');
const MockOracleMath = artifacts.require('MockOracleMath');
const MockPath = artifacts.require('ComputePath');
const MockPathComplex = artifacts.require('ComputePathComplex');
const OracleMulti = artifacts.require('OracleMulti');
const OracleDAI = artifacts.require('OracleDAI');
const OracleClSingle = artifacts.require('OracleChainlinkSingle');
const MockChainlinkOracle = artifacts.require('MockChainlinkOracle');
const MockChainlinkOracleNullRoundData = artifacts.require('MockChainlinkOracleNullRoundData');
const MockUniswapV3Pool = artifacts.require('MockUniswapV3Pool');
const MockERC721Holder = artifacts.require('ERC721Holder');
const MockERC721HolderWrongReason = artifacts.require('ERC721HolderWrongReason');

const MockToken = artifacts.require('MockToken');
const MockWETH = artifacts.require('MockWETH');
const MockStETH = artifacts.require('MockStETH');
const MockCurveStETHETH = artifacts.require('MockCurveStETHETH');
const MockANGLE = artifacts.require('MockANGLE');
const MockBot = artifacts.require('MockBot');

const MockStrategy = artifacts.require('MockStrategy');
const MockCompound = artifacts.require('MockCompound');
const MockAave = artifacts.require('MockAave');
const MockProtocolDataProvider = artifacts.require('MockProtocolDataProvider');
const MockComptroller = artifacts.require('MockComptroller');
const MockFeeDistributor = artifacts.require('MockFeeDistributor');
const MockUniswapV3Router = artifacts.require('MockUniswapV3Router');
const MockUniswapV2Router = artifacts.require('MockUniswapV2Router');

const SmartWalletWhitelist = artifacts.require('SmartWalletWhitelist');
const SurplusConverterUniV2Sushi = artifacts.require('SurplusConverterUniV2Sushi');
const SurplusConverterUniV3 = artifacts.require('SurplusConverterUniV3');
const SurplusConverterSanTokens = artifacts.require('SurplusConverterSanTokens');

const AngleStakingRewards = artifacts.require('StakingRewards');
const RewardsDistributor = artifacts.require('RewardsDistributor');
const PoolAddress = artifacts.require('PoolAddress');

const MAX_MINT_AMOUNT = new BN(2).pow(new BN(256)).sub(new BN(1));

async function initAngle(governor, guardian) {
  const core = await Core.new(governor, guardian);

  const ANGLE = await MockANGLE.new('ANGLE', 'ANGLE');
  const stableMaster = await StableMaster.new();
  await stableMaster.initialize(core.address);
  const agToken = await AgToken.new();
  await agToken.initialize('agEUR', 'agEUR', stableMaster.address);
  await core.deployStableMaster(agToken.address, { from: governor });

  return [core, ANGLE, stableMaster, agToken];
}

async function initCollateral(name, stableMaster, ANGLE, governor, collatBase = new BN('18'), setFees = true) {
  const token = await MockToken.new(name, name, collatBase);
  const oracle = await MockOracle.new(BASE_ORACLE, collatBase);
  const manager = await PoolManager.new();

  await manager.initialize(token.address, stableMaster.address);
  const sanToken = await SanToken.new();
  await sanToken.initialize('san' + name, 'san' + name, manager.address);
  const perpetualManager = await PerpetualManager.new();
  await perpetualManager.initialize(manager.address, ANGLE.address);
  const feeManager = await FeeManager.new(manager.address);

  await stableMaster.deployCollateral(
    manager.address,
    perpetualManager.address,
    feeManager.address,
    oracle.address,
    sanToken.address,
    { from: governor },
  );

  if (setFees) {
    // For test purpose
    const xFeeMint = [new BN('0'), gwei('1')];
    const yFeeMint = [gwei('0.1'), gwei('0.1')];
    await stableMaster.setUserFees(manager.address, xFeeMint, yFeeMint, 1, { from: governor });

    const xFeeBurn = [ether('0'), gwei('1')];
    const yFeeBurn = [gwei('0.1'), gwei('0.1')];
    await stableMaster.setUserFees(manager.address, xFeeBurn, yFeeBurn, 0, { from: governor });

    const xHAFeesDeposit = [gwei('0.1'), gwei('0.4'), gwei('0.7')];
    const yHAFeesDeposit = [gwei('0.01'), gwei('0.01'), gwei('0.01')];
    await perpetualManager.setHAFees(xHAFeesDeposit, yHAFeesDeposit, 1, { from: governor });

    const xHAFeesWithdraw = [gwei('0.1'), gwei('0.4'), gwei('0.7')];
    const yHAFeesWithdraw = [gwei('0.01'), gwei('0.01'), gwei('0.01')];
    await perpetualManager.setHAFees(xHAFeesWithdraw, yHAFeesWithdraw, 0, { from: governor });

    const xSlippage = [gwei('1'), gwei('1.5')];
    const ySlippage = [gwei('1'), gwei('0')];
    const xSlippageFee = [gwei('1'), gwei('1.5')];
    const ySlippageFee = [gwei('1'), gwei('0')];
    await feeManager.setFees(xSlippage, ySlippage, 3, { from: governor });
    await feeManager.setFees(xSlippageFee, ySlippageFee, 0, { from: governor });
  } else {
    const xFeeMint = [gwei('0'), gwei('0.4'), gwei('0.7'), gwei('1')];
    const yFeeMint = [gwei('0.002'), gwei('0.005'), gwei('0.025'), gwei('0.08')];
    await stableMaster.setUserFees(manager.address, xFeeMint, yFeeMint, 1, { from: governor });

    const xFeeBurn = [gwei('0'), gwei('0.4'), gwei('0.7'), gwei('1')];
    const yFeeBurn = [gwei('0.015'), gwei('0.005'), gwei('0.003'), gwei('0.002')];
    await stableMaster.setUserFees(manager.address, xFeeBurn, yFeeBurn, 0, { from: governor });

    const xHAFeesDeposit = [gwei('0'), gwei('0.4'), gwei('0.7'), gwei('1')];
    const yHAFeesDeposit = [gwei('0.03'), gwei('0.01'), gwei('0.005'), gwei('0.002')];
    await perpetualManager.setHAFees(xHAFeesDeposit, yHAFeesDeposit, 1, { from: governor });

    const xHAFeesWithdraw = [gwei('0'), gwei('0.4'), gwei('0.7'), gwei('1')];
    const yHAFeesWithdraw = [gwei('0.002'), gwei('0.01'), gwei('0.02'), gwei('0.06')];
    await perpetualManager.setHAFees(xHAFeesWithdraw, yHAFeesWithdraw, 0, { from: governor });

    const xSlippage = [gwei('0.5'), gwei('1'), gwei('1.2'), gwei('1.5')];
    const ySlippage = [gwei('0.5'), gwei('0.2'), gwei('0.1'), gwei('0')];
    const xSlippageFee = [gwei('0.5'), gwei('1'), gwei('1.2'), gwei('1.5')];
    const ySlippageFee = [gwei('0.75'), gwei('0.5'), gwei('0.15'), gwei('0')];

    await feeManager.setFees(xSlippage, ySlippage, 3, { from: governor });
    await feeManager.setFees(xSlippageFee, ySlippageFee, 0, { from: governor });
  }
  const xBonusMalusMint = [gwei('0.5'), gwei('1')];
  const yBonusMalusMint = [gwei('0.8'), gwei('1')];
  const xBonusMalusBurn = [gwei('0'), gwei('0.5'), gwei('1'), gwei('1.3'), gwei('1.5')];
  const yBonusMalusBurn = [gwei('10'), gwei('4'), gwei('1.5'), gwei('1'), gwei('1')];
  await feeManager.setFees(xBonusMalusMint, yBonusMalusMint, 1, { from: governor });
  await feeManager.setFees(xBonusMalusBurn, yBonusMalusBurn, 2, { from: governor });
  await feeManager.setHAFees(gwei('1'), gwei('1'), { from: governor });

  await stableMaster.setIncentivesForSLPs(gwei('0.5'), gwei('0.5'), manager.address, { from: governor });
  await stableMaster.setCapOnStableAndMaxInterests(MAX_UINT256, new BN('10').pow(collatBase), manager.address, {
    from: governor,
  });

  // Limit HA hedge should always be set before the target HA hedge
  await perpetualManager.setTargetAndLimitHAHedge(gwei('0.9'), gwei('0.95'), { from: governor });
  await perpetualManager.setBoundsPerpetual(gwei('3'), gwei('0.0625'), { from: governor });
  await perpetualManager.setKeeperFeesLiquidationRatio(gwei('0.2'), { from: governor });
  await perpetualManager.setKeeperFeesCap(ether('100'), ether('100'), { from: governor });
  const xKeeperFeesClosing = [gwei('0.25'), gwei('0.5'), gwei('1')];
  const yKeeperFeesClosing = [gwei('0.1'), gwei('0.6'), gwei('0.1')];
  await perpetualManager.setKeeperFeesClosing(xKeeperFeesClosing, yKeeperFeesClosing, { from: governor });

  await feeManager.updateUsersSLP();
  await feeManager.updateHA();

  await stableMaster.unpause(web3.utils.soliditySha3('STABLE'), manager.address, { from: governor });
  await stableMaster.unpause(web3.utils.soliditySha3('SLP'), manager.address, { from: governor });
  await perpetualManager.unpause({ from: governor });

  return [token, oracle, manager, sanToken, perpetualManager, feeManager];
}

async function initWETH(stableMaster, ANGLE, governor, guardian, collatBase = new BN('18')) {
  const token = await MockWETH.new('WETH', 'WETH', collatBase);
  const oracle = await MockOracle.new(BASE_ORACLE, collatBase);
  const manager = await PoolManager.new();

  await manager.initialize(token.address, stableMaster.address);
  const sanToken = await SanToken.new();
  await sanToken.initialize('sanWETH', 'sanWETH', manager.address);
  const perpetualManager = await PerpetualManager.new();
  await perpetualManager.initialize(manager.address, ANGLE.address);
  const feeManager = await FeeManager.new(manager.address);

  await stableMaster.deployCollateral(
    manager.address,
    perpetualManager.address,
    feeManager.address,
    oracle.address,
    sanToken.address,
    { from: governor },
  );
  const xFeeMint = [new BN('0'), gwei('1')];
  const yFeeMint = [gwei('0.1'), gwei('0.1')];
  await stableMaster.setUserFees(manager.address, xFeeMint, yFeeMint, 1, { from: governor });

  const xFeeBurn = [ether('0'), gwei('1')];
  const yFeeBurn = [gwei('0.1'), gwei('0.1')];
  await stableMaster.setUserFees(manager.address, xFeeBurn, yFeeBurn, 0, { from: governor });

  const xHAFeesDeposit = [gwei('0.1'), gwei('0.4'), gwei('0.7')];
  const yHAFeesDeposit = [gwei('0.01'), gwei('0.01'), gwei('0.01')];
  await perpetualManager.setHAFees(xHAFeesDeposit, yHAFeesDeposit, 1, { from: governor });

  const xHAFeesWithdraw = [gwei('0.1'), gwei('0.4'), gwei('0.7')];
  const yHAFeesWithdraw = [gwei('0.01'), gwei('0.01'), gwei('0.01')];
  await perpetualManager.setHAFees(xHAFeesWithdraw, yHAFeesWithdraw, 0, { from: governor });

  const xSlippage = [gwei('1'), gwei('1.5')];
  const ySlippage = [gwei('1'), gwei('0')];
  const xSlippageFee = [gwei('1'), gwei('1.5')];
  const ySlippageFee = [gwei('1'), gwei('0')];
  await feeManager.setFees(xSlippage, ySlippage, 3, { from: governor });
  await feeManager.setFees(xSlippageFee, ySlippageFee, 0, { from: governor });
  const xBonusMalusMint = [gwei('0.5'), gwei('1')];
  const yBonusMalusMint = [gwei('0.8'), gwei('1')];
  const xBonusMalusBurn = [gwei('0'), gwei('0.5'), gwei('1'), gwei('1.3'), gwei('1.5')];
  const yBonusMalusBurn = [gwei('10'), gwei('4'), gwei('1.5'), gwei('1'), gwei('1')];
  await feeManager.setFees(xBonusMalusMint, yBonusMalusMint, 1, { from: governor });
  await feeManager.setFees(xBonusMalusBurn, yBonusMalusBurn, 2, { from: governor });
  await feeManager.setHAFees(gwei('1'), gwei('1'), { from: governor });

  await stableMaster.setIncentivesForSLPs(gwei('0.5'), gwei('0.5'), manager.address, { from: governor });
  await stableMaster.setCapOnStableAndMaxInterests(MAX_UINT256, new BN('10').pow(collatBase), manager.address, {
    from: governor,
  });

  // Limit HA hedge should always be set before the target HA hedge
  await perpetualManager.setTargetAndLimitHAHedge(gwei('0.9'), gwei('0.95'), { from: governor });
  await perpetualManager.setBoundsPerpetual(gwei('3'), gwei('0.0625'), { from: governor });
  await perpetualManager.setKeeperFeesLiquidationRatio(gwei('0.2'), { from: governor });
  await perpetualManager.setKeeperFeesCap(ether('100'), ether('100'), { from: governor });
  const xKeeperFeesClosing = [gwei('0.25'), gwei('0.5'), gwei('1')];
  const yKeeperFeesClosing = [gwei('0.1'), gwei('0.6'), gwei('0.1')];
  await perpetualManager.setKeeperFeesClosing(xKeeperFeesClosing, yKeeperFeesClosing, { from: governor });

  await feeManager.updateUsersSLP();
  await feeManager.updateHA();

  await stableMaster.unpause(web3.utils.soliditySha3('STABLE'), manager.address, { from: governor });
  await stableMaster.unpause(web3.utils.soliditySha3('SLP'), manager.address, { from: governor });
  await perpetualManager.unpause({ from: governor });

  const stETH = await MockStETH.new('stETH', 'stETH', collatBase);
  const curve = await MockCurveStETHETH.new(stETH.address);

  const strategy = await StrategyStETHAcc.new(
    manager.address,
    ANGLE.address,
    [governor],
    guardian,
    curve.address,
    token.address,
    stETH.address,
  );

  await manager.addStrategy(strategy.address, gwei('0.8'), { from: governor });

  return [token, oracle, manager, sanToken, perpetualManager, feeManager, stETH, curve, strategy];
}

async function initStrategy(name, token, manager, ANGLE, oracle, governor, guardian) {
  const comp = await MockToken.new('COMP', 'COMP', 18);
  const weth = await MockToken.new('WETH', 'WETH', 18);
  const compound = await MockCompound.new('c' + name, 'c' + name, token.address);

  const uniswapPool = await initMockUniPoolDeterministic(weth.address, token.address);
  const uniswapRooter = await MockUniswapV3Router.new(comp.address, token.address);
  const uniswapV2Router = await MockUniswapV2Router.new(new BN('10'));
  // Price obtained from a Compound price feed
  const comptroller = await MockComptroller.new(new BN('1462500000000000'));

  const strategy = await Strategy.new(manager.address, ANGLE.address, [governor], guardian);
  strategy.setWithdrawalThreshold(new BN('100000000000000'));

  const genericCompound = await GenericCompound.new(
    strategy.address,
    name,
    uniswapRooter.address,
    uniswapV2Router.address,
    comptroller.address,
    comp.address,
    web3.utils.asciiToHex('0'),
    compound.address,
    [governor],
    guardian,
  );

  await strategy.addLender(genericCompound.address, { from: governor });

  await manager.addStrategy(strategy.address, gwei('0.8'), { from: governor });

  return [comp, compound, uniswapRooter, uniswapPool, genericCompound, strategy, uniswapV2Router, comptroller];
}

async function getInfoUniPool(factory, inERC20, outERC20, fee) {
  const poolAddress = await PoolAddress.new();
  let isMultiplied;
  const addressPool = await poolAddress.computeAddress(factory, await poolAddress.getPoolKey(inERC20, outERC20, fee));
  if (inERC20 < outERC20) isMultiplied = 1;
  else isMultiplied = 0;

  return [addressPool, isMultiplied];
}

async function initMockClOracle(decimals, desc) {
  const oracle = await MockChainlinkOracle.new();
  await oracle.setDecimals(decimals);
  await oracle.setDescritpion(desc);
  await oracle.setLatestAnswer(new BN(10).pow(decimals), await time.latest());

  return oracle;
}

async function initMockUniPool(tokenIn, tokenOut) {
  const uniPool = await MockUniswapV3Pool.new(tokenIn, tokenOut);
  let rdnNumber;
  const max = 1000000;
  const min = 100;
  for (let i = 0; i < 50; i++) {
    rdnNumber = Math.floor(Math.random() * (max - min + 1)) + min;
    await uniPool.updateNextTick(rdnNumber);
  }

  return uniPool;
}

async function initMockUniPooLPartialRandom(tokenIn, tokenOut) {
  const uniPool = await MockUniswapV3Pool.new(tokenIn, tokenOut);
  let rdnNumber;
  let cst = 1000;
  const max = 100000;
  const min = 90000;
  for (let i = 0; i < 50; i++) {
    rdnNumber = Math.floor(Math.random() * (max - min + 1)) + min;
    await uniPool.updateNextTick(cst + rdnNumber);
    cst += 100;
  }

  return uniPool;
}

// initialize the ticks such that the price is multiplied by 2 at each block
async function initMockUniPoolDeterministic(tokenIn, tokenOut) {
  const uniPool = await MockUniswapV3Pool.new(tokenIn, tokenOut);
  let nexTickVal = 0;
  await uniPool.updateNextTick(new BN(0));
  for (let i = 1; i < 50; i++) {
    nexTickVal += 1;
    await uniPool.updateNextTick(new BN(nexTickVal));
  }

  return uniPool;
}

// Function to watch event
async function getEvent(contract, eventName) {
  const events = await contract.getPastEvents(eventName, { fromBlock: 0 });
  for (let i = 0; i < events.length; i++) {
    console.log(events[i].args);
  }
}

async function expectApprox(actual, expected) {
  const delta = expected.div(new BN('100'));
  expect(actual).to.be.bignumber.closeTo(expected, delta);
}

async function expectApproxDelta(actual, expected, margin) {
  const delta = expected.mul(margin).div(new BN('100'));
  expect(actual).to.be.bignumber.closeTo(expected, delta);
}

const FEE_SIZE = 3;

function encodePath(path, fees) {
  if (path.length !== fees.length + 1) {
    throw new Error('path/fee lengths do not match');
  }

  let encoded = '0x';
  for (let i = 0; i < fees.length; i++) {
    // 20 byte encoding of the address
    encoded += path[i].slice(2);
    // 3 byte encoding of the fee
    encoded += fees[i].toString(16).padStart(2 * FEE_SIZE, '0');
  }
  // encode the final token
  encoded += path[path.length - 1].slice(2);

  return encoded.toLowerCase();
}

module.exports = {
  // utils,
  ZERO_ADDRESS,
  MAX_UINT256,
  web3,
  BN,
  balance,
  ether,
  gwei,
  encodePath,
  expectEvent,
  expectRevert,
  expectApprox,
  expectApproxDelta,
  time,
  send,
  expect,
  BASE,
  BASE_PARAMS,
  BASE_RATE,
  BASE_15,
  BASE_ORACLE,
  MAX_MINT_AMOUNT,
  // contracts
  Core,
  AgToken,
  SanToken,
  PoolManager,
  StableMaster,
  Strategy,
  PerpetualManager,
  AngleStakingRewards,
  RewardsDistributor,
  AngleDistributor,
  BondingCurve,
  FeeManager,
  CollateralSettlerVeANGLE,
  StrategyStETHAcc,
  PoolAddress,
  SurplusConverterUniV2Sushi,
  SurplusConverterUniV3,
  SurplusConverterSanTokens,
  // mock contracts
  MockOracle,
  MockOracleMath,
  MockERC721Holder,
  MockERC721HolderWrongReason,
  OracleDAI,
  OracleMulti,
  OracleClSingle,
  Orchestrator,
  OrchestratorOwnable,
  MockChainlinkOracle,
  MockLiquidityGauge,
  MockGaugeController,
  MockChainlinkOracleNullRoundData,
  MockUniswapV3Pool,
  GenericAave,
  MockUniswapV2Router,
  MockUniswapV3Router,
  MockFeeDistributor,
  MockToken,
  MockPath,
  MockPathComplex,
  MockBot,
  MockCore,
  MockStrategy,
  MockCompound,
  MockAave,
  MockProtocolDataProvider,
  SmartWalletWhitelist,
  // functions
  getEvent,
  initAngle,
  initCollateral,
  initWETH,
  initStrategy,
  initMockClOracle,
  initMockUniPool,
  initMockUniPoolDeterministic,
  initMockUniPooLPartialRandom,
  getInfoUniPool,
};
