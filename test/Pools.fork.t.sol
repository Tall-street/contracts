// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Deploy} from "../script/Deploy.s.sol";
import {V3TwapPrice, IV3PoolOracle} from "../src/prices/V3TwapPrice.sol";

/// @notice Reads every tower's price from the live chain, with the deploy script's pools. Skipped unless
///         ROBINHOOD_RPC_URL is set:
///         ROBINHOOD_RPC_URL=https://robinhood.drpc.org forge test --match-contract PoolsFork
contract PoolsForkTest is Test {
    function test_EveryTowerReadsADollarPrice() public {
        string memory url = vm.envOr("ROBINHOOD_RPC_URL", string(""));
        vm.skip(bytes(url).length == 0, "set ROBINHOOD_RPC_URL to read the live pools");
        vm.createSelectFork(url);

        Deploy d = new Deploy();
        Deploy.Tower[8] memory t = d.towers();
        for (uint256 i; i < t.length; ++i) {
            V3TwapPrice src = new V3TwapPrice(IV3PoolOracle(t[i].pool), d.stockIsToken0(t[i]), d.WINDOW());
            // USDG has 6 decimals and the stocks 18, so $1 reads as 1e6
            uint256 p = src.priceAt(block.timestamp);
            assertGt(p, 10e6, t[i].ticker);
            assertLt(p, 5_000e6, t[i].ticker);
            // a recording can come up to two hours late, so the pool must reach back 2.5 hours
            try src.priceAt(block.timestamp - 2 hours) returns (uint256 late) {
                assertGt(late, 0, t[i].ticker);
            } catch {
                fail(string.concat(t[i].ticker, ": not enough price history for a recording two hours late"));
            }
        }
    }
}
