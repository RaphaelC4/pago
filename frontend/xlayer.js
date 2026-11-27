/* Pago — the X Layer frontend.
   Static module: no build step, no bundler, no server of our own.

   Reads are unsigned JSON-RPC `eth_call`s against the public testnet
   endpoint, so the ledger and every pay card render with no wallet at all —
   that is what makes the read-only Playwright project possible. Writes go
   through an injected EIP-1193 wallet (MetaMask, OKX Wallet, …) over
   `window.ethereum`; nothing here ever sees a private key, and there is no
   relayer, because no relayer runs on X Layer. The payer signs `approve`
   then `pay` themselves, or signs an EIP-3009 authorization off-chain and
   submits it — the contract would accept it from any wallet
   (frontend/gasless.js; docs/RESEARCH.md §16/§22).

   Contract calls are encoded by frontend/abi.js, a hand-rolled codec: the app
   is buildless, so it cannot import ethers or web3, and what Pago needs is a
   closed set of a dozen functions. Every selector in that file was produced
   with `cast sig` and cross-checked against the deployed bytecode.

   Rules enforced here are the contract's, not this page's invention: the
   note must be 1–280 UTF-8 bytes, the amount must be above zero, expiry is
   written in *chain* time, only the creator can cancel, the payee can never
   pay their own link, and a payer must hold the tokens — plus enough OKB
   for two transactions on the approve+pay path; on the gasless path the
   payer needs no OKB at all and whoever submits it pays. A rejection the
   chain makes is surfaced, never papered over. */

import { XLAYER } from "./config.js?v=20261121b";
import {
  SEL,
  GET_LINK_TYPES,
  GET_LINKS_TYPES,
  SPLIT_TYPES,
  STATUS,
  callData,
  decodeReturn,
} from "./abi.js?v=20261121a";
import {
  EVT,
  XLAYER_RECEIPT_SENTENCE,
  formatUnits,
  decodeLinkClaimed,
  decodeLegs,
  splitClaimLegs,
  claimReceiptLines,
  ledgerCsv,
} from "./payout.js?v=20261121a";
import { buildReceiptPdf, receiptFilename } from "./receipt.js?v=20261121a";
import {
  VALID_AFTER,
  VALID_BEFORE,
  authorizationTypedData,
  encodePayWithAuthorization,
} from "./gasless.js?v=20261125a";

/* ── configuration ──────────────────────────────────────────────────────── */

/* `chainId` in the URL selects the configured network; the public default is
   testnet. Network labels and wallet requests always come from this id. */
const NETWORKS = [XLAYER.pago.testnet, XLAYER.pago.mainnet].filter(Boolean);
const requestedChainId = Number(new URLSearchParams(location.search).get("chainId"));
const NET = NETWORKS.find((entry) => entry.chainId === requestedChainId) || XLAYER.pago.testnet;
const CHAIN_ID = NET.chainId;
const CHAIN_HEX = "0x" + CHAIN_ID.toString(16);
const PAGO = NET.pago;
const NETWORK_CONFIG = CHAIN_ID === 196 ? XLAYER.mainnet : XLAYER.testnet;
const TOKEN_OPTIONS = NET.tokens || [{
  address: NET.token,
  symbol: NET.tokenSymbol,
  decimals: NET.tokenDecimals,
  isMock: NET.tokenIsMock === true,
}];
const requestedToken = new URLSearchParams(location.search).get("token");
let activeToken = TOKEN_OPTIONS.find((entry) => entry.address.toLowerCase() === String(requestedToken || "").toLowerCase()) || TOKEN_OPTIONS[0];
let TOKEN = activeToken.address;

/* Deduped: config carries the endpoint on both the pago block and the
   testnet block, and they are the same URL today. */
const RPC_URLS = [...new Set([NET.rpc, ...NETWORK_CONFIG.rpcUrls].filter(Boolean))];

let DECIMALS = activeToken.decimals ?? NET.tokenDecimals;
let MOCK = activeToken.isMock === true || (activeToken.isMock !== false && NET.tokenIsMock === true);
/* The one label every surface must use. `pUSD` alone would read as a real
   stablecoin, which this is not. */
let TOKEN_LABEL = MOCK ? `${activeToken.symbol} (MOCK)` : activeToken.symbol;
/* The label every new surface prints: the chain id decides, never a
   hard-coded string, so pointing this page at mainnet relabels it honestly. */
const NETWORK_LABEL = CHAIN_ID === 196 ? "X Layer mainnet" : "X Layer testnet";
const ENC = new TextEncoder();

function selectToken(address) {
  activeToken = TOKEN_OPTIONS.find((entry) => entry.address.toLowerCase() === String(address).toLowerCase()) || TOKEN_OPTIONS[0];
  TOKEN = activeToken.address;
  DECIMALS = activeToken.decimals ?? NET.tokenDecimals;
  MOCK = activeToken.isMock === true || (activeToken.isMock !== false && NET.tokenIsMock === true);
  TOKEN_LABEL = MOCK ? `${activeToken.symbol} (MOCK)` : activeToken.symbol;
}

/* ── tiny helpers ───────────────────────────────────────────────────────── */

const $ = (sel, root = document) => root.querySelector(sel);
const $$ = (sel, root = document) => [...root.querySelectorAll(sel)];

function toast(msg) {
  const el = $("#toast");
  el.textContent = msg;
  el.classList.add("show");
  clearTimeout(toast._t);
  toast._t = setTimeout(() => el.classList.remove("show"), 4200);
}

function esc(s) {
  return String(s ?? "").replace(/[&<>"']/g, (c) =>
    ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
}

function truncate(a, head = 8, tail = 6) {
  if (!a || a.length <= head + tail + 1) return a || "";
  return `${a.slice(0, head)}…${a.slice(-tail)}`;
}

const sameAddr = (a, b) =>
  typeof a === "string" && typeof b === "string" && a.toLowerCase() === b.toLowerCase();

const isAddress = (a) => /^0x[0-9a-fA-F]{40}$/.test(String(a || ""));

/* The zero address marks an unused split seat on the wire (abi.js
   SPLIT_TYPES: three recipients, three shares). */
const ZERO_ADDR = "0x0000000000000000000000000000000000000000";

/* base units -> human string, grouped, no float anywhere */
function fmt(raw, decimals = DECIMALS) {
  const s = BigInt(raw).toString().padStart(decimals + 1, "0");
  const whole = s.slice(0, -decimals).replace(/\B(?=(\d{3})+(?!\d))/g, ",");
  const frac = s.slice(-decimals).replace(/0+$/, "");
  return frac ? `${whole}.${frac}` : whole;
}

/* human string -> base units, refusing anything the contract would reject */
function parseAmount(human) {
  const m = String(human ?? "").trim().match(/^(\d+)(?:\.(\d*))?$/);
  if (!m) throw new Error("Enter an amount like 12 or 12.50.");
  const digits = m[2] ?? "";
  if (digits.length > DECIMALS) throw new Error(`At most ${DECIMALS} decimal places.`);
  const frac = digits.padEnd(DECIMALS, "0");
  const base = BigInt(m[1]) * 10n ** BigInt(DECIMALS) + (frac ? BigInt(frac) : 0n);
  if (base <= 0n) throw new Error("Amount must be greater than zero.");
  return base;
}

/* Mirrors `splitFee` in Pago.sol: fee rounds down, payout + fee always
   equals the credited amount. Displayed, never trusted for a transfer — the
   contract recomputes it at claim. */
function splitFee(raw) {
  const amount = BigInt(raw);
  const bps = BigInt(NET.feeBps);
  const fee = (amount / 10000n) * bps + ((amount % 10000n) * bps) / 10000n;
  return { payout: amount - fee, fee };
}

const fmtDate = (ms) =>
  Number(ms) === 0
    ? "never"
    : new Date(Number(ms)).toLocaleString(undefined, { dateStyle: "medium", timeStyle: "short" });

async function copyText(text) {
  try {
    await navigator.clipboard.writeText(text);
    return true;
  } catch {
    try {
      const ta = document.createElement("textarea");
      ta.value = text;
      ta.setAttribute("readonly", "");
      ta.style.cssText = "position:fixed;left:-9999px";
      document.body.appendChild(ta);
      ta.select();
      const ok = document.execCommand("copy");
      ta.remove();
      return ok;
    } catch { return false; }
  }
}

/* Wallet / RPC errors arrive in a dozen shapes. This is the whole
   translation layer: an EIP-1193 code, a revert string, or the raw message
   as a last resort — never a silent success. */
function friendly(err) {
  const code = err && typeof err.code === "number" ? err.code : null;
  if (code === 4001) return "Rejected in the wallet.";
  if (code === -32002) return "A request is already waiting in your wallet.";
  if (code === 4902) return "This chain is not in your wallet yet — approve adding it.";
  if (code === 4100) return "The wallet refused this account. Unlock it and try again.";
  const msg = String((err && err.message) || err || "something went wrong");
  if (/insufficient funds/i.test(msg)) return "Not enough OKB in the wallet to pay gas.";
  const revert = msg.match(/reverted(?: with reason string)?:?\s*"?([^"]{0,160})/i);
  if (revert) return `The contract refused: ${revert[1].trim() || "reverted"}.`;
  if (/failed to fetch|network|timed? ?out|aborted/i.test(msg)) {
    return "The X Layer RPC did not answer. Try again in a moment.";
  }
  return msg.slice(0, 180);
}

/* ── read client ────────────────────────────────────────────────────────── */

let rpcSeq = 0;

async function rpcOnceAt(url, method, params) {
  const ctl = new AbortController();
  const timer = setTimeout(() => ctl.abort(), 15_000);
  try {
    const res = await fetch(url, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ jsonrpc: "2.0", id: ++rpcSeq, method, params }),
      signal: ctl.signal,
    });
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    const body = await res.json();
    if (body.error) {
      /* The chain answered — that is a real answer, not a transport
         failure, so it is thrown as-is and never retried into a storm. */
      const e = new Error(body.error.message || "rpc error");
      e.rpc = true;
      e.code = body.error.code;
      throw e;
    }
    return body.result;
  } finally {
    clearTimeout(timer);
  }
}

/* Endpoint failover with a bounded retry. The testnet endpoint resolves
   intermittently (RESEARCH.md §15), so a single attempt would make the page
   look broken roughly one load in three. Reads only — a write never goes
   through here; writes go through the wallet, which signs exactly once. */
async function rpc(method, params) {
  let lastErr;
  for (let round = 0; round < 3; round++) {
    for (const url of RPC_URLS) {
      try {
        return await rpcOnceAt(url, method, params);
      } catch (err) {
        lastErr = err;
        if (err && err.rpc) throw err; // the chain answered: no point retrying
      }
    }
    if (round < 2) await new Promise((r) => setTimeout(r, 400 * (round + 1)));
  }
  throw lastErr || new Error("no RPC endpoint answered");
}

const ethCall = (to, data) => rpc("eth_call", [{ to, data }, "latest"]);

/* One JSON-RPC *batch* request: an array of calls in a single POST. The X
   Layer testnet endpoint accepts batches (verified live), and its
   eth_getLogs caps a block range at 100 — so locating a claim needs many
   cheap probes, and batching keeps that to a handful of round trips.
   Responses come back matched by id, not by position. */
async function rpcBatchOnceAt(url, calls) {
  const ctl = new AbortController();
  const timer = setTimeout(() => ctl.abort(), 20_000);
  try {
    const res = await fetch(url, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(calls.map(([method, params], i) => ({ jsonrpc: "2.0", id: i + 1, method, params }))),
      signal: ctl.signal,
    });
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    const body = await res.json();
    if (!Array.isArray(body)) throw new Error("rpc: endpoint does not accept batch arrays");
    const byId = new Map(body.map((r) => [r.id, r]));
    return calls.map((_, i) => {
      const r = byId.get(i + 1);
      if (!r) throw new Error("rpc: batch response missing an id");
      if (r.error) {
        const e = new Error(r.error.message || "rpc error");
        e.rpc = true;
        e.code = r.error.code;
        throw e;
      }
      return r.result;
    });
  } finally {
    clearTimeout(timer);
  }
}

/* Same endpoint failover as `rpc()`, for batches. If no endpoint takes the
   batch shape, fall back to one request per call — slower, never wrong. */
