// SPDX-License-Identifier: AGPL-3.0-or-later

/// ClipperMom.sol -- governance interface for the Clipper

// Copyright (C) 2021 Maker Ecosystem Growth Holdings, INC.
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

pragma solidity >=0.6.12;

interface ClipLike {
    function file(bytes32, uint256) external;
    function ilk() external view returns (bytes32);
}

interface AuthorityLike {
    function canCall(address src, address dst, bytes4 sig) external view returns (bool);
}

interface PipLike {
    function peek() external view returns (uint256, bool);
    function peep() external view returns (uint256, bool);
}

interface SpotterLike {
    function ilks(bytes32) external view returns (PipLike, uint256);
}

contract ClipperMom {
    address public owner;
    address public authority;
    SpotterLike public spotter;
    mapping (bytes32 => uint256) public locked;
    mapping (bytes32 => uint256) public tolerance; // ilk -> ray

    event SetOwner(address indexed oldOwner, address indexed newOwner);
    event SetAuthority(address indexed oldAuthority, address indexed newAuthority);
    event SetBreaker(address indexed clip, uint256 level);

    modifier onlyOwner {
        require(msg.sender == owner, "ClipperMom/only-owner");
        _;
    }

    modifier auth {
        require(isAuthorized(msg.sender, msg.sig), "ClipperMom/not-authorized");
        _;
    }

    constructor(address spotter_) public {
        owner = msg.sender;
        spotter = SpotterLike(spotter_);
        emit SetOwner(address(0), msg.sender);
    }

    // --- Math ---
    uint256 constant WAD = 10 ** 18;
    uint256 constant RAY = 10 ** 27;

    function sub(uint256 x, uint256 y) internal pure returns (uint256 z) {
        require((z = x - y) <= x);
    }
    function mul(uint256 x, uint256 y) internal pure returns (uint256 z) {
        require(y == 0 || (z = x * y) / y == x);
    }
    function rmul(uint256 x, uint256 y) internal pure returns (uint256 z) {
        z = mul(x, y) / RAY;
    }

    function isAuthorized(address src, bytes4 sig) internal view returns (bool) {
        if (src == address(this)) {
            return true;
        } else if (src == owner) {
            return true;
        } else if (authority == address(0)) {
            return false;
        } else {
            return AuthorityLike(authority).canCall(src, address(this), sig);
        }
    }

    function getPrices(bytes32 ilk_) internal view returns (uint256 cur, uint256 nxt) {
        (PipLike pip, ) = spotter.ilks(ilk_);
        bool has;
        (cur, has) = pip.peek();
        require(has, "ClipperMom/invalid-cur-price");
        (nxt, has) = pip.peep();
        require(has, "ClipperMom/invalid-nxt-price");
    }

    // Governance actions with delay
    function setOwner(address owner_) external onlyOwner {
        emit SetOwner(owner, owner_);
        owner = owner_;
    }

    function setAuthority(address authority_) external onlyOwner {
        emit SetAuthority(authority, authority_);
        authority = authority_;
    }

    function setPriceDropTolerance(bytes32 ilk_, uint256 tolerance_) external onlyOwner {
        require(tolerance_ <= 1 * RAY && tolerance_ > 0, "ClipperMom/tolerance-out-of-bounds");
        tolerance[ilk_] = tolerance_;
    }

    // Governance action without delay
    function setBreaker(address clip_, uint256 level) external auth {
        require(level <= 3, "ClipperMom/wrong-level");
        ClipLike(clip_).file("stopped", level);
        // If governance changes the status of the breaker we want to lock for one hour
        // the permissionless function so the osm can pull new nxt price to compare
        locked[ClipLike(clip_).ilk()] = block.timestamp + 1 hours;
        emit SetBreaker(clip_, level);
    }

    /**
        The following implements a permissionless circuit breaker in case the price reported by an oracle
        for a particular collateral type has dropped more than a governance-defined % from 1 hour to the next.

        SetPriceDropTolerance sets a % (a RAY number between 0 and 1) for a specific collateral type
        It then gets the price of the ilk from the spotter and caches that price, the current time, and
        the % tolerance.
            

        tripBreaker takes the address of the ilk's clipper as well as the ilk identifier.
        it then gets the current and next price and checks:
          - the next price < current price
          - the currentPrice * (tolerance % * 100) is less than the currentPrice - next price
            - i.e., the acceptable drop in price < the actual drop
          - If the drop is unacceptable, it stops auctions for the current ilk and allows a later retry
        
          - Edge cases: 
            - The clipper is for a different ilk than the ilk whose price we are breaking -> require the clipper's ilk == ilk_
    
    */
    function tripBreaker(address clip_) external {
        ClipLike clipper = ClipLike(clip_);
        bytes32 ilk_ = clipper.ilk();
        require(tolerance[ilk_] > 0, "ClipperMom/invalid-ilk-break");
        require(block.timestamp > locked[ilk_], "ClipperMom/temporary-locked");
      
        (uint256 cur, uint256 nxt) = getPrices(ilk_);

        require(nxt < rmul(cur, sub(RAY, tolerance[ilk_])), "ClipperMom/price-within-bounds");
        clipper.file("stopped", 1);
        emit SetBreaker(clip_, 1);
    }
}
