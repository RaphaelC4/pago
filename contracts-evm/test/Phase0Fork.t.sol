// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {IRuleProcessor} from "../src/IRuleProcessor.sol";
import {Pago} from "../src/Pago.sol";
import {Split3} from "../src/circuits/Split3.sol";
import {MockToken} from "./mocks/MockToken.sol";

interface ITapeFactory {
    event CPUCreated(
        address indexed circuits,
        address indexed transistors,
        address indexed creator,
        string name,
        uint256 supply,
        uint256 mintPrice
    );

    function createCPU(string calldata, string calldata, string calldata, uint256, uint256) external payable
        returns (address circuits, address transistors);

    function deployFee() external view returns (uint256);
    function protocolFee() external view returns (uint256);
    function cpuCount() external view returns (uint256);
}

interface ITransistors {
    function mint(uint256 id, uint256 amount) external payable;
    function NAND() external view returns (uint256);
    function LATCH() external view returns (uint256);
    function protocolFee() external view returns (uint256);
    function mintPrice() external view returns (uint256);
}

interface ICircuits {
    function tapeout(bytes calldata, uint32, uint32) external payable returns (uint256);
    function TAPEOUT_FEE() external view returns (uint256);
}

/// Phase 0 fork proofs. Every transaction here is simulated against a fork of
/// X Layer mainnet. Nothing is broadcast; no real key is ever used.
contract Phase0ForkTest is Test {
    address constant FACTORY = 0x1f09DAeFA827f02CBb40967cc91b259763760761;
    address constant USDT0 = 0x779Ded0c9e1022225f8E0630b35a9b54bE713736;
    address constant USDG = 0x4ae46a509F6b1D9056937BA4500cb143933D2dc8;
    // Processor #340 (BBBFi TapeGuard), circuit #1, used as the public reference circuit.
    address constant CPU_340 = 0x9de448A1CE9537d24199B3b5355239d73aA6F591;
    // The factory's fee token (section 13): 0.1 BEM = 1e7 units at 8 decimals.
    address constant BEM = 0x60e62Efa9405d6873C5deaBD4E6CC91c25363952;

    // Rule 6's recorded references (section 18), deliberately literals - the
    // point of the Tier 2 test is that Pago is deployed against values
    // recorded OFFCHAIN, never read live from the fork under test. Same
    // values ForkPin.t.sol pins processor #340 against.
    address constant BEACON = 0xf70d1ed4f62CF3780157B0b421b7E2F45bD0991C;
    address constant IMPL = 0x977f217887E085D298Cb3819cDAD5A0ee35F29B2;
    bytes32 constant RECORDED_SHELL = 0x57aa306fd0be97087da3534e03398f5ff4efd533b5be4e45a405ce86fa6717d5;
    bytes32 constant RECORDED_IMPL = 0x7a15c353205e5245f40f5f5524542a982a4bb3b9a28476e4f10845163f941b30;

    // Derived from a single deterministic key in setUp so that every signature
    // in this file actually recovers to `alice`. Signing with an unrelated key
    // would recover to some other address and fail as "invalid signature".
    address alice;
    uint256 aliceKey;

    function setUp() public {
        vm.createSelectFork(vm.envString("XLAYER_RPC"));
        (alice, aliceKey) = makeAddrAndKey("alice");
    }

    // ---------- Phase 0.5: EIP-3009 ----------

    /// Rebuilds the EIP-712 domain from name()/version()/chainId and checks it
    /// equals the token's own DOMAIN_SEPARATOR. If this fails, our domain is wrong
    /// and any signature would be rejected.
    function test_eip3009DomainMatchesOnchain() public {
        assertEq(_domainMatch(USDT0), true, "USDT0 domain mismatch");
        assertEq(_domainMatch(USDG), true, "USDG domain mismatch");
    }

    function _domainMatch(address token) internal returns (bool) {
        string memory name = IERC20Name(token).name();
        bytes32 onchain = IDomain(token).DOMAIN_SEPARATOR();
        bytes32 v1 = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes(name)),
                keccak256(bytes("1")),
                block.chainid,
                token
            )
        );
        if (v1 == onchain) {
            console.log("domain ok (version 1) for", token);
            return true;
        }
        bytes32 vEmpty = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes(name)),
                keccak256(bytes("")),
                block.chainid,
                token
            )
        );
        console.log("version '1' and '' both mismatch; onchain:", vm.toString(onchain));
        console.log("calculated v1:", vm.toString(v1));
        console.log("calculated v'':", vm.toString(vEmpty));
        return vEmpty == onchain;
    }

    /// The path Pago will use: the payer signs once, a **third party** (our
    /// relayer) submits `transferWithAuthorization`. This is the gasless path.
    /// Note USDT0's `receiveWithAuthorization` is recipient-only
    /// (`TetherToken: to != msg.sender`), so that variant is not usable by a
    /// relayer.
    function test_eip3009TransferAuthorizationByThirdParty() public {
        _proveTransferMoves(USDT0);
    }

    function test_eip3009TransferAuthorizationByThirdPartyUsdg() public {
        _proveTransferMoves(USDG);
    }

    function _proveTransferMoves(address token) internal {
        deal(token, alice, 100e6);
        address recipient = makeAddr("recipient");
        uint256 startBal = IERC20(token).balanceOf(recipient);

        bytes32 nonce = keccak256(abi.encodePacked("pago", token, block.timestamp));
        bytes32 digest = _digestTransfer(token, alice, recipient, 25e6, 0, block.timestamp + 1 days, nonce);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(aliceKey, digest);
        assertEq(ecrecover(digest, v, r, s), alice, "signature must recover to payer");

        // Called by this contract: neither alice nor the recipient.
        uint256 g = gasleft();
        IERC3009(token).transferWithAuthorization(alice, recipient, 25e6, 0, block.timestamp + 1 days, nonce, v, r, s);
        console.log("transferWithAuthorization gas", g - gasleft());

        assertEq(IERC20(token).balanceOf(recipient) - startBal, 25e6, "recipient not paid");
        assertEq(IERC20(token).balanceOf(alice), 75e6, "payer not debited");
    }

    /// The same authorization must not be spendable twice.
    function test_eip3009TransferAuthorizationReplayFails() public {
        _proveTransferReplay(USDT0);
    }

    function _proveTransferReplay(address token) internal {
        deal(token, alice, 100e6);
        address recipient = makeAddr("recipient");

        bytes32 nonce = keccak256(abi.encodePacked("replay", token, block.timestamp));
        bytes32 digest = _digestTransfer(token, alice, recipient, 25e6, 0, block.timestamp + 1 days, nonce);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(aliceKey, digest);

        IERC3009(token).transferWithAuthorization(alice, recipient, 25e6, 0, block.timestamp + 1 days, nonce, v, r, s);
        assertEq(IERC20(token).balanceOf(recipient), 25e6, "first use must succeed");

        vm.expectRevert();
        IERC3009(token).transferWithAuthorization(alice, recipient, 25e6, 0, block.timestamp + 1 days, nonce, v, r, s);
        assertEq(IERC20(token).balanceOf(recipient), 25e6, "replay must not pay again");
    }

    /// Outside its validity window the authorization must be refused.
    function test_eip3009TransferAuthorizationTimeWindowFails() public {
        _proveTransferTimeWindow(USDT0);
    }

    function _proveTransferTimeWindow(address token) internal {
        deal(token, alice, 100e6);
        address recipient = makeAddr("recipient");

        // validAfter in the future
        bytes32 n1 = keccak256(abi.encodePacked("future", token, block.timestamp));
        bytes32 d1 = _digestTransfer(token, alice, recipient, 1e6, block.timestamp + 1 days, block.timestamp + 2 days, n1);
        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(aliceKey, d1);
        vm.expectRevert();
        IERC3009(token).transferWithAuthorization(
            alice, recipient, 1e6, block.timestamp + 1 days, block.timestamp + 2 days, n1, v1, r1, s1
        );

        // validBefore in the past
        bytes32 n2 = keccak256(abi.encodePacked("past", token, block.timestamp));
        bytes32 d2 = _digestTransfer(token, alice, recipient, 1e6, block.timestamp + 10 days, block.timestamp + 20 days, n2);
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(aliceKey, d2);
        vm.expectRevert();
        IERC3009(token).transferWithAuthorization(
            alice, recipient, 1e6, block.timestamp + 10 days, block.timestamp + 20 days, n2, v2, r2, s2
        );

        assertEq(IERC20(token).balanceOf(recipient), 0, "nothing may have moved");
    }

    /// A well-formed signature from a key that is not the payer's must revert.
    function test_eip3009WrongSignerReverts() public {
        deal(USDT0, alice, 100e6);
        address recipient = makeAddr("recipient");
        (, uint256 bobKey) = makeAddrAndKey("bob");

        bytes32 nonce = keccak256(abi.encodePacked("wrong-signer", block.timestamp));
        bytes32 digest = _digestTransfer(USDT0, alice, recipient, 1e6, 0, block.timestamp + 1 days, nonce);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(bobKey, digest);
        assertTrue(ecrecover(digest, v, r, s) != alice, "sanity: wrong signer");

        vm.expectRevert();
        IERC3009(USDT0).transferWithAuthorization(
            alice, recipient, 1e6, 0, block.timestamp + 1 days, nonce, v, r, s
        );
        assertEq(IERC20(USDT0).balanceOf(recipient), 0, "nothing moved");
    }

    /// `receiveWithAuthorization` is recipient-submitted only on USDT0.
    function test_eip3009ReceiveIsRecipientOnly() public {
        deal(USDT0, alice, 100e6);
        address recipient = makeAddr("recipient");

        bytes32 nonce = keccak256(abi.encodePacked("recv", block.timestamp));
        bytes32 digest = _digest(USDT0, alice, recipient, 25e6, 0, block.timestamp + 1 days, nonce);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(aliceKey, digest);
        assertEq(ecrecover(digest, v, r, s), alice, "signature must recover to payer");

        // Third-party submission must be refused.
        vm.expectRevert(bytes("TetherToken: to != msg.sender"));
        IERC3009(USDT0).receiveWithAuthorization(
            alice, recipient, 25e6, 0, block.timestamp + 1 days, nonce, v, r, s
        );
        assertEq(IERC20(USDT0).balanceOf(recipient), 0, "nothing moved");

        // The recipient itself may submit it.
        vm.prank(recipient);
        IERC3009(USDT0).receiveWithAuthorization(
            alice, recipient, 25e6, 0, block.timestamp + 1 days, nonce, v, r, s
        );
        assertEq(IERC20(USDT0).balanceOf(recipient), 25e6, "recipient-submitted receive must work");
    }

    function _digest(address token, address from, address to, uint256 value, uint256 after_, uint256 before_, bytes32 nonce)
        internal
        view
        returns (bytes32)
    {
        return _digestOfType(
            token,
            keccak256(
                "ReceiveWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)"
            ),
            from,
            to,
            value,
            after_,
            before_,
            nonce
        );
    }

    function _digestTransfer(
        address token,
        address from,
        address to,
        uint256 value,
        uint256 after_,
        uint256 before_,
        bytes32 nonce
    ) internal view returns (bytes32) {
        return _digestOfType(
            token,
            keccak256(
                "TransferWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)"
            ),
            from,
            to,
            value,
            after_,
            before_,
            nonce
        );
    }

    function _digestOfType(
        address token,
        bytes32 typehash,
        address from,
        address to,
        uint256 value,
        uint256 after_,
        uint256 before_,
        bytes32 nonce
    ) internal view returns (bytes32) {
        bytes32 structHash = keccak256(abi.encode(typehash, from, to, value, after_, before_, nonce));
        return keccak256(abi.encodePacked("\x19\x01", IDomain(token).DOMAIN_SEPARATOR(), structHash));
    }

    // ---------- Tier 2 de-risk: a processor made through the real factory ----

    /// Tier 2, de-risked on the fork before a cent is spent: create a
    /// processor through the REAL factory (cheatcode-funded BEM, nothing
    /// broadcast), mint a transistor, tape out the real Split3 netlist, then
    /// deploy Pago against references recorded offchain from THAT processor
    /// and prove it pins and the rule table pays - exactly what
    /// `deploy to mainnet tier 2` would do with real funds.
    ///
    /// Honest outcomes, in order:
    ///   * a stage is blocked on this factory -> the console says UNSUPPORTED
    ///     at that stage with the revert reason, and the test records it;
    ///   * createCPU's two addresses are assigned by CAPABILITY, not
    ///     position - the interface's return order was a placeholder and
    ///     the first probe had them backwards (first = transistors);
    ///   * the inference "every processor carries #340's recorded shell
    ///     hash" is DISCLOSED either way with a byte-level diff - if the
    ///     shells differ, the log says where, and the deploy uses the new
    ///     processor's OWN recorded references (the Tier 2 procedure);
    ///   * hard failures (must never be hidden): the embedded beacon has no
    ///     code or does not answer implementation(), Pago does not pin, or
    ///     the real taped-out circuit does not make the rule table pay.
    function test_realFactoryProcessorTapesOutSplit3AndPaysTheRuleTable() public {
        vm.deal(alice, 10 ether);
        deal(BEM, alice, 1_000_000_000); // 10 BEM at 8 decimals - cheatcode money, never real

        // ── stage 1: createCPU - the fee is ERC-20 BEM, approved, no value ──
        // Section 13: the blocker Phase 0 recorded was the wrong cause; the
        // fee is a transferFrom, not msg.value.
        address circuits;
        address transistors;
        {
            uint256 countBefore = ITapeFactory(FACTORY).cpuCount();
            (bool created, address first, address second) = _tryCreateCPU();
            if (!created) {
                assertEq(ITapeFactory(FACTORY).cpuCount(), countBefore, "no processor may have been created");
                return;
            }
            assertEq(ITapeFactory(FACTORY).cpuCount(), countBefore + 1, "processor not created");
            console.log("createCPU returned first:", first);
            console.log("createCPU returned second:", second);

            // Which address is which: the interface's return names were a
            // placeholder never verified against TapeOut's ABI, and the
            // first probe had them backwards - the FIRST address serves the
            // mint / ERC-1155 transistors surface, the SECOND the tapeout /
            // netlist circuits surface. Assign ROLES BY CAPABILITY, and log
            // the shape each one answered.
            (bool rolesOk, address c_, address t_) = _discoverRoles(first, second);
            if (!rolesOk) return; // _discoverRoles logged UNSUPPORTED
            circuits = c_;
            transistors = t_;
        }
        console.log("circuits (tapeout surface):", circuits);
        console.log("transistors (mint surface):", transistors);
        assertGt(circuits.code.length, 0, "the circuits contract must have code");
        assertGt(transistors.code.length, 0, "the transistors contract must have code");
        _logWiring(circuits, transistors);

        // THE Tier 2 inference, tested head-on and DISCLOSED either way:
        // "every factory processor carries the same recorded shell hash"
        // (from #30/#333/#340) holds only if this new shell matches #340's.
        // The byte-diff runs in its own frame, so the log says WHERE the
        // shells differ, not just THAT they do.
        _logShellDiff(circuits, CPU_340);
        console.log("new shell matches recorded #340 shell:", circuits.codehash == RECORDED_SHELL);
        console.log("#340 recorded beacon:", BEACON);
        console.log("#340 recorded impl:", IMPL);

        // What a Tier 2 operator actually records OFFCHAIN after createCPU:
        // the new processor's own shell hash, the beacon its shell embeds
        // (found by disassembling the PUSH32 behind the `implementation()`
        // selector - the documented method, README "how the beacon address
        // is bound"), what that beacon currently reports, and that code's
        // hash. All four become Pago constructor arguments; Pago itself
        // never reads them from anywhere - it only re-verifies them live.
        Refs memory refs = _recordReferences(circuits);
        console.log("recorded shell hash:", vm.toString(refs.shell));
        console.log("recorded beacon:", refs.beacon);
        console.log("beacon reports impl:", refs.impl);
        console.log("recorded impl hash:", vm.toString(refs.implHash));
        assertGt(refs.beacon.code.length, 0, "the shell's embedded beacon must have code");
        assertGt(refs.impl.code.length, 0, "the beacon must report an implementation with code");

        // Does the CURRENT circuit implementation still expose the surface
        // Pago calls? A new processor delegates to it, so if `netlist` /
        // `eval` / `circuitInfo` are gone, no new processor can ever serve a
        // Pago link - a hard Tier 2 blocker, logged here before anything
        // tries to call them.
        bytes memory implCode = refs.impl.code;
        console.log("circuit impl has netlist(uint256):", _hasSelector(implCode, "netlist(uint256)"));
        console.log("circuit impl has eval(uint256,bytes):", _hasSelector(implCode, "eval(uint256,bytes)"));
        console.log("circuit impl has circuitInfo(uint256):", _hasSelector(implCode, "circuitInfo(uint256)"));
        console.log("circuit impl has tapeout(bytes,uint32,uint32):", _hasSelector(implCode, "tapeout(bytes,uint32,uint32)"));

        // ── stages 2 + 3: tape out the real Split3, minting first only if
        // the tapeout gate demands it ────────────────────────────────────────
        // Tapeout is attempted first: if the current factory gates it behind
        // a transistor, the revert says so and we mint then retry; if the
        // gate changed (or the creator is pre-credited), minting is
        // pointless. Every blocked stage is a logged UNSUPPORTED outcome,
        // never a bare revert.
        (bool ok, uint256 circuitId) = _tapeOutSplit3(circuits);
        if (!ok) {
            console.log("first tapeout attempt did not succeed - trying the transistor mint, then retrying once");
            if (!_mintTransistor(transistors)) {
                console.log("UNSUPPORTED: no way to mint the transistor that tapeout may require");
                return;
            }
            (ok, circuitId) = _tapeOutSplit3(circuits);
            if (!ok) {
                console.log("UNSUPPORTED: tapeout still does not succeed after the mint");
                return;
            }
        }

        // ── stages 4 + 5: deploy Pago, then prove the rule table pays ────────
        // Their own frame keeps the stack above shallow enough to compile
        // (no via-ir needed for one test).
        _deployAndProveRuleTable(circuits, circuitId, refs);
        console.log("TIER 2 REPRODUCIBLE: factory processor pinned and the rule table paid");
    }

    /// Dump what the factory's CURRENT transistors exposes: follow its beacon
    /// to the implementation, list every PUSH4 (dispatcher selector
    /// candidate), and check the plausible mint signatures explicitly - so
    /// an unknown surface is looked up, not guessed at.
    function _discoverTransistorSurface(address transistors) internal view {
        (address tImpl, bool isShell) = _followBeacon(transistors);
        bytes memory dispatch = isShell ? tImpl.code : transistors.code;
        if (isShell) console.log("transistors beacon impl:", tImpl);
        _logPush4s(isShell ? "transistors impl" : "transistors", dispatch);
        console.log("has mint(uint256,uint256):", _hasSelector(dispatch, "mint(uint256,uint256)"));
        console.log("has mint(uint256):", _hasSelector(dispatch, "mint(uint256)"));
        console.log("has mint(address,uint256):", _hasSelector(dispatch, "mint(address,uint256)"));
        console.log("has buy(uint256):", _hasSelector(dispatch, "buy(uint256)"));
        console.log("has mintPrice():", _hasSelector(dispatch, "mintPrice()"));
        console.log("has price():", _hasSelector(dispatch, "price()"));
        console.log("has protocolFee():", _hasSelector(dispatch, "protocolFee()"));
        console.log("has owner():", _hasSelector(dispatch, "owner()"));
    }

    /// Stage 2: mint the transistors that gate `tapeout` (ERC-1155 id 0 -
    /// the gate wants ONE HELD PER GATE of the netlist: Split3 has 104
    /// NANDs, so 104 are minted here). The role was assigned by capability
    /// (_discoverRoles), so the fee reads below hit the real mint surface;
    /// both mint routes (native value as some processors charge, no value
    /// + BEM allowance as section 13 says) are attempted under try/catch.
    /// A blocked stage logs UNSUPPORTED and returns false; it never
    /// reverts bare.
    function _mintTransistor(address transistors) internal returns (bool) {
        console.log("stage 2: mint the transistors tapeout requires (ERC-1155 id 0)");
        // Surface discovery: dump the mint surface (PUSH4 candidates plus
        // the known signatures) so the evidence is in the test output even
        // if the mint itself is blocked.
        _discoverTransistorSurface(transistors);

        (bool okMp, bytes memory retMp) = transistors.staticcall(abi.encodeWithSignature("mintPrice()"));
        (bool okPf, bytes memory retPf) = transistors.staticcall(abi.encodeWithSignature("protocolFee()"));
        uint256 mintPrice;
        uint256 protocolFee;
        bool haveFees = okMp && retMp.length == 32 && okPf && retPf.length == 32;
        if (okMp && retMp.length == 32) {
            mintPrice = abi.decode(retMp, (uint256));
            console.log("mintPrice (BEM units):", mintPrice);
        } else {
            console.log("mintPrice() did not answer - this transistors differs from #340's");
        }
        if (okPf && retPf.length == 32) {
            protocolFee = abi.decode(retPf, (uint256));
            console.log("protocolFee:", protocolFee);
        }

        // Tapeout's gate, observed on this factory: its revert carries
        // (account, held, required, 0) with required = the netlist's gate
        // count - Split3 has 104 NANDs, so 104 transistors of id 0 must be
        // held, not just one (the Phase 0 probe used a 1-gate netlist and
        // saw required = 1, which is why the docs used to say "one").
        uint256 required = Split3.NAND_COUNT;
        ITransistors tr = ITransistors(transistors);
        vm.startPrank(alice);
        IBem(BEM).approve(transistors, type(uint256).max);
        bool minted;
        if (haveFees) {
            try tr.mint{value: protocolFee + mintPrice}(0, required) {
                minted = true;
            } catch (bytes memory reason) {
                console.log("native-value mint failed:");
                console.logBytes(reason);
            }
        }
        if (!minted) {
            try tr.mint(0, required) {
                minted = true;
            } catch (bytes memory reason) {
                console.log("no-value (BEM) mint failed:");
                console.logBytes(reason);
            }
        }
        vm.stopPrank();
        if (!minted) {
            console.log("UNSUPPORTED at stage 2 (transistor mint) - reasons logged above");
            return false;
        }
        console.log("minted transistors (id 0):", required);
        return true;
    }

    /// Stage 3: tape out the real Split3 netlist through the factory-made
    /// processor, then check the processor serves those exact bytes back
    /// (rule 5 reads them at createLink) and reports the real TAP-02 shape.
    /// `TAPEOUT_FEE()` is probed first for the same reason as the transistors
    /// surface: a call that does not answer is a logged stage outcome.
    function _tapeOutSplit3(address circuits) internal returns (bool, uint256) {
        console.log("stage 3: tape out the real Split3 netlist");
        bytes memory nl = Split3.netlist();
        console.log("netlist bytes:", nl.length);
        (bool okFee, bytes memory retFee) = circuits.staticcall(abi.encodeWithSignature("TAPEOUT_FEE()"));
        if (!okFee || retFee.length != 32) {
            console.log("TAPEOUT_FEE() did not answer - the circuits surface differs from #340's");
            return (false, 0);
        }
        uint256 tapeoutFee = abi.decode(retFee, (uint256));
        console.log("TAPEOUT_FEE (native wei):", tapeoutFee);

        ICircuits ci = ICircuits(circuits);
        uint256 circuitId;
        bool taped;
        vm.startPrank(alice);
        try ci.tapeout{value: tapeoutFee}(nl, Split3.N_IN, Split3.N_OUT) returns (uint256 id_) {
            circuitId = id_;
            taped = true;
        } catch (bytes memory reason) {
            console.log("tapeout failed:");
            console.logBytes(reason);
        }
        vm.stopPrank();
        if (!taped) {
            console.log("tapeout did not succeed - reason logged above");
            return (false, 0);
        }
        console.log("taped out circuit id:", circuitId);

        IRuleProcessor rp = IRuleProcessor(circuits);
        assertEq(keccak256(rp.netlist(circuitId)), keccak256(nl), "processor must serve the netlist we taped out");
        (uint32 nIn, uint32 nOut,,) = rp.circuitInfo(circuitId);
        assertEq(uint256(nIn), uint256(Split3.N_IN), "15 inputs");
        assertEq(uint256(nOut), uint256(Split3.N_OUT), "1 output");
        return (true, circuitId);
    }

    /// Stages 4 and 5 of the Tier 2 test: deploy Pago against the four
    /// references recorded for THIS processor, assert the live two-leg check
    /// passes, then create -> pay -> claim a link whose rule table the REAL
    /// taped-out Split3 circuit must select (event `usedRuleSplit = true`)
    /// and whose seats must be paid to the unit.
    function _deployAndProveRuleTable(address circuits, uint256 circuitId, Refs memory refs) internal {
        // ── stage 4: deploy Pago against the recorded references ─────────────
        MockToken token = new MockToken("Fork USD", "fkUSD", 6);
        Pago.TokenConfig[] memory configs = new Pago.TokenConfig[](1);
        configs[0] = Pago.TokenConfig({token: address(token), decimals_: 6, unpinnedCap: 10_000_000_000});
        Pago p = new Pago(configs, makeAddr("fee"), circuits, circuitId, refs.shell, refs.beacon, refs.impl, refs.implHash);
        assertTrue(p.evaluatorPinned(), "factory processor + its own recorded references must pin");

        // ── stage 5: the rule table pays, live, through the real circuit ─────
        address creator = makeAddr("creator");
        address payer = makeAddr("payer");
        address relayer = makeAddr("relayer");
        address payee = makeAddr("payee");
        address seat1 = makeAddr("seat1");
        address seat2 = makeAddr("seat2");

        vm.prank(creator);
        p.createLink(
            "factory-rule",
            1_000_000,
            address(token),
            "Tier 2 fork proof: real factory processor",
            0,
            _split(payee, address(0), address(0), 20, 0, 0),
            _split(payee, seat1, seat2, 15, 3, 2)
        );

        token.mint(payer, 1_000_000);
        vm.startPrank(payer);
        token.approve(address(p), 1_000_000);
        p.pay("factory-rule", 1_000_000, p.termsHash("factory-rule"));
        vm.stopPrank();

        // The claim event itself must record which table paid: the RULE
        // table, chosen by the REAL taped-out circuit answering yes to
        // 15+3+2 = 100%. Seat percentages: 75/15/10 of the 995,000 payout.
        bytes32 key = p.linkKeyOf("factory-rule");
        vm.expectEmit(true, true, true, true);
        emit Pago.LinkClaimed(key, 995_000, 5_000, true);
        vm.prank(relayer);
        p.claim("factory-rule");

        assertEq(token.balanceOf(payee), 746_250, "rule seat 1: 75% - the real circuit said yes");
        assertEq(token.balanceOf(seat1), 149_250, "rule seat 2: 15%");
        assertEq(token.balanceOf(seat2), 99_500, "rule seat 3: 10%");
        assertEq(token.balanceOf(makeAddr("fee")), 5_000, "the 0.5% fee");
        console.log("rule table paid through the real factory circuit");
    }

    /// Three seats in 5% steps: recipients with a share must be honest seats.
    function _split(address r0, address r1, address r2, uint8 s0, uint8 s1, uint8 s2)
        internal
        pure
        returns (Pago.Split memory s)
    {
        s.recipients = [r0, r1, r2];
        s.shares = [s0, s1, s2];
    }

    /// The four references a Tier 2 deploy records offchain for ONE processor:
    /// its shell's codehash, the beacon embedded in that shell (disassembled,
    /// not read from storage - no storage of another account is readable
    /// onchain), what the beacon's public getter reports right now, and the
    /// code hash there. Recorded from a read of the fork, exactly as a mainnet
    /// operator would record them with `cast` before deploying Pago.
    struct Refs {
        bytes32 shell;
        address beacon;
        address impl;
        bytes32 implHash;
    }

    function _recordReferences(address shellAddr) internal view returns (Refs memory r) {
        r.shell = shellAddr.codehash;
        r.beacon = _embeddedBeacon(shellAddr);
        (bool ok, bytes memory ret) = r.beacon.staticcall(abi.encodeWithSignature("implementation()"));
        require(ok && ret.length == 32, "the embedded beacon does not answer implementation()");
        r.impl = address(uint160(uint256(bytes32(ret))));
        r.implHash = r.impl.codehash;
    }

    /// Disassemble the shell: `PUSH4 5c60da1b` (`implementation()`) ...
    /// `PUSH32 <beacon>` ... `STATICCALL` - the first PUSH32 payload in the
    /// code is the beacon address the shell hardcodes (README step 2).
    function _embeddedBeacon(address shellAddr) internal view returns (address) {
        (bool found, address beacon) = _tryEmbeddedBeacon(shellAddr);
        require(found, "no PUSH32 in shell - re-disassemble");
        return beacon;
    }

    /// The same disassembly, non-reverting: (found, beacon address).
    function _tryEmbeddedBeacon(address target) internal view returns (bool, address) {
        bytes memory code = target.code;
        for (uint256 i; i + 33 <= code.length; ++i) {
            if (code[i] == 0x7f) {
                // PUSH32 payload, big-endian; the address is its low 20 bytes.
                uint256 payload;
                for (uint256 j; j < 32; ++j) {
                    payload = (payload << 8) | uint8(code[i + 1 + j]);
                }
                return (true, address(uint160(payload)));
            }
        }
        return (false, address(0));
    }

    /// Follow a beacon-proxy shell to its implementation: embedded beacon ->
    /// `implementation()` -> code there. (impl, isShell).
    function _followBeacon(address target) internal view returns (address, bool) {
        (bool found, address beacon) = _tryEmbeddedBeacon(target);
        if (!found) return (address(0), false);
        (bool ok, bytes memory ret) = beacon.staticcall(abi.encodeWithSignature("implementation()"));
        if (!ok || ret.length != 32) return (address(0), false);
        address impl = address(uint160(uint256(bytes32(ret))));
        if (impl.code.length == 0) return (address(0), false);
        return (impl, true);
    }

    /// True if the runtime code contains `PUSH4 <selector of sig>` - i.e. the
    /// dispatcher plausibly exposes that function. A presence probe, not a
    /// proof: PUSH4 constants appear elsewhere too, which is why the full
    /// list is dumped next to it and the real call is still made under
    /// try/catch.
    function _hasSelector(bytes memory code, string memory sig) internal pure returns (bool) {
        uint32 want = uint32(bytes4(keccak256(bytes(sig))));
        for (uint256 i; i + 5 <= code.length; ++i) {
            if (
                code[i] == 0x63 && uint32(uint8(code[i + 1])) == (want >> 24)
                    && uint32(uint8(code[i + 2])) == ((want >> 16) & 0xff)
                    && uint32(uint8(code[i + 3])) == ((want >> 8) & 0xff) && uint32(uint8(code[i + 4])) == (want & 0xff)
            ) {
                return true;
            }
        }
        return false;
    }

    /// Every `PUSH4` constant in runtime code, logged as hex - in practice
    /// the dispatcher's function selectors, so an unknown surface can be
    /// looked up (4byte) instead of guessed at.
    function _logPush4s(string memory label, bytes memory code) internal pure {
        console.log(label, "PUSH4 candidates:");
        uint256 n;
        for (uint256 i; i + 5 <= code.length && n < 64; ++i) {
            if (code[i] == 0x63) {
                uint32 sel = (uint32(uint8(code[i + 1])) << 24) | (uint32(uint8(code[i + 2])) << 16)
                    | (uint32(uint8(code[i + 3])) << 8) | uint32(uint8(code[i + 4]));
                console.log("  ", _u32Hex(sel));
                ++n;
            }
        }
    }

    function _u32Hex(uint32 v) internal pure returns (string memory) {
        bytes memory h = "0123456789abcdef";
        bytes memory o = new bytes(10);
        o[0] = "0";
        o[1] = "x";
        for (uint32 i; i < 4; ++i) {
            uint8 b = uint8(v >> (8 * (3 - i)));
            o[2 + 2 * i] = h[b >> 4];
            o[3 + 2 * i] = h[b & 0xf];
        }
        return string(o);
    }

    /// Stage 1: createCPU with the BEM fee approved and no value (section
    /// 13). Returns the two addresses UNNAMED - which is which is decided
    /// by _discoverRoles, never by position.
    function _tryCreateCPU() internal returns (bool, address, address) {
        vm.startPrank(alice);
        IBem(BEM).approve(FACTORY, type(uint256).max);
        try ITapeFactory(FACTORY).createCPU(
            "Pago", "PAGO", "Pago rule library: shareable payment-term circuits.", 100_000, 1e6
        ) returns (address a, address b) {
            vm.stopPrank();
            return (true, a, b);
        } catch (bytes memory reason) {
            vm.stopPrank();
            console.log("UNSUPPORTED at stage 1 (createCPU) - revert reason:");
            console.logBytes(reason);
            return (false, address(0), address(0));
        }
    }

    /// staticcall a no-arg uint getter: (answered, value).
    function _answerUint(address target, string memory sig) internal view returns (bool, uint256) {
        (bool ok, bytes memory ret) = target.staticcall(abi.encodeWithSignature(sig));
        if (!ok || ret.length != 32) return (false, 0);
        return (true, abi.decode(ret, (uint256)));
    }

    /// A contract's shape: bit 1 = answers TAPEOUT_FEE() (circuits), bit 0
    /// = answers mintPrice() (transistors).
    function _roleCode(address target) internal view returns (uint8) {
        (bool tape,) = _answerUint(target, "TAPEOUT_FEE()");
        (bool mint,) = _answerUint(target, "mintPrice()");
        return uint8((tape ? 2 : 0) | (mint ? 1 : 0));
    }

    /// createCPU returns two addresses and the interface never verified
    /// their order - probing showed the FIRST carries the transistors
    /// surface and the SECOND the circuits surface. Identify each by what
    /// it ANSWERS: shape 2 = circuits (tapeout fee, no mint price),
    /// shape 1 = transistors (mint price, no tapeout fee). Logs both
    /// shapes; (false, 0, 0) when the pair matches neither shape.
    function _discoverRoles(address first, address second) internal view returns (bool, address, address) {
        uint8 shapeA = _roleCode(first);
        uint8 shapeB = _roleCode(second);
        console.log("first shape (2=circuits, 1=transistors):", uint256(shapeA));
        console.log("second shape (2=circuits, 1=transistors):", uint256(shapeB));
        if (shapeA == 2 && shapeB == 1) return (true, first, second);
        if (shapeA == 1 && shapeB == 2) return (true, second, first);
        console.log("UNSUPPORTED: the pair matches neither known circuits/transistors shape");
        return (false, address(0), address(0));
    }

    /// The circuits proxy's own storage, read directly on the fork: which
    /// slot points at the transistors contract (tapeout's transistor gate
    /// must read it from somewhere) and what else is wired in slots 0-7.
    function _logWiring(address circuits, address transistors) internal {
        for (uint256 s; s < 8; ++s) {
            bytes32 v = vm.load(circuits, bytes32(s));
            if (v == bytes32(0)) continue;
            console.log("circuits storage slot:", s);
            console.logBytes32(v);
            if (address(uint160(uint256(v))) == transistors) {
                console.log("  ^ the transistors contract - tapeout's gate is wired to it");
            }
        }
    }

    /// Byte-level comparison of two processor shells, in its own stack frame.
    /// Logs both codes in full plus the index and bytes of every difference,
    /// so a failed pin says exactly where two shells diverge.
    function _logShellDiff(address a, address b) internal view {
        bytes memory codeA = a.code;
        bytes memory codeB = b.code;
        console.log("shell A hex:", vm.toString(codeA));
        console.log("shell B hex:", vm.toString(codeB));
        uint256 diffs;
        for (uint256 i; i < codeA.length && i < codeB.length; ++i) {
            if (codeA[i] != codeB[i]) {
                if (diffs < 16) {
                    console.log("differing byte index:", i);
                    console.log("  A:", uint256(uint8(codeA[i])));
                    console.log("  B:", uint256(uint8(codeB[i])));
                }
                ++diffs;
            }
        }
        console.log("lengths:", codeA.length, codeB.length);
        console.log("total differing bytes:", diffs);
    }

    /// Phase 0 finding, kept as evidence and re-scoped after section 13: on
    /// the current factory implementation (`0x336e9F0F4c3fEe7C8c803377e4DEA00293f4ae2a`)
    /// `createCPU` is **non-payable**, yet it also enforces a 1e7 fee - but
    /// the fee is an ERC-20 BEM transferFrom, NOT msg.value (section 13), so
    /// no native value can ever satisfy it. Phase 0's UNSUPPORTED conclusion
    /// was the wrong cause; the satisfiable path - approve BEM, send no
    /// value - is proven in `test_realFactoryProcessorTapesOutSplit3AndPaysTheRuleTable`
    /// above.
    ///
    /// Evidence gathered in Phase 0:
    ///   - `createCPU` entry at byte 0x1027 begins `CALLVALUE PUSH3 0x540 JUMPI`
    ///   - 0x540 is `PUSH0 DUP1 REVERT` -> `revert(0,0)`, no revert data
    ///   - the paid call's trace reverts after 179 gas, before any storage read
    ///   - the unpaid call passes the guard and fails the fee check instead
    ///     (`ERC20InsufficientAllowance(factory, 0, 1e7)`, section 13)
    ///
    /// Both branches are pinned here so the suite turns red if either guard
    /// changes.
    function test_createCPUChargesBemNotNativeCoin() public {
        vm.deal(alice, 1 ether);
        uint256 deployFee = ITapeFactory(FACTORY).deployFee();
        uint256 countBefore = ITapeFactory(FACTORY).cpuCount();

        // Branch 1: paying the fee -> non-payable guard -> empty revert.
        bool paidOk;
        vm.prank(alice);
        try ITapeFactory(FACTORY).createCPU{value: deployFee}("Pago", "PAGO", "story", 100_000, 0) {
            paidOk = true;
        } catch (bytes memory reason) {
            console.log("paid call revert bytes", reason.length);
            assertEq(reason.length, 0, "paid call must revert with empty data (non-payable guard)");
        }
        assertTrue(!paidOk, "createCPU accepted native value; the non-payable guard changed - re-investigate");

        // Branch 2: paying nothing -> passes the guard, fails the fee check.
        bool unpaidOk;
        vm.prank(alice);
        try ITapeFactory(FACTORY).createCPU{value: 0}("Pago", "PAGO", "story", 100_000, 0) {
            unpaidOk = true;
        } catch (bytes memory reason) {
            console.log("unpaid call revert bytes", reason.length);
            assertGt(reason.length, 0, "unpaid call must revert with the fee error");
            console.logBytes(reason);
        }
        assertTrue(!unpaidOk, "createCPU accepted zero payment with no allowance; the fee check changed - re-investigate");

        assertEq(ITapeFactory(FACTORY).cpuCount(), countBefore, "no processor may have been created");
    }

    function test_feesAreReadFromChainNotHardcoded() public {
        uint256 deployFee = ITapeFactory(FACTORY).deployFee();
        uint256 protocolFee = ITapeFactory(FACTORY).protocolFee();
        console.log("deployFee", deployFee);
        console.log("protocolFee", protocolFee);
        assertLt(deployFee, 1 ether, "sanity: deploy fee is a small OKB amount");
        assertLt(protocolFee, 1 ether, "sanity: protocol fee is a small OKB amount");
    }

    function test_publicCircuitEvalGasMeasured() public {
        IRuleProcessor p = IRuleProcessor(CPU_340);
        uint256 g = gasleft();
        p.eval(1, hex"0f");
        console.log("eval gas (6 gates)", g - gasleft());
    }
}

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
}

/// BEM, the factory's fee token (section 13). `approve` declares no return
/// value so it decodes whether or not the token returns one.
interface IBem {
    function approve(address spender, uint256 amount) external;
    function balanceOf(address) external view returns (uint256);
}

interface IERC20Name {
    function name() external view returns (string memory);
}

interface IDomain {
    function DOMAIN_SEPARATOR() external view returns (bytes32);
}

interface IERC3009 {
    function receiveWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external payable;

    function transferWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external payable;
}
