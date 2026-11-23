// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {TallStreet} from "../src/TallStreet.sol";
import {TallStaking} from "../src/TallStaking.sol";
import {IPriceSource} from "../src/interfaces/IPriceSource.sol";
import {MockPriceSource, MockTall, OddPriceSource} from "./mocks/Mocks.sol";

/// @notice The same cases as github.com/Tall-street/rules, run against the contract, plus the on-chain parts.
contract TallStreetTest is Test {
    TallStreet internal game;
    MockPriceSource[8] internal src;

    address internal owner = makeAddr("owner");
    address internal treasury = makeAddr("treasury");
    address internal a = makeAddr("a");
    address internal a2 = makeAddr("a2");
    address internal b = makeAddr("b");
    address internal c = makeAddr("c");

    /// @dev 23 November 2026, 20:00 UTC.
    uint256 internal constant OPEN = 1_795_464_000;
    uint256 internal constant H = 1 hours;
    uint256 internal R;
    uint256 internal ember;
    uint256 internal verdigris;
    uint256 internal graphite;

    function setUp() public {
        IPriceSource[8] memory s;
        for (uint256 i; i < 8; ++i) {
            src[i] = new MockPriceSource();
            s[i] = src[i];
        }
        game = new TallStreet(owner, treasury, s);
        vm.warp(OPEN);
        R = game.currentRound();
        vm.prank(a);
        ember = game.foundCrew("Ember", 1, 0);
        vm.prank(b);
        verdigris = game.foundCrew("Verdigris", 2, 1);
        vm.prank(c);
        graphite = game.foundCrew("Graphite", 3, 2);
        for (uint256 i; i < 4; ++i) {
            vm.deal([a, a2, b, c][i], 100 ether);
        }
    }

    function _place(address who, uint256 tower, uint256 crewId, uint256 floors) internal {
        uint256 cost = game.floorPrice(who) * floors;
        vm.prank(who);
        game.placeFloors{value: cost}(tower, crewId, floors);
    }

    // ---------------------------------------------------------------- the published rules

    function test_PublishedNumbers() public view {
        assertEq(game.FLOOR_PRICE(), 0.001 ether);
        assertEq(game.FINAL_FLOOR_PRICE(), 0.002 ether);
        assertEq(game.OPEN_OFFSET(), 20 hours);
        assertEq(game.ROUND(), 24 hours);
        assertEq(game.FINAL_HOUR(), 1 hours);
        assertEq(game.TOWER_COUNT(), 8);
        assertEq(game.WEIGHT_FACTOR(), 10);
        assertEq(game.WEIGHT_MIN(), 5_000);
        assertEq(game.WEIGHT_MAX(), 15_000);
        assertEq(game.WINNER_SHARE(), 9_000);
        assertEq(game.MAX_FLOORS_PER_TX(), 20);
        assertEq(OPEN % 1 days, 20 hours, "the test clock starts at 20:00 UTC");
    }

    function test_RoundRunsFrom20To20() public {
        assertEq(game.openAt(R), OPEN);
        assertEq(game.closeAt(R), OPEN + 24 * H);
        vm.warp(OPEN - 1);
        assertEq(game.currentRound(), R - 1);
        vm.warp(OPEN + 24 * H - 1);
        assertEq(game.currentRound(), R);
        vm.warp(OPEN + 24 * H);
        assertEq(game.currentRound(), R + 1);
    }

    function test_FinalHourCostsDoubleWhenTheTransactionLands() public {
        vm.warp(OPEN + 23 * H - 1);
        assertEq(game.floorPrice(a), 0.001 ether);
        vm.warp(OPEN + 23 * H);
        assertEq(game.floorPrice(a), 0.002 ether);
        vm.prank(a);
        vm.expectRevert(abi.encodeWithSelector(TallStreet.WrongPayment.selector, 0.006 ether));
        game.placeFloors{value: 0.003 ether}(0, ember, 3);
        _place(a, 0, ember, 3);
        assertEq(game.roundData(R).pot, 0.006 ether);
    }

    function test_RefusedPlacementsCostNothing() public {
        vm.startPrank(a);
        vm.expectRevert(TallStreet.BadTower.selector);
        game.placeFloors{value: 0.001 ether}(8, ember, 1);
        vm.expectRevert(TallStreet.BadCrew.selector);
        game.placeFloors{value: 0.001 ether}(0, 0, 1);
        vm.expectRevert(TallStreet.BadCrew.selector);
        game.placeFloors{value: 0.001 ether}(0, 99, 1);
        vm.expectRevert(TallStreet.BadFloors.selector);
        game.placeFloors{value: 0}(0, ember, 0);
        vm.expectRevert(abi.encodeWithSelector(TallStreet.TooManyFloors.selector, 20));
        game.placeFloors{value: 0.021 ether}(0, ember, 21);
        game.placeFloors{value: 0.001 ether}(0, ember, 1);
        vm.expectRevert(abi.encodeWithSelector(TallStreet.OtherCrew.selector, ember));
        game.placeFloors{value: 0.001 ether}(0, verdigris, 1);
        vm.stopPrank();
        vm.prank(owner);
        game.setPaused(true);
        vm.prank(b);
        vm.expectRevert(TallStreet.Paused.selector);
        game.placeFloors{value: 0.001 ether}(0, verdigris, 1);
        assertEq(game.roundData(R).pot, 0.001 ether, "only the accepted floor was paid for");
    }

    function test_OneTransactionPlacesAtMost20Floors() public {
        _place(a, 0, ember, 20);
        assertEq(game.towerAt(R, 0).floors, 20);
    }

    function test_MostFloorsHoldsAndADrawStaysWithWhoeverGotThereFirst() public {
        _place(a, 2, ember, 5);
        assertEq(game.towerAt(R, 2).holder, ember);
        _place(b, 2, verdigris, 5);
        assertEq(game.towerAt(R, 2).holder, ember, "drawing level does not take the tower");
        assertEq(game.floorsToTake(R, 2, verdigris), 1);
        vm.warp(OPEN + 3);
        _place(b, 2, verdigris, 1);
        assertEq(game.towerAt(R, 2).holder, verdigris);
        assertEq(game.towerAt(R, 2).heldSince, OPEN + 3);
        _place(a, 2, ember, 1);
        assertEq(game.towerAt(R, 2).holder, verdigris, "the old holder only draws level");
        assertEq(game.floorsToTake(R, 2, graphite), 7);
        assertEq(game.floorsToTake(R, 5, graphite), 1, "an empty tower takes one floor");
        assertEq(game.floorsToTake(R, 2, verdigris), 0);
    }

    function test_WeightFollowsTheStockBetweenHalfAndOneAndAHalf() public view {
        assertEq(game.weightBps(100, 103), 13_000);
        assertEq(game.weightBps(100, 98), 8_000);
        assertEq(game.weightBps(100, 112), 15_000);
        assertEq(game.weightBps(100, 80), 5_000);
        assertEq(game.weightBps(1_000_000, 1_000_049), 10_000, "moves under a basis point don't count");
        assertEq(game.weightBps(0.3e18, 0.309e18), 13_000);
        assertEq(game.weightBps(0, 5), 10_000, "a missing price counts as 1.00");
        assertEq(game.weightBps(5, 0), 10_000);
        assertEq(game.weightBps(10_000, 9_997), 9_970, "falls are cut toward zero too");
        assertEq(game.weightBps(1_000_000, 999_951), 10_000);
        assertEq(game.weightBps(1, type(uint256).max), 15_000, "any two readings work without overflowing");
        assertEq(game.weightBps(type(uint256).max, 1), 5_000);
    }

    function test_StreetValueCountsEveryFloorOnHeldTowers() public {
        // weights 1.20 on tower 0 and 0.90 on tower 6
        src[0].set(OPEN, 100);
        src[0].set(OPEN + 24 * H, 102);
        src[6].set(OPEN, 100);
        src[6].set(OPEN + 24 * H, 99);
        game.recordPrices(OPEN);
        _place(a, 0, ember, 20);
        _place(a, 0, ember, 10);
        _place(b, 0, verdigris, 10);
        _place(a, 6, ember, 20);
        _place(a, 6, ember, 5);
        vm.warp(OPEN + 24 * H);
        game.settle(R);
        // the docs example: 40 floors × 1.20 + 25 floors × 0.90 = 70.5
        assertEq(game.streetValue(R, ember), 705_000);
        assertEq(game.streetValue(R, verdigris), 0);
        assertEq(game.roundData(R).winner, ember);
    }

    function test_ATieGoesToMoreFloorsThenToTheCrewFoundedFirst() public {
        _place(b, 0, verdigris, 10);
        _place(c, 1, graphite, 8);
        _place(b, 1, verdigris, 2);
        vm.warp(OPEN + 24 * H);
        game.settle(R);
        assertEq(game.streetValue(R, verdigris), 100_000);
        assertEq(game.streetValue(R, graphite), 100_000);
        assertEq(game.roundData(R).winner, verdigris, "12 floors placed beat 8");

        _place(c, 1, graphite, 5);
        _place(b, 0, verdigris, 5);
        vm.warp(OPEN + 48 * H);
        game.settle(R + 1);
        assertEq(game.roundData(R + 1).winner, verdigris, "Verdigris was founded before Graphite");

        vm.warp(OPEN + 72 * H);
        game.settle(R + 2);
        assertEq(game.roundData(R + 2).winner, 0, "no floors, no winner");
    }

    function test_WinnersSplit90PercentByFloorsAndTallStreetKeeps10() public {
        _place(a, 0, ember, 20);
        _place(a, 0, ember, 10);
        _place(a2, 3, ember, 10);
        _place(b, 0, verdigris, 20);
        vm.warp(OPEN + 23 * H);
        _place(b, 5, verdigris, 5);
        assertEq(game.roundData(R).pot, 0.07 ether, "60 floors at 0.001 and 5 at 0.002");

        vm.warp(OPEN + 24 * H);
        game.settle(R);
        assertEq(game.roundData(R).winner, ember);
        assertEq(game.claimable(R, a), 0.04725 ether);
        assertEq(game.claimable(R, a2), 0.01575 ether);
        assertEq(game.claimable(R, b), 0);
        assertEq(game.houseBalance(), 0.007 ether);

        uint256 before = a.balance;
        vm.prank(a);
        game.claim(R);
        assertEq(a.balance - before, 0.04725 ether);
        vm.prank(a);
        vm.expectRevert(TallStreet.NothingToClaim.selector);
        game.claim(R);
        vm.prank(b);
        vm.expectRevert(TallStreet.NothingToClaim.selector);
        game.claim(R);

        game.withdrawHouse();
        assertEq(treasury.balance, 0.007 ether);
        vm.prank(a2);
        game.claim(R);
        assertEq(address(game).balance, 0, "everything paid out, no rounding left in this case");
    }

    // ---------------------------------------------------------------- closing a round

    function test_ClosingNeedsTheCloseAndHappensOnce() public {
        vm.expectRevert(TallStreet.RoundNotClosed.selector);
        game.settle(R);
        vm.warp(OPEN + 24 * H);
        game.settle(R);
        assertTrue(game.snapped(OPEN + 24 * H), "closing records the closing prices");
        vm.expectRevert(TallStreet.AlreadySettled.selector);
        game.settle(R);
    }

    function test_PricesAreRecordedOnlyAtABoundaryInsideItsWindow() public {
        vm.expectRevert(TallStreet.NotABoundary.selector);
        game.recordPrices(OPEN + 1);
        vm.expectRevert(TallStreet.TooEarly.selector);
        game.recordPrices(OPEN + 24 * H);
        game.recordPrices(OPEN);
        vm.expectRevert(TallStreet.AlreadyRecorded.selector);
        game.recordPrices(OPEN);
        vm.warp(OPEN + 24 * H + 2 * H + 1);
        vm.expectRevert(TallStreet.TooLate.selector);
        game.recordPrices(OPEN + 24 * H);
    }

    function test_ALateCloseUsesWeightOne() public {
        src[0].set(OPEN, 100);
        src[0].set(OPEN + 24 * H, 150);
        game.recordPrices(OPEN);
        _place(a, 0, ember, 10);
        vm.warp(OPEN + 30 * H);
        game.settle(R);
        assertFalse(game.snapped(OPEN + 24 * H));
        assertEq(game.weights(R)[0], 10_000);
        assertEq(game.streetValue(R, ember), 100_000);
    }

    function test_ABrokenSourceRecordsNoPrice() public {
        src[1].set(OPEN, 77);
        src[2].breakIt();
        game.recordPrices(OPEN);
        uint256[8] memory p = game.pricesAt(OPEN);
        assertEq(p[1], 77);
        assertEq(p[2], 0);
    }

    /// @dev Swaps in sources for some towers; they apply two days later, at the 20:00 UTC that opens round R + 2.
    function _swapSources(uint256[] memory towers, address[] memory next) internal returns (uint256 open) {
        vm.startPrank(owner);
        for (uint256 i; i < towers.length; ++i) {
            game.proposeSource(towers[i], IPriceSource(next[i]));
        }
        vm.stopPrank();
        open = OPEN + 2 days;
        vm.warp(open);
        for (uint256 i; i < towers.length; ++i) {
            game.applySource(towers[i]);
        }
    }

    function test_AnOddSourceCountsAsNoPriceAndCantStopTheClose() public {
        OddPriceSource short = new OddPriceSource();
        OddPriceSource absurd = new OddPriceSource();
        uint256[] memory towers = new uint256[](3);
        address[] memory next = new address[](3);
        (towers[0], next[0]) = (1, makeAddr("not a contract"));
        (towers[1], next[1]) = (2, address(short));
        (towers[2], next[2]) = (3, address(absurd));
        uint256 open = _swapSources(towers, next);

        src[0].set(open, 100);
        absurd.setMode(1, 1);
        game.recordPrices(open);
        uint256[8] memory p = game.pricesAt(open);
        assertEq(p[0], 100);
        assertEq(p[1], 0, "no code, no price");
        assertEq(p[2], 0, "a 16-byte answer is no price");
        assertEq(p[3], 1);

        uint256 r = game.currentRound();
        _place(a, 3, ember, 2);
        _place(b, 0, verdigris, 2);
        absurd.setMode(1, type(uint256).max);
        vm.warp(open + 24 * H);
        game.settle(r);
        assertEq(game.weights(r)[3], 15_000, "an absurd close is capped at 1.50");
        assertEq(game.roundData(r).winner, ember);
    }

    function test_ALowGasLimitCantBlankAPrice() public {
        OddPriceSource heavy = new OddPriceSource();
        uint256[] memory towers = new uint256[](1);
        address[] memory next = new address[](1);
        (towers[0], next[0]) = (7, address(heavy));
        uint256 open = _swapSources(towers, next);
        heavy.setMode(2, 7);
        for (uint256 i; i < 7; ++i) {
            src[i].set(open, 100 + i);
        }
        // whoever records picks the gas limit: a recording either fails as a whole or reads every source in full
        bool recorded;
        for (uint256 g = 50_000; g < 2_000_000 && !recorded; g += 4_999) {
            (recorded,) = address(game).call{gas: g}(abi.encodeCall(TallStreet.recordPrices, (open)));
        }
        assertTrue(recorded);
        uint256[8] memory p = game.pricesAt(open);
        for (uint256 i; i < 7; ++i) {
            assertEq(p[i], 100 + i);
        }
        assertEq(p[7], 7, "the heavy source got its whole allowance");
    }

    function test_ANewSourceWaitsTwoDays() public {
        MockPriceSource next = new MockPriceSource();
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, a));
        vm.prank(a);
        game.proposeSource(3, next);
        vm.prank(owner);
        game.proposeSource(3, next);
        vm.expectRevert(TallStreet.TooEarly.selector);
        game.applySource(3);
        vm.warp(block.timestamp + 2 days);
        game.applySource(3);
        assertEq(address(game.sources(3)), address(next));
        vm.expectRevert(TallStreet.NoPendingSource.selector);
        game.applySource(3);
    }

    // ---------------------------------------------------------------- crews

    function test_CrewNames() public {
        string[6] memory bad = ["A", "Nineteen characters", " Ember", "Em  ber", "Ember ", "Ember!"];
        for (uint256 i; i < bad.length; ++i) {
            vm.expectRevert(TallStreet.BadName.selector);
            game.foundCrew(bad[i], 0, 0);
        }
        vm.expectRevert(TallStreet.NameTaken.selector);
        game.foundCrew("eMBER", 0, 0);
        vm.expectRevert(TallStreet.BadStyle.selector);
        game.foundCrew("Night Shift", 8, 0);
        uint256 id = game.foundCrew("Night Shift", 0, 5);
        assertEq(id, 4);
        assertEq(game.crew(id).name, "Night Shift");
        assertEq(game.crewIdByName(keccak256("night shift")), id);
    }

    // ---------------------------------------------------------------- $TALL perks

    function _withTall() internal returns (MockTall tall, TallStaking staking) {
        tall = new MockTall();
        staking = new TallStaking(tall);
        vm.startPrank(owner);
        game.setTall(tall, staking);
        game.setPerks(1_000e18, 5_000e18);
        vm.stopPrank();
    }

    function test_HoldingTallFoundsCrewsAndPlaces100AtOnce() public {
        (MockTall tall,) = _withTall();
        address d = makeAddr("d");
        vm.deal(d, 1 ether);
        vm.prank(d);
        vm.expectRevert(TallStreet.NotAllowedToFound.selector);
        game.foundCrew("Saffron", 5, 4);
        tall.mint(d, 1_000e18);
        vm.prank(d);
        uint256 saffron = game.foundCrew("Saffron", 5, 4);
        assertEq(game.maxFloorsPerTx(d), 100);
        _place(d, 4, saffron, 100);
        assertEq(game.towerAt(R, 4).floors, 100);
        vm.prank(a);
        vm.expectRevert(abi.encodeWithSelector(TallStreet.TooManyFloors.selector, 20));
        game.placeFloors{value: 0.021 ether}(4, ember, 21);
        vm.prank(owner);
        vm.expectRevert(TallStreet.AlreadySet.selector);
        game.setTall(tall, TallStaking(address(0)));
    }

    function test_StakingGivesUpTo20PercentOffAndUnstakingCoolsDown() public {
        (MockTall tall, TallStaking staking) = _withTall();
        tall.mint(a, 10_000e18);
        vm.startPrank(a);
        tall.approve(address(staking), type(uint256).max);
        staking.stake(2_500e18);
        assertEq(game.discountBps(a), 1_000);
        assertEq(game.floorPrice(a), 0.0009 ether);
        staking.stake(5_000e18);
        assertEq(game.discountBps(a), 2_000, "capped at 20%");
        assertEq(game.floorPrice(a), 0.0008 ether);
        game.placeFloors{value: 0.016 ether}(0, ember, 20);

        staking.requestUnstake(7_500e18);
        assertEq(staking.stakedOf(a), 0, "leaving stake stops counting at once");
        assertEq(game.discountBps(a), 0);
        vm.expectRevert(abi.encodeWithSelector(TallStaking.StillCooling.selector, block.timestamp + 3 days));
        staking.withdraw();
        vm.warp(block.timestamp + 3 days);
        staking.withdraw();
        assertEq(tall.balanceOf(a), 10_000e18);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- invariants under random play

    /// @dev The overflow-proof weight gives exactly the published formula, int maths cut toward zero.
    function testFuzz_WeightIsThePublishedFormula(uint128 open, uint128 close) public view {
        vm.assume(open > 0 && close > 0);
        int256 move = ((int256(uint256(close)) - int256(uint256(open))) * 10_000) / int256(uint256(open));
        int256 w = 10_000 + 10 * move;
        if (w < 5_000) w = 5_000;
        if (w > 15_000) w = 15_000;
        assertEq(game.weightBps(open, close), uint256(w));
    }

    function testFuzz_PotSplitsCleanly(uint256 seed) public {
        address[3] memory who = [a, b, c];
        uint256[3] memory crewOf = [ember, verdigris, graphite];
        uint256 paid;
        for (uint256 k; k < 40; ++k) {
            seed = uint256(keccak256(abi.encode(seed, k)));
            uint256 p = seed % 3;
            uint256 t = (seed >> 8) % 8;
            uint256 n = 1 + (seed >> 16) % 20;
            vm.warp(OPEN + ((seed >> 32) % (24 * H - 1)));
            if (game.currentRound() != R) continue;
            uint256 cost = game.floorPrice(who[p]) * n;
            vm.prank(who[p]);
            game.placeFloors{value: cost}(t, crewOf[p], n);
            paid += cost;
        }
        for (uint256 t; t < 8; ++t) {
            uint256 h = game.towerAt(R, t).holder;
            for (uint256 j; j < 3; ++j) {
                if (h != 0) assertGe(game.crewFloorsOn(R, t, h), game.crewFloorsOn(R, t, crewOf[j]));
            }
        }
        TallStreet.RoundData memory rd = game.roundData(R);
        assertEq(rd.pot, paid);
        vm.warp(OPEN + 24 * H);
        game.settle(R);
        rd = game.roundData(R);
        assertEq(uint256(rd.winnersShare) + game.houseBalance(), rd.pot);
        uint256 claims;
        for (uint256 j; j < 3; ++j) {
            claims += game.claimable(R, who[j]);
        }
        assertLe(claims, rd.winnersShare);
        if (rd.pot > 0) assertGt(claims, 0);
    }
}
