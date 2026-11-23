// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {ITallStaking} from "./interfaces/ITallStaking.sol";

/// @title $TALL staking
/// @notice Stake $TALL for cheaper floors. Unstaking takes a cooldown, so a stake can't be borrowed for one
///         transaction and handed straight back. This contract only holds what people stake: it never touches the
///         token itself, its supply or its fees.
contract TallStaking is ITallStaking, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant COOLDOWN = 3 days;

    IERC20 public immutable tall;

    struct Account {
        uint128 staked;
        uint128 leaving;
        uint64 leaveAt;
    }

    mapping(address => Account) public accounts;

    event Staked(address indexed who, uint256 amount);
    event UnstakeRequested(address indexed who, uint256 amount, uint256 availableAt);
    event Withdrawn(address indexed who, uint256 amount);

    error ZeroAmount();
    error NotEnoughStaked();
    error StillCooling(uint256 availableAt);
    error NothingToWithdraw();

    constructor(IERC20 tall_) {
        tall = tall_;
    }

    /// @notice Stake $TALL. Only what actually arrives counts, in case the token takes a fee on transfer.
    function stake(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        uint256 before = tall.balanceOf(address(this));
        tall.safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = tall.balanceOf(address(this)) - before;
        accounts[msg.sender].staked += SafeCast.toUint128(received);
        emit Staked(msg.sender, received);
    }

    /// @notice Start unstaking. The amount stops counting at once and can be withdrawn after the cooldown.
    ///         Asking again restarts the cooldown for everything that is leaving.
    function requestUnstake(uint256 amount) external {
        Account storage a = accounts[msg.sender];
        if (amount == 0) revert ZeroAmount();
        if (amount > a.staked) revert NotEnoughStaked();
        a.staked -= uint128(amount);
        a.leaving += uint128(amount);
        a.leaveAt = uint64(block.timestamp + COOLDOWN);
        emit UnstakeRequested(msg.sender, amount, a.leaveAt);
    }

    /// @notice Withdraw everything whose cooldown has ended.
    function withdraw() external nonReentrant {
        Account storage a = accounts[msg.sender];
        uint256 amount = a.leaving;
        if (amount == 0) revert NothingToWithdraw();
        if (block.timestamp < a.leaveAt) revert StillCooling(a.leaveAt);
        a.leaving = 0;
        a.leaveAt = 0;
        emit Withdrawn(msg.sender, amount);
        tall.safeTransfer(msg.sender, amount);
    }

    /// @inheritdoc ITallStaking
    function stakedOf(address who) external view returns (uint256) {
        return accounts[who].staked;
    }
}
