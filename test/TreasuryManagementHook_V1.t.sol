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
