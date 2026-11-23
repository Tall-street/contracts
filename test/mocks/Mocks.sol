// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IPriceSource} from "../../src/interfaces/IPriceSource.sol";

/// @dev A price source whose readings the test sets by hand.
contract MockPriceSource is IPriceSource {
    mapping(uint256 => uint256) public prices;
    bool public broken;

    function set(uint256 timestamp, uint256 price) external {
        prices[timestamp] = price;
    }

    function breakIt() external {
        broken = true;
    }

    function priceAt(uint256 timestamp) external view returns (uint256) {
        require(!broken, "broken");
        return prices[timestamp];
    }
}

/// @dev A pool oracle whose tick is `tickBefore` until `switchAt` and `tickAfter` from then on,
///      with observations kept back to `oldest`.
contract MockV3Pool {
    int24 public tickBefore;
    int24 public tickAfter;
    uint256 public switchAt;
    uint256 public oldest;

    function setTicks(int24 before, int24 after_, uint256 switchAt_, uint256 oldest_) external {
        tickBefore = before;
        tickAfter = after_;
        switchAt = switchAt_;
        oldest = oldest_;
    }

    function cumulativeAt(uint256 t) public view returns (int56) {
        if (t <= switchAt) return int56(tickBefore) * int56(uint56(t));
        return int56(tickBefore) * int56(uint56(switchAt)) + int56(tickAfter) * int56(uint56(t - switchAt));
    }

    function observe(uint32[] calldata secondsAgos) external view returns (int56[] memory cums, uint160[] memory spl) {
        cums = new int56[](secondsAgos.length);
        spl = new uint160[](secondsAgos.length);
        for (uint256 i; i < secondsAgos.length; ++i) {
            uint256 t = block.timestamp - secondsAgos[i];
            require(t >= oldest, "OLD");
            cums[i] = cumulativeAt(t);
        }
    }
}

/// @dev A price source that misbehaves on purpose. Mode 0 answers with 16 bytes, mode 1 answers `price`,
///      mode 2 reads 90 cold storage slots (about 190k gas) before answering `price`.
contract OddPriceSource {
    uint256 public mode;
    uint256 public price;

    function setMode(uint256 mode_, uint256 price_) external {
        mode = mode_;
        price = price_;
    }

    fallback(bytes calldata) external returns (bytes memory) {
        uint256 m = mode;
        if (m == 0) return new bytes(16);
        if (m == 2) {
            uint256 acc;
            for (uint256 i = 1; i <= 90; ++i) {
                assembly {
                    acc := add(acc, sload(add(i, 0x1000)))
                }
            }
            if (acc != 0) revert();
        }
        return abi.encode(price);
    }
}

/// @dev Stand-in for $TALL.
contract MockTall is ERC20 {
    constructor() ERC20("Tall Street", "TALL") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
