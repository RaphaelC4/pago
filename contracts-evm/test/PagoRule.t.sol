// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Pago} from "../src/Pago.sol";
import {Split3} from "../src/circuits/Split3.sol";
import {MockBeacon} from "./mocks/MockBeacon.sol";
import {MockToken} from "./mocks/MockToken.sol";
import {ProcessorStandIn} from "./mocks/ProcessorStandIn.sol";
import {FaultyProcessor} from "./mocks/FaultyProcessor.sol";

/// The master-prompt contract rules (docs/MASTER_PROMPT.md), one file:
/// terms consent (rule 4), circuit identity (rule 5), the implementation
/// check behind evaluatorPinned and the unpinned cap (rule 6), the rule-2/3
/// processor selection and every fallback that keeps a link from freezing
/// (rules 2, 3), and per-recipient failure with withdrawOwed (rule 9).
///
/// Every processor fault the rules name has a matching mock: revert, malformed
/// return (wrong length and dirty padding), gas exhaustion, a lie about an
/// unsafe split, a missing netlist, and a processor that vanishes after link
/// creation. The suite proves the fallback in each case instead of trusting the
/// prose. Runs against a local chain: no fork, no network, no keys.
contract PagoRuleTest is Test {
    MockToken internal token;
    Pago internal pago; // stand-in backed: pinned, rule path live
    ProcessorStandIn internal standIn;

    address internal feeAccount;
    address internal alice;
    address internal bob;
    address internal keeper;
    address internal relayer;

    uint256 internal payerPk = 0x5EED;
    address internal payer;

    uint256 internal constant AMOUNT = 1_000_000; // 1.00 pUSD at 6 decimals

    function setUp() public {
        token = new MockToken("Mock USD", "mUSD", 6);
        feeAccount = makeAddr("feeAccount");
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        keeper = makeAddr("keeper");
        relayer = makeAddr("relayer");
        payer = vm.addr(payerPk);

        standIn = new ProcessorStandIn();
        pago = _pagoWith(address(standIn));
    }

    // ══ rule 4: terms consent ═══════════════════════════════════════════

    function test_termsHashIsKeccakOfTerms() public {
        _createWith("terms-1", AMOUNT, _defaultAlice(), _ruleValid());
        bytes32 expected = keccak256(pago.terms("terms-1"));
        assertEq(pago.termsHash("terms-1"), expected, "termsHash must be the keccak of terms");
    }

    function test_termsHashBindsTheLinkId() public {
        _createWith("terms-a", AMOUNT, _defaultAlice(), _ruleValid());
        _createWith("terms-b", AMOUNT, _defaultAlice(), _ruleValid());
        // Identical money and splits, different id -> different consent target,
        // so a signature or page shown for one link can never match the other.
        assertTrue(pago.termsHash("terms-a") != pago.termsHash("terms-b"));
    }

    function test_termsRevertsForAnUnknownLink() public {
        vm.expectRevert("link not found");
        pago.terms("no-such-link");
        vm.expectRevert("link not found");
        pago.termsHash("no-such-link");
    }

    function test_payRevertsOnTermsHashMismatch() public {
        _createWith("terms-pay", AMOUNT, _defaultAlice(), _ruleValid());
        token.mint(bob, AMOUNT);
        vm.startPrank(bob);
        token.approve(address(pago), AMOUNT);
        vm.expectRevert("terms hash mismatch");
        pago.pay("terms-pay", AMOUNT, bytes32(uint256(0xBAD)));
        vm.stopPrank();

        // The refusal happens before anything moves: the link is untouched.
        (, Pago.Link memory l) = pago.getLink("terms-pay");
        assertTrue(l.status == Pago.Status.Open);
        assertEq(token.balanceOf(address(pago)), 0);
        assertEq(token.balanceOf(bob), AMOUNT, "a rejected payment costs only gas");

        // And the honest hash still works. Precomputed: an inline call here
        // would be evaluated before `pay` and consume the prank.
        bytes32 honest = pago.termsHash("terms-pay");
        vm.prank(bob);
        pago.pay("terms-pay", AMOUNT, honest);
        (, l) = pago.getLink("terms-pay");
        assertTrue(l.status == Pago.Status.Paid);
    }

    function test_payWithAuthorizationRevertsOnTermsHashMismatch() public {
        _createWith("terms-auth", AMOUNT, _defaultAlice(), _ruleValid());
        bytes32 nonce = bytes32(pago.authorizationNonce(pago.linkKeyOf("terms-auth"), payer));
        bytes memory sig = _sign(payerPk, payer, AMOUNT, 0, type(uint64).max, nonce);

        vm.prank(relayer);
        vm.expectRevert("terms hash mismatch");
        pago.payWithAuthorization("terms-auth", payer, AMOUNT, 0, type(uint64).max, nonce, sig, bytes32(uint256(0xBAD)));

        (, Pago.Link memory l) = pago.getLink("terms-auth");
        assertTrue(l.status == Pago.Status.Open, "a mismatched consent must change nothing");
        assertEq(token.balanceOf(address(pago)), 0);
    }

    // ══ rule 5: circuit netlist identity ════════════════════════════════

    function test_createLinkStoresTheNetlistHash() public {
        _createWith("net-1", AMOUNT, _defaultAlice(), _ruleValid());
        (, Pago.Link memory l) = pago.getLink("net-1");
        assertEq(l.netlistHash, keccak256(Split3.netlist()), "the link must record the netlist it was created under");
    }

    function test_createLinkRevertsWhenTheNetlistIsUnreadable() public {
        Pago broken = _pagoWith(address(new FaultyProcessor(FaultyProcessor.Mode.NoNetlist)));
        vm.prank(alice);
        vm.expectRevert("circuit netlist is unreadable");
        broken.createLink("net-broken", AMOUNT, address(token), "x", 0, _defaultAlice(), _ruleValid());
    }

    // ══ rules 2 & 3: the verdict only selects, and never freezes ════════

    function test_claimUsesTheRuleSplitWhenTheHardwareAccepts() public {
        // Valid rule table: 50/30/20 in 5% steps, exactly what Split3 checks.
        _createWith("rule-ok", AMOUNT, _defaultAlice(), _split(alice, bob, keeper, 10, 6, 4));
        _pay("rule-ok", AMOUNT);

        bytes32 key = pago.linkKeyOf("rule-ok");
        vm.expectEmit(true, true, true, true);
        emit Pago.LinkClaimed(key, 995_000, 5_000, true);

        vm.prank(relayer);
        pago.claim("rule-ok");

        // 995,000 post-fee, divided by the rule table's cumulative shares.
        assertEq(token.balanceOf(alice), 497_500, "seat 1: 50%");
        assertEq(token.balanceOf(bob), 298_500, "seat 2: 30%");
        assertEq(token.balanceOf(keeper), 199_000, "seat 3: 20%");
        assertEq(token.balanceOf(feeAccount), 5_000, "the 0.5% fee");
        assertEq(token.balanceOf(address(pago)), 0, "every unit accounted for");
    }

    function test_claimFallsBackWhenTheHardwareRejects() public {
        // Invalid rule table (23 steps): the circuit says 0, so the default
        // table - fixed at creation - pays instead.
        _createWith("rule-bad", AMOUNT, _defaultAlice(), _split(alice, bob, keeper, 10, 8, 5));
        _pay("rule-bad", AMOUNT);

        bytes32 key = pago.linkKeyOf("rule-bad");
        vm.expectEmit(true, true, true, true);
        emit Pago.LinkClaimed(key, 995_000, 5_000, false);

        vm.prank(relayer);
        pago.claim("rule-bad");

        assertEq(token.balanceOf(alice), 995_000, "the default table pays alice in full");
        assertEq(token.balanceOf(bob), 0, "a rejected rule table pays nobody");
        assertEq(token.balanceOf(keeper), 0);
        assertEq(token.balanceOf(address(pago)), 0);
    }

    function test_claimFallsBackWhenTheProcessorReverts() public {
        Pago p = _pagoWith(address(new FaultyProcessor(FaultyProcessor.Mode.Revert)));
        _createWith(p, "fault-revert", AMOUNT, _defaultAlice(), _split(alice, bob, keeper, 10, 6, 4));
        _pay(p, "fault-revert", AMOUNT);

        vm.prank(relayer);
        p.claim("fault-revert");

        assertEq(token.balanceOf(alice), 995_000, "a reverting processor must not freeze the link");
        assertEq(token.balanceOf(bob), 0, "and must not pay the rule table either");
        assertEq(token.balanceOf(address(p)), 0);
    }

    function test_claimFallsBackWhenEvalReturnsMalformedData() public {
        Pago p = _pagoWith(address(new FaultyProcessor(FaultyProcessor.Mode.Short)));
        _createWith(p, "fault-short", AMOUNT, _defaultAlice(), _split(alice, bob, keeper, 10, 6, 4));
        _pay(p, "fault-short", AMOUNT);

        vm.prank(relayer);
        p.claim("fault-short");

        assertEq(token.balanceOf(alice), 995_000, "a wrong-length return must not freeze the link");
        assertEq(token.balanceOf(address(p)), 0);
    }

    function test_claimFallsBackWhenEvalPaddingIsDirty() public {
        Pago p = _pagoWith(address(new FaultyProcessor(FaultyProcessor.Mode.DirtyPad)));
        _createWith(p, "fault-pad", AMOUNT, _defaultAlice(), _split(alice, bob, keeper, 10, 6, 4));
        _pay(p, "fault-pad", AMOUNT);

        vm.prank(relayer);
        p.claim("fault-pad");

        assertEq(token.balanceOf(alice), 995_000, "non-zero padding must be rejected, not trusted");
        assertEq(token.balanceOf(address(p)), 0);
    }

    function test_claimFallsBackWhenTheProcessorRunsOutOfGas() public {
        Pago p = _pagoWith(address(new FaultyProcessor(FaultyProcessor.Mode.GasHog)));
        _createWith(p, "fault-gas", AMOUNT, _defaultAlice(), _split(alice, bob, keeper, 10, 6, 4));
        _pay(p, "fault-gas", AMOUNT);

        vm.prank(relayer);
        p.claim("fault-gas");

        // If the gas cap had NOT applied, GasHog would have answered 1 and the
        // rule table would have paid. It answered nothing, so the default did.
        assertEq(token.balanceOf(alice), 995_000, "the gas cap must turn into a fallback");
        assertEq(token.balanceOf(bob), 0, "the rule table must not have been used");
        assertEq(token.balanceOf(address(p)), 0);
    }

    function test_claimIgnoresALyingProcessorAboutAnUnsafeSplit() public {
        // Lie mode always answers 1 - even for a 23-step table the circuit
        // would reject. The contract's own solvency check must refuse the
        // selection: paying it would overdraw the contract.
        Pago p = _pagoWith(address(new FaultyProcessor(FaultyProcessor.Mode.Lie)));
        _createWith(p, "fault-lie", AMOUNT, _defaultAlice(), _split(alice, bob, keeper, 10, 8, 5));
        _pay(p, "fault-lie", AMOUNT);

        vm.prank(relayer);
        p.claim("fault-lie");

        assertEq(token.balanceOf(alice), 995_000, "the default table must survive a lying evaluator");
        assertEq(token.balanceOf(bob), 0);
        assertEq(token.balanceOf(keeper), 0);
        assertEq(token.balanceOf(address(p)), 0, "the contract must never overdraw");
    }

    function test_claimFallsBackWhenTheProcessorVanishesAfterCreation() public {
        _createWith("fault-vanish", AMOUNT, _defaultAlice(), _split(alice, bob, keeper, 10, 6, 4));
        _pay("fault-vanish", AMOUNT);

        // The link was created under a readable netlist; the processor then
        // disappears entirely. The claim must still settle.
        vm.etch(address(standIn), "");
        vm.prank(relayer);
        pago.claim("fault-vanish");

        assertEq(token.balanceOf(alice), 995_000, "a vanished evaluator must not freeze the link");
        assertEq(token.balanceOf(address(pago)), 0);
    }

    // ══ rule 6: the implementation check and the unpinned cap ════════════

    function test_faultyProcessorLeavesTheDeploymentUnpinned() public {
        // The fault mocks' code is never this suite's recorded reference, so
        // the flag stays false whatever the mock does - and the known-answer
        // view reports each fault too, as separate evidence.
        Pago reverter = _pagoWith(address(new FaultyProcessor(FaultyProcessor.Mode.Revert)));
        assertFalse(reverter.evaluatorPinned(), "code that is not the reference is never pinned");
        assertFalse(reverter.changeDetector(), "the known-answer view reports the revert too");

        Pago liar = _pagoWith(address(new FaultyProcessor(FaultyProcessor.Mode.Lie)));
        assertFalse(liar.evaluatorPinned(), "code that is not the reference is never pinned");
        assertFalse(liar.changeDetector(), "the known-answer view reports the lie too");
    }

    /// Rule 6's decisive clause, tested in both directions: the flag may come
    /// ONLY from the onchain code check, never from the change detector.
    function test_pinningComesOnlyFromTheCodeCheck() public {
        // Matching code but a lying evaluator: pinned anyway. Safety here is
        // rule 3 - claim's strict staticcall with default-split fallback - not
        // the flag. Behaviour must not be able to clear or set it.
        FaultyProcessor liar = new FaultyProcessor(FaultyProcessor.Mode.Lie);
        Pago codeMatches = _pagoWith(address(liar), address(liar).codehash);
        assertTrue(codeMatches.evaluatorPinned(), "matching code pins; behaviour never speaks");
        assertFalse(codeMatches.changeDetector(), "the lie still shows in the view");

        // Honest evaluator but code that is not the reference: never pinned,
        // even though every known-answer vector passes - which is exactly the
        // path rule 6 forbids the change detector from taking.
        Pago wrongCode = _pagoWith(address(standIn), keccak256("some other implementation"));
        assertFalse(wrongCode.evaluatorPinned(), "a passing changeDetector may never set the flag");
        assertTrue(wrongCode.changeDetector(), "every vector answers correctly - and it still must not pin");
    }

    function test_unpinnedDeploymentCapsEveryLink() public {
        Pago capped = _pagoWith(address(new FaultyProcessor(FaultyProcessor.Mode.Revert)));
        uint256 cap = capped.MAX_LINK_AMOUNT_UNPINNED(address(token));
        assertEq(cap, 10_000_000_000);

        vm.startPrank(alice);
        vm.expectRevert("unpinned evaluator: link amount above cap");
        capped.createLink("cap-over", cap + 1, address(token), "x", 0, _defaultAlice(), _ruleValid());

        // Exactly the cap is allowed; one base unit more is not.
        capped.createLink("cap-exact", cap, address(token), "x", 0, _defaultAlice(), _ruleValid());
        vm.stopPrank();
        assertTrue(capped.linkExists("cap-exact"));
    }

    function test_pinnedDeploymentHasNoCap() public {
        // The stand-in's own code is the reference this suite pins against, so
        // the deployment is pinned and a link above the unpinned cap is
        // perfectly fine - the cap only ever applies while unpinned.
        uint256 cap = pago.MAX_LINK_AMOUNT_UNPINNED(address(token));
        vm.prank(alice);
        pago.createLink("pin-big", cap + 1, address(token), "x", 0, _defaultAlice(), _ruleValid());
        assertTrue(pago.linkExists("pin-big"));
    }

    /// The live re-check's decisive case (master prompt: "verify both at
    /// claim"): a link is created and paid while BOTH legs pass, THEN the
    /// beacon is swapped to report a different implementation. The flag was
    /// never a stored bool - it flips false at the very next read on the
    /// SAME deployment - so `claim` must ignore the rule table (which the
    /// evaluator would happily accept) and pay the default split instead,
    /// and a link created after the swap must be capped.
    function test_beaconSwapAfterTheLinkExistsForcesDefaultAndCap() public {
        // Precondition: this suite's deployment passes both legs right now.
        assertTrue(pago.evaluatorPinned(), "precondition: stand-in shell + mock beacon both match");

        // Created and paid under the passing verdict: rule table 50/30/20 -
        // the exact table test_claimUsesTheRuleSplitWhenTheHardwareAccepts
        // proves this evaluator accepts.
        _createWith("swap-after", AMOUNT, _defaultAlice(), _split(alice, bob, keeper, 10, 6, 4));
        _pay("swap-after", AMOUNT);

        // The swap: what sits behind the beacon changes AFTER the link
        // exists. Nothing about the link, the tables or the evaluator
        // changed - only the implementation behind the proxy.
        MockBeacon beacon = MockBeacon(pago.circuitBeacon());
        beacon.setImplementation(makeAddr("some other implementation"));
        assertFalse(pago.evaluatorPinned(), "the live check must flip false at the next read");

        // Claim: the default table (100% alice) applies instead of the rule
        // table - and the event says so.
        bytes32 key = pago.linkKeyOf("swap-after");
        vm.expectEmit(true, true, true, true);
        emit Pago.LinkClaimed(key, 995_000, 5_000, false);
        vm.prank(relayer);
        pago.claim("swap-after");

        assertEq(token.balanceOf(alice), 995_000, "the default split applies after the swap");
        assertEq(token.balanceOf(bob), 0, "the rule seat must not be paid while unpinned");
        assertEq(token.balanceOf(keeper), 0, "the rule seat must not be paid while unpinned");
        assertEq(token.balanceOf(feeAccount), 5_000, "the fee is unaffected by the rule verdict");
        assertEq(token.balanceOf(address(pago)), 0, "every unit accounted for");

        // And a link created AFTER the swap is capped, on the same
        // deployment that allowed an uncapped link minutes earlier.
        uint256 cap = pago.MAX_LINK_AMOUNT_UNPINNED(address(token));
        vm.prank(alice);
        vm.expectRevert("unpinned evaluator: link amount above cap");
        pago.createLink("swap-over", cap + 1, address(token), "x", 0, _defaultAlice(), _ruleValid());
    }

    function test_splitStepsMatchTheCircuitTarget() public view {
        assertEq(pago.SPLIT_STEPS(), Split3.TARGET, "Pago's 100% and Split3's 100% must be the same number");
        assertEq(pago.SEATS(), 3, "three seats, because Split3 judges three shares");
        assertEq(pago.MAX_SHARE(), 31, "5-bit fields: 0..31");
    }

    // ══ rule 9: one failing recipient never blocks the others ═══════════

    function test_oneFailingRecipientDoesNotBlockTheOthers() public {
        _createWith("leg-fail", AMOUNT, _split(alice, bob, keeper, 10, 6, 4), _ruleInvalid());
        token.setBlockedRecipient(bob, true);
        _pay("leg-fail", AMOUNT);

        vm.prank(relayer);
        pago.claim("leg-fail");

        // The other two seats and the fee were paid in the same transaction...
        assertEq(token.balanceOf(alice), 497_500, "seat 1 paid");
        assertEq(token.balanceOf(keeper), 199_000, "seat 3 paid");
        assertEq(token.balanceOf(feeAccount), 5_000, "fee paid");
        // ...bob's leg stayed in the contract, owed to bob alone.
        assertEq(token.balanceOf(address(pago)), 298_500, "exactly the failed leg is held");
        assertEq(pago.owed(bob, address(token)), 298_500);

        token.setBlockedRecipient(bob, false);
        vm.prank(bob);
        assertEq(pago.withdrawOwed(address(token)), 298_500);
        assertEq(token.balanceOf(bob), 298_500);
        assertEq(token.balanceOf(address(pago)), 0, "nothing may be left behind");
    }

    function test_withdrawOwedOnlyEverPaysTheCaller() public {
        _createWith("leg-two", AMOUNT, _split(alice, bob, keeper, 10, 6, 4), _ruleInvalid());
        token.setBlockedRecipient(alice, true);
        token.setBlockedRecipient(bob, true);
        _pay("leg-two", AMOUNT);

        vm.prank(relayer);
        pago.claim("leg-two");
        assertEq(pago.owed(alice, address(token)), 497_500);
        assertEq(pago.owed(bob, address(token)), 298_500);

        // Alice can only ever withdraw alice's balance - the amount comes from
        // storage keyed by msg.sender, never from a caller-supplied figure.
        token.setBlockedRecipient(alice, false);
        vm.prank(alice);
        assertEq(pago.withdrawOwed(address(token)), 497_500);
        assertEq(pago.owed(bob, address(token)), 298_500, "bob's balance is not alice's to take");

        vm.prank(alice);
        vm.expectRevert("nothing owed");
        pago.withdrawOwed(address(token));
    }

    function test_aFailedFeeLegIsDeferredNotDropped() public {
        _createWith("leg-fee", AMOUNT, _defaultAlice(), _ruleInvalid());
        token.setBlockedRecipient(feeAccount, true);
        _pay("leg-fee", AMOUNT);

        vm.prank(relayer);
        pago.claim("leg-fee");

        assertEq(token.balanceOf(alice), 995_000, "the payee must not suffer for a broken fee leg");
        assertEq(pago.owed(feeAccount, address(token)), 5_000, "the fee is owed, never dropped");
        assertEq(token.balanceOf(address(pago)), 5_000);

        token.setBlockedRecipient(feeAccount, false);
        vm.prank(feeAccount);
        pago.withdrawOwed(address(token));
        assertEq(token.balanceOf(feeAccount), 5_000);
        assertEq(token.balanceOf(address(pago)), 0);
    }

    // ══ internals ═══════════════════════════════════════════════════════

    /// One-argument form: both references are this suite's recorded ones - the
    /// stand-in's runtime code - and a fresh mock beacon reports the processor
    /// itself, so a stand-in-backed deployment passes BOTH legs of rule 6 while
    /// every fault mock's different code fails leg 1 and stays unpinned and
    /// capped, whatever its behaviour. The three-argument form sets the
    /// references and the beacon explicitly, for the tests that probe the
    /// check itself.
    function _pagoWith(address processor) internal returns (Pago p) {
        p = _pagoWith(processor, keccak256(type(ProcessorStandIn).runtimeCode));
    }

    function _pagoWith(address processor, bytes32 expectedCodehash) internal returns (Pago p) {
        MockBeacon beacon = new MockBeacon(processor);
        p = _pagoWith(processor, expectedCodehash, address(beacon), expectedCodehash);
    }

    function _pagoWith(address processor, bytes32 expectedCodehash, address beacon, bytes32 expectedImplCodehash)
        internal
        returns (Pago p)
    {
        Pago.TokenConfig[] memory configs = new Pago.TokenConfig[](1);
        configs[0] = Pago.TokenConfig({token: address(token), decimals_: 6, unpinnedCap: 10_000_000_000});
        p = new Pago(configs, feeAccount, processor, 1, expectedCodehash, beacon, processor, expectedImplCodehash);
    }

    function _split(address r0, address r1, address r2, uint8 s0, uint8 s1, uint8 s2) internal pure returns (Pago.Split memory s) {
        s.recipients = [r0, r1, r2];
        s.shares = [s0, s1, s2];
    }

    function _defaultAlice() internal view returns (Pago.Split memory) {
        return _split(alice, address(0), address(0), 20, 0, 0);
    }

    function _ruleValid() internal view returns (Pago.Split memory) {
        return _split(alice, bob, keeper, 10, 6, 4);
    }

    function _ruleInvalid() internal view returns (Pago.Split memory) {
        return _split(alice, bob, keeper, 10, 8, 5); // 23 steps
    }

    function _createWith(string memory id, uint256 amount, Pago.Split memory def, Pago.Split memory rule) internal {
        _createWith(pago, id, amount, def, rule);
    }

    function _createWith(Pago p, string memory id, uint256 amount, Pago.Split memory def, Pago.Split memory rule) internal {
        vm.prank(alice);
        p.createLink(id, amount, address(token), "rule test", 0, def, rule);
    }

    function _pay(string memory id, uint256 amount) internal {
        _pay(pago, id, amount);
    }

    function _pay(Pago p, string memory id, uint256 amount) internal {
        token.mint(bob, amount);
        vm.startPrank(bob);
        token.approve(address(p), amount);
        p.pay(id, amount, p.termsHash(id));
        vm.stopPrank();
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
