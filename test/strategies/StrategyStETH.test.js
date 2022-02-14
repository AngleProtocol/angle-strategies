const balance = require('@openzeppelin/test-helpers/src/balance');
const { ZERO_ADDRESS } = require('@openzeppelin/test-helpers/src/constants');
const { BN } = require('@openzeppelin/test-helpers/src/setup');
const { ethers } = require('hardhat');
const {
  // utils
  ether,
  expectRevert,
  expect,
  BASE,
  BASE_PARAMS,
  // functions
  initAngle,
  initWETH,
  StrategyStETHAcc,
} = require('../helpers');

// Start test block
contract('StrategyStETH', accounts => {
  const [governor, guardian, user, tester] = accounts;

  before(async () => {
    [this.owner] = await ethers.getSigners();
    [this.core, this.ANGLE, this.stableMaster, this.agEUR] = await initAngle(governor, guardian);
    [
      this.wETH,
      this.oracleETH,
      this.managerETH,
      this.sanETH_EUR,
      this.perpetualManagerETH,
      this.feeManagerETH,
      this.stETH,
      this.curve,
      this.strategy,
    ] = await initWETH(this.stableMaster, this.ANGLE, governor, guardian);

    this.minWindow = new BN('1000');

    this.maxWindow = new BN('10000');
    this.blocksPerYear = new BN('2350000');
  });

  describe('Initialization', () => {
    describe('Parameters', () => {
      it('poolManager', async () => {
        expect(await this.strategy.poolManager()).to.be.equal(this.managerETH.address);
      });
      it('want', async () => {
        expect(await this.strategy.want()).to.be.equal(this.wETH.address);
      });
      it('rewards', async () => {
        expect(await this.strategy.rewards()).to.be.equal(this.ANGLE.address);
      });
      it('stETH', async () => {
        expect(await this.strategy.stETH()).to.be.equal(this.stETH.address);
      });
      it('wETH', async () => {
        expect(await this.strategy.weth()).to.be.equal(this.wETH.address);
      });
      it('stableSwapSTETH', async () => {
        expect(await this.strategy.stableSwapSTETH()).to.be.equal(this.curve.address);
      });
      it('BASE', async () => {
        expect(await this.strategy.BASE()).to.be.bignumber.equal(BASE);
      });
      it('apr', async () => {
        expect(await this.strategy.apr()).to.be.bignumber.equal(new BN('0'));
      });
      it('SECONDSPERYEAR', async () => {
        expect(await this.strategy.SECONDSPERYEAR()).to.be.bignumber.equal(new BN('31556952'));
      });
      it('DENOMINATOR', async () => {
        expect(await this.strategy.DENOMINATOR()).to.be.bignumber.equal(new BN('10000'));
      });
      it('debtThreshold', async () => {
        expect(await this.strategy.debtThreshold()).to.be.bignumber.equal(BASE.mul(new BN('100')));
      });
      it('maxSingleTrade', async () => {
        expect(await this.strategy.maxSingleTrade()).to.be.bignumber.equal(BASE.mul(new BN('1000')));
      });
      it('slippageProtectionOut', async () => {
        expect(await this.strategy.slippageProtectionOut()).to.be.bignumber.equal(new BN('50'));
      });
      it('minReportDelay', async () => {
        expect(await this.strategy.minReportDelay()).to.be.bignumber.equal(new BN('0'));
      });
      it('maxReportDelay', async () => {
        expect(await this.strategy.maxReportDelay()).to.be.bignumber.equal(new BN('86400'));
      });
      it('minimumAmountMoved', async () => {
        expect(await this.strategy.minimumAmountMoved()).to.be.bignumber.equal(new BN('0'));
      });
      it('rewardAmount', async () => {
        expect(await this.strategy.rewardAmount()).to.be.bignumber.equal(new BN('0'));
      });
      it('emergencyExit', async () => {
        expect(await this.strategy.emergencyExit()).to.be.equal(false);
      });
      it('allowance - wETH', async () => {
        expect(await this.wETH.allowance(this.strategy.address, this.managerETH.address)).to.be.bignumber.equal(
          new BN(2).pow(new BN(256)).sub(new BN(1)),
        );
      });
      it('allowance - stETH', async () => {
        expect(await this.stETH.allowance(this.strategy.address, this.curve.address)).to.be.bignumber.equal(
          new BN(2).pow(new BN(256)).sub(new BN(1)),
        );
      });
    });

    describe('constructor', () => {
      it('reverts - zero guardian address', async () => {
        await expectRevert(
          StrategyStETHAcc.new(
            this.managerETH.address,
            this.ANGLE.address,
            [governor],
            ZERO_ADDRESS,
            this.curve.address,
            this.wETH.address,
            this.stETH.address,
          ),
          '0',
        );
      });
      it('reverts - zero governor address', async () => {
        await expectRevert(
          StrategyStETHAcc.new(
            this.managerETH.address,
            this.ANGLE.address,
            [ZERO_ADDRESS],
            guardian,
            this.curve.address,
            this.wETH.address,
            this.stETH.address,
          ),
          '0',
        );
      });
      it('reverts - zero reward address', async () => {
        await expectRevert(
          StrategyStETHAcc.new(
            this.managerETH.address,
            ZERO_ADDRESS,
            [governor],
            guardian,
            this.curve.address,
            this.wETH.address,
            this.stETH.address,
          ),
          '0',
        );
      });
      it('reverts - want != weth', async () => {
        await expectRevert(
          StrategyStETHAcc.new(
            this.managerETH.address,
            this.ANGLE.address,
            [governor],
            guardian,
            this.curve.address,
            this.stETH.address,
            this.stETH.address,
          ),
          '20',
        );
      });
      it('reverts - rewards != want', async () => {
        await expectRevert(
          StrategyStETHAcc.new(
            this.managerETH.address,
            this.wETH.address,
            [governor],
            guardian,
            this.curve.address,
            this.wETH.address,
            this.stETH.address,
          ),
          '92',
        );
      });
    });

    describe('AccessControl', () => {
      it('guardian role', async () => {
        this.guardianRole = web3.utils.soliditySha3('GUARDIAN_ROLE');
        this.managerRole = web3.utils.soliditySha3('POOLMANAGER_ROLE');
        this.guardianError = `AccessControl: account ${user.toLowerCase()} is missing role ${this.guardianRole}`;
        this.managerError = `AccessControl: account ${user.toLowerCase()} is missing role ${this.managerRole}`;

        expect(await this.strategy.hasRole(web3.utils.soliditySha3('GUARDIAN_ROLE'), guardian)).to.be.equal(true);
        expect(await this.strategy.hasRole(web3.utils.soliditySha3('GUARDIAN_ROLE'), governor)).to.be.equal(true);
      });
      it('manager role', async () => {
        expect(
          await this.strategy.hasRole(web3.utils.soliditySha3('POOLMANAGER_ROLE'), this.managerETH.address),
        ).to.be.equal(true);
      });
      it('withdraw - reverts nonManager', async () => {
        await expectRevert(this.strategy.withdraw(BASE, { from: user }), this.managerError);
      });
      it('addGuardian - reverts nonManager', async () => {
        await expectRevert(this.strategy.addGuardian(this.wETH.address, { from: user }), this.managerError);
      });
      it('revokeGuardian - reverts nonManager', async () => {
        await expectRevert(this.strategy.revokeGuardian(this.wETH.address, { from: user }), this.managerError);
      });
      it('setEmergencyExit - reverts nonManager', async () => {
        await expectRevert(this.strategy.setEmergencyExit({ from: user }), this.managerError);
      });
      it('setRewards - reverts nonGuardian', async () => {
        await expectRevert(this.strategy.setRewards(this.wETH.address, { from: user }), this.guardianError);
      });
      it('setRewardAmount - reverts nonGuardian', async () => {
        await expectRevert(
          this.strategy.setRewardAmountAndMinimumAmountMoved(BASE, BASE, { from: user }),
          this.guardianError,
        );
      });
      it('setMinReportDelay - reverts nonGuardian', async () => {
        await expectRevert(this.strategy.setMinReportDelay(BASE, { from: user }), this.guardianError);
      });
      it('setMaxReportDelay - reverts nonGuardian', async () => {
        await expectRevert(this.strategy.setMaxReportDelay(BASE, { from: user }), this.guardianError);
      });
      it('setDebtThreshold - reverts nonGuardian', async () => {
        await expectRevert(this.strategy.setDebtThreshold(BASE, { from: user }), this.guardianError);
      });
      it('sweep - reverts nonGuardian', async () => {
        await expectRevert(this.strategy.sweep(this.wETH.address, user, { from: user }), this.guardianError);
      });
      it('updateReferral - reverts nonGuardian', async () => {
        await expectRevert(this.strategy.updateReferral(this.wETH.address, { from: user }), this.guardianError);
      });
      it('updateMaxSingleTrade - reverts nonGuardian', async () => {
        await expectRevert(this.strategy.updateMaxSingleTrade(new BN('0'), { from: user }), this.guardianError);
      });
      it('setApr - reverts nonGuardian', async () => {
        await expectRevert(this.strategy.setApr(new BN('0'), { from: user }), this.guardianError);
      });
      it('updateSlippageProtectionOut - reverts nonGuardian', async () => {
        await expectRevert(this.strategy.updateSlippageProtectionOut(new BN('0'), { from: user }), this.guardianError);
      });
      it('invest - reverts nonGuardian', async () => {
        await expectRevert(this.strategy.invest(new BN('0'), { from: user }), this.guardianError);
      });
      it('rescueStuckEth - reverts nonGuardian', async () => {
        await expectRevert(this.strategy.rescueStuckEth({ from: user }), this.guardianError);
      });
    });
  });

  describe('debtRatio', () => {
    it('success - set correctly for strategy', async () => {
      const debtRatio = (await this.managerETH.strategies(this.strategy.address)).debtRatio;
      expect(debtRatio).to.be.bignumber.equal(BASE_PARAMS.mul(new BN('8')).div(new BN('10')));
    });
    it('success - set correctly for manager', async () => {
      expect(await this.managerETH.debtRatio()).to.be.bignumber.equal(BASE_PARAMS.mul(new BN('8')).div(new BN('10')));
    });
  });

  describe('setGuardian - when there is a strategy', () => {
    it('success - adding a new guardian', async () => {
      await this.core.setGuardian(tester, { from: governor });
      expect(await this.managerETH.hasRole(web3.utils.soliditySha3('GUARDIAN_ROLE'), tester)).to.be.equal(true);
      expect(await this.managerETH.hasRole(web3.utils.soliditySha3('GUARDIAN_ROLE'), guardian)).to.be.equal(false);
    });
    it('success - resetting guardian', async () => {
      await this.core.setGuardian(guardian, { from: governor });
    });
  });

  describe('estimatedAPR', () => {
    it('success - returns 0 when no asset', async () => {
      expect(await this.strategy.estimatedAPR()).to.be.bignumber.equal(new BN('0'));
    });
  });

  describe('initializing contracts', () => {
    it('success - send ETH and wETH to curve', async () => {
      await this.owner.sendTransaction({
        to: this.curve.address,
        value: ethers.utils.parseEther('10'),
      });
      await this.owner.sendTransaction({
        to: this.wETH.address,
        value: ethers.utils.parseEther('10'),
      });
      await this.stETH.mint(this.curve.address, BASE.mul(new BN('10')));
    });
  });
  describe('harvest', () => {
    it('init - minting on poolManager', async () => {
      await this.wETH.mint(this.managerETH.address, ether('10'));
      expect(await this.wETH.balanceOf(this.managerETH.address)).to.be.bignumber.equal(BASE.mul(new BN('10')));
    });

    it('success - lent assets updated', async () => {
      const balance2 = await balance.current(this.curve.address);
      await this.strategy.harvest();
      // Still 10 total assets
      expect(await this.managerETH.getTotalAsset()).to.be.bignumber.equal(ether('10'));
      // But 8 lent from manager to strategy
      expect(await this.wETH.balanceOf(this.managerETH.address)).to.be.bignumber.equal(ether('2'));
      expect(await this.strategy.estimatedTotalAssets()).to.be.bignumber.equal(ether('8'));
      // These 8 are then given to the lender
      expect(await this.wETH.balanceOf(this.strategy.address)).to.be.bignumber.equal(ether('0'));
      expect(await this.stETH.balanceOf(this.strategy.address)).to.be.bignumber.equal(ether('8'));
      expect(await this.strategy.wantBalance()).to.be.bignumber.equal(ether('0'));
      expect(await this.strategy.stethBalance()).to.be.bignumber.equal(ether('8'));
      expect(await this.managerETH.totalDebt()).to.be.bignumber.equal(ether('8'));
      expect((await this.managerETH.strategies(this.strategy.address)).totalStrategyDebt).to.be.bignumber.equal(
        ether('8'),
      );
      expect(await balance.current(this.curve.address)).to.be.bignumber.equal(balance2.add(ether('8')));
    });

    it('setting - creation of debt for the strategy', async () => {
      await this.managerETH.updateStrategyDebtRatio(
        this.strategy.address,
        BASE_PARAMS.mul(new BN('5')).div(new BN('10')),
        { from: governor },
      );
      expect((await this.managerETH.strategies(this.strategy.address)).debtRatio).to.be.bignumber.equal(
        BASE_PARAMS.mul(new BN('5')).div(new BN('10')),
      );
      expect(await this.managerETH.getTotalAsset()).to.be.bignumber.equal(ether('10'));
    });
    it('success - manager debt ratio check', async () => {
      expect(await this.managerETH.debtRatio()).to.be.bignumber.equal(BASE_PARAMS.mul(new BN('5')).div(new BN('10')));
    });

    it('updateStrategyDebtRatio reverts', async () => {
      await expectRevert(
        this.managerETH.updateStrategyDebtRatio(tester, BASE_PARAMS.mul(new BN('5')).div(new BN('10')), {
          from: governor,
        }),
        '78',
      );
      await expectRevert(
        this.managerETH.updateStrategyDebtRatio(
          this.strategy.address,
          BASE_PARAMS.mul(new BN('11')).div(new BN('10')),
          { from: governor },
        ),
        '76',
      );
    });
    it('success - harvesting with debt', async () => {
      await this.strategy.harvest();
      // 3 have been withdrawn from strat
      expect(await this.wETH.balanceOf(this.managerETH.address)).to.be.bignumber.equal(ether('5'));

      // Still 10 total assets
      expect(await this.managerETH.getTotalAsset()).to.be.bignumber.equal(ether('10'));
      expect(await this.wETH.balanceOf(this.strategy.address)).to.be.bignumber.equal(ether('0'));
      expect(await this.stETH.balanceOf(this.strategy.address)).to.be.bignumber.equal(ether('5'));
      expect(await this.strategy.estimatedTotalAssets()).to.be.bignumber.equal(ether('5'));
    });
    it('success - resetting everything', async () => {
      await this.managerETH.updateStrategyDebtRatio(
        this.strategy.address,
        BASE_PARAMS.mul(new BN('0')).div(new BN('10')),
        { from: governor },
      );
      expect((await this.managerETH.strategies(this.strategy.address)).debtRatio).to.be.bignumber.equal(
        BASE_PARAMS.mul(new BN('0')).div(new BN('10')),
      );
      expect(await this.managerETH.getTotalAsset()).to.be.bignumber.equal(ether('10'));
      expect(await this.managerETH.debtRatio()).to.be.bignumber.equal(BASE_PARAMS.mul(new BN('0')).div(new BN('10')));
      await this.strategy.harvest();
      // 3 have been withdrawn from strat
      expect(await this.wETH.balanceOf(this.managerETH.address)).to.be.bignumber.equal(ether('10'));

      // Still 10 total assets
      expect(await this.managerETH.getTotalAsset()).to.be.bignumber.equal(ether('10'));
      expect(await this.wETH.balanceOf(this.strategy.address)).to.be.bignumber.equal(ether('0'));
      expect(await this.stETH.balanceOf(this.strategy.address)).to.be.bignumber.equal(ether('0'));
      expect(await this.strategy.estimatedTotalAssets()).to.be.bignumber.equal(ether('0'));
    });
    it('success - increasing back again debt ratios and setting dy', async () => {
      await this.managerETH.updateStrategyDebtRatio(
        this.strategy.address,
        BASE_PARAMS.mul(new BN('8')).div(new BN('10')),
        { from: governor },
      );
      // In this situation, we should use the Lido way
      await this.curve.setDy(BASE.mul(new BN('9')).div(new BN('10')));
    });
    it('success - harvest using the Lido circuit', async () => {
      const balance2 = await balance.current(this.curve.address);
      await this.strategy.harvest();
      // Still 10 total assets
      expect(await this.managerETH.getTotalAsset()).to.be.bignumber.equal(ether('10'));
      // But 8 lent from manager to strategy
      expect(await this.wETH.balanceOf(this.managerETH.address)).to.be.bignumber.equal(ether('2'));
      expect(await this.strategy.estimatedTotalAssets()).to.be.bignumber.equal(ether('8'));
      // These 8 are then given to the lender
      expect(await this.wETH.balanceOf(this.strategy.address)).to.be.bignumber.equal(ether('0'));
      expect(await this.stETH.balanceOf(this.strategy.address)).to.be.bignumber.equal(ether('8'));
      expect(await this.managerETH.totalDebt()).to.be.bignumber.equal(ether('8'));
      expect((await this.managerETH.strategies(this.strategy.address)).totalStrategyDebt).to.be.bignumber.equal(
        ether('8'),
      );
      // The amount of ETH on Curve should not have changed in this situation
      expect(await balance.current(this.curve.address)).to.be.bignumber.equal(balance2);
      // Setting reward back to normal
      await this.curve.setDy(BASE);
    });
    it('success - recording a gain', async () => {
      // Minting two stETH meaning there is an increase
      await this.stETH.mint(this.strategy.address, ether('2'));
      expect(await this.stETH.balanceOf(this.strategy.address)).to.be.bignumber.equal(ether('10'));
    });
    it('success - harvesting after a gain', async () => {
      // There is 12 in total assets now, 0.8 * 12 should go to the strategy, the rest to the poolManager
      await this.strategy.harvest();
      expect(await this.managerETH.getTotalAsset()).to.be.bignumber.equal(ether('12'));
      // But 8 lent from manager to strategy
      expect(await this.wETH.balanceOf(this.managerETH.address)).to.be.bignumber.equal(ether('2.4'));
      expect(await this.strategy.estimatedTotalAssets()).to.be.bignumber.equal(ether('9.6'));
      // These 8 are then given to the lender
      expect(await this.wETH.balanceOf(this.strategy.address)).to.be.bignumber.equal(ether('0'));
      expect(await this.stETH.balanceOf(this.strategy.address)).to.be.bignumber.equal(ether('9.6'));
      expect(await this.managerETH.totalDebt()).to.be.bignumber.equal(ether('9.6'));
      expect((await this.managerETH.strategies(this.strategy.address)).totalStrategyDebt).to.be.bignumber.equal(
        ether('9.6'),
      );
    });
    it('success - recording a loss', async () => {
      await this.stETH.burn(this.strategy.address, ether('2'));
      await this.strategy.harvest();
      expect(await this.managerETH.getTotalAsset()).to.be.bignumber.equal(ether('10'));
      expect(await this.managerETH.debtRatio()).to.be.bignumber.equal(BASE_PARAMS.mul(new BN('8')).div(new BN('10')));
      // Still 10 total assets
      expect(await this.wETH.balanceOf(this.strategy.address)).to.be.bignumber.equal(ether('0'));
      expect(await this.stETH.balanceOf(this.strategy.address)).to.be.bignumber.equal(ether('8'));
      expect(await this.strategy.estimatedTotalAssets()).to.be.bignumber.equal(ether('8'));
    });
  });
  describe('withdraw', () => {
    it('reverts - invalid strategy', async () => {
      await expectRevert(this.managerETH.withdrawFromStrategy(governor, ether('1'), { from: governor }), '78');
    });
    it('success - wantBal < _amountNeeded', async () => {
      await this.managerETH.withdrawFromStrategy(this.strategy.address, ether('1'), { from: governor });
      // 1 have been withdrawn from strat
      expect(await this.wETH.balanceOf(this.managerETH.address)).to.be.bignumber.equal(ether('3'));
      expect(await this.strategy.estimatedTotalAssets()).to.be.bignumber.equal(ether('7'));
      // Still 10 total assets
      expect(await this.managerETH.getTotalAsset()).to.be.bignumber.equal(ether('10'));
      // 4 are given to the lender
      expect(await this.wETH.balanceOf(this.strategy.address)).to.be.bignumber.equal(ether('0'));
    });
    it('success - wantBal >= amountNeeded', async () => {
      await this.wETH.mint(this.strategy.address, ether('1'));
      await this.managerETH.withdrawFromStrategy(this.strategy.address, ether('1'), { from: governor });
      // 1 have been withdrawn from strat
      expect(await this.wETH.balanceOf(this.managerETH.address)).to.be.bignumber.equal(ether('4'));
      expect(await this.strategy.estimatedTotalAssets()).to.be.bignumber.equal(ether('7'));
      // Still 10 total assets
      // total debt is not updated after withdrawing
      expect(await this.managerETH.getTotalAsset()).to.be.bignumber.equal(ether('10'));
      // 4 are given to the lender
      expect(await this.wETH.balanceOf(this.strategy.address)).to.be.bignumber.equal(ether('0'));
    });
    it('success - with a loss', async () => {
      await this.curve.setDy(BASE.mul(new BN('11')).div(new BN('10')));
      // In this case you loose a portion and cannot withdraw everything
      await this.managerETH.withdrawFromStrategy(this.strategy.address, ether('1'), { from: governor });

      // 1 have been withdrawn from strat
      expect(await this.wETH.balanceOf(this.managerETH.address)).to.be.bignumber.equal(
        ether('4').add(ether('1').mul(new BN('10')).div(new BN('11'))),
      );
      expect(await this.strategy.estimatedTotalAssets()).to.be.bignumber.equal(ether('6'));
      // Still 10 total assets

      expect(await this.managerETH.getTotalAsset()).to.be.bignumber.equal(
        ether('9').add(ether('10').div(new BN('11'))),
      );
      // 4 are given to the lender
      expect(await this.wETH.balanceOf(this.strategy.address)).to.be.bignumber.equal(ether('0'));
      await this.curve.setDy(BASE);
    });
  });
  describe('liquidateAllPositions', () => {
    it('success - setEmergencyExit', async () => {
      await this.managerETH.setStrategyEmergencyExit(this.strategy.address, { from: governor });
      expect(await this.strategy.emergencyExit()).to.be.equal(true);
    });
    it('success - harvest', async () => {
      await this.strategy.harvest();
      // This harvest makes us find about the wETH that had been left aside
      expect(await this.managerETH.getTotalAsset()).to.be.bignumber.equal(
        ether('10').add(ether('10').div(new BN('11'))),
      );
      expect(await this.wETH.balanceOf(this.strategy.address)).to.be.bignumber.equal(ether('0'));
      expect(await this.strategy.estimatedTotalAssets()).to.be.bignumber.equal(ether('0'));
    });
  });

  describe('updateReferral', () => {
    it('success', async () => {
      await this.strategy.updateReferral(user, { from: governor });
    });
  });
  describe('updateMaxSingleTrade', () => {
    it('success', async () => {
      await this.strategy.updateMaxSingleTrade(BASE.mul(new BN('100')), { from: governor });
      expect(await this.strategy.maxSingleTrade()).to.be.bignumber.equal(BASE.mul(new BN('100')));
    });
  });
  describe('setApr', () => {
    it('success', async () => {
      await this.strategy.setApr(BASE.mul(new BN('9')).div(new BN('100')), { from: governor });
      expect(await this.strategy.apr()).to.be.bignumber.equal(BASE.mul(new BN('9')).div(new BN('100')));
    });
  });
  describe('updateSlippageProtectionOut', () => {
    it('success', async () => {
      await this.strategy.updateSlippageProtectionOut(new BN('51'), { from: governor });
      expect(await this.strategy.slippageProtectionOut()).to.be.bignumber.equal(new BN('51'));
    });
  });
  describe('invest', () => {
    it('reverts - wantBalance <= amount', async () => {
      await expectRevert.unspecified(this.strategy.invest(BASE.mul(new BN('100')), { from: guardian }));
    });

    it('success', async () => {
      // First minting wETH to have a non
      await this.curve.setDy(BASE);
      await this.wETH.mint(this.strategy.address, BASE.mul(new BN('1')));
      const stETHBalance = await this.strategy.stethBalance();
      await this.strategy.invest(BASE.mul(new BN('1')), { from: guardian });
      expect(await this.strategy.stethBalance()).to.be.bignumber.equal(stETHBalance.add(BASE.mul(new BN('1'))));
    });
  });
  describe('rescueStuckEth', () => {
    it('success - eth converted', async () => {
      await this.owner.sendTransaction({
        to: this.strategy.address,
        value: ethers.utils.parseEther('10'),
      });
      await this.strategy.rescueStuckEth({ from: guardian });
      expect(await this.wETH.balanceOf(this.strategy.address)).to.be.bignumber.equal(BASE.mul(new BN('10')));
    });
  });
  describe('sweep', () => {
    it('reverts - wETH', async () => {
      await expectRevert(this.strategy.sweep(this.wETH.address, governor, { from: guardian }), '93');
    });
    it('reverts - stETH', async () => {
      await expectRevert(this.strategy.sweep(this.stETH.address, governor, { from: guardian }), '93');
    });
  });
  describe('harvest - other cases', () => {
    it('init', async () => {
      [this.core, this.ANGLE, this.stableMaster, this.agEUR] = await initAngle(governor, guardian);
      [
        this.wETH,
        this.oracleETH,
        this.managerETH,
        this.sanETH_EUR,
        this.perpetualManagerETH,
        this.feeManagerETH,
        this.stETH,
        this.curve,
        this.strategy,
      ] = await initWETH(this.stableMaster, this.ANGLE, governor, guardian);
      await this.owner.sendTransaction({
        to: this.curve.address,
        value: ethers.utils.parseEther('10'),
      });
      await this.owner.sendTransaction({
        to: this.wETH.address,
        value: ethers.utils.parseEther('10'),
      });
      await this.stETH.mint(this.curve.address, BASE.mul(new BN('10')));
      await this.wETH.mint(this.managerETH.address, ether('10'));
      await this.strategy.harvest();
    });
    it('success - withdraw < withdrawn', async () => {
      // In this situation we should have a profit inferior to the loss
      // This will result in a loss if we increase the dy
      await this.curve.setDy(BASE.mul(new BN('20')).div(new BN('10')));
      await this.wETH.burn(this.managerETH.address, ether('2'));
      await this.strategy.harvest();
      // Has lost 2, then to bring it back to 0.64 => has lost 0.8 when withdrawing
      expect(await this.managerETH.getTotalAsset()).to.be.bignumber.equal(ether('7.2'));
      // But 8 lent from manager to strategy
      expect(await this.wETH.balanceOf(this.managerETH.address)).to.be.bignumber.equal(ether('0.8'));
      expect(await this.strategy.estimatedTotalAssets()).to.be.bignumber.equal(ether('6.4'));
      // These 8 are then given to the lender
      expect(await this.wETH.balanceOf(this.strategy.address)).to.be.bignumber.equal(ether('0'));
      expect(await this.stETH.balanceOf(this.strategy.address)).to.be.bignumber.equal(ether('6.4'));
      expect(await this.strategy.wantBalance()).to.be.bignumber.equal(ether('0'));
      expect(await this.strategy.stethBalance()).to.be.bignumber.equal(ether('6.4'));
      expect(await this.managerETH.totalDebt()).to.be.bignumber.equal(ether('6.4'));
      expect((await this.managerETH.strategies(this.strategy.address)).totalStrategyDebt).to.be.bignumber.equal(
        ether('6.4'),
      );
      await this.curve.setDy(BASE);
    });
    it('success - wantBal < toWithdraw', async () => {
      await this.stETH.mint(this.strategy.address, ether('2'));
      await this.strategy.updateMaxSingleTrade(new BN('0'), { from: guardian });
      await this.strategy.harvest();
      expect(await this.managerETH.getTotalAsset()).to.be.bignumber.equal(ether('7.2'));
      // But 8 lent from manager to strategy
      expect(await this.wETH.balanceOf(this.managerETH.address)).to.be.bignumber.equal(ether('0.8'));
      expect(await this.strategy.estimatedTotalAssets()).to.be.bignumber.equal(ether('8.4'));
      // These 8 are then given to the lender
      expect(await this.wETH.balanceOf(this.strategy.address)).to.be.bignumber.equal(ether('0'));
      expect(await this.stETH.balanceOf(this.strategy.address)).to.be.bignumber.equal(ether('8.4'));
      expect(await this.strategy.wantBalance()).to.be.bignumber.equal(ether('0'));
      expect(await this.strategy.stethBalance()).to.be.bignumber.equal(ether('8.4'));
      expect(await this.managerETH.totalDebt()).to.be.bignumber.equal(ether('6.4'));
      expect((await this.managerETH.strategies(this.strategy.address)).totalStrategyDebt).to.be.bignumber.equal(
        ether('6.4'),
      );
    });
    it('success - harvestTrigger with a big debt threshold', async () => {
      await this.strategy.setDebtThreshold(ether('1'), { from: guardian });
      await this.strategy.setMinReportDelay(new BN('0'), { from: guardian });
      await this.strategy.harvest();
      await this.stETH.burn(this.strategy.address, ether('8.4'));
      expect(await this.strategy.harvestTrigger()).to.be.equal(true);
    });
    it('success - strategyExit with too much freed', async () => {
      await this.managerETH.setStrategyEmergencyExit(this.strategy.address, { from: governor });
      expect(await this.strategy.emergencyExit()).to.be.equal(true);
      const assets = await this.managerETH.getTotalAsset();
      await this.wETH.mint(this.strategy.address, BASE.mul(new BN('100')));
      await this.strategy.harvest();
      expect(await this.managerETH.getTotalAsset()).to.be.bignumber.equal(assets.add(BASE.mul(new BN('100'))));
    });
  });
});
