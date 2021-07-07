# DRAI: Dollar-Pegged RAI

_1 Drai = $1 USD = 1 Rai / OracleRelayer.redemptionPrice()_

## Overview

Drai is an ERC20 token representing a claim on Rai. It can be freely converted to and from Rai: the amount of Rai claimed by one Drai is proportional to the current redemption price of Rai, such that 1 Drai is pegged to $1 USD. To make this work, Drai balances are dynamic, and therefore *Drai cannot be safely used in many DeFi protocols*. This is implemented by having all internal accounting done in units of Rai, and converted to Drai only as needed, e.g. when calling `balanceOf(user)`.

Apart from the standard ERC20 functionality, the Drai contract includes a few other helper methods:

- ERC-2612 `permit` for approvals by signature
- `balanceOfRai(usr)` to return how many Rai a given user's Drai balance can claim
- `totalSupplyRai()` to return how many Rai are held by the contract
- `allowanceRai(owner, spender)` to return how many of the `owner`'s Drai the `spender` can spend, denominated in Rai
- `pull` to transfer Drai from another address to your address
- `push` as an alias for `transfer`
- `move` as an alias for `transferFrom`


## Development

This contract is built using [dapptools](http://dapp.tools/), and follows the standard dapptools procedure for building and testing. Tests related to the dollar-peg functionality are fuzzed.


To compile:
```sh
$ make all
```

To run the tests:
```sh
$ make test
```

## Integration

If you are an app or wallet integrating Drai, make sure you take the following considerations into account.

### Dynamic Balances

Drai is like a rebasing token in that is has dynamic balances. Therefore Drai should not be used with any applications or protocols that cache a token balance in their own storage&mdash;such as Uniswap&mdash;as these balances will quickly become inaccurate as the Rai redemption price changes.

Please consider carefully whether or not the app you want to use with Drai supports tokens with dynamic balances.

### Accurate Drai Balances

Rai's `OracleRelayer` does not expose a `view` method to query the current redemption price. Therefore, the Drai contract reads and caches this data on each state-changing action. This means that showing a user their Drai balance using `Drai.balanceOf(user)` will likely show a balance that is slightly out of date (unless someone interacted with the Drai contract very recently).

To show the most up tp date Drai balance, your app or wallet should read the last stored `_redemptionPrice`, `redemptionRate`, and `redemptionPriceUpdateTime` from the `OracleRelayer` contract, then compute the "current" redemption price by executing the logic in `OracleRelayer.redemptionPrice()`. 

However, the `_redemptionPrice` is an internal variable, so there is no public getter method for it. Instead you must read it by querying storage slot 4 of the `OracleRelayer` contract. You can do this with ethers' [`getStorageAt`](https://docs.ethers.io/v5/single-page/#/v5/api/providers/provider/-%23-Provider-getStorageAt) method:

```javascript
// Assuming you have an ethers provider instance called `provider`
const oracleRelayerAddr = '0x4ed9C0dCa0479bC64d8f4EB3007126D5791f7851';
const lastRedemptionPrice = await provider.getStorageAt(oracleRelayerAddr, 4);
```

Alternatively, you can do this with `seth` using `seth storage 0x4ed9C0dCa0479bC64d8f4EB3007126D5791f7851 4`

### Maximum Drai Balances

Internally, the Drai contract stores everything denominated in Rai, and Rai balances and allowances are used for all internal accounting. As a result, many methods convert Rai values to Drai before converting them.

The conversion from Rai to Drai requires multiplying by the current redemption price, which is on the order of `10 ** 27` (currently about `3 * 10 ** 27` at the time of this writing). This means there is a chance of overflow for users who have more than `(2^256-1) / (3 * 10^27) / 1e18` Rai. This is extremely unlikely to happen, and it can be worked around in the rare case it does happen. The main purpose of noting this here is because it affects fuzz testing, to avoid overflow failures.