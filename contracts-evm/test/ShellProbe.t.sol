// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console} from "forge-std/Test.sol";

interface ITapeFactoryS {
    function createCPU(string calldata, string calldata, string calldata, uint256, uint256)
        external
        payable
        returns (address, address);
    function deployFee() external view returns (uint256);
}

interface IBemS {
    function approve(address spender, uint256 amount) external;
    function transfer(address to, uint256 amount) external;
    function balanceOf(address owner) external view returns (uint256);
}

/// Why does a NEW processor's shell hash to 0x8c799a18... while section 18
/// records 0x57aa306f... (verified live: #340's circuits, 295 bytes)?
///
/// Pago pins extcodehash(processor) forever, so pinning the wrong shell leaves
/// every link capped with no way to fix it. This probe creates one processor
/// on a FORK (read-only, nothing broadcast, no key) and prints:
///   * the new shell's byte length and keccak - is it even the same template?
///   * a byte-for-byte diff against #340's recorded shell - WHAT changed
///   * the embedded beacon literal in both, to confirm the beacon did not move
///
/// Machine-readable output:
///   SHELL|meta|chainid=..|block=..
///   SHELL|new|addr=0x..|bytes=N|hash=0x..
///   SHELL|ref|addr=0x..|bytes=N|hash=0x..
///   SHELL|diff|count=N|offsets=..|newBytes=..|refBytes=..
///   SHELL|beacon|new=0x..|ref=0x..
contract ShellProbeTest is Test {
    address constant FACTORY = 0x1f09DAeFA827f02CBb40967cc91b259763760761;
    address constant BEM = 0x60e62Efa9405d6873C5deaBD4E6CC91c25363952;
    // The BEM/WOKB 1% pool holds ~2,400 BEM on mainnet - the fork's source.
    address constant WHALE = 0x2CcF8aa17F5DF9Fb5D51C9de12135a913fF29f7A;
    // Section 18's recorded shell: #340's circuits contract, 295 bytes.
    address constant REF_SHELL = 0x9de448A1CE9537d24199B3b5355239d73aA6F591;

    // Phase state kept in storage so each helper stays stack-safe.
    address internal newShell;

    function setUp() public {
        vm.createSelectFork(vm.envString("XLAYER_RPC"));
    }

    function _answerUint(address target, string memory sig) internal view returns (bool, uint256) {
        (bool ok, bytes memory ret) = target.staticcall(abi.encodeWithSignature(sig));
        if (!ok || ret.length != 32) return (false, 0);
        return (true, abi.decode(ret, (uint256)));
    }

    /// createCPU's two addresses assigned BY CAPABILITY (shape 2 = circuits,
    /// shape 1 = transistors), never by position - same rule as section 19.
    function _discover(address first, address second) internal view returns (address, address) {
        (bool tapeA,) = _answerUint(first, "TAPEOUT_FEE()");
        (bool mintA,) = _answerUint(first, "mintPrice()");
        (bool tapeB,) = _answerUint(second, "TAPEOUT_FEE()");
        (bool mintB,) = _answerUint(second, "mintPrice()");
        uint8 shapeA = uint8((tapeA ? 2 : 0) | (mintA ? 1 : 0));
        uint8 shapeB = uint8((tapeB ? 2 : 0) | (mintB ? 1 : 0));
        if (shapeA == 2 && shapeB == 1) return (first, second);
        if (shapeA == 1 && shapeB == 2) return (second, first);
        return (address(0), address(0));
    }

    /// The beacon literal a shell hardcodes (section 18: PUSH32 inside the
    /// proxy). Scanned rather than decoded, so a template change shows up too.
    function _embeddedBeacon(address shell) internal view returns (bool, address) {
        bytes memory code = shell.code;
        for (uint256 i; i + 32 <= code.length; ++i) {
            bytes32 word;
            for (uint256 j; j < 32; ++j) {
                word |= bytes32(uint256(uint8(code[i + j]))) >> (8 * j);
            }
            address candidate = address(uint160(uint256(word)));
            if (candidate == 0xf70d1ed4f62CF3780157B0b421b7E2F45bD0991C) return (true, candidate);
        }
        return (false, address(0));
    }

    function test_newProcessorShellVsRecorded() public {
        console.log(
            string.concat("SHELL|meta|chainid=", vm.toString(block.chainid), "|block=", vm.toString(block.number))
        );

        // Create one processor on the fork, exactly as execution will.
        // Fund from the pool's BEM balance - fork-only, nothing broadcast.
        address fresh = makeAddr("shell-probe");
        vm.prank(WHALE);
        IBemS(BEM).transfer(fresh, 3e8);
        require(IBemS(BEM).balanceOf(fresh) > 0, "whale funding failed");

        vm.startPrank(fresh);
        IBemS(BEM).approve(FACTORY, type(uint256).max);
        (address first, address second) = ITapeFactoryS(FACTORY).createCPU(
            "ShellProbe", "SHP", "shell template probe", 100_000, 0
        );
        vm.stopPrank();

        (address circuits, address transistors) = _discover(first, second);
        require(circuits != address(0), "role discovery failed");
        newShell = circuits;

        _printNew(circuits, transistors);
        _printDiff(circuits);
        _printHex(circuits);
        _printVerdict(circuits);
    }

    function _hex(bytes memory b, uint256 from) internal pure returns (string memory out) {
        bytes16 hexDigits = "0123456789abcdef";
        for (uint256 i = from; i < b.length; ++i) {
            uint8 v = uint8(b[i]);
            out = string.concat(
                out,
                string(abi.encodePacked(hexDigits[v >> 4], hexDigits[v & 0x0f]))
            );
        }
    }

    /// Raw tail plus every PUSH32 (0x7f) offset: the shell's hardcoded
    /// constants live behind those opcodes, and one of them is what differs.
    function _printHex(address circuits) internal view {
        bytes memory n = circuits.code;
        bytes memory r = REF_SHELL.code;
        console.log(string.concat("SHELL|newTail|", _hex(n, 200)));
        console.log(string.concat("SHELL|refTail|", _hex(r, 200)));
        string memory nP;
        string memory rP;
        for (uint256 i; i < n.length; ++i) {
            if (uint8(n[i]) == 0x7f) nP = string.concat(nP, i > 0 ? "," : "", vm.toString(i));
        }
        for (uint256 i; i < r.length; ++i) {
            if (uint8(r[i]) == 0x7f) rP = string.concat(rP, i > 0 ? "," : "", vm.toString(i));
        }
        console.log(string.concat("SHELL|push32|new=", nP, "|ref=", rP));
        // The full shells, so the template difference can be named exactly.
        console.log(string.concat("SHELL|newFull|", _hex(n, 0)));
        console.log(string.concat("SHELL|refFull|", _hex(r, 0)));
    }

    function _printNew(address circuits, address transistors) internal view {
        bytes memory newCode = circuits.code;
        bytes memory refCode = REF_SHELL.code;
        console.log(
            string.concat(
                "SHELL|new|addr=", vm.toString(circuits), "|bytes=", vm.toString(newCode.length),
                "|hash=", vm.toString(circuits.codehash)
            )
        );
        console.log(
            string.concat(
                "SHELL|ref|addr=", vm.toString(REF_SHELL), "|bytes=", vm.toString(refCode.length),
                "|hash=", vm.toString(REF_SHELL.codehash)
            )
        );
        console.log(
            string.concat(
                "SHELL|transistors|addr=", vm.toString(transistors),
                "|bytes=", vm.toString(transistors.code.length),
                "|hash=", vm.toString(transistors.codehash)
            )
        );
    }

    /// Byte diff: if the templates are the same length, show every offset
    /// that differs with both bytes - that names the changed field.
    function _printDiff(address circuits) internal view {
        bytes memory newCode = circuits.code;
        bytes memory refCode = REF_SHELL.code;
        uint256 len = newCode.length < refCode.length ? newCode.length : refCode.length;
        uint256 count;
        string memory offsets;
        string memory newB;
        string memory refB;
        for (uint256 i; i < len; ++i) {
            if (newCode[i] != refCode[i]) {
                count++;
                offsets = string.concat(offsets, i > 0 ? "," : "", vm.toString(i));
                newB = string.concat(newB, i > 0 ? "," : "", vm.toString(uint8(newCode[i])));
                refB = string.concat(refB, i > 0 ? "," : "", vm.toString(uint8(refCode[i])));
            }
        }
        if (newCode.length != refCode.length) {
            console.log(
                string.concat(
                    "SHELL|lengthMismatch|new=", vm.toString(newCode.length), "|ref=", vm.toString(refCode.length)
                )
            );
        }
        console.log(
            string.concat("SHELL|diff|count=", vm.toString(count), "|offsets=", offsets, "|newBytes=", newB, "|refBytes=", refB)
        );
        (bool nFound, address nBeacon) = _embeddedBeacon(circuits);
        (bool rFound, address rBeacon) = _embeddedBeacon(REF_SHELL);
        console.log(
            string.concat(
                "SHELL|beacon|new=", nFound ? vm.toString(nBeacon) : "not-found",
                "|ref=", rFound ? vm.toString(rBeacon) : "not-found"
            )
        );
    }

    /// What Pago's leg 1 would compare against, stated outright.
    function _printVerdict(address circuits) internal view {
        bool same = circuits.codehash == REF_SHELL.codehash;
        console.log(
            string.concat(
                "SHELL|verdict|newShellHash=", vm.toString(circuits.codehash),
                "|section18Hash=", vm.toString(REF_SHELL.codehash),
                "|equal=", same ? "true" : "false"
            )
        );
    }
}