async function rpcBatch(calls) {
  let lastErr;
  for (let round = 0; round < 3; round++) {
    for (const url of RPC_URLS) {
      try {
        return await rpcBatchOnceAt(url, calls);
      } catch (err) {
        lastErr = err;
        if (err && err.rpc) throw err;
      }
    }
    if (round < 2) await new Promise((r) => setTimeout(r, 400 * (round + 1)));
  }
  /* No endpoint took the batch shape (unsupported, too large, or a
     transport failure) — every call is a read, so running them one by one
     through the normal failover path is slower but never wrong. A chain
     answer (`err.rpc`) already threw above: the batch was understood. */
  if (lastErr && !lastErr.rpc) {
    return Promise.all(calls.map(([method, params]) => rpc(method, params)));
  }
  throw lastErr || new Error("no RPC endpoint answered");
}

const blockTimestampMs = async (n) => {
  const b = await rpc("eth_getBlockByNumber", ["0x" + n.toString(16), false]);
  return Number(BigInt(b.timestamp)) * 1000;
};

/* First block whose timestamp is >= `targetMs` — the claim's own block,
   since `claimedAt` IS `block.timestamp * 1000` (Pago.nowMs). A linear scan
   over 46M blocks is impossible and eth_getLogs only allows 100-block
   windows, so: binary search with 10 probes per round in one batch (the
   endpoint rejects batches over 10 calls with -32014), ~8 rounds, then the
   caller queries a 100-block window around it. Returns { block, latest } —
   the head is fetched once and reused. */
async function findBlockAtOrAfter(targetMs) {
  const latest = Number(BigInt(await rpc("eth_blockNumber", [])));
  let lo = 0;
  let hi = latest; // invariant: ts(hi) >= target (the chain's head is "now")
  if ((await blockTimestampMs(hi)) < targetMs) return { block: null, latest }; // claim is in the future? no block
  while (hi - lo > 1) {
    const span = hi - lo;
    const n = Math.min(10, span);
    const probes = [];
    for (let i = 1; i <= n; i++) probes.push(lo + Math.floor((span * i) / (n + 1)));
    let stamps = await rpcBatch(probes.map((b) => ["eth_getBlockByNumber", ["0x" + b.toString(16), false]]));
    /* The endpoint answers `null` for some block numbers (flaky, seen live
       on old heights). A null must NOT read as "infinitely far in the
       future" — that drags `hi` onto an ancient wrong block and the caller
       then queries a window where the claim's events cannot be. Re-read the
       probe alone; if it still comes back empty, skip it: only a block we
       actually read may move `hi`. */
    stamps = await Promise.all(stamps.map((s, i) =>
      s && s.timestamp ? Promise.resolve(s)
        : rpc("eth_getBlockByNumber", ["0x" + probes[i].toString(16), false]).catch(() => null)));
    let hit = -1;
    for (let i = 0; i < probes.length; i++) {
      if (!stamps[i] || !stamps[i].timestamp) continue; // unknown: leave both bounds alone
      const ts = Number(BigInt(stamps[i].timestamp)) * 1000;
      if (ts >= targetMs) { hit = i; break; }
    }
    if (hit === -1) lo = probes[probes.length - 1];
    else hi = probes[hit];
  }
  return { block: hi, latest };
}

/* ── claim evidence: the LinkClaimed / LegPaid / LegOwed events ──────────
   Everything the claimed receipt and the CSV print comes from here — the
   events of the claim transaction itself, never a recomputation. The RPC's
   100-block log cap means: locate the claim block by claimedAt, then read
   a window around it. One result per link, cached for the session. */
const evidenceCache = new Map();

async function readClaimEvidence(link) {
  if (evidenceCache.has(link.linkId)) return evidenceCache.get(link.linkId);

  const key = decodeReturn(["bytes32"], await ethCall(PAGO, callData(SEL.linkKeyOf, ["string"], [link.linkId])))[0];
  const claimedAt = Number(link.claimedAt);
  if (!claimedAt) throw new Error("this link was never claimed");

  const { block, latest } = await findBlockAtOrAfter(claimedAt);
  if (block === null) throw new Error("could not locate the claim block on the chain");

  const from = Math.max(0, block - 5);
  const to = Math.min(latest, block + 94); // <= 100 blocks: the endpoint's cap
  const range = { fromBlock: "0x" + from.toString(16), toBlock: "0x" + to.toString(16) };
  const topicFor = (t) => ({ address: PAGO, topics: [t, key], ...range });

  const [claimedLogs, paidLogs, owedLogs] = await rpcBatch([
    ["eth_getLogs", [topicFor(EVT.linkClaimed)]],
    ["eth_getLogs", [topicFor(EVT.legPaid)]],
    ["eth_getLogs", [topicFor(EVT.legOwed)]],
  ]);
  if (!claimedLogs.length) throw new Error("the claim event was not found in its block window");

  const evidence = {
    claim: decodeLinkClaimed(claimedLogs[0]),
    legs: decodeLegs(paidLogs, owedLogs),
    block,
  };
  evidenceCache.set(link.linkId, evidence);
  return evidence;
}

/* Each seat carries a small portrait so people can tell the rows apart.
   Two faces per seat; the portrait in the create form is a button that
   rotates to the next one, and the choice lives in localStorage so the
   receipt on this device shows the same face. Local decoration only —
   nothing about it is written to the chain. */
const SEAT_AVATARS = [
  ["img/seat1-avatar.png", "img/seat1-avatar2.png"],
  ["img/seat2-avatar.png", "img/seat2-avatar2.png"],
  ["img/seat3-avatar.png", "img/seat3-avatar2.png"],
];
const seatAvatarKey = (seat) => `pago.seatAvatar.${seat}`;

function seatAvatarIndex(seat) {
  try {
    const pool = SEAT_AVATARS[seat - 1];
    const v = Number(localStorage.getItem(seatAvatarKey(seat)));
    return pool && Number.isInteger(v) && v >= 0 && v < pool.length ? v : 0;
  } catch {
    return 0;
  }
}

function seatAvatarSrc(seat) {
  const pool = SEAT_AVATARS[seat - 1];
  return pool ? pool[seatAvatarIndex(seat)] : "";
}

/* Repaint every portrait on the page — the create form's three and any
   receipt rows already on screen — from the stored choice. */
function paintSeatAvatars() {
  $$("[data-seat-avatar]").forEach((img) => {
    const src = seatAvatarSrc(Number(img.dataset.seatAvatar));
    if (src) img.src = src;
  });
}

function wireSeatAvatars() {
  $$(".seat-avatar-btn").forEach((btn) => {
    btn.addEventListener("click", () => {
      const seat = Number(btn.dataset.seat);
      const pool = SEAT_AVATARS[seat - 1];
      if (!pool) return;
      const next = (seatAvatarIndex(seat) + 1) % pool.length;
      try {
        localStorage.setItem(seatAvatarKey(seat), String(next));
      } catch {
        /* private mode: the rotation still shows, it just won't persist */
      }
      paintSeatAvatars();
      const img = btn.querySelector(".seat-avatar");
      if (img) {
        img.classList.remove("is-rotating");
        void img.offsetWidth; // restart the animation on a repeat tap
        img.classList.add("is-rotating");
      }
    });
  });
  paintSeatAvatars();
}

/* Render the payout result from the claim's own events: the pool, the fee,
   which table the circuit selected, one row per leg as the transaction
   emitted them, and the claim hash. Called by renderPay for Claimed links;
   the card is already on screen, so a slow RPC only delays these rows. */
async function fillClaimReceipt(link) {
  const { claim, legs } = await readClaimEvidence(link);
  const amount = $("#claimAmount");
  const summary = $("#claimSummary");
  const rows = $("#claimRows");
  const foot = $("#claimFoot");
  if (!summary || !rows || !foot) return; // navigated away mid-read

  if (amount) amount.textContent = `${formatUnits(claim.payout, DECIMALS)} ${TOKEN_LABEL}`;
  summary.textContent = `${formatUnits(claim.fee, DECIMALS)} ${TOKEN_LABEL} fee · amounts read from payout events`;

  const { feeLeg, seatLegs } = splitClaimLegs(legs, claim.fee, NET.feeAccount);
  /* One row per leg the claim emitted, in the card's own row language: the
     portrait and the seat sit in the label, the amount it paid sits in the
     value, and the address it went to rides under the seat — the full
     address stays in `title`, so no row can outgrow a 360px screen. */
  const seatRow = (leg, index) => `
    <div class="pi-row">
      <span class="pi-l rcpt-seat">
        <img class="rcpt-avatar" data-seat-avatar="${index + 1}" src="${seatAvatarSrc(index + 1)}" alt="" width="20" height="20" decoding="async">
        <span class="rcpt-seat-txt">Seat ${index + 1}${leg.kind === "owed" ? " · owed" : ""}<i>→ ${truncate(leg.recipient, 8, 6)}</i></span>
      </span>
      <span class="pi-p" title="${esc(leg.recipient)}">${formatUnits(leg.amount, DECIMALS)} ${esc(TOKEN_LABEL)}</span>
    </div>`;

  /* The event rows sit under the stored facts as their own table — only
     what the claim transaction itself said, nothing restated from the card
     above; the legs themselves, who was paid what, are one click away,
     collapsed, so the settled card still reads like the open one. */
  rows.innerHTML = `<div class="pay-items">
      <span class="pi-h">payout events</span>
      <div class="pi-row"><span class="pi-l">split applied</span><span class="pi-p">${claim.usedRuleSplit ? "Rule table" : "Default table"}</span></div>
      <div class="pi-row"><span class="pi-l">Pago fee</span><span class="pi-p">${formatUnits(claim.fee, DECIMALS)} ${esc(TOKEN_LABEL)}${feeLeg ? ` · ${truncate(feeLeg.recipient, 7, 5)}` : ""}</span></div>
    </div>
    <details class="pay-details">
      <summary>More details</summary>
      <div class="pay-items">
        ${seatLegs.map(seatRow).join("")}
        <div class="pi-row"><span class="pi-l">claim transaction</span><span class="pi-p mono"><a href="${esc(txUrl(claim.txHash))}" target="_blank" rel="noopener">${truncate(claim.txHash, 10, 6)}</a></span></div>
      </div>
    </details>`;

  foot.innerHTML = `<span class="tiny">${esc(XLAYER_RECEIPT_SENTENCE)}. Amounts are the claim transaction's events, not recomputed.</span>
    <button class="btn btn-sm" type="button" id="claimPdf"><span>Download PDF receipt</span></button>`;
  $("#claimPdf")?.addEventListener("click", () => {
    const lines = claimReceiptLines({
      linkId: link.linkId,
      description: link.description,
      credited: link.paidAmount > 0n ? link.paidAmount : link.amount,
      payer: link.paidBy,
      claimedAtMs: Number(link.claimedAt),
      decimals: DECIMALS,
      tokenLabel: TOKEN_LABEL,
      networkLabel: NETWORK_LABEL,
      claim,
      legs,
      feeAccount: NET.feeAccount,
      claimTxUrl: txUrl(claim.txHash),
    });
    const blob = new Blob([buildReceiptPdf(lines)], { type: "application/pdf" });
    const url = URL.createObjectURL(blob);
    const a = document.createElement("a");
    a.href = url;
    a.download = receiptFilename(link.linkId);
    document.body.appendChild(a);
    a.click();
    a.remove();
    setTimeout(() => URL.revokeObjectURL(url), 4000);
    toast("Receipt downloaded");
  });
}

/* ── contract reads ─────────────────────────────────────────────────────── */

async function readLink(id) {
  const data = callData(SEL.getLink, ["string"], [id]);
  const ret = await ethCall(PAGO, data);
  const [found, link] = decodeReturn(GET_LINK_TYPES, ret);
  return { found, link };
}

async function readPaymentPolicy(token) {
  const [ruleCheckData, capData] = await Promise.all([
    ethCall(PAGO, callData(SEL.evaluatorPinned, [], [])),
    ethCall(PAGO, callData(SEL.maxLinkAmountUnpinned, ["address"], [token])),
  ]);
  return {
    ruleCheckPasses: decodeReturn(["bool"], ruleCheckData)[0],
    cap: decodeReturn(["uint256"], capData)[0],
  };
}

/* One line about the circuit state, rendered the way config.js demands:
   never a bare "pinned". Mainnet's line is green and short; testnet's
   carries the required label — its check passes against the MOCK stand-in's
   own codehash, not a recorded TapeOut shell; a failed check is a warning,
   because on that network every link is capped. A check that never came
   back renders nothing: a status printed from an unanswered call would be
   a guess dressed as a fact. */
