// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {Split3} from "../src/circuits/Split3.sol";

interface ITapeFactoryP {
    function createCPU(string calldata, string calldata, string calldata, uint256, uint256)
        external
        payable
        returns (address, address);
    function deployFee() external view returns (uint256);
}

interface ITransistorsP {
    function mint(uint256 id, uint256 amount) external payable;
    function mintPrice() external view returns (uint256);
    function protocolFee() external view returns (uint256);
}

interface IBemP {
    function approve(address spender, uint256 amount) external;
    function transfer(address to, uint256 amount) external;
    function balanceOf(address owner) external view returns (uint256);
}

/// How much does a Split3 tape-out actually cost if the CREATOR sets a
/// different gate price?  Section 13 says the caller sets `mintPrice` when
/// creating the processor, and official CPU #340 runs with `mintPrice = 0` -
/// so the 104 x 0.01 BEM = 1.04 BEM gate line in the cost table may be our
/// own choice, not a protocol floor.
///
/// This probe answers it on a FORK of X Layer mainnet (chain 196): create two
/// processors, one with `mintPrice = 0` and one with the proven `1e6`, mint the
/// full 104 Split3 gates on each, and print the REAL BEM each path pulls.
/// Nothing is broadcast, no key is used, BEM comes from the pool's fork
/// balance via `vm.prank` - pure measurement.
///
/// Machine-readable output:
///   PROBE|meta|chainid=..|block=..
///   PROBE|<tag>|create=ok|costUnits=..|transistors=0x..
///   PROBE|<tag>|create=REVERT|price=..
///   PROBE|<tag>|mint=ok|costUnits=..|mintPrice=..|protocolFee=..
///   PROBE|<tag>|mint=REVERT|price=..
contract MintPriceProbeTest is Test {
    address constant FACTORY = 0x1f09DAeFA827f02CBb40967cc91b259763760761;
    address constant BEM = 0x60e62Efa9405d6873C5deaBD4E6CC91c25363952;
    // The BEM/WOKB 1% pool holds ~2,370 BEM on mainnet - the fork's source.
    address constant WHALE = 0x2CcF8aa17F5DF9Fb5D51C9de12135a913fF29f7A;

    // Phase state kept in storage so each helper stays stack-safe.
    address internal fresh;
    address internal trans;
    uint256 internal balBeforeCreate;
    uint256 internal balBeforeMint;

    function setUp() public {
        vm.createSelectFork(vm.envString("XLAYER_RPC"));
    }

    function _answerUint(address target, string memory sig) internal view returns (bool, uint256) {
        (bool ok, bytes memory ret) = target.staticcall(abi.encodeWithSignature(sig));
        if (!ok || ret.length != 32) return (false, 0);
        return (true, abi.decode(ret, (uint256)));
    }

    /// createCPU's two addresses assigned BY CAPABILITY (shape 2 = circuits,
    /// shape 1 = transistors), never by position - same rule as §19.
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

    function _createPhase(string memory tag, uint256 price) internal returns (bool) {
        vm.startPrank(fresh);
        IBemP(BEM).approve(FACTORY, type(uint256).max);
        bool ok;
        address first;
        address second;
        bytes memory why;
        try ITapeFactoryP(FACTORY).createCPU(
            string.concat("Probe-", tag), "PRB", "mint price probe", 100_000, price
        ) returns (address f, address s) {
            ok = true;
            first = f;
            second = s;
        } catch (bytes memory r) {
            why = r;
        }
        vm.stopPrank();

        if (!ok) {
            console.log(string.concat("PROBE|", tag, "|create=REVERT|price=", vm.toString(price)));
            console.logBytes(why);
            return false;
        }

        (address circuits, address t_) = _discover(first, second);
        uint256 cost = balBeforeCreate - IBemP(BEM).balanceOf(fresh);
        console.log(
            string.concat(
                "PROBE|",
                tag,
                "|create=ok|costUnits=",
                vm.toString(cost),
                "|transistors=",
                vm.toString(t_)
            )
        );
        console.log(string.concat("PROBE|", tag, "|circuits=", vm.toString(circuits)));
        if (t_ == address(0)) return false;
        trans = t_;
        return true;
    }

    function _mintPhase(string memory tag, uint256 price) internal {
        vm.startPrank(fresh);
        IBemP(BEM).approve(trans, type(uint256).max);
        bool ok;
        bytes memory why;
        try ITransistorsP(trans).mint(0, Split3.NAND_COUNT) {
            ok = true;
        } catch (bytes memory r) {
            why = r;
        }
        vm.stopPrank();

        if (!ok) {
            console.log(string.concat("PROBE|", tag, "|mint=REVERT|price=", vm.toString(price)));
            console.logBytes(why);
            return;
        }

        uint256 cost = balBeforeMint - IBemP(BEM).balanceOf(fresh);
        (bool okMp, uint256 mp) = _answerUint(trans, "mintPrice()");
        (bool okPf, uint256 pf) = _answerUint(trans, "protocolFee()");
        console.log(
            string.concat(
                "PROBE|",
                tag,
                "|mint=ok|costUnits=",
                vm.toString(cost),
                "|mintPrice=",
                okMp ? vm.toString(mp) : "no-answer",
                "|protocolFee=",
                okPf ? vm.toString(pf) : "no-answer"
            )
        );
    }

    function _probe(string memory tag, uint256 price) internal {
        fresh = makeAddr(string.concat("p-", tag));
        // Fund from the pool's BEM balance - fork-only, nothing broadcast.
        // BEM declares no return value, so check the balance instead.
        vm.prank(WHALE);
        IBemP(BEM).transfer(fresh, 3e8);
        require(IBemP(BEM).balanceOf(fresh) > 0, "whale funding failed");

        balBeforeCreate = IBemP(BEM).balanceOf(fresh);
        if (!_createPhase(tag, price)) return;
        balBeforeMint = IBemP(BEM).balanceOf(fresh);
        _mintPhase(tag, price);
    }

    function test_mintPriceFloorProbe() public {
        console.log(
            string.concat(
                "PROBE|meta|chainid=", vm.toString(block.chainid), "|block=", vm.toString(block.number)
            )
        );
        _probe("zero", 0);
        _probe("one", 1e6);
    }
}
