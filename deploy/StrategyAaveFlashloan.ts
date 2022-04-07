import { DeployFunction } from 'hardhat-deploy/types';
import { CONTRACTS_ADDRESSES, Interfaces } from '@angleprotocol/sdk';
import { Contract, utils } from 'ethers';
import { AaveFlashloanStrategy__factory, PoolManager } from '../typechain';
import { impersonate } from '../test/test-utils';
import { network } from 'hardhat';

const func: DeployFunction = async ({ deployments, ethers }) => {
  const { deploy } = deployments;
  const [deployer] = await ethers.getSigners();

  const governor = CONTRACTS_ADDRESSES[1].GovernanceMultiSig as string;
  const guardian = CONTRACTS_ADDRESSES[1].Guardian as string;

  // const keeper = '0xC2ad4f9799Dc7Cbc88958d1165bC43507664f3E0';
  const keeper = '0xcC617C6f9725eACC993ac626C7efC6B96476916E';

  const flashMintLib = await deploy('FlashMintLib', {
    contract: 'FlashMintLib',
    from: deployer.address,
  });

  const poolManager = new Contract(
    CONTRACTS_ADDRESSES[1].agEUR.collaterals!.USDC.PoolManager as string,
    Interfaces.PoolManager_Interface,
  ) as PoolManager;

  // const strategy = await deploy('AaveFlashloanStrategy', {
  //   contract: 'AaveFlashloanStrategy',
  //   from: deployer.address,
  //   proxy: {
  //     owner: deployer.address,
  //     proxyContract: 'TransparentUpgradeableProxy',
  //     viaAdminContract: 'ProxyAdmin',
  //     execute: {
  //       methodName: 'initialize',
  //       args: [poolManager.address,
  //         governor,
  //         guardian,
  //         [keeper],
  //         computeProfitabilityContract.address,],
  //     },
  //   },
  //   args: [],
  // });

  const strategyImplementation = await deploy('AaveFlashloanStrategy', {
    contract: 'AaveFlashloanStrategy',
    from: deployer.address,
    args: [],
    libraries: { FlashMintLib: flashMintLib.address },
  });

  const initializeData = AaveFlashloanStrategy__factory.createInterface().encodeFunctionData('initialize', [
    poolManager.address,
    '0x8Cae0596bC1eD42dc3F04c4506cfe442b3E74e27',
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
  console.log('Deploy cost', proxy.receipt?.gasUsed);

  // const strategy = new Contract(proxy.address, ['function harvest() external'], deployer);
  // const oldStrategy = new Contract(
  //   '0x5fE0E497Ac676d8bA78598FC8016EBC1E6cE14a3',
  //   ['function harvest() external'],
  //   deployer,
  // );

  // // CHANGE DEBT RATIOS
  // await impersonate('0xdC4e6DFe07EFCa50a197DF15D9200883eF4Eb1c8', async _governor => {
  //   await network.provider.send('hardhat_setBalance', [_governor.address, '0x8ac7230489e80000']);
  //   await poolManager.connect(_governor).updateStrategyDebtRatio(oldStrategy.address, utils.parseUnits('0', 9));
  //   await poolManager.connect(_governor).addStrategy(strategy.address, utils.parseUnits('0.95', 9));
  // });

  // await oldStrategy.harvest();
  // await strategy.harvest();
};

func.tags = ['aave_flashloan_strategy'];
export default func;
