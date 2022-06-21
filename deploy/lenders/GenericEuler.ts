import { network } from 'hardhat';
import { DeployFunction } from 'hardhat-deploy/types';
import { CONTRACTS_ADDRESSES, ChainId } from '@angleprotocol/sdk';
import { BigNumber } from 'ethers';
import { GenericEuler__factory, OptimizerAPRStrategy, OptimizerAPRStrategy__factory } from '../../typechain';
import { impersonate } from '../../test/test-utils';

const func: DeployFunction = async ({ deployments, ethers }) => {
  const { deploy } = deployments;
  const { deployer, keeper: fakeKeeper } = await ethers.getNamedSigners();
  const stableName = 'agEUR';
  const collats = ['USDC', 'DAI'];

  let guardian: string;
  let governor: string;
  let strategyAddress, proxyAdminAddress: string;
  let keepers: string[];

  // if fork we suppose that we are in mainnet
  // eslint-disable-next-line
  let json = (await import('../networks/mainnet.json')) as any;
  if (!network.live) {
    guardian = CONTRACTS_ADDRESSES[ChainId.MAINNET].Guardian as string;
    governor = CONTRACTS_ADDRESSES[ChainId.MAINNET].GovernanceMultiSig as string;
    proxyAdminAddress = CONTRACTS_ADDRESSES[ChainId.MAINNET].ProxyAdmin as string;

    keepers = [
      '0xcC617C6f9725eACC993ac626C7efC6B96476916E',
      CONTRACTS_ADDRESSES[ChainId.MAINNET].KeeperMulticall as string,
    ];
  } else {
    guardian = CONTRACTS_ADDRESSES[network.config.chainId as ChainId].Guardian!;
    governor = CONTRACTS_ADDRESSES[network.config.chainId as ChainId].GovernanceMultiSig as string;
    proxyAdminAddress = CONTRACTS_ADDRESSES[network.config.chainId as ChainId].ProxyAdmin as string;
    keepers = [fakeKeeper.address];
  }

  const lenderImplementationAddress = (await ethers.getContract(`GenericEuler_Implementation`)).address;
  console.log('deployed lender Euler implementation', lenderImplementationAddress);
  console.log('');

  for (const collat in collats) {
    const collateralName = collats[collat];
    console.log('');
    console.log('Handling collat: ', collateralName);
    if (!network.live) {
      strategyAddress = CONTRACTS_ADDRESSES[ChainId.MAINNET].agEUR?.collaterals?.[collateralName]?.Strategies
        ?.GenericOptimisedLender.Contract as string;
    } else {
      strategyAddress = CONTRACTS_ADDRESSES[network.config.chainId as ChainId].agEUR?.collaterals?.[collateralName]
        ?.Strategies?.GenericOptimisedLender.Contract as string;
    }

    const initializeData = GenericEuler__factory.createInterface().encodeFunctionData('initialize', [
      strategyAddress,
      `Euler Lender ${stableName}-${collateralName}`,
      [governor],
      guardian,
      keepers,
    ]);

    const proxyLender = await deploy(`GenericEuler_${stableName}_${collateralName}`, {
      contract: 'TransparentUpgradeableProxy',
      from: deployer.address,
      args: [lenderImplementationAddress, proxyAdminAddress, initializeData],
    });

    console.log(
      `Lender GenericEuler_${stableName}_${collateralName} (proxy) successfully deployed at address: `,
      proxyLender.address,
    );
    console.log(`Deploy cost: ${(proxyLender.receipt?.gasUsed as BigNumber)?.toString()} (proxy)`);

    if (!network.live) {
      const strategy = new ethers.Contract(
        strategyAddress,
        OptimizerAPRStrategy__factory.createInterface(),
        deployer,
      ) as OptimizerAPRStrategy;

      await impersonate(guardian, async acc => {
        await network.provider.send('hardhat_setBalance', [guardian, '0x10000000000000000000000000000']);
        await await strategy.connect(acc).addLender(proxyLender.address);
        console.log('Add lender: success');
      });
    }
  }
};

func.tags = ['genericEuler'];
func.dependencies = ['genericEulerImplementation'];
export default func;
