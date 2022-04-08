import { DeployFunction } from 'hardhat-deploy/types';
import { CONTRACTS_ADDRESSES, Interfaces } from '@angleprotocol/sdk';
import { BigNumber, Contract } from 'ethers';
import { AaveFlashloanStrategy__factory, PoolManager } from '../typechain';

const func: DeployFunction = async ({ deployments, ethers }) => {
  const { deploy } = deployments;
  const [deployer] = await ethers.getSigners();

  const governor = CONTRACTS_ADDRESSES[1].GovernanceMultiSig as string;
  const guardian = CONTRACTS_ADDRESSES[1].Guardian as string;

  const keeper = '0xcC617C6f9725eACC993ac626C7efC6B96476916E';

  const poolManager = new Contract(
    CONTRACTS_ADDRESSES[1].agEUR.collaterals!.DAI.PoolManager as string,
    Interfaces.PoolManager_Interface,
  ) as PoolManager;

  const strategyImplementation = await deploy('AaveFlashloanStrategy', {
    contract: 'AaveFlashloanStrategy',
    from: deployer.address,
    args: [],
    libraries: { FlashMintLib: '0x169487a55dE79476125A56B07C36cA8dbF37a373' },
  });

  console.log('success: deployed strategy implementation', strategyImplementation.address);

  const initializeData = AaveFlashloanStrategy__factory.createInterface().encodeFunctionData('initialize', [
    poolManager.address,
    '0xfffE32106A68aA3eD39CcCE673B646423EEaB62a',
    governor,
    guardian,
    [keeper],
  ]);

  const proxyAdmin = '0x1D941EF0D3Bba4ad67DBfBCeE5262F4CEE53A32b';
  const proxy = await deploy('TransparentUpgradeableProxy', {
    contract: 'TransparentUpgradeableProxy',
    from: deployer.address,
    args: [strategyImplementation.address, proxyAdmin, initializeData],
  });

  console.log('Implementation deployed at address: ', strategyImplementation.address);
  console.log('Strategy (proxy) successfully deployed at address: ', proxy.address);
  console.log(
    'Deploy cost',
    (strategyImplementation.receipt?.gasUsed as BigNumber)?.add(proxy.receipt?.gasUsed as BigNumber)?.toString(),
  );
};

func.tags = ['aave_flashloan_strategy_dai'];
export default func;
