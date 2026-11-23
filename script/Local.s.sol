// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {TallStreet} from "../src/TallStreet.sol";
import {IPriceSource} from "../src/interfaces/IPriceSource.sol";
import {LivePriceSource} from "../test/mocks/Mocks.sol";

/// @notice A local street to build the website against: the game on Anvil with stand-in prices, three rival crews
///         and some floors already placed. It signs with Anvil's public test accounts and refuses any other chain.
/// @dev anvil --block-time 2 --timestamp <a 20:00 UTC boundary, plus a few seconds>
///      forge script script/Local.s.sol --rpc-url http://127.0.0.1:8545 --broadcast
contract Local is Script {
    /// @notice Anvil's default test mnemonic: public, and only ever funded on a local chain.
    string internal constant MNEMONIC = "test test test test test test test test test test test junk";

    function run() external returns (TallStreet game) {
        require(block.chainid == 31337, "local chain only");
        // dollar prices in USDG units (6 decimals), the way the real pools read
        uint256[8] memory prices = [uint256(165e6), 136e6, 388e6, 349e6, 259e6, 499e6, 457e6, 725e6];

        uint256 deployer = vm.deriveKey(MNEMONIC, 0);
        vm.startBroadcast(deployer);
        IPriceSource[8] memory sources;
        for (uint256 i; i < 8; ++i) {
            sources[i] = new LivePriceSource(prices[i]);
        }
        game = new TallStreet(vm.addr(deployer), vm.addr(vm.deriveKey(MNEMONIC, 1)), sources);
        // the round's opening prices, while the chain is still inside the recording window
        uint256 boundary = game.openAt(game.currentRound());
        if (block.timestamp <= boundary + game.SNAPSHOT_WINDOW()) game.recordPrices(boundary);
        vm.stopBroadcast();

        // three rival crews founded by test accounts 2 to 4, and a fourth account that joins the first
        uint256 ember = _found(game, 2, "Ember", 1, 2);
        uint256 verdigris = _found(game, 3, "Verdigris", 2, 0);
        uint256 graphite = _found(game, 4, "Graphite", 3, 3);
        _place(game, 2, 0, ember, 6);
        _place(game, 2, 3, ember, 3);
        _place(game, 3, 2, verdigris, 4);
        _place(game, 3, 7, verdigris, 7);
        _place(game, 4, 5, graphite, 5);
        _place(game, 4, 0, graphite, 2);
        _place(game, 5, 4, ember, 2);

        console.log("TALLSTREET", address(game));
        for (uint256 i; i < 8; ++i) {
            console.log("SOURCE", i, address(sources[i]));
        }
    }

    function _found(TallStreet game, uint32 account, string memory name, uint8 color, uint8 emblem)
        internal
        returns (uint256 id)
    {
        vm.broadcast(vm.deriveKey(MNEMONIC, account));
        id = game.foundCrew(name, color, emblem);
    }

    function _place(TallStreet game, uint32 account, uint256 tower, uint256 crewId, uint256 floors) internal {
        uint256 key = vm.deriveKey(MNEMONIC, account);
        uint256 cost = game.floorPrice(vm.addr(key)) * floors;
        vm.broadcast(key);
        game.placeFloors{value: cost}(tower, crewId, floors);
    }
}
