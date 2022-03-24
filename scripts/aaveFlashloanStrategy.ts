import { ethers, network } from 'hardhat';
import { utils, constants, Contract, BigNumber } from 'ethers';
import { impersonate, deploy } from '../test/test-utils';
import {
  AaveFlashloanStrategy,
  ERC20,
  ERC20__factory,
  PoolManager__factory,
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

import { logBN, advanceTime, setup, assert } from './setup_tests';
import { ether } from '@angleprotocol/sdk';

async function main() {
  const [deployer, proxyAdmin, governor, guardian, user, keeper] = await ethers.getSigners();
  const {
    strategy,
    poolManager,
    incentivesController,
    oldStrategy,
    realGuardian,
    aToken,
    debtToken,
    logAssets,
    harvest,
    lendingPool,
    richUSDCUser,
    USDC,
    protocolDataProvider,
    aavePrice,
  } = await setup(14434700);

  // === SETUP ===
  await (
    await poolManager
      .connect(realGuardian)
      .updateStrategyDebtRatio((await oldStrategy).address, utils.parseUnits('0.2', 9))
  ).wait();
  const strategyDebtRatio = 0.75;
  await (
    await poolManager
      .connect(realGuardian)
      .addStrategy(strategy.address, utils.parseUnits(strategyDebtRatio.toString(), 9))
  ).wait();
  await network.provider.request({ method: 'hardhat_stopImpersonatingAccount', params: [realGuardian.address] });

  // ====== SCRIPTS ======
  await (await oldStrategy.harvest()).wait();

  // we check that values are in the correct state
  assert((await ethers.provider.getBlockNumber()) === 14434710);
  assert((await poolManager.getTotalAsset()).mul(3).div(4).eq(BigNumber.from(0x5c8e689c33d2)));

  const _data = await protocolDataProvider.getReserveData(USDC);
  assert(_data.availableLiquidity.eq(BigNumber.from('0x0294c3750b51fb')));
  assert(_data.totalStableDebt.eq(BigNumber.from('0x0dd0a2f9893b')));
  assert(_data.totalVariableDebt.eq(BigNumber.from('0x0566084e0e3f5f')));

  // log params for python script
  const normalizationFactor = utils.parseUnits('1', 27).div(1e6);
  const ray = utils.parseUnits('1', 27);
  console.log(`
  poolManagerFund=${(await poolManager.getTotalAsset()).mul(3).div(4).mul(normalizationFactor).div(ray)}
  compBorrowStable=${_data.totalStableDebt.mul(normalizationFactor).div(ray)}
  compBorrowVariable=${_data.totalVariableDebt.mul(normalizationFactor).div(ray)}
  compDeposit=${_data.availableLiquidity
    .add((await poolManager.getTotalAsset()).mul(3).div(4))
    .add(_data.totalStableDebt)
    .add(_data.totalVariableDebt)
    .mul(normalizationFactor)
    .div(ray)}
  rFixed=0.${_data.averageStableBorrowRate}
  rewardDeposit=${(await incentivesController.assets(aToken.address)).emissionPerSecond
    .mul(86400 * 365)
    .mul(aavePrice.mul(await strategy.discountFactor()).div(utils.parseUnits('1', 4)))
    .mul(utils.parseUnits('1', 9))
    .div(1e6)
    .div(ray)}
  rewardBorrow=${(await incentivesController.assets(debtToken.address)).emissionPerSecond
    .mul(86400 * 365)
    .mul(aavePrice.mul(await strategy.discountFactor()).div(utils.parseUnits('1', 4)))
    .mul(utils.parseUnits('1', 9))
    .div(1e6)
    .div(ray)}
  `);
  await harvest();
  // CR should be 0.7628
  assert((await strategy.targetCollatRatio()).eq(BigNumber.from('0x0a95f6c2e772ac2d')));

  await lendingPool.connect(richUSDCUser).deposit(USDC, utils.parseUnits('80000000', 6), richUSDCUser.address, 0);
  await harvest();
  logAssets();

  // // set rewards to 0
  await impersonate('0xee56e2b3d491590b5b31738cc34d5232f378a8d5', async emissionManager => {
    await network.provider.send('hardhat_setBalance', [emissionManager.address, '0x8ac7230489e80000']);

    await incentivesController.connect(emissionManager).configureAssets([aToken.address], [0]);
    await incentivesController.connect(emissionManager).configureAssets([debtToken.address], [0]);
  });

  console.log(`
  poolManagerFund=${(await poolManager.getTotalAsset()).mul(3).div(4).mul(normalizationFactor).div(ray)}
  compBorrowStable=${_data.totalStableDebt.mul(normalizationFactor).div(ray)}
  compBorrowVariable=${_data.totalVariableDebt.mul(normalizationFactor).div(ray)}
  compDeposit=${_data.availableLiquidity
    .add((await poolManager.getTotalAsset()).mul(3).div(4))
    .add(_data.totalStableDebt)
    .add(_data.totalVariableDebt)
    .mul(normalizationFactor)
    .div(ray)}
  rFixed=0.${_data.averageStableBorrowRate}
  rewardDeposit=${(await incentivesController.assets(aToken.address)).emissionPerSecond
    .mul(86400 * 365)
    .mul(aavePrice.mul(await strategy.discountFactor()).div(utils.parseUnits('1', 4)))
    .mul(utils.parseUnits('1', 9))
    .div(1e6)
    .div(ray)}
  rewardBorrow=${(await incentivesController.assets(debtToken.address)).emissionPerSecond
    .mul(86400 * 365)
    .mul(aavePrice.mul(await strategy.discountFactor()).div(utils.parseUnits('1', 4)))
    .mul(utils.parseUnits('1', 9))
    .div(1e6)
    .div(ray)}
  `);
  await harvest();
  await harvest();
  assert((await strategy.targetCollatRatio()).eq(0));
}

main();
