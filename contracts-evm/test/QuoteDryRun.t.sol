// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {IRuleProcessor} from "../src/IRuleProcessor.sol";
import {Pago} from "../src/Pago.sol";
import {Split3} from "../src/circuits/Split3.sol";
// The swap buyer lives in script/, not src/ (src/ is frozen), and the test
// imports it rather than re-declaring it: the artifact under test here is the
// exact artifact the tape-out will deploy.
import {BemBuyer} from "../script/BemBuyer.sol";

interface IERC20Like {
    function approve(address spender, uint256 amount) external;
    function balanceOf(address owner) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external;
}

interface IWOKBLike is IERC20Like {
    function deposit() external payable;
    function withdraw(uint256 amount) external;
}

interface ITapeFactoryQ {
    function createCPU(string calldata, string calldata, string calldata, uint256, uint256)
        external
        payable
        returns (address, address);
    function deployFee() external view returns (uint256);
    function protocolFee() external view returns (uint256);
}

interface ITransistorsQ {
    function mint(uint256 id, uint256 amount) external payable;
    function mintPrice() external view returns (uint256);
    function protocolFee() external view returns (uint256);
}

interface ICircuitsQ {
    function tapeout(bytes calldata netlist, uint32 nIn, uint32 nOut) external payable returns (uint256);
    function TAPEOUT_FEE() external view returns (uint256);
}

interface IPoolQ {
    function swap(
        address recipient,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        bytes calldata data
    ) external returns (int256 amount0Delta, int256 amount1Delta);
    function slot0() external view returns (uint160 sqrtPriceX96, int24, uint16, uint16, uint16, uint8, bool);
}

