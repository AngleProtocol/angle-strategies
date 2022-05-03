import { SignerWithAddress } from '@nomiclabs/hardhat-ethers/signers';
import { BigNumber, Contract, utils } from 'ethers';
import {
  ERC20,
  ERC20__factory,
  GenericAaveFraxStaker,
  GenericAaveFraxStaker__factory,
  IAaveIncentivesController,
  IAaveIncentivesController__factory,
  IFraxUnifiedFarmTemplate,
  IFraxUnifiedFarmTemplate__factory,
  ILendingPool,
  ILendingPool__factory,
  IProtocolDataProvider,
  IProtocolDataProvider__factory,
  IStakedAave,
  IStakedAave__factory,
  OptimizerAPRStrategy,
  OptimizerAPRStrategy__factory,
  PoolManager,
} from '../../typechain';
import { gwei } from '../../utils/bignumber';
import { deploy, deployUpgradeable, impersonate } from '../test-utils';
import hre, { ethers, network } from 'hardhat';
import { expect } from '../test-utils/chai-setup';
import { parseUnits } from 'ethers/lib/utils';
import { logBN, setTokenBalanceFor } from '../utils-interaction';
import { DAY } from '../contants';

async function initStrategy(
  governor: SignerWithAddress,
  guardian: SignerWithAddress,
  keeper: SignerWithAddress,
  manager: PoolManager,
): Promise<{
  strategy: OptimizerAPRStrategy;
}> {
  const strategy = (await deployUpgradeable(new OptimizerAPRStrategy__factory(guardian))) as OptimizerAPRStrategy;
  await strategy.initialize(manager.address, governor.address, guardian.address, [keeper.address]);
  await manager.connect(governor).addStrategy(strategy.address, gwei('0.8'));
  return { strategy };
}

async function initLenderAaveFraxStaker(
  governor: SignerWithAddress,
  guardian: SignerWithAddress,
  keeper: SignerWithAddress,
  strategy: OptimizerAPRStrategy,
  name: string,
  isIncentivized: boolean,
): Promise<{
  lender: GenericAaveFraxStaker;
}> {
  const lender = (await deployUpgradeable(new GenericAaveFraxStaker__factory(guardian))) as GenericAaveFraxStaker;
  await lender.initialize(
    strategy.address,
    name,
    isIncentivized,
    [governor.address],
    guardian.address,
    [keeper.address],
    DAY,
  );
  await strategy.connect(governor).addLender(lender.address);
  return { lender };
}

let governor: SignerWithAddress, guardian: SignerWithAddress, user: SignerWithAddress, keeper: SignerWithAddress;
let strategy: OptimizerAPRStrategy;
let token: ERC20;
let aToken: ERC20;
let tokenDecimal: number;
let FEI: ERC20;
let manager: PoolManager;
let lenderAave: GenericAaveFraxStaker;
let aave: ERC20;
let stkAave: IStakedAave;
let incentivesController: IAaveIncentivesController;
let lendingPool: ILendingPool;
let protocolDataProvider: IProtocolDataProvider;
let aFraxStakingContract: IFraxUnifiedFarmTemplate;
const lockerStakeDAO = '0xCd3a267DE09196C48bbB1d9e842D7D7645cE448f';
const fraxTimelock = '0x8412ebf45bAC1B340BbE8F318b928C466c4E39CA';

const guardianRole = ethers.utils.solidityKeccak256(['string'], ['GUARDIAN_ROLE']);
const strategyRole = ethers.utils.solidityKeccak256(['string'], ['STRATEGY_ROLE']);
const governorRole = ethers.utils.solidityKeccak256(['string'], ['GOVERNOR_ROLE']);
const keeperRole = ethers.utils.solidityKeccak256(['string'], ['KEEPER_ROLE']);
let guardianError: string;

// Start test block
describe('OptimizerAPR - lenderAaveFraxStaker', () => {
  before(async () => {
    await network.provider.request({
      method: 'hardhat_reset',
      params: [
        {
          forking: {
            jsonRpcUrl: process.env.ETH_NODE_URI_FORK,
            blockNumber: 14705411,
          },
        },
      ],
    });

    ({ governor, guardian, user, keeper } = await ethers.getNamedSigners());

    token = (await ethers.getContractAt(ERC20__factory.abi, '0x853d955aCEf822Db058eb8505911ED77F175b99e')) as ERC20;
    aToken = (await ethers.getContractAt(ERC20__factory.abi, '0xd4937682df3C8aEF4FE912A96A74121C0829E664')) as ERC20;

    FEI = (await ethers.getContractAt(ERC20__factory.abi, '0x956F47F50A910163D8BF957Cf5846D573E7f87CA')) as ERC20;

    tokenDecimal = await token.decimals();

    aave = (await ethers.getContractAt(ERC20__factory.abi, '0x7Fc66500c84A76Ad7e9c93437bFc5Ac33E2DDaE9')) as ERC20;
    stkAave = (await ethers.getContractAt(
      IStakedAave__factory.abi,
      '0x4da27a545c0c5B758a6BA100e3a049001de870f5',
    )) as IStakedAave;
    incentivesController = (await ethers.getContractAt(
      IAaveIncentivesController__factory.abi,
      '0xd784927Ff2f95ba542BfC824c8a8a98F3495f6b5',
    )) as IAaveIncentivesController;
    lendingPool = (await ethers.getContractAt(
      ILendingPool__factory.abi,
      '0x7d2768dE32b0b80b7a3454c06BdAc94A69DDc7A9',
    )) as ILendingPool;
    protocolDataProvider = (await ethers.getContractAt(
      IProtocolDataProvider__factory.abi,
      '0x057835Ad21a177dbdd3090bB1CAE03EaCF78Fc6d',
    )) as IProtocolDataProvider;

    aFraxStakingContract = (await ethers.getContractAt(
      IFraxUnifiedFarmTemplate__factory.abi,
      '0x02577b426F223A6B4f2351315A19ecD6F357d65c',
    )) as IFraxUnifiedFarmTemplate;

    guardianError = `AccessControl: account ${user.address.toLowerCase()} is missing role ${guardianRole}`;
  });

  beforeEach(async () => {
    manager = (await deploy('PoolManager', [token.address, governor.address, guardian.address])) as PoolManager;

    ({ strategy: strategy } = await initStrategy(governor, guardian, keeper, manager));

    ({ lender: lenderAave } = await initLenderAaveFraxStaker(
      governor,
      guardian,
      keeper,
      strategy,
      'genericAave',
      true,
    ));
  });

  describe('Initialization', () => {
    describe('Parameters', () => {
      it('stakingPeriod', async () => {
        expect(await lenderAave.stakingPeriod()).to.be.equal(BigNumber.from(DAY.toString()));
      });
      it('allowance - frax staking contract', async () => {
        expect(await aToken.allowance(lenderAave.address, aFraxStakingContract.address)).to.be.equal(
          ethers.constants.MaxUint256,
        );
      });
    });

    describe('AccessControl', () => {
      it('setLockTime - reverts nonStrategy', async () => {
        await expect(lenderAave.connect(user).setLockTime(ethers.constants.Zero)).to.be.revertedWith(guardianError);
      });
      it('setProxyBoost - reverts nonStrategy', async () => {
        await expect(lenderAave.connect(user).setProxyBoost(ethers.constants.AddressZero)).to.be.revertedWith(
          guardianError,
        );
      });
      it('changeAllowance - reverts nonStrategy', async () => {
        await expect(lenderAave.connect(user).changeAllowance(ethers.constants.Zero)).to.be.revertedWith(guardianError);
      });
    });

    describe('Permisionless functions', () => {
      it('setMinLockTime', async () => {
        const minLockTimeBefore = await lenderAave.minStakingPeriod();
        expect(minLockTimeBefore).to.be.equal(parseUnits(DAY.toString(), 0));
        await impersonate(fraxTimelock, async acc => {
          await network.provider.send('hardhat_setBalance', [
            fraxTimelock,
            utils.parseEther('1').toHexString().replace('0x0', '0x'),
          ]);
          await (
            await aFraxStakingContract
              .connect(acc)
              .setMiscVariables([
                parseUnits('1', 18),
                ethers.constants.Zero,
                ethers.constants.Zero,
                ethers.constants.Zero,
                parseUnits('100000000', 0),
                parseUnits('1', 0),
              ])
          ).wait();
        });
        await lenderAave.connect(user).setMinLockTime();
        const minLockTimeAfter = await lenderAave.minStakingPeriod();
        expect(minLockTimeAfter).to.be.equal(parseUnits('1', 0));
      });
    });

    describe('Governance functions', () => {
      it('setLockTime', async () => {
        const minLockTimeBefore = await lenderAave.minStakingPeriod();
        expect(minLockTimeBefore).to.be.equal(parseUnits(DAY.toString(), 0));
        await lenderAave.connect(guardian).setLockTime(ethers.constants.Zero);
        expect(await lenderAave.stakingPeriod()).to.be.equal(ethers.constants.Zero);
      });
      it('setProxyBoost', async () => {
        const veFXSMultiplierBefore = await aFraxStakingContract.veFXSMultiplier(lenderAave.address);
        await impersonate(fraxTimelock, async acc => {
          await network.provider.send('hardhat_setBalance', [
            fraxTimelock,
            utils.parseEther('1').toHexString().replace('0x0', '0x'),
          ]);
          await (await aFraxStakingContract.connect(acc).toggleValidVeFXSProxy(lockerStakeDAO)).wait();
        });
        await impersonate(lockerStakeDAO, async acc => {
          await network.provider.send('hardhat_setBalance', [
            lockerStakeDAO,
            utils.parseEther('1').toHexString().replace('0x0', '0x'),
          ]);
          await (await aFraxStakingContract.connect(acc).proxyToggleStaker(lenderAave.address)).wait();
        });
        await lenderAave.connect(guardian).setProxyBoost(lockerStakeDAO);
        const veFXSMultiplierAfter = await aFraxStakingContract.veFXSMultiplier(lenderAave.address);
        console.log(`multiplier before:\t${logBN(veFXSMultiplierBefore)}`);
        console.log(`multiplier after:\t${logBN(veFXSMultiplierAfter)}`);
        expect(veFXSMultiplierAfter).to.be.gt(veFXSMultiplierBefore);
      });
      it('changeAllowance', async () => {
        await lenderAave.connect(guardian).changeAllowance(ethers.constants.Zero);
        expect(await aToken.allowance(lenderAave.address, aFraxStakingContract.address)).to.be.equal(
          ethers.constants.Zero,
        );
        await lenderAave.connect(guardian).changeAllowance(ethers.constants.MaxUint256.div(BigNumber.from('2')));
        expect(await aToken.allowance(lenderAave.address, aFraxStakingContract.address)).to.be.equal(
          ethers.constants.MaxUint256.div(BigNumber.from('2')),
        );
        await lenderAave.connect(guardian).changeAllowance(ethers.constants.MaxUint256);
        expect(await aToken.allowance(lenderAave.address, aFraxStakingContract.address)).to.be.equal(
          ethers.constants.MaxUint256,
        );
      });
    });

    describe('View functions', () => {
      it('apr - no boost', async () => {
        await setTokenBalanceFor(token, strategy.address, 1000000);
        await (await strategy.connect(keeper)['harvest()']()).wait();
        const apr = await lenderAave.connect(keeper).apr();
        // at mainnet fork time there is 1.22% coming from liquidity rate, 0.05% coming from incentives
        // and 11.58% (computed by hand because apr displyed on Frax front is wrong)
        console.log(`apr computed:\t${logBN(apr)}`);
        console.log(`apr expected:\t${0.1478}`);

        expect(apr).to.be.closeTo(parseUnits('0.1285', 18), parseUnits('0.005', 18));
      });
      it('apr - with boost', async () => {
        await impersonate(fraxTimelock, async acc => {
          await network.provider.send('hardhat_setBalance', [
            fraxTimelock,
            utils.parseEther('1').toHexString().replace('0x0', '0x'),
          ]);
          await (await aFraxStakingContract.connect(acc).toggleValidVeFXSProxy(lockerStakeDAO)).wait();
        });
        await impersonate(lockerStakeDAO, async acc => {
          await network.provider.send('hardhat_setBalance', [
            lockerStakeDAO,
            utils.parseEther('1').toHexString().replace('0x0', '0x'),
          ]);
          await (await aFraxStakingContract.connect(acc).proxyToggleStaker(lenderAave.address)).wait();
        });
        const veFXSMultiplierAfter = await aFraxStakingContract.veFXSMultiplier(lenderAave.address);
        console.log(`multiplier after:\t${logBN(veFXSMultiplierAfter)}`);

        await setTokenBalanceFor(token, strategy.address, 1000000);
        await (await strategy.connect(keeper)['harvest()']()).wait();
        const apr = await lenderAave.connect(keeper).apr();
        // at mainnet fork time there is 1.22% coming from liquidity rate, 0.05% coming from incentives
        // and 11.58% (computed by hand because apr displyed on Frax front is wrong)
        console.log(`apr computed:\t${logBN(apr)}`);
        console.log(`apr expected:\t${0.1478}`);
        expect(apr).to.be.closeTo(parseUnits('0.1285', 18), parseUnits('0.005', 18));
      });
      it('aprAfterDeposit', async () => {
        const aprAfterDepositSupposed = await lenderAave
          .connect(keeper)
          .aprAfterDeposit(parseUnits('10000000', tokenDecimal));

        // Do the deposit and see if the values are indeed equals
        await setTokenBalanceFor(token, strategy.address, 10000000);
        await (await strategy.connect(keeper)['harvest()']()).wait();
        const aprReal = await lenderAave.connect(keeper).apr();

        console.log(`apr computed:\t${logBN(aprAfterDepositSupposed)}`);
        console.log(`apr expected:\t${logBN(aprReal)}`);

        expect(aprAfterDepositSupposed).to.be.closeTo(aprReal, parseUnits('0.001', 18));
      });
    });

    // describe('Strategy deposits and withdraw', () => {
    //   it('deposit -success ', async () => {
    //     await setTokenBalanceFor(token, strategy.address, 1000000);
    //     await (await strategy.connect(keeper)['harvest()']()).wait();
    //     const balanceToken = await lenderAave.nav();
    //     const balanceTokenStrat = await token.balanceOf(strategy.address);
    //     expect(balanceToken).to.be.equal(parseUnits('1000000', tokenDecimal));
    //     expect(balanceTokenStrat).to.be.equal(parseUnits('0', tokenDecimal));
    //   });
    //   it('withdrawEmergency - success', async () => {
    //     await setTokenBalanceFor(token, strategy.address, 1000000);
    //     await (await strategy.connect(keeper)['harvest()']()).wait();
    //     await (await lenderAave.connect(guardian).emergencyWithdraw(parseUnits('1000000', 18))).wait();
    //     expect(await token.balanceOf(manager.address)).to.be.equal(parseUnits('1000000', tokenDecimal));
    //   });
    //   it('withdraw - success', async () => {
    //     await setTokenBalanceFor(token, strategy.address, 1000000);
    //     await (await strategy.connect(keeper)['harvest()']()).wait();
    //     await (
    //       await manager.connect(guardian).updateStrategyDebtRatio(strategy.address, ethers.constants.AddressZero)
    //     ).wait();
    //     await (await strategy.connect(keeper)['harvest()']()).wait();
    //     const balanceToken = await lenderAave.nav();
    //     const balanceTokenStrat = await token.balanceOf(strategy.address);
    //     const balanceTokenManager = await token.balanceOf(manager.address);
    //     expect(balanceToken).to.be.equal(parseUnits('0', tokenDecimal));
    //     expect(balanceTokenStrat).to.be.equal(parseUnits('0', tokenDecimal));
    //     expect(balanceTokenManager).to.be.closeTo(
    //       parseUnits('1000000', tokenDecimal),
    //       parseUnits('0.001', tokenDecimal),
    //     );
    //   });
    // });

    // describe('Handle rewards', () => {
    //   it('claimRewards - cooldown triggered', async () => {
    //     expect(await stkAave.balanceOf(lenderAave.address)).to.equal(0);
    //     expect(await aave.balanceOf(lenderAave.address)).to.equal(0);

    //     await setTokenBalanceFor(token, strategy.address, 1000000);
    //     await (await strategy.connect(keeper)['harvest()']()).wait();

    //     await network.provider.send('evm_increaseTime', [3600 * 24 * 365]); // forward 1 year
    //     await network.provider.send('evm_mine');
    //     // start coolDown
    //     await lenderAave.connect(keeper).claimRewards();

    //     const currentBalanceStkAave = await stkAave.balanceOf(lenderAave.address);

    //     await network.provider.send('evm_increaseTime', [3600 * 24 * 10]); // forward 10 days after the cooldown finished
    //     await network.provider.send('evm_mine');

    //     // will change stkAave into Aave
    //     await lenderAave.connect(keeper).claimRewards();

    //     expect(ethers.constants.Zero).to.be.closeTo(
    //       await stkAave.balanceOf(lenderAave.address),
    //       parseUnits('0.001', tokenDecimal),
    //     );
    //     expect(currentBalanceStkAave).to.be.closeTo(
    //       await aave.balanceOf(lenderAave.address),
    //       parseUnits('0.001', tokenDecimal),
    //     );
    //   });
    //   it('claimRewards - claim too soon', async () => {
    //     expect(await stkAave.balanceOf(lenderAave.address)).to.equal(0);
    //     expect(await aave.balanceOf(lenderAave.address)).to.equal(0);

    //     await setTokenBalanceFor(token, strategy.address, 1000000);
    //     await (await strategy.connect(keeper)['harvest()']()).wait();

    //     await network.provider.send('evm_increaseTime', [3600 * 24 * 365]); // forward 1 year
    //     await network.provider.send('evm_mine');
    //     // start coolDown
    //     await lenderAave.connect(keeper).claimRewards();

    //     const currentBalanceStkAave = await stkAave.balanceOf(lenderAave.address);

    //     await network.provider.send('evm_increaseTime', [3600 * 24 * 5]); // forward 5 days before the cooldown finished
    //     await network.provider.send('evm_mine');

    //     // will change stkAave into Aave
    //     await lenderAave.connect(keeper).claimRewards();

    //     const futureBalanceStkAave = await stkAave.balanceOf(lenderAave.address);

    //     console.log(`${logBN(currentBalanceStkAave, { base: 18 })} --> ${logBN(futureBalanceStkAave, { base: 18 })}`);

    //     expect(currentBalanceStkAave.lte(futureBalanceStkAave)).to.be.equal(true);
    //     expect(ethers.constants.Zero).to.be.closeTo(
    //       await aave.balanceOf(lenderAave.address),
    //       parseUnits('0.001', tokenDecimal),
    //     );
    //   });
    // });
  });
});
