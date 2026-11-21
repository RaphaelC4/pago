/* Pago payout-evidence tests — run with: node frontend/test/payout.test.mjs
 *
 * The logs are real: test/fixtures/raw-claim-logs.json is the exact
 * eth_getLogs output the X Layer testnet RPC returned for the two claims of
 * the 2026-11-19 live run (Pago 0x36d212b8814470d60aaddb6e204f09efb3a3dce9,
 * chain 1952), captured 2026-11-21. Leg A used the rule table (circuit
 * accepted 10+6+4 = 20 steps); Leg B fell back to the default split (its
 * rule table summed to 23). So a green run means frontend/payout.js decodes
 * what the chain actually emitted — the receipt and the CSV print nothing
 * the events did not say.
 *
 * Nothing here touches the network.
 */

import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import {
  EVT,
  XLAYER_RECEIPT_SENTENCE,
  formatUnits,
  decodeLinkClaimed,
  decodeLegs,
  splitClaimLegs,
  claimReceiptLines,
  ledgerCsv,
} from "../payout.js";

let passed = 0;
let failed = 0;
const ok = (cond, label) => {
  if (cond) { passed++; console.log(`  ok  ${label}`); }
  else { failed++; console.log(`FAIL  ${label}`); }
};
const eq = (got, want, label) =>
  ok(Object.is(got, want) || got === want, `${label} (got ${String(got)}, want ${String(want)})`);

const here = dirname(fileURLToPath(import.meta.url));
const raw = JSON.parse(readFileSync(join(here, "fixtures", "raw-claim-logs.json"), "utf8"));
/* The capture script wrote single-element arrays; PowerShell's JSON writer
   unwrapped them into bare objects. Accept both shapes. */
const asArray = (v) => (Array.isArray(v) ? v : [v]);
const fix = { ...raw, claimA: asArray(raw.claimA), claimB: asArray(raw.claimB) };

const PAYEE = "0x7fce520d881454ea234d371e1256b75843609b62";
const DEPLOYER = "0x3f1004aaed662227d535d794da679110111a2fc4";
const FEE = 5000n; // 0.5% of 1.000000 at 6 decimals

/* ── event topics ──────────────────────────────────────────────────────── */

console.log("event topics");
eq(EVT.linkClaimed, "0xb5b858e924331e29402dfbd0244b02fc16bfd21a9e0799474f536750377cc398", "LinkClaimed(bytes32,uint256,uint256,bool)");
eq(EVT.legPaid, "0x4ef82e18e70727bf3ad29af492a007429cee27018a072f1003552ba174791bdc", "LegPaid(bytes32,address,uint256)");
eq(EVT.legOwed, "0x11a4ea12c72a399e1763204aa4fbfe38c154797d98be4bdf4b3a1cd3ea620863", "LegOwed(bytes32,address,uint256)");
eq(XLAYER_RECEIPT_SENTENCE, "Payment delivered and paid out on X Layer", "the X Layer receipt sentence is its own constant");

/* ── formatUnits ───────────────────────────────────────────────────────── */

console.log("formatUnits");
eq(formatUnits(995000n, 6), "0.995000", "995000 at 6 decimals");
eq(formatUnits(5000n, 6), "0.005000", "the fee leg");
eq(formatUnits(1000000n, 6), "1.000000", "a whole unit keeps its trailing zeros");
eq(formatUnits(0n, 6), "0.000000", "zero");
eq(formatUnits(1n, 6), "0.000001", "one base unit");
eq(formatUnits(12345678901234567890123n, 6), "12345678901234567.890123", "a 20-digit amount survives intact");
eq(formatUnits(-1000000n, 6), "-1.000000", "negative");
eq(formatUnits(42n, 0), "42", "zero decimals");

/* ── decoding the real claim events ────────────────────────────────────── */

console.log("decoding Leg A's claim (rule table accepted)");

const claimA = decodeLinkClaimed(fix.claimA[0]);
ok(claimA.usedRuleSplit === true, "usedRuleSplit is true — the circuit accepted the rule table");
eq(claimA.payout, 995000n, "payout is the post-fee pool 0.995000");
eq(claimA.fee, FEE, "fee is 0.005000");
eq(claimA.txHash, "0xd645981905f6e97989285c857bd0967f20248fee7a1ffb2fc8707dfcca214c9e", "claim tx hash");
eq(claimA.blockNumber, "0x2c78427", "claim block");

