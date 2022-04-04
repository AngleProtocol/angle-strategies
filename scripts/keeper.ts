/* eslint-disable camelcase */
import { ethers } from 'hardhat';
import { Contract } from 'ethers';
import {
  AaveFlashloanStrategy,
  ILendingPool__factory,
  ILendingPool,
  AaveFlashloanStrategy__factory,
  IAaveIncentivesController__factory,
  IAaveIncentivesController,
  IProtocolDataProvider__factory,
  IProtocolDataProvider,
  ILendingPoolAddressesProvider,
  ILendingPoolAddressesProvider__factory,
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
