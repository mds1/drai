pragma solidity ^0.6.7;

interface CoinLike {
    function transferFrom(address,address,uint256) external returns (bool);
    function transfer(address,uint256) external returns (bool);
    function balanceOf(address) external returns (uint256);
}

interface OracleRelayerLike {
    // Fetches the latest redemption price by first updating it (returns a RAY)
    function redemptionPrice() external returns (uint256);
    // The force that changes the system users' incentives by changing the redemption price (returns a RAY)
    function redemptionRate() external view returns (uint256);
    // Last time when the redemption price was changed
    function redemptionPriceUpdateTime() external view returns (uint256);
}

contract Drai {
    // -- Data --
    CoinLike public raiToken = CoinLike(0x03ab458634910AaD20eF5f1C8ee96F1D6ac54919);
    OracleRelayerLike public oracleRelayer = OracleRelayerLike(0x4ed9C0dCa0479bC64d8f4EB3007126D5791f7851);

    // Because RAI's OracleRelayer does not expose the last redemption price, we must caclulate it as
    // needed to avoid breaking conformity to ERC-20 standards. Doing this requires us to cache the
    // redemption price, redemption rate, and update time ourselves
    uint256 public lastRedemptionPrice;
    uint256 public lastRedemptionRate;
    uint256 public lastRedemptionPriceUpdateTime;

    // --- ERC20 Data ---
    string  public constant name     = "Drai";
    string  public constant symbol   = "DRAI";
    string  public constant version  = "1";
    uint8   public constant decimals = 18;
    uint256 public totalSupplyRai;

    mapping (address => uint256)                      public balanceOfRai;
    mapping (address => mapping (address => uint256)) public   allowanceRai;
    mapping (address => uint256)                      public   nonces;

    event Approval(address indexed src, address indexed guy, uint256 wad);
    event Transfer(address indexed src, address indexed dst, uint256 wad);

    // --- Math ---
    uint256 constant RAY = 10 ** 27;
    function addition(uint256 x, uint256 y) internal pure returns (uint256 z) {
        require((z = x + y) >= x, "drai/add-overflow");
    }
    function subtract(uint256 x, uint256 y) internal pure returns (uint256 z) {
        require((z = x - y) <= x, "drai/sub-underflow");
    }
    function multiply(uint256 x, uint256 y) internal pure returns (uint256 z) {
        require(y == 0 || (z = x * y) / y == x, "drai/mul-overflow");
    }
    function rmultiply(uint256 x, uint256 y) internal pure returns (uint256 z) {
        // always rounds down
        z = multiply(x, y) / RAY;
    }
    function rdivide(uint256 x, uint256 y) internal pure returns (uint256 z) {
        require(y > 0, "drai/rdivide-by-zero");
        z = multiply(x, RAY) / y;
    }
    function rpower(uint256 x, uint256 n, uint256 base) internal pure returns (uint256 z) {
        assembly {
            switch x case 0 {switch n case 0 {z := base} default {z := 0}}
            default {
                switch mod(n, 2) case 0 { z := base } default { z := x }
                let half := div(base, 2)  // for rounding.
                for { n := div(n, 2) } n { n := div(n,2) } {
                    let xx := mul(x, x)
                    if iszero(eq(div(xx, x), x)) { revert(0,0) }
                    let xxRound := add(xx, half)
                    if lt(xxRound, xx) { revert(0,0) }
                    x := div(xxRound, base)
                    if mod(n,2) {
                        let zx := mul(z, x)
                        if and(iszero(iszero(x)), iszero(eq(div(zx, x), z))) { revert(0,0) }
                        let zxRound := add(zx, half)
                        if lt(zxRound, zx) { revert(0,0) }
                        z := div(zxRound, base)
                    }
                }
            }
        }
    }

    // --- EIP712 niceties ---
    bytes32 public immutable DOMAIN_SEPARATOR;
    // keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");
    bytes32 public constant PERMIT_TYPEHASH = 0x6e71edae12b1b97f4d1f60370fef10105fa2faae0126114a169c64845d6126c9;

    // --- Constructor ---
    constructor() public {
        // Initialize contract with the current redemption price
        updateRedemptionPrice();

        // Initialize ERC-2612 DOMAIN_SEPARATOR
        uint256 chainId;
        assembly {
            chainId := chainid()
        }
        DOMAIN_SEPARATOR = keccak256(
            abi.encode(
                keccak256('EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)'),
                keccak256(bytes(name)),
                keccak256(bytes('1')),
                chainId,
                address(this)
            )
        );
    }

    // --- Token ---
    /*
    * @notice Transfer coins to another address
    * @param dst The address to transfer coins to
    * @param amount The amount of coins to transfer, denominated in Drai
    */
    function transfer(address dst, uint256 amount) external returns (bool) {
        return transferFrom(msg.sender, dst, amount);
    }

    /*
     * @notice Transfer coins from a source address to a destination address (if allowed)
     * @param src The address from which to transfer coins
     * @param dst The address that will receive the coins
     * @param amount The amount of coins to transfer, specified in Drai
     */
    function transferFrom(address src, address dst, uint256 amount) public returns (bool) {
        updateRedemptionPrice();
        uint256 raiAmount = _draiToRai(amount);
        require(balanceOfRai[src] >= raiAmount, "drai/insufficient-balance");
        if (src != msg.sender && allowanceRai[src][msg.sender] != uint256(-1)) {
            require(allowanceRai[src][msg.sender] >= raiAmount, "drai/insufficient-allowanceRai");
            allowanceRai[src][msg.sender] = subtract(allowanceRai[src][msg.sender], raiAmount);
        }
        balanceOfRai[src] = subtract(balanceOfRai[src], amount);
        balanceOfRai[dst] = addition(balanceOfRai[dst], amount);
        emit Transfer(src, dst, amount);
        return true;
    }

    /*
     * @notice Change the transfer/burn allowance that another address has on your behalf
     * @param usr The address whose allowance is changed
     * @param amount The new total allowance for the usr, specified in Drai
     */
    function approve(address usr, uint256 amount) external returns (bool) {
        _approve(msg.sender, usr, amount);
        return true;
    }

    /*
     * @notice Change the transfer/burn allowance that another address has on your behalf
     * @param owner The address whose coins can be spent by `spender`
     * @param spender The address whose allowance is changed
     * @param amount The new total allowance for the usr, specified in Drai
     */
    function _approve(address owner, address spender, uint256 amount) private {
        updateRedemptionPrice();
        allowanceRai[owner][spender] = amount == uint256(-1) ? amount : _draiToRai(amount); // avoid overflow on MAX_UINT approvals
        emit Approval(owner, spender, amount);
    }

    // --- Transfer aliases ---
    /*
     * @notice Send Drai to another address
     * @param usr The address to send tokens to
     * @param amount The amount of Drai to send
     */
    function push(address usr, uint256 amount) external {
        transferFrom(msg.sender, usr, amount);
    }

    /*
     * @notice Transfer Drai from another address to your address
     * @param usr The address to take Drai from
     * @param amount The amount of Drai to take from the usr
     */
    function pull(address usr, uint256 amount) external {
        transferFrom(usr, msg.sender, amount);
    }

    /*
     * @notice Transfer Drai from another address to a destination address (if allowed)
     * @param src The address to transfer Drai from
     * @param dst The address to transfer Drai to
     * @param amount The amount of Drai to transfer
     */
    function move(address src, address dst, uint256 amount) external {
        transferFrom(src, dst, amount);
    }

    // --- ERC-2612 permit: approve by signature ---
    /*
     * @notice Submit a signed message that modifies an allowance for a specific address
     * @param owner The address whose coins can be spent by `spender`
     * @param spender The address whose allowance is changed
     * @param amount The new total allowance for the usr, specified in Drai
     * @param deadline Timestamp the permit expires, i.e. latest valid time it can be submitted
     * @param v ECDSA signature component: Parity of the `y` coordinate of point `R`
     * @param r ECDSA signature component: x-coordinate of `R`
     * @param s ECDSA signature component: `s` value of the signature
     */
    function permit(address owner, address spender, uint256 amount, uint256 deadline, uint8 v, bytes32 r, bytes32 s) external {
        require(deadline >= block.timestamp, 'drai/expired');
        bytes32 digest = keccak256(
            abi.encodePacked(
                '\x19\x01',
                DOMAIN_SEPARATOR,
                keccak256(abi.encode(PERMIT_TYPEHASH, owner, spender, amount, nonces[owner]++, deadline))
            )
        );
        address recoveredAddress = ecrecover(digest, v, r, s);
        require(recoveredAddress != address(0) && recoveredAddress == owner, 'drai/invalid-signature');
        _approve(owner, spender, amount);
    }

    // --- Mint and Redeem Drai ---
    /*
     * @notice Mint new Drai by sending Rai to this contract
     * @param usr The address for which to mint coins
     * @param amount The amount of Rai to use for minting Drai
     */
    function mint(address usr, uint256 amount) external {
        // Get amount of DRAI to mint based on current redemption price
        updateRedemptionPrice();
        uint256 draiAmount = _raiToDrai(amount);

        // Update state and transfer tokens. Balances are stored internally at a 1:1 exchange rate with RAI, and
        // "true" dollar-pegged balances are computed on-demand in the `balanceOf()` and totalSupply()` methods.
        // This is why the `Transfer` event emits `draiAmount` but `amount` is used everywhere else
        balanceOfRai[usr] = addition(balanceOfRai[usr], amount);
        totalSupplyRai     = addition(totalSupplyRai, amount);
        raiToken.transferFrom(msg.sender, address(this), amount);
        emit Transfer(address(0), usr, draiAmount);
    }

    /*
     * @notice Reddem Drai for Rai
     * @dev Use MAX_UINT256 as `amount` to redeem all Drai held by `src`
     * @param src The address from which to pull Drai
     * @param dst The address to send Rai to
     * @param amount The amount of Rai to send back after redemption (Drai amount is calculated)
     */
    function redeemUnderlying(address src, address dst, uint256 amount) public {
        updateRedemptionPrice();
        uint256 raiAmount = amount == uint256(-1) ? balanceOfRai[src] : amount;
        _redeem(src, dst, raiAmount, _raiToDrai(raiAmount));
    }

    /*
     * @notice Reddem Drai for Rai
     * @dev Use MAX_UINT256 as `amount` to redeem all Drai held by `src`
     * @param src The address from which to pull Drai
     * @param dst The address to send Rai to
     * @param amount The amount of Drai to send to this contract (Rai amount is calculated)
     */
    function redeem(address src, address dst, uint256 amount) public {
        updateRedemptionPrice();
        uint256 draiAmount = amount == uint256(-1) ? balanceOf(src) : amount;
        _redeem(src, dst, _draiToRai(draiAmount), draiAmount);
    }

    /*
     * @notice Reddem Drai for Rai
     * @dev Intended to be called from a method that ensures `raiAmount` and `draiAmount` are equivalent
     * @dev Assumes redemption price has already been updated before this method is called
     * @dev Use MAX_UINT256 as `amount` to redeem all Drai held by `src`
     * @param src The address from which to pull Drai
     * @param dst The address to send Rai to
     * @param raiAmount The amount of Rai to send back after redemption
     * @param draiAmount The amount of Drai to send to this contract
     */
    function _redeem(address src, address dst, uint256 raiAmount, uint256 draiAmount) internal {
        // Balance and allowance checks
        require(balanceOfRai[src] >= raiAmount, "drai/insufficient-balance");
        if (src != msg.sender && allowanceRai[src][msg.sender] != uint256(-1)) {
            require(allowanceRai[src][msg.sender] >= raiAmount, "drai/insufficient-allowanceRai");
            allowanceRai[src][msg.sender] = subtract(allowanceRai[src][msg.sender], raiAmount);
        }

        // Update state and transfer tokens
        balanceOfRai[src] = subtract(balanceOfRai[src], raiAmount);
        totalSupplyRai    = subtract(totalSupplyRai, raiAmount);
        raiToken.transfer(dst, raiAmount);
        emit Transfer(src, address(0), draiAmount);
    }

    // --- Dollar peg logic ---
    /**
     * @notice Returns Drai balance of a user
     * @dev Calculated dynamically based on last known Rai redemption price
     * @param usr User whose balance to return
     */
    function balanceOf(address usr) public view returns(uint256) {
        return rmultiply(balanceOfRai[usr], lastRedemptionPrice);
    }

    /**
     * @notice Returns total supply of Drai
     * @dev Calculated dynamically based on last known Rai redemption price
     */
    function totalSupply() public view returns(uint256) {
        return rmultiply(totalSupplyRai, lastRedemptionPrice);
    }

    /**
     * @notice Returns allowance of `spender` to spend `owner`s Drai
     * @param owner Drai holder
     * @param spender Drai spender
     */
    function allowance(address owner, address spender) public view returns(uint256) {
        uint256 raiAllowance = allowanceRai[owner][spender];
        return raiAllowance == uint256(-1) ? raiAllowance : rmultiply(raiAllowance, lastRedemptionPrice);
    }

    /**
     * @dev Helper method to convert a quantity of Drai to Rai, based on last known redemption price
     */
    function _draiToRai(uint256 amount) internal view returns(uint256) {
        // Does not update redemption price before converting
        return rdivide(amount, lastRedemptionPrice); // wad / ray = wad, so no other unit conversions needed
    }

    /**
     * @dev Helper method to convert a quantity of Rai to Drai, based on last known redemption price
     */
    function _raiToDrai(uint256 amount) internal view returns(uint256) {
        // Does not update redemption price before converting
        return rmultiply(amount, lastRedemptionPrice); // ray * wad = wad, so no other unit conversions needed
    }

    /**
     * @notice Computes the current redemption price
     * @dev RAI's OracleRelayer does not have a view method to read what the current redemption
     * price is -- you must send a transaction which updates the state to get the latest price.
     * The redemption price is required by the `balanceOf()` and `totalSupply()` methods, which
     * are required to be `view` methods to conform to ERC-20 (and to avoid breaking any frontend
     * or contract that simply wants to query a user's balance). The state variables required to
     * compute the current redemption price are all public, so we use this method compute what the
     * current redemption price is based on our cached data
     * @dev This method is based on https://github.com/reflexer-labs/geb/blob/8ff6f9499df94486063a27b82e1b2126728ffa18/src/OracleRelayer.sol#L247-L261
     */
    function computeRedemptionPrice() public view returns (uint256) {
        uint256 redemptionPrice = rmultiply(
            rpower(lastRedemptionRate, subtract(now, lastRedemptionPriceUpdateTime), RAY),
            lastRedemptionPrice
        );
        return redemptionPrice == 0 ? 1 : redemptionPrice;
    }

    /**
     * @dev RAI's OracleRelayer does not have a view method to read what the current redemption
     * price is, so this method caches the most recent value as often as possible. It's called at
     * the start of every non-view method to update and store the current redemption price
     */
    function updateRedemptionPrice() public returns (uint256) {
        // These are trusted external calls, so it's ok that we call them before modifying state in other methods
        lastRedemptionPrice = oracleRelayer.redemptionPrice(); // non-payable (i.e. non-view) method
        lastRedemptionRate = oracleRelayer.redemptionRate(); // view method

        // We just updated the OracleRelayer's redemption price which sets `oracleRelayer.redemptionPriceUpdateTime()`
        // to the current time. Therefore we can set our cached value directly to the current time, which avoids
        // saves gas by avoiding another external call to read `redemptionPriceUpdateTime`
        lastRedemptionPriceUpdateTime = now;
        return lastRedemptionPrice;
    }
}
