// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {IRuleProcessor} from "../src/IRuleProcessor.sol";

/// Reference implementation of the TAP-02 netlist format, written from the spec
/// (github.com/TapeOutProtocol/TAPs, TAP-02) and then checked bit-for-bit
/// against a live processor on X Layer mainnet.
///
/// Format, as specified by TAP-02:
///   - netlist = concatenation of records, no header, no padding, no terminator
///   - multi-byte integers are big-endian; u24 is a 3-byte signal index
///   - signal 0 = constant 0, signal 1 = constant 1
///   - signals 2 .. 2+nIn-1 are the inputs (input i at index 2+i)
///   - each record appends the signals it produces, in record order
///   - opcodes: 0x00 NAND(a:u24,b:u24) -> 7 bytes,  produces 1 signal
///              0x01 LATCH(d:u24)       -> 4 bytes,  produces 1 signal
///              0x02 REF(...)           -> 31+3*nIns bytes, produces nOuts
///   - inputs/outputs are packed least-significant-bit first
///
/// NAND is implemented and proven against the chain. LATCH and REF are parsed
/// (so counts and boundaries are validated) but deliberately rejected at
/// evaluation time: REF needs to call another processor, and LATCH feedback
/// semantics (TAP-02 section 4) are not implemented here yet. Rejecting is
/// required -- a reference model must never guess.
library Tap02 {
    error UnsupportedOpcode(uint8 op);
    error RefUnsupported();
    error LatchUnsupported();
    error TruncatedNetlist();

    struct Ctx {
        uint256[] sig;
        uint256 next;
    }

    /// Walks the netlist and counts each opcode. Reverts on a truncated or
    /// unknown record, so a malformed netlist can never be silently accepted.
    function stats(bytes memory nl) internal pure returns (uint256 nands, uint256 latches, uint256 refs) {
        uint256 i;
        while (i < nl.length) {
            uint8 op = uint8(nl[i]);
            if (op == 0x00) {
                if (i + 7 > nl.length) revert TruncatedNetlist();
                nands++;
                i += 7;
            } else if (op == 0x01) {
                if (i + 4 > nl.length) revert TruncatedNetlist();
                latches++;
                i += 4;
            } else if (op == 0x02) {
                if (i + 31 > nl.length) revert TruncatedNetlist();
                uint256 nIns = uint256(uint8(nl[i + 29]));
                if (i + 31 + 3 * nIns > nl.length) revert TruncatedNetlist();
                refs++;
                i += 31 + 3 * nIns;
            } else {
                revert UnsupportedOpcode(op);
            }
        }
    }

    /// Evaluates one beat of a NAND-only netlist.
    /// `inBits` holds the inputs LSB-first, matching the contracts' packing.
    function eval(bytes memory nl, uint32 nIn, uint32 nOut, uint256 inBits)
        internal
        pure
        returns (uint256 outBits)
    {
        uint256 nands;
        uint256 latches;
        uint256 refs;
        (nands, latches, refs) = stats(nl);
        if (refs != 0) revert RefUnsupported();
        if (latches != 0) revert LatchUnsupported();

        Ctx memory c;
        c.sig = new uint256[](2 + uint256(nIn) + nands);
        c.sig[0] = 0;
        c.sig[1] = 1;
        for (uint256 k; k < nIn; ++k) {
            c.sig[2 + k] = (inBits >> k) & 1;
        }
        c.next = 2 + uint256(nIn);

        _runNands(nl, c);

        // The circuit's outputs are the last nOut produced signals.
        uint256 base = c.next - uint256(nOut);
        for (uint256 k; k < nOut; ++k) {
            outBits |= c.sig[base + k] << k;
        }
    }

    function _runNands(bytes memory nl, Ctx memory c) private pure {
        uint256 i;
        while (i < nl.length) {
            // stats() already validated every record, so this is a guard rail.
            if (uint8(nl[i]) != 0x00) revert UnsupportedOpcode(uint8(nl[i]));
            uint256 a = _u24(nl, i + 1);
            uint256 b = _u24(nl, i + 4);
            c.sig[c.next] = (c.sig[a] & c.sig[b]) ^ 1; // NAND
            c.next++;
            i += 7;
        }
    }

    function _u24(bytes memory b, uint256 off) private pure returns (uint256 v) {
        v = (uint256(uint8(b[off])) << 16) | (uint256(uint8(b[off + 1])) << 8) | uint256(uint8(b[off + 2]));
    }
}

/// External wrapper: `vm.expectRevert` only observes reverts that happen at a
/// *deeper* call depth than the cheatcode itself. `Tap02` is a library, so an
/// internal revert occurs at the test's own depth and the cheatcode cannot see
/// it. Routing the call through this contract moves it one frame down.
contract Tap02Harness {
    function stats(bytes memory nl) external pure returns (uint256 nands, uint256 latches, uint256 refs) {
        return Tap02.stats(nl);
    }

    function eval(bytes memory nl, uint32 nIn, uint32 nOut, uint256 inBits) external pure returns (uint256) {
        return Tap02.eval(nl, nIn, nOut, inBits);
    }
}

