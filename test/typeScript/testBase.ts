import { ethers, expect } from 'hardhat';
import { BigNumber } from 'ethers';
import { parseAmount, gwei, mwei } from '../../utils/bignumber';
import { SignerWithAddress } from '@nomiclabs/hardhat-ethers/dist/src/signers';

// we import our utilities

import {
  PoolManager,
  StableMasterFront,
  MockToken,
  MockANGLE,
  SanToken,
  AgToken,
  PerpetualManagerFront,
} from '../../typechain';

import {
  // functions
  initAngle,
  initCollateral,
} from './helpers';

let ANGLE: MockANGLE;
let stableMasterEUR: StableMasterFront;
let agEUR: AgToken;

let wBTC: MockToken;
let managerBTC: PoolManager;
let sanTokenBTC: SanToken;
let perpEURBTC: PerpetualManagerFront;

let DAI: MockToken;
let managerDAI: PoolManager;
let sanTokenDAI: SanToken;
let perpEURDAI: PerpetualManagerFront;

let deployer: SignerWithAddress;
let guardian: SignerWithAddress;
let user: SignerWithAddress;
let ha: SignerWithAddress;

describe('Testing collateral with different bases ', function () {
  describe('Users, HAs and SLPs', function () {
    before(async function () {
      ({ deployer, guardian, user, ha } = await ethers.getNamedSigners());
      ({ ANGLE, stableMaster: stableMasterEUR, agToken: agEUR } = await initAngle(deployer, guardian));
      ({
        token: wBTC,
        manager: managerBTC,
        sanToken: sanTokenBTC,
        perpetualManager: perpEURBTC,
      } = await initCollateral('wBTC', stableMasterEUR, ANGLE, deployer, BigNumber.from(9), true));

      ({
        token: DAI,
        manager: managerDAI,
        sanToken: sanTokenDAI,
        perpetualManager: perpEURDAI,
      } = await initCollateral('DAI', stableMasterEUR, ANGLE, deployer, BigNumber.from(6), true));

      await wBTC.connect(user).mint(user.address, gwei(1000));
      await DAI.connect(user).mint(user.address, mwei(1000));
      await wBTC.connect(ha).mint(ha.address, gwei(1000));
      await DAI.connect(ha).mint(ha.address, mwei(1000));

      await wBTC.connect(user).approve(stableMasterEUR.address, gwei(1000));
      await DAI.connect(user).approve(stableMasterEUR.address, mwei(1000));
      await wBTC.connect(ha).approve(stableMasterEUR.address, gwei(1000));
      await DAI.connect(ha).approve(stableMasterEUR.address, mwei(1000));

      await wBTC.connect(user).approve(perpEURBTC.address, gwei(1000));
      await DAI.connect(user).approve(perpEURDAI.address, mwei(1000));
      await wBTC.connect(ha).approve(perpEURBTC.address, gwei(1000));
      await DAI.connect(ha).approve(perpEURDAI.address, mwei(1000));

      this.countPerpBTC = BigNumber.from('0');
      this.countPerpDAI = BigNumber.from('0');
    });

    it('mint success - correct balances', async function () {
      await stableMasterEUR.connect(user).mint(gwei('1'), user.address, managerBTC.address, 0);
      expect((await agEUR.balanceOf(user.address)).toString()).to.be.equal(parseAmount.ether('0.9').toString());

      await stableMasterEUR.connect(user).mint(mwei('1'), user.address, managerDAI.address, 0);
      expect((await agEUR.balanceOf(user.address)).toString()).to.be.equal(parseAmount.ether('1.8').toString());
    });

    it('deposit success - correct balances', async function () {
      await stableMasterEUR.connect(user).deposit(gwei('1'), user.address, managerBTC.address);
      expect((await sanTokenBTC.balanceOf(user.address)).toString()).to.be.equal(gwei('1').toString());

      await stableMasterEUR.connect(user).deposit(mwei('1'), user.address, managerDAI.address);
      expect((await sanTokenDAI.balanceOf(user.address)).toString()).to.be.equal(mwei('1').toString());
    });

    it('openPerpetual success - correct perpetual data BTC', async function () {
      await perpEURBTC
        .connect(ha)
        .openPerpetual(
          ha.address,
          gwei('1'),
          gwei('0.8'),
          parseAmount.ether('10000000000000000'),
          parseAmount.ether(0),
        );
      this.countPerpBTC = this.countPerpBTC.add(BigNumber.from('1'));
      const perpBTC = await perpEURBTC.connect(ha).perpetualData(this.countPerpBTC);
      this.netAmountBTC = gwei('1').sub(gwei('0.8').mul(BigNumber.from('1')).div(BigNumber.from('100')));
      expect(perpBTC.entryRate.toString()).to.be.equal(parseAmount.ether('1').toString());
      expect(perpBTC.margin.toString()).to.be.equal(this.netAmountBTC.toString());
      expect(perpBTC.committedAmount.toString()).to.be.equal(gwei('0.8').toString());
    });
    it('success - correct balance HA BTC', async function () {
      this.balanceHABTC = gwei(1000).sub(gwei(1));
      expect((await wBTC.balanceOf(ha.address)).toString()).to.be.equal(this.balanceHABTC.toString());
    });

    it('openPerpetual success - correct perpetual data DAI', async function () {
      await perpEURDAI
        .connect(ha)
        .openPerpetual(
          ha.address,
          mwei('1'),
          mwei('0.8'),
          parseAmount.ether('10000000000000000'),
          parseAmount.ether(0),
        );
      this.countPerpDAI = this.countPerpDAI.add(BigNumber.from('1'));
      const perpDAI = await perpEURDAI.perpetualData(this.countPerpDAI);
      this.netAmountDAI = mwei('1').sub(mwei('0.8').mul(BigNumber.from('1')).div(BigNumber.from('100')));
      expect(perpDAI.entryRate.toString()).to.be.equal(parseAmount.ether('1').toString());
      expect(perpDAI.margin.toString()).to.be.equal(this.netAmountDAI.toString());
      expect(perpDAI.committedAmount.toString()).to.be.equal(mwei('0.8').toString());
    });

    it('success - HAs - correct balance HA DAI', async function () {
      this.balanceHADAI = mwei(1000).sub(mwei(1));
      expect((await DAI.balanceOf(ha.address)).toString()).to.be.equal(this.balanceHADAI.toString());
    });

    it('addToPerpetual - success BTC', async function () {
      await perpEURBTC.connect(ha).addToPerpetual(this.countPerpBTC, gwei('1'));
      const perpBTC = await perpEURBTC.connect(ha).perpetualData(this.countPerpBTC);
      this.netAmountBTC = this.netAmountBTC.add(gwei('1'));
      expect(perpBTC.entryRate.toString()).to.be.equal(parseAmount.ether('1').toString());
      expect(perpBTC.margin.toString()).to.be.equal(this.netAmountBTC.toString());
      expect(perpBTC.committedAmount.toString()).to.be.equal(gwei('0.8').toString());
    });
    it('success - HAs - correct balance HA BTC', async function () {
      this.balanceHABTC = this.balanceHABTC.sub(gwei(1));
      expect((await wBTC.balanceOf(ha.address)).toString()).to.be.equal(this.balanceHABTC.toString());
    });

    it('addToPerpetual success - HA DAI', async function () {
      await perpEURDAI.connect(ha).addToPerpetual(this.countPerpDAI, mwei('1'));
      const perpDAI = await perpEURDAI.connect(ha).perpetualData(this.countPerpDAI);
      this.netAmountDAI = this.netAmountDAI.add(mwei('1'));
      this.feesDAI = mwei('2').sub(this.netAmountDAI);
      expect(perpDAI.entryRate.toString()).to.be.equal(parseAmount.ether('1').toString());
      expect(perpDAI.margin.toString()).to.be.equal(this.netAmountDAI.toString());
      expect(perpDAI.committedAmount.toString()).to.be.equal(mwei('0.8').toString());
    });
    it('success - HAs - correct balance HA DAI', async function () {
      this.balanceHADAI = this.balanceHADAI.sub(mwei(1));
      expect((await DAI.balanceOf(ha.address)).toString()).to.be.equal(this.balanceHADAI.toString());
    });

    it('removeFromPerpetual success - HA BTC', async function () {
      await perpEURBTC.connect(ha).removeFromPerpetual(this.countPerpBTC, gwei('1'), ha.address);
      const perpBTC = await perpEURBTC.connect(ha).perpetualData(this.countPerpBTC);
      this.netAmountBTC = this.netAmountBTC.sub(gwei('1'));
      expect(perpBTC.entryRate.toString()).to.be.equal(parseAmount.ether('1').toString());
      expect(perpBTC.margin.toString()).to.be.equal(this.netAmountBTC.toString());
      expect(perpBTC.committedAmount.toString()).to.be.equal(gwei('0.8').toString());
    });

    it('success - HAs - correct balance HA BTC', async function () {
      this.balanceHABTC = this.balanceHABTC.add(gwei('1'));
      expect((await wBTC.balanceOf(ha.address)).toString()).to.be.equal(this.balanceHABTC.toString());
    });

    it('removeFromPerpetual success - HA DAI', async function () {
      await perpEURDAI.connect(ha).removeFromPerpetual(this.countPerpDAI, mwei('1'), ha.address);
      const perpDAI = await perpEURDAI.connect(ha).perpetualData(this.countPerpDAI);
      this.netAmountDAI = this.netAmountDAI.sub(mwei('1'));
      this.feesDAI = this.feesDAI.add(mwei('1').div(BigNumber.from('100')));
      expect(perpDAI.entryRate.toString()).to.be.equal(parseAmount.ether('1').toString());
      expect(perpDAI.margin.toString()).to.be.equal(this.netAmountDAI.toString());
      expect(perpDAI.committedAmount.toString()).to.be.equal(mwei('0.8').toString());
    });
    it('success - correct balance HA DAI', async function () {
      this.balanceHADAI = this.balanceHADAI.add(mwei(1));
      expect((await DAI.balanceOf(ha.address)).toString()).to.be.equal(this.balanceHADAI.toString());
    });

    it('closePerpetual success - HA BTC', async function () {
      await perpEURBTC.connect(ha).closePerpetual(this.countPerpBTC, ha.address, parseAmount.ether('0'));
      this.balanceHABTC = this.balanceHABTC.add(
        this.netAmountBTC.sub(gwei('0.8').mul(BigNumber.from('1')).div(BigNumber.from('100'))),
      );
      expect((await wBTC.balanceOf(ha.address)).toString()).to.be.equal(this.balanceHABTC.toString());
    });

    it('closePerpetual success - HA DAI', async function () {
      await perpEURDAI.connect(ha).closePerpetual(this.countPerpDAI, ha.address, parseAmount.ether('0'));
      this.balanceHADAI = this.balanceHADAI.add(
        this.netAmountDAI.sub(mwei('0.8').mul(BigNumber.from('1')).div(BigNumber.from('100'))),
      );
      expect((await DAI.balanceOf(ha.address)).toString()).to.be.equal(this.balanceHADAI.toString());
    });

    it('openPerpetual success - new perp BTC', async function () {
      await perpEURBTC
        .connect(ha)
        .openPerpetual(
          ha.address,
          gwei('1'),
          gwei('0.8'),
          parseAmount.ether('10000000000000000'),
          parseAmount.ether(0),
        );
      this.countPerpBTC = this.countPerpBTC.add(BigNumber.from('1'));
      this.balanceHABTC = this.balanceHABTC.sub(gwei('1'));
      expect((await wBTC.balanceOf(ha.address)).toString()).to.be.equal(this.balanceHABTC.toString());
    });
    it('burn success - partially exit stable seeker', async function () {
      await stableMasterEUR
        .connect(user)
        .burn(parseAmount.ether('0.5'), user.address, user.address, managerBTC.address, 0);
    });
    it('forceClosePerpetuals success - perpetual cashed out', async function () {
      await perpEURBTC.connect(guardian).forceClosePerpetuals([this.countPerpBTC]);
      this.balanceHABTC = this.balanceHABTC
        .add(gwei('1'))
        .sub(gwei('0.8').mul(BigNumber.from('2')).div(BigNumber.from('100')));
      expect((await wBTC.balanceOf(ha.address)).toString()).to.be.equal(this.balanceHABTC.toString());
    });

    it('openPerpetual - new perp BTC', async function () {
      await perpEURBTC
        .connect(ha)
        .openPerpetual(
          ha.address,
          gwei('1'),
          gwei('0.3'),
          parseAmount.ether('10000000000000000'),
          parseAmount.ether(0),
        );
      this.countPerpBTC = this.countPerpBTC.add(BigNumber.from('1'));
      this.balanceHABTC = this.balanceHABTC.sub(gwei('1'));
      expect((await wBTC.balanceOf(ha.address)).toString()).to.be.equal(this.balanceHABTC.toString());
    });
  });
});
