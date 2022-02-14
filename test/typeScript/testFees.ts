import { ethers, expect } from 'hardhat';
import { BigNumber } from 'ethers';
import { parseAmount } from '../../utils/bignumber';
import { SignerWithAddress } from '@nomiclabs/hardhat-ethers/dist/src/signers';
// we import our utilities

import {
  PoolManager,
  StableMasterFront,
  MockOracle,
  FeeManager,
  MockToken,
  MockANGLE,
  PerpetualManagerFront,
  AgToken,
} from '../../typechain';

import {
  BASE,
  BASE_ORACLE,
  BASE_PARAMS,
  BASE_RATE,
  // functions
  initAngle,
  initCollateral,
  piecewiseFunction,
} from './helpers';

let maxAlock: BigNumber;

let ANGLE: MockANGLE;
let stableMasterEUR: StableMasterFront;
let agEUR: AgToken;

let wBTC: MockToken;
let oracleBTC: MockOracle;
let managerBTC: PoolManager;
let feeManagerContract: FeeManager;
let perpEURBTC: PerpetualManagerFront;

let deployer: SignerWithAddress;
let guardian: SignerWithAddress;
let user: SignerWithAddress;
let ha: SignerWithAddress;
let slp: SignerWithAddress;

let collatBASE: BigNumber;
const mintAmount = parseAmount.ether(100);
const burnAmount = parseAmount.ether(50).mul(BASE_RATE);
const commitAmount = parseAmount.ether(30);
const broughtAmount = parseAmount.ether(50);
const slpDeposit = parseAmount.ether(50);

// WARNING if the deployed contract doesn't have the same fees please update this file
// hardcoded piecewise linear functions
const xFeeMint: BigNumber[] = [parseAmount.gwei(0), parseAmount.gwei(0.4), parseAmount.gwei(0.7), parseAmount.gwei(1)];
const yFeeMint: BigNumber[] = [
  parseAmount.gwei(0.08),
  parseAmount.gwei(0.025),
  parseAmount.gwei(0.005),
  parseAmount.gwei(0.002),
];
const xFeeBurn: BigNumber[] = [parseAmount.gwei(0), parseAmount.gwei(0.3), parseAmount.gwei(0.6), parseAmount.gwei(1)];
const yFeeBurn: BigNumber[] = [
  parseAmount.gwei(0.002),
  parseAmount.gwei(0.003),
  parseAmount.gwei(0.005),
  parseAmount.gwei(0.015),
];
// const feesForSLPs: BigNumber = parseAmount.gwei(0.5);

const xBonusMalusMint: BigNumber[] = [parseAmount.gwei(0.5), parseAmount.gwei(1)];
const yBonusMalusMint: BigNumber[] = [parseAmount.gwei(0.8), parseAmount.gwei(1)];
const xBonusMalusBurn: BigNumber[] = [
  parseAmount.gwei(0),
  parseAmount.gwei(0.5),
  parseAmount.gwei(1),
  parseAmount.gwei(1.3),
  parseAmount.gwei(1.5),
];
const yBonusMalusBurn: BigNumber[] = [
  parseAmount.gwei(10),
  parseAmount.gwei(4),
  parseAmount.gwei(1.5),
  parseAmount.gwei(1),
  parseAmount.gwei(1),
];

const xSlippage: BigNumber[] = [
  parseAmount.gwei(0.5),
  parseAmount.gwei(1),
  parseAmount.gwei(1.2),
  parseAmount.gwei(1.5),
];
const ySlippage: BigNumber[] = [
  parseAmount.gwei(0.5),
  parseAmount.gwei(0.2),
  parseAmount.gwei(0.1),
  parseAmount.gwei(0),
];

const xSlippageFee: BigNumber[] = [
  parseAmount.gwei(0.5),
  parseAmount.gwei(1),
  parseAmount.gwei(1.2),
  parseAmount.gwei(1.5),
];
const ySlippageFee: BigNumber[] = [
  parseAmount.gwei(0.75),
  parseAmount.gwei(0.5),
  parseAmount.gwei(0.15),
  parseAmount.gwei(0),
];

