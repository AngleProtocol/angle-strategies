import { network } from 'hardhat';
import yargs from 'yargs';
import { DeployFunction } from 'hardhat-deploy/types';
import { CONTRACTS_ADDRESSES, ChainId, Interfaces } from '@angleprotocol/sdk';
import { BigNumber, Contract } from 'ethers';
import { PoolManager, StETHStrategy__factory } from '../typechain';
import { parseUnits } from 'ethers/lib/utils';

const func: DeployFunction = async ({ deployments, ethers }) => {
  const { deploy } = deployments;
  const { deployer } = await ethers.getNamedSigners();
  const collats = ['WETH'];

  let guardian: string;
  let ANGLE: string;
  let governor: string;
  let proxyAdmin: string;
  let json = await import('./networks/' + network.name + '.json');

  // if fork we suppose that we are in mainnet
  if (!network.live) {
    guardian = CONTRACTS_ADDRESSES[ChainId.MAINNET].Guardian!;
    ANGLE = CONTRACTS_ADDRESSES[ChainId.MAINNET].ANGLE!;
    governor = CONTRACTS_ADDRESSES[ChainId.MAINNET].GovernanceMultiSig! as string;
    proxyAdmin = CONTRACTS_ADDRESSES[ChainId.MAINNET].ProxyAdmin! as string;
    json = await import('./networks/mainnet.json');
  } else {
    guardian = CONTRACTS_ADDRESSES[network.config.chainId as ChainId].Guardian!;
    ANGLE = CONTRACTS_ADDRESSES[network.config.chainId as ChainId].ANGLE!;
    governor = CONTRACTS_ADDRESSES[network.config.chainId as ChainId].GovernanceMultiSig! as string;
    proxyAdmin = CONTRACTS_ADDRESSES[network.config.chainId as ChainId].ProxyAdmin! as string;
  }

  let strategyImplementation = await deployments.getOrNull('StETHStrategy_Implementation');

  if (!strategyImplementation) {
    strategyImplementation = await deploy('StETHStrategy_Implementation', {
      contract: 'StETHStrategy',
      from: deployer.address,
      args: [],
    });
    console.log('success: deployed strategy implementation', strategyImplementation.address);
  } else {
    console.log('strategy implementation already deployed: ', strategyImplementation.address);
  }

  for (const collat in collats) {
    let poolManager: PoolManager;
    // if fork we suppose that we are in mainnet
    if (!network.live) {
      // in this specific case the poolManager is not already deploy we need to hardcode the address
      // CONTRACTS_ADDRESSES[ChainId.MAINNET].agEUR.collaterals![collat].PoolManager as string;
      poolManager = new Contract('', Interfaces.PoolManager_Interface) as PoolManager;
    } else {
      poolManager = new Contract(
        CONTRACTS_ADDRESSES[network.config.chainId as ChainId].agEUR.collaterals![collat].PoolManager as string,
        Interfaces.PoolManager_Interface,
      ) as PoolManager;
    }
    console.log(`collat: ${collat}, poolManager: ${poolManager.address}`);

    const curvePool = json.Curve.StableSwapStETHnETH;
    const wETH = json.wETH;
    const stETH = json.stETH;
    console.log(`Needed addresses \n: Curve pool:${curvePool} \n wETH:${wETH} \n stETH:${stETH} \n`);

    const initializeData = StETHStrategy__factory.createInterface().encodeFunctionData('initialize', [
      poolManager.address,
      governor,
      guardian,
      [],
      curvePool,
      wETH,
      stETH,
      parseUnits('4', 9),
    ]);

    const proxy = await deploy(`StETHStrategy`, {
      contract: 'TransparentUpgradeableProxy',
      from: deployer.address,
      args: [strategyImplementation.address, proxyAdmin, initializeData],
    });

    console.log('Implementation deployed at address: ', strategyImplementation.address);
    console.log(`Strategy StETH (proxy) successfully deployed at address: `, proxy.address);
    console.log(
      `Deploy cost: ${(strategyImplementation.receipt?.gasUsed as BigNumber)?.toString()} (implem) + ${(
        proxy.receipt?.gasUsed as BigNumber
      )?.toString()} (proxy)`,
    );
  }
};

func.tags = ['collat_strategyStETH'];
// func.dependencies = ['collat'];
export default func;
