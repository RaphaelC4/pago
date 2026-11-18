// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IRuleProcessor} from "../../src/IRuleProcessor.sol";
import {Split3} from "../../src/circuits/Split3.sol";
import {Tap02} from "../../src/Tap02.sol";

/// @title ProcessorStandIn - an EVM stand-in for the TapeOut processor.
///
/// **This is not hardware.** X Layer's TapeOut factory exists only on mainnet
/// (chain 196): probing it on testnet returns no code at all (docs/RESEARCH.md
/// section 17). Without it, Pago's rule path could not be exercised live on the
/// testnet the hackathon rules require development against.
///
/// What it is: a contract implementing the exact `IRuleProcessor` surface Pago
/// calls, whose `eval` runs the **real TAP-02 netlist bytes** of Split3 through
/// the same `Tap02` evaluator the test suite proves bit-for-bit against a live
/// mainnet processor (section 4). So on testnet:
///
///   * `netlist(1)` returns the byte-for-byte netlist that will be taped out on
///     mainnet, and Pago stores its keccak256 (rule 5) - the identity is real.
///   * `eval(1, inputs)` executes that netlist gate by gate; the verdict is the
///     netlist's, computed from the bytes, not a hard-coded answer.
///   * `circuitInfo(1)` reports the shape those bytes actually have.
///
/// On mainnet tier 2 this address is replaced by the real taped-out processor;
/// nothing in Pago changes, only the constructor argument. Every doc that shows
/// this contract says "stand-in" - it is never presented as hardware.
contract ProcessorStandIn is IRuleProcessor {
    uint32 internal constant N_IN = Split3.N_IN;
    uint32 internal constant N_OUT = Split3.N_OUT;

    bytes internal _netlist;
    uint256 internal _gateCount;

    constructor() {
        _netlist = Split3.netlist();
        (uint256 nands,,) = Tap02.stats(_netlist);
        _gateCount = nands;
    }

    /// Circuit #1 is the only circuit this stand-in holds; #2 is what the next
    /// tape-out would receive, mirroring a real processor's `nextId`.
    function nextId() external pure returns (uint256) {
        return 2;
    }

    function circuitInfo(uint256 circuitId) external view returns (uint32 nIn, uint32 nOut, uint32 nState, uint32 gateCount) {
        require(circuitId == 1, "no such circuit");
        return (N_IN, N_OUT, 0, uint32(_gateCount));
    }

    function netlist(uint256 circuitId) external view returns (bytes memory) {
        require(circuitId == 1, "no such circuit");
        return _netlist;
    }

    /// Evaluate the netlist itself - not a shortcut through Split3.holds(). The
    /// inputs are LSB-first packed exactly as TAP-02 specifies; the output is
    /// the netlist's single bit as `abi.encode(bytes)`, which is what Pago's
    /// strict decoder (exact length, zero padding, payload 0 or 1) demands.
    function eval(uint256 circuitId, bytes calldata inputs) external view returns (bytes memory) {
        require(circuitId == 1, "no such circuit");
        require(inputs.length == (N_IN + 7) / 8, "wrong input length");

        uint256 inBits;
        for (uint256 i; i < inputs.length; ++i) {
            inBits |= uint256(uint8(inputs[i])) << (8 * i);
        }

        uint256 outBits = Tap02.eval(_netlist, N_IN, N_OUT, inBits);
        // encodePacked: the payload must be exactly ONE byte. abi.encode of a
        // bytes1 would be a 32-byte payload and fail Pago's strict decoder.
        return abi.encodePacked(bytes1(uint8(outBits & 1)));
    }
}
