// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Pago} from "../src/Pago.sol";
import {MockBeacon} from "./mocks/MockBeacon.sol";
import {MockToken} from "./mocks/MockToken.sol";
import {ProcessorStandIn} from "./mocks/ProcessorStandIn.sol";

/// Rule 10 of the master prompt (docs/MASTER_PROMPT.md), proven rather than
/// asserted: payouts + fee == credited, the contract balance always covers what
/// it still owes, and a link's status never moves backward.
///
/// Two layers:
///
///   * `testFuzz_claimConservesEveryUnit` - a direct fuzz over amounts and
///     split shapes: after create -> pay -> claim, every base unit is in a
///     recipient's or the fee account's balance and the contract holds zero.
///   * The handler/invariant pair below - a stateful fuzzer that interleaves
///     create, pay, claim, cancel and withdraw in random order across a pool of
///     links, recording violations as flags (a reverting handler assertion
///     would only roll back that call and hide the bug).
///
/// Runs against a local chain: no fork, no network, no keys.
contract PagoInvariantTest is Test {
    PagoHandler internal handler;

    function setUp() public {
        handler = new PagoHandler();

        bytes4[] memory selectors = new bytes4[](5);
        selectors[0] = PagoHandler.actCreate.selector;
        selectors[1] = PagoHandler.actPay.selector;
        selectors[2] = PagoHandler.actClaim.selector;
        selectors[3] = PagoHandler.actCancel.selector;
        selectors[4] = PagoHandler.actWithdraw.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// Rule 10: balance >= owed - the contract always holds at least what it
    /// has promised to accounts whose transfers failed.
    function invariant_balanceAlwaysCoversOwed() public view {
        assertGe(handler.token().balanceOf(address(handler.pago())), handler.owedTotal(), "balance must cover owed");
    }

    /// Rule 10, exact: every token the contract holds is either credited to a
    /// link still waiting to be claimed, or owed to a recipient whose transfer
    /// failed - nothing is created, nothing is lost.
    function invariant_balanceEqualsUnclaimedPlusOwed() public view {
        assertEq(
            handler.token().balanceOf(address(handler.pago())),
            handler.ghostUnclaimed() + handler.owedTotal(),
            "held == unclaimed credited + owed"
        );
    }

    /// Rule 10: after every claim, payouts + fee == credited, to the unit.
    function invariant_payoutsPlusFeeAlwaysEqualCredited() public view {
        assertFalse(handler.conservationBroke(), "a claim must divide the credited amount exactly");
    }

    /// Rule 10: Open -> Paid -> Claimed, Open -> Cancelled, never backward.
    function invariant_statusNeverMovesBackward() public view {
        assertFalse(handler.statusWentBackward(), "status must be monotonic");
    }
}

/// The stateful actor the invariant fuzzer drives. Each action is idempotent-
/// enough to be called in any order: guards are re-checked inside, impossible
/// moves become no-ops, and violations are *recorded* so the invariant
/// functions above can fail loudly instead of a handler revert hiding them.
contract PagoHandler is Test {
    MockToken public token;
    Pago public pago;

    address public constant CREATOR = address(0xC0FFEE);
    address public constant PAYER = address(0xB0B);
    address public constant FEE_ACCOUNT = address(0xFEE);

    /// The only addresses a generated split may name (seat i -> seats[i]).
    address[3] public seats;

    string[] public ids;

    /// Rule 10 ghosts and violation flags.
    uint256 public ghostUnclaimed;
    bool public conservationBroke;
    bool public statusWentBackward;
    mapping(bytes32 => uint8) public maxRank;

    constructor() {
        seats = [address(0x1111), address(0x2222), address(0x3333)];

        token = new MockToken("Invariant USD", "iUSD", 6);
        ProcessorStandIn standIn = new ProcessorStandIn();
        MockBeacon beacon = new MockBeacon(address(standIn));

        Pago.TokenConfig[] memory configs = new Pago.TokenConfig[](1);
        configs[0] = Pago.TokenConfig({token: address(token), decimals_: 6, unpinnedCap: 10_000_000_000});
        pago = new Pago(configs, FEE_ACCOUNT, address(standIn), 1, address(standIn).codehash, address(beacon), address(standIn), address(standIn).codehash);

        for (uint256 i; i < 12; ++i) {
            ids.push(string(abi.encodePacked("inv-", vm.toString(i))));
        }
    }

    // ── actions ────────────────────────────────────────────────────────────

    function actCreate(uint256 seed) external {
        string memory id = ids[seed % ids.length];
        if (pago.linkExists(id)) return;

        uint256 r = uint256(keccak256(abi.encode(seed, "create")));
        uint256 amount = bound(r, 1, 1_000_000_000);

        // A default table that always sums to exactly 20 steps.
        uint256 d0 = bound(r >> 8, 0, 20);
        uint256 d1 = bound(r >> 16, 0, 20 - d0);
        uint256 d2 = 20 - d0 - d1;
        Pago.Split memory def = _table(d0, d1, d2);

        // A rule table with unconstrained shares (0..31 each): valid sums let
        // the circuit select it, invalid sums make claim fall back to `def`.
        Pago.Split memory rule = _table(bound(r >> 24, 0, 31), bound(r >> 32, 0, 31), bound(r >> 40, 0, 31));

        vm.prank(CREATOR);
        pago.createLink(id, amount, address(token), "invariant", 0, def, rule);
        _observe(id);
    }

    function actPay(uint256 seed) external {
        string memory id = ids[seed % ids.length];
        (bool found, Pago.Link memory l) = pago.getLink(id);
        if (!found || l.status != Pago.Status.Open) return;

        uint256 extra = bound(uint256(keccak256(abi.encode(seed, "pay"))), 0, 1_000);
        uint256 amount = l.amount + extra; // overpay sometimes; never underpay

        token.mint(PAYER, amount);
        vm.startPrank(PAYER);
        token.approve(address(pago), amount);
        pago.pay(id, amount, pago.termsHash(id));
        vm.stopPrank();

        ghostUnclaimed += amount;
        _observe(id);
    }

    function actClaim(uint256 seed) external {
        string memory id = ids[seed % ids.length];
        (bool found, Pago.Link memory l) = pago.getLink(id);
        if (!found || l.status != Pago.Status.Paid) return;

        uint256 credited = l.paidAmount;
        uint256 balBefore = token.balanceOf(address(pago));
        uint256 owedBefore = owedTotal();

        pago.claim(id);

        // Rule 10: payouts + fee == credited. Recorded, not asserted - a
        // reverting handler would roll back the claim and hide the breach.
        uint256 moved = balBefore - token.balanceOf(address(pago));
        uint256 newlyOwed = owedTotal() - owedBefore;
        if (moved + newlyOwed != credited) conservationBroke = true;

        ghostUnclaimed -= credited;
        _observe(id);
    }

    function actCancel(uint256 seed) external {
        string memory id = ids[seed % ids.length];
        (bool found, Pago.Link memory l) = pago.getLink(id);
        if (!found || l.status != Pago.Status.Open) return;

        vm.prank(CREATOR);
        pago.cancelLink(id);
        _observe(id);
    }

    function actWithdraw(uint256 seed) external {
        address[4] memory accounts = [seats[0], seats[1], seats[2], FEE_ACCOUNT];
        address who = accounts[seed % 4];
        uint256 owed = pago.owed(who, address(token));
        if (owed == 0) return;

        vm.prank(who);
        pago.withdrawOwed(address(token));
    }

    // ── reads used by the invariants ───────────────────────────────────────

    function owedTotal() public view returns (uint256 total) {
        address[6] memory accounts = [CREATOR, PAYER, seats[0], seats[1], seats[2], FEE_ACCOUNT];
        for (uint256 i; i < accounts.length; ++i) {
            total += pago.owed(accounts[i], address(token));
        }
    }

    // ── internals ──────────────────────────────────────────────────────────

    /// Record the link's current status rank; flag any move backward.
    /// Open/Expired = 0, Paid = 1, Claimed = 2, Cancelled = 3.
    function _observe(string memory id) internal {
        (bool found, Pago.Link memory l) = pago.getLink(id);
        if (!found) return;
        uint8 rank = l.status == Pago.Status.Paid
            ? 1
            : (l.status == Pago.Status.Claimed ? 2 : (l.status == Pago.Status.Cancelled ? 3 : 0));
        bytes32 key = keccak256(bytes(id));
        if (rank < maxRank[key]) statusWentBackward = true;
        if (rank > maxRank[key]) maxRank[key] = rank;
    }

    /// A three-seat table: seat i takes `shares[i]` steps, and a zero share
    /// always means a zero recipient (Pago enforces the same pairing).
    function _table(uint256 s0, uint256 s1, uint256 s2) internal view returns (Pago.Split memory t) {
        t.shares = [uint8(s0), uint8(s1), uint8(s2)];
        t.recipients = [
            s0 > 0 ? seats[0] : address(0),
            s1 > 0 ? seats[1] : address(0),
            s2 > 0 ? seats[2] : address(0)
        ];
    }
}

/// Rule 10 as a plain fuzz test: whatever the amount and whatever the split,
/// claim divides everything exactly and leaves the contract empty.
contract PagoFuzzTest is Test {
    MockToken internal token;
    Pago internal pago;

    address internal feeAccount = address(0xFEE);
    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);
    address internal carol = address(0xCA401);

    function setUp() public {
        token = new MockToken("Fuzz USD", "fUSD", 6);
        ProcessorStandIn standIn = new ProcessorStandIn();
        MockBeacon beacon = new MockBeacon(address(standIn));
        Pago.TokenConfig[] memory configs = new Pago.TokenConfig[](1);
        configs[0] = Pago.TokenConfig({token: address(token), decimals_: 6, unpinnedCap: 10_000_000_000});
        pago = new Pago(configs, feeAccount, address(standIn), 1, address(standIn).codehash, address(beacon), address(standIn), address(standIn).codehash);
    }

    function testFuzz_claimConservesEveryUnit(uint96 rawAmount, uint8 a, uint8 b) public {
        uint256 amount = bound(uint256(rawAmount), 1, 1_000_000_000);
        uint256 s0 = bound(uint256(a), 0, 20);
        uint256 s1 = bound(uint256(b), 0, 20 - s0);
        uint256 s2 = 20 - s0 - s1;

        Pago.Split memory def;
        def.shares = [uint8(s0), uint8(s1), uint8(s2)];
        def.recipients = [s0 > 0 ? alice : address(0), s1 > 0 ? bob : address(0), s2 > 0 ? carol : address(0)];
        Pago.Split memory rule;
        rule.shares = [uint8(10), 8, 5]; // invalid on purpose: default always pays
        rule.recipients = [alice, bob, carol];

        vm.prank(alice);
        pago.createLink("fuzz-1", amount, address(token), "fuzz", 0, def, rule);

        token.mint(bob, amount);
        vm.startPrank(bob);
        token.approve(address(pago), amount);
        pago.pay("fuzz-1", amount, pago.termsHash("fuzz-1"));
        vm.stopPrank();

        vm.prank(carol);
        pago.claim("fuzz-1");

        (uint256 payout, uint256 fee) = pago.splitFee(amount);
        uint256 paidOut = token.balanceOf(alice) + token.balanceOf(bob) + token.balanceOf(carol) + token.balanceOf(feeAccount);
        assertEq(paidOut, amount, "payouts + fee == credited, to the unit");
        assertEq(token.balanceOf(address(pago)), 0, "the contract must end empty");
        assertEq(payout + fee, amount, "splitFee itself conserves");
    }
}
