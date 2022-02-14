import { Pool } from '@uniswap/v3-sdk';
import { Token } from '@uniswap/sdk-core';
import { abi as IUniswapV3PoolABI } from '@uniswap/v3-core/artifacts/contracts/interfaces/IUniswapV3Pool.sol/IUniswapV3Pool.json';
import { ethers } from 'hardhat';
import Web3 from 'web3';
import { PoolAddress } from '../typechain';
 


interface Immutables {
  factory: string;
  token0: string;
  token1: string;
  fee: number;
  tickSpacing: number;
  maxLiquidityPerTick: ethers.BigNumber;
}

interface State {
  liquidity: ethers.BigNumber;
  sqrtPriceX96: ethers.BigNumber;
  tick: number;
  observationIndex: number;
  observationCardinality: number;
  observationCardinalityNext: number;
  feeProtocol: number;
  unlocked: boolean;
}

async function getPoolImmutables(poolAddress: string) {
  const poolContract = new ethers.Contract(poolAddress, IUniswapV3PoolABI, ethers.provider);
  const [factory, token0, token1, fee, tickSpacing, maxLiquidityPerTick] = await Promise.all([
    poolContract.factory(),
    poolContract.token0(),
    poolContract.token1(),
    poolContract.fee(),
    poolContract.tickSpacing(),
    poolContract.maxLiquidityPerTick(),
  ]);

  const immutables: Immutables = {
    factory,
    token0,
    token1,
    fee,
    tickSpacing,
    maxLiquidityPerTick,
  };
  return immutables;
}
async function getPoolState(poolAddress: string) {
  const poolContract = new ethers.Contract(poolAddress, IUniswapV3PoolABI, ethers.provider);
  const [liquidity, slot] = await Promise.all([poolContract.liquidity(), poolContract.slot0()]);

  const PoolState: State = {
    liquidity,
    sqrtPriceX96: slot[0],
    tick: slot[1],
    observationIndex: slot[2],
    observationCardinality: slot[3],
    observationCardinalityNext: slot[4],
    feeProtocol: slot[5],
    unlocked: slot[6],
  };

  return PoolState;
}

export async function getTokenPriceFromUniswap(
  poolAddress: string,
  _tokenIn: { address: string; decimals: number },
  _tokenOut: { address: string; decimals: number },
): Promise<string> {
  const [immutables, state] = await Promise.all([getPoolImmutables(poolAddress), getPoolState(poolAddress)]);

  const tokenIn = new Token(1, _tokenIn.address, _tokenIn.decimals, 'FEI', 'FEI');
  const tokenOut = new Token(1, _tokenOut.address, _tokenOut.decimals, 'USDC', 'USDC');

  const pool = new Pool(
    tokenIn,
    tokenOut,
    immutables.fee,
    state.sqrtPriceX96.toString(),
    state.liquidity.toString(),
    state.tick,
  );
  //   console.log(pool, pool.token0Price.toFixed(), pool.token1Price.toFixed());
  return pool.token0.address === _tokenIn.address ? pool.token0Price.toFixed() : pool.token1Price.toFixed();
}


type PoolKey = {
  token0: string,
  token1:string,
  fee: number,
} 


        // require(key.token0 < key.token1);
        // pool = address(
        //     uint160(
        //         uint256(
        //             keccak256(
        //                 abi.encodePacked(
        //                     hex"ff",
        //                     factory,
        //                     keccak256(abi.encode(key.token0, key.token1, key.fee)),
        //                     _POOL_INIT_CODE_HASH
        //                 )
        //             )
        //         )
        //     )
        // );

async function main() {
  const { deployer } = await ethers.getNamedSigners();


  // tmp
  const poolAddressContract = '0x029F049C59A6b56610a34ba01d0d28E26ed407A8';

  // Params 
  const _POOL_INIT_CODE_HASH = '0xe34f199b19b2b4f47f68442619d555527d244f78a3297ea89325f843f87b8b54';
  const FEIAddress = '0x956F47F50A910163D8BF957Cf5846D573E7f87CA';
  const USDCAddress = '0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48';
  const uniFee = 500;
  let key: PoolKey;

  if (FEIAddress < USDCAddress) {
    key = { token0: FEIAddress, token1: USDCAddress, fee: uniFee };
  } else {
  }
  const GuardianRoleHash = Web3.utils.soliditySha3('GUARDIAN_ROLE')!;

  // EXAMPLE with FEI-USDC
  const POOLADDRESS = '0xdf50fbde8180c8785842c8e316ebe06f542d3443'; // FEI-USDC
  getTokenPriceFromUniswap(
    POOLADDRESS,
    { address: '0x956F47F50A910163D8BF957Cf5846D573E7f87CA', decimals: 18 },
    { address: '0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48', decimals: 6 },
  );

  const contractUniPoolAddress = new ethers.Contract(
    poolAddressContract,
    [
      'function getPoolKey(address tokenA, address tokenB, uint24 fee) external pure returns ((address token0,address token1, uint24 fee))',
    ],
    deployer,
  ) as PoolAddress;

  const poolKey = await contractUniPoolAddress.connect(deployer).getPoolKey(USDCAddress, FEIAddress, uniFee);

  console.log('the pool key is ', poolKey);
}

main().catch(error => {
  console.error(error);
  process.exit(1);
});
