# import matplotlib.pyplot as plt
import numpy as np


# currently deposited assets on the poolManager
poolManagerFund = 168439706352281000000000000000000000 / 10**27
# current deposits on compound 
compDeposit = 2327880275443382000000000000000000000 / 10**27
# current stable borrows on compound 
compBorrowStable = 12952786073367000000000000000000000 / 10**27
# current variable borrows on compound 
compBorrowVariable = 1350219982386577000000000000000000000 / 10**27
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

# different borrow 
b = np.arange(0, poolManagerFund , poolManagerFund/10000)
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
    derInterests[mask] = slope1 / uOptimal * uprime[mask]
    derInterests[~mask] = slope2 / (1-uOptimal) * uprime[~mask]

    return derInterests

def interestRatePrime2nd(b):
    newUtilisation = (compBorrowVariable + b + compBorrowStable) / (compDeposit+ b)

    derInterests = np.zeros_like(newUtilisation)
    mask = newUtilisation <= uOptimal

    uprime = - 2* (compDeposit - compBorrowStable - compBorrowVariable) / (compDeposit + b)**3
    derInterests[mask] = slope1 / uOptimal * uprime[mask]
    derInterests[~mask] = slope2 / (1-uOptimal) * uprime[~mask]

    return derInterests

def revenue(b):
    newRate = computeInterestRate(b)
    newPoolDeposit = b + poolManagerFund
    newCompDeposit = b + compDeposit
    newCompBorrowVariable = b + compBorrowVariable

    f1 = newPoolDeposit / newCompDeposit * (1-rf)
    f2 = compBorrowStable * rFixed  + newCompBorrowVariable * newRate

    earnings = f1*f2
    cost = b * newRate
    rewards = b / (compBorrowStable+newCompBorrowVariable) * rewardBorrow + newPoolDeposit/newCompDeposit * rewardDeposit
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
    f4prime =  rewardBorrow * (compBorrowStable + compBorrowVariable) / newCompBorrow**2 + rewardDeposit * (compDeposit - poolManagerFund) / newPoolDeposit**2

    derivate = f1prime*f2 + f2prime*f1 - f3prime + f4prime
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
    f4prime2nd =  - rewardBorrow * (compBorrowStable + compBorrowVariable) * 2/ newCompBorrow**3 - rewardDeposit * (compDeposit - poolManagerFund) * 2 / newPoolDeposit**3

    derivate = f1prime2nd*f2 + f1prime*f2prime + f2prime*f1prime + f2prime2nd*f1 - f3prime2nd + f4prime2nd
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

# plt.plot(b,allRevenues)
# plt.show()

# plt.plot(b,allRevenuesPrime)
# plt.show()


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

    return(b,count)

bSol,count = gradientDescent(np.array([poolManagerFund]), epsGD, tolGD)

print('Gradient descent method: We get in %s from the optimisation :%s', count,bSol)

bSolNR,countNR = newtonRaphson(np.array([poolManagerFund]), epsNR ,tolNR)

print('Newton raphson method: We get in {} from the optimisation :{}', countNR,bSolNR)


# fig, ax = plt.subplots(subplot_kw={"projection": "3d"})

# X, Y = np.meshgrid(b, rewards)
# allRevenues3D = revenue3D(X,Y)

# # Plot the surface.
# surf = ax.plot_surface(X, Y, allRevenues3D, cmap=cm.coolwarm,
#                        linewidth=0, antialiased=False)

# plt.show()

arr = np.array([0, 1, 5, 10, 100, 1000, 58749, 100000, 3089873, 28746827])

res1 = [
26616602537848525433819048 ,
26616602544942786735178637 ,
26616602573319831884156381 ,
26616602608791138193342183 ,
26616603247274627621776001 ,
26616609632107006586949724 ,
26617019308862577744175521 ,
26617311935749760901967919 ,
26638495985043111725348189 ,
26818233528846130678991097 ,
]
for i,val in enumerate(computeInterestRate(arr)):
    print(val * 10**17)
    print(res1[i])

print("")

res2 = [
7094261304182619 ,
7094261298536558 ,
7094261275952313 ,
7094261247722007 ,
7094260739576530 ,
7094255658124765 ,
7093929615363163 ,
7093696731759579 ,
7076847814970011 ,
6934698079518307 ,
]
for i,val in enumerate(interestRatePrime(arr)):
    print(val * 10**27)
    print(res2[i])

print("")

res3 = [
-5646061,
-5646061,
-5646061,
-5646061,
-5646060,
-5646054,
-5645665,
-5645387,
-5625285,
-5456650,
]
for i,val in enumerate(interestRatePrime2nd(arr)):
    print(val * 10**27)
    print(res3[i])

print("")
res4 = [
2479727464860833275815169190498434 ,
2479727454223068978709793328093782 ,
2479727411672011791140829499698658 ,
2479727358483190308597839037086472 ,
2479726401084403987285561786574571 ,
2479716827096578755732098452933863 ,
2479102506993456749978861194786366 ,
2478663688858334913504449232349283 ,
2446858559012809815178863307286320 ,
2173982702258861724008118286134272 ,
]
for i,val in enumerate(revenue(arr)):
    print(val * 10**27)
    print(res4[i])

print("")
res5 = [
-10637764137340206900705414,
-10637764137254954779464458,
-10637764136913946423107670,
-10637764136487685857145678,
-10637764128814970988198709,
-10637764052085291372289899,
-10637759119063283859724042,
-10637755583732043994211602,
-10637473690864349485001585,
-10633036905268623741363881,
]
for i,val in enumerate(revenuePrime(arr)):
    print(val * 10**27)
    print(res5[i])

print("")
res6 = [
85252131951110,
85252123975911,
85252133181432,
85252175518071,
85252739794720,
85257817185732,
85585819409418,
85820101274660,
102718101792698,
241227315872567,
]
for i,val in enumerate(revenuePrime2nd(arr)):
    print(val * 10**27)
    print(res6[i])


