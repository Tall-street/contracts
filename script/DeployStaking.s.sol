// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {TallStreet} from "../src/TallStreet.sol";
import {TallStaking} from "../src/TallStaking.sol";
import {ITallStaking} from "../src/interfaces/ITallStaking.sol";

/// @notice Launch day, from the owner's wallet: deploys TallStaking for $TALL, hands both to the game (once, it can't
///         be changed) and sets the perk amounts. Amounts are given in whole tokens.
/// @dev TALL=0x.. HOLDER=<whole $TALL> FULL=<whole $TALL> forge script script/DeployStaking.s.sol \
///        --rpc-url <robinhood rpc> --sender <owner> --interactives 1 --broadcast --slow
contract DeployStaking is Script {
    /// @notice The game on Robinhood Chain, deployed 24 November 2026.
    TallStreet internal constant GAME = TallStreet(0xD96cb122028adBbe5e85C255598E66D2B9ab5999);

    function run() external returns (TallStaking staking) {
        require(block.chainid == 4663, "Robinhood Chain only");
        IERC20Metadata tall = IERC20Metadata(vm.envAddress("TALL"));
        // setTall works once, so check the address really is $TALL before it is spent
        require(keccak256(bytes(tall.symbol())) == keccak256("TALL"), "the token's symbol isn't TALL");
        require(tall.totalSupply() > 0, "the token has no supply");
        require(address(GAME.tall()) == address(0), "$TALL is already set on the game");

        uint256 unit = 10 ** tall.decimals();
        uint256 holder = vm.envUint("HOLDER") * unit;
        uint256 full = vm.envUint("FULL") * unit;
        require(holder > 0 && full > 0, "set HOLDER and FULL");

        vm.startBroadcast();
        staking = new TallStaking(IERC20(address(tall)));
        GAME.setTall(IERC20(address(tall)), ITallStaking(address(staking)));
        GAME.setPerks(holder, full);
        vm.stopBroadcast();

        console.log("STAKING", address(staking));
    }
}
