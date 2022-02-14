import { ethers } from 'hardhat';
import { BigNumber, Contract } from 'ethers';
import { parseAmount, multBy10e15 } from '../../utils/bignumber';

import {
  AgToken,
  Core,
  PoolManager,
  FeeManager,
  MockANGLE,
  MockOracle,
  MockToken,
  PerpetualManagerFront,
  SanToken,
  StableMasterFront,
} from '../../typechain';
import { SignerWithAddress } from '@nomiclabs/hardhat-ethers/dist/src/signers';

export const BASE = parseAmount.ether(1);
export const BASE_PARAMS = parseAmount.gwei(1);
export const BASE_15 = multBy10e15(15);
export const BASE_RATE = BigNumber.from(10 ** 2);
export const BASE_ORACLE = parseAmount.ether(1);

export const MAX_MINT_AMOUNT = BigNumber.from(2).pow(BigNumber.from(256)).sub(BigNumber.from(1));

export async function setupUsers<T extends { [contractName: string]: Contract }>(
  addresses: string[],
  contracts: T,
): Promise<({ address: string } & T)[]> {
  const users: ({ address: string } & T)[] = [];
  for (const address of addresses) {
    users.push(await setupUser(address, contracts));
  }
  return users;
}

export async function setupUser<T extends { [contractName: string]: Contract }>(
  address: string,
  contracts: T,
): Promise<{ address: string } & T> {
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const user: any = { address };
  for (const key of Object.keys(contracts)) {
    user[key] = contracts[key].connect(await ethers.getSigner(address));
  }
  return user as { address: string } & T;
}

export async function initAngle(
  governor: SignerWithAddress,
  guardian: SignerWithAddress,
): Promise<{ core: Core; ANGLE: MockANGLE; stableMaster: StableMasterFront; agToken: AgToken }> {
  const CoreArtifacts = await ethers.getContractFactory('Core');
  const MockANGLEArtifacts = await ethers.getContractFactory('MockANGLE');
  const AgTokenArtifacts = await ethers.getContractFactory('AgToken');
  const StableMasterArtifacts = await ethers.getContractFactory('StableMasterFront');

  const core = (await CoreArtifacts.deploy(governor.address, guardian.address)) as Core;
  const ANGLE = (await MockANGLEArtifacts.deploy('ANGLE', 'ANGLE')) as MockANGLE;
  const stableMaster = (await StableMasterArtifacts.deploy()) as StableMasterFront;
  await stableMaster.initialize(core.address);
  const agToken = (await AgTokenArtifacts.deploy()) as AgToken;
  await agToken.initialize('agEUR', 'agEUR', stableMaster.address);

  await (await core.connect(governor).deployStableMaster(agToken.address)).wait();

  return { core, ANGLE, stableMaster, agToken };
}

