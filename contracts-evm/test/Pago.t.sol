// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Pago} from "../src/Pago.sol";
import {MockToken} from "./mocks/MockToken.sol";
import {ProcessorStandIn} from "./mocks/ProcessorStandIn.sol";

/// Pago's unit suite: every guard, every money path, every ledger read.
///
/// It mirrors the NEAR contract's own test suite one concern at a time - fee
/// arithmetic, creation guards, the three refusal paths a payer can hit,
/// cancellation rules, expiry being derived rather than stored, payout
/// atomicity, and the gasless EIP-3009 payer path with its
/// signature-to-link binding - so a reviewer coming from the Rust original can
/// see that each property survived the port. The master-prompt rules
/// (docs/MASTER_PROMPT.md) that change existing behaviour live here too: terms
/// consent on `pay`, and deferred payout legs. The rule/processor paths and the
/// fuzz+invariant proofs have their own files: test/PagoRule.t.sol and
/// test/Pago.invariant.t.sol.
///
/// Runs against a local chain: no fork, no network, no keys.
contract PagoTest is Test {
    MockToken internal token;
    Pago internal pago;

    address internal feeAccount;
    address internal alice; // payee / creator
    address internal bob; // payer
    address internal keeper; // third party who triggers claim
    address internal relayer; // third party who submits an EIP-3009 payment

    uint256 internal payerPk = 0x5EED;
    address internal payer;

    uint256 internal constant AMOUNT = 1_000_000; // 1.00 mUSD at 6 decimals

    /// Cached `termsHash` per link id. Terms are immutable after creation, so
    /// reading the hash once at creation and reusing it is identical to calling
    /// `pago.termsHash` inline - but an inline call would be an *external call*
    /// evaluated before `pay`, consuming `vm.prank` / `vm.expectRevert` /
    /// `vm.expectEmit` meant for the payment itself.
    mapping(string => bytes32) internal terms_;

    function setUp() public {
        token = new MockToken("Mock USD", "mUSD", 6);
        feeAccount = makeAddr("feeAccount");
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        keeper = makeAddr("keeper");
        relayer = makeAddr("relayer");
        payer = vm.addr(payerPk);

        // The rule path runs against the stand-in processor, which executes the
        // real Split3 netlist bytes. The constructor is handed that stand-in's
        // own codehash as the implementation reference, so rule 6's code check
        // passes and the deployment starts pinned (no cap) - the same shape a
        // mainnet tier-2 deploy takes with the recorded TapeOut codehash. The
        // unpinned/capped path is covered in PagoRule.t.sol.
        ProcessorStandIn standIn = new ProcessorStandIn();
        Pago.TokenConfig[] memory configs = new Pago.TokenConfig[](1);
        configs[0] = Pago.TokenConfig({token: address(token), decimals_: 6, unpinnedCap: 10_000_000_000});
        pago = new Pago(configs, feeAccount, address(standIn), 1, address(standIn).codehash);
    }

    // ══ construction ═════════════════════════════════════════════════════

    function test_constructorRejectsEmptyTokenList() public {
        Pago.TokenConfig[] memory configs = new Pago.TokenConfig[](0);
        vm.expectRevert("at least one token must be allowed");
        new Pago(configs, feeAccount, address(0xDEAD), 1, bytes32(uint256(0xDEAD)));
    }

    function test_constructorRejectsZeroFeeAccount() public {
        Pago.TokenConfig[] memory configs = new Pago.TokenConfig[](1);
        configs[0] = Pago.TokenConfig({token: address(token), decimals_: 6, unpinnedCap: 1});
        vm.expectRevert("fee account required");
        new Pago(configs, address(0), address(0xDEAD), 1, bytes32(uint256(0xDEAD)));
    }

    function test_constructorRejectsZeroToken() public {
        Pago.TokenConfig[] memory configs = new Pago.TokenConfig[](1);
        configs[0] = Pago.TokenConfig({token: address(0), decimals_: 6, unpinnedCap: 1});
        vm.expectRevert("token cannot be the zero address");
        new Pago(configs, feeAccount, address(0xDEAD), 1, bytes32(uint256(0xDEAD)));
    }

    function test_constructorRejectsDuplicateToken() public {
        Pago.TokenConfig[] memory configs = new Pago.TokenConfig[](2);
        configs[0] = Pago.TokenConfig({token: address(token), decimals_: 6, unpinnedCap: 1});
        configs[1] = Pago.TokenConfig({token: address(token), decimals_: 6, unpinnedCap: 1});
        vm.expectRevert("duplicate token");
        new Pago(configs, feeAccount, address(0xDEAD), 1, bytes32(uint256(0xDEAD)));
    }

    /// Rule 6: a deployment that cannot pay its way out of the unpinned state
    /// would silently create links nobody may ever claim in full - refused.
    function test_constructorRejectsZeroUnpinnedCap() public {
        Pago.TokenConfig[] memory configs = new Pago.TokenConfig[](1);
        configs[0] = Pago.TokenConfig({token: address(token), decimals_: 6, unpinnedCap: 0});
        vm.expectRevert("unpinned cap must be positive");
        new Pago(configs, feeAccount, address(0xDEAD), 1, bytes32(uint256(0xDEAD)));
    }

    /// Rule 6: a missing implementation reference is refused outright - the
    /// flag must never be decidable from an empty configuration.
    function test_constructorRejectsMissingExpectedCodehash() public {
        Pago.TokenConfig[] memory configs = new Pago.TokenConfig[](1);
        configs[0] = Pago.TokenConfig({token: address(token), decimals_: 6, unpinnedCap: 1});
        vm.expectRevert("expected codehash required");
        new Pago(configs, feeAccount, address(0xDEAD), 1, bytes32(0));
    }

    /// Rule 6: the stand-in's code equals the reference the constructor was
    /// handed, so the deployment this suite runs against starts pinned. The
    /// known-answer view passes separately, as behavioural evidence only -
    /// it is never what sets the flag.
    function test_standInPassesTheImplementationCheck() public view {
        assertTrue(pago.evaluatorPinned(), "code present and equal to the expected codehash");
        assertTrue(pago.changeDetector(), "anyone may re-run the known-answer check");
    }

    /// Rule 7: expected decimals are ours, stored at deploy, never queried back.
    function test_expectedDecimalsAreStoredNotQueried() public view {
        assertEq(pago.expectedDecimals(address(token)), 6);
        assertEq(token.decimals(), 6, "the chain agrees - the deploy script aborts when it does not");
    }

    function test_constructorRegistersTheAllowlist() public view {
        assertTrue(pago.isTokenAllowed(address(token)));
        assertFalse(pago.isTokenAllowed(alice), "an arbitrary address must not be acceptable");
    }

    function test_feeIsHalfAPercent() public view {
        assertEq(pago.feeBps(), 50);
        assertEq(pago.FEE_BPS(), 50);
    }

    // ══ fee arithmetic ═══════════════════════════════════════════════════

    function test_splitFeeTakesHalfAPercent() public view {
        (uint256 payout, uint256 fee) = pago.splitFee(AMOUNT);
        assertEq(fee, 5_000);
        assertEq(payout, 995_000);
    }

    /// The decomposition must never lose or invent a unit, for any amount,
    /// including the largest uint256 - the invariant `payout + fee == amount`.
    function test_splitFeeConservesEveryUnit() public view {
        // 50 bps is exactly 1/200, so the reference fee is a plain divide.
        uint256[7] memory samples = [uint256(1), 9_999, 10_000, 10_001, 19_999, 1_000_000, type(uint256).max];
        for (uint256 i; i < samples.length; ++i) {
            uint256 amount = samples[i];
            (uint256 payout, uint256 fee) = pago.splitFee(amount);
            assertEq(payout + fee, amount, "split lost or invented units");
            assertEq(fee, amount / 200, "fee is not plain floor(amount / 200)");
            if (amount > 0) {
                assertGt(payout, 0, "payee must never be paid nothing");
            }
        }
    }

    function test_splitFeeRoundsDownOnTinyAmounts() public view {
        // 1 unit of a 6-decimal token: the fee rounds to zero, all of it is paid out.
        (uint256 payout, uint256 fee) = pago.splitFee(1);
        assertEq(fee, 0);
        assertEq(payout, 1);
    }

    // ══ createLink ═══════════════════════════════════════════════════════

    function test_createLinkStoresTheInvoice() public {
        bytes32 key = pago.linkKeyOf("invoice-1");

        vm.expectEmit(true, true, true, true);
        emit Pago.LinkCreated(key, alice, address(token), AMOUNT, 0);

        vm.prank(alice);
        Pago.Link memory l = pago.createLink("invoice-1", AMOUNT, address(token), "two coffees", 0, _defaultSplit(), _ruleSplit());

        assertEq(l.linkId, "invoice-1");
        assertEq(l.creator, alice);
        assertEq(l.amount, AMOUNT);
        assertEq(l.token, address(token));
        assertEq(l.description, "two coffees");
        assertEq(l.createdAt, pago.nowMs());
        assertEq(uint256(l.expiresAt), 0);
        assertTrue(l.status == Pago.Status.Open);
        assertEq(l.paidAmount, 0);
        assertEq(l.paidBy, address(0));
    }

    function test_createLinkRejectsShortLinkIds() public {
        vm.startPrank(alice);
        vm.expectRevert("link id must be 4-64 characters");
        pago.createLink("abc", AMOUNT, address(token), "x", 0, _defaultSplit(), _ruleSplit());

        vm.expectRevert("link id must be 4-64 characters");
        pago.createLink("", AMOUNT, address(token), "x", 0, _defaultSplit(), _ruleSplit());

        // Exactly four characters is fine.
        pago.createLink("abcd", AMOUNT, address(token), "x", 0, _defaultSplit(), _ruleSplit());
        vm.stopPrank();
    }

    function test_createLinkRejectsLongLinkIds() public {
        bytes memory tooLong = new bytes(65);
        for (uint256 i; i < tooLong.length; ++i) {
            tooLong[i] = 0x61;
        }

        vm.startPrank(alice);
        vm.expectRevert("link id must be 4-64 characters");
        pago.createLink(string(tooLong), AMOUNT, address(token), "x", 0, _defaultSplit(), _ruleSplit());

        // Exactly 64 is fine.
        bytes memory justRight = new bytes(64);
        for (uint256 i; i < justRight.length; ++i) {
            justRight[i] = 0x61;
        }
        pago.createLink(string(justRight), AMOUNT, address(token), "x", 0, _defaultSplit(), _ruleSplit());
        vm.stopPrank();
    }

    function test_createLinkRejectsDisallowedToken() public {
        vm.prank(alice);
        vm.expectRevert("this token is not accepted");
        pago.createLink("invoice-x", AMOUNT, keeper, "nope", 0, _defaultSplit(), _ruleSplit());
    }

    function test_createLinkRejectsZeroAmount() public {
        vm.startPrank(alice);
        vm.expectRevert("amount must be greater than zero");
        pago.createLink("invoice-0", 0, address(token), "x", 0, _defaultSplit(), _ruleSplit());
        vm.stopPrank();
    }

    function test_createLinkRejectsBlankDescription() public {
        vm.startPrank(alice);
        vm.expectRevert("description must be 1-280 characters");
        pago.createLink("invoice-b", AMOUNT, address(token), "", 0, _defaultSplit(), _ruleSplit());

        vm.expectRevert("description must be 1-280 characters");
        pago.createLink("invoice-b2", AMOUNT, address(token), "   \t\n  ", 0, _defaultSplit(), _ruleSplit());
        vm.stopPrank();
    }

    function test_createLinkRejectsOverlongDescription() public {
        bytes memory desc = new bytes(281);
        for (uint256 i; i < desc.length; ++i) {
            desc[i] = 0x61;
        }

        vm.startPrank(alice);
        vm.expectRevert("description must be 1-280 characters");
        pago.createLink("invoice-d", AMOUNT, address(token), string(desc), 0, _defaultSplit(), _ruleSplit());

        bytes memory ok = new bytes(280);
        for (uint256 i; i < ok.length; ++i) {
            ok[i] = 0x61;
        }
        pago.createLink("invoice-d2", AMOUNT, address(token), string(ok), 0, _defaultSplit(), _ruleSplit());
        vm.stopPrank();
    }

    function test_createLinkRejectsDuplicateId() public {
        vm.prank(alice);
        pago.createLink("invoice-dup", AMOUNT, address(token), "first", 0, _defaultSplit(), _ruleSplit());

        vm.prank(bob);
        vm.expectRevert("link id already used");
        pago.createLink("invoice-dup", AMOUNT, address(token), "second", 0, _defaultSplit(), _ruleSplit());
    }

    function test_createLinkRejectsExpiryInThePast() public {
        vm.warp(1_000);
        uint64 atCreation = pago.nowMs();

        vm.startPrank(alice);
        vm.expectRevert("expiry must be in the future");
        pago.createLink("invoice-e", AMOUNT, address(token), "x", atCreation - 1, _defaultSplit(), _ruleSplit());

        // Expiry exactly "now" is already too late to accept.
        vm.expectRevert("expiry must be in the future");
        pago.createLink("invoice-e2", AMOUNT, address(token), "x", atCreation, _defaultSplit(), _ruleSplit());
        vm.stopPrank();
    }

    function test_createLinkAcceptsZeroExpiryAsNeverExpiring() public {
        vm.prank(alice);
        Pago.Link memory l = pago.createLink("invoice-f", AMOUNT, address(token), "x", 0, _defaultSplit(), _ruleSplit());
        assertEq(uint256(l.expiresAt), 0);
        assertTrue(l.status == Pago.Status.Open);
    }

    function test_createLinkIsVisibleToTheLedger() public {
        vm.prank(alice);
        pago.createLink("invoice-l", AMOUNT, address(token), "x", 0, _defaultSplit(), _ruleSplit());

        assertTrue(pago.linkExists("invoice-l"));
        assertFalse(pago.linkExists("invoice-missing"));
        assertEq(pago.linkCountByCreator(alice), 1);
        assertEq(pago.linkCountByCreator(bob), 0);
    }

    // ══ pay ══════════════════════════════════════════════════════════════

    function test_payPullsTokensAndMarksPaid() public {
        _create("pay-1");
        _fundAndApprove(bob, AMOUNT);
        bytes32 key = pago.linkKeyOf("pay-1");

        vm.expectEmit(true, true, true, true);
        emit Pago.LinkPaid(key, bob, AMOUNT);

        vm.prank(bob);
        pago.pay("pay-1", AMOUNT, terms_["pay-1"]);

        assertEq(token.balanceOf(address(pago)), AMOUNT, "the contract must hold what was paid in");
        assertEq(token.balanceOf(bob), 0);

        (, Pago.Link memory l) = pago.getLink("pay-1");
        assertTrue(l.status == Pago.Status.Paid);
        assertEq(l.paidBy, bob);
        assertEq(l.paidAmount, AMOUNT);
        assertEq(l.paidAt, pago.nowMs());
    }

    function test_payRejectsUnknownLink() public {
        _fundAndApprove(bob, AMOUNT);
        vm.prank(bob);
        vm.expectRevert("link not found");
        pago.pay("nope", AMOUNT, terms_["nope"]);
    }

    function test_payeeCannotPayTheirOwnLink() public {
        _create("self-1");
        _fundAndApprove(alice, AMOUNT);

        vm.prank(alice);
        vm.expectRevert("the payee cannot pay their own link");
        pago.pay("self-1", AMOUNT, terms_["self-1"]);

        // The refusal happens before any token moves: the link is untouched.
        (, Pago.Link memory l) = pago.getLink("self-1");
        assertTrue(l.status == Pago.Status.Open);
        assertEq(token.balanceOf(address(pago)), 0);
    }

    function test_payRejectsUnderpayment() public {
        _create("under-1");
        _fundAndApprove(bob, AMOUNT);

        vm.prank(bob);
        vm.expectRevert("payment amount is too small");
        pago.pay("under-1", AMOUNT - 1, terms_["under-1"]);

        assertEq(token.balanceOf(bob), AMOUNT, "a rejected payment must cost only gas");
        (, Pago.Link memory l) = pago.getLink("under-1");
        assertTrue(l.status == Pago.Status.Open);
    }

    function test_payAcceptsOverpaymentAndCreditsAllOfIt() public {
        _create("over-1");
        uint256 over = AMOUNT * 3;
        _fundAndApprove(bob, over);

        vm.prank(bob);
        pago.pay("over-1", over, terms_["over-1"]);

        (, Pago.Link memory l) = pago.getLink("over-1");
        assertEq(l.paidAmount, over);
        assertTrue(l.status == Pago.Status.Paid);

        // The fee is charged on what actually arrived, at claim time.
        vm.prank(keeper);
        pago.claim("over-1");
        (uint256 payout, uint256 fee) = pago.splitFee(over);
        assertEq(token.balanceOf(alice), payout);
        assertEq(token.balanceOf(feeAccount), fee);
        assertEq(payout + fee, over);
    }

    function test_payRejectsAnExpiredLink() public {
        _createWithExpiry("exp-1", uint64(pago.nowMs() + 10_000));
        _fundAndApprove(bob, AMOUNT);

        vm.warp(uint256(pago.nowMs() / 1000) + 11); // past the ms deadline

        vm.prank(bob);
        vm.expectRevert("link has expired");
        pago.pay("exp-1", AMOUNT, terms_["exp-1"]);

        assertEq(token.balanceOf(bob), AMOUNT, "no tokens may move on an expired link");
        assertEq(token.balanceOf(address(pago)), 0);
    }

    function test_payRejectsACancelledLink() public {
        _create("cancel-pay-1");
        vm.prank(alice);
        pago.cancelLink("cancel-pay-1");

        _fundAndApprove(bob, AMOUNT);
        vm.prank(bob);
        vm.expectRevert("link is not open");
        pago.pay("cancel-pay-1", AMOUNT, terms_["cancel-pay-1"]);
        assertEq(token.balanceOf(address(pago)), 0, "a cancelled link must never receive funds");
    }

    function test_payRejectsAnAlreadyPaidLink() public {
        _create("twice-1");
        _fundAndApprove(bob, AMOUNT * 2);

        vm.startPrank(bob);
        pago.pay("twice-1", AMOUNT, terms_["twice-1"]);
        vm.expectRevert("link is not open");
        pago.pay("twice-1", AMOUNT, terms_["twice-1"]);
        vm.stopPrank();

        assertEq(token.balanceOf(address(pago)), AMOUNT, "double payment must not double the credit");
    }

    function test_payLeavesNoMoneyBehindOnFailure() public {
        _create("fail-1");
        token.mint(bob, AMOUNT);
        // No approval at all - the transferFrom must fail and unwind everything.
        vm.prank(bob);
        vm.expectRevert("token transfer failed");
        pago.pay("fail-1", AMOUNT, terms_["fail-1"]);

        (, Pago.Link memory l) = pago.getLink("fail-1");
        assertTrue(l.status == Pago.Status.Open, "a failed payment must leave no partial state");
        assertEq(l.paidAmount, 0);
        assertEq(token.balanceOf(address(pago)), 0);
    }

    // ══ cancellation ═════════════════════════════════════════════════════

    function test_creatorMayCancelAnUnpaidLink() public {
        _create("cancel-1");
        bytes32 key = pago.linkKeyOf("cancel-1");

        vm.expectEmit(true, true, true, true);
        emit Pago.LinkCancelled(key, alice);

        vm.prank(alice);
        Pago.Link memory l = pago.cancelLink("cancel-1");
        assertTrue(l.status == Pago.Status.Cancelled);
        assertEq(l.amount, AMOUNT, "cancellation must not rewrite the invoice");
        assertEq(l.paidAmount, 0);
        assertEq(l.paidBy, address(0));
    }

    function test_onlyTheCreatorMayCancel() public {
        _create("cancel-2");
        vm.prank(bob);
        vm.expectRevert("only the creator can cancel");
        pago.cancelLink("cancel-2");
    }

    function test_cancellingAnUnknownLinkFails() public {
        vm.prank(alice);
        vm.expectRevert("link not found");
        pago.cancelLink("cancel-missing");
    }

    function test_paidAndClaimedLinksAreNeverCancellable() public {
        _create("cancel-3");
        _fundAndApprove(bob, AMOUNT);
        vm.prank(bob);
        pago.pay("cancel-3", AMOUNT, terms_["cancel-3"]);

        vm.prank(alice);
        vm.expectRevert("link is not open");
        pago.cancelLink("cancel-3");

        vm.prank(keeper);
        pago.claim("cancel-3");

        vm.prank(alice);
        vm.expectRevert("link is not open");
        pago.cancelLink("cancel-3");

        (, Pago.Link memory l) = pago.getLink("cancel-3");
        assertTrue(l.status == Pago.Status.Claimed, "the winner of the race is settlement, not cancellation");
    }

    function test_cancellingTwiceFails() public {
        _create("cancel-4");
        vm.startPrank(alice);
        pago.cancelLink("cancel-4");
        vm.expectRevert("link is not open");
        pago.cancelLink("cancel-4");
        vm.stopPrank();
    }

    /// Cancellation is a pure status write: no transfer, no escrow release.
    function test_cancellationMovesNoMoney() public {
        _create("cancel-5");
        token.mint(alice, 123);
        token.mint(keeper, 456);

        uint256 contractBefore = token.balanceOf(address(pago));
        uint256 feeBefore = token.balanceOf(feeAccount);

        vm.prank(alice);
        pago.cancelLink("cancel-5");

        assertEq(token.balanceOf(address(pago)), contractBefore, "cancellation released escrow it never held");
        assertEq(token.balanceOf(feeAccount), feeBefore, "cancellation paid a fee it never owed");
        assertEq(token.balanceOf(alice), 123, "cancellation moved the creator's own balance");
        assertEq(token.balanceOf(keeper), 456);
    }

    function test_cancelAllowedOnAnExpiredButUnpaidLink() public {
        _createWithExpiry("cancel-exp", uint64(pago.nowMs() + 5_000));
        vm.warp(uint256(pago.nowMs() / 1000) + 6);

        (, Pago.Link memory before) = pago.getLink("cancel-exp");
        assertTrue(before.status == Pago.Status.Expired, "an overdue open link must read as expired");

        // The *stored* status is still Open, so the creator can still close it.
        vm.prank(alice);
        Pago.Link memory l = pago.cancelLink("cancel-exp");
        assertTrue(l.status == Pago.Status.Cancelled);
        assertTrue(pago.linkExists("cancel-exp"), "cancellation never deletes the record");
    }

    // ══ expiry ═══════════════════════════════════════════════════════════

    function test_expiryIsDerivedNotStored() public {
        _createWithExpiry("exp-2", uint64(pago.nowMs() + 10_000));

        (, Pago.Link memory open) = pago.getLink("exp-2");
        assertTrue(open.status == Pago.Status.Open);

        vm.warp(uint256(pago.nowMs() / 1000) + 11);

        (, Pago.Link memory expired) = pago.getLink("exp-2");
        assertTrue(expired.status == Pago.Status.Expired, "a read past the deadline must say expired");
        assertTrue(pago.linkExists("exp-2"), "an expired link still exists");
        assertEq(pago.linkCountByCreator(alice), 1, "expiry must not change the ledger");
    }

    function test_expiryNeverAppliesToALinkThatIsAlreadySettled() public {
        _createWithExpiry("exp-3", uint64(pago.nowMs() + 10_000));
        _fundAndApprove(bob, AMOUNT);
        vm.prank(bob);
        pago.pay("exp-3", AMOUNT, terms_["exp-3"]);

        vm.warp(uint256(pago.nowMs() / 1000) + 11);

        (, Pago.Link memory l) = pago.getLink("exp-3");
        assertTrue(l.status == Pago.Status.Paid, "settled work does not expire");
    }

    function test_neverExpiringLinkStaysOpen() public {
        _create("exp-never");
        // Ten-ish years on (2096). Well past any invoice's patience, and
        // still comfortably inside the millisecond range `nowMs` works in.
        vm.warp(4_000_000_000);
        (, Pago.Link memory l) = pago.getLink("exp-never");
        assertTrue(l.status == Pago.Status.Open);
    }

    function test_nowMsIsMilliseconds() public view {
        assertEq(pago.nowMs(), uint64(block.timestamp) * 1000);
    }

    // ══ claim ════════════════════════════════════════════════════════════

    function test_claimPaysThePayeeLessTheFee() public {
        _create("claim-1");
        _fundAndApprove(bob, AMOUNT);
        vm.prank(bob);
        pago.pay("claim-1", AMOUNT, terms_["claim-1"]);
        bytes32 key = pago.linkKeyOf("claim-1");

        vm.expectEmit(true, true, true, true);
        emit Pago.LinkClaimed(key, 995_000, 5_000, false);

        vm.prank(keeper);
        pago.claim("claim-1");

        assertEq(token.balanceOf(alice), 995_000);
        assertEq(token.balanceOf(feeAccount), 5_000);
        assertEq(token.balanceOf(address(pago)), 0, "nothing may be left stuck in the contract");
        assertEq(token.balanceOf(keeper), 0, "the caller must never be a recipient");

        (, Pago.Link memory l) = pago.getLink("claim-1");
        assertTrue(l.status == Pago.Status.Claimed);
        assertEq(l.claimedAt, pago.nowMs());
    }

    function test_claimIsCallableByAnyone() public {
        _create("claim-2");
        _fundAndApprove(bob, AMOUNT);
        vm.prank(bob);
        pago.pay("claim-2", AMOUNT, terms_["claim-2"]);

        // An uninvolved account triggers the payout and gains nothing.
        vm.prank(relayer);
        pago.claim("claim-2");

        assertEq(token.balanceOf(alice), 995_000);
        assertEq(token.balanceOf(relayer), 0);
        assertEq(token.balanceOf(feeAccount), 5_000);
    }

    function test_claimRejectsALinkThatWasNeverPaid() public {
        _create("claim-3");
        vm.prank(keeper);
        vm.expectRevert("link is not paid");
        pago.claim("claim-3");
    }

    function test_claimRejectsCancelledAndMissingLinks() public {
        _create("claim-4");
        vm.prank(alice);
        pago.cancelLink("claim-4");

        vm.startPrank(keeper);
        vm.expectRevert("link is not paid");
        pago.claim("claim-4");
        vm.expectRevert("link not found");
        pago.claim("claim-missing");
        vm.stopPrank();
    }

    function test_claimPaysExactlyOnce() public {
        _create("claim-5");
        _fundAndApprove(bob, AMOUNT);
        vm.prank(bob);
        pago.pay("claim-5", AMOUNT, terms_["claim-5"]);

        vm.prank(keeper);
        pago.claim("claim-5");

        vm.prank(keeper);
        vm.expectRevert("link is not paid");
        pago.claim("claim-5");

        assertEq(token.balanceOf(alice), 995_000, "a second claim must not pay twice");
        assertEq(token.balanceOf(feeAccount), 5_000);
    }

    /// Rule 3 + rule 9: a claim whose transfers all fail neither reverts nor
    /// freezes. The status moves to `Claimed` exactly once, every leg becomes
    /// owed to its recipient, the contract keeps precisely the money owed, and
    /// each recipient later withdraws their own share with `withdrawOwed`. The
    /// NEAR build's "rewind to Paid and re-claim" retry has no EVM equivalent
    /// once legs are independent - `withdrawOwed` is the retry.
    function test_failedPayoutsBecomeOwedAndAreWithdrawable() public {
        _create("claim-6");
        _fundAndApprove(bob, AMOUNT);
        vm.prank(bob);
        pago.pay("claim-6", AMOUNT, terms_["claim-6"]);

        token.setTransfersFailing(true);
        vm.prank(keeper);
        pago.claim("claim-6"); // must NOT revert

        (, Pago.Link memory afterFail) = pago.getLink("claim-6");
        assertTrue(afterFail.status == Pago.Status.Claimed, "claim completes even when transfers fail");
        assertEq(token.balanceOf(alice), 0, "no partial payout");
        assertEq(token.balanceOf(feeAccount), 0, "no partial fee");
        assertEq(token.balanceOf(address(pago)), AMOUNT, "the funds must still be held");
        assertEq(pago.owed(alice, address(token)), 995_000, "alice's share is owed to alice");
        assertEq(pago.owed(feeAccount, address(token)), 5_000, "the fee is owed to the fee account");

        token.setTransfersFailing(false);
        vm.prank(alice);
        assertEq(pago.withdrawOwed(address(token)), 995_000);
        vm.prank(feeAccount);
        pago.withdrawOwed(address(token));

        assertEq(token.balanceOf(alice), 995_000);
        assertEq(token.balanceOf(feeAccount), 5_000);
        assertEq(token.balanceOf(address(pago)), 0, "nothing may be left behind");
        vm.expectRevert("nothing owed");
        vm.prank(alice);
        pago.withdrawOwed(address(token));
    }

    function test_tinyInvoiceChargesNoFeeInsteadOfTransferringZero() public {
        vm.prank(alice);
        pago.createLink("claim-tiny", 1, address(token), "x", 0, _defaultSplit(), _ruleSplit());
        terms_["claim-tiny"] = pago.termsHash("claim-tiny");

        _fundAndApprove(bob, 1);
        vm.prank(bob);
        pago.pay("claim-tiny", 1, terms_["claim-tiny"]);

        vm.prank(keeper);
        pago.claim("claim-tiny");

        assertEq(token.balanceOf(alice), 1, "everything, when the fee rounds to zero");
        assertEq(token.balanceOf(feeAccount), 0, "no zero-amount fee transfer");
        assertEq(token.balanceOf(address(pago)), 0);
    }

    // ══ reads ════════════════════════════════════════════════════════════

    function test_getLinkReportsMissingLinks() public view {
        (bool found, Pago.Link memory l) = pago.getLink("nothing-here");
        assertFalse(found);
        assertEq(l.creator, address(0));
        assertEq(l.amount, 0);
    }

    function test_ledgerListsACreatorInCreationOrder() public {
        vm.startPrank(alice);
        pago.createLink("led-1", 10, address(token), "first", 0, _defaultSplit(), _ruleSplit());
        pago.createLink("led-2", 20, address(token), "second", 0, _defaultSplit(), _ruleSplit());
        pago.createLink("led-3", 30, address(token), "third", 0, _defaultSplit(), _ruleSplit());
        vm.stopPrank();

        vm.prank(bob);
        pago.createLink("led-other", 40, address(token), "someone else's", 0, _defaultSplit(), _ruleSplit());

        Pago.Link[] memory mine = pago.getLinksByCreator(alice);
        assertEq(mine.length, 3, "another creator's links must never appear in this ledger");
        assertEq(mine[0].linkId, "led-1");
        assertEq(mine[1].linkId, "led-2");
        assertEq(mine[2].linkId, "led-3");
        assertEq(mine[0].amount, 10);
        assertEq(mine[2].amount, 30);
    }

    function test_ledgerKeepsCancelledAndExpiredEntries() public {
        vm.startPrank(alice);
        pago.createLink("led-a", 10, address(token), "stays open", 0, _defaultSplit(), _ruleSplit());
        pago.createLink("led-b", 20, address(token), "gets cancelled", 0, _defaultSplit(), _ruleSplit());
        pago.createLink("led-c", 30, address(token), "will expire", uint64(pago.nowMs() + 5_000), _defaultSplit(), _ruleSplit());
        vm.stopPrank();

        vm.prank(alice);
        pago.cancelLink("led-b");

        vm.warp(uint256(pago.nowMs() / 1000) + 6);

        Pago.Link[] memory ledger = pago.getLinksByCreator(alice);
        assertEq(ledger.length, 3, "the ledger never deletes a record");
        assertTrue(ledger[0].status == Pago.Status.Open);
        assertTrue(ledger[1].status == Pago.Status.Cancelled);
        assertTrue(ledger[2].status == Pago.Status.Expired, "expiry is reported on read");
    }

    function test_linkKeyIsTheKeccakOfTheId() public view {
        assertEq(pago.linkKeyOf("abcde"), keccak256(bytes("abcde")));
        assertEq(
            pago.authorizationNonce(pago.linkKeyOf("abcde"), bob),
            uint256(keccak256(abi.encode(pago.linkKeyOf("abcde"), bob)))
        );
    }

    // ══ gasless payment (EIP-3009) ════════════════════════════════════════

    function test_gaslessPaymentMovesTokensWithoutThePayerCallingIn() public {
        _create("auth-1");
        token.mint(payer, AMOUNT);
        // Deliberately no approval: an EIP-3009 signature never needs one.

        bytes32 nonce = _nonce("auth-1", payer);
        bytes memory sig = _sign(payerPk, payer, AMOUNT, 0, type(uint64).max, nonce);

        vm.prank(relayer);
        pago.payWithAuthorization("auth-1", payer, AMOUNT, 0, type(uint64).max, nonce, sig, terms_["auth-1"]);

        assertEq(token.balanceOf(address(pago)), AMOUNT, "the signed value must have arrived");
        assertEq(token.balanceOf(payer), 0);
        assertEq(token.balanceOf(relayer), 0, "the relayer submitted but never received");

        (, Pago.Link memory l) = pago.getLink("auth-1");
        assertTrue(l.status == Pago.Status.Paid);
        assertEq(l.paidBy, payer, "the payer is whoever signed, not whoever relayed");
        assertEq(l.paidAmount, AMOUNT);
    }

    function test_gaslessPaymentCanBeClaimedLikeAnyOther() public {
        _create("auth-2");
        token.mint(payer, AMOUNT);
        bytes32 nonce = _nonce("auth-2", payer);
        bytes memory sig = _sign(payerPk, payer, AMOUNT, 0, type(uint64).max, nonce);

        vm.prank(relayer);
        pago.payWithAuthorization("auth-2", payer, AMOUNT, 0, type(uint64).max, nonce, sig, terms_["auth-2"]);

        vm.prank(keeper);
        pago.claim("auth-2");
        assertEq(token.balanceOf(alice), 995_000);
        assertEq(token.balanceOf(feeAccount), 5_000);
    }

    /// The whole point of the binding: one signed authorization can only ever
    /// settle the one link it was built for.
    function test_authorizationForOneLinkCannotSettleAnother() public {
        _create("auth-target");
        _create("auth-decoy");
        token.mint(payer, AMOUNT * 2);

        // Sign for the decoy...
        bytes32 decoyNonce = _nonce("auth-decoy", payer);
        bytes memory sig = _sign(payerPk, payer, AMOUNT, 0, type(uint64).max, decoyNonce);

        // ...but submit it against the target.
        vm.prank(relayer);
        vm.expectRevert("authorization must be bound to this link");
        pago.payWithAuthorization("auth-target", payer, AMOUNT, 0, type(uint64).max, decoyNonce, sig, terms_["auth-target"]);

        assertEq(token.balanceOf(payer), AMOUNT * 2, "a misbound signature must move nothing");
        (, Pago.Link memory target) = pago.getLink("auth-target");
        assertTrue(target.status == Pago.Status.Open);
    }

    function test_authorizationCannotBeReplayed() public {
        _create("auth-replay");
        token.mint(payer, AMOUNT * 2);
        bytes32 nonce = _nonce("auth-replay", payer);
        bytes memory sig = _sign(payerPk, payer, AMOUNT, 0, type(uint64).max, nonce);

        vm.prank(relayer);
        pago.payWithAuthorization("auth-replay", payer, AMOUNT, 0, type(uint64).max, nonce, sig, terms_["auth-replay"]);

        vm.prank(relayer);
        vm.expectRevert("link is not open");
        pago.payWithAuthorization("auth-replay", payer, AMOUNT, 0, type(uint64).max, nonce, sig, terms_["auth-replay"]);

        assertEq(token.balanceOf(address(pago)), AMOUNT, "a replay must not double the credit");
    }

    function test_authorizationSignedByTheWrongKeyIsRefused() public {
        _create("auth-badkey");
        token.mint(payer, AMOUNT);
        bytes32 nonce = _nonce("auth-badkey", payer);
        // `payer` is named as the source, but the signature comes from another key.
        bytes memory sig = _sign(0xDEAD, payer, AMOUNT, 0, type(uint64).max, nonce);

        vm.prank(relayer);
        vm.expectRevert("invalid signature");
        pago.payWithAuthorization("auth-badkey", payer, AMOUNT, 0, type(uint64).max, nonce, sig, terms_["auth-badkey"]);
        assertEq(token.balanceOf(payer), AMOUNT);
    }

    function test_authorizationIsRefusedOutsideItsTimeWindow() public {
        _create("auth-window");
        token.mint(payer, AMOUNT * 2);
        bytes32 nonce = _nonce("auth-window", payer);

        // validBefore already passed.
        uint64 nowTs = uint64(block.timestamp);
        bytes memory expired = _sign(payerPk, payer, AMOUNT, 0, nowTs, nonce);
        vm.prank(relayer);
        vm.expectRevert("authorization expired");
        pago.payWithAuthorization("auth-window", payer, AMOUNT, 0, nowTs, nonce, expired, terms_["auth-window"]);

        // validAfter not reached yet.
        bytes memory early = _sign(payerPk, payer, AMOUNT, nowTs, type(uint64).max, nonce);
        vm.prank(relayer);
        vm.expectRevert("authorization not yet valid");
        pago.payWithAuthorization("auth-window", payer, AMOUNT, nowTs, type(uint64).max, nonce, early, terms_["auth-window"]);

        assertEq(token.balanceOf(payer), AMOUNT * 2, "out-of-window authorizations must move nothing");
    }

    function test_gaslessPathEnforcesTheSameGuardsAsTheOrdinaryPath() public {
        _create("auth-guards");
        token.mint(payer, AMOUNT);
        bytes32 nonce = _nonce("auth-guards", payer);
        bytes memory sig = _sign(payerPk, payer, AMOUNT, 0, type(uint64).max, nonce);

        // Too small.
        vm.prank(relayer);
        vm.expectRevert("payment amount is too small");
        pago.payWithAuthorization("auth-guards", payer, AMOUNT - 1, 0, type(uint64).max, nonce, sig, terms_["auth-guards"]);

        // Unknown link.
        vm.prank(relayer);
        vm.expectRevert("link not found");
        pago.payWithAuthorization("auth-missing", payer, AMOUNT, 0, type(uint64).max, nonce, sig, terms_["auth-missing"]);
    }

    function test_gaslessPathRefusesThePayeePayingThemselves() public {
        uint256 payeePk = 0xA11CE;
        address payee = vm.addr(payeePk);

        // The payee creates the invoice, then signs an authorization against it.
        vm.prank(payee);
        pago.createLink("auth-self", AMOUNT, address(token), "x", 0, _defaultSplit(), _ruleSplit());
        terms_["auth-self"] = pago.termsHash("auth-self");
        token.mint(payee, AMOUNT);

        bytes32 nonce = _nonce("auth-self", payee);
        bytes memory sig = _sign(payeePk, payee, AMOUNT, 0, type(uint64).max, nonce);

        vm.prank(relayer);
        vm.expectRevert("the payee cannot pay their own link");
        pago.payWithAuthorization("auth-self", payee, AMOUNT, 0, type(uint64).max, nonce, sig, terms_["auth-self"]);
        assertEq(token.balanceOf(payee), AMOUNT, "a self-payment must move nothing");
    }

    function test_gaslessPathRejectsTheZeroPayer() public {
        _create("auth-zero");
        bytes32 nonce = _nonce("auth-zero", address(0));
        vm.prank(relayer);
        vm.expectRevert("invalid payer");
        pago.payWithAuthorization("auth-zero", address(0), AMOUNT, 0, type(uint64).max, nonce, hex"", terms_["auth-zero"]);
    }

    // ══ internals ════════════════════════════════════════════════════════

    function _create(string memory id) internal {
        _createWithExpiry(id, 0);
    }

    function _createWithExpiry(string memory id, uint64 expiresAt) internal {
        vm.prank(alice);
        pago.createLink(id, AMOUNT, address(token), "one coffee", expiresAt, _defaultSplit(), _ruleSplit());
        terms_[id] = pago.termsHash(id);
    }

    /// The default table these tests create links with: alice takes 100% (20
    /// steps), the other seats unused. Chosen so the payout assertions written
    /// against the single-payee NEAR port stay literally true.
    function _defaultSplit() internal view returns (Pago.Split memory s) {
        s.recipients = [alice, address(0), address(0)];
        s.shares = [uint8(20), 0, 0];
    }

    /// The rule table: three seats summing to 23 steps - invalid on purpose.
    /// The circuit rejects it (23 != 20), so `claim` falls back to the default
    /// table and every single-payee assertion above keeps holding. The rule
    /// path itself is proven in test/PagoRule.t.sol with honest tables.
    function _ruleSplit() internal view returns (Pago.Split memory s) {
        s.recipients = [alice, bob, keeper];
        s.shares = [uint8(10), 8, 5];
    }

    function _fundAndApprove(address who, uint256 amount) internal {
        token.mint(who, amount);
        vm.startPrank(who);
        token.approve(address(pago), type(uint256).max);
        vm.stopPrank();
    }

    function _nonce(string memory id, address from) internal view returns (bytes32) {
        return bytes32(pago.authorizationNonce(pago.linkKeyOf(id), from));
    }

    function _sign(uint256 pk, address from, uint256 value, uint64 validAfter, uint64 validBefore, bytes32 nonce)
        internal
        view
        returns (bytes memory)
    {
        bytes32 digest = token.digestOf(from, address(pago), value, validAfter, validBefore, nonce);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }
}
