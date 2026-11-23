// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

/// @notice Where a tower reads its stock price.
/// @dev Only ratios between two readings matter (the weight compares the close with the open), so a source may use
///      any fixed unit. Returning 0 means "no price", which the game counts as a weight of 1.00.
interface IPriceSource {
    /// @return price The stock's price at `timestamp`, or 0 if it can't be read.
    function priceAt(uint256 timestamp) external view returns (uint256 price);
}
