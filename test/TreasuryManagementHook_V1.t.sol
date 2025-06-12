// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {TreasuryManagementHook_V1} from "../src/TreasuryManagementHook_V1.sol";

/// @title Test Constants
/// @notice Constants used across Treasury Hook tests
library TestConstants {
    // Price constants (sqrt prices in Q96 format)
    uint160 public constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    uint160 public constant SQRT_PRICE_1_2 = 56022770974786139918731938227;
    uint160 public constant SQRT_PRICE_2_1 = 158456325028528675187087900672;
    uint160 public constant SQRT_PRICE_1_4 = 39614081257132168796771975168;
    uint160 public constant SQRT_PRICE_4_1 = 316912650057057350374175801344;
    
    // Fee tier constants
    uint24 public constant FEE_LOW = 500;      // 0.05%
    uint24 public constant FEE_MEDIUM = 3000;  // 0.3%
    uint24 public constant FEE_HIGH = 10000;   // 1%
    
    // Tick spacing constants
    int24 public constant TICK_SPACING_LOW = 10;
    int24 public constant TICK_SPACING_MEDIUM = 60;
    int24 public constant TICK_SPACING_HIGH = 200;
    
    // Treasury fee constants
    uint24 public constant MIN_FEE_RATE = 1;     // 0.01%
    uint24 public constant DEFAULT_FEE_RATE = 100; // 1%
    uint24 public constant MAX_FEE_RATE = 1000;  // 10%
    uint24 public constant BASIS_POINTS = 10000;
    
    // Test amounts
    uint256 public constant SMALL_AMOUNT = 1e12;      // 0.000001 tokens
    uint256 public constant MEDIUM_AMOUNT = 1e18;     // 1 token
    uint256 public constant LARGE_AMOUNT = 1000e18;   // 1000 tokens
    uint256 public constant HUGE_AMOUNT = 1000000e18; // 1M tokens
    
    // Liquidity amounts
    uint128 public constant MIN_LIQUIDITY = 1000;
    uint128 public constant DEFAULT_LIQUIDITY = 1000e18;
    uint128 public constant MAX_LIQUIDITY = type(uint128).max / 2;
}

/// @title Test Utilities
/// @notice Utility functions for Treasury Hook testing
library TestUtils {
    /// @notice Calculate expected fee for a given amount and rate
    function calculateExpectedFee(uint256 amount, uint24 feeRate) internal pure returns (uint256) {
        return (amount * feeRate) / TestConstants.BASIS_POINTS;
    }
    
    /// @notice Create a pool key with standard parameters
    function createPoolKey(
        Currency currency0,
        Currency currency1,
        uint24 fee,
        int24 tickSpacing,
        address hookAddress
    ) internal pure returns (PoolKey memory) {
        return PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: fee,
            tickSpacing: tickSpacing,
            hooks: IHooks(hookAddress)
        });
    }
    
    /// @notice Sort two currencies to ensure currency0 < currency1
    function sortCurrencies(Currency currencyA, Currency currencyB) 
        internal 
        pure 
        returns (Currency currency0, Currency currency1) 
    {
        if (Currency.unwrap(currencyA) < Currency.unwrap(currencyB)) {
            return (currencyA, currencyB);
        } else {
            return (currencyB, currencyA);
        }
    }
    
    /// @notice Check if an amount is dust (too small to generate fees)
    function isDustAmount(uint256 amount, uint24 feeRate) internal pure returns (bool) {
        return calculateExpectedFee(amount, feeRate) == 0;
    }
    
    /// @notice Calculate slippage for a swap
    function calculateSlippage(uint256 amountIn, uint256 amountOut) internal pure returns (uint256) {
        if (amountIn == 0) return 0;
        return ((amountIn - amountOut) * TestConstants.BASIS_POINTS) / amountIn;
    }
}

contract MockPoolManager {
    mapping(Currency => mapping(address => uint256)) public balances;
    mapping(Currency => uint256) public poolBalances;
    
    // Track total takes for debugging
    mapping(Currency => uint256) public totalTakes;
    
    event Take(Currency indexed currency, address indexed to, uint256 amount);
    
    function take(Currency currency, address to, uint256 amount) external {
        // Just do accounting, no validation
        balances[currency][to] += amount;
        totalTakes[currency] += amount;
        emit Take(currency, to, amount);
    }
    
    function settle(Currency currency, address from, uint256 amount) external {
        // Safe settle that doesn't underflow
        if (balances[currency][from] >= amount) {
            balances[currency][from] -= amount;
        }
        poolBalances[currency] += amount;
    }
    
    function addPoolLiquidity(Currency currency, uint256 amount) external {
        poolBalances[currency] += amount;
    }
    
    function getBalance(Currency currency, address account) external view returns (uint256) {
        return balances[currency][account];
    }
    
    function getPoolBalance(Currency currency) external view returns (uint256) {
        return poolBalances[currency];
    }
    
    function getTotalTakes(Currency currency) external view returns (uint256) {
        return totalTakes[currency];
    }
}

contract MockToken is ERC20 {
    uint8 private _decimals;
    
    constructor(string memory name, string memory symbol, uint8 decimals_) ERC20(name, symbol) {
        _decimals = decimals_;
    }
    
    function decimals() public view override returns (uint8) {
        return _decimals;
    }
    
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
    
    function burn(address from, uint256 amount) external {
        _burn(from, amount);
    }
    
    // Allow unlimited approval for testing
    function approve(address spender, uint256 amount) public override returns (bool) {
        return super.approve(spender, amount);
    }
    
    // Helper function for testing
    function approveMax(address spender) external {
        _approve(msg.sender, spender, type(uint256).max);
    }
}

contract TreasuryHookTest is Test {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    TreasuryManagementHook_V1 public hook;
    MockPoolManager public mockPoolManager;
    
    MockToken public token0;
    MockToken public token1;
    
    PoolKey public poolKey;
    PoolId public poolId;
    
    address public treasury;
    address public user;
    address public unauthorized;
    address public newTreasury;
    
    uint24 public constant INITIAL_FEE_RATE = 100; // 1%
    uint24 public constant MAX_FEE_RATE = 1000; // 10%
    uint24 public constant BASIS_POINTS = 10000;
    
    // Events for testing
    event TreasuryFeeCollected(PoolId indexed poolId, Currency indexed token, uint256 amount);
    event TreasuryAddressChanged(address indexed oldTreasury, address indexed newTreasury);
    event TreasuryFeeRateChanged(uint24 oldRate, uint24 newRate);
    event FeesWithdrawn(Currency indexed token, uint256 amount);

    function setUp() public {
        // Create test addresses
        treasury = makeAddr("treasury");
        user = makeAddr("user");
        unauthorized = makeAddr("unauthorized");
        newTreasury = makeAddr("newTreasury");
        
        // Deploy mock pool manager
        mockPoolManager = new MockPoolManager();
        
        // Deploy test tokens
        token0 = new MockToken("Token0", "TK0", 18);
        token1 = new MockToken("Token1", "TK1", 18);
        
        // Ensure token0 < token1 for proper ordering
        if (address(token0) > address(token1)) {
            (token0, token1) = (token1, token0);
        }
        
        // Deploy hook
        hook = new TreasuryManagementHook_V1(
            IPoolManager(address(mockPoolManager)),
            treasury,
            INITIAL_FEE_RATE
        );
        
        // Create pool key
        poolKey = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        poolId = poolKey.toId();
        
        // Set pool as managed
        hook.setPoolManaged(poolKey, true);
        
        // Setup initial token balances
        token0.mint(user, 1000 ether);
        token1.mint(user, 1000 ether);
        token0.mint(address(this), 1000 ether);
        token1.mint(address(this), 1000 ether);
        
        // Add liquidity to mock pool
        token0.mint(address(mockPoolManager), 10000 ether);
        token1.mint(address(mockPoolManager), 10000 ether);
        mockPoolManager.addPoolLiquidity(Currency.wrap(address(token0)), 10000 ether);
        mockPoolManager.addPoolLiquidity(Currency.wrap(address(token1)), 10000 ether);

        vm.startPrank(address(mockPoolManager));
        token0.approveMax(address(mockPoolManager));
        token1.approveMax(address(mockPoolManager));
        vm.stopPrank();
    }

    // ============ CONSTRUCTOR TESTS ============
    
    function test_Constructor_Success() public view {
        assertEq(hook.treasury(), treasury);
        assertEq(hook.treasuryFeeRate(), INITIAL_FEE_RATE);
        assertEq(hook.MAX_FEE_RATE(), MAX_FEE_RATE);
        assertEq(hook.BASIS_POINTS(), BASIS_POINTS);
    }

    function test_Constructor_InvalidTreasury() public {
        vm.expectRevert(TreasuryManagementHook_V1.InvalidTreasuryAddress.selector);
        new TreasuryManagementHook_V1(
            IPoolManager(address(mockPoolManager)),
            address(0),
            INITIAL_FEE_RATE
        );
    }

    function test_Constructor_FeeRateTooHigh() public {
        vm.expectRevert(TreasuryManagementHook_V1.FeeRateTooHigh.selector);
        new TreasuryManagementHook_V1(
            IPoolManager(address(mockPoolManager)),
            treasury,
            MAX_FEE_RATE + 1
        );
    }

    // ============ TREASURY MANAGEMENT TESTS ============
    
    function test_SetTreasury_Success() public {
        vm.expectEmit(true, true, false, false);
        emit TreasuryAddressChanged(treasury, newTreasury);
        
        vm.prank(treasury);
        hook.setTreasury(newTreasury);
        
        assertEq(hook.treasury(), newTreasury);
    }

    function test_SetTreasury_OnlyTreasury() public {
        vm.expectRevert(TreasuryManagementHook_V1.OnlyTreasuryAllowed.selector);
        vm.prank(unauthorized);
        hook.setTreasury(newTreasury);
    }

    function test_SetTreasury_InvalidAddress() public {
        vm.expectRevert(TreasuryManagementHook_V1.InvalidTreasuryAddress.selector);
        vm.prank(treasury);
        hook.setTreasury(address(0));
    }

    function test_SetTreasury_SameAddress() public {
        vm.expectEmit(true, true, false, false);
        emit TreasuryAddressChanged(treasury, treasury);
        
        vm.prank(treasury);
        hook.setTreasury(treasury);
        
        assertEq(hook.treasury(), treasury);
    }

    // ============ FEE RATE MANAGEMENT TESTS ============
    
    function test_SetTreasuryFeeRate_Success() public {
        uint24 newFeeRate = 200; // 2%
        
        vm.expectEmit(false, false, false, true);
        emit TreasuryFeeRateChanged(INITIAL_FEE_RATE, newFeeRate);
        
        vm.prank(treasury);
        hook.setTreasuryFeeRate(newFeeRate);
        
        assertEq(hook.treasuryFeeRate(), newFeeRate);
    }

    function test_SetTreasuryFeeRate_OnlyTreasury() public {
        vm.expectRevert(TreasuryManagementHook_V1.OnlyTreasuryAllowed.selector);
        vm.prank(unauthorized);
        hook.setTreasuryFeeRate(200);
    }

    function test_SetTreasuryFeeRate_TooHigh() public {
        vm.expectRevert(TreasuryManagementHook_V1.FeeRateTooHigh.selector);
        vm.prank(treasury);
        hook.setTreasuryFeeRate(MAX_FEE_RATE + 1);
    }

    function test_SetTreasuryFeeRate_MaxAllowed() public {
        vm.prank(treasury);
        hook.setTreasuryFeeRate(MAX_FEE_RATE);
        
        assertEq(hook.treasuryFeeRate(), MAX_FEE_RATE);
    }

    function test_SetTreasuryFeeRate_Zero() public {
        vm.prank(treasury);
        hook.setTreasuryFeeRate(0);
        
        assertEq(hook.treasuryFeeRate(), 0);
    }

    // ============ HOOK PERMISSIONS TESTS ============
    
    function test_GetHookPermissions() public view {
        Hooks.Permissions memory permissions = hook.getHookPermissions();
        
        assertFalse(permissions.beforeInitialize);
        assertTrue(permissions.afterInitialize);
        assertFalse(permissions.beforeAddLiquidity);
        assertFalse(permissions.afterAddLiquidity);
        assertFalse(permissions.beforeRemoveLiquidity);
        assertFalse(permissions.afterRemoveLiquidity);
        assertTrue(permissions.beforeSwap);
        assertTrue(permissions.afterSwap);
        assertFalse(permissions.beforeDonate);
        assertFalse(permissions.afterDonate);
        assertFalse(permissions.beforeSwapReturnDelta);
        assertFalse(permissions.afterSwapReturnDelta);
        assertFalse(permissions.afterAddLiquidityReturnDelta);
        assertFalse(permissions.afterRemoveLiquidityReturnDelta);
    }

    // ============ POOL MANAGEMENT TESTS ============

    function test_AfterInitialize() public {
        PoolKey memory newPoolKey = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: 5000, // Different fee to create new pool
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        
        assertFalse(hook.getPoolManagedStatus(newPoolKey));
        
        // Simulate the PoolManager calling afterInitialize with correct parameters
        vm.prank(address(mockPoolManager));
        bytes4 selector = hook.afterInitialize(address(this), newPoolKey, 0, 0);
        
        assertEq(selector, IHooks.afterInitialize.selector);
        assertTrue(hook.getPoolManagedStatus(newPoolKey));
    }

    function test_SetPoolManaged() public {
        PoolKey memory newPoolKey = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: 5000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        
        assertFalse(hook.getPoolManagedStatus(newPoolKey));
        
        hook.setPoolManaged(newPoolKey, true);
        assertTrue(hook.getPoolManagedStatus(newPoolKey));
        
        hook.setPoolManaged(newPoolKey, false);
        assertFalse(hook.getPoolManagedStatus(newPoolKey));
    }

    // ============ BEFORE SWAP TESTS ============
    
    function test_BeforeSwap_ManagedPool() public {
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: -1 ether,
            sqrtPriceLimitX96: 79228162514264337593543950336 // SQRT_PRICE_1_2
        });
        
        vm.prank(address(mockPoolManager));
        (bytes4 selector, BeforeSwapDelta delta, uint24 fee) = hook.beforeSwap(
            user,
            poolKey,
            params,
            ""
        );
        
        assertEq(selector, IHooks.beforeSwap.selector);
        assertEq(BeforeSwapDelta.unwrap(delta), 0);
        assertEq(fee, 0);
    }

    function test_BeforeSwap_UnmanagedPool() public {
        PoolKey memory unmanagedPoolKey = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: 5000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: -1 ether,
            sqrtPriceLimitX96: 79228162514264337593543950336
        });
        
        vm.prank(address(mockPoolManager));
        (bytes4 selector, BeforeSwapDelta delta, uint24 fee) = hook.beforeSwap(
            user,
            unmanagedPoolKey,
            params,
            ""
        );
        
        assertEq(selector, bytes4(0));
        assertEq(BeforeSwapDelta.unwrap(delta), 0);
        assertEq(fee, 0);
    }
