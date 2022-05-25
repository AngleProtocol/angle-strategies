import { network } from 'hardhat';
import { DeployFunction } from 'hardhat-deploy/types';
import { CONTRACTS_ADDRESSES, ChainId } from '@angleprotocol/sdk';
import { BigNumber } from 'ethers';
import { GenericCompoundUpgradeable, GenericCompoundUpgradeable__factory } from '../typechain';
import { parseUnits } from 'ethers/lib/utils';
import { ProxyAdmin, ProxyAdmin__factory } from '@angleprotocol/sdk/dist/constants/types';

const func: DeployFunction = async ({ deployments, ethers }) => {
  const { deploy } = deployments;
  const { deployer, keeper: fakeKeeper } = await ethers.getNamedSigners();
  const collateralName = 'DAI';

  let guardian: string;
  let governor: string;
  let strategyAddress, lenderAddress, proxyAdminAddress: string;
  let keeper: string;

  // if fork we suppose that we are in mainnet
  // eslint-disable-next-line
  let json = (await import('./networks/mainnet.json')) as any;
  if (!network.live) {
    guardian = CONTRACTS_ADDRESSES[ChainId.MAINNET].Guardian as string;
    governor = CONTRACTS_ADDRESSES[ChainId.MAINNET].GovernanceMultiSig as string;
    strategyAddress = CONTRACTS_ADDRESSES[ChainId.MAINNET].agEUR?.collaterals?.[collateralName]?.Strategies
      ?.GenericOptimisedLender as string;
    lenderAddress = CONTRACTS_ADDRESSES[ChainId.MAINNET].agEUR?.collaterals?.[collateralName]
      ?.GenericCompound as string;
    proxyAdminAddress = CONTRACTS_ADDRESSES[ChainId.MAINNET].ProxyAdmin as string;
    keeper = '0xcC617C6f9725eACC993ac626C7efC6B96476916E';
  } else {
    guardian = CONTRACTS_ADDRESSES[network.config.chainId as ChainId].Guardian!;
    governor = CONTRACTS_ADDRESSES[network.config.chainId as ChainId].GovernanceMultiSig as string;
    strategyAddress = CONTRACTS_ADDRESSES[network.config.chainId as ChainId].agEUR?.collaterals?.[collateralName]
      ?.Strategies?.GenericOptimisedLender as string;
    lenderAddress = CONTRACTS_ADDRESSES[network.config.chainId as ChainId].agEUR?.collaterals?.[collateralName]
      ?.GenericCompound as string;
    proxyAdminAddress = CONTRACTS_ADDRESSES[network.config.chainId as ChainId].ProxyAdmin as string;
    keeper = fakeKeeper.address;
  }

  const lenderImplementation = await deploy(`GenericCompoundV3_Implementation`, {
    contract: 'GenericCompoundUpgradeable',
    from: deployer.address,
    args: [],
  });
  const lenderImplementationAddress = (await ethers.getContract(`GenericCompoundV3_Implementation`)).address;
  console.log('success: deployed lender implementation', lenderImplementationAddress);
  console.log(`Deploy cost: ${(lenderImplementation?.receipt?.gasUsed as BigNumber)?.toString()} (implem)`);

  if (!network.live) {
    await network.provider.request({
      method: 'hardhat_impersonateAccount',
      params: [governor],
    });
    const governorSigner = await ethers.getSigner(governor);
    await network.provider.send('hardhat_setBalance', [governor, '0x10000000000000000000000000000']);

    const proxyAdmin = new ethers.Contract(
      proxyAdminAddress,
      ProxyAdmin__factory.createInterface(),
      governorSigner,
    ) as ProxyAdmin;
    await (await proxyAdmin.connect(governorSigner).upgrade(lenderAddress, lenderImplementation?.address)).wait();
    console.log('Upgrade lender: success');

    const lenderCompound = new ethers.Contract(
      lenderAddress,
      GenericCompoundUpgradeable__factory.createInterface(),
      deployer,
    ) as GenericCompoundUpgradeable;
    await await lenderCompound.connect(governorSigner).setDust(parseUnits('1', 8));
    console.log('Set dust: success');
  }
};

func.tags = ['genericCompoundV3'];
export default func;
