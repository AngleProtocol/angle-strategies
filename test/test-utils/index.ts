import { ethers, network } from 'hardhat';
import { Contract, Wallet } from 'ethers';
import { SignerWithAddress } from '@nomiclabs/hardhat-ethers/signers';

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

export async function impersonate(
  address: string,
  cb?: (_account: SignerWithAddress) => Promise<void>,
  stopImpersonating = true,
): Promise<SignerWithAddress> {
  await network.provider.request({
    method: 'hardhat_impersonateAccount',
    params: [address],
  });

  const account = await ethers.getSigner(address);
  if (cb) {
    await cb(account);
  }

  if (stopImpersonating) {
    await network.provider.request({
      method: 'hardhat_stopImpersonatingAccount',
      params: [address],
    });
  }
  return account;
}
