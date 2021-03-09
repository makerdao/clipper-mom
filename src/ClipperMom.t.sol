pragma solidity ^0.6.7;

import "ds-test/test.sol";

import "./ClipperMom.sol";

contract ClipperMomTest is DSTest {
    ClipperMom mom;

    function setUp() public {
        mom = new ClipperMom();
    }

    function testFail_basic_sanity() public {
        assertTrue(false);
    }

    function test_basic_sanity() public {
        assertTrue(true);
    }
}
