// SPDX-License-Identifier: GPL-3.0

pragma solidity ^0.8.7;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

// import "../strategies/AaveFlashloanStrategy/AaveInterfaces.sol";
import "../interfaces/external/aave/IAave.sol";

contract MockAave is
    IAToken,
    ERC20,
    IAaveIncentivesController,
    ILendingPool,
    ILendingPoolAddressesProvider,
    IReserveInterestRateStrategy,
    IStakedAave
{
    using SafeERC20 for IERC20;

    event Minting(address indexed _to, address indexed _minter, uint256 _amount);
    event Burning(address indexed _from, address indexed _burner, uint256 _amount);

    IERC20 public token; // Interface for the token

    uint256 public constant BASE = 10**27;

    uint256 public distributionEnd = type(uint256).max;
    uint256 public emissionsPerSecond = 10;
    uint256 public unstakeWindow = type(uint256).max;
    uint256 public stakersCooldownsValue = 0;
    uint128 public currentLiquidityRate = 0;
    uint256 public rewardsBalance = 0;

    mapping(address => uint256) public reserveNormalizedIncomes; // Mapping between an underlying asset and its reserveNoramlized income

    /// @notice constructor
    /// @param name_ of the token lent
    /// @param symbol_ of the token lent
    constructor(
        string memory name_,
        string memory symbol_,
        address token_
    ) ERC20(name_, symbol_) {
        token = IERC20(token_);
    }

    function deployNewUnderlying(address underlying) external {
        reserveNormalizedIncomes[underlying] = BASE;
    }

    function getReserveNormalizedIncome(address asset) external view returns (uint256) {
        return reserveNormalizedIncomes[asset] / BASE;
    }

    function changeReserveNormalizedIncome(uint256 newIncome, address asset) external {
        reserveNormalizedIncomes[asset] = newIncome * BASE;
    }

    function deposit(
        address asset,
        uint256 amount,
        address onBehalfOf,
        uint16
    ) external override {
        IERC20 underlying = IERC20(asset);
        underlying.safeTransferFrom(msg.sender, address(this), amount);
        // With Aave the amount of cToken is exactly what has been given
        uint256 reserveNormalizedIncome_ = reserveNormalizedIncomes[asset];
        _mint(onBehalfOf, (amount * BASE) / reserveNormalizedIncome_); // Here we don't exactly respect what Aave is doing
        emit Minting(onBehalfOf, msg.sender, amount);
    }

    function withdraw(
        address asset,
        uint256 amount,
        address to
    ) external override returns (uint256) {
        uint256 reserveNormalizedIncome_ = reserveNormalizedIncomes[asset];
        uint256 amountcToken = (amount * BASE) / reserveNormalizedIncome_;
        burn(msg.sender, amountcToken);
        uint256 amountToken = (amountcToken * reserveNormalizedIncome_) / BASE;
        token.safeTransfer(to, amountToken);
        return (amountToken);
    }

    function mint(address account, uint256 amount) external {
        _mint(account, amount);
        emit Minting(account, msg.sender, amount);
    }

    function burn(address account, uint256 amount) public {
        _burn(account, amount);
        emit Burning(account, msg.sender, amount);
    }

    function getIncentivesController() external view override returns (IAaveIncentivesController) {
        return IAaveIncentivesController(address(this));
    }

    function getRewardsBalance(address[] calldata, address) external view override returns (uint256) {
        return rewardsBalance;
    }

    function setRewardsBalance(uint256 _rewardsBalance) external {
        rewardsBalance = _rewardsBalance;
    }

    function claimRewards(
        address[] calldata,
        uint256,
        address
    ) external pure override returns (uint256) {
        return uint256(0);
    }

    function getDistributionEnd() external view override returns (uint256) {
        return distributionEnd;
    }

    function setDistributionEnd(uint256 _distributionEnd) external {
        distributionEnd = _distributionEnd;
    }

    function getAssetData(address)
        external
        view
        override
        returns (
            uint256,
            uint256,
            uint256
        )
    {
        return (0, emissionsPerSecond, 0);
    }

    function setEmissionsPerSecond(uint256 _emissionsPerSecond) external {
        emissionsPerSecond = _emissionsPerSecond;
    }

    function setCurrentLiquidityRate(uint128 _liquidityRate) external {
        currentLiquidityRate = _liquidityRate;
    }

    function getReserveData(address) external view override returns (DataTypes.ReserveData memory) {
        return
            DataTypes.ReserveData(
                DataTypes.ReserveConfigurationMap(uint256(0)),
                uint128(0),
                uint128(0),
                currentLiquidityRate,
                uint128(0),
                uint128(0),
                uint40(0),
                address(this),
                address(this),
                address(this),
                address(this),
                uint8(0)
            );
    }

    function getLendingPool() external view override returns (address) {
        return address(this);
    }

    function calculateInterestRates(
        address reserve,
        uint256 utilizationRate,
        uint256 totalStableDebt,
        uint256 totalVariableDebt,
        uint256 averageStableBorrowRate,
        uint256 reserveFactor
    )
        external
        pure
        override
        returns (
            uint256 liquidityRate,
            uint256 stableBorrowRate,
            uint256 variableBorrowRate
        )
    {
        return (0.04 ether, 0.04 ether, 0.04 ether);
    }

    function stake(address to, uint256 amount) external override {}

    function redeem(address to, uint256 amount) external override {}

    function cooldown() external override {}

    function claimRewards(address to, uint256 amount) external override {}

    function getTotalRewardsBalance(address) external view override returns (uint256) {}

    function COOLDOWN_SECONDS() external pure override returns (uint256) {
        return 0;
    }

    function stakersCooldowns(address) external view override returns (uint256) {
        return stakersCooldownsValue;
    }

    function UNSTAKE_WINDOW() external view override returns (uint256) {
        return unstakeWindow;
    }

    function setUnstakeWindowAndStakers(uint256 _unstakeWindow, uint256 _stakersCooldownsValue) external {
        unstakeWindow = _unstakeWindow;
        stakersCooldownsValue = _stakersCooldownsValue;
    }
}

