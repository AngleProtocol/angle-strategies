import { network } from 'hardhat';
import { DeployFunction } from 'hardhat-deploy/types';
import { CONTRACTS_ADDRESSES, ChainId } from '@angleprotocol/sdk';
import {
  ERC20,
  ERC20__factory,
  GenericAaveNoStaker,
  GenericAaveNoStaker__factory,
  IAaveIncentivesController,
  IStakedAave,
  IStakedAave__factory,
  OptimizerAPRStrategy,
  OptimizerAPRStrategy__factory,
} from '../../typechain';
import { impersonate } from '../../test/test-utils';
import { GenericAave, GenericAave__factory } from '@angleprotocol/sdk/dist/constants/types';
import { expect } from '../../test/test-utils/chai-setup';
import { parseUnits } from 'ethers/lib/utils';

const func: DeployFunction = async ({ deployments, ethers }) => {
  const { deployer } = await ethers.getNamedSigners();
  const collats = ['USDC', 'DAI'];

  let guardian: string;
  let governor: string;
  let strategyAddress, oldLenderAddress: string;

  for (const collat in collats) {
    const collateralName = collats[collat];
    console.log('');
    console.log('Saving for collat: ', collateralName);

    let json = (await import('../networks/mainnet.json')) as any;
    // operation only doable in fork
    if (!network.live) {
      guardian = CONTRACTS_ADDRESSES[ChainId.MAINNET].Guardian as string;
      governor = CONTRACTS_ADDRESSES[ChainId.MAINNET].GovernanceMultiSig as string;
      strategyAddress = CONTRACTS_ADDRESSES[ChainId.MAINNET].agEUR?.collaterals?.[collateralName]?.Strategies
        ?.GenericOptimisedLender as string;
      oldLenderAddress = CONTRACTS_ADDRESSES[ChainId.MAINNET].agEUR?.collaterals?.[collateralName]
        ?.GenericAave as string;
      const stkAaveAddress = json.Aave.stkAave;
      const aaveAddress = json.Aave.aave;
      const incentiveControllerAddress = '0xd784927Ff2f95ba542BfC824c8a8a98F3495f6b5';
      const aTokenAddress = json.Aave.aDAI;

      console.log(guardian);
      console.log(governor);
      console.log(strategyAddress);
      console.log(oldLenderAddress);
      console.log(stkAaveAddress);
      console.log(aaveAddress);
      console.log(incentiveControllerAddress);
      console.log(aTokenAddress);

      await network.provider.request({
        method: 'hardhat_impersonateAccount',
        params: [governor],
      });
      const governorSigner = await ethers.getSigner(governor);
      await network.provider.send('hardhat_setBalance', [governor, '0x10000000000000000000000000000']);

      const aToken = (await ethers.getContractAt(ERC20__factory.abi, aTokenAddress)) as ERC20;
      const oldLenderAave = new ethers.Contract(
        oldLenderAddress,
        GenericAave__factory.createInterface(),
        deployer,
      ) as GenericAave;

      const newLenderAddress = (await ethers.getContract(`GenericAaveNoStaker_${collateralName}`)).address;
      const newLenderAave = new ethers.Contract(
        newLenderAddress,
        GenericAaveNoStaker__factory.createInterface(),
        deployer,
      ) as GenericAaveNoStaker;

      const strategy = new ethers.Contract(
        strategyAddress,
        OptimizerAPRStrategy__factory.createInterface(),
        deployer,
      ) as OptimizerAPRStrategy;

      const stkAave = (await ethers.getContractAt(IStakedAave__factory.abi, stkAaveAddress)) as IStakedAave;
      const aave = (await ethers.getContractAt(ERC20__factory.abi, aaveAddress)) as ERC20;

      const incentiveController = new ethers.Contract(
        incentiveControllerAddress,
        [
          'function claimRewardsOnBehalf(address[] calldata assets,uint256 amount,address user,address to) external returns (uint256)',
          'function getRewardsBalance(address[] calldata assets, address user) external view returns (uint256)',
        ],
        deployer,
      ) as IAaveIncentivesController;

      const aTokenBalanceOld = await aToken.balanceOf(oldLenderAddress);
      console.log('old balnce fetched for lender ');
      await strategy.connect(governorSigner).forceRemoveLender(oldLenderAddress);
      console.log('Remove old lender: success');

      // Transfer, harvest and transfer the rewards to the new lender
      // This is done in this order to set the cooldown to 0 on the oldLender such that no Aave will be sold
      // while still being able to claim the new stkAave
      const claimableRewards = await incentiveController.getRewardsBalance([aToken.address], oldLenderAddress);
      const oldLenderStkAaveBalance = await stkAave.balanceOf(oldLenderAddress);
      const oldLenderAaveBalance = await aave.balanceOf(oldLenderAddress);
      expect(oldLenderAaveBalance).to.be.equal(parseUnits('0', 18));
      await impersonate(guardian, async acc => {
        await network.provider.send('hardhat_setBalance', [guardian, '0x10000000000000000000000000000']);
        // USDC don't have this problem because there hasn't been any harvest yet
        if (collateralName == 'DAI') {
          await (await oldLenderAave.connect(acc).sweep(stkAave.address, newLenderAddress)).wait();
          console.log('first sweep: success');
        }
        await (await oldLenderAave.connect(acc).harvest()).wait();
        console.log('lender harvest: success');
        await (await oldLenderAave.connect(acc).sweep(stkAave.address, newLenderAddress)).wait();
        console.log('second sweep: success');
      });
      const newLenderStkAaveBalance = await stkAave.balanceOf(newLenderAddress);
      expect(newLenderStkAaveBalance).to.be.closeTo(
        oldLenderStkAaveBalance.add(claimableRewards),
        parseUnits('0.01', 18),
      );

      // Harvest and verify that all funds have been transferred to the new lender
      await strategy.connect(deployer)['harvest()'];
      console.log('strategy harvest: success');
      const aTokenBalanceNew = await aToken.balanceOf(newLenderAddress);
      expect(aTokenBalanceNew).to.be.closeTo(aTokenBalanceOld, parseUnits('0.1', 18));
    }
  }
};

func.tags = ['saveFundsAave'];
export default func;
