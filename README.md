<div align="center">

# WizardDAO

**Wizard-Themed GameFi Burn & Dividend Platform on BNB Smart Chain**

[![BSC](https://img.shields.io/badge/Chain-BSC-F0B90B?style=flat-square&logo=binance)](https://www.bnbchain.org/)
[![Solidity](https://img.shields.io/badge/Solidity-^0.8.20-363636?style=flat-square&logo=solidity)](https://soliditylang.org/)
[![Chainlink VRF](https://img.shields.io/badge/Chainlink-VRF%20v2.5-375BD2?style=flat-square&logo=chainlink)](https://chain.link/)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg?style=flat-square)](LICENSE)
[![Verified](https://img.shields.io/badge/BSCScan-Verified-green?style=flat-square&logo=ethereum)](https://bscscan.com/address/0x764b08Dc29bA6cd698Be29a3DA11a1826B5618E2#code)

</div>

---

## Overview

WizardDAO is a GameFi + DeFi platform where users burn WIZARD tokens to mint magic items (ERC-1155 Soulbound NFTs), earn shares, and receive proportional BNB dividends from transaction taxes.

### How It Works

```
Buy WIZARD → Burn Tokens → Mint Item (VRF Random Quality) → Earn Shares → Collect BNB Dividends
```

1. **Burn to Mint** — Burn WIZARD tokens to mint magic items with Chainlink VRF random quality
2. **Earn Shares** — Each item grants shares based on type, quality multiplier, and decay coefficient
3. **Collect Dividends** — Transaction tax (BNB) is distributed proportionally to all share holders
4. **Forge & Upgrade** — Combine 3 identical items to attempt a quality upgrade

## Deployed Contract

| Network | Address | Verified Source |
|---------|---------|-----------------|
| **BSC Mainnet** | [`0x764b08Dc29bA6cd698Be29a3DA11a1826B5618E2`](https://bscscan.com/address/0x764b08Dc29bA6cd698Be29a3DA11a1826B5618E2) | [View on BSCScan](https://bscscan.com/address/0x764b08Dc29bA6cd698Be29a3DA11a1826B5618E2#code) |

## Contract Architecture

Single contract design — all logic in [`WizardDAO.sol`](contracts/WizardDAO.sol):

```
WizardDAO.sol
├── ERC-1155 Soulbound Items    (5 types × 6 qualities = 30 tokenIds)
├── Chainlink VRF v2.5          (on-chain randomness)
├── PancakeSwap Price Oracle    (WIZARD/WBNB reserves)
├── Chainlink BNB/USD Feed      (USD price conversion)
└── Accumulator Dividend Model  (O(1) gas dividendPerShare)
```

## Items

| Item | USD Price | Base Shares |
|:-----|:---------:|:-----------:|
| Wand | $5 | 100 |
| Potion | $15 | 300 |
| Spellbook | $50 | 1,000 |
| Crystal Ball | $150 | 3,000 |
| Wizard Crown | $500 | 10,000 |

## Quality System

Quality determined by **Chainlink VRF** on each mint:

| Quality | Probability | Multiplier |
|:--------|:-----------:|:----------:|
| Common | 50% | 0.7x |
| Fine | 25% | 1.0x |
| Rare | 15% | 1.5x |
| Epic | 7% | 2.5x |
| Legendary | 2.5% | 5.0x |
| Mythical | 0.5% | 15.0x |

> **Expected multiplier: 1.20x**

## Core Formulas

```
Final Shares    = Base Shares × Quality Multiplier × Decay Coefficient
Decay Factor    = INITIAL_POOL / (INITIAL_POOL + totalShares)
Mint Cost       = max(USD Base Price, NAV × Base Shares) / WIZARD USD Price
User Dividend   = User Shares × (Current DPS - Last Claimed DPS)
```

## Fusion System

Combine **3 items of the same type and quality** to attempt an upgrade:

| Upgrade Path | Success Rate |
|:-------------|:------------:|
| Common → Fine | 85% |
| Fine → Rare | 65% |
| Rare → Epic | 45% |
| Epic → Legendary | 25% |
| Legendary → Mythical | 10% |

- **Success**: New item at higher quality, shares = input × 1.5
- **Failure**: All 3 items destroyed, 40% shares returned

## Security

| Protection | Description |
|:-----------|:------------|
| Soulbound NFTs | Non-transferable, prevents share/NFT desync |
| Cooldown (100 blocks) | ~5 min between actions, prevents front-running |
| Burn to Dead Address | Natural flash loan protection |
| NAV Floor Pricing | Prevents share dilution |
| Asymptotic Decay | Prevents infinite share inflation |
| ReentrancyGuard | OpenZeppelin reentrancy protection |
| Price Validation | Chainlink negative/stale price checks |
| Reserve Checks | Minimum DEX liquidity requirements |
| Custom Errors | 14 gas-efficient custom errors |

## Token

| Property | Value |
|:---------|:------|
| Name | WIZARD |
| Launch | Four.meme |
| Supply | 1,000,000,000 (1B) |
| Tax | Buy 3% / Sell 3% → Dividend Contract |
| Standard | BEP-20 |

## Dependencies

- [OpenZeppelin](https://github.com/OpenZeppelin/openzeppelin-contracts) — ERC-1155, ReentrancyGuard, SafeERC20
- [Chainlink VRF v2.5](https://docs.chain.link/vrf) — Verifiable Random Function
- [PancakeSwap](https://pancakeswap.finance/) — DEX Price Oracle

## Built With

- Smart contract architecture & security audit powered by [Claude](https://claude.ai) (Anthropic)

---

<div align="center">

**MIT License** | Built on BNB Smart Chain

</div>
