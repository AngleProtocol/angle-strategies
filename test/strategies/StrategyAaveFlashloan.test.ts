import { SignerWithAddress } from '@nomiclabs/hardhat-ethers/signers';
import { ethers, network } from 'hardhat';
import { utils, Wallet, constants, Contract, BigNumber } from 'ethers';
import { expect } from '../test-utils/chai-setup';
import { deploy, randomAddress, impersonate } from '../test-utils';
import { inReceipt, inIndirectReceipt } from '../test-utils/expectEvent';
import {
  AaveFlashloanStrategy,
  FlashMintLib,
  ERC20,
  MockToken,
  MockAave,
  MockPoolManager,
  MockProtocolDataProvider,
  MockUniswapV2Router,
  MockUniswapV3Router,
  ERC20__factory,
  MockAToken,
  MockLendingPool,
  FlashMintLib__factory,
  MockLendingPool__factory,
  IAaveIncentivesController__factory,
  MockProtocolDataProvider__factory,
  MockUniswapV2Router__factory,
  MockUniswapV3Pool__factory,
  MockToken__factory,
  ComputeProfitability,
} from '../../typechain';

// HELPER for console.log, to delete
const logUSDC = (amount: BigNumber) => utils.formatUnits(amount, 6);

describe('AaveFlashloan Strat', () => {
  // ATokens
  let aToken: MockAToken, debtToken: MockAToken, aDai: MockAToken;

  // Tokens
  let wantToken: MockToken,
    dai: MockToken,
    aave: MockToken,
    stkAave: MockToken,
    weth: MockToken,
    rewardToken: MockToken,
    mockAAVE: MockToken;

  // Guardians
  let governor: SignerWithAddress, guardian: SignerWithAddress, user: SignerWithAddress;

  // Routers
  let uniV2Router: MockUniswapV2Router, uniV3Router: MockUniswapV3Router, sushiV2Router: MockUniswapV2Router;

  let poolManager: MockPoolManager;
  let protocolDataProvider: MockProtocolDataProvider;
  let incentivesController: MockAave;
  let lendingPool: MockLendingPool;
  let flashMintLib: FlashMintLib;
  let computeProfitabilityContract: ComputeProfitability;

  let strategy: AaveFlashloanStrategy;

  beforeEach(async () => {
    // aToken = (await deploy('MockAToken', ['aave token', 'aToken', 18])) as MockAToken;
    // debtToken = (await deploy('MockAToken', ['debt token', 'debtToken', 18])) as MockAToken;
    // aDai = (await deploy('MockAToken', ['adai token', 'aDai', 18])) as MockAToken;

    wantToken = (await ethers.getContractAt(
      MockToken__factory.abi,
      '0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48',
    )) as MockToken;
    dai = (await ethers.getContractAt(
      MockToken__factory.abi,
      '0x6B175474E89094C44Da98b954EedeAC495271d0F',
    )) as MockToken;
    aave = (await ethers.getContractAt(
      MockToken__factory.abi,
      '0x7Fc66500c84A76Ad7e9c93437bFc5Ac33E2DDaE9',
    )) as MockToken;
    stkAave = (await ethers.getContractAt(
      MockToken__factory.abi,
      '0x4da27a545c0c5B758a6BA100e3a049001de870f5',
    )) as MockToken;
    weth = (await ethers.getContractAt(
      MockToken__factory.abi,
      '0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2',
    )) as MockToken;
    rewardToken = (await ethers.getContractAt(
      MockToken__factory.abi,
      '0x31429d1856aD1377A8A0079410B297e1a9e214c2',
    )) as MockToken;
    mockAAVE = (await deploy('MockToken', ['mock aave token', 'mockAAVE', 18])) as MockToken;

    [governor, guardian, user] = await ethers.getSigners();

    uniV2Router = (await ethers.getContractAt(
      MockUniswapV2Router__factory.abi,
      '0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D',
    )) as MockUniswapV2Router;
    sushiV2Router = (await ethers.getContractAt(
      MockUniswapV2Router__factory.abi,
      '0xd9e1cE17f2641f24aE83637ab66a2cca9C378B9F',
    )) as MockUniswapV2Router;
    uniV3Router = (await ethers.getContractAt(
      MockUniswapV3Pool__factory.abi,
      '0xE592427A0AEce92De3Edee1F18E0157C05861564',
    )) as MockUniswapV3Router;

    poolManager = (await deploy('MockPoolManager', [wantToken.address, 0])) as MockPoolManager;

    protocolDataProvider = (await ethers.getContractAt(
      MockProtocolDataProvider__factory.abi,
      '0x057835Ad21a177dbdd3090bB1CAE03EaCF78Fc6d',
    )) as MockProtocolDataProvider;

    incentivesController = (await ethers.getContractAt(
      IAaveIncentivesController__factory.abi,
      '0xd784927Ff2f95ba542BfC824c8a8a98F3495f6b5',
    )) as MockAave;

    lendingPool = (await ethers.getContractAt(
      MockLendingPool__factory.abi,
      '0x7d2768dE32b0b80b7a3454c06BdAc94A69DDc7A9',
    )) as MockLendingPool;

    const daiLender = await deploy('MockMKRLender', [dai.address, constants.MaxUint256]);

    flashMintLib = (await deploy('FlashMintLib')) as FlashMintLib;
    computeProfitabilityContract = (await deploy('ComputeProfitability')) as ComputeProfitability;

    strategy = (await deploy(
      'AaveFlashloanStrategy',
      [
        poolManager.address,
        rewardToken.address,
        [governor.address],
        guardian.address,
        computeProfitabilityContract.address,
      ],
      { libraries: { FlashMintLib: flashMintLib.address } },
    )) as AaveFlashloanStrategy;

    aToken = (await ethers.getContractAt(MockToken__factory.abi, await strategy.aToken())) as MockAToken;
    debtToken = (await ethers.getContractAt(MockToken__factory.abi, await strategy.debtToken())) as MockAToken;
    // aDai = (await deploy('MockAToken', ['adai token', 'aDai', 18])) as MockAToken;
  });

  // it('basic test', async () => {
  //   await (await poolManager.addStrategy(strategy.address, utils.parseUnits('0.75', 9))).wait();
  //   // await strategy.connect(guardian).setIsFlashMintActive(false);
  //   // expect(await poolManager.strategyList(0)).to.equal(strategy.address);

  //   // console.log('strategy', strategy.address);
  //   // const total = await strategy.estimatedTotalAssets();
  //   // console.log('total', total, total.toString());
  //   // console.log(await strategy.harvestTrigger());
  //   // console.log(await strategy.isActive());

  //   const amount = utils.parseUnits('10000', 6);

  //   await impersonate('0x6262998Ced04146fA42253a5C0AF90CA02dfd2A3', async acc => {
  //     await wantToken.connect(acc).transfer(user.address, amount);
  //     await wantToken.connect(acc).transfer(user.address, amount);
  //   });
  //   console.log('balance', utils.formatUnits(await wantToken.balanceOf(user.address), 6));

  //   await wantToken.connect(user).transfer(poolManager.address, amount);
  //   await wantToken.connect(user).transfer(strategy.address, amount);

  //   console.log('\ntotal2', await strategy.estimatedTotalAssets());
  //   console.log('total2', utils.formatUnits(await wantToken.balanceOf(poolManager.address), 6));
  //   console.log('total2', utils.formatUnits(await wantToken.balanceOf(strategy.address), 6), '\n');

  //   console.log('emergencyExit', await strategy.emergencyExit());
  //   console.log('getCurrentCollatRatio', await strategy.getCurrentCollatRatio());
  //   console.log('isFlashMintActive', await strategy.isFlashMintActive());

  //   await strategy.harvest();
  //   console.log('balance PM', utils.formatUnits(await wantToken.balanceOf(poolManager.address), 6));
  //   console.log('balance STRAT', utils.formatUnits(await wantToken.balanceOf(strategy.address), 6), '\n');

  //   console.log('\nLENDING BALANCE', (await wantToken.balanceOf(lendingPool.address)).toString());
  //   console.log('BALANCE aToken\n', (await aToken.balanceOf(strategy.address)).toString());

  //   await strategy.harvest();
  //   console.log('balance PM', utils.formatUnits(await wantToken.balanceOf(poolManager.address), 6));
  //   console.log('balance STRAT', utils.formatUnits(await wantToken.balanceOf(strategy.address), 6), '\n');
  //   console.log('balance aToken', utils.formatUnits(await aToken.balanceOf(strategy.address), 6), '\n');
  //   console.log('balance debtToken', utils.formatUnits(await debtToken.balanceOf(strategy.address), 6), '\n');

  //   await strategy.harvest();
  //   console.log('balance PM', utils.formatUnits(await wantToken.balanceOf(poolManager.address), 6));
  //   console.log('balance STRAT', utils.formatUnits(await wantToken.balanceOf(strategy.address), 6), '\n');
  //   console.log('balance aToken', utils.formatUnits(await aToken.balanceOf(strategy.address), 6), '\n');
  //   console.log('balance debtToken', utils.formatUnits(await debtToken.balanceOf(strategy.address), 6), '\n');

  //   await strategy.harvest();
  //   console.log('balance PM', utils.formatUnits(await wantToken.balanceOf(poolManager.address), 6));
  //   console.log('balance STRAT', utils.formatUnits(await wantToken.balanceOf(strategy.address), 6), '\n');
  //   console.log('balance aToken', utils.formatUnits(await aToken.balanceOf(strategy.address), 6), '\n');
  //   console.log('balance debtToken', utils.formatUnits(await debtToken.balanceOf(strategy.address), 6), '\n');

  //   console.log('\ntotal3', await strategy.estimatedTotalAssets());
  //   console.log('total3', utils.formatUnits(await wantToken.balanceOf(poolManager.address), 6));
  //   console.log('total3', utils.formatUnits(await wantToken.balanceOf(strategy.address), 6));
  // });

  describe('Constructor', () => {
    it('tokens', async () => {
      expect(await strategy.aToken()).to.equal(aToken.address);
      expect(await strategy.debtToken()).to.equal(debtToken.address);
      expect(await strategy.rewards()).to.equal(rewardToken.address);
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

      const allowanceAave1 = await aave.allowance(strategy.address, uniV2Router.address);
      const allowanceAave2 = await aave.allowance(strategy.address, sushiV2Router.address);
      const allowanceAave3 = await aave.allowance(strategy.address, uniV3Router.address);
      expect(allowanceAave1).to.equal(constants.MaxUint256);
      expect(allowanceAave2).to.equal(constants.MaxUint256);
      expect(allowanceAave3).to.equal(constants.MaxUint256);

      const allowanceStkAave = await stkAave.allowance(strategy.address, uniV3Router.address);
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
      expect(await strategy.computeProfitability()).to.equal(computeProfitabilityContract.address);
      expect(await strategy.maxIterations()).to.equal(6);
      await expect(await strategy.isFlashMintActive()).to.be.true;
      expect(await strategy.swapRouter()).to.equal(0);
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
      // const ratiosUsdc = await protocolDataProvider.getReserveConfigurationData(wantToken.address);
      // const ratiosDai = await protocolDataProvider.getReserveConfigurationData(dai.address);

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
    });

    it('setIsFlashMintActive', async () => {
      expect(strategy.connect(user).setIsFlashMintActive(true)).to.be.revertedWith(
        `AccessControl: account ${user.address.toLowerCase()} is missing role`,
      );
      await expect(await strategy.isFlashMintActive()).to.be.true;
      await strategy.connect(guardian).setIsFlashMintActive(false);
      await expect(await strategy.isFlashMintActive()).to.be.false;
    });

    it('setWithdrawCheck', async () => {
      expect(strategy.connect(user).setWithdrawCheck(true)).to.be.revertedWith(
        `AccessControl: account ${user.address.toLowerCase()} is missing role`,
      );

      await expect(await strategy.withdrawCheck()).to.be.false;
      await strategy.connect(guardian).setWithdrawCheck(true);
      await expect(await strategy.withdrawCheck()).to.be.true;
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

    it('setRewardBehavior', async () => {
      const uniswapPoolFee = utils.parseUnits('0.3', 4);

      expect(
        strategy
          .connect(user)
          .setRewardBehavior(
            0,
            true,
            true,
            utils.parseUnits('0.1', 18),
            utils.parseUnits('0.05', 4),
            uniswapPoolFee,
            uniswapPoolFee,
            uniswapPoolFee,
          ),
      ).to.be.revertedWith(`AccessControl: account ${user.address.toLowerCase()} is missing role`);

      expect(await strategy.swapRouter()).to.equal(0);
      await expect(await strategy.sellStkAave()).to.be.true;
      await expect(await strategy.cooldownStkAave()).to.be.false;
      expect(await strategy.minRewardToSell()).to.equal(utils.parseUnits('0.001', 18));
      expect(await strategy.maxStkAavePriceImpactBps()).to.equal(utils.parseUnits('0.05', 4));
      expect(await strategy.stkAaveToAaveSwapFee()).to.equal(uniswapPoolFee);

      await strategy
        .connect(guardian)
        .setRewardBehavior(
          1,
          false,
          false,
          utils.parseUnits('0.1', 18),
          utils.parseUnits('0.2', 4),
          uniswapPoolFee,
          uniswapPoolFee,
          uniswapPoolFee,
        );

      expect(await strategy.swapRouter()).to.equal(1);
      await expect(await strategy.sellStkAave()).to.be.false;
      await expect(await strategy.cooldownStkAave()).to.be.false;
      expect(await strategy.minRewardToSell()).to.equal(utils.parseUnits('0.1', 18));
      expect(await strategy.maxStkAavePriceImpactBps()).to.equal(utils.parseUnits('0.2', 4));
      expect(await strategy.stkAaveToAaveSwapFee()).to.equal(uniswapPoolFee);
    });
  });

  describe('View functions', () => {
    const amount = utils.parseUnits((1e6).toString(), 6);

    beforeEach(async () => {
      await (await poolManager.addStrategy(strategy.address, utils.parseUnits('0.75', 9))).wait();

      await impersonate('0x6262998Ced04146fA42253a5C0AF90CA02dfd2A3', async acc => {
        await wantToken.connect(acc).transfer(user.address, amount);
        await wantToken.connect(acc).transfer(user.address, amount);
      });
      console.log('balance', utils.formatUnits(await wantToken.balanceOf(user.address), 6));

      await wantToken.connect(user).transfer(poolManager.address, amount);
      await wantToken.connect(user).transfer(strategy.address, amount);
    });

    it('estimatedTotalAssets', async () => {
      expect(await strategy.estimatedTotalAssets()).to.equal(amount);
      await strategy.harvest();

      const { deposits, borrows } = await strategy.getCurrentPosition();
      const totalAssets = (await wantToken.balanceOf(strategy.address)).add(deposits).sub(borrows);
      expect(await strategy.estimatedTotalAssets()).to.equal(totalAssets);
    });

    // it.only('estimatedRewardsInWant', async () => {
    //   console.log('estimatedRewardsInWant', logUSDC(await strategy.estimatedRewardsInWant()));
    //   await strategy.harvest();

    //   const rewards = await incentivesController.getRewardsBalance(
    //     [aToken.address, debtToken.address],
    //     strategy.address,
    //   );
    //   console.log('rewards before', rewards);

    //   console.log('stkaave balance', await stkAave.balanceOf(strategy.address));
    //   await network.provider.send('evm_increaseTime', [3600 * 24 * 10]);
    //   await network.provider.send('evm_mine');

    //   console.log('stkaave balance', await stkAave.balanceOf(strategy.address));
    //   console.log('aave balance', await aave.balanceOf(strategy.address));

    //   console.log(
    //     'rewards after',
    //     await incentivesController.getRewardsBalance([aToken.address, debtToken.address], strategy.address),
    //   );
    //   console.log('estimatedRewardsInWant', logUSDC(await strategy.estimatedRewardsInWant()));
    //   console.log('_AAVEToWant', logUSDC(await strategy.AAVEToWant(utils.parseEther('1'))));
    //   console.log('_tokenToWant', logUSDC(await strategy._tokenToWant(aave.address, utils.parseEther('1'))));
    // });

    // it.only('', async () => {});
  });

  // describe("", () => {
  // it.only('', async () => {});
  // })

  describe('computeMostProfitableBorrow', () => {
    beforeEach(async () => {
      await (await poolManager.addStrategy(strategy.address, utils.parseUnits('0.75', 9))).wait();
      const amount = utils.parseUnits('10000', 6);

      await impersonate('0x6262998Ced04146fA42253a5C0AF90CA02dfd2A3', async acc => {
        await wantToken.connect(acc).transfer(user.address, amount);
        await wantToken.connect(acc).transfer(user.address, amount);
      });
      console.log('balance', utils.formatUnits(await wantToken.balanceOf(user.address), 6));

      await wantToken.connect(user).transfer(poolManager.address, amount);
      await wantToken.connect(user).transfer(strategy.address, amount);
    });

    it('', async () => {
      console.log('balance strat', await wantToken.balanceOf(strategy.address));
    });

    // it.only('', async () => {});
  });
});
