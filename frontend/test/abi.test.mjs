/* Pago ABI codec tests — run with: node frontend/test/abi.test.mjs
 *
 * The vectors are real: `createLink`'s argument encoding came from
 * `cast abi-encode`, and every return blob was read out of an `eth_call`
 * against the live X Layer testnet deployment (chain 1952, Pago
 * 0x3b5B9639…A6C5) — not written by hand. So a green run means the codec in
 * frontend/abi.js agrees with what the chain actually sends, which is the
 * only agreement that matters: this file is the browser's whole
 * understanding of the contract's wire format.
 *
 * Nothing here touches the network; the captured blobs are in
 * test/fixtures/abi-vectors.json.
 */

import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import {
  SEL,
  LINK_TYPES,
  GET_LINK_TYPES,
  GET_LINKS_TYPES,
  STATUS,
  callData,
  decodeReturn,
  encodeTuple,
} from "../abi.js";

let passed = 0;
let failed = 0;
const ok = (cond, label) => {
  if (cond) { passed++; console.log(`  ok  ${label}`); }
  else { failed++; console.log(`FAIL  ${label}`); }
};
const eq = (got, want, label) =>
  ok(Object.is(got, want) || got === want, `${label} (got ${String(got)}, want ${String(want)})`);

const here = dirname(fileURLToPath(import.meta.url));
const { vectors } = JSON.parse(readFileSync(join(here, "fixtures", "abi-vectors.json"), "utf8"));
const vec = (name) => {
  const v = vectors.find((x) => x.name === name);
  if (!v) throw new Error("missing vector: " + name);
  return v.data;
};

const PAYEE = "0x7fce520d881454ea234d371e1256b75843609b62";
const DEPLOYER = "0x3f1004aaed662227d535d794da679110111a2fc4";
const TOKEN = "0x229a19b9d237629fc0c94812d21a4cf2b22b3615";

/* ── selectors ─────────────────────────────────────────────────────────── */

console.log("selectors");
eq(SEL.createLink, "0x167f1e66", "createLink(string,uint256,address,string,uint64)");
eq(SEL.pay, "0x901c5953", "pay(string,uint256)");
eq(SEL.claim, "0xf3fe12c9", "claim(string)");
eq(SEL.cancelLink, "0xc49dc85c", "cancelLink(string)");
eq(SEL.getLink, "0x7476452a", "getLink(string)");
eq(SEL.getLinksByCreator, "0x4afe4a95", "getLinksByCreator(address)");
eq(SEL.linkCountByCreator, "0xc0f27021", "linkCountByCreator(address)");
eq(SEL.feeBps, "0x24a9d853", "feeBps()");
eq(SEL.isTokenAllowed, "0xf9eaee0d", "isTokenAllowed(address)");
eq(SEL.approve, "0x095ea7b3", "approve(address,uint256)");
eq(SEL.balanceOf, "0x70a08231", "balanceOf(address)");
eq(SEL.nowMs, "0x6202306a", "nowMs()");
eq(SEL.mint, "0x40c10f19", "mint(address,uint256)");
ok(Object.values(SEL).every((s) => /^0x[0-9a-f]{8}$/.test(s)), "every selector is 0x + 8 lowercase hex");

/* ── encoding, against cast ────────────────────────────────────────────── */

console.log("encoding");

const CREATE_TYPES = ["string", "uint256", "address", "string", "uint64"];
const CREATE_VALUES = [
  "pago-261118-002651-a",
  1000000n,
  TOKEN,
  "Brand identity",
  1795000000000n,
];
const encoded = callData(SEL.createLink, CREATE_TYPES, CREATE_VALUES);
eq(encoded, SEL.createLink + vec("createLink args").slice(2), "createLink calldata matches cast abi-encode");

ok(encoded.length === 2 + 8 + 288 * 2, "createLink calldata is 4-byte selector + 288 bytes");

/* Two dynamic members in a row — the offset arithmetic that a one-word head
   would get wrong. head = 64 bytes; "ab" bodies 64 bytes (32 length + 32
   padded data), so the second offset lands at 64 + 64 = 128. */
const twoStrings = encodeTuple(["string", "string"], ["ab", "cdef"]);
eq(twoStrings.slice(0, 64), (64n).toString(16).padStart(64, "0"), "first string offset = 64");
eq(twoStrings.slice(64, 128), (128n).toString(16).padStart(64, "0"), "second string offset = 64 + first body (64) = 128");

/* ── decoding, against the live chain ──────────────────────────────────── */

console.log("decoding getLink (a real, claimed invoice)");

const [found, link] = decodeReturn(GET_LINK_TYPES, vec("getLink (claimed)"));
ok(found === true, "found is true");
eq(link.linkId, "pago-261118-002651-a", "linkId");
eq(link.creator, PAYEE, "creator is the payee");
eq(link.amount, 1000000n, "amount is 1.000000 in base units");
eq(link.token, TOKEN, "token");
eq(link.description, "live test: ordinary payer path", "description");
eq(Number(link.status), 2, "status is Claimed");
eq(STATUS[Number(link.status)], "Claimed", "status name");
eq(link.paidBy, DEPLOYER, "paidBy is the deployer");
eq(link.paidAmount, 1000000n, "paidAmount");
ok(Number(link.expiresAt) === 0, "never expires");
ok(Number(link.createdAt) > 1_700_000_000_000, "createdAt is a plausible ms timestamp");
ok(Number(link.claimedAt) > Number(link.paidAt) && Number(link.paidAt) > Number(link.createdAt), "createdAt < paidAt < claimedAt");

