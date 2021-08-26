# Meta vaults

Simple idea: build on top of the base **covered call**, **put selling**, **options buying** ribbon vaults to create innovative vaults, and get a **cut of the fees**!

![](https://media.giphy.com/media/6AFldi5xJQYIo/giphy.gif?cid=790b76114d35b658e811d41752ae4f3c60a5cde2a6ba8f18&rid=giphy.gif&ct=g)

Example Vaults:
1. [Short strangle](https://tinyurl.com/shortya) strategy, which simultaneously deposits your funds into the eth covered call vault and put selling vault
3. Pseudo [knock-in / knock-out](https://www.investopedia.com/terms/k/knock-inoption.asp) options vault, which deposits into the corresponding delta vault
4. Use yields from delta neutral basis trading on [lemma.finance](https://medium.com/coinmonks/earning-defi-yield-via-basis-trading-379d1d5e7207) to buy call options on delta vault or directly bid on gnosis
5. Auto-purchase options from lending returns using delta vaults to gain market exposure (flavor of [Principal protected notes](https://www.investopedia.com/terms/p/principalprotectednote.asp) where instead of ATM call option you buy OTM call option)


Credits to [Vadym](https://twitter.com/0x_vadym) for some of these ideas
