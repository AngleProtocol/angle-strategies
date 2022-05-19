import { ProxyAdmin, ProxyAdmin__factory } from '@angleprotocol/sdk/dist/constants/interfaces';

import { CONTRACTS_ADDRESSES, ChainId } from '@angleprotocol/sdk';
import { network, ethers } from 'hardhat';
import { parseUnits } from 'ethers/lib/utils';
import {
  GenericCompoundUpgradeable,
  GenericCompoundUpgradeable__factory,
  OptimizerAPRStrategy,
  OptimizerAPRStrategy__factory,
} from '../../../typechain';
import yargs from 'yargs';
const argv = yargs.env('').boolean('ci').parseSync();

async function main() {
  // =============== Simulation parameters ====================
  const { deployer } = await ethers.getNamedSigners();

  const collateralName = 'DAI';

  let strategyAddress: string;
  let poolManagerAddress: string;
  let guardian: string;
  let governor: string;
  let lenderAddress: string;
  let proxyAdminAddress: string;

  if (!network.live) {
    guardian = CONTRACTS_ADDRESSES[ChainId.MAINNET].Guardian as string;
    governor = CONTRACTS_ADDRESSES[ChainId.MAINNET].GovernanceMultiSig as string;
    poolManagerAddress = CONTRACTS_ADDRESSES[ChainId.MAINNET].agEUR?.collaterals?.[collateralName]
      ?.PoolManager as string;
    strategyAddress = CONTRACTS_ADDRESSES[ChainId.MAINNET].agEUR?.collaterals?.[collateralName]?.Strategies
      ?.GenericOptimisedLender as string;
    lenderAddress = CONTRACTS_ADDRESSES[ChainId.MAINNET].agEUR?.collaterals?.[collateralName]
      ?.GenericCompound as string;
    proxyAdminAddress = CONTRACTS_ADDRESSES[ChainId.MAINNET].ProxyAdmin as string;
  } else {
    guardian = CONTRACTS_ADDRESSES[network.config.chainId as ChainId].Guardian!;
    governor = CONTRACTS_ADDRESSES[network.config.chainId as ChainId].GovernanceMultiSig as string;
    poolManagerAddress = CONTRACTS_ADDRESSES[network.config.chainId as ChainId].agEUR?.collaterals?.[collateralName]
      ?.PoolManager as string;
    strategyAddress = CONTRACTS_ADDRESSES[network.config.chainId as ChainId].agEUR?.collaterals?.[collateralName]
      ?.Strategies?.GenericOptimisedLender as string;
    lenderAddress = CONTRACTS_ADDRESSES[network.config.chainId as ChainId].agEUR?.collaterals?.[collateralName]
      ?.GenericCompound as string;
    proxyAdminAddress = CONTRACTS_ADDRESSES[network.config.chainId as ChainId].ProxyAdmin as string;
  }

  const strategy = new ethers.Contract(
    strategyAddress,
    OptimizerAPRStrategy__factory.createInterface(),
    deployer,
  ) as OptimizerAPRStrategy;

  const lenderCompound = new ethers.Contract(
    lenderAddress,
    GenericCompoundUpgradeable__factory.createInterface(),
    deployer,
  ) as GenericCompoundUpgradeable;

  console.log('All contracts loaded');

  if (!network.live) {
    await network.provider.send('hardhat_setBalance', [deployer.address, parseUnits('1000000', 18).toHexString()]);

    await network.provider.request({
      method: 'hardhat_impersonateAccount',
      params: [governor],
    });
    const governorSigner = await ethers.getSigner(governor);
    await network.provider.request({
      method: 'hardhat_impersonateAccount',
      params: [guardian],
    });
    const guardianSigner = await ethers.getSigner(guardian);

    await network.provider.send('hardhat_setBalance', [governor, '0x10000000000000000000000000000']);
    await network.provider.send('hardhat_setBalance', [guardian, '0x10000000000000000000000000000']);

    // Grant strategy role to the guardian on compound lender
    await lenderCompound
      .connect(governorSigner)
      .grantRole(ethers.utils.solidityKeccak256(['string'], ['STRATEGY_ROLE']), guardian);

    console.log('Grant role: success');

    // Then withdraw funds from the lender
    await lenderCompound.connect(guardianSigner).withdraw(parseUnits('4900644189785575915519', 0));
    console.log('Withdraw: success');

    // Revoke role to the guardian
    await lenderCompound
      .connect(governorSigner)
      .revokeRole(ethers.utils.solidityKeccak256(['string'], ['STRATEGY_ROLE']), guardian);
    console.log('Revoke role: success');

    // Remove the lender
    await strategy.connect(governorSigner).forceRemoveLender(lenderCompound.address);
    console.log('Remove lender: success');
  }
}

main().catch(error => {
  console.error(error);
  process.exit(1);
});