// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {TallStreet} from "../src/TallStreet.sol";
import {IPriceSource} from "../src/interfaces/IPriceSource.sol";
import {V3TwapPrice, IV3PoolOracle} from "../src/prices/V3TwapPrice.sol";

interface IPoolTokens {
    function token0() external view returns (address);
    function token1() external view returns (address);
}

/// @notice Deploys the game with one 30-minute average price source per tower, in the website's tower order.
///         Every pool pairs its stock with USDG. Which side of the pool the stock sits on is read on-chain, so it
///         can't be set wrong by hand.
/// @dev OWNER=0x.. TREASURY=0x.. forge script script/Deploy.s.sol --rpc-url <robinhood rpc> --broadcast, with the
///      deployer's key given at deploy time. No key is stored here.
contract Deploy is Script {
    uint32 public constant WINDOW = 30 minutes;
    /// @notice USDG on Robinhood Chain: every tower is priced in it.
    address public constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;

    struct Tower {
        string ticker;
        address stock;
        address pool;
    }

    /// @notice The eight towers. Index i here is tower i in the game and on the website.
    /// @dev Uniswap v3 pools, and Aerodrome Slipstream for SPY; checked on-chain 24 November 2026.
    function towers() public pure returns (Tower[8] memory t) {
        t[0] = Tower("NVDA", 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC, 0xd4EB21209C4D6093f80B5b84f5C45cc093EA14a3);
        t[1] = Tower("SPCX", 0x4a0E65A3EcceC6dBe60AE065F2e7bb85Fae35eEa, 0xc61284332117c3FB23A2A56cceFFD07F7aF60029);
        t[2] = Tower("TSLA", 0x322F0929c4625eD5bAd873c95208D54E1c003b2d, 0xf4ACdAEEB7022862A763C9B1B885e11191c889E3);
        t[3] = Tower("AAPL", 0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9, 0xAae0d815EE56e4092a5E5C2911E676Fea50B2d6D);
        t[4] = Tower("AMZN", 0x12f190a9F9d7D37a250758b26824B97CE941bF54, 0x8AC92DA74AB5F3b1d024Dc1943Ad7e15Dc4179Ef);
        t[5] = Tower("MSFT", 0xe93237C50D904957Cf27E7B1133b510C669c2e74, 0xeb60bCD1D920ad6E102690CCFC6fB488899E1510);
        t[6] = Tower("AMD", 0x86923f96303D656E4aa86D9d42D1e57ad2023fdC, 0x48D284A2A4d3DC1b3Da08231Fe44317e7e7Aa51f);
        t[7] = Tower("SPY", 0x117cc2133c37B721F49dE2A7a74833232B3B4C0C, 0x4A9b7cCBa4a3CD9Ee604AfA95d3DfA77D0d593e5);
    }

    /// @notice Whether a tower's stock is its pool's token0. Reverts unless the pool pairs the stock with USDG.
    function stockIsToken0(Tower memory t) public view returns (bool) {
        address a = IPoolTokens(t.pool).token0();
        address b = IPoolTokens(t.pool).token1();
        if (a == t.stock && b == USDG) return true;
        if (a == USDG && b == t.stock) return false;
        revert(string.concat(t.ticker, ": the pool doesn't pair the stock with USDG"));
    }

    function run() external returns (TallStreet game) {
        address owner = vm.envAddress("OWNER");
        address treasury = vm.envAddress("TREASURY");
        Tower[8] memory t = towers();
        bool[8] memory token0;
        for (uint256 i; i < t.length; ++i) {
            token0[i] = stockIsToken0(t[i]);
        }

        vm.startBroadcast();
        IPriceSource[8] memory sources;
        for (uint256 i; i < t.length; ++i) {
            sources[i] = new V3TwapPrice(IV3PoolOracle(t[i].pool), token0[i], WINDOW);
        }
        game = new TallStreet(owner, treasury, sources);
        vm.stopBroadcast();
    }
}
