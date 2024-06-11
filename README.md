# Auto Compound Hook

The Auto compound is a hook for LP providers to increase their yield. As Uniswap v4 manages earned fees separate from the actual pool. This leads to the part where users may earn a lot of fees but that money will be sitting there and doing nothing. Auto compound will provide an automatic way of reinvesting that money into LP positions. Users could do manual reinvesting but many times it is not efficient enough. There can be several things you need to take care of while compounding the liquidity manually. But with this hook, it automatically takes care of all the things. The idea revolves around these concepts.

1. LP Providers whose fees will be reinvested
2. Swappers / Other Liquidity Providers which will trigger the auto reinvest.
3. Auto Swapping fee according to the required price ratio to properly use the earned fee.

The current implementation does not incentivize the Swappers or Other liquidity providers. But it is required to provide an incentive mechanism for them also. So that they will be willing to do the transactions. One way to incentivize them is by paying back the transaction fee or paying them a portion of the LP fee.

## Usage

### Build

```shell
$ forge build
```

### Test

```shell
$ forge test
```

### Format

```shell
$ forge fmt
```

### Acknowledgements

Inspired by [Revert Compounder](https://github.com/revert-finance/compoundor)
