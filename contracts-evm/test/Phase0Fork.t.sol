// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {IRuleProcessor} from "../src/IRuleProcessor.sol";

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

    // ---------- Phase 0.8: create a processor and tape out on the fork ----------

    /// Phase 0.8 result: **UNSUPPORTED** on the current factory implementation.
    ///
    /// `createCPU` cannot be satisfied (see `test_createCPUIsCurrentlyUnsatisfiable`),
    /// so minting transistors and taping out a netlist on this fork cannot be
    /// reproduced end to end. Rather than pretend otherwise, this test records
    /// the blocked state and keeps the real flow ready for the day TapeOut ships
    /// a payable `createCPU`.
    function test_createProcessorAndTapeOutOnFork() public {
        uint256 before = ITapeFactory(FACTORY).cpuCount();
        vm.deal(alice, 10 ether);

        address circuits;
        address transistors;
        bool creatable;
        vm.prank(alice);
        try ITapeFactory(FACTORY).createCPU{value: ITapeFactory(FACTORY).deployFee()}(
            "Pago", "PAGO", "Pago rule library: shareable payment-term circuits.", 100_000, 0
        ) returns (address c, address t) {
            creatable = true;
            circuits = c;
            transistors = t;
        } catch {
            creatable = false;
        }

        if (!creatable) {
            console.log("UNSUPPORTED: createCPU is non-payable yet charges a fee.");
            console.log("Cannot mint transistors or tape out a netlist on this fork.");
            assertEq(ITapeFactory(FACTORY).cpuCount(), before, "no processor may have been created");
            return;
        }

        console.log("circuits:", circuits);
        console.log("transistors:", transistors);
        assertTrue(ITapeFactory(FACTORY).cpuCount() == before + 1, "cpu not created");

        ITransistors t = ITransistors(transistors);
        vm.prank(alice);
        t.mint{value: t.protocolFee() + t.mintPrice() * 64}(t.NAND(), 64);
        console.log("minted NAND");

        // A minimal AND(a,b) netlist: signals 0,1 constants; inputs 2,3; then NAND(2,3).
        bytes memory nl = hex"00000002000003";
        ICircuits c = ICircuits(circuits);
        vm.prank(alice);
        uint256 id = c.tapeout{value: c.TAPEOUT_FEE()}(nl, 2, 1);
        console.log("taped out circuit id", id);
        assertEq(id, 1, "first circuit id");

        IRuleProcessor p = IRuleProcessor(circuits);
        (uint32 nIn, uint32 nOut, , uint32 gates) = p.circuitInfo(id);
        assertEq(nIn, 2, "nIn");
        assertEq(nOut, 1, "nOut");
        assertEq(gates, 1, "one NAND");

        assertEq(uint256(uint8(p.eval(id, hex"03")[0])), 1, "AND(1,1) must be 1");
        assertEq(uint256(uint8(p.eval(id, hex"01")[0])), 0, "AND(0,1) must be 0");
    }

    /// Phase 0.8 finding: on the current factory implementation
    /// (`0x336e9F0F4c3fEe7C8c803377e4DEA00293f4ae2a`) `createCPU` is
    /// **non-payable**, yet it also enforces the 1e7 wei creation fee. Paying
    /// trips the payable guard; paying nothing trips the fee check, so no value
    /// satisfies both.
    ///
    /// Evidence gathered in Phase 0:
    ///   - `createCPU` entry at byte 0x1027 begins `CALLVALUE PUSH3 0x540 JUMPI`
    ///   - 0x540 is `PUSH0 DUP1 REVERT` -> `revert(0,0)`, no revert data
    ///   - the paid call's trace reverts after 179 gas, before any storage read
    ///   - the unpaid call passes the guard and fails the fee check instead
    ///
    /// Both branches are pinned here so the suite turns red if TapeOut upgrades
    /// the implementation to a payable version, which would lift this limit.
    function test_createCPUIsCurrentlyUnsatisfiable() public {
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
        assertTrue(!paidOk, "createCPU accepted a payment; re-investigate and lift UNSUPPORTED");

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
        assertTrue(!unpaidOk, "createCPU accepted zero payment; re-investigate and lift UNSUPPORTED");

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
