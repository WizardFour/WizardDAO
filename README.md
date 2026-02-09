<div align="center">

# WizardDAO

**BSC 链上巫师主题 GameFi 燃烧分红平台**

**Wizard-Themed GameFi Burn & Dividend Platform on BNB Smart Chain**

[![BSC](https://img.shields.io/badge/Chain-BSC-F0B90B?style=flat-square&logo=binance)](https://www.bnbchain.org/)
[![Solidity](https://img.shields.io/badge/Solidity-^0.8.20-363636?style=flat-square&logo=solidity)](https://soliditylang.org/)
[![Chainlink VRF](https://img.shields.io/badge/Chainlink-VRF%20v2.5-375BD2?style=flat-square&logo=chainlink)](https://chain.link/)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg?style=flat-square)](LICENSE)
[English](#english) | [中文](#中文)

</div>

---

<a id="english"></a>

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
| **BSC Mainnet** | *Coming Soon* | — |

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

---

<a id="中文"></a>

## 项目概述

WizardDAO 是 BSC 链上的 GameFi + DeFi 平台。用户燃烧 WIZARD 代币铸造魔法道具（ERC-1155 灵魂绑定 NFT），获得份额，按比例获取交易税收 BNB 分红。

### 运作流程

```
购买 WIZARD → 燃烧代币 → 铸造道具（VRF 随机品质）→ 获得份额 → 领取 BNB 分红
```

1. **燃烧铸造** — 燃烧 WIZARD 代币，铸造带有 Chainlink VRF 随机品质的魔法道具
2. **获得份额** — 每个道具根据类型、品质倍数和衰减系数授予份额
3. **领取分红** — 交易税收（BNB）按份额比例分配给所有持有者
4. **融合升级** — 3 个相同道具融合，尝试品质升级

## 已部署合约

| 网络 | 地址 | 验证源码 |
|------|------|----------|
| **BSC 主网** | *即将公布* | — |

## 合约架构

单合约设计 — 所有逻辑在 [`WizardDAO.sol`](contracts/WizardDAO.sol) 中：

```
WizardDAO.sol
├── ERC-1155 灵魂绑定道具    （5 种道具 × 6 种品质 = 30 个 tokenId）
├── Chainlink VRF v2.5      （链上随机数）
├── PancakeSwap 价格预言机   （WIZARD/WBNB 储备金读取）
├── Chainlink BNB/USD 喂价   （USD 价格转换）
└── 累加器分红模型           （O(1) Gas dividendPerShare）
```

## 道具系统

| 道具 | USD 价格 | 基础份额 |
|:-----|:--------:|:--------:|
| 魔法棒 Wand | $5 | 100 |
| 魔法药水 Potion | $15 | 300 |
| 魔法书 Spellbook | $50 | 1,000 |
| 水晶球 Crystal Ball | $150 | 3,000 |
| 巫师之冠 Wizard Crown | $500 | 10,000 |

## 品质系统

品质由 **Chainlink VRF** 在每次铸造时决定：

| 品质 | 概率 | 份额倍数 |
|:-----|:----:|:--------:|
| 普通 Common | 50% | 0.7x |
| 精良 Fine | 25% | 1.0x |
| 稀有 Rare | 15% | 1.5x |
| 史诗 Epic | 7% | 2.5x |
| 传说 Legendary | 2.5% | 5.0x |
| 神话 Mythical | 0.5% | 15.0x |

> **期望倍数：1.20x**

## 核心公式

```
最终份额 = 基础份额 × 品质倍数 × 衰减系数
衰减系数 = INITIAL_POOL / (INITIAL_POOL + totalShares)
铸造成本 = max(USD底价, NAV × 基础份额) / WIZARD USD价格
用户分红 = 用户份额 × (当前DPS - 上次领取DPS)
```

## 融合系统

**3 个相同类型、相同品质**的道具融合，尝试品质升级：

| 升级路径 | 成功率 |
|:---------|:------:|
| 普通 → 精良 | 85% |
| 精良 → 稀有 | 65% |
| 稀有 → 史诗 | 45% |
| 史诗 → 传说 | 25% |
| 传说 → 神话 | 10% |

- **成功**：获得更高品质道具，份额 = 投入 × 1.5
- **失败**：3 个道具销毁，返还 40% 份额

## 安全机制

| 防护措施 | 说明 |
|:---------|:-----|
| 灵魂绑定 NFT | 不可转让，防止份额与 NFT 脱节 |
| 冷却期 (100 区块) | ~5 分钟间隔，防抢跑 |
| 燃烧至死地址 | 天然防闪电贷 |
| NAV 底价保护 | 防份额稀释 |
| 份额衰减曲线 | 防无限膨胀 |
| ReentrancyGuard | OpenZeppelin 防重入 |
| 价格校验 | Chainlink 负数/过期价格检查 |
| 储备金检查 | DEX 最小流动性要求 |
| 自定义错误 | 14 个 gas 优化错误 |

## 代币信息

| 属性 | 值 |
|:-----|:---|
| 名称 | WIZARD |
| 发射平台 | Four.meme |
| 总量 | 1,000,000,000（10 亿） |
| 税收 | 买入 3% / 卖出 3% → 分红合约 |
| 标准 | BEP-20 |

## 依赖

- [OpenZeppelin](https://github.com/OpenZeppelin/openzeppelin-contracts) — ERC-1155, ReentrancyGuard, SafeERC20
- [Chainlink VRF v2.5](https://docs.chain.link/vrf) — 可验证随机函数
- [PancakeSwap](https://pancakeswap.finance/) — DEX 价格预言机

## Built With

- Smart contract architecture & security audit powered by [Claude](https://claude.ai) (Anthropic)

---

<div align="center">

**MIT License** | Built on BNB Smart Chain

</div>
