// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {Vm} from "forge-std/Vm.sol";
import {Pago} from "../src/Pago.sol";
// The testnet token is the *same* contract the 60-test Pago suite runs
// against. Deploying a second, hand-written token for the live testnet would
// mean the thing being exercised onchain is not the thing that was proven
// locally — so the mock is promoted to a deployable test asset instead.
import {MockToken} from "../test/mocks/MockToken.sol";

/// Deploys Pago to X Layer (testnet 1952 by default).
///
/// What it does, in order:
///   1. If `PAGO_TOKEN` is unset, deploys a test stablecoin (6 decimals,
///      ERC-20 + EIP-3009) and mints a starting balance to `PAGO_DEPLOYER`, so
///      the whole create -> pay -> gasless pay -> claim flow can be exercised
///      without needing a faucet for a token that does not exist on testnet.
///   2. Deploys `Pago` with that token on its allowlist and `PAGO_FEE_ACCOUNT`
///      (falling back to `PAGO_DEPLOYER`) as the immutable fee recipient.
///
/// `PAGO_DEPLOYER` is read explicitly rather than taken from `msg.sender`
/// because in a Foundry script `msg.sender` is whatever `--sender` says — it
/// is not automatically the account doing the signing. Setting the address in
/// the environment keeps the mint recipient and the fee account pinned to the
/// account that is actually funding the deployment, whichever way the script
/// is invoked.
///
/// Signing is never done here: the script only builds transactions, and
/// `forge script --account <alias>` signs them through the Foundry keystore.
/// No private key appears in this file, in the command line, or in `.env`.
///
/// Usage (from contracts-evm/):
///
///   # optional overrides
///   $env:PAGO_DEPLOYER = "0x..."        # who gets the test-token mint
///   $env:PAGO_TOKEN = "0x..."           # reuse an already-deployed token
///   $env:PAGO_FEE_ACCOUNT = "0x..."     # who receives the 0.5% fee
///
///   forge script script/Deploy.s.sol:Deploy `
///     --rpc-url https://testrpc.xlayer.tech `
///     --account paylink-testnet `
///     --broadcast
///
/// Add `--verify` later once the explorer accepts the deployment; the
/// addresses are recorded in docs/RESEARCH.md regardless.
contract Deploy is Script {
    function run() external {
        string memory tokenAddr = vm.envOr("PAGO_TOKEN", string(""));
        address deployer = vm.envOr("PAGO_DEPLOYER", msg.sender);
        address feeAccount = vm.envOr("PAGO_FEE_ACCOUNT", deployer);

        vm.startBroadcast();

        address token;
        if (bytes(tokenAddr).length != 0) {
            token = vm.parseAddress(tokenAddr);
            console.log("using token from PAGO_TOKEN:", token);
        } else {
            // No stablecoin exists on testnet (RESEARCH.md section 13), so
            // Pago gets one of its own — the mock the test suite proves.
            MockToken t = new MockToken("Pago Test USD", "pUSD", 6);
            token = address(t);
            // A starting balance so the deployer can immediately create and
            // settle an invoice end to end.
            t.mint(deployer, 1_000_000_000); // 1,000 pUSD
            console.log("deployed test token (pUSD, MOCK - not a stablecoin):", token);
        }

        address[] memory tokens = new address[](1);
        tokens[0] = token;

        Pago pago = new Pago(tokens, feeAccount);

        vm.stopBroadcast();

        console.log("Pago deployed at:", address(pago));
        console.log("  chain id:      ", block.chainid);
        console.log("  deployer:      ", deployer);
        console.log("  fee account:   ", feeAccount);
        console.log("  token:         ", token);
        console.log("  fee bps:       ", pago.feeBps());
        console.log("");
        console.log("Record these in frontend/config.js XLAYER.pago and docs/RESEARCH.md.");
    }
}