const xHAFeesDeposit: BigNumber[] = [
  parseAmount.gwei(0),
  parseAmount.gwei(0.4),
  parseAmount.gwei(0.7),
  parseAmount.gwei(1),
];
const yHAFeesDeposit: BigNumber[] = [
  parseAmount.gwei(0.002),
  parseAmount.gwei(0.005),
  parseAmount.gwei(0.01),
  parseAmount.gwei(0.03),
];
const xHAFeesWithdraw: BigNumber[] = [
  parseAmount.gwei(0),
  parseAmount.gwei(0.4),
  parseAmount.gwei(0.7),
  parseAmount.gwei(1),
];
const yHAFeesWithdraw: BigNumber[] = [
  parseAmount.gwei(0.06),
  parseAmount.gwei(0.02),
  parseAmount.gwei(0.01),
  parseAmount.gwei(0.002),
];

describe('KeeperFees update - FeeManager', function () {
  describe('Only Stable seekers', function () {
    let PoolManagerStockInStable = BigNumber.from(0);
    let stableOut = BigNumber.from(0);

    before(async function () {
      ({ deployer, guardian, user } = await ethers.getNamedSigners());
      ({ ANGLE, stableMaster: stableMasterEUR, agToken: agEUR } = await initAngle(deployer, guardian));
      ({
        token: wBTC,
        oracle: oracleBTC,
        manager: managerBTC,
        feeManager: feeManagerContract,
        perpetualManager: perpEURBTC,
      } = await initCollateral('wBTC', stableMasterEUR, ANGLE, deployer, BigNumber.from(18), false));
      collatBASE = BigNumber.from(10).pow(BigNumber.from(18));

      await (await oracleBTC.connect(deployer).update(BASE_RATE.mul(BASE_ORACLE))).wait();

      await wBTC.connect(user).mint(user.address, parseAmount.ether(1000));

      await wBTC.connect(user).approve(stableMasterEUR.address, parseAmount.ether(1000));
    });
    it('success - after minting', async () => {
      await (await stableMasterEUR.connect(user).mint(mintAmount, user.address, managerBTC.address, 0)).wait();
      stableOut = mintAmount.mul(BigNumber.from(92)).div(BigNumber.from(100));
      PoolManagerStockInStable = mintAmount;
      const expectedCollatRatio = PoolManagerStockInStable.mul(BASE_PARAMS).div(stableOut);

      await (await feeManagerContract.connect(guardian).updateUsersSLP()).wait();

      const collatRatio = await stableMasterEUR.getCollateralRatio();

      expect(collatRatio.toString()).to.be.equal(expectedCollatRatio.toString());
      await testKeeperUpdateFee(stableMasterEUR, managerBTC, expectedCollatRatio);
    });

    it('success - after oracle divided by 2', async () => {
      const divisionOracle = BigNumber.from('2');
      await (await oracleBTC.connect(deployer).update(BASE_RATE.mul(BASE_ORACLE).div(divisionOracle))).wait();

      PoolManagerStockInStable = PoolManagerStockInStable.div(divisionOracle);
      const expectedCollatRatio = PoolManagerStockInStable.mul(BASE_PARAMS).div(stableOut);

      const collatRatio = await stableMasterEUR.getCollateralRatio();

      expect(collatRatio.toString()).to.be.equal(expectedCollatRatio.toString());

      await (await feeManagerContract.connect(guardian).updateUsersSLP()).wait();
      // await printFees(stableMasterEUR, managerBTC);
      await testKeeperUpdateFee(stableMasterEUR, managerBTC, expectedCollatRatio);
    });
  });

  describe('Stable seekers & HA', function () {
    let PoolManagerStockInStable = BigNumber.from(0);
    let stableOut = BigNumber.from(0);

    before(async function () {
      ({ deployer, guardian, user } = await ethers.getNamedSigners());
      ({ ANGLE, stableMaster: stableMasterEUR, agToken: agEUR } = await initAngle(deployer, guardian));
      ({
        token: wBTC,
        oracle: oracleBTC,
        manager: managerBTC,
        feeManager: feeManagerContract,
        perpetualManager: perpEURBTC,
      } = await initCollateral('wBTC', stableMasterEUR, ANGLE, deployer, BigNumber.from(18), false));
      collatBASE = BigNumber.from(10).pow(BigNumber.from(18));

      await (await oracleBTC.connect(deployer).update(BASE_RATE.mul(BASE_ORACLE))).wait();

      await wBTC.connect(user).mint(user.address, parseAmount.ether(1000));
      await wBTC.connect(user).approve(stableMasterEUR.address, parseAmount.ether(1000));
      await wBTC.connect(user).approve(perpEURBTC.address, parseAmount.ether(1000));
    });
    it('success - after minting', async () => {
      await (await stableMasterEUR.connect(user).mint(mintAmount, user.address, managerBTC.address, 0)).wait();
      stableOut = mintAmount.mul(BigNumber.from(92)).div(BigNumber.from(100));
      PoolManagerStockInStable = mintAmount;
      const expectedCollatRatio = PoolManagerStockInStable.mul(BASE_PARAMS).div(stableOut);

      await (await feeManagerContract.connect(guardian).updateUsersSLP()).wait();

      const collatRatio = await stableMasterEUR.getCollateralRatio();
      expect(collatRatio.toString()).to.be.equal(expectedCollatRatio.toString());

      await testKeeperUpdateFee(stableMasterEUR, managerBTC, expectedCollatRatio);
    });

    it('success - after covering a tenth by a tenth', async () => {
      await (
        await perpEURBTC
          .connect(user)
          .openPerpetual(
            user.address,
            broughtAmount,
            commitAmount,
            parseAmount.ether('10000000000000000'),
            parseAmount.ether(0),
          )
      ).wait();

      PoolManagerStockInStable = PoolManagerStockInStable.add(broughtAmount);
      const expectedCollatRatio = PoolManagerStockInStable.mul(BASE_PARAMS).div(stableOut);

      const collatRatio = await stableMasterEUR.getCollateralRatio();

      expect(collatRatio.toString()).to.be.equal(expectedCollatRatio.toString());

      await (await feeManagerContract.connect(guardian).updateUsersSLP()).wait();
      await testKeeperUpdateFee(stableMasterEUR, managerBTC, expectedCollatRatio);
    });

    it('success - after covering 2 tenth by 2 tenth', async () => {
      await (
        await perpEURBTC
          .connect(user)
          .openPerpetual(
            user.address,
            broughtAmount,
            commitAmount,
            parseAmount.ether('10000000000000000'),
            parseAmount.ether(0),
          )
      ).wait();

      PoolManagerStockInStable = PoolManagerStockInStable.add(broughtAmount);
      const expectedCollatRatio = PoolManagerStockInStable.mul(BASE_PARAMS).div(stableOut);

      const collatRatio = await stableMasterEUR.getCollateralRatio();

      expect(collatRatio.toString()).to.be.equal(expectedCollatRatio.toString());

      await (await feeManagerContract.connect(guardian).updateUsersSLP()).wait();
      // await printFees(stableMasterEUR, managerBTC);
      await testKeeperUpdateFee(stableMasterEUR, managerBTC, expectedCollatRatio);
    });

    it('success - after oracle divided by 5', async () => {
      const divisionOracle = BigNumber.from('5');

      await (await oracleBTC.connect(deployer).update(BASE_RATE.mul(BASE_ORACLE).div(divisionOracle))).wait();

      PoolManagerStockInStable = PoolManagerStockInStable.div(divisionOracle);
      const expectedCollatRatio = PoolManagerStockInStable.mul(BASE_PARAMS).div(stableOut);
      const collatRatio = await stableMasterEUR.getCollateralRatio();

      expect(collatRatio.toString()).to.be.equal(expectedCollatRatio.toString());

      await (await feeManagerContract.connect(guardian).updateUsersSLP()).wait();
      // await printFees(stableMasterEUR, managerBTC);
      await testKeeperUpdateFee(stableMasterEUR, managerBTC, expectedCollatRatio);
    });

    it('success - HAs are exiting', async () => {
      await (await perpEURBTC.connect(user).closePerpetual(1, user.address, parseAmount.ether('0'))).wait();
      await (await perpEURBTC.connect(user).closePerpetual(2, user.address, parseAmount.ether('0'))).wait();

      const expectedCollatRatio = PoolManagerStockInStable.mul(BASE_PARAMS).div(stableOut);

      const collatRatio = await stableMasterEUR.getCollateralRatio();

      expect(collatRatio.toString()).to.be.equal(expectedCollatRatio.toString());

      await (await feeManagerContract.connect(guardian).updateUsersSLP()).wait();
      await testKeeperUpdateFee(stableMasterEUR, managerBTC, expectedCollatRatio);
    });

    it('success - after oracle back to normal', async () => {
      const divisionOracle = BigNumber.from('5');
      await (await oracleBTC.connect(deployer).update(BASE_RATE.mul(BASE_ORACLE))).wait();

      PoolManagerStockInStable = PoolManagerStockInStable.mul(divisionOracle);
      const expectedCollatRatio = PoolManagerStockInStable.mul(BASE_PARAMS).div(stableOut);
      const collatRatio = await stableMasterEUR.getCollateralRatio();

      expect(collatRatio.toString()).to.be.equal(expectedCollatRatio.toString());

      await (await feeManagerContract.connect(guardian).updateUsersSLP()).wait();
      await testKeeperUpdateFee(stableMasterEUR, managerBTC, expectedCollatRatio);
    });
  });

  describe('Stable seekers, HA & SLP', function () {
    let PoolManagerStockInStable = BigNumber.from(0);
    let stableOut = BigNumber.from(0);

    before(async function () {
      ({ deployer, guardian, user } = await ethers.getNamedSigners());
      ({ ANGLE, stableMaster: stableMasterEUR, agToken: agEUR } = await initAngle(deployer, guardian));
      ({
        token: wBTC,
        oracle: oracleBTC,
        manager: managerBTC,
        feeManager: feeManagerContract,
        perpetualManager: perpEURBTC,
      } = await initCollateral('wBTC', stableMasterEUR, ANGLE, deployer, BigNumber.from(18), false));
      collatBASE = BigNumber.from(10).pow(BigNumber.from(18));

      await (await oracleBTC.connect(deployer).update(BASE_RATE.mul(BASE_ORACLE))).wait();

      await wBTC.connect(user).mint(user.address, parseAmount.ether(1000));
      await wBTC.connect(user).approve(stableMasterEUR.address, parseAmount.ether(1000));
      await wBTC.connect(user).approve(perpEURBTC.address, parseAmount.ether(1000));
    });

    it('success - after minting and cover', async () => {
      await (await stableMasterEUR.connect(user).mint(mintAmount, user.address, managerBTC.address, 0)).wait();
      await (
        await perpEURBTC
          .connect(user)
          .openPerpetual(
            user.address,
            broughtAmount,
            commitAmount,
            parseAmount.ether('10000000000000000'),
            parseAmount.ether(0),
          )
      ).wait();

      stableOut = mintAmount.mul(BigNumber.from(92)).div(BigNumber.from(100));
      PoolManagerStockInStable = mintAmount;
      PoolManagerStockInStable = PoolManagerStockInStable.add(broughtAmount);

      const expectedCollatRatio = PoolManagerStockInStable.mul(BASE_PARAMS).div(stableOut);

      await (await feeManagerContract.connect(guardian).updateUsersSLP()).wait();

      const collatRatio = await stableMasterEUR.getCollateralRatio();
      expect(collatRatio.toString()).to.be.equal(expectedCollatRatio.toString());

      await testKeeperUpdateFee(stableMasterEUR, managerBTC, expectedCollatRatio);

      // await printFees(stableMasterEUR, managerBTC);
    });

    it('success - after SLP enters with half BASE', async () => {
      await (await stableMasterEUR.connect(user).deposit(slpDeposit, user.address, managerBTC.address)).wait();

      PoolManagerStockInStable = PoolManagerStockInStable.add(slpDeposit);
      const expectedCollatRatio = PoolManagerStockInStable.mul(BASE_PARAMS).div(stableOut);

      const collatRatio = await stableMasterEUR.getCollateralRatio();

      expect(collatRatio.toString()).to.be.equal(expectedCollatRatio.toString());

      await (await feeManagerContract.connect(guardian).updateUsersSLP()).wait();
      // await printFees(stableMasterEUR, managerBTC);
      await testKeeperUpdateFee(stableMasterEUR, managerBTC, expectedCollatRatio);
    });

    it('success - oracle divided by 3', async () => {
      const divisionOracle = BigNumber.from('3');

      await (await oracleBTC.connect(deployer).update(BASE_RATE.mul(BASE_ORACLE).div(divisionOracle))).wait();

      PoolManagerStockInStable = PoolManagerStockInStable.div(divisionOracle);

      const expectedCollatRatio = PoolManagerStockInStable.mul(BASE_PARAMS).div(stableOut);
      const collatRatio = await stableMasterEUR.getCollateralRatio();

      expect(collatRatio.toString()).to.be.equal(expectedCollatRatio.toString());

      await (await feeManagerContract.connect(guardian).updateUsersSLP()).wait();
      // await printFees(stableMasterEUR, managerBTC);
      await testKeeperUpdateFee(stableMasterEUR, managerBTC, expectedCollatRatio);
    });

    it('success - SLP exit', async () => {
      const divisionOracle = BigNumber.from('3');
      await (
        await stableMasterEUR.connect(user).withdraw(slpDeposit, user.address, user.address, managerBTC.address)
      ).wait();

      const collatData = await stableMasterEUR.collateralMap(managerBTC.address);
      const sanRate = await collatData.sanRate;
      const slpData = await collatData.slpData;

      const slpWithdrawInStable = slpDeposit
        .mul(BASE_PARAMS.sub(slpData.slippage))
        .mul(sanRate)
        .div(BASE_PARAMS)
        .div(BASE)
        .div(divisionOracle);
      PoolManagerStockInStable = PoolManagerStockInStable.sub(slpWithdrawInStable);
      const expectedCollatRatio = PoolManagerStockInStable.mul(BASE_PARAMS).div(stableOut);

      const collatRatio = await stableMasterEUR.getCollateralRatio();

      expect(collatRatio.toString()).to.be.equal(expectedCollatRatio.toString());

      await (await feeManagerContract.connect(guardian).updateUsersSLP()).wait();
      await testKeeperUpdateFee(stableMasterEUR, managerBTC, expectedCollatRatio);
    });
  });
});