contract MockProtocolDataProvider {
    uint256 public availableLiquidityStorage = 0;

    address public immutable aToken;
    address public immutable debtToken;

    constructor(address _aToken, address _debtToken) {
        aToken = _aToken;
        debtToken = _debtToken;
    }

    function getReserveTokensAddresses(address) external view returns(
        address aTokenAddress,
        address stableDebtTokenAddress,
        address variableDebtTokenAddress
    ) {
        aTokenAddress = aToken;
        stableDebtTokenAddress = debtToken;
        variableDebtTokenAddress = address(0);
    }

    function ADDRESSES_PROVIDER() external view returns (ILendingPoolAddressesProvider) {
        return ILendingPoolAddressesProvider(aToken);
    }

    function getReserveConfigurationData(address)
        external
        pure
        returns (
            uint256 decimals,
            uint256 ltv,
            uint256 liquidationThreshold,
            uint256 liquidationBonus,
            uint256 reserveFactor,
            bool usageAsCollateralEnabled,
            bool borrowingEnabled,
            bool stableBorrowRateEnabled,
            bool isActive,
            bool isFrozen
        )
    {
        return (uint256(0), uint256(0.8 ether), uint256(0.8 ether), uint256(0), uint256(0), true, true, true, true, true);
    }

    function setAvailableLiquidity(uint256 _availableLiquidity) external {
        availableLiquidityStorage = _availableLiquidity;
    }

    function getReserveData(address)
        external
        view
        returns (
            uint256 availableLiquidity,
            uint256 totalStableDebt,
            uint256 totalVariableDebt,
            uint256 liquidityRate,
            uint256 variableBorrowRate,
            uint256 stableBorrowRate,
            uint256 averageStableBorrowRate,
            uint256 liquidityIndex,
            uint256 variableBorrowIndex,
            uint40 lastUpdateTimestamp
        )
    {
        availableLiquidity = availableLiquidityStorage;
        return (
            availableLiquidity,
            uint256(0),
            uint256(0),
            uint256(0),
            uint256(0),
            uint256(0),
            uint256(0),
            uint256(0),
            uint256(0),
            uint40(0)
        );
    }
}
