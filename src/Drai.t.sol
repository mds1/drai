pragma solidity ^0.6.7;

import "ds-test/test.sol";

import "./Drai.sol";

contract DraiTest is DSTest {
    Drai drai;

    function setUp() public {
        drai = new Drai();
    }

    function testFail_basic_sanity() public {
        assertTrue(false);
    }

    function test_basic_sanity() public {
        assertTrue(true);
    }
}
