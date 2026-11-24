// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {Pago} from "../src/Pago.sol";

/// The two live reads this test needs from the genuine USD0 proxy.
interface IDomain {
    function DOMAIN_SEPARATOR() external view returns (bytes32);
}

interface IERC20View {
    function balanceOf(address) external view returns (uint256);
}

/// `payWithAuthorization` settled end-to-end against the REAL X Layer USD0
/// on a mainnet fork - the test that would have caught the selector bug.
///
/// Pago's `IEIP3009` used to declare `uint64 validAfter, uint64 validBefore`,
/// giving selector 0xd8fde8d5, while the live token implements the `uint256`
/// form, 0xcf092995. The gasless path therefore reverted at the token call
/// against mainnet while every mock-based test passed: the testnet leg routed
/// Pago through pUSD, a mock built with the same uint64 shape, and Phase0Fork
/// called the genuine token directly instead of routing Pago through it.
/// Nothing in the suite ever joined the two.
///
/// This file joins them. Any future change that diverges Pago's interface
/// from a live token's EIP-3009 surface fails here, against the genuine
/// contract, not against a mock that agrees with the mistake.
///
/// The rule table deliberately sums to 23 rather than `SPLIT_STEPS` (20): the
/// solvency check in `_ruleApplies` rejects any table that does not total
/// exactly 100%, so whatever the genuine circuit answers, the DEFAULT table
/// pays and the payout is exact and deterministic.
///
/// Runs against a local fork of chain 196. No transaction is broadcast:
/// every signature comes from `vm.sign` and every balance from `deal`.
contract PagoGaslessForkTest is Test {
    // The genuine X Layer mainnet USD0: an ERC-1967 proxy over a 6-decimal
    // EIP-3009 implementation.
    address constant USDT0 = 0x779Ded0c9e1022225f8E0630b35a9b54bE713736;

    // Recorded references, probed 2026-11-18 (docs/RESEARCH.md section 18).
    // Deliberately literals, exactly as ForkPin pins them: the point is that
    // they were recorded offchain, never read live from the fork.
    address constant PROCESSOR = 0x9de448A1CE9537d24199B3b5355239d73aA6F591;
    address constant BEACON = 0xf70d1ed4f62CF3780157B0b421b7E2F45bD0991C;
    address constant IMPL = 0x977f217887E085D298Cb3819cDAD5A0ee35F29B2;
    bytes32 constant RECORDED_SHELL = 0x57aa306fd0be97087da3534e03398f5ff4efd533b5be4e45a405ce86fa6717d5;
    bytes32 constant RECORDED_IMPL = 0x7a15c353205e5245f40f5f5524542a982a4bb3b9a28476e4f10845163f941b30;

    /// 1.00 USD0 - the demo amount, in the token's 6 decimals.
    uint256 constant AMOUNT = 1_000_000;
    /// No deadline: far enough ahead that the token's `auth expired` check
    /// can never be the reason a case passes or fails by accident.
    uint64 constant NO_DEADLINE = type(uint64).max;

    string constant LINK_ID = "gasless-fork-1";

    Pago internal pago;
    address internal payee;
    address internal payer;
    uint256 internal payerKey;
    address internal feeAccount;

    function setUp() public {
        vm.createSelectFork(vm.envString("XLAYER_RPC"));

        // A fresh Pago compiled from the FIXED source, deployed against the
        // genuine processor, beacon and implementation, so the two-leg pin -
        // and with it the rule path - is the real one.
        Pago.TokenConfig[] memory configs = new Pago.TokenConfig[](1);
        configs[0] = Pago.TokenConfig({token: USDT0, decimals_: 6, unpinnedCap: 10_000_000_000});
        feeAccount = makeAddr("fee account");
        pago = new Pago(configs, feeAccount, PROCESSOR, 1, RECORDED_SHELL, BEACON, IMPL, RECORDED_IMPL);
        assertTrue(pago.evaluatorPinned(), "genuine references must pin on the genuine chain");

        payee = makeAddr("payee");
        (payer, payerKey) = makeAddrAndKey("payer");
        deal(USDT0, payer, 100e6); // cheatcode money, never real

        // The payee creates the invoice, exactly as in the demo. The default
        // table pays the payee 100%; the rule table sums to 23 so the
        // solvency check always rejects it and the default table pays.
        vm.prank(payee);
        pago.createLink(
            LINK_ID,
            AMOUNT,
            USDT0,
            "mainnet fork: gasless payer path",
            0,
            _split(payee, address(0), address(0), 20, 0, 0),
            _split(payee, makeAddr("rule seat 1"), makeAddr("rule seat 2"), 10, 8, 5)
        );
    }

    // ── the six cases ───────────────────────────────────────────────────────

    /// The positive control. The payer holds tokens but ZERO OKB, signs
    /// off-chain, and the payee settles against the genuine USD0. With the
    /// old uint64 interface this reverted at the token call; the fixed
    /// uint256 form must settle, escrow, and then pay out on claim.
    function test_gaslessPaySettlesAgainstRealUSD0() public {
        bytes32 nonce = _boundNonce();
        bytes32 terms = pago.termsHash(LINK_ID); // read BEFORE vm.prank
        bytes memory sig = _signAuth(address(pago), AMOUNT, 0, NO_DEADLINE, nonce);

        uint256 payerBefore = IERC20View(USDT0).balanceOf(payer);

        vm.prank(payee); // the payee submits; the payer sends nothing
        pago.payWithAuthorization(LINK_ID, payer, AMOUNT, 0, NO_DEADLINE, nonce, sig, terms);

        assertEq(
            IERC20View(USDT0).balanceOf(payer), payerBefore - AMOUNT, "payer must be debited exactly the amount"
        );
        assertEq(IERC20View(USDT0).balanceOf(address(pago)), AMOUNT, "Pago must escrow the payment");
        assertEq(payer.balance, 0, "the payer must never have needed gas");

        // Claim: the rule table sums to 23, so the default table pays.
        bytes32 key = pago.linkKeyOf(LINK_ID);
        vm.expectEmit(true, true, true, true);
        emit Pago.LinkClaimed(key, 995_000, 5_000, false);
        vm.prank(payee);
        pago.claim(LINK_ID);

        assertEq(IERC20View(USDT0).balanceOf(payee), 995_000, "payee receives the 99.5% payout");
        assertEq(IERC20View(USDT0).balanceOf(feeAccount), 5_000, "fee account receives the 0.5% fee");
        assertEq(IERC20View(USDT0).balanceOf(address(pago)), 0, "nothing may remain in escrow");
        console.log("gasless settle against genuine USD0: OK");
    }

    /// The same authorization must never settle twice. The link is Paid after
    /// the first submission, so the replay dies on Pago's own status check
    /// before the token ever sees the nonce again.
    function test_replayIsRejected() public {
        bytes32 nonce = _boundNonce();
        bytes32 terms = pago.termsHash(LINK_ID);
        bytes memory sig = _signAuth(address(pago), AMOUNT, 0, NO_DEADLINE, nonce);

        vm.prank(payee);
        pago.payWithAuthorization(LINK_ID, payer, AMOUNT, 0, NO_DEADLINE, nonce, sig, terms);

        vm.prank(payee);
        vm.expectRevert("link is not open");
        pago.payWithAuthorization(LINK_ID, payer, AMOUNT, 0, NO_DEADLINE, nonce, sig, terms);
    }

    /// An authorization past its deadline is refused by the TOKEN itself,
    /// with the genuine Tether reason bubbling up through Pago.
    function test_expiredAuthorizationReverts() public {
        bytes32 nonce = _boundNonce();
        bytes32 terms = pago.termsHash(LINK_ID);
        uint64 expired = 1; // validBefore already in the past
        bytes memory sig = _signAuth(address(pago), AMOUNT, 0, expired, nonce);

        vm.prank(payee);
        vm.expectRevert("TetherToken: auth expired");
        pago.payWithAuthorization(LINK_ID, payer, AMOUNT, 0, expired, nonce, sig, terms);
    }

    /// A well-formed signature from a key that is not the payer's. Everything
    /// Pago checks passes; only the token's ecrecover refuses it.
    function test_wrongSignerReverts() public {
        (, uint256 attackerKey) = makeAddrAndKey("attacker");
        bytes32 nonce = _boundNonce();
        bytes32 terms = pago.termsHash(LINK_ID);
        bytes32 digest = _digestOf(payer, address(pago), AMOUNT, 0, NO_DEADLINE, nonce);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(attackerKey, digest);
        bytes memory sig = abi.encodePacked(r, s, v);

        vm.prank(payee);
        vm.expectRevert("TetherToken: invalid signature");
        pago.payWithAuthorization(LINK_ID, payer, AMOUNT, 0, NO_DEADLINE, nonce, sig, terms);
    }

    /// A nonce that is not bound to (this link, this payer) dies on Pago's
    /// binding check, before the token is called at all.
    function test_wrongNonceReverts() public {
        bytes32 nonce = bytes32(uint256(_boundNonce()) + 1);
        bytes32 terms = pago.termsHash(LINK_ID);
        bytes memory sig = _signAuth(address(pago), AMOUNT, 0, NO_DEADLINE, nonce);

        vm.prank(payee);
        vm.expectRevert("authorization must be bound to this link");
        pago.payWithAuthorization(LINK_ID, payer, AMOUNT, 0, NO_DEADLINE, nonce, sig, terms);
    }

    /// Paying less than the invoiced amount dies on Pago's amount check.
    function test_underpaymentReverts() public {
        uint256 short = AMOUNT - 1;
        bytes32 nonce = _boundNonce();
        bytes32 terms = pago.termsHash(LINK_ID);
        bytes memory sig = _signAuth(address(pago), short, 0, NO_DEADLINE, nonce);

        vm.prank(payee);
        vm.expectRevert("payment amount is too small");
        pago.payWithAuthorization(LINK_ID, payer, short, 0, NO_DEADLINE, nonce, sig, terms);
    }

    // ── helpers ─────────────────────────────────────────────────────────────

    /// The EIP-712 digest the genuine USD0 verifies: the standard
    /// TransferWithAuthorization typehash with uint256 validAfter/validBefore,
    /// structurally identical to Phase0Fork's proven construction.
    function _digestOf(address from, address to, uint256 value, uint256 after_, uint256 before_, bytes32 nonce)
        internal
        view
        returns (bytes32)
    {
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256(
                    "TransferWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)"
                ),
                from,
                to,
                value,
                after_,
                before_,
                nonce
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", IDomain(USDT0).DOMAIN_SEPARATOR(), structHash));
    }

    /// A 65-byte `r || s || v` authorization from the payer's key - the
    /// packed-bytes form Pago forwards to the token.
    function _signAuth(address to, uint256 value, uint256 after_, uint256 before_, bytes32 nonce)
        internal
        view
        returns (bytes memory)
    {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(payerKey, _digestOf(payer, to, value, after_, before_, nonce));
        return abi.encodePacked(r, s, v);
    }

    /// The only nonce Pago will accept for this payer on this link - read
    /// from the contract, never invented.
    function _boundNonce() internal view returns (bytes32) {
        return bytes32(pago.authorizationNonce(pago.linkKeyOf(LINK_ID), payer));
    }

    /// Three seats in 5% steps: a zero share requires a zero recipient.
    function _split(address r0, address r1, address r2, uint8 s0, uint8 s1, uint8 s2)
        internal
        pure
        returns (Pago.Split memory s)
    {
        s.recipients = [r0, r1, r2];
        s.shares = [s0, s1, s2];
    }
}
