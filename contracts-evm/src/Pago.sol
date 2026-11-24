// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IRuleProcessor} from "./IRuleProcessor.sol";

/// @title Pago - shareable payment links on X Layer, with the split rule taped out.
///
/// A Solidity port of the NEAR contract in `contracts/paylink-contract/src/lib.rs`,
/// extended with the contract rules from the project's master prompt
/// (docs/MASTER_PROMPT.md). The concept is ported, not the code.
///
/// What carries over unchanged from the NEAR build:
///
///   * The payee records what they are owed; nothing is held until a payer settles it.
///   * `claim(linkId)` takes no result arguments, is callable by anyone, and can only
///     ever pay the link's own recipients plus the fixed 0.5% fee to `feeAccount` -
///     never the caller as a reward for calling.
///   * The payee cannot settle their own link.
///   * Cancellation is the creator's alone, only while the stored status is `Open`.
///   * `Expired` is derived on read, never stored.
///   * Timestamps are **milliseconds** since the Unix epoch, as on NEAR.
///   * The fee split uses the same floor-rounding decomposition as the Rust
///     `split_fee`: it cannot overflow and always satisfies `payout + fee == amount`.
///
/// What the master prompt adds (rules 1-10, docs/MASTER_PROMPT.md):
///
///   * **Rule 2 - the processor only ever selects.** At `claim` the contract derives
///     the rule inputs from its own state (the split shares fixed at creation; the
///     credited amount drives the payout base; the deadline is enforced against
///     `block.timestamp` at `pay`), then calls the TapeOut processor with a strict
///     `staticcall`: gas-limited, exact return length, strict decoding. The decoded
///     bit selects between the two split tables fixed at creation - the rule table
///     and the default table. A rule can never invent a split, a recipient or an
///     amount: every payable leg comes from a table this contract stored.
///   * **Rule 3 - a link can never freeze.** The default split is fixed at creation
///     with no setter. If the processor reverts, returns malformed data, runs out of
///     gas or fails a check, `claim` pays the default split. The only ways `claim`
///     reverts are "link not found" and "link is not paid".
///   * **Rule 4 - terms consent.** `terms(linkId)` is the canonical byte string of
///     everything a payer is agreeing to; `termsHash(linkId)` is its keccak256.
///     `pay` and `payWithAuthorization` take `expectedTermsHash` and revert on a
///     mismatch. This binds the payer to the terms *recorded onchain* - it does NOT
///     prove what the payer's screen displayed, and nothing here claims it does.
///   * **Rule 5 - circuit identity.** `createLink` reverts if the processor's
///     netlist cannot be read, and stores `keccak256(netlist)` on the link.
///   * **Rule 6 - evaluatorPinned / implementation check.** Master prompt,
///     verbatim: "If Phase 0 proves the implementation can be checked onchain,
///     store the implementation address and its `extcodehash` and verify both
///     at claim." So the flag is NOT a value frozen at deploy: `evaluatorPinned`
///     is a view that re-runs the two-leg check on every call, and `claim` and
///     `createLink` both consult it live (docs/RESEARCH.md section 18). The two
///     legs, both required: (1) `extcodehash(processor)` equals
///     `expectedProcessorCodehash` with code present - the processor is a
///     beacon proxy shell that hardcodes its beacon address in its own code;
///     (2) `circuitBeacon.implementation()`, the beacon's public getter, returns
///     the stored implementation address whose `extcodehash` equals
///     `expectedImplementationCodehash`. A beacon that reverts, reports a
///     different address or shows different code fails leg 2 - a swap after
///     deploy flips the flag false at the next call. When `claim` finds the
///     check failing it uses the default split; while the check fails,
///     `createLink` enforces `MAX_LINK_AMOUNT_UNPINNED[token]` in base units.
///     The known-answer check is named `changeDetector` (never "pin"); it
///     stays a public view and can never make the flag true. What the flag
///     proves and does not prove is disclosed in README and section 18.
///   * **Rule 7 - decimals are ours, not the token's.** Expected decimals are given
///     by us at deploy time and stored; this contract never calls `decimals()` for
///     any safety decision. The deploy script aborts if the onchain value differs.
///   * **Rule 8 - no markPaid.** Underpay reverts, overpay is credited, double pay
///     reverts, the creator cannot self-pay, and a fee leg that rounds to zero is
///     skipped rather than transferred.
///   * **Rule 9 - one failing recipient never blocks the others.** Every payout leg
///     is an independent transfer; a leg whose transfer fails is deferred as
///     `owed[recipient][token]` and withdrawable by that recipient alone.
///   * **Rule 10 - conservation.** payouts + fee == credited, contract balance >=
///     what is still owed, and stored status never moves backward - proven by the
///     fuzz and invariant suites (test/Pago.invariant.t.sol).
///
/// The one structural change from the NEAR build: a link now carries two preset
/// split tables (default and rule), each three seats in 5% steps - the unit the
/// Split3 circuit judges. See docs/MASTER_PROMPT.md and docs/RESEARCH.md.
contract Pago {
    // ── constants ──────────────────────────────────────────────────────────

    /// Fee taken from the credited amount at `claim`, in basis points (50 = 0.5%).
    uint256 public constant FEE_BPS = 50;

    uint256 private constant BPS_DENOMINATOR = 10_000;

    /// Longest description `createLink` accepts, counted in **UTF-8 bytes**.
    uint256 public constant MAX_DESCRIPTION_LEN = 280;

    uint256 public constant MAX_LINK_ID_LEN = 64;
    uint256 public constant MIN_LINK_ID_LEN = 4;

    /// Seats in a split table. Three, because the Split3 circuit judges exactly
    /// three shares; a circuit with a different arity needs a new deployment.
    uint256 public constant SEATS = 3;

    /// What the shares of a payable split must add up to: 100% / 5% = 20 steps.
    /// This is the same constant Split3.TARGET; the two are asserted equal in
    /// test/PagoRule.t.sol.
    uint256 public constant SPLIT_STEPS = 20;

    /// Widest share the circuit's 5-bit fields can hold (0..31 = 0..155%).
    uint256 public constant MAX_SHARE = 31;

    /// Gas ceiling for an `eval` call. The processor is hardware-backed on mainnet
    /// and an EVM stand-in on testnet; either way the call is bounded, so a
    /// circuit that burns gas can delay a claim but can never freeze it (rule 3).
    uint256 public constant EVAL_GAS_LIMIT = 500_000;

    /// Gas ceiling for reading the netlist at `createLink`.
    uint256 public constant NETLIST_GAS_LIMIT = 200_000;

    // ── types ──────────────────────────────────────────────────────────────

    /// Lifecycle of an invoice. `Expired` is never stored: it is derived on read
    /// from `expiresAt`, exactly as in the NEAR build.
    enum Status {
        Open,
        Paid,
        Claimed,
        Cancelled,
        Expired
    }

    /// One preset split table: three seats, each a share in 5% steps.
    ///
    /// A zero share means the seat is unused and its recipient must be the zero
    /// address; a non-zero share requires a non-zero recipient. The *default*
    /// table must sum to exactly `SPLIT_STEPS` (it always pays out 100%); the
    /// *rule* table may sum to anything - that sum is precisely what the circuit
    /// judges at claim time.
    struct Split {
        address[3] recipients;
        uint8[3] shares;
    }

    /// One invoice.
    struct Link {
        string linkId;
        /// Who created the invoice. `claim` never pays this as a reward; it pays
        /// whichever table (default or rule) applies, seat by seat.
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
        /// Fixed at creation, no setter: the split used when the rule does not
        /// apply (rule 3).
        Split defaultSplit;
        /// Fixed at creation, no setter: the candidate the circuit judges.
        Split ruleSplit;
        /// keccak256 of the processor's TAP-02 netlist, read at creation (rule 5).
        bytes32 netlistHash;
    }

    /// Constructor input per allowed token (rule 7): the token, the decimals as
    /// written by us (the deploy script aborts if the chain disagrees), and the
    /// per-link cap that applies while `evaluatorPinned()` is false (rule 6).
    struct TokenConfig {
        address token;
        uint8 decimals_;
        uint256 unpinnedCap;
    }

    // ── storage ────────────────────────────────────────────────────────────

    /// Receives the fee at `claim`. Set once in the constructor and immutable.
    address public immutable feeAccount;

    /// The TapeOut processor this deployment asks (rule 2). address(0) means "no
    /// evaluator": `createLink` then always reverts (rule 5) and the deployment
    /// stays unpinned and capped - the tier-1 shape before a tape-out exists.
    address public immutable processor;

    /// The circuit's id inside `processor` (Split3 is #1 on our processor).
    uint256 public immutable circuitId;

    /// The exact `extcodehash(processor)` `evaluatorPinned()` compares against
    /// (rule 6, leg 1). Public so anyone can audit the reference the live
    /// implementation check uses.
    bytes32 public immutable expectedProcessorCodehash;

    /// The circuit beacon whose `implementation()` getter `evaluatorPinned()`
    /// calls for rule 6's leg 2. On mainnet this is the address the recorded
    /// processor shell hardcodes; on testnet it is the stand-in's mock beacon.
    /// Public so anyone can audit which beacon the second leg consults.
    address public immutable circuitBeacon;

    /// The exact implementation address recorded at deploy (rule 6, leg 2).
    /// Master prompt, verbatim: "store the implementation address and its
    /// `extcodehash` and verify both at claim." The live check requires the
    /// beacon to still report THIS address - a beacon swapped to point
    /// elsewhere fails there - and the code at it to still hash to
    /// `expectedImplementationCodehash`.
    address public immutable circuitImplementation;

    /// The exact `extcodehash` recorded at deploy for `circuitImplementation`
    /// (rule 6, leg 2 - the second half of "verify both at claim").
    bytes32 public immutable expectedImplementationCodehash;

    /// Expected decimals per token, as written by us at deploy time. This
    /// contract never calls `decimals()` (rule 7).
    mapping(address => uint8) public expectedDecimals;

    /// Per-link cap in base units while `evaluatorPinned()` is false (rule 6).
    mapping(address => uint256) public MAX_LINK_AMOUNT_UNPINNED;

    /// Token contracts this deployment accepts. Written only by the constructor.
    mapping(address => bool) private _allowedTokens;

    /// link key -> invoice.
    mapping(bytes32 => Link) private _links;

    /// creator -> their link keys, in creation order.
    mapping(address => bytes32[]) private _byCreator;

    /// account -> token -> amount owed there because a payout leg's transfer
    /// failed (rule 9). Only the account itself can ever withdraw it.
    mapping(address => mapping(address => uint256)) public owed;

    /// Reentrancy guard.
    uint256 private _entered = 1;

    // ── events ─────────────────────────────────────────────────────────────

    event LinkCreated(bytes32 indexed linkKey, address indexed creator, address indexed token, uint256 amount, uint64 expiresAt);
    event LinkCancelled(bytes32 indexed linkKey, address indexed creator);
    event LinkPaid(bytes32 indexed linkKey, address indexed payer, uint256 amount);
    /// Emitted once per claim. `payout` is the post-fee total the split table
    /// divided; `usedRuleSplit` says whether the circuit's verdict selected the
    /// rule table or the default table took over.
    event LinkClaimed(bytes32 indexed linkKey, uint256 payout, uint256 fee, bool usedRuleSplit);
    /// One seat's transfer succeeded.
    event LegPaid(bytes32 indexed linkKey, address indexed recipient, uint256 amount);
    /// One seat's transfer failed; the amount stayed in the contract as owed.
    event LegOwed(bytes32 indexed linkKey, address indexed recipient, uint256 amount);
    event OwedWithdrawn(address indexed account, address indexed token, uint256 amount);

    // ── modifiers ──────────────────────────────────────────────────────────

    modifier nonReentrant() {
        require(_entered == 1, "reentrancy");
        _entered = 2;
        _;
        _entered = 1;
    }

    // ── construction ───────────────────────────────────────────────────────

    /// @param tokens Allowlist with per-token decimals and unpinned cap.
    /// @param feeAccount_ Account that receives the fee at `claim`.
    /// @param processor_ TapeOut processor to query; address(0) = none.
    /// @param circuitId_ Circuit id inside `processor_`.
    /// @param expectedProcessorCodehash_ keccak256 of the code expected at
    ///        `processor_`: rule 6's leg 1 reference (the proxy shell).
    /// @param circuitBeacon_ The beacon whose `implementation()` getter rule
    ///        6's leg 2 calls. On mainnet the recorded shell hardcodes it.
    /// @param expectedImplementationCodehash_ keccak256 of the code expected
    ///        behind that beacon: rule 6's leg 2 reference.
    /// @param circuitImplementation_ The implementation address the beacon
    ///        reported at deploy (rule 6, leg 2). Stored, per the master
    ///        prompt's verbatim sentence, and re-checked live forever after.
    constructor(
        TokenConfig[] memory tokens,
        address feeAccount_,
        address processor_,
        uint256 circuitId_,
        bytes32 expectedProcessorCodehash_,
        address circuitBeacon_,
        address circuitImplementation_,
        bytes32 expectedImplementationCodehash_
    ) {
        require(tokens.length > 0, "at least one token must be allowed");
        require(expectedProcessorCodehash_ != bytes32(0), "expected codehash required");
        require(circuitBeacon_ != address(0), "circuit beacon required");
        require(circuitImplementation_ != address(0), "circuit implementation required");
        require(expectedImplementationCodehash_ != bytes32(0), "expected implementation codehash required");
        require(feeAccount_ != address(0), "fee account required");
        for (uint256 i; i < tokens.length; ++i) {
            require(tokens[i].token != address(0), "token cannot be the zero address");
            require(!_allowedTokens[tokens[i].token], "duplicate token");
            require(tokens[i].unpinnedCap > 0, "unpinned cap must be positive");
            _allowedTokens[tokens[i].token] = true;
            expectedDecimals[tokens[i].token] = tokens[i].decimals_;
            MAX_LINK_AMOUNT_UNPINNED[tokens[i].token] = tokens[i].unpinnedCap;
        }
        feeAccount = feeAccount_;
        processor = processor_;
        circuitId = circuitId_;
        expectedProcessorCodehash = expectedProcessorCodehash_;
        circuitBeacon = circuitBeacon_;
        circuitImplementation = circuitImplementation_;
        expectedImplementationCodehash = expectedImplementationCodehash_;

        // Rule 6: the references are recorded here, but the verdict is not.
        // The ONLY path that may report the flag true is `evaluatorPinned()`,
        // which re-runs both legs of the real onchain implementation check on
        // every call (docs/RESEARCH.md section 18). A bool stored now would
        // freeze this moment's answer and outlive any later change behind the
        // beacon; the live view cannot.
        //
        // Leg 1 - the processor is a beacon proxy shell (295 bytes,
        // disassembled in section 18) that hardcodes its beacon address in
        // its own bytecode. Matching the shell's codehash proves the running
        // code is byte-for-byte that shell - the one bound to the beacon.
        //
        // Leg 2 - with the shell confirmed, ask the configured beacon's
        // public `implementation()` getter what it CURRENTLY reports: it must
        // still be the recorded `circuitImplementation`, and the code at that
        // address must still hash to `expectedImplementationCodehash`. The
        // call is a low-level staticcall with strict decoding (the same
        // discipline as `_eval`): a reverting beacon, an address with no
        // code, a short or long return - all fail this leg.
        //
        // Two guarantees, stated precisely (docs/RESEARCH.md section 18 Q2):
        // a wrong configured beacon can never make a WRONG EVALUATOR pass -
        // leg 1 pins the shell, and the genuine shell ignores configuration
        // and delegates to the beacon it hardcodes. What a wrong configured
        // beacon CAN do is make this leg pass while pointing elsewhere: any
        // address whose `implementation()` merely returns the recorded
        // implementation satisfies the getter check. So leg 2 checks the
        // CONFIGURED address, and the binding between that address and the
        // shell's hardcoded one is established offchain by disassembling the
        // shell - it cannot be rederived onchain (another account's storage
        // is unreadable and bytecode cannot be parsed here). On mainnet the
        // configured value IS that shell-embedded beacon, so the two agree
        // by construction rather than by this check.
        //
        // `changeDetector` is never consulted: a wrong, missing or replaced
        // implementation leaves the flag false and every link capped.
    }

    /// Rule 6's verdict, recomputed on every call - never a stored bool.
    ///
    /// Leg 1: `processor` still carries exactly the recorded shell code
    /// (`expectedProcessorCodehash`). Leg 2: the beacon still reports the
    /// recorded `circuitImplementation`, and the code at that address still
    /// hashes to `expectedImplementationCodehash`. Both legs must pass,
    /// every time, for as long as links exist.
    ///
    /// `changeDetector` cannot reach this function: it only ever compares,
    /// it never writes, and nothing else in this contract stores a verdict.
    /// A swapped shell, a beacon pointing elsewhere, a re-taped
    /// implementation - each fails here at the moment it is asked about, so
    /// the flag follows the chain instead of freezing deploy time. False (or
    /// any failure at all) means every link is capped and every claim uses
    /// the default split if the rule check fails.
    function evaluatorPinned() public view returns (bool) {
        // Leg 1 - the processor is still byte-for-byte the recorded shell.
        if (processor == address(0) || processor.code.length == 0 || processor.codehash != expectedProcessorCodehash) {
            return false;
        }

        // Leg 2 - the beacon's public `implementation()` getter, called as a
        // low-level staticcall with strict decoding (the same discipline as
        // `_eval`): a reverting beacon, no code, a short or long return, or
        // dirty padding all fail the leg rather than revert the caller.
        (bool ok, bytes memory ret) = circuitBeacon.staticcall(abi.encodeWithSelector(IBeaconLike.implementation.selector));
        if (!ok || ret.length != 32) return false;
        // Masked read, not abi.decode: dirty upper bits must fail the leg.
        address impl = address(uint160(uint256(bytes32(ret))));
        // "store the implementation address and its extcodehash and verify
        // both": the beacon must still name the recorded address, and the
        // code there must still hash to the recorded reference.
        if (impl != circuitImplementation) return false;
        if (impl.code.length == 0 || impl.codehash != expectedImplementationCodehash) return false;
        return true;
    }

    // ── payee ──────────────────────────────────────────────────────────────

    /// Record an invoice with its two preset split tables fixed (rules 2, 3, 5).
    ///
    /// Guards, in order: id length, allowlist, amount, description, uniqueness,
    /// expiry - as in the NEAR port - then the split tables, the unpinned cap
    /// (rule 6) and the netlist identity read (rule 5).
    function createLink(
        string calldata linkId,
        uint256 amount,
        address token,
        string calldata description,
        uint64 expiresAt,
        Split calldata defaultSplit,
        Split calldata ruleSplit
    ) external returns (Link memory) {
        require(
            bytes(linkId).length >= MIN_LINK_ID_LEN && bytes(linkId).length <= MAX_LINK_ID_LEN, "link id must be 4-64 characters"
        );
        require(_allowedTokens[token], "this token is not accepted");
        require(amount > 0, "amount must be greater than zero");
        require(bytes(description).length <= MAX_DESCRIPTION_LEN && !_isBlank(description), "description must be 1-280 characters");

        bytes32 key = keccak256(bytes(linkId));
        require(_links[key].creator == address(0), "link id already used");

        uint64 ts = nowMs();
        if (expiresAt != 0) {
            require(expiresAt > ts, "expiry must be in the future");
        }

        // Rule 3: the default table is the safety net, so it must be able to pay
        // out every unit on its own - exactly 100%, no seat left inconsistent.
        require(_validDefaultSplit(defaultSplit), "default split must pay exactly 100% in valid seats");
        // Rule 2/6: the rule table is a candidate, so its shares only have to be
        // representable in the circuit's 5-bit fields (0..31) with honest seats.
        // Its sum is deliberately NOT checked here - the circuit judges it.
        require(_validRuleSplit(ruleSplit), "rule split shares must be 0-31 with matching seats");

        // Rule 6: while the evaluator is unpinned no link may exceed the cap.
        // `evaluatorPinned()` is re-run here, so a link created after the
        // implementation changed is capped even if deploy time was pinned.
        if (!evaluatorPinned()) {
            require(amount <= MAX_LINK_AMOUNT_UNPINNED[token], "unpinned evaluator: link amount above cap");
        }

        // Rule 5: the link may only be created under a circuit whose netlist
        // identity can actually be read, and it records that identity.
        {
            bytes memory nl = _readNetlist();
            require(nl.length > 0, "circuit netlist is unreadable");
            _links[key].netlistHash = keccak256(nl);
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
        l.defaultSplit = defaultSplit;
        l.ruleSplit = ruleSplit;

        _byCreator[msg.sender].push(key);

        emit LinkCreated(key, msg.sender, token, amount, expiresAt);
        return _read(key);
    }

    /// Cancel an unpaid link. Callable only by the link's creator. Moves no money.
    function cancelLink(string calldata linkId) external returns (Link memory) {
        bytes32 key = keccak256(bytes(linkId));
        Link storage l = _links[key];
        require(l.creator != address(0), "link not found");
        require(msg.sender == l.creator, "only the creator can cancel");
        require(l.status == Status.Open, "link is not open");

        l.status = Status.Cancelled;
        emit LinkCancelled(key, msg.sender);
        return _read(key);
    }

    // ── payer ──────────────────────────────────────────────────────────────

    /// Settle an invoice by pulling the tokens from the caller.
    ///
    /// `expectedTermsHash` must equal `termsHash(linkId)` - the payer consents to
    /// the exact terms recorded onchain (rule 4). Every rejection path reverts
    /// before `transferFrom` runs, so a failed payment costs only gas (rule 8).
    ///
    /// @param amount May exceed `link.amount`; the whole amount is credited.
    function pay(string calldata linkId, uint256 amount, bytes32 expectedTermsHash) external nonReentrant {
        bytes32 key = keccak256(bytes(linkId));
        Link storage l = _links[key];
        _requireSettleable(l, msg.sender, amount);
        require(expectedTermsHash == keccak256(_termsBytes(l)), "terms hash mismatch");

        l.status = Status.Paid;
        l.paidBy = msg.sender;
        l.paidAmount = amount;
        l.paidAt = nowMs();

        emit LinkPaid(key, msg.sender, amount);

        _safeTransferFrom(l.token, msg.sender, address(this), amount);
    }

    /// Settle an invoice without the payer holding any OKB for gas: the payer
    /// signs an EIP-3009 authorization off-chain and a third party submits it.
    /// The nonce stays bound to `(linkKey, from)`, and `expectedTermsHash` binds
    /// the payer to the onchain terms exactly as `pay` does (rule 4).
    function payWithAuthorization(
        string calldata linkId,
        address from,
        uint256 value,
        uint64 validAfter,
        uint64 validBefore,
        bytes32 nonce,
        bytes calldata signature,
        bytes32 expectedTermsHash
    ) external nonReentrant {
        require(from != address(0) && from != address(this), "invalid payer");

        bytes32 key = keccak256(bytes(linkId));
        Link storage l = _links[key];
        _requireSettleable(l, from, value);
        require(uint256(nonce) == authorizationNonce(key, from), "authorization must be bound to this link");
        require(expectedTermsHash == keccak256(_termsBytes(l)), "terms hash mismatch");

        l.status = Status.Paid;
        l.paidBy = from;
        l.paidAmount = value;
        l.paidAt = nowMs();

        emit LinkPaid(key, from, value);

        IEIP3009(l.token).transferWithAuthorization(from, address(this), value, validAfter, validBefore, nonce, signature);
    }

    // ── payout ─────────────────────────────────────────────────────────────

    /// Release a paid invoice to the recipients of whichever preset split table
    /// applies, less the 0.5% fee. Callable by anyone; takes no result arguments;
    /// pays only the link's recipients and the fee account, never the caller as
    /// a reward (rule 1).
    ///
    /// The rule verdict comes from a strict, gas-limited `staticcall` to the
    /// processor (rule 2). Every failure mode - revert, malformed return, gas
    /// exhaustion, a verdict that would not conserve 100% - falls back to the
    /// default split fixed at creation (rule 3), so this function's only revert
    /// paths are "link not found" and "link is not paid".
    ///
    /// Rule 6 is checked HERE, live: `evaluatorPinned()` re-runs the two-leg
    /// implementation check in the same transaction, so if the implementation
    /// changed after the link was created the rule table is not even asked
    /// about and the default split applies instead (the master prompt's
    /// "verify both at claim").
    ///
    /// Each seat's transfer is independent (rule 9): a seat whose transfer fails
    /// does not block the others; its amount stays in the contract as
    /// `owed[recipient][token]`. The fee leg behaves the same way, and a fee of
    /// zero is skipped rather than transferred (rule 8).
    function claim(string calldata linkId) external nonReentrant {
        bytes32 key = keccak256(bytes(linkId));
        Link storage l = _links[key];
        require(l.creator != address(0), "link not found");
        // Written before any transfer so a second claim cannot start while this
        // one is in flight. A failure reverts the write along with the transfer.
        require(l.status == Status.Paid, "link is not paid");

        uint256 credited = l.paidAmount;
        (uint256 remainder, uint256 fee) = splitFee(credited);

        l.status = Status.Claimed;
        l.claimedAt = nowMs();

        // Rule 6 first, live: an unpinned evaluator may not use the rule
        // table at all - the default split fixed at creation applies.
        // Rule 2: the verdict only selects between the two tables fixed at
        // creation; rule 3: anything unexpected means the default table.
        bool usedRule = evaluatorPinned() && _ruleApplies(l);
        address[3] memory recipients;
        uint8[3] memory shares;
        if (usedRule) {
            recipients = l.ruleSplit.recipients;
            shares = l.ruleSplit.shares;
        } else {
            recipients = l.defaultSplit.recipients;
            shares = l.defaultSplit.shares;
        }

        emit LinkClaimed(key, remainder, fee, usedRule);

        // Rule 8: a fee that rounds to zero is skipped, not transferred.
        if (fee > 0) _payLeg(key, l.token, feeAccount, fee);

        // Divide `remainder` by cumulative shares. The last seat takes whatever
        // is left so payout + fee == credited holds to the unit (rule 10); both
        // reachable tables sum to SPLIT_STEPS, so the leftover is never forced.
        uint256 allocated;
        uint256 cum;
        for (uint256 i; i < SEATS; ++i) {
            cum += shares[i];
            uint256 target = (i == SEATS - 1) ? remainder : (remainder * cum) / SPLIT_STEPS;
            uint256 amount = target - allocated;
            allocated = target;
            if (amount > 0) _payLeg(key, l.token, recipients[i], amount);
        }
    }

    /// Withdraw this caller's own deferred payout legs (rule 9). The amount is
    /// read from storage; the caller supplies neither a recipient nor an amount.
    function withdrawOwed(address token) external nonReentrant returns (uint256 amount) {
        amount = owed[msg.sender][token];
        require(amount > 0, "nothing owed");
        owed[msg.sender][token] = 0;

        emit OwedWithdrawn(msg.sender, token, amount);
        // Reverting here is safe and intentional: this is the caller's own
        // withdrawal, nothing else is in flight, and they may simply retry.
        _safeTransfer(token, msg.sender, amount);
    }

    // ── reads ──────────────────────────────────────────────────────────────

    /// @return found False when no link was ever created under this id.
    /// @return link  With `status` replaced by the derived status.
    function getLink(string calldata linkId) external view returns (bool found, Link memory link) {
        bytes32 key = keccak256(bytes(linkId));
        found = _links[key].creator != address(0);
        link = _read(key);
    }

    /// A creator's ledger, oldest first. Never deletes a record.
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

    /// Fee in basis points (50 = 0.5%), read from the chain rather than a
    /// constant in the page.
    function feeBps() external pure returns (uint256) {
        return FEE_BPS;
    }

    function linkCountByCreator(address creator) external view returns (uint256) {
        return _byCreator[creator].length;
    }

    /// The storage key a link id hashes to.
    function linkKeyOf(string memory linkId) public pure returns (bytes32) {
        return keccak256(bytes(linkId));
    }

    /// The only nonce the token will accept for this payer on this link.
    function authorizationNonce(bytes32 linkKey, address from) public pure returns (uint256) {
        return uint256(keccak256(abi.encode(linkKey, from)));
    }

    /// ms since the Unix epoch, matching `created_at` / `expires_at`.
    function nowMs() public view returns (uint64) {
        return uint64(block.timestamp) * 1000;
    }

    /// Split a credited amount into `(post-fee remainder, fee)` with floor
    /// rounding; `payout + fee == amount` always (rule 10).
    function splitFee(uint256 amount) public pure returns (uint256 payout, uint256 fee) {
        fee = amount / BPS_DENOMINATOR * FEE_BPS + (amount % BPS_DENOMINATOR) * FEE_BPS / BPS_DENOMINATOR;
        payout = amount - fee;
    }

    /// The canonical byte string of everything a payer consents to: identity,
    /// money, description, deadline, both split tables, the fee terms and the
    /// circuit identity (rule 4). Every field in it is immutable after creation.
    function terms(string calldata linkId) external view returns (bytes memory) {
        Link storage l = _links[keccak256(bytes(linkId))];
        require(l.creator != address(0), "link not found");
        return _termsBytes(l);
    }

    /// keccak256(terms(linkId)) - what `pay` and `payWithAuthorization` demand
    /// as `expectedTermsHash` (rule 4).
    function termsHash(string calldata linkId) external view returns (bytes32) {
        Link storage l = _links[keccak256(bytes(linkId))];
        require(l.creator != address(0), "link not found");
        return keccak256(_termsBytes(l));
    }

    /// The known-answer check - a public view, never the source of `evaluatorPinned`
    /// (rule 6).
    ///
    /// Runs the processor over vectors whose correct verdict is known from
    /// Split3's exhaustive proof (every input of the whole 2^15 space is checked
    /// in test/Split3.t.sol): valid sums must answer 1, invalid sums must answer
    /// 0. Reverts, malformed returns, gas exhaustion or a wrong answer all make
    /// this return false. Anyone may call it: it is a view over published
    /// hardware (or over the labelled testnet stand-in).
    ///
    /// Rule 6 forbids this check from ever turning the flag on: `evaluatorPinned()`
    /// comes only from the live two-leg `extcodehash` implementation check.
    /// This function answers "does the linked processor behave correctly right
    /// now?" for anyone to read - the deploy log prints it as evidence - but it
    /// writes nothing, and `claim` never trusts it (rule 3's per-call strict
    /// staticcall with default-split fallback stands on its own).
    function changeDetector() public view returns (bool) {
        // (share1, share2, share3) -> expected single output bit.
        uint16[6] memory shares = [uint16(10 | (6 << 5) | (4 << 10)), uint16(20), uint16(0), uint16(10 | (8 << 5) | (4 << 10)), uint16(10 | (6 << 5) | (5 << 10)), uint16(31 | (31 << 5) | (31 << 10))];
        uint8[6] memory expected = [uint8(1), 1, 0, 0, 0, 0];

        for (uint256 i; i < shares.length; ++i) {
            (bool ok, uint256 bit) = _eval(uint256(shares[i]));
            if (!ok || bit != expected[i]) return false;
        }
        return true;
    }

    // ── internals ──────────────────────────────────────────────────────────

    /// Guards shared by `pay` and `payWithAuthorization`, in order: token
    /// allowlist, existence, stored status, self-payment, amount, deadline.
    function _requireSettleable(Link storage l, address sender, uint256 amount) private view {
        require(l.creator != address(0), "link not found");
        require(_allowedTokens[l.token], "this token is not accepted");
        require(l.status == Status.Open, "link is not open");
        require(sender != l.creator, "the payee cannot pay their own link");
        require(amount >= l.amount, "payment amount is too small");
        require(!_expired(l.expiresAt), "link has expired");
    }

    /// An open invoice past its deadline reports `EXPIRED`; stored status is
    /// untouched.
    function _read(bytes32 key) private view returns (Link memory l) {
        l = _links[key];
        if (l.status == Status.Open && _expired(l.expiresAt)) {
            l.status = Status.Expired;
        }
    }

    function _expired(uint64 expiresAt) private view returns (bool) {
        return expiresAt != 0 && nowMs() >= expiresAt;
    }

    function _termsBytes(Link storage l) private view returns (bytes memory) {
        return abi.encode(
            l.linkId,
            l.amount,
            l.token,
            l.description,
            l.expiresAt,
            l.defaultSplit,
            l.ruleSplit,
            FEE_BPS,
            feeAccount,
            l.netlistHash,
            processor,
            circuitId
        );
    }

    /// Rule 2, in one function: derive the inputs from state, call the processor
    /// under a gas cap with strict decoding, and let the bit only ever select
    /// between the tables already stored on the link.
    function _ruleApplies(Link storage l) private view returns (bool) {
        // Inputs: the rule table's three shares, 5 bits each, LSB-first - the
        // exact packing TAP-02 and Split3 use. The other state the rules name is
        // enforced where it belongs without consuming input bits Split3 does not
        // have: the deadline against block.timestamp at `pay`, and the credited
        // amount as this function's caller derives the payout base from it.
        uint256 inBits = uint256(l.ruleSplit.shares[0]) | (uint256(l.ruleSplit.shares[1]) << 5) | (uint256(l.ruleSplit.shares[2]) << 10);

        (bool ok, uint256 bit) = _eval(inBits);
        if (!ok || bit == 0) return false;

        // Solvency check (rule 3, "fails a check"): even if the evaluator said
        // yes, a table that does not sum to exactly 100% must never be paid -
        // otherwise a misbehaving evaluator could overdraw the contract. Honest
        // hardware never makes this branch reachable; the check exists so that
        // trusting it is not required.
        uint256 sum = uint256(l.ruleSplit.shares[0]) + uint256(l.ruleSplit.shares[1]) + uint256(l.ruleSplit.shares[2]);
        return sum == SPLIT_STEPS;
    }

    /// Strict, gas-limited `staticcall` to `processor.eval(circuitId, inputs)`.
    /// Returns (false, 0) for *any* deviation: revert, empty code at `processor`,
    /// gas exhaustion, wrong selector echo, wrong offset/length, a payload byte
    /// outside {0,1}, or non-zero padding. Callers treat that as "no verdict"
    /// and fall back to the default split.
    function _eval(uint256 inBits) private view returns (bool ok, uint256 bit) {
        // Split3 has 15 inputs -> ceil(15/8) = 2 bytes, LSB-first.
        bytes memory inputs = new bytes(2);
        inputs[0] = bytes1(uint8(inBits));
        inputs[1] = bytes1(uint8(inBits >> 8));

        bytes memory ret;
        bool success;
        (success, ret) = processor.staticcall{gas: EVAL_GAS_LIMIT}(abi.encodeWithSelector(IRuleProcessor.eval.selector, circuitId, inputs));
        return _decodeEvalReturn(success, ret);
    }

    /// Decode `abi.encode(bytes)` where the bytes payload is exactly one byte,
    /// 0 or 1, zero-padded to the word. `ret.length` must be exactly
    /// 32 (offset) + 32 (length) + 32 (one padded word) = 96.
    function _decodeEvalReturn(bool success, bytes memory ret) private pure returns (bool ok, uint256 bit) {
        if (!success) return (false, 0);
        if (ret.length != 96) return (false, 0);

        uint256 offset;
        uint256 length;
        uint256 word;
        assembly {
            offset := mload(add(ret, 32))
            length := mload(add(ret, 64))
            word := mload(add(ret, 96))
        }
        if (offset != 32 || length != 1) return (false, 0);
        if (word >> 248 > 1) return (false, 0); // payload must be 0 or 1
        if ((word << 8) != 0) return (false, 0); // padding must be zero
        return (true, word >> 248);
    }

    /// Rule 5: read the processor's netlist for `circuitId`, gas-limited. Empty
    /// result (no processor, no such circuit, revert, gas) means unreadable.
    function _readNetlist() private view returns (bytes memory) {
        (bool success, bytes memory ret) =
            processor.staticcall{gas: NETLIST_GAS_LIMIT}(abi.encodeWithSelector(IRuleProcessor.netlist.selector, circuitId));
        if (!success) return "";
        // `netlist(uint256) returns (bytes)`: head is offset + length; an empty
        // netlist has length 0 at offset 32.
        if (ret.length < 64) return "";
        uint256 offset;
        uint256 length;
        assembly {
            offset := mload(add(ret, 32))
            length := mload(add(ret, 64))
        }
        if (offset != 32 || length == 0) return "";
        if (ret.length != 64 + ((length + 31) / 32) * 32) return "";

        bytes memory nl = new bytes(length);
        for (uint256 i; i < length; ++i) {
            nl[i] = ret[64 + i];
        }
        return nl;
    }

    /// One payout leg: try the transfer; on any failure the amount stays in the
    /// contract as owed to that recipient and the other legs still run (rule 9).
    /// This function never reverts - a token that misbehaves must not be able to
    /// freeze a claim (rule 3).
    function _payLeg(bytes32 key, address token, address to, uint256 amount) private {
        (bool success, bytes memory ret) = token.call(abi.encodeWithSelector(IERC20.transfer.selector, to, amount));
        // Manual verdict instead of abi.decode: a token returning garbage must
        // defer the leg, not revert the claim.
        bool paid = success && (ret.length == 0 || (ret.length >= 32 && _word(ret) == 1));
        if (paid) {
            emit LegPaid(key, to, amount);
        } else {
            owed[to][token] += amount;
            emit LegOwed(key, to, amount);
        }
    }

    function _word(bytes memory b) private pure returns (uint256 w) {
        assembly {
            w := mload(add(b, 32))
        }
    }

    function _validDefaultSplit(Split memory s) private pure returns (bool) {
        uint256 sum;
        for (uint256 i; i < SEATS; ++i) {
            if ((s.recipients[i] == address(0)) != (s.shares[i] == 0)) return false;
            sum += s.shares[i];
        }
        return sum == SPLIT_STEPS;
    }

    function _validRuleSplit(Split memory s) private pure returns (bool) {
        for (uint256 i; i < SEATS; ++i) {
            if (s.shares[i] > MAX_SHARE) return false;
            if ((s.recipients[i] == address(0)) != (s.shares[i] == 0)) return false;
        }
        return true; // the sum is the circuit's verdict, not ours
    }

    /// `true` when the description is empty or holds nothing but whitespace.
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

    /// ERC-20 verdict for the *payer* path: a failed transferFrom must revert
    /// the whole payment (rule 8), so garbage returns raise "token transfer
    /// failed" rather than deferring.
    function _ok(bool success, bytes memory ret) private pure {
        require(success, "token transfer failed");
        if (ret.length == 0) return;
        require(ret.length >= 32 && _word(ret) == 1, "token transfer failed");
    }

    function _safeTransfer(address token, address to, uint256 amount) private {
        (bool success, bytes memory ret) = token.call(abi.encodeWithSelector(IERC20.transfer.selector, to, amount));
        _ok(success, ret);
    }

    function _safeTransferFrom(address token, address from, address to, uint256 amount) private {
        (bool success, bytes memory ret) = token.call(abi.encodeWithSelector(IERC20.transferFrom.selector, from, to, amount));
        _ok(success, ret);
    }
}

/// Minimal ERC-20 surface Pago calls. Written out rather than imported so the
/// contract has no external dependencies.
interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);

    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// The one getter rule 6's leg 2 calls: the beacon's public
/// `implementation()` (selector `0x5c60da1b`, verified live on X Layer
/// mainnet - docs/RESEARCH.md section 18). Any other surface fails the call
/// and therefore fails the leg.
interface IBeaconLike {
    function implementation() external view returns (address);
}

/// EIP-3009 `transferWithAuthorization`. Proven live on X Layer mainnet for
/// USDT0 and USDG in Phase 0 (docs/RESEARCH.md section 8).
interface IEIP3009 {
    function transferWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        bytes calldata signature
    ) external;
}
