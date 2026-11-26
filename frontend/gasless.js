/* Pago — the gasless payer path: EIP-712 typed data and calldata.

   The payer signs a TransferWithAuthorization off-chain; any connected
   wallet may submit it and pay the gas. This module only *builds* the two
   payloads the wallet and the chain need:

     1. authorizationTypedData — the object fed to eth_signTypedData_v4.
        The digest is computed wallet-side; this file never hashes.
     2. encodePayWithAuthorization — the exact calldata for Pago's
        payWithAuthorization, encoded by the same codec as every other call.

   Every value that could drift is read from the chain at signing time
   (token name() for the domain, authorizationNonce() and termsHash() as
   message fields) — the same rule the pay path follows in xlayer.js.

   Constants match the settlement proven on X Layer mainnet in tx
   0x0cb7a79a…811f6: validAfter = 0, validBefore = uint64 max, domain
   version "1". frontend/test/gasless.test.mjs replays that transaction's
   calldata byte for byte against this encoder. */

import { SEL, callData } from "./abi.js";

/* The two bounds the demo settled with: validAfter = 0 (valid now) and
   validBefore = 2^64-1 (never expires on its own — the invoice's own
   expiry still rules, enforced by the contract). */
export const VALID_AFTER = 0n;
export const VALID_BEFORE = 2n ** 64n - 1n;

/* The EIP-712 struct the token verifies. Field order and types are the
   tokens' own, proven against both USD₮0 and USDG DOMAIN_SEPARATORs
   (docs/RESEARCH.md §16; contracts-evm/test/Phase0Fork.t.sol). */
export const PAY_AUTH_TYPES = [
  { name: "from", type: "address" },
  { name: "to", type: "address" },
  { name: "value", type: "uint256" },
  { name: "validAfter", type: "uint256" },
  { name: "validBefore", type: "uint256" },
  { name: "nonce", type: "bytes32" },
];

/* EIP-712Domain fields both tokens use: name (the token's onchain name()),
   version "1", chainId, verifyingContract (the token itself). */
export const DOMAIN_FIELDS = [
  { name: "name", type: "string" },
  { name: "version", type: "string" },
  { name: "chainId", type: "uint256" },
  { name: "verifyingContract", type: "address" },
];

/** The payload for `eth_signTypedData_v4`. `value`, `validAfter` and
    `validBefore` are bigints (or numeric strings) and serialize as decimal
    strings, which is what wallets expect for uint256 fields; `nonce` stays
    0x-hex for bytes32. `name` must be the token's own name() — it *is* the
    domain binding, so a wrong name makes every signature invalid. */
export function authorizationTypedData({
  name,
  chainId,
  verifyingContract,
  from,
  to,
  value,
  nonce,
  validAfter = VALID_AFTER,
  validBefore = VALID_BEFORE,
}) {
  if (!name) throw new Error("typed data needs the token's onchain name()");
  return {
    types: {
      EIP712Domain: DOMAIN_FIELDS,
      TransferWithAuthorization: PAY_AUTH_TYPES,
    },
    primaryType: "TransferWithAuthorization",
    domain: {
      name,
      version: "1",
      chainId: Number(chainId),
      verifyingContract,
    },
    message: {
      from,
      to,
      value: BigInt(value).toString(),
      validAfter: BigInt(validAfter).toString(),
      validBefore: BigInt(validBefore).toString(),
      nonce,
    },
  };
}

/** The exact `payWithAuthorization` calldata Pago settles with. Argument
    order mirrors the Solidity signature — linkId, from, value, validAfter,
    validBefore, nonce, signature, expectedTermsHash. */
export function encodePayWithAuthorization({
  linkId,
  from,
  value,
  nonce,
  signature,
  expectedTermsHash,
  validAfter = VALID_AFTER,
  validBefore = VALID_BEFORE,
}) {
  return callData(
    SEL.payWithAuthorization,
    ["string", "address", "uint256", "uint64", "uint64", "bytes32", "bytes", "bytes32"],
    [linkId, from, value, validAfter, validBefore, nonce, signature, expectedTermsHash]
  );
}
