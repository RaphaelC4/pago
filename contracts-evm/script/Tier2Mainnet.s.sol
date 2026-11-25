// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {Pago} from "../src/Pago.sol";
import {Split3} from "../src/circuits/Split3.sol";
import {IRuleProcessor} from "../src/IRuleProcessor.sol";
// The swap helper is imported from script/, not re-declared here, and the
// quote test imports the SAME file: the artifact exercised by the dry run is
// the artifact this script deploys.
import {BemBuyer} from "./BemBuyer.sol";

interface IERC20T {
    function approve(address spender, uint256 amount) external;
    function balanceOf(address owner) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function decimals() external view returns (uint8);
}

interface IWOKBT is IERC20T {
    function deposit() external payable;
    function withdraw(uint256 amount) external;
}

interface IPoolT {
    function slot0()
        external
        view
        returns (uint160 sqrtPriceX96, int24 tick, uint16 observationIndex, uint16 observationCardinality, uint16 observationCardinalityNext, uint8 feeProtocol, bool unlocked);
}

interface ITapeFactoryT {
    function createCPU(string calldata, string calldata, string calldata, uint256, uint256)
        external
        payable
        returns (address, address);
    function deployFee() external view returns (uint256);
}

interface ITransistorsT {
    function mint(uint256, uint256) external;
    function mintPrice() external view returns (uint256);
    function protocolFee() external view returns (uint256);
}

interface ICircuitsT {
    function TAPEOUT_FEE() external view returns (uint256);
    function tapeout(bytes calldata, uint256, uint256) external payable returns (uint256);
}

