/* Pago on X Layer — payout evidence: Pago's claim events, decoded.
 *
 * When a link is claimed the contract emits, in one transaction:
 *
 *   LinkClaimed(linkKey, payout, fee, usedRuleSplit)  — the post-fee pool and
 *       which of the two tables fixed at creation the circuit selected;
 *   LegPaid(linkKey, recipient, amount)  — one row per amount that actually
 *       moved (the fee leg first, then the table's seats in order);
 *   LegOwed(linkKey, recipient, amount)  — only if a transfer failed: the
 *       amount stays in the contract, owed to that recipient.
 *
 * This module is pure — no network, no DOM — so the node suite can decode
 * the exact log blobs the chain returned (test/fixtures/raw-claim-logs.json,
 * captured from the 2026-11-19 live run) and assert on them. The page does
 * the fetching (xlayer.js) and hands the logs in here.
 *
 * Honesty rules, same as the rest of the app: every number printed comes
 * straight from an event or the contract's own stored link; nothing is
 * recomputed, re-split or inferred. The NEAR receipt sentence lives in
 * receipt.js and is pinned by its test — the X Layer sentence below is a
 * separate constant for a separate chain, never a reuse of the NEAR one.
 */

import { decodeReturn, STATUS } from "./abi.js";

/* Event topic0 hashes: `cast keccak "<signature>"`, then matched against the
   deployed Pago runtime (each appears as its own topic in the real claim
   logs of fixture raw-claim-logs.json). Pinned by test/payout.test.mjs. */
export const EVT = {
  linkClaimed: "0xb5b858e924331e29402dfbd0244b02fc16bfd21a9e0799474f536750377cc398",
  legPaid: "0x4ef82e18e70727bf3ad29af492a007429cee27018a072f1003552ba174791bdc",
  legOwed: "0x11a4ea12c72a399e1763204aa4fbfe38c154797d98be4bdf4b3a1cd3ea620863",
};

/* The sentence every X Layer receipt carries — deliberately not the NEAR
   sentence ("Payment delivered and verified on NEAR", pinned by
   receipt.test.mjs): there is no verifier here, only the chain's own event,
   so this one names exactly that evidence. ASCII-only: the PDF is WinAnsi. */
export const XLAYER_RECEIPT_SENTENCE = "Payment delivered and paid out on X Layer";

/* Base units -> exact fixed-point string. No floats anywhere: a 20-digit
   amount survives intact, and 995000 at 6 decimals is "0.995000". */
export function formatUnits(raw, decimals) {
  const value = typeof raw === "bigint" ? raw : BigInt(raw);
  const neg = value < 0n;
  const digits = (neg ? -value : value).toString().padStart(decimals + 1, "0");
  const whole = digits.slice(0, digits.length - decimals);
  const frac = decimals > 0 ? digits.slice(digits.length - decimals) : "";
  return `${neg ? "-" : ""}${whole}${frac ? "." + frac : ""}`;
}

/** Decode one LinkClaimed log into the claim's own facts. */
export function decodeLinkClaimed(log) {
  if (!log || !Array.isArray(log.topics) || log.topics[0] !== EVT.linkClaimed) {
    throw new TypeError("not a LinkClaimed log");
  }
  const [payout, fee, usedRuleSplit] = decodeReturn(["uint256", "uint256", "bool"], log.data);
  return { payout, fee, usedRuleSplit, txHash: log.transactionHash, blockNumber: log.blockNumber };
}

/** Decode LegPaid / LegOwed logs into legs ordered as the transaction
    emitted them (the fee leg first, then the table's seats).
    `kind` is "paid" or "owed" — an owed leg never left the contract. */
export function decodeLegs(paidLogs, owedLogs = []) {
  const read = (log) => {
    const topic = log && Array.isArray(log.topics) ? log.topics[0] : null;
    if (topic !== EVT.legPaid && topic !== EVT.legOwed) throw new TypeError("not a leg log");
    if (!/^0x[0-9a-f]{64}$/.test(log.topics[2] || "")) throw new TypeError("leg log has no recipient topic");
    const [amount] = decodeReturn(["uint256"], log.data);
    return {
      kind: topic === EVT.legOwed ? "owed" : "paid",
      recipient: "0x" + log.topics[2].slice(26).toLowerCase(),
      amount,
      txHash: log.transactionHash,
      logIndex: typeof log.logIndex === "string" ? parseInt(log.logIndex, 16) : Number(log.logIndex || 0),
    };
  };
  const legs = [...(paidLogs || []).map(read), ...(owedLogs || []).map(read)];
  /* Both event kinds share the claim transaction's log ordering, but they
     arrive from two separate RPC queries — re-merge by position. */
  legs.sort((a, b) => a.logIndex - b.logIndex);
  return legs;
}

/* Split the merged legs: the fee leg is the one the contract pays first —
   only when it exists (fee > 0), is a paid leg, and its amount and
   recipient match the claim's fee and the configured fee account. Anything
   that does not match stays a raw leg row; nothing is relabelled. */
export function splitClaimLegs(legs, fee, feeAccount) {
  const first = legs[0];
  const feeLeg =
    fee > 0n && first && first.kind === "paid" && first.amount === fee &&
    !!feeAccount && first.recipient === String(feeAccount).toLowerCase()
      ? first
      : null;
  return { feeLeg, seatLegs: feeLeg ? legs.slice(1) : legs };
}

const isoUtc = (ms) => `${new Date(Number(ms)).toISOString().replace("T", " ").slice(0, 19)} UTC`;

/* The receipt's PDF model: [{text, kind}] lines for receipt.js. Every value
   arrives already read from the chain — this function only lays it out. */
export function claimReceiptLines({
  linkId,
  description,
  credited,
  payer,
  claimedAtMs,
  decimals,
  tokenLabel,
  networkLabel,
  claim,
  legs,
  feeAccount,
  claimTxUrl,
}) {
  const { feeLeg, seatLegs } = splitClaimLegs(legs, claim.fee, feeAccount);
  const rows = [
    { text: `Network: ${networkLabel}`, kind: "row" },
    { text: `Invoice: ${linkId}`, kind: "row" },
    { text: `Description: ${description || "-"}`, kind: "row" },
    { text: `Amount credited: ${formatUnits(credited, decimals)} ${tokenLabel}`, kind: "row" },
    { text: `Payout: ${formatUnits(claim.payout, decimals)} ${tokenLabel}`, kind: "row" },
    { text: `Fee: ${formatUnits(claim.fee, decimals)} ${tokenLabel}`, kind: "row" },
    {
      text: `Split applied: ${claim.usedRuleSplit ? "rule table (the circuit accepted it)" : "default split"}`,
      kind: "row",
    },
    ...(feeLeg ? [{ text: `Fee paid to ${feeLeg.recipient}`, kind: "row" }] : []),
    ...seatLegs.map((leg, i) => ({
      text: leg.kind === "paid"
        ? `Seat ${i + 1}: ${formatUnits(leg.amount, decimals)} ${tokenLabel} -> ${leg.recipient}`
        : `Seat ${i + 1}: ${formatUnits(leg.amount, decimals)} ${tokenLabel} owed in the contract -> ${leg.recipient}`,
      kind: "row",
    })),
    { text: `Payer: ${payer}`, kind: "row" },
    { text: `Claimed: ${isoUtc(claimedAtMs)}`, kind: "row" },
  ];
  return [
    { text: "Pago payment receipt", kind: "title" },
    { text: XLAYER_RECEIPT_SENTENCE, kind: "sub" },
    { kind: "rule" },
    ...rows,
    { kind: "rule" },
    { text: "Claim transaction:", kind: "head" },
    { text: claim.txHash, kind: "small" },
    ...(claimTxUrl ? [{ text: claimTxUrl, kind: "small" }] : []),
    {
      text: "Payout, fee, split and leg amounts are read from that transaction's LinkClaimed and LegPaid events; invoice facts are read from the contract's stored link.",
      kind: "small",
    },
  ];
}

/* The ledger's CSV export: one row per link, with the claim's event facts
   filled in for claimed links and left empty for anything not yet claimed —
   never a computed stand-in. Quoting mirrors the NEAR export. */
export function ledgerCsv(rows, { tokenSymbol, decimals }) {
  const head = [
    "link", "amount", "token", "status", "payer", "paid at",
    "payout", "fee", "split applied", "claim tx", "description",
  ];
  const cell = (v) => {
    const s = String(v ?? "");
    return /[",\n]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s;
  };
  const lines = [head.join(",")];
  for (const { link, claim } of rows) {
    const paid = Number(link.paidAt) > 0;
    lines.push([
      link.linkId,
      formatUnits(link.amount, decimals),
      tokenSymbol,
      STATUS[Number(link.status)] || "Open",
      paid ? link.paidBy : "",
      paid ? new Date(Number(link.paidAt)).toISOString() : "",
      claim ? formatUnits(claim.payout, decimals) : "",
      claim ? formatUnits(claim.fee, decimals) : "",
      claim ? (claim.usedRuleSplit ? "rule table" : "default split") : "",
      claim ? claim.txHash : "",
      link.description,
    ].map(cell).join(","));
  }
  return lines.join("\r\n");
}