function pinLine(policy) {
  if (!policy) return "";
  if (CHAIN_ID !== 196) {
    return `<p class="ai-note">testnet pin reference is the MOCK stand-in; mainnet uses the recorded TapeOut references.</p>`;
  }
  return policy.ruleCheckPasses
    ? `<p class="ai-note ok">Circuit pinned on mainnet.</p>`
    : `<p class="ai-note warn">Circuit check did not pass — links are capped on this network.</p>`;
}

function splitRowsMarkup(split, payee) {
  return split.shares.map((rawShare, index) => {
    const share = Number(rawShare);
    const recipient = split.recipients[index];
    const destination = share === 0 ? "Unused seat" : sameAddr(recipient, payee) ? "Payee wallet" : truncate(recipient, 8, 6);
    return `<span>${share === 0 ? "Seat " + (index + 1) : `${share * 5}% · ${destination}`}</span>`;
  }).join("");
}

function paymentRulesMarkup(link, policy) {
  const cap = policy?.cap ?? BigInt(NET.unpinnedCap);
  const enforcement = policy
    ? policy.ruleCheckPasses ? "Stored · not enforced while the live rule check passes" : "Enforced now · the live rule check did not pass"
    : "Live enforcement state unavailable; payment is paused until it can be read";
  const processor = CHAIN_ID === 196 ? NET.processor : NET.processorStandIn;
  const processorLabel = CHAIN_ID === 196 ? "Processor" : "Processor (EVM stand-in, not hardware)";
  const circuitId = CHAIN_ID === 196 ? ` · circuit ${NET.circuitId}` : " · Split3 circuit";
  const testnetReferences = CHAIN_ID === 1952
    ? `<p class="rule-note">Circuit beacon (MOCK): <span class="mono">${esc(NET.circuitBeaconMock)}</span>. testnet pin reference is the MOCK stand-in; mainnet uses the recorded TapeOut references.</p>`
    : "";
  return `<section class="pay-rule-card" aria-label="Payment rule and fallback details">
    <div class="pay-rule-title"><span>Before you pay</span><span class="rule-tag">Split3 rule</span></div>
    <div class="pay-rule-row"><b>Rule table</b><div>Checks whether the three rule shares total 100% (${esc(NETWORK_LABEL)}${circuitId}).<div class="rule-share-list">${splitRowsMarkup(link.ruleSplit, link.creator)}</div><span class="rule-note">Checked by the Split3 circuit when the payment is made.</span><span class="rule-note">Netlist hash · <span class="mono">${esc(link.netlistHash)}</span></span><span class="rule-note">${processorLabel} · <span class="mono">${esc(processor || "Address unavailable")}</span></span>${testnetReferences}</div></div>
    <div class="pay-rule-row"><b>Default table</b><div><div class="rule-share-list">${splitRowsMarkup(link.defaultSplit, link.creator)}</div><span class="rule-note">Applies whenever the check does not pass.</span></div></div>
    <div class="pay-rule-row"><b>Cap</b><div><strong>${fmt(cap)} ${esc(TOKEN_LABEL)}</strong><span class="rule-note">${esc(enforcement)}</span></div></div>
    <p class="rule-fallback">If the rule check fails at payout time — or the circuit cannot be reached — this default table applies instead, so the link can never freeze.</p>
  </section>`;
}

/* A one-recipient link: both preset tables pay the whole amount to the same
   seat-1 destination and nothing at all to seats 2 and 3. Shares are twenty
   steps of 5%, so 20 is 100%. Returns that destination's address, or null
   for anything that actually splits — the pay card only changes shape when
   the money has exactly one place to go. */
function oneRecipientDestination(link) {
  const allToOne = (split) =>
    Number(split.shares[0]) === 20 &&
    Number(split.shares[1]) === 0 &&
    Number(split.shares[2]) === 0 &&
    sameAddr(split.recipients[1], ZERO_ADDR) &&
    sameAddr(split.recipients[2], ZERO_ADDR) &&
    !sameAddr(split.recipients[0], ZERO_ADDR);
  if (!allToOne(link.ruleSplit) || !allToOne(link.defaultSplit)) return null;
  return sameAddr(link.ruleSplit.recipients[0], link.defaultSplit.recipients[0])
    ? link.defaultSplit.recipients[0]
    : null;
}

async function readLedger(creator) {
  const data = callData(SEL.getLinksByCreator, ["address"], [creator]);
  const ret = await ethCall(PAGO, data);
  const [links] = decodeReturn(GET_LINKS_TYPES, ret);
  return links;
}

async function readUint(to, selector, types = [], values = []) {
  const ret = await ethCall(to, callData(selector, types, values));
  return decodeReturn(["uint256"], ret)[0];
}

const readFeeBps = () => readUint(PAGO, SEL.feeBps);
const readChainNow = () => readUint(PAGO, SEL.nowMs).then((v) => Number(v));
const readAllowance = (owner) => readUint(TOKEN, SEL.allowance, ["address", "address"], [owner, PAGO]);
const readBalance = (owner) => readUint(TOKEN, SEL.balanceOf, ["address"], [owner]);
const readLinkExists = (id) =>
  ethCall(PAGO, callData(SEL.linkExists, ["string"], [id])).then(
    (r) => decodeReturn(["bool"], r)[0]
  );

/* The payer's consent hash (contract rule 4): everything the payment is
   bound to, read from the chain immediately before the pay transaction is
   signed — never computed in the browser, never carried over from an
   earlier visit. Both pay paths require it as their last argument. */
const readTermsHash = (id) =>
  ethCall(PAGO, callData(SEL.termsHash, ["string"], [id])).then(
    (r) => decodeReturn(["bytes32"], r)[0]
  );

/* The three chain reads the gasless path needs — all unsigned eth_calls,
   like everything above: the token's own `name()` (it *is* the EIP-712
   domain binding, so a wrong name makes every signature invalid), the link
   key the nonce derives from, and the payer's current authorization nonce
   for that pair. Nothing is computed in the browser. */
const readTokenName = () =>
  ethCall(TOKEN, callData(SEL.name, [], [])).then((r) => decodeReturn(["string"], r)[0]);
const readLinkKeyOf = (id) =>
  ethCall(PAGO, callData(SEL.linkKeyOf, ["string"], [id])).then(
    (r) => decodeReturn(["bytes32"], r)[0]
  );
const readAuthorizationNonce = (key, from) =>
  ethCall(PAGO, callData(SEL.authorizationNonce, ["bytes32", "address"], [key, from])).then(
    (r) => decodeReturn(["bytes32"], r)[0]
  );

/* ── wallet (EIP-1193) ──────────────────────────────────────────────────── */

let account = null; // connected address, checksum as the wallet reports it
let walletChain = null; // chain id the wallet is on, as a number

/* The payer's signed-but-unsubmitted authorization: { linkId, from, value,
   nonce, termsHash, signature }. It lives only in this tab's memory and is
   bound to the account that signed it — renderPay drops it for any other
   link or account, accountsChanged drops it outright, and a successful
   submit drops it. */
let gaslessDraft = null;

const hasWallet = () => typeof window !== "undefined" && !!window.ethereum;

function paintWallet() {
  const label = $("#walletLabel");
  const field = $("#payToField");
  const addr = $("#payToAddr");
  const badge = $("#payToBadge");
  const heroBtn = $("#heroConnect");

  /* The header button never prints the address — only the state: "Connect"
     when a wallet is installed, "No wallet" when there is none, and
     "Connected" once an account is in. Same for the hero button. */
  if (label) label.textContent = account ? "Connected" : hasWallet() ? "Connect" : "No wallet";
  if (heroBtn) heroBtn.querySelector("span").textContent = account ? "Connected" : "Connect wallet";

  if (field && addr) {
    if (account) {
      field.classList.remove("empty");
      addr.textContent = account;
      addr.title = account;
      if (badge) badge.hidden = false;
    } else {
      field.classList.add("empty");
      addr.textContent = "connect a wallet";
      addr.removeAttribute("title");
      if (badge) badge.hidden = true;
    }
  }
}

function paintNet(state, note) {
  const dot = $("#netDot");
  const label = $("#netLabel");
  if (dot) {
    dot.classList.toggle("ok", state === "ok");
    dot.classList.toggle("err", state === "err");
  }
  if (label) label.textContent = note || NETWORK_LABEL;
}

/* Ask the wallet to be on chain 1952, adding the network if it has never
   heard of it. Returns true when the wallet ends up on the right chain. */
async function ensureChain() {
  if (!hasWallet()) return false;
  const eth = window.ethereum;
  try {
    const id = await eth.request({ method: "eth_chainId" });
    walletChain = parseInt(id, 16);
    if (walletChain === CHAIN_ID) return true;
  } catch { /* fall through to the switch below */ }

  try {
    await eth.request({
      method: "wallet_switchEthereumChain",
      params: [{ chainId: CHAIN_HEX }],
    });
    walletChain = CHAIN_ID;
    return true;
  } catch (err) {
    if (err && err.code === 4902) {
      try {
        await eth.request({
          method: "wallet_addEthereumChain",
          params: [{
            chainId: CHAIN_HEX,
            chainName: NETWORK_LABEL,
            nativeCurrency: NETWORK_CONFIG.nativeCurrency,
            rpcUrls: RPC_URLS,
            blockExplorerUrls: [NET.explorer],
          }],
        });
        walletChain = CHAIN_ID;
        return true;
      } catch (err2) {
        toast(friendly(err2));
        return false;
      }
    }
    toast(friendly(err));
    return false;
  }
}

async function connect() {
  if (!hasWallet()) {
    toast("No wallet detected. Install an EIP-1193 wallet (MetaMask, OKX Wallet) to sign.");
    paintWallet();
    return false;
  }
  try {
    const accounts = await window.ethereum.request({ method: "eth_requestAccounts" });
    account = accounts && accounts[0] ? accounts[0] : null;
    paintWallet();
    if (!account) return false;
    if (!(await ensureChain())) return false;
    paintWallet();
    return true;
  } catch (err) {
    toast(friendly(err));
    return false;
  }
}

/* Silent: only picks up an account the user has already authorised. Never
   prompts, so the page can boot without a wallet pop-up. */
async function silentConnect() {
  if (!hasWallet()) return;
  try {
    const accounts = await window.ethereum.request({ method: "eth_accounts" });
    if (accounts && accounts[0]) account = accounts[0];
    const id = await window.ethereum.request({ method: "eth_chainId" });
    walletChain = parseInt(id, 16);
  } catch { /* a locked wallet answers nothing; that is fine */ }
  paintWallet();
}

function wireWalletEvents() {
  if (!hasWallet()) return;
  window.ethereum.on?.("accountsChanged", (accounts) => {
    account = accounts && accounts[0] ? accounts[0] : null;
    gaslessDraft = null; // a signature belongs to the account that made it
    paintWallet();
    if (currentPanel === "ledger") loadLedger();
  });
  window.ethereum.on?.("chainChanged", (id) => {
    walletChain = parseInt(id, 16);
    if (walletChain !== CHAIN_ID) {
      toast(`Wallet is on chain ${walletChain}, not ${NETWORK_LABEL} (${CHAIN_ID}).`);
    }
  });
}

/* ── writes ─────────────────────────────────────────────────────────────── */

async function waitReceipt(hash) {
  for (let i = 0; i < 60; i++) {
    try {
      const r = await rpc("eth_getTransactionReceipt", [hash]);
      if (r) {
        if (r.status === "0x0") throw new Error("the transaction reverted on chain");
        return r;
      }
    } catch (err) {
      if (String(err.message).includes("reverted")) throw err;
      /* receipt not indexed yet — keep polling */
    }
    await new Promise((r) => setTimeout(r, 1_500));
  }
  throw new Error(`Transaction ${truncate(hash)} was sent but not mined in 90s. Check the explorer.`);
}

/* One signed transaction, then its receipt. `data` is always a Pago or token
   call encoded by abi.js; `value` stays undefined because every function on
   this path is non-payable — Pago takes no native coin, ever. */
async function sendTx(to, data) {
  if (!account) throw new Error("Connect a wallet first.");
  if (!(await ensureChain())) throw new Error(`Switch the wallet to ${NETWORK_LABEL} and try again.`);
  const from = account;
  const hash = await window.ethereum.request({
    method: "eth_sendTransaction",
    params: [{ from, to, data }],
  });
  return { hash, receipt: await waitReceipt(hash) };
}

/* ── routing / panels ───────────────────────────────────────────────────── */

const TABS = ["home", "create", "ledger"];
let currentPanel = "home";
let ledgerLoaded = false;
let pendingLinkId = null; // the invoice currently rendered in #panel-ready
let pendingTxHash = null; // the create transaction for that invoice

