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

contract Anyone {
    ClipperMom mom;

    constructor(ClipperMom mom_) public {
        mom = mom_;
    }

    function tripBreaker(address clip_) external {
        mom.tripBreaker(clip_);
    }
}

contract MomCaller {
    ClipperMom mom;

    constructor(ClipperMom mom_) public {
        mom = mom_;
    }

    function setOwner(address newOwner) external {
        mom.setOwner(newOwner);
    }

    function setAuthority(address newAuthority) external {
        mom.setAuthority(newAuthority);
    }

    function setBreaker(address clip_, uint256 level) external {
        mom.setBreaker(clip_, level);
    }

    function setPriceDropTolerance(bytes32 ilk_, uint256 tolerance) external {
        mom.setPriceDropTolerance(ilk_, tolerance);
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
    bytes32 public ilk;
    constructor(bytes32 _ilk) public {
        wards[msg.sender] = 1;
        ilk = _ilk;
    }
    function file(bytes32 what, uint256 data) external auth {
        if (what == "stopped") stopped = data;
        else revert("MockClipper/file-unrecognized-param");
    }
}

contract MockSpotter {
    address public pip;

    constructor(address pip_) public {
        pip = pip_;
    }

    function ilks(bytes32) external view returns (address pip_, uint256) {
        pip_ = pip;
    }
}

contract MockPip {
    struct Feed {
        uint128 val;
        uint128 has;
    }

    Feed cur;
    Feed nxt;

    function setCurPrice(uint256 val, uint256 has) external {
        cur.val = uint128(val);
        cur.has = uint128(has);
    }

    function setNxtPrice(uint256 val, uint256 has) external {
        nxt.val = uint128(val);
        nxt.has = uint128(has);
    }

    function peek() external view returns (bytes32,bool) {
        return (bytes32(uint256(cur.val)), cur.has == 1);
    }

    function peep() external view returns (bytes32,bool) {
        return (bytes32(uint256(nxt.val)), nxt.has == 1);
    }
}

interface Hevm {
    function warp(uint256) external;
}

contract ClipperMomTest is DSTest {
    MockPip pip;
    MockSpotter spotter;
    ClipperMom mom;
    MomCaller caller;
    SimpleAuthority authority;
    MockClipper clip;
    Anyone anyone;

    Hevm hevm;

    uint256 constant WAD = 10 ** 18;
    uint256 constant RAY = 10 ** 27;

    // CHEAT_CODE = 0x7109709ECfa91a80626fF3989D68f67F5b1DD12D
    bytes20 constant CHEAT_CODE =
        bytes20(uint160(uint256(keccak256('hevm cheat code'))));

    function setUp() public {
        hevm = Hevm(address(CHEAT_CODE));
        pip = new MockPip();
        spotter = new MockSpotter(address(pip));
        mom = new ClipperMom(address(spotter));
        caller = new MomCaller(mom);
        authority = new SimpleAuthority(address(caller));
        mom.setAuthority(address(authority));
        clip = new MockClipper("ETH");
        clip.rely(address(mom));
        anyone = new Anyone(mom);
        hevm.warp(1000);
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
        caller.setBreaker(address(clip), 3);
        assertEq(clip.stopped(), 3);
        caller.setBreaker(address(clip), 0);
        assertEq(clip.stopped(), 0);
    }

    function testSetBreakerViaOwner() public {
        mom.setAuthority(address(0));
        mom.setBreaker(address(clip), 1);
        assertEq(clip.stopped(), 1);
        mom.setBreaker(address(clip), 2);
        assertEq(clip.stopped(), 2);
        mom.setBreaker(address(clip), 3);
        assertEq(clip.stopped(), 3);
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
        caller.setBreaker(address(clip), 4);
    }

    function testFailSetToleranceViaAuth() public {
        caller.setPriceDropTolerance("ETH", 100);
    }

    function testSetToleranceViaOwner() public {
        assertEq(mom.tolerance("ETH"), 0);
        mom.setPriceDropTolerance("ETH", 100);
        assertEq(mom.tolerance("ETH"), 100);
    }

    function testEmergencyBreak() public {
        assertEq(clip.stopped(), 0);
        mom.setPriceDropTolerance("ETH", 40 * RAY / 100); // 40% drop
        pip.setCurPrice(100 * WAD, 1);
        pip.setNxtPrice(59 * WAD, 1);

        anyone.tripBreaker(address(clip));
        assertEq(clip.stopped(), 2);
    }

    function testEmergencyBreakMulipleClipper() public {
        assertEq(clip.stopped(), 0);
        mom.setPriceDropTolerance("ETH", 40 * RAY / 100); // 40% drop
        pip.setCurPrice(100 * WAD, 1);
        pip.setNxtPrice(59 * WAD, 1);

        MockClipper clipalt = new MockClipper("ETH");
        clipalt.rely(address(mom));

        anyone.tripBreaker(address(clipalt));
        assertEq(clipalt.stopped(), 2);      // Attempt to stop with a false or secondary clipper
        anyone.tripBreaker(address(clip));
        assertEq(clip.stopped(), 2);         // Should not affect ability to stop the correct one
    }

    function testFailEmergencyBreakWithinBounds() public {
        mom.setPriceDropTolerance("ETH", 40 * RAY / 100);
        pip.setCurPrice(100 * WAD, 1);
        pip.setNxtPrice(60 * WAD, 1);

        anyone.tripBreaker(address(clip));
    }

    function testEmergencyBreakLockedAndWait() public {
        mom.setPriceDropTolerance("ETH", 40 * RAY / 100);
        pip.setCurPrice(100 * WAD, 1);
        pip.setNxtPrice(59 * WAD, 1);

        anyone.tripBreaker(address(clip));
        assertEq(clip.stopped(), 2);
        mom.setBreaker(address(clip), 0);
        assertEq(clip.stopped(), 0);
        hevm.warp(block.timestamp + 1 hours + 1);
        anyone.tripBreaker(address(clip));
        assertEq(clip.stopped(), 2);
    }

    function testFailEmergencyBreakLocked() public {
        mom.setPriceDropTolerance("ETH", 40 * RAY / 100);
        pip.setCurPrice(100 * WAD, 1);
        pip.setNxtPrice(59 * WAD, 1);

        anyone.tripBreaker(address(clip));
        mom.setBreaker(address(clip), 0);
        anyone.tripBreaker(address(clip));
    }
}
