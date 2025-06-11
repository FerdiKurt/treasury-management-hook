// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {BaseHook} from "@uniswap/v4-periphery/src/utils/BaseHook.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";

/**
 * @title Treasury Management Hook for Uniswap V4
 * @notice A hook that collects fees on swaps and manages treasury funds
 */
contract TreasuryManagementHook_V1 is BaseHook {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    /// @notice The address authorized to manage treasury operations
    address public treasury;
    
    /// @notice The fee rate charged on swaps in basis points (100 = 1%)
    uint24 public treasuryFeeRate;
    
    /// @notice Maximum allowed fee rate (10%)
    uint24 public constant MAX_FEE_RATE = 1000;
    
    /// @notice Denominator for basis points calculations
    uint256 public constant BASIS_POINTS = 10000;
    
    /// @notice Tracks which pools are managed by this hook
    mapping(PoolId => bool) public isPoolManaged;
    
    /// @notice Accumulated fees per token available for withdrawal
    mapping(Currency => uint256) public accumulatedFees;

    event TreasuryFeeCollected(PoolId indexed poolId, Currency indexed token, uint256 amount);
    event TreasuryAddressChanged(address indexed oldTreasury, address indexed newTreasury);
    event TreasuryFeeRateChanged(uint24 oldRate, uint24 newRate);
    event FeesWithdrawn(Currency indexed token, uint256 amount);

    error InvalidTreasuryAddress();
    error FeeRateTooHigh();
    error OnlyTreasuryAllowed();
    error InsufficientFees();

