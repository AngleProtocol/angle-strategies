/* eslint-disable camelcase */
import { SignerWithAddress } from '@nomiclabs/hardhat-ethers/signers';
import { ethers, deployments, network } from 'hardhat';
import { utils, Wallet, constants, Contract, BigNumber } from 'ethers';
import { impersonate } from '../test/test-utils';
import {
  AaveFlashloanStrategy,
  ERC20,
  ERC20__factory,
  PoolManager__factory,
  Strategy,
  Strategy__factory,
  FlashMintLib__factory,
  FlashMintLib,
  ILendingPool__factory,
  ILendingPool,
} from '../typechain';

async function randomDeposit(_lendingPool: string, _user: string, _asset: string) {
  const lendingPool = (await ethers.getContractAt(ILendingPool__factory.abi, _lendingPool)) as ILendingPool;

  const min = 100_000;
  const max = 100_000_000;
  const amount = utils.parseUnits(Math.floor(Math.random() * (max - min + 1) + min).toString(), 6);
  await impersonate(_user, async user => {
    await lendingPool.connect(user).deposit(_asset, amount, _user, 0);
  });
}
async function randomWithdraw(_lendingPool: string, _user: string, _asset: string) {
  const lendingPool = (await ethers.getContractAt(ILendingPool__factory.abi, _lendingPool)) as ILendingPool;

  const min = 100_000;
  const max = 100_000_000;
  const amount = utils.parseUnits(Math.floor(Math.random() * (max - min + 1) + min).toString(), 6);
  await impersonate(_user, async user => {
    await lendingPool.connect(user).withdraw(_asset, amount, _user);
  });
}

async function main() {
  const [deployer, guardian, governor, user] = await ethers.getSigners();

  const poolManager = await ethers.getContractAt(
    PoolManager__factory.abi,
    '0xe9f183FC656656f1F17af1F2b0dF79b8fF9ad8eD',
  );

  // // Tokens
  const ANGLE = '0x31429d1856aD1377A8A0079410B297e1a9e214c2';
  const stkAave = '0x4da27a545c0c5B758a6BA100e3a049001de870f5';

  const flashMintLib = await (await ethers.getContractFactory('FlashMintLib')).deploy();

  const strategyFactory = await ethers.getContractFactory('AaveFlashloanStrategy', {
    libraries: {
      FlashMintLib: flashMintLib.address,
    },
  });

  const computeProfitabilityContract = await (await ethers.getContractFactory('ComputeProfitability')).deploy();

  const strategy = (await strategyFactory.deploy(
    poolManager.address,
    ANGLE,
    [governor.address],
    guardian.address,
    computeProfitabilityContract.address,
  )) as AaveFlashloanStrategy;

  // TO DELETE
  // await network.provider.request({
  //   method: 'hardhat_impersonateAccount',
  //   params: ['0x7E0188b0312A26ffE64B7e43a7a91d430fB20673'],
  // });
  // const account = await ethers.getSigner('0x7E0188b0312A26ffE64B7e43a7a91d430fB20673');
  // const wantToken = (await ethers.getContractAt(ERC20__factory.abi, await strategy.want())) as ERC20;
  // console.log('wantToken', wantToken.address);
  // await wantToken.connect(account).transfer(strategy.address, utils.parseUnits('100', 6));
  // await strategy.test();
  // await network.provider.request({
  //   method: 'hardhat_stopImpersonatingAccount',
  //   params: ['0x7E0188b0312A26ffE64B7e43a7a91d430fB20673'],
  // });

  const oldStrategy = (await ethers.getContractAt(
    Strategy__factory.abi,
    '0x5fE0E497Ac676d8bA78598FC8016EBC1E6cE14a3',
  )) as Strategy;

  const realGuardian = await ethers.getSigner('0xdc4e6dfe07efca50a197df15d9200883ef4eb1c8');
  await network.provider.send('hardhat_setBalance', [
    realGuardian.address,
    utils.parseEther('100').toHexString().replace('0x0', '0x'),
  ]);
  await network.provider.request({ method: 'hardhat_impersonateAccount', params: [realGuardian.address] });
  await (
    await poolManager
      .connect(realGuardian)
      .updateStrategyDebtRatio((await oldStrategy).address, utils.parseUnits('0.2', 9))
  ).wait();
  await (await poolManager.connect(realGuardian).addStrategy(strategy.address, utils.parseUnits('0.75', 9))).wait();
  await network.provider.request({ method: 'hardhat_stopImpersonatingAccount', params: [realGuardian.address] });

  console.log('total assets old', await oldStrategy.estimatedTotalAssets());
  await (await oldStrategy.connect(guardian).harvest()).wait();
  console.log('total assets old', await oldStrategy.estimatedTotalAssets());

  const want = (await ethers.getContractAt(ERC20__factory.abi, await strategy.want())) as ERC20;
  console.log('balance pm before', utils.formatUnits(await want.balanceOf(poolManager.address), 6));
  await (await strategy.connect(guardian).harvest()).wait();
  console.log('balance pm after', utils.formatUnits(await want.balanceOf(poolManager.address), 6));
  console.log('total assets', await strategy.estimatedTotalAssets());

  // Temper stkAave balance
  const stkAaveContract = (await ethers.getContractAt(ERC20__factory.abi, stkAave)) as ERC20;
  const stkAaveBalanceStorage = ethers.utils.solidityKeccak256(['uint256', 'uint256'], [strategy.address, 0]);
  await network.provider.send('hardhat_setStorageAt', [
    stkAave,
    stkAaveBalanceStorage,
    ethers.utils.hexZeroPad(utils.parseEther('50').toHexString(), 32),
  ]);
  console.log('balance stkAave', await stkAaveContract.balanceOf(strategy.address));

  console.log('done');
  // await strategy.computeProfitability();
  // await strategy.estimatedAPR();
}

main();
