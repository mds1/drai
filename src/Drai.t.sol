pragma solidity ^0.6.7;

import "ds-test/test.sol";
import "./Drai.sol";

interface Hevm {
    function warp(uint256 x) external;
    function store(address c, bytes32 loc, bytes32 val) external;
}

interface RaiLike is CoinLike {
    function approve(address, uint256) external returns (bool);
    function allowance(address, address) external returns (uint256);
}

contract DraiTest is DSTest {
    Hevm hevm = Hevm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);
    Drai drai;
    RaiLike rai = RaiLike(0x03ab458634910AaD20eF5f1C8ee96F1D6ac54919);

    function setUp() public virtual {
        drai = new Drai();

        // Give us 100 RAI to work with
        uint256 initialRaiBalance = 100 ether;
        setRaiBalance(address(this), initialRaiBalance);
        rai.approve(address(drai), uint256(-1));
        assertEq(rai.balanceOf(address(this)), initialRaiBalance);
        assertEq(rai.allowance(address(this), address(drai)), uint256(-1));
    }

    function setRaiBalance(address dst, uint256 wad) public {
        bytes32 slot = keccak256(abi.encode(dst, 6)); // get storage slot
        hevm.store(address(rai), slot, bytes32(wad)); // set balance of `dst` to `wad` RAI
    }

    function testFail_basic_sanity() public {
        assertTrue(false);
    }

    function test_basic_sanity() public {
        assertTrue(true);
    }

    function test_token_properties() public {
        assertEq(drai.name(), "Drai");
        assertEq(drai.symbol(), "DRAI");
        assertEq(drai.version(), "1");
        assertEq(uint256(drai.decimals()), uint256(18));
    }
}

contract DraiUser {
    Drai token;

    constructor(Drai token_) public {
        token = token_;
    }

    function doTransferFrom(address from, address to, uint256 amount) public returns (bool) {
        return token.transferFrom(from, to, amount);
    }

    function doTransfer(address to, uint256 amount) public returns (bool) {
        return token.transfer(to, amount);
    }

    function doApprove(address recipient, uint256 amount) public returns (bool) {
        return token.approve(recipient, amount);
    }

    function doAllowance(address owner, address spender) public view returns (uint256) {
        return token.allowance(owner, spender);
    }

    function doBalanceOf(address who) public view returns (uint256) {
        return token.balanceOf(who);
    }

    function doApprove(address guy) public returns (bool) {
        return token.approve(guy, uint256(-1));
    }
}

contract TokenTest is DraiTest {
    address user1;
    address user2;
    address self;

    uint256 constant initialBalanceThis = 20 ether;

    function setUp() public override {
        super.setUp();
        drai.join(address(this), initialBalanceThis);
        user1 = address(new DraiUser(drai));
        user2 = address(new DraiUser(drai));
        self = address(this);
    }

    function testSetupPrecondition() public {
        assertEq(drai.balanceOf(self), initialBalanceThis);
    }

    function testTransferCost() public {
        drai.transfer(address(0), 10);
    }

    function testAllowanceStartsAtZero() public {
        assertEq(drai.allowance(user1, user2), 0);
    }

    function testValidTransfers() public {
        uint256 sentAmount = 250;
        emit log_named_address("drai11111", address(drai));
        drai.transfer(user2, sentAmount);
        assertEq(drai.balanceOf(user2), sentAmount);
        assertEq(drai.balanceOf(self), initialBalanceThis - sentAmount);
    }

    function testFailWrongAccountTransfers() public {
        uint256 sentAmount = 250;
        drai.transferFrom(user2, self, sentAmount);
    }

    function testFailInsufficientFundsTransfers() public {
        uint256 sentAmount = 250;
        drai.transfer(user1, initialBalanceThis - sentAmount);
        drai.transfer(user2, sentAmount + 1);
    }

    function testApproveSetsAllowance() public {
        emit log_named_address("Test", self);
        emit log_named_address("Drai", address(drai));
        emit log_named_address("Me", self);
        emit log_named_address("User 2", user2);
        drai.approve(user2, 25);
        assertEq(drai.allowance(self, user2), 25);
    }

    function testChargesAmountApproved() public {
        uint256 amountApproved = 20;
        drai.approve(user2, amountApproved);
        assertTrue(DraiUser(user2).doTransferFrom(self, user2, amountApproved));
        assertEq(drai.balanceOf(self), initialBalanceThis - amountApproved);
    }

    function testFailTransferWithoutApproval() public {
        drai.transfer(user1, 50);
        drai.transferFrom(user1, self, 1);
    }

    function testFailChargeMoreThanApproved() public {
        drai.transfer(user1, 50);
        DraiUser(user1).doApprove(self, 20);
        drai.transferFrom(user1, self, 21);
    }
    function testTransferFromSelf() public {
        drai.transferFrom(self, user1, 50);
        assertEq(drai.balanceOf(user1), 50);
    }
    function testFailTransferFromSelfNonArbitrarySize() public {
        // you shouldn't be able to evade balance checks by transferring to yourself
        drai.transferFrom(self, self, drai.balanceOf(self) + 1);
    }
    function testFailUntrustedTransferFrom() public {
        assertEq(drai.allowance(self, user2), 0);
        DraiUser(user1).doTransferFrom(self, user2, 200);
    }
    function testTrusting() public {
        assertEq(drai.allowance(self, user2), 0);
        drai.approve(user2, uint256(-1));
        assertEq(drai.allowance(self, user2), uint256(-1));
        drai.approve(user2, 0);
        assertEq(drai.allowance(self, user2), 0);
    }
    function testTrustedTransferFrom() public {
        drai.approve(user1, uint256(-1));
        DraiUser(user1).doTransferFrom(self, user2, 200);
        assertEq(drai.balanceOf(user2), 200);
    }
    function testApproveWillModifyAllowance() public {
        assertEq(drai.allowance(self, user1), 0);
        assertEq(drai.balanceOf(user1), 0);
        drai.approve(user1, 1000);
        assertEq(drai.allowance(self, user1), 1000);
        DraiUser(user1).doTransferFrom(self, user1, 500);
        assertEq(drai.balanceOf(user1), 500);
        assertEq(drai.allowance(self, user1), 500);
    }
    function testApproveWillNotModifyAllowance() public {
        assertEq(drai.allowance(self, user1), 0);
        assertEq(drai.balanceOf(user1), 0);
        drai.approve(user1, uint256(-1));
        assertEq(drai.allowance(self, user1), uint256(-1));
        DraiUser(user1).doTransferFrom(self, user1, 1000);
        assertEq(drai.balanceOf(user1), 1000);
        assertEq(drai.allowance(self, user1), uint256(-1));
    }
    function testDraiAddress() public {
        // The drai address generated by hevm used for signature generation testing
        assertEq(address(drai), address(0xCe71065D4017F316EC606Fe4422e11eB2c47c246));
    }
}