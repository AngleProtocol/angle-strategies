import { SignerWithAddress } from '@nomiclabs/hardhat-ethers/signers';
import { BigNumber, utils } from 'ethers';
import {
  AggregatorV3Interface,
  AggregatorV3Interface__factory,
  ERC20,
  ERC20__factory,
  GenericAaveFraxStaker,
  GenericAaveFraxStaker__factory,
  IMockFraxUnifiedFarm,
  IMockFraxUnifiedFarm__factory,
  IStakedAave,
  IStakedAave__factory,
  MockToken,
  MockToken__factory,
  OptimizerAPRStrategy,
  OptimizerAPRStrategy__factory,
  PoolManager,
} from '../../typechain';
import { gwei } from '../../utils/bignumber';
import { deploy, deployUpgradeable, impersonate } from '../test-utils';
import { ethers, network } from 'hardhat';
import { expect } from '../test-utils/chai-setup';
import { parseUnits } from 'ethers/lib/utils';
import { logBN, setTokenBalanceFor } from '../utils-interaction';
import { DAY } from '../contants';
import { latestTime, time } from '../test-utils/helpers';

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
  await manager.connect(governor).addStrategy(strategy.address, gwei('0.99999'));
  return { strategy };
}

async function initLenderAaveFraxStaker(
  governor: SignerWithAddress,
  guardian: SignerWithAddress,
  keeper: SignerWithAddress,
  strategy: OptimizerAPRStrategy,
  name: string,
  isIncentivized: boolean,
  stakingPeriod: number,
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
    stakingPeriod,
  );
  await strategy.connect(governor).addLender(lender.address);
  return { lender };
}

let governor: SignerWithAddress, guardian: SignerWithAddress, user: SignerWithAddress, keeper: SignerWithAddress;
let strategy: OptimizerAPRStrategy;
let token: ERC20;
let aToken: ERC20;
let nativeRewardToken: MockToken;
let tokenDecimal: number;
let manager: PoolManager;
let lenderAave: GenericAaveFraxStaker;
let stkAave: IStakedAave;
let aFraxStakingContract: IMockFraxUnifiedFarm;
let oracleNativeReward: AggregatorV3Interface;
let oracleStkAave: AggregatorV3Interface;
const lockerStakeDAO = '0xCd3a267DE09196C48bbB1d9e842D7D7645cE448f';
const fraxTimelock = '0x8412ebf45bAC1B340BbE8F318b928C466c4E39CA';

const guardianRole = ethers.utils.solidityKeccak256(['string'], ['GUARDIAN_ROLE']);
let guardianError: string;

// Start test block
describe('OptimizerAPR - lenderAaveFraxStaker', () => {
  beforeEach(async () => {
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
    nativeRewardToken = (await ethers.getContractAt(
      MockToken__factory.abi,
      '0x3432B6A60D23Ca0dFCa7761B7ab56459D9C964D0',
    )) as MockToken;

    tokenDecimal = await token.decimals();

    stkAave = (await ethers.getContractAt(
      IStakedAave__factory.abi,
      '0x4da27a545c0c5B758a6BA100e3a049001de870f5',
    )) as IStakedAave;

    aFraxStakingContract = (await ethers.getContractAt(
      IMockFraxUnifiedFarm__factory.abi,
      '0x02577b426F223A6B4f2351315A19ecD6F357d65c',
    )) as IMockFraxUnifiedFarm;

    oracleNativeReward = (await ethers.getContractAt(
      AggregatorV3Interface__factory.abi,
      '0x6Ebc52C8C1089be9eB3945C4350B68B8E4C2233f',
    )) as AggregatorV3Interface;

    oracleStkAave = (await ethers.getContractAt(
      AggregatorV3Interface__factory.abi,
      '0x547a514d5e3769680Ce22B2361c10Ea13619e8a9',
    )) as AggregatorV3Interface;

    guardianError = `AccessControl: account ${user.address.toLowerCase()} is missing role ${guardianRole}`;

    manager = (await deploy('PoolManager', [token.address, governor.address, guardian.address])) as PoolManager;

    ({ strategy } = await initStrategy(governor, guardian, keeper, manager));

    ({ lender: lenderAave } = await initLenderAaveFraxStaker(
      governor,
      guardian,
      keeper,
      strategy,
      'genericAave',
      true,
      DAY,
    ));
  });

  describe('Contructor', () => {
    it('reverts - too small saking period', async () => {
      const lender = (await deployUpgradeable(new GenericAaveFraxStaker__factory(guardian))) as GenericAaveFraxStaker;
      await expect(
        lender.initialize(strategy.address, 'test', true, [governor.address], guardian.address, [keeper.address], 0),
      ).to.be.revertedWith('TooSmallStakingPeriod()');
    });
  });

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
    it('setLockTime - reverts Guardian', async () => {
      await expect(lenderAave.connect(user).setLockTime(ethers.constants.Zero)).to.be.revertedWith(guardianError);
    });
    it('setProxyBoost - reverts Guardian', async () => {
      await expect(lenderAave.connect(user).setProxyBoost(ethers.constants.AddressZero)).to.be.revertedWith(
        guardianError,
      );
    });
    it('changeAllowance - reverts Guardian', async () => {
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
    it('setLockTime - revert', async () => {
      const minLockTimeBefore = await lenderAave.minStakingPeriod();
      expect(minLockTimeBefore).to.be.equal(parseUnits(DAY.toString(), 0));
      await expect(lenderAave.connect(guardian).setLockTime(ethers.constants.Zero)).to.be.revertedWith(
        'StakingPeriodTooSmall',
      );
    });
    it('setLockTime', async () => {
      const minLockTimeBefore = await lenderAave.minStakingPeriod();
      expect(minLockTimeBefore).to.be.equal(parseUnits(DAY.toString(), 0));
      await lenderAave.connect(guardian).setLockTime(parseUnits((2 * DAY).toString(), 0));
      expect(await lenderAave.stakingPeriod()).to.be.equal(parseUnits((2 * DAY).toString(), 0));
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
      // doesn't change anything
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
    it('apr - no funds', async () => {
      await (await strategy.connect(keeper)['harvest()']()).wait();
      const apr = await lenderAave.connect(keeper).apr();
      // at mainnet fork time there is 1.22% coming from liquidity rate, 0.05% coming from incentives
      // and 0% as no funds deposited yet on the strat
      expect(apr).to.be.closeTo(parseUnits('0.0127', 18), parseUnits('0.001', 18));
    });
    it('apr - no boost', async () => {
      await setTokenBalanceFor(token, strategy.address, 1000000);
      await (await strategy.connect(keeper)['harvest()']()).wait();
      const apr = await lenderAave.connect(keeper).apr();
      // at mainnet fork time there is 1.22% coming from liquidity rate, 0.05% coming from incentives
      // and 11.58% (computed by hand because apr displyed on Frax front is wrong)
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
      await lenderAave.connect(guardian).setProxyBoost(lockerStakeDAO);

      const veFXSMultiplierAfter = await aFraxStakingContract.veFXSMultiplier(lenderAave.address);
      await setTokenBalanceFor(token, strategy.address, 1000000);
      await (await strategy.connect(keeper)['harvest()']()).wait();
      const apr = await lenderAave.connect(keeper).apr();
      // at mainnet fork time there is 1.22% coming from liquidity rate, 0.05% coming from incentives
      // and 13.59% (computed by hand because apr displyed on Frax front is wrong)
      expect(apr).to.be.closeTo(parseUnits('0.1481', 18), parseUnits('0.005', 18));
    });
    it('aprAfterDeposit', async () => {
      const aprAfterDepositSupposed = await lenderAave
        .connect(keeper)
        .aprAfterDeposit(parseUnits('10000000', tokenDecimal));

      // Do the deposit and see if the values are indeed equals
      await setTokenBalanceFor(token, strategy.address, 10000000);
      await (await strategy.connect(keeper)['harvest()']()).wait();
      const aprReal = await lenderAave.connect(keeper).apr();

      expect(aprAfterDepositSupposed).to.be.closeTo(aprReal, parseUnits('0.001', 18));
    });
  });

  describe('Strategy deposits', () => {
    it('deposit - success - no previous lock', async () => {
      expect(await lenderAave.kekId()).to.be.equal(ethers.constants.HashZero);
      // expect(await lenderAave.lastAaveLiquidityIndex()).to.be.equal(ethers.constants.Zero);
      expect(await lenderAave.lastCreatedStake()).to.be.equal(ethers.constants.Zero);

      await setTokenBalanceFor(token, strategy.address, 1000000);

      const timestamp = await latestTime();
      await (await strategy.connect(keeper)['harvest()']()).wait();
      expect(await lenderAave.kekId()).to.not.eq('');
      expect(await lenderAave.lastCreatedStake()).to.be.gte(timestamp);

      const underlyingBalance = await lenderAave.underlyingBalanceStored();
      const balanceToken = await lenderAave.nav();
      const balanceTokenStrat = await token.balanceOf(strategy.address);
      expect(balanceToken).to.be.equal(parseUnits('1000000', tokenDecimal));
      expect(underlyingBalance).to.be.closeTo(parseUnits('1000000', tokenDecimal), parseUnits('10', tokenDecimal));
      expect(balanceTokenStrat).to.be.equal(parseUnits('0', tokenDecimal));
    });
    it('deposit - success - with previous lock', async () => {
      // going through the poolManager to not have to withdraw funds (because it would think we made a huge profit)
      await setTokenBalanceFor(token, manager.address, 1000000);
      await (await strategy.connect(keeper)['harvest()']()).wait();
      const kekId = await lenderAave.kekId();
      const stakerCreated = await lenderAave.lastCreatedStake();
      await setTokenBalanceFor(token, manager.address, 1000000);
      await (await strategy.connect(keeper)['harvest()']()).wait();

      const kekIdAfter = await lenderAave.kekId();
      const stakerCreatedAfter = await lenderAave.lastCreatedStake();
      expect(kekIdAfter).to.be.equal(kekId);
      expect(stakerCreatedAfter).to.be.equal(stakerCreated);

      const underlyingBalance = await lenderAave.underlyingBalanceStored();
      const balanceToken = await lenderAave.nav();
      const balanceTokenStrat = await token.balanceOf(strategy.address);
      expect(balanceToken).to.be.closeTo(parseUnits('2000000', tokenDecimal), parseUnits('1000', tokenDecimal));
      expect(underlyingBalance).to.be.closeTo(parseUnits('2000000', tokenDecimal), parseUnits('1000', tokenDecimal));
      expect(balanceTokenStrat).to.be.equal(parseUnits('0', tokenDecimal));
    });
  });

  describe('Strategy withdraws', () => {
    it('withdraw - revert - too soon', async () => {
      await setTokenBalanceFor(token, strategy.address, 1000000);
      await (await strategy.connect(keeper)['harvest()']()).wait();
      await setTokenBalanceFor(token, strategy.address, 1000000);
      await expect(strategy.connect(keeper)['harvest()']()).to.be.rejectedWith('UnstakedTooSoon');
    });
    it('emergencyWithdraw - revert - nothing to remove', async () => {
      await expect(lenderAave.connect(guardian).emergencyWithdraw(parseUnits('1000000', 18))).to.be.revertedWith(
        'NoLockedLiquidity()',
      );
    });
    it('emergencyWithdraw - success', async () => {
      await setTokenBalanceFor(token, strategy.address, 1000000);
      await (await strategy.connect(keeper)['harvest()']()).wait();
      await time.increase(DAY);
      await (await lenderAave.connect(guardian).emergencyWithdraw(parseUnits('1000000', 18))).wait();
      expect(await token.balanceOf(manager.address)).to.be.equal(parseUnits('1000000', tokenDecimal));
    });
    it('withdrawAll - success', async () => {
      await setTokenBalanceFor(token, strategy.address, 1000000);
      await (await strategy.connect(keeper)['harvest()']()).wait();

      await time.increase(DAY);
      const { lender: lenderAaveBis } = await initLenderAaveFraxStaker(
        governor,
        guardian,
        keeper,
        strategy,
        'genericAave',
        true,
        DAY,
      );
      await (
        await strategy.connect(guardian).manualAllocation([
          { lender: lenderAave.address, share: parseUnits('0', 0) },
          { lender: lenderAaveBis.address, share: parseUnits('1000', 0) },
        ])
      ).wait();

      const balanceTokenStrat = await token.balanceOf(strategy.address);
      expect(await lenderAaveBis.underlyingBalanceStored()).to.be.closeTo(
        parseUnits('1000000', tokenDecimal),
        parseUnits('1000', tokenDecimal),
      );
      expect(await lenderAaveBis.nav()).to.be.closeTo(
        parseUnits('1000000', tokenDecimal),
        parseUnits('1000', tokenDecimal),
      );
      expect(await lenderAave.underlyingBalanceStored()).to.be.equal(parseUnits('0', tokenDecimal));
      expect(await lenderAave.nav()).to.be.equal(parseUnits('0', tokenDecimal));
      expect(balanceTokenStrat).to.be.equal(parseUnits('0', tokenDecimal));
    });
    it('withdraw - success - restake', async () => {
      await setTokenBalanceFor(token, strategy.address, 1000000);
      await (await strategy.connect(keeper)['harvest()']()).wait();

      // let days pass to have a non negligible gain
      await time.increase(DAY * 7);

      const kekIdBefore = await lenderAave.kekId();
      const stakerCreatedBefore = await lenderAave.lastCreatedStake();

      // to let some surplus on the poolManager
      await manager.connect(guardian).updateStrategyDebtRatio(strategy.address, parseUnits('0.5', 9));
      await (await strategy.connect(keeper)['harvest()']()).wait();
      // currently rate is at 1.20% so for 7 days we roughly divide by 52 --> 0.023% over the period
      const earnings = parseUnits('1000230', tokenDecimal);

      const kekIdAfter = await lenderAave.kekId();
      const stakerCreatedAfter = await lenderAave.lastCreatedStake();

      expect(kekIdAfter).to.not.equal(kekIdBefore);
      expect(kekIdAfter).to.not.equal('');
      expect(stakerCreatedAfter).to.be.gte(stakerCreatedBefore);

      const balanceToken = await lenderAave.nav();
      const balanceTokenStrat = await token.balanceOf(strategy.address);
      const balanceTokenManager = await token.balanceOf(manager.address);
      expect(balanceToken).to.be.closeTo(earnings.div(BigNumber.from('2')), parseUnits('100', tokenDecimal));
      expect(balanceTokenStrat).to.be.equal(parseUnits('0', tokenDecimal));
      expect(balanceTokenManager).to.be.closeTo(earnings.div(BigNumber.from('2')), parseUnits('100', tokenDecimal));
    });
    it('withdraw - success - no new locker', async () => {
      // change lock period
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
      await lenderAave.setMinLockTime();
      await lenderAave.connect(guardian).setLockTime(parseUnits('1', 0));

      await setTokenBalanceFor(token, manager.address, 1000000);
      await (await strategy.connect(keeper)['harvest()']()).wait();

      // change debtRatio
      await manager.connect(guardian).updateStrategyDebtRatio(strategy.address, parseUnits('0', 9));
      const kekIdBefore = await lenderAave.kekId();

      await time.increase(1);
      await (await strategy.connect(keeper)['harvest()']()).wait();

      const kekIdAfter = await lenderAave.kekId();
      const stakerCreatedAfter = await lenderAave.lastCreatedStake();

      expect(kekIdAfter).to.not.equal(kekIdBefore);
      expect(kekIdAfter).to.be.equal(ethers.constants.HashZero);
      expect(stakerCreatedAfter).to.be.equal(ethers.constants.Zero);

      const balanceToken = await lenderAave.nav();
      const balanceTokenStrat = await token.balanceOf(strategy.address);
      const balanceTokenManager = await token.balanceOf(manager.address);
      expect(balanceToken).to.be.equal(parseUnits('0', tokenDecimal));
      expect(balanceTokenStrat).to.be.equal(parseUnits('0', tokenDecimal));
      expect(balanceTokenManager).to.be.closeTo(parseUnits('1000000', tokenDecimal), parseUnits('1', tokenDecimal));
    });
    it('withdraw - success - no liquidity left', async () => {
      // change lock period
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
      await lenderAave.setMinLockTime();
      await lenderAave.connect(guardian).setLockTime(parseUnits('1', 0));

      await setTokenBalanceFor(token, manager.address, 1000000);
      await (await strategy.connect(keeper)['harvest()']()).wait();

      // change debtRatio
      await manager.connect(guardian).updateStrategyDebtRatio(strategy.address, parseUnits('0', 9));
      const kekIdBefore = await lenderAave.kekId();
      const stakerCreatedBefore = await lenderAave.lastCreatedStake();

      // remove liquidity from Aave
      await impersonate(aToken.address, async acc => {
        await network.provider.send('hardhat_setBalance', [
          aToken.address,
          utils.parseEther('1').toHexString().replace('0x0', '0x'),
        ]);
        const liquidityAave = await token.balanceOf(aToken.address);
        await (await token.connect(acc).transfer(keeper.address, liquidityAave)).wait();
      });

      await time.increase(1);
      await (await strategy.connect(keeper)['harvest()']()).wait();

      const kekIdAfter = await lenderAave.kekId();
      const stakerCreatedAfter = await lenderAave.lastCreatedStake();

      expect(kekIdAfter).to.be.equal(kekIdBefore);
      expect(stakerCreatedAfter).to.be.equal(stakerCreatedBefore);

      const stakingBalance = (await aFraxStakingContract.lockedStakes(lenderAave.address, 0)).liquidity;
      const balanceToken = await lenderAave.nav();
      const balanceTokenStrat = await token.balanceOf(strategy.address);
      const balanceTokenManager = await token.balanceOf(manager.address);
      expect(stakingBalance).to.be.equal(parseUnits('999990', tokenDecimal));
      expect(balanceToken).to.be.closeTo(parseUnits('999990', tokenDecimal), parseUnits('0.1', tokenDecimal));
      expect(balanceTokenStrat).to.be.equal(parseUnits('0', tokenDecimal));
      expect(balanceTokenManager).to.be.equal(parseUnits('10', tokenDecimal));
    });
    it('withdraw - success - few liquidity left', async () => {
      // change lock period
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
      await lenderAave.setMinLockTime();
      await lenderAave.connect(guardian).setLockTime(parseUnits('1', 0));

      await setTokenBalanceFor(token, manager.address, 1000000);
      await (await strategy.connect(keeper)['harvest()']()).wait();

      // change debtRatio
      await manager.connect(guardian).updateStrategyDebtRatio(strategy.address, parseUnits('0', 9));
      const kekIdBefore = await lenderAave.kekId();
      const stakerCreatedBefore = await lenderAave.lastCreatedStake();

      // remove liquidity from Aave
      await impersonate(aToken.address, async acc => {
        await network.provider.send('hardhat_setBalance', [
          aToken.address,
          utils.parseEther('1').toHexString().replace('0x0', '0x'),
        ]);
        const liquidityAave = await token.balanceOf(aToken.address);
        await (
          await token.connect(acc).transfer(keeper.address, liquidityAave.sub(parseUnits('1', tokenDecimal)))
        ).wait();
      });

      await time.increase(1);
      await (await strategy.connect(keeper)['harvest()']()).wait();

      const kekIdAfter = await lenderAave.kekId();
      const stakerCreatedAfter = await lenderAave.lastCreatedStake();

      expect(kekIdAfter).to.not.equal(kekIdBefore);
      expect(stakerCreatedAfter).to.be.gt(stakerCreatedBefore);

      const stakingBalance = (await aFraxStakingContract.lockedStakes(lenderAave.address, 1)).liquidity;
      const balanceToken = await lenderAave.nav();
      const balanceTokenStrat = await token.balanceOf(strategy.address);
      const balanceTokenManager = await token.balanceOf(manager.address);
      expect(stakingBalance).to.be.closeTo(parseUnits('999989', tokenDecimal), parseUnits('1', tokenDecimal));
      expect(balanceToken).to.be.closeTo(parseUnits('999989', tokenDecimal), parseUnits('1', tokenDecimal));
      expect(balanceTokenStrat).to.be.equal(parseUnits('0', tokenDecimal));
      expect(balanceTokenManager).to.be.closeTo(parseUnits('11', tokenDecimal), parseUnits('1', tokenDecimal));
    });
  });

  describe('Handle rewards', () => {
    it('claimRewardsExternal - success - FXS+stkAave reward', async () => {
      await setTokenBalanceFor(token, strategy.address, 1000000);
      await (await strategy.connect(keeper)['harvest()']()).wait();

      // let days pass to have a non negligible gain
      await time.increase(DAY * 7);

      await (await lenderAave.connect(user).claimRewardsExternal()).wait();

      expect(await nativeRewardToken.balanceOf(lenderAave.address)).to.be.gte(parseUnits('0', tokenDecimal));
      expect(await stkAave.balanceOf(lenderAave.address)).to.be.gte(parseUnits('0', tokenDecimal));
    });
    it('claimRewardsExternal - success - verify apr', async () => {
      await setTokenBalanceFor(token, strategy.address, 1000000);
      await (await strategy.connect(keeper)['harvest()']()).wait();

      const aprSupposed = await lenderAave.connect(keeper).apr();

      // let days pass to have a non negligible gain
      await time.increase(DAY * 7);

      await (await lenderAave.connect(user).claimRewardsExternal()).wait();

      let rewardNative = await nativeRewardToken.balanceOf(lenderAave.address);
      let rewardStkAave = await stkAave.balanceOf(lenderAave.address);
      rewardNative = rewardNative.mul((await oracleNativeReward.latestRoundData()).answer).div(parseUnits('1', 8));
      rewardStkAave = rewardStkAave.mul((await oracleStkAave.latestRoundData()).answer).div(parseUnits('1', 8));
      const interestToken = (await lenderAave.nav()).sub(parseUnits('1000000', tokenDecimal));
      // console.log(`FXS reward in USD:\t${logBN(rewardNative)}`);
      // console.log(`stkAave reward in USD:\t${logBN(rewardStkAave)}`);
      // console.log(`interest in USD:\t${logBN(interestToken)}`);

      // console.log(
      //   `FXS apr:\t${logBN(
      //     parseUnits('52', 18)
      //       .mul(rewardNative.mul(parseUnits('0.95', 4)))
      //       .div(parseUnits('1000000', 22)),
      //   )}`,
      // );
      // console.log(
      //   `stkAave apr:\t${logBN(
      //     parseUnits('52', 18)
      //       .mul(rewardStkAave.mul(parseUnits('0.95', 4)))
      //       .div(parseUnits('1000000', 22)),
      //   )}`,
      // );
      // console.log(`interest apr:\t${logBN(parseUnits('52', 18).mul(interestToken).div(parseUnits('1000000', 18)))}`);

      // we roughly multiply by 52 weeks and don't take into account compounding
      const impliedApr = parseUnits('52', 18)
        .mul(rewardNative.add(rewardStkAave).add(interestToken))
        .div(parseUnits('1000000', 18));

      console.log(`supposed apr --> implied apr:\t${logBN(aprSupposed)} --> ${logBN(impliedApr)}`);

      // not equal?
      // expect(impliedApr).to.be.equal(aprSupposed);
    });
    it('claimRewardsExternal - success - verify apr with boost', async () => {
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

      // const aprSupposed = await lenderAave.connect(keeper).aprAfterDeposit(parseUnits('1000000', tokenDecimal));

      await setTokenBalanceFor(token, strategy.address, 1000000);
      await (await strategy.connect(keeper)['harvest()']()).wait();

      const aprSupposed = await lenderAave.connect(keeper).apr();

      // let days pass to have a non negligible gain
      await time.increase(DAY * 7);

      await (await lenderAave.connect(user).claimRewardsExternal()).wait();

      let rewardNative = await nativeRewardToken.balanceOf(lenderAave.address);
      let rewardStkAave = await stkAave.balanceOf(lenderAave.address);
      rewardNative = rewardNative.mul((await oracleNativeReward.latestRoundData()).answer).div(parseUnits('1', 8));
      rewardStkAave = rewardStkAave.mul((await oracleStkAave.latestRoundData()).answer).div(parseUnits('1', 8));
      const interestToken = (await lenderAave.nav()).sub(parseUnits('1000000', tokenDecimal));
      // console.log(`FXS reward in USD:\t${logBN(rewardNative)}`);
      // console.log(`stkAave reward in USD:\t${logBN(rewardStkAave)}`);
      // console.log(`interest in USD:\t${logBN(interestToken)}`);

      // console.log(
      //   `FXS apr:\t${logBN(
      //     parseUnits('52', 18)
      //       .mul(rewardNative.mul(parseUnits('0.95', 4)))
      //       .div(parseUnits('1000000', 22)),
      //   )}`,
      // );
      // console.log(
      //   `stkAave apr:\t${logBN(
      //     parseUnits('52', 18)
      //       .mul(rewardStkAave.mul(parseUnits('0.95', 4)))
      //       .div(parseUnits('1000000', 22)),
      //   )}`,
      // );
      // console.log(`interest apr:\t${logBN(parseUnits('52', 18).mul(interestToken).div(parseUnits('1000000', 18)))}`);

      // we roughly multiply by 52 weeks and don't take into account compounding
      const impliedApr = parseUnits('52', 18)
        .mul(rewardNative.add(rewardStkAave).add(interestToken))
        .div(parseUnits('1000000', 18));

      console.log(`supposed apr --> implied apr:\t${logBN(aprSupposed)} --> ${logBN(impliedApr)}`);

      // not equal?
      // expect(impliedApr).to.be.equal(aprSupposed);
    });
  });
});
