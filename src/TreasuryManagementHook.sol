// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {BaseHook} from "@uniswap/v4-periphery/src/utils/BaseHook.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

/// @title Treasury Management Hook
/// @notice Hook that implements treasury management features for Uniswap V4 pools
contract TreasuryManagementHook is BaseHook {
    // Treasury address to receive fees
    address public treasury;
    
    // Fee rate in basis points (e.g., 10 = 0.1%)
    uint24 public treasuryFeeRate;
    
    // Mapping to track whether a pool uses this hook
    mapping(bytes32 => bool) public isPoolManaged;

    event TreasuryFeeCollected(PoolKey key, address token, uint256 amount);
    event TreasuryAddressChanged(address oldTreasury, address newTreasury);
    event TreasuryFeeRateChanged(uint24 oldRate, uint24 newRate);

    constructor(IPoolManager _poolManager, address _treasury, uint24 _treasuryFeeRate) BaseHook(_poolManager) {
        require(_treasury != address(0), "Invalid treasury address");
        require(_treasuryFeeRate <= 1000, "Fee rate too high"); // Max 10%
        
        treasury = _treasury;
        treasuryFeeRate = _treasuryFeeRate;
    }

    /// @notice Updates the treasury address
    /// @param _newTreasury The new treasury address
    function setTreasury(address _newTreasury) external {
        require(msg.sender == treasury, "Only treasury can update");
        require(_newTreasury != address(0), "Invalid treasury address");
        
        address oldTreasury = treasury;
        treasury = _newTreasury;
        
        emit TreasuryAddressChanged(oldTreasury, _newTreasury);
    }

    /// @notice Updates the treasury fee rate
    /// @param _newFeeRate The new fee rate in basis points
    function setTreasuryFeeRate(uint24 _newFeeRate) external {
        require(msg.sender == treasury, "Only treasury can update");
        require(_newFeeRate <= 1000, "Fee rate too high"); // Max 10%
        
        uint24 oldRate = treasuryFeeRate;
        treasuryFeeRate = _newFeeRate;
        
        emit TreasuryFeeRateChanged(oldRate, _newFeeRate);
    }

    /// @notice Returns the hook's permissions
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        Hooks.Permissions memory permissions;
        permissions.beforeInitialize = false;
        permissions.afterInitialize = true;
        permissions.beforeAddLiquidity = false;
        permissions.afterAddLiquidity = false;
        permissions.beforeRemoveLiquidity = false;
        permissions.afterRemoveLiquidity = false;
        permissions.beforeSwap = true;
        permissions.afterSwap = true;
        permissions.beforeDonate = false;
        permissions.afterDonate = false;
        return permissions;
    }

    /// @notice Register a pool with this hook after initialization
    function _afterInitialize(address, PoolKey calldata key, uint160, int24)
        internal
        override
        returns (bytes4)
    {
        bytes32 poolId = keccak256(abi.encode(key));
        isPoolManaged[poolId] = true;
        return IHooks.afterInitialize.selector;
    }

    /// @notice Implement beforeSwap to match the BaseHook signature
    function beforeSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        bytes calldata hookData
    ) external override view onlyPoolManager returns (bytes4, BeforeSwapDelta, uint24) {
        return _beforeSwap(sender, key, params, hookData);
    }

    /// @notice Internal implementation of beforeSwap
    function _beforeSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata,
        bytes calldata
    ) internal override view returns (bytes4, BeforeSwapDelta, uint24) {
        bytes32 poolId = keccak256(abi.encode(key));
        
        // Only apply fee if pool is managed by this hook
        if (!isPoolManaged[poolId]) {
            // Create a zero BeforeSwapDelta using default initialization
            BeforeSwapDelta _zeroSwapDelta; // Default initialization sets all values to 0
            return (IHooks.beforeSwap.selector, _zeroSwapDelta, 0);
        }
        
        // Return additional fee to be charged - zero delta, non-zero fee
        BeforeSwapDelta zeroSwapDelta; // Default initialization sets all values to 0
        return (IHooks.beforeSwap.selector, zeroSwapDelta, treasuryFeeRate);
    }

}