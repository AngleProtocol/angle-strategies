import { SignerWithAddress } from '@nomiclabs/hardhat-ethers/signers';
import { ethers } from 'hardhat';
import { utils, Wallet, constants, Contract, BigNumber } from 'ethers';
import { expect } from '../test-utils/chai-setup';
import { deploy, randomAddress } from '../test-utils';
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
} from '../../typechain';

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

  let strategy: AaveFlashloanStrategy;

  beforeEach(async () => {
    aToken = (await deploy('MockAToken', ['aave token', 'aToken', 18])) as MockAToken;
    debtToken = (await deploy('MockAToken', ['debt token', 'debtToken', 18])) as MockAToken;
    aDai = (await deploy('MockAToken', ['adai token', 'aDai', 18])) as MockAToken;

    wantToken = (await deploy('MockToken', ['usdc token', 'USDC', 6])) as MockToken;
    dai = (await deploy('MockToken', ['dai token', 'DAI', 18])) as MockToken;
    aave = (await deploy('MockToken', ['aave token', 'AAVE', 18])) as MockToken;
    stkAave = (await deploy('MockToken', ['stkAave token', 'stkAAVE', 18])) as MockToken;
    weth = (await deploy('MockToken', ['weth token', 'WETH', 18])) as MockToken;
    rewardToken = (await deploy('MockToken', ['reward token', 'rewardToken', 18])) as MockToken;
    mockAAVE = (await deploy('MockToken', ['mock aave token', 'mockAAVE', 18])) as MockToken;

    [governor, guardian, user] = await ethers.getSigners();

    uniV2Router = (await deploy('MockUniswapV2Router', [10])) as MockUniswapV2Router;
    sushiV2Router = (await deploy('MockUniswapV2Router', [10])) as MockUniswapV2Router;
    uniV3Router = (await deploy('MockUniswapV3Router', [wantToken.address, aave.address])) as MockUniswapV3Router;

    poolManager = (await deploy('MockPoolManager', [wantToken.address, 0])) as MockPoolManager;
    protocolDataProvider = (await deploy('MockProtocolDataProvider', [
      aToken.address,
      debtToken.address,
      (await deploy('MockAave')).address,
    ])) as MockProtocolDataProvider;
    incentivesController = (await deploy('MockAave')) as MockAave;
    lendingPool = (await deploy('MockLendingPool', [aToken.address, debtToken.address])) as MockLendingPool;
    await lendingPool.connect(user).deployNewUnderlying(wantToken.address);

    const daiLender = await deploy('MockMKRLender', [dai.address, constants.MaxUint256]);

    strategy = (await deploy('AaveFlashloanStrategy', [
      poolManager.address,
      rewardToken.address,
      [governor.address],
      guardian.address,
      protocolDataProvider.address,
      incentivesController.address,
      lendingPool.address,
      [dai.address, aave.address, stkAave.address, weth.address],
      [uniV2Router.address, uniV3Router.address, sushiV2Router.address],
      { lender: daiLender.address, adai: aDai.address },
    ])) as AaveFlashloanStrategy;

    flashMintLib = (await ethers.getContractAt(
      FlashMintLib__factory.abi,
      await strategy.flashMintlib(),
    )) as FlashMintLib;
  });

  it('basic test', async () => {
    await (await poolManager.addStrategy(strategy.address, utils.parseUnits('0.75', 9))).wait();
    // await strategy.connect(guardian).setIsFlashMintActive(false);
    // expect(await poolManager.strategyList(0)).to.equal(strategy.address);

    // console.log('strategy', strategy.address);
    // const total = await strategy.estimatedTotalAssets();
    // console.log('total', total, total.toString());
    // console.log(await strategy.harvestTrigger());
    // console.log(await strategy.isActive());

    const amount = utils.parseUnits('10000', 6);
    await wantToken.connect(user).mint(user.address, amount);
    await wantToken.connect(user).mint(user.address, amount);
    console.log('balance', utils.formatUnits(await wantToken.balanceOf(user.address), 6));

    await wantToken.connect(user).transfer(poolManager.address, amount);
    // await wantToken.connect(user).transfer(strategy.address, amount);

    console.log('\ntotal2', await strategy.estimatedTotalAssets());
    console.log('total2', utils.formatUnits(await wantToken.balanceOf(poolManager.address), 6));
    console.log('total2', utils.formatUnits(await wantToken.balanceOf(strategy.address), 6), '\n');

    // console.log('emergencyExit', await strategy.emergencyExit());
    // console.log('getCurrentCollatRatio', await strategy.getCurrentCollatRatio());
    // console.log('isFlashMintActive', await strategy.isFlashMintActive());

    await strategy.harvest();
    console.log('balance PM', utils.formatUnits(await wantToken.balanceOf(poolManager.address), 6));
    console.log('balance STRAT', utils.formatUnits(await wantToken.balanceOf(strategy.address), 6), '\n');

    console.log('\nLENDING BALANCE', (await wantToken.balanceOf(lendingPool.address)).toString());
    console.log('BALANCE aToken\n', (await aToken.balanceOf(strategy.address)).toString());

    await strategy.harvest();
    console.log('balance PM', utils.formatUnits(await wantToken.balanceOf(poolManager.address), 6));
    console.log('balance STRAT', utils.formatUnits(await wantToken.balanceOf(strategy.address), 6), '\n');

    await strategy.harvest();
    console.log('balance PM', utils.formatUnits(await wantToken.balanceOf(poolManager.address), 6));
    console.log('balance STRAT', utils.formatUnits(await wantToken.balanceOf(strategy.address), 6), '\n');

    await strategy.harvest();
    console.log('balance PM', utils.formatUnits(await wantToken.balanceOf(poolManager.address), 6));
    console.log('balance STRAT', utils.formatUnits(await wantToken.balanceOf(strategy.address), 6), '\n');

    console.log('\ntotal3', await strategy.estimatedTotalAssets());
    console.log('total3', utils.formatUnits(await wantToken.balanceOf(poolManager.address), 6));
    console.log('total3', utils.formatUnits(await wantToken.balanceOf(strategy.address), 6));
  });

  describe('Constructor', () => {
    it('tokens', async () => {
      expect(await strategy.aToken()).to.equal(aToken.address);
      expect(await strategy.debtToken()).to.equal(debtToken.address);
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
  });

  // it('', async () => {});
});
