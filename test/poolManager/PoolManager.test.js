const { MAX_UINT256 } = require('@openzeppelin/test-helpers/src/constants');
const {
  // utils
  web3,
  BN,
  expectEvent,
  expectRevert,
  expect,
  // params
  BASE,
  BASE_PARAMS,
  // functions
  initAngle,
  initCollateral,
  MockStrategy,
  PoolManager,
  ZERO_ADDRESS,
} = require('../helpers');

// Start test block
contract('PoolManager', accounts => {
  const [governor, guardian, user, user2, minter] = accounts;

  describe('PoolManager', () => {
    before(async () => {
      [this.core, this.ANGLE, this.stableMaster, this.agEUR] = await initAngle(governor, guardian);
      [this.wBTC, this.oracleBTC, this.managerBTC, this.sanBTC_EUR, this.perpetualManagerBTC, this.feeManager] =
        await initCollateral('wBTC', this.stableMaster, this.ANGLE, governor);
      [this.DAI, this.oracleDAI, this.managerDAI, this.sanDAI_EUR, this.perpetualManagerDAI, this.feeManagerDAI] =
        await initCollateral('DAI', this.stableMaster, this.ANGLE, governor, new BN('18'));
      this.HA = web3.utils.soliditySha3('HA');
      this.SLP = web3.utils.soliditySha3('SLP');
      this.STABLE_HOLDER = web3.utils.soliditySha3('STABLE_HOLDER');

      await this.wBTC.mint(user, new BN(1000).mul(BASE));
      await this.wBTC.mint(user2, new BN(1000).mul(BASE));
      this.governorRole = web3.utils.soliditySha3('GOVERNOR_ROLE');
      this.guardianRole = web3.utils.soliditySha3('GUARDIAN_ROLE');
      this.governorError = `AccessControl: account ${user.toLowerCase()} is missing role ${this.governorRole}`;
      this.guardianError = `AccessControl: account ${user.toLowerCase()} is missing role ${this.guardianRole}`;
      this.stableMasterRole = web3.utils.soliditySha3('STABLEMASTER_ROLE');
      this.feeManagerRole = web3.utils.soliditySha3('FEEMANAGER_ROLE');
      this.stableMasterError = `AccessControl: account ${user.toLowerCase()} is missing role ${this.stableMasterRole}`;
      this.feeManagerError = `AccessControl: account ${user.toLowerCase()} is missing role ${this.feeManagerRole}`;
      this.strategyRole = web3.utils.soliditySha3('STRATEGY_ROLE');
      this.strategyError = `AccessControl: account ${user.toLowerCase()} is missing role ${this.strategyRole}`;
    });
    describe('Initialization', () => {
      it('token', async () => {
        expect(await this.managerBTC.token()).to.be.equal(this.wBTC.address);
      });
      it('perpetual manager', async () => {
        expect(await this.managerBTC.perpetualManager()).to.be.equal(this.perpetualManagerBTC.address);
      });
      it('stableMaster', async () => {
        expect(await this.managerBTC.stableMaster()).to.be.equal(this.stableMaster.address);
      });
      it('keeper', async () => {
        expect(await this.managerBTC.feeManager()).to.be.equal(this.feeManager.address);
      });
      it('totalDebt', async () => {
        expect(await this.managerBTC.totalDebt()).to.be.bignumber.equal(new BN('0'));
      });
      it('debtRatio', async () => {
        expect(await this.managerBTC.debtRatio()).to.be.bignumber.equal(new BN('0'));
      });
      it('interestsAccumulated', async () => {
        expect(await this.managerBTC.interestsAccumulated()).to.be.bignumber.equal(new BN('0'));
      });
      it('interestsForSurplus', async () => {
        expect(await this.managerBTC.interestsForSurplus()).to.be.bignumber.equal(new BN('0'));
      });
      it('surplusConverter', async () => {
        expect(await this.managerBTC.surplusConverter()).to.be.equal(ZERO_ADDRESS);
      });
      it('constructor reverts - zero token address', async () => {
        const manager = await PoolManager.new();
        await expectRevert(manager.initialize(ZERO_ADDRESS, this.stableMaster.address), '0');
      });
      it('constructor reverts - zero stableMaster address', async () => {
        const manager = await PoolManager.new();
        await expectRevert(manager.initialize(this.wBTC.address, ZERO_ADDRESS), '0');
      });
    });

    describe('AccessControl', () => {
      it('governor & guardian', async () => {
        expect(await this.managerBTC.hasRole(web3.utils.soliditySha3('GOVERNOR_ROLE'), governor)).to.be.equal(true);
        expect(await this.managerBTC.hasRole(web3.utils.soliditySha3('GUARDIAN_ROLE'), guardian)).to.be.equal(true);
        expect(await this.managerBTC.hasRole(web3.utils.soliditySha3('GUARDIAN_ROLE'), governor)).to.be.equal(true);
      });
      it('StableMaster', async () => {
        expect(
          await this.managerBTC.hasRole(web3.utils.soliditySha3('STABLEMASTER_ROLE'), this.stableMaster.address),
        ).to.be.equal(true);
      });
      it('deployCollateral - reverts nonStableMaster', async () => {
        await expectRevert(
          this.managerBTC.deployCollateral(
            [governor],
            governor,
            this.perpetualManagerBTC.address,
            this.feeManager.address,
            this.oracleBTC.address,
            { from: user },
          ),
          this.stableMasterError,
        );
      });

      it('grantRole - reverts nonStableMaster', async () => {
        await expectRevert.unspecified(
          this.managerBTC.grantRole(web3.utils.soliditySha3('STRATEGY_ROLE'), user, { from: user }),
        );
      });

      it('addGovernor - reverts nonStableMaster', async () => {
        await expectRevert(this.managerBTC.addGovernor(governor, { from: user }), this.stableMasterError);
      });
      it('removeGovernor - reverts nonStableMaster', async () => {
        await expectRevert(this.managerBTC.removeGovernor(governor, { from: user }), this.stableMasterError);
      });
      it('setGuardian - reverts nonStableMaster', async () => {
        await expectRevert(this.managerBTC.setGuardian(governor, guardian, { from: user }), this.stableMasterError);
      });
      it('revokeGuardian - reverts nonStableMaster', async () => {
        await expectRevert(this.managerBTC.revokeGuardian(guardian, { from: user }), this.stableMasterError);
      });
      it('setFeeManager - reverts nonStableMaster', async () => {
        await expectRevert(
          this.managerBTC.setFeeManager(this.feeManager.address, { from: user }),
          this.stableMasterError,
        );
      });
      it('addStrategy - reverts nonGovernor', async () => {
        await expectRevert(this.managerBTC.addStrategy(user, BASE, { from: user }), this.governorError);
      });
      it('report - reverts nonStrategy', async () => {
        await expectRevert(this.managerBTC.report(BASE, BASE, BASE, { from: user }), this.strategyError);
      });
      it('recoverERC20 - reverts nonGovernor', async () => {
        await expectRevert(
          this.managerBTC.recoverERC20(this.wBTC.address, user, BASE, { from: user }),
          this.governorError,
        );
      });
      it('updateStrategyDebtRatio - reverts nonGuardian', async () => {
        await expectRevert(this.managerBTC.updateStrategyDebtRatio(user, BASE, { from: user }), this.guardianError);
      });
      it('setStrategyEmergencyExit - reverts nonGuardian', async () => {
        await expectRevert(this.managerBTC.setStrategyEmergencyExit(user, { from: user }), this.guardianError);
      });
      it('revokeStrategy - reverts nonGuardian', async () => {
        await expectRevert(this.managerBTC.revokeStrategy(user, { from: user }), this.guardianError);
      });
      it('withdrawFromStrategy - reverts nonGuardian', async () => {
        await expectRevert(this.managerBTC.withdrawFromStrategy(user, BASE, { from: user }), this.guardianError);
      });
      it('setInterestsForSurplus - reverts nonGuardian', async () => {
        await expectRevert(this.managerBTC.setInterestsForSurplus(new BN('1'), { from: user }), this.guardianError);
      });
      it('setSurplusConverter - reverts nonGuardian', async () => {
        await expectRevert(this.managerBTC.setSurplusConverter(user, { from: user }), this.guardianError);
      });
    });

    describe('Mock Token', () => {
      describe('mint', () => {
        it('success - balance updated', async () => {
          expect(await this.wBTC.balanceOf(user)).to.be.bignumber.equal(new BN(1000).mul(BASE));
        });
      });
      describe('transfer', () => {
        before(async () => {
          await this.wBTC.transfer(minter, new BN(100).mul(BASE), { from: user });
        });
        it('success - minter balance updated', async () => {
          expect(await this.wBTC.balanceOf(minter)).to.be.bignumber.equal(new BN(100).mul(BASE));
        });

        it('success - contract balance updated', async () => {
          expect(await this.managerBTC.getBalance()).to.be.bignumber.equal(new BN(0));
        });
      });
    });

    describe('Governance Functions', () => {
      describe('setInterestsForSurplus', () => {
        it('reverts - too big amount', async () => {
          await expectRevert(
            this.managerBTC.setInterestsForSurplus(BASE_PARAMS.mul(new BN('2')), { from: governor }),
            '4',
          );
        });
        it('success - value updated', async () => {
          await this.managerBTC.setInterestsForSurplus(new BN('1'), { from: guardian });
          expect(await this.managerBTC.interestsForSurplus()).to.be.bignumber.equal(new BN('1'));
        });
        it('success - value reset', async () => {
          await this.managerBTC.setInterestsForSurplus(new BN('0'), { from: guardian });
          expect(await this.managerBTC.interestsForSurplus()).to.be.bignumber.equal(new BN('0'));
        });
      });
      describe('setSurplusConverter', () => {
        it('pushSurplus reverts - zero address', async () => {
          await expectRevert(this.managerBTC.pushSurplus(), '0');
        });
        it('success - role granted', async () => {
          await this.managerBTC.setSurplusConverter(guardian, { from: guardian });
          expect(await this.managerBTC.surplusConverter()).to.be.equal(guardian);
        });
        it('success - role revoked and granted', async () => {
          await this.managerBTC.setSurplusConverter(governor, { from: guardian });
          expect(await this.managerBTC.surplusConverter()).to.be.equal(governor);
        });
      });
    });
    describe('pushSurplus', () => {
      it('success - normal value', async () => {
        await this.managerBTC.pushSurplus();
      });
    });

    describe('recoverERC20 - underlying token', () => {
      it('reverts - too big amount', async () => {
        await expectRevert(
          this.managerBTC.recoverERC20(this.wBTC.address, user, MAX_UINT256, { from: governor }),
          '66',
        );
      });
      it('success - works fine', async () => {
        const balance = await this.managerBTC.getBalance();
        const receipt = await this.managerBTC.recoverERC20(this.wBTC.address, user, balance, { from: governor });

        expectEvent(receipt, 'Recovered', {
          token: this.wBTC.address,
          to: user,
          amount: balance,
        });
      });
      it('success - balance updated', async () => {
        expect(await this.managerBTC.getBalance()).to.be.bignumber.equal(new BN('0'));
      });
      it('reverts - too much withdrawn compared with user claims', async () => {
        await this.wBTC.mint(user, new BN(1000).mul(BASE));
        await this.wBTC.approve(this.stableMaster.address, new BN(1000).mul(BASE), { from: user });
        await this.stableMaster.mint(BASE, user, this.managerBTC.address, new BN('0'), { from: user });
        expect(await this.managerBTC.getBalance()).to.be.bignumber.equal(BASE);
        await expectRevert(
          this.managerBTC.recoverERC20(this.wBTC.address, user, BASE.sub(new BN('1')), { from: governor }),
          '66',
        );
      });
    });
    describe('recoverERC20 - other token', () => {
      it('success - mint', async () => {
        await this.DAI.mint(this.managerBTC.address, new BN('1000').mul(BASE));
        expect(await this.DAI.balanceOf(this.managerBTC.address)).to.be.bignumber.equal(new BN('1000').mul(BASE));
      });
      it('reverts - too big amount', async () => {
        await expectRevert.unspecified(
          this.managerBTC.recoverERC20(this.DAI.address, user, new BN('10000').mul(BASE), { from: governor }),
        );
      });
      it('success - recovered', async () => {
        await this.managerBTC.recoverERC20(this.DAI.address, user, new BN('1000').mul(BASE), { from: governor });
        expect(await this.DAI.balanceOf(user)).to.be.bignumber.equal(new BN('1000').mul(BASE));
      });
    });
    describe('addStrategy', () => {
      it('success', async () => {
        this.strategy = await MockStrategy.new(this.managerBTC.address, this.wBTC.address);
        await this.managerBTC.addStrategy(this.strategy.address, BASE_PARAMS.div(new BN('2')), { from: governor });
        this.strategy2 = await MockStrategy.new(this.managerBTC.address, this.wBTC.address);
        await this.managerBTC.addStrategy(this.strategy2.address, BASE_PARAMS.div(new BN('4')), { from: governor });
      });
    });
    describe('report', () => {
      it('reverts - incorrect freed amount', async () => {
        await expectRevert(this.strategy.report(BASE, 0, BASE), '72');
      });
      it('success - correct freed amount', async () => {
        await this.strategy.report(0, 0, 0);
        expect(await this.wBTC.balanceOf(this.strategy.address)).to.be.bignumber.equal(BASE.div(new BN('2')));
      });
      it('success - correct freed amount', async () => {
        await this.strategy2.report(0, 0, 0);
        expect(await this.wBTC.balanceOf(this.strategy2.address)).to.be.bignumber.equal(BASE.div(new BN('4')));
        expect(await this.wBTC.balanceOf(this.managerBTC.address)).to.be.bignumber.equal(BASE.div(new BN('4')));
      });
      it('success - with no collateral available', async () => {
        // There is BASE/4 left in the protocol: to bring the balance to 0, we should burn with 90% fees
        // BASE/4*10/9
        await this.stableMaster.burn(
          BASE.mul(new BN('100')).div(new BN('360')).add(new BN('1')),
          user,
          user,
          this.managerBTC.address,
          new BN('0'),
          { from: user },
        );
        expect(await this.wBTC.balanceOf(this.managerBTC.address)).to.be.bignumber.equal(new BN('0'));
        await this.strategy.report(0, BASE.div(new BN('3')), 0);
        expect(await this.wBTC.balanceOf(this.strategy.address)).to.be.bignumber.equal(BASE.div(new BN('2')));
      });
      it('creditAvailable - success', async () => {
        expect(await this.strategy2.creditAvailable()).to.be.bignumber.equal(new BN('0'));
      });

      it('withdrawFromStrategy with loss - success', async () => {
        const receipt = await this.managerBTC.withdrawFromStrategy(this.strategy.address, BASE.div(new BN('100')));
        expectEvent(receipt, 'StrategyReported', {
          loss: new BN('1'),
        });
      });
    });
    describe('report - with loss and lockedInterests taken to reimburse the loss', () => {
      it('success - loss smaller than lockedInterests', async () => {
        await this.wBTC.approve(this.stableMaster.address, new BN(100).mul(BASE), { from: user2 });
        await this.stableMaster.deposit(BASE.div(new BN(100)), user2, this.managerBTC.address, { from: user2 });
        await this.stableMaster.mint(new BN(BASE), user, this.managerBTC.address, new BN('0'), { from: user });
        await this.stableMaster.burn(
          BASE.mul(new BN('90')).div(new BN('100')),
          user,
          user,
          this.managerBTC.address,
          new BN('0'),
          { from: user },
        );
        let colData = await this.stableMaster.collateralMap(this.managerBTC.address);
        const lockedInterests = new BN(colData.slpData.lockedInterests);
        const prevSanRate = colData.sanRate;
        await this.strategy.report(0, lockedInterests.div(new BN(2)), 0);
        colData = await this.stableMaster.collateralMap(this.managerBTC.address);
        expect(colData.sanRate).to.be.bignumber.equal(prevSanRate);
      });
      it('success - loss larger than LockedInterests', async () => {
        await this.stableMaster.mint(new BN(BASE), user, this.managerBTC.address, new BN('0'), { from: user });
        await this.stableMaster.burn(
          BASE.mul(new BN('90')).div(new BN('100')),
          user,
          user,
          this.managerBTC.address,
          new BN('0'),
          { from: user },
        );
        let colData = await this.stableMaster.collateralMap(this.managerBTC.address);
        const lockedInterests = new BN(colData.slpData.lockedInterests);
        const prevSanRate = colData.sanRate;
        const sanMint = await this.sanBTC_EUR.totalSupply();
        const loss = lockedInterests.mul(new BN(2));
        await this.strategy.report(0, loss, 0);
        colData = await this.stableMaster.collateralMap(this.managerBTC.address);
        const newSanRate = prevSanRate.sub(loss.sub(lockedInterests).mul(BASE).div(sanMint));
        expect(colData.sanRate).to.be.bignumber.equal(newSanRate);
      });
      it('success - loss needs to pause', async () => {
        await this.stableMaster.mint(new BN(BASE), user, this.managerBTC.address, new BN('0'), { from: user });
        await this.stableMaster.burn(
          BASE.mul(new BN('90')).div(new BN('100')),
          user,
          user,
          this.managerBTC.address,
          new BN('0'),
          { from: user },
        );
        let colData = await this.stableMaster.collateralMap(this.managerBTC.address);
        const lockedInterests = new BN(colData.slpData.lockedInterests);
        const prevSanRate = colData.sanRate;
        const sanMint = await this.sanBTC_EUR.totalSupply();
        const loss = sanMint.mul(prevSanRate).div(BASE).add(lockedInterests);
        await this.strategy.report(0, loss, 0);
        colData = await this.stableMaster.collateralMap(this.managerBTC.address);
        expect(colData.sanRate).to.be.bignumber.equal(new BN(1));
        expect(colData.slpData.lockedInterests).to.be.bignumber.equal(new BN('0'));
        await expectRevert(
          this.stableMaster.deposit(new BN(BASE), user, this.managerBTC.address, { from: user }),
          '18',
        );
      });
    });
    describe('report - with non null interestsForSurplus', () => {
      it('init ', async () => {
        [this.core, this.ANGLE, this.stableMaster, this.agEUR] = await initAngle(governor, guardian);
        [this.wBTC, this.oracleBTC, this.managerBTC, this.sanBTC_EUR, this.perpetualManagerBTC, this.feeManager] =
          await initCollateral('wBTC', this.stableMaster, this.ANGLE, governor);
        this.strategy = await MockStrategy.new(this.managerBTC.address, this.wBTC.address);
        await this.managerBTC.addStrategy(this.strategy.address, BASE_PARAMS.div(new BN('2')), { from: governor });
        await this.wBTC.mint(this.managerBTC.address, BASE);
        await this.wBTC.mint(this.strategy.address, BASE);
        await this.wBTC.setAllowance(this.strategy.address, this.managerBTC.address);
        await this.managerBTC.setInterestsForSurplus(BASE_PARAMS.div(new BN('2')), { from: governor });
        await this.managerBTC.setSurplusConverter(guardian, { from: guardian });
        // Minting some sanTokens
        await this.wBTC.approve(this.stableMaster.address, BASE, { from: user });
        await this.wBTC.mint(user, BASE);
        await this.stableMaster.deposit(BASE, user, this.managerBTC.address, { from: user });
      });
      it('report - with a profit', async () => {
        // const colData = await this.stableMaster.collateralMap(this.managerBTC.address);
        await this.strategy.report(BASE_PARAMS, 0, 0);
        expect(await this.managerBTC.interestsAccumulated()).to.be.bignumber.equal(BASE_PARAMS.div(new BN('2')));
        await this.managerBTC.pushSurplus({ from: guardian });
        expect(await this.wBTC.balanceOf(guardian)).to.be.bignumber.equal(BASE_PARAMS.div(new BN('2')));
        expect(await this.managerBTC.interestsAccumulated()).to.be.bignumber.equal(new BN('0'));
      });
      it('report - with a loss smaller than interests accumulated', async () => {
        await this.strategy.report(BASE_PARAMS.div(new BN('2')), 0, 0);
        await this.strategy.report(0, BASE_PARAMS.div(new BN('4')), 0);
        expect(await this.managerBTC.interestsAccumulated()).to.be.bignumber.equal(BASE_PARAMS.div(new BN('8')));
        expect(await this.managerBTC.adminDebt()).to.be.bignumber.equal(new BN('0'));
      });
      it('report - with a loss bigger than interests accumulated', async () => {
        await this.strategy.report(0, BASE_PARAMS.div(new BN('2')), 0);
        // The loss is BASE_PARAMS / 2, and BASE_PARAMS / 8 have been taken up by accumulated interests
        // So the sanRate should decrease see a loss of 3/8 * BASE_PARAMS
        expect(await this.managerBTC.interestsAccumulated()).to.be.bignumber.equal(new BN('0'));
        expect(await this.managerBTC.adminDebt()).to.be.bignumber.equal(BASE_PARAMS.div(new BN('8')));
      });
      it('recoverERC20 - reverts - too big amount', async () => {
        await this.managerBTC.updateStrategyDebtRatio(this.strategy.address, 0, { from: guardian });
        let totalAssets = await this.managerBTC.getTotalAsset();
        let balance = await this.managerBTC.getBalance();
        // make the balance and total assets equal for simplicity reasons
        await this.strategy.report(0, totalAssets.sub(balance), 0);
        totalAssets = await this.managerBTC.getTotalAsset();
        balance = await this.managerBTC.getBalance();
        // faking some increase gain on pool manager
        await this.wBTC.mint(this.managerBTC.address, BASE);
        totalAssets = await this.managerBTC.getTotalAsset();
        balance = await this.managerBTC.getBalance();
        const collatData = await this.stableMaster.collateralMap(this.managerBTC.address);
        const sanTokenSupply = await this.sanBTC_EUR.totalSupply();
        const interestsAccumulated = await this.managerBTC.interestsAccumulated();
        const stocksUsers = collatData.stocksUsers;
        const oracleRate = await this.oracleBTC.readUpper();
        const maxAmount = sanTokenSupply
          .mul(collatData.sanRate)
          .div(BASE)
          .add(stocksUsers.mul(collatData.collatBase).div(oracleRate))
          .add(interestsAccumulated);

        const tooMuch = balance.sub(maxAmount).add(BASE);
        await expectRevert(this.managerBTC.recoverERC20(this.wBTC.address, user, tooMuch, { from: governor }), '66');
      });
      it('recoverERC20 - success - works fine', async () => {
        const collatData = await this.stableMaster.collateralMap(this.managerBTC.address);
        const sanTokenSupply = await this.sanBTC_EUR.totalSupply();
        const interestsAccumulated = await this.managerBTC.interestsAccumulated();
        const stocksUsers = collatData.stocksUsers;
        const oracleRate = await this.oracleBTC.readUpper();
        const maxAmount = sanTokenSupply
          .mul(collatData.sanRate)
          .div(BASE)
          .add(stocksUsers.mul(collatData.collatBase).div(oracleRate))
          .add(interestsAccumulated);
        const balance = await this.managerBTC.getBalance();
        const perfectAmount = balance.sub(maxAmount);
        const receipt = await this.managerBTC.recoverERC20(this.wBTC.address, user, perfectAmount, {
          from: governor,
        });

        expectEvent(receipt, 'Recovered', {
          token: this.wBTC.address,
          to: user,
          amount: perfectAmount,
        });
      });
    });
    describe('report - with debtAdmin non null', () => {
      it('init ', async () => {
        [this.core, this.ANGLE, this.stableMaster, this.agEUR] = await initAngle(governor, guardian);
        [this.wBTC, this.oracleBTC, this.managerBTC, this.sanBTC_EUR, this.perpetualManagerBTC, this.feeManager] =
          await initCollateral('wBTC', this.stableMaster, this.ANGLE, governor);
        this.strategy = await MockStrategy.new(this.managerBTC.address, this.wBTC.address);
        await this.managerBTC.addStrategy(this.strategy.address, BASE_PARAMS.div(new BN('2')), { from: governor });
        await this.wBTC.mint(this.managerBTC.address, BASE);
        await this.wBTC.mint(this.strategy.address, BASE);
        await this.wBTC.setAllowance(this.strategy.address, this.managerBTC.address);
        await this.managerBTC.setInterestsForSurplus(BASE_PARAMS.div(new BN('2')), { from: governor });
        await this.managerBTC.setSurplusConverter(guardian, { from: guardian });
        // Minting some sanTokens
        await this.wBTC.approve(this.stableMaster.address, BASE, { from: user });
        await this.wBTC.mint(user, BASE);
        await this.stableMaster.deposit(BASE, user, this.managerBTC.address, { from: user });
        await this.strategy.report(BASE, 0, 0);
        await this.managerBTC.pushSurplus({ from: guardian });
      });
      it('report - with a loss', async () => {
        // const colData = await this.stableMaster.collateralMap(this.managerBTC.address);
        await this.strategy.report(0, BASE_PARAMS, 0);
        expect(await this.managerBTC.interestsAccumulated()).to.be.bignumber.equal(new BN('0'));
        expect(await this.managerBTC.adminDebt()).to.be.bignumber.equal(BASE_PARAMS.div(new BN('2')));
      });
      it('report - with a gain larger than the adminDebt', async () => {
        await this.strategy.report(BASE_PARAMS.mul(new BN('2')), 0, 0);
        expect(await this.managerBTC.interestsAccumulated()).to.be.bignumber.equal(BASE_PARAMS.div(new BN('2')));
        expect(await this.managerBTC.adminDebt()).to.be.bignumber.equal(new BN('0'));
      });
      it('report - with a gain smaller than the adminDebt', async () => {
        await this.strategy.report(0, BASE_PARAMS.mul(new BN('2')), 0);
        expect(await this.managerBTC.interestsAccumulated()).to.be.bignumber.equal(new BN('0'));
        expect(await this.managerBTC.adminDebt()).to.be.bignumber.equal(BASE_PARAMS.div(new BN('2')));
        await this.strategy.report(BASE_PARAMS.div(new BN('2')), 0, 0);
        expect(await this.managerBTC.interestsAccumulated()).to.be.bignumber.equal(new BN('0'));
        expect(await this.managerBTC.adminDebt()).to.be.bignumber.equal(BASE_PARAMS.div(new BN('4')));
      });
    });
  });
});
