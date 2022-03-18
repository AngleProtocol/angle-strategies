import { DeployFunction } from 'hardhat-deploy/types';
import { CONTRACTS_ADDRESSES } from '@angleprotocol/sdk';

const func: DeployFunction = async ({ deployments, ethers }) => {
  const { deploy } = deployments;
  const [deployer] = await ethers.getSigners();

  const angleDistributorAddress = (await deployments.get('AngleDistributor')).address; // 0x4f91F01cE8ec07c9B1f6a82c18811848254917Ab

  const governors = [CONTRACTS_ADDRESSES[1].GovernanceMultiSig as string, '0x0C2553e4B9dFA9f83b1A6D3EAB96c4bAaB42d430'];

  const deployed = await deploy('AngleMiddleman', {
    contract: 'AngleMiddleman',
    from: deployer.address,
    args: [governors, angleDistributorAddress],
  });

  console.log('Successfully deployed at address: ', deployed.address);
  console.log('Tx hash', deployed.transactionHash);
};

func.tags = ['middleman'];
export default func;
