const { ZERO_ADDRESS } = require('@openzeppelin/test-helpers/src/constants');
const { BN } = require('@openzeppelin/test-helpers/src/setup');
const { artifacts } = require('hardhat');
const {
  // utils
  ether,
  expectRevert,
  expect,
  expectApprox,
  expectEvent,
  time,
  Strategy,
  MockToken,
  MockOracle,
  MockStrategy,
  BASE,
  BASE_PARAMS,
  BASE_ORACLE,
  // functions
  initAngle,
  initCollateral,
  initStrategy,
} = require('../helpers');

// Start test block
contract('Strategy', accounts => {
  const [governor, guardian, user, tester] = accounts;
  before(async () => {
    [this.core, this.ANGLE, this.stableMaster, this.agEUR] = await initAngle(governor, guardian);
    [this.wBTC, this.oracleBTC, this.managerBTC, this.sanBTC_EUR, this.perpetualManagerBTC] = await initCollateral(
      'wBTC',
      this.stableMaster,
      this.ANGLE,
      governor,
      new BN(18),
    );

    [this.DAI, this.oracleDAI, this.managerDAI, this.sanDAI_EUR, this.perpetualManagerDAI] = await initCollateral(
      'DAI',
      this.stableMaster,
      this.ANGLE,
      governor,
      new BN('18'),
    );
    this.oracleETHWant = await MockOracle.new(BASE_ORACLE, new BN('18'));

    // The default debt ratio of the strategy is 0.8
    [
      this.comp,
      this.compound,
      this.uniswapRouter,
      this.uniswapPool,
      this.genericCompound,
      this.strategy,
      this.uniswapV2Router,
      this.comptroller,
    ] = await initStrategy('wBTC', this.wBTC, this.managerBTC, this.ANGLE, this.oracleETHWant, governor, guardian);

    this.genericCompound2 = await artifacts
      .require('GenericCompound')
      .new(
        this.strategy.address,
        ' ',
        this.uniswapRouter.address,
        this.uniswapV2Router.address,
        this.comptroller.address,
        this.comp.address,
        web3.utils.asciiToHex('0'),
        this.compound.address,
        [governor],
        guardian,
      );

    this.weth = await MockToken.new('WETH', 'WETH', 18);

    this.strategy2 = await Strategy.new(this.managerBTC.address, this.ANGLE.address, [governor], guardian);

    this.genericCompound3 = await artifacts
      .require('GenericCompound')
      .new(
        this.strategy2.address,
        ' ',
        this.uniswapRouter.address,
        this.uniswapV2Router.address,
        this.comptroller.address,
        this.comp.address,
        web3.utils.asciiToHex('0'),
        this.compound.address,
        [governor],
        guardian,
      );
    this.SLPhash = web3.utils.soliditySha3('SLP');

    this.minWindow = new BN('1000');

    this.maxWindow = new BN('10000');

    this.supplySpeed = await this.comptroller.price();
    this.blocksPerYear = new BN('2350000');
  });

  describe('Initialization', () => {
    describe('Parameters', () => {
      it('poolManager', async () => {
        expect(await this.strategy.poolManager()).to.be.equal(this.managerBTC.address);
      });
      it('want', async () => {
        expect(await this.strategy.want()).to.be.equal(this.wBTC.address);
      });
      it('rewards', async () => {
        expect(await this.strategy.rewards()).to.be.equal(this.ANGLE.address);
      });
      it('BASE', async () => {
        expect(await this.strategy.BASE()).to.be.bignumber.equal(BASE);
      });
      it('SECONDSPERYEAR', async () => {
        expect(await this.strategy.SECONDSPERYEAR()).to.be.bignumber.equal(new BN('31556952'));
      });
      it('debtThreshold', async () => {
        expect(await this.strategy.debtThreshold()).to.be.bignumber.equal(BASE.mul(new BN('100')));
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
      it('allowance', async () => {
        expect(await this.wBTC.allowance(this.strategy.address, this.managerBTC.address)).to.be.bignumber.equal(
          new BN(2).pow(new BN(256)).sub(new BN(1)),
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
          await this.strategy.hasRole(web3.utils.soliditySha3('POOLMANAGER_ROLE'), this.managerBTC.address),
        ).to.be.equal(true);
      });
      it('withdraw - reverts nonManager', async () => {
        await expectRevert(this.strategy.withdraw(BASE, { from: user }), this.managerError);
      });
      it('setEmergencyExit - reverts nonManager', async () => {
        await expectRevert(this.strategy.setEmergencyExit({ from: user }), this.managerError);
      });
      it('setRewards - reverts nonGuardian', async () => {
        await expectRevert(this.strategy.setRewards(this.wBTC.address, { from: user }), this.guardianError);
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
        await expectRevert(this.strategy.sweep(this.wBTC.address, user, { from: user }), this.guardianError);
      });
      it('manualAllocation - reverts nonGuardian', async () => {
        this.newPositions = [{ lender: this.genericCompound.address, share: 1100 }];
        await expectRevert(this.strategy.manualAllocation(this.newPositions, { from: user }), this.guardianError);
      });
      it('setWithdrawalThreshold - reverts nonGuardian', async () => {
        await expectRevert(this.strategy.setWithdrawalThreshold(BASE, { from: user }), this.guardianError);
      });
      it('addLender - reverts nonGuardian', async () => {
        await expectRevert(this.strategy.addLender(user, { from: user }), this.guardianError);
      });
      it('safeRemoveLender - reverts nonGuardian', async () => {
        await expectRevert(this.strategy.safeRemoveLender(user, { from: user }), this.guardianError);
      });
      it('forceRemoveLender - reverts nonGuardian', async () => {
        await expectRevert(this.strategy.forceRemoveLender(user, { from: user }), this.guardianError);
      });
      it('addGuardian - reverts nonGuardian', async () => {
        await expectRevert(this.strategy.addGuardian(this.wBTC.address, { from: user }), this.managerError);
      });
      it('revokeGuardian - reverts nonGuardian', async () => {
        await expectRevert(this.strategy.revokeGuardian(this.wBTC.address, { from: user }), this.managerError);
      });
    });
  });

  describe('debtRatio', () => {
    it('success - set correctly for strategy', async () => {
      const debtRatio = (await this.managerBTC.strategies(this.strategy.address)).debtRatio;
      expect(debtRatio).to.be.bignumber.equal(BASE_PARAMS.mul(new BN('8')).div(new BN('10')));
    });
    it('success - set correctly for manager', async () => {
      expect(await this.managerBTC.debtRatio()).to.be.bignumber.equal(BASE_PARAMS.mul(new BN('8')).div(new BN('10')));
    });
  });

  describe('setGuardian - when there is a strategy', () => {
    it('success - adding a new guardian', async () => {
      await this.core.setGuardian(tester, { from: governor });
      expect(await this.managerBTC.hasRole(web3.utils.soliditySha3('GUARDIAN_ROLE'), tester)).to.be.equal(true);
      expect(await this.managerBTC.hasRole(web3.utils.soliditySha3('GUARDIAN_ROLE'), guardian)).to.be.equal(false);
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

  describe('harvest', () => {
    it('init - minting on poolManager', async () => {
      await this.wBTC.mint(this.managerBTC.address, ether('10'));
      expect(await this.wBTC.balanceOf(this.managerBTC.address)).to.be.bignumber.equal(BASE.mul(new BN('10')));
    });

    it('success - lent assets updated', async () => {
      await this.strategy.harvest();
      // Still 10 total assets
      expect(await this.managerBTC.getTotalAsset()).to.be.bignumber.equal(ether('10'));
      // But 8 lent from manager to strategy
      expect(await this.wBTC.balanceOf(this.managerBTC.address)).to.be.bignumber.equal(ether('2'));
      expect(await this.strategy.estimatedTotalAssets()).to.be.bignumber.equal(ether('8'));
      // These 8 are then given to the lender
      expect(await this.wBTC.balanceOf(this.strategy.address)).to.be.bignumber.equal(ether('0'));
      expect(await this.managerBTC.totalDebt()).to.be.bignumber.equal(ether('8'));
      expect((await this.managerBTC.strategies(this.strategy.address)).totalStrategyDebt).to.be.bignumber.equal(
        ether('8'),
      );
      expect(await this.genericCompound.nav()).to.be.bignumber.equal(ether('8'));
      expect(await this.wBTC.balanceOf(this.genericCompound.address)).to.be.bignumber.equal(ether('0'));
      expect(await this.strategy.lentTotalAssets()).to.be.bignumber.equal(ether('8'));
    });

    it('setting - creation of debt for the strategy', async () => {
      await this.managerBTC.updateStrategyDebtRatio(
        this.strategy.address,
        BASE_PARAMS.mul(new BN('5')).div(new BN('10')),
        { from: governor },
      );
      expect((await this.managerBTC.strategies(this.strategy.address)).debtRatio).to.be.bignumber.equal(
        BASE_PARAMS.mul(new BN('5')).div(new BN('10')),
      );
      expect(await this.managerBTC.getTotalAsset()).to.be.bignumber.equal(ether('10'));
    });
    it('success - manager debt ratio check', async () => {
      expect(await this.managerBTC.debtRatio()).to.be.bignumber.equal(BASE_PARAMS.mul(new BN('5')).div(new BN('10')));
    });

    it('updateStrategyDebtRatio reverts', async () => {
      await expectRevert(
        this.managerBTC.updateStrategyDebtRatio(tester, BASE_PARAMS.mul(new BN('5')).div(new BN('10')), {
          from: governor,
        }),
        '78',
      );
      await expectRevert(
        this.managerBTC.updateStrategyDebtRatio(
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
      expect(await this.wBTC.balanceOf(this.managerBTC.address)).to.be.bignumber.equal(ether('5'));
      expect(await this.strategy.estimatedTotalAssets()).to.be.bignumber.equal(ether('5'));

      // Still 10 total assets
      expect(await this.managerBTC.getTotalAsset()).to.be.bignumber.equal(ether('10'));
      // These 5 are then given to the lender
      expect(await this.wBTC.balanceOf(this.strategy.address)).to.be.bignumber.equal(ether('0'));
      expect(await this.genericCompound.nav()).to.be.bignumber.equal(ether('5'));
      expect(await this.wBTC.balanceOf(this.genericCompound.address)).to.be.bignumber.equal(ether('0'));
    });
  });

  describe('withdraw', () => {
    it('reverts - invalid strategy', async () => {
      await expectRevert(this.managerBTC.withdrawFromStrategy(governor, ether('1'), { from: governor }), '78');
    });

    it('success - amount withdrawn', async () => {
      this.initialDebt = await this.managerBTC.totalDebt();
      await this.managerBTC.withdrawFromStrategy(this.strategy.address, ether('1'), { from: governor });
      // 1 have been withdrawn from strat
      expect(await this.wBTC.balanceOf(this.managerBTC.address)).to.be.bignumber.equal(ether('6'));
      expect(await this.strategy.estimatedTotalAssets()).to.be.bignumber.equal(ether('4'));

      // Still 10 total assets
      expect(await this.managerBTC.getTotalAsset()).to.be.bignumber.equal(ether('10'));
      // 4 are given to the lender
      expect(await this.wBTC.balanceOf(this.strategy.address)).to.be.bignumber.equal(ether('0'));
      expect(await this.genericCompound.nav()).to.be.bignumber.equal(ether('4'));
      expect(await this.wBTC.balanceOf(this.genericCompound.address)).to.be.bignumber.equal(ether('0'));
    });

    it('success - totalDebt updated', async () => {
      expect(await this.managerBTC.totalDebt()).to.be.bignumber.equal(this.initialDebt.sub(ether('1')));
      const totalDebt = (await this.managerBTC.strategies(this.strategy.address)).totalStrategyDebt;
      expect(totalDebt).to.be.bignumber.equal(this.initialDebt.sub(ether('1')));
    });

    it('success - harvesting - lent assets updated', async () => {
      await this.strategy.harvest();
      // 3 have been withdrawn from strat
      expect(await this.wBTC.balanceOf(this.managerBTC.address)).to.be.bignumber.equal(ether('5'));
      expect(await this.strategy.estimatedTotalAssets()).to.be.bignumber.equal(ether('5'));

      // Still 10 total assets
      expect(await this.managerBTC.getTotalAsset()).to.be.bignumber.equal(ether('10'));
      // 5 lent from manager to strategy
      // 5 are given to the lender
      expect(await this.wBTC.balanceOf(this.strategy.address)).to.be.bignumber.equal(ether('0'));
      expect(await this.genericCompound.nav()).to.be.bignumber.equal(ether('5'));
      expect(await this.wBTC.balanceOf(this.genericCompound.address)).to.be.bignumber.equal(ether('0'));
    });
  });

  describe('harvestTrigger', () => {
    it('reverts - invalid strategy', async () => {
      await expectRevert(this.managerBTC.withdrawFromStrategy(governor, ether('1'), { from: governor }), '78');
    });
    it('success - call too soon', async () => {
      const minReportDelay = await this.strategy.minReportDelay({ from: governor });
      await this.strategy.setMinReportDelay(this.minWindow, { from: governor });
      expect(await this.strategy.harvestTrigger({ from: user })).to.be.equal(false);
      await this.strategy.setMinReportDelay(minReportDelay, { from: governor });
    });
    it('success - call after maxReportDelay ', async () => {
      const maxReportDelay = await this.strategy.maxReportDelay({ from: governor });
      await this.strategy.setMaxReportDelay(0, { from: governor });
      expect(await this.strategy.harvestTrigger({ from: user })).to.be.equal(true);
      await this.strategy.setMaxReportDelay(maxReportDelay, { from: governor });
    });
    it('success - Outstanding > debtThreshold', async () => {
      await this.strategy.setDebtThreshold(ether('1'), { from: governor });
      await this.managerBTC.updateStrategyDebtRatio(this.strategy.address, ether('0'), { from: governor });
      expect(await this.strategy.harvestTrigger({ from: user })).to.be.equal(true);
      await this.strategy.setDebtThreshold(ether('0'), { from: governor });
      await this.managerBTC.updateStrategyDebtRatio(
        this.strategy.address,
        BASE_PARAMS.mul(new BN('5')).div(new BN('10')),
        { from: governor },
      );
    });
    it('success - feeManager should not call', async () => {
      await this.strategy.setRewardAmountAndMinimumAmountMoved(0, BASE, { from: governor });
      expect(await this.strategy.harvestTrigger({ from: user })).to.be.equal(false);
    });
    it('success - feeManager should call', async () => {
      await this.wBTC.mint(this.strategy.address, ether('10'), { from: guardian });
      expect(await this.strategy.harvestTrigger({ from: user })).to.be.equal(true);
      await this.wBTC.burn(this.strategy.address, ether('10'), { from: guardian });
    });
  });

  describe('removeLender', () => {
    it('reverts - not a lender', async () => {
      await expectRevert(this.strategy.safeRemoveLender(tester, { from: governor }), '94');
    });

    it('success - lender removed', async () => {
      await this.strategy.safeRemoveLender(this.genericCompound.address, { from: governor });
      expect(await this.wBTC.balanceOf(this.strategy.address)).to.be.bignumber.equal(ether('5'));
    });

    it('withdraw - success', async () => {
      await this.managerBTC.withdrawFromStrategy(this.strategy.address, ether('1'), { from: governor });
      // 1 have been withdrawn from strat
      expect(await this.wBTC.balanceOf(this.managerBTC.address)).to.be.bignumber.equal(ether('6'));
      expect(await this.strategy.estimatedTotalAssets()).to.be.bignumber.equal(ether('4'));

      // Still 10 total assets
      expect(await this.managerBTC.getTotalAsset()).to.be.bignumber.equal(ether('10'));
    });

    it('success - harvesting - assets updated', async () => {
      await this.strategy.harvest();
      // 3 have been withdrawn from strat
      expect(await this.wBTC.balanceOf(this.managerBTC.address)).to.be.bignumber.equal(ether('5'));
      expect(await this.strategy.estimatedTotalAssets()).to.be.bignumber.equal(ether('5'));

      // Still 10 total assets
      expect(await this.managerBTC.getTotalAsset()).to.be.bignumber.equal(ether('10'));
    });
  });

  describe('addLender', () => {
    it('success - lender added', async () => {
      await this.strategy.addLender(this.genericCompound.address, { from: governor });
    });
    it('reverts - strategy already added', async () => {
      await expectRevert(this.strategy.addLender(this.genericCompound.address, { from: governor }), '97');
    });
    it('reverts - undockedLender', async () => {
      await expectRevert(this.strategy.addLender(this.genericCompound3.address, { from: governor }), '96');
    });

    it('success - harvesting - assets updated', async () => {
      await this.strategy.harvest();
      // 3 have been withdrawn from strat
      expect(await this.wBTC.balanceOf(this.managerBTC.address)).to.be.bignumber.equal(ether('5'));
      expect(await this.strategy.estimatedTotalAssets()).to.be.bignumber.equal(ether('5'));

      // Still 10 total assets
      expect(await this.managerBTC.getTotalAsset()).to.be.bignumber.equal(ether('10'));
      // 5 lent from manager to strategy
      // 5 are given to the lender
      expect(await this.wBTC.balanceOf(this.strategy.address)).to.be.bignumber.equal(ether('0'));
      expect(await this.genericCompound.nav()).to.be.bignumber.equal(ether('5'));
      expect(await this.wBTC.balanceOf(this.genericCompound.address)).to.be.bignumber.equal(ether('0'));
    });
  });

  describe('forceRemoveLender', () => {
    it('init - adding another lender / harvesting', async () => {
      await this.strategy.addLender(this.genericCompound2.address, { from: governor });
      await this.strategy.harvest();
    });

    it('success', async () => {
      await this.strategy.forceRemoveLender(this.genericCompound2.address, { from: governor });
    });
  });

  describe('revokeStrategy', () => {
    it('reverts - invalid debtRatio', async () => {
      await expectRevert(this.managerBTC.revokeStrategy(this.strategy.address, { from: governor }), '77');
    });

    it('reverts - funds not withdrawn', async () => {
      await this.managerBTC.updateStrategyDebtRatio(this.strategy.address, ether('0'), { from: governor });
      await expectRevert(this.managerBTC.revokeStrategy(this.strategy.address, { from: governor }), '77');
    });

    it('reverts - invalid strategy', async () => {
      await expectRevert(this.managerBTC.revokeStrategy(tester, { from: governor }), '78');
    });

    it('success - strategy revoked', async () => {
      await this.strategy.harvest();
      await this.managerBTC.revokeStrategy(this.strategy.address, { from: governor });
      expect(
        await this.managerBTC.hasRole(web3.utils.soliditySha3('STRATEGY_ROLE'), this.strategy.address),
      ).to.be.equal(false);
    });
  });

  describe('addStrategy', () => {
    it('reverts - invalid address', async () => {
      await expectRevert(
        this.managerBTC.addStrategy(ZERO_ADDRESS, BASE_PARAMS.mul(new BN('6')).div(new BN('10')), { from: governor }),
        '0',
      );
    });

    it('reverts - wrong manager', async () => {
      const mockStrategy = await artifacts
        .require('Strategy')
        .new(this.managerDAI.address, this.ANGLE.address, [governor], guardian);

      await expectRevert(
        this.managerBTC.addStrategy(mockStrategy.address, BASE_PARAMS.mul(new BN('6')).div(new BN('10')), {
          from: governor,
        }),
        '74',
      );
    });

    it('reverts - invalid want', async () => {
      const strat = await MockStrategy.new(this.managerBTC.address, user);
      await expectRevert(
        this.managerBTC.addStrategy(strat.address, BASE_PARAMS.mul(new BN('6')).div(new BN('10')), { from: governor }),
        '75',
      );
    });

    it('success - strategy added', async () => {
      await this.managerBTC.addStrategy(this.strategy.address, BASE_PARAMS.mul(new BN('5')).div(new BN('10')), {
        from: governor,
      });
    });

    it('reverts - already added', async () => {
      await expectRevert(
        this.managerBTC.addStrategy(this.strategy.address, BASE_PARAMS.mul(new BN('5')).div(new BN('10')), {
          from: governor,
        }),
        '73',
      );
    });
  });
  describe('deploy Strategy', () => {
    it('reverts - rewards zero address', async () => {
      await expectRevert(
        artifacts.require('Strategy').new(this.managerBTC.address, ZERO_ADDRESS, [governor], guardian),
        '0',
      );
    });

    it('reverts - rewards same as want', async () => {
      await expectRevert(
        artifacts.require('Strategy').new(this.managerBTC.address, this.wBTC.address, [governor], guardian),
        '92',
      );
    });

    it('reverts - governor zero address', async () => {
      await expectRevert(
        artifacts.require('Strategy').new(this.managerBTC.address, this.ANGLE.address, [ZERO_ADDRESS], guardian),
        '0',
      );
    });
    it('reverts guardian zero address', async () => {
      await expectRevert(
        artifacts.require('Strategy').new(this.managerBTC.address, this.ANGLE.address, [governor], ZERO_ADDRESS),
        '0',
      );
    });
    it('reverts - guardian zero address', async () => {
      await expectRevert.unspecified(
        artifacts.require('Strategy').new(ZERO_ADDRESS, this.ANGLE.address, [governor], guardian),
      );
    });

    it('reverts - debt Ratio too high', async () => {
      const mockStrategy = await artifacts
        .require('Strategy')
        .new(this.managerBTC.address, this.ANGLE.address, [governor], guardian);

      await expectRevert(
        this.managerBTC.addStrategy(mockStrategy.address, BASE_PARAMS.mul(new BN('6')).div(new BN('10')), {
          from: governor,
        }),
        '76',
      );
    });

    it('addStrategy - success with two other strategies', async () => {
      this.mockStrategy1 = await artifacts
        .require('Strategy')
        .new(this.managerBTC.address, this.ANGLE.address, [governor], guardian);
      await this.managerBTC.addStrategy(this.mockStrategy1.address, BASE_PARAMS.mul(new BN('1')).div(new BN('10')), {
        from: governor,
      });
      this.mockStrategy2 = await artifacts
        .require('Strategy')
        .new(this.managerBTC.address, this.ANGLE.address, [governor], guardian);
      await this.managerBTC.addStrategy(this.mockStrategy2.address, BASE_PARAMS.mul(new BN('1')).div(new BN('10')), {
        from: governor,
      });
    });

    it('revokeStrategy - success two strategies', async () => {
      await this.managerBTC.updateStrategyDebtRatio(this.mockStrategy1.address, ether('0'), { from: governor });
      await this.managerBTC.updateStrategyDebtRatio(this.mockStrategy2.address, ether('0'), { from: governor });
      await this.managerBTC.revokeStrategy(this.mockStrategy1.address, { from: governor });
      await this.managerBTC.revokeStrategy(this.mockStrategy2.address, { from: governor });
      expect(
        await this.managerBTC.hasRole(web3.utils.soliditySha3('STRATEGY_ROLE'), this.mockStrategy2.address),
      ).to.be.equal(false);
      expect(
        await this.managerBTC.hasRole(web3.utils.soliditySha3('STRATEGY_ROLE'), this.mockStrategy1.address),
      ).to.be.equal(false);
    });
  });

  describe('lendStatuses', () => {
    it('success', async () => {
      await this.strategy.harvest();
      expect((await this.strategy.lendStatuses())[0].assets).to.be.bignumber.equal(ether('5'));
    });
  });

  describe('estimatedAPR', () => {
    it('success', async () => {
      const cTokenSupply = await this.compound.totalSupply();
      const exchangeRate = await this.compound.exchangeRateStored();
      const supplyInWant = cTokenSupply.mul(exchangeRate).div(BASE);

      const compInWant = this.supplySpeed.mul(new BN('10'));
      const incentivesRate = compInWant
        .mul(this.blocksPerYear)
        .mul(BASE)
        .div(supplyInWant)
        .mul(new BN(95))
        .div(new BN('100'));

      expectApprox(await this.strategy.estimatedAPR(), ether('0.04').add(incentivesRate));
    });
  });

  describe('estimatedAPR - manager level', () => {
    it('success - without SLP', async () => {
      expect(await this.managerBTC.estimatedAPR()).to.be.bignumber.equal(new BN(2).pow(new BN(256)).sub(new BN(1)));
    });

    it('success - with SLP', async () => {
      await this.wBTC.mint(user, ether('10'));
      await this.wBTC.approve(this.stableMaster.address, ether('10'), { from: user });
      await this.stableMaster.deposit(ether('10'), user, this.managerBTC.address, { from: user });
      const cTokenSupply = await this.compound.totalSupply();
      const exchangeRate = await this.compound.exchangeRateStored();
      const supplyInWant = cTokenSupply.mul(exchangeRate).div(BASE);

      const compInWant = this.supplySpeed.mul(new BN('10'));
      const incentivesRate = compInWant
        .mul(this.blocksPerYear)
        .mul(BASE)
        .div(supplyInWant)
        .mul(new BN(95))
        .div(new BN('100'));
      expectApprox(
        await this.managerBTC.estimatedAPR(),
        BASE_PARAMS.mul(new BN('2'))
          .div(new BN('100'))
          .add(incentivesRate.mul(new BN('5')).div(new BN('10')).div(BASE_PARAMS)),
      );
      await this.stableMaster.withdraw(ether('10'), user, user, this.managerBTC.address, { from: user });
    });
  });

  describe('numLenders', () => {
    it('success', async () => {
      expect(await this.strategy.numLenders()).to.be.bignumber.equal(new BN(1));
    });
  });

  describe('sweep', () => {
    it('reverts - access control', async () => {
      await expectRevert.unspecified(this.strategy.sweep(this.comp.address, user, { from: user }));
    });

    it('reverts - protected token', async () => {
      await this.ANGLE.mint(this.strategy.address, ether('1'));
      await expectRevert(this.strategy.sweep(this.wBTC.address, user, { from: governor }), '93');
    });

    it('success - balance updated', async () => {
      await this.strategy.sweep(this.ANGLE.address, user, { from: governor });
      expect(await this.ANGLE.balanceOf(user)).to.be.bignumber.equal(ether('1'));
    });
  });

  describe('setMinReportDelay', () => {
    it('success', async () => {
      await this.strategy.setMinReportDelay(this.minWindow, { from: governor });
      expect(await this.strategy.minReportDelay()).to.be.bignumber.equal(this.minWindow);
    });
  });

  describe('setMaxReportDelay', () => {
    it('success', async () => {
      await this.strategy.setMaxReportDelay(this.maxWindow, { from: governor });
      expect(await this.strategy.maxReportDelay()).to.be.bignumber.equal(this.maxWindow);
    });
  });

  describe('setDebtThreshold', () => {
    it('success', async () => {
      await this.strategy.setDebtThreshold(ether('1'), { from: governor });
      expect(await this.strategy.debtThreshold()).to.be.bignumber.equal(ether('1'));
    });
  });

  describe('setWithdrawalThreshold', () => {
    it('success', async () => {
      await this.strategy.setWithdrawalThreshold(ether('1'), { from: governor });
      expect(await this.strategy.withdrawalThreshold()).to.be.bignumber.equal(ether('1'));
    });
    it('success - resets', async () => {
      await this.strategy.setWithdrawalThreshold(BASE.div(new BN('10000')), { from: governor });
      expect(await this.strategy.withdrawalThreshold()).to.be.bignumber.equal(BASE.div(new BN('10000')));
    });
  });

  describe('setRewards', () => {
    it('reverts - incorrect address', async () => {
      await expectRevert(this.strategy.setRewards(ZERO_ADDRESS, { from: governor }), '92');
    });
    it('success', async () => {
      await this.strategy.setRewards(this.DAI.address, { from: governor });
      expect(await this.strategy.rewards()).to.be.equal(this.DAI.address);
    });
    it('success - resets', async () => {
      await this.strategy.setRewards(this.ANGLE.address, { from: governor });
      expect(await this.strategy.rewards()).to.be.equal(this.ANGLE.address);
    });
  });

  describe('setRewardAmount and harvest trigger', () => {
    it('success - balance updated', async () => {
      // Setting the rewardAmount
      await this.strategy.setRewardAmountAndMinimumAmountMoved(ether('3'), ether('7'), { from: governor });
      expect(await this.strategy.rewardAmount()).to.be.bignumber.equal(ether('3'));
      expect(await this.strategy.minimumAmountMoved()).to.be.bignumber.equal(ether('7'));

      await this.ANGLE.mint(this.strategy.address, ether('1000000'));
      // Changing the last report timestamp
      await this.strategy.harvest({ from: user });
      // Making time pass over maxReportDelay
      await time.increase(this.maxWindow.mul(new BN('2')));
    });

    it('success - harvest updates balance', async () => {
      const balance = await this.ANGLE.balanceOf(user);
      await this.strategy.harvest({ from: user });
      const balance2 = await this.ANGLE.balanceOf(user);
      expect(balance2).to.be.bignumber.equal(balance.add(ether('3')));
    });
  });

  describe('isActive', () => {
    it('success', async () => {
      const receipt = await this.strategy.isActive({ from: governor });
      expect(receipt).to.be.equal(true);
    });
  });

  describe('harvest with profit and loss', () => {
    it('init', async () => {
      await this.strategy.harvest();
      expect(await this.managerBTC.getTotalAsset()).to.be.bignumber.equal(ether('10'));
      expect(await this.wBTC.balanceOf(this.managerBTC.address)).to.be.bignumber.equal(ether('5'));
      expect(await this.wBTC.balanceOf(this.strategy.address)).to.be.bignumber.equal(ether('0'));
      expect(await this.wBTC.balanceOf(this.genericCompound.address)).to.be.bignumber.equal(ether('0'));
      expect(await this.strategy.estimatedTotalAssets()).to.be.bignumber.equal(ether('5'));
      expect(await this.genericCompound.nav()).to.be.bignumber.equal(ether('5'));
    });

    it('success - updated Compound Exchange Rate', async () => {
      // Minting the tokens for the capital gain made on Compound
      await this.wBTC.mint(this.compound.address, ether('10000'));
      await this.compound.updateExchangeRate(ether('2'));
      expect(await this.genericCompound.nav()).to.be.bignumber.equal(ether('10'));
      expect(await this.strategy.estimatedTotalAssets()).to.be.bignumber.equal(ether('10'));
    });

    it('success - profit registered', async () => {
      const receipt = await this.strategy.harvest();
      expectEvent.inTransaction(receipt.tx, this.managerBTC, 'FeesDistributed', {
        amountDistributed: ether('5'),
      });
      expect(await this.managerBTC.getTotalAsset()).to.be.bignumber.equal(ether('15'));
      expect(await this.strategy.estimatedTotalAssets()).to.be.bignumber.equal(ether('7.5'));
      expect(await this.genericCompound.nav()).to.be.bignumber.equal(ether('7.5'));
      expect(await this.wBTC.balanceOf(this.managerBTC.address)).to.be.bignumber.equal(ether('7.5'));
      expect(await this.wBTC.balanceOf(this.strategy.address)).to.be.bignumber.equal(ether('0'));
    });

    it('success - harvest with loss', async () => {
      await this.compound.updateExchangeRate(ether('1'));
      // The value of the total assets is now 3.75, so the total value is now 11.25
      // In the end the total assets will be 11.25/2 = 5.625
      // The loss here is 3.75
      await this.strategy.harvest();
      expect(await this.managerBTC.getTotalAsset()).to.be.bignumber.equal(ether('11.25'));
      expect(await this.strategy.estimatedTotalAssets()).to.be.bignumber.equal(ether('5.625'));
      expect(await this.genericCompound.nav()).to.be.bignumber.equal(ether('5.625'));
      expect(await this.wBTC.balanceOf(this.managerBTC.address)).to.be.bignumber.equal(ether('5.625'));
      expect(await this.wBTC.balanceOf(this.strategy.address)).to.be.bignumber.equal(ether('0'));
    });

    it('init - creates SLPs', async () => {
      await this.wBTC.mint(user, ether('1000'));
      await this.wBTC.approve(this.stableMaster.address, ether('1000'), { from: user });
      await this.stableMaster.deposit(ether('1'), user, this.managerBTC.address, { from: user });
      // 1 has been deposited by SLPs
      expect(await this.sanBTC_EUR.balanceOf(user)).to.be.bignumber.equal(ether('1'));
      expect(await this.managerBTC.getTotalAsset()).to.be.bignumber.equal(ether('12.25'));
      this.sanRate = (await this.stableMaster.collateralMap(this.managerBTC.address)).sanRate;
    });

    it('success - updating exchange rate first for a small loss', async () => {
      await this.compound.updateExchangeRate(ether('0.9'));
      // The exchange rate decreases from 1 to 0.9, meaning the value of the tokens in the strategy is 0.9 * 5.625
      expect(await this.genericCompound.nav()).to.be.bignumber.equal(ether('5.0625'));
      expect(await this.strategy.estimatedTotalAssets()).to.be.bignumber.equal(ether('5.0625'));
    });

    it('success - harvest with small loss and sanTokens', async () => {
      await this.strategy.harvest();
      expect(await this.wBTC.balanceOf(this.strategy.address)).to.be.bignumber.equal(ether('0'));
      expect(await this.wBTC.balanceOf(this.genericCompound.address)).to.be.bignumber.equal(ether('0'));
      expect(await this.managerBTC.getTotalAsset()).to.be.bignumber.equal(ether('11.6875'));
      // The strategy should have 10.6875/2
      expectApprox(await this.strategy.estimatedTotalAssets(), ether('5.84375'));
      expectApprox(await this.genericCompound.nav(), ether('5.84375'));
      expectApprox(await this.wBTC.balanceOf(this.managerBTC.address), ether('5.84375'));
    });

    it('success - new sanRate updated', async () => {
      // The Loss is ether('0.5625')
      expect((await this.stableMaster.collateralMap(this.managerBTC.address)).sanRate).to.be.bignumber.equal(
        ether('0.4375'),
      );
    });

    it('success - updating exchange rate first for a big loss', async () => {
      // Exchange rate is divided by two
      await this.compound.updateExchangeRate(ether('0.45'));
      expectApprox(await this.genericCompound.nav(), ether('2.921875'));
      expectApprox(await this.strategy.estimatedTotalAssets(), ether('2.921875'));
    });

    it('success - harvest with big loss and sanTokens', async () => {
      await this.strategy.harvest();
      expect(await this.wBTC.balanceOf(this.strategy.address)).to.be.bignumber.equal(ether('0'));
      expect(await this.wBTC.balanceOf(this.genericCompound.address)).to.be.bignumber.equal(ether('0'));
      expectApprox(await this.managerBTC.getTotalAsset(), ether('8.715625'));
    });

    it('success - checking for new sanRate', async () => {
      // The Loss is ether('0.5625')
      expect((await this.stableMaster.collateralMap(this.managerBTC.address)).sanRate).to.be.bignumber.equal(
        new BN('1'),
      );
    });
    it('success - unpause SLPs', async () => {
      await this.stableMaster.unpause(this.SLPhash, this.managerBTC.address, { from: this.governor });
      const hash = web3.utils.soliditySha3(
        { t: 'bytes32', v: this.SLPhash },
        { t: 'address', v: this.managerBTC.address },
      );
      expect(await this.stableMaster.paused(hash)).to.be.equal(false);
    });
  });

  describe('creditAvailable', () => {
    it('success', async () => {
      expect(await this.managerBTC.creditAvailable({ from: tester })).to.be.bignumber.equal(new BN('0'));
    });
  });

  describe('manualAllocation', () => {
    it('reverts - too high shares', async () => {
      this.newPositions = [{ lender: this.genericCompound.address, share: 1100 }];
      await expectRevert(
        this.strategy.manualAllocation(this.newPositions, { from: governor }),
        'ERC20: transfer amount exceeds balance',
      );
    });
    it('reverts - invalid shares', async () => {
      this.newPositions = [{ lender: this.genericCompound.address, share: 900 }];
      await expectRevert(this.strategy.manualAllocation(this.newPositions, { from: governor }), '95');
    });
    it('reverts - invalid lender', async () => {
      this.newPositions = [{ lender: this.genericCompound2.address, share: 1000 }];
      await expectRevert(this.strategy.manualAllocation(this.newPositions, { from: governor }), '94');
    });
    it('success - positions updated', async () => {
      this.newPositions = [{ lender: this.genericCompound.address, share: 1000 }];
      await this.strategy.manualAllocation(this.newPositions, { from: governor });
    });
  });

  describe('setEmergencyExit', () => {
    it('success - works fine', async () => {
      this.totalAsset = await this.managerBTC.getTotalAsset();
      await this.managerBTC.setStrategyEmergencyExit(this.strategy.address, { from: governor });
    });
    it('success - emergencyExit parameter updated', async () => {
      expect(await this.strategy.emergencyExit()).to.be.equal(true);
    });
    it('success - Strategy debtRatio updated', async () => {
      const debtRatio = (await this.managerBTC.strategies(this.strategy.address)).debtRatio;
      expect(debtRatio).to.be.bignumber.equal(new BN('0'));
    });
    it('success - Manager debtRatio updated', async () => {
      expect(await this.managerBTC.debtRatio()).to.be.bignumber.equal(new BN('0'));
    });

    it('success - harvest check', async () => {
      expectApprox(await this.managerBTC.getTotalAsset(), this.totalAsset);
      expectApprox(await this.wBTC.balanceOf(this.managerBTC.address), this.totalAsset);
      expect(await this.wBTC.balanceOf(this.strategy.address)).to.be.bignumber.equal(ether('0'));
      expect(await this.wBTC.balanceOf(this.genericCompound.address)).to.be.bignumber.equal(ether('0'));
      expect(await this.strategy.estimatedTotalAssets()).to.be.bignumber.equal(ether('0'));
      expect(await this.genericCompound.nav()).to.be.bignumber.equal(ether('0'));
    });
  });

  describe('setEmergencyExit - harvest amount freed = debt outstanding', () => {
    it('init', async () => {
      [this.core, this.ANGLE, this.stableMaster, this.agEUR] = await initAngle(governor, guardian);
      [this.wBTC, this.oracleBTC, this.managerBTC, this.sanBTC_EUR, this.perpetualManagerBTC] = await initCollateral(
        'wBTC',
        this.stableMaster,
        this.ANGLE,
        governor,
        new BN(18),
      );

      [this.DAI, this.oracleDAI, this.managerDAI, this.sanDAI_EUR, this.perpetualManagerDAI] = await initCollateral(
        'DAI',
        this.stableMaster,
        this.ANGLE,
        governor,
        new BN(18),
      );
      // The default debt ratio of the strategy is 0.8
      [this.comp, this.compound, this.uniswapRouter, this.uniswapPool, this.genericCompound, this.strategy] =
        await initStrategy('wBTC', this.wBTC, this.managerBTC, this.ANGLE, this.oracleETHWant, governor, guardian);
      await this.wBTC.mint(this.managerBTC.address, ether('10'));
      expect(await this.wBTC.balanceOf(this.managerBTC.address)).to.be.bignumber.equal(ether('10'));
      await this.strategy.harvest();
      expect(await this.managerBTC.getTotalAsset()).to.be.bignumber.equal(ether('10'));
      // But 8 lent from manager to strategy
      expect(await this.wBTC.balanceOf(this.managerBTC.address)).to.be.bignumber.equal(ether('2'));
      expect(await this.strategy.estimatedTotalAssets()).to.be.bignumber.equal(ether('8'));
    });

    it('success - parameter = true', async () => {
      // This automatically harvests
      await this.managerBTC.setStrategyEmergencyExit(this.strategy.address, { from: governor });
      expect(await this.strategy.emergencyExit()).to.be.equal(true);
    });
  });

  describe('setEmergencyExit - harvest amount freed > debt outstanding', () => {
    it('init', async () => {
      [this.core, this.ANGLE, this.stableMaster, this.agEUR] = await initAngle(governor, guardian);
      [this.wBTC, this.oracleBTC, this.managerBTC, this.sanBTC_EUR, this.perpetualManagerBTC] = await initCollateral(
        'wBTC',
        this.stableMaster,
        this.ANGLE,
        governor,
        new BN(18),
      );

      [this.DAI, this.oracleDAI, this.managerDAI, this.sanDAI_EUR, this.perpetualManagerDAI] = await initCollateral(
        'DAI',
        this.stableMaster,
        this.ANGLE,
        governor,
        new BN(18),
      );
      // The default debt ratio of the strategy is 0.8
      [this.comp, this.compound, this.uniswapRouter, this.uniswapPool, this.genericCompound, this.strategy] =
        await initStrategy('wBTC', this.wBTC, this.managerBTC, this.ANGLE, this.oracleETHWant, governor, guardian);

      await this.wBTC.mint(this.managerBTC.address, ether('10'));
      expect(await this.wBTC.balanceOf(this.managerBTC.address)).to.be.bignumber.equal(ether('10'));
      await this.strategy.harvest();
      expect(await this.managerBTC.getTotalAsset()).to.be.bignumber.equal(ether('10'));
      // But 8 lent from manager to strategy
      expect(await this.wBTC.balanceOf(this.managerBTC.address)).to.be.bignumber.equal(ether('2'));
      expect(await this.strategy.estimatedTotalAssets()).to.be.bignumber.equal(ether('8'));
    });
    it('update Compound Exchange Rate - success', async () => {
      // Minting the tokens for the capital gain made on Compound
      await this.wBTC.mint(this.compound.address, ether('10000'));
      await this.compound.updateExchangeRate(ether('2'));
      expect(await this.genericCompound.nav()).to.be.bignumber.equal(ether('16'));
      expect(await this.strategy.estimatedTotalAssets()).to.be.bignumber.equal(ether('16'));
    });
    it('success - emergencyExit prepared', async () => {
      // This automatically harvests
      await this.managerBTC.setStrategyEmergencyExit(this.strategy.address, { from: governor });
      expect(await this.strategy.emergencyExit()).to.be.equal(true);
    });
  });

  describe('withdrawSome', () => {
    it('init', async () => {
      [this.core, this.ANGLE, this.stableMaster, this.agEUR] = await initAngle(governor, guardian);
      [this.wBTC, this.oracleBTC, this.managerBTC, this.sanBTC_EUR, this.perpetualManagerBTC] = await initCollateral(
        'wBTC',
        this.stableMaster,
        this.ANGLE,
        governor,
        new BN(18),
      );

      [this.DAI, this.oracleDAI, this.managerDAI, this.sanDAI_EUR, this.perpetualManagerDAI] = await initCollateral(
        'DAI',
        this.stableMaster,
        this.ANGLE,
        governor,
        new BN(18),
      );
      // The default debt ratio of the strategy is 0.8
      [this.comp, this.compound, this.uniswapRouter, this.uniswapPool, this.genericCompound, this.strategy] =
        await initStrategy('wBTC', this.wBTC, this.managerBTC, this.ANGLE, this.oracleETHWant, governor, guardian);

      await this.wBTC.mint(this.managerBTC.address, ether('10'));
      expect(await this.wBTC.balanceOf(this.managerBTC.address)).to.be.bignumber.equal(ether('10'));
      await this.strategy.harvest();
    });
    it('withdrawFromStrategy - success - small amount', async () => {
      await this.managerBTC.withdrawFromStrategy(this.strategy.address, new BN('1'), { from: governor });
      expect(await this.wBTC.balanceOf(this.managerBTC.address)).to.be.bignumber.equal(ether('2'));
    });
    it('removeLender - success', async () => {
      // This automatically harvests
      await this.strategy.safeRemoveLender(this.genericCompound.address, { from: governor });
      expect(await this.wBTC.balanceOf(this.strategy.address)).to.be.bignumber.equal(ether('8'));
    });
    it('withdrawFromStrategy - success - withdraw important amount when there are no lenders left', async () => {
      // This automatically harvests
      await this.managerBTC.withdrawFromStrategy(this.strategy.address, ether('9'), { from: governor });
      expect(await this.wBTC.balanceOf(this.managerBTC.address)).to.be.bignumber.equal(ether('10'));
    });
  });

  describe('withdrawSome -  multiple lenders', () => {
    it('init', async () => {
      [this.core, this.ANGLE, this.stableMaster, this.agEUR] = await initAngle(governor, guardian);
      [this.wBTC, this.oracleBTC, this.managerBTC, this.sanBTC_EUR, this.perpetualManagerBTC] = await initCollateral(
        'wBTC',
        this.stableMaster,
        this.ANGLE,
        governor,
        new BN(18),
      );

      [this.DAI, this.oracleDAI, this.managerDAI, this.sanDAI_EUR, this.perpetualManagerDAI] = await initCollateral(
        'DAI',
        this.stableMaster,
        this.ANGLE,
        governor,
        new BN(18),
      );
      // The default debt ratio of the strategy is 0.8
      [this.comp, this.compound, this.uniswapRouter, this.uniswapPool, this.genericCompound, this.strategy] =
        await initStrategy('wBTC', this.wBTC, this.managerBTC, this.ANGLE, this.oracleETHWant, governor, guardian);

      this.genericCompound2 = await artifacts
        .require('GenericCompound')
        .new(
          this.strategy.address,
          ' ',
          this.uniswapRouter.address,
          this.uniswapV2Router.address,
          this.comptroller.address,
          this.comp.address,
          web3.utils.asciiToHex('0'),
          this.compound.address,
          [governor],
          guardian,
        );

      this.genericCompound3 = await artifacts
        .require('GenericCompound')
        .new(
          this.strategy.address,
          ' ',
          this.uniswapRouter.address,
          this.uniswapV2Router.address,
          this.comptroller.address,
          this.comp.address,
          web3.utils.asciiToHex('0'),
          this.compound.address,
          [governor],
          guardian,
        );

      await this.wBTC.mint(this.managerBTC.address, ether('10'));
      expect(await this.wBTC.balanceOf(this.managerBTC.address)).to.be.bignumber.equal(ether('10'));
      await this.strategy.harvest();
      expect(await this.wBTC.balanceOf(this.managerBTC.address)).to.be.bignumber.equal(ether('2'));
    });
    it('genericCompound - constructor - reverts wrong cToken', async () => {
      await expectRevert(
        artifacts
          .require('GenericCompound')
          .new(
            this.strategy2.address,
            ' ',
            this.uniswapRouter.address,
            this.uniswapV2Router.address,
            this.comptroller.address,
            this.comp.address,
            web3.utils.asciiToHex('0'),
            this.compound.address,
            [governor],
            guardian,
          ),
        'wrong cToken',
      );
    });
    it('genericCompound - constructor - reverts zero address', async () => {
      await expectRevert(
        artifacts
          .require('GenericCompound')
          .new(
            this.strategy.address,
            ' ',
            ZERO_ADDRESS,
            this.uniswapV2Router.address,
            this.comptroller.address,
            this.comp.address,
            web3.utils.asciiToHex('0'),
            this.compound.address,
            [governor],
            guardian,
          ),
        '0',
      );

      await expectRevert(
        artifacts
          .require('GenericCompound')
          .new(
            this.strategy.address,
            ' ',
            this.uniswapRouter.address,
            ZERO_ADDRESS,
            this.comptroller.address,
            this.comp.address,
            web3.utils.asciiToHex('0'),
            this.compound.address,
            [governor],
            guardian,
          ),
        '0',
      );

      await expectRevert(
        artifacts
          .require('GenericCompound')
          .new(
            this.strategy.address,
            ' ',
            this.uniswapRouter.address,
            this.uniswapV2Router.address,
            ZERO_ADDRESS,
            this.comp.address,
            web3.utils.asciiToHex('0'),
            this.compound.address,
            [governor],
            guardian,
          ),
        '0',
      );

      await expectRevert.unspecified(
        artifacts
          .require('GenericCompound')
          .new(
            this.strategy.address,
            ' ',
            this.uniswapRouter.address,
            this.uniswapV2Router.address,
            this.comptroller.address,
            ZERO_ADDRESS,
            web3.utils.asciiToHex('0'),
            this.compound.address,
            [governor],
            guardian,
          ),
      );

      await expectRevert.unspecified(
        artifacts
          .require('GenericCompound')
          .new(
            ZERO_ADDRESS,
            ' ',
            this.uniswapRouter.address,
            this.uniswapV2Router.address,
            this.comptroller.address,
            this.comp.address,
            web3.utils.asciiToHex('0'),
            this.compound.address,
            [governor],
            guardian,
          ),
      );

      await expectRevert.unspecified(
        artifacts
          .require('GenericCompound')
          .new(
            this.strategy.address,
            ' ',
            this.uniswapRouter.address,
            this.uniswapV2Router.address,
            this.comptroller.address,
            this.comp.address,
            web3.utils.asciiToHex('0'),
            ZERO_ADDRESS,
            [governor],
            guardian,
          ),
      );
    });

    it('addLender - success - adding multiple', async () => {
      await this.strategy.addLender(this.genericCompound3.address, { from: governor });
      await this.strategy.addLender(this.genericCompound2.address, { from: governor });
    });
    it('removeLender - success', async () => {
      await this.strategy.safeRemoveLender(this.genericCompound3.address, { from: governor });
    });
    it('withdrawSome - fail - under withdrawThreshold', async () => {
      await this.strategy.setWithdrawalThreshold(ether('9'));
      const totalStrategyDebtPre = (await this.managerBTC.strategies(this.strategy.address)).totalStrategyDebt;
      await this.managerBTC.withdrawFromStrategy(this.strategy.address, ether('8'), { from: governor });
      await this.strategy.setWithdrawalThreshold(ether('0'));
      const totalStrategyDebtPost = (await this.managerBTC.strategies(this.strategy.address)).totalStrategyDebt;
      // ether('8') is considered as dust, therefore not considered as gain --> no change of totalStrategyDebt
      expect(totalStrategyDebtPre).to.be.bignumber.equal(totalStrategyDebtPost);
    });
    it('withdrawSome - success - two lenders', async () => {
      // This automatically harvests
      await this.managerBTC.withdrawFromStrategy(this.strategy.address, ether('8'), { from: governor });
      expect(await this.wBTC.balanceOf(this.managerBTC.address)).to.be.bignumber.equal(ether('10'));
    });
  });
});
