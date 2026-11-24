// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TallStreet} from "../src/TallStreet.sol";
import {TallStaking} from "../src/TallStaking.sol";
import {ITallStaking} from "../src/interfaces/ITallStaking.sol";
import {MockTall} from "../test/mocks/Mocks.sol";

/// @notice $TALL for the local street: a stand-in token, its staking contract, the perks switched on, and tokens for
///         the website's local test wallet. Runs after Local.s.sol, on the local chain only.
/// @dev GAME=0x.. forge script script/LocalTall.s.sol --rpc-url http://127.0.0.1:8545 --broadcast
contract LocalTall is Script {
    /// @notice Anvil's default test mnemonic: public, and only ever funded on a local chain.
    string internal constant MNEMONIC = "test test test test test test test test test test test junk";

    function run() external returns (MockTall tall, TallStaking staking) {
        require(block.chainid == 31337, "local chain only");
        TallStreet game = TallStreet(vm.envAddress("GAME"));
        uint256 owner = vm.deriveKey(MNEMONIC, 0);
        // the website's local test wallet is Anvil account 9
        address player = vm.addr(vm.deriveKey(MNEMONIC, 9));

        vm.startBroadcast(owner);
        tall = new MockTall();
        staking = new TallStaking(IERC20(address(tall)));
        game.setTall(IERC20(address(tall)), ITallStaking(address(staking)));
        // a holder from 1M $TALL, the full 20% off from 10M staked
        game.setPerks(1_000_000 ether, 10_000_000 ether);
        tall.mint(player, 25_000_000 ether);
        vm.stopBroadcast();

        console.log("TALL", address(tall));
        console.log("STAKING", address(staking));
    }
}
