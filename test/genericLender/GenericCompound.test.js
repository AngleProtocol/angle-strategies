require('@openzeppelin/test-helpers/src/setup');
const { BN } = require('@openzeppelin/test-helpers/src/setup');
const {
  // utils
  BASE,
  ether,
  expectRevert,
  expect,
  expectApprox,
  BASE_ORACLE,
  MockOracle,
  // functions
  initAngle,
  initCollateral,
  initStrategy,
} = require('../helpers');

// Start test block
contract('GenericCompound', accounts => {
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

    this.oracleETHWant = await MockOracle.new(BASE_ORACLE, new BN('18'));

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

    this.supplySpeed = await this.comptroller.price();
    this.blocksPerYear = new BN('2350000');

    await this.genericCompound.grantRole(web3.utils.soliditySha3('STRATEGY_ROLE'), tester, { from: governor });
    this.guardianRole = web3.utils.soliditySha3('GUARDIAN_ROLE');
    this.guardianError = `AccessControl: account ${user.toLowerCase()} is missing role ${this.guardianRole}`;
    this.strategyRole = web3.utils.soliditySha3('STRATEGY_ROLE');
    this.strategyError = `AccessControl: account ${user.toLowerCase()} is missing role ${this.strategyRole}`;
  });

  describe('Initialization', () => {
    describe('Parameters', () => {
      it('uniswapV3Router', async () => {
        expect(await this.genericCompound.uniswapV3Router()).to.be.equal(this.uniswapRouter.address);
      });
      it('uniswapV2Router', async () => {
        expect(await this.genericCompound.uniswapV2Router()).to.be.equal(this.uniswapV2Router.address);
      });
      it('comp', async () => {
        expect(await this.genericCompound.comp()).to.be.equal(this.comp.address);
      });
      it('comptroller', async () => {
        expect(await this.genericCompound.comptroller()).to.be.equal(this.comptroller.address);
      });
      it('cToken', async () => {
        expect(await this.genericCompound.cToken()).to.be.equal(this.compound.address);
      });
      it('minCompToSell', async () => {
        expect(await this.genericCompound.minCompToSell()).to.be.bignumber.equal(BASE.div(new BN('2')));
      });
      it('path', async () => {
        expect(await this.genericCompound.path()).to.be.equal(web3.utils.asciiToHex('0'));
      });
      it('lenderName', async () => {
        expect(await this.genericCompound.lenderName()).to.be.equal('wBTC');
      });
      it('poolManager', async () => {
        expect(await this.genericCompound.poolManager()).to.be.equal(this.managerBTC.address);
      });
      it('strategy', async () => {
        expect(await this.genericCompound.strategy()).to.be.equal(this.strategy.address);
      });
      it('want', async () => {
        expect(await this.genericCompound.want()).to.be.equal(this.wBTC.address);
      });
    });
    describe('Access Control', () => {
      it('deposit - reverts nonStrategy', async () => {
        await expectRevert(this.genericCompound.deposit({ from: user }), this.strategyError);
      });
      it('withdraw - reverts nonStrategy', async () => {
        await expectRevert(this.genericCompound.withdraw(new BN('1'), { from: user }), this.strategyError);
      });
      it('withdrawAll - reverts nonStrategy', async () => {
        await expectRevert(this.genericCompound.withdrawAll({ from: user }), this.strategyError);
      });
      it('setPath - reverts nonGuardian', async () => {
        await expectRevert(
          this.genericCompound.setPath(web3.utils.asciiToHex('0'), { from: user }),
          this.guardianError,
        );
      });
      it('emergencyWithdraw - reverts nonGuardian', async () => {
        await expectRevert(this.genericCompound.emergencyWithdraw(new BN('1'), { from: user }), this.guardianError);
      });
      it('sweep - reverts nonGuardian', async () => {
        await expectRevert.unspecified(this.genericCompound.sweep(this.comp.address, user, { from: user }));
      });
    });
  });

  describe('sweep', () => {
    it('reverts - protected token', async () => {
      await this.ANGLE.mint(this.genericCompound.address, ether('1'));
      await expectRevert(this.genericCompound.sweep(this.comp.address, user, { from: governor }), '93');
    });

    it('success - balance updated', async () => {
      await this.genericCompound.sweep(this.ANGLE.address, user, { from: governor });
      expect(await this.ANGLE.balanceOf(user)).to.be.bignumber.equal(ether('1'));
    });
  });

  describe('deposit', () => {
    it('success', async () => {
      await this.wBTC.mint(this.genericCompound.address, ether('1'));
      await this.genericCompound.deposit({ from: tester });
      expect(await this.wBTC.balanceOf(this.genericCompound.address)).to.be.bignumber.equal(ether('0'));
      expect(await this.compound.balanceOf(this.genericCompound.address)).to.be.bignumber.equal(ether('1'));
    });

    it('success - failure of compound catch', async () => {
      await expectRevert(this.genericCompound.deposit({ from: tester }), 'mint fail');
    });
  });

  describe('withdraw', () => {
    it('success - more than total', async () => {
      await this.genericCompound.withdraw(ether('2'), { from: tester });
      expect(await this.wBTC.balanceOf(this.strategy.address)).to.be.bignumber.equal(ether('1'));
    });

    it('success - without interaction with compound', async () => {
      await this.wBTC.mint(this.genericCompound.address, ether('1'));
      await this.genericCompound.withdraw(ether('1'), { from: tester });
      expect(await this.wBTC.balanceOf(this.strategy.address)).to.be.bignumber.equal(ether('2'));
    });

    it('success - with withdrawal', async () => {
      await this.wBTC.mint(this.genericCompound.address, ether('1'));
      await this.genericCompound.deposit({ from: tester });
      await this.wBTC.mint(this.genericCompound.address, ether('1'));
      await this.genericCompound.withdraw(ether('2'), { from: tester });
      expect(await this.wBTC.balanceOf(this.strategy.address)).to.be.bignumber.equal(ether('4'));
    });

    it('success - with comp swap', async () => {
      await this.wBTC.mint(this.genericCompound.address, ether('1'));
      await this.genericCompound.deposit({ from: tester });
      await this.wBTC.mint(this.genericCompound.address, ether('1'));
      // Add comp gov reward tokens
      await this.comp.mint(this.genericCompound.address, ether('1'));
      // The withdrawal should swap the comp
      await this.genericCompound.withdraw(ether('2'), { from: tester });
      expect(await this.comp.balanceOf(this.genericCompound.address)).to.be.bignumber.equal(ether('0'));
      expect(await this.comp.balanceOf(this.uniswapRouter.address)).to.be.bignumber.equal(ether('1'));
      expect(await this.wBTC.balanceOf(this.strategy.address)).to.be.bignumber.equal(ether('7'));
    });
  });

  describe('emergencyWithdraw', () => {
    it('success', async () => {
      await this.wBTC.mint(this.genericCompound.address, ether('1'));
      await this.genericCompound.deposit({ from: tester });
      await this.genericCompound.emergencyWithdraw(ether('1'), { from: guardian });
      expect(await this.wBTC.balanceOf(this.managerBTC.address)).to.be.bignumber.equal(ether('1'));
    });
  });

  describe('withdrawAll', () => {
    it('init', async () => {
      await this.wBTC.mint(this.genericCompound.address, ether('1'));
      await this.genericCompound.deposit({ from: tester });
      await this.wBTC.mint(this.genericCompound.address, ether('1'));
      expect(await this.genericCompound.nav()).to.be.bignumber.equal(ether('2'));
    });

    it('success - success balances updated', async () => {
      await this.genericCompound.withdrawAll({ from: tester });
      expect(await this.genericCompound.nav()).to.be.bignumber.equal(ether('0'));
      expect(await this.wBTC.balanceOf(this.strategy.address)).to.be.bignumber.equal(ether('9'));
    });
  });

  describe('underlyingBalanceStored', () => {
    it('success - without cToken', async () => {
      expect(await this.genericCompound.underlyingBalanceStored()).to.be.bignumber.equal(ether('0'));
    });

    it('success - with cToken', async () => {
      await this.wBTC.mint(this.genericCompound.address, ether('1'));
      await this.genericCompound.deposit({ from: tester });
      expect(await this.genericCompound.underlyingBalanceStored()).to.be.bignumber.equal(ether('1'));
    });
  });

  describe('apr', () => {
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
      expectApprox(await this.genericCompound.apr(), ether('0.04').add(incentivesRate));
    });
  });

  describe('aprAfterDeposit', () => {
    it('success', async () => {
      const cTokenSupply = await this.compound.totalSupply();
      const exchangeRate = await this.compound.exchangeRateStored();
      const supplyInWant = cTokenSupply.mul(exchangeRate).div(BASE).add(ether('1'));

      const compInWant = this.supplySpeed.mul(new BN('10'));
      const incentivesRate = compInWant
        .mul(this.blocksPerYear)
        .mul(BASE)
        .div(supplyInWant)
        .mul(new BN(95))
        .div(new BN('100'));
      expectApprox(await this.genericCompound.aprAfterDeposit(ether('1')), ether('0.04').add(incentivesRate));
    });
  });

  describe('weightedApr', () => {
    it('success', async () => {
      await this.wBTC.mint(this.genericCompound.address, ether('1'));
      await this.genericCompound.deposit({ from: tester });
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
      expect(await this.genericCompound.nav()).to.be.bignumber.equal(ether('2'));
      expectApprox(await this.genericCompound.weightedApr(), ether('0.04').add(incentivesRate).mul(ether('2')));
    });
  });

  describe('hasAssets', () => {
    it('success - with assets', async () => {
      expect(await this.genericCompound.hasAssets()).to.be.equal(true);
    });

    it('success - without assets', async () => {
      await this.genericCompound.withdrawAll({ from: tester });
      expect(await this.genericCompound.hasAssets()).to.be.equal(false);
    });
  });

  describe('setPath', () => {
    it('success - path changed', async () => {
      this.path = web3.utils.soliditySha3('GUARDIAN_ROLE');
      await this.genericCompound.setPath(this.path, { from: governor });
      expect(await this.genericCompound.path()).to.be.equal(this.path);
    });
  });
  describe('apr - with null supply speed', () => {
    it('success', async () => {
      await this.comptroller.setPrice(new BN('0'));
      const supplyRate = await this.compound.supplyRatePerBlock();
      const receipt = await this.genericCompound.apr();
      expect(receipt).to.be.bignumber.equal(supplyRate.mul(new BN('2350000')));
    });
  });

  describe('withdraw - other branches', () => {
    it('init', async () => {
      [this.core, this.ANGLE, this.stableMaster, this.agEUR] = await initAngle(governor, guardian);
      [this.wBTC, this.oracleBTC, this.managerBTC, this.sanBTC_EUR, this.perpetualManagerBTC] = await initCollateral(
        'wBTC',
        this.stableMaster,
        this.ANGLE,
        governor,
        new BN(18),
      );
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
      await this.genericCompound.grantRole(web3.utils.soliditySha3('STRATEGY_ROLE'), tester, { from: governor });
    });
    it('success - null liquidity', async () => {
      // Liquidity
      await this.compound.mint(this.genericCompound.address, ether('3'));
      await this.genericCompound.withdraw(ether('3'), { from: tester });
    });
    it('success - toWithdraw > Liquidity', async () => {
      await this.wBTC.mint(this.compound.address, ether('2'));
      await this.genericCompound.withdraw(ether('3'), { from: tester });
    });
  });
});
