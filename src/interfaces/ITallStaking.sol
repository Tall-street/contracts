// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

interface ITallStaking {
    /// @return The $TALL a wallet has staked, not counting amounts it asked to unstake.
    function stakedOf(address who) external view returns (uint256);
}
