/* Pago — the X Layer frontend.
   Static module: no build step, no bundler, no server of our own.

   Reads are unsigned JSON-RPC `eth_call`s against the public testnet
   endpoint, so the ledger and every pay card render with no wallet at all —
   that is what makes the read-only Playwright project possible. Writes go
   through an injected EIP-1193 wallet (MetaMask, OKX Wallet, …) over
   `window.ethereum`; nothing here ever sees a private key, and there is no
   relayer, because no relayer runs on X Layer — the payer signs `approve`
   then `pay` themselves (v1 scope, see docs/RESEARCH.md).

   Contract calls are encoded by frontend/abi.js, a hand-rolled codec: the app
   is buildless, so it cannot import ethers or web3, and what Pago needs is a
   closed set of a dozen functions. Every selector in that file was produced
   with `cast sig` and cross-checked against the deployed bytecode.

   Rules enforced here are the contract's, not this page's invention: the
   note must be 1–280 UTF-8 bytes, the amount must be above zero, expiry is
   written in *chain* time, only the creator can cancel, the payee can never
   pay their own link, and a payer must hold the tokens plus enough OKB for
   two transactions. A rejection the chain makes is surfaced, never papered
   over. */

import { XLAYER } from "./config.js?v=20261119a";
import {
  SEL,
  GET_LINK_TYPES,
  GET_LINKS_TYPES,
  STATUS,
  callData,
  decodeReturn,
} from "./abi.js?v=20261119a";

/* ── configuration ──────────────────────────────────────────────────────── */

/* This page is deliberately testnet-only: `pago.mainnet` is `null` until a
   mainnet deploy is explicitly approved, and there is nothing to point at
   until then. Chain 1952, one endpoint list, one token. */
const NET = XLAYER.pago.testnet;
const CHAIN_ID = NET.chainId;
const CHAIN_HEX = "0x" + CHAIN_ID.toString(16);
const PAGO = NET.pago;
const TOKEN = NET.token;

/* Deduped: config carries the endpoint on both the pago block and the
   testnet block, and they are the same URL today. */
const RPC_URLS = [...new Set([NET.rpc, ...XLAYER.testnet.rpcUrls].filter(Boolean))];

const DECIMALS = NET.tokenDecimals;
const MOCK = NET.tokenIsMock === true;
/* The one label every surface must use. `pUSD` alone would read as a real
   stablecoin, which this is not. */
const TOKEN_LABEL = MOCK ? `${NET.tokenSymbol} (MOCK)` : NET.tokenSymbol;
const ENC = new TextEncoder();

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

/* ── contract reads ─────────────────────────────────────────────────────── */

