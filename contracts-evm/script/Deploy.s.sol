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
///   4. Deploys `Pago` with the allowlist, the unpinned cap
///      (`PAGO_UNPINNED_CAP` base units, default 10,000 tokens at the expected
///      decimals) and `PAGO_FEE_ACCOUNT` (falling back to `PAGO_DEPLOYER`).
///      Pago then runs its own `changeDetector` known-answer check at
///      construction and the resulting `evaluatorPinned` flag is printed.
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
///   $env:PAGO_CIRCUIT_ID = "1"          # circuit id inside the processor
///
///   forge script script/Deploy.s.sol:Deploy `
///     --rpc-url https://testrpc.xlayer.tech `
///     --account pago-deployer `
///     --broadcast
contract Deploy is Script {
    function run() external {
        string memory tokenAddr = vm.envOr("PAGO_TOKEN", string(""));
        address deployer = vm.envOr("PAGO_DEPLOYER", msg.sender);
        address feeAccount = vm.envOr("PAGO_FEE_ACCOUNT", deployer);
        uint256 expectedDecimals = vm.envOr("PAGO_EXPECTED_DECIMALS", uint256(6));
        uint256 unpinnedCap = vm.envOr("PAGO_UNPINNED_CAP", uint256(10_000 * 10 ** expectedDecimals));
        string memory processorAddr = vm.envOr("PAGO_PROCESSOR", string(""));
        uint256 circuitId = vm.envOr("PAGO_CIRCUIT_ID", uint256(1));

        vm.startBroadcast();

        address token;
        if (bytes(tokenAddr).length != 0) {
            token = vm.parseAddress(tokenAddr);
            console.log("using token from PAGO_TOKEN:", token);
        } else {
            // No stablecoin exists on testnet (docs/RESEARCH.md section 13), so
            // Pago gets one of its own - the mock the test suite proves.
            MockToken t = new MockToken("Pago Test USD", "pUSD", uint8(expectedDecimals));
            token = address(t);
            t.mint(deployer, 1_000 * 10 ** expectedDecimals); // 1,000 pUSD
            console.log("deployed test token (pUSD, MOCK - not a stablecoin):", token);
        }

        // Rule 7: our expected decimals vs what the chain says. Abort loudly on
        // mismatch - Pago stores the expected value and never asks the token.
        uint256 onchainDecimals = IERC20Decimals(token).decimals();
        require(onchainDecimals == expectedDecimals, "DECIMALS MISMATCH: token disagrees with PAGO_EXPECTED_DECIMALS - aborting");
        console.log("token decimals (chain == expected):", onchainDecimals);

        address processor;
        if (bytes(processorAddr).length != 0) {
            processor = vm.parseAddress(processorAddr);
            console.log("using processor from PAGO_PROCESSOR:", processor);
        } else {
            // Testnet has no TapeOut factory (probe returns no code), so the
            // rule path runs against an EVM stand-in executing the real
            // Split3 netlist bytes. NOT hardware - see ProcessorStandIn.
            ProcessorStandIn standIn = new ProcessorStandIn();
            processor = address(standIn);
            console.log("DEPLOYED PROCESSOR STAND-IN (EVM, not hardware):", processor);
        }

        Pago.TokenConfig[] memory configs = new Pago.TokenConfig[](1);
        configs[0] = Pago.TokenConfig({token: token, decimals_: uint8(expectedDecimals), unpinnedCap: unpinnedCap});

        Pago pago = new Pago(configs, feeAccount, processor, circuitId);

        vm.stopBroadcast();

        console.log("Pago deployed at:", address(pago));
        console.log("  chain id:         ", block.chainid);
        console.log("  deployer:         ", deployer);
        console.log("  fee account:      ", feeAccount);
        console.log("  token:            ", token);
        console.log("  token decimals:   ", pago.expectedDecimals(token));
        console.log("  fee bps:          ", pago.feeBps());
        console.log("  processor:        ", processor);
        console.log("  circuit id:       ", circuitId);
        console.log("  evaluatorPinned:  ", pago.evaluatorPinned());
        console.log("  unpinned cap:     ", pago.MAX_LINK_AMOUNT_UNPINNED(token));
        if (!pago.evaluatorPinned()) {
            console.log("  NOTE: changeDetector did not pass - every link is capped until it does.");
        }
        console.log("");
        console.log("Record these in frontend/config.js XLAYER.pago and docs/RESEARCH.md.");
    }
}

/// `decimals()` as standard ERC-20s declare it. Read exactly once, here, to
/// compare against the value we wrote (rule 7); Pago never calls it.
interface IERC20Decimals {
    function decimals() external view returns (uint8);
}
