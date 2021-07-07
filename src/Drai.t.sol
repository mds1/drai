pragma solidity ^0.6.7;

import "ds-test/test.sol";
import "./Drai.sol";

interface Hevm {
    // Sets block timestamp to `x`
    function warp(uint256 x) external view;
    // Sets slot `loc` of contract `c` to value `val`
    function store(address c, bytes32 loc, bytes32 val) external view;
    // Reads the slot `loc` of contract `c`
    function load(address c, bytes32 loc) external view returns (bytes32 val);
    // Generates address derived from private key `sk`
    function addr(uint256 sk) external view returns (address _addr);
    // Signs `digest` with private key `sk` (WARNING: this is insecure as it leaks the private key)
    function sign(uint256 sk, bytes32 digest) external view returns (uint8 v, bytes32 r, bytes32 s);
}

interface RaiLike is CoinLike {
    function approve(address, uint256) external returns (bool);
    function allowance(address, address) external returns (uint256);
}

contract DraiUser {
    Drai drai;

    constructor(Drai _drai) public {
        drai = _drai;
    }

    function doTransferFrom(address from, address to, uint256 amount) public returns (bool) {
        return drai.transferFrom(from, to, amount);
    }

    function doApprove(address recipient, uint256 amount) public returns (bool) {
        return drai.approve(recipient, amount);
    }
}

// Tests basic setup and initialization of the contract and test suite
contract DraiTest is DSTest {
    // --- Data ---
    uint256 constant RAY = 10 ** 27;
    uint256 initialRedemptionPrice = RAY;

    // Contracts
    Hevm hevm = Hevm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);
    OracleRelayerLike public oracleRelayer = OracleRelayerLike(0x4ed9C0dCa0479bC64d8f4EB3007126D5791f7851);
    RaiLike rai = RaiLike(0x03ab458634910AaD20eF5f1C8ee96F1D6ac54919);
    Drai drai;

    // --- Setup ---
    function setUp() public virtual {
        drai = new Drai();
    }

    // --- Basic initialization tests ---
    function testFailBasicSanity() public {
        assertTrue(false);
    }

    function testBasicSanity() public {
        assertTrue(true);
    }

    function testTokenProperties() public {
        assertEq(drai.name(), "Drai");
        assertEq(drai.symbol(), "DRAI");
        assertEq(drai.version(), "1");
        assertEq(uint256(drai.decimals()), uint256(18));
    }

    function testDraiAddress() public {
        // The drai address generated by HEVM
        assertEq(address(drai), address(0xCe71065D4017F316EC606Fe4422e11eB2c47c246));
    }
}

