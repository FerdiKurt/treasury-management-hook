# Treasury Management Hook for Uniswap V4

A treasury management hook implementation for Uniswap V4 that automatically collects fees on swaps and manages treasury operations.

## 📋 Table of Contents

- [Overview](#overview)
- [Features](#features)
- [Contract Architecture](#contract-architecture)
- [Installation](#installation)
- [Usage](#usage)
- [Testing](#testing)
- [Security Considerations](#security-considerations)
- [License](#license)

## 🔍 Overview

The Treasury Management Hook is a Uniswap V4 hook that automatically collects configurable fees on swaps and manages treasury operations. It provides a decentralized mechanism for protocol revenue generation with treasury management capabilities.


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

## Usage

### 1. Deploy the Hook
```solidity
TreasuryManagementHook hook = new TreasuryManagementHook(
    poolManager,              // Uniswap V4 Pool Manager
    treasuryAddress,          // Your treasury address
    50                        // 0.5% fee rate (50 basis points)
);
```

### 2. Create a Pool with the Hook
```solidity
PoolKey memory poolKey = PoolKey({
    currency0: Currency.wrap(address(token0)),
    currency1: Currency.wrap(address(token1)),
    fee: 3000,                // 0.3% standard pool fee
    tickSpacing: 60,
    hooks: IHooks(address(hook))
});

poolManager.initialize(poolKey, startingPrice);
```

### 3. Collect Fees
Fees are automatically collected on each swap. The treasury can withdraw accumulated fees using:
```solidity
hook.withdrawFees(Currency.wrap(address(token)), amount);
```

## Fee Calculation

Fees are calculated as a percentage of the input token in a swap:

- For token0 → token1 swaps: Fee is charged on token0
- For token1 → token0 swaps: Fee is charged on token1
- Fee rate is specified in basis points (100 basis points = 1%)

Example:
- Fee rate: 50 basis points (0.5%)
- Swap: 1000 USDC → ETH
- Treasury fee: 5 USDC (0.5% of 1000)

## Security Considerations

### Access Control
- Only the treasury address can update treasury settings
- Only the treasury address can withdraw fees
- Maximum fee rate is capped at 10% (1000 basis points)

### Pool Management
- Pools are automatically registered when initialized with this hook
- Unregistered pools won't have fees collected

### Fee Collection
- Fees are calculated based on the actual swap amounts
- Zero fees are not emitted as events
- Fees are stored in the pool manager and withdrawn explicitly

## Gas Considerations

- Additional gas cost for each swap due to custom fee calculation
- Minimal storage usage with bitpacked pool tracking

## Integration Examples

### With Protocols
```solidity
// Example: Integration with a DeFi protocol
contract ProtocolTreasury {
    TreasuryManagementHook public treasuryHook;
    
    function collectProtocolFees() external {
        // Collect fees for all managed tokens
        treasuryHook.withdrawFees(Currency.wrap(USDC), usdcBalance);
        treasuryHook.withdrawFees(Currency.wrap(WETH), wethBalance);
    }
}
```

### With DAOs
```solidity
// Example: DAO governance integration
contract DAOTreasury {
    TreasuryManagementHook public treasuryHook;
    
    function updateFeeRate(uint24 newRate) external onlyGovernance {
        treasuryHook.setTreasuryFeeRate(newRate);
    }
}
```

## Deployment Information

### Required Dependencies
- Uniswap V4 Core (`@uniswap/v4-core`)
- Uniswap V4 Periphery (`@uniswap/v4-periphery`)
- Solidity ^0.8.0

### Network Deployment
1. Deploy the hook contract
2. Set up treasury address
3. Configure initial fee rate
4. Create pools using the hook

### Verification
After deployment, verify the contract on Etherscan or similar block explorers using the constructor parameters.