/* One module serves both documents: the site (pago-onboarding.html) carries
   home/create/ledger/ready, this page carries only the payment card.
   `hasPanel` tells the two apart; `siteUrl` builds the way across. */
const hasPanel = (name) => !!document.querySelector(`[data-panel="${name}"]`);
const siteUrl = (hash = "") => {
  const u = new URL("pago-onboarding.html", location.href);
  /* Carry the query: `new URL("path", base)` replaces the base's search, so
     without this every in-site hop silently drops ?chainId (and ?token) and
     the reader lands back on the default network. */
  u.search = location.search;
  if (hash) u.hash = hash;
  return u.href;
};

function showPanel(name) {
  currentPanel = name;
  $$("[data-panel]").forEach((p) => { p.hidden = p.dataset.panel !== name; });
  /* The site's header actions are links, not tabs: they take the current
     marker instead of aria-selected, which belongs to a real tablist. */
  $$("[data-tab]").forEach((b) => {
    const on = b.dataset.tab === name;
    b.classList.toggle("on", on);
    if (on) b.setAttribute("aria-current", "page");
    else b.removeAttribute("aria-current");
  });
  if (name === "ledger" && !ledgerLoaded) loadLedger();
}

function go(name, { push = true } = {}) {
  /* A view this document does not own — "Back home" from the payment card —
     leaves for the site instead of blanking every panel here. */
  if (!hasPanel(name)) { location.href = siteUrl(name); return; }
  if (push && location.hash.slice(1) !== name) location.hash = name;
  showPanel(name);
  window.scrollTo({ top: 0, behavior: "auto" });
}

function openPay(id) {
  /* "Open pay page" is pressed on the site's share card, where no payment
     panel exists — cross straight over instead of rewriting the hash. */
  if (!hasPanel("pay")) { location.href = payUrlFor(id); return; }
  if (location.hash.slice(1) !== `pay/${id}`) location.hash = `pay/${id}`;
  else {
    showPanel("pay");
    renderPay(id);
  }
}

/* The creation transaction hash only exists in this navigation, so it is
   parked before the hash change: `route()` cannot know it, and the share
   card would otherwise lose the "created in 0x…" line on a back/forward. */
function openReady(id, txHash) {
  pendingLinkId = id;
  pendingTxHash = txHash || null;
  if (location.hash.slice(1) !== `ready/${id}`) location.hash = `ready/${id}`;
  else {
    showPanel("ready");
    renderReady(id, pendingTxHash);
  }
}

function route() {
  const h = decodeURIComponent(location.hash.slice(1));

  if (h.startsWith("pay/")) {
    /* The share card lives on the site; the payment card lives here. A share
       link opened on the site has no pay panel, so it crosses to the app —
       siteUrl() would only rewrite the hash onto this same document, where
       nothing owns it. */
    if (!hasPanel("pay")) { location.replace(payUrlFor(h.slice(4))); return; }
    const id = h.slice(4);
    showPanel("pay");
    window.scrollTo({ top: 0, behavior: "auto" });
    renderPay(id);
    return;
  }
  if (h.startsWith("ready/")) {
    if (!hasPanel("ready")) { location.replace(siteUrl(h)); return; }
    const id = h.slice(6);
    showPanel("ready");
    window.scrollTo({ top: 0, behavior: "auto" });
    renderReady(id, id === pendingLinkId ? pendingTxHash : null);
    return;
  }
  if (TABS.includes(h)) {
    /* #create and #ledger used to be tabs here; they are pages on the site
       now, so a hash left over from the old layout follows them there. */
    if (!hasPanel(h)) { location.replace(siteUrl(h)); return; }
    showPanel(h);
    window.scrollTo({ top: 0, behavior: "auto" });
    return;
  }
  /* #why, #proof and the bare hash belong to the site: show the landing and
     leave the scrolling to the browser. This page has no landing panel, so
     anything else falls through to the site — a bare visit lands there. */
  if (hasPanel("home")) { showPanel("home"); return; }
  location.replace(siteUrl(h));
}

/* ── shared markup bits ─────────────────────────────────────────────────── */

const pillClass = (status) => `pill ${String(status).toLowerCase()}`;
const statusName = (link) => STATUS[Number(link.status)] || "Open";

/* Payment links always open on this page's payment card, whichever document
   they were created or copied from — the site links back here. */
const payUrlFor = (id) => {
  const u = new URL("xlayer.html", location.href);
  /* The shared link must name the network it was created on: copy, QR and
     navigator.share all take this URL, and without the query a mainnet
     payment link opens on the default testnet and reports "no link with that
     id". */
  u.search = location.search;
  u.hash = `pay/${encodeURIComponent(id)}`;
  return u.href;
};

const txUrl = (hash) => (hash ? `${NET.explorer}/tx/${hash}` : "");

function qrMarkup(text) {
  if (typeof window.qrcode !== "function") return "";
  try {
    const qr = window.qrcode(0, "M");
    qr.addData(text);
    qr.make();
    return qr.createSvgTag({ cellSize: 4, margin: 0, scalable: true });
  } catch { return ""; }
}

function txLine(el, state, html) {
  if (!el) return;
  el.hidden = false;
  el.className = `tx-line ${state}`;
  el.innerHTML = html;
}

/* ── create ─────────────────────────────────────────────────────────────── */

/* Same shape as the runbook's ids (pago-261118-002651-a) so a link created
   in the browser is indistinguishable from one created by the script, and
   uniqueness is still checked against the chain before it is signed. */
async function newLinkId() {
  const now = new Date();
  const pad = (n, w = 2) => String(n).padStart(w, "0");
  const stamp =
    pad(now.getFullYear() % 100) + pad(now.getMonth() + 1) + pad(now.getDate()) +
    "-" + pad(now.getHours()) + pad(now.getMinutes()) + pad(now.getSeconds());
  const alphabet = "abcdefghijkmnpqrstuvwxyz";
  for (let attempt = 0; attempt < 6; attempt++) {
    const buf = new Uint8Array(2);
    crypto.getRandomValues(buf);
    const suffix = Array.from(buf, (b) => alphabet[b % alphabet.length]).join("");
    const id = `pago-${stamp}-${suffix}`;
    if (id.length >= 4 && id.length <= 64 && !(await readLinkExists(id))) return id;
  }
  throw new Error("Could not get a free link id — try again in a second.");
}

/* Percentages from the one visible table, converted to the contract's
   units — the same math this form always used: 5% per step, 20 steps =
   100% (SPLIT_STEPS in abi.js). A blank recipient is the connected
   wallet; a 0% seat must be empty. The total has to be exactly 100% —
   the live total on the form gates the Create button, and this is the
   same check again at submit time. */
function readSplitInputs(tableName, creator) {
  const seats = $$(`[data-split-table="${tableName}"] .split-seat`);
  const recipients = [];
  const shares = [];
  for (const [index, seat] of seats.entries()) {
    const addressInput = $(".split-address", seat);
    const shareInput = $(".split-share", seat);
    const address = addressInput.value.trim();
    const percent = Number(shareInput.value);
    if (!Number.isInteger(percent) || percent < 0 || percent > Number(shareInput.max) || percent % 5 !== 0) {
      throw new Error(`Seat ${index + 1}: shares move in 5% steps, up to 100%.`);
    }
    const step = percent / 5;
    if (step === 0) {
      if (address) throw new Error(`Seat ${index + 1} has an address but 0% — add a share or clear the address.`);
      recipients.push(ZERO_ADDR);
    } else {
      const recipient = address || creator;
      if (!isAddress(recipient)) throw new Error(`Seat ${index + 1}: enter a valid wallet address, or leave it blank for your own.`);
      recipients.push(recipient);
    }
    shares.push(step);
  }
  if (shares.reduce((sum, share) => sum + share, 0) !== 20) {
    throw new Error("Shares must add up to exactly 100%.");
  }
  return [recipients, shares];
}

/* The note's friendly error lives under the field, not in the status
   line: exact copy for the empty case, and the field takes focus so a
   keyboard user lands on what needs fixing. */
function setNoteError(message) {
  const input = $("#description");
  const errorEl = $("#noteError");
  if (errorEl) {
    errorEl.textContent = message;
    errorEl.hidden = false;
  }
  if (input) {
    input.setAttribute("aria-invalid", "true");
    input.focus();
  }
}

/* The split is optional and off by default. While it is on, the live
   total has to read exactly 100% before Create link is enabled — the
   same 5%-per-step, 20-steps-to-100% unit readSplitInputs submits. */
function updateCreateGate() {
  const btn = $("#createBtn");
  const toggle = $("#splitToggle");
  const editor = $("#splitEditor");
  if (!toggle || !editor) {
    if (btn) btn.disabled = false;
    return;
  }
  const on = toggle.checked;
  editor.hidden = !on;
  let total = 0;
  if (on) {
    for (const input of $$("#splitEditor .split-share")) total += Number(input.value) || 0;
  }
  const totalEl = $("#splitTotal");
  if (totalEl) {
    totalEl.textContent = `${total}%`;
    totalEl.classList.toggle("ok", on && total === 100);
  }
  const err = $("#splitTotalErr");
  if (err) err.hidden = !on || total === 100;
  if (btn) btn.disabled = on && total !== 100;
}

function wireCreateForm() {
  const toggle = $("#splitToggle");
  if (!toggle) return;
  toggle.addEventListener("change", updateCreateGate);
  $$("#splitEditor .split-share, #splitEditor .split-address").forEach((input) =>
    input.addEventListener("input", updateCreateGate)
  );
  const noteEl = $("#description");
  const noteError = $("#noteError");
  noteEl?.addEventListener("input", () => {
    if (noteError) noteError.hidden = true;
    noteEl.removeAttribute("aria-invalid");
  });
  updateCreateGate();
}

async function onCreate(e) {
  e.preventDefault();
  const btn = $("#createBtn");
  const result = $("#createResult");

  let amount;
  const noteEl = $("#description");
  const note = noteEl.value.trim();
  try {
    amount = parseAmount($("#amount").value);
  } catch (err) {
    txLine(result, "err", esc(err.message));
    return;
  }
  /* The note is the one field with an inline friendly error. Blank gets
     the exact words a first-time user needs; the byte ceiling (the
     contract counts UTF-8 bytes, 1–280) gets a plain version of it —
     maxlength already stops most notes before they reach either. */
  if (!note) {
    setNoteError("Add a short note, for example Brand identity.");
    return;
  }
  if (ENC.encode(note).length > 280) {
    setNoteError("Keep the note to 280 characters or fewer.");
    return;
  }
  $("#noteError")?.setAttribute("hidden", "");
  noteEl.removeAttribute("aria-invalid");

  if (!account && !(await connect())) {
    txLine(result, "err", "Connect a wallet to create a link — it has to be signed by someone.");
    return;
  }

  /* Where the money goes. Toggle off (the default): both tables send
     everything to the creator — seat 1 is the creator at 100%, seats 2
     and 3 are zero. Toggle on: the rule table is what the user just
     entered (it must total 100%), and the fallback table still sends
     everything to the creator, so a failed check never loses the money.
     Nothing is ever pre-filled in the rows. */
  const creatorSplit = [[account, ZERO_ADDR, ZERO_ADDR], [20, 0, 0]];
  const defaultSplit = creatorSplit;
  let ruleSplit = creatorSplit;
  if ($("#splitToggle")?.checked) {
    try {
      ruleSplit = readSplitInputs("rule", account);
    } catch (err) {
      txLine(result, "err", esc(err.message));
      return;
    }
  }

  btn.disabled = true;
  const label = btn.querySelector("span");
  const labelWas = label.textContent;
  label.textContent = "Signing…";
  txLine(result, "pending", "Reading the chain for a free link id…");

  try {
    const hours = Number($("#expires").value) || 0;
    /* Expiry is written in chain time: `expiresAt > nowMs()` on chain, so a
       browser clock that runs fast cannot mint a link that is already dead. */
    const expiresAt = hours === 0 ? 0 : (await readChainNow()) + hours * 3_600_000;
    const linkId = await newLinkId();

    txLine(result, "pending", `Creating <code>${esc(linkId)}</code> — confirm in your wallet…`);
    const data = callData(
      SEL.createLink,
      ["string", "uint256", "address", "string", "uint64", SPLIT_TYPES, SPLIT_TYPES],
      [linkId, amount, TOKEN, note, BigInt(expiresAt), defaultSplit, ruleSplit]
    );
    const { hash } = await sendTx(PAGO, data);

    txLine(result, "ok",
      `Link created. <a href="${txUrl(hash)}" target="_blank" rel="noopener">View transaction</a>`);
    $("#createForm").reset();
    $("#noteError")?.setAttribute("hidden", "");
    updateCreateGate();
    openReady(linkId, hash);
  } catch (err) {
    txLine(result, "err", esc(friendly(err)));
  } finally {
    label.textContent = labelWas;
    updateCreateGate();
  }
}

