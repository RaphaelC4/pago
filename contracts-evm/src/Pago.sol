// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title Pago - shareable payment links on X Layer.
///
/// A Solidity port of the NEAR contract in `contracts/paylink-contract/src/lib.rs`.
/// The concept is ported, not the code: NEAR's `ft_transfer_call` / `ft_on_transfer`
/// handshake has no direct EVM equivalent, so the payer path is an ordinary ERC-20
/// `transferFrom` (or an EIP-3009 `transferWithAuthorization` submitted by a relayer,
/// proven on X Layer mainnet in Phase 0 - see docs/RESEARCH.md section 8).
///
/// What carries over unchanged:
///
///   * The payee records what they are owed; nothing is held until a payer settles it.
///   * Money out: `claim(linkId)` takes no result arguments, is callable by anyone, and
///     can only ever pay the invoice's payee minus the fixed 0.5% fee to `feeAccount`.
///     The caller is never a recipient, so a keeper may trigger it the moment a link is
///     paid and the payee does nothing.
///   * The payee cannot settle their own link.
///   * Cancellation is the creator's alone, only while the stored status is `Open`, and
///     moves no money.
///   * `Expired` is derived on read, never stored, so a link that quietly ages out is
///     reported honestly without a background job rewriting it.
///   * Timestamps are **milliseconds** since the Unix epoch, as on NEAR, so browser
///     callers keep using `Date` unchanged.
///   * The fee split uses the same floor-rounding decomposition as the Rust `split_fee`,
///     which cannot overflow and always satisfies `payout + fee == amount`.
///
/// What changes, and why:
///
///   * No creation stake and no yoctoNEAR guards. On EVM, storage is paid for in gas by
///     the caller and state-changing calls are already transaction-scoped, so neither
///     NEAR's `CREATE_STORAGE_STAKE` nor `attach exactly 1 yoctoNEAR` has a purpose.
///   * No `on_claimed` callback. NEAR needs it because its transfer batch can fail after
///     `claim` has already written `Claimed`. On EVM the writes and the transfers happen
///     in one transaction: if a transfer fails the whole transaction reverts, the status
///     goes back to `Paid` on its own, and anyone may simply retry. Nothing is ever
///     stranded and nothing is ever double-sent, for the same reason, with no callback.
///   * No NEP-145 registration. ERC-20 has no per-account registration to fund.
///
/// Security model: funds move only per what the contract computed from its own onchain
/// state, or per the visible default split. No function lets a caller supply a recipient
/// or an amount that the contract did not derive itself.
contract Pago {
    // ── constants ──────────────────────────────────────────────────────────

    /// Fee taken from the payee's payout at `claim`, in basis points (50 = 0.5%).
    /// A constant, not state: it can only change through a visible code upgrade.
    uint256 public constant FEE_BPS = 50;

    uint256 private constant BPS_DENOMINATOR = 10_000;

    /// Longest description `createLink` accepts, counted in **UTF-8 bytes**, matching
    /// `String::len()` in the Rust original.
    uint256 public constant MAX_DESCRIPTION_LEN = 280;

    uint256 public constant MAX_LINK_ID_LEN = 64;
    uint256 public constant MIN_LINK_ID_LEN = 4;

    // ── types ──────────────────────────────────────────────────────────────

    /// Lifecycle of an invoice.
    ///
    /// `Expired` is never stored: it is derived on read from `expiresAt`, exactly as in
    /// the NEAR build. Stored statuses are therefore 0..=3 (Open, Paid, Claimed,
    /// Cancelled), so nothing ever writes a value that a later read would have to
    /// reinterpret.
    enum Status {
        Open,
        Paid,
        Claimed,
        Cancelled,
        Expired
    }

    /// One invoice.
    struct Link {
        string linkId;
        /// Who is owed the money. `claim` always pays this account, whoever calls it.
        address creator;
        /// Invoiced amount, in the token's base units.
        uint256 amount;
        /// The one ERC-20 this invoice is denominated in.
        address token;
        string description;
        /// ms since epoch.
        uint64 createdAt;
        /// ms since epoch. 0 = never expires.
        uint64 expiresAt;
        Status status;
        /// address(0) until a payment is credited.
        address paidBy;
        /// What actually arrived - may exceed `amount` if the payer overpaid.
        uint256 paidAmount;
        /// ms since epoch. 0 = not paid.
        uint64 paidAt;
        /// ms since epoch. 0 = not claimed.
        uint64 claimedAt;
    }

    // ── storage ────────────────────────────────────────────────────────────

    /// Receives the fee at `claim`. Set once in the constructor and immutable, so there
    /// is deliberately no setter: changing it requires a visible code upgrade.
    address public immutable feeAccount;

    /// Token contracts this deployment accepts. Written only by the constructor and
    /// exposed read-only: widening it requires a visible code upgrade rather than a
    /// quiet call, mirroring `allowed_tokens` in the NEAR build.
    mapping(address => bool) private _allowedTokens;

    /// link key -> invoice. The hot path: point lookups only.
    mapping(bytes32 => Link) private _links;

    /// creator -> their link keys, in creation order. Only the requested creator's
    /// ledger is ever loaded.
    mapping(address => bytes32[]) private _byCreator;

    /// Reentrancy guard. The allowlist is fixed at construction, so only audited tokens
    /// can ever call back in, but a malicious *recipient* could try to reenter `claim`
    /// mid-payout. Checks-effects-interactions already orders the writes first; this
    /// closes the cross-function path for the cost of two cold SSTOREs.
    uint256 private _entered = 1;

    // ── events ─────────────────────────────────────────────────────────────

    event LinkCreated(bytes32 indexed linkKey, address indexed creator, address indexed token, uint256 amount, uint64 expiresAt);
    event LinkCancelled(bytes32 indexed linkKey, address indexed creator);
    event LinkPaid(bytes32 indexed linkKey, address indexed payer, uint256 amount);
    event LinkClaimed(bytes32 indexed linkKey, address indexed payee, uint256 payout, uint256 fee);

    // ── modifiers ──────────────────────────────────────────────────────────

    modifier nonReentrant() {
        require(_entered == 1, "reentrancy");
        _entered = 2;
        _;
        _entered = 1;
    }

    // ── construction ───────────────────────────────────────────────────────

    /// @param tokens ERC-20 contracts this deployment accepts. At least one.
    /// @param feeAccount_ Account that receives the fee at `claim`.
    constructor(address[] memory tokens, address feeAccount_) {
        require(tokens.length > 0, "at least one token must be allowed");
        require(feeAccount_ != address(0), "fee account required");
        for (uint256 i; i < tokens.length; ++i) {
            require(tokens[i] != address(0), "token cannot be the zero address");
            require(!_allowedTokens[tokens[i]], "duplicate token");
            _allowedTokens[tokens[i]] = true;
        }
        feeAccount = feeAccount_;
    }

    // ── payee ──────────────────────────────────────────────────────────────

    /// Record an invoice. Holds no funds and grants nobody a withdrawal; it only writes
    /// down what someone is owed.
    ///
    /// @param linkId 4-64 bytes. Uniqueness is over `keccak256(bytes(linkId))`, so the
    ///               id a payer sees in the URL is the id the contract enforces.
    /// @param expiresAt ms since epoch, or 0 for "never expires".
    function createLink(
        string calldata linkId,
        uint256 amount,
        address token,
        string calldata description,
        uint64 expiresAt
    ) external returns (Link memory) {
        uint256 idLen = bytes(linkId).length;
        require(idLen >= MIN_LINK_ID_LEN && idLen <= MAX_LINK_ID_LEN, "link id must be 4-64 characters");
        require(_allowedTokens[token], "this token is not accepted");
        require(amount > 0, "amount must be greater than zero");
        require(bytes(description).length <= MAX_DESCRIPTION_LEN && !_isBlank(description), "description must be 1-280 characters");

        bytes32 key = keccak256(bytes(linkId));
        // `creator` is only ever set to `msg.sender`, which can never be the zero
        // address, so it doubles as the "this slot is empty" flag.
        require(_links[key].creator == address(0), "link id already used");

        uint64 ts = nowMs();
        if (expiresAt != 0) {
            require(expiresAt > ts, "expiry must be in the future");
        }

        Link storage l = _links[key];
        l.linkId = linkId;
        l.creator = msg.sender;
        l.amount = amount;
        l.token = token;
        l.description = description;
        l.createdAt = ts;
        l.expiresAt = expiresAt;
        l.status = Status.Open;

        _byCreator[msg.sender].push(key);

        emit LinkCreated(key, msg.sender, token, amount, expiresAt);
        return _read(key);
    }

    /// Cancel an unpaid link. Callable only by the link's creator.
    ///
    /// Three guards, in order: the link must exist, the caller must be `link.creator`
    /// (read from storage, never from arguments), and the *stored* status must still be
    /// `Open`. So `Paid`, `Claimed` and `Cancelled` are all refused, while a link whose
    /// `expiresAt` has passed but which was never paid stays cancellable - it still
    /// holds no funds.
    ///
    /// Deliberately moves no money: it transfers nothing, schedules nothing and takes no
    /// deposit. `Cancelled` is terminal - `pay` refuses it with a full revert, so a
    /// payment arriving later never reaches the token at all, and `claim` refuses
    /// anything not `Paid`.
    function cancelLink(string calldata linkId) external returns (Link memory) {
        bytes32 key = keccak256(bytes(linkId));
        Link storage l = _links[key];
        require(l.creator != address(0), "link not found");
        require(msg.sender == l.creator, "only the creator can cancel");
        // Stored status, not the derived one: an expired-but-unpaid link is still safe
        // to cancel, and every paid/claimed/cancelled state is refused here before
        // anything else can happen.
        require(l.status == Status.Open, "link is not open");

        l.status = Status.Cancelled;
        emit LinkCancelled(key, msg.sender);
        return _read(key);
    }

    // ── payer ──────────────────────────────────────────────────────────────

    /// Settle an invoice by pulling the tokens from the caller.
    ///
    /// Every rejection path reverts before `transferFrom` runs, so a failed payment
    /// costs the payer nothing but gas and no tokens move - the EVM equivalent of the
    /// NEAR build returning the full amount as a refund. This includes the payee who
    /// tries to settle their own link: refused outright, and the link stays `Open`.
    ///
    /// @param amount May exceed `link.amount`; the whole amount is credited and the fee
    ///               is taken from it at `claim`.
    function pay(string calldata linkId, uint256 amount) external nonReentrant {
        bytes32 key = keccak256(bytes(linkId));
        Link storage l = _links[key];
        _requireSettleable(l, msg.sender, amount);

        l.status = Status.Paid;
        l.paidBy = msg.sender;
        l.paidAmount = amount;
        l.paidAt = nowMs();

        // Logged before the transfer for the same reason the writes are: the
        // whole transaction reverts together, so a log can never outlive a
        // payment that did not happen.
        emit LinkPaid(key, msg.sender, amount);

        // Interaction last: if the token reverts or lies, the writes above revert too.
        _safeTransferFrom(l.token, msg.sender, address(this), amount);
    }

    /// Settle an invoice without the payer holding any OKB for gas.
    ///
    /// The payer signs an EIP-3009 `TransferWithAuthorization` off-chain; a third party
    /// (the Pago relayer) submits it here and pays the gas. The token verifies the
    /// signature over `(from, to, value, validAfter, validBefore, nonce)` itself, so the
    /// authorization can only ever move tokens from `from` to *this* contract - a
    /// signature naming any other recipient simply fails to recover `from` and reverts.
    ///
    /// The `nonce` is not free choice: it must equal `authorizationNonce(linkKey, from)`.
    /// That binds one signature to exactly one link, so a relayer holding Alice's
    /// authorization for link A cannot spend it against link B. A link can only be paid
    /// once, so the nonce is single-use for free.
    ///
    /// @param from The payer named in the signature. Cannot be this contract.
    /// @param value Must be at least `link.amount`; the whole value is credited.
    function payWithAuthorization(
        string calldata linkId,
        address from,
        uint256 value,
        uint64 validAfter,
        uint64 validBefore,
        bytes32 nonce,
        bytes calldata signature
    ) external nonReentrant {
        require(from != address(0) && from != address(this), "invalid payer");

        bytes32 key = keccak256(bytes(linkId));
        Link storage l = _links[key];
        _requireSettleable(l, from, value);
        require(uint256(nonce) == authorizationNonce(key, from), "authorization must be bound to this link");

        l.status = Status.Paid;
        l.paidBy = from;
        l.paidAmount = value;
        l.paidAt = nowMs();

        emit LinkPaid(key, from, value);

        IEIP3009(l.token).transferWithAuthorization(from, address(this), value, validAfter, validBefore, nonce, signature);
    }

    // ── payout ─────────────────────────────────────────────────────────────

    /// Release a paid invoice to its payee, less the 0.5% fee. Callable by anyone - the
    /// money can only go to the invoice's payee and the fee account, never to the caller
    /// - only while the link is `Paid`, and only once.
    ///
    /// The payout and the fee go out as two transfers inside one transaction, so they
    /// succeed or fail together. If either fails the whole transaction reverts, the
    /// status returns to `Paid` with no callback needed, and the next attempt - frontend
    /// or keeper - starts over. That is the property `on_claimed` existed to provide on
    /// NEAR; on EVM it falls out of atomicity.
    ///
    /// A zero fee (tiny invoices round down to it) skips the fee transfer instead of
    /// calling `transfer` with an amount of 0.
    function claim(string calldata linkId) external nonReentrant {
        bytes32 key = keccak256(bytes(linkId));
        Link storage l = _links[key];
        require(l.creator != address(0), "link not found");
        // Written before the transfers so a second claim cannot be issued while this
        // one is in flight. A failure reverts the write along with the transfer.
        require(l.status == Status.Paid, "link is not paid");

        address payee = l.creator;
        address token = l.token;
        uint256 credited = l.paidAmount > 0 ? l.paidAmount : l.amount;
        (uint256 payout, uint256 fee) = splitFee(credited);

        l.status = Status.Claimed;
        l.claimedAt = nowMs();

        emit LinkClaimed(key, payee, payout, fee);

        if (payout > 0) _safeTransfer(token, payee, payout);
        if (fee > 0) _safeTransfer(token, feeAccount, fee);
    }

    // ── reads ──────────────────────────────────────────────────────────────

    /// @return found False when no link was ever created under this id - the EVM shape
    ///               of NEAR's `Option<Link>` being `None`.
    /// @return link  With `status` replaced by the derived status, so an open link past
    ///               its deadline reads `Expired` even though `Open` is what is stored.
    function getLink(string calldata linkId) external view returns (bool found, Link memory link) {
        bytes32 key = keccak256(bytes(linkId));
        found = _links[key].creator != address(0);
        link = _read(key);
    }

    /// A creator's ledger, oldest first. The contract never deletes a record, so every
    /// stored key resolves; `Cancelled` and `Expired` links stay in the ledger exactly
    /// as they do on NEAR.
    function getLinksByCreator(address creator) external view returns (Link[] memory out) {
        bytes32[] storage keys = _byCreator[creator];
        out = new Link[](keys.length);
        for (uint256 i; i < keys.length; ++i) {
            out[i] = _read(keys[i]);
        }
    }

    function linkExists(string calldata linkId) external view returns (bool) {
        return _links[keccak256(bytes(linkId))].creator != address(0);
    }

    function isTokenAllowed(address token) external view returns (bool) {
        return _allowedTokens[token];
    }

    /// Fee in basis points (50 = 0.5%). Lets the frontend show "you receive X" by
    /// reading it from the chain rather than trusting a constant in the page.
    function feeBps() external pure returns (uint256) {
        return FEE_BPS;
    }

    /// How many invoices a creator has. Cheap count for a dashboard header.
    function linkCountByCreator(address creator) external view returns (uint256) {
        return _byCreator[creator].length;
    }

    /// The storage key a link id hashes to. Exposed so a caller can compute the nonce
    /// `payWithAuthorization` demands without reimplementing the hash.
    function linkKeyOf(string memory linkId) public pure returns (bytes32) {
        return keccak256(bytes(linkId));
    }

    /// The only nonce the token will accept for this payer on this link.
    function authorizationNonce(bytes32 linkKey, address from) public pure returns (uint256) {
        return uint256(keccak256(abi.encode(linkKey, from)));
    }

    /// ms since the Unix epoch, matching `created_at` / `expires_at` on the invoices.
    function nowMs() public view returns (uint64) {
        return uint64(block.timestamp) * 1000;
    }

    /// Split a credited amount into `(payee payout, fee)`.
    ///
    /// The fee is `amount * FEE_BPS / 10_000`, rounded down, computed by the same
    /// two-term decomposition as the Rust original so it cannot overflow even for
    /// `type(uint256).max`. `payout + fee == amount` always, and the payout is never
    /// zero for a non-zero amount.
    function splitFee(uint256 amount) public pure returns (uint256 payout, uint256 fee) {
        fee = amount / BPS_DENOMINATOR * FEE_BPS + (amount % BPS_DENOMINATOR) * FEE_BPS / BPS_DENOMINATOR;
        payout = amount - fee;
    }

    // ── internals ──────────────────────────────────────────────────────────

    /// Guards shared by `pay` and `payWithAuthorization`, in the order the NEAR build
    /// checked them: token allowlist, existence, stored status, self-payment, amount,
    /// deadline.
    function _requireSettleable(Link storage l, address sender, uint256 amount) private view {
        require(l.creator != address(0), "link not found");
        require(_allowedTokens[l.token], "this token is not accepted");
        require(l.status == Status.Open, "link is not open");
        require(sender != l.creator, "the payee cannot pay their own link");
        require(amount >= l.amount, "payment amount is too small");
        require(!_expired(l.expiresAt), "link has expired");
    }

    /// An open invoice past its deadline reports `EXPIRED` rather than pretending it is
    /// still payable. Written status is untouched.
    function _read(bytes32 key) private view returns (Link memory l) {
        l = _links[key];
        if (l.status == Status.Open && _expired(l.expiresAt)) {
            l.status = Status.Expired;
        }
    }

    function _expired(uint64 expiresAt) private view returns (bool) {
        return expiresAt != 0 && nowMs() >= expiresAt;
    }

    /// `true` when the description is empty or holds nothing but whitespace. The Rust
    /// original used `str::trim()`, which strips Unicode whitespace; this covers ASCII
    /// whitespace, which is what the frontend emits.
    function _isBlank(string memory s) private pure returns (bool) {
        bytes memory b = bytes(s);
        for (uint256 i; i < b.length; ++i) {
            bytes1 c = b[i];
            if (c != 0x20 && c != 0x09 && c != 0x0a && c != 0x0d && c != 0x0b && c != 0x0c) {
                return false;
            }
        }
        return true;
    }

    /// ERC-20s are inconsistent about their return value: most return `bool`,
    /// classic USDT-style tokens return nothing at all. Both are accepted; a
    /// token that returns data which does not decode as `true` is treated as a
    /// failed transfer rather than being silently trusted.
    function _ok(bool ok, bytes memory ret) private pure {
        require(ok && (ret.length == 0 || (ret.length >= 32 && abi.decode(ret, (bool)))), "token transfer failed");
    }

    function _safeTransfer(address token, address to, uint256 amount) private {
        (bool ok, bytes memory ret) = token.call(abi.encodeWithSelector(IERC20.transfer.selector, to, amount));
        _ok(ok, ret);
    }

    function _safeTransferFrom(address token, address from, address to, uint256 amount) private {
        (bool ok, bytes memory ret) = token.call(abi.encodeWithSelector(IERC20.transferFrom.selector, from, to, amount));
        _ok(ok, ret);
    }
}

/// Minimal ERC-20 surface Pago calls. Written out rather than imported so the contract
/// has no external dependencies.
interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);

    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// EIP-3009 `transferWithAuthorization`. Proven live on X Layer mainnet for USDT0 and
/// USDG in Phase 0 (docs/RESEARCH.md section 8): a third party may submit it, and a
/// signature naming any recipient other than the caller fails to recover `from`.
interface IEIP3009 {
    function transferWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint64 validAfter,
        uint64 validBefore,
        bytes32 nonce,
        bytes calldata signature
    ) external;
}