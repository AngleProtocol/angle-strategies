import { ethers, network } from 'hardhat';
import { utils, BigNumber } from 'ethers';
import { impersonate } from '../test-utils';
import { expect } from '../test-utils/chai-setup';

import { setup, assert, assertAlmostEq } from './setup_tests';

describe('AaveFlashloan strategy', () => {
  it('scenario static', async () => {
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
      wantToken,
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
    expect((await poolManager.getTotalAsset()).mul(3).div(4)).to.be.closeTo(BigNumber.from('0x5365efafcf9b'), 1000);

    let _data = await protocolDataProvider.getReserveData(USDC);
    expect(_data.availableLiquidity).to.equal(BigNumber.from('0x020ce27db56962'));
    expect(_data.totalStableDebt).to.equal(BigNumber.from('0x0dfd587ea04e'));
    expect(_data.totalVariableDebt).to.equal(BigNumber.from('0x0665030e3803a1'));

    // log params for python script
    const logState = async () => {
      const normalizationFactor = utils.parseUnits('1', 27).div(1e6);
      const ray = utils.parseUnits('1', 27);

      _data = await protocolDataProvider.getReserveData(USDC);
      const borrow = await debtToken.balanceOf(strategy.address);

      console.log(`
      ---
poolManagerFund=${(await poolManager.getTotalAsset()).mul(3).div(4).mul(normalizationFactor).div(ray)}.0
compBorrowStable=${_data.totalStableDebt.mul(normalizationFactor).div(ray)}.0
compBorrowVariable=${_data.totalVariableDebt.sub(borrow).mul(normalizationFactor).div(ray)}.0
compDeposit=${_data.availableLiquidity
        .add(_data.totalStableDebt)
        .add(_data.totalVariableDebt)
        .add(await wantToken.balanceOf(strategy.address))
        .sub(borrow)
        .mul(normalizationFactor)
        .div(ray)}.0
rFixed=0.${_data.averageStableBorrowRate}
rewardDeposit=${(await incentivesController.assets(aToken.address)).emissionPerSecond
        .mul(86400 * 365)
        .mul(aavePrice.mul(await strategy.discountFactor()).div(utils.parseUnits('1', 4)))
        .mul(utils.parseUnits('1', 9))
        .div(1e6)
        .div(ray)}.0
rewardBorrow=${(await incentivesController.assets(debtToken.address)).emissionPerSecond
        .mul(86400 * 365)
        .mul(aavePrice.mul(await strategy.discountFactor()).div(utils.parseUnits('1', 4)))
        .mul(utils.parseUnits('1', 9))
        .div(1e6)
        .div(ray)}.0
        ---
  `);

      // Solidity
      // console.log("poolManagerFund=%s.0", balanceExcludingRewards / wantBase);
      // console.log("compBorrowStable=%s.0", totalStableDebt  / wantBase);
      // console.log("compBorrowVariable=%s.0", (totalVariableDebt - currentBorrow)  / wantBase);
      // console.log("compDeposit=%s.0", (availableLiquidity + totalStableDebt + totalVariableDebt + balanceExcludingRewards - deposits)  / wantBase);
      // console.log("rFixed=0.%s", averageStableBorrowRate  / wantBase);
      // console.log("rewardDeposit=%s.0", (emissionPerSecondAToken * 86400 * 365 * stkAavePriceInWant) / (wantBase*10**18));
      // console.log("rewardBorrow=%s.0", (emissionPerSecondDebtToken * 86400 * 365 * stkAavePriceInWant) / (wantBase*10**18));
      // console.log("==============");
    };

    await harvest();
    expect(parseFloat(utils.formatEther(await strategy.targetCollatRatio()))).to.be.closeTo(0.8188, 0.01);

    await lendingPool.connect(richUSDCUser).deposit(USDC, utils.parseUnits('20000000', 6), richUSDCUser.address, 0);
    await harvest();
    expect(parseFloat(utils.formatEther(await strategy.targetCollatRatio()))).to.be.closeTo(0.812, 0.01);

    await network.provider.send('evm_increaseTime', [3600 * 24 * 2]); // forward 2 days
    await network.provider.send('evm_mine');

    await lendingPool.connect(richUSDCUser).deposit(USDC, utils.parseUnits('75000000', 6), richUSDCUser.address, 0);
    // logState();
    await harvest();
    expect(parseFloat(utils.formatEther(await strategy.targetCollatRatio()))).to.be.closeTo(0.785, 0.01);

    await network.provider.send('evm_increaseTime', [3600 * 24 * 2]); // forward 2 days
    await network.provider.send('evm_mine');

    await lendingPool.connect(richUSDCUser).withdraw(USDC, utils.parseUnits('90000000', 6), richUSDCUser.address);
    await harvest();
    expect(parseFloat(utils.formatEther(await strategy.targetCollatRatio()))).to.be.closeTo(0.817, 0.01);

    await lendingPool.connect(richUSDCUser).deposit(USDC, utils.parseUnits('120000000', 6), richUSDCUser.address, 0);
    await harvest();
    expect(parseFloat(utils.formatEther(await strategy.targetCollatRatio()))).to.be.closeTo(0.7747, 0.01);

    await lendingPool.connect(richUSDCUser).withdraw(USDC, utils.parseUnits('125000000', 6), richUSDCUser.address);
    await harvest();
    expect(parseFloat(utils.formatEther(await strategy.targetCollatRatio()))).to.be.closeTo(0.8188, 0.01);

    // // set rewards to 0
    await impersonate('0xee56e2b3d491590b5b31738cc34d5232f378a8d5', async emissionManager => {
      await network.provider.send('hardhat_setBalance', [emissionManager.address, '0x8ac7230489e80000']);
      await incentivesController.connect(emissionManager).configureAssets([aToken.address], [0]);
      await incentivesController.connect(emissionManager).configureAssets([debtToken.address], [0]);
    });
    await harvest();
    // CR should be 0
    expect(await strategy.targetCollatRatio()).to.equal(0);

    await network.provider.send('evm_increaseTime', [3600 * 24 * 3]); // forward 2 days
    await network.provider.send('evm_mine');

    await impersonate('0xee56e2b3d491590b5b31738cc34d5232f378a8d5', async emissionManager => {
      await network.provider.send('hardhat_setBalance', [emissionManager.address, '0x8ac7230489e80000']);
      await incentivesController.connect(emissionManager).configureAssets([aToken.address], ['5903258773510960']);
      await incentivesController.connect(emissionManager).configureAssets([debtToken.address], ['9806517547021920']);
    });
    await harvest();
    expect(parseFloat(utils.formatEther(await strategy.targetCollatRatio()))).to.be.closeTo(0.845, 0.01);

    await lendingPool.connect(richUSDCUser).deposit(USDC, utils.parseUnits('120000000', 6), richUSDCUser.address, 0);
    await harvest();
    expect(parseFloat(utils.formatEther(await strategy.targetCollatRatio()))).to.be.closeTo(0.845, 0.01);
  });
});
