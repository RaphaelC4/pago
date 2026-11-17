// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {IRuleProcessor} from "../src/IRuleProcessor.sol";

interface IFactoryReader {
    function cpuAt(uint256) external view returns (address);
    function cpuCount() external view returns (uint256);
}

/// Phase 0 item 9: find public circuits we can use for the live "Verify rule"
/// demo, and prove each one's truth table by running `eval` for every input
/// combination (only for circuits with at most 12 input bits).
///
/// The scan is deliberately bounded: X Layer's RPC rejects `eth_getLogs`
/// ranges wider than 100 blocks, so enumerating all 425 processors through
/// events is not possible. We scan a fixed, documented index set instead and
/// record exactly which indices were checked.
contract DemoCircuitsTest is Test {
    address constant FACTORY = 0x1f09DAeFA827f02CBb40967cc91b259763760761;
    // Processor #340 (BBBFi TapeGuard) is known to hold circuit #1.
    address constant KNOWN = 0x9de448A1CE9537d24199B3b5355239d73aA6F591;

    function setUp() public {
        vm.createSelectFork(vm.envString("XLAYER_RPC"));
    }

    function test_scanForPublicCircuits() public {
        IFactoryReader f = IFactoryReader(FACTORY);
        uint256 count = f.cpuCount();
        console.log("cpuCount", count);

        uint256 found;
        // Fixed, documented index set: the first 31 processors and a window
        // around the known-good #340.
        for (uint256 i; i < 31; ++i) {
            found += _inspect(f, i);
        }
        for (uint256 i = 330; i <= 345 && i < count; ++i) {
            found += _inspect(f, i);
        }
        console.log("processors with >=1 circuit in scanned range", found);
        assertGt(found, 0, "expected at least the known processor #340");
    }

    function _inspect(IFactoryReader f, uint256 idx) internal returns (uint256 withCircuits) {
        address cpu;
        try f.cpuAt(idx) returns (address c) {
            cpu = c;
        } catch {
            return 0;
        }
        if (cpu == address(0)) return 0;

        uint256 next;
        try IRuleProcessor(cpu).nextId() returns (uint256 n) {
            next = n;
        } catch {
            return 0;
        }
        if (next <= 1) return 0;

        console.log("---- processor", idx);
        console.log("address", cpu);
        console.log("circuits taped out", next - 1);

        for (uint256 id = 1; id < next && id <= 5; ++id) {
            try IRuleProcessor(cpu).circuitInfo(id) returns (uint32 nIn, uint32 nOut, uint32 nState, uint32 gates) {
                console.log("  circuit", id);
                console.log("   nIn", nIn);
                console.log("   nOut", nOut);
                console.log("   nState", nState);
                console.log("   gates", gates);
                console.logBytes(IRuleProcessor(cpu).netlist(id));
            } catch {
                console.log("  circuit", id, "circuitInfo reverted");
            }
        }
        return 1;
    }

    /// Exhaustive truth table for a small circuit, read straight from the chain.
    function test_truthTableOfKnownCircuit() public {
        IRuleProcessor p = IRuleProcessor(KNOWN);
        (uint32 nIn, uint32 nOut, uint32 nState, uint32 gates) = p.circuitInfo(1);
        console.log("nIn", nIn, "nOut", nOut);
        console.log("nState", nState, "gates", gates);
        assertLe(nIn, 12, "exhaustive table only for <=12 input bits");

        uint256 combos = uint256(1) << nIn;
        uint256 ones;
        for (uint256 i; i < combos; ++i) {
            bytes memory out = p.eval(1, _pack(i, nIn));
            assertEq(out.length, (nOut + 7) / 8, "output byte length");
            uint256 v = _unpack(out);
            if (v != 0) ones++;
            console.log(i, v);
        }
        console.log("inputs that yield a non-zero output", ones);
        assertGt(ones, 0, "circuit must be satisfiable");
    }

    /// LSB-first bit packing, matching TAP-02's input encoding.
    function _pack(uint256 bits, uint32 nIn) internal pure returns (bytes memory) {
        uint256 nBytes = (uint256(nIn) + 7) / 8;
        bytes memory b = new bytes(nBytes);
        for (uint256 i; i < nBytes; ++i) {
            b[i] = bytes1(uint8(bits >> (8 * i)));
        }
        return b;
    }

    function _unpack(bytes memory b) internal pure returns (uint256 v) {
        for (uint256 i; i < b.length; ++i) {
            v |= uint256(uint8(b[i])) << (8 * i);
        }
    }
}
