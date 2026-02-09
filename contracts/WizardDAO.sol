// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@chainlink/contracts/src/v0.8/vrf/dev/VRFConsumerBaseV2Plus.sol";
import "@chainlink/contracts/src/v0.8/vrf/dev/libraries/VRFV2PlusClient.sol";

/// @title WizardDAO - 巫师燃烧分红系统
/// @notice 用户燃烧 WIZARD 代币铸造道具 → 获得份额 → 按份额比例获得交易税收 BNB 分红
/// @dev 集成 Chainlink VRF v2.5 + ERC-1155 + 累加器分红模型（分红以 BNB 发放）

// ============ 接口 ============

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

// ============ 主合约 ============

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

    // ============ 常量 ============

    uint256 public constant PRECISION = 1e18;
    uint256 public constant INITIAL_DECAY_POOL = 1_000_000 * PRECISION; // 衰减因子初始池
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;

    // 品质概率阈值 (cumulative, /10000)
    uint16[6] public QUALITY_THRESHOLDS = [5000, 7500, 9000, 9700, 9950, 10000];
    // 品质份额倍数 (/1000)
    uint16[6] public QUALITY_MULTIPLIERS = [700, 1000, 1500, 2500, 5000, 15000];
    // 融合成功率 (/10000) - 普通→精良, 精良→稀有, ...
    uint16[5] public FUSION_SUCCESS_RATES = [8500, 6500, 4500, 2500, 1000];

    // ============ 枚举 ============

    enum PropType { Wand, Potion, Book, Crystal, Crown }
    enum Quality { Common, Fine, Rare, Epic, Legendary, Mythical }
    enum RequestType { Mint, Fusion }

    // ============ 结构体 ============

    struct PropConfig {
        uint256 baseUsdCost;   // USD 底价 (1e18 精度, 如 $5 = 5e18)
        uint256 baseShares;    // 基础份额
    }

    struct MintRequest {
        address user;
        PropType propType;
        uint256 tokensBurned;
        RequestType requestType;
        // 融合专用
        uint256[3] fusionTokenIds;
        uint256[3] fusionAmounts;
        Quality fusionSourceQuality;
        PropType fusionSourcePropType;
        uint256 fusionTotalShares;
    }

    struct UserInfo {
        uint256 shares;          // 用户总份额
        uint256 lastDividendPerShare; // 上次领取时的 DPS
        uint256 pendingRewards;  // 待领取 BNB 奖励
        uint256 cooldownBlock;   // 冷却期结束区块
    }

    // ============ 状态变量 ============

    // 代币
    IERC20 public wizardToken;

    // 价格预言机
    IPancakePair public dexPair;         // WIZARD/WBNB 交易对
    IAggregatorV3 public bnbPriceFeed;   // Chainlink BNB/USD
    bool public wizardIsToken0;          // WIZARD 是否为 pair 的 token0

    // VRF
    uint256 public s_subscriptionId;
    bytes32 public s_keyHash;
    uint32 public s_callbackGasLimit = 350000;
    uint16 public s_requestConfirmations = 3;

    // 道具配置
    mapping(PropType => PropConfig) public propConfigs;

    // 份额与分红（BNB）
    uint256 public totalShares;
    uint256 public dividendPerShare;       // 每份额累计 BNB 分红 (1e18 精度)
    uint256 public totalDividendsDistributed; // 已分配的 BNB 总量
    uint256 public totalDividendsClaimed;     // 已领取的 BNB 总量
    mapping(address => UserInfo) public users;

    // 道具份额记录: tokenId => 单个道具的份额数
    mapping(uint256 => uint256) public propShareValue;

    // VRF 请求
    mapping(uint256 => MintRequest) public mintRequests;

    // 冷却期（防抢跑）
    uint256 public cooldownBlocks = 100; // ~5分钟 on BSC

    // 融合奖励倍数 (/1000)
    uint256 public fusionSuccessMultiplier = 1500; // 成功: 1.5x
    uint256 public fusionFailReturnRate = 400;     // 失败: 返还 40%

    // 道具份额追踪: user => tokenId => 该道具贡献的总份额
    mapping(address => mapping(uint256 => uint256)) public userPropShares;

    // 已删除 pendingDividendsWhenNoShares（修复双重计账 Bug）
    // BNB 在 totalShares==0 时自然留在合约余额中，下次有份额时自动计入

    // ============ 事件 ============

    event MintRequested(address indexed user, uint256 requestId, PropType propType, uint256 tokensBurned);
    event PropMinted(address indexed user, uint256 tokenId, PropType propType, Quality quality, uint256 shares);
    event FusionRequested(address indexed user, uint256 requestId, PropType propType, Quality sourceQuality);
    event FusionResult(address indexed user, bool success, uint256 newTokenId, uint256 newShares);
    event DividendsClaimed(address indexed user, uint256 amount);
    event DividendsDistributed(uint256 amount, uint256 newDividendPerShare);
    event SharesUpdated(address indexed user, uint256 newTotalShares);
    event EmergencyWithdraw(address indexed owner, uint256 amount);

    // ============ 构造函数 ============

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

        // 初始化道具配置 (USD 价格用 1e18 精度)
        propConfigs[PropType.Wand]    = PropConfig(5 * PRECISION,   100);
        propConfigs[PropType.Potion]  = PropConfig(15 * PRECISION,  300);
        propConfigs[PropType.Book]    = PropConfig(50 * PRECISION,  1000);
        propConfigs[PropType.Crystal] = PropConfig(150 * PRECISION, 3000);
        propConfigs[PropType.Crown]   = PropConfig(500 * PRECISION, 10000);
    }

    // ============ 价格计算 ============

    /// @notice 获取 WIZARD 代币的 USD 价格 (1e18 精度)
    function getWizardPriceUSD() public view returns (uint256) {
        // 1. 从 PancakeSwap 获取 WIZARD/WBNB 价格
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

        // 防闪电贷：储备金最小值检查，防止空池价格操纵
        if (wizardReserve <= 1e18 || wbnbReserve <= 1e15) revert InsufficientLiquidity();

        // WIZARD 价格 (以 WBNB 计) = wbnbReserve / wizardReserve
        uint256 wizardPriceInBNB = wbnbReserve * PRECISION / wizardReserve;

        // 2. 从 Chainlink 获取 BNB/USD 价格（含安全校验）
        (, int256 bnbPrice,,uint256 updatedAt,) = bnbPriceFeed.latestRoundData();
        if (bnbPrice <= 0) revert InvalidPrice();
        if (updatedAt <= block.timestamp - 3600) revert StalePrice();
        uint8 feedDecimals = bnbPriceFeed.decimals();

        // 3. WIZARD USD 价格 = WIZARD/BNB × BNB/USD
        uint256 wizardPriceUSD = wizardPriceInBNB * uint256(bnbPrice) / (10 ** feedDecimals);

        return wizardPriceUSD;
    }

    /// @notice 计算铸造某道具需要燃烧的代币数量
    function getMintCost(PropType propType) public view returns (uint256 tokenAmount) {
        PropConfig memory config = propConfigs[propType];
        uint256 wizardPrice = getWizardPriceUSD();
        if (wizardPrice == 0) revert InvalidPrice();

        // 基于 USD 底价计算代币数量
        uint256 usdCost = config.baseUsdCost;

        // NAV 保底: 如果当前 NAV > 底价，按 NAV 算
        if (totalShares > 0) {
            uint256 navPerShare = getTotalDividendValue() * PRECISION / totalShares;
            uint256 navCost = navPerShare * config.baseShares / PRECISION;
            if (navCost > usdCost) {
                usdCost = navCost;
            }
        }

        // USD 成本 / 代币价格 = 需要燃烧的代币数
        tokenAmount = usdCost * PRECISION / wizardPrice;
    }

    /// @notice 获取分红池（BNB）当前 USD 总值
    function getTotalDividendValue() public view returns (uint256) {
        uint256 bnbBalance = address(this).balance;
        (, int256 bnbPrice,,uint256 updatedAt,) = bnbPriceFeed.latestRoundData();
        if (bnbPrice <= 0) revert InvalidPrice();
        if (updatedAt <= block.timestamp - 3600) revert StalePrice();
        uint8 feedDecimals = bnbPriceFeed.decimals();
        // BNB 余额 × BNB/USD 价格 = 分红池 USD 总值
        return bnbBalance * uint256(bnbPrice) / (10 ** feedDecimals);
    }

    // ============ 衰减系数 ============

    /// @notice 获取当前份额衰减系数 (1e18 精度)
    function getDecayFactor() public view returns (uint256) {
        return INITIAL_DECAY_POOL * PRECISION / (INITIAL_DECAY_POOL + totalShares * PRECISION);
    }

    // ============ 分红更新 ============

    /// @notice 将合约收到的 BNB 税收分配给份额持有者
    function updateDividends() public {
        if (totalShares == 0) {
            // 没有份额持有者，BNB 自然留在合约余额中
            // 下次有份额时 contractBalance - trackedBalance 会自动包含这些 BNB
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

    /// @notice 更新用户待领取分红
    function _updateUserRewards(address user) internal {
        UserInfo storage info = users[user];
        if (info.shares > 0) {
            uint256 pending = info.shares * (dividendPerShare - info.lastDividendPerShare) / PRECISION;
            info.pendingRewards += pending;
        }
        info.lastDividendPerShare = dividendPerShare;
    }

    // ============ 铸造道具 ============

    /// @notice 燃烧 WIZARD 代币铸造道具（异步，等待 VRF 回调）
    function mintProp(PropType propType) external nonReentrant {
        if (block.number < users[msg.sender].cooldownBlock) revert CooldownActive();

        updateDividends();
        _updateUserRewards(msg.sender);

        uint256 cost = getMintCost(propType);
        if (cost == 0) revert InvalidCost();

        // 将代币转到死地址（永久销毁）
        wizardToken.safeTransferFrom(msg.sender, DEAD, cost);

        // 请求 VRF 随机数
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

    // ============ 融合道具 ============

    /// @notice 融合 3 个同类型同品质道具，尝试升级
    function fusionProps(PropType propType, Quality quality) external nonReentrant {
        if (uint8(quality) >= 5) revert MythicalCannotFuse();
        if (block.number < users[msg.sender].cooldownBlock) revert CooldownActive();

        updateDividends();
        _updateUserRewards(msg.sender);

        uint256 tokenId = encodeTokenId(propType, quality);
        uint256 userBalance = balanceOf(msg.sender, tokenId);
        if (userBalance < 3) revert NeedThreeProps();

        // 计算消耗的总份额（用用户实际追踪的份额，按持有量平均计算）
        uint256 userSharesForToken = userPropShares[msg.sender][tokenId];
        if (userSharesForToken == 0) revert NoTrackedShares();
        uint256 avgSharesPerProp = userSharesForToken / userBalance;
        uint256 totalConsumedShares = avgSharesPerProp * 3;

        // 立即扣减 userPropShares（在 VRF 回调前）
        userPropShares[msg.sender][tokenId] -= totalConsumedShares;

        // 销毁 3 个道具
        _burn(msg.sender, tokenId, 3);

        // 请求 VRF
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

    // ============ VRF 回调 ============

    /// @notice Chainlink VRF 回调 - 处理铸造和融合结果
    function fulfillRandomWords(uint256 requestId, uint256[] calldata randomWords) internal override {
        MintRequest memory req = mintRequests[requestId];
        if (req.user == address(0)) revert UnknownRequest();

        // 在修改 totalShares 前先分配到账的 BNB，确保分红公平
        updateDividends();

        if (req.requestType == RequestType.Mint) {
            _handleMintResult(req, randomWords[0]);
        } else {
            _handleFusionResult(req, randomWords[0]);
        }

        delete mintRequests[requestId];
    }

    function _handleMintResult(MintRequest memory req, uint256 randomWord) internal {
        // 1. 确定品质
        Quality quality = _getQualityFromRandom(randomWord);

        // 2. 计算份额 = 基础份额 × 品质倍数 × 衰减系数
        PropConfig memory config = propConfigs[req.propType];
        uint256 qualityMul = QUALITY_MULTIPLIERS[uint8(quality)];
        uint256 decay = getDecayFactor();

        uint256 shares = config.baseShares * qualityMul * decay / (1000 * PRECISION);
        if (shares == 0) revert SharesTooSmall();

        // 3. 铸造 ERC-1155 道具
        uint256 tokenId = encodeTokenId(req.propType, quality);
        _mint(req.user, tokenId, 1, "");

        // 4. 记录道具份额
        propShareValue[tokenId] = shares; // 最新铸造的份额值
        userPropShares[req.user][tokenId] += shares;

        // 5. 增加用户份额
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
            // 融合成功：生成高一级品质道具
            Quality newQuality = Quality(uint8(req.fusionSourceQuality) + 1);
            uint256 newTokenId = encodeTokenId(req.fusionSourcePropType, newQuality);
            uint256 newShares = req.fusionTotalShares * fusionSuccessMultiplier / 1000;

            _mint(req.user, newTokenId, 1, "");
            propShareValue[newTokenId] = newShares;
            userPropShares[req.user][newTokenId] += newShares;

            // 份额变化 = 新份额 - 旧份额
            _updateUserRewards(req.user);
            users[req.user].shares = users[req.user].shares - req.fusionTotalShares + newShares;
            totalShares = totalShares - req.fusionTotalShares + newShares;

            emit FusionResult(req.user, true, newTokenId, newShares);
        } else {
            // 融合失败：道具已销毁，返还部分份额
            uint256 returnShares = req.fusionTotalShares * fusionFailReturnRate / 1000;
            uint256 lostShares = req.fusionTotalShares - returnShares;

            _updateUserRewards(req.user);
            users[req.user].shares -= lostShares;
            totalShares -= lostShares;

            emit FusionResult(req.user, false, 0, returnShares);
        }

        // 融合后也设冷却期
        users[req.user].cooldownBlock = block.number + cooldownBlocks;

        emit SharesUpdated(req.user, users[req.user].shares);
    }

    // ============ 领取分红 ============

    /// @notice 领取累计 BNB 分红
    function claim() external nonReentrant {
        if (block.number < users[msg.sender].cooldownBlock) revert CooldownActive();

        updateDividends();
        _updateUserRewards(msg.sender);

        uint256 amount = users[msg.sender].pendingRewards;
        if (amount == 0) revert NothingToClaim();

        users[msg.sender].pendingRewards = 0;
        totalDividendsClaimed += amount;

        // 发送 BNB 给用户
        (bool success, ) = payable(msg.sender).call{value: amount}("");
        if (!success) revert TransferFailed();
        emit DividendsClaimed(msg.sender, amount);
    }

    /// @notice 查询用户待领取 BNB 分红
    function pendingRewards(address user) external view returns (uint256) {
        UserInfo memory info = users[user];
        uint256 pending = info.shares * (dividendPerShare - info.lastDividendPerShare) / PRECISION;
        return info.pendingRewards + pending;
    }

    // ============ 辅助函数 ============

    /// @notice 编码 tokenId = propType * 10 + quality
    function encodeTokenId(PropType propType, Quality quality) public pure returns (uint256) {
        return uint256(propType) * 10 + uint256(quality);
    }

    /// @notice 解码 tokenId
    function decodeTokenId(uint256 tokenId) public pure returns (PropType propType, Quality quality) {
        propType = PropType(tokenId / 10);
        quality = Quality(tokenId % 10);
    }

    /// @notice 根据随机数确定品质
    function _getQualityFromRandom(uint256 randomWord) internal view returns (Quality) {
        uint16 roll = uint16(randomWord % 10000);
        for (uint8 i = 0; i < 6; i++) {
            if (roll < QUALITY_THRESHOLDS[i]) {
                return Quality(i);
            }
        }
        return Quality.Mythical;
    }

    // ============ 管理函数 ============

    /// @notice 更新道具配置
    function setPropConfig(PropType propType, uint256 baseUsdCost, uint256 baseShares) external onlyOwner {
        if (baseUsdCost == 0 || baseShares == 0) revert InvalidParam();
        propConfigs[propType] = PropConfig(baseUsdCost, baseShares);
    }

    /// @notice 更新冷却区块数（10~1200 区块，约 30秒~1小时）
    function setCooldownBlocks(uint256 _blocks) external onlyOwner {
        if (_blocks < 10 || _blocks > 1200) revert InvalidParam();
        cooldownBlocks = _blocks;
    }

    /// @notice 更新 VRF 参数
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

    /// @notice 更新融合参数（成功倍数 1000~3000 即 1x~3x，失败返还 0~800 即 0%~80%）
    function setFusionParams(uint256 _successMultiplier, uint256 _failReturnRate) external onlyOwner {
        if (_successMultiplier < 1000 || _successMultiplier > 3000) revert InvalidParam();
        if (_failReturnRate > 800) revert InvalidParam();
        fusionSuccessMultiplier = _successMultiplier;
        fusionFailReturnRate = _failReturnRate;
    }

    /// @notice 更新品质概率（必须升序且最后一个为 10000）
    function setQualityThresholds(uint16[6] calldata _thresholds) external onlyOwner {
        if (_thresholds[5] != 10000) revert InvalidParam();
        for (uint8 i = 1; i < 6; i++) {
            if (_thresholds[i] < _thresholds[i - 1]) revert InvalidParam();
        }
        QUALITY_THRESHOLDS = _thresholds;
    }

    /// @notice 更新品质倍数
    function setQualityMultipliers(uint16[6] calldata _multipliers) external onlyOwner {
        QUALITY_MULTIPLIERS = _multipliers;
    }

    /// @notice 更新融合成功率（每个值 0~10000）
    function setFusionSuccessRates(uint16[5] calldata _rates) external onlyOwner {
        for (uint8 i = 0; i < 5; i++) {
            if (_rates[i] > 10000) revert InvalidParam();
        }
        FUSION_SUCCESS_RATES = _rates;
    }

    /// @notice 设置 ERC-1155 URI
    function setURI(string memory newUri) external onlyOwner {
        _setURI(newUri);
    }

    /// @notice 设置 WIZARD 代币地址
    function setWizardToken(address _wizardToken) external onlyOwner {
        if (_wizardToken == address(0)) revert InvalidParam();
        wizardToken = IERC20(_wizardToken);
    }

    /// @notice 设置 DEX 交易对地址
    function setDexPair(address _dexPair) external onlyOwner {
        if (_dexPair == address(0)) revert InvalidParam();
        dexPair = IPancakePair(_dexPair);
        wizardIsToken0 = dexPair.token0() == address(wizardToken);
    }

    /// @notice Owner
    function emergencyWithdraw() external onlyOwner {
        uint256 balance = address(this).balance;
        if (balance == 0) revert NothingToClaim();
        (bool success, ) = payable(owner()).call{value: balance}("");
        if (!success) revert TransferFailed();
        emit EmergencyWithdraw(owner(), balance);
    }

    // ============ Soulbound（灵魂绑定，不可转让） ============

    /// @notice 禁止 NFT 转让，道具铸造后永久绑定（仅允许铸造和销毁）
    function _update(
        address from,
        address to,
        uint256[] memory ids,
        uint256[] memory values
    ) internal override {
        // 允许铸造（from == 0）和销毁（to == 0）
        // 禁止地址之间的转账
        if (from != address(0) && to != address(0)) {
            revert Soulbound();
        }
        super._update(from, to, ids, values);
    }

    // ============ 接收 BNB ============

    /// @notice 接收 BNB（交易税收自动打入合约）
    receive() external payable {}

    // ============ 查询函数 ============

    /// @notice 获取用户完整信息
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

    /// @notice 获取系统全局信息
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
        _contractBalance = address(this).balance; // BNB 余额
    }
}