/// Proves the reference evaluator against processor #340's live circuit #1.
contract NetlistRefTest is Test {
    address constant CPU = 0x9de448A1CE9537d24199B3b5355239d73aA6F591;

    Tap02Harness harness;

    function setUp() public {
        vm.createSelectFork(vm.envString("XLAYER_RPC"));
        harness = new Tap02Harness();
    }

    function test_referenceEvaluatorMatchesChainExhaustively() public {
        IRuleProcessor p = IRuleProcessor(CPU);
        (uint32 nIn, uint32 nOut, uint32 nState, uint32 gates) = p.circuitInfo(1);
        bytes memory nl = p.netlist(1);

        console.log("nIn", nIn, "nOut", nOut);
        console.log("nState", nState, "gates", gates);
        console.logBytes(nl);

        (uint256 nands, uint256 latches, uint256 refs) = Tap02.stats(nl);
        console.log("parsed nands", nands, "latches", latches);
        console.log("refs", refs);
        assertEq(nands, gates, "parsed NAND count must equal the chain's gateCount");
        assertEq(latches, 0, "this circuit has no latches");
        assertEq(refs, 0, "this circuit has no sub-circuit references");
        assertEq(nState, 0, "this circuit is stateless");

        // Exhaustive: nIn <= 12, so every input combination is checked.
        assertLe(nIn, 12, "exhaustive comparison only for <=12 input bits");
        _compareAll(p, nl, nIn, nOut);
    }

    function _compareAll(IRuleProcessor p, bytes memory nl, uint32 nIn, uint32 nOut) internal {
        uint256 combos = uint256(1) << nIn;
        for (uint256 i; i < combos; ++i) {
            uint256 expected = _unpack(p.eval(1, _pack(i, nIn)), nOut);
            uint256 got = Tap02.eval(nl, nIn, nOut, i);
            assertEq(got, expected, "reference evaluator disagrees with the chain");
        }
        console.log("all", combos, "input combinations matched the chain");
    }

    /// States this circuit's behaviour in plain words, from the parsed netlist.
    function test_referenceEvaluatorRevealsTruthTable() public {
        IRuleProcessor p = IRuleProcessor(CPU);
        (uint32 nIn, uint32 nOut,,) = p.circuitInfo(1);
        bytes memory nl = p.netlist(1);

        uint256 combos = uint256(1) << nIn;
        uint256 ones;
        uint256 allOnes;
        for (uint256 i; i < combos; ++i) {
            uint256 got = Tap02.eval(nl, nIn, nOut, i);
            if (got != 0) ones++;
            if (i == combos - 1) allOnes = got;
        }
        // Circuit #1 computes the AND of all nIn inputs: only the all-ones
        // input combination yields 1.
        assertEq(ones, 1, "exactly one input combination yields 1");
        assertEq(allOnes, 1, "the all-ones input must yield 1");
        console.log("circuit #1 computes AND of all", nIn, "inputs");
    }

    // ---------- malformed netlists must fail loudly ----------
    //
    // Each call goes through `harness` so the revert happens one frame deeper
    // than the test, which is what `vm.expectRevert` requires.

    function test_referenceEvaluatorRejectsTruncatedNand() public {
        vm.expectRevert(Tap02.TruncatedNetlist.selector);
        harness.stats(hex"00000002");
    }

    function test_referenceEvaluatorRejectsUnknownOpcode() public {
        vm.expectRevert(abi.encodeWithSelector(Tap02.UnsupportedOpcode.selector, uint8(0x7f)));
        harness.stats(hex"7f");
    }

    function test_referenceEvaluatorRejectsRef() public {
        // REF calls another processor, which a pure model cannot do. It must
        // fail loudly rather than guess at the sub-circuit's answer.
        bytes memory nl = abi.encodePacked(hex"02", new bytes(30));
        (,, uint256 refs) = harness.stats(nl);
        assertEq(refs, 1, "REF record must be counted");
        vm.expectRevert(Tap02.RefUnsupported.selector);
        harness.eval(nl, 1, 1, 0);
    }

    function test_referenceEvaluatorRejectsLatch() public {
        // LATCH parses, but its feedback semantics are not implemented yet.
        bytes memory nl = abi.encodePacked(hex"01", hex"000002");
        (, uint256 latches,) = harness.stats(nl);
        assertEq(latches, 1, "LATCH record must be counted");
        vm.expectRevert(Tap02.LatchUnsupported.selector);
        harness.eval(nl, 1, 1, 0);
    }

    // ---------- helpers ----------

    function _pack(uint256 bits, uint32 nIn) internal pure returns (bytes memory b) {
        b = new bytes((uint256(nIn) + 7) / 8);
        for (uint256 i; i < b.length; ++i) {
            b[i] = bytes1(uint8(bits >> (8 * i)));
        }
    }

    function _unpack(bytes memory b, uint32 nOut) internal pure returns (uint256 v) {
        uint256 nBytes = (uint256(nOut) + 7) / 8;
        for (uint256 i; i < b.length && i < nBytes; ++i) {
            v |= uint256(uint8(b[i])) << (8 * i);
        }
        if (nOut < 256) v &= (uint256(1) << nOut) - 1;
    }
}
