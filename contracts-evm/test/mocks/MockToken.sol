// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title MockToken - an ERC-20 that also honours EIP-3009 authorizations.
///
/// Used only by Pago's tests. It exists so the suite can exercise both payer
/// paths - the caller-pays-gas `transferFrom` and the gasless
/// `transferWithAuthorization` - against one deterministic token, including
/// the failure mode `claim` has to survive (a transfer that reverts).
///
/// The EIP-3009 implementation here follows the specification exactly
/// (domain separator, `TransferWithAuthorization` typehash, `validAfter` /
/// `validBefore` strict comparisons, per-signer single-use nonces).
///
/// SHAPE PINNED TO THE REAL TOKEN. This mock used to declare
/// `uint64 validAfter, uint64 validBefore` - a shape no live X Layer token
/// has - so `transferWithAuthorization` resolved to selector 0xd8fde8d5 while
/// the real USD0 implements the `uint256` form, 0xcf092995. Pago's gasless
/// path therefore reverted against the real token while every test here still
/// passed, because the mock was the only token the suite ever routed Pago
/// through. The typehash, `digestOf` and `transferWithAuthorization` below now
/// match USD0's EIP-3009 surface, so a mock that disagrees with a live token
/// breaks the build or a test instead of hiding the difference.
///
/// What the mock is genuinely for is Pago's own logic - in particular that its
/// nonce binding is what stops a signature for one link being spent against
/// another. Phase 0 proved the *tokens* honour EIP-3009 (docs/RESEARCH.md
/// section 8); it never proved Pago routes through them, which is what the
/// mainnet-fork payWithAuthorization test now covers.
///
/// `digestOf` exposes the exact hash the token verifies, so a test can sign it
/// with `vm.sign` without reimplementing the encoding and getting a byte wrong.
contract MockToken {
    string public name;
    string public symbol;
    uint8 public decimals;

    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    /// EIP-3009: one authorization may be used exactly once, keyed by signer.
    mapping(address => mapping(bytes32 => bool)) public authorizationUsed;

    /// Test hook: when true every `transfer` / `transferFrom` reverts. Used to
    /// prove that a claim whose transfers all fail still completes: the money
    /// becomes owed (rule 9) instead of freezing the link (rule 3).
    bool public transfersFailing;

    /// Test hook: per-recipient transfer failures. A transfer *to* a blocked
    /// account reverts while transfers to everyone else succeed, which is how
    /// rule 9 (one failing recipient must not block the others) is proven.
    mapping(address => bool) public blockedRecipient;

    bytes32 public constant EIP712_DOMAIN_TYPEHASH = keccak256(
        "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
    );
    bytes32 public constant TRANSFER_WITH_AUTHORIZATION_TYPEHASH = keccak256(
        "TransferWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)"
    );

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
    event AuthorizationUsed(address indexed from, bytes32 indexed nonce);

    constructor(string memory name_, string memory symbol_, uint8 decimals_) {
        name = name_;
        symbol = symbol_;
        decimals = decimals_;
    }

    // ── test helpers ───────────────────────────────────────────────────────

    function mint(address to, uint256 amount) external {
        totalSupply += amount;
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function setTransfersFailing(bool failing) external {
        transfersFailing = failing;
    }

    function setBlockedRecipient(address who, bool blocked) external {
        blockedRecipient[who] = blocked;
    }

    // ── ERC-20 ─────────────────────────────────────────────────────────────

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _move(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            require(allowed >= amount, "insufficient allowance");
            allowance[from][msg.sender] = allowed - amount;
        }
        _move(from, to, amount);
        return true;
    }

    // ── EIP-3009 ───────────────────────────────────────────────────────────

    function DOMAIN_SEPARATOR() public view returns (bytes32) {
        return keccak256(
            abi.encode(EIP712_DOMAIN_TYPEHASH, keccak256(bytes(name)), keccak256(bytes("1")), block.chainid, address(this))
        );
    }

    /// The EIP-712 digest an authorization must be signed over. Mirrored by
    /// the verifier below so tests and token can never disagree.
    function digestOf(address from, address to, uint256 value, uint256 validAfter, uint256 validBefore, bytes32 nonce)
        public
        view
        returns (bytes32)
    {
        bytes32 structHash =
            keccak256(abi.encode(TRANSFER_WITH_AUTHORIZATION_TYPEHASH, from, to, value, validAfter, validBefore, nonce));
        return keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR(), structHash));
    }

    /// Submitted by any account (a relayer) - the payer only ever signs.
    /// The token itself recovers `from`, so the signature can only ever move
    /// tokens from the signer to `to`.
    function transferWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        bytes calldata signature
    ) external {
        require(signature.length == 64 || signature.length == 65, "invalid signature length");
        require(!authorizationUsed[from][nonce], "authorization already used");
        require(block.timestamp > validAfter, "authorization not yet valid");
        require(block.timestamp < validBefore, "authorization expired");

        bytes32 digest = digestOf(from, to, value, validAfter, validBefore, nonce);
        (bytes32 r, bytes32 s) = abi.decode(signature, (bytes32, bytes32));
        uint8 v = signature.length == 65 ? uint8(signature[64]) : 27;
        // Accept both the 0/1 and the 27/28 convention; `vm.sign` returns 27/28.
        if (v == 0 || v == 1) v += 27;
        address signer = ecrecover(digest, v, r, s);
        require(signer != address(0) && signer == from, "invalid signature");

        authorizationUsed[from][nonce] = true;
        emit AuthorizationUsed(from, nonce);
        _move(from, to, value);
    }

    // ── internals ──────────────────────────────────────────────────────────

    function _move(address from, address to, uint256 amount) private {
        require(!transfersFailing, "mock transfer failure");
        require(!blockedRecipient[to], "recipient blocked");
        require(balanceOf[from] >= amount, "insufficient balance");
        unchecked {
            balanceOf[from] -= amount;
        }
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
    }
}
