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
  IAaveIncentivesController__factory,
  ComputeProfitability,
  IStakedAave,
  IStakedAave__factory,
  AaveFlashloanStrategy__factory,
  PoolManager,
  IProtocolDataProvider,
  IAaveIncentivesController,
  ILendingPool,
  IProtocolDataProvider__factory,
  ILendingPool__factory,
} from '../../typechain';
import { formatUnits, parseUnits } from 'ethers/lib/utils';

describe('AaveFlashloan Strat - coverage', () => {
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
  let incentivesController: IAaveIncentivesController;
  let lendingPool: ILendingPool;
  let flashMintLib: FlashMintLib;
  let computeProfitabilityLib: ComputeProfitability;

  let strategy: AaveFlashloanStrategy;

  // ReserveInterestRateStrategy for USDC
  const reserveInterestRateStrategyUSDC = '0x8Cae0596bC1eD42dc3F04c4506cfe442b3E74e27';
  // ReserveInterestRateStrategy for DAI
  const reserveInterestRateStrategyDAI = '0xfffE32106A68aA3eD39CcCE673B646423EEaB62a';

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

    incentivesController = (await ethers.getContractAt(
      IAaveIncentivesController__factory.abi,
      '0xd784927Ff2f95ba542BfC824c8a8a98F3495f6b5',
    )) as IAaveIncentivesController;

    lendingPool = (await ethers.getContractAt(
      ILendingPool__factory.abi,
      '0x7d2768dE32b0b80b7a3454c06BdAc94A69DDc7A9',
    )) as ILendingPool;

    flashMintLib = (await deploy('FlashMintLib')) as FlashMintLib;
    computeProfitabilityLib = (await deploy('ComputeProfitability')) as ComputeProfitability;

    const strategyImplementation = (await deploy('AaveFlashloanStrategy', [], {
      libraries: {
        FlashMintLib: flashMintLib.address,
        ComputeProfitability: computeProfitabilityLib.address,
      },
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

  describe('Strategy', () => {
    const _startAmountUSDC = utils.parseUnits((2_000_000).toString(), 6);
    let _guessedBorrowed = utils.parseUnits((0).toString(), 6);

    beforeEach(async () => {
      await (await poolManager.addStrategy(strategy.address, utils.parseUnits('0.75', 9))).wait();

      await impersonate('0x6262998Ced04146fA42253a5C0AF90CA02dfd2A3', async acc => {
        await wantToken.connect(acc).transfer(user.address, _startAmountUSDC);
      });

      // sending funds to emission controller
      await network.provider.send('hardhat_setBalance', [
        '0xEE56e2B3D491590B5b31738cC34d5232F378a8D5',
        utils.parseEther('100').toHexString().replace('0x0', '0x'),
      ]);

      // sending funds to strategy
      await network.provider.send('hardhat_setBalance', [
        strategy.address,
        utils.parseEther('100').toHexString().replace('0x0', '0x'),
      ]);

      await wantToken.connect(user).transfer(poolManager.address, _startAmountUSDC);

      await strategy.connect(keeper)['harvest()']({ gasLimit: 3e6 });
    });

    it('adjustPosition - currentCollatRatio > _targetCollatRatio', async () => {
      await impersonate('0xEE56e2B3D491590B5b31738cC34d5232F378a8D5', async acc => {
        await incentivesController
          .connect(acc)
          .configureAssets([aToken.address, debtToken.address], [ethers.constants.Zero, ethers.constants.Zero]);
      });

      await strategy.connect(keeper)['harvest(uint256)'](ethers.constants.Zero, { gasLimit: 3e6 });
      const { borrows } = await strategy.getCurrentPosition();
      expect(borrows).to.equal(ethers.constants.Zero);
    });

    it('_liquidatePosition - withdrawCheck - success', async () => {
      await impersonate('0xEE56e2B3D491590B5b31738cC34d5232F378a8D5', async acc => {
        await incentivesController
          .connect(acc)
          .configureAssets([aToken.address, debtToken.address], [ethers.constants.Zero, ethers.constants.Zero]);
      });

      await strategy.connect(guardian).setBoolParams({
        isFlashMintActive: true,
        automaticallyComputeCollatRatio: (await strategy.boolParams()).automaticallyComputeCollatRatio,
        withdrawCheck: false,
        cooldownStkAave: (await strategy.boolParams()).cooldownStkAave,
      });

      await strategy.connect(keeper)['harvest(uint256)'](ethers.constants.Zero, { gasLimit: 3e6 });
      const { borrows } = await strategy.getCurrentPosition();
      expect(borrows).to.equal(ethers.constants.Zero);
    });

    it('sellRewards - cooldown triggered', async () => {
      expect(await stkAave.balanceOf(strategy.address)).to.equal(0);
      expect(await aave.balanceOf(strategy.address)).to.equal(0);

      await network.provider.send('evm_increaseTime', [3600 * 24 * 2]); // forward 2 day
      await network.provider.send('evm_mine');
      await strategy.connect(keeper)['harvest()']({ gasLimit: 3e6 });

      const chainId = 1;
      const oneInchParams = qs.stringify({
        fromTokenAddress: stkAave.address,
        toTokenAddress: wantToken.address,
        fromAddress: strategy.address,
        amount: parseUnits('3.5', 18),
        slippage: 50,
        disableEstimate: true,
      });
      const url = `https://api.1inch.exchange/v4.0/${chainId}/swap?${oneInchParams}`;

      const res = await axios.get(url);
      const payload = res.data.tx.data;

      const stkAaveBefore = parseFloat(utils.formatUnits(await stkAave.balanceOf(strategy.address)));

      await strategy.connect(keeper).sellRewards(0, payload, true);

      const stkAaveAfter = parseFloat(utils.formatUnits(await stkAave.balanceOf(strategy.address)));

      expect(stkAaveBefore).to.be.closeTo(3.6, 0.1);
      expect(stkAaveAfter).to.be.closeTo(0, 0.01);

      await network.provider.send('evm_increaseTime', [3600 * 24 * 5]); // forward 5 days
      await network.provider.send('evm_mine');

      // cooldown triggered
      await strategy.connect(keeper)['harvest()']({ gasLimit: 3e6 });
    });

    it('sellRewards - not claiming', async () => {
      expect(await stkAave.balanceOf(strategy.address)).to.equal(0);
      expect(await aave.balanceOf(strategy.address)).to.equal(0);

      await network.provider.send('evm_increaseTime', [3600 * 24 * 2]); // forward 1 day
      await network.provider.send('evm_mine');
      await strategy.connect(keeper)['harvest()']({ gasLimit: 3e6 });

      const chainId = 1;
      const oneInchParams = qs.stringify({
        fromTokenAddress: stkAave.address,
        toTokenAddress: wantToken.address,
        fromAddress: strategy.address,
        amount: parseUnits('3.5', 18),
        slippage: 50,
        disableEstimate: true,
      });
      const url = `https://api.1inch.exchange/v4.0/${chainId}/swap?${oneInchParams}`;

      const res = await axios.get(url);
      const payload = res.data.tx.data;

      const stkAaveBefore = parseFloat(utils.formatUnits(await stkAave.balanceOf(strategy.address)));

      await strategy.connect(keeper).sellRewards(0, payload, true);

      const stkAaveAfter = parseFloat(utils.formatUnits(await stkAave.balanceOf(strategy.address)));

      expect(stkAaveBefore).to.be.closeTo(3.6, 0.1);
      expect(stkAaveAfter).to.be.closeTo(0, 0.01);
    });

    it('onFlashLoan - revert', async () => {
      await expect(
        strategy
          .connect(keeper)
          .onFlashLoan(keeper.address, keeper.address, ethers.constants.Zero, ethers.constants.Zero, '0x'),
      ).to.be.revertedWith('1');
    });

    it('cooldownStkAave - too soon', async () => {
      await strategy['harvest()']({ gasLimit: 3e6 });
      await expect((await strategy.boolParams()).cooldownStkAave).to.be.true;

      await network.provider.send('evm_increaseTime', [3600 * 24]);
      await network.provider.send('evm_mine');
      await strategy['harvest()']({ gasLimit: 3e6 });

      await network.provider.send('evm_increaseTime', [3600 * 24 * 5]); // forward 11 days
      await network.provider.send('evm_mine');

      const aaveBalanceBefore = parseFloat(utils.formatUnits(await aave.balanceOf(strategy.address), 18));
      await strategy['harvest()']({ gasLimit: 3e6 });
      const aaveBalanceAfterRedeem = parseFloat(utils.formatUnits(await aave.balanceOf(strategy.address), 18));

      expect(aaveBalanceAfterRedeem).to.be.closeTo(aaveBalanceBefore, 0.1);
    });
  });
});
