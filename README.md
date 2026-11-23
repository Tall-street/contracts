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

## Tests

Install [Foundry](https://getfoundry.sh), then:

```
forge test
```

The tests cover the published rules case by case (the docs' 70.5 street value, the 0.07 ETH pot split, ties, the holding rule, weights, the final hour) and the on-chain parts: price windows, source delays, broken and malformed sources, low gas limits, crew names, staking and perks. Fuzz tests check that the weight matches the published formula exactly and that every pot splits into the winners' 90% and the house 10%.

## Before deploying

- **Pick each tower's price pool.** The stocks trade on different DEXes: some on Aerodrome Slipstream against USDG, AAPL on Uniswap v3 against WETH, TSLA on Metric. Each tower needs a pool this oracle can read, ideally priced in dollars, with enough observations kept for a 30-minute average.
- **Run the 20:00 UTC keeper.** It records the prices and closes the round, and needs a wallet with gas.
- **Set the $TALL thresholds** once the token is live.
- **Choose the owner and treasury addresses.**
- **Get a review or audit before real ETH.**
