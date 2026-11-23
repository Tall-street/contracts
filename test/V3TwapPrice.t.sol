// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {V3TwapPrice, IV3PoolOracle} from "../src/prices/V3TwapPrice.sol";
import {TickPrice} from "../src/libraries/TickPrice.sol";
import {MockV3Pool} from "./mocks/Mocks.sol";

contract TickPriceHarness {
    function price(int256 tick) external pure returns (uint256) {
        return TickPrice.price(tick);
    }
}

contract V3TwapPriceTest is Test {
    MockV3Pool internal pool;
    TickPriceHarness internal tp;
    uint256 internal constant T = 1_795_464_000;

    function setUp() public {
        pool = new MockV3Pool();
        tp = new TickPriceHarness();
        vm.warp(T + 10 minutes);
    }

    function test_TickPrice() public view {
        assertEq(tp.price(0), 1e18);
        assertEq(tp.price(1), 1.0001e18);
        // 1.0001^100 = 1.010049662092876...
        assertApproxEqRel(tp.price(100), 1.010049662092876e18, 1e6);
        assertApproxEqRel(tp.price(-100), 0.990050328741209e18, 1e6); // 1 / 1.0001^100
        // an 18-decimal stock at $180 priced in a 6-decimal dollar sits near tick -224,000
        assertGt(tp.price(-224_000), 0);
        assertGt(tp.price(887_272), 0);
    }

    function test_ConstantTickGivesItsPrice() public {
        pool.setTicks(100, 100, 0, 0);
        V3TwapPrice src = new V3TwapPrice(IV3PoolOracle(address(pool)), true, 30 minutes);
        assertEq(src.priceAt(T), tp.price(100));
        V3TwapPrice flipped = new V3TwapPrice(IV3PoolOracle(address(pool)), false, 30 minutes);
        assertEq(flipped.priceAt(T), tp.price(-100), "stock as token1 inverts the price");
    }

    function test_AverageRoundsTowardNegativeInfinity() public {
        // tick -1 for the first half of the window, 0 for the second: average -0.5 rounds to -1
        pool.setTicks(-1, 0, T - 15 minutes, 0);
        V3TwapPrice src = new V3TwapPrice(IV3PoolOracle(address(pool)), true, 30 minutes);
        assertEq(src.priceAt(T), tp.price(-1));
    }

    function test_TheWindowEndsAtTheRequestedMoment() public {
        // the tick jumps after T: the reading at T must not see it
        pool.setTicks(50, 5_000, T, 0);
        V3TwapPrice src = new V3TwapPrice(IV3PoolOracle(address(pool)), true, 30 minutes);
        assertEq(src.priceAt(T), tp.price(50));
    }

    function test_NoFutureAndNoTooOldReadings() public {
        pool.setTicks(10, 10, 0, T);
        V3TwapPrice src = new V3TwapPrice(IV3PoolOracle(address(pool)), true, 30 minutes);
        assertEq(src.priceAt(block.timestamp + 1), 0);
        vm.expectRevert(bytes("OLD"));
        src.priceAt(T);
    }
}
