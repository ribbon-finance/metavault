# Meta Vaults

Simple idea: build on top of the base **covered call**, **put selling**, **options buying** ribbon vaults to create innovative vaults, and potentially get a **cut of the fees**!

![](https://media.giphy.com/media/6AFldi5xJQYIo/giphy.gif?cid=790b76114d35b658e811d41752ae4f3c60a5cde2a6ba8f18&rid=giphy.gif&ct=g)

Example Vaults:
1. [Short strangle](https://tinyurl.com/shortya) strategy, which simultaneously deposits your funds into the eth covered call vault and put selling vault
3. Pseudo [knock-in / knock-out](https://www.investopedia.com/terms/k/knock-inoption.asp) options vault, which deposits into the corresponding delta vault
4. Use yields from delta neutral basis trading on [lemma.finance](https://medium.com/coinmonks/earning-defi-yield-via-basis-trading-379d1d5e7207) to buy call options on delta vault or directly bid on gnosis
5. Auto-purchase options from lending returns using delta vaults to gain market exposure (flavor of [Principal protected notes](https://www.investopedia.com/terms/p/principalprotectednote.asp) where instead of ATM call option you buy OTM call option)

A more comprehensive list can be found in this nice [thread by vadym](https://twitter.com/0x_vadym/status/1422257780891729921).

## Quick Start

We use Hardhat for compiling and testing

0. Install Node 12.3.0 with `nvm`

```sh
nvm install 12.3.0

nvm use 12.3.0
```

1. Install all the NodeJS dependencies with yarn.

```sh
yarn install
```

2. You can start compiling the Solidity code with Hardhat.

```sh
npx hardhat compile
```

3. You will need access to an archive node to run tests, since the tests use forked mainnet state. Create a .env file with a `TEST_URI`. Ask @chuddy for access to archive node.

```sh
TEST_URI=<add node url here>
```

4. Run the unit tests with the command:

```sh
npx hardhat test
```

## Deployment

Ribbon uses [hardhat-deploy](https://github.com/wighawag/hardhat-deploy) to manage contract deployments to the blockchain.

To deploy all the contracts to Kovan, do

```
yarn deploy --network kovan
```

The deployment info is stored on disk and committed into Git. Next, we have to export out the deployed addresses in a parseable format for the frontend to use (JSON).

```
yarn export-deployments
```

Finally, we can verify the contracts on Etherscan:

```
npx hardhat etherscan-verify --network kovan
```
