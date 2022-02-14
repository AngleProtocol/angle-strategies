require('@openzeppelin/test-helpers/src/setup');
const { ZERO_ADDRESS } = require('@openzeppelin/test-helpers/src/constants');
const expectEvent = require('@openzeppelin/test-helpers/src/expectEvent');
const { BN } = require('@openzeppelin/test-helpers/src/setup');
const {
  // utils
  ether,
  expectRevert,
  expect,
  BASE_ORACLE,
  BASE,
  gwei,
  GenericAave,
  MockOracle,
  MockAave,
  MockUniswapV3Router,
  MockUniswapV2Router,
  MockProtocolDataProvider,
  Strategy,
  // functions
  initAngle,
  initCollateral,
  MAX_UINT256,
} = require('../helpers');

// Start test block
contract('GenericAave', accounts => {
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
    this.aaveContract = await MockAave.new('AAVE', 'AAVE', this.wBTC.address);
    this.aaveContract.deployNewUnderlying(this.wBTC.address);
    this.uniswapV3Router = await MockUniswapV3Router.new(this.aaveContract.address, this.wBTC.address);
    this.uniswapV2Router = await MockUniswapV2Router.new(new BN('10'));
    this.strategy = await Strategy.new(this.managerBTC.address, this.ANGLE.address, [governor], guardian);
    this.protocolDataProvider = await MockProtocolDataProvider.new(this.aaveContract.address);
    this.params = {
      aToken: this.aaveContract.address,
      protocolDataProvider: this.protocolDataProvider.address,
      stkAave: this.aaveContract.address,
      aave: this.aaveContract.address,
    };

    this.genericAave = await GenericAave.new(
      this.strategy.address,
      'aave',
      this.uniswapV3Router.address,
      this.uniswapV2Router.address,
      this.params,
      false,
      web3.utils.asciiToHex('0'),
      [governor],
      guardian,
    );

    await this.strategy.addLender(this.genericAave.address, { from: governor });

    await this.managerBTC.addStrategy(this.strategy.address, gwei('0.8'), { from: governor });
    // For easier testing:
    await this.genericAave.grantRole(web3.utils.soliditySha3('STRATEGY_ROLE'), tester, { from: governor });
    this.guardianRole = web3.utils.soliditySha3('GUARDIAN_ROLE');
    this.guardianError = `AccessControl: account ${user.toLowerCase()} is missing role ${this.guardianRole}`;
    this.strategyRole = web3.utils.soliditySha3('STRATEGY_ROLE');
    this.strategyError = `AccessControl: account ${user.toLowerCase()} is missing role ${this.strategyRole}`;
  });

  describe('Initialization', () => {
    describe('Parameters', () => {
      it('uniswapV3Router', async () => {
        expect(await this.genericAave.uniswapV3Router()).to.be.equal(this.uniswapV3Router.address);
      });
      it('uniswapV2Router', async () => {
        expect(await this.genericAave.uniswapV2Router()).to.be.equal(this.uniswapV2Router.address);
      });
      it('aToken', async () => {
        expect(await this.genericAave.aToken()).to.be.equal(this.aaveContract.address);
      });
      it('protocolDataProvider', async () => {
        expect(await this.genericAave.protocolDataProvider()).to.be.equal(this.protocolDataProvider.address);
      });
      it('stkAave', async () => {
        expect(await this.genericAave.stkAave()).to.be.equal(this.aaveContract.address);
      });
      it('aave', async () => {
        expect(await this.genericAave.aave()).to.be.equal(this.aaveContract.address);
      });
      it('path', async () => {
        expect(await this.genericAave.path()).to.be.equal(web3.utils.asciiToHex('0'));
      });
      it('isIncentivised', async () => {
        expect(await this.genericAave.isIncentivised()).to.be.equal(false);
      });
      it('lenderName', async () => {
        expect(await this.genericAave.lenderName()).to.be.equal('aave');
      });
      it('poolManager', async () => {
        expect(await this.genericAave.poolManager()).to.be.equal(this.managerBTC.address);
      });
      it('strategy', async () => {
        expect(await this.genericAave.strategy()).to.be.equal(this.strategy.address);
      });
      it('want', async () => {
        expect(await this.genericAave.want()).to.be.equal(this.wBTC.address);
      });
    });
    describe('Access Control', () => {
      it('deposit - reverts nonStrategy', async () => {
        await expectRevert(this.genericAave.deposit({ from: user }), this.strategyError);
      });
      it('withdraw - reverts nonStrategy', async () => {
        await expectRevert(this.genericAave.withdraw(new BN('1'), { from: user }), this.strategyError);
      });
      it('withdrawAll - reverts nonStrategy', async () => {
        await expectRevert(this.genericAave.withdrawAll({ from: user }), this.strategyError);
      });
      it('setPath - reverts nonGuardian', async () => {
        await expectRevert(this.genericAave.setPath(web3.utils.asciiToHex('0'), { from: user }), this.guardianError);
      });
      it('emergencyWithdraw - reverts nonGuardian', async () => {
        await expectRevert(this.genericAave.emergencyWithdraw(new BN('1'), { from: user }), this.guardianError);
      });
      it('sweep - reverts nonGuardian', async () => {
        await expectRevert(this.genericAave.sweep(this.aaveContract.address, user, { from: user }), this.guardianError);
      });
      it('setReferralCode - reverts nonGuardian', async () => {
        await expectRevert(this.genericAave.setReferralCode(new BN('1'), { from: user }), this.guardianError);
      });
      it('setIsIncentivised - reverts nonGuardian', async () => {
        await expectRevert(this.genericAave.setIsIncentivised(false, { from: user }), this.guardianError);
      });
      it('startCooldown - reverts nonGuardian', async () => {
        await expectRevert(this.genericAave.startCooldown({ from: user }), this.guardianError);
      });
    });
    describe('constructor', () => {
      it('reverts - zero uniswapV3 address', async () => {
        await expectRevert(
          GenericAave.new(
            this.strategy.address,
            'aave',
            ZERO_ADDRESS,
            this.uniswapV2Router.address,
            this.params,
            false,
            web3.utils.asciiToHex('0'),
            [governor],
            guardian,
          ),
          '0',
        );
      });
      it('reverts - zero uniswapV2 address', async () => {
        await expectRevert(
          GenericAave.new(
            this.strategy.address,
            'aave',
            this.uniswapV3Router.address,
            ZERO_ADDRESS,
            this.params,
            false,
            web3.utils.asciiToHex('0'),
            [governor],
            guardian,
          ),
          '0',
        );
      });
      it('reverts - zero stkAave address', async () => {
        this.params = {
          aToken: this.aaveContract.address,
          protocolDataProvider: this.protocolDataProvider.address,
          stkAave: ZERO_ADDRESS,
          aave: this.aaveContract.address,
        };
        await expectRevert(
          GenericAave.new(
            this.strategy.address,
            'aave',
            this.uniswapV3Router.address,
            this.uniswapV2Router.address,
            this.params,
            false,
            web3.utils.asciiToHex('0'),
            [governor],
            guardian,
          ),
          '0',
        );
      });
      it('reverts - zero aToken address', async () => {
        this.params = {
          aToken: ZERO_ADDRESS,
          protocolDataProvider: this.protocolDataProvider.address,
          stkAave: this.aaveContract.address,
          aave: this.aaveContract.address,
        };
        await expectRevert.unspecified(
          GenericAave.new(
            this.strategy.address,
            'aave',
            this.uniswapV3Router.address,
            this.uniswapV2Router.address,
            this.params,
            false,
            web3.utils.asciiToHex('0'),
            [governor],
            guardian,
          ),
        );
      });
    });
  });

  describe('setIsIncentivised', () => {
    it('harvestTrigger - returns false', async () => {
      expect(await this.genericAave.harvestTrigger()).to.be.equal(false);
    });
    it('harvest - reverts - conditions are not met', async () => {
      await expectRevert(this.genericAave.harvest(), 'conditions are not met');
    });
    it('apr - null', async () => {
      expect(await this.genericAave.apr()).to.be.bignumber.equal(new BN('0'));
    });
    it('success - parameter updated', async () => {
      await this.genericAave.setIsIncentivised(true, { from: guardian });
      expect(await this.genericAave.isIncentivised()).to.be.equal(true);
    });
    it('harvest - null stkAave balance', async () => {
      await this.genericAave.harvest();
    });
  });

  describe('hasAssets', () => {
    it('success', async () => {
      expect(await this.genericAave.hasAssets()).to.be.equal(false);
    });
  });

  describe('withdrawAll', () => {
    it('success', async () => {
      await this.genericAave.withdrawAll({ from: tester });
    });
  });

  describe('apr', () => {
    it('startCooldown', async () => {
      await this.genericAave.startCooldown({ from: guardian });
    });
  });

  describe('setPath', () => {
    it('success', async () => {
      await this.genericAave.setPath(web3.utils.asciiToHex('1'), { from: guardian });
      expect(await this.genericAave.path()).to.be.equal(web3.utils.asciiToHex('1'));
    });
  });

  describe('nav', () => {
    it('success', async () => {
      expect(await this.genericAave.nav()).to.be.bignumber.equal(new BN('0'));
    });
  });

  describe('underlyingBalanceStored', () => {
    it('success', async () => {
      expect(await this.genericAave.underlyingBalanceStored()).to.be.bignumber.equal(new BN('0'));
    });
  });

  describe('apr', () => {
    it('success', async () => {
      expect(await this.genericAave.apr()).to.be.bignumber.equal(new BN('0'));
    });
  });

  describe('weightedApr', () => {
    it('success', async () => {
      expect(await this.genericAave.weightedApr()).to.be.bignumber.equal(new BN('0'));
    });
  });

  describe('aprAfterDeposit', () => {
    it('success', async () => {
      await this.aaveContract.setDistributionEnd(new BN('0'));
      expect(await this.genericAave.aprAfterDeposit(new BN('1'))).to.be.bignumber.equal(
        ether('0.04').div(new BN('1000000000')),
      );
    });
  });

  describe('sweep', () => {
    it('reverts - protected token', async () => {
      await this.ANGLE.mint(this.genericAave.address, ether('1'));
      await expectRevert(this.genericAave.sweep(this.aaveContract.address, user, { from: governor }), '93');
    });

    it('success - balance updated', async () => {
      await this.genericAave.sweep(this.ANGLE.address, user, { from: governor });
      expect(await this.ANGLE.balanceOf(user)).to.be.bignumber.equal(ether('1'));
    });
  });

  describe('deposit', () => {
    it('success', async () => {
      await this.wBTC.mint(this.genericAave.address, ether('1'));
      await this.genericAave.deposit({ from: tester });
      expect(await this.wBTC.balanceOf(this.genericAave.address)).to.be.bignumber.equal(ether('0'));
      expect(await this.aaveContract.balanceOf(this.genericAave.address)).to.be.bignumber.equal(ether('1'));
    });
    it('hasAssets - success', async () => {
      expect(await this.genericAave.hasAssets()).to.be.equal(true);
    });
  });
  describe('setReferralCode', () => {
    it('success', async () => {
      const receipt = await this.genericAave.setReferralCode(new BN('10'), { from: guardian });
      expectEvent(receipt, 'CustomReferralUpdated', {
        customReferral: new BN('10'),
      });
    });
    it('reverts - invalid referral code', async () => {
      await expectRevert(this.genericAave.setReferralCode(new BN('0'), { from: guardian }), 'invalid referral code');
    });
  });

  describe('harvestTrigger', () => {
    it('success', async () => {
      expect(await this.genericAave.harvestTrigger()).to.be.equal(true);
    });
    it('success - returns false when weird conditions', async () => {
      await this.aaveContract.setUnstakeWindowAndStakers(new BN('0'), new BN('1'));
      expect(await this.genericAave.harvestTrigger()).to.be.equal(false);
      await this.aaveContract.setUnstakeWindowAndStakers(new BN('0'), MAX_UINT256);
      expect(await this.genericAave.harvestTrigger()).to.be.equal(false);
      await this.aaveContract.setUnstakeWindowAndStakers(MAX_UINT256, new BN('0'));
    });
  });

  describe('apr & weightedApr - with collateral', () => {
    it('success - with no incentives', async () => {
      await this.aaveContract.setCurrentLiquidityRate(BASE.mul(new BN('1000000000')));
      expect(await this.genericAave.apr()).to.be.bignumber.equal(BASE);
    });
    it('success - with available liquidity and incentives', async () => {
      await this.aaveContract.setDistributionEnd(MAX_UINT256);
      await this.protocolDataProvider.setAvailableLiquidity(BASE);
      // Emissions per second is 10, emissions in want is 100, seconds in year are 31536000 -> 3 153 600 000
      // 3 153 600 000 * 9.5 / 10
      expect(await this.genericAave.apr()).to.be.bignumber.equal(
        BASE.add(new BN('3153600000').mul(new BN('95')).div(new BN('100'))),
      );
    });
    it('success - with null emissions per second', async () => {
      await this.aaveContract.setEmissionsPerSecond(new BN('0'));
      expect(await this.genericAave.apr()).to.be.bignumber.equal(BASE);
      await this.aaveContract.setEmissionsPerSecond(new BN('10'));
    });
  });

  describe('underlyingBalanceStored', () => {
    it('success', async () => {
      expect(await this.genericAave.underlyingBalanceStored()).to.be.bignumber.equal(ether('1'));
    });
  });

  describe('withdraw', () => {
    it('success - more than total', async () => {
      await this.genericAave.withdraw(ether('2'), { from: tester });
      expect(await this.wBTC.balanceOf(this.strategy.address)).to.be.bignumber.equal(ether('1'));
    });

    it('success - without interaction with Aave', async () => {
      await this.wBTC.mint(this.genericAave.address, ether('1'));
      await this.genericAave.withdraw(ether('1'), { from: tester });
      expect(await this.wBTC.balanceOf(this.strategy.address)).to.be.bignumber.equal(ether('2'));
    });

    it('success - with withdrawal', async () => {
      await this.wBTC.mint(this.genericAave.address, ether('1'));
      await this.genericAave.deposit({ from: tester });
      await this.wBTC.mint(this.genericAave.address, ether('1'));
      await this.genericAave.withdraw(ether('2'), { from: tester });
      expect(await this.wBTC.balanceOf(this.strategy.address)).to.be.bignumber.equal(ether('4'));
    });

    it('success - with no aave swap', async () => {
      await this.wBTC.mint(this.genericAave.address, ether('1'));
      await this.genericAave.deposit({ from: tester });
      await this.wBTC.mint(this.genericAave.address, ether('1'));
      // Add comp gov reward tokens
      await this.aaveContract.mint(this.genericAave.address, ether('1'));
      // The withdrawal should not swap the aave -> we should use harvest
      await this.genericAave.withdraw(ether('2'), { from: tester });
      expect(await this.aaveContract.balanceOf(this.genericAave.address)).to.be.bignumber.equal(ether('1'));
      expect(await this.aaveContract.balanceOf(this.uniswapV3Router.address)).to.be.bignumber.equal(ether('0'));
      expect(await this.wBTC.balanceOf(this.strategy.address)).to.be.bignumber.equal(ether('6'));
    });
  });

  describe('emergencyWithdraw', () => {
    it('success', async () => {
      await this.wBTC.mint(this.genericAave.address, ether('1'));
      await this.genericAave.deposit({ from: tester });
      await this.genericAave.emergencyWithdraw(ether('1'), { from: guardian });
      expect(await this.wBTC.balanceOf(this.managerBTC.address)).to.be.bignumber.equal(ether('1'));
    });
  });

  describe('harvest - with rewards', () => {
    it('init', async () => {
      await this.aaveContract.mint(this.genericAave.address, ether('1'));
      await this.wBTC.mint(this.genericAave.address, ether('1'));
      await this.aaveContract.setRewardsBalance(ether('1'));
    });
    it('success', async () => {
      await this.genericAave.harvest();
    });
  });
  describe('harvest - without rewards', () => {
    it('init', async () => {
      await this.aaveContract.mint(this.genericAave.address, ether('1'));
      await this.wBTC.mint(this.genericAave.address, ether('1'));
    });
    it('success', async () => {
      await this.genericAave.harvest();
    });
  });

  describe('aprAfterDeposit - with rewards', () => {
    it('init', async () => {
      expect(await this.genericAave.aprAfterDeposit(new BN('1'))).to.be.bignumber.equal(
        ether('0.04')
          .div(new BN('1000000000'))
          .add(new BN('3153600000').mul(new BN('95')).div(new BN('100')))
          .sub(new BN('1')),
      );
    });
  });
});
