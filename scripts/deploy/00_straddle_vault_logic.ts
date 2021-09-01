import { HardhatRuntimeEnvironment } from "hardhat/types";
import { WETH_ADDRESS, USDC_ADDRESS } from "../../test/helpers/constants";

const KOVAN_WETH = "0xd0A1E359811322d97991E03f863a0C30C2cF029C";
const KOVAN_USDC = "0x7e6edA50d1c833bE936492BF42C1BF376239E9e2";

const main = async ({
  network,
  deployments,
  getNamedAccounts,
}: HardhatRuntimeEnvironment) => {
  const { deploy } = deployments;
  const { deployer } = await getNamedAccounts();
  console.log(`00 - Deploying Short Straddle Vault logic on ${network.name}`);

  const isMainnet = network.name === "mainnet";
  const weth = isMainnet ? WETH_ADDRESS : KOVAN_WETH;
  const usdc = isMainnet ? USDC_ADDRESS : KOVAN_USDC;

  const lifecycle = await deploy("VaultLifecycle", {
    contract: "VaultLifecycle",
    from: deployer,
  });

  await deploy("RibbonStraddleVault", {
    contract: "RibbonStraddleVault",
    from: deployer,
    args: [weth, usdc],
    libraries: {
      VaultLifecycle: lifecycle.address,
    },
  });
};
main.tags = ["RibbonStraddleVaultLogic"];

export default main;