describe('Total User Fees ', function () {
  let coveredRatio = parseAmount.ether(0);
  let stockUser = parseAmount.ether(0);
  let coveredAmount = parseAmount.ether(0);

  before(async function () {
    ({ deployer, guardian, user, ha, slp } = await ethers.getNamedSigners());
    ({ ANGLE, stableMaster: stableMasterEUR, agToken: agEUR } = await initAngle(deployer, guardian));
    ({
      token: wBTC,
      oracle: oracleBTC,
      manager: managerBTC,
      feeManager: feeManagerContract,
      perpetualManager: perpEURBTC,
    } = await initCollateral('wBTC', stableMasterEUR, ANGLE, deployer, BigNumber.from(18), false));
    collatBASE = BigNumber.from(10).pow(BigNumber.from(18));

    // update stockuser with the true value
    maxAlock = await perpEURBTC.targetHAHedge();

    await (await oracleBTC.connect(deployer).update(BASE_RATE.mul(BASE_ORACLE))).wait();

    await wBTC.connect(user).mint(user.address, parseAmount.ether(1000));
    await wBTC.connect(user).approve(stableMasterEUR.address, parseAmount.ether(1000));
    await wBTC.connect(ha).mint(ha.address, parseAmount.ether(1000));
    await wBTC.connect(ha).approve(perpEURBTC.address, parseAmount.ether(1000));
    await wBTC.connect(slp).mint(slp.address, parseAmount.ether(1000));
    await wBTC.connect(slp).approve(stableMasterEUR.address, parseAmount.ether(1000));
  });

  it('reverts - overflow on amount', async () => {
    // fees are computed using the fee structure and what we had covered
    // There was before a `computeUserFees` function we could use
    const fee = BigNumber.from('80000000');

    await testMintBurnFee(true, stableMasterEUR, managerBTC, parseAmount.ether(0), fee);
  });

  it('success - 1st mint and cover a tenth', async () => {
    const fee = BigNumber.from('80000000');

    stockUser = stockUser.add(mintAmount).mul(BASE_RATE);
    coveredRatio = coveredAmount.mul(parseAmount.gwei(1)).div(stockUser);

    await testMintBurnFee(true, stableMasterEUR, managerBTC, coveredRatio, fee);

    stockUser.sub(mintAmount.mul(BASE_RATE).mul(fee).div(BASE));

    await (await stableMasterEUR.connect(user).mint(mintAmount, user.address, managerBTC.address, 0)).wait();
    await (
      await perpEURBTC
        .connect(ha)
        .openPerpetual(
          ha.address,
          broughtAmount,
          commitAmount,
          parseAmount.ether('10000000000000000'),
          parseAmount.ether(0),
        )
    ).wait();

    // update stockuser with the true value
    const collatData = await stableMasterEUR.collateralMap(managerBTC.address);
    stockUser = collatData.stocksUsers;

    // update values
    await (await feeManagerContract.connect(guardian).updateUsersSLP()).wait();
    const curRate = await oracleBTC.readUpper();
    coveredAmount = coveredAmount.add(commitAmount.mul(curRate).div(collatBASE));
  });

  it('success - after SLP enters with half BASE', async () => {
    await (await stableMasterEUR.connect(slp).deposit(slpDeposit, slp.address, managerBTC.address)).wait();
    await (await feeManagerContract.connect(guardian).updateUsersSLP()).wait();

    stockUser = stockUser.add(mintAmount.mul(BASE_RATE));
    const colFromUsersToCover = stockUser.mul(maxAlock).div(BASE_PARAMS);
    coveredRatio = coveredAmount.mul(parseAmount.gwei(1)).div(colFromUsersToCover);

    let collatData = await stableMasterEUR.collateralMap(managerBTC.address);

    const prevBalance = await agEUR.balanceOf(user.address);
    await (await stableMasterEUR.connect(user).mint(mintAmount, user.address, managerBTC.address, 0)).wait();
    const newBalance = await agEUR.balanceOf(user.address);
    const curOracle = await oracleBTC.readLower();
    const deltaStable = newBalance.sub(prevBalance);
    const trueFee = mintAmount.sub(deltaStable.mul(BASE).div(curOracle)).mul(BASE_PARAMS).div(mintAmount);
    await testMintBurnFee(true, stableMasterEUR, managerBTC, coveredRatio, trueFee);

    // update stockuser with the true value
    collatData = await stableMasterEUR.collateralMap(managerBTC.address);
    stockUser = collatData.stocksUsers;
  });

  it('success - oracle divided by 3', async () => {
    const divisionOracle = BigNumber.from('3');

    await (await oracleBTC.connect(deployer).update(BASE_RATE.mul(BASE_ORACLE).div(divisionOracle))).wait();
    await (await feeManagerContract.connect(guardian).updateUsersSLP()).wait();

    stockUser = stockUser.add(await oracleBTC.readQuoteLower(mintAmount));
    const colFromUsersToCover = stockUser.mul(maxAlock).div(BASE_PARAMS);
    coveredRatio = coveredAmount.mul(parseAmount.gwei(1)).div(colFromUsersToCover);

    let collatData = await stableMasterEUR.collateralMap(managerBTC.address);

    const prevBalance = await agEUR.balanceOf(user.address);
    await (await stableMasterEUR.connect(user).mint(mintAmount, user.address, managerBTC.address, 0)).wait();
    const newBalance = await agEUR.balanceOf(user.address);
    const curOracle = await oracleBTC.readLower();
    const deltaStable = newBalance.sub(prevBalance);
    const trueFee = mintAmount.sub(deltaStable.mul(BASE).div(curOracle)).mul(BASE_PARAMS).div(mintAmount);
    await testMintBurnFee(true, stableMasterEUR, managerBTC, coveredRatio, trueFee);

    // update stockuser with the true value
    collatData = await stableMasterEUR.collateralMap(managerBTC.address);
    stockUser = collatData.stocksUsers;
  });

  it('success - user exit partially', async () => {
    await (await oracleBTC.connect(deployer).update(BASE_RATE.mul(BASE_ORACLE))).wait();
    await (await feeManagerContract.connect(guardian).updateUsersSLP()).wait();

    stockUser = stockUser.sub(burnAmount);
    const colFromUsersToCover = stockUser.mul(maxAlock).div(BASE_PARAMS);
    coveredRatio = coveredAmount.mul(parseAmount.gwei(1)).div(colFromUsersToCover);

    let collatData = await stableMasterEUR.collateralMap(managerBTC.address);

    const prevBalance = await wBTC.balanceOf(user.address);
    await (
      await stableMasterEUR.connect(user).burn(burnAmount, user.address, user.address, managerBTC.address, 0)
    ).wait();
    const newBalance = await wBTC.balanceOf(user.address);
    const curOracle = await oracleBTC.readUpper();
    const deltaStable = newBalance.sub(prevBalance).mul(curOracle).div(collatBASE);
    const trueFee = BASE_PARAMS.sub(deltaStable.mul(BASE_PARAMS).div(burnAmount));
    await testMintBurnFee(false, stableMasterEUR, managerBTC, coveredRatio, trueFee);

    // update stockuser with the true value
    collatData = await stableMasterEUR.collateralMap(managerBTC.address);
    stockUser = collatData.stocksUsers;
  });
  it('success - SLP and HA exit User exit partially', async () => {
    const curOracle = await oracleBTC.readUpper();

    await (
      await stableMasterEUR.connect(slp).withdraw(slpDeposit, slp.address, slp.address, managerBTC.address)
    ).wait();
    await (await perpEURBTC.connect(ha).closePerpetual(1, ha.address, parseAmount.ether('0'))).wait();
    await (await feeManagerContract.connect(guardian).updateUsersSLP()).wait();
    coveredAmount = coveredAmount.sub(commitAmount.mul(curOracle).div(collatBASE));

    stockUser = stockUser.sub(burnAmount);
    const colFromUsersToCover = stockUser.mul(maxAlock).div(BASE_PARAMS);
    coveredRatio = BigNumber.from(0).mul(parseAmount.gwei(1)).div(colFromUsersToCover);

    const prevBalance = await wBTC.balanceOf(user.address);
    await (
      await stableMasterEUR.connect(user).burn(burnAmount, user.address, user.address, managerBTC.address, 0)
    ).wait();
    const newBalance = await wBTC.balanceOf(user.address);
    const deltaStable = newBalance.sub(prevBalance).mul(curOracle).div(collatBASE);
    const trueFee = BASE_PARAMS.sub(deltaStable.mul(BASE_PARAMS).div(burnAmount));
    await testMintBurnFee(false, stableMasterEUR, managerBTC, coveredRatio, trueFee);
  });
});

