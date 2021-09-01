import { HardhatRuntimeEnvironment } from "hardhat/types";
import {
  WETH_ADDRESS,
  USDC_ADDRESS,
  COVERED_CALL_VAULT_ETH,
  PUT_SELLING_VAULT_ETH,
} from "../../test/helpers/constants";

const KOVAN_WETH = "0xd0A1E359811322d97991E03f863a0C30C2cF029C";
const KOVAN_USDC = "0x7e6edA50d1c833bE936492BF42C1BF376239E9e2";

const main = async ({
  network,
  deployments,
  ethers,
  getNamedAccounts,
}: HardhatRuntimeEnvironment) => {
  const { BigNumber } = ethers;
  const { parseEther } = ethers.utils;
  const { deploy } = deployments;
  const { deployer, owner, keeper, admin, feeRecipient } =
    await getNamedAccounts();
  console.log(`01 - Deploying ETH Short Straddle Vault on ${network.name}`);

  const isMainnet = network.name === "mainnet";
  const weth = isMainnet ? WETH_ADDRESS : KOVAN_WETH;
  const usdc = isMainnet ? USDC_ADDRESS : KOVAN_USDC;

  const logicDeployment = await deployments.get("RibbonStraddleVaultLogic");
  const lifecycle = await deployments.get("VaultLifecycle");

  const RibbonStraddleVault = await ethers.getContractFactory(
    "RibbonStraddleVault",
    {
      libraries: {
        VaultLifecycle: lifecycle.address,
      },
    }
  );

  const initArgs = [
    owner,
    keeper,
    feeRecipient,
    0,
    0,
    "Ribbon ETH Straddle Vault",
    "rETH-STRADDLE",
    COVERED_CALL_VAULT_ETH,
    PUT_SELLING_VAULT_ETH,
    {
      decimals: 8,
      asset: usdc,
      underlying: weth,
      minimumSupply: BigNumber.from(10).pow(3),
      cap: BigNumber.from(10).pow(12),
    },
  ];
  const initData = RibbonThetaVault.interface.encodeFunctionData(
    "initialize",
    initArgs
  );

  await deploy("RibbonETHStraddleVault", {
    contract: "AdminUpgradeabilityProxy",
    from: deployer,
    args: [logicDeployment.address, admin, initData],
  });
};
main.tags = ["RibbonETHStraddleVault"];
main.dependencies = ["RibbonStraddleVaultLogic"];

export default main;
