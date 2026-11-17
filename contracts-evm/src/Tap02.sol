// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// Reference implementation of the TAP-02 netlist format, written from the spec
/// (github.com/TapeOutProtocol/TAPs, TAP-02) and then checked bit-for-bit
/// against a live processor on X Layer mainnet (docs/RESEARCH.md section 4).
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
/// NAND is implemented and proven against the chain; LATCH and REF are
/// deliberately **rejected** rather than guessed: REF needs to call another
/// processor, and LATCH feedback semantics (TAP-02 section 4) are not
/// implemented here. A reference model must never guess.
///
/// Lives in `src/` rather than `test/` because Pago's circuit (Split3) is
/// checked against it: a rule expressed as a netlist needs an executable
/// statement of what that netlist means.
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
/// internal revert occurs at the caller's own depth and the cheatcode cannot
/// see it. Routing the call through this contract moves it one frame down.
contract Tap02Harness {
    function stats(bytes memory nl) external pure returns (uint256 nands, uint256 latches, uint256 refs) {
        return Tap02.stats(nl);
    }

    function eval(bytes memory nl, uint32 nIn, uint32 nOut, uint256 inBits) external pure returns (uint256) {
        return Tap02.eval(nl, nIn, nOut, inBits);
    }
}