contract TokenTest is DraiTest {
    // --- Data ---
    // Test users that will later be of type DraiUser
    address user1;
    address user2;

    // Parameters for this contract
    address self = address(this);
    uint256 constant initialDraiBalance = uint128(-1) / 2; // to be minted in setUp at 1:1 ratio
    uint256 initialRaiBalance; // set after minting Drai

    // Parameters for `permit` tests
    uint256 skOwner = 1; // owner's private key, used for signing
    address owner = hevm.addr(skOwner); // address derived from `skOwner`
    address spender = address(2); // address of user who `owner` is approving
    uint256 value = 40; // amount to approve `spender` for
    uint256 deadline = 5000000000; // timestamp far in the future
    uint256 nonce = 0;

    // Storage slot locations used for updating OracleRelayer's redemption price info
    bytes32 redemptionPriceSlot = bytes32(uint256(4));
    bytes32 redemptionRateSlot = bytes32(uint256(5));
    bytes32 redemptionPriceUpdateTimeSlot = bytes32(uint256(6));

    // --- Helpers ---
    // Rai balances and redemption price parameters are uint128 to avoid overflow when fuzzing

    function setRaiBalance(address dst, uint256 amount) public view {
        bytes32 slot = keccak256(abi.encode(dst, 6)); // get storage slot
        hevm.store(address(rai), slot, bytes32(amount)); // set balance of `dst` to `amount` RAI
    }

    function setRaiRedemptionPrice(uint256 price) public view {
        // Sets the redemption price to price. Also sets the internal redemption rate to 1 and sets the last update
        // time to now, so no additional rate accrues when redemptionPrice() is called
        hevm.store(address(oracleRelayer), redemptionPriceSlot, bytes32(price));
        hevm.store(address(oracleRelayer), redemptionRateSlot, bytes32(RAY));
        hevm.store(address(oracleRelayer), redemptionPriceUpdateTimeSlot, bytes32(now));
    }

    function isRedemptionPriceZero() public view returns (bool) {
        return drai.lastRedemptionPrice() == 0 
            || drai.computeRedemptionPrice() == 0
            || uint256(hevm.load(address(oracleRelayer), redemptionPriceSlot)) == 0;
    }

    function setRaiRedemptionParams(uint256 price, uint256 rate, uint256 timestamp) public view {
        require(timestamp >= now, "setRaiRedemptionParams/bad-timestamp");
        hevm.store(address(oracleRelayer), redemptionPriceSlot, bytes32(price));
        hevm.store(address(oracleRelayer), redemptionRateSlot, bytes32(rate));
        hevm.store(address(oracleRelayer), redemptionPriceUpdateTimeSlot, bytes32(timestamp));
        hevm.warp(timestamp); // required to ensure current block time matches timestamp
    }

    // Returns an ERC-2612 `permit` digest for the `owner` to sign
    function getDigest(address owner_, address spender_, uint256 value_, uint256 nonce_, uint256 deadline_) public view returns (bytes32) {
        return keccak256(
            abi.encodePacked(
                '\x19\x01',
                drai.DOMAIN_SEPARATOR(),
                keccak256(abi.encode(drai.PERMIT_TYPEHASH(), owner_, spender_, value_, nonce_, deadline_))
            )
        );
    }

    // Returns a valid `permit` signature signed by this contract's `owner` address
    function getValidPermitSignature() public view returns (uint8, bytes32, bytes32) {
        bytes32 digest = getDigest(owner, spender, value, nonce, deadline);
        (uint8 v, bytes32 r, bytes32 s) = hevm.sign(skOwner, digest);
        return (v, r, s);
    }

    // Asserts that redemption parameters set on the Drai contract equal the passed in values
    function assertRedemptionParamsNew(uint256 price, uint256 rate, uint256 timestamp) public {
        assertEq(drai.lastRedemptionPrice(), price);
        assertEq(drai.lastRedemptionRate(), rate);
        assertEq(drai.lastRedemptionPriceUpdateTime(), timestamp);
    }

    // --- Setup ---
    function setUp() public override {
        super.setUp();
        hevm.warp(deadline - 52 weeks); // don't warp to deadline to allow room to warp more before permit deadline

        // Give us 2^128-1 RAI to work with
        uint128 balanceToSet = uint128(-1);
        setRaiBalance(address(this), balanceToSet);
        assertEq(rai.balanceOf(address(this)), balanceToSet);
        rai.approve(address(drai), uint256(-1));
        assertEq(rai.allowance(address(this), address(drai)), uint256(-1));

        // Set initial redemption price to 1, so minting is 1:1 by default
        setRaiRedemptionPrice(initialRedemptionPrice);
        assertEq(oracleRelayer.redemptionPrice(), RAY);

        // Use half our RAI balance to mint DRAI
        drai.mint(self, initialDraiBalance);
        initialRaiBalance = rai.balanceOf(self);

        // Setup test users
        user1 = address(new DraiUser(drai));
        user2 = address(new DraiUser(drai));
    }

    // --- Test standard ERC-20 functionality ---
    function testSetupPrecondition() public {
        assertEq(drai.balanceOf(self), initialDraiBalance);
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
        assertEq(drai.balanceOf(self), initialDraiBalance - sentAmount);
    }

    function testFailWrongAccountTransfers() public {
        uint256 sentAmount = 250;
        drai.transferFrom(user2, self, sentAmount);
    }

    function testFailInsufficientFundsTransfers() public {
        uint256 sentAmount = 250;
        drai.transfer(user1, initialDraiBalance - sentAmount);
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
        assertEq(drai.balanceOf(self), initialDraiBalance - amountApproved);
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
    function testPermitPrecondition() public {
        assertEq(drai.allowance(owner, spender), 0);
        assertEq(drai.nonces(owner), 0);
    }

    function testTypehash() public {
        assertEq(drai.PERMIT_TYPEHASH(), 0x6e71edae12b1b97f4d1f60370fef10105fa2faae0126114a169c64845d6126c9);
    }

    function testDomain_Separator() public {
        assertEq(drai.DOMAIN_SEPARATOR(), 0xcea1dd431eeb6d317d1fe6b277c67b97f750a6d1d5865d1adc3ca4e55fc5e44b);
    }

    function testPermit() public {
        (uint8 v, bytes32 r, bytes32 s) = getValidPermitSignature();
        drai.permit(owner, spender, value, deadline, v, r, s);
        assertEq(drai.allowance(owner, spender), value);
        assertEq(drai.nonces(owner), 1);
    }

    function testFailPermitBadNonce(uint256 _nonce) public {
        // Test for failure when using the wrong _nonce value on the digest
        if (_nonce == 0) _nonce += 1; // nonce should be zero, so bump it to 1 if we get zero
        bytes32 digest = getDigest(owner, spender, value, _nonce, deadline);
        (uint8 v, bytes32 r, bytes32 s) = hevm.sign(skOwner, digest);
        drai.permit(owner, spender, value, deadline, v, r, s);
    }

    function testFailPermitBadDeadline(uint128 extraTime) public {
        // Test for failure when passing in the wrong deadline to permit
        (uint8 v, bytes32 r, bytes32 s) = getValidPermitSignature();
        drai.permit(owner, spender, value, deadline + extraTime + 1, v, r, s); // add 1 to ensure deadline + extraTime > deadline
    }

    function testFailPermitPastDeadline(uint128 extraTime) public {
        // Test for failure when waiting until after the deadline to submit the permit
        (uint8 v, bytes32 r, bytes32 s) = getValidPermitSignature();
        hevm.warp(deadline + extraTime + 1); // add 1 to ensure we're past deadline when extraTime = 0
        drai.permit(owner, spender, value, deadline, v, r, s);
    }

    function testFailReplay() public {
        // Test for failure when replaying an already used signature
        (uint8 v, bytes32 r, bytes32 s) = getValidPermitSignature();
        drai.permit(owner, spender, value, deadline, v, r, s);
        drai.permit(owner, spender, value, deadline, v, r, s);
    }

    // --- Test redemption parameters required to maintain dollar peg ---
    function testDollarPegPrecondition() public {
        assertEq(rai.balanceOf(self), initialRaiBalance);
        assertEq(drai.balanceOf(self), initialDraiBalance);
        // these next asserts also test that the constructor correctly initialized redemption data
        assertEq(drai.lastRedemptionPrice(), initialRedemptionPrice);
        assertEq(drai.lastRedemptionRate(), RAY);
        assertEq(drai.lastRedemptionPriceUpdateTime(), now);
    }

    function testRedemptionPriceUpdateOnTransfer(uint128 redemptionPrice, uint128 redemptionRate, uint128 extraTime) public {
        // Ensure cached redemption data is updated on transfer
        uint256 newTime = now + extraTime; // add time to `now` to avoid going into the past
        setRaiRedemptionParams(redemptionPrice, redemptionRate, newTime);
        if (isRedemptionPriceZero()) return; // avoid divide by zero conditions
        drai.transfer(self, 0);
        assertRedemptionParamsNew(redemptionPrice, redemptionRate, newTime);
    }

    function testRedemptionPriceUpdateOnTransferFrom(uint128 redemptionPrice, uint128 redemptionRate, uint128 extraTime) public {
        // Ensure cached redemption data is updated on transferFrom
        uint256 newTime = now + extraTime;
        setRaiRedemptionParams(redemptionPrice, redemptionRate, newTime);
        if (isRedemptionPriceZero()) return;
        drai.transferFrom(self, self, 0);
        assertRedemptionParamsNew(redemptionPrice, redemptionRate, newTime);
    }

    function testRedemptionPriceUpdateOnApprove(uint128 redemptionPrice, uint128 redemptionRate, uint128 extraTime) public {
        // Ensure cached redemption data is updated on approve
        uint256 newTime = now + extraTime;
        setRaiRedemptionParams(redemptionPrice, redemptionRate, newTime);
        if (isRedemptionPriceZero()) return;
        drai.approve(self, 0);
        assertRedemptionParamsNew(redemptionPrice, redemptionRate, newTime);
    }

    function testRedemptionPriceUpdateOnPermit(uint128 redemptionPrice, uint128 redemptionRate, uint24 extraTime) public {
        // Ensure cached redemption data is updated on permit
        uint256 newTime = now + extraTime; // smaller extra time value so permit does not expire
        setRaiRedemptionParams(redemptionPrice, redemptionRate, newTime);
        (uint8 v, bytes32 r, bytes32 s) = getValidPermitSignature();
        if (isRedemptionPriceZero()) return;
        drai.permit(owner, spender, value, deadline, v, r, s);
        assertRedemptionParamsNew(redemptionPrice, redemptionRate, newTime);
    }

    function testRedemptionPriceUpdateOnMint(uint128 redemptionPrice, uint128 redemptionRate, uint128 extraTime) public {
        // Ensure cached redemption data is updated on mint
        uint256 newTime = now + extraTime;
        setRaiRedemptionParams(redemptionPrice, redemptionRate, newTime);
        if (isRedemptionPriceZero()) return;
        drai.mint(self, 0);
        assertRedemptionParamsNew(redemptionPrice, redemptionRate, newTime);
    }

    function testRedemptionPriceUpdateOnRedeem(uint128 redemptionPrice, uint128 redemptionRate, uint128 extraTime) public {
        // Ensure cached redemption data is updated on redeem
        uint256 newTime = now + extraTime;
        setRaiRedemptionParams(redemptionPrice, redemptionRate, newTime);
        if (isRedemptionPriceZero()) return;
        drai.redeem(self, self, 0);
        assertRedemptionParamsNew(redemptionPrice, redemptionRate, newTime);
    }

    function testComputeRedemptionPrice(uint128 redemptionPrice, uint128 redemptionRate, uint128 extraTime) public {
        // Ensure DRAI's initial value matches OracleRelayer's value
        assertEq(drai.computeRedemptionPrice(), RAY);
        assertEq(drai.computeRedemptionPrice(), oracleRelayer.redemptionPrice());

        // Change redemption price and ensure DRAI still matches OracleRelayer
        setRaiRedemptionPrice(redemptionPrice);
        drai.updateRedemptionPrice(); // poke DRAI to update it's cached values
        if (isRedemptionPriceZero()) return;
        assertEq(drai.computeRedemptionPrice(), redemptionPrice);
        assertEq(drai.computeRedemptionPrice(), oracleRelayer.redemptionPrice());

        // Change all 3 parameters and ensure DRAI still matches OracleRelayer
        uint256 newTime = now + extraTime;
        setRaiRedemptionParams(redemptionPrice, redemptionRate, newTime);
        drai.updateRedemptionPrice(); // poke DRAI to update it's cached values
        if (isRedemptionPriceZero()) return;
        assertEq(drai.computeRedemptionPrice(), oracleRelayer.redemptionPrice());
    }

    function testBalanceOf(uint128 redemptionPrice) public {
        // Initial check minted at redemption price of 1
        assertEq(drai.balanceOf(self), initialDraiBalance);
        // Update redemption price
        setRaiRedemptionPrice(redemptionPrice);
        // Still should have same amount of DRAI until poked
        assertEq(drai.balanceOf(self), initialDraiBalance);
        // Poke and check new value
        drai.updateRedemptionPrice();
        assertEq(drai.balanceOf(self), redemptionPrice * initialDraiBalance / RAY);
    }

    function testTotalSupply(uint128 redemptionPrice) public {
        // Initial check minted at redemption price of 1
        assertEq(drai.totalSupply(), initialDraiBalance);
        // Update redemption price
        setRaiRedemptionPrice(redemptionPrice);
        // Still should have same amount of DRAI until poked
        assertEq(drai.totalSupply(), initialDraiBalance);
        // Poke and check new value
        drai.updateRedemptionPrice();
        assertEq(drai.totalSupply(), redemptionPrice * initialDraiBalance / RAY);
    }

    function testMintSelf(uint128 redemptionPrice, uint64 mintAmount) public {
        // Update redemption price
        setRaiRedemptionPrice(redemptionPrice);
        // Mint
        drai.mint(self, mintAmount);
        assertEq(rai.balanceOf(self), initialRaiBalance - mintAmount);
        assertEq(drai.balanceOf(self), redemptionPrice * (initialDraiBalance + mintAmount) / RAY);
    }

    function testMintOther(uint128 redemptionPrice, uint64 mintAmount) public {
        // Update redemption price
        setRaiRedemptionPrice(redemptionPrice);
        // Mint
        address to = address(1); // this user has no initial balances
        drai.mint(to, mintAmount);
        assertEq(rai.balanceOf(self), initialRaiBalance - mintAmount);
        assertEq(drai.balanceOf(to), uint256(redemptionPrice) * mintAmount / RAY); // need a uint256 in here to avoid overflow
    }

    // TODO fuzz test redeem tests -- rounding errors somewhere?
    function testRedeem() public {
        // Update redemption price
        setRaiRedemptionPrice(RAY / 2);
        // Redeem
        uint256 redeemAmount = 5 ether; // in DRAI
        drai.redeem(self, self, redeemAmount);
        assertEq(rai.balanceOf(self), initialRaiBalance + redeemAmount * 2);
        assertEq(drai.balanceOf(self), initialDraiBalance / 2 - redeemAmount);
    }

    function testRedeemToDst() public {
        // Update redemption price
        setRaiRedemptionPrice(RAY / 2);
        // Redeem
        uint256 redeemAmount = 5 ether; // in DRAI
        address dst = address(5);
        drai.redeem(self, dst, redeemAmount);
        assertEq(rai.balanceOf(dst), redeemAmount * 2);
        assertEq(drai.balanceOf(self), initialDraiBalance / 2 - redeemAmount);
    }

    function testRedeemUnderlying() public {
        // Update redemption price
        setRaiRedemptionPrice(RAY * 2);
        // Redeem
        uint256 redeemAmount = 5 ether; // in RAI
        drai.redeemUnderlying(self, self, redeemAmount);
        assertEq(rai.balanceOf(self), initialRaiBalance + redeemAmount);
        assertEq(drai.balanceOf(self), initialDraiBalance * 2 - redeemAmount * 2);
    }

    function testRedeemMaxUint() public {
        // Update redemption price
        setRaiRedemptionPrice(RAY * 12);
        // Redeem
        uint256 redeemAmount = uint256(-1); // in DRAI
        drai.redeem(self, self, redeemAmount);
        assertEq(rai.balanceOf(self), uint128(-1)); // balanceToSet = uint128(-1)
        assertEq(drai.balanceOf(self), 0);
    }

    function testRedeemUnderlyingMaxUint() public {
        // Update redemption price
        setRaiRedemptionPrice(RAY * 12);
        // Redeem
        uint256 redeemAmount = uint256(-1); // in RAI
        drai.redeemUnderlying(self, self, redeemAmount);
        assertEq(rai.balanceOf(self), uint128(-1)); // balanceToSet = uint128(-1)
        assertEq(drai.balanceOf(self), 0);
    }

    function testFailRedeemInsufficientBalance() public {
        // redeem fails with insufficient-balance
        drai.redeem(self, self, uint128(-1));
    }

    function testFailRedeemUnderlyingInsufficientBalance() public {
        // redeemUnderlying fails with insufficient-balance
        drai.redeemUnderlying(self, self, uint128(-1));
    }

    function testFailRedeemInsufficientAllowance() public {
        // redeem fails with insufficient-allowance
        address user = address(1);
        drai.transfer(user, drai.balanceOf(self));
        drai.redeem(user, self, 1);
    }

    function testFailRedeemUnderlyingInsufficientAllowance() public {
        // redeemUnderlying fails with insufficient-allowance
        address user = address(1);
        drai.transfer(user, drai.balanceOf(self));
        rai.transfer(user, rai.balanceOf(self));
        drai.redeem(user, self, 1);
    }
}