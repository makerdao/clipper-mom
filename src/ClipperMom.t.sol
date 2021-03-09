// SPDX-License-Identifier: AGPL-3.0-or-later

/// ClipperMom.t.sol

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

import "ds-test/test.sol";

import "./ClipperMom.sol";

contract MomCaller {
    ClipperMom mom;

    constructor(ClipperMom mom_) public {
        mom = mom_;
    }

    function setOwner(address newOwner) public {
        mom.setOwner(newOwner);
    }

    function setAuthority(address newAuthority) public {
        mom.setAuthority(newAuthority);
    }

    function setBreaker(address clip, uint256 level) public {
        mom.setBreaker(clip, level);
    }
}

contract SimpleAuthority {
    address public authorized_caller;

    constructor(address authorized_caller_) public {
        authorized_caller = authorized_caller_;
    }

    function canCall(address src, address, bytes4) public view returns (bool) {
        return src == authorized_caller;
    }
}

contract MockClipper {
    // --- Auth ---
    mapping (address => uint) public wards;
    uint256 public stopped;
    function rely(address usr) external auth { wards[usr] = 1; }
    function deny(address usr) external auth { wards[usr] = 0; }
    modifier auth {
        require(wards[msg.sender] == 1, "MockClipper/not-authorized");
        _;
    }
    constructor() public {
        wards[msg.sender] = 1;
    }
    function file(bytes32 what, uint256 data) external auth {
        if (what == "stopped") stopped = data;
        else revert("MockClipper/file-unrecognized-param");
    }
}

contract ClipperMomTest is DSTest {
    ClipperMom mom;
    MomCaller caller;
    SimpleAuthority authority;
    MockClipper clip;

    function setUp() public {
        mom = new ClipperMom();
        caller = new MomCaller(mom);
        authority = new SimpleAuthority(address(caller));
        mom.setAuthority(address(authority));
        clip = new MockClipper();
        clip.rely(address(mom));
    }

    function testSetOwner() public {
        assertTrue(mom.owner() == address(this));
        mom.setOwner(address(123));
        assertTrue(mom.owner() == address(123));
    }

    // a contract that does not own the Mom cannot set a new owner
    function testFailSetOwner() public {
        caller.setOwner(address(123));
    }

    function testSetAuthority() public {
        assertTrue(mom.owner() == address(this));
        mom.setAuthority(address(123));
        assertTrue(mom.authority() == address(123));
    }

    // a contract that does not own the Mom cannot set a new authority
    function testFailSetAuthority() public {
        caller.setAuthority(address(caller));
    }

    function testSetBreakerViaAuth() public {
        assertEq(clip.stopped(), 0);
        caller.setBreaker(address(clip), 1);
        assertEq(clip.stopped(), 1);
        caller.setBreaker(address(clip), 2);
        assertEq(clip.stopped(), 2);
        caller.setBreaker(address(clip), 0);
        assertEq(clip.stopped(), 0);
    }

    function testSetBreakerViaOwner() public {
        mom.setAuthority(address(0));
        mom.setBreaker(address(clip), 1);
        assertEq(clip.stopped(), 1);
        mom.setBreaker(address(clip), 2);
        assertEq(clip.stopped(), 2);
        mom.setBreaker(address(clip), 0);
        assertEq(clip.stopped(), 0);
    }

    function testFailSetBreakerNoAuthority() public {
        mom.setAuthority(address(0));
        assertTrue(mom.owner() != address(caller));
        caller.setBreaker(address(clip), 1);
    }

    function testFailSetBreakerUnauthorized() public {
        mom.setAuthority(address(new SimpleAuthority(address(this))));
        assertTrue(mom.owner() != address(caller));
        caller.setBreaker(address(clip), 1);
    }

    function testFailSetBreakerWrongLevel() public {
        caller.setBreaker(address(clip), 3);
    }
}
