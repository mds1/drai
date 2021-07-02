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
    function redemptionRate() external returns (uint256);
    // Last time when the redemption price was changed
    function redemptionPriceUpdateTime() external returns (uint256);
}

contract Drai {
    // -- Data --
    CoinLike public raiToken = CoinLike(0x03ab458634910AaD20eF5f1C8ee96F1D6ac54919);
    OracleRelayerLike public oracleRelayer = OracleRelayerLike(0x4ed9C0dCa0479bC64d8f4EB3007126D5791f7851);

    // --- ERC20 Data ---
    string  public constant name     = "Drai";
    string  public constant symbol   = "DRAI";
    string  public constant version  = "1";
    uint8   public constant decimals = 18;
    uint256 public totalSupply;

    mapping (address => uint256)                      public balanceOf;
    mapping (address => mapping (address => uint256)) public allowance;
    mapping (address => uint256)                      public nonces;

    event Approval(address indexed src, address indexed guy, uint256 wad);
    event Transfer(address indexed src, address indexed dst, uint256 wad);

    // --- Math ---
    uint256 constant RAY = 10 ** 27;
    function add(uint256 x, uint256 y) internal pure returns (uint256 z) {
        require((z = x + y) >= x);
    }
    function sub(uint256 x, uint256 y) internal pure returns (uint256 z) {
        require((z = x - y) <= x);
    }
    function mul(uint256 x, uint256 y) internal pure returns (uint256 z) {
        require(y == 0 || (z = x * y) / y == x);
    }
    function rmul(uint256 x, uint256 y) internal pure returns (uint256 z) {
        // always rounds down
        z = mul(x, y) / RAY;
    }
    function rdiv(uint256 x, uint256 y) internal pure returns (uint256 z) {
        // always rounds down
        z = mul(x, RAY) / y;
    }
    function rdivup(uint256 x, uint256 y) internal pure returns (uint256 z) {
        // always rounds up
        z = add(mul(x, RAY), sub(y, 1)) / y;
    }

    // --- EIP712 niceties ---
    bytes32 public immutable DOMAIN_SEPARATOR;
    // keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");
    bytes32 public constant PERMIT_TYPEHASH = 0x6e71edae12b1b97f4d1f60370fef10105fa2faae0126114a169c64845d6126c9;

    // --- Constructor ---
    constructor() public {
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
        require(balanceOf[src] >= wad, "drai/insufficient-balance");
        if (src != msg.sender && allowance[src][msg.sender] != uint256(-1)) {
            require(allowance[src][msg.sender] >= wad, "drai/insufficient-allowance");
            allowance[src][msg.sender] = sub(allowance[src][msg.sender], wad);
        }
        balanceOf[src] = sub(balanceOf[src], wad);
        balanceOf[dst] = add(balanceOf[dst], wad);
        emit Transfer(src, dst, wad);
        return true;
    }

    function approve(address usr, uint256 wad) external returns (bool) {
        _approve(msg.sender, usr, wad);
        return true;
    }

    function _approve(address owner, address spender, uint value) private {
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
        uint256 redemptionPrice = oracleRelayer.redemptionPrice();
        uint256 mintAmount = rmul(redemptionPrice, amount); // ray * wad = wad, so no other unit conversions needed

        // Update state and transfer tokens
        balanceOf[user] = add(balanceOf[user], mintAmount);
        totalSupply    = add(totalSupply, mintAmount);
        raiToken.transferFrom(msg.sender, address(this), amount);
        emit Transfer(address(0), user, mintAmount);
    }

    // amount is denominated in DRAI (USD)
    function exit(address src, uint256 amount) public {
        // Balance and allowance checks
        require(balanceOf[src] >= amount, "drai/insufficient-balance");
        if (src != msg.sender && allowance[src][msg.sender] != uint256(-1)) {
            require(allowance[src][msg.sender] >= amount, "drai/insufficient-allowance");
            allowance[src][msg.sender] = sub(allowance[src][msg.sender], amount);
        }

        // Get amount to redeem based on current redemption price
        uint256 redemptionPrice = oracleRelayer.redemptionPrice();
        uint256 redeemAmount = rmul(redemptionPrice, amount); // ray * wad = wad, so no other unit conversions needed

        // Update state and transfer tokens
        balanceOf[src] = sub(balanceOf[src], amount);
        totalSupply      = sub(totalSupply, amount);
        raiToken.transfer(msg.sender, redeemAmount);
        emit Transfer(src, address(0), amount);
    }
}
