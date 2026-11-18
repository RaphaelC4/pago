// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IRuleProcessor} from "../../src/IRuleProcessor.sol";
import {Split3} from "../../src/circuits/Split3.sol";
import {Tap02} from "../../src/Tap02.sol";

/// @title FaultyProcessor - every way the evaluator can misbehave, on demand.
///
/// Pago's rule 3 says a link must never freeze: whatever the processor does -
/// revert, return malformed data, burn gas, lie, or not exist - `claim` pays the
/// default split. One configurable mock covers each of those paths so the suite
/// proves the fallback rather than asserting it in prose.
///
/// `netlist()` returns Split3's real bytes in every mode except `NoNetlist`,
/// so `createLink` (rule 5) succeeds and only the *eval* behaviour differs -
/// except in `NoNetlist`, which exists precisely to prove createLink reverts
/// when the identity cannot be read.
contract FaultyProcessor is IRuleProcessor {
    enum Mode {
        Revert, // eval reverts
        Short, // eval returns a payload whose length is not 1
        DirtyPad, // eval returns the right length with non-zero padding
        Lie, // eval always answers 1, even for invalid splits
        GasHog, // eval burns more gas than Pago's cap allows
        NoNetlist // netlist reverts (eval itself is honest)
    }

    Mode public mode;

    constructor(Mode m) {
        mode = m;
    }

    function nextId() external pure returns (uint256) {
        return 2;
    }

    function circuitInfo(uint256 circuitId) external pure returns (uint32 nIn, uint32 nOut, uint32 nState, uint32 gateCount) {
        require(circuitId == 1, "no such circuit");
        return (Split3.N_IN, Split3.N_OUT, 0, uint32(Split3.NAND_COUNT));
    }

    function netlist(uint256 circuitId) external view returns (bytes memory) {
        require(circuitId == 1, "no such circuit");
        if (mode == Mode.NoNetlist) revert("netlist unavailable");
        return Split3.netlist();
    }

    function eval(uint256 circuitId, bytes calldata inputs) external view returns (bytes memory) {
        require(circuitId == 1, "no such circuit");

        if (mode == Mode.Revert) revert("processor on fire");

        if (mode == Mode.Short) {
            // A two-byte payload: Pago's decoder demands exactly one.
            return abi.encodePacked(hex"0101");
        }

        if (mode == Mode.DirtyPad) {
            // Right offset, right length, payload byte 0x01 - but byte 1 of the
            // data word is 0xFF instead of zero padding: must be rejected.
            assembly {
                mstore(0x00, 0x20) // offset
                mstore(0x20, 0x01) // length
                mstore(0x40, or(shl(248, 0x01), shl(240, 0xFF))) // data word
                return(0x00, 0x60)
            }
        }

        if (mode == Mode.Lie) return abi.encodePacked(bytes1(0x01));

        if (mode == Mode.GasHog) {
            // Deterministically exceeds Pago's EVAL_GAS_LIMIT (500k): roughly
            // 10M loop iterations at a few gas each. If it ever finished - it
            // cannot under the cap - it would answer 1, which is exactly the
            // answer a test must NOT observe when the gas cap does its job.
            uint256 i;
            while (i < 10_000_000) {
                unchecked {
                    ++i;
                }
            }
            return abi.encodePacked(bytes1(0x01));
        }

        // Honest path (also used by NoNetlist): run the real netlist bytes
        // through the same TAP-02 evaluator the mainnet cross-check used.
        uint256 inBits;
        for (uint256 j; j < inputs.length && j < 2; ++j) {
            inBits |= uint256(uint8(inputs[j])) << (8 * j);
        }
        uint256 outBits = Tap02.eval(Split3.netlist(), Split3.N_IN, Split3.N_OUT, inBits);
        return abi.encodePacked(bytes1(uint8(outBits & 1)));
    }
}