/* ── ready / share ──────────────────────────────────────────────────────── */

async function renderReady(id, txHash) {
  const card = $("#readyCard");
  let link;
  try {
    const res = await readLink(id);
    if (!res.found) throw new Error("the chain has no link with that id");
    link = res.link;
  } catch (err) {
    card.innerHTML =
      `<div class="empty-line">Could not read the chain: ${esc(friendly(err))}
       <div class="cancel-row"><button class="btn ghost" type="button" id="readyRetry"><span>Try again</span></button></div></div>`;
    $("#readyRetry")?.addEventListener("click", () => renderReady(id, txHash));
    return;
  }

  const url = payUrlFor(id);
  const { payout } = splitFee(link.amount);
  const qr = qrMarkup(url);

  card.innerHTML = `
    <div class="ready-top">
      <div class="ready-title">${esc(link.description)}
        <span>${fmt(link.amount)} ${esc(TOKEN_LABEL)} &middot; ${esc(statusName(link))}</span>
      </div>
      <span class="${pillClass(statusName(link))}">${esc(statusName(link))}</span>
    </div>

    <div class="share-grid">
      <div class="share-main">
        <div class="share-url">
          <code title="${esc(url)}">${esc(url)}</code>
          <button class="copy" type="button" id="copyLink" aria-label="Copy payment link">Copy</button>
        </div>

        <div class="share-btns">
          <button class="share-btn" type="button" id="shareNative">
            <svg viewBox="0 0 16 16" width="13" height="13" aria-hidden="true"><use href="#coin-share"/></svg>
            <span>Share…</span>
          </button>
          <button class="share-btn" type="button" id="openPay">
            <svg viewBox="0 0 16 16" width="13" height="13" aria-hidden="true"><path d="M6 3H3.5A1.5 1.5 0 0 0 2 4.5v7A1.5 1.5 0 0 0 3.5 13h7a1.5 1.5 0 0 0 1.5-1.5V10M9.5 2H14v4.5M14 2 7.5 8.5" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round"/></svg>
            <span>Open pay page</span>
          </button>
        </div>

        <div class="detail-grid">
          <div><span class="net-k">amount</span><span class="net-v">${fmt(link.amount)} ${esc(TOKEN_LABEL)}</span></div>
          <div><span class="net-k">you receive</span><span class="net-v">${fmt(payout)} ${esc(TOKEN_LABEL)}</span></div>
          <div><span class="net-k">fee</span><span class="net-v">${NET.feeBps / 100}%</span></div>
          <div><span class="net-k">link id</span><span class="net-v mono">${esc(link.linkId)}</span></div>
          <div><span class="net-k">expires</span><span class="net-v">${esc(fmtDate(link.expiresAt))}</span></div>
          <div><span class="net-k">network</span><span class="net-v">${NETWORK_LABEL} (${CHAIN_ID})</span></div>
        </div>

        ${txHash ? `<p class="tiny" style="margin-top:1rem">Created in
          <a href="${txUrl(txHash)}" target="_blank" rel="noopener">${truncate(txHash, 12, 8)}</a>
          &middot; paid to <span class="mono">${truncate(link.creator, 10, 6)}</span></p>` : ""}
      </div>

      ${qr ? `<div class="qr-col">
        <div class="qr-tile" role="img" aria-label="QR code for this payment link">${qr}</div>
        <p class="qr-cap">Scan to open the payment page on any phone.</p>
      </div>` : ""}
    </div>

    <div class="ready-actions">
      <button class="btn" type="button" id="readyCreateAnother"><span>Create another</span></button>
      <button class="btn ghost" type="button" id="readyLedger"><span>My links</span></button>
    </div>`;

  const copyBtn = $("#copyLink");
  copyBtn?.addEventListener("click", async () => {
    const ok = await copyText(url);
    copyBtn.classList.toggle("done", ok);
    copyBtn.textContent = ok ? "Copied" : "Copy";
    toast(ok ? "Link copied." : "Copy failed — select the address and copy it manually.");
    setTimeout(() => {
      copyBtn.classList.remove("done");
      copyBtn.textContent = "Copy";
    }, 2200);
  });

  $("#shareNative")?.addEventListener("click", async () => {
    if (navigator.share) {
      try {
        await navigator.share({ title: "Pago payment request", text: `${fmt(link.amount)} ${TOKEN_LABEL} — ${link.description}`, url });
      } catch { /* the user closed the sheet */ }
    } else {
      toast(await copyText(url) ? "Link copied — your browser has no share sheet." : "Copy failed.");
    }
  });

  $("#openPay")?.addEventListener("click", () => openPay(id));
  $("#readyCreateAnother")?.addEventListener("click", () => go("create"));
  $("#readyLedger")?.addEventListener("click", () => go("ledger"));
}

/* ── pay ────────────────────────────────────────────────────────────────── */