const legsA = decodeLegs(fix.legsA);
eq(legsA.length, 4, "four legs: the fee plus three seats");
ok(legsA.every((l) => l.kind === "paid"), "every Leg A leg actually moved");
eq(legsA[0].recipient, DEPLOYER, "leg 1 is the fee to the fee account");
eq(legsA[0].amount, FEE, "fee leg amount 0.005000");
eq(legsA[1].recipient, PAYEE, "seat 1 is the payee");
eq(legsA[1].amount, 497500n, "payee seat 0.497500 (10 of 20 steps of the pool)");
eq(legsA[2].recipient, DEPLOYER, "seat 2 is the deployer");
eq(legsA[2].amount, 298500n, "seat 2 0.298500 (6 steps)");
eq(legsA[3].recipient, DEPLOYER, "seat 3 is the deployer");
eq(legsA[3].amount, 199000n, "seat 3 0.199000 (4 steps)");
ok(
  legsA.reduce((sum, l) => sum + l.amount, 0n) === 1000000n,
  "the four legs add up to the credited 1.000000 exactly"
);

const splitA = splitClaimLegs(legsA, claimA.fee, DEPLOYER);
ok(splitA.feeLeg === legsA[0], "the fee leg is recognised as the first leg");
eq(splitA.seatLegs.length, 3, "three seats remain after the fee");
ok(splitA.seatLegs.every((l) => l !== splitA.feeLeg), "the fee leg is not double-counted as a seat");

console.log("decoding Leg B's claim (default split fallback)");

const claimB = decodeLinkClaimed(fix.claimB[0]);
ok(claimB.usedRuleSplit === false, "usedRuleSplit is false — the default table applied");
eq(claimB.payout, 995000n, "same pool 0.995000");
eq(claimB.fee, FEE, "same fee");
eq(claimB.txHash, "0x9a661e7f0b6d26cd81cce54f27897d1392ca8a54b38825616be0c26def4c4183", "claim tx hash");

const legsB = decodeLegs(fix.legsB);
eq(legsB.length, 2, "two legs: the fee plus one seat");
eq(legsB[0].amount, FEE, "fee leg");
eq(legsB[1].recipient, PAYEE, "the whole pool to the payee");
eq(legsB[1].amount, 995000n, "payee seat 0.995000 (20 of 20 steps)");

const splitB = splitClaimLegs(legsB, claimB.fee, DEPLOYER);
ok(splitB.feeLeg === legsB[0], "fee leg recognised");
eq(splitB.seatLegs.length, 1, "one seat remains");

/* An owed leg must survive as owed, never be relabelled paid. */
const owedLog = {
  ...fix.legsB[1],
  topics: [EVT.legOwed, fix.legsB[1].topics[1], fix.legsB[1].topics[2]],
};
const legsOwed = decodeLegs([], [owedLog]);
eq(legsOwed.length, 1, "one owed leg decodes");
eq(legsOwed[0].kind, "owed", "it stays owed");
eq(legsOwed[0].amount, 995000n, "its amount is intact");

/* A mismatched fee account must not be mistaken for the fee leg — the raw
   first leg stays a seat row and nothing is relabelled. */
const noFee = splitClaimLegs(legsA, FEE, "0x0000000000000000000000000000000000000001");
ok(noFee.feeLeg === null, "a different fee account yields no fee leg");
eq(noFee.seatLegs.length, 4, "all four legs remain raw rows");

/* ── refusals ──────────────────────────────────────────────────────────── */

console.log("refusals");

const throws = (fn, label) => {
  try { fn(); failed++; console.log(`FAIL  ${label} (did not throw)`); }
  catch { passed++; console.log(`  ok  ${label}`); }
};
throws(() => decodeLinkClaimed(fix.legsA[0]), "a LegPaid log is refused by decodeLinkClaimed");
throws(() => decodeLinkClaimed({ topics: [EVT.linkClaimed], data: "0x12" }), "truncated LinkClaimed data is refused");
throws(() => decodeLegs([{ topics: [EVT.linkClaimed], data: "0x", transactionHash: "0x" }]), "a non-leg log is refused by decodeLegs");

/* ── receipt lines ─────────────────────────────────────────────────────── */

console.log("receipt lines (Leg A)");

