// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {IRuleProcessor} from "../src/IRuleProcessor.sol";
// The reference evaluator now lives in `src/` so Pago's own circuit tests can
// import it; the header explaining the TAP-02 format moved there with it.
import {Tap02, Tap02Harness} from "../src/Tap02.sol";

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
