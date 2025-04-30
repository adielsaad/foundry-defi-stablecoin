# Decentralized Stablecoin (DSC)

A decentralized stablecoin system that maintains a 1:1 peg with USD, backed by crypto collateral (ETH and BTC).

## Overview

This project implements a decentralized stablecoin system with the following key features:

### 1. Relative Stability: Anchored to $1.00
- Uses Chainlink Price Feeds for accurate price data
- Implements exchange functions for ETH & BTC to USD conversion

### 2. Stability Mechanism: Algorithmic (Decentralized)
- Minting is only allowed with sufficient collateral
- Health factor monitoring to ensure over-collateralization
- Liquidation mechanism for under-collateralized positions

### 3. Collateral: Exogenous (Crypto)
- Wrapped ETH (wETH)
- Wrapped BTC (wBTC)

## Technical Details

### Smart Contracts
- `DecentralizedStableCoin.sol`: ERC20 implementation of the stablecoin
- `DSCEngine.sol`: Core contract handling collateral, minting, and liquidation

### Key Features
- Over-collateralization requirement (200%)
- Health factor monitoring
- Price feed integration via Chainlink
- Reentrancy protection
- Custom error handling

## Development

### Prerequisites
- Foundry
- Node.js
- Git

### Installation
```bash
# Clone the repository
git clone <repository-url>

# Install dependencies
forge install
```

### Testing (TBD)
```bash
# Run all tests
forge test

# Run specific test file
forge test --match-path test/DSCEngine.t.sol
```

## Security
- ReentrancyGuard implementation
- Health factor checks
- Price feed staleness checks
- Over-collateralization requirements

## License
MIT

## Author
Adiel Saad