/// Quote-only dry run for the Tier 2 tape-out, against a FORK of X Layer
/// mainnet (chain 196).
///
/// What makes it a quote and not a run:
///   * every state change lives in the test EVM - nothing is broadcast, no key
///     is ever used, no approval survives the run;
///   * the actor is a wallet PROVEN empty first (0 wei, nonce 0, 0 BEM), then
///     funded with a simulated balance - so the numbers describe the path from
///     a fresh empty wallet exactly the way the real tape-out would take it;
///   * every real step prints one machine-readable line:
///       QUOTE|<step>|gas=<gasUsed>|bem=<delta, 8-dec units>|okb=<delta wei>|wokb=<delta wei>
///     and `contracts-evm/script/quote-dry-run.ps1` prices those deltas in USD
///     with a UTC timestamp, marking anything it cannot price UNPRICEABLE;
///   * every amount here was measured, not assumed: the BEM buy is a real
///     exact-output swap against the live BEM/WOKB pool on the fork, and the
///     fees (createCPU, mint, tape-out) show up as balance deltas.
///
/// Step order mirrors the execution plan: buy BEM FIRST (shortest exposure
/// window), then create the processor, mint one transistor per gate (104 for
/// Split3), tape out Split3, deploy Pago against the recorded references, and
/// sweep leftovers back to the owner wallet.
contract QuoteDryRunTest is Test {
    address constant FACTORY = 0x1f09DAeFA827f02CBb40967cc91b259763760761;
    address constant BEM = 0x60e62Efa9405d6873C5deaBD4E6CC91c25363952;
    // The only BEM/WOKB pool this factory's Uniswap V3 deployment has
    // (getPool returned zero for the 0.05% and 0.3% tiers): 1% fee tier.
    address constant POOL = 0x2CcF8aa17F5DF9Fb5D51C9de12135a913fF29f7A;
    address constant WOKB = 0xe538905cf8410324e03A5A23C1c177a474D59b2b;

    // Rule 6's recorded references (docs/RESEARCH.md section 18), literals on
    // purpose: the deploy step must show the NEW processor's own recorded
    // values next to the recorded ones, never read them live from the fork.
    address constant RECORDED_BEACON = 0xf70d1ed4f62CF3780157B0b421b7E2F45bD0991C;
    address constant RECORDED_IMPL = 0x977f217887E085D298Cb3819cDAD5A0ee35F29B2;
    bytes32 constant RECORDED_IMPL_HASH = 0x7a15c353205e5245f40f5f5524542a982a4bb3b9a28476e4f10845163f941b30;

    // 0.11 BEM needed (0.1 createCPU + 0.01 flat mint protocol fee - gate
    // price is 0, chosen like CPU #340 - probe-proven in MintPriceProbe.t.sol)
    // + 20% buffer.
    uint256 constant BUY_BEM_UNITS = 13_200_000;
    // Simulated funding for the run itself; the REAL amount the wallet must
    // hold is computed by the script from these measured deltas.
    uint256 constant FUND_BUDGET = 0.5 ether;
    // Native coin that stays unwrapped so the tape-out fee can be paid.
    uint256 constant RESERVE_NATIVE = 0.01 ether;

    address fresh;
    address sweepTo;
    address buyer;

    struct Refs {
        bytes32 shell;
        address beacon;
        address impl;
        bytes32 implHash;
    }

    function setUp() public {
        vm.createSelectFork(vm.envString("XLAYER_RPC"));
        fresh = makeAddr("pago-quote-dry-run-fresh-wallet");
        sweepTo = makeAddr("pago-quote-dry-run-owner");
    }

    // ---------- machine-readable quote output ----------

    function _info(string memory k, string memory v) internal {
        console.log(string.concat("QUOTE|info|", k, "=", v));
    }

    function _fail(string memory step, bytes memory reason) internal {
        console.log(string.concat("QUOTE|FAIL|", step, "="));
        console.logBytes(reason);
    }

    function _bal() internal view returns (uint256[3] memory b) {
        b[0] = IERC20Like(BEM).balanceOf(fresh);
        b[1] = fresh.balance;
        b[2] = IERC20Like(WOKB).balanceOf(fresh);
    }

    /// Emit one QUOTE line: gas of the step plus the fresh wallet's balance
    /// deltas in BEM (8 decimals), native OKB (wei) and WOKB (wei).
    function _q(string memory id, uint256 gasUsed, uint256[3] memory beforeBal) internal {
        uint256[3] memory afterBal = _bal();
        console.log(
            string.concat(
                "QUOTE|",
                id,
                "|gas=",
                vm.toString(gasUsed),
                "|bem=",
                vm.toString(int256(afterBal[0]) - int256(beforeBal[0])),
                "|okb=",
                vm.toString(int256(afterBal[1]) - int256(beforeBal[1])),
                "|wokb=",
                vm.toString(int256(afterBal[2]) - int256(beforeBal[2]))
            )
        );
    }

    // ---------- shared probes (same shapes Phase0Fork.t.sol proved) ----------

    /// staticcall a no-arg uint getter: (answered, value).
    function _answerUint(address target, string memory sig) internal view returns (bool, uint256) {
        (bool ok, bytes memory ret) = target.staticcall(abi.encodeWithSignature(sig));
        if (!ok || ret.length != 32) return (false, 0);
        return (true, abi.decode(ret, (uint256)));
    }

    /// Input-side WOKB cap for the BEM buy, quoted ONCE from the pool's spot
    /// price and stored: the approval and the swap then use the same number.
    /// Two separate reads could straddle a price move and disagree, which
    /// would either over-approve or trip the cap mid-swap.
    uint256 internal maxInQuoted;

    /// spot input = output x price, where price = (sqrtPriceX96/2^96)^2 in
    /// raw token units (WOKB wei per BEM unit); +15% covers the 1% LP fee,
    /// price impact and any adverse move between quoting and execution.
    function _quoteMaxIn() internal {
        (uint160 sqrtNow,,,,,,) = IPoolQ(POOL).slot0();
        uint256 priceX96sq = (uint256(sqrtNow) * uint256(sqrtNow)) / (uint256(1) << 192);
        maxInQuoted = (uint256(BUY_BEM_UNITS) * priceX96sq * 115) / 100;
        _info("buyBem_maxIn_wokb", vm.toString(maxInQuoted));
    }

    /// createCPU's two addresses assigned BY CAPABILITY, never by position:
    /// shape 2 = circuits (TAPEOUT_FEE answers), shape 1 = transistors
    /// (mintPrice answers).
    function _discoverRoles(address first, address second) internal returns (bool, address, address) {
        (bool tapeA,) = _answerUint(first, "TAPEOUT_FEE()");
        (bool mintA,) = _answerUint(first, "mintPrice()");
        (bool tapeB,) = _answerUint(second, "TAPEOUT_FEE()");
        (bool mintB,) = _answerUint(second, "mintPrice()");
        uint8 shapeA = uint8((tapeA ? 2 : 0) | (mintA ? 1 : 0));
        uint8 shapeB = uint8((tapeB ? 2 : 0) | (mintB ? 1 : 0));
        console.log("first shape (2=circuits, 1=transistors):", uint256(shapeA));
        console.log("second shape (2=circuits, 1=transistors):", uint256(shapeB));
        if (shapeA == 2 && shapeB == 1) return (true, first, second);
        if (shapeA == 1 && shapeB == 2) return (true, second, first);
        _fail("createCpu", bytes("the two returned addresses match neither known circuits/transistors shape"));
        return (false, address(0), address(0));
    }

    /// Disassemble a beacon-proxy shell: the first PUSH32 payload's low 20
    /// bytes are the beacon address hardcoded in the shell's own bytecode
    /// (README "how the beacon address is bound").
    function _tryEmbeddedBeacon(address target) internal view returns (bool, address) {
        bytes memory code = target.code;
        for (uint256 i; i + 33 <= code.length; ++i) {
            if (code[i] == 0x7f) {
                uint256 payload;
                for (uint256 j; j < 32; ++j) {
                    payload = (payload << 8) | uint8(code[i + 1 + j]);
                }
                return (true, address(uint160(payload)));
            }
        }
        return (false, address(0));
    }

    /// The four references a Tier 2 operator records offchain for ONE
    /// processor (docs/RESEARCH.md section 18): shell codehash, the beacon
    /// embedded in that shell, what the beacon reports now, its codehash.
    function _recordRefs(address shellAddr) internal view returns (bool, Refs memory r) {
        r.shell = shellAddr.codehash;
        (bool found, address bcn) = _tryEmbeddedBeacon(shellAddr);
        if (!found) return (false, r);
        r.beacon = bcn;
        (bool ok, bytes memory ret) = bcn.staticcall(abi.encodeWithSignature("implementation()"));
        if (!ok || ret.length != 32) return (false, r);
        r.impl = address(uint160(uint256(bytes32(ret))));
        if (r.impl.code.length == 0) return (false, r);
        r.implHash = r.impl.codehash;
        return (true, r);
    }

    // ---------- the steps ----------

    /// Tx 1: wrap the simulated OKB funding into WOKB (the swap needs WOKB).
    function _stepWrap() internal returns (bool) {
        uint256 amt = FUND_BUDGET - RESERVE_NATIVE;
        uint256[3] memory b = _bal();
        uint256 g0 = gasleft();
        vm.startPrank(fresh);
        IWOKBLike(WOKB).deposit{value: amt}();
        vm.stopPrank();
        _q("wrap", g0 - gasleft(), b);
        return true;
    }

    /// Tx 2/5/7: an ERC-20 approve on the fresh wallet (token picked per step).
    ///
    /// The amount is EXACT and passed in, never `type(uint256).max`: an
    /// unlimited allowance sitting on a wallet that holds real funds is the
    /// drain vector this whole flow has to avoid. Each caller approves only
    /// what its own step will spend.
    function _stepApprove(string memory id, address token, address spender, uint256 amount) internal returns (bool) {
        uint256[3] memory b = _bal();
        uint256 g0 = gasleft();
        vm.startPrank(fresh);
        IERC20Like(token).approve(spender, amount);
        vm.stopPrank();
        _q(id, g0 - gasleft(), b);
        _info(string.concat(id, "_approved"), vm.toString(amount));
        return true;
    }

    /// Tx 8: revoke an allowance back to zero once its step is done, so no
    /// spender keeps a live claim on the wallet after the money has moved.
    function _stepRevoke(string memory id, address token, address spender) internal returns (bool) {
        return _stepApprove(id, token, spender, 0);
    }

    /// Tx 2: deploy the swap buyer helper - a real transaction in the real
    /// flow too: an EOA cannot call the pool directly (see BemBuyer).
    function _stepDeployBuyer() internal returns (bool) {
        uint256[3] memory b = _bal();
        uint256 g0 = gasleft();
        vm.startPrank(fresh);
        buyer = address(new BemBuyer(POOL, WOKB, fresh));
        vm.stopPrank();
        _q("deployBuyer", g0 - gasleft(), b);
        _info("swapBuyer", vm.toString(buyer));
        return true;
    }

    /// Tx 3: buy the buffered BEM amount with WOKB, EXACT OUTPUT, through the
    /// buyer helper against the live 1% pool - so the measured WOKB delta is
    /// the real fill (pool price impact + 1% LP fee included), not an estimate.
    ///
    /// Three guards, each catching a different way this could go wrong:
    ///   * Uniswap V3 rejects `type(uint160).max` with revert string "SPL",
    ///     so the limit is read from slot0 and given ~4% of price headroom;
    ///   * the callback needs a contract on this side (BemBuyer);
    ///   * `maxIn` is the INPUT-side cap quoted from the spot price before the
    ///     call (spot + 15% for fee, impact and price movement). The output
    ///     limit bounds how bad the price may get; maxIn bounds how much WOKB
    ///     may leave the wallet at all. Exceeding it reverts inside the
    ///     callback and the whole swap fails.
    ///
    /// A partial fill turns into a loud failure instead of a quietly smaller
    /// purchase, and the buyer is asserted empty afterwards.
    function _stepBuyBem() internal returns (bool) {
        (uint160 sqrtNow,,,,,,) = IPoolQ(POOL).slot0();
        uint160 limit = sqrtNow + (sqrtNow / 50);
        // maxInQuoted was priced from the same slot0 reading and is exactly
        // what the approval granted - no second quote, no disagreement.
        uint256 maxIn = maxInQuoted;
        uint256[3] memory b = _bal();
        uint256 g0 = gasleft();
        vm.startPrank(fresh);
        try BemBuyer(buyer).buy(fresh, -int256(BUY_BEM_UNITS), limit, maxIn)
        returns (int256 amount0Delta, int256 amount1Delta) {
            vm.stopPrank();
            _q("buyBem", g0 - gasleft(), b);
            _info("buyBem_amount0_delta_bem", vm.toString(amount0Delta));
            _info("buyBem_amount1_delta_wokb", vm.toString(amount1Delta));
            // The pool reports its own balance change: it PAID the BEM out,
            // so the delta is negative and its magnitude is the fill.
            if (-amount0Delta < int256(BUY_BEM_UNITS)) {
                _fail("buyBem", bytes("PARTIAL FILL: the price limit was reached before the exact BEM output"));
                return false;
            }
            // The buyer must hold nothing: bought BEM went to the wallet,
            // owed WOKB went to the pool. Anything left would mean value
            // parked where it does not belong.
            if (!BemBuyer(buyer).isEmpty(BEM) || !BemBuyer(buyer).isEmpty(WOKB)) {
                _fail("buyBem", bytes("SWAP BUYER NOT EMPTY after the swap - funds are sitting in the helper"));
                return false;
            }
            _info("swapBuyerEmptyAfterSwap", "true");
            // The allowance has served its purpose: revoke it so the helper
            // keeps no live claim on the wallet.
            vm.startPrank(fresh);
            IERC20Like(WOKB).approve(buyer, 0);
            vm.stopPrank();
            _info("swapBuyerAllowanceRevoked", "true");
            return true;
        } catch (bytes memory reason) {
            vm.stopPrank();
            _fail("buyBem", reason);
            return false;
        }
    }

    /// Tx 4: unwrap whatever WOKB the swap did not consume, so only the exact
    /// fill sits in WOKB and everything else is back in OKB for the sweep.
    function _stepUnwrap() internal returns (bool) {
        uint256 w = IERC20Like(WOKB).balanceOf(fresh);
        if (w == 0) {
            _info("unwrap", "no WOKB left to unwrap");
            return true;
        }
        uint256[3] memory b = _bal();
        uint256 g0 = gasleft();
        vm.startPrank(fresh);
        IWOKBLike(WOKB).withdraw(w);
        vm.stopPrank();
        _q("unwrap", g0 - gasleft(), b);
        return true;
    }

    /// Tx 5 + 6: approve the BEM fee, then createCPU with the same arguments
    /// the proven Tier 2 test uses (mintPrice 1e6 = 0.01 BEM per transistor).
    /// The measured BEM delta says what the factory actually pulls.
    function _stepCreateCpu() internal returns (bool, address, address) {
        // Exact approval: the factory pulls `deployFee()` in BEM, so that
        // value is what gets approved - read onchain, never assumed.
        (bool okFee, uint256 deployFee) = _answerUint(FACTORY, "deployFee()");
        if (!okFee) {
            _fail("createCpu", bytes("deployFee() did not answer - refusing to guess an approval amount"));
            return (false, address(0), address(0));
        }
        _info("factoryDeployFee_wei", vm.toString(deployFee));
        if (!_stepApprove("approveFactory", BEM, FACTORY, deployFee)) return (false, address(0), address(0));
        uint256[3] memory b = _bal();
        uint256 g0 = gasleft();
        vm.startPrank(fresh);
        try ITapeFactoryQ(FACTORY).createCPU(
            // Gate price 0: the caller sets it (section 13), official CPU #340
            // runs at 0, and MintPriceProbe.t.sol proved the factory has no
            // floor on X Layer. Mints then cost the flat 0.01 BEM protocol
            // fee per call instead of 0.01 BEM x 104 gates.
            "Pago", "PAGO", "Pago rule library: shareable payment-term circuits.", 100_000, 0
        ) returns (address first, address second) {
            vm.stopPrank();
            _q("createCpu", g0 - gasleft(), b);
            return _discoverRoles(first, second);
        } catch (bytes memory reason) {
            vm.stopPrank();
            _fail("createCpu", reason);
            return (false, address(0), address(0));
        }
    }

    /// Tx 7 + 8: approve BEM to OUR transistors surface, then mint one
    /// transistor per gate (Split3 = 104). The proven route on this factory is
    /// the no-value mint (BEM allowance only); a processor that charges a
    /// native protocol fee would need the value route, which is the fallback
    /// below - whichever succeeds is the one whose gas gets quoted.
    function _stepMint(address transistors) internal returns (bool) {
        // The fees are read BEFORE the approval, so the approved amount is
        // the amount this mint will actually pull: flat protocol fee plus
        // gate price x gates (gate price is 0 here, so it is the flat fee).
        (bool okMp, uint256 mintPrice) = _answerUint(transistors, "mintPrice()");
        (bool okPf, uint256 protocolFee) = _answerUint(transistors, "protocolFee()");
        _info("mintPrice_bemUnits", okMp ? vm.toString(mintPrice) : "did not answer");
        _info("transistorsProtocolFee_wei", okPf ? vm.toString(protocolFee) : "did not answer");
        if (!okMp || !okPf) {
            _fail("mint", bytes("mintPrice()/protocolFee() did not answer - refusing to guess an approval amount"));
            return false;
        }
        uint256 mintAllowance = protocolFee + mintPrice * Split3.NAND_COUNT;
        _info("mintApprovedAmount", vm.toString(mintAllowance));
        if (!_stepApprove("approveTransistors", BEM, transistors, mintAllowance)) return false;

        {
            uint256[3] memory b = _bal();
            uint256 g0 = gasleft();
            vm.startPrank(fresh);
            try ITransistorsQ(transistors).mint(0, Split3.NAND_COUNT) {
                vm.stopPrank();
                _q("mint", g0 - gasleft(), b);
                _info("mintRoute", "noValue (BEM allowance only)");
                return true;
            } catch (bytes memory reason) {
                vm.stopPrank();
                _info("mintNoValueReverted", vm.toString(reason));
            }
        }
        if (!(okMp && okPf)) {
            _fail("mint", bytes("no-value mint reverted and the surface reports no fee pair for the value route"));
            return false;
        }
        {
            uint256[3] memory b = _bal();
            uint256 g0 = gasleft();
            vm.startPrank(fresh);
            try ITransistorsQ(transistors).mint{value: protocolFee + mintPrice}(0, Split3.NAND_COUNT) {
                vm.stopPrank();
                _q("mintValueRoute", g0 - gasleft(), b);
                _info("mintRoute", "value route (native fee lands in the okb delta)");
                return true;
            } catch (bytes memory reason) {
                vm.stopPrank();
                _fail("mint", reason);
                return false;
            }
        }
    }

    /// Tx 9: tape out the real Split3 netlist with the factory's TAPEOUT_FEE
    /// attached, then check the processor serves the exact bytes back (evidence
    /// read, not part of the quoted transaction).
    function _stepTapeout(address circuits) internal returns (bool, uint256) {
        (bool okFee, uint256 fee) = _answerUint(circuits, "TAPEOUT_FEE()");
        if (!okFee) {
            _fail("tapeout", bytes("TAPEOUT_FEE() did not answer on this processor"));
            return (false, 0);
        }
        _info("tapeoutFee_wei", vm.toString(fee));
        bytes memory nl = Split3.netlist();
        _info("netlistBytes", vm.toString(nl.length));

        uint256[3] memory b = _bal();
        uint256 g0 = gasleft();
        vm.startPrank(fresh);
        try ICircuitsQ(circuits).tapeout{value: fee}(nl, Split3.N_IN, Split3.N_OUT) returns (uint256 id) {
            vm.stopPrank();
            _q("tapeout", g0 - gasleft(), b);
            _info("circuitId", vm.toString(id));
            bool served = keccak256(IRuleProcessor(circuits).netlist(id)) == keccak256(nl);
            _info("netlistServedBack", served ? "true" : "FALSE");
            if (!served) {
                console.log("QUOTE|WARN|processor did not serve the taped-out netlist bytes back");
            }
            return (true, id);
        } catch (bytes memory reason) {
            vm.stopPrank();
            _fail("tapeout", reason);
            return (false, 0);
        }
    }

    /// Tx 10: deploy Pago on mainnet shape against THIS processor's own
    /// recorded references, then check the live two-leg pin passes. The token
    /// config is BEM-shaped (8 decimals) because gas does not depend on which
    /// payment token is allowed; the final cap/token are execution-time env
    /// knobs of Deploy.s.sol and are disclosed as such.
    function _stepDeploy(address circuits, uint256 circuitId) internal returns (bool) {
        (bool recorded, Refs memory r) = _recordRefs(circuits);
        if (!recorded) {
            _fail("deployPago", bytes("could not record the new processor's four references"));
            return false;
        }
        _info("recordedShellCodehash", vm.toString(r.shell));
        _info("recordedBeacon", vm.toString(r.beacon));
        _info("beaconReportsImpl", vm.toString(r.impl));
        _info("recordedImplCodehash", vm.toString(r.implHash));
        _info("beaconMatchesRecorded18", r.beacon == RECORDED_BEACON ? "true" : "false");
        _info("implMatchesRecorded18", r.impl == RECORDED_IMPL ? "true" : "false");
        _info("implHashMatchesRecorded18", r.implHash == RECORDED_IMPL_HASH ? "true" : "false");
        _info(
            "deployConfigNote",
            "BEM-shaped config (8 decimals); final token/cap/feeAccount are Deploy.s.sol env knobs (gas-insensitive)"
        );

        Pago.TokenConfig[] memory configs = new Pago.TokenConfig[](1);
        configs[0] = Pago.TokenConfig({token: BEM, decimals_: 8, unpinnedCap: 10_000 * 1e8});
        uint256[3] memory b = _bal();
        uint256 g0 = gasleft();
        vm.startPrank(fresh);
        Pago p = new Pago(configs, fresh, circuits, circuitId, r.shell, r.beacon, r.impl, r.implHash);
        vm.stopPrank();
        _q("deployPago", g0 - gasleft(), b);
        _info("pagoAddress", vm.toString(address(p)));
        bool pinned = p.evaluatorPinned();
        _info("evaluatorPinned", pinned ? "true" : "FALSE");
        if (!pinned) {
            console.log("QUOTE|WARN|evaluatorPinned()=false at this block - a deploy would pin nothing");
        }
        return true;
    }

    /// Tx 11 + 12: move whatever is left (BEM buffer residue, native residue
    /// after the tape-out fee) out of the fresh wallet to the owner wallet.
    function _stepSweep() internal returns (bool) {
        uint256 bemLeft = IERC20Like(BEM).balanceOf(fresh);
        _info("leftoverBemToSweep_bemUnits", vm.toString(bemLeft));
        if (bemLeft > 0) {
            uint256[3] memory b = _bal();
            uint256 g0 = gasleft();
            vm.startPrank(fresh);
            IERC20Like(BEM).transfer(sweepTo, bemLeft);
            vm.stopPrank();
            _q("sweepBem", g0 - gasleft(), b);
        } else {
            _info("sweepBem", "nothing left to sweep in BEM");
        }

        uint256 okbLeft = fresh.balance;
        _info("leftoverOkbToSweep_wei", vm.toString(okbLeft));
        if (okbLeft > 0) {
            uint256[3] memory b = _bal();
            uint256 g0 = gasleft();
            vm.startPrank(fresh);
            (bool sent,) = sweepTo.call{value: okbLeft}("");
            vm.stopPrank();
            if (!sent) {
                _fail("sweepOkb", bytes("native transfer to the owner wallet failed"));
                return false;
            }
            _q("sweepOkb", g0 - gasleft(), b);
        } else {
            _info("sweepOkb", "nothing left to sweep in native OKB");
        }

        _info("freshBemAfterSweep_units", vm.toString(IERC20Like(BEM).balanceOf(fresh)));
        _info("freshOkbAfterSweep_wei", vm.toString(fresh.balance));
        _info("sweepRecipient", vm.toString(sweepTo));
        return true;
    }

    // ---------- the dry run ----------

    function test_quoteDryRun() public {
        console.log(
            string.concat(
                "QUOTE|meta|forkBlock=", vm.toString(block.number), "|chainid=", vm.toString(block.chainid)
            )
        );

        // The whole point: the wallet STARTS empty. If any of these holds
        // something, the quote would silently inherit it and lie.
        assertEq(fresh.balance, 0, "fresh wallet must hold no native coin");
        assertEq(uint256(vm.getNonce(fresh)), 0, "fresh wallet must never have transacted");
        assertEq(IERC20Like(BEM).balanceOf(fresh), 0, "fresh wallet must hold no BEM");

        _info("freshWallet", vm.toString(fresh));
        _info("factory", vm.toString(FACTORY));
        _info("bem", vm.toString(BEM));
        _info("pool", vm.toString(POOL));
        _info("wokb", vm.toString(WOKB));
        _info("quoteMode", "READ-ONLY fork simulation from an empty wallet; nothing broadcast; no key used");
        _info("fundBudgetWei_simulated", vm.toString(FUND_BUDGET));
        _info("buyBemUnits_withBuffer", vm.toString(BUY_BEM_UNITS));
        _info("factoryDeployFee", vm.toString(ITapeFactoryQ(FACTORY).deployFee()));
        _info("factoryProtocolFee", vm.toString(ITapeFactoryQ(FACTORY).protocolFee()));
        _info("gatePrice", "0 (chosen like CPU #340; no floor on X Layer, probe-proven)");
        vm.deal(fresh, FUND_BUDGET);

        if (!_stepWrap()) return;
        if (!_stepDeployBuyer()) return;
        _quoteMaxIn();
        if (!_stepApprove("approveBuyer", WOKB, buyer, maxInQuoted)) return;
        if (!_stepBuyBem()) return;
        if (!_stepUnwrap()) return;

        (bool okCpu, address circuits, address transistors) = _stepCreateCpu();
        if (!okCpu) return;

        if (!_stepMint(transistors)) return;

        (bool okTape, uint256 circuitId) = _stepTapeout(circuits);
        if (!okTape) return;

        if (!_stepDeploy(circuits, circuitId)) return;

        if (!_stepSweep()) return;

        console.log("QUOTE|done|steps=ok");
    }
}
