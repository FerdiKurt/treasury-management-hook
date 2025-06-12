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

    // ============ AFTER SWAP TESTS ============
    
    function test_AfterSwap_ZeroForOne_CollectsFees() public {
        uint256 swapAmount = 1 ether;
        uint256 expectedFee = (swapAmount * INITIAL_FEE_RATE) / BASIS_POINTS;
        
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: -int256(swapAmount),
            sqrtPriceLimitX96: 79228162514264337593543950336
        });
        
        // Create BalanceDelta: negative amount0 (input), positive amount1 (output)
        BalanceDelta delta = _createBalanceDelta(-int128(int256(swapAmount)), int128(int256(swapAmount * 99 / 100)));
        
        vm.expectEmit(true, true, false, true);
        emit TreasuryFeeCollected(poolId, poolKey.currency0, expectedFee);
        
        vm.prank(address(mockPoolManager));
        (bytes4 selector, int128 feeAmount) = hook.afterSwap(
            user,
            poolKey,
            params,
            delta,
            ""
        );
        
        assertEq(selector, IHooks.afterSwap.selector);
        assertEq(feeAmount, int128(int256(expectedFee)));
        assertEq(hook.getAvailableFees(poolKey.currency0), expectedFee);
    }

    function test_AfterSwap_OneForZero_CollectsFees() public {
        uint256 swapAmount = 1 ether;
        uint256 expectedFee = (swapAmount * INITIAL_FEE_RATE) / BASIS_POINTS;
        
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: false,
            amountSpecified: -int256(swapAmount),
            sqrtPriceLimitX96: 158456325028528675187087900672 // SQRT_PRICE_2_1
        });
        
        // Create BalanceDelta: positive amount0 (output), negative amount1 (input)
        BalanceDelta delta = _createBalanceDelta(int128(int256(swapAmount * 99 / 100)), -int128(int256(swapAmount)));
        
        vm.expectEmit(true, true, false, true);
        emit TreasuryFeeCollected(poolId, poolKey.currency1, expectedFee);
        
        vm.prank(address(mockPoolManager));
        (bytes4 selector, int128 feeAmount) = hook.afterSwap(
            user,
            poolKey,
            params,
            delta,
            ""
        );
        
        assertEq(selector, IHooks.afterSwap.selector);
        assertEq(feeAmount, int128(int256(expectedFee)));
        assertEq(hook.getAvailableFees(poolKey.currency1), expectedFee);
    }

    function test_AfterSwap_ZeroFeeRate() public {
        // Set fee rate to 0
        vm.prank(treasury);
        hook.setTreasuryFeeRate(0);
        
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: -1 ether,
            sqrtPriceLimitX96: 79228162514264337593543950336
        });
        
        BalanceDelta delta = _createBalanceDelta(-1 ether, 0.99 ether);
        
        vm.prank(address(mockPoolManager));
        (bytes4 selector, int128 feeAmount) = hook.afterSwap(
            user,
            poolKey,
            params,
            delta,
            ""
        );
        
        assertEq(selector, IHooks.afterSwap.selector);
        assertEq(feeAmount, 0);
        assertEq(hook.getAvailableFees(poolKey.currency0), 0);
    }

    function test_AfterSwap_UnmanagedPool() public {
        hook.setPoolManaged(poolKey, false);
        
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: -1 ether,
            sqrtPriceLimitX96: 79228162514264337593543950336
        });
        
        BalanceDelta delta = _createBalanceDelta(-1 ether, 0.99 ether);
        
        vm.prank(address(mockPoolManager));
        (bytes4 selector, int128 feeAmount) = hook.afterSwap(
            user,
            poolKey,
            params,
            delta,
            ""
        );
        
        assertEq(selector, IHooks.afterSwap.selector);
        assertEq(feeAmount, 0);
        assertEq(hook.getAvailableFees(poolKey.currency0), 0);
    }

    function test_AfterSwap_PositiveAmounts_NoFee() public {
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: -1 ether,
            sqrtPriceLimitX96: 79228162514264337593543950336
        });
        
        // Create delta with positive amount0 (should not charge fee)
        BalanceDelta delta = _createBalanceDelta(1 ether, -0.99 ether);
        
        vm.prank(address(mockPoolManager));
        (bytes4 selector, int128 feeAmount) = hook.afterSwap(
            user,
            poolKey,
            params,
            delta,
            ""
        );
        
        assertEq(selector, IHooks.afterSwap.selector);
        assertEq(feeAmount, 0);
        assertEq(hook.getAvailableFees(poolKey.currency0), 0);
    }

    // ============ FEE WITHDRAWAL TESTS ============
    
    function test_WithdrawFees_Success() public {
        Currency token = poolKey.currency0;
        uint256 feeAmount = 1 ether;
        
        // Fee simulation
        _simulateFeesCollected(token, feeAmount);
        
        uint256 treasuryBalanceBefore = mockPoolManager.getBalance(token, treasury);
        
        vm.expectEmit(true, false, false, true);
        emit FeesWithdrawn(token, feeAmount);
        
        vm.prank(treasury);
        hook.withdrawFees(token, feeAmount);
        
        assertEq(hook.getAvailableFees(token), 0);
        assertEq(mockPoolManager.getBalance(token, treasury), treasuryBalanceBefore + feeAmount);
    }

    function test_WithdrawFees_WithdrawAll() public {
        Currency token = poolKey.currency0;
        uint256 feeAmount = 1 ether;
        
        _simulateFeesCollected(token, feeAmount);
        
        vm.expectEmit(true, false, false, true);
        emit FeesWithdrawn(token, feeAmount);
        
        vm.prank(treasury);
        hook.withdrawFees(token, 0); // 0 means withdraw all
        
        assertEq(hook.getAvailableFees(token), 0);
    }

    function test_WithdrawFees_PartialWithdrawal() public {
        Currency token = poolKey.currency0;
        uint256 totalFees = 1 ether;
        uint256 withdrawAmount = 0.5 ether;
        
        _simulateFeesCollected(token, totalFees);
        
        vm.expectEmit(true, false, false, true);
        emit FeesWithdrawn(token, withdrawAmount);
        
        vm.prank(treasury);
        hook.withdrawFees(token, withdrawAmount);
        
        assertEq(hook.getAvailableFees(token), totalFees - withdrawAmount);
    }

    function test_WithdrawFees_OnlyTreasury() public {
        vm.expectRevert(TreasuryManagementHook_V1.OnlyTreasuryAllowed.selector);
        vm.prank(unauthorized);
        hook.withdrawFees(poolKey.currency0, 1 ether);
    }

    function test_WithdrawFees_InsufficientFees() public {
        vm.expectRevert(TreasuryManagementHook_V1.InsufficientFees.selector);
        vm.prank(treasury);
        hook.withdrawFees(poolKey.currency0, 1 ether);
    }

    function test_WithdrawFees_AmountTooHigh() public {
        Currency token = poolKey.currency0;
        uint256 feeAmount = 1 ether;
        
        _simulateFeesCollected(token, feeAmount);
        
        vm.expectRevert(TreasuryManagementHook_V1.InsufficientFees.selector);
        vm.prank(treasury);
        hook.withdrawFees(token, feeAmount + 1);
    }

    function test_WithdrawFees_AfterTreasuryChange() public {
        Currency token = poolKey.currency0;
        uint256 feeAmount = 1 ether;
        
        _simulateFeesCollected(token, feeAmount);
        
        // Change treasury
        vm.prank(treasury);
        hook.setTreasury(newTreasury);
        
        // Old treasury can't withdraw
        vm.expectRevert(TreasuryManagementHook_V1.OnlyTreasuryAllowed.selector);
        vm.prank(treasury);
        hook.withdrawFees(token, feeAmount);
        
        // New treasury can withdraw
        vm.prank(newTreasury);
        hook.withdrawFees(token, feeAmount);
        
        assertEq(hook.getAvailableFees(token), 0);
    }

    // ============ VIEW FUNCTION TESTS ============
    
    function test_GetAvailableFees() public {
        assertEq(hook.getAvailableFees(poolKey.currency0), 0);
        assertEq(hook.getAvailableFees(poolKey.currency1), 0);
        
        Currency token = poolKey.currency0;
        uint256 feeAmount = 1 ether;
        
        _simulateFeesCollected(token, feeAmount);
        
        assertEq(hook.getAvailableFees(token), feeAmount);
        assertEq(hook.getAvailableFees(poolKey.currency1), 0);
    }

    function test_GetPoolManagedStatus() public view {
        assertTrue(hook.getPoolManagedStatus(poolKey));
        
        PoolKey memory newPoolKey = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: 5000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        
        assertFalse(hook.getPoolManagedStatus(newPoolKey));
    }

    // ============ FUZZ TESTS ============
    
    function testFuzz_SetTreasuryFeeRate(uint24 feeRate) public {
        if (feeRate > MAX_FEE_RATE) {
            vm.expectRevert(TreasuryManagementHook_V1.FeeRateTooHigh.selector);
            vm.prank(treasury);
            hook.setTreasuryFeeRate(feeRate);
        } else {
            vm.prank(treasury);
            hook.setTreasuryFeeRate(feeRate);
            assertEq(hook.treasuryFeeRate(), feeRate);
        }
    }

    function testFuzz_FeeCalculation(uint128 swapAmount, uint24 feeRate) public {
        vm.assume(swapAmount > 0 && swapAmount <= 100 ether);
        vm.assume(feeRate <= MAX_FEE_RATE);
        
        vm.prank(treasury);
        hook.setTreasuryFeeRate(feeRate);
        
        uint256 expectedFee = (uint256(swapAmount) * feeRate) / BASIS_POINTS;
        
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: -int256(uint256(swapAmount)),
            sqrtPriceLimitX96: 79228162514264337593543950336
        });
        
        BalanceDelta delta = _createBalanceDelta(-int128(int256(uint256(swapAmount))), int128(int256(uint256(swapAmount) * 99 / 100)));
        
        vm.prank(address(mockPoolManager));
        (, int128 feeAmount) = hook.afterSwap(user, poolKey, params, delta, "");
        
        assertEq(feeAmount, int128(int256(expectedFee)));
        assertEq(hook.getAvailableFees(poolKey.currency0), expectedFee);
    }

    function testFuzz_WithdrawFees(uint256 totalFees, uint256 withdrawAmount) public {
        totalFees = bound(totalFees, 1, 100 ether);
        withdrawAmount = bound(withdrawAmount, 1, totalFees);
        
        Currency token = poolKey.currency0;
        _simulateFeesCollected(token, totalFees);
        
        vm.prank(treasury);
        hook.withdrawFees(token, withdrawAmount);
        
        assertEq(hook.getAvailableFees(token), totalFees - withdrawAmount);
    }

    // ============ INTEGRATION TESTS ============
    
    function test_IntegrationFlow() public {
        // 1. Perform swap and collect fees
        uint256 swapAmount = 2 ether;
        uint256 expectedFee = (swapAmount * INITIAL_FEE_RATE) / BASIS_POINTS;
        
        _performSwap(swapAmount, true);
        
        assertEq(hook.getAvailableFees(poolKey.currency0), expectedFee);
        
        // 2. Change fee rate
        uint24 newFeeRate = 200; // 2%
        vm.prank(treasury);
        hook.setTreasuryFeeRate(newFeeRate);
        
        // 3. Perform another swap
        uint256 secondSwapAmount = 1 ether;
        uint256 secondExpectedFee = (secondSwapAmount * newFeeRate) / BASIS_POINTS;
        
        _performSwap(secondSwapAmount, true);
        
        assertEq(hook.getAvailableFees(poolKey.currency0), expectedFee + secondExpectedFee);
        
        // 4. Change treasury
        vm.prank(treasury);
        hook.setTreasury(newTreasury);
        
        // 5. Withdraw fees as new treasury
        uint256 totalFees = expectedFee + secondExpectedFee;
        vm.prank(newTreasury);
        hook.withdrawFees(poolKey.currency0, totalFees);
        
        assertEq(hook.getAvailableFees(poolKey.currency0), 0);
        assertEq(mockPoolManager.getBalance(poolKey.currency0, newTreasury), totalFees);
    }

    function test_MultipleTokenFees() public {
        uint256 swapAmount = 1 ether;
        uint256 expectedFee = (swapAmount * INITIAL_FEE_RATE) / BASIS_POINTS;
        
        // Swap token0 for token1
        _performSwap(swapAmount, true);
        assertEq(hook.getAvailableFees(poolKey.currency0), expectedFee);
        assertEq(hook.getAvailableFees(poolKey.currency1), 0);
        
        // Swap token1 for token0
        _performSwap(swapAmount, false);
        assertEq(hook.getAvailableFees(poolKey.currency0), expectedFee);
        assertEq(hook.getAvailableFees(poolKey.currency1), expectedFee);
        
        // Withdraw both
        vm.prank(treasury);
        hook.withdrawFees(poolKey.currency0, expectedFee);
        
        vm.prank(treasury);
        hook.withdrawFees(poolKey.currency1, expectedFee);
        
        assertEq(hook.getAvailableFees(poolKey.currency0), 0);
        assertEq(hook.getAvailableFees(poolKey.currency1), 0);
    }

    function test_FeeAccumulation() public {
        uint256 swapAmount = 1 ether;
        uint256 expectedFeePerSwap = (swapAmount * INITIAL_FEE_RATE) / BASIS_POINTS;
        uint256 numSwaps = 5;
        
        // Perform multiple swaps
        for (uint256 i = 0; i < numSwaps; i++) {
            _performSwap(swapAmount, true);
        }
        
        uint256 totalExpectedFees = expectedFeePerSwap * numSwaps;
        assertEq(hook.getAvailableFees(poolKey.currency0), totalExpectedFees);
        
        // Withdraw all fees
        vm.prank(treasury);
        hook.withdrawFees(poolKey.currency0, 0); // Withdraw all
        
        assertEq(hook.getAvailableFees(poolKey.currency0), 0);
        assertEq(mockPoolManager.getBalance(poolKey.currency0, treasury), totalExpectedFees);
    }

    // ============ EDGE CASE TESTS ============
    
    function test_SwapWithZeroAmount() public {
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: 0,
            sqrtPriceLimitX96: 79228162514264337593543950336
        });
        
        BalanceDelta delta = _createBalanceDelta(0, 0);
        
        vm.prank(address(mockPoolManager));
        (bytes4 selector, int128 feeAmount) = hook.afterSwap(
            user,
            poolKey,
            params,
            delta,
            ""
        );
        
        assertEq(selector, IHooks.afterSwap.selector);
        assertEq(feeAmount, 0);
        assertEq(hook.getAvailableFees(poolKey.currency0), 0);
    }

    function test_SwapWithMaxFeeRate() public {
        // Set maximum fee rate
        vm.prank(treasury);
        hook.setTreasuryFeeRate(MAX_FEE_RATE);
        
        uint256 swapAmount = 1 ether;
        uint256 expectedFee = (swapAmount * MAX_FEE_RATE) / BASIS_POINTS; // 10%
        
        _performSwap(swapAmount, true);
        
        assertEq(hook.getAvailableFees(poolKey.currency0), expectedFee);
    }

    function test_SwapWithMinFeeRate() public {
        // Set minimum fee rate (1 basis point)
        vm.prank(treasury);
        hook.setTreasuryFeeRate(1);
        
        uint256 swapAmount = 1 ether;
        uint256 expectedFee = (swapAmount * 1) / BASIS_POINTS; // 0.01%
        
        _performSwap(swapAmount, true);
        
        assertEq(hook.getAvailableFees(poolKey.currency0), expectedFee);
    }

    function test_LargeSwapAmount() public {
        uint256 largeSwapAmount = 1000 ether;
        uint256 expectedFee = (largeSwapAmount * INITIAL_FEE_RATE) / BASIS_POINTS;
        
        _performSwap(largeSwapAmount, true);
        
        assertEq(hook.getAvailableFees(poolKey.currency0), expectedFee);
    }

    function test_SmallSwapAmount() public {
        uint256 smallSwapAmount = 1; // 1 wei
        uint256 expectedFee = (smallSwapAmount * INITIAL_FEE_RATE) / BASIS_POINTS;
        
        _performSwap(smallSwapAmount, true);
        
        assertEq(hook.getAvailableFees(poolKey.currency0), expectedFee);
    }

    // ============ SECURITY TESTS ============
    
    function test_ReentrancyProtection() public {
        // This test verifies that the hook doesn't have reentrancy issues
        // Since we're using a mock pool manager, we can't test real reentrancy
        // but we can verify state consistency
        
        uint256 swapAmount = 1 ether;
        _performSwap(swapAmount, true);
        
        uint256 feesAfterSwap = hook.getAvailableFees(poolKey.currency0);
        
        // Perform another swap
        _performSwap(swapAmount, true);
        
        uint256 feesAfterSecondSwap = hook.getAvailableFees(poolKey.currency0);
        uint256 expectedFee = (swapAmount * INITIAL_FEE_RATE) / BASIS_POINTS;
        
        assertEq(feesAfterSecondSwap, feesAfterSwap + expectedFee);
    }

    function test_UnauthorizedAccess() public {
        // Test all treasury-only functions with unauthorized user
        address[] memory unauthorizedUsers = new address[](3);
        unauthorizedUsers[0] = user;
        unauthorizedUsers[1] = address(this);
        unauthorizedUsers[2] = address(0x123);
        
        for (uint256 i = 0; i < unauthorizedUsers.length; i++) {
            address unauthorizedUser = unauthorizedUsers[i];
            
            vm.expectRevert(TreasuryManagementHook_V1.OnlyTreasuryAllowed.selector);
            vm.prank(unauthorizedUser);
            hook.setTreasury(newTreasury);
            
            vm.expectRevert(TreasuryManagementHook_V1.OnlyTreasuryAllowed.selector);
            vm.prank(unauthorizedUser);
            hook.setTreasuryFeeRate(200);
            
            vm.expectRevert(TreasuryManagementHook_V1.OnlyTreasuryAllowed.selector);
            vm.prank(unauthorizedUser);
            hook.withdrawFees(poolKey.currency0, 1 ether);
        }
    }

    function test_InvalidParameterBounds() public {
        // Test various invalid parameters
        vm.startPrank(treasury);
        
        // Fee rate bounds
        vm.expectRevert(TreasuryManagementHook_V1.FeeRateTooHigh.selector);
        hook.setTreasuryFeeRate(MAX_FEE_RATE + 1);
        
        vm.expectRevert(TreasuryManagementHook_V1.FeeRateTooHigh.selector);
        hook.setTreasuryFeeRate(type(uint24).max);
        
        // Treasury address bounds
        vm.expectRevert(TreasuryManagementHook_V1.InvalidTreasuryAddress.selector);
        hook.setTreasury(address(0));
        
        vm.stopPrank();
    }

    // ============ GAS OPTIMIZATION TESTS ============
    
    function test_GasUsage_AfterSwap() public {
        uint256 swapAmount = 1 ether;
        
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: -int256(swapAmount),
            sqrtPriceLimitX96: 79228162514264337593543950336
        });
        
        BalanceDelta delta = _createBalanceDelta(-int128(int256(swapAmount)), int128(int256(swapAmount * 99 / 100)));
        
        vm.prank(address(mockPoolManager));
        uint256 gasStart = gasleft();
        hook.afterSwap(user, poolKey, params, delta, "");
        uint256 gasUsed = gasStart - gasleft();
        
        // Verify gas usage is reasonable 
        assertLt(gasUsed, 125000, "Gas usage too high for afterSwap");
    }

    function test_GasUsage_WithdrawFees() public {
        Currency token = poolKey.currency0;
        uint256 feeAmount = 1 ether;
        
        _simulateFeesCollected(token, feeAmount);
        
        vm.prank(treasury);
        uint256 gasStart = gasleft();
        hook.withdrawFees(token, feeAmount);
        uint256 gasUsed = gasStart - gasleft();
        
        // Verify gas usage is reasonable
        assertLt(gasUsed, 60000, "Gas usage too high for withdrawFees");
    }

    // ============ STRESS TESTS ============

    function test_StressTest_ManyFeeRateChanges() public {
        uint24[] memory feeRates = new uint24[](10);
        feeRates[0] = 50;
        feeRates[1] = 100;
        feeRates[2] = 150;
        feeRates[3] = 200;
        feeRates[4] = 250;
        feeRates[5] = 300;
        feeRates[6] = 500;
        feeRates[7] = 750;
        feeRates[8] = 1000;
        feeRates[9] = 0;
        
        for (uint256 i = 0; i < feeRates.length; i++) {
            vm.prank(treasury);
            hook.setTreasuryFeeRate(feeRates[i]);
            
            // Verify fee rate was set
            uint24 actualRate = hook.treasuryFeeRate();
            require(actualRate == feeRates[i], "Fee rate not set correctly");
            
            // Perform swap
            _performSwap(1 ether, true);
        }
    }


    function test_StressTest_LargeAmounts() public {
        // Test with very large amounts
        uint256[] memory amounts = new uint256[](5);
        amounts[0] = 1000 ether;
        amounts[1] = 10000 ether;
        amounts[2] = 100000 ether;
        amounts[3] = 1000000 ether;
        amounts[4] = type(uint128).max / 10000; // Max safe amount
        
        for (uint256 i = 0; i < amounts.length; i++) {
            uint256 expectedFee = (amounts[i] * INITIAL_FEE_RATE) / BASIS_POINTS;
            uint256 feesBefore = hook.getAvailableFees(poolKey.currency0);
            
            _performSwap(amounts[i], true);
            
            uint256 feesAfter = hook.getAvailableFees(poolKey.currency0);
            assertEq(feesAfter - feesBefore, expectedFee);
        }
    }

    // ============ BOUNDARY TESTS ============
    
    function test_BoundaryTest_MaxUint128Swap() public {
        // Test with maximum uint128 value (but safe for calculations)
        uint256 maxSafeAmount = type(uint128).max / 10000;
        uint256 expectedFee = (maxSafeAmount * INITIAL_FEE_RATE) / BASIS_POINTS;
        
        _performSwap(maxSafeAmount, true);
        
        assertEq(hook.getAvailableFees(poolKey.currency0), expectedFee);
    }

    function test_BoundaryTest_MinSwapAmount() public {
        // Test with 1 wei
        uint256 minAmount = 1;
        uint256 expectedFee = (minAmount * INITIAL_FEE_RATE) / BASIS_POINTS; // Should be 0 due to rounding
        
        _performSwap(minAmount, true);
        
        assertEq(hook.getAvailableFees(poolKey.currency0), expectedFee);
    }

    function test_BoundaryTest_RoundingBehavior() public {
        // Test fee calculation rounding
        uint256 swapAmount = 99; // Amount that would result in fractional fee
        uint256 expectedFee = (swapAmount * INITIAL_FEE_RATE) / BASIS_POINTS; // Should round down to 0
        
        _performSwap(swapAmount, true);
        
        assertEq(hook.getAvailableFees(poolKey.currency0), expectedFee);
    }
}

