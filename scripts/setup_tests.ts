import { SignerWithAddress } from '@nomiclabs/hardhat-ethers/signers';
import { ethers, deployments, network } from 'hardhat';
import { utils, Wallet, constants, Contract, BigNumber, providers } from 'ethers';
import { impersonate, deploy } from '../test/test-utils';
import {
  AaveFlashloanStrategy,
  ERC20,
  ERC20__factory,
  PoolManager__factory,
  MockPoolManager,
  Strategy,
  Strategy__factory,
  ILendingPool__factory,
  ILendingPool,
  FlashMintLib,
  AaveFlashloanStrategy__factory,
  ComputeProfitability,
  PoolManager,
  IAaveIncentivesController__factory,
  IAaveIncentivesController,
  IProtocolDataProvider__factory,
  IProtocolDataProvider,
} from '../typechain';

export const logBN = (amount: BigNumber, { base = 6, pad = 20, sign = false } = {}) => {
  const num = parseFloat(utils.formatUnits(amount, base));
  const formattedNum = new Intl.NumberFormat('fr-FR', {
    style: 'decimal',
    maximumFractionDigits: 4,
    minimumFractionDigits: 4,
    signDisplay: sign ? 'always' : 'never',
  }).format(num);
  return formattedNum.padStart(pad, ' ');
};

export const advanceTime = async (hours: number) => {
  await network.provider.send('evm_increaseTime', [3600 * hours]); // forward X hours
  await network.provider.send('evm_mine');
};

export function assert(assertion: boolean, message = 'Assertion failed') {
  if (!assertion) throw new Error(message);
}