async function renderPay(id) {
  const card = $("#payCard");
  const status = $("#payStatus");
  status.hidden = true;

  /* A gasless draft belongs to exactly one invoice and one signing
     account: rendering any other combination drops it rather than showing
     a signature that no longer matches what is on screen. */
  if (gaslessDraft && (gaslessDraft.linkId !== id || !sameAddr(gaslessDraft.from, account))) {
    gaslessDraft = null;
  }

  let res;
  try {
    res = await readLink(id);
  } catch (err) {
    card.innerHTML =
      `<span class="eyebrow">payment request</span>
       <div class="empty-line">The chain did not answer: ${esc(friendly(err))}
         <div class="cancel-row"><button class="btn ghost" type="button" id="payRetry"><span>Try again</span></button></div>
       </div>`;
    $("#payRetry")?.addEventListener("click", () => renderPay(id));
    return;
  }

  if (!res.found) {
    card.innerHTML =
      `<span class="eyebrow">payment request</span>
       <div class="empty-line">No link with the id <code>${esc(id)}</code> on ${esc(NETWORK_LABEL)}.
         <div class="cancel-row"><button class="btn ghost" type="button" data-go="home"><span>Back home</span></button></div>
       </div>`;
    return;
  }

  const link = res.link;
  const linkToken = TOKEN_OPTIONS.find((entry) => entry.address.toLowerCase() === link.token.toLowerCase());
  if (linkToken) {
    selectToken(linkToken.address);
    paintStatic();
  }
  const statusNameNow = statusName(link);
  const { payout, fee } = splitFee(link.paidAmount > 0n ? link.paidAmount : link.amount);
  const isCreator = sameAddr(account, link.creator);
  let paymentPolicy = null;
  if (statusNameNow === "Open") {
    try { paymentPolicy = await readPaymentPolicy(link.token); }
    catch { /* keep the configured cap visible; paying stays paused until live state reads */ }
  }
  const paymentRules = statusNameNow === "Open" ? paymentRulesMarkup(link, paymentPolicy) : "";
  /* One-recipient links lead with one plain sentence and move the full
     detail into "Payment details" — collapsed by default, one click away,
     and always present before the pay button (handoff §7: the details may
     be collapsed for these links, but never removed). Multi-recipient
     links keep the rule card exactly as it renders above. */
  const payeeDestination = statusNameNow === "Open" ? oneRecipientDestination(link) : null;
  const prelude = payeeDestination
    ? `<div class="pay-nosplit">
         <p class="pay-nosplit-line">No split. The full amount, minus the ${NET.feeBps / 100}% fee, goes to <span class="mono pay-nosplit-addr" title="${esc(payeeDestination)}">${esc(payeeDestination)}</span>.</p>
         <p class="pay-nosplit-sub">The rule check can't change where this money goes. If the circuit fails at payout time, this same default table pays out — the money never gets stuck.</p>
       </div>`
    : "";
  const details = payeeDestination
    ? `<details class="pay-details"><summary>Payment details</summary>${paymentRules}</details>`
    : paymentRules;

  /* ── facts every state shares ── */
  /* A claimed link prints no computed pool here: the rule table may have
     paid the payee a seat rather than the pool, so a figure this page
     derived would either contradict the claim events or repeat them. The
     pool is read back from the claim and printed once, in the payout
     result — the event's own number, not this page's arithmetic. */
  const isClaimed = statusNameNow === "Claimed";
  /* Every state renders the same card: the payee row, the status pill, the
     amount, the "for" line and this invoice table. A settled link is the
     same invoice, only paid — the payout result below replaces the pay
     button, not the card (xlayer.html styles the .pay-result block). */
  const facts = `
    <div class="pay-items">
      <span class="pi-h">invoice</span>
      <div class="pi-row"><span class="pi-l">amount</span><span class="pi-p">${fmt(link.amount)} ${esc(TOKEN_LABEL)}</span></div>
      ${isClaimed ? "" : `<div class="pi-row"><span class="pi-l">payee receives</span><span class="pi-p">${fmt(payout)} ${esc(TOKEN_LABEL)}</span></div>`}
      <div class="pi-row"><span class="pi-l">fee (${NET.feeBps / 100}%)</span><span class="pi-p">${fmt(fee)} ${esc(TOKEN_LABEL)}</span></div>
      <div class="pi-row"><span class="pi-l">link id</span><span class="pi-p mono">${esc(link.linkId)}</span></div>
      <div class="pi-row"><span class="pi-l">created</span><span class="pi-p">${esc(fmtDate(link.createdAt))}</span></div>
      <div class="pi-row"><span class="pi-l">expires</span><span class="pi-p">${esc(fmtDate(link.expiresAt))}</span></div>
      ${Number(link.paidAt) > 0 ? `<div class="pi-row"><span class="pi-l">paid</span><span class="pi-p">${esc(fmtDate(link.paidAt))}</span></div>` : ""}
      ${Number(link.claimedAt) > 0 ? `<div class="pi-row"><span class="pi-l">claimed</span><span class="pi-p">${esc(fmtDate(link.claimedAt))}</span></div>` : ""}
    </div>
    <p class="tiny" id="payFinality" style="margin-top:1rem">Links are final once claimed &mdash; there are no refunds.</p>
    <div id="payPinLine" style="margin-top:.6rem">${pinLine(paymentPolicy)}</div>`;

  /* Nobody is owed anything on a settled invoice, so the line under the
     payee says what the link is now instead of repeating the open card's
     promise. */
  const whoLine = isCreator
    ? "this is your invoice"
    : isClaimed ? "this invoice is settled" : "is owed money";

  /* The card is the card in every state: the payee row, the status pill
     (the contract's own word for the state), the amount, the "for" line and
     the invoice table render for a settled link too — a claimed invoice is
     the same invoice, only paid. What changes is what sits underneath: the
     payout result takes the pay button's place. */
  const head = `
    <div class="pay-card-bar">
      <a class="pay-iconbtn" href="#home" aria-label="Back to Pago home"><svg viewBox="0 0 24 24" aria-hidden="true"><path d="m14.5 5-7 7 7 7"/></svg></a>
      <strong>${isClaimed ? "Transfer" : "Payment request"}</strong>
      <button class="pay-iconbtn" type="button" id="payCardShare" aria-label="Share payment request"><svg viewBox="0 0 24 24" aria-hidden="true"><circle cx="18" cy="5" r="2.4"/><circle cx="6" cy="12" r="2.4"/><circle cx="18" cy="19" r="2.4"/><path d="m8.1 10.9 7.8-4.7M8.1 13.1l7.8 4.7"/></svg></button>
    </div>
    <div class="pay-top">
      <div class="pay-who">
        <span class="pay-avatar" aria-hidden="true"><svg class="coin"><use href="#coin-stable"/></svg></span>
        <div class="pay-who-txt">
          <strong title="${esc(link.creator)}">${truncate(link.creator, 10, 6)}</strong>
          <span>${whoLine}</span>
        </div>
      </div>
      <span class="${pillClass(statusNameNow)}">${esc(statusNameNow)}</span>
    </div>

    <div class="pay-amount">
      <div class="pay-usd">${fmt(link.amount)}<span class="approx">${esc(TOKEN_LABEL)}</span></div>
      <div class="pay-token">
        <svg class="coin" aria-hidden="true"><use href="#coin-stable"/></svg>
        <span>${esc(TOKEN_LABEL)}</span>
        <span class="pay-net">${NETWORK_LABEL}</span>
      </div>
    </div>

    <div class="pay-desc"><b>for</b>${esc(link.description)}</div>`;

  card.innerHTML = `${head}${prelude}${facts}${details}
    <div class="pay-actions" id="payActions"></div>
    <p class="wallet-note" id="payNote"></p>`;

  $("#payCardShare")?.addEventListener("click", async () => {
    const url = payUrlFor(id);
    if (navigator.share) {
      try { await navigator.share({ title: "Pago payment request", text: `${fmt(link.amount)} ${TOKEN_LABEL} — ${link.description}`, url }); }
      catch { /* the user closed the share sheet */ }
    } else {
      toast(await copyText(url) ? "Payment link copied." : "Copy failed.");
    }
  });
  const actions = $("#payActions");
  const note = $("#payNote");

  const setActions = (html) => { actions.innerHTML = html; };
  const setNote = (html) => { note.innerHTML = html || ""; };

  /* ── terminal states: nothing to do, say so plainly ── */
  if (statusNameNow === "Claimed") {
    /* The payout result renders where the pay button sat, in the card's own
       row language: the success line, the pool and the stored facts come up
       at once — the payout event itself is a separate live read (the RPC
       caps eth_getLogs at 100 blocks, so the claim has to be located
       first), so its rows, the fee line and the PDF button appear when it
       answers. Nothing here is recomputed: every amount in the result comes
       out of the claim's own events. */
    setActions(`<div class="pay-result" id="claimResult" role="status" aria-label="Payout result">
      <p class="pay-result-ok">
        <span class="chk" aria-hidden="true">
          <svg viewBox="0 0 16 16" width="12" height="12"><path d="M3.5 8.4 6.6 11.5 12.5 5.5" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"/></svg>
        </span>
        <strong>Paid out to the payee</strong>
      </p>
      <div class="pay-items">
        <span class="pi-h">payout</span>
        <!-- The claim event's payout field is the post-fee pool the
             circuit distributed — not a single recipient's share, so the
             row says pool. The legs that shared it are in More details. -->
        <div class="pi-row"><span class="pi-l">payout pool</span><span class="pi-p" id="claimAmount">Reading payout&hellip;</span></div>
        <div class="pi-row"><span class="pi-l">payee</span><span class="pi-p mono" title="${esc(link.creator)}">${truncate(link.creator, 10, 6)}</span></div>
        <div class="pi-row"><span class="pi-l">payer</span><span class="pi-p mono" title="${esc(link.paidBy)}">${truncate(link.paidBy, 10, 6)}</span></div>
      </div>
      <p class="pay-fee" id="claimSummary">Reading the payout event from the chain&hellip;</p>
      <div id="claimRows"></div>
      <div class="pay-result-foot" id="claimFoot"></div>
    </div>`);
    setNote(`Invoice <code>${esc(link.linkId)}</code> &middot; A link can only be claimed once, and only ever by its payee.`);
    fillClaimReceipt(link).catch((err) => {
      /* The stored rows above are contract state and stay; only the event
         read failed, and the page says exactly that instead of guessing. */
      const el = $("#claimResult");
      if (!el) return; // the user navigated away mid-read
      const summary = $("#claimSummary");
      if (summary) summary.textContent = "The payout event could not be read from the chain just now.";
      const amount = $("#claimAmount");
      if (amount) amount.textContent = "Payout details unavailable";
      const foot = $("#claimFoot");
      if (foot) foot.innerHTML = `<span class="tiny">${esc(friendly(err))}</span>
        <button class="btn btn-sm ghost" type="button" id="claimRetry"><span>Try again</span></button>`;
      $("#claimRetry")?.addEventListener("click", () => fillClaimReceipt(link).catch(() => {}));
    });
    return;
  }

  if (statusNameNow === "Cancelled") {
    setActions(`<div class="empty-line">This link was cancelled by its creator. Nothing was ever held, so nothing is refundable — it simply never took payment.</div>`);
    return;
  }

  if (statusNameNow === "Expired") {
    setActions(`<div class="empty-line">This link expired before it was paid. The invoice is closed; create a new one if you are still owed.</div>`);
    return;
  }

  /* ── Paid: anyone may trigger the payout ── */
  if (statusNameNow === "Paid") {
    setActions(`
      <button class="btn btn-lg" type="button" id="claimBtn"><span>Release ${fmt(payout)} ${esc(TOKEN_LABEL)} to the payee</span></button>
      <p class="pay-fee">Anyone can press this &mdash; the money can only ever go to
        <strong>${truncate(link.creator, 10, 6)}</strong> and the fee account.</p>`);
    setNote(`Paid by ${truncate(link.paidBy, 10, 6)} · ${fmt(link.paidAmount)} ${esc(TOKEN_LABEL)} credited.`);
    $("#claimBtn")?.addEventListener("click", () => runClaim(id));
    return;
  }

  /* ── Open: the payer path, approve then pay ── */
  if (!account) {
    setActions(`<button class="btn btn-lg" type="button" id="payConnect"><span>Connect wallet to pay</span></button>`);
    setNote("Read-only so far: this page never needed a wallet to show you the invoice.");
    $("#payConnect")?.addEventListener("click", async () => {
      if (await connect()) renderPay(id);
    });
    return;
  }

  if (isCreator) {
    setActions(`<div class="empty-line">You created this link, so you cannot pay it &mdash; the contract refuses a payee settling their own invoice. Cancel it instead if it was a mistake.</div>
      <button class="btn ghost" type="button" id="cancelBtn"><span>Cancel this link</span></button>`);
    setNote("");
    $("#cancelBtn")?.addEventListener("click", () => runCancel(id));
    return;
  }

  if (!paymentPolicy) {
    setActions(`<div class="empty-line">Live rule and cap details could not be read. Payment is paused until the network answers.
      <div class="cancel-row"><button class="btn ghost" type="button" id="policyRetry"><span>Try again</span></button></div></div>`);
    setNote("Review the rule table, default table and current cap above before paying.");
    $("#policyRetry")?.addEventListener("click", () => renderPay(id));
    return;
  }

  /* Balance, allowance and chain state are all live: the two buttons below
     are rendered from what the chain says, not from what the form said. */
  setActions(`<div class="empty-line">Reading your balance and allowance…</div>`);
  try {
    const [balance, allowance] = await Promise.all([readBalance(account), readAllowance(account)]);
    const need = link.amount;
    const short = balance < need;
    const approved = allowance >= need;
    const { payout: willReceive, fee: willFee } = splitFee(need);

    let html = "";
    if (short) {
      /* Nothing to approve against: `pay` would revert at transferFrom, so
         offering the button would only manufacture a failed transaction.
           The MOCK token's public faucet is the way out, and it is offered
           only because the label says MOCK. */
      html += `<p class="pay-fee">Your wallet holds <strong>${fmt(balance)} ${esc(TOKEN_LABEL)}</strong>
        and this invoice needs <strong>${fmt(need)}</strong>.</p>`;
      if (MOCK) {
        html += `<button class="btn btn-lg" type="button" id="mintBtn"><span>Mint 10 ${esc(TOKEN_LABEL)} test tokens</span></button>`;
      }
      html += `<p class="pay-fee">Approve and pay unlock once your wallet holds at least
        <strong>${fmt(need)} ${esc(TOKEN_LABEL)}</strong>.</p>`;
    } else if (approved) {
      html += `<button class="btn btn-lg" type="button" id="payBtn"><span>Pay ${fmt(need)} ${esc(TOKEN_LABEL)}</span></button>
        <p class="pay-fee">Already approved — this signature moves the tokens.</p>`;
    } else {
      html += `<button class="btn btn-lg" type="button" id="approveBtn"><span>Step 1 — approve ${fmt(need)} ${esc(TOKEN_LABEL)}</span></button>`;
    }
    if (!short) {
      html += `<p class="pay-fee">You send <strong>${fmt(need)} ${esc(TOKEN_LABEL)}</strong>;
        the payee gets <strong>${fmt(willReceive)}</strong> on claim,
        <strong>${fmt(willFee)}</strong> is the fee. Two signatures: this one, then the payment.</p>`;

      /* Gasless alternative: sign the transfer itself off-chain instead of
         approve + pay. Only offered while the wallet actually holds the
         amount (a signature without balance would only revert) and only
         ever bound to this link and this account. */
      html += `<div class="pay-gasless" id="gaslessBlock">`;
      if (gaslessDraft) {
        html += `<p class="pay-fee">Signed off-chain by <strong>${truncate(gaslessDraft.from, 10, 6)}</strong> —
          no transaction, no gas. Anyone can submit it now.</p>
          <div class="pay-items">
            <div class="pi-row"><span class="pi-l">signer</span><span class="pi-p mono" title="${esc(gaslessDraft.from)}">${truncate(gaslessDraft.from, 10, 6)}</span></div>
            <div class="pi-row"><span class="pi-l">bound to</span><span class="pi-p mono">${esc(gaslessDraft.linkId)}</span></div>
            <div class="pi-row"><span class="pi-l">nonce</span><span class="pi-p mono" title="${esc(gaslessDraft.nonce)}">${truncate(gaslessDraft.nonce, 10, 6)}</span></div>
          </div>
          <button class="btn btn-lg" type="button" id="gaslessSubmit"><span>Submit signed payment</span></button>
          <div class="cancel-row">
            <button class="btn ghost" type="button" id="gaslessCopy"><span>Copy authorization</span></button>
            <button class="btn ghost" type="button" id="gaslessDiscard"><span>Discard signature</span></button>
          </div>`;
      } else {
        html += `<p class="pay-fee">No OKB? Sign the payment off-chain instead — your wallet
          signs one authorization for free, and <strong>anyone</strong> can then submit it and
          pay the gas. Same amount, same rules, same contract.</p>
          <div class="cancel-row">
            <button class="btn ghost" type="button" id="gaslessSign"><span>Sign payment authorization</span></button>
          </div>`;
      }
      html += `</div>`;
    }

    setActions(html);
    setNote(MOCK
      ? `Gas is paid in OKB on chain ${CHAIN_ID}. ${TOKEN_LABEL} is test scaffolding — every amount here is test money.`
      : `Gas is paid in OKB on chain ${CHAIN_ID}. Token and payout details are read from this network.`);

    $("#mintBtn")?.addEventListener("click", () => runMint(id, account));
    $("#approveBtn")?.addEventListener("click", () => runApproveThenPay(id, need));
    $("#payBtn")?.addEventListener("click", () => runPay(id, need));
    $("#gaslessSign")?.addEventListener("click", () => runSignGasless(id, need));
    $("#gaslessSubmit")?.addEventListener("click", () => runSubmitGasless(id));
    $("#gaslessCopy")?.addEventListener("click", async () => {
      if (!gaslessDraft) return;
      const okCopy = await copyText(JSON.stringify(gaslessDraft, null, 2));
      toast(okCopy ? "Authorization copied — anyone can submit it." : "Copy failed.");
    });
    $("#gaslessDiscard")?.addEventListener("click", () => {
      gaslessDraft = null;
      renderPay(id);
    });
  } catch (err) {
    setActions(`<div class="empty-line">Could not read your token balance: ${esc(friendly(err))}
      <div class="cancel-row"><button class="btn ghost" type="button" id="payRetry2"><span>Try again</span></button></div></div>`);
    $("#payRetry2")?.addEventListener("click", () => renderPay(id));
  }
}

function runTxLine(state, html) {
  txLine($("#payStatus"), state, html);
}

async function runApproveThenPay(id, amount) {
  const btn = $("#approveBtn");
  if (btn) { btn.disabled = true; btn.querySelector("span").textContent = "Approving in your wallet…"; }
  try {
    runTxLine("pending", `Approving <strong>${fmt(amount)}</strong> ${esc(TOKEN_LABEL)} for Pago — confirm in your wallet…`);
    const { hash } = await sendTx(TOKEN, callData(SEL.approve, ["address", "uint256"], [PAGO, amount]));
    runTxLine("pending", `Approved in <a href="${txUrl(hash)}" target="_blank" rel="noopener">${truncate(hash, 10, 6)}</a> — now the payment…`);
    const terms = await readTermsHash(id);
    const payHash = (await sendTx(PAGO, callData(SEL.pay, ["string", "uint256", "bytes32"], [id, amount, terms]))).hash;
    runTxLine("ok", `Paid. <a href="${txUrl(payHash)}" target="_blank" rel="noopener">View transaction</a>`);
    toast("Payment sent.");
    renderPay(id);
  } catch (err) {
    runTxLine("err", esc(friendly(err)));
    if (btn) { btn.disabled = false; btn.querySelector("span").textContent = `Step 1 — approve ${fmt(amount)} ${TOKEN_LABEL}`; }
  }
}

