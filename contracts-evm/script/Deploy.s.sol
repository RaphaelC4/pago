// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {Vm} from "forge-std/Vm.sol";
import {Pago} from "../src/Pago.sol";
// The testnet token is the *same* contract the Pago suites run against.
// Deploying a second, hand-written token for the live testnet would mean the
// thing being exercised onchain is not the thing that was proven locally - so
// the mock is promoted to a deployable test asset instead.
import {MockToken} from "../test/mocks/MockToken.sol";
import {MockBeacon} from "../test/mocks/MockBeacon.sol";
import {ProcessorStandIn} from "../test/mocks/ProcessorStandIn.sol";

/// Deploys Pago to X Layer (testnet 1952 by default).
///
/// What it does, in order:
///   1. If `PAGO_TOKEN` is unset, deploys a test stablecoin (6 decimals,
///      ERC-20 + EIP-3009) and mints a starting balance to `PAGO_DEPLOYER`.
///   2. **Rule 7 (decimals):** reads the token's onchain `decimals()` and
///      **aborts** unless it equals the expected value - `PAGO_EXPECTED_DECIMALS`
///      (default 6), which is the value *we* wrote when we deployed the token.
///      Pago itself never calls `decimals()`; the value it stores comes from
///      here, checked against the chain once, at deploy time.
///   3. Resolves the rule processor: `PAGO_PROCESSOR` if set, otherwise deploys
///      the **EVM stand-in** (testnet only - TapeOut exists solely on mainnet,
///      docs/RESEARCH.md section 17) and says so loudly in the log. This is not
///      hardware and is never described as such.
///   4. Resolves the references for rule 6's two-leg implementation check:
///      the recorded codehash of the live TapeOut processor **shell** (a
///      beacon proxy, disassembled in docs/RESEARCH.md section 18) by default,
///      overridable with `PAGO_PROCESSOR_CODEHASH`; the recorded circuit
///      beacon address (`PAGO_BEACON`, default the beacon hardcoded in the
///      recorded shell); and the recorded circuit **implementation** codehash
///      (`PAGO_IMPLEMENTATION_CODEHASH`). On testnet all three are supplied
///      for the stand-in: its own codehash as the shell reference and a
///      freshly deployed mock beacon reporting the stand-in, so the check
///      machinery runs live even though the result is the stand-in's own
///      shape - never the recorded mainnet values, which the stand-in could
///      not satisfy anyway. Deploys `Pago` with the allowlist, the unpinned
///      cap (`PAGO_UNPINNED_CAP` base units, default 10,000 tokens at the
///      expected decimals) and `PAGO_FEE_ACCOUNT` (falling back to
///      `PAGO_DEPLOYER`). Pago's constructor compares both references onchain
///      - the only path that may set `evaluatorPinned` - and the flag, the
///      references and a live `changeDetector` reading (evidence only, never
///      the source of the flag) are printed. On testnet the stand-in's code
///      differs from the recorded shell reference, so the flag prints false
///      and every link stays capped: honest, and exactly what rule 6 wants
///      until a real tape-out exists.
///
/// `PAGO_DEPLOYER` is read explicitly rather than taken from `msg.sender`
/// because in a Foundry script `msg.sender` is whatever `--sender` says.
///
/// Signing is never done here: the script only builds transactions, and
/// `forge script --account <alias>` signs them through the Foundry keystore.
/// No private key appears in this file, the command line, or `.env`.
///
/// Usage (from contracts-evm/):
///
///   # optional overrides
///   $env:PAGO_DEPLOYER = "0x..."        # who gets the test-token mint
///   $env:PAGO_TOKEN = "0x..."           # reuse an already-deployed token
///   $env:PAGO_FEE_ACCOUNT = "0x..."     # who receives the 0.5% fee
///   $env:PAGO_EXPECTED_DECIMALS = "6"   # abort if the token disagrees
///   $env:PAGO_UNPINNED_CAP = "10000000000"  # base units, while unpinned
///   $env:PAGO_PROCESSOR = "0x..."       # skip the stand-in (mainnet tier 2)
///   $env:PAGO_PROCESSOR_CODEHASH = "0x..."  # leg 1: shell codehash reference;
///                                            # default = recorded TapeOut
///                                            # shell (docs/RESEARCH.md 18)
///   $env:PAGO_BEACON = "0x..."          # leg 2: beacon whose implementation()
///                                            # getter is called; default =
///                                            # beacon hardcoded in the
///                                            # recorded shell (section 18)
///   $env:PAGO_IMPLEMENTATION_CODEHASH = "0x..."  # leg 2: codehash the beacon's
///                                            # answer must equal; default =
///                                            # recorded circuit impl hash
///   $env:PAGO_CIRCUIT_ID = "1"          # circuit id inside the processor
///
///   forge script script/Deploy.s.sol:Deploy `
///     --rpc-url https://testrpc.xlayer.tech `
///     --account pago-deployer `
///     --broadcast
contract Deploy is Script {
    /// Recorded codehash of the real TapeOut processor **shell** on X Layer
    /// mainnet (chain 196): a 295-byte beacon proxy, disassembled in
    /// docs/RESEARCH.md section 18; probed identical across processors #340,
    /// #30 and #333 via `cast code` + `cast keccak`. Rule 6's leg 1 compares
    /// `extcodehash(processor)` against this unless `PAGO_PROCESSOR_CODEHASH`
    /// overrides it. A live read would be no check at all - the reference must
    /// come from our own recorded probe.
    bytes32 internal constant RECORDED_TAPEOUT_PROCESSOR_CODEHASH = 0x57aa306fd0be97087da3534e03398f5ff4efd533b5be4e45a405ce86fa6717d5;

    /// Recorded circuit beacon on X Layer mainnet: the address the recorded
    /// shell hardcodes (its EIP-1967 beacon slot and its PUSH32 literal both
    /// read `0xf70d1ed4…bd0991c` - section 18), frozen (`owner() = 0`).
    /// Rule 6's leg 2 calls `implementation()` on this. Overridable with
    /// `PAGO_BEACON`.
    address internal constant RECORDED_CIRCUIT_BEACON = 0xf70d1ed4f62CF3780157B0b421b7E2F45bD0991C;

    /// Recorded codehash of the circuit implementation behind that beacon
    /// (12,562 bytes at `0x977f2178…29B2`, `cast code` + `cast keccak`,
    /// section 18). Rule 6's leg 2 compares the beacon's answer against this
    /// unless `PAGO_IMPLEMENTATION_CODEHASH` overrides it.
    bytes32 internal constant RECORDED_CIRCUIT_IMPL_CODEHASH = 0x7a15c353205e5245f40f5f5524542a982a4bb3b9a28476e4f10845163f941b30;

    /// The environment knobs, bundled: reading them one by one into `run()`
    /// locals overflows the legacy codegen's stack ("stack too deep"), and a
    /// memory struct costs exactly one slot.
    struct Cfg {
        string tokenAddr;
        address deployer;
        address feeAccount;
        uint256 expectedDecimals;
        uint256 unpinnedCap;
        string processorAddr;
        uint256 circuitId;
    }

    function run() external {
        Cfg memory cfg = Cfg({
            tokenAddr: vm.envOr("PAGO_TOKEN", string("")),
            deployer: vm.envOr("PAGO_DEPLOYER", msg.sender),
            // Placeholders: a struct literal cannot reference sibling fields,
            // so the two derived knobs are assigned right after construction.
            feeAccount: msg.sender,
            expectedDecimals: vm.envOr("PAGO_EXPECTED_DECIMALS", uint256(6)),
            unpinnedCap: 0, // replaced below
            processorAddr: vm.envOr("PAGO_PROCESSOR", string("")),
            circuitId: vm.envOr("PAGO_CIRCUIT_ID", uint256(1))
        });
        cfg.feeAccount = vm.envOr("PAGO_FEE_ACCOUNT", cfg.deployer);
        cfg.unpinnedCap = vm.envOr("PAGO_UNPINNED_CAP", uint256(10_000 * 10 ** cfg.expectedDecimals));

        vm.startBroadcast();

        address token;
        if (bytes(cfg.tokenAddr).length != 0) {
            token = vm.parseAddress(cfg.tokenAddr);
            console.log("using token from PAGO_TOKEN:", token);
        } else {
            // No stablecoin exists on testnet (docs/RESEARCH.md section 13), so
            // Pago gets one of its own - the mock the test suite proves.
            MockToken t = new MockToken("Pago Test USD", "pUSD", uint8(cfg.expectedDecimals));
            token = address(t);
            t.mint(cfg.deployer, 1_000 * 10 ** cfg.expectedDecimals); // 1,000 pUSD
            console.log("deployed test token (pUSD, MOCK - not a stablecoin):", token);
        }

        // Rule 7: our expected decimals vs what the chain says. Abort loudly on
        // mismatch - Pago stores the expected value and never asks the token.
        uint256 onchainDecimals = IERC20Decimals(token).decimals();
        require(onchainDecimals == cfg.expectedDecimals, "DECIMALS MISMATCH: token disagrees with PAGO_EXPECTED_DECIMALS - aborting");
        console.log("token decimals (chain == expected):", onchainDecimals);

        // Rule 6 leg 1 reference: the recorded implementation codehash of the
        // live TapeOut processor shells (probed identical across #340, #30 and
        // #333 - docs/RESEARCH.md section 18). PAGO_PROCESSOR_CODEHASH
        // overrides it, e.g. after a future tape-out, and must never be a live
        // read: echoing back extcodehash(processor) from this RPC would make
        // the constructor's check tautological (it could only ever pass).
        bytes32 expectedProcessorCodehash = vm.envOr("PAGO_PROCESSOR_CODEHASH", RECORDED_TAPEOUT_PROCESSOR_CODEHASH);

        bool usingStandIn = bytes(cfg.processorAddr).length == 0;
        address processor = usingStandIn ? address(new ProcessorStandIn()) : vm.parseAddress(cfg.processorAddr);
        if (usingStandIn) {
            // Testnet has no TapeOut factory (probe returns no code), so the
            // rule path runs against an EVM stand-in executing the real
            // Split3 netlist bytes. NOT hardware - see ProcessorStandIn.
            console.log("DEPLOYED PROCESSOR STAND-IN (EVM, not hardware):", processor);
        } else {
            console.log("using processor from PAGO_PROCESSOR:", processor);
        }
        console.log("leg 1 shell reference (codehash):", vm.toString(expectedProcessorCodehash));

        // Rule 6 leg 2: the beacon and the implementation reference (helper
        // below, kept out of run() for the stack limit).
        (address beacon, bytes32 expectedImplCodehash) = _resolveBeacon(processor, usingStandIn);

        Pago.TokenConfig[] memory configs = new Pago.TokenConfig[](1);
        configs[0] = Pago.TokenConfig({token: token, decimals_: uint8(cfg.expectedDecimals), unpinnedCap: cfg.unpinnedCap});

        Pago pago = new Pago(configs, cfg.feeAccount, processor, cfg.circuitId, expectedProcessorCodehash, beacon, expectedImplCodehash);

        vm.stopBroadcast();

        _logDeployment(pago, token, cfg.deployer, cfg.feeAccount);
        console.log("");
        console.log("Record these in frontend/config.js XLAYER.pago and docs/RESEARCH.md.");
    }

    /// Rule 6 leg 2 resolution: the beacon whose public `implementation()`
    /// getter the constructor calls, and the codehash its answer must equal.
    /// On mainnet (PAGO_PROCESSOR set) the defaults are the recorded beacon
    /// hardcoded in the recorded shell and the recorded circuit
    /// implementation's codehash (docs/RESEARCH.md section 18). On testnet
    /// there is no genuine beacon for a stand-in, so the mock the test suite
    /// uses is deployed instead - reporting the stand-in, so the second leg
    /// runs live against real code rather than being skipped, and the flag's
    /// false result stays honest.
    function _resolveBeacon(address processor, bool usingStandIn) internal returns (address beacon, bytes32 expectedImplCodehash) {
        string memory beaconAddr = vm.envOr("PAGO_BEACON", string(""));
        if (bytes(beaconAddr).length != 0) {
            beacon = vm.parseAddress(beaconAddr);
            console.log("using beacon from PAGO_BEACON:", beacon);
        } else if (usingStandIn) {
            MockBeacon mockBeacon = new MockBeacon(processor);
            beacon = address(mockBeacon);
            console.log("DEPLOYED MOCK BEACON reporting the stand-in (not the TapeOut beacon):", beacon);
        } else {
            beacon = RECORDED_CIRCUIT_BEACON;
            console.log("using recorded circuit beacon:", beacon);
        }
        expectedImplCodehash = vm.envOr("PAGO_IMPLEMENTATION_CODEHASH", usingStandIn ? address(processor).codehash : RECORDED_CIRCUIT_IMPL_CODEHASH);
        console.log("leg 2 implementation reference (codehash):", vm.toString(expectedImplCodehash));
    }

    /// Everything printed after the broadcast, in one place (the stack limit
    /// keeps run() itself small): the deployment record, both references, the
    /// flag, and a live read of what each leg saw as evidence next to it.
    /// Everything except the token and the two accounts is read back from
    /// Pago's own public surface - the deployment describing itself.
    function _logDeployment(Pago pago, address token, address deployer, address feeAccount) internal view {
        address processor = pago.processor();
        address beacon = pago.circuitBeacon();
        console.log("Pago deployed at:", address(pago));
        console.log("  chain id:         ", block.chainid);
        console.log("  deployer:         ", deployer);
        console.log("  fee account:      ", feeAccount);
        console.log("  token:            ", token);
        console.log("  token decimals:   ", pago.expectedDecimals(token));
        console.log("  fee bps:          ", pago.feeBps());
        console.log("  processor:        ", processor);
        console.log("  circuit id:       ", pago.circuitId());
        console.log("  circuit beacon:   ", beacon);
        console.log("  leg 1 reference:  ", vm.toString(pago.expectedProcessorCodehash()));
        console.log("  leg 2 reference:  ", vm.toString(pago.expectedImplementationCodehash()));
        console.log("  evaluatorPinned:  ", pago.evaluatorPinned());
        console.log("  changeDetector:   ", pago.changeDetector());
        console.log("  (changeDetector is evidence only; rule 6 lets only the two-leg code check set evaluatorPinned)");
        console.log("  unpinned cap:     ", pago.MAX_LINK_AMOUNT_UNPINNED(token));
        // Live reads of what each leg saw, as evidence next to the flag.
        console.log("  live leg 1 read:  ", vm.toString(address(processor).codehash));
        (bool legOk, bytes memory legRet) = beacon.staticcall(abi.encodeWithSignature("implementation()"));
        if (legOk && legRet.length == 32) {
            console.log("  live leg 2 read:  ", vm.toString(address(uint160(uint256(bytes32(legRet))))));
        } else {
            console.log("  live leg 2 read:  beacon.implementation() reverted or returned nothing");
        }
        if (!pago.evaluatorPinned()) {
            console.log("  NOTE: rule 6's two-leg check did not pass - every link is capped. Legs:");
            console.log("        1. extcodehash(processor) vs PAGO_PROCESSOR_CODEHASH (recorded shell)");
            console.log("        2. extcodehash(beacon.implementation()) vs PAGO_IMPLEMENTATION_CODEHASH");
            console.log("        Recorded values: docs/RESEARCH.md section 18.");
        }
    }
}

/// `decimals()` as standard ERC-20s declare it. Read exactly once, here, to
/// compare against the value we wrote (rule 7); Pago never calls it.
interface IERC20Decimals {
    function decimals() external view returns (uint8);
}
