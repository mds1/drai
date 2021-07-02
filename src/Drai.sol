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
    // redemption price and update time ourselves
    uint256 public lastRedemptionPrice;
    uint256 public lastRedemptionRate;
    uint256 public lastRedemptionPriceUpdateTime;

    // --- ERC20 Data ---
    string  public constant name     = "Drai";
    string  public constant symbol   = "DRAI";
    string  public constant version  = "1";
    uint8   public constant decimals = 18;
    uint256 internal _totalSupply;

    mapping (address => uint256)                      internal _balances;
    mapping (address => mapping (address => uint256)) public   allowance;
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
    function transfer(address dst, uint256 wad) external returns (bool) {
        return transferFrom(msg.sender, dst, wad);
    }

    function transferFrom(address src, address dst, uint256 wad) public returns (bool) {
        updateRedemptionPrice();
        require(balanceOf(src) >= wad, "drai/insufficient-balance");
        if (src != msg.sender && allowance[src][msg.sender] != uint256(-1)) {
            require(allowance[src][msg.sender] >= wad, "drai/insufficient-allowance");
            allowance[src][msg.sender] = subtract(allowance[src][msg.sender], wad);
        }
        _balances[src] = subtract(balanceOf(src), wad);
        _balances[dst] = addition(balanceOf(dst), wad);
        emit Transfer(src, dst, wad);
        return true;
    }

    function approve(address usr, uint256 wad) external returns (bool) {
        _approve(msg.sender, usr, wad);
        return true;
    }

    function _approve(address owner, address spender, uint value) private {
        updateRedemptionPrice();
        allowance[owner][spender] = value;
        emit Approval(owner, spender, value);
    }

    // --- ERC-2612 permit: approve by signature ---
    function permit(address owner, address spender, uint value, uint deadline, uint8 v, bytes32 r, bytes32 s) external {
        require(deadline >= block.timestamp, 'drai/expired');
        bytes32 digest = keccak256(
            abi.encodePacked(
                '\x19\x01',
                DOMAIN_SEPARATOR,
                keccak256(abi.encode(PERMIT_TYPEHASH, owner, spender, value, nonces[owner]++, deadline))
            )
        );
        address recoveredAddress = ecrecover(digest, v, r, s);
        require(recoveredAddress != address(0) && recoveredAddress == owner, 'drai/invalid-signature');
        _approve(owner, spender, value);
    }

    // --- Join/Exit ---
    // amount is denominated in RAI
    function join(address user, uint256 amount) external {
        // Get amount to mint based on current redemption price
        uint256 redemptionPrice = updateRedemptionPrice();
        uint256 mintAmount = rmultiply(redemptionPrice, amount); // ray * wad = wad, so no other unit conversions needed

        // Update state and transfer tokens
        _balances[user] = addition(balanceOf(user), mintAmount);
        _totalSupply     = addition(totalSupply(), mintAmount);
        raiToken.transferFrom(msg.sender, address(this), amount);
        emit Transfer(address(0), user, mintAmount);
    }

    // amount is denominated in DRAI (USD)
    function exit(address src, uint256 amount) public {
        // Balance and allowance checks
        require(balanceOf(src) >= amount, "drai/insufficient-balance");
        if (src != msg.sender && allowance[src][msg.sender] != uint256(-1)) {
            require(allowance[src][msg.sender] >= amount, "drai/insufficient-allowance");
            allowance[src][msg.sender] = subtract(allowance[src][msg.sender], amount);
        }

        // Get amount to redeem based on current redemption price
        uint256 redemptionPrice = updateRedemptionPrice();
        uint256 redeemAmount = rmultiply(redemptionPrice, amount); // ray * wad = wad, so no other unit conversions needed

        // Update state and transfer tokens
        _balances[src] = subtract(balanceOf(src), amount);
        _totalSupply    = subtract(totalSupply(), amount);
        raiToken.transfer(msg.sender, redeemAmount);
        emit Transfer(src, address(0), amount);
    }

    // --- Dollar peg logic ---
    function balanceOf(address user) public view returns(uint256) {
        // TODO make this based on redemption price
        return _balances[user];
    }

    function totalSupply() public view returns(uint256) {
        // TODO make this based on redemption price
        return _totalSupply;
    }

    /**
     * @notice Computes the current redemption price
     * @dev RAI's OracleRelayer does not have a view method to read what the current redemption
     * price is -- you must send a transaction which updates the state to get the latest price.
     * The redemption price is required by the `balanceOf()` and `totalSupply()` methods, which
     * are required to be `view` methods to conform to ERC-20 (and to avoid breaking any frontend
     * that wants to simply query a user's balance). The state variables required to compute the
     * current redemption price are all public, so we use this method compute what the current
     * redemption price is
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
     * price is, so this internal method caches the most recent value as often as possible. It's
     * used in every non-view method to update and return the current redemption price
     */
    function updateRedemptionPrice() public returns (uint256) {
        // These are trusted external calls
        lastRedemptionPrice = oracleRelayer.redemptionPrice(); // non-payable (i.e. non-view) method
        lastRedemptionRate = oracleRelayer.redemptionRate(); // view method

        // We just updated the OracleRelayer's redemption price which sets `oracleRelayer.redemptionPriceUpdateTime()`
        // to the current time. Therefore we can set our cached value directly to the current time, which avoids
        // saves gas by avoiding another external call
        lastRedemptionPriceUpdateTime = now;
        return lastRedemptionPrice;
    }
}
