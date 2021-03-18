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
    function peek() external returns (bytes32, bool);
    function peep() external returns (bytes32, bool);
}

interface SpotterLike {
    function par() external returns (uint256);
    function ilks(bytes32) external returns (PipLike, uint256);
}

struct Tolerance {
    uint256 drop; // % allowed drop / 100 measured (ray val between 0 and 1)
    uint256 droppedAt; // latest acceptable price prior to break being pulled (ray value).
    bool isSet;
    bool isPulled;
}


contract ClipperMom {
    address public owner;
    address public authority;
    SpotterLike public spotter;
    mapping (bytes32 => Tolerance) public tolerance;
    
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
    uint256 constant BLN = 10 **  9;
    uint256 constant WAD = 10 ** 18;
    uint256 constant RAY = 10 ** 27;

    function min(uint256 x, uint256 y) internal pure returns (uint256 z) {
        z = x <= y ? x : y;
    }
    function add(uint256 x, uint256 y) internal pure returns (uint256 z) {
        require((z = x + y) >= x);
    }
    function sub(uint256 x, uint256 y) internal pure returns (uint256 z) {
        require((z = x - y) <= x);
    }
    function mul(uint256 x, uint256 y) internal pure returns (uint256 z) {
        require(y == 0 || (z = x * y) / y == x);
    }
    function wmul(uint256 x, uint256 y) internal pure returns (uint256 z) {
        z = mul(x, y) / WAD;
    }
    function rmul(uint256 x, uint256 y) internal pure returns (uint256 z) {
        z = mul(x, y) / RAY;
    }
    function rdiv(uint256 x, uint256 y) internal pure returns (uint256 z) {
        z = mul(x, RAY) / y;
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

    function setOwner(address owner_) external onlyOwner {
        emit SetOwner(owner, owner_);
        owner = owner_;
    }

    function setAuthority(address authority_) external onlyOwner {
        emit SetAuthority(authority, authority_);
        authority = authority_;
    }

    function setBreaker(address clip_, uint256 level) external auth {
        require(level <= 2, "ClipperMom/wrong-level");
        ClipLike(clip_).file("stopped", level);
        emit SetBreaker(clip_, level);
    }

    /**
        The following implements a permissionless circuit breaker in case the price reported by an oracle
        for a particular collateral type has dropped more than a governance-defined % from 1 hour to the next.

        SetPriceDropTolerance sets a % (a RAY number between 0 and 1) for a specific collateral type
        It then gets the price of the ilk from the spotter and caches that price, the current time, and
        the % tolerance.
            

        emergencyBreak takes the address of the ilk's clipper as well as the ilk identifier.
        it then gets the current and next price and checks:
          - the next price < current price
          - the currentPrice * (tolerance % * 100) is less than the currentPrice - next price
            - i.e., the acceptable drop in price < the actual drop
          - If the drop is unacceptable, it stops auctions for the current ilk and allows a later retry
        
          - Edge cases: 
            - The clipper is for a different ilk than the ilk whose price we are breaking -> require the clipper's ilk == ilk_
    

        States of the emergency break system:
            - Pulled (yes/no)
            - IsSet (yes/no)
            - drop (number)
            - priceWhenDropped (number)
        Workflow: 
            1. SetPriceDropTolerance[ilk]
                - Allowed in any state
            2. Pull E-Break
                - Allowed if pulled is False & IsSet is true
                - Succeeds if:
                    - currPrice * drop < currPrice - nextPrice  (and currPrice < nextPrice)
                - After: priceWhenDropped = currPrice; Pulled = true
            3. Release E-Break
                - Allowed if pulled is True and IsSet is True
                - Succeeds if:
                    - (currPrice >= priceWhenDropped OR
                    - priceWhenDropped * drop > priceWhenDropped - currPrice) AND
                    - currPrice * drop > currPrice - nextPrice
                - After: priceWhenDropped = 0; Pulled = false;
            4. Unset E-Break
                - Allowed if pulled is False and IsSet is true
                - After: IsSet is true

        Points of discussion:
            - Should break unset be unallowable when someone could pull the break? Maybe this is okay since unsetBreak is auth'd
            - Can the stopped level of clipper be changed by anything other than clipperMom or is there risk of "isPulled" being
              out of sync with the clipper such that a clipper is re-enabled but we can't reset the emergency break.
            - Should we allow the tolerable drop % to be configured on an ilk when it's emergency break is pulled?
    */
    function setPriceDropTolerance(bytes32 ilk_, uint256 tolerance_) external auth {
        require(tolerance_ <= 1 * RAY && tolerance_ > 0, "ClipperMom/tolerance-out-of-bounds");
        tolerance[ilk_].drop = tolerance_;
        tolerance[ilk_].isSet = true;
    }

    // Succeeds if drop tolerance is set and the break for the ilk is not currently "pulled"/active
    // Fails if (price > priceNxt && diff(price, priceNxt) > tolerableChange) OR price < priceNxt 
    function pullBreak(address clip_) external {
        ClipLike clipper = ClipLike(clip_);
        bytes32 ilk_ = clipper.ilk();
        require(tolerance[ilk_].isSet && !tolerance[ilk_].isPulled, "ClipperMom/invalid-ilk-break");
      
        (uint256 price, uint256 priceNxt) = getPrices(ilk_);

        require(rmul(price, tolerance[ilk_].drop) <  sub(price, priceNxt), "ClipperMom/price-within-bounds");
        tolerance[ilk_].droppedAt = price;
        tolerance[ilk_].isPulled = true;
        clipper.file("stopped", 2);
        emit SetBreaker(clip_, 2);
    }



    // Succeeds if:
    //   (price > droppedAt & (price < nxtPrice OR (price >= nxtPrice && change from price to nxtPrice < tolerableChange)) 
    //  OR
    //    price < droppedAt & change from droppedAt to Price < tolerableChange
    function releaseBreak(address clip_) external {
        ClipLike clipper = ClipLike(clip_);
        bytes32 ilk_ = clipper.ilk();
        Tolerance memory ilkTolerance = tolerance[ilk_];
        require(ilkTolerance.isPulled && ilkTolerance.isSet, "ClipperMom/invalid-ilk-release");
        
        (uint256 price, uint256 nxtPrice) = getPrices(ilk_);
        if (price < ilkTolerance.droppedAt) {
            require(rmul(ilkTolerance.droppedAt, ilkTolerance.drop) >  sub(ilkTolerance.droppedAt, price), "ClipperMom/price-within-bounds");
        }
        if (price > nxtPrice) {
            require(rmul(price, ilkTolerance.drop) <  sub(price, nxtPrice), "ClipperMom/price-within-bounds");
        }

        tolerance[ilk_].isPulled = false;
        tolerance[ilk_].droppedAt = 0;
        clipper.file("stopped", 0);
    }

    function unsetBreak(bytes32 ilk_) external auth {
        require(tolerance[ilk_].isSet == true);
        tolerance[ilk_].isSet = false;
    }
  
    function getPrices(bytes32 ilk_) internal returns (uint256 price, uint256 priceNxt) {
        (PipLike pip, ) = spotter.ilks(ilk_);
        (bytes32 val, bool has) = pip.peek();
        require(has, "ClipperMom/invalid-price");
        price = mul(uint256(val), BLN);
        (bytes32 valNxt, bool hasNxt) = pip.peep();
        require(hasNxt, "ClipperMom/invalid-price");
        priceNxt = mul(uint256(valNxt), BLN);
    }
  
}
