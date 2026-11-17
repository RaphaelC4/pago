// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {IRuleProcessor} from "../src/IRuleProcessor.sol";

/// Phase 0 fork proof: can a contract staticcall a TapeOut processor's `eval`,
/// what does it return, and what does it cost?
///
/// Runs against a local fork of X Layer mainnet (chain 196). No transaction is
/// ever broadcast: every call here is a read.
contract ForkEvalTest is Test {
    // Processor #340 (BBBFi TapeGuard), circuit #1: 4 inputs, 1 output, 6 NANDs.
    IRuleProcessor constant CPU = IRuleProcessor(0x9de448A1CE9537d24199B3b5355239d73aA6F591);

    function setUp() public {
        vm.createSelectFork(vm.envString("XLAYER_RPC"));
    }

    function test_circuitInfoIsReadable() public view {
        (uint32 nIn, uint32 nOut, uint32 nState, uint32 gates) = CPU.circuitInfo(1);
        console.log("nIn", nIn);
        console.log("nOut", nOut);
        console.log("nState", nState);
        console.log("gateCount", gates);

        assertEq(nIn, 4, "nIn");
        assertEq(nOut, 1, "nOut");
        assertEq(gates, 6, "gateCount");
    }

    function test_truthTableIsReadable() public view {
        uint256 ones;
        for (uint256 i; i < 16; ++i) {
            bytes memory out = CPU.eval(1, abi.encodePacked(uint8(i)));
            assertEq(out.length, 1, "output must be ceil(nOut/8) = 1 byte");
            console.log(i, uint256(uint8(out[0])));
            if (uint8(out[0]) != 0) ++ones;
        }
        assertEq(ones, 1, "exactly one input combination yields 1");
    }

    function test_directStaticcallWorks() public view {
        (bool ok, bytes memory ret) = address(CPU).staticcall(
            abi.encodeWithSelector(IRuleProcessor.eval.selector, uint256(1), abi.encodePacked(uint8(0x0f)))
        );
        assertTrue(ok, "staticcall must succeed");
        // abi.encode(bytes) = offset word + length word + one padded data word.
        assertEq(ret.length, 96, "abi.encode(bytes) with 1 byte of data");
        console.logBytes(ret);
    }

    function test_gasCostOfEval() public {
        uint256 before = gasleft();
        CPU.eval(1, abi.encodePacked(uint8(0x0f)));
        uint256 used = before - gasleft();
        console.log("eval gas for 6-gate circuit", used);
        assertLt(used, 100_000, "small circuit should be cheap");
    }
}