async function runPay(id, amount) {
  const btn = $("#payBtn");
  if (btn) { btn.disabled = true; btn.querySelector("span").textContent = "Paying…"; }
  try {
    runTxLine("pending", `Paying <strong>${fmt(amount)}</strong> ${esc(TOKEN_LABEL)} — confirm in your wallet…`);
    const terms = await readTermsHash(id);
    const { hash } = await sendTx(PAGO, callData(SEL.pay, ["string", "uint256", "bytes32"], [id, amount, terms]));
    runTxLine("ok", `Paid. <a href="${txUrl(hash)}" target="_blank" rel="noopener">View transaction</a>`);
    toast("Payment sent — the payee can claim now.");
    renderPay(id);
  } catch (err) {
    runTxLine("err", esc(friendly(err)));
    if (btn) { btn.disabled = false; btn.querySelector("span").textContent = `Pay ${fmt(amount)} ${TOKEN_LABEL}`; }
  }
}

async function runClaim(id) {
  const btn = $("#claimBtn");
  if (btn) { btn.disabled = true; btn.querySelector("span").textContent = "Releasing…"; }
  try {
    runTxLine("pending", "Releasing the payout — confirm in your wallet…");
    const { hash } = await sendTx(PAGO, callData(SEL.claim, ["string"], [id]));
    runTxLine("ok", `Payout released. <a href="${txUrl(hash)}" target="_blank" rel="noopener">View transaction</a>`);
    toast("Claimed.");
    renderPay(id);
  } catch (err) {
    runTxLine("err", esc(friendly(err)));
    if (btn) { btn.disabled = false; btn.querySelector("span").textContent = "Release to the payee"; }
  }
}

async function runCancel(id) {
  const btn = $("#cancelBtn");
  if (btn) { btn.disabled = true; btn.querySelector("span").textContent = "Cancelling…"; }
  try {
    runTxLine("pending", "Cancelling — confirm in your wallet…");
    const { hash } = await sendTx(PAGO, callData(SEL.cancelLink, ["string"], [id]));
    runTxLine("ok", `Cancelled. <a href="${txUrl(hash)}" target="_blank" rel="noopener">View transaction</a>`);
    renderPay(id);
  } catch (err) {
    runTxLine("err", esc(friendly(err)));
    if (btn) { btn.disabled = false; btn.querySelector("span").textContent = "Cancel this link"; }
  }
}

/* pUSD (MOCK) has a public `mint` — that is what makes it test scaffolding
   rather than a stablecoin, and it is offered here only while the token
   label says MOCK. It moves nothing real, by definition. */
async function runMint(id, to) {
  const btn = $("#mintBtn");
  if (btn) { btn.disabled = true; btn.querySelector("span").textContent = "Minting…"; }
  try {
    runTxLine("pending", `Minting 10 ${esc(TOKEN_LABEL)} test tokens — confirm in your wallet…`);
    const amount = 10n * 10n ** BigInt(DECIMALS);
    const { hash } = await sendTx(TOKEN, callData(SEL.mint, ["address", "uint256"], [to, amount]));
    runTxLine("ok", `Minted. <a href="${txUrl(hash)}" target="_blank" rel="noopener">View transaction</a>`);
    renderPay(id);
  } catch (err) {
    runTxLine("err", esc(friendly(err)));
    if (btn) { btn.disabled = false; btn.querySelector("span").textContent = `Mint 10 ${TOKEN_LABEL} test tokens`; }
  }
}

/* Sign the gasless authorization: three chain reads, then one
   eth_signTypedData_v4 the wallet computes the digest for. Nothing is
   broadcast — the signature lands in gaslessDraft; the wallet that signed
   it submits it (the contract itself would accept a relay from anyone). */
async function runSignGasless(id, amount) {
  const btn = $("#gaslessSign");
  if (btn) { btn.disabled = true; btn.querySelector("span").textContent = "Waiting for signature…"; }
  try {
    if (!(await ensureChain())) throw new Error(`Switch the wallet to ${NETWORK_LABEL} and try again.`);
    runTxLine("pending", "Reading the token name, nonce and terms from the chain…");
    const [name, key, termsHash] = await Promise.all([
      readTokenName(),
      readLinkKeyOf(id),
      readTermsHash(id),
    ]);
    const nonce = await readAuthorizationNonce(key, account);
    const typed = authorizationTypedData({
      name,
      chainId: CHAIN_ID,
      verifyingContract: TOKEN,
      from: account,
      to: PAGO, // the contract is the transfer's recipient (Pago.sol: transferWithAuthorization(from, address(this), …))
      value: amount,
      nonce,
    });
    runTxLine("pending", "Confirm the signature in your wallet — it costs nothing.");
    const signature = await window.ethereum.request({
      method: "eth_signTypedData_v4",
      params: [account, JSON.stringify(typed)],
    });
    gaslessDraft = { linkId: id, from: account, value: amount.toString(), nonce, termsHash, signature };
    toast("Signed off-chain — no transaction was sent.");
    renderPay(id);
  } catch (err) {
    runTxLine("err", esc(friendly(err)));
    if (btn) { btn.disabled = false; btn.querySelector("span").textContent = "Sign payment authorization"; }
  }
}

/* Submit a draft authorization: the page only shows this button to the
   signing account (renderPay drops a draft on any account mismatch), but
   the contract checks the signature against `from`, not the caller. */
async function runSubmitGasless(id) {
  const draft = gaslessDraft;
  if (!draft || draft.linkId !== id) return;
  const btn = $("#gaslessSubmit");
  if (btn) { btn.disabled = true; btn.querySelector("span").textContent = "Submitting…"; }
  try {
    runTxLine("pending", "Submitting the signed authorization — confirm in your wallet…");
    const data = encodePayWithAuthorization({
      linkId: draft.linkId,
      from: draft.from,
      value: draft.value,
      nonce: draft.nonce,
      signature: draft.signature,
      expectedTermsHash: draft.termsHash,
    });
    const { hash } = await sendTx(PAGO, data);
    gaslessDraft = null;
    runTxLine("ok", `Paid. <a href="${txUrl(hash)}" target="_blank" rel="noopener">View transaction</a>`);
    toast("Payment sent — the payee can claim now.");
    renderPay(id);
  } catch (err) {
    runTxLine("err", esc(friendly(err)));
    if (btn) { btn.disabled = false; btn.querySelector("span").textContent = "Submit signed payment"; }
  }
}

/* ── ledger ─────────────────────────────────────────────────────────────── */

let ledgerLinks = [];
let ledgerFilter = "all";

function matchesFilter(link) {
  if (ledgerFilter === "all") return true;
  return statusName(link).toLowerCase() === ledgerFilter;
}

function renderLedger() {
  const list = $("#ledgerList");
  const visible = ledgerLinks.filter(matchesFilter);

  /* Counts come from the whole set, so a filter never lies about how many
     links exist in a state it is not showing. */
  const count = (f) => (f === "all" ? ledgerLinks.length : ledgerLinks.filter((l) => statusName(l).toLowerCase() === f).length);
  $$("#ledgerFilters [data-f]").forEach((el) => { el.textContent = count(el.dataset.f) || ""; });

  if (!visible.length) {
    list.innerHTML = `<div class="empty-line">${ledgerLinks.length ? "No links in that state." : "No links for this address yet."}</div>`;
    return;
  }

  list.innerHTML = visible
    .map((l) => {
      const st = statusName(l);
      const credited = Number(l.paidAt) > 0 ? fmt(l.paidAmount) : "—";
      const isMine = sameAddr(account, l.creator);
      let action = `<button class="btn btn-sm ghost" type="button" data-open="${esc(l.linkId)}"><span>Open</span></button>`;
      if (st === "Paid") {
        action = `<button class="btn btn-sm" type="button" data-claim="${esc(l.linkId)}"><span>Claim</span></button>`;
      } else if (st === "Open" && isMine) {
        action = `<button class="btn btn-sm ghost" type="button" data-cancel="${esc(l.linkId)}"><span>Cancel</span></button>`;
      }
      return `<div class="row-main" data-row="${esc(l.linkId)}">
        <span class="c-invoice">
          <span class="inv-desc">${esc(l.description)}</span>
          <span class="inv-id">${esc(l.linkId)}</span>
        </span>
        <span class="c-amount">${fmt(l.amount)}</span>
        <span class="c-usd">${credited}</span>
        <span class="c-status"><span class="${pillClass(st)}">${esc(st)}</span></span>
        <span class="c-payer" title="${esc(l.paidBy)}">${l.paidBy && l.paidBy !== "0x0000000000000000000000000000000000000000" ? truncate(l.paidBy, 8, 4) : "—"}</span>
        <span class="c-action">${action}</span>
      </div>`;
    })
    .join("");

  $$("[data-open]", list).forEach((b) => b.addEventListener("click", () => openPay(b.dataset.open)));
  $$("[data-claim]", list).forEach((b) => b.addEventListener("click", async () => {
    b.disabled = true;
    try {
      await sendTx(PAGO, callData(SEL.claim, ["string"], [b.dataset.claim]));
      toast("Claimed.");
      loadLedger();
    } catch (err) { toast(friendly(err)); b.disabled = false; }
  }));
  $$("[data-cancel]", list).forEach((b) => b.addEventListener("click", async () => {
    b.disabled = true;
    try {
      await sendTx(PAGO, callData(SEL.cancelLink, ["string"], [b.dataset.cancel]));
      toast("Cancelled.");
      loadLedger();
    } catch (err) { toast(friendly(err)); b.disabled = false; }
  }));
}

async function loadLedger() {
  const input = $("#creatorInput");
  const list = $("#ledgerList");
  /* No default address: the ledger starts empty until a wallet connects or
     an address is typed. The configured payee's links are real, but showing
     them unprompted reads as the visitor's own history. */
  const creator = (input.value || "").trim() || account;

  if (!creator) {
    ledgerLinks = [];
    ledgerLoaded = false;
    list.innerHTML = `<div class="empty-line">Connect a wallet — or enter an address above to read the chain.</div>`;
    $("#tableCreator").textContent = "–";
    $("#tableCount").textContent = "–";
    $("#ledgerStats").hidden = true;
    $("#ledgerFilters").hidden = true;
    $("#ledgerCsv").hidden = true;
    return;
  }

  if (!isAddress(creator)) {
    list.innerHTML = `<div class="empty-line">That is not an address. Pago ledgers are keyed by a 0x… address — paste the creator's full wallet address.</div>`;
    $("#ledgerStats").hidden = true;
    $("#ledgerFilters").hidden = true;
    $("#ledgerCsv").hidden = true;
    return;
  }
  input.value = creator;

  list.innerHTML = `<div class="empty-line">Reading ${truncate(creator, 10, 6)} from the chain…</div>`;
  $("#ledgerStats").hidden = true;
  $("#ledgerFilters").hidden = true;
  $("#ledgerCsv").hidden = true;

  try {
    ledgerLinks = await readLedger(creator);
    ledgerLoaded = true;

    const claimed = ledgerLinks.filter((l) => statusName(l) === "Claimed");
    const received = claimed.reduce((sum, l) => sum + splitFee(l.paidAmount).payout, 0n);
    const open = ledgerLinks.filter((l) => statusName(l) === "Open").length;

    $("#statReceived").textContent = fmt(received);
    $("#statOpen").textContent = String(open);
    $("#statCount").textContent = String(ledgerLinks.length);
    $("#ledgerStats").hidden = false;
    $("#ledgerFilters").hidden = ledgerLinks.length === 0;
    $("#tableCreator").textContent = truncate(creator, 10, 6);
    $("#tableCreator").title = creator;
    $("#tableCount").textContent = `${ledgerLinks.length} link${ledgerLinks.length === 1 ? "" : "s"} · read from getLinksByCreator`;
    $("#ledgerCsv").hidden = ledgerLinks.length === 0;

    renderLedger();
  } catch (err) {
    ledgerLinks = [];
    $("#ledgerCsv").hidden = true;
    list.innerHTML = `<div class="empty-line">Could not read the chain: ${esc(friendly(err))}
      <div class="cancel-row"><button class="btn ghost" type="button" id="ledgerRetry"><span>Try again</span></button></div></div>`;
    $("#ledgerRetry")?.addEventListener("click", loadLedger);
  }
}