export async function initCollateral(
  name: string,
  stableMaster: StableMasterFront,
  ANGLE: MockANGLE,
  governor: SignerWithAddress,
  collatBase = BigNumber.from('18'),
  initFees = true,
): Promise<{
  token: MockToken;
  oracle: MockOracle;
  manager: PoolManager;
  sanToken: SanToken;
  perpetualManager: PerpetualManagerFront;
  feeManager: FeeManager;
}> {
  const SanTokenArtifacts = await ethers.getContractFactory('SanToken');
  const PoolManagerArtifacts = await ethers.getContractFactory('PoolManager');
  const PerpetualManagerArtifacts = await ethers.getContractFactory('PerpetualManagerFront');
  const FeeManagerArtifacts = await ethers.getContractFactory('FeeManager');
  const MockOracleArtifacts = await ethers.getContractFactory('MockOracle');
  const MockTokenArtifacts = await ethers.getContractFactory('MockToken');

  const token = (await MockTokenArtifacts.deploy(name, name, collatBase)) as MockToken;
  const oracle = (await MockOracleArtifacts.deploy(BASE_ORACLE, collatBase)) as MockOracle;
  const manager = (await PoolManagerArtifacts.deploy()) as PoolManager;

  await manager.initialize(token.address, stableMaster.address);
  const sanName = ethers.utils.formatBytes32String('san' + name);
  const sanToken = (await SanTokenArtifacts.deploy()) as SanToken;
  await sanToken.initialize(sanName, sanName, manager.address);
  const perpetualManager = (await PerpetualManagerArtifacts.deploy()) as PerpetualManagerFront;
  await perpetualManager.initialize(manager.address, ANGLE.address);
  const feeManager = (await FeeManagerArtifacts.deploy(manager.address)) as FeeManager;

  await (
    await stableMaster
      .connect(governor)
      .deployCollateral(manager.address, perpetualManager.address, feeManager.address, oracle.address, sanToken.address)
  ).wait();

  if (initFees) {
    // for test purpose
    const xFeeMint = [parseAmount.gwei(0), parseAmount.gwei(1)];
    const yFeeMint = [parseAmount.gwei(0.1), parseAmount.gwei(0.1)];
    await stableMaster.connect(governor).setUserFees(manager.address, xFeeMint, yFeeMint, 1);

    const xFeeBurn = [parseAmount.gwei(0), parseAmount.gwei(1)];
    const yFeeBurn = [parseAmount.gwei(0.1), parseAmount.gwei(0.1)];
    await stableMaster.connect(governor).setUserFees(manager.address, xFeeBurn, yFeeBurn, 0);

    const xHAFeesDeposit = [parseAmount.gwei(0.1), parseAmount.gwei(0.4), parseAmount.gwei(0.7)];
    const yHAFeesDeposit = [parseAmount.gwei(0.01), parseAmount.gwei(0.01), parseAmount.gwei(0.01)];
    await perpetualManager.connect(governor).setHAFees(xHAFeesDeposit, yHAFeesDeposit, 1);

    const xHAFeesWithdraw = [parseAmount.gwei(0.1), parseAmount.gwei(0.4), parseAmount.gwei(0.7)];
    const yHAFeesWithdraw = [parseAmount.gwei(0.01), parseAmount.gwei(0.01), parseAmount.gwei(0.01)];
    await perpetualManager.connect(governor).setHAFees(xHAFeesWithdraw, yHAFeesWithdraw, 0);

    const xSlippage = [parseAmount.gwei(1), parseAmount.gwei(1.5)];
    const ySlippage = [parseAmount.gwei(1), parseAmount.gwei(0)];
    const xSlippageFee = [parseAmount.gwei(1), parseAmount.gwei(1.5)];
    const ySlippageFee = [parseAmount.gwei(1), parseAmount.gwei(0)];

    await feeManager.connect(governor).setFees(xSlippage, ySlippage, 3);
    await feeManager.connect(governor).setFees(xSlippageFee, ySlippageFee, 0);
  } else {
    const xFeeMint = [parseAmount.gwei('0'), parseAmount.gwei('0.4'), parseAmount.gwei('0.7'), parseAmount.gwei('1')];
    const yFeeMint = [
      parseAmount.gwei('0.08'),
      parseAmount.gwei('0.025'),
      parseAmount.gwei('0.005'),
      parseAmount.gwei('0.002'),
    ];
    await stableMaster.connect(governor).setUserFees(manager.address, xFeeMint, yFeeMint, 1);

    const xFeeBurn = [parseAmount.gwei('0'), parseAmount.gwei('0.3'), parseAmount.gwei('0.6'), parseAmount.gwei('1')];
    const yFeeBurn = [
      parseAmount.gwei('0.002'),
      parseAmount.gwei('0.003'),
      parseAmount.gwei('0.005'),
      parseAmount.gwei('0.015'),
    ];
    await stableMaster.connect(governor).setUserFees(manager.address, xFeeBurn, yFeeBurn, 0);

    const xHAFeesDeposit = [
      parseAmount.gwei('0'),
      parseAmount.gwei('0.4'),
      parseAmount.gwei('0.7'),
      parseAmount.gwei('1'),
    ];
    const yHAFeesDeposit = [
      parseAmount.gwei('0.002'),
      parseAmount.gwei('0.005'),
      parseAmount.gwei('0.01'),
      parseAmount.gwei('0.03'),
    ];
    await perpetualManager.connect(governor).setHAFees(xHAFeesDeposit, yHAFeesDeposit, 1);

    const xHAFeesWithdraw = [
      parseAmount.gwei('0'),
      parseAmount.gwei('0.4'),
      parseAmount.gwei('0.7'),
      parseAmount.gwei('1'),
    ];
    const yHAFeesWithdraw = [
      parseAmount.gwei('0.06'),
      parseAmount.gwei('0.02'),
      parseAmount.gwei('0.01'),
      parseAmount.gwei('0.002'),
    ];
    await perpetualManager.connect(governor).setHAFees(xHAFeesWithdraw, yHAFeesWithdraw, 0);

    const xSlippage = [
      parseAmount.gwei('0.5'),
      parseAmount.gwei('1'),
      parseAmount.gwei('1.2'),
      parseAmount.gwei('1.5'),
    ];
    const ySlippage = [
      parseAmount.gwei('0.5'),
      parseAmount.gwei('0.2'),
      parseAmount.gwei('0.1'),
      parseAmount.gwei('0'),
    ];
    const xSlippageFee = [
      parseAmount.gwei('0.5'),
      parseAmount.gwei('1'),
      parseAmount.gwei('1.2'),
      parseAmount.gwei('1.5'),
    ];
    const ySlippageFee = [
      parseAmount.gwei('0.75'),
      parseAmount.gwei('0.5'),
      parseAmount.gwei('0.15'),
      parseAmount.gwei('0'),
    ];

    await feeManager.connect(governor).setFees(xSlippage, ySlippage, 3);
    await feeManager.connect(governor).setFees(xSlippageFee, ySlippageFee, 0);
  }

  const xBonusMalusMint = [parseAmount.gwei('0.5'), parseAmount.gwei('1')];
  const yBonusMalusMint = [parseAmount.gwei('0.8'), parseAmount.gwei('1')];
  const xBonusMalusBurn = [
    parseAmount.gwei('0'),
    parseAmount.gwei('0.5'),
    parseAmount.gwei('1'),
    parseAmount.gwei('1.3'),
    parseAmount.gwei('1.5'),
  ];
  const yBonusMalusBurn = [
    parseAmount.gwei('10'),
    parseAmount.gwei('4'),
    parseAmount.gwei('1.5'),
    parseAmount.gwei('1'),
    parseAmount.gwei('1'),
  ];
  await feeManager.connect(governor).setFees(xBonusMalusMint, yBonusMalusMint, 1);
  await feeManager.connect(governor).setFees(xBonusMalusBurn, yBonusMalusBurn, 2);
  await feeManager.connect(governor).setHAFees(parseAmount.gwei('1'), parseAmount.gwei('1'));

  await stableMaster
    .connect(governor)
    .setIncentivesForSLPs(parseAmount.gwei('0.5'), parseAmount.gwei('0.5'), manager.address);
  await stableMaster
    .connect(governor)
    .setCapOnStableAndMaxInterests(
      parseAmount.ether('1000000000000'),
      parseAmount.ether('1000000000000'),
      manager.address,
    );

  // Limit HA hedge should always be set before the target HA hedge
  await perpetualManager.connect(governor).setTargetAndLimitHAHedge(parseAmount.gwei('0.9'), parseAmount.gwei('0.95'));
  await perpetualManager.connect(governor).setBoundsPerpetual(parseAmount.gwei('3'), parseAmount.gwei('0.0625'));
  await perpetualManager.connect(governor).setKeeperFeesLiquidationRatio(parseAmount.gwei('0.2'));
  await perpetualManager.connect(governor).setKeeperFeesCap(parseAmount.ether('100'), parseAmount.ether('100'));
  const xKeeperFeesClosing = [parseAmount.gwei('0.25'), parseAmount.gwei('0.5'), parseAmount.gwei('1')];
  const yKeeperFeesClosing = [parseAmount.gwei('0.1'), parseAmount.gwei('0.6'), parseAmount.gwei('1')];
  await perpetualManager.connect(governor).setKeeperFeesClosing(xKeeperFeesClosing, yKeeperFeesClosing);

  await feeManager.connect(governor).updateUsersSLP();
  await feeManager.connect(governor).updateHA();

  await stableMaster
    .connect(governor)
    .unpause('0xfb286912c6eadba541f23a3bb3e83373ab139b6e65d84e2a473c186efc2b4642', manager.address);
  await stableMaster
    .connect(governor)
    .unpause('0xe0136b3661826a483734248681e4f59ae66bc6065ceb43fdd469ecb22c21d745', manager.address);
  await perpetualManager.connect(governor).unpause();

  return { token, oracle, manager, sanToken, perpetualManager, feeManager };
}

export function piecewiseFunction(value: BigNumber, xArray: BigNumber[], yArray: BigNumber[]): BigNumber {
  if (value.gte(xArray[xArray.length - 1])) return yArray[yArray.length - 1];
  if (value.lte(xArray[0])) return yArray[0];

  let i = 0;
  while (value.gte(xArray[i + 1])) {
    i += 1;
  }
  const pct = value
    .sub(xArray[i])
    .mul(BASE)
    .div(xArray[i + 1].sub(xArray[i]));
  const normalized = pct
    .mul(yArray[i + 1].sub(yArray[i]))
    .div(BASE)
    .add(yArray[i]);

  return normalized;
}
