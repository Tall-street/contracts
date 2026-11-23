// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {IPriceSource} from "../interfaces/IPriceSource.sol";
import {TickPrice} from "../libraries/TickPrice.sol";

/// @notice The oracle part of a Uniswap v3 style pool. Aerodrome Slipstream pools expose the same call.
interface IV3PoolOracle {
    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s);
}

/// @notice A stock's price as the time-weighted average over `window` seconds ending at the requested moment,
///         read from a concentrated-liquidity pool. A short spike inside one block can't move it much.
/// @dev The pool must keep enough observations to reach back to `timestamp - window`; ask for more with the pool's
///      increaseObservationCardinalityNext. If it can't, `observe` reverts and the game records no price.
contract V3TwapPrice is IPriceSource {
    IV3PoolOracle public immutable pool;
    /// @notice True when the stock token is the pool's token0, so the tick prices the stock in the other token.
    bool public immutable stockIsToken0;
    uint32 public immutable window;

    error ZeroWindow();

    constructor(IV3PoolOracle pool_, bool stockIsToken0_, uint32 window_) {
        if (window_ == 0) revert ZeroWindow();
        pool = pool_;
        stockIsToken0 = stockIsToken0_;
        window = window_;
    }

    /// @inheritdoc IPriceSource
    function priceAt(uint256 timestamp) external view returns (uint256) {
        if (timestamp > block.timestamp) return 0;
        uint256 endAgo = block.timestamp - timestamp;
        if (endAgo + window > type(uint32).max) return 0;

        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = uint32(endAgo + window);
        secondsAgos[1] = uint32(endAgo);
        (int56[] memory cumulatives,) = pool.observe(secondsAgos);

        int56 delta = cumulatives[1] - cumulatives[0];
        int56 span = int56(uint56(window));
        int56 tick = delta / span;
        // round toward negative infinity, as the pool's own oracle library does
        if (delta < 0 && delta % span != 0) tick--;
        return TickPrice.price(stockIsToken0 ? int256(tick) : -int256(tick));
    }
}
