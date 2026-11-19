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
        p = new Pago(configs, makeAddr("fee"), PROCESSOR, 1, RECORDED_SHELL, BEACON, RECORDED_IMPL);
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

    /// Runtime code returning a constant address: PUSH32 addr, MSTORE at 0,
    /// RETURN the 32 bytes. Ignores calldata, so it answers implementation()
    /// (and anything else) with the same address.
    function _constBeaconCode(address value) internal pure returns (bytes memory) {
        return abi.encodePacked(hex"7f", bytes32(uint256(uint160(value))), hex"60005260206000f3");
    }
}
