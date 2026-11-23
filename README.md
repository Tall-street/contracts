# Tall Street contracts

The game contracts for Tall Street, a daily tower game on Robinhood Chain. They follow the rules published at [Tall-street/rules](https://github.com/Tall-street/rules): the same numbers, the same checks and the same rounding.

Status: written and tested locally. **Not deployed and not audited.**

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

## Before deploying

- **Run the 20:00 UTC keeper.** It records the prices and closes the round, and needs a wallet with gas.
- **Set the $TALL thresholds** once the token is live.
- **Choose the owner and treasury addresses.**
- **Get a review or audit before real ETH.**
- **Deploy:** `OWNER=0x.. TREASURY=0x.. forge script script/Deploy.s.sol --rpc-url <robinhood rpc> --broadcast`, with the deployer's key given at deploy time.
