import { SignerWithAddress } from '@nomiclabs/hardhat-ethers/signers';
import { ethers, network } from 'hardhat';
import { utils, constants, BigNumber, Contract } from 'ethers';
import { expect } from '../test-utils/chai-setup';
import { deploy, impersonate } from '../test-utils';
import axios from 'axios';
import qs from 'qs';
import {
  AaveFlashloanStrategy,
  FlashMintLib,
  ERC20,
  ERC20__factory,
  // IAaveIncentivesController__factory,
  IStakedAave,
  IStakedAave__factory,
  AaveFlashloanStrategy__factory,
  PoolManager,
  IProtocolDataProvider,
  // IAaveIncentivesController,
  ILendingPool,
  IProtocolDataProvider__factory,
  ILendingPool__factory,
} from '../../typechain';
import { parseUnits } from 'ethers/lib/utils';

describe('AaveFlashloan Strategy1', () => {
  // ATokens
  let aToken: ERC20, debtToken: ERC20;

  // Tokens
  let wantToken: ERC20, dai: ERC20, aave: ERC20, stkAave: IStakedAave;

  // Guardians
  let deployer: SignerWithAddress,
    proxyAdmin: SignerWithAddress,
    governor: SignerWithAddress,
    guardian: SignerWithAddress,
    user: SignerWithAddress,
    keeper: SignerWithAddress;

  let poolManager: PoolManager;
  let protocolDataProvider: IProtocolDataProvider;
  // let incentivesController: IAaveIncentivesController;
  let lendingPool: ILendingPool;
  let flashMintLib: FlashMintLib;

  let strategy: AaveFlashloanStrategy;

  // ReserveInterestRateStrategy for USDC
  const reserveInterestRateStrategyUSDC = '0x8Cae0596bC1eD42dc3F04c4506cfe442b3E74e27';
  // ReserveInterestRateStrategy for DAI
  // const reserveInterestRateStrategyDAI = '0xfffE32106A68aA3eD39CcCE673B646423EEaB62a';

  beforeEach(async () => {
    await network.provider.request({
      method: 'hardhat_reset',
      params: [
        {
          forking: {
            jsonRpcUrl: process.env.ETH_NODE_URI_FORK,
            blockNumber: 14519530,
          },
        },
      ],
    });

    wantToken = (await ethers.getContractAt(ERC20__factory.abi, '0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48')) as ERC20;
    dai = (await ethers.getContractAt(ERC20__factory.abi, '0x6B175474E89094C44Da98b954EedeAC495271d0F')) as ERC20;
    aave = (await ethers.getContractAt(ERC20__factory.abi, '0x7Fc66500c84A76Ad7e9c93437bFc5Ac33E2DDaE9')) as ERC20;
    stkAave = (await ethers.getContractAt(
      IStakedAave__factory.abi,
      '0x4da27a545c0c5B758a6BA100e3a049001de870f5',
    )) as IStakedAave;

    [deployer, proxyAdmin, governor, guardian, user, keeper] = await ethers.getSigners();

    poolManager = (await deploy('MockPoolManager', [wantToken.address, 0])) as PoolManager;

    protocolDataProvider = (await ethers.getContractAt(
      IProtocolDataProvider__factory.abi,
      '0x057835Ad21a177dbdd3090bB1CAE03EaCF78Fc6d',
    )) as IProtocolDataProvider;

    /*
    incentivesController = (await ethers.getContractAt(
      IAaveIncentivesController__factory.abi,
      '0xd784927Ff2f95ba542BfC824c8a8a98F3495f6b5',
    )) as IAaveIncentivesController;
    */

    lendingPool = (await ethers.getContractAt(
      ILendingPool__factory.abi,
      '0x7d2768dE32b0b80b7a3454c06BdAc94A69DDc7A9',
    )) as ILendingPool;

    flashMintLib = (await deploy('FlashMintLib')) as FlashMintLib;

    const strategyImplementation = (await deploy('AaveFlashloanStrategy', [], {
      libraries: { FlashMintLib: flashMintLib.address },
    })) as AaveFlashloanStrategy;

    const proxy = await deploy('TransparentUpgradeableProxy', [
      strategyImplementation.address,
      proxyAdmin.address,
      '0x',
    ]);
    strategy = new Contract(proxy.address, AaveFlashloanStrategy__factory.abi, deployer) as AaveFlashloanStrategy;

    await strategy.initialize(
      poolManager.address,
      reserveInterestRateStrategyUSDC,
      governor.address,
      guardian.address,
      [keeper.address],
    );

    aToken = (await ethers.getContractAt(ERC20__factory.abi, '0xBcca60bB61934080951369a648Fb03DF4F96263C')) as ERC20;
    debtToken = (await ethers.getContractAt(ERC20__factory.abi, '0x619beb58998eD2278e08620f97007e1116D5D25b')) as ERC20;
  });

  describe('Constructor', () => {
    it('initialize', async () => {
      expect(
        strategy.initialize(poolManager.address, reserveInterestRateStrategyUSDC, governor.address, guardian.address, [
          keeper.address,
        ]),
      ).to.revertedWith('Initializable: contract is already initialized');

      expect(strategy.connect(proxyAdmin).boolParams()).to.revertedWith(
        'TransparentUpgradeableProxy: admin cannot fallback to proxy target',
      );
      const isActive1 = (await strategy.connect(deployer).boolParams()).isFlashMintActive;
      const isActive2 = (await strategy.connect(user).boolParams()).isFlashMintActive;
      await expect(isActive1).to.be.true;
      expect(isActive1).to.equal(isActive2);
    });

    it('approvals1', async () => {
      const token = await poolManager.token();
      const want = await strategy.want();
      expect(want).to.equal(token);
      const wantContract = (await ethers.getContractAt(ERC20__factory.abi, want)) as ERC20;
      const allowance1 = await wantContract.allowance(strategy.address, lendingPool.address);
      expect(allowance1).to.equal(constants.MaxUint256);

      const allowance2 = await aToken.allowance(strategy.address, lendingPool.address);
      expect(allowance2).to.equal(constants.MaxUint256);

      // PoolManager
      expect(await wantContract.allowance(strategy.address, poolManager.address)).to.equal(constants.MaxUint256);
    });
    it('approvals2', async () => {
      const allowanceDai1 = await dai.allowance(strategy.address, lendingPool.address);
      const allowanceDai2 = await dai.allowance(strategy.address, await flashMintLib.LENDER());
      expect(allowanceDai1).to.equal(constants.MaxUint256);
      expect(allowanceDai2).to.equal(constants.MaxUint256);

      const allowanceAave = await aave.allowance(strategy.address, '0x1111111254fb6c44bAC0beD2854e76F90643097d');
      expect(allowanceAave).to.equal(constants.MaxUint256);

      const allowanceStkAave = await stkAave.allowance(strategy.address, '0x1111111254fb6c44bAC0beD2854e76F90643097d');
      expect(allowanceStkAave).to.equal(constants.MaxUint256);
    });

    it('roles', async () => {
      const GUARDIAN_ROLE = await strategy.GUARDIAN_ROLE();
      const POOLMANAGER_ROLE = await strategy.POOLMANAGER_ROLE();
      await expect(await strategy.hasRole(GUARDIAN_ROLE, guardian.address)).to.be.true;
      await expect(await strategy.hasRole(GUARDIAN_ROLE, governor.address)).to.be.true;
      await expect(await strategy.hasRole(GUARDIAN_ROLE, strategy.address)).to.be.false;
      await expect(await strategy.hasRole(GUARDIAN_ROLE, poolManager.address)).to.be.false;
      await expect(await strategy.hasRole(POOLMANAGER_ROLE, poolManager.address)).to.be.true;
    });

    it('params', async () => {
      expect(await strategy.maxIterations()).to.equal(6);
      await expect((await strategy.boolParams()).isFlashMintActive).to.be.true;
      expect(await strategy.discountFactor()).to.equal(9000);
      expect(await strategy.minWant()).to.equal(100);
      expect(await strategy.minRatio()).to.equal(utils.parseEther('0.005'));
      await expect((await strategy.boolParams()).automaticallyComputeCollatRatio).to.be.true;
      await expect((await strategy.boolParams()).withdrawCheck).to.be.false;
      await expect((await strategy.boolParams()).cooldownStkAave).to.be.true;
    });

    it('collat ratios', async () => {
      const { ltv, liquidationThreshold } = await protocolDataProvider.getReserveConfigurationData(wantToken.address);
      const _DEFAULT_COLLAT_TARGET_MARGIN = utils.parseUnits('0.02', 4);
      const _DEFAULT_COLLAT_MAX_MARGIN = utils.parseUnits('0.005', 4);

      expect(await strategy.maxBorrowCollatRatio()).to.equal(ltv.sub(_DEFAULT_COLLAT_MAX_MARGIN).mul(1e14));
      expect(await strategy.targetCollatRatio()).to.equal(
        liquidationThreshold.sub(_DEFAULT_COLLAT_TARGET_MARGIN).mul(1e14),
      );
      expect(await strategy.maxCollatRatio()).to.equal(liquidationThreshold.sub(_DEFAULT_COLLAT_MAX_MARGIN).mul(1e14));
    });
  });

  describe('setters', () => {
    it('setCollateralTargets', async () => {
      expect(
        strategy
          .connect(user)
          .setCollateralTargets(
            utils.parseUnits('0.8', 18),
            utils.parseUnits('0.7', 18),
            utils.parseUnits('0.6', 18),
            utils.parseUnits('0.8', 18),
          ),
      ).to.be.revertedWith(`AccessControl: account ${user.address.toLowerCase()} is missing role`);

      await expect(
        strategy
          .connect(guardian)
          .setCollateralTargets(
            utils.parseUnits('0.75', 18),
            utils.parseUnits('0.8', 18),
            utils.parseUnits('0.6', 18),
            utils.parseUnits('0.8', 18),
          ),
      ).to.be.reverted;

      await strategy
        .connect(guardian)
        .setCollateralTargets(
          utils.parseUnits('0.75', 18),
          utils.parseUnits('0.8', 18),
          utils.parseUnits('0.6', 18),
          utils.parseUnits('0.7', 18),
        );

      expect(await strategy.targetCollatRatio()).to.equal(utils.parseUnits('0.75', 18));
      expect(await strategy.maxCollatRatio()).to.equal(utils.parseUnits('0.8', 18));
      expect(await strategy.maxBorrowCollatRatio()).to.equal(utils.parseUnits('0.6', 18));
      expect(await strategy.daiBorrowCollatRatio()).to.equal(utils.parseUnits('0.7', 18));
    });

    it('setBoolParams', async () => {
      await expect((await strategy.boolParams()).isFlashMintActive).to.be.true;
      await expect((await strategy.boolParams()).automaticallyComputeCollatRatio).to.be.true;
      await expect((await strategy.boolParams()).withdrawCheck).to.be.false;
      await expect((await strategy.boolParams()).cooldownStkAave).to.be.true;

      expect(
        strategy.connect(user).setBoolParams({
          isFlashMintActive: false,
          automaticallyComputeCollatRatio: false,
          withdrawCheck: false,
          cooldownStkAave: false,
        }),
      ).to.be.revertedWith(`AccessControl: account ${user.address.toLowerCase()} is missing role`);

      await strategy.connect(guardian).setBoolParams({
        isFlashMintActive: false,
        automaticallyComputeCollatRatio: false,
        withdrawCheck: false,
        cooldownStkAave: false,
      });

      await expect((await strategy.boolParams()).isFlashMintActive).to.be.false;
      await expect((await strategy.boolParams()).automaticallyComputeCollatRatio).to.be.false;
      await expect((await strategy.boolParams()).withdrawCheck).to.be.false;
      await expect((await strategy.boolParams()).cooldownStkAave).to.be.false;
    });

    it('setMinsAndMaxs - revert', async () => {
      await expect(strategy.connect(user).setMinsAndMaxs(1000, utils.parseUnits('0.7', 18), 20)).to.be.revertedWith(
        '8',
      );
    });

    it('setMinsAndMaxs', async () => {
      expect(strategy.connect(user).setMinsAndMaxs(1000, utils.parseUnits('0.7', 18), 20)).to.be.revertedWith(
        `AccessControl: account ${user.address.toLowerCase()} is missing role`,
      );

      expect(await strategy.minWant()).to.equal(100);
      expect(await strategy.minRatio()).to.equal(utils.parseUnits('0.005', 18));
      expect(await strategy.maxIterations()).to.equal(6);

      await strategy.connect(guardian).setMinsAndMaxs(1000, utils.parseUnits('0.6', 18), 15);

      expect(await strategy.minWant()).to.equal(1000);
      expect(await strategy.minRatio()).to.equal(utils.parseUnits('0.6', 18));
      expect(await strategy.maxIterations()).to.equal(15);
    });

    it('setAavePoolVariables', async () => {
      await strategy.setAavePoolVariables();
    });

    it('setDiscountFactor', async () => {
      expect(await strategy.discountFactor()).to.equal(9000);
      expect(strategy.setDiscountFactor(12000)).to.revertedWith(
        `AccessControl: account ${deployer.address.toLowerCase()} is missing role ${await strategy.GUARDIAN_ROLE()}`,
      );
      expect(strategy.connect(guardian).setDiscountFactor(12000)).to.revertedWith('4');
      await strategy.connect(guardian).setDiscountFactor(2000);
      expect(await strategy.discountFactor()).to.equal(2000);
    });

    it('addGuardian', async () => {
      expect(strategy.addGuardian(user.address)).to.be.revertedWith(
        `AccessControl: account ${deployer.address.toLowerCase()} is missing role ${await strategy.POOLMANAGER_ROLE()}`,
      );
      await expect(await strategy.hasRole(await strategy.GUARDIAN_ROLE(), user.address)).to.be.false;
      await impersonate(poolManager.address, async acc => {
        await network.provider.send('hardhat_setBalance', [
          poolManager.address,
          utils.parseEther('1').toHexString().replace('0x0', '0x'),
        ]);
        await strategy.connect(acc).addGuardian(user.address);
      });
      await expect(await strategy.hasRole(await strategy.GUARDIAN_ROLE(), user.address)).to.be.true;
    });

    it('revokeGuardian', async () => {
      expect(strategy.revokeGuardian(user.address)).to.be.revertedWith(
        `AccessControl: account ${deployer.address.toLowerCase()} is missing role ${await strategy.POOLMANAGER_ROLE()}`,
      );
      await expect(await strategy.hasRole(await strategy.GUARDIAN_ROLE(), guardian.address)).to.be.true;
      await impersonate(poolManager.address, async acc => {
        await network.provider.send('hardhat_setBalance', [
          poolManager.address,
          utils.parseEther('1').toHexString().replace('0x0', '0x'),
        ]);
        await strategy.connect(acc).revokeGuardian(guardian.address);
      });
      await expect(await strategy.hasRole(await strategy.GUARDIAN_ROLE(), guardian.address)).to.be.false;
    });
  });

  describe('Strategy', () => {
    const _startAmountUSDC = utils.parseUnits((2_000_000).toString(), 6);
    let _guessedBorrowed = utils.parseUnits((0).toString(), 6);

    beforeEach(async () => {
      await (await poolManager.addStrategy(strategy.address, utils.parseUnits('0.75', 9))).wait();

      await impersonate('0x6262998Ced04146fA42253a5C0AF90CA02dfd2A3', async acc => {
        await wantToken.connect(acc).transfer(user.address, _startAmountUSDC);
      });
      // console.log('balance', utils.formatUnits(await wantToken.balanceOf(user.address), 6));

      await wantToken.connect(user).transfer(poolManager.address, _startAmountUSDC);
      // await wantToken.connect(user).transfer(strategy.address, _startAmountUSDC);
    });

    it('estimatedTotalAssets', async () => {
      expect(await strategy.estimatedTotalAssets()).to.equal(0);
      await strategy['harvest()']({ gasLimit: 3e6 });

      const { deposits, borrows } = await strategy.getCurrentPosition();
      _guessedBorrowed = borrows;
      const totalAssets = (await wantToken.balanceOf(strategy.address)).add(deposits).sub(borrows);
      const debtRatio = (await poolManager.strategies(strategy.address)).debtRatio;

      expect(debtRatio).to.equal(utils.parseUnits('0.75', 9));
      expect(totalAssets).to.be.closeTo(_startAmountUSDC.mul(debtRatio).div(utils.parseUnits('1', 9)), 10);
      expect(await strategy.estimatedTotalAssets()).to.equal(totalAssets);
    });

    it('estimatedTotalAssets - check harvest with guessedBorrows', async () => {
      expect(await strategy.estimatedTotalAssets()).to.equal(0);
      await strategy.connect(keeper)['harvest(uint256)'](_guessedBorrowed, { gasLimit: 3e6 });

      const { deposits, borrows } = await strategy.getCurrentPosition();
      expect(borrows).to.equal(_guessedBorrowed);
      const totalAssets = (await wantToken.balanceOf(strategy.address)).add(deposits).sub(borrows);
      const debtRatio = (await poolManager.strategies(strategy.address)).debtRatio;

      expect(debtRatio).to.equal(utils.parseUnits('0.75', 9));
      expect(totalAssets).to.be.closeTo(_startAmountUSDC.mul(debtRatio).div(utils.parseUnits('1', 9)), 10);
      expect(await strategy.estimatedTotalAssets()).to.equal(totalAssets);
    });

    it('estimatedTotalAssets - balanceExcludingRewards < minWant', async () => {
      await impersonate(strategy.address, async acc => {
        await network.provider.send('hardhat_setBalance', [
          strategy.address,
          utils.parseEther('1').toHexString().replace('0x0', '0x'),
        ]);

        const balance = await wantToken.balanceOf(acc.address);
        await wantToken.connect(acc).transfer(user.address, balance);
      });

      expect(await strategy.estimatedTotalAssets()).to.equal(0);
    });

    it('sellRewards', async () => {
      expect(await stkAave.balanceOf(strategy.address)).to.equal(0);
      expect(await aave.balanceOf(strategy.address)).to.equal(0);

      await network.provider.send('evm_increaseTime', [3600 * 24 * 1]); // forward 1 day
      await network.provider.send('evm_mine');

      expect(await stkAave.stakersCooldowns(strategy.address)).to.equal(0);
      expect(await wantToken.balanceOf(strategy.address)).to.equal(0);

      await strategy.connect(keeper).claimRewards();
      expect(strategy.connect(guardian).sellRewards(0, '0x')).to.be.revertedWith(
        `AccessControl: account ${guardian.address.toLowerCase()} is missing role ${await strategy.KEEPER_ROLE()}`,
      );

      await strategy['harvest()']({ gasLimit: 3e6 });
      await network.provider.send('evm_increaseTime', [3600 * 24 * 1]); // forward 1 day
      await network.provider.send('evm_mine');
      await strategy['harvest()']({ gasLimit: 3e6 });

      // expect(parseFloat(utils.formatUnits(await stkAave.balanceOf(strategy.address)))).to.be.closeTo(1.8, 0.1);

      // const payloadRevert = (
      //   await axios.get(
      //     `https://api.1inch.exchange/v4.0/1/swap?${qs.stringify({
      //       fromTokenAddress: stkAave.address,
      //       toTokenAddress: wantToken.address,
      //       fromAddress: strategy.address,
      //       amount: (await stkAave.balanceOf(strategy.address)).mul(10).toString(),
      //       slippage: 50,
      //       disableEstimate: true,
      //     })}`,
      //   )
      // ).data.tx.data;
      // await strategy.connect(keeper).sellRewards(0, payloadRevert, true);

      await strategy.connect(keeper).claimRewards();
      await expect(strategy.connect(keeper).sellRewards(0, '0x')).to.be.reverted;

      const chainId = 1;
      const oneInchParams = qs.stringify({
        fromTokenAddress: stkAave.address,
        toTokenAddress: wantToken.address,
        fromAddress: strategy.address,
        amount: parseUnits('1.79', 18).toString(),
        slippage: 50,
        disableEstimate: true,
      });
      const url = `https://api.1inch.exchange/v4.0/${chainId}/swap?${oneInchParams}`;

      const res = await axios.get(url);
      const payload = res.data.tx.data;

      const usdcBefore = await wantToken.balanceOf(strategy.address);

      await strategy.connect(keeper).claimRewards();
      await strategy.connect(keeper).sellRewards(0, payload);

      const usdcAfter = parseFloat(utils.formatUnits(await wantToken.balanceOf(strategy.address), 6));
      const stkAaveAfter = parseFloat(utils.formatUnits(await stkAave.balanceOf(strategy.address)));

      expect(usdcBefore).to.equal(0);
      expect(stkAaveAfter).to.be.closeTo(0, 0.1);
      expect(usdcAfter).to.be.closeTo(210, 5);
    });

    it('_prepareReturn', async () => {
      const balance = (await wantToken.balanceOf(strategy.address))
        .add(await wantToken.balanceOf(poolManager.address))
        .mul((await poolManager.strategies(strategy.address)).debtRatio)
        .div(BigNumber.from(1e9));

      await strategy['harvest()']({ gasLimit: 3e6 });

      const targetCollatRatio = await strategy.targetCollatRatio();
      const expectedBorrows = balance.mul(targetCollatRatio).div(utils.parseEther('1').sub(targetCollatRatio));
      const expectedDeposits = expectedBorrows.mul(utils.parseEther('1')).div(targetCollatRatio);

      const deposits = await aToken.balanceOf(strategy.address);
      const borrows = await debtToken.balanceOf(strategy.address);

      expect(deposits).to.be.closeTo(expectedDeposits, 5);
      expect(borrows).to.be.closeTo(expectedBorrows, 5);
    });

    it('_prepareReturn 2', async () => {
      await strategy['harvest()']({ gasLimit: 3e6 });
      const debtRatio = (await poolManager.strategies(strategy.address)).debtRatio;
      expect(await strategy.estimatedTotalAssets()).to.be.closeTo(
        _startAmountUSDC.mul(debtRatio).div(utils.parseUnits('1', 9)),
        10,
      );

      const newDebtRatio = utils.parseUnits('0.5', 9);
      await poolManager.updateStrategyDebtRatio(strategy.address, newDebtRatio);
      await strategy['harvest()']({ gasLimit: 3e6 });
      expect(await strategy.estimatedTotalAssets()).to.be.closeTo(
        _startAmountUSDC.mul(newDebtRatio).div(utils.parseUnits('1', 9)),
        50000,
      );
    });

    it('_prepareReturn 3', async () => {
      await strategy['harvest()']({ gasLimit: 3e6 });

      // fake profit for strategy
      await impersonate('0x6262998Ced04146fA42253a5C0AF90CA02dfd2A3', async acc => {
        await wantToken.connect(acc).transfer(strategy.address, _startAmountUSDC);
      });

      await strategy['harvest()']({ gasLimit: 3e6 });

      const balance = (await poolManager.strategies(strategy.address)).totalStrategyDebt;

      const targetCollatRatio = await strategy.targetCollatRatio();
      const expectedBorrows = balance.mul(targetCollatRatio).div(utils.parseEther('1').sub(targetCollatRatio));
      const expectedDeposits = expectedBorrows.mul(utils.parseEther('1')).div(targetCollatRatio);

      const deposits = await aToken.balanceOf(strategy.address);
      const borrows = await debtToken.balanceOf(strategy.address);

      expect(deposits).to.be.closeTo(expectedDeposits, 10);
      expect(borrows).to.be.closeTo(expectedBorrows, 10);
    });

    it('manualDeleverage', async () => {
      const _amount = 10_000;
      const amount = utils.parseUnits(_amount.toString(), 6);
      await strategy.connect(guardian).manualDeleverage(0);

      await strategy['harvest()']({ gasLimit: 3e6 });

      const aBefore = await aToken.balanceOf(strategy.address);
      const debtBefore = await debtToken.balanceOf(strategy.address);

      expect(await wantToken.balanceOf(strategy.address)).to.equal(0);
      await strategy.connect(guardian).manualDeleverage(amount);

      expect(await wantToken.balanceOf(strategy.address)).to.equal(0);
      expect(_amount).to.be.closeTo(aBefore.sub(await aToken.balanceOf(strategy.address)).div(1e6), 2);
      expect(_amount).to.be.closeTo(debtBefore.sub(await debtToken.balanceOf(strategy.address)).div(1e6), 2);
    });

    it('manualReleaseWant', async () => {
      await strategy['harvest()']({ gasLimit: 3e6 });
      await strategy.connect(guardian).manualReleaseWant(0);

      const _amount = 10_000;
      const amount = utils.parseUnits(_amount.toString(), 6);

      const aBefore = await aToken.balanceOf(strategy.address);
      const debtBefore = await debtToken.balanceOf(strategy.address);
      expect(await wantToken.balanceOf(strategy.address)).to.equal(0);

      await strategy.connect(guardian).manualReleaseWant(amount);

      expect(await wantToken.balanceOf(strategy.address)).to.equal(amount);
      expect(_amount).to.be.closeTo(aBefore.sub(await aToken.balanceOf(strategy.address)).div(1e6), 2);
      expect((await debtToken.balanceOf(strategy.address)).div(1e6)).to.equal(debtBefore.div(1e6));
    });

    it('_adjustPosition - _leverDownTo', async () => {
      await strategy['harvest()']({ gasLimit: 3e6 });

      await strategy.connect(guardian).setBoolParams({
        isFlashMintActive: (await strategy.boolParams()).isFlashMintActive,
        automaticallyComputeCollatRatio: false,
        withdrawCheck: (await strategy.boolParams()).withdrawCheck,
        cooldownStkAave: (await strategy.boolParams()).cooldownStkAave,
      });
      const newCollatRatio = utils.parseUnits('0.7', 18);
      await strategy
        .connect(guardian)
        .setCollateralTargets(
          newCollatRatio,
          await strategy.maxCollatRatio(),
          await strategy.maxBorrowCollatRatio(),
          await strategy.daiBorrowCollatRatio(),
        );

      expect(await strategy.targetCollatRatio()).to.equal(newCollatRatio);

      await strategy['harvest()']({ gasLimit: 3e6 });

      const borrow = (await poolManager.strategies(strategy.address)).totalStrategyDebt
        .mul(newCollatRatio)
        .div(utils.parseEther('1').sub(newCollatRatio));

      expect(borrow).to.be.closeTo(await debtToken.balanceOf(strategy.address), 5);
      expect(await aToken.balanceOf(strategy.address)).to.be.closeTo(
        borrow.mul(utils.parseEther('1')).div(newCollatRatio),
        5,
      );
      expect(0).to.be.closeTo(await wantToken.balanceOf(strategy.address), 5);
    });

    it('_leverMax - isFlashMintActive', async () => {
      await strategy.connect(guardian).setBoolParams({
        isFlashMintActive: false,
        automaticallyComputeCollatRatio: (await strategy.boolParams()).automaticallyComputeCollatRatio,
        withdrawCheck: (await strategy.boolParams()).withdrawCheck,
        cooldownStkAave: (await strategy.boolParams()).cooldownStkAave,
      });
      await strategy['harvest()']({ gasLimit: 3e6 });

      const targetCollatRatioBefore = await strategy.targetCollatRatio();
      const aTokenBefore = await aToken.balanceOf(strategy.address);
      const debtTokenBefore = await debtToken.balanceOf(strategy.address);

      await strategy.connect(guardian).setBoolParams({
        isFlashMintActive: true,
        automaticallyComputeCollatRatio: (await strategy.boolParams()).automaticallyComputeCollatRatio,
        withdrawCheck: (await strategy.boolParams()).withdrawCheck,
        cooldownStkAave: (await strategy.boolParams()).cooldownStkAave,
      });
      await strategy['harvest()']({ gasLimit: 3e6 });

      expect(targetCollatRatioBefore).to.equal(await strategy.targetCollatRatio());
      expect(aTokenBefore).to.be.lte(await aToken.balanceOf(strategy.address));
      expect(debtTokenBefore).to.be.lte(await debtToken.balanceOf(strategy.address));
      expect(await wantToken.balanceOf(strategy.address)).to.equal(0);
    });

    it('_leverDownTo - isFlashMintActive false', async () => {
      await strategy.connect(guardian).setBoolParams({
        isFlashMintActive: false,
        automaticallyComputeCollatRatio: false,
        withdrawCheck: (await strategy.boolParams()).withdrawCheck,
        cooldownStkAave: (await strategy.boolParams()).cooldownStkAave,
      });

      await strategy['harvest()']({ gasLimit: 3e6 });
      const newCollatRatio = utils.parseUnits('0.7', 18);
      await strategy
        .connect(guardian)
        .setCollateralTargets(
          newCollatRatio,
          await strategy.maxCollatRatio(),
          await strategy.maxBorrowCollatRatio(),
          await strategy.daiBorrowCollatRatio(),
        );
      await strategy['harvest()']({ gasLimit: 3e6 });

      expect(await strategy.targetCollatRatio()).to.equal(newCollatRatio);

      expect((await aToken.balanceOf(strategy.address)).mul(newCollatRatio).div(utils.parseEther('1'))).to.be.closeTo(
        await debtToken.balanceOf(strategy.address),
        5,
      );
      expect(96).to.be.closeTo(await wantToken.balanceOf(strategy.address), 5);
    });

    it('emergencyExit', async () => {
      await impersonate(poolManager.address, async acc => {
        await network.provider.send('hardhat_setBalance', [
          poolManager.address,
          utils.parseEther('1').toHexString().replace('0x0', '0x'),
        ]);
        await strategy.connect(acc).setEmergencyExit();
      });

      expect(await strategy.estimatedTotalAssets()).to.equal(0);
      await strategy['harvest()']({ gasLimit: 3e6 });
      expect(await strategy.estimatedTotalAssets()).to.be.closeTo(utils.parseUnits('1500000', 6), 10);
    });

    // it.only('flashloan more than maxLiquidity', async () => {
    //   const balanceStorage = utils.solidityKeccak256(['uint256', 'uint256'], [strategy.address, 9]);

    //   await network.provider.send('hardhat_setStorageAt', [
    //     '0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48',
    //     balanceStorage.replace('0x0', '0x'),
    //     utils.hexZeroPad(utils.parseUnits('900000000', 6).toHexString(), 32),
    //   ]);

    //   await impersonate('0x6262998Ced04146fA42253a5C0AF90CA02dfd2A3', async acc => {
    //     await wantToken.connect(acc).approve(lendingPool.address, constants.MaxUint256);
    //     await aToken.connect(acc).approve(lendingPool.address, constants.MaxUint256);
    //     // await lendingPool.connect(acc).deposit(wantToken.address, utils.parseUnits('120000000', 6), acc.address, 0);
    //   });
    //   await poolManager.updateStrategyDebtRatio(strategy.address, utils.parseUnits('1', 9));

    //   await strategy['harvest()']({ gasLimit: 3e6 });

    //   // // expect(parseFloat(utils.formatUnits(await strategy.estimatedTotalAssets(), 6))).to.be.closeTo(301_500_000, 100);

    //   await impersonate('0x6262998Ced04146fA42253a5C0AF90CA02dfd2A3', async acc => {
    //     await lendingPool.connect(acc).deposit(wantToken.address, utils.parseUnits('200000000', 6), acc.address, 0);
    //   });

    //   await strategy['harvest()']({ gasLimit: 3e6 });
    //   console.log('cr', await strategy.targetCollatRatio());
    //   console.log(
    //     utils.formatUnits(await aToken.balanceOf(strategy.address), 6),
    //     utils.formatUnits(await debtToken.balanceOf(strategy.address), 6),
    //     utils.formatUnits(
    //       (await aToken.balanceOf(strategy.address)).sub(await debtToken.balanceOf(strategy.address)),
    //       6,
    //     ),
    //   );
    // });

    it('cooldownStkAave', async () => {
      await strategy['harvest()']({ gasLimit: 3e6 });
      await expect((await strategy.boolParams()).cooldownStkAave).to.be.true;

      await network.provider.send('evm_increaseTime', [3600 * 24]);
      await network.provider.send('evm_mine');
      await strategy['harvest()']({ gasLimit: 3e6 });

      await network.provider.send('evm_increaseTime', [3600 * 24 * 10.5]); // forward 11 days
      await network.provider.send('evm_mine');

      const stkAaveBalanceBefore = parseFloat(utils.formatUnits(await stkAave.balanceOf(strategy.address), 18));
      await strategy['harvest()']({ gasLimit: 3e6 });
      const aaveBalanceAfterRedeem = parseFloat(utils.formatUnits(await aave.balanceOf(strategy.address), 18));

      expect(stkAaveBalanceBefore).to.be.closeTo(aaveBalanceAfterRedeem, 0.1);
    });

    it('estimatedApr', async () => {
      expect(await strategy.estimatedAPR()).to.equal(0);

      await strategy['harvest()']({ gasLimit: 3e6 });
      expect(parseFloat(utils.formatUnits(await aToken.balanceOf(strategy.address), 6))).to.be.closeTo(9677419, 1000);

      expect(await wantToken.balanceOf(strategy.address)).to.equal(0);
      expect(parseFloat(utils.formatUnits(await strategy.estimatedAPR(), 18))).to.be.closeTo(0.067, 0.001);
    });
  });

  // describe("", () => {
  // it.only('', async () => {});
  // })
});
