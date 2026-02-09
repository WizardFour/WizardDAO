const hre = require("hardhat");

async function main() {
  const [deployer] = await hre.ethers.getSigners();
  console.log("Deploying with account:", deployer.address);
  console.log(
    "Account balance:",
    hre.ethers.formatEther(await hre.ethers.provider.getBalance(deployer.address)),
    "BNB"
  );

  // ===== 部署参数 =====
  // Chainlink VRF v2.5 (BSC Mainnet)
  const VRF_COORDINATOR = "0xd691f04bc0C9a24Edb78af9E005Cf85768F694C9";
  const SUBSCRIPTION_ID = process.env.VRF_SUBSCRIPTION_ID || "0";
  const KEY_HASH =
    "0x130dba50ad435d4ecc214aad0d5820474137bd68e7e09a4a1b9a94e676e3b5f8"; // 500 gwei

  // Chainlink BNB/USD Price Feed (BSC Mainnet)
  const BNB_USD_FEED = "0x0567F2323251f0Aab15c8dFb1967E4e8A7D42aeE";

  // 初始分红池（衰减分母）
  const INITIAL_POOL = hre.ethers.parseEther("1000000"); // 1,000,000

  console.log("\nDeploy parameters:");
  console.log("  VRF Coordinator:", VRF_COORDINATOR);
  console.log("  Subscription ID:", SUBSCRIPTION_ID);
  console.log("  Key Hash:", KEY_HASH);
  console.log("  BNB/USD Feed:", BNB_USD_FEED);
  console.log("  Initial Pool:", hre.ethers.formatEther(INITIAL_POOL));

  // ===== 部署合约 =====
  console.log("\nDeploying WizardDAO...");
  const WizardDAO = await hre.ethers.getContractFactory("WizardDAO");
  const wizardDAO = await WizardDAO.deploy(
    VRF_COORDINATOR,
    SUBSCRIPTION_ID,
    KEY_HASH,
    BNB_USD_FEED,
    INITIAL_POOL
  );

  await wizardDAO.waitForDeployment();
  const address = await wizardDAO.getAddress();
  console.log("WizardDAO deployed to:", address);

  // ===== 部署后配置提醒 =====
  console.log("\n===== 部署后需手动配置 =====");
  console.log("1. 在 Chainlink VRF 订阅中添加此合约为 Consumer");
  console.log("2. 代币发射后调用 setWizardToken(tokenAddress)");
  console.log("3. LP 建好后调用 setDexPair(pairAddress)");
  console.log("4. 在 BSCScan 验证合约源码");
  console.log("================================\n");

  // ===== 验证合约（可选）=====
  if (process.env.BSCSCAN_API_KEY) {
    console.log("Waiting for block confirmations...");
    await wizardDAO.deploymentTransaction().wait(5);

    console.log("Verifying contract on BSCScan...");
    try {
      await hre.run("verify:verify", {
        address: address,
        constructorArguments: [
          VRF_COORDINATOR,
          SUBSCRIPTION_ID,
          KEY_HASH,
          BNB_USD_FEED,
          INITIAL_POOL,
        ],
      });
      console.log("Contract verified on BSCScan!");
    } catch (error) {
      console.log("Verification failed:", error.message);
    }
  }
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
