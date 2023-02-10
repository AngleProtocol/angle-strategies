import { DeployFunction } from 'hardhat-deploy/types';
import yargs from 'yargs';
const argv = yargs.env('').boolean('ci').parseSync();

const func: DeployFunction = async ({ deployments, ethers }) => {
  const { deploy } = deployments;
  const { deployer } = await ethers.getNamedSigners();

  console.log('Now deploying the implementation for OptimizerAPRStrategy');
  await deploy('OptimizerAPRStrategy_Implementation', {
    contract: 'OptimizerAPRStrategy',
    from: deployer.address,
    args: [],
    log: !argv.ci,
  });

  const optimizerAPRStrategyImplementation = (await ethers.getContract('OptimizerAPRStrategy_Implementation')).address;

  console.log(`Successfully deployed the implementation for OptimizerAPR at ${optimizerAPRStrategyImplementation}`);
  console.log('');
};

func.tags = ['optimizerAPRImplementation'];
export default func;
