import { BASE_18 } from '@angleprotocol/sdk';
import {
  AgToken,
  AgToken__factory,
  OracleMulti,
  OracleMulti__factory,
  PerpetualManagerFront,
  PoolManager,
  SanToken,
  SanToken__factory,
  StableMasterFront,
} from '@angleprotocol/sdk/dist/constants/types';
import { SignerWithAddress } from '@nomiclabs/hardhat-ethers/signers';
import { BigNumber } from 'ethers';
import { formatUnits, parseUnits } from 'ethers/lib/utils';
import { ethers } from 'hardhat';
import { ERC20, ERC20__factory, StETHStrategy } from '../typechain';

export const wait = (n = 1000) => {
  return new Promise(resolve => {
    setTimeout(() => {
      resolve('ok');
    }, n);
  });
};

export const logBN = (amount: BigNumber, { base = 18, pad = 20, sign = false } = {}) => {
  const num = parseFloat(formatUnits(amount, base));
  const formattedNum = new Intl.NumberFormat('fr-FR', {
    style: 'decimal',
    maximumFractionDigits: 4,
    minimumFractionDigits: 4,
    signDisplay: sign ? 'always' : 'never',
  }).format(num);
  return formattedNum.padStart(pad, ' ');
};

export const logGeneralInfo = async (
  stableMaster: StableMasterFront,
  poolManager: PoolManager,
  perpetualManager: PerpetualManagerFront,
  strategy: StETHStrategy,
) => {
  const agTokenAddress = await stableMaster.agToken();
  const agToken = (await ethers.getContractAt(AgToken__factory.abi, agTokenAddress)) as AgToken;
  const agTokenName = await agToken.name();

  const collatAddress = (await stableMaster.collateralMap(poolManager.address)).token;
  const collat = (await ethers.getContractAt(ERC20__factory.abi, collatAddress)) as ERC20;
  const collatDecimal = await collat.decimals();

  const collatData = await stableMaster.collateralMap(poolManager.address);
  const oracle = (await ethers.getContractAt(OracleMulti__factory.abi, collatData.oracle)) as OracleMulti;
  const oracleValues = await oracle.readAll();

  const stratParams = await poolManager.strategies(strategy.address);

  console.log(`
  General Info:
   Total supply ${agTokenName}:\t${logBN(await agToken.totalSupply(), { base: 18 })}
   Cap On stock user:\t${logBN(collatData.feeData.capOnStableMinted, { base: 18 })}
   Stocks Users:\t${logBN(collatData.stocksUsers, { base: 18 })}
   Total hedge amount:\t${logBN(await perpetualManager.totalHedgeAmount(), { base: 18 })}
  Oracle Info:
   Lower rate:\t${logBN(oracleValues[0], { base: 18 })}
   Upper rate:\t${logBN(oracleValues[1], { base: 18 })}
  Strategy:
   total assets PoolManager:\t${logBN(await poolManager.getTotalAsset(), { base: collatDecimal })}
   wETH PoolManager:\t${logBN(await collat.balanceOf(poolManager.address), { base: collatDecimal })}
   debt ratio:\t${logBN(stratParams.debtRatio, { base: 9 })}
   total debt:\t${logBN(stratParams.totalStrategyDebt, { base: collatDecimal })}
   wETH balance:\t${logBN(await strategy.wantBalance(), { base: collatDecimal })}
   stETH balance:\t${logBN(await strategy.stethBalance(), { base: collatDecimal })}
   apr:\t${logBN(await strategy.estimatedAPR(), { base: 9 })}

  SLP:
   SanRate:\t${logBN(collatData.sanRate, { base: 18 })}
   Locked Interest:\t${logBN(collatData.slpData.lockedInterests, { base: 18 })}
   max interest distributed:\t${logBN(collatData.slpData.maxInterestsDistributed, { base: 18 })}
   fees aside:\t${logBN(collatData.slpData.feesAside, { base: collatDecimal })}
   slippage fee:\t${logBN(collatData.slpData.slippageFee, { base: collatDecimal })}
   fees aside:\t${logBN(collatData.slpData.feesAside, { base: collatDecimal })}
   slippage:\t${logBN(collatData.slpData.slippage, { base: 9 })}
   interests for SLPs:\t${logBN(collatData.slpData.interestsForSLPs, { base: 9 })}
   fees for SLPs:\t${logBN(collatData.slpData.feesForSLPs, { base: 18 })}
  `);
};

export const randomMint = async (
  user: SignerWithAddress,
  stableMaster: StableMasterFront,
  poolManager: PoolManager,
) => {
  const min = 2;
  const max = 500;

  const collatData = await stableMaster.collateralMap(poolManager.address);
  const oracle = (await ethers.getContractAt(OracleMulti__factory.abi, collatData.oracle)) as OracleMulti;
  const oracleValues = await oracle.readAll();

  const collatAddress = (await stableMaster.collateralMap(poolManager.address)).token;
  const collat = (await ethers.getContractAt(ERC20__factory.abi, collatAddress)) as ERC20;
  const collatDecimal = await collat.decimals();
  const agTokenAddress = await stableMaster.agToken();
  const agToken = (await ethers.getContractAt(AgToken__factory.abi, agTokenAddress)) as AgToken;
  let amount = parseUnits(Math.floor(Math.random() * (max - min + 1) + min).toString(), collatDecimal);

  const maxMintable = collatData.feeData.capOnStableMinted
    .sub(collatData.stocksUsers)
    .mul(BASE_18)
    .div(oracleValues[0]);
  if (amount.gt(maxMintable)) {
    amount = maxMintable;
  }

  const agTokenBalanceBefore = await agToken.balanceOf(user.address);
  await collat.connect(user).approve(stableMaster.address, amount);
  await stableMaster.connect(user).mint(amount, user.address, poolManager.address, parseUnits('0', 1));
  const agTokenBalanceAfter = await agToken.balanceOf(user.address);

  console.log(
    `user minting from \t${logBN(amount, { base: collatDecimal })} ${await collat.name()}\t for\t ${logBN(
      agTokenBalanceAfter.sub(agTokenBalanceBefore),
    )} ${await agToken.name()}`,
  );
};

export const randomBurn = async (
  user: SignerWithAddress,
  stableMaster: StableMasterFront,
  poolManager: PoolManager,
) => {
  const min = 20_000;
  const max = 1_000_000;
  const collatAddress = (await stableMaster.collateralMap(poolManager.address)).token;
  const collat = (await ethers.getContractAt(ERC20__factory.abi, collatAddress)) as ERC20;
  const collatDecimal = await collat.decimals();
  const agTokenAddress = await stableMaster.agToken();
  const agToken = (await ethers.getContractAt(AgToken__factory.abi, agTokenAddress)) as AgToken;

  let amount = parseUnits(Math.floor(Math.random() * (max - min + 1) + min).toString(), 18);
  const maxAmount = (await agToken.balanceOf(user.address)).div(parseUnits('2', 0));
  if (amount.gt(maxAmount)) {
    amount = maxAmount;
  }

  const collatBalanceBefore = await collat.balanceOf(user.address);
  await agToken.connect(user).approve(stableMaster.address, amount);
  await stableMaster.connect(user).burn(amount, user.address, user.address, poolManager.address, parseUnits('0', 1));
  const collatBalanceAfter = await collat.balanceOf(user.address);

  console.log(
    `user burning \t${logBN(amount)} ${await agToken.name()}\t for\t ${logBN(
      collatBalanceAfter.sub(collatBalanceBefore),
      { base: collatDecimal },
    )} ${await collat.name()}`,
  );
};

export const randomDeposit = async (
  user: SignerWithAddress,
  stableMaster: StableMasterFront,
  poolManager: PoolManager,
) => {
  const min = 2;
  const max = 500;
  const collatAddress = (await stableMaster.collateralMap(poolManager.address)).token;
  const collat = (await ethers.getContractAt(ERC20__factory.abi, collatAddress)) as ERC20;
  const sanTokenAddress = (await stableMaster.collateralMap(poolManager.address)).sanToken;
  const sanToken = (await ethers.getContractAt(SanToken__factory.abi, sanTokenAddress)) as SanToken;
  const collatDecimal = await collat.decimals();

  const amount = parseUnits(Math.floor(Math.random() * (max - min + 1) + min).toString(), collatDecimal);

  const sanTokenBalanceBefore = await sanToken.balanceOf(user.address);
  await collat.connect(user).approve(stableMaster.address, amount);
  await stableMaster.connect(user).deposit(amount, user.address, poolManager.address);
  const sanTokenBalanceAfter = await sanToken.balanceOf(user.address);

  console.log(
    `user depositing \t${logBN(amount, { base: collatDecimal })} ${await collat.name()}\t for\t ${logBN(
      sanTokenBalanceAfter.sub(sanTokenBalanceBefore),
    )} ${await sanToken.name()}`,
  );
};

export const randomWithdraw = async (
  user: SignerWithAddress,
  stableMaster: StableMasterFront,
  poolManager: PoolManager,
) => {
  const min = 2;
  const max = 500;
  const collatAddress = (await stableMaster.collateralMap(poolManager.address)).token;
  const collat = (await ethers.getContractAt(ERC20__factory.abi, collatAddress)) as ERC20;
  const sanTokenAddress = (await stableMaster.collateralMap(poolManager.address)).sanToken;
  const sanToken = (await ethers.getContractAt(SanToken__factory.abi, sanTokenAddress)) as SanToken;
  const collatDecimal = await collat.decimals();

  const amount = parseUnits(Math.floor(Math.random() * (max - min + 1) + min).toString(), collatDecimal);

  const collatBalanceBefore = await collat.balanceOf(user.address);
  await sanToken.connect(user).approve(stableMaster.address, amount);
  await stableMaster.connect(user).withdraw(amount, user.address, user.address, poolManager.address);
  const collatBalanceAfter = await collat.balanceOf(user.address);

  console.log(
    `user withdrawing \t${logBN(amount, { base: collatDecimal })} ${await sanToken.name()}\t for\t ${logBN(
      collatBalanceAfter.sub(collatBalanceBefore),
    )} ${await collat.name()}`,
  );
};

export const randomOpenPerp = async (
  user: SignerWithAddress,
  perpetualManager: PerpetualManagerFront,
  collateral: ERC20,
  stableMaster: StableMasterFront,
  poolManager: PoolManager,
) => {
  const min = 2;
  const max = 50;
  // in bps
  const minMultiplier = 100;
  const maxMultiplier = 85_000;

  const collatDecimal = await collateral.decimals();

  const margin = parseUnits(Math.floor(Math.random() * (max - min + 1) + min).toString(), collatDecimal);
  let position = margin.mul(
    parseUnits(Math.floor(Math.random() * (maxMultiplier - minMultiplier + 1) + min).toString(), 0).div(
      parseUnits('10000', 0),
    ),
  );

  const collatData = await stableMaster.collateralMap(poolManager.address);
  const oracle = (await ethers.getContractAt(OracleMulti__factory.abi, collatData.oracle)) as OracleMulti;
  const oracleValues = await oracle.readAll();
  const totalHedge = await perpetualManager.totalHedgeAmount();

  //   const maxPosition = collatData.stocksUsers
  //     .sub(totalHedge)
  //     .mul(BASE_18)
  //     .mul(parseUnits('0.9', 5))
  //     .div(oracleValues[1])
  //     .div(parseUnits('1', 5));
  //   if (position.gt(maxPosition)) {
  //     position = maxPosition;
  //   }

  await collateral.connect(user).approve(perpetualManager.address, margin);
  const perpTx = await (
    await perpetualManager
      .connect(user)
      .openPerpetual(user.address, margin, position, parseUnits('1000000', 18), parseUnits('0', 1))
  ).wait();
  const perpId = perpTx.events
    ?.filter(x => {
      return x.event === 'PerpetualOpened';
    })
    .map(x => {
      return x.args?._perpetualID;
    }) as any[];
  const perpData = await perpetualManager.perpetualData(perpId[0]);

  console.log(`
  Open perp ${perpId[0]}:
   balance:\t${await perpetualManager.balanceOf(user.address)}
   margin:\t${logBN(perpData.margin, { base: collatDecimal })}
   position:\t${logBN(perpData.committedAmount, { base: collatDecimal })} 
   entry oracle:\t${logBN(perpData.entryRate, { base: 18 })}
  `);
};

export const closePerp = async (
  user: SignerWithAddress,
  perpetualManager: PerpetualManagerFront,
  collateral: ERC20,
  perpId: number,
) => {
  const collatDecimal = await collateral.decimals();

  const collatBalanceBefore = await collateral.connect(user).balanceOf(user.address);
  await perpetualManager.connect(user).closePerpetual(perpId, user.address, parseUnits('0', 1));
  const collatBalanceAfter = await collateral.connect(user).balanceOf(user.address);

  console.log(
    `Burnt perp ${perpId}\t for\t ${logBN(collatBalanceAfter.sub(collatBalanceBefore), {
      base: collatDecimal,
    })} ${await collateral.name()}`,
  );
};
