/* eslint-disable camelcase */
import { SignerWithAddress } from '@nomiclabs/hardhat-ethers/signers';
import { ethers, deployments, network } from 'hardhat';
import { utils, Wallet, constants, Contract, BigNumber, providers } from 'ethers';
import { impersonate, deploy } from '../test/test-utils';
import {
  AaveFlashloanStrategy,
  ERC20,
  ERC20__factory,
  PoolManager__factory,
  MockPoolManager,
  Strategy,
  Strategy__factory,
  ILendingPool__factory,
  ILendingPool,
  FlashMintLib,
  AaveFlashloanStrategy__factory,
  ComputeProfitability,
  PoolManager,
  IAaveIncentivesController__factory,
  IAaveIncentivesController,
  IProtocolDataProvider__factory,
  IProtocolDataProvider,
  ILendingPoolAddressesProvider,
  ILendingPoolAddressesProvider__factory,
  MockAToken__factory,
  IAToken__factory,
  IAToken,
} from '../typechain';

async function main() {
  const protocolDataProvider = (await ethers.getContractAt(
    IProtocolDataProvider__factory.abi,
    '0x057835Ad21a177dbdd3090bB1CAE03EaCF78Fc6d',
  )) as IProtocolDataProvider;

  const USDC = '0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48';

  const tokens = await protocolDataProvider.getReserveTokensAddresses(USDC);

  const aToken = new Contract(tokens.aTokenAddress, IAToken__factory.abi) as IAToken;

  const addressProvider = new Contract(
    await protocolDataProvider.ADDRESSES_PROVIDER(),
    ILendingPoolAddressesProvider__factory.abi,
  ) as ILendingPoolAddressesProvider;

  const lendingPool = new Contract(await addressProvider.getLendingPool(), ILendingPool__factory.abi) as ILendingPool;

  const incentivesController = new Contract(
    await aToken.getIncentivesController(),
    IAaveIncentivesController__factory.abi,
  ) as IAaveIncentivesController;

  // TODO: check if some values have changed
  // Check if harvest must be called
  const strategy = new Contract('', AaveFlashloanStrategy__factory.abi) as AaveFlashloanStrategy;
}

main();
