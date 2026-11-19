// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {Pago} from "../src/Pago.sol";
import {MockBeacon} from "./mocks/MockBeacon.sol";
import {MockToken} from "./mocks/MockToken.sol";

/// Rule 6's two-leg implementation check against the genuine X Layer mainnet
/// chain (docs/RESEARCH.md section 18): the recorded processor shell, the
/// recorded circuit beacon and the recorded circuit implementation, plus the
/// Q4 swap case - moving what sits behind the proxy must flip the flag false.
///
/// Runs against a local fork of chain 196. No transaction is ever broadcast:
/// every call here is a read, and `vm.etch` changes only this test's local
/// fork state.
contract ForkPinTest is Test {
    // Processor #340: the 295-byte beacon-proxy shell disassembled in §18.
    address constant PROCESSOR = 0x9de448A1CE9537d24199B3b5355239d73aA6F591;
    // The beacon hardcoded inside that shell (its EIP-1967 slot and PUSH32).
    address constant BEACON = 0xf70d1ed4f62CF3780157B0b421b7E2F45bD0991C;
    // The implementation the beacon's public getter reports.
    address constant IMPL = 0x977f217887E085D298Cb3819cDAD5A0ee35F29B2;

    // Recorded references, probed 2026-11-18 (§18). Deliberately literals:
    // the point of the check is that these were recorded offchain, never read
    // live from the fork being tested against.
    bytes32 constant RECORDED_SHELL = 0x57aa306fd0be97087da3534e03398f5ff4efd533b5be4e45a405ce86fa6717d5;
    bytes32 constant RECORDED_IMPL = 0x7a15c353205e5245f40f5f5524542a982a4bb3b9a28476e4f10845163f941b30;

    MockToken internal token;

    function setUp() public {
        vm.createSelectFork(vm.envString("XLAYER_RPC"));
        token = new MockToken("Fork USD", "fkUSD", 6);
    }

    /// One deployment of Pago against whatever the fork currently holds at
    /// PROCESSOR and BEACON, with both recorded references.
    function _deploy() internal returns (Pago p) {
        Pago.TokenConfig[] memory configs = new Pago.TokenConfig[](1);
        configs[0] = Pago.TokenConfig({token: address(token), decimals_: 6, unpinnedCap: 10_000_000_000});
        p = new Pago(configs, makeAddr("fee"), PROCESSOR, 1, RECORDED_SHELL, BEACON, IMPL, RECORDED_IMPL);
    }

    function test_theGenuineChainPins() public {
        // Sanity: the fork really is the chain these references came from.
        assertEq(PROCESSOR.codehash, RECORDED_SHELL, "forked shell must match the recorded probe");
        assertEq(IMPL.codehash, RECORDED_IMPL, "forked implementation must match the recorded probe");

        Pago p = _deploy();
        assertTrue(p.evaluatorPinned(), "genuine shell + genuine beacon-reported implementation pins");
        console.log("evaluatorPinned on the genuine chain:", p.evaluatorPinned());
    }

    function test_beaconGetterIsReachableFromTheConstructor() public view {
        // Leg 2's raw material: the beacon answers implementation() onchain.
        (bool ok, bytes memory ret) = BEACON.staticcall(abi.encodeWithSignature("implementation()"));
        assertTrue(ok, "beacon.implementation() must succeed");
        assertEq(ret.length, 32, "one address, ABI encoded");
        assertEq(address(uint160(uint256(bytes32(ret)))), IMPL, "the getter must report the recorded implementation");
    }

    /// Q4's swap case: keep the shell identical, move what sits behind the
    /// proxy - the flag must flip to false. Implemented by `vm.etch`-ing a
    /// code-only beacon over BEACON that returns a different address from its
    /// runtime code (PUSH32 addr / MSTORE / RETURN), so nothing but the
    /// beacon's code differs from the genuine chain.
    function test_swappingTheImplementationBehindTheProxyFlipsTheFlagFalse() public {
        assertTrue(_deploy().evaluatorPinned(), "precondition: the genuine chain pins");

        address otherImpl = makeAddr("some other implementation");
        vm.etch(BEACON, _constBeaconCode(otherImpl));

        Pago p = _deploy();
        assertFalse(p.evaluatorPinned(), "a beacon reporting different code must never pin");
        console.log("evaluatorPinned after the swap:", p.evaluatorPinned());

        // And the swap is visible to anyone: the getter now says otherwise.
        (bool ok, bytes memory ret) = BEACON.staticcall(abi.encodeWithSignature("implementation()"));
        assertTrue(ok, "the swapped beacon still answers");
        assertEq(address(uint160(uint256(bytes32(ret)))), otherImpl, "the swapped beacon reports the other address");
    }

    /// Leg 1 in isolation: identical beacon, corrupted shell. Etching over the
    /// processor changes its codehash, so the first leg fails even though the
    /// beacon half of the chain is untouched.
    function test_aChangedShellNeverPins() public {
        address otherShell = makeAddr("some other shell");
        vm.etch(PROCESSOR, _constBeaconCode(otherShell)); // any code that is not the recorded shell

        Pago p = _deploy();
        assertFalse(p.evaluatorPinned(), "a shell whose hash is not the recorded one must never pin");
    }

    /// The live re-check, end to end against the genuine chain: a link is
    /// created, paid and claimed while BOTH legs pass (the rule table is
    /// paid - proof the real evaluator was consulted), THEN the beacon is
    /// swapped. On the SAME deployment the flag flips false at the next
    /// read - it was never a stored bool - so the next claim uses the
    /// default split, and a link created after the swap is capped.
    /// No transaction is broadcast: `vm.etch` changes only this test's
    /// local fork state.
    function test_swapAfterTheLinkExistsForcesDefaultSplitAndCap() public {
        Pago p = _deploy();
        assertTrue(p.evaluatorPinned(), "precondition: genuine shell + genuine implementation pins");

        address creator = makeAddr("creator");
        address payer = makeAddr("payer");
        address relayer = makeAddr("relayer");

        // ── link A: created, paid and claimed WHILE the check passes ─────
        // Default 100% to carolA; rule 15/3/2 (sum 20 = 100%), the exact
        // input bytes (0x6f08) the genuine circuit answers 1 to (§18 probe:
        // `cast call #340 "eval(uint256,bytes)" 1 0x6f08` -> 1).
        address carolA = makeAddr("carolA");
        vm.prank(creator);
        p.createLink(
            "fork-rule",
            1_000_000,
            address(token),
            "claimed while pinned",
            0,
            _split(carolA, address(0), address(0), 20, 0, 0),
            _split(carolA, makeAddr("seatA1"), makeAddr("seatA2"), 15, 3, 2)
        );
        _payTo(p, "fork-rule", payer, 1_000_000);

        bytes32 keyA = p.linkKeyOf("fork-rule");
        vm.expectEmit(true, true, true, true);
        emit Pago.LinkClaimed(keyA, 995_000, 5_000, true); // usedRuleSplit = true
        vm.prank(relayer);
        p.claim("fork-rule");
        assertEq(token.balanceOf(carolA), 746_250, "rule seat 1: 75% - the genuine evaluator said yes");
        assertEq(token.balanceOf(makeAddr("seatA1")), 149_250, "rule seat 2: 15%");
        assertEq(token.balanceOf(makeAddr("seatA2")), 99_500, "rule seat 3: 10%");

        // ── link B: created and paid WHILE the check still passes ────────
        // Same tables, different seats. It stays unpaid until after the
        // swap: on the genuine chain the shell reads its netlist THROUGH the
        // beacon, so a swapped beacon would make rule 5 refuse a new link
        // ("netlist is unreadable") before rule 6's cap is even reached -
        // correct behaviour, but it would hide the case under test here.
        address carolB = makeAddr("carolB");
        vm.prank(creator);
        p.createLink(
            "fork-default",
            1_000_000,
            address(token),
            "claimed after the swap",
            0,
            _split(carolB, address(0), address(0), 20, 0, 0),
            _split(carolB, makeAddr("seatB1"), makeAddr("seatB2"), 15, 3, 2)
        );
        _payTo(p, "fork-default", payer, 1_000_000);

        // ── the swap: only the beacon's code changes on this fork ────────
        address otherImpl = makeAddr("some other implementation");
        vm.etch(BEACON, _constBeaconCode(otherImpl));
        assertFalse(p.evaluatorPinned(), "the SAME deployment must flip false at the next read");

        // ── claim link B AFTER the swap: the rule table must be ignored ──
        bytes32 keyB = p.linkKeyOf("fork-default");
        vm.expectEmit(true, true, true, true);
        emit Pago.LinkClaimed(keyB, 995_000, 5_000, false); // usedRuleSplit = false
        vm.prank(relayer);
        p.claim("fork-default");
        assertEq(token.balanceOf(carolB), 995_000, "the default split applies after the swap");
        assertEq(token.balanceOf(makeAddr("seatB1")), 0, "no rule seat may be paid while unpinned");
        assertEq(token.balanceOf(makeAddr("seatB2")), 0, "no rule seat may be paid while unpinned");
        assertEq(token.balanceOf(makeAddr("fee")), 10_000, "both claims took the 0.5% fee");

        // ── and the cap applies to new links on the same deployment ──────
        // Rule 6's cap is checked BEFORE rule 5's netlist read, so this
        // reverts with the cap message even though the swapped beacon has
        // already made the netlist unreadable on this chain. The cap is read
        // into a local first: as an argument it would be its own call and
        // swallow the expectRevert.
        uint256 cap = p.MAX_LINK_AMOUNT_UNPINNED(address(token));
        vm.prank(creator);
        vm.expectRevert("unpinned evaluator: link amount above cap");
        p.createLink(
            "fork-over",
            cap + 1,
            address(token),
            "above the cap",
            0,
            _split(carolB, address(0), address(0), 20, 0, 0),
            _split(carolB, makeAddr("seatB1"), makeAddr("seatB2"), 15, 3, 2)
        );
        console.log("swap-after-link-exists: default split paid, cap enforced, flag flipped live");
    }

    /// Mint, approve and pay in one helper (rule 4: the payer consents to the
    /// exact terms hash read from the link itself).
    function _payTo(Pago p, string memory id, address from, uint256 amount) internal {
        token.mint(from, amount);
        vm.startPrank(from);
        token.approve(address(p), amount);
        p.pay(id, amount, p.termsHash(id));
        vm.stopPrank();
    }

    /// Three seats in 5% steps: recipients with a share must be honest seats.
    function _split(address r0, address r1, address r2, uint8 s0, uint8 s1, uint8 s2) internal pure returns (Pago.Split memory s) {
        s.recipients = [r0, r1, r2];
        s.shares = [s0, s1, s2];
    }

    /// Runtime code returning a constant address: PUSH32 addr, MSTORE at 0,
    /// RETURN the 32 bytes. Ignores calldata, so it answers implementation()
    /// (and anything else) with the same address.
    function _constBeaconCode(address value) internal pure returns (bytes memory) {
        return abi.encodePacked(hex"7f", bytes32(uint256(uint160(value))), hex"60005260206000f3");
    }
}
