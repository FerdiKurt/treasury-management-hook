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

### Key Capabilities

- **Automated Fee Collection**: Collects fees on every swap based on configurable rates
- **Treasury Management**: Management of collected fees with proper access controls
- **Pool-Specific Configuration**: Per-pool fee management and configuration
- **Flexible Fee Rates**: Configurable fee rates from 0% to 10% (0-1000 basis points)
- **Secure Withdrawals**: Treasury-only withdrawal mechanism with proper validations

## ✨ Features

### Core Features

- **Configurable Fee Rates**: Set fee rates from 0.01% to 10% (1-1000 basis points)
- **Automated Collection**: Fees automatically collected on each swap
- **Multi-Token Support**: Handles fees for any ERC20 token pair
- **Treasury Controls**: Only treasury address can withdraw fees and change settings
- **Pool Management**: Enable/disable hook for specific pools
- **Fee Accumulation**: Efficient accumulation of fees over time
- **Event Emission**: Event logging for transparency

### Security Features

- 🔒 **Access Control**: Treasury-only functions with proper validation
- 🔒 **Rate Limits**: Maximum fee rate capped at 10%
- 🔒 **Input Validation**: Input validation and error handling
- 🔒 **Reentrancy Safety**: Protected against reentrancy attacks

## 🏗 Contract Architecture

### Main Contract: `TestTreasuryManagementHook`

```solidity
contract TestTreasuryManagementHook is BaseHook {
    // Core state variables
    address public treasury;                    // Treasury address
    uint24 public treasuryFeeRate;             // Fee rate in basis points
    mapping(PoolId => bool) public isPoolManaged;
    mapping(Currency => uint256) public accumulatedFees;
    
    // Constants
    uint24 public constant MAX_FEE_RATE = 1000;    // 10%
    uint256 public constant BASIS_POINTS = 10000;
}
```

### Key Functions

#### Treasury Management
- `setTreasury(address)` - Update treasury address
- `setTreasuryFeeRate(uint24)` - Update fee rate (0-1000 basis points)
- `withdrawFees(Currency, uint256)` - Withdraw accumulated fees

#### Pool Management
- `getPoolManagedStatus(PoolKey)` - Check if pool is managed

#### Fee Operations
- `getAvailableFees(Currency)` - View accumulated fees for a token
- `_afterSwap()` - Internal hook function that collects fees

## 🚀 Installation

### Prerequisites

- [Foundry](https://getfoundry.sh/)
- [Node.js](https://nodejs.org/) (v16+)
- [Git](https://git-scm.com/)

### Setup

```bash
# Clone the repository
git clone <repository-url>
cd treasury-management-hook

# Install dependencies
forge install

# Build contracts
forge build

# Run tests
forge test
```

### Dependencies

```toml
[dependencies]
forge-std = "^1.0.0"
openzeppelin-contracts = "^4.9.0"
uniswap-v4-core = "^0.0.1"
uniswap-v4-periphery = "^0.0.1"
```

## 📖 Usage

### Deployment

```solidity
// Deploy the hook
TestTreasuryManagementHook hook = new TestTreasuryManagementHook(
    IPoolManager(poolManagerAddress),
    treasuryAddress,
    100  // 1% fee rate (100 basis points)
);

// Enable for a specific pool
PoolKey memory poolKey = PoolKey({
    currency0: Currency.wrap(token0Address),
    currency1: Currency.wrap(token1Address),
    fee: 3000,
    tickSpacing: 60,
    hooks: IHooks(address(hook))
});

hook.setPoolManaged(poolKey, true);
```

### Fee Management

```solidity
// Update fee rate (treasury only)
hook.setTreasuryFeeRate(250); // 2.5%

// Check accumulated fees
uint256 fees = hook.getAvailableFees(Currency.wrap(tokenAddress));

// Withdraw fees (treasury only)
hook.withdrawFees(Currency.wrap(tokenAddress), amount);
```

### Treasury Operations

```solidity
// Update treasury address (current treasury only)
hook.setTreasury(newTreasuryAddress);

// Withdraw all fees for a token
hook.withdrawFees(Currency.wrap(tokenAddress), 0);
```

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

