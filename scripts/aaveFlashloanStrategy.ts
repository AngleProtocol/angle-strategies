import { ethers, network } from 'hardhat';
import { utils, BigNumber } from 'ethers';
import { impersonate } from '../test/test-utils';

import { setup, assert, assertAlmostEq } from './setup_tests';

async function main() {
  const {
    strategy,
    poolManager,
    incentivesController,
    oldStrategy,
    realGuardian,
    aToken,
    debtToken,
    harvest,
    lendingPool,
    richUSDCUser,
    USDC,
    protocolDataProvider,
    aavePrice,
  } = await setup(14456160);

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
  assert((await ethers.provider.getBlockNumber()) === 14456170);
  assert((await poolManager.getTotalAsset()).mul(3).div(4).eq(BigNumber.from(0x5365efafcf9b)));

  let _data = await protocolDataProvider.getReserveData(USDC);
  assert(_data.availableLiquidity.eq(BigNumber.from('0x020ce27db56962')));
  assert(_data.totalStableDebt.eq(BigNumber.from('0x0dfd587ea04e')));
  assert(_data.totalVariableDebt.eq(BigNumber.from('0x0665030e3803a1')));

  // log params for python script
  const logState = async () => {
    const normalizationFactor = utils.parseUnits('1', 27).div(1e6);
    const ray = utils.parseUnits('1', 27);

    _data = await protocolDataProvider.getReserveData(USDC);

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
  };

  await harvest();
  // CR should be 0.81886
  assertAlmostEq(await strategy.targetCollatRatio(), BigNumber.from('0x0b5d2e700bbfcd97'), 0.01);

  await lendingPool.connect(richUSDCUser).deposit(USDC, utils.parseUnits('20000000', 6), richUSDCUser.address, 0);
  await harvest();
  // CR should be 0.70699
  assertAlmostEq(await strategy.targetCollatRatio(), BigNumber.from('0x09cfc2f833b69c67'), 0.01);

  await network.provider.send('evm_increaseTime', [3600 * 24 * 2]); // forward 2 days
  await network.provider.send('evm_mine');

  await lendingPool.connect(richUSDCUser).deposit(USDC, utils.parseUnits('75000000', 6), richUSDCUser.address, 0);
  await harvest();
  assertAlmostEq(await strategy.targetCollatRatio(), BigNumber.from('0x0a11f41c8c66d742'), 0.01);

  await network.provider.send('evm_increaseTime', [3600 * 24 * 2]); // forward 2 days
  await network.provider.send('evm_mine');

  await lendingPool.connect(richUSDCUser).withdraw(USDC, utils.parseUnits('90000000', 6), richUSDCUser.address);
  await harvest();
  assertAlmostEq(await strategy.targetCollatRatio(), BigNumber.from('0x0ab92e61fede1b00'), 0.01);

  await lendingPool.connect(richUSDCUser).deposit(USDC, utils.parseUnits('120000000', 6), richUSDCUser.address, 0);
  await harvest();
  assertAlmostEq(await strategy.targetCollatRatio(), BigNumber.from('0x092c91fc24e75bcd'), 0.01);

  await lendingPool.connect(richUSDCUser).withdraw(USDC, utils.parseUnits('125000000', 6), richUSDCUser.address);
  await harvest();
  assertAlmostEq(await strategy.targetCollatRatio(), BigNumber.from('0x0af3f0f0305cfa5e'), 0.01);

  // // set rewards to 0
  await impersonate('0xee56e2b3d491590b5b31738cc34d5232f378a8d5', async emissionManager => {
    await network.provider.send('hardhat_setBalance', [emissionManager.address, '0x8ac7230489e80000']);
    await incentivesController.connect(emissionManager).configureAssets([aToken.address], [0]);
    await incentivesController.connect(emissionManager).configureAssets([debtToken.address], [0]);
  });
  await harvest();
  // CR should be 0
  assert((await strategy.targetCollatRatio()).eq(0));

  await network.provider.send('evm_increaseTime', [3600 * 24 * 3]); // forward 2 days
  await network.provider.send('evm_mine');

  await impersonate('0xee56e2b3d491590b5b31738cc34d5232f378a8d5', async emissionManager => {
    await network.provider.send('hardhat_setBalance', [emissionManager.address, '0x8ac7230489e80000']);
    await incentivesController.connect(emissionManager).configureAssets([aToken.address], ['5903258773510960']);
    await incentivesController.connect(emissionManager).configureAssets([debtToken.address], ['9806517547021920']);
  });
  await harvest();
  // CR should be 0.845
  assertAlmostEq(await strategy.targetCollatRatio(), BigNumber.from('0x0bba0b05e3348000'), 0.01);

  await lendingPool.connect(richUSDCUser).deposit(USDC, utils.parseUnits('120000000', 6), richUSDCUser.address, 0);
  await harvest();
  // CR should be 0.845
  assertAlmostEq(await strategy.targetCollatRatio(), BigNumber.from('0x0bba0b05e3348000'), 0.01);
}

main();
