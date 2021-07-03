pragma solidity ^0.6.7;

import "ds-test/test.sol";
import "./Drai.sol";

interface Hevm {
    // Sets block timestamp to `x`
    function warp(uint256 x) external;
    // Sets slot `loc` of contract `c` to value `val`
    function store(address c, bytes32 loc, bytes32 val) external;
    // Generates address derived from private key `sk`
    function addr(uint sk) external returns (address addr);
    // Signs `digest` with private key `sk` (WARNING: this is insecure as it leaks the private key)
    function sign(uint sk, bytes32 digest) external returns (uint8 v, bytes32 r, bytes32 s);
}

interface RaiLike is CoinLike {
    function approve(address, uint256) external returns (bool);
    function allowance(address, address) external returns (uint256);
}

contract DraiTest is DSTest {
    // --- Data ---
    uint256 constant RAY = 10 ** 27;
    uint256 initialRedemptionPrice = RAY;

    // Contracts
    Hevm hevm = Hevm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);
    OracleRelayerLike public oracleRelayer = OracleRelayerLike(0x4ed9C0dCa0479bC64d8f4EB3007126D5791f7851);
    RaiLike rai = RaiLike(0x03ab458634910AaD20eF5f1C8ee96F1D6ac54919);
    Drai drai;

    // Storage slot locations used for updating OracleRelayer's redemption price info
    bytes32 redemptionPriceSlot = bytes32(uint256(4));
    bytes32 redemptionRateSlot = bytes32(uint256(5));
    bytes32 redemptionPriceUpdateTimeSlot = bytes32(uint256(6));

    function setUp() public virtual {
        drai = new Drai();

        // Give us 100 RAI to work with
        uint256 initialRaiBalance = 100 ether;
        setRaiBalance(address(this), initialRaiBalance);
        rai.approve(address(drai), uint256(-1));
        assertEq(rai.balanceOf(address(this)), initialRaiBalance);
        assertEq(rai.allowance(address(this), address(drai)), uint256(-1));

        // Set initial redemption price to 1, so minting is 1:1 by default
        setRaiRedemptionPrice(initialRedemptionPrice);
        assertEq(oracleRelayer.redemptionPrice(), RAY);
    }

    function setRaiBalance(address dst, uint256 wad) public {
        bytes32 slot = keccak256(abi.encode(dst, 6)); // get storage slot
        hevm.store(address(rai), slot, bytes32(wad)); // set balance of `dst` to `wad` RAI
    }

    function setRaiRedemptionPrice(uint256 price) public {
        // Sets the redemption price to price. Also sets the internal redemption rate to 1 and sets the last update
        // time to now, so no additional rate accrues when redemptionPrice() is called
        hevm.store(address(oracleRelayer), redemptionPriceSlot, bytes32(price));
        hevm.store(address(oracleRelayer), redemptionRateSlot, bytes32(RAY));
        hevm.store(address(oracleRelayer), redemptionPriceUpdateTimeSlot, bytes32(now));
    }

    function setRaiRedemptionParams(uint256 price, uint256 rate, uint256 timestamp) public {
        require(timestamp >= now, "setRaiRedemptionParams/bad-timestamp");
        hevm.store(address(oracleRelayer), redemptionPriceSlot, bytes32(price));
        hevm.store(address(oracleRelayer), redemptionRateSlot, bytes32(rate));
        hevm.store(address(oracleRelayer), redemptionPriceUpdateTimeSlot, bytes32(timestamp));
        hevm.warp(timestamp); // required to ensure current block time matches timestamp
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
    // Test users
    address user1;
    address user2;

    // Parameters for this contract
    address self = address(this);
    uint256 constant initialBalanceThis = 20 ether;

    // Parameters for `permit` tests
    uint256 skOwner = 1; // owner's private key, used for signing
    address owner = hevm.addr(skOwner); // address derived from `skOwner`
    address spender = address(2); // address of user who `owner` is approving
    uint256 value = 40; // amount to approve `spender` for
    uint256 deadline = 5000000000; // timestamp far in the future
    uint256 nonce = 0;

    function setUp() public override {
        super.setUp();
        hevm.warp(deadline - 52 weeks); // don't warp to deadline to allow room to warp more before permit deadline

        // Use our RAI balance to mint DRAI
        drai.join(address(this), initialBalanceThis);

        // Setup test users
        user1 = address(new DraiUser(drai));
        user2 = address(new DraiUser(drai));
    }

    // --- Standard ERC-20 functionality tests ---
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

    // --- Permit tests ---

    // Helper method to return an ERC-2612 `permit` digest for the `owner` to sign
    function getDigest(address owner_, address spender_, uint256 value_, uint256 nonce_, uint256 deadline_) public returns (bytes32) {
        return keccak256(
            abi.encodePacked(
                '\x19\x01',
                drai.DOMAIN_SEPARATOR(),
                keccak256(abi.encode(drai.PERMIT_TYPEHASH(), owner_, spender_, value_, nonce_, deadline_))
            )
        );
    }

    // Helper method to return a valid `permit` signature signed by this contract's `owner` address
    function getValidPermitSignature() public returns (uint8, bytes32, bytes32) {
        bytes32 digest = getDigest(owner, spender, value, nonce, deadline);
        (uint8 v, bytes32 r, bytes32 s) = hevm.sign(skOwner, digest);
        return (v, r, s);
    }

    function testDraiAddress() public {
        // The drai address generated by hevm
        assertEq(address(drai), address(0xCe71065D4017F316EC606Fe4422e11eB2c47c246));
    }

    function testTypehash() public {
        assertEq(drai.PERMIT_TYPEHASH(), 0x6e71edae12b1b97f4d1f60370fef10105fa2faae0126114a169c64845d6126c9);
    }

    function testDomain_Separator() public {
        assertEq(drai.DOMAIN_SEPARATOR(), 0xcea1dd431eeb6d317d1fe6b277c67b97f750a6d1d5865d1adc3ca4e55fc5e44b);
    }

    function testPermit() public {
        assertEq(drai.allowance(owner, spender), 0);
        assertEq(drai.nonces(owner), 0);

        (uint8 v, bytes32 r, bytes32 s) = getValidPermitSignature();
        drai.permit(owner, spender, value, deadline, v, r, s);

        assertEq(drai.allowance(owner, spender), value);
        assertEq(drai.nonces(owner), 1);
    }

    function testFailPermitBadNonce() public {
        // Test for failure when using the wrong nonce value on the digest
        bytes32 digest = getDigest(owner, spender, value, 123, deadline);
        (uint8 v, bytes32 r, bytes32 s) = hevm.sign(skOwner, digest);
        drai.permit(owner, spender, value, deadline, v, r, s);
    }

    function testFailPermitBadDeadline() public {
        // Test for failure when passing in the wrong deadline to permit
        (uint8 v, bytes32 r, bytes32 s) = getValidPermitSignature();
        drai.permit(owner, spender, value, deadline + 1 hours, v, r, s);
    }
    
    function testFailPermitPastDeadline() public {
        // Test for failure when waiting until after the deadline to submit the permit
        (uint8 v, bytes32 r, bytes32 s) = getValidPermitSignature();
        hevm.warp(deadline + 1 weeks);
        drai.permit(owner, spender, value, deadline, v, r, s);
    }

    function testFailReplay() public {
        // Test for failure when replaying an already used signature
        (uint8 v, bytes32 r, bytes32 s) = getValidPermitSignature();
        drai.permit(owner, spender, value, deadline, v, r, s);
        drai.permit(owner, spender, value, deadline, v, r, s);
    }

    // --- Dollar peg tests ---
    function assertRedemptionParamsInit() public {
        assertEq(drai.lastRedemptionPrice(), initialRedemptionPrice);
        assertEq(drai.lastRedemptionRate(), RAY);
        assertEq(drai.lastRedemptionPriceUpdateTime(), now);
    }

    function assertRedemptionParamsNew(uint256 price, uint256 rate, uint256 timestamp) public {
        assertEq(drai.lastRedemptionPrice(), price);
        assertEq(drai.lastRedemptionRate(), rate);
        assertEq(drai.lastRedemptionPriceUpdateTime(), timestamp);
    }

    function testRedemptionPriceUpdateOnConstruction() public {
        assertRedemptionParamsInit();
    }
    
    function testRedemptionPriceUpdateOnTransfer() public {
        // Ensure cached redemption data is updated on transfer
        assertRedemptionParamsInit();
        uint256 newTime = now + 1 weeks;
        setRaiRedemptionParams(123, 456, newTime);
        drai.transfer(self, 0);
        assertRedemptionParamsNew(123, 456, newTime);
    }
    
    function testRedemptionPriceUpdateOnTransferFrom() public {
        // Ensure cached redemption data is updated on transferFrom
        assertRedemptionParamsInit();
        uint256 newTime = now + 1 weeks;
        setRaiRedemptionParams(123, 456, newTime);
        drai.transferFrom(self, self, 0);
        assertRedemptionParamsNew(123, 456, newTime);
    }
    
    function testRedemptionPriceUpdateOnApprove() public {
        // Ensure cached redemption data is updated on approve
        assertRedemptionParamsInit();
        uint256 newTime = now + 1 weeks;
        setRaiRedemptionParams(123, 456, newTime);
        drai.approve(self, 0);
        assertRedemptionParamsNew(123, 456, newTime);
    }
    
    function testRedemptionPriceUpdateOnPermit() public {
        // Ensure cached redemption data is updated on permit
        assertRedemptionParamsInit();
        uint256 newTime = now + 1 weeks;
        setRaiRedemptionParams(123, 456, newTime);
        (uint8 v, bytes32 r, bytes32 s) = getValidPermitSignature();
        drai.permit(owner, spender, value, deadline, v, r, s);
        assertRedemptionParamsNew(123, 456, newTime);
    }

    function testRedemptionPriceUpdateOnJoin() public {
        // Ensure cached redemption data is updated on join
        assertRedemptionParamsInit();
        uint256 newTime = now + 1 weeks;
        setRaiRedemptionParams(123, 456, newTime);
        drai.join(self, 0);
        assertRedemptionParamsNew(123, 456, newTime);
    }
    
    function testRedemptionPriceUpdateOnExit() public {
        // Ensure cached redemption data is updated on exit
        assertRedemptionParamsInit();
        uint256 newTime = now + 1 weeks;
        setRaiRedemptionParams(123, 456, newTime);
        drai.exit(self, 0);
        assertRedemptionParamsNew(123, 456, newTime);
    }

    function testComputeRedemptionPrice() public {
        // TODO check user's balance, update redemption data, check balance again
    }
    
    function testComputeRedemptionPriceAccuracy() public {
        // TODO compute redemption price, read most recent redemption price, and compare the two
    }

    function testBalanceOf() public {
        // TODO check user's balance, update redemption price, check balance again
    }

    function testTotalSupply() public {
        // TODO check total supply, update redemption price, check balance again
    }

    function testJoin() public {
        // TODO check balance before and after joining based on redemption price
    }

    function testExit() public {
        // TODO check balance before and after exiting based on redemption price
    }

    function testFailExitInsufficientBalance() public {
        // TODO exit fails with insufficient balance
        assertTrue(false);
    }

    function testFailExitInsufficientAllowance() public {
        // TODO exit fails with insufficient allowance
        assertTrue(false);
    }
}