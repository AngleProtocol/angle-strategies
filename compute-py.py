import matplotlib.pyplot as plt
import numpy as np

# price AAVE
price_Aave = 127

# # for DAI on Aave 
# # currently deposited assets on the poolManager
# poolManagerFund = 168439706352281000000000000000000000 / 10**27
# # current deposits on compound 
# compDeposit = 2327880275443382000000000000000000000 / 10**27
# # current stable borrows on compound 
# compBorrowStable = 12952786073367000000000000000000000 / 10**27
# # current variable borrows on compound 
# compBorrowVariable = 1350219982386577000000000000000000000 / 10**27
# # optimal utilisation ratio
# uOptimal = 0.9
# # base rate 
# r0 = 0
# # slope borrow rate before U optimal
# slope1 = 0.04
# # slope borrow rate after U optimal
# slope2 = 0.6
# # fixed borow rate
# rFixed = 103013007441955644227054734 / 10**27
# # reserve factor
# rf = 0.1
# # rewards per second (in dollar) in farm tokens from deposits
# rewardDeposit = price_Aave * 1903258773510960000000000 * 60 * 60 * 24 * 365/ 10**27 # this is as if there was 150$ distributed each week
# # rewards per second (in dollar) in farm tokens from borrows
# rewardBorrow = price_Aave * 3806517547021920000000000 * 60 * 60 * 24 * 365 / 10**27


# for USDC on Aave 
# currently deposited assets on the poolManager
poolManagerFund = 2000000.0
# current stable borrows on compound 
compBorrowStable = 12293507.852921
# current variable borrows on compound 
compBorrowVariable = 1387980428.907538
# current deposits on compound 
compDeposit = 2069734850.295572 # 669460913.5351131 + compBorrowStable + compBorrowVariable
# optimal utilisation ratio
uOptimal = 0.9
# base rate 
r0 = 0
# slope borrow rate before U optimal
slope1 = 0.04
# slope borrow rate after U optimal
slope2 = 0.6
# average fixed borow rate
rFixed = 0.10863054577400451
# reserve factor
rf = 0.1
# rewards per second (in dollar) in farm tokens from deposits
rewardDeposit = 6198502.5307997195
# rewards per second (in dollar) in farm tokens from borrows
rewardBorrow = 12397005.061599439

# params iteravite method
# tolerance on diff between b on GD
tolGD = 10**(-1)
# tolerance on diffbetween b on Newton Raphson
tolNR = 10**(-1)
# max iteration methods
maxCount = 30

maxCollatRatio = 0.845

# different borrow 
b = np.arange(0, compDeposit / 10, compDeposit/1000)
# if we only consider the rewards from borrow as the full revenue will only be a translation of the one only considering borrow rewards
rewards = np.arange(0, 0.1, 0.005)


def computeInterestRate(b):
    newUtilisation = (compBorrowVariable + b + compBorrowStable) / (compDeposit+ b)

    interests = np.zeros_like(newUtilisation)
    mask = newUtilisation <= uOptimal

    interests[mask] = r0 + slope1 * newUtilisation[mask] / uOptimal 
    interests[~mask] = r0 + slope1 + slope2 * (newUtilisation[~mask] - uOptimal) / (1-uOptimal) 

    return interests

def interestRatePrime(b):
    newUtilisation = (compBorrowVariable + b + compBorrowStable) / (compDeposit+ b)

    derInterests = np.zeros_like(newUtilisation)
    mask = newUtilisation <= uOptimal

    uprime = (compDeposit - compBorrowStable - compBorrowVariable) / (compDeposit + b)**2
    derInterests[mask] = slope1 * uprime[mask] / uOptimal 
    derInterests[~mask] = slope2 * uprime[~mask] / (1-uOptimal)

    return derInterests

def interestRatePrime2nd(b):
    newUtilisation = (compBorrowVariable + b + compBorrowStable) / (compDeposit+ b)

    derInterests = np.zeros_like(newUtilisation)
    mask = newUtilisation <= uOptimal

    uprime = - 2* (compDeposit - compBorrowStable - compBorrowVariable) / (compDeposit + b)**3
    derInterests[mask] = slope1 * uprime[mask] / uOptimal
    derInterests[~mask] = slope2 * uprime[~mask] / (1-uOptimal)

    return derInterests

def revenue(b):
    newRate = computeInterestRate(b)
    newPoolDeposit = b + poolManagerFund
    newCompDeposit = b + compDeposit
    newCompBorrowVariable = b + compBorrowVariable
    newCompBorrow = newCompBorrowVariable + compBorrowStable

    f1 = newPoolDeposit / newCompDeposit * (1-rf)
    f2 = compBorrowStable * rFixed  + newCompBorrowVariable * newRate

    depositRate = f2 * (1-rf)/ newCompDeposit
    earnings = f1*f2
    cost = b * newRate
    rewards = b * rewardBorrow / newCompBorrow + newPoolDeposit * rewardDeposit /newCompDeposit
    return  earnings + rewards - cost


