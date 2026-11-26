# Tall Street contracts

The game contracts for Tall Street, a daily tower game on Robinhood Chain. They follow the rules published at [Tall-street/rules](https://github.com/Tall-street/rules): the same numbers, the same checks and the same rounding.

Status: **deployed on Robinhood Chain** on 24 November 2026 and verified on Sourcify. **Open with $TALL** since 26 November 2026. **Not audited.**

## Deployed on Robinhood Chain

Chain 4663. Every contract is verified on [Sourcify](https://repo.sourcify.dev/4663/0xD96cb122028adBbe5e85C255598E66D2B9ab5999) with an exact match. The deploy records are in `broadcast/Deploy.s.sol/4663/` and, for the staking contract, `broadcast/DeployStaking.s.sol/4663/`.

| Contract | Address |
| --- | --- |
| TallStreet | `0xD96cb122028adBbe5e85C255598E66D2B9ab5999` |
| TallStaking | `0x21f36721dc6Ee094DB3Fb3A9b96147898D034548` |
| $TALL (the token, not one of these contracts) | `0x4c5FF4029f581010bEF5709EC0b909584b129BFb` |
| Price source, NVDA | `0x008261EB0a10401bB4544E5f223E62C5bFA93E60` |
| Price source, SPCX | `0x1F3bd2E013639C46F353E0cFf53EC499cB5dFF07` |
| Price source, TSLA | `0x5cda534647a4dc11F0e0c40f3d19a65c221E86B9` |
| Price source, AAPL | `0x6f4Ee2B8E3E00a8021A6cE76eA36028B991604eD` |
| Price source, AMZN | `0x0EF361A6184e2E71E007e91b05131716F4815a02` |
| Price source, MSFT | `0x37488577CaeFca3A672E9bd3B4ad0c599997b238` |
| Price source, AMD | `0x71104A4d7a711499290D6CADB2A6BbDC4aADBbce` |
| Price source, SPY | `0xa372258459D23eE3BFF694E4e263Be092d50f0F8` |
| Owner | `0xBC29FCcE61BFB72a196A8a09B74c715b0F137fc4` |
| Treasury | `0x9EB9A33B1A9351071ca95EC2D730322F5075b666` |

## Contracts

| Contract | What it does |
| --- | --- |
| `src/TallStreet.sol` | Rounds, crews, floors, prices at each 20:00 UTC, the close, claims and Tall Street's 10%. |
| `src/TallStaking.sol` | Stake $TALL for cheaper floors, with a 3-day cooldown to unstake. It only holds what people stake and never touches the token, its supply or its fees. |
| `src/prices/V3TwapPrice.sol` | A tower's stock price as a time-weighted average from a Uniswap v3 style pool (Aerodrome Slipstream uses the same oracle). |
| `src/libraries/TickPrice.sol` | 1.0001^tick in 18-decimal fixed point, across the full tick range. |

## How a round runs on-chain

- **Clock.** Round `r` opens at `r × 1 day + 20:00 UTC` and closes 24 hours later. Nothing has to open it.
- **Floors.** `placeFloors(tower, crew, floors)`:
  - takes one crew per wallet per round, and 1 to 20 floors per transaction;
  - charges exactly 0.001 ETH a floor, or 0.002 ETH in the final hour, priced when the transaction lands;
  - follows the holding rule: most floors holds the tower, and a draw stays with whoever got there first.
- **Prices.**
  - `recordPrices(boundary)` reads every tower's price at a 20:00 UTC, from the boundary until 2 hours later. Anyone can call it, and a keeper calls it at every 20:00 UTC.
  - A round's close is the next round's open, so each boundary is read once.
  - Each source gets a fixed gas allowance, and the recording only goes ahead when every source gets all of it, so a low gas limit can't blank a price.
  - A failed, missing or malformed reading counts as a weight of 1.00. No reading can stop a round from closing.
- **The close.** `settle(round)`:
  - anyone can call it after 20:00 UTC; it records the closing prices if nobody has;
  - weights the towers, picks the winner (ties go to more floors placed, then to the crew founded first), sets the winners' 90%, and adds 10% to the house balance.
- **Claims.** `claim(round)` pays each member of the winning crew their floors' share of the 90%, rounded down. `withdrawHouse()` sends the house balance to the treasury and nowhere else.

## Trust and admin

The owner (two-step ownership) can:

- pause new floors in an emergency. Closing, claims and withdrawals keep working. A pause also freezes the round in play as it stands, so it is for emergencies only;
- propose a new price source for a tower. It takes effect only after 2 days, so it can't be swapped right before a close;
- set the treasury, the $TALL token (once) and the perk thresholds.

The owner can't move the pot, change a settled result or touch anyone's claim.

## $TALL perks

| Perk | Rule |
| --- | --- |
| Found a crew | Hold at least `holderThreshold` $TALL, wallet plus staked. Open to anyone until $TALL and a threshold are set. |
| Bigger orders | Holders place up to 100 floors per transaction instead of 20. |
| Cheaper floors | Up to 20% off every floor at `fullDiscountStake` staked, proportional below it. |

## Price pools

Each tower reads a 30-minute average price from its stock's dollar pool on Robinhood Chain. `script/Deploy.s.sol` holds the list in the website's tower order. It reads which side of each pool the stock sits on, and it refuses a pool that doesn't pair the stock with USDG.

| Tower | Pool | Pair |
| --- | --- | --- |
| NVDA | Uniswap v3 `0xd4EB21209C4D6093f80B5b84f5C45cc093EA14a3` | NVDA / USDG |
| SPCX | Uniswap v3 `0xc61284332117c3FB23A2A56cceFFD07F7aF60029` | SPCX / USDG |
| TSLA | Uniswap v3 `0xf4ACdAEEB7022862A763C9B1B885e11191c889E3` | TSLA / USDG |
| AAPL | Uniswap v3 `0xAae0d815EE56e4092a5E5C2911E676Fea50B2d6D` | AAPL / USDG |
| AMZN | Uniswap v3 `0x8AC92DA74AB5F3b1d024Dc1943Ad7e15Dc4179Ef` | AMZN / USDG |
| MSFT | Uniswap v3 `0xeb60bCD1D920ad6E102690CCFC6fB488899E1510` | MSFT / USDG |
| AMD | Uniswap v3 `0x48D284A2A4d3DC1b3Da08231Fe44317e7e7Aa51f` | AMD / USDG |
| SPY | Aerodrome Slipstream `0x4A9b7cCBa4a3CD9Ee604AfA95d3DfA77D0d593e5` | SPY / USDG |

The pools were checked on-chain on 24 November 2026:

- Every pool keeps at least 3.5 hours of price history. A recording two hours late needs 2.5 hours.
- Metric pools and Uniswap v4 pools have no oracle a contract can read, so none are used.
- AAPL and AMD have the thinnest pools, about $120–130k each, so they're the cheapest to push around. Watch them as pots grow.

## A local street for the website

`script/Local.s.sol` puts the game on a local Anvil chain, so the website's live game can be built and tested without keys. The chain gets stand-in prices, three rival crews and some floors.

```
anvil --block-time 2 --timestamp <a 20:00 UTC boundary in seconds, plus a few>
cast rpc anvil_setCode 0xcA11bde05977b3631167028862bE2a173976CA11 $(cast code 0xcA11bde05977b3631167028862bE2a173976CA11 --rpc-url https://robinhood.drpc.org) --rpc-url http://127.0.0.1:8545
forge script script/Local.s.sol --rpc-url http://127.0.0.1:8545 --broadcast --gas-estimate-multiplier 500
```

- The second line copies Multicall3 from Robinhood Chain, which the website reads through.
- Start the website with `NEXT_PUBLIC_CHAIN_ID=31337` and with `NEXT_PUBLIC_TALLSTREET_ADDRESS` set to the address the script prints.
- On that chain the page offers a local test wallet.
- Move a price with `setPrice` on a source. Move the clock with `cast rpc evm_increaseTime`.

`recordPrices` (and `settle`, which calls it) only goes ahead when every price source gets its full gas allowance, so its gas limit must sit well above the gas it uses:

- Forge sizes a transaction from the gas it used, so the script needs the multiplier.
- Wallets estimate with the node and need nothing extra.
- The keeper should send these calls with a gas limit of 1,000,000.

## Tests

Install [Foundry](https://getfoundry.sh), then:

```
forge test
```

The tests cover the published rules case by case (the docs' 70.5 street value, the 0.07 ETH pot split, ties, the holding rule, weights, the final hour) and the on-chain parts: price windows, source delays, broken and malformed sources, low gas limits, crew names, staking and perks. Fuzz tests check that the weight matches the published formula exactly and that every pot splits into the winners' 90% and the house 10%.

A fork test reads every tower's live price through the deploy script's pools. It is skipped unless an RPC is given:

```
ROBINHOOD_RPC_URL=https://robinhood.drpc.org forge test --match-contract PoolsFork
```

## Deployment

- **How it was deployed:** `OWNER=0x.. TREASURY=0x.. forge script script/Deploy.s.sol --rpc-url <robinhood rpc> --broadcast --slow --interactives 1`, with the deployer's key typed at the prompt. It used 7.54M gas for 0.000151 ETH.
- **The 20:00 UTC keeper** records the prices and closes played rounds from its own gas-only wallet. It sends its calls with a gas limit of 3,000,000: a recording uses about 1.22M gas, and the contract wants each of the eight price reads to have its full 300,000 gas allowance in reach, so 1,000,000 was too little.
- **$TALL and staking** were set on 26 November 2026 by `script/DeployStaking.s.sol`, run from the owner's wallet: TallStaking deployed, `setTall` and `setPerks` called. A holder holds at least 1,000,000 $TALL, and the full 20% off comes at 10,000,000 staked. The script ran with `--evm-version cancun`, because the $TALL token's code uses MCOPY, and TallStaking is verified on Sourcify with the same setting.
- **Not audited.** The tests above are the only review so far.
