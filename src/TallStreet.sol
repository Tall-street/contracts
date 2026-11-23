// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPriceSource} from "./interfaces/IPriceSource.sol";
import {ITallStaking} from "./interfaces/ITallStaking.sol";

/// @title Tall Street
/// @notice A daily tower game on Robinhood Chain. Crews stack floors on eight towers, each tied to a stock token.
///         At 20:00 UTC the crew with the most valuable street takes 90% of the pot, split by the floors each member
///         placed. The rules are the ones published at github.com/Tall-street/rules, with the same numbers, the same
///         checks and the same rounding.
/// @dev Rounds are fixed by the clock: round r runs from r days + 20 h to the same time a day later (UTC).
///      Prices are recorded once per boundary (each 20:00 UTC) and shared: a round's close is the next round's open.
contract TallStreet is Ownable2Step, ReentrancyGuard {
    // ---------------------------------------------------------------- the rules

    uint256 public constant BPS = 10_000;
    uint256 public constant TOWER_COUNT = 8;
    uint256 public constant ROUND = 1 days;
    /// @notice Rounds open and close at 20:00 UTC.
    uint256 public constant OPEN_OFFSET = 20 hours;
    uint256 public constant FINAL_HOUR = 1 hours;
    uint256 public constant FLOOR_PRICE = 0.001 ether;
    uint256 public constant FINAL_FLOOR_PRICE = 0.002 ether;
    int256 public constant WEIGHT_FACTOR = 10;
    uint256 public constant WEIGHT_MIN = 5_000;
    uint256 public constant WEIGHT_MAX = 15_000;
    uint256 public constant WINNER_SHARE = 9_000;
    uint256 public constant MAX_FLOORS_PER_TX = 20;
    uint256 public constant HOLDER_MAX_FLOORS_PER_TX = 100;
    uint256 public constant MAX_DISCOUNT = 2_000;

    // ---------------------------------------------------------------- operations

    /// @notice How long after a boundary its prices can still be recorded.
    uint256 public constant SNAPSHOT_WINDOW = 2 hours;
    /// @notice How long a new price source waits before it can replace the old one.
    uint256 public constant SOURCE_DELAY = 2 days;
    /// @notice Gas each price source gets when a boundary is recorded, so a broken source can't block the others.
    ///         A recording only goes ahead when every source gets all of it.
    uint256 public constant SOURCE_GAS = 300_000;

    // ---------------------------------------------------------------- crews

    struct Crew {
        address founder;
        uint8 color;
        uint8 emblem;
        uint64 foundedAt;
        string name;
    }

    /// @dev Crew ids start at 1; a lower id was founded earlier, which breaks ties at the close.
    Crew[] internal _crews;
    /// @notice Crew id by the hash of its lowercase name, so two crews can't share a name.
    mapping(bytes32 => uint256) public crewIdByName;

    // ---------------------------------------------------------------- rounds

    struct Tower {
        uint32 holder;
        uint32 floors;
        uint64 heldSince;
    }

    struct RoundData {
        uint128 pot;
        uint128 winnersShare;
        uint32 winner;
        uint32 floors;
        bool settled;
    }

    mapping(uint256 round => RoundData) internal _rounds;
    mapping(uint256 round => Tower[8]) internal _towers;
    mapping(uint256 round => mapping(uint256 tower => mapping(uint256 crew => uint256))) public crewFloorsOn;
    mapping(uint256 round => mapping(uint256 crew => uint256)) public crewFloors;
    mapping(uint256 round => mapping(address member => uint256)) public memberFloors;
    /// @notice The crew a wallet plays for in a round, 0 before its first floor.
    mapping(uint256 round => mapping(address member => uint256)) public memberCrew;
    mapping(uint256 round => mapping(address member => bool)) public claimed;

    // ---------------------------------------------------------------- prices

    IPriceSource[8] public sources;

    struct PendingSource {
        IPriceSource source;
        uint64 readyAt;
    }

    mapping(uint256 tower => PendingSource) public pendingSources;
    mapping(uint256 boundary => uint256[8]) internal _prices;
    mapping(uint256 boundary => bool) public snapped;

    // ---------------------------------------------------------------- money and perks

    address public treasury;
    /// @notice Tall Street's 10% of settled pots, waiting to be sent to the treasury.
    uint256 public houseBalance;
    bool public paused;

    IERC20 public tall;
    ITallStaking public staking;
    /// @notice $TALL (held plus staked) a wallet needs to found a crew and place up to 100 floors at once. 0 = off.
    uint256 public holderThreshold;
    /// @notice Staked $TALL for the full 20% off every floor; less gives a proportional discount. 0 = off.
    uint256 public fullDiscountStake;

    // ---------------------------------------------------------------- events and errors

    event CrewFounded(uint256 indexed crew, address indexed founder, string name, uint8 color, uint8 emblem);
    event FloorsPlaced(
        uint256 indexed round,
        uint256 indexed tower,
        uint256 indexed crew,
        address member,
        uint256 floors,
        uint256 paid,
        uint256 holder
    );
    event PricesRecorded(uint256 indexed boundary, uint256[8] prices);
    event Settled(
        uint256 indexed round, uint256 indexed winner, uint256 streetValue, uint256 pot, uint256 winnersShare
    );
    event Claimed(uint256 indexed round, address indexed member, uint256 amount);
    event HouseWithdrawn(address indexed to, uint256 amount);
    event SourceProposed(uint256 indexed tower, address source, uint256 readyAt);
    event SourceSet(uint256 indexed tower, address source);
    event TreasurySet(address treasury);
    event PausedSet(bool paused);
    event TallSet(address tall, address staking);
    event PerksSet(uint256 holderThreshold, uint256 fullDiscountStake);

    error Paused();
    error BadTower();
    error BadCrew();
    error BadFloors();
    error TooManyFloors(uint256 max);
    error OtherCrew(uint256 crew);
    error WrongPayment(uint256 expected);
    error BadName();
    error NameTaken();
    error BadStyle();
    error NotAllowedToFound();
    error NotABoundary();
    error TooEarly();
    error TooLate();
    error AlreadyRecorded();
    error RoundNotClosed();
    error AlreadySettled();
    error NothingToClaim();
    error NoPendingSource();
    error ZeroAddress();
    error AlreadySet();
    error LowGas();

    constructor(address owner_, address treasury_, IPriceSource[8] memory sources_) Ownable(owner_) {
        if (treasury_ == address(0)) revert ZeroAddress();
        treasury = treasury_;
        for (uint256 i; i < TOWER_COUNT; ++i) {
            sources[i] = sources_[i];
            emit SourceSet(i, address(sources_[i]));
        }
    }

    // ---------------------------------------------------------------- time

    function currentRound() public view returns (uint256) {
        return (block.timestamp - OPEN_OFFSET) / ROUND;
    }

    function openAt(uint256 round) public pure returns (uint256) {
        return round * ROUND + OPEN_OFFSET;
    }

    function closeAt(uint256 round) public pure returns (uint256) {
        return openAt(round) + ROUND;
    }

    function inFinalHour() public view returns (bool) {
        return block.timestamp >= closeAt(currentRound()) - FINAL_HOUR;
    }

    // ---------------------------------------------------------------- crews

    /// @notice Found a crew. Names are 2 to 18 characters: letters, digits, spaces and & ' . - and they're unique
    ///         regardless of case. Colour and emblem are indexes into the site's palettes.
    function foundCrew(string calldata name, uint8 color, uint8 emblem) external returns (uint256 id) {
        if (!canFound(msg.sender)) revert NotAllowedToFound();
        if (color >= 8 || emblem >= 6) revert BadStyle();
        bytes32 key = _nameKey(name);
        if (crewIdByName[key] != 0) revert NameTaken();
        if (_crews.length >= type(uint32).max) revert BadCrew();
        _crews.push(Crew(msg.sender, color, emblem, uint64(block.timestamp), name));
        id = _crews.length;
        crewIdByName[key] = id;
        emit CrewFounded(id, msg.sender, name, color, emblem);
    }

    function crewCount() external view returns (uint256) {
        return _crews.length;
    }

    function crew(uint256 id) external view returns (Crew memory) {
        if (id == 0 || id > _crews.length) revert BadCrew();
        return _crews[id - 1];
    }

    // ---------------------------------------------------------------- floors

    /// @notice Place floors on a tower for a crew in the current round. A wallet plays for one crew per round.
    function placeFloors(uint256 tower, uint256 crewId, uint256 floors) external payable nonReentrant {
        if (paused) revert Paused();
        if (tower >= TOWER_COUNT) revert BadTower();
        if (crewId == 0 || crewId > _crews.length) revert BadCrew();
        if (floors == 0) revert BadFloors();
        if (floors > MAX_FLOORS_PER_TX) {
            uint256 max = maxFloorsPerTx(msg.sender);
            if (floors > max) revert TooManyFloors(max);
        }

        uint256 r = currentRound();
        uint256 joined = memberCrew[r][msg.sender];
        if (joined == 0) memberCrew[r][msg.sender] = crewId;
        else if (joined != crewId) revert OtherCrew(joined);

        uint256 cost = floorPrice(msg.sender) * floors;
        if (msg.value != cost) revert WrongPayment(cost);

        // the crew with the most floors holds the tower; a draw stays with whoever got there first
        uint256 count = crewFloorsOn[r][tower][crewId] + floors;
        crewFloorsOn[r][tower][crewId] = count;
        Tower storage t = _towers[r][tower];
        uint256 holder = t.holder;
        if (holder == 0 || (holder != crewId && count > crewFloorsOn[r][tower][holder])) {
            t.holder = uint32(crewId);
            t.heldSince = uint64(block.timestamp);
        }
        t.floors += uint32(floors);

        crewFloors[r][crewId] += floors;
        memberFloors[r][msg.sender] += floors;
        RoundData storage rd = _rounds[r];
        rd.pot += uint128(msg.value);
        rd.floors += uint32(floors);

        emit FloorsPlaced(r, tower, crewId, msg.sender, floors, msg.value, t.holder);
    }

    /// @notice Price of one floor for a wallet right now: 0.001 ETH, 0.002 ETH in the final hour, less any staking discount.
    function floorPrice(address who) public view returns (uint256) {
        uint256 base = inFinalHour() ? FINAL_FLOOR_PRICE : FLOOR_PRICE;
        return base * (BPS - discountBps(who)) / BPS;
    }

    /// @notice Floors a crew must place on a tower to hold it (0 if it already does).
    function floorsToTake(uint256 round, uint256 tower, uint256 crewId) external view returns (uint256) {
        uint256 holder = _towers[round][tower].holder;
        if (holder == crewId) return 0;
        if (holder == 0) return 1;
        return crewFloorsOn[round][tower][holder] - crewFloorsOn[round][tower][crewId] + 1;
    }

    function towerAt(uint256 round, uint256 index) external view returns (Tower memory) {
        return _towers[round][index];
    }

    function roundData(uint256 round) external view returns (RoundData memory) {
        return _rounds[round];
    }

    // ---------------------------------------------------------------- prices

    /// @notice Record every tower's price at a boundary (a 20:00 UTC). Anyone can call it, from the boundary until
    ///         two hours later. A source that fails or returns nothing is recorded as no price.
    function recordPrices(uint256 boundary) public {
        if (boundary % ROUND != OPEN_OFFSET) revert NotABoundary();
        if (block.timestamp < boundary) revert TooEarly();
        if (block.timestamp > boundary + SNAPSHOT_WINDOW) revert TooLate();
        if (snapped[boundary]) revert AlreadyRecorded();
        snapped[boundary] = true;

        uint256[8] memory p;
        for (uint256 i; i < TOWER_COUNT; ++i) {
            IPriceSource s = sources[i];
            if (address(s) != address(0)) p[i] = _read(s, boundary);
        }
        _prices[boundary] = p;
        emit PricesRecorded(boundary, p);
    }

    /// @dev Reads one source with SOURCE_GAS. Whoever records picks the transaction's gas limit, so the read only
    ///      goes ahead when the source gets its whole allowance: a low limit reverts the recording instead of quietly
    ///      turning a good price into no price. A revert, or an answer that isn't 32 bytes, counts as no price.
    function _read(IPriceSource s, uint256 boundary) internal view returns (uint256 price) {
        bytes memory data = abi.encodeCall(IPriceSource.priceAt, (boundary));
        // a call passes on at most 63/64 of the gas left, plus a margin for the call itself
        if (gasleft() < SOURCE_GAS + SOURCE_GAS / 63 + 10_000) revert LowGas();
        address target = address(s);
        uint256 cap = SOURCE_GAS;
        bool ok;
        uint256 size;
        assembly ("memory-safe") {
            ok := staticcall(cap, target, add(data, 0x20), mload(data), 0x00, 0x20)
            size := returndatasize()
            price := mload(0x00)
        }
        if (!ok || size != 32) price = 0;
    }

    function pricesAt(uint256 boundary) external view returns (uint256[8] memory) {
        return _prices[boundary];
    }

    /// @notice weight = 1 + 10 × (close − open) / open, in basis points, kept between 0.5 and 1.5.
    ///         The move is cut to whole basis points, toward zero. A missing price counts as 1.
    /// @dev Works for any two readings without overflowing, so no price can stop a round from closing.
    function weightBps(uint256 open, uint256 close) public pure returns (uint256) {
        if (open == 0 || close == 0) return BPS;
        uint256 factor = uint256(WEIGHT_FACTOR);
        if (close >= open) {
            // a rise of 100% or more is far past the cap, and keeping below it keeps the division in range
            if (close - open >= open) return WEIGHT_MAX;
            uint256 up = Math.mulDiv(close - open, BPS, open);
            return up >= (WEIGHT_MAX - BPS) / factor ? WEIGHT_MAX : BPS + factor * up;
        }
        uint256 down = Math.mulDiv(open - close, BPS, open);
        return down >= (BPS - WEIGHT_MIN) / factor ? WEIGHT_MIN : BPS - factor * down;
    }

    /// @notice Each tower's weight for a round, from the prices recorded at its open and its close.
    function weights(uint256 round) public view returns (uint256[8] memory w) {
        uint256[8] storage open = _prices[openAt(round)];
        uint256[8] storage close = _prices[closeAt(round)];
        for (uint256 i; i < TOWER_COUNT; ++i) {
            w[i] = weightBps(open[i], close[i]);
        }
    }

    /// @notice Street value of a crew at a round's recorded prices, in floors × basis points.
    function streetValue(uint256 round, uint256 crewId) external view returns (uint256 value) {
        uint256[8] memory w = weights(round);
        for (uint256 i; i < TOWER_COUNT; ++i) {
            Tower storage t = _towers[round][i];
            if (t.holder == crewId && crewId != 0) value += uint256(t.floors) * w[i];
        }
    }

    // ---------------------------------------------------------------- the close

    /// @notice Close a round. Anyone can call it after 20:00 UTC; it records the closing prices if nobody has yet.
    function settle(uint256 round) external nonReentrant {
        uint256 close = closeAt(round);
        if (block.timestamp < close) revert RoundNotClosed();
        RoundData storage rd = _rounds[round];
        if (rd.settled) revert AlreadySettled();
        if (!snapped[close] && block.timestamp <= close + SNAPSHOT_WINDOW) recordPrices(close);
        rd.settled = true;

        (uint256 winner, uint256 value) = _winner(round, weights(round));
        uint256 pot = rd.pot;
        if (winner != 0) {
            uint256 share = (pot * WINNER_SHARE) / BPS;
            rd.winner = uint32(winner);
            rd.winnersShare = uint128(share);
            houseBalance += pot - share;
        } else {
            // unreachable while weights stay positive: any floor makes a holder. Kept so no ETH can be stranded.
            houseBalance += pot;
        }
        emit Settled(round, winner, value, pot, rd.winnersShare);
    }

    /// @dev Only crews that hold a tower have a street value, so the winner is one of at most eight holders.
    ///      Ties go to the crew that placed more floors in the round, then to the crew founded first.
    function _winner(uint256 round, uint256[8] memory w) internal view returns (uint256 best, uint256 bestValue) {
        uint256[8] memory crews;
        uint256[8] memory values;
        uint256 n;
        for (uint256 i; i < TOWER_COUNT; ++i) {
            Tower storage t = _towers[round][i];
            uint256 holder = t.holder;
            if (holder == 0) continue;
            uint256 j;
            while (j < n && crews[j] != holder) ++j;
            if (j == n) crews[n++] = holder;
            values[j] += uint256(t.floors) * w[i];
        }
        uint256 bestFloors;
        for (uint256 j; j < n; ++j) {
            uint256 c = crews[j];
            uint256 v = values[j];
            uint256 f = crewFloors[round][c];
            if (best == 0 || v > bestValue || (v == bestValue && (f > bestFloors || (f == bestFloors && c < best)))) {
                best = c;
                bestValue = v;
                bestFloors = f;
            }
        }
    }

    /// @notice What a wallet can claim from a settled round: its floors' share of the winners' 90%, rounded down.
    function claimable(uint256 round, address who) public view returns (uint256) {
        RoundData storage rd = _rounds[round];
        if (!rd.settled || rd.winner == 0 || claimed[round][who] || memberCrew[round][who] != rd.winner) return 0;
        return (uint256(rd.winnersShare) * memberFloors[round][who]) / crewFloors[round][rd.winner];
    }

    function claim(uint256 round) external nonReentrant {
        uint256 amount = claimable(round, msg.sender);
        if (amount == 0) revert NothingToClaim();
        claimed[round][msg.sender] = true;
        emit Claimed(round, msg.sender, amount);
        Address.sendValue(payable(msg.sender), amount);
    }

    /// @notice Send Tall Street's share to the treasury. Anyone can trigger it; the ETH only ever goes to the treasury.
    function withdrawHouse() external nonReentrant {
        uint256 amount = houseBalance;
        if (amount == 0) revert NothingToClaim();
        houseBalance = 0;
        emit HouseWithdrawn(treasury, amount);
        Address.sendValue(payable(treasury), amount);
    }

    // ---------------------------------------------------------------- $TALL perks

    /// @notice $TALL a wallet holds plus what it has staked.
    function heldBy(address who) public view returns (uint256 amount) {
        if (address(tall) == address(0)) return 0;
        amount = tall.balanceOf(who);
        if (address(staking) != address(0)) amount += staking.stakedOf(who);
    }

    function isHolder(address who) public view returns (bool) {
        return holderThreshold != 0 && heldBy(who) >= holderThreshold;
    }

    /// @notice Before $TALL is set, or while the threshold is 0, anyone can found a crew.
    function canFound(address who) public view returns (bool) {
        return address(tall) == address(0) || holderThreshold == 0 || heldBy(who) >= holderThreshold;
    }

    function maxFloorsPerTx(address who) public view returns (uint256) {
        return isHolder(who) ? HOLDER_MAX_FLOORS_PER_TX : MAX_FLOORS_PER_TX;
    }

    /// @notice Discount on every floor, up to 20% at `fullDiscountStake` staked $TALL, proportional below it.
    function discountBps(address who) public view returns (uint256) {
        if (address(staking) == address(0) || fullDiscountStake == 0) return 0;
        uint256 s = staking.stakedOf(who);
        return s >= fullDiscountStake ? MAX_DISCOUNT : (s * MAX_DISCOUNT) / fullDiscountStake;
    }

    // ---------------------------------------------------------------- owner

    /// @notice Point the game at $TALL and its staking contract, once, after the token launches.
    function setTall(IERC20 tall_, ITallStaking staking_) external onlyOwner {
        if (address(tall) != address(0)) revert AlreadySet();
        if (address(tall_) == address(0)) revert ZeroAddress();
        tall = tall_;
        staking = staking_;
        emit TallSet(address(tall_), address(staking_));
    }

    function setPerks(uint256 holderThreshold_, uint256 fullDiscountStake_) external onlyOwner {
        holderThreshold = holderThreshold_;
        fullDiscountStake = fullDiscountStake_;
        emit PerksSet(holderThreshold_, fullDiscountStake_);
    }

    function setTreasury(address treasury_) external onlyOwner {
        if (treasury_ == address(0)) revert ZeroAddress();
        treasury = treasury_;
        emit TreasurySet(treasury_);
    }

    /// @notice Stop new floors in an emergency. Closing rounds, claims and the house withdrawal keep working.
    function setPaused(bool paused_) external onlyOwner {
        paused = paused_;
        emit PausedSet(paused_);
    }

    /// @notice Propose a new price source for a tower. It can replace the old one after SOURCE_DELAY, so a change
    ///         can't be slipped in right before a close.
    function proposeSource(uint256 index, IPriceSource source) external onlyOwner {
        if (index >= TOWER_COUNT) revert BadTower();
        uint64 readyAt = uint64(block.timestamp + SOURCE_DELAY);
        pendingSources[index] = PendingSource(source, readyAt);
        emit SourceProposed(index, address(source), readyAt);
    }

    function applySource(uint256 index) external {
        PendingSource memory p = pendingSources[index];
        if (p.readyAt == 0) revert NoPendingSource();
        if (block.timestamp < p.readyAt) revert TooEarly();
        sources[index] = p.source;
        delete pendingSources[index];
        emit SourceSet(index, address(p.source));
    }

    // ---------------------------------------------------------------- internal

    /// @dev Validates a crew name and returns the hash of its lowercase form.
    function _nameKey(string calldata name) internal pure returns (bytes32) {
        bytes memory b = bytes(name);
        uint256 n = b.length;
        if (n < 2 || n > 18) revert BadName();
        bytes memory lower = new bytes(n);
        bool prevSpace = true;
        for (uint256 i; i < n; ++i) {
            bytes1 c = b[i];
            bool space = c == 0x20;
            if (space) {
                if (prevSpace) revert BadName();
            } else if (!((c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5a) || (c >= 0x61 && c <= 0x7a) || c == 0x26
                        || c == 0x27 || c == 0x2e || c == 0x2d)) {
                revert BadName();
            }
            lower[i] = (c >= 0x41 && c <= 0x5a) ? bytes1(uint8(c) + 32) : c;
            prevSpace = space;
        }
        if (prevSpace) revert BadName();
        return keccak256(lower);
    }
}