export async function setup(startBlocknumber?: number) {
  if (startBlocknumber) {
    await network.provider.request({
      method: 'hardhat_reset',
      params: [
        {
          forking: {
            jsonRpcUrl: process.env.ETH_NODE_URI_FORK,
            blockNumber: startBlocknumber,
          },
        },
      ],
    });
  }

  const [deployer, proxyAdmin, governor, guardian, user, keeper] = await ethers.getSigners();

  // === TOKENS ===
  const USDC = '0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48';

  const stkAave = (await ethers.getContractAt(
    ERC20__factory.abi,
    '0x4da27a545c0c5B758a6BA100e3a049001de870f5',
  )) as ERC20;
  const wantToken = (await ethers.getContractAt(ERC20__factory.abi, USDC)) as ERC20;

  // === CONTRACTS ===

  // const poolManager = (await deploy('MockPoolManager', [wantToken.address, 0])) as MockPoolManager;
  const poolManager = (await ethers.getContractAt(
    PoolManager__factory.abi,
    '0xe9f183FC656656f1F17af1F2b0dF79b8fF9ad8eD',
  )) as PoolManager;

  const lendingPool = (await ethers.getContractAt(
    ILendingPool__factory.abi,
    '0x7d2768dE32b0b80b7a3454c06BdAc94A69DDc7A9',
  )) as ILendingPool;

  const protocolDataProvider = (await ethers.getContractAt(
    IProtocolDataProvider__factory.abi,
    '0x057835Ad21a177dbdd3090bB1CAE03EaCF78Fc6d',
  )) as IProtocolDataProvider;

  const incentivesController = (await ethers.getContractAt(
    IAaveIncentivesController__factory.abi,
    '0xd784927Ff2f95ba542BfC824c8a8a98F3495f6b5',
  )) as IAaveIncentivesController;

  const flashMintLib = (await deploy('FlashMintLib')) as FlashMintLib;
  const computeProfitabilityContract = (await deploy('ComputeProfitability')) as ComputeProfitability;

  const oldStrategy = (await ethers.getContractAt(
    Strategy__factory.abi,
    '0x5fE0E497Ac676d8bA78598FC8016EBC1E6cE14a3',
  )) as Strategy;

  // === INIT STRATEGY ===

  const strategyImplementation = (await deploy('AaveFlashloanStrategy', [], {
    libraries: { FlashMintLib: flashMintLib.address },
  })) as AaveFlashloanStrategy;
  const proxy = await deploy('TransparentUpgradeableProxy', [strategyImplementation.address, proxyAdmin.address, '0x']);
  const strategy = new Contract(proxy.address, AaveFlashloanStrategy__factory.abi, deployer) as AaveFlashloanStrategy;

  await strategy.initialize(
    poolManager.address,
    governor.address,
    guardian.address,
    [keeper.address],
    computeProfitabilityContract.address,
  );

  // === AAVE TOKENS ===
  const aToken = (await ethers.getContractAt(
    ERC20__factory.abi,
    '0xBcca60bB61934080951369a648Fb03DF4F96263C',
  )) as ERC20;
  const debtToken = (await ethers.getContractAt(
    ERC20__factory.abi,
    '0x619beb58998eD2278e08620f97007e1116D5D25b',
  )) as ERC20;

  // === SIGNERS ===
  const realGuardian = await ethers.getSigner('0xdc4e6dfe07efca50a197df15d9200883ef4eb1c8');
  await network.provider.send('hardhat_setBalance', [
    realGuardian.address,
    utils.parseEther('100').toHexString().replace('0x0', '0x'),
  ]);
  await network.provider.request({ method: 'hardhat_impersonateAccount', params: [realGuardian.address] });

  // 0x6262998Ced04146fA42253a5C0AF90CA02dfd2A3: crypto.com account ($1.5b USDC)
  await network.provider.request({
    method: 'hardhat_impersonateAccount',
    params: ['0x6262998Ced04146fA42253a5C0AF90CA02dfd2A3'],
  });
  const richUSDCUser = await ethers.getSigner('0x6262998Ced04146fA42253a5C0AF90CA02dfd2A3');
  await wantToken.connect(richUSDCUser).approve(lendingPool.address, constants.MaxUint256);
  await aToken.connect(richUSDCUser).approve(lendingPool.address, constants.MaxUint256);

  const logBalances = async () =>
    console.log(`
  Balance USDC:     ${logBN(await wantToken.balanceOf(strategy.address))}
  Balance stkAave:  ${logBN(await stkAave.balanceOf(strategy.address), { base: 18 })}
  Rewards:          ${logBN(
    await incentivesController.getRewardsBalance([aToken.address, debtToken.address], strategy.address),
    { base: 18 },
  )}
  `);

  const logPosition = async () =>
    console.log(`
  Position:
   deposits:  ${logBN(await aToken.balanceOf(strategy.address))}
   borrows:   ${logBN(await debtToken.balanceOf(strategy.address))}
   target cr: ${logBN(await strategy.targetCollatRatio(), { base: 18 })}
  `);

  const logAssets = async () =>
    console.log(`
  Assets:
    PM:           ${logBN(await poolManager.getTotalAsset())}
    old strategy: ${logBN(await oldStrategy.estimatedTotalAssets())}
    strategy:     ${logBN(await strategy.estimatedTotalAssets())}
  `);

  const logRates = async () => {
    const rates = await protocolDataProvider.getReserveData(wantToken.address);
    console.log(`
    Rates:
      deposit: ${utils.formatUnits(rates.liquidityRate, 25).slice(0, 6)}%
      borrow: ${utils.formatUnits(rates.variableBorrowRate, 25).slice(0, 6)}%
    `);
  };

  const aavePriceChainlink = await new Contract(
    '0x547a514d5e3769680Ce22B2361c10Ea13619e8a9',
    [
      'function latestRoundData() external view returns (uint80 roundId,int256 answer,uint256 startedAt,uint256 updatedAt,uint80 answeredInRound)',
    ],
    deployer,
  ).latestRoundData();
  const aavePrice = (aavePriceChainlink.answer as BigNumber).div(100);
  // const aavePrice = utils.parseUnits('157', 6); // Can be used to update the price manually

  const harvest = async () => {
    const aTokenBefore = await aToken.balanceOf(strategy.address);
    const debtTokenBefore = await debtToken.balanceOf(strategy.address);
    const crBefore = await strategy.targetCollatRatio();
    const ratesBefore = await protocolDataProvider.getReserveData(wantToken.address);

    console.log('harvesting...');

    // console.log('estimate', await strategy.estimateGas.harvest());
    const receipt = await (await strategy.harvest({ gasLimit: 2e6 })).wait();
    // console.log('gasUsed', receipt.gasUsed.toString());

    const aTokenAfter = await aToken.balanceOf(strategy.address);
    const debtTokenAfter = await debtToken.balanceOf(strategy.address);
    const crAfter = await strategy.targetCollatRatio();
    const ratesAfter = await protocolDataProvider.getReserveData(wantToken.address);

    const aTokenEmissions = (await incentivesController.assets(aToken.address)).emissionPerSecond.mul(
      60 * 60 * 24 * 365,
    );
    const debtTokenEmissions = (await incentivesController.assets(debtToken.address)).emissionPerSecond.mul(
      60 * 60 * 24 * 365,
    );

    // const aEmissions = aTokenAfter
    //   .mul(aTokenEmissions)
    //   .mul(aavePrice)
    //   .mul(1e9)
    //   .div(await aToken.totalSupply())
    //   .div(aTokenAfter); // BASE 27
    // const debtEmissions = debtTokenAfter
    //   .mul(debtTokenEmissions)
    //   .mul(aavePrice)
    //   .mul(1e9)
    //   .div(await debtToken.totalSupply())
    //   .div(debtTokenAfter); // BASE 27

    // let finalRate = ratesAfter.liquidityRate
    //   .mul(aTokenAfter)
    //   .add(ratesAfter.variableBorrowRate.mul(debtTokenAfter))
    //   .div(aTokenAfter.add(debtTokenAfter));
    // console.log(`finalRate1 ${utils.formatUnits(finalRate, 25).slice(0, 6)}%`);
    // finalRate = finalRate.add(aEmissions).add(debtEmissions);

    const aEmissions = aTokenAfter
      .mul(aTokenEmissions)
      .mul(aavePrice)
      .mul(1e3)
      .div(await aToken.totalSupply()); // BASE 27
    const debtEmissions = debtTokenAfter
      .mul(debtTokenEmissions)
      .mul(aavePrice)
      .mul(1e3)
      .div(await debtToken.totalSupply()); // BASE 27

    const interests = ratesAfter.liquidityRate
      .mul(aTokenAfter)
      .sub(ratesAfter.variableBorrowRate.mul(debtTokenAfter))
      .div(1e6);
    const totalUSD = aEmissions.add(debtEmissions).add(interests);
    const strategyDebt = (await poolManager.strategies(strategy.address)).totalStrategyDebt;
    const finalRate = totalUSD.div(strategyDebt); // BASE 21

    console.log(`
    ==========================
    deposits: ${logBN(aTokenBefore)} -> ${logBN(aTokenAfter)} (${logBN(aTokenAfter.sub(aTokenBefore), { sign: true })})
    rate: ${utils.formatUnits(ratesBefore.liquidityRate, 25).slice(0, 6)}% -> ${utils
      .formatUnits(ratesAfter.liquidityRate, 25)
      .slice(0, 6)}%

    borrows: ${logBN(debtTokenBefore)} -> ${logBN(debtTokenAfter)} (${logBN(debtTokenAfter.sub(debtTokenBefore), {
      sign: true,
    })})
    rate: ${utils.formatUnits(ratesBefore.variableBorrowRate, 25).slice(0, 6)}% -> ${utils
      .formatUnits(ratesAfter.variableBorrowRate, 25)
      .slice(0, 6)}%

    cr: ${logBN(crBefore, { base: 18 })} -> ${logBN(crAfter, { base: 18 })}

    finalRate: ${utils.formatUnits(finalRate, 19).slice(0, 6)}% (aRewards: ${utils
      .formatUnits(aEmissions.div(aTokenAfter), 19)
      .slice(0, 6)}% / debtRewards: ${
      debtTokenAfter.eq(0) ? '0' : utils.formatUnits(debtEmissions.div(debtTokenAfter), 19).slice(0, 6)
    }%)
    ==========================
    `);
  };

  return {
    USDC,
    strategy,
    lendingPool,
    protocolDataProvider,
    stkAave,
    poolManager,
    incentivesController,
    oldStrategy,
    realGuardian,
    richUSDCUser,
    aToken,
    debtToken,
    wantToken,
    aavePrice,
    logAssets,
    logBalances,
    logPosition,
    logRates,
    harvest,
  };
}
