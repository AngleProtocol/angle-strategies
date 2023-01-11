// SPDX-License-Identifier: GPL-3.0

pragma solidity ^0.8.17;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import "../BaseStrategyUpgradeable.sol";
import "../../interfaces/IGenericLender.sol";

struct LendStatus {
    string name;
    uint256 assets;
    uint256 rate;
    address add;
}

struct LenderRatio {
    address lender;
    uint16 share; // basis point
}

/// @title OptimizerAPRSharesStrategy
/// @author Angle Labs, Inc.
/// @notice A lender optimisation strategy for any ERC20 asset, leverage multiple lenders at once
/// @dev This strategy works by taking plugins designed for standard lending platforms
/// It automatically chooses the best yield generating platform and adjusts accordingly
/// The adjustment is sub optimal so there is an additional option to manually set position if the
/// manual allocation is better than the greedy one
contract OptimizerAPRSharesStrategy is BaseStrategyUpgradeable {
    using SafeERC20 for IERC20;
    using Address for address;

    // ================================= CONSTANTS =================================
    uint64 internal constant _BPS = 10000;

    // ============================ CONTRACTS REFERENCES ===========================
    IGenericLender[] public lenders;

    // ================================= PARAMETERS ================================
    uint256 public withdrawalThreshold;

    // =================================== EVENTS ==================================
    event AddLender(address indexed lender);
    event RemoveLender(address indexed lender);

    // =================================== ERRORS ==================================
    error IncorrectListLength();
    error InvalidShares();
    error UndockedLender();
    error LenderAlreadyAdded();
    error FailedWithdrawal();
    error NonExistentLender();

    /// @notice Constructor of the `Strategy`
    /// @param _poolManager Address of the `PoolManager` lending to this strategy
    /// @param governor Address with governor privilege
    /// @param guardian Address of the guardian
    function initialize(
        address _poolManager,
        address governor,
        address guardian,
        address[] memory keepers
    ) external {
        _initialize(_poolManager, governor, guardian, keepers);
        withdrawalThreshold = 1000 * wantBase;
    }

    // ============================= INTERNAL FUNCTIONS ============================

    /// @notice Frees up profit plus `_debtOutstanding`.
    /// @param _debtOutstanding Amount to withdraw
    /// @return _profit Profit freed by the call
    /// @return _loss Loss discovered by the call
    /// @return _debtPayment Amount freed to reimburse the debt
    /// @dev If `_debtOutstanding` is more than we can free we get as much as possible.
    function _prepareReturn(uint256 _debtOutstanding)
        internal
        override
        returns (
            uint256 _profit,
            uint256 _loss,
            uint256 _debtPayment
        )
    {
        _profit = 0;
        _loss = 0; //for clarity
        _debtPayment = _debtOutstanding;

        uint256 lentAssets = lentTotalAssets();

        uint256 looseAssets = want.balanceOf(address(this));

        uint256 total = looseAssets + lentAssets;

        if (lentAssets == 0) {
            // No position to harvest or profit to report
            if (_debtPayment > looseAssets) {
                // We can only return looseAssets
                _debtPayment = looseAssets;
            }

            return (_profit, _loss, _debtPayment);
        }

        uint256 debt = poolManager.strategies(address(this)).totalStrategyDebt;

        if (total > debt) {
            _profit = total - debt;

            uint256 amountToFree = _profit + _debtPayment;
            // We need to add outstanding to our profit
            // don't need to do logic if there is nothing to free
            if (amountToFree > 0 && looseAssets < amountToFree) {
                // Withdraw what we can withdraw
                _withdrawSome(amountToFree - looseAssets);
                uint256 newLoose = want.balanceOf(address(this));

                // If we dont have enough money adjust _debtOutstanding and only change profit if needed
                if (newLoose < amountToFree) {
                    if (_profit > newLoose) {
                        _profit = newLoose;
                        _debtPayment = 0;
                    } else {
                        _debtPayment = Math.min(newLoose - _profit, _debtPayment);
                    }
                }
            }
        } else {
            // Serious loss should never happen but if it does lets record it accurately
            _loss = debt - total;

            uint256 amountToFree = _loss + _debtPayment;
            if (amountToFree > 0 && looseAssets < amountToFree) {
                // Withdraw what we can withdraw

                _withdrawSome(amountToFree - looseAssets);
                uint256 newLoose = want.balanceOf(address(this));

                // If we dont have enough money adjust `_debtOutstanding` and only change profit if needed
                if (newLoose < amountToFree) {
                    if (_loss > newLoose) {
                        _loss = newLoose;
                        _debtPayment = 0;
                    } else {
                        _debtPayment = Math.min(newLoose - _loss, _debtPayment);
                    }
                }
            }
        }
    }

    /// @notice Estimates highest and lowest apr lenders among a `lendersList`
    /// @param lendersList List of all the lender contracts associated to this strategy
    /// @return _lowest The index of the lender in the `lendersList` with lowest apr
    /// @return _lowestApr The lowest apr
    /// @return _highest The index of the lender with highest apr
    /// @return _potential The potential apr of this lender if funds are moved from lowest to highest
    /// @dev `lendersList` is kept as a parameter to avoid multiplying reads in storage to the `lenders`
    /// array
    function _estimateGreedyAdjustPosition(IGenericLender[] memory lendersList)
        internal
        view
        returns (
            uint256 _lowest,
            uint256 _lowestApr,
            uint256 _highest,
            uint256 _potential,
            uint256 _totalApr
        )
    {
        //all loose assets are to be invested
        uint256 looseAssets = want.balanceOf(address(this));

        // our simple algo
        // get the lowest apr strat
        // cycle through and see who could take its funds plus want for the highest apr
        _lowestApr = type(uint256).max;
        _lowest = 0;
        uint256 lowestNav = 0;

        uint256 highestApr = 0;
        _highest = 0;

        uint256 brutHighestApr;
        uint256 bal = looseAssets;
        uint256[] memory weightedAprs = new uint256[](lendersList.length);
        for (uint256 i = 0; i < lendersList.length; i++) {
            uint256 aprAfterDeposit = lendersList[i].aprAfterDeposit(int256(looseAssets));
            if (aprAfterDeposit > highestApr) {
                highestApr = aprAfterDeposit;
                _highest = i;
            }

            if (lendersList[i].hasAssets()) {
                uint256 apr = lendersList[i].apr();
                uint256 nav = lendersList[i].nav();
                weightedAprs[i] = apr * nav;
                if (_highest == i) brutHighestApr == apr;
                if (apr < _lowestApr) {
                    _lowestApr = apr;
                    _lowest = i;
                    lowestNav = nav;
                }
            } else {
                weightedAprs[i] = 0;
                if (_highest == i) brutHighestApr == lendersList[i].apr();
            }
        }

        //if we can improve apr by withdrawing we do so
        _potential = lendersList[_highest].aprAfterDeposit(int256(lowestNav + looseAssets));

        // We will deposits into a lender without funds currently
        if (weightedAprs[_highest] == 0) weightedAprs[_highest] == looseAssets * brutHighestApr;

        if (_potential > _lowestApr) {
            weightedAprs[_lowest] = 0;
            weightedAprs[_highest] = (weightedAprs[_highest] / brutHighestApr) * _potential;
        } else weightedAprs[_highest] = (weightedAprs[_highest] / brutHighestApr) * highestApr;

        uint256 weightedAPR;
        for (uint256 i = 0; i < lendersList.length; i++) {
            weightedAPR = weightedAPR + weightedAprs[i];
        }

        _totalApr = weightedAPR / bal;
    }

    /// @notice Function called by keepers to adjust the position
    /// @dev The algorithm moves assets from lowest return to highest
    /// like a very slow idiot bubble sort
    function _adjustPosition(bytes memory data) internal override {
        // Emergency exit is dealt with at beginning of harvest
        if (emergencyExit) {
            return;
        }
        // Storing the `lenders` array in a cache variable
        IGenericLender[] memory lendersList = lenders;
        // We just keep all money in want if we dont have any lenders
        if (lendersList.length == 0) {
            return;
        }

        uint64[] memory lenderSharesHint = abi.decode(data, (uint64[]));

        uint256 estimatedAprHint;
        int256[] memory lenderAdjustedAmounts;
        if (lenderSharesHint.length != 0) (estimatedAprHint, lenderAdjustedAmounts) = estimatedAPR(lenderSharesHint);
        (
            uint256 lowest,
            uint256 lowestApr,
            uint256 highest,
            uint256 potential,
            uint256 _totalApr
        ) = _estimateGreedyAdjustPosition(lendersList);

        // The hint was successful --> we find a better allocation than the current one
        if (_totalApr < estimatedAprHint) {
            // not optimal currently, we should better withdraw from excess lenders and then deposit reducing the number of withdraw to be done
            for (uint256 i = 0; i < lendersList.length; i++) {
                if (uint256(lenderAdjustedAmounts[i]) < 0) lendersList[i].withdraw(uint256(-lenderAdjustedAmounts[i]));
            }

            for (uint256 i = 0; i < lendersList.length; i++) {
                if (uint256(lenderAdjustedAmounts[i]) > 0) {
                    want.safeTransfer(address(lendersList[i]), uint256(lenderAdjustedAmounts[i]));
                    lendersList[i].deposit();
                }
            }
        } else {
            if (potential > lowestApr) {
                // Apr should go down after deposit so won't be withdrawing from self
                lendersList[lowest].withdrawAll();
            }

            uint256 bal = want.balanceOf(address(this));
            if (bal > 0) {
                want.safeTransfer(address(lendersList[highest]), bal);
                lendersList[highest].deposit();
            }
        }
    }

    /// @inheritdoc BaseStrategyUpgradeable
    function _adjustPosition() internal override {
        _adjustPosition(abi.encode(new uint64[](0)));
    }

    /// @inheritdoc BaseStrategyUpgradeable
    function _adjustPosition(uint256) internal override {
        _adjustPosition(abi.encode(new uint64[](0)));
    }

    /// @notice Withdraws a given amount from lenders
    /// @param _amount The amount to withdraw
    /// @dev Cycle through withdrawing from worst rate first
    function _withdrawSome(uint256 _amount) internal returns (uint256 amountWithdrawn) {
        IGenericLender[] memory lendersList = lenders;
        if (lendersList.length == 0) {
            return 0;
        }

        // Don't withdraw dust
        if (_amount < withdrawalThreshold) {
            return 0;
        }

        amountWithdrawn = 0;
        // In most situations this will only run once. Only big withdrawals will be a gas guzzler
        uint256 j = 0;
        while (amountWithdrawn < _amount - withdrawalThreshold) {
            uint256 lowestApr = type(uint256).max;
            uint256 lowest = 0;
            for (uint256 i = 0; i < lendersList.length; i++) {
                if (lendersList[i].hasAssets()) {
                    uint256 apr = lendersList[i].apr();
                    if (apr < lowestApr) {
                        lowestApr = apr;
                        lowest = i;
                    }
                }
            }
            if (!lendersList[lowest].hasAssets()) {
                return amountWithdrawn;
            }
            uint256 amountWithdrawnFromStrat = lendersList[lowest].withdraw(_amount - amountWithdrawn);
            // To avoid staying on the same strat if we can't withdraw anythin from it
            amountWithdrawn = amountWithdrawn + amountWithdrawnFromStrat;
            j++;
            // not best solution because it would be better to move to the 2nd lowestAPR instead of quiting
            if (amountWithdrawnFromStrat == 0) {
                return amountWithdrawn;
            }
            // To avoid want infinite loop
            if (j >= 6) {
                return amountWithdrawn;
            }
        }
    }

    /// @notice Liquidates up to `_amountNeeded` of `want` of this strategy's positions,
    /// irregardless of slippage. Any excess will be re-invested with `_adjustPosition()`.
    /// This function should return the amount of `want` tokens made available by the
    /// liquidation. If there is a difference between them, `_loss` indicates whether the
    /// difference is due to a realized loss, or if there is some other sitution at play
    /// (e.g. locked funds) where the amount made available is less than what is needed.
    ///
    /// NOTE: The invariant `_liquidatedAmount + _loss <= _amountNeeded` should always be maintained
    function _liquidatePosition(uint256 _amountNeeded) internal override returns (uint256 _amountFreed, uint256 _loss) {
        uint256 _balance = want.balanceOf(address(this));

        if (_balance >= _amountNeeded) {
            //if we don't set reserve here withdrawer will be sent our full balance
            return (_amountNeeded, 0);
        } else {
            uint256 received = _withdrawSome(_amountNeeded - _balance) + (_balance);
            if (received >= _amountNeeded) {
                return (_amountNeeded, 0);
            } else {
                return (received, 0);
            }
        }
    }

    /// @notice Liquidates everything and returns the amount that got freed.
    /// This function is used during emergency exit instead of `_prepareReturn()` to
    /// liquidate all of the Strategy's positions back to the Manager.
    function _liquidateAllPositions() internal override returns (uint256 _amountFreed) {
        (_amountFreed, ) = _liquidatePosition(estimatedTotalAssets());
    }

    // =============================== VIEW FUNCTIONS ==============================

    /// @notice View function to check the current state of the strategy
    /// @return Returns the status of all lenders attached the strategy
    function lendStatuses() external view returns (LendStatus[] memory) {
        uint256 lendersListLength = lenders.length;
        LendStatus[] memory statuses = new LendStatus[](lendersListLength);
        for (uint256 i = 0; i < lendersListLength; i++) {
            LendStatus memory s;
            s.name = lenders[i].lenderName();
            s.add = address(lenders[i]);
            s.assets = lenders[i].nav();
            s.rate = lenders[i].apr();
            statuses[i] = s;
        }
        return statuses;
    }

    /// @notice View function to check the total assets lent
    function lentTotalAssets() public view returns (uint256) {
        uint256 nav = 0;
        for (uint256 i = 0; i < lenders.length; i++) {
            nav = nav + lenders[i].nav();
        }
        return nav;
    }

    /// @notice View function to check the total assets managed by the strategy
    function estimatedTotalAssets() public view override returns (uint256 nav) {
        nav = lentTotalAssets() + want.balanceOf(address(this));
    }

    /// @notice View function to check the number of lending platforms
    function numLenders() external view returns (uint256) {
        return lenders.length;
    }

    /// @notice The weighted apr of all lenders. sum(nav * apr)/totalNav
    function estimatedAPR() external view returns (uint256) {
        uint256 bal = estimatedTotalAssets();
        if (bal == 0) {
            return 0;
        }

        uint256 weightedAPR = 0;

        for (uint256 i = 0; i < lenders.length; i++) {
            weightedAPR = weightedAPR + lenders[i].weightedApr();
        }

        return weightedAPR / bal;
    }

    /// @notice The weighted apr in an hypothetical world where the strategy split its nav in respect to shares
    /// @param shares List of shares that should be allocated to each lender
    function estimatedAPR(uint64[] memory shares)
        public
        view
        returns (uint256 weightedAPR, int256[] memory lenderAdjustedAmounts)
    {
        uint256 lenderListLength = lenders.length;
        lenderAdjustedAmounts = new int256[](lenderListLength);
        if (lenderListLength != shares.length) revert IncorrectListLength();

        uint256 bal = estimatedTotalAssets();
        if (bal == 0) {
            return (weightedAPR, lenderAdjustedAmounts);
        }

        uint256 share = 0;
        for (uint256 i = 0; i < lenderListLength; i++) {
            share = share + shares[i];
            uint256 futureDeposit = (bal * shares[i]) / _BPS;
            uint256 currentDeposit = lenders[i].underlyingBalanceStored();
            // It won't overflow for decimals <= 18, as it would mean gigantic amounts
            int256 adjustedAmount = int256(futureDeposit) - int256(currentDeposit);
            lenderAdjustedAmounts[i] = adjustedAmount;
            uint256 aprAfterDelta = lenders[i].aprAfterDeposit(adjustedAmount);
            weightedAPR = weightedAPR + futureDeposit * aprAfterDelta;
        }
        if (share != 10000) revert InvalidShares();

        weightedAPR /= bal;
    }

    /// @notice Prevents the governance from withdrawing want tokens
    function _protectedTokens() internal view override returns (address[] memory) {
        address[] memory protected = new address[](1);
        protected[0] = address(want);
        return protected;
    }

    // ================================= GOVERNANCE ================================

    /// @notice Changes the withdrawal threshold
    /// @param _threshold The new withdrawal threshold
    /// @dev governor, guardian or `PoolManager` only
    function setWithdrawalThreshold(uint256 _threshold) external onlyRole(GUARDIAN_ROLE) {
        withdrawalThreshold = _threshold;
    }

    /// @notice Add lenders for the strategy to choose between
    /// @param newLender The adapter to the added lending platform
    /// @dev Governor, guardian or `PoolManager` only
    function addLender(IGenericLender newLender) external onlyRole(GUARDIAN_ROLE) {
        if (newLender.strategy() != address(this)) revert UndockedLender();

        for (uint256 i = 0; i < lenders.length; i++) {
            if (address(newLender) == address(lenders[i])) revert LenderAlreadyAdded();
        }
        lenders.push(newLender);

        emit AddLender(address(newLender));
    }

    /// @notice Removes a lending platform and fails if total withdrawal is impossible
    /// @param lender The address of the adapter to the lending platform to remove
    function safeRemoveLender(address lender) external onlyRole(GUARDIAN_ROLE) {
        _removeLender(lender, false);
    }

    /// @notice Removes a lending platform and even if total withdrawal is impossible
    /// @param lender The address of the adapter to the lending platform to remove
    function forceRemoveLender(address lender) external onlyRole(GUARDIAN_ROLE) {
        _removeLender(lender, true);
    }

    /// @notice Internal function to handle lending platform removing
    /// @param lender The address of the adapter for the lending platform to remove
    /// @param force Whether it is required that all the funds are withdrawn prior to removal
    function _removeLender(address lender, bool force) internal {
        IGenericLender[] memory lendersList = lenders;
        for (uint256 i = 0; i < lendersList.length; i++) {
            if (lender == address(lendersList[i])) {
                bool allWithdrawn = lendersList[i].withdrawAll();

                if (!force && !allWithdrawn) revert FailedWithdrawal();

                // Put the last index here
                // then remove last index
                if (i != lendersList.length - 1) {
                    lenders[i] = lendersList[lendersList.length - 1];
                }

                // Pop shortens array by 1 thereby deleting the last index
                lenders.pop();

                // If balance to spend we might as well put it into the best lender
                if (want.balanceOf(address(this)) > 0) {
                    _adjustPosition();
                }

                emit RemoveLender(lender);

                return;
            }
        }
        revert NonExistentLender();
    }

    // ============================= MANAGER FUNCTIONS =============================

    /// @notice Adds a new guardian address and echoes the change to the contracts
    /// that interact with this collateral `PoolManager`
    /// @param _guardian New guardian address
    /// @dev This internal function has to be put in this file because `AccessControl` is not defined
    /// in `PoolManagerInternal`
    function addGuardian(address _guardian) external override onlyRole(POOLMANAGER_ROLE) {
        // Granting the new role
        // Access control for this contract
        _grantRole(GUARDIAN_ROLE, _guardian);
        // Propagating the new role in other contract
        for (uint256 i = 0; i < lenders.length; i++) {
            lenders[i].grantRole(GUARDIAN_ROLE, _guardian);
        }
    }

    /// @notice Revokes the guardian role and propagates the change to other contracts
    /// @param guardian Old guardian address to revoke
    function revokeGuardian(address guardian) external override onlyRole(POOLMANAGER_ROLE) {
        _revokeRole(GUARDIAN_ROLE, guardian);
        for (uint256 i = 0; i < lenders.length; i++) {
            lenders[i].revokeRole(GUARDIAN_ROLE, guardian);
        }
    }
}
