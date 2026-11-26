/* Pago gasless tests — run with: node frontend/test/gasless.test.mjs
 *
 * The calldata vector is real: the `input` of X Layer mainnet transaction
 * 0x0cb7a79a…811f6, the settled 0.1 USD₮0 gasless payment (RESEARCH §22),
 * captured with `cast tx` and reproduced here field for field. A green run
 * means frontend/gasless.js encodes exactly the bytes the chain accepted —
 * the browser builds the same transaction the demo settled with.
 *
 * The typed-data assertions pin the EIP-712 shape docs/RESEARCH.md §16
 * proved against both real tokens: domain version "1", uint fields as
 * decimal strings, nonce as 0x-hex, validAfter 0 and validBefore uint64 max
 * — the window the demo settled under.
 *
 * Nothing here touches the network; every value below came from chain. */

import {
  VALID_AFTER,
  VALID_BEFORE,
  PAY_AUTH_TYPES,
  DOMAIN_FIELDS,
  authorizationTypedData,
  encodePayWithAuthorization,
} from "../gasless.js";

let passed = 0;
let failed = 0;
const ok = (cond, label) => {
  if (cond) { passed++; console.log(`  ok  ${label}`); }
  else { failed++; console.log(`FAIL  ${label}`); }
};
const eq = (got, want, label) =>
  ok(got === want, `${label} (got ${String(got)}, want ${String(want)})`);

/* ── the settled demo transaction, decoded (cast tx 0x0cb7a79a…811f6) ── */

const LINK_ID = "pago-261125-demo01";
const FROM = "0x6256B90E4f36ee9e7A16cd29E7705dbdc539ec7b";
const VALUE = 100000n;
const NONCE = "0xb339df73410376abda69ff998949e91c821cf71c9c5a49760124782282e11ac0";
const SIGNATURE =
  "0xe44f5f9e48ed3573bb2f9f4e3ba87cc35b76cd4f7bd8bd73a144127f768e43e7" +
  "109b7a0c70acb1a1d20943a29dbe73c79cf6e2cb25b1e17593253135bd2d42cd1b";
const TERMS_HASH = "0xb97c550b173a41ba313bc430802d8c726c5fdd3f0e53085a08278e78c1206073";

/* The full input hex of that transaction — the byte-exact oracle. */
const DEMO_INPUT =
  "0x69c1372a00000000000000000000000000000000000000000000000000000000000001000000000000000000000000006256b90e4f36ee9e7a16cd29e7705dbdc539ec7b00000000000000000000000000000000000000000000000000000000000186a00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000ffffffffffffffffb339df73410376abda69ff998949e91c821cf71c9c5a49760124782282e11ac00000000000000000000000000000000000000000000000000000000000000140b97c550b173a41ba313bc430802d8c726c5fdd3f0e53085a08278e78c120607300000000000000000000000000000000000000000000000000000000000000127061676f2d3236313132352d64656d6f303100000000000000000000000000000000000000000000000000000000000000000000000000000000000000000041e44f5f9e48ed3573bb2f9f4e3ba87cc35b76cd4f7bd8bd73a144127f768e43e7109b7a0c70acb1a1d20943a29dbe73c79cf6e2cb25b1e17593253135bd2d42cd1b00000000000000000000000000000000000000000000000000000000000000";

console.log("constants");
eq(VALID_AFTER, 0n, "validAfter is 0");
eq(VALID_BEFORE, 2n ** 64n - 1n, "validBefore is uint64 max");

console.log("payWithAuthorization calldata == settled mainnet tx input");
const got = encodePayWithAuthorization({
  linkId: LINK_ID,
  from: FROM,
  value: VALUE,
  nonce: NONCE,
  signature: SIGNATURE,
  expectedTermsHash: TERMS_HASH,
});
eq(got.toLowerCase(), DEMO_INPUT.toLowerCase(), "byte-exact replay of 0x0cb7a79a…811f6");
eq(got.slice(0, 10), "0x69c1372a", "selector is payWithAuthorization");

console.log("the same call with defaults the demo used");
eq(
  encodePayWithAuthorization({
    linkId: LINK_ID,
    from: FROM,
    value: "100000",
    nonce: NONCE,
    signature: SIGNATURE,
    expectedTermsHash: TERMS_HASH,
    validAfter: VALID_AFTER,
    validBefore: VALID_BEFORE,
  }).toLowerCase(),
  DEMO_INPUT.toLowerCase(),
  "explicit window equals the defaults"
);

console.log("EIP-712 typed data (docs/RESEARCH.md §16)");
const PAGO = "0x2fC4180db7318F4364F6FC559A25359c9F537D3e";
const TOKEN = "0x779Ded0c9e1022225f8E0630b35a9b54bE713736";
const td = authorizationTypedData({
  /* USD₮0's live name() on X Layer mainnet — the domain binding the
     settled signature verified against (cast call … "name()(string)"). */
  name: "USD₮0",
  chainId: 196,
  verifyingContract: TOKEN,
  from: FROM,
  to: PAGO,
  value: VALUE,
  nonce: NONCE,
});
eq(td.primaryType, "TransferWithAuthorization", "primaryType");
eq(td.domain.version, "1", "domain version is \"1\"");
eq(td.domain.chainId, 196, "chainId is a number, not a string");
eq(td.domain.verifyingContract, TOKEN, "verifyingContract is the token");
eq(td.domain.name, "USD₮0", "domain name is the token's name()");
eq(td.message.from, FROM, "message.from");
eq(td.message.to, PAGO, "message.to is the Pago contract");
eq(td.message.value, "100000", "uint256 value serializes as a decimal string");
eq(td.message.validAfter, "0", "validAfter is \"0\"");
eq(td.message.validBefore, "18446744073709551615", "validBefore is uint64 max as a decimal string");
eq(td.message.nonce, NONCE, "bytes32 nonce stays 0x-hex");
eq(
  td.types.TransferWithAuthorization.map((f) => `${f.name}:${f.type}`).join(","),
  PAY_AUTH_TYPES.map((f) => `${f.name}:${f.type}`).join(","),
  "TransferWithAuthorization field order matches the tokens' struct"
);
eq(
  td.types.EIP712Domain.map((f) => `${f.name}:${f.type}`).join(","),
  DOMAIN_FIELDS.map((f) => `${f.name}:${f.type}`).join(","),
  "EIP712Domain fields"
);

console.log("guards");
let threw = false;
try {
  authorizationTypedData({ chainId: 196, verifyingContract: TOKEN, from: FROM, to: PAGO, value: 1n, nonce: NONCE });
} catch { threw = true; }
ok(threw, "missing token name() throws instead of signing a wrong domain");

console.log("");
console.log(`${passed} passed, ${failed} failed`);
if (failed) process.exit(1);