def revenuePrime(b):
    newRate = computeInterestRate(b)
    newRatePrime = interestRatePrime(b)

    newPoolDeposit = b + poolManagerFund
    newCompDeposit = b + compDeposit
    newCompBorrowVariable = b + compBorrowVariable
    newCompBorrow = newCompBorrowVariable + compBorrowStable

    f1 = newPoolDeposit / newCompDeposit * (1-rf)
    f2 = compBorrowStable * rFixed  + newCompBorrowVariable * newRate
    f1prime = (compDeposit - poolManagerFund) * (1-rf) / newCompDeposit**2 
    f2prime = newRate + newCompBorrowVariable * newRatePrime
    f3prime = newRate + b * newRatePrime
    f4prime =  rewardBorrow * (compBorrowStable + compBorrowVariable) / newCompBorrow**2 
    f5prime =  rewardDeposit * (compDeposit - poolManagerFund) / newCompDeposit**2

    derivate = f1prime*f2 + f2prime*f1 - f3prime + f4prime + f5prime
    return  derivate

def revenuePrime2nd(b):
    newRate = computeInterestRate(b)
    newRatePrime = interestRatePrime(b)
    newRatePrime2nd = interestRatePrime2nd(b)

    newPoolDeposit = b + poolManagerFund
    newCompDeposit = b + compDeposit
    newCompBorrowVariable = b + compBorrowVariable
    newCompBorrow = newCompBorrowVariable + compBorrowStable

    f1 = newPoolDeposit / newCompDeposit * (1-rf)
    f2 = compBorrowStable * rFixed  + newCompBorrowVariable * newRate
    f1prime = (compDeposit - poolManagerFund) * (1-rf) / newCompDeposit**2 
    f2prime = newRate + newCompBorrowVariable * newRatePrime
    f1prime2nd = - (compDeposit - poolManagerFund) * (1-rf) *2 / newCompDeposit**3
    f2prime2nd = newRatePrime + newRatePrime + newCompBorrowVariable * newRatePrime2nd
    f3prime2nd = newRatePrime + newRatePrime + b * newRatePrime2nd
    f4prime2nd =  - rewardBorrow * (compBorrowStable + compBorrowVariable) * 2/ newCompBorrow**3 
    f5prime2nd =  - rewardDeposit * (compDeposit - poolManagerFund) * 2 / newCompDeposit**3

    derivate = f1prime2nd*f2 + f1prime*f2prime + f2prime*f1prime + f2prime2nd*f1 - f3prime2nd + f4prime2nd + f5prime2nd
    return  derivate

def revenue3D(b, rewards):
    newRate = computeInterestRate(b)
    newPoolDeposit = b + poolManagerFund
    newCompDeposit = b + compDeposit
    newCompBorrowVariable = b + compBorrowVariable

    earnings = newPoolDeposit * (1-rf) * (compBorrowStable * rFixed  + newCompBorrowVariable * newRate) / newCompDeposit
    cost = b * newRate
    rewards = b * rewards # as it doesn' impact the optimisation
    return  earnings + rewards - cost

allRevenues = revenue(b)
allRevenuesPrime = revenuePrime(b)

# during optim we should first check whether current apr: depositInterest +  rewardDeposit + rewardBorrow - borrowFees > 0
# otherwise your leverage should be 0 as fold is not profitable

plt.plot(b,allRevenues)
plt.savefig("plt1.png")
plt.show()

plt.plot(b,allRevenuesPrime)
plt.savefig("plt2.png")
plt.show()


def computeAlpha(count):
    return 0.5*10**10

def gradientDescent(bInit, tol):
    grad = 0
    b = bInit
    count = 0
    if(revenue(np.array([1]))[0]<revenue(np.array([0]))[0]):
        return(0,1)
    while((count==0 or np.greater(np.abs(bInit-b),tol)) and maxCount>count):
        grad = - revenuePrime(b)
        alpha = computeAlpha(count)
        bInit = b
        b = bInit - alpha * grad
        count +=1

    return(b,count)

def newtonRaphson(bInit, tol):
    grad = 0
    grad2nd = grad
    b = bInit
    count = 0

    print(revenue(np.array([1])))
    print(revenue(np.array([0])))
    if(revenue(np.array([1]))[0]<revenue(np.array([0]))[0]):
        return(0,1)
    while((count==0 or np.greater(np.abs(bInit-b),tol)) and maxCount>count):
        grad = - revenuePrime(b)
        grad2nd = - revenuePrime2nd(b)
        bInit = b
        b = bInit - grad / grad2nd
        count +=1

    collatRatio = b / (poolManagerFund + b)
    print("collatRatio", collatRatio)
    if (collatRatio > maxCollatRatio):
        b = maxCollatRatio * poolManagerFund / (1-maxCollatRatio)

    return(b,count)

# bSol,count = gradientDescent(np.array([poolManagerFund]), tolGD)
# print('Gradient descent method: We get in %s from the optimisation :%s', count,bSol)

bSolNR,countNR = newtonRaphson(np.array([poolManagerFund]) ,tolNR)
print('Newton raphson method: We get in {} from the optimisation :{}', countNR,bSolNR)


# fig, ax = plt.subplots(subplot_kw={"projection": "3d"})

# X, Y = np.meshgrid(b, rewards)
# allRevenues3D = revenue3D(X,Y)

# # Plot the surface.
# surf = ax.plot_surface(X, Y, allRevenues3D, cmap=cm.coolwarm,
#                        linewidth=0, antialiased=False)

# plt.show()