/// X Layer MAINNET (chain 196) Tier 2 tape-out + Pago deployment, in one
/// all-or-nothing broadcast: forge simulates the entire sequence against a
/// fork first and sends NOTHING if any step reverts.
///
/// The sequence, each step measured by `test/QuoteDryRun.t.sol` on a fork of
/// this same chain (13 txs, $1.65 at the 2026-11-20 02:28Z quote):
///
///   1  wrap exactly the swap's input cap (maxIn) into WOKB
///   2  deploy BemBuyer (the swap callback must land on a contract)
///   3  approve the buyer for EXACTLY maxIn - never type(uint256).max
///   4  exact-output buy of 0.132 BEM, input-capped, buyer asserted empty
///   5  revoke that allowance back to 0
///   6  unwrap the WOKB the swap did not consume
///   7  approve the factory for EXACTLY deployFee()
///   8  createCPU (gate price 0, probe-proven to have no floor)
///   9  approve the transistors for EXACTLY protocolFee + mintPrice x gates
///  10  mint the 104 gates (BEM allowance route, no native value)
///  11  tape out the real Split3 netlist with TAPEOUT_FEE attached
///  12  deploy Pago with the references recorded by our own probe
///
/// NO sweep: every wallet in this flow is the deployer itself, so the
/// leftovers (0.022 BEM and the OKB residue) simply stay where they are.
///
/// References are CONSTANTS recorded by probes that ran against a DIFFERENT
/// processor (`ShellProbe.t.sol`, `QuoteDryRun.t.sol`), never a live read of
/// the processor about to be created - a live read would make rule 6's check
/// tautological. Each constant is re-verified against the live chain before
/// it is used, and the script aborts if the template ever moves again.
///
/// Signing is never done here: `forge script --account pago-deployer` signs
/// through the Foundry keystore. No private key appears in this file, on the
/// command line, or in `.env`.
///
/// Usage (from contracts-evm/):
///
///   $env:XLAYER_RPC = "https://rpc.xlayer.tech"
///   forge script script/Tier2Mainnet.s.sol:Tier2Mainnet `
///     --rpc-url $env:XLAYER_RPC --account pago-deployer --broadcast --slow
contract Tier2Mainnet is Script {
    // ---- X Layer mainnet addresses (chain 196) ----
    address internal constant FACTORY = 0x1f09DAeFA827f02CBb40967cc91b259763760761;
    address internal constant BEM = 0x60e62Efa9405d6873C5deaBD4E6CC91c25363952;
    address internal constant POOL = 0x2CcF8aa17F5DF9Fb5D51C9de12135a913fF29f7A;
    address internal constant WOKB = 0xe538905cf8410324e03A5A23C1c177a474D59b2b;
    address internal constant USD_T0 = 0x779Ded0c9e1022225f8E0630b35a9b54bE713736;
    address internal constant USDG = 0x4ae46a509F6b1D9056937BA4500cb143933D2dc8;

    /// Who receives Pago's 0.5% fee at claim. Immutable after construction,
    /// so it is fixed here rather than passed around: the payee keystore.
    address internal constant FEE_ACCOUNT = 0x7FCe520D881454EA234d371E1256B75843609b62;

    // ---- references recorded by our own probes (docs/RESEARCH.md section 18,
    //      re-measured 2026-11-20 by ShellProbe.t.sol and QuoteDryRun.t.sol) ----

    /// keccak of the 295-byte shell a NEWLY created processor serves.
    /// Section 18's 0x57aa306f... describes the PRE-EXISTING processors
    /// (#340/#30/#333); the two are byte-identical executable code and differ
    /// only in the trailing CBOR IPFS metadata hash (offsets 252-283).
    /// Pinning the old value would leave evaluatorPinned() false forever.
    bytes32 internal constant RECORDED_NEW_SHELL =
        0x8c799a18cd8e0d5f5f3c0cec4fbc145e2daf79f70c2b131c09d0f380921db545;

    /// The beacon hardcoded in that shell (PUSH32 literal, section 18).
    address internal constant RECORDED_BEACON = 0xf70d1ed4f62CF3780157B0b421b7E2F45bD0991C;

    /// The circuit implementation that beacon reports (12,562 bytes).
    address internal constant RECORDED_IMPL = 0x977f217887E085D298Cb3819cDAD5A0ee35F29B2;

    /// keccak of that implementation's code.
    bytes32 internal constant RECORDED_IMPL_HASH = 0x7a15c353205e5245f40f5f5524542a982a4bb3b9a28476e4f10845163f941b30;

    // ---- amounts ----

    /// 0.132 BEM at 8 decimals: 0.11 spent (0.10 createCPU + 0.01 mint) plus
    /// a 20% buffer, exactly what the quote measured and swept.
    uint256 internal constant BUY_BEM_UNITS = 13_200_000;

    /// Unpinned cap per token, base units: 10,000 tokens at 6 decimals.
    /// Binds only while evaluatorPinned() is false, which the fork proved is
    /// TRUE from the moment of this deployment.
    uint256 internal constant UNPINNED_CAP = 10_000 * 1e6;

    /// Native kept in hand beyond the swap cap: tape-out fee (0.0013) plus a
    /// generous gas allowance for all 12 transactions at 0.02 gwei.
    uint256 internal constant NATIVE_HEADROOM = 0.0015e18;

    // ---- flow state (storage, so every helper stays stack-safe) ----
    address internal deployer;
    uint256 internal maxIn;
    address internal buyer;
    address internal circuits;
    address internal transistors;
    uint256 internal circuitId;

    function run() external {
        deployer = vm.envOr("PAGO_DEPLOYER", msg.sender);

        // PAGO_PROCESSOR_CODEHASH exists for the testnet stand-in only; every
        // reference this script hands to Pago is a recorded constant below,
        // verified live in _preflight and again at deploy time. A stale
        // override left in the environment must abort the run rather than sit
        // unnoticed beside values it can never legitimately influence.
        require(
            vm.envOr("PAGO_PROCESSOR_CODEHASH", bytes32(0)) == bytes32(0),
            "PAGO_PROCESSOR_CODEHASH is set - the testnet override must never reach a mainnet deploy"
        );

        // Read-only phase: nothing here can create a transaction.
        maxIn = _quoteMaxIn();
        _preflight();

        vm.startBroadcast();

        IWOKBT(WOKB).deposit{value: maxIn}();
        buyer = address(new BemBuyer(POOL, WOKB, deployer));
        IERC20T(WOKB).approve(buyer, maxIn);
        _buy();
        // The allowance has done its job: no spender keeps a live claim.
        IERC20T(WOKB).approve(buyer, 0);
        _unwrapAll();
        _createCpu();
        _mintGates();
        _tapeout();
        _deployPago();

        vm.stopBroadcast();
    }

    // ---------- read-only phase ----------

    /// spot input = output x price, where price = (sqrtPriceX96/2^96)^2 in
    /// raw token units (WOKB wei per BEM unit); +15% covers the 1% LP fee,
    /// price impact and any adverse move between quoting and execution.
    function _quoteMaxIn() internal view returns (uint256 m) {
        (uint160 sqrtNow,,,,,,) = IPoolT(POOL).slot0();
        uint256 priceX96sq = (uint256(sqrtNow) * uint256(sqrtNow)) / (uint256(1) << 192);
        m = (uint256(BUY_BEM_UNITS) * priceX96sq * 115) / 100;
    }

    /// Abort BEFORE any transaction exists if the chain, the funds, the tokens
    /// or the recorded references are not what this script was written for.
    function _preflight() internal view {
        require(block.chainid == 196, "WRONG CHAIN: this script is X Layer mainnet (196) only");
        console.log("TIER2|preflight|chainid", block.chainid);
        console.log("TIER2|preflight|deployer", deployer);
        console.log("TIER2|preflight|maxIn_wokb", maxIn);

        uint256 need = maxIn + NATIVE_HEADROOM;
        require(deployer.balance >= need, "deployer does not hold enough OKB for the swap cap + tape-out fee + gas");
        console.log("TIER2|preflight|okb_balance", deployer.balance);
        console.log("TIER2|preflight|okb_required", need);

        // Rule 7: our expected decimals vs what the chain says, for BOTH
        // allowlisted tokens. Pago stores the expected value and never asks
        // the token again, so a wrong value here would be permanent.
        require(FACTORY.code.length > 0, "TapeOut factory not found at the recorded address");
        require(IERC20T(BEM).decimals() == 8, "BEM decimals != 8");
        require(IERC20T(USD_T0).decimals() == 6, "USD_T0 decimals != 6");
        require(IERC20T(USDG).decimals() == 6, "USDG decimals != 6");
        console.log("TIER2|preflight|decimals_ok", "BEM=8 USD_T0=6 USDG=6");

        // Rule 6, leg 2, checked against the recorded values BEFORE they are
        // handed to the constructor: the beacon must still report the
        // recorded implementation, and that code must still hash to the
        // recorded hash. The reference is the constant, not this read.
        (address liveImpl, bytes32 liveHash) = _liveLeg2();
        require(liveImpl == RECORDED_IMPL, "beacon reports an implementation other than the recorded one");
        require(liveHash == RECORDED_IMPL_HASH, "implementation codehash differs from the recorded one");
        console.log("TIER2|preflight|leg2_ok", vm.toString(liveImpl));
    }

    /// Leg 2 as the chain answers it right now: (implementation, its codehash).
    function _liveLeg2() internal view returns (address impl, bytes32 h) {
        (bool ok, bytes memory ret) = RECORDED_BEACON.staticcall(abi.encodeWithSignature("implementation()"));
        require(ok && ret.length == 32, "recorded beacon did not answer implementation()");
        impl = address(uint160(uint256(bytes32(ret))));
        require(impl.code.length > 0, "recorded implementation has no code");
        h = impl.codehash;
    }

    // ---------- broadcast phase ----------

    function _buy() internal {
        (uint160 sqrtNow,,,,,,) = IPoolT(POOL).slot0();
        // Uniswap V3 rejects type(uint160).max with revert string "SPL": the
        // limit must sit strictly between the current sqrt price and
        // MAX_SQRT_RATIO. ~4% of headroom never bites at this size.
        uint160 limit = sqrtNow + (sqrtNow / 50);
        (int256 amount0Delta, int256 amount1Delta) =
            BemBuyer(buyer).buy(deployer, -int256(BUY_BEM_UNITS), limit, maxIn);
        console.log("TIER2|buy|bem_out", amount0Delta);
        console.log("TIER2|buy|wokb_in", amount1Delta);
        console.log("TIER2|buy|maxIn_cap", maxIn);
        // A partial fill is a loud failure, never a quietly smaller purchase.
        require(-amount0Delta >= int256(BUY_BEM_UNITS), "PARTIAL FILL: price limit reached before the exact BEM output");
        // Bought BEM went to the wallet, owed WOKB went to the pool, so the
        // helper must hold nothing. Anything parked here would be stranded.
        require(BemBuyer(buyer).isEmpty(BEM) && BemBuyer(buyer).isEmpty(WOKB), "swap buyer is not empty after the swap");
        console.log("TIER2|buy|buyer_empty", true);
    }

    function _unwrapAll() internal {
        uint256 w = IERC20T(WOKB).balanceOf(deployer);
        console.log("TIER2|unwrap|wokb_returned", w);
        if (w > 0) IWOKBT(WOKB).withdraw(w);
    }

    function _createCpu() internal {
        // Exact approval: the factory pulls deployFee(), read onchain rather
        // than assumed.
        uint256 fee = ITapeFactoryT(FACTORY).deployFee();
        console.log("TIER2|createCpu|deployFee_bem", fee);
        IERC20T(BEM).approve(FACTORY, fee);

        // Gate price 0: the caller sets it, official CPU #340 runs at 0, and
        // MintPriceProbe.t.sol proved the factory has no floor on X Layer.
        // Mints then cost the flat 0.01 BEM per call instead of
        // 0.01 BEM x 104 gates.
        (address first, address second) =
            ITapeFactoryT(FACTORY).createCPU("Pago", "PAGO", "Pago rule library: shareable payment-term circuits.", 100_000, 0);
        (circuits, transistors) = _roles(first, second);
        console.log("TIER2|createCpu|circuits", circuits);
        console.log("TIER2|createCpu|transistors", transistors);
        console.log("TIER2|createCpu|bem_left", IERC20T(BEM).balanceOf(deployer));

        // The whole deployment hinges on this: a processor whose shell hashes
        // to anything but the probed value would leave evaluatorPinned()
        // false forever, with no way to fix it. Abort instead.
        require(circuits.codehash == RECORDED_NEW_SHELL, "NEW PROCESSOR SHELL HASH != recorded probe - references would be wrong");
        console.log("TIER2|createCpu|shell_hash_matches_probe", true);
    }

    function _mintGates() internal {
        // Fees read BEFORE the approval, so the approved amount is the amount
        // this mint actually pulls: flat protocol fee + gate price x gates.
        uint256 mintPrice = ITransistorsT(transistors).mintPrice();
        uint256 protocolFee = ITransistorsT(transistors).protocolFee();
        uint256 allowance = protocolFee + mintPrice * Split3.NAND_COUNT;
        console.log("TIER2|mint|mintPrice", mintPrice);
        console.log("TIER2|mint|protocolFee", protocolFee);
        console.log("TIER2|mint|approved_bem", allowance);
        IERC20T(BEM).approve(transistors, allowance);
        ITransistorsT(transistors).mint(0, Split3.NAND_COUNT);
        console.log("TIER2|mint|gates", Split3.NAND_COUNT);
        console.log("TIER2|mint|bem_left", IERC20T(BEM).balanceOf(deployer));
    }

    function _tapeout() internal {
        uint256 fee = ICircuitsT(circuits).TAPEOUT_FEE();
        bytes memory nl = Split3.netlist();
        console.log("TIER2|tapeout|fee_okb", fee);
        console.log("TIER2|tapeout|netlist_bytes", nl.length);
        circuitId = ICircuitsT(circuits).tapeout{value: fee}(nl, Split3.N_IN, Split3.N_OUT);
        console.log("TIER2|tapeout|circuitId", circuitId);
        // Evidence read back, not part of the priced transaction: the
        // processor must serve the exact bytes we handed it.
        require(keccak256(IRuleProcessor(circuits).netlist(circuitId)) == keccak256(nl), "processor did not serve the netlist back");
        console.log("TIER2|tapeout|netlist_served_back", true);
    }

    function _deployPago() internal {
        // Re-verify every reference against the live chain at the moment of
        // use: the recorded shell (already checked in _createCpu), the
        // recorded beacon, and the implementation behind it.
        require(circuits.codehash == RECORDED_NEW_SHELL, "shell reference no longer matches at deploy time");
        (address liveImpl, bytes32 liveHash) = _liveLeg2();
        require(liveImpl == RECORDED_IMPL, "beacon moved since preflight");
        require(liveHash == RECORDED_IMPL_HASH, "implementation changed since preflight");

        // Two allowlisted stablecoins, both EIP-3009-proven on this chain
        // (docs/RESEARCH.md section 8) - the gasless payer path depends on
        // it - and both 6 decimals, checked in preflight.
        Pago.TokenConfig[] memory configs = new Pago.TokenConfig[](2);
        configs[0] = Pago.TokenConfig({token: USD_T0, decimals_: 6, unpinnedCap: UNPINNED_CAP});
        configs[1] = Pago.TokenConfig({token: USDG, decimals_: 6, unpinnedCap: UNPINNED_CAP});

        Pago pago = new Pago(configs, FEE_ACCOUNT, circuits, circuitId, RECORDED_NEW_SHELL, RECORDED_BEACON, RECORDED_IMPL, RECORDED_IMPL_HASH);

        console.log("TIER2|pago|address", address(pago));
        console.log("TIER2|pago|evaluatorPinned", pago.evaluatorPinned());
        console.log("TIER2|pago|feeAccount", pago.feeAccount());
        console.log("TIER2|pago|feeBps", pago.feeBps());
        console.log("TIER2|pago|circuitId", pago.circuitId());
        console.log("TIER2|pago|cap_USDT0", pago.MAX_LINK_AMOUNT_UNPINNED(USD_T0));
        console.log("TIER2|pago|cap_USDG", pago.MAX_LINK_AMOUNT_UNPINNED(USDG));
        console.log("TIER2|pago|changeDetector", vm.toString(pago.changeDetector()));
        // The deployment's whole point: rule 6's two-leg check must pass from
        // the first block, or every link stays capped.
        require(pago.evaluatorPinned(), "evaluatorPinned() is false immediately after deploy - do not ship this");
        console.log("TIER2|pago|pinned_ok", true);
    }

    // ---------- helpers ----------

    function _answerUint(address target, string memory sig) internal view returns (bool, uint256) {
        (bool ok, bytes memory ret) = target.staticcall(abi.encodeWithSignature(sig));
        if (!ok || ret.length != 32) return (false, 0);
        return (true, abi.decode(ret, (uint256)));
    }

    /// createCPU's two addresses are assigned BY CAPABILITY, never by
    /// position: TAPEOUT_FEE() answering = circuits, mintPrice() answering =
    /// transistors. Same rule the quote test proved on the fork.
    function _roles(address x, address y) internal view returns (address, address) {
        (bool tapeX,) = _answerUint(x, "TAPEOUT_FEE()");
        (bool mintX,) = _answerUint(x, "mintPrice()");
        (bool tapeY,) = _answerUint(y, "TAPEOUT_FEE()");
        (bool mintY,) = _answerUint(y, "mintPrice()");
        uint8 shapeX = uint8((tapeX ? 2 : 0) | (mintX ? 1 : 0));
        uint8 shapeY = uint8((tapeY ? 2 : 0) | (mintY ? 1 : 0));
        if (shapeX == 2 && shapeY == 1) return (x, y);
        if (shapeX == 1 && shapeY == 2) return (y, x);
        revert("role discovery failed: createCPU returned an unexpected pair");
    }
}