console.log("decoding getLink (an id that was never used)");

const [found2, link2] = decodeReturn(GET_LINK_TYPES, vec("getLink (missing)"));
ok(found2 === false, "found is false");
eq(link2.linkId, "", "linkId is empty");
eq(link2.creator, "0x0000000000000000000000000000000000000000", "creator is the zero address");
eq(link2.amount, 0n, "amount is zero");
eq(Number(link2.status), 0, "stored status reads Open on an empty slot");

console.log("decoding getLinksByCreator (six real invoices)");

const [links] = decodeReturn(GET_LINKS_TYPES, vec("getLinksByCreator (payee)"));
eq(links.length, 6, "six links");
eq(links[0].linkId, "pago-261118-000753-a", "oldest first");
eq(links[5].linkId, "pago-261118-002651-b", "newest last");
ok(links.every((l) => l.creator === PAYEE), "every link belongs to the requested creator");
ok(
  links.every((l, i) => i === 0 || Number(links[i - 1].createdAt) <= Number(l.createdAt)),
  "ordered by creation time"
);
ok(links.some((l) => Number(l.status) === 2), "at least one is Claimed");
ok(links.some((l) => Number(l.status) === 0 || Number(l.status) === 1), "at least one is not yet claimed");

console.log("decoding scalars");
eq(decodeReturn(["uint256"], vec("feeBps"))[0], 50n, "feeBps is 50 (0.5%)");
eq(decodeReturn(["uint256"], vec("balanceOf (payee)"))[0], 3980000n, "payee holds 3.980000 — exactly two 0.995 payouts");

/* ── round trip ────────────────────────────────────────────────────────── */

console.log("round trip");

const synthetic = [
  "pago-round-trip",
  PAYEE,
  12345678901234567890n,
  TOKEN,
  "note with — a unicode dash",
  1795000000001n,
  1795000864000n,
  1,
  DEPLOYER,
  12345678901234567890n,
  1795000000002n,
  0n,
];
const wire = encodeTuple(GET_LINK_TYPES, [true, synthetic]);
const [againFound, againLink] = decodeReturn(GET_LINK_TYPES, "0x" + wire);
ok(againFound === true, "round trip keeps found=true");
eq(againLink.linkId, synthetic[0], "round trip keeps linkId");
eq(againLink.amount, synthetic[2], "round trip keeps a 20-digit amount exactly");
eq(againLink.description, synthetic[4], "round trip keeps unicode");
eq(againLink.paidBy, synthetic[8], "round trip keeps the payer");
eq(againLink.claimedAt, 0n, "round trip keeps an unset timestamp");

/* An empty string and an empty array are the two shapes most likely to be
   mis-encoded as "absent" rather than "present and zero length". */
const [, emptyLink] = decodeReturn(GET_LINK_TYPES, "0x" + encodeTuple(GET_LINK_TYPES, [false, ["", "0x" + "00".repeat(20), 0n, TOKEN, "", 0n, 0n, 0, "0x" + "00".repeat(20), 0n, 0n, 0n]]));
eq(emptyLink.linkId, "", "an empty string decodes as empty, not undefined");
const [emptyArr] = decodeReturn(GET_LINKS_TYPES, "0x" + encodeTuple(GET_LINKS_TYPES, [[]]));
eq(emptyArr.length, 0, "an empty link list decodes as length 0");

/* ── refusals ──────────────────────────────────────────────────────────── */

console.log("refusals");

const throws = (fn, label) => {
  try { fn(); failed++; console.log(`FAIL  ${label} (did not throw)`); }
  catch { passed++; console.log(`  ok  ${label}`); }
};

throws(() => encodeTuple(["address"], ["0x1234"]), "a short address is refused");
throws(() => encodeTuple(["address"], ["not-an-address"]), "a non-address is refused");
throws(() => encodeTuple(["string"], [123]), "a number where a string belongs is refused");
throws(() => encodeTuple(["string", "string"], ["only-one"]), "a wrong value count is refused");
throws(() => encodeTuple(["bytes32"], ["0x12"]), "a short bytes32 is refused");
throws(() => decodeReturn(["uint256"], "0x"), "empty return data is refused");
throws(() => decodeReturn(["uint256"], "0x1234"), "truncated return data is refused");
throws(() => callData("0xnothex", [], []), "a malformed selector is refused");
throws(() => decodeReturn(["uint256"], "not hex at all"), "non-hex return data is refused");

/* ──────────────────────────────────────────────────────────────────────── */

console.log(`\n${passed} passed, ${failed} failed`);
if (failed) process.exit(1);