describe('Total ha fees', function () {
  let coveredRatio = parseAmount.ether(0);
  let stockUser = parseAmount.ether(0);
  let coveredAmount = parseAmount.ether(0);
  let nbrPerpetual = 0;

  before(async function () {
    ({ deployer, guardian, user, ha, slp } = await ethers.getNamedSigners());
    ({ ANGLE, stableMaster: stableMasterEUR, agToken: agEUR } = await initAngle(deployer, guardian));
    ({
      token: wBTC,
      oracle: oracleBTC,
      manager: managerBTC,
      feeManager: feeManagerContract,
      perpetualManager: perpEURBTC,
    } = await initCollateral('wBTC', stableMasterEUR, ANGLE, deployer, BigNumber.from(18), false));
    collatBASE = BigNumber.from(10).pow(BigNumber.from(18));

    // update stockuser with the true value
    maxAlock = await perpEURBTC.targetHAHedge();

    await (await oracleBTC.connect(deployer).update(BASE_RATE.mul(BASE_ORACLE))).wait();

    await wBTC.connect(user).mint(user.address, parseAmount.ether(1000));
    await wBTC.connect(user).approve(stableMasterEUR.address, parseAmount.ether(1000));
    await wBTC.connect(ha).mint(ha.address, parseAmount.ether(1000));
    await wBTC.connect(ha).approve(perpEURBTC.address, parseAmount.ether(1000));
    await wBTC.connect(slp).mint(slp.address, parseAmount.ether(1000));
    await wBTC.connect(slp).approve(stableMasterEUR.address, parseAmount.ether(1000));
  });
  it('success - 1st mint and cover a tenth', async () => {
    await (await stableMasterEUR.connect(user).mint(mintAmount, ha.address, managerBTC.address, 0)).wait();
    // update stockuser with the true value
    const collatData = await stableMasterEUR.collateralMap(managerBTC.address);
    stockUser = collatData.stocksUsers;
    const colFromUsersToCover = stockUser.mul(maxAlock).div(BASE_PARAMS);
    coveredAmount = coveredAmount.add(commitAmount.mul(BASE_RATE));
    coveredRatio = coveredAmount.mul(parseAmount.gwei(1)).div(colFromUsersToCover);

    await (
      await perpEURBTC
        .connect(ha)
        .openPerpetual(
          ha.address,
          broughtAmount,
          commitAmount,
          parseAmount.ether('10000000000000000'),
          parseAmount.ether(0),
        )
    ).wait();
    nbrPerpetual += 1;
    stockUser = collatData.stocksUsers;

    const perpUser = await perpEURBTC.perpetualData(nbrPerpetual);
    const netMargin = perpUser.margin;
    const trueFee = broughtAmount.sub(netMargin);
    await testHAFee(0, perpEURBTC, coveredRatio, trueFee, commitAmount);
  });
  it('success - HA cashout', async () => {
    const perpUser = await perpEURBTC.perpetualData(nbrPerpetual);
    const netMargin = perpUser.margin;

    const colFromUsersToCover = stockUser.mul(maxAlock).div(BASE);
    coveredRatio = coveredAmount
      .sub(commitAmount.mul(perpUser.entryRate).div(collatBASE))
      .mul(parseAmount.ether(1))
      .div(colFromUsersToCover);

    const prevBalance = await wBTC.balanceOf(ha.address);
    await (await perpEURBTC.connect(ha).closePerpetual(nbrPerpetual, ha.address, BigNumber.from(0))).wait();
    const newBalance = await wBTC.balanceOf(ha.address);

    const collatData = await stableMasterEUR.collateralMap(managerBTC.address);
    stockUser = collatData.stocksUsers;

    const trueFee = netMargin.sub(newBalance.sub(prevBalance));
    await testHAFee(1, perpEURBTC, coveredRatio, trueFee, commitAmount);
  });
});

