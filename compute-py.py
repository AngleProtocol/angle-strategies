import matplotlib.pyplot as plt
from matplotlib import cm
import numpy as np


# currently deposited assets on the poolManager
poolManagerFund = 168439706352281000000000000000000000 / 10**27
# current deposits on compound 
compDeposit = 2327880275443382000000000000000000000 / 10**27
# current stable borrows on compound 
compBorrowStable = 12952786073367000000000000000000000 / 10**27
# current variable borrows on compound 
compBorrowVariable = 1350219982386577000000000000000000000 / 10**27 / 8
# optimal utilisation ratio
uOptimal = 0.9
# base rate 
r0 = 0
# slope borrow rate before U optimal
slope1 = 0.04
# slope borrow rate after U optimal
slope2 = 0.6
# fixed borow rate
rFixed = 103013007441955644227054734 / 10**27
# reserve factor
rf = 0.1
# rewards per second (in dollar) in farm tokens from deposits
rewardDeposit = 1903258773510960000000000 * 60 * 60 * 24 * 365 / 10**27 # this is as if there was 150$ distributed each week
# rewards per second (in dollar) in farm tokens from borrows
rewardBorrow = 10*3806517547021920000000000 * 60 * 60 * 24 * 365 / 10**27

# TODO gradient are really low maybe only check for delta between bs 
# epsilon for Gradient descent to stop
epsGD = 10**(-12)
# epsilon for Newton method to stop
epsNR = 10**(-12)
# tolerance on diff between b on GD
tolGD = 10**(-1)
# tolerance on diffbetween b on Newton Raphson
tolNR = 10**(-1)
# max iteration methods
maxCount = 30

# # different borrow 
b = np.arange(0, poolManagerFund , poolManagerFund/10000)
# # if we only consider the rewards from borrow as the full revenue will only be a translation of the one only considering borrow rewards
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

plt.plot(b,allRevenuesPrime)
plt.savefig("plt2.png")


def computeAlpha(count):
    return 0.5*10**10

def gradientDescent(bInit, epsilon, tol):
    grad = epsilon + 1
    b = bInit
    count = 0
    if(revenue(np.array([1]))[0]<revenue(np.array([0]))[0]):
        return(0,1)
    while(np.greater(np.abs(grad),epsilon) and (count==0 or np.greater(np.abs(bInit-b),tol)) and maxCount>count):
        grad = - revenuePrime(b)
        alpha = computeAlpha(count)
        bInit = b
        b = bInit - alpha * grad
        count +=1

    return(b,count)

def newtonRaphson(bInit, epsilon, tol):
    grad = tol + 1
    grad2nd = grad
    b = bInit
    count = 0
    if(revenue(np.array([1]))[0]<revenue(np.array([0]))[0]):
        return(0,1)
    while(np.greater(np.abs(grad2nd),epsilon) and (count==0 or np.greater(np.abs(bInit-b),tol)) and maxCount>count):
        grad = - revenuePrime(b)
        grad2nd = - revenuePrime2nd(b)
        bInit = b
        b = bInit - grad / grad2nd
        count +=1
        print(count)

    return(b,count)

# bSol,count = gradientDescent(np.array([poolManagerFund]), epsGD, tolGD)
# print('Gradient descent method: We get in %s from the optimisation :%s', count,bSol)

bSolNR,countNR = newtonRaphson(np.array([poolManagerFund]), epsNR ,tolNR)
print('Newton raphson method: We get in {} from the optimisation :{}', countNR,bSolNR)


# fig, ax = plt.subplots(subplot_kw={"projection": "3d"})

# X, Y = np.meshgrid(b, rewards)
# allRevenues3D = revenue3D(X,Y)

# # Plot the surface.
# surf = ax.plot_surface(X, Y, allRevenues3D, cmap=cm.coolwarm,
#                        linewidth=0, antialiased=False)

# # plt.show()
# plt.savefig("plt.png")

arr = np.array([0, 1, 5, 10, 100, 1000, 58749, 100000, 3089873, 28746827])

# res1 = [
# 26026019041919173758309758,
# 26026019049831275419596907,
# 26026019081479681996768626,
# 26026019121040190065285300,
# 26026019833129306238471561,
# 26026026954017439601866892,
# 26026483858249245669133776,
# 26026810218098663395004295,
# 26050434024406951118702356,
# 26250692384642694385757352
# ]
# for i,val in enumerate(computeInterestRate(arr)):
#     print(val * 10**17)
#     print(res1[i])

# print("")

# res2 = [
# 7912101664685993,
# 7912101657888305,
# 7912101630697554,
# 7912101596709115,
# 7912100984917257,
# 7912094867002581,
# 7911702322443344,
# 7911421939706082,
# 7891139417774604,
# 7720250709557837,
# ]
# for i,val in enumerate(interestRatePrime(arr)):
#     print(val * 10**27)
#     print(res2[i])

# print("")

# res3 = [
# -6797687,
# -6797687,
# -6797687,
# -6797687,
# -6797686,
# -6797679,
# -6797173,
# -6796811,
# -6770691,
# -6551949,
# ]
# for i,val in enumerate(interestRatePrime2nd(arr)):
#     print(val * 10**27)
#     print(res3[i])

# print("")
# res4 = [
# 2379670543812338783344954513657837 ,
# 2379670534162973065750615109418929 ,
# 2379670495565510179252556432342650 ,
# 2379670447318681534858406609523886 ,
# 2379669578875759044165647340617037 ,
# 2379660894445815961714392285537344 ,
# 2379103650444209168890476108389167 ,
# 2378705599182043589020665488730977,
# 2349847584782967144713271195022879,
# 2101656068332964648010446696573724,
# ]
# for i,val in enumerate(revenue(arr)):
#     print(val * 10**27)
#     print(res4[i])

# print("")
# res5 = [
# -9649365716788304384030022,
# -9649365718400374498206115,
# -9649365724848654878986905,
# -9649365732909005130393012,
# -9649365877995264504408393,
# -9649367328853222424279269,
# -9649460406338616491643354,
# -9649526871774563362923613,
# -9654297297556283738680427,
# -9691537873413962027602059,
# ]
# for i,val in enumerate(revenuePrime(arr)):
#     print(val * 10**27)
#     print(res5[i])

# print("")
# res6 = [
# -1612070023823331,
# -1612070028671364,
# -1612069975113178,
# -1612069926403025,
# -1612068998166719,
# -1612059687791531,
# -1611458802277070,
# -1611029555932478,
# -1580075954186488,
# -1326386620559395,
# ]
# for i,val in enumerate(revenuePrime2nd(arr)):
#     print(val * 10**27)
#     print(res6[i])


