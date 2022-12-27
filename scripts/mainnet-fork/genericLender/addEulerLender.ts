// eslint-disable-next-line camelcase

import { CONTRACTS_ADDRESSES, ChainId } from '@angleprotocol/sdk';
import { network, ethers, deployments } from 'hardhat';
import { parseUnits } from 'ethers/lib/utils';
import {
  GenericAaveNoStaker,
  GenericAaveNoStaker__factory,
  GenericCompoundUpgradeable,
  GenericCompoundUpgradeable__factory,
  GenericEuler,
  GenericEuler__factory,
  OptimizerAPRStrategy,
  OptimizerAPRStrategy__factory,
  PoolManager,
  PoolManager__factory,
} from '../../../typechain';
import { logBN } from '../../../test/hardhat/utils-interaction';

async function main() {
  // =============== Simulation parameters ====================
  const { deployer } = await ethers.getNamedSigners();

  const stableName = 'agEUR';
  const collateralName = 'DAI';
  const tokenDecimal = 18;

  let strategyAddress: string;
  let poolManagerAddress: string;
  let lenderAaveAddress, lenderCompoundAddress: string;

  if (!network.live) {
    poolManagerAddress = CONTRACTS_ADDRESSES[ChainId.MAINNET].agEUR?.collaterals?.[collateralName]
      ?.PoolManager as string;
    strategyAddress = CONTRACTS_ADDRESSES[ChainId.MAINNET].agEUR?.collaterals?.[collateralName]?.Strategies
      ?.GenericOptimisedLender.Contract as string;
    lenderAaveAddress = CONTRACTS_ADDRESSES[ChainId.MAINNET].agEUR?.collaterals?.[collateralName]?.Strategies
      ?.GenericOptimisedLender.GenericAave as string;
    lenderCompoundAddress = CONTRACTS_ADDRESSES[ChainId.MAINNET].agEUR?.collaterals?.[collateralName]?.Strategies
      ?.GenericOptimisedLender.GenericCompound as string;
  } else {
    poolManagerAddress = CONTRACTS_ADDRESSES[network.config.chainId as ChainId].agEUR?.collaterals?.[collateralName]
      ?.PoolManager as string;
    strategyAddress = CONTRACTS_ADDRESSES[network.config.chainId as ChainId].agEUR?.collaterals?.[collateralName]
      ?.Strategies?.GenericOptimisedLender as string;
    lenderAaveAddress = CONTRACTS_ADDRESSES[network.config.chainId as ChainId].agEUR?.collaterals?.[collateralName]
      ?.Strategies?.GenericOptimisedLender.GenericAave as string;
    lenderCompoundAddress = CONTRACTS_ADDRESSES[network.config.chainId as ChainId].agEUR?.collaterals?.[collateralName]
      ?.Strategies?.GenericOptimisedLender.GenericCompound as string;
  }

  const lenderEulerDeployment = await deployments.get(`GenericEuler_${stableName}_${collateralName}`);

  // const FRAX = '0x853d955aCEf822Db058eb8505911ED77F175b99e';
  // const wantToken = (await ethers.getContractAt(ERC20__factory.abi, FRAX)) as ERC20;

  const strategy = new ethers.Contract(
    strategyAddress,
    OptimizerAPRStrategy__factory.createInterface(),
    deployer,
  ) as OptimizerAPRStrategy;
  const poolManager = new ethers.Contract(
    poolManagerAddress,
    PoolManager__factory.createInterface(),
    deployer,
  ) as PoolManager;

  const lenderCompound = new ethers.Contract(
    lenderCompoundAddress,
    GenericCompoundUpgradeable__factory.createInterface(),
    deployer,
  ) as GenericCompoundUpgradeable;

  const lenderAave = new ethers.Contract(
    lenderAaveAddress,
    GenericAaveNoStaker__factory.createInterface(),
    deployer,
  ) as GenericAaveNoStaker;

  const lenderEuler = new ethers.Contract(
    lenderEulerDeployment.address,
    GenericEuler__factory.createInterface(),
    deployer,
  ) as GenericEuler;

  await network.provider.send('hardhat_setBalance', [deployer.address, parseUnits('1000', 18).toHexString()]);

  console.log('All contracts loaded');

  let navAave = await lenderAave.nav();
  let navComp = await lenderCompound.nav();
  let navEuler = await lenderEuler.nav();

  let aprAave = await lenderAave.apr();
  let aprComp = await lenderCompound.apr();
  let aprEuler = await lenderEuler.apr();

  console.log('Aave nav: \t', logBN(navAave, { base: tokenDecimal }));
  console.log('Comp nav: \t', logBN(navComp, { base: tokenDecimal }));
  console.log('Euler nav: \t', logBN(navEuler, { base: tokenDecimal }));

  console.log('');

  console.log('Aave apr: \t', logBN(aprAave));
  console.log('Comp apr: \t', logBN(aprComp));
  console.log('Euler apr: \t', logBN(aprEuler));

  await (await strategy['harvest()']()).wait();

  console.log('Harvest');

  navAave = await lenderAave.nav();
  navComp = await lenderCompound.nav();
  navEuler = await lenderEuler.nav();
  aprAave = await lenderAave.apr();
  aprComp = await lenderCompound.apr();
  aprEuler = await lenderEuler.apr();

  console.log('Aave nav: \t', logBN(navAave, { base: tokenDecimal }));
  console.log('Comp nav: \t', logBN(navComp, { base: tokenDecimal }));
  console.log('Euler nav: \t', logBN(navEuler, { base: tokenDecimal }));

  console.log('');

  console.log('Aave apr: \t', logBN(aprAave));
  console.log('Comp apr: \t', logBN(aprComp));
  console.log('Euler apr: \t', logBN(aprEuler));
}

main().catch(error => {
  console.error(error);
  process.exit(1);
});
