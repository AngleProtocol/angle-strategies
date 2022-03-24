import { DeployFunction } from 'hardhat-deploy/types';
import { CONTRACTS_ADDRESSES, Interfaces } from '@angleprotocol/sdk';
import { Contract, utils } from 'ethers';
import { AaveFlashloanStrategy__factory, AaveFlashloanStrategy, PoolManager } from '../typechain';

const func: DeployFunction = async ({ deployments, ethers }) => {
  const { deploy } = deployments;
  const [deployer] = await ethers.getSigners();

  const governor = CONTRACTS_ADDRESSES[1].GovernanceMultiSig as string;
  const guardian = CONTRACTS_ADDRESSES[1].Guardian as string;
  const keeper = '';

  const flashMintLib = await deploy('FlashMintLib', {
    contract: 'FlashMintLib',
    from: deployer.address,
  });
  const computeProfitabilityContract = await deploy('ComputeProfitability', {
    contract: 'ComputeProfitability',
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
    governor,
    guardian,
    [keeper],
    computeProfitabilityContract.address,
  ]);

  const proxyAdmin = '';
  const proxy = await deploy('TransparentUpgradeableProxy', {
    contract: 'TransparentUpgradeableProxy',
    from: deployer.address,
    args: [strategyImplementation.address, proxyAdmin, initializeData],
  });

  console.log('Implementation deployed at address: ', strategyImplementation.address);
  console.log('Strategy (proxy) successfully deployed at address: ', proxy.address);

  // CHANGE DEBT RATIOS
  const oldStrategy = '0x5fE0E497Ac676d8bA78598FC8016EBC1E6cE14a3';

  poolManager.updateStrategyDebtRatio(oldStrategy, utils.parseUnits('0.8', 9));
  poolManager.addStrategy(proxy.address, utils.parseUnits('0.1', 9));
};

func.tags = ['aave_flashloan_strategy'];
export default func;
