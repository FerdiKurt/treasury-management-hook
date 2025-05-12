# Treasury Management Hook for Uniswap V4

A custom hook for Uniswap V4 that implements treasury management features, enabling pools to collect protocol fees and automatically distribute them to a designated treasury address.

## Overview

The Treasury Management Hook extends Uniswap V4 pools with the ability to:
- Collect additional fees on token swaps (beyond standard pool swap fees)
- Send collected fees directly to a designated treasury address
- Support configurable fee rates with a maximum cap of 10%
- Enable treasury management (change treasury address and fee rates)
- Track which pools are managed by the hook

## Features

### Core Functionality
- **Custom Fee Collection**: Charges additional fees on swaps (configurable in basis points)
- **Automatic Treasury Distribution**: Fees are automatically sent to the treasury address
- **Pool Management**: Track which pools use this hook
- **Fee Withdrawal**: Treasury can withdraw accumulated fees

### Administrative Functions
- **Update Treasury Address**: Change where fees are sent
- **Update Fee Rate**: Modify the fee percentage (maximum 10%)
- **Access Control**: Only the treasury address can update settings

## Smart Contract Details

### Constructor Parameters
```solidity
constructor(
    IPoolManager _poolManager,    // Uniswap V4 Pool Manager address
    address _treasury,            // Initial treasury address
    uint24 _treasuryFeeRate       // Initial fee rate in basis points
)
```

### Key Functions

#### Administrative Functions
```solidity
// Update treasury address (only callable by current treasury)
function setTreasury(address _newTreasury) external

// Update fee rate (only callable by treasury)
function setTreasuryFeeRate(uint24 _newFeeRate) external

// Withdraw collected fees (only callable by treasury)
function withdrawFees(Currency token, uint256 amount) external
```

#### Hook Implementations
```solidity
// Called when a pool is initialized
function _afterInitialize(...) internal override

// Called before a swap occurs
function beforeSwap(...) external override view

// Called after a swap occurs
function _afterSwap(...) internal override
```

### Events
```solidity
event TreasuryFeeCollected(PoolKey key, address token, uint256 amount);
event TreasuryAddressChanged(address oldTreasury, address newTreasury);
event TreasuryFeeRateChanged(uint24 oldRate, uint24 newRate);
```

