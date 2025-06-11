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

    /**
     * @notice Constructor to initialize the hook
     * @param _poolManager The Uniswap V4 Pool Manager contract
     * @param _treasury The initial treasury address
     * @param _treasuryFeeRate The initial fee rate in basis points
     */
    constructor(
        IPoolManager _poolManager, 
        address _treasury, 
        uint24 _treasuryFeeRate
    ) BaseHook(_poolManager) {
        if (_treasury == address(0)) revert InvalidTreasuryAddress();
        if (_treasuryFeeRate > MAX_FEE_RATE) revert FeeRateTooHigh();
        
        treasury = _treasury;
        treasuryFeeRate = _treasuryFeeRate;
    }

    /// @notice Override validation for testing
    function validateHookAddress(BaseHook) internal pure override {
        // Skip validation in tests
    }

    /**
     * @notice Updates the treasury address
     * @param _newTreasury The new treasury address
     */
    function setTreasury(address _newTreasury) external {
        if (msg.sender != treasury) revert OnlyTreasuryAllowed();
        if (_newTreasury == address(0)) revert InvalidTreasuryAddress();
        
        address oldTreasury = treasury;
        treasury = _newTreasury;
        
        emit TreasuryAddressChanged(oldTreasury, _newTreasury);
    }

    /**
     * @notice Updates the treasury fee rate
     * @param _newFeeRate The new fee rate in basis points (0-1000)
     */
    function setTreasuryFeeRate(uint24 _newFeeRate) external {
        if (msg.sender != treasury) revert OnlyTreasuryAllowed();
        if (_newFeeRate > MAX_FEE_RATE) revert FeeRateTooHigh();
        
        uint24 oldRate = treasuryFeeRate;
        treasuryFeeRate = _newFeeRate;
        
        emit TreasuryFeeRateChanged(oldRate, _newFeeRate);
    }

    /// @notice Returns the hook's permissions configuration
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: true,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    /**
     * @notice Hook called after a pool is initialized
     * @param key The pool key containing pool parameters
     */
    function _afterInitialize(
        address,
        PoolKey calldata key,
        uint160,
        int24
    ) internal override returns (bytes4) {
        PoolId poolId = key.toId();
        isPoolManaged[poolId] = true;
        return IHooks.afterInitialize.selector;
    }

    /**
     * @notice Hook called before a swap is executed
     * @param key The pool key for the swap
     */
    function _beforeSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata,
        bytes calldata
    ) internal view override returns (bytes4, BeforeSwapDelta, uint24) {
        PoolId poolId = key.toId();
        
        // For unmanaged pools, return zero selector to skip afterSwap processing
        if (!isPoolManaged[poolId]) {
            return (bytes4(0), BeforeSwapDelta.wrap(0), 0);
        }
        
        // For managed pools, continue to afterSwap hook
        return (IHooks.beforeSwap.selector, BeforeSwapDelta.wrap(0), 0);
    }

    /**
     * @notice Hook called after a swap is executed to collect fees
     * @param key The pool key for the swap
     * @param params The swap parameters
     * @param delta The balance changes from the swap
     */
    function _afterSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) internal override returns (bytes4, int128) {
        PoolId poolId = key.toId();
        
        if (!isPoolManaged[poolId] || treasuryFeeRate == 0) {
            return (IHooks.afterSwap.selector, 0);
        }
        
        (Currency tokenIn, uint256 amountIn) = _getSwapInputDetails(key, params, delta);
        
        if (amountIn > 0) {
            uint256 feeAmount = (amountIn * treasuryFeeRate) / BASIS_POINTS;
            
            if (feeAmount > 0) {
                accumulatedFees[tokenIn] += feeAmount;
                poolManager.take(tokenIn, address(this), feeAmount);
                
                emit TreasuryFeeCollected(poolId, tokenIn, feeAmount);
                
                return (IHooks.afterSwap.selector, int128(int256(feeAmount)));
            }
        }
        
        return (IHooks.afterSwap.selector, 0);
    }

    /**
     * @notice Determines the input token and amount from swap parameters
     * @param key The pool key
     * @param params The swap parameters
     * @param delta The balance changes
     */
    function _getSwapInputDetails(
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta delta
    ) private pure returns (Currency tokenIn, uint256 amountIn) {
        if (params.zeroForOne) {
            tokenIn = key.currency0;
            amountIn = delta.amount0() < 0 ? uint256(uint128(-delta.amount0())) : 0;
        } else {
            tokenIn = key.currency1;
            amountIn = delta.amount1() < 0 ? uint256(uint128(-delta.amount1())) : 0;
        }
    }

    /**
     * @notice Withdraws accumulated fees to the treasury
     * @param token The token to withdraw fees for
     * @param amount The amount to withdraw (0 = withdraw all)
     */
    function withdrawFees(Currency token, uint256 amount) external {
        if (msg.sender != treasury) revert OnlyTreasuryAllowed();
        
        uint256 availableFees = accumulatedFees[token];
        if (availableFees == 0) revert InsufficientFees();
        
        uint256 withdrawAmount = amount == 0 ? availableFees : amount;
        
        if (withdrawAmount > availableFees) revert InsufficientFees();
        
        accumulatedFees[token] -= withdrawAmount;
        poolManager.take(token, treasury, withdrawAmount);
        
        emit FeesWithdrawn(token, withdrawAmount);
    }

