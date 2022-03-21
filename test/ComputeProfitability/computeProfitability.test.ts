import { expect } from 'chai';
import { BigNumber } from 'ethers';
import { formatUnits, parseUnits } from 'ethers/lib/utils';
import { ethers } from 'hardhat';
import { ComputeProfitability, ComputeProfitability__factory } from '../../typechain';
import { expectApproxDelta } from '../../utils/bignumber';

const PRECISION = 6;
let computeProfitabilityContract: ComputeProfitability;
let priceAave: number;
let paramsBorrow: SCalculateBorrow;

export type SCalculateBorrow = {
  reserveFactor: BigNumber;
  totalStableDebt: BigNumber;
  totalVariableDebt: BigNumber;
  totalDeposits: BigNumber;
  stableBorrowRate: BigNumber;
  rewardDeposit: BigNumber;
  rewardBorrow: BigNumber;
  strategyAssets: BigNumber;
  maxCollatRatio: BigNumber;
  slope1: BigNumber;
  slope2: BigNumber;
  r0: BigNumber;
  uOptimal: BigNumber;
};

describe('AaveFlashLoanStrategy - ComputeProfitability', () => {
  before(async () => {
    const [deployer] = await ethers.getSigners();
    computeProfitabilityContract = (await new ComputeProfitability__factory(deployer).deploy()) as ComputeProfitability;
  });

  describe('Testing Optim', () => {
    beforeEach('Fix borrow Params', () => {
      const wantDecimal = 6;
      priceAave = 130;
      const priceMultiplier = BigNumber.from(Math.floor(priceAave * 60 * 60 * 24 * 365));
      const rewardDeposit = BigNumber.from('1903258773510960').mul(priceMultiplier);
      const rewardBorrow = BigNumber.from('3806517547021920').mul(priceMultiplier);
      const totalStableDebt = BigNumber.from('11958029754937');
      const totalVariableDebt = BigNumber.from('1425711403399322');
      const totalLiquidity = BigNumber.from('812664505140562');
      paramsBorrow = {
        reserveFactor: parseUnits('0.1', 27),
        totalStableDebt: parseUnits(totalStableDebt.toString(), 27 - wantDecimal),
        totalVariableDebt: parseUnits(totalVariableDebt.toString(), 27 - wantDecimal),
        totalDeposits: parseUnits(
          totalLiquidity.add(totalStableDebt).add(totalVariableDebt).toString(),
          27 - wantDecimal,
        ),
        stableBorrowRate: BigNumber.from('108870068051917638359824820'),
        rewardDeposit: parseUnits(rewardDeposit.toString(), 27 - 18),
        rewardBorrow: parseUnits(rewardBorrow.toString(), 27 - 18),
        strategyAssets: parseUnits('1000000', 27),
        maxCollatRatio: parseUnits('0.9', 27),
        slope1: parseUnits('0.04', 27),
        slope2: parseUnits('0.6', 27),
        r0: parseUnits('0', 27),
        uOptimal: parseUnits('0.9', 27),
      };
    });
    it('1st case - rates and revenues', async () => {
      const toBorrow = parseUnits('100000', 27);
      const ratesPrimes = await computeProfitabilityContract.calculateInterestPrimes(toBorrow, paramsBorrow);
      const revenuePrimes = await computeProfitabilityContract.revenuePrimes(toBorrow, paramsBorrow, false);

      expectApproxDelta(ratesPrimes[0], parseUnits('2.8394907581318844', 25), parseUnits('1', PRECISION));
      expectApproxDelta(ratesPrimes[1], parseUnits('7131752054577753', 0), parseUnits('1', PRECISION));
      expectApproxDelta(ratesPrimes[2], parseUnits('-6338112', 0), parseUnits('1', PRECISION));

      expectApproxDelta(revenuePrimes[0], parseUnits('2.0451974884293873', 31), parseUnits('1', PRECISION));
      expectApproxDelta(revenuePrimes[1], parseUnits('2.7347712665372165', 24), parseUnits('1', PRECISION));
      expectApproxDelta(revenuePrimes[2], parseUnits('-1.6707144318562614', 16), parseUnits('1', PRECISION));
    });
    it('2nd case - rates and revenues', async () => {
      const toBorrow = parseUnits('200000', 27);
      const ratesPrimes = await computeProfitabilityContract.calculateInterestPrimes(toBorrow, paramsBorrow);
      const revenuePrimes = await computeProfitabilityContract.revenuePrimes(toBorrow, paramsBorrow, false);

      expectApproxDelta(ratesPrimes[0], parseUnits('2.8395620724835146', 25), parseUnits('1', PRECISION));
      expectApproxDelta(ratesPrimes[1], parseUnits('7131118285542997', 0), parseUnits('1', PRECISION));
      expectApproxDelta(ratesPrimes[2], parseUnits('-6337267', 0), parseUnits('1', PRECISION));

      expectApproxDelta(revenuePrimes[0], parseUnits('2.0725368481954744', 31), parseUnits('1', PRECISION));
      expectApproxDelta(revenuePrimes[1], parseUnits('2.733100753962924', 24), parseUnits('1', PRECISION));
      expectApproxDelta(revenuePrimes[2], parseUnits('-1.6703107360771058', 16), parseUnits('1', PRECISION));
    });
    it('3rd case - rates and revenues', async () => {
      const toBorrow = parseUnits('79312137', 27);
      const ratesPrimes = await computeProfitabilityContract.calculateInterestPrimes(toBorrow, paramsBorrow);
      const revenuePrimes = await computeProfitabilityContract.revenuePrimes(toBorrow, paramsBorrow, false);

      expectApproxDelta(ratesPrimes[0], parseUnits('2.8940620565909253', 25), parseUnits('1', PRECISION));
      expectApproxDelta(ratesPrimes[1], parseUnits('6655012554459868', 0), parseUnits('1', PRECISION));
      expectApproxDelta(ratesPrimes[2], parseUnits('-5713324', 0), parseUnits('1', PRECISION));

      expectApproxDelta(revenuePrimes[0], parseUnits('1.878279888231759', 32), parseUnits('1', PRECISION));
      expectApproxDelta(revenuePrimes[1], parseUnits('1.5290286055725022', 24), parseUnits('1', PRECISION));
      expectApproxDelta(revenuePrimes[2], parseUnits('-1.3842598981251928', 16), parseUnits('1', PRECISION));
    });
    it('1st case - optimal borrow', async () => {
      const optimalBorrow = await computeProfitabilityContract.computeProfitability(paramsBorrow);
      const optimalRevenue = await computeProfitabilityContract.revenuePrimes(optimalBorrow, paramsBorrow, false);

      expectApproxDelta(optimalBorrow, parseUnits('2.06699448', 8 + 27), parseUnits('1', PRECISION));
      expectApproxDelta(optimalRevenue[0], parseUnits('280521.08056477', 27), parseUnits('1', PRECISION));
    });
    it('2nd case - optimal borrow', async () => {
      const wantDecimal = 6;
      priceAave = 130;
      const priceMultiplier = BigNumber.from(Math.floor(priceAave * 60 * 60 * 24 * 365));
      const rewardDeposit = BigNumber.from('2903258773510960').mul(priceMultiplier);
      const rewardBorrow = BigNumber.from('2806517547021920').mul(priceMultiplier);
      const totalStableDebt = BigNumber.from('11958029754937');
      const totalVariableDebt = BigNumber.from('1425711403399322');
      const totalLiquidity = BigNumber.from('812664505140562');
      paramsBorrow = {
        reserveFactor: parseUnits('0.1', 27),
        totalStableDebt: parseUnits(totalStableDebt.toString(), 27 - wantDecimal),
        totalVariableDebt: parseUnits(totalVariableDebt.toString(), 27 - wantDecimal),
        totalDeposits: parseUnits(
          totalLiquidity.add(totalStableDebt).add(totalVariableDebt).toString(),
          27 - wantDecimal,
        ),
        stableBorrowRate: BigNumber.from('108870068051917638359824820'),
        rewardDeposit: parseUnits(rewardDeposit.toString(), 27 - 18),
        rewardBorrow: parseUnits(rewardBorrow.toString(), 27 - 18),
        strategyAssets: parseUnits('27000000', 27),
        maxCollatRatio: parseUnits('0.9', 27),
        slope1: parseUnits('0.04', 27),
        slope2: parseUnits('0.6', 27),
        r0: parseUnits('0', 27),
        uOptimal: parseUnits('0.9', 27),
      };

      const optimalBorrow = await computeProfitabilityContract.computeProfitability(paramsBorrow);
      const optimalRevenue = await computeProfitabilityContract.revenuePrimes(optimalBorrow, paramsBorrow, false);

      expectApproxDelta(optimalBorrow, parseUnits('1.50829743', 8 + 27), parseUnits('1', PRECISION));
      expectApproxDelta(optimalRevenue[0], parseUnits('723965.6979702', 27), parseUnits('1', PRECISION));
    });
  });
});