/// @title Advanced Treasury Hook Test Scenarios
/// @notice Complex test scenarios and edge cases for Treasury Management Hook
contract AdvancedTreasuryHookTest is TreasuryHookTest {
    using TestUtils for *;

    // ============ INTEGRATION TESTS ============
    
    function test_AdvancedIntegration_MultiPoolScenario() public {
        // Create multiple pools with different fee tiers
        PoolKey memory lowFeePool = TestUtils.createPoolKey(
            poolKey.currency0,
            poolKey.currency1,
            TestConstants.FEE_LOW,
            TestConstants.TICK_SPACING_LOW,
            address(hook)
        );
        
        PoolKey memory highFeePool = TestUtils.createPoolKey(
            poolKey.currency0,
            poolKey.currency1,
            TestConstants.FEE_HIGH,
            TestConstants.TICK_SPACING_HIGH,
            address(hook)
        );
        
        // Register pools
        hook.setPoolManaged(lowFeePool, true);
        hook.setPoolManaged(highFeePool, true);
        
        uint256 swapAmount = TestConstants.MEDIUM_AMOUNT;
        
        // Perform swaps on each pool
        _performSwapOnPool(swapAmount, true, lowFeePool);
        _performSwapOnPool(swapAmount, true, highFeePool);
        _performSwapOnPool(swapAmount, true, poolKey); // Original pool
        
        // All swaps should collect the same fee (treasury fee, not pool fee)
        uint256 expectedFee = TestUtils.calculateExpectedFee(swapAmount, INITIAL_FEE_RATE);
        assertEq(hook.getAvailableFees(poolKey.currency0), expectedFee * 3);
    }

    function test_AdvancedIntegration_TreasuryRotation() public {
        address treasury1 = makeAddr("treasury1");
        address treasury2 = makeAddr("treasury2");
        address treasury3 = makeAddr("treasury3");
        
        uint256 swapAmount = TestConstants.MEDIUM_AMOUNT;
        uint256 expectedFee = TestUtils.calculateExpectedFee(swapAmount, INITIAL_FEE_RATE);
        
        // Phase 1: Original treasury
        _performSwap(swapAmount, true);
        assertEq(hook.getAvailableFees(poolKey.currency0), expectedFee);
        
        vm.prank(treasury);
        hook.withdrawFees(poolKey.currency0, expectedFee);
        
        // Phase 2: Switch to treasury1
        vm.prank(treasury);
        hook.setTreasury(treasury1);
        
        _performSwap(swapAmount, true);
        assertEq(hook.getAvailableFees(poolKey.currency0), expectedFee);
        
        vm.prank(treasury1);
        hook.withdrawFees(poolKey.currency0, expectedFee);
        
        // Phase 3: Switch to treasury2
        vm.prank(treasury1);
        hook.setTreasury(treasury2);
        
        _performSwap(swapAmount, true);
        
        // Phase 4: Switch to treasury3 without withdrawing
        vm.prank(treasury2);
        hook.setTreasury(treasury3);
        
        // treasury3 can withdraw fees collected under treasury2
        vm.prank(treasury3);
        hook.withdrawFees(poolKey.currency0, expectedFee);
        
        assertEq(hook.getAvailableFees(poolKey.currency0), 0);
    }

    function test_AdvancedIntegration_FeeRateEvolution() public {
        uint24[] memory feeRateProgression = new uint24[](5);
        feeRateProgression[0] = 50;   // 0.5%
        feeRateProgression[1] = 100;  // 1%
        feeRateProgression[2] = 200;  // 2%
        feeRateProgression[3] = 500;  // 5%
        feeRateProgression[4] = 1000; // 10%
        
        uint256 swapAmount = TestConstants.MEDIUM_AMOUNT;
        uint256 totalExpectedFees = 0;
        
        for (uint256 i = 0; i < feeRateProgression.length; i++) {
            // Update fee rate
            vm.prank(treasury);
            hook.setTreasuryFeeRate(feeRateProgression[i]);
            
            // Perform swap
            _performSwap(swapAmount, true);
            
            // Calculate expected fee for this rate
            uint256 expectedFee = TestUtils.calculateExpectedFee(swapAmount, feeRateProgression[i]);
            totalExpectedFees += expectedFee;
            
            // Verify accumulated fees
            assertEq(hook.getAvailableFees(poolKey.currency0), totalExpectedFees);
        }
        
        // Final withdrawal
        vm.prank(treasury);
        hook.withdrawFees(poolKey.currency0, 0); // Withdraw all
        
        assertEq(hook.getAvailableFees(poolKey.currency0), 0);
        assertEq(mockPoolManager.getBalance(poolKey.currency0, treasury), totalExpectedFees);
    }


    // ============ HELPER FUNCTIONS ============
    
    function _performSwapOnPool(uint256 swapAmount, bool zeroForOne, PoolKey memory targetPool) internal {
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: -int256(swapAmount),
            sqrtPriceLimitX96: zeroForOne ? 
                TestConstants.SQRT_PRICE_1_2 :
                TestConstants.SQRT_PRICE_2_1
        });
        
        BalanceDelta delta;
        if (zeroForOne) {
            delta = _createBalanceDelta(-int128(int256(swapAmount)), int128(int256(swapAmount * 99 / 100)));
        } else {
            delta = _createBalanceDelta(int128(int256(swapAmount * 99 / 100)), -int128(int256(swapAmount)));
        }
        
        vm.prank(address(mockPoolManager));
        hook.afterSwap(user, targetPool, params, delta, "");
    }
    
    function _createBalanceDelta(int128 amount0, int128 amount1) internal pure returns (BalanceDelta) {
    // Convert to uint256 to avoid sign extension issues
    uint256 unsignedAmount0 = uint256(int256(amount0));
    uint256 unsignedAmount1 = uint256(int256(amount1));
    
    // Mask to 128 bits to ensure no overflow
    unsignedAmount0 = unsignedAmount0 & 0xffffffffffffffffffffffffffffffff;
    unsignedAmount1 = unsignedAmount1 & 0xffffffffffffffffffffffffffffffff;
    
    // Pack into int256
    int256 packed = int256((unsignedAmount0 << 128) | unsignedAmount1);
    return BalanceDelta.wrap(packed);
    }

    function _simulateFeesCollected(Currency token, uint256 feeAmount) internal {
        // Simulate a swap that would generate this fee amount
        uint256 swapAmount = (feeAmount * BASIS_POINTS) / INITIAL_FEE_RATE;
        _performSwap(swapAmount, token == poolKey.currency0);
        
        // Verify the expected fee was collected
        assertEq(hook.getAvailableFees(token), feeAmount);
    }

    function _performSwap(uint256 swapAmount, bool zeroForOne) internal {
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: -int256(swapAmount),
            sqrtPriceLimitX96: zeroForOne ? 
                79228162514264337593543950336 :  // SQRT_PRICE_1_2
                158456325028528675187087900672   // SQRT_PRICE_2_1
        });
        
        BalanceDelta delta;
        if (zeroForOne) {
            delta = _createBalanceDelta(-int128(int256(swapAmount)), int128(int256(swapAmount * 99 / 100)));
        } else {
            delta = _createBalanceDelta(int128(int256(swapAmount * 99 / 100)), -int128(int256(swapAmount)));
        }
        
        vm.prank(address(mockPoolManager));
        hook.afterSwap(user, poolKey, params, delta, "");
    }
}