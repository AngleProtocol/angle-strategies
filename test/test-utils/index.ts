import { ethers } from 'hardhat';
import { Contract, Wallet } from 'ethers';

export async function deploy(
  contractName: string,
  args: any[] = [],
  options: Record<string, any> & { libraries?: Record<string, string> } = {},
): Promise<Contract> {
  const factory = await ethers.getContractFactory(contractName, options);
  const contract = await factory.deploy(...args);
  return contract;
}

export const randomAddress = () => Wallet.createRandom().address;