async function readLink(id) {
  const data = callData(SEL.getLink, ["string"], [id]);
  const ret = await ethCall(PAGO, data);
  const [found, link] = decodeReturn(GET_LINK_TYPES, ret);
  return { found, link };
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

/* ── wallet (EIP-1193) ──────────────────────────────────────────────────── */

let account = null; // connected address, checksum as the wallet reports it
let walletChain = null; // chain id the wallet is on, as a number

const hasWallet = () => typeof window !== "undefined" && !!window.ethereum;

function paintWallet() {
  const label = $("#walletLabel");
  const field = $("#payToField");
  const addr = $("#payToAddr");
  const badge = $("#payToBadge");
  const heroBtn = $("#heroConnect");

  if (label) label.textContent = account ? truncate(account, 6, 4) : hasWallet() ? "Connect" : "No wallet";
  if (heroBtn) heroBtn.querySelector("span").textContent = account ? truncate(account, 6, 4) : "Connect wallet";

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
  if (label) label.textContent = note || "X Layer testnet";
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
            chainName: "X Layer Testnet",
            nativeCurrency: XLAYER.testnet.nativeCurrency,
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
    paintWallet();
    if (currentPanel === "ledger") loadLedger();
  });
  window.ethereum.on?.("chainChanged", (id) => {
    walletChain = parseInt(id, 16);
    if (walletChain !== CHAIN_ID) {
      toast(`Wallet is on chain ${walletChain}, not X Layer testnet (${CHAIN_ID}).`);
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
  if (!(await ensureChain())) throw new Error("Switch the wallet to X Layer testnet and try again.");
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

function showPanel(name) {
  currentPanel = name;
  $$("[data-panel]").forEach((p) => { p.hidden = p.dataset.panel !== name; });
  $$("[data-tab]").forEach((b) => {
    const on = b.dataset.tab === name;
    b.setAttribute("aria-selected", on ? "true" : "false");
    b.tabIndex = on ? 0 : -1;
  });
  if (name === "ledger" && !ledgerLoaded) loadLedger();
}

function go(name, { push = true } = {}) {
  if (push && location.hash.slice(1) !== name) location.hash = name;
  showPanel(name);
  window.scrollTo({ top: 0, behavior: "auto" });
}

function openPay(id) {
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
    const id = h.slice(4);
    showPanel("pay");
    window.scrollTo({ top: 0, behavior: "auto" });
    renderPay(id);
    return;
  }
  if (h.startsWith("ready/")) {
    const id = h.slice(6);
    showPanel("ready");
    window.scrollTo({ top: 0, behavior: "auto" });
    renderReady(id, id === pendingLinkId ? pendingTxHash : null);
    return;
  }
  showPanel(TABS.includes(h) ? h : "home");
}

/* ── shared markup bits ─────────────────────────────────────────────────── */

const pillClass = (status) => `pill ${String(status).toLowerCase()}`;
const statusName = (link) => STATUS[Number(link.status)] || "Open";

const payUrlFor = (id) =>
  `${location.origin}${location.pathname}#pay/${encodeURIComponent(id)}`;

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

async function onCreate(e) {
  e.preventDefault();
  const btn = $("#createBtn");
  const result = $("#createResult");

  let amount;
  const note = $("#description").value.trim();
  try {
    amount = parseAmount($("#amount").value);
    if (!note) throw new Error("Add a note — the contract refuses a blank one.");
    const bytes = ENC.encode(note).length;
    if (bytes > 280) throw new Error(`That note is ${bytes} bytes; the limit is 280 UTF-8 bytes.`);
  } catch (err) {
    txLine(result, "err", esc(err.message));
    return;
  }

  if (!account && !(await connect())) {
    txLine(result, "err", "Connect a wallet to create a link — it has to be signed by someone.");
    return;
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
      ["string", "uint256", "address", "string", "uint64"],
      [linkId, amount, TOKEN, note, BigInt(expiresAt)]
    );
    const { hash } = await sendTx(PAGO, data);

    txLine(result, "ok",
      `Link created. <a href="${txUrl(hash)}" target="_blank" rel="noopener">View transaction</a>`);
    $("#createForm").reset();
    openReady(linkId, hash);
  } catch (err) {
    txLine(result, "err", esc(friendly(err)));
  } finally {
    btn.disabled = false;
    label.textContent = labelWas;
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
          <div><span class="net-k">fee at claim</span><span class="net-v">${NET.feeBps / 100}%</span></div>
          <div><span class="net-k">link id</span><span class="net-v mono">${esc(link.linkId)}</span></div>
          <div><span class="net-k">expires</span><span class="net-v">${esc(fmtDate(link.expiresAt))}</span></div>
          <div><span class="net-k">network</span><span class="net-v">X Layer testnet (${CHAIN_ID})</span></div>
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
       <div class="empty-line">No link with the id <code>${esc(id)}</code> on X Layer testnet.
         <div class="cancel-row"><button class="btn ghost" type="button" data-go="home"><span>Back home</span></button></div>
       </div>`;
    return;
  }

  const link = res.link;
  const statusNameNow = statusName(link);
  const { payout, fee } = splitFee(link.paidAmount > 0n ? link.paidAmount : link.amount);
  const isCreator = sameAddr(account, link.creator);

  /* ── facts every state shares ── */
  const facts = `
    <div class="pay-items">
      <span class="pi-h">invoice</span>
      <div class="pi-row"><span class="pi-l">amount</span><span class="pi-p">${fmt(link.amount)} ${esc(TOKEN_LABEL)}</span></div>
      <div class="pi-row"><span class="pi-l">payee receives</span><span class="pi-p">${fmt(payout)} ${esc(TOKEN_LABEL)}</span></div>
      <div class="pi-row"><span class="pi-l">fee (${NET.feeBps / 100}%)</span><span class="pi-p">${fmt(fee)} ${esc(TOKEN_LABEL)}</span></div>
      <div class="pi-row"><span class="pi-l">link id</span><span class="pi-p mono">${esc(link.linkId)}</span></div>
      <div class="pi-row"><span class="pi-l">created</span><span class="pi-p">${esc(fmtDate(link.createdAt))}</span></div>
      <div class="pi-row"><span class="pi-l">expires</span><span class="pi-p">${esc(fmtDate(link.expiresAt))}</span></div>
      ${Number(link.paidAt) > 0 ? `<div class="pi-row"><span class="pi-l">paid</span><span class="pi-p">${esc(fmtDate(link.paidAt))}</span></div>` : ""}
      ${Number(link.claimedAt) > 0 ? `<div class="pi-row"><span class="pi-l">claimed</span><span class="pi-p">${esc(fmtDate(link.claimedAt))}</span></div>` : ""}
    </div>`;

  const head = `
    <div class="pay-top">
      <div class="pay-who">
        <span class="pay-avatar" aria-hidden="true">P</span>
        <div class="pay-who-txt">
          <strong title="${esc(link.creator)}">${truncate(link.creator, 10, 6)}</strong>
          <span>${isCreator ? "this is your invoice" : "is owed money"}</span>
        </div>
      </div>
      <span class="${pillClass(statusNameNow)}">${esc(statusNameNow)}</span>
    </div>

    <div class="pay-amount">
      <div class="pay-usd">${fmt(link.amount)}<span class="approx">${esc(TOKEN_LABEL)}</span></div>
      <div class="pay-token">
        <svg class="coin" aria-hidden="true"><use href="#coin-pusd"/></svg>
        <span>${esc(TOKEN_LABEL)}</span>
        <span class="pay-net">X Layer testnet</span>
      </div>
    </div>

    <div class="pay-desc"><b>for</b>${esc(link.description)}</div>`;

  card.innerHTML = `${head}${facts}
    <div class="pay-actions" id="payActions"></div>
    <p class="wallet-note" id="payNote"></p>`;

  const actions = $("#payActions");
  const note = $("#payNote");

  const setActions = (html) => { actions.innerHTML = html; };
  const setNote = (html) => { note.innerHTML = html || ""; };

  /* ── terminal states: nothing to do, say so plainly ── */
  if (statusNameNow === "Claimed") {
    setActions(`<div class="pay-receipt">
      <div class="rcpt-head">
        <span class="chk" aria-hidden="true">
          <svg viewBox="0 0 16 16" width="13" height="13"><path d="M3.5 8.4 6.6 11.5 12.5 5.5" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/></svg>
        </span>
        <div class="rcpt-head-txt">
          <strong>Paid out to the payee</strong>
          <span>${fmt(payout)} ${esc(TOKEN_LABEL)} released, ${fmt(fee)} ${esc(TOKEN_LABEL)} fee</span>
        </div>
      </div>
      <div class="rcpt-rows">
        <span class="rcpt-k">payee</span><span class="rcpt-v mono">${esc(link.creator)}</span>
        <span class="rcpt-k">payer</span><span class="rcpt-v mono">${esc(link.paidBy)}</span>
        <span class="rcpt-k">claimed</span><span class="rcpt-v">${esc(fmtDate(link.claimedAt))}</span>
      </div>
    </div>`);
    setNote("A link can only be claimed once, and only ever by its payee.");
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
    }

    setActions(html);
    setNote(`Gas is paid in OKB on chain ${CHAIN_ID}. pUSD (MOCK) is test scaffolding — do not send real funds.`);

    $("#mintBtn")?.addEventListener("click", () => runMint(id, account));
    $("#approveBtn")?.addEventListener("click", () => runApproveThenPay(id, need));
    $("#payBtn")?.addEventListener("click", () => runPay(id, need));
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
    const payHash = (await sendTx(PAGO, callData(SEL.pay, ["string", "uint256"], [id, amount]))).hash;
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
    const { hash } = await sendTx(PAGO, callData(SEL.pay, ["string", "uint256"], [id, amount]));
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
  const creator = (input.value || "").trim() || account || NET.payee;

  if (!isAddress(creator)) {
    list.innerHTML = `<div class="empty-line">That is not an address. Pago ledgers are keyed by a 0x… address, not a NEAR account name.</div>`;
    $("#ledgerStats").hidden = true;
    $("#ledgerFilters").hidden = true;
    return;
  }
  input.value = creator;

  list.innerHTML = `<div class="empty-line">Reading ${truncate(creator, 10, 6)} from the chain…</div>`;
  $("#ledgerStats").hidden = true;
  $("#ledgerFilters").hidden = true;

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

    renderLedger();
  } catch (err) {
    ledgerLinks = [];
    list.innerHTML = `<div class="empty-line">Could not read the chain: ${esc(friendly(err))}
      <div class="cancel-row"><button class="btn ghost" type="button" id="ledgerRetry"><span>Try again</span></button></div></div>`;
    $("#ledgerRetry")?.addEventListener("click", loadLedger);
  }
}

/* ── boot ───────────────────────────────────────────────────────────────── */

function paintStatic() {
  const tokenLabel = $("#tokenLabel");
  const tokenAddr = $("#tokenAddr");
  const tokenBadge = $("#tokenBadge");
  const amountSymbol = $("#amountSymbol");
  if (tokenLabel) tokenLabel.textContent = TOKEN_LABEL;
  if (amountSymbol) amountSymbol.textContent = NET.tokenSymbol;
  if (tokenAddr) {
    tokenAddr.textContent = TOKEN;
    tokenAddr.title = NET.tokenExplorerUrl;
  }
  if (tokenBadge) tokenBadge.textContent = MOCK ? "MOCK" : "allowlisted";

  const note = $("#tokenNote");
  if (note) {
    note.innerHTML = MOCK
      ? `<strong>${esc(TOKEN_LABEL)}</strong> is a freely mintable test token with no backing and no redemption value. Every amount on this page is fake money.`
      : `${esc(TOKEN_LABEL)} is the allowlisted token for this deployment.`;
  }

  const input = $("#creatorInput");
  if (input && !input.value) input.value = NET.payee;

  const hero = $("#heroChainNote");
  if (hero) {
    hero.innerHTML = `Chain ${CHAIN_ID} &middot; token <strong>${esc(TOKEN_LABEL)}</strong> &middot; fixed ${NET.feeBps / 100}% fee &middot; no relayer, no custody.`;
  }
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

function initTheme() {
  let theme = document.documentElement.dataset.theme || "light";
  const apply = (t) => {
    document.documentElement.dataset.theme = t;
    const meta = document.getElementById("themeColor");
    if (meta) meta.content = t === "dark" ? "#0A0A0A" : "#99f7d5";
    const btn = document.getElementById("themeBtn");
    if (btn) {
      const next = t === "dark" ? "light" : "dark";
      btn.setAttribute("aria-label", `Switch to ${next} mode`);
      btn.title = `Switch to ${next} mode`;
    }
  };
  apply(theme);
  document.getElementById("themeBtn")?.addEventListener("click", () => {
    theme = theme === "dark" ? "light" : "dark";
    apply(theme);
    try { localStorage.setItem("paylink:theme", theme); } catch { /* private mode */ }
  });
}

function boot() {
  initTheme();
  paintStatic();
  paintWallet();
  wireTabs();
  wireWalletEvents();

  $("#walletBtn")?.addEventListener("click", async () => {
    if (account) {
      account = null;
      paintWallet();
      toast("Wallet disconnected from this page.");
      return;
    }
    await connect();
    if (currentPanel === "ledger" && ledgerLoaded) loadLedger();
  });
  $("#heroConnect")?.addEventListener("click", async () => {
    if (await connect() && currentPanel === "ledger" && ledgerLoaded) loadLedger();
  });

  $("#createForm")?.addEventListener("submit", onCreate);

  $("#ledgerLoad")?.addEventListener("click", loadLedger);
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
