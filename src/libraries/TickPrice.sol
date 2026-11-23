// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice 1.0001^tick in 18-decimal fixed point, the price a concentrated-liquidity pool encodes in a tick.
library TickPrice {
    uint256 internal constant ONE = 1e18;
    uint256 internal constant BASE = 1.0001e18;
    int256 internal constant MAX_TICK = 887_272;

    error TickOutOfRange();

    /// @dev Exponentiation by squaring with 512-bit intermediate products, so nothing overflows across the full tick range.
    function price(int256 tick) internal pure returns (uint256) {
        if (tick > MAX_TICK || tick < -MAX_TICK) revert TickOutOfRange();
        uint256 n = tick < 0 ? uint256(-tick) : uint256(tick);
        uint256 result = ONE;
        uint256 base = BASE;
        while (n > 0) {
            if (n & 1 == 1) result = Math.mulDiv(result, base, ONE);
            n >>= 1;
            if (n > 0) base = Math.mulDiv(base, base, ONE);
        }
        return tick < 0 ? Math.mulDiv(ONE, ONE, result) : result;
    }
}