const linesA = claimReceiptLines({
  linkId: "pago-261119-124452-a",
  description: "live test: ordinary payer path",
  credited: 1000000n,
  payer: DEPLOYER,
  claimedAtMs: 1795088764000,
  decimals: 6,
  tokenLabel: "pUSD (MOCK)",
  networkLabel: "X Layer testnet",
  claim: claimA,
  legs: legsA,
  feeAccount: DEPLOYER,
  claimTxUrl: "https://oklink.com/xlayer/tx/" + claimA.txHash,
});
const textA = linesA.map((l) => l.text || "").join("\n");
ok(linesA.every((l) => !/[^\x20-\x7e]/.test(l.text || "")), "every line is ASCII (the PDF is WinAnsi)");
ok(textA.includes(XLAYER_RECEIPT_SENTENCE), "the sentence is present");
ok(textA.includes("1.000000 pUSD (MOCK)"), "credited amount printed exactly");
ok(textA.includes("0.995000 pUSD (MOCK)"), "pool printed exactly");
ok(textA.includes("0.005000 pUSD (MOCK)"), "fee printed exactly");
ok(textA.includes("rule table"), "Leg A says the rule table was applied");
ok(!textA.includes("default split"), "Leg A does not claim the default split");
ok(textA.includes("0.497500 pUSD (MOCK)"), "the payee's real seat amount is printed");
ok(textA.includes(claimA.txHash), "the claim tx hash is printed");
ok(textA.includes("pago-261119-124452-a"), "the invoice id is printed");
ok(linesA.some((l) => l.kind === "title"), "the receipt has a title");
ok(linesA.some((l) => l.kind === "rule"), "the receipt has rules");
ok(!textA.includes("undefined") && !textA.includes("NaN"), "no undefined/NaN leaked into the receipt");

console.log("receipt lines (Leg B)");

const linesB = claimReceiptLines({
  linkId: "pago-261119-124452-b",
  description: "live test: gasless payer path",
  credited: 1000000n,
  payer: DEPLOYER,
  claimedAtMs: 1795088769000,
  decimals: 6,
  tokenLabel: "pUSD (MOCK)",
  networkLabel: "X Layer testnet",
  claim: claimB,
  legs: legsB,
  feeAccount: DEPLOYER,
  claimTxUrl: "",
});
const textB = linesB.map((l) => l.text || "").join("\n");
ok(textB.includes(XLAYER_RECEIPT_SENTENCE), "the sentence is present");
ok(textB.includes("default split"), "Leg B says the default split applied");
ok(!textB.includes("rule table (the circuit"), "Leg B does not claim the rule table");
ok(textB.includes("0.995000 pUSD (MOCK)"), "the payee's real seat amount is printed");
ok(!textB.includes("undefined") && !textB.includes("NaN"), "no undefined/NaN leaked into the receipt");

/* ── CSV export ────────────────────────────────────────────────────────── */

console.log("CSV export");

const csv = ledgerCsv(
  [
    {
      link: {
        linkId: "pago-261119-124452-a",
        amount: 1000000n,
        status: 2,
        paidBy: DEPLOYER,
        paidAt: 1795088720000n,
        description: 'a note, with "quotes" and, commas',
      },
      claim: claimA,
    },
    {
      link: {
        linkId: "pago-261119-124452-open",
        amount: 2500000n,
        status: 0,
        paidBy: "0x0000000000000000000000000000000000000000",
        paidAt: 0n,
        description: "not paid yet",
      },
      claim: null,
    },
  ],
  { tokenSymbol: "pUSD (MOCK)", decimals: 6 }
);
const rows = csv.split("\r\n");
eq(rows.length, 3, "header + two rows");
eq(
  rows[0],
  "link,amount,token,status,payer,paid at,payout,fee,split applied,claim tx,description",
  "the CSV header"
);
ok(rows[1].startsWith("pago-261119-124452-a,1.000000,pUSD (MOCK),Claimed,"), "claimed row: amount, token, status");
ok(rows[1].includes(",0.995000,0.005000,rule table," + claimA.txHash + ","), "claimed row: event facts from the chain");
ok(rows[1].includes('""quotes""'), "embedded quotes are doubled");
ok(rows[1].includes('"a note, with ""quotes"" and, commas"'), "commas force quoting");
ok(rows[2].startsWith("pago-261119-124452-open,2.500000,pUSD (MOCK),Open,,,"), "open row: empty payer/paid-at");
ok(rows[2].endsWith(",not paid yet"), "open row: claim columns stay empty, description kept");
ok(!csv.includes("undefined"), "no undefined in the CSV");

/* ──────────────────────────────────────────────────────────────────────── */

console.log(`\n${passed} passed, ${failed} failed`);
if (failed) process.exit(1);
