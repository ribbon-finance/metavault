import "@nomiclabs/hardhat-ethers";
import "@nomiclabs/hardhat-waffle";

require("dotenv").config();

export default {
  solidity: {
    version: "0.7.3",
    settings: {
      optimizer: {
        runs: 200,
        enabled: true,
      },
    },
  },
  networks: {
    hardhat: {
      forking: {
        url: process.env.TEST_URI,
        gasLimit: 8e6,
        blockNumber: 12570201,
      },
    },
  },
  mocha: {
    timeout: 500000,
  },
};
