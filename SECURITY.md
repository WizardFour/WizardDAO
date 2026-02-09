# Security Policy

## Supported Versions

| Version | Supported |
|---------|-----------|
| BSC Mainnet (`0x764b...18E2`) | ✅ |

## Reporting a Vulnerability

If you discover a security vulnerability in WizardDAO, please report it responsibly.

### Contact

- **Email**: Open a [GitHub Issue](https://github.com/user/WizardDAO/issues) with the label `security`
- **Severity**: Please include the severity level (Critical / High / Medium / Low)

### What to Include

1. Description of the vulnerability
2. Steps to reproduce
3. Potential impact
4. Suggested fix (if any)

### Response Timeline

- **Acknowledgement**: Within 48 hours
- **Initial Assessment**: Within 1 week
- **Fix Timeline**: Depends on severity

## Security Measures

The WizardDAO smart contract implements the following security measures:

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

## Audit Status

- Internal security audit completed (7 issues identified and fixed)
- No formal third-party audit has been conducted

## Known Risks

- **Smart contract risk**: Code is deployed on BSC mainnet and is immutable
- **Oracle dependency**: Relies on Chainlink VRF and BNB/USD price feed
- **DEX dependency**: Relies on PancakeSwap WIZARD/WBNB pair for pricing
- **Owner privileges**: Owner can call `emergencyWithdraw()`, `setWizardToken()`, `setDexPair()`, and parameter adjustment functions