/* ── activity bell ────────────────────────────────────────────────────────
   The header bell opens a popover over the same chain read the ledger
   makes — getLinksByCreator for the address My links would load — so every
   row is a field that came back from the contract: newest payments first,
   a link with paidAt = 0 shown as awaiting and never as paid. The first
   open performs the read and caches it with the ledger; later opens paint
   that cache instead of spending another call. */
let activityLoading = false;

function renderActivity() {
  const list = $("#actList");
  const note = $("#actNote");
  if (!list) return;

  if (!ledgerLinks.length) {
    const typed = ($("#creatorInput")?.value || "").trim();
    list.innerHTML = `<div class="lp-act-empty">${
      !typed && !account
        ? "Connect a wallet to see recent activity."
        : ledgerLoaded
          ? "No links for this address yet — create one and it appears here."
          : "Could not read the chain. Open My links to try again."
    }</div>`;
    if (note) note.textContent = "";
    return;
  }

  const recent = ledgerLinks
    .slice()
    .sort((a, b) => Number(b.paidAt || 0) - Number(a.paidAt || 0))
    .slice(0, 6);

  list.innerHTML = recent
    .map((l) => {
      const paid = Number(l.paidAt) > 0;
      const payer =
        paid && l.paidBy && l.paidBy !== "0x0000000000000000000000000000000000000000"
          ? truncate(l.paidBy, 6, 4)
          : "";
      const meta = [esc(l.linkId), payer].filter(Boolean).join(" · ");
      return `<div class="lp-act-row">
        <span class="lp-act-dot${paid ? " paid" : ""}" aria-hidden="true"></span>
        <span class="lp-act-main">
          <span class="lp-act-desc">${esc(l.description || "Payment link")}</span>
          <span class="lp-act-meta">${esc(meta)}</span>
        </span>
        <span class="lp-act-right">
          <span class="lp-act-amt">${fmt(l.amount)}${paid ? ` · ${esc(statusName(l))}` : ""}</span>
          <span class="lp-act-time">${paid ? esc(fmtDate(l.paidAt)) : "awaiting payment"}</span>
        </span>
      </div>`;
    })
    .join("");

  if (note) note.textContent = `${ledgerLinks.length} link${ledgerLinks.length === 1 ? "" : "s"} · getLinksByCreator`;
}

function wireActivity() {
  const bell = $("#bellBtn");
  const panel = $("#activityPanel");
  if (!bell || !panel) return;

  const close = () => {
    panel.hidden = true;
    bell.setAttribute("aria-expanded", "false");
    bell.classList.remove("on");
  };

  bell.addEventListener("click", () => {
    if (!panel.hidden) return close();
    panel.hidden = false;
    bell.setAttribute("aria-expanded", "true");
    bell.classList.add("on");

    /* A read already in flight keeps its "Reading…" line — repainting from
       the empty cache here would claim a failure while the chain is still
       answering. */
    if (activityLoading) return;
    renderActivity();
    if (ledgerLoaded) return;

    activityLoading = true;
    const list = $("#actList");
    if (list) list.innerHTML = `<div class="lp-act-empty">Reading ${esc(NETWORK_LABEL)}…</div>`;
    loadLedger()
      .catch(() => {})
      .finally(() => {
        activityLoading = false;
        renderActivity();
      });
  });

  /* Outside click and Escape both put the popover away; the footer link
     navigates to My links, so it must not stay open over that panel. */
  document.addEventListener("click", (e) => {
    if (panel.hidden || panel.contains(e.target) || bell.contains(e.target)) return;
    close();
  });
  document.addEventListener("keydown", (e) => {
    if (e.key === "Escape" && !panel.hidden) {
      close();
      bell.focus();
    }
  });
  $(".lp-act-foot")?.addEventListener("click", close);
}

/* ── boot ───────────────────────────────────────────────────────────────── */

function paintStatic() {
  const tokenLabel = $("#tokenLabel");
  const tokenAddr = $("#tokenAddr");
  const tokenBadge = $("#tokenBadge");
  const amountSymbol = $("#amountSymbol");
  if (tokenLabel) tokenLabel.textContent = TOKEN_LABEL;
  if (amountSymbol) amountSymbol.textContent = activeToken.symbol;
  if (tokenAddr) {
    tokenAddr.textContent = TOKEN;
    tokenAddr.title = TOKEN_OPTIONS.find((token) => token.address === TOKEN)?.explorerUrl || NET.tokenExplorerUrl || TOKEN;
  }
  if (tokenBadge) tokenBadge.textContent = MOCK ? "MOCK" : "allowlisted";

  const networkSelect = $("#networkSelect");
  if (networkSelect && !networkSelect.options.length) {
    NETWORKS.forEach((network) => {
      const option = document.createElement("option");
      option.value = String(network.chainId);
      option.textContent = network.chainId === 196 ? "X Layer mainnet" : "X Layer testnet";
      networkSelect.appendChild(option);
    });
    networkSelect.addEventListener("change", () => {
      const url = new URL(location.href);
      url.searchParams.set("chainId", networkSelect.value);
      url.searchParams.delete("token");
      location.assign(url);
    });
  }
  if (networkSelect) networkSelect.value = String(CHAIN_ID);

  const tokenSelect = $("#tokenSelect");
  const tokenSelectLabel = $(".token-select-label");
  if (tokenSelect) {
    tokenSelect.replaceChildren(...TOKEN_OPTIONS.map((token) => {
      const option = document.createElement("option");
      option.value = token.address;
      option.textContent = token.isMock ? `${token.symbol} (MOCK)` : token.symbol;
      return option;
    }));
    tokenSelect.value = TOKEN;
    tokenSelect.hidden = TOKEN_OPTIONS.length < 2;
    if (tokenSelectLabel) tokenSelectLabel.hidden = TOKEN_OPTIONS.length < 2;
    tokenSelect.onchange = () => {
      const url = new URL(location.href);
      url.searchParams.set("token", tokenSelect.value);
      location.assign(url);
    };
  }

  const note = $("#tokenNote");
  if (note) {
    note.innerHTML = MOCK
      ? `<strong>${esc(TOKEN_LABEL)}</strong> is a freely mintable test token with no backing and no redemption value. Every amount on this page is fake money.`
      : `${esc(TOKEN_LABEL)} is the allowlisted token for this deployment.`;
  }

  /* The create head's circuit line fills once, from the same live rule
     check the pay card shows. It starts hidden and stays hidden if the
     read fails; the guard keeps a later paintStatic() (renderPay calls it
     too) from re-reading a chain the page already asked. */
  const pinSlot = $("#createPinLine");
  if (pinSlot && !pinSlot.dataset.done) {
    pinSlot.dataset.done = "1";
    readPaymentPolicy(TOKEN)
      .then((policy) => {
        if (!policy) return;
        pinSlot.hidden = false;
        pinSlot.innerHTML = pinLine(policy);
      })
      .catch(() => { /* no line rather than a guessed one */ });
  }

  const hero = $("#heroChainNote");
  if (hero) {
    hero.innerHTML = `Chain ${CHAIN_ID} &middot; token <strong>${esc(TOKEN_LABEL)}</strong> &middot; fixed ${NET.feeBps / 100}% fee &middot; no sign-up, no admin keys, funds move only through the contract.`;
  }
  const networkCopy = $("#heroNetworkLabel");
  if (networkCopy) networkCopy.textContent = `${NETWORK_LABEL} · payment links`;
  const networkChip = $("#netLabel");
  if (networkChip) networkChip.textContent = NETWORK_LABEL;
  const footer = $("#footerNetworkLabel");
  if (footer) footer.textContent = `${NETWORK_LABEL} (${CHAIN_ID}) · ${MOCK ? `${TOKEN_LABEL} test token only` : `${TOKEN_LABEL} · allowlisted stablecoin`}`;
  /* The site footer's safety line names the network this page is actually
     on: a mainnet build must never read "Demo on X Layer testnet". */
  const safety = $("#footerSafetyNote");
  if (safety) safety.textContent = `${CHAIN_ID === 196 ? NETWORK_LABEL : `Demo on ${NETWORK_LABEL}`} — check the contract address on the explorer before you pay.`;
}

/* One boot read: fee, allowlist, clock. It also drives the connection dot,
   which is the honest signal — a cached "ok" would be a lie the moment the
   RPC stops answering. */
async function refreshChainInfo() {
  try {
    const [bps, allowed] = await Promise.all([
      readFeeBps(),
      ethCall(PAGO, callData(SEL.isTokenAllowed, ["address"], [TOKEN])).then((r) => decodeReturn(["bool"], r)[0]),
    ]);
    NET.feeBps = Number(bps);
    paintNet("ok");
    if (!allowed) {
      toast("This deployment does not accept the configured token — check config.js.");
      paintNet("err", "allowlist mismatch");
    }
    /* Every fee figure on the page is rendered from NET.feeBps at paint
       time, so overwriting it here is what keeps the UI on the chain's
       number rather than config's. */
    return true;
  } catch (err) {
    paintNet("err", "chain unreachable");
    return false;
  }
}

function wireTabs() {
  $$("[data-tab]").forEach((b) => b.addEventListener("click", () => go(b.dataset.tab)));
  $$("[data-go]").forEach((b) => b.addEventListener("click", () => go(b.dataset.go)));
}

function boot() {
  paintStatic();
  paintWallet();
  wireTabs();
  wireCreateForm();
  wireSeatAvatars();
  wireActivity();
  wireWalletEvents();

  $("#walletBtn")?.addEventListener("click", async () => {
    if (account) {
      account = null;
      paintWallet();
      toast("Wallet disconnected from this page.");
      return;
    }
    /* Reload whenever the ledger panel is open: it may have been showing
       the empty state before this wallet connected. */
    if ((await connect()) && currentPanel === "ledger") loadLedger();
  });
  $("#heroConnect")?.addEventListener("click", async () => {
    if ((await connect()) && currentPanel === "ledger") loadLedger();
  });

  $("#createForm")?.addEventListener("submit", onCreate);

  $("#ledgerLoad")?.addEventListener("click", loadLedger);

  /* "Use my wallet": the one-click path from the empty ledger to the
     visitor's own links — connects if nothing is connected yet, drops the
     address into the field (so the box always shows which account is being
     read) and loads in the same press. */
  $("#ledgerMine")?.addEventListener("click", async () => {
    const input = $("#creatorInput");
    if (!account && !(await connect())) return;
    if (input) input.value = account;
    loadLedger();
  });

  /* CSV export: one row per link, with the claim's event facts for claimed
     links (read live, sequentially — the RPC's log cap makes each one a
     locate-then-read) and empty claim columns for anything else. */
  $("#ledgerCsv")?.addEventListener("click", async () => {
    const btn = $("#ledgerCsv");
    if (!ledgerLinks.length) return;
    btn.disabled = true;
    const label = btn.querySelector("span");
    const wasLabel = label.textContent;
    label.textContent = "Collecting claim events…";
    try {
      const rows = [];
      let eventMisses = 0;
      for (const link of ledgerLinks) {
        let claim = null;
        if (statusName(link) === "Claimed") {
          try { claim = (await readClaimEvidence(link)).claim; } catch { eventMisses++; }
        }
        rows.push({ link, claim });
      }
      const csv = ledgerCsv(rows, { tokenSymbol: TOKEN_LABEL, decimals: DECIMALS });
      const blob = new Blob([csv], { type: "text/csv;charset=utf-8" });
      const url = URL.createObjectURL(blob);
      const a = document.createElement("a");
      a.href = url;
      a.download = `pago-ledger-${($("#creatorInput").value || "links").trim().slice(0, 42)}.csv`;
      document.body.appendChild(a);
      a.click();
      a.remove();
      setTimeout(() => URL.revokeObjectURL(url), 4000);
      toast(eventMisses
        ? `CSV downloaded — ${eventMisses} claim event${eventMisses === 1 ? "" : "s"} could not be read; those claim columns are empty.`
        : "CSV downloaded");
    } catch (err) {
      toast(friendly(err));
    } finally {
      btn.disabled = false;
      label.textContent = wasLabel;
    }
  });
  $("#creatorInput")?.addEventListener("keydown", (e) => {
    if (e.key === "Enter") { e.preventDefault(); loadLedger(); }
  });
  $$("#ledgerFilters [data-filter]").forEach((b) =>
    b.addEventListener("click", () => {
      ledgerFilter = b.dataset.filter;
      $$("#ledgerFilters [data-filter]").forEach((x) => x.classList.toggle("on", x === b));
      renderLedger();
    })
  );

  window.addEventListener("hashchange", route);

  route();
  refreshChainInfo();
  silentConnect();
}

boot();
