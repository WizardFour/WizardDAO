// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@chainlink/contracts/src/v0.8/vrf/dev/VRFConsumerBaseV2Plus.sol";
import "@chainlink/contracts/src/v0.8/vrf/dev/libraries/VRFV2PlusClient.sol";

/// @title WizardDAO - Wizard Burn & Dividend System
/// @notice Users burn WIZARD tokens to mint items -> earn shares -> receive proportional BNB dividends from transaction tax
/// @dev Integrates Chainlink VRF v2.5 + ERC-1155 + Accumulator Dividend Model (dividends paid in BNB)

// ============ Interfaces ============

interface IPancakePair {
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
    function token0() external view returns (address);
    function token1() external view returns (address);
}

interface IAggregatorV3 {
    function latestRoundData() external view returns (
        uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound
    );
    function decimals() external view returns (uint8);
}

// ============ Main Contract ============

contract WizardDAO is ERC1155, VRFConsumerBaseV2Plus, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ============ Custom Errors ============

    error InsufficientLiquidity();
    error InvalidPrice();
    error StalePrice();
    error CooldownActive();
    error InvalidCost();
    error MythicalCannotFuse();
    error NeedThreeProps();
    error NoTrackedShares();
    error UnknownRequest();
    error SharesTooSmall();
    error NothingToClaim();
    error TransferFailed();
    error InvalidParam();
    error Soulbound();

    // ============ Constants ============

    uint256 public constant PRECISION = 1e18;
    uint256 public constant INITIAL_DECAY_POOL = 1_000_000 * PRECISION; // Decay factor initial pool
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;

    // Quality probability thresholds (cumulative, /10000)
    uint16[6] public QUALITY_THRESHOLDS = [5000, 7500, 9000, 9700, 9950, 10000];
    // Quality share multipliers (/1000)
    uint16[6] public QUALITY_MULTIPLIERS = [700, 1000, 1500, 2500, 5000, 15000];
    // Fusion success rates (/10000) - Common->Fine, Fine->Rare, ...
    uint16[5] public FUSION_SUCCESS_RATES = [8500, 6500, 4500, 2500, 1000];

    // ============ Enums ============

    enum PropType { Wand, Potion, Book, Crystal, Crown }
    enum Quality { Common, Fine, Rare, Epic, Legendary, Mythical }
    enum RequestType { Mint, Fusion }

    // ============ Structs ============

    struct PropConfig {
        uint256 baseUsdCost;   // USD base price (1e18 precision, e.g. $5 = 5e18)
        uint256 baseShares;    // Base shares
    }

    struct MintRequest {
        address user;
        PropType propType;
        uint256 tokensBurned;
        RequestType requestType;
        // Fusion-specific fields
        uint256[3] fusionTokenIds;
        uint256[3] fusionAmounts;
        Quality fusionSourceQuality;
        PropType fusionSourcePropType;
        uint256 fusionTotalShares;
    }

    struct UserInfo {
        uint256 shares;          // User's total shares
        uint256 lastDividendPerShare; // DPS at last claim
        uint256 pendingRewards;  // Pending BNB rewards
        uint256 cooldownBlock;   // Cooldown end block
    }

    // ============ State Variables ============

    // Token
    IERC20 public wizardToken;

    // Price Oracles
    IPancakePair public dexPair;         // WIZARD/WBNB trading pair
    IAggregatorV3 public bnbPriceFeed;   // Chainlink BNB/USD
    bool public wizardIsToken0;          // Whether WIZARD is token0 in the pair

    // VRF
    uint256 public s_subscriptionId;
    bytes32 public s_keyHash;
    uint32 public s_callbackGasLimit = 350000;
    uint16 public s_requestConfirmations = 3;

    // Item configuration
    mapping(PropType => PropConfig) public propConfigs;

    // Shares & Dividends (BNB)
    uint256 public totalShares;
    uint256 public dividendPerShare;       // Accumulated BNB dividend per share (1e18 precision)
    uint256 public totalDividendsDistributed; // Total BNB distributed
    uint256 public totalDividendsClaimed;     // Total BNB claimed
    mapping(address => UserInfo) public users;

    // Item share records: tokenId => shares per individual item
    mapping(uint256 => uint256) public propShareValue;

    // VRF requests
    mapping(uint256 => MintRequest) public mintRequests;

    // Cooldown (anti-frontrunning)
    uint256 public cooldownBlocks = 100; // ~5 min on BSC

    // Fusion reward multipliers (/1000)
    uint256 public fusionSuccessMultiplier = 1500; // Success: 1.5x
    uint256 public fusionFailReturnRate = 400;     // Failure: return 40%

    // Item share tracking: user => tokenId => total shares contributed by this item
    mapping(address => mapping(uint256 => uint256)) public userPropShares;

    // Removed pendingDividendsWhenNoShares (fixed double-accounting bug)
    // BNB naturally stays in contract balance when totalShares==0, auto-included when shares exist

    // ============ Events ============

    event MintRequested(address indexed user, uint256 requestId, PropType propType, uint256 tokensBurned);
    event PropMinted(address indexed user, uint256 tokenId, PropType propType, Quality quality, uint256 shares);
    event FusionRequested(address indexed user, uint256 requestId, PropType propType, Quality sourceQuality);
    event FusionResult(address indexed user, bool success, uint256 newTokenId, uint256 newShares);
    event DividendsClaimed(address indexed user, uint256 amount);
    event DividendsDistributed(uint256 amount, uint256 newDividendPerShare);
    event SharesUpdated(address indexed user, uint256 newTotalShares);
    event EmergencyWithdraw(address indexed owner, uint256 amount);

    // ============ Constructor ============

    constructor(
        address _vrfCoordinator,
        uint256 _subscriptionId,
        bytes32 _keyHash,
        address _bnbPriceFeed,
        string memory _uri
    )
        ERC1155(_uri)
        VRFConsumerBaseV2Plus(_vrfCoordinator)
    {
        s_subscriptionId = _subscriptionId;
        s_keyHash = _keyHash;
        bnbPriceFeed = IAggregatorV3(_bnbPriceFeed);

        // Initialize item configs (USD prices in 1e18 precision)
        propConfigs[PropType.Wand]    = PropConfig(5 * PRECISION,   100);
        propConfigs[PropType.Potion]  = PropConfig(15 * PRECISION,  300);
        propConfigs[PropType.Book]    = PropConfig(50 * PRECISION,  1000);
        propConfigs[PropType.Crystal] = PropConfig(150 * PRECISION, 3000);
        propConfigs[PropType.Crown]   = PropConfig(500 * PRECISION, 10000);
    }

    // ============ Price Calculation ============

    /// @notice Get WIZARD token USD price (1e18 precision)
    function getWizardPriceUSD() public view returns (uint256) {
        // 1. Get WIZARD/WBNB price from PancakeSwap
        (uint112 reserve0, uint112 reserve1,) = dexPair.getReserves();
        uint256 wizardReserve;
        uint256 wbnbReserve;

        if (wizardIsToken0) {
            wizardReserve = uint256(reserve0);
            wbnbReserve = uint256(reserve1);
        } else {
            wizardReserve = uint256(reserve1);
            wbnbReserve = uint256(reserve0);
        }

        // Anti-flash-loan: minimum reserve check to prevent empty pool price manipulation
        if (wizardReserve <= 1e18 || wbnbReserve <= 1e15) revert InsufficientLiquidity();

        // WIZARD price in WBNB = wbnbReserve / wizardReserve
        uint256 wizardPriceInBNB = wbnbReserve * PRECISION / wizardReserve;

        // 2. Get BNB/USD price from Chainlink (with safety checks)
        (, int256 bnbPrice,,uint256 updatedAt,) = bnbPriceFeed.latestRoundData();
        if (bnbPrice <= 0) revert InvalidPrice();
        if (updatedAt <= block.timestamp - 3600) revert StalePrice();
        uint8 feedDecimals = bnbPriceFeed.decimals();

        // 3. WIZARD USD price = WIZARD/BNB * BNB/USD
        uint256 wizardPriceUSD = wizardPriceInBNB * uint256(bnbPrice) / (10 ** feedDecimals);

        return wizardPriceUSD;
    }

    /// @notice Calculate the number of tokens to burn for minting an item
    function getMintCost(PropType propType) public view returns (uint256 tokenAmount) {
        PropConfig memory config = propConfigs[propType];
        uint256 wizardPrice = getWizardPriceUSD();
        if (wizardPrice == 0) revert InvalidPrice();

        // Calculate token amount based on USD base price
        uint256 usdCost = config.baseUsdCost;

        // NAV floor: if current NAV > base price, use NAV
        if (totalShares > 0) {
            uint256 navPerShare = getTotalDividendValue() * PRECISION / totalShares;
            uint256 navCost = navPerShare * config.baseShares / PRECISION;
            if (navCost > usdCost) {
                usdCost = navCost;
            }
        }

        // USD cost / token price = tokens to burn
        tokenAmount = usdCost * PRECISION / wizardPrice;
    }

    /// @notice Get the current USD value of the dividend pool (BNB)
    function getTotalDividendValue() public view returns (uint256) {
        uint256 bnbBalance = address(this).balance;
        (, int256 bnbPrice,,uint256 updatedAt,) = bnbPriceFeed.latestRoundData();
        if (bnbPrice <= 0) revert InvalidPrice();
        if (updatedAt <= block.timestamp - 3600) revert StalePrice();
        uint8 feedDecimals = bnbPriceFeed.decimals();
        // BNB balance * BNB/USD price = dividend pool USD value
        return bnbBalance * uint256(bnbPrice) / (10 ** feedDecimals);
    }

    // ============ Decay Factor ============

    /// @notice Get current share decay factor (1e18 precision)
    function getDecayFactor() public view returns (uint256) {
        return INITIAL_DECAY_POOL * PRECISION / (INITIAL_DECAY_POOL + totalShares * PRECISION);
    }

    // ============ Dividend Update ============

    /// @notice Distribute BNB tax revenue to share holders
    function updateDividends() public {
        if (totalShares == 0) {
            // No share holders, BNB stays in contract balance
            // Will be auto-included via contractBalance - trackedBalance when shares exist
            return;
        }

        uint256 contractBalance = address(this).balance;
        uint256 trackedBalance = totalDividendsDistributed - totalDividendsClaimed;
        if (contractBalance <= trackedBalance) return;
        uint256 newDividends = contractBalance - trackedBalance;

        dividendPerShare += newDividends * PRECISION / totalShares;
        totalDividendsDistributed += newDividends;
        emit DividendsDistributed(newDividends, dividendPerShare);
    }

    /// @notice Update user's pending rewards
    function _updateUserRewards(address user) internal {
        UserInfo storage info = users[user];
        if (info.shares > 0) {
            uint256 pending = info.shares * (dividendPerShare - info.lastDividendPerShare) / PRECISION;
            info.pendingRewards += pending;
        }
        info.lastDividendPerShare = dividendPerShare;
    }

    // ============ Mint Items ============

    /// @notice Burn WIZARD tokens to mint an item (async, awaits VRF callback)
    function mintProp(PropType propType) external nonReentrant {
        if (block.number < users[msg.sender].cooldownBlock) revert CooldownActive();

        updateDividends();
        _updateUserRewards(msg.sender);

        uint256 cost = getMintCost(propType);
        if (cost == 0) revert InvalidCost();

        // Transfer tokens to dead address (permanent burn)
        wizardToken.safeTransferFrom(msg.sender, DEAD, cost);

        // Request VRF random number
        uint256 requestId = s_vrfCoordinator.requestRandomWords(
            VRFV2PlusClient.RandomWordsRequest({
                keyHash: s_keyHash,
                subId: s_subscriptionId,
                requestConfirmations: s_requestConfirmations,
                callbackGasLimit: s_callbackGasLimit,
                numWords: 1,
                extraArgs: VRFV2PlusClient._argsToBytes(
                    VRFV2PlusClient.ExtraArgsV1({nativePayment: false})
                )
            })
        );

        mintRequests[requestId] = MintRequest({
            user: msg.sender,
            propType: propType,
            tokensBurned: cost,
            requestType: RequestType.Mint,
            fusionTokenIds: [uint256(0), 0, 0],
            fusionAmounts: [uint256(0), 0, 0],
            fusionSourceQuality: Quality.Common,
            fusionSourcePropType: PropType.Wand,
            fusionTotalShares: 0
        });

        emit MintRequested(msg.sender, requestId, propType, cost);
    }

    // ============ Fuse Items ============

    /// @notice Fuse 3 items of the same type and quality to attempt an upgrade
    function fusionProps(PropType propType, Quality quality) external nonReentrant {
        if (uint8(quality) >= 5) revert MythicalCannotFuse();
        if (block.number < users[msg.sender].cooldownBlock) revert CooldownActive();

        updateDividends();
        _updateUserRewards(msg.sender);

        uint256 tokenId = encodeTokenId(propType, quality);
        uint256 userBalance = balanceOf(msg.sender, tokenId);
        if (userBalance < 3) revert NeedThreeProps();

        // Calculate total consumed shares (using user's tracked shares, averaged by balance)
        uint256 userSharesForToken = userPropShares[msg.sender][tokenId];
        if (userSharesForToken == 0) revert NoTrackedShares();
        uint256 avgSharesPerProp = userSharesForToken / userBalance;
        uint256 totalConsumedShares = avgSharesPerProp * 3;

        // Immediately deduct userPropShares (before VRF callback)
        userPropShares[msg.sender][tokenId] -= totalConsumedShares;

        // Burn 3 items
        _burn(msg.sender, tokenId, 3);

        // Request VRF
        uint256 requestId = s_vrfCoordinator.requestRandomWords(
            VRFV2PlusClient.RandomWordsRequest({
                keyHash: s_keyHash,
                subId: s_subscriptionId,
                requestConfirmations: s_requestConfirmations,
                callbackGasLimit: s_callbackGasLimit,
                numWords: 1,
                extraArgs: VRFV2PlusClient._argsToBytes(
                    VRFV2PlusClient.ExtraArgsV1({nativePayment: false})
                )
            })
        );

        mintRequests[requestId] = MintRequest({
            user: msg.sender,
            propType: propType,
            tokensBurned: 0,
            requestType: RequestType.Fusion,
            fusionTokenIds: [tokenId, 0, 0],
            fusionAmounts: [uint256(3), 0, 0],
            fusionSourceQuality: quality,
            fusionSourcePropType: propType,
            fusionTotalShares: totalConsumedShares
        });

        emit FusionRequested(msg.sender, requestId, propType, quality);
    }

    // ============ VRF Callback ============

    /// @notice Chainlink VRF callback - processes mint and fusion results
    function fulfillRandomWords(uint256 requestId, uint256[] calldata randomWords) internal override {
        MintRequest memory req = mintRequests[requestId];
        if (req.user == address(0)) revert UnknownRequest();

        // Distribute incoming BNB before modifying totalShares to ensure fair dividend allocation
        updateDividends();

        if (req.requestType == RequestType.Mint) {
            _handleMintResult(req, randomWords[0]);
        } else {
            _handleFusionResult(req, randomWords[0]);
        }

        delete mintRequests[requestId];
    }

    function _handleMintResult(MintRequest memory req, uint256 randomWord) internal {
        // 1. Determine quality
        Quality quality = _getQualityFromRandom(randomWord);

        // 2. Calculate shares = base shares * quality multiplier * decay factor
        PropConfig memory config = propConfigs[req.propType];
        uint256 qualityMul = QUALITY_MULTIPLIERS[uint8(quality)];
        uint256 decay = getDecayFactor();

        uint256 shares = config.baseShares * qualityMul * decay / (1000 * PRECISION);
        if (shares == 0) revert SharesTooSmall();

        // 3. Mint ERC-1155 item
        uint256 tokenId = encodeTokenId(req.propType, quality);
        _mint(req.user, tokenId, 1, "");

        // 4. Record item shares
        propShareValue[tokenId] = shares; // Latest minted share value
        userPropShares[req.user][tokenId] += shares;

        // 5. Add user shares
        _updateUserRewards(req.user);
        users[req.user].shares += shares;
        users[req.user].cooldownBlock = block.number + cooldownBlocks;
        totalShares += shares;

        emit PropMinted(req.user, tokenId, req.propType, quality, shares);
        emit SharesUpdated(req.user, users[req.user].shares);
    }

    function _handleFusionResult(MintRequest memory req, uint256 randomWord) internal {
        uint16 successRate = FUSION_SUCCESS_RATES[uint8(req.fusionSourceQuality)];
        bool success = (randomWord % 10000) < successRate;

        if (success) {
            // Fusion success: mint higher quality item
            Quality newQuality = Quality(uint8(req.fusionSourceQuality) + 1);
            uint256 newTokenId = encodeTokenId(req.fusionSourcePropType, newQuality);
            uint256 newShares = req.fusionTotalShares * fusionSuccessMultiplier / 1000;

            _mint(req.user, newTokenId, 1, "");
            propShareValue[newTokenId] = newShares;
            userPropShares[req.user][newTokenId] += newShares;

            // Share delta = new shares - old shares
            _updateUserRewards(req.user);
            users[req.user].shares = users[req.user].shares - req.fusionTotalShares + newShares;
            totalShares = totalShares - req.fusionTotalShares + newShares;

            emit FusionResult(req.user, true, newTokenId, newShares);
        } else {
            // Fusion failure: items already burned, return partial shares
            uint256 returnShares = req.fusionTotalShares * fusionFailReturnRate / 1000;
            uint256 lostShares = req.fusionTotalShares - returnShares;

            _updateUserRewards(req.user);
            users[req.user].shares -= lostShares;
            totalShares -= lostShares;

            emit FusionResult(req.user, false, 0, returnShares);
        }

        // Set cooldown after fusion as well
        users[req.user].cooldownBlock = block.number + cooldownBlocks;

        emit SharesUpdated(req.user, users[req.user].shares);
    }

    // ============ Claim Dividends ============

    /// @notice Claim accumulated BNB dividends
    function claim() external nonReentrant {
        if (block.number < users[msg.sender].cooldownBlock) revert CooldownActive();

        updateDividends();
        _updateUserRewards(msg.sender);

        uint256 amount = users[msg.sender].pendingRewards;
        if (amount == 0) revert NothingToClaim();

        users[msg.sender].pendingRewards = 0;
        totalDividendsClaimed += amount;

        // Send BNB to user
        (bool success, ) = payable(msg.sender).call{value: amount}("");
        if (!success) revert TransferFailed();
        emit DividendsClaimed(msg.sender, amount);
    }

    /// @notice Query user's pending BNB dividends
    function pendingRewards(address user) external view returns (uint256) {
        UserInfo memory info = users[user];
        uint256 pending = info.shares * (dividendPerShare - info.lastDividendPerShare) / PRECISION;
        return info.pendingRewards + pending;
    }

    // ============ Helper Functions ============

    /// @notice Encode tokenId = propType * 10 + quality
    function encodeTokenId(PropType propType, Quality quality) public pure returns (uint256) {
        return uint256(propType) * 10 + uint256(quality);
    }

    /// @notice Decode tokenId
    function decodeTokenId(uint256 tokenId) public pure returns (PropType propType, Quality quality) {
        propType = PropType(tokenId / 10);
        quality = Quality(tokenId % 10);
    }

    /// @notice Determine quality from random number
    function _getQualityFromRandom(uint256 randomWord) internal view returns (Quality) {
        uint16 roll = uint16(randomWord % 10000);
        for (uint8 i = 0; i < 6; i++) {
            if (roll < QUALITY_THRESHOLDS[i]) {
                return Quality(i);
            }
        }
        return Quality.Mythical;
    }

    // ============ Admin Functions ============

    /// @notice Update item configuration
    function setPropConfig(PropType propType, uint256 baseUsdCost, uint256 baseShares) external onlyOwner {
        if (baseUsdCost == 0 || baseShares == 0) revert InvalidParam();
        propConfigs[propType] = PropConfig(baseUsdCost, baseShares);
    }

    /// @notice Update cooldown blocks (10~1200 blocks, ~30s to ~1hr)
    function setCooldownBlocks(uint256 _blocks) external onlyOwner {
        if (_blocks < 10 || _blocks > 1200) revert InvalidParam();
        cooldownBlocks = _blocks;
    }

    /// @notice Update VRF parameters
    function setVRFConfig(
        uint256 _subId,
        bytes32 _keyHash,
        uint32 _callbackGasLimit,
        uint16 _confirmations
    ) external onlyOwner {
        s_subscriptionId = _subId;
        s_keyHash = _keyHash;
        s_callbackGasLimit = _callbackGasLimit;
        s_requestConfirmations = _confirmations;
    }

    /// @notice Update fusion parameters (success multiplier 1000~3000 i.e. 1x~3x, fail return 0~800 i.e. 0%~80%)
    function setFusionParams(uint256 _successMultiplier, uint256 _failReturnRate) external onlyOwner {
        if (_successMultiplier < 1000 || _successMultiplier > 3000) revert InvalidParam();
        if (_failReturnRate > 800) revert InvalidParam();
        fusionSuccessMultiplier = _successMultiplier;
        fusionFailReturnRate = _failReturnRate;
    }

    /// @notice Update quality thresholds (must be ascending, last value must be 10000)
    function setQualityThresholds(uint16[6] calldata _thresholds) external onlyOwner {
        if (_thresholds[5] != 10000) revert InvalidParam();
        for (uint8 i = 1; i < 6; i++) {
            if (_thresholds[i] < _thresholds[i - 1]) revert InvalidParam();
        }
        QUALITY_THRESHOLDS = _thresholds;
    }

    /// @notice Update quality multipliers
    function setQualityMultipliers(uint16[6] calldata _multipliers) external onlyOwner {
        QUALITY_MULTIPLIERS = _multipliers;
    }

    /// @notice Update fusion success rates (each value 0~10000)
    function setFusionSuccessRates(uint16[5] calldata _rates) external onlyOwner {
        for (uint8 i = 0; i < 5; i++) {
            if (_rates[i] > 10000) revert InvalidParam();
        }
        FUSION_SUCCESS_RATES = _rates;
    }

    /// @notice Set ERC-1155 metadata URI
    function setURI(string memory newUri) external onlyOwner {
        _setURI(newUri);
    }

    /// @notice Set WIZARD token address
    function setWizardToken(address _wizardToken) external onlyOwner {
        if (_wizardToken == address(0)) revert InvalidParam();
        wizardToken = IERC20(_wizardToken);
    }

    /// @notice Set DEX trading pair address
    function setDexPair(address _dexPair) external onlyOwner {
        if (_dexPair == address(0)) revert InvalidParam();
        dexPair = IPancakePair(_dexPair);
        wizardIsToken0 = dexPair.token0() == address(wizardToken);
    }

    /// @notice Owner emergency withdrawal of all BNB
    function emergencyWithdraw() external onlyOwner {
        uint256 balance = address(this).balance;
        if (balance == 0) revert NothingToClaim();
        (bool success, ) = payable(owner()).call{value: balance}("");
        if (!success) revert TransferFailed();
        emit EmergencyWithdraw(owner(), balance);
    }

    // ============ Soulbound (Non-transferable) ============

    /// @notice Prohibit NFT transfers, items are permanently bound after minting (only mint and burn allowed)
    function _update(
        address from,
        address to,
        uint256[] memory ids,
        uint256[] memory values
    ) internal override {
        // Allow minting (from == 0) and burning (to == 0)
        // Prohibit transfers between addresses
        if (from != address(0) && to != address(0)) {
            revert Soulbound();
        }
        super._update(from, to, ids, values);
    }

    // ============ Receive BNB ============

    /// @notice Receive BNB (transaction tax auto-deposited to contract)
    receive() external payable {}

    // ============ View Functions ============

    /// @notice Get user's complete info
    function getUserInfo(address user) external view returns (
        uint256 shares,
        uint256 pending,
        uint256 cooldownBlock,
        uint256 sharePercentage
    ) {
        UserInfo memory info = users[user];
        uint256 pendingAmount = info.shares * (dividendPerShare - info.lastDividendPerShare) / PRECISION;
        shares = info.shares;
        pending = info.pendingRewards + pendingAmount;
        cooldownBlock = info.cooldownBlock;
        sharePercentage = totalShares > 0 ? info.shares * 10000 / totalShares : 0; // basis points
    }

    /// @notice Get system global info
    function getSystemInfo() external view returns (
        uint256 _totalShares,
        uint256 _dividendPerShare,
        uint256 _totalDistributed,
        uint256 _totalClaimed,
        uint256 _decayFactor,
        uint256 _contractBalance
    ) {
        _totalShares = totalShares;
        _dividendPerShare = dividendPerShare;
        _totalDistributed = totalDividendsDistributed;
        _totalClaimed = totalDividendsClaimed;
        _decayFactor = getDecayFactor();
        _contractBalance = address(this).balance; // BNB balance
    }
}