async function testKeeperUpdateFee(
  contract: StableMasterFront,
  collateral: PoolManager,
  expectedCollateral: BigNumber,
) {
  const collatData = await contract.collateralMap(collateral.address);
  const feeData = await collatData.feeData;
  const slpData = await collatData.slpData;

  let expectedFee = piecewiseFunction(expectedCollateral, xBonusMalusMint, yBonusMalusMint);
  expect(feeData.bonusMalusMint.toString()).to.be.equal(expectedFee.toString());

  expectedFee = piecewiseFunction(expectedCollateral, xBonusMalusBurn, yBonusMalusBurn);
  expect(feeData.bonusMalusBurn.toString()).to.be.equal(expectedFee.toString());

  expectedFee = piecewiseFunction(expectedCollateral, xSlippage, ySlippage);
  expect(slpData.slippage.toString()).to.be.equal(expectedFee.toString());

  expectedFee = piecewiseFunction(expectedCollateral, xSlippageFee, ySlippageFee);
  expect(slpData.slippageFee.toString()).to.be.equal(expectedFee.toString());
}

async function testMintBurnFee(
  mint: boolean,
  contract: StableMasterFront,
  collateral: PoolManager,
  coveredRatio: BigNumber,
  incuredFee: BigNumber,
) {
  const collatData = await contract.collateralMap(collateral.address);
  const feeData = await collatData.feeData;

  let personalFee: BigNumber;
  let globalFee: BigNumber;
  if (mint) {
    personalFee = piecewiseFunction(coveredRatio, xFeeMint, yFeeMint);
    globalFee = feeData.bonusMalusMint;
  } else {
    personalFee = piecewiseFunction(coveredRatio, xFeeBurn, yFeeBurn);
    globalFee = feeData.bonusMalusBurn;
  }
  const expectedFee = personalFee.mul(globalFee).div(parseAmount.gwei(1));
  // we approximate by an order of 10 (which means precision of 10**17 if working in BASE = 10**18)
  // because the incurred fee is computed with the round on the other side
  const orderApprox = BigNumber.from(1);
  expect(incuredFee.div(orderApprox).toString()).to.be.equal(expectedFee.div(orderApprox).toString());
}

async function testHAFee(
  action: number,
  contract: PerpetualManagerFront,
  coveredRatio: BigNumber,
  incuredPaidFee: BigNumber,
  commit: BigNumber,
) {
  let personalFee: BigNumber;
  let globalFee: BigNumber;
  switch (action) {
    // this to add
    case 0: {
      personalFee = piecewiseFunction(coveredRatio, xHAFeesDeposit, yHAFeesDeposit);
      globalFee = await contract.haBonusMalusDeposit();
      break;
    }
    // this to remove
    case 1: {
      personalFee = piecewiseFunction(coveredRatio, xHAFeesWithdraw, yHAFeesWithdraw);
      globalFee = await contract.haBonusMalusWithdraw();
      break;
    }
    // this to liquidate
    default: {
      // to be changed
      personalFee = piecewiseFunction(coveredRatio, xHAFeesWithdraw, yHAFeesWithdraw);
      globalFee = await contract.haBonusMalusWithdraw();
      break;
    }
  }
  const expectedFee = personalFee.mul(globalFee).div(parseAmount.gwei(1));
  const expectedPaidFee = commit.mul(expectedFee).div(parseAmount.gwei(1));
  expect(incuredPaidFee.toString()).to.be.equal(expectedPaidFee.toString());
}
