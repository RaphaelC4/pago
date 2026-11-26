#!/usr/bin/env node
/* record-demo.mjs — records the real-product footage for the ≤3-min demo video.
 *
 * One Playwright context per segment → one webm clip each (1920×1080), plus
 * the title cards as PNGs. Everything here points at the LIVE site
 * (https://pago-nu.vercel.app) with no mocks, no wallet and no signing:
 * this file can only *read* the product. The wallet moments — create, the
 * gasless sign, the claim — are recorded by hand in the user's own browser
 * (docs/DEMO-VIDEO.md), because signatures stay in the user's hand.
 *
 * What each clip is for (story spine: demand → problem → Pago → X Layer /
 * TapeOut → impact → model → close):
 *   01-landing      splash plays out, hero, ticker, why-block, footer
 *   02-create       form fill: amount, note, split gate 0% → 60% → 100%
 *                   (stops before Create — the wallet boundary is on camera
 *                   in the human's segment, not faked here)
 *   03-share        share card for a real claimed invoice + Copy flash
 *   04-pay-testnet  claimed receipt, RULE-table claim: pool 0.995000,
 *                   fee 0.005000, seat legs incl. 0.497500 to the payee —
 *                   the circuit's own selection, read from claim events
 *   05-pay-mainnet  same card on chain 196: 0.1 USD₮0 settled for real
 *   06-ledger       empty state → bell asks for a wallet → type an address
 *                   → live rows → filter Claimed → back to All
 *   07-tapeout      mainnet create head: USD₮0 pill + the live policy read
 *                   printing "Circuit pinned on mainnet."
 *
 * Honesty rules this script keeps, by construction:
 *   - every frame is the deployed UI answering real eth_calls; if a read
 *     fails the segment fails and is re-run — nothing is patched over;
 *   - the circuit pin line is waited on, never typed: if the chain does
 *     not answer, 07 fails rather than showing a claim that wasn't read;
 *   - no `#proof` footage (it stays hidden on the site).
 *
 * Usage (from e2e/):
 *   node record-demo.mjs                  # title cards + all seven segments
 *   node record-demo.mjs --cards          # title cards only
 *   node record-demo.mjs --only pay       # segments whose name matches (comma: --only 02,03)
 *
 * Output: video/cards/*.png (+ .html source) and video/clips/*.webm
 * (+ .marker.json where a clip needs trimming in the edit).
 */

import { chromium } from "@playwright/test";
import { mkdir, readFile, writeFile, rename, rm } from "node:fs/promises";
import { join, dirname } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { XLAYER } from "../frontend/config.js";

const E2E = dirname(fileURLToPath(import.meta.url));
const VIDEO = join(E2E, "video");
const CLIPS = join(VIDEO, "clips");
const CARDS = join(VIDEO, "cards");
const FONT_DIR = join(E2E, "..", "frontend", "fonts");

const BASE = "https://pago-nu.vercel.app";
const W = 1920;
const H = 1080;
const PAYEE = XLAYER.pago.testnet.payee;

/* ── small helpers ──────────────────────────────────────────────────────── */

const pause = (page, ms) => page.waitForTimeout(ms);

/* The site's splash runs a fixed 5.6s timeline (4s fill → Ready → Welcome)
   and clicking releases it early. Landing plays it out — it is the opening
   shot; every other segment skips it to keep the clip tight. */
async function settleSplash(page, mode) {
  const splash = page.locator("#splash");
  if ((await splash.count()) === 0) return; // xlayer.html has no splash
  if (mode === "play") {
    try {
      await splash.waitFor({ state: "hidden", timeout: 7500 });
      return;
    } catch {
      /* timeline never finished (a slow asset): release it like a tap */
    }
  }
  await page.evaluate(() => document.getElementById("splash")?.click());
  await splash.waitFor({ state: "hidden", timeout: 10000 });
}

/* One poll loop for every "wait until the page says X" condition. Using
   page.evaluate instead of waitForFunction keeps the signatures honest —
   one function, one timeout, no arg/options ambiguity. */
async function waitFor(page, fn, { timeout = 30_000, interval = 250, label = "condition" } = {}) {
  const t0 = Date.now();
  for (;;) {
    if (await page.evaluate(fn)) return;
    if (Date.now() - t0 > timeout) throw new Error(`timed out waiting for ${label}`);
    await page.waitForTimeout(interval);
  }
}

/* The connection dot only turns .ok when feeBps + allowlist both answered.
   A cold or flaky RPC leaves it on "chain unreachable" with no self-heal,
   so reload until it is honest — reloads keep the hash, so the segment
   stays on its page. */
async function ensureHealthy(page, tries = 4) {
  for (let attempt = 1; attempt <= tries; attempt++) {
    try {
      await page.waitForSelector("#netDot.ok", { timeout: 15_000 });
      return;
    } catch {
      if (attempt === tries) throw new Error("chain health dot never turned green");
      await page.reload({ waitUntil: "domcontentloaded" });
      await settleSplash(page, "skip");
      await prepScroll(page);
    }
  }
}

/* scroll-behavior:smooth would compound with the stepped scroll below; the
   recording session turns it off (runtime style only — not the site). */
const prepScroll = (page) =>
  page.evaluate(() => {
    document.documentElement.style.scrollBehavior = "auto";
  });

async function smoothScrollTo(page, targetY, { steps = 30, stepMs = 40 } = {}) {
  const end = await page.evaluate((y) => {
    const max = document.documentElement.scrollHeight - window.innerHeight;
    return Math.max(0, Math.min(y, max));
  }, targetY);
  await page.evaluate(
    async ({ end, steps, stepMs }) => {
      const start = window.scrollY;
      for (let i = 1; i <= steps; i++) {
        window.scrollTo(0, start + ((end - start) * i) / steps);
        await new Promise((r) => setTimeout(r, stepMs));
      }
      window.scrollTo(0, end);
    },
    { end, steps, stepMs }
  );
}

async function scrollToSel(page, sel, opts) {
  const y = await page.evaluate((s) => {
    const el = document.querySelector(s);
    if (!el) throw new Error(`scroll target missing: ${s}`);
    return el.getBoundingClientRect().top + window.scrollY - 110;
  }, sel);
  await smoothScrollTo(page, y, opts);
}

/* Playwright's video has no cursor, so this exists to land real :hover
   states on buttons before a click — the footage should look lived in. */
async function moveTo(page, locator) {
  const box = await locator.boundingBox();
  if (box) await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2, { steps: 20 });
}

/* Shared by the two receipt clips: the card renders first, the payout
   events fill later (locate-then-read against a 100-block log cap — 30-90s
   on testnet, longer when the mainnet RPC's DNS is having a moment).
   Retry buttons are clicked, never waited around: the footage starts its
   choreography only once the receipt is complete, and the marker says how
   much of the head of the clip is dead air for the edit to cut. */
async function waitForClaimCard(page, { cardMs = 120_000, totalMs = 240_000 } = {}) {
  const t0 = Date.now();
  const elapsed = () => Date.now() - t0;
  while (!(await page.locator("#claimResult").count())) {
    const retry = page.locator("#payRetry");
    if (await retry.count()) {
      await retry.click();
      await retry.waitFor({ state: "detached", timeout: 5000 }).catch(() => {});
    }
    if (elapsed() > cardMs) throw new Error("the pay card never rendered");
    await page.waitForTimeout(1500);
  }
  const cardSec = elapsed() / 1000;
  while (!(await page.locator("#claimPdf").count())) {
    const retry = page.locator("#claimRetry");
    if (await retry.count()) {
      await retry.click();
      await retry.waitFor({ state: "detached", timeout: 5000 }).catch(() => {});
    }
    if (elapsed() > totalMs) throw new Error("the claim evidence never filled");
    await page.waitForTimeout(1500);
  }
  return { cardSec, evidenceSec: Number((elapsed() / 1000).toFixed(1)) };
}

async function writeMarker(name, data) {
  await writeFile(join(CLIPS, `${name}.marker.json`), JSON.stringify(data, null, 2), "utf8");
}

/* Common opening for every onboarding segment: land on the final document
   (the root redirects through index.html), settle the splash, unfreeze
   smooth scrolling, then demand an honest connection dot. */
async function openSite(page, url, { splash = "skip" } = {}) {
  await page.goto(url, { waitUntil: "domcontentloaded" });
  await page.waitForURL(/pago-onboarding\.html/, { timeout: 20_000 });
  await settleSplash(page, splash);
  await prepScroll(page);
  await ensureHealthy(page);
}

/* ── segments ───────────────────────────────────────────────────────────── */

const SEGMENTS = [
  {
    name: "01-landing",
    async run(page) {
      await page.goto(`${BASE}/`, { waitUntil: "domcontentloaded" });
      await page.waitForURL(/pago-onboarding\.html/, { timeout: 20_000 });
      await settleSplash(page, "play"); // the branded opener, in full
      await prepScroll(page);
      await ensureHealthy(page);
      await page.waitForSelector(".lp-title", { state: "visible" });
      await pause(page, 2600); // hero: chip, "Send a link. Get paid.", stats
      await moveTo(page, page.locator(".hero-actions .btn").first());
      await pause(page, 900);
      await scrollToSel(page, ".lp-ticker");
      await pause(page, 2000); // marquee: 0.5% flat fee, gasless payer path…
      await scrollToSel(page, "#why");
      await pause(page, 2400); // why-block: the bento of claims
      await scrollToSel(page, "#footerSafetyNote");
      await pause(page, 2000); // footer + the check-the-explorer safety line
      await smoothScrollTo(page, 0, { steps: 34, stepMs: 34 });
      await pause(page, 800);
    },
  },

  {
    name: "02-create",
    async run(page) {
      await openSite(page, `${BASE}/#create`);
      await page.waitForSelector("#createForm", { state: "visible" });
      await waitFor(
        page,
        () => {
          const t = document.getElementById("tokenLabel");
          return !!t && !t.textContent.includes("Loading");
        },
        { label: "the token pill to fill in" }
      );
      await pause(page, 1600); // head "What are you owed?" + pUSD (MOCK) pill

      const amount = page.locator("#amount");
      await moveTo(page, amount);
      await amount.click();
      await amount.pressSequentially("120", { delay: 110 });
      const note = page.locator("#description");
      await moveTo(page, note);
      await note.click();
      await note.pressSequentially("Brand identity — milestone 1", { delay: 42 });
      await pause(page, 800);

      await scrollToSel(page, "#splitToggle");
      await pause(page, 600);
      const sw = page.locator("label.split-switch");
      await moveTo(page, sw);
      await sw.click();
      await pause(page, 1000); // 0% — the gate refuses, Create stays disabled

      const shares = page.locator("#splitEditor .split-share");
      await shares.nth(0).click();
      await shares.nth(0).pressSequentially("60", { delay: 110 });
      await pause(page, 900); // 60% — still short of 100
      await shares.nth(1).click();
      await shares.nth(1).pressSequentially("40", { delay: 110 });
      await pause(page, 1500); // 100% — the total goes green, Create enables

      await scrollToSel(page, "#createBtn");
      await moveTo(page, page.locator("#createBtn"));
      await pause(page, 1400);
      /* Stop here on purpose: pressing Create crosses into signing, and the
         signature is recorded in the human's browser, not simulated here. */
    },
  },

  {
    name: "03-share",
    async run(page) {
      await openSite(page, `${BASE}/#ready/pago-261125-020108-a`);
      await page.waitForSelector("#readyCard .share-url code", { state: "visible", timeout: 60_000 });
      await pause(page, 2400); // card: description, status, URL, QR

      const copy = page.locator("#copyLink");
      await moveTo(page, copy);
      await copy.click();
      try {
        await waitFor(page, () => document.getElementById("copyLink")?.textContent === "Copied", {
          timeout: 3000,
          interval: 100,
          label: "the Copied flash",
        });
      } catch {
        /* clipboard refused: keep the card, lose the flash — never fake it */
      }
      await pause(page, 1200); // toast "Link copied."

      await scrollToSel(page, "#readyCard .detail-grid", { steps: 20, stepMs: 38 });
      await pause(page, 2000); // amount / you receive / fee / link id / network
    },
  },

  {
    name: "04-pay-testnet",
    async run(page) {
      await page.goto(`${BASE}/xlayer.html#pay/pago-261125-020108-a`, {
        waitUntil: "domcontentloaded",
      });
      await prepScroll(page);
      await ensureHealthy(page);
      const marks = await waitForClaimCard(page);
      await writeMarker("04-pay-testnet", marks);

      await page.evaluate(() => window.scrollTo(0, 0));
      await pause(page, 2200); // header: description, 1.000000 pUSD, Claimed
      await scrollToSel(page, "#claimResult");
      await pause(page, 2600); // "Paid out to the payee" · pool 0.995000 · fee

      const details = page.locator("#claimRows details summary");
      if (await details.count()) {
        await moveTo(page, details);
        await details.click();
        await pause(page, 2200); // seat legs: 0.497500 → payee + claim tx
      }
      await scrollToSel(page, "#claimFoot", { steps: 18, stepMs: 38 });
      await moveTo(page, page.locator("#claimPdf"));
      await pause(page, 2400); // receipt sentence + Download PDF receipt
    },
  },

  {
    name: "05-pay-mainnet",
    async run(page) {
      await page.goto(`${BASE}/xlayer.html?chainId=196#pay/pago-261125-demo01`, {
        waitUntil: "domcontentloaded",
      });
      await prepScroll(page);
      await ensureHealthy(page, 5); // mainnet RPC's DNS is the flaky one
      const marks = await waitForClaimCard(page, { cardMs: 150_000, totalMs: 300_000 });
      await writeMarker("05-pay-mainnet", marks);

      await page.evaluate(() => window.scrollTo(0, 0));
      await pause(page, 2400); // X Layer (196) · 0.1 USD₮0 · Claimed
      await scrollToSel(page, "#claimResult");
      await pause(page, 2600); // the real settlement: pool, fee, payer
      const details = page.locator("#claimRows details summary");
      if (await details.count()) {
        await moveTo(page, details);
        await details.click();
        await pause(page, 2000);
      }
      await scrollToSel(page, "#claimFoot", { steps: 18, stepMs: 38 });
      await moveTo(page, page.locator("#claimPdf"));
      await pause(page, 2400);
    },
  },

  {
    name: "06-ledger",
    async run(page) {
      await openSite(page, `${BASE}/#ledger`);
      await page.waitForSelector("#ledgerList .empty-line", { state: "visible", timeout: 30_000 });
      await pause(page, 2200); // empty until a wallet or an address shows up

      const bell = page.locator("#bellBtn");
      await moveTo(page, bell);
      await bell.click();
      await pause(page, 2000); // activity popover asks for a wallet too
      await bell.click();
      await pause(page, 600);

      const input = page.locator("#creatorInput");
      await moveTo(page, input);
      await input.click();
      await input.pressSequentially(PAYEE, { delay: 45 });
      await pause(page, 700);
      const load = page.locator("#ledgerLoad");
      await moveTo(page, load);
      await load.click();
      await page.waitForSelector("#ledgerList .row-main", { timeout: 90_000 });
      await pause(page, 1800); // stats + rows straight from getLinksByCreator

      const claimed = page.locator('#ledgerFilters [data-filter="claimed"]');
      await moveTo(page, claimed);
      await claimed.click();
      await pause(page, 1700);
      const all = page.locator('#ledgerFilters [data-filter="all"]');
      await moveTo(page, all);
      await all.click();
      await pause(page, 1000);

      await scrollToSel(page, "#ledgerList", { steps: 16, stepMs: 40 });
      await pause(page, 1500);
    },
  },

  {
    name: "07-tapeout",
    async run(page) {
      /* The slash must NOT sit between the query and the hash: in
         "?chainId=196/#create" the query value parses as "196/", Number()
         is NaN, and xlayer.js silently falls back to testnet — the pin line
         would then print the testnet note forever. */
      await openSite(page, `${BASE}/?chainId=196#create`);
      await page.waitForSelector("#createForm", { state: "visible" });
      await waitFor(
        page,
        () => {
          const t = document.getElementById("tokenLabel");
          return !!t && t.textContent.includes("USD₮0");
        },
        { label: "the mainnet USD₮0 pill — is ?chainId=196 being honored?" }
      );

      /* The pin line fills once from the live policy read; a failed read
         leaves it hidden for the life of the load (dataset.done guard), so
         retry by reloading. Never print a circuit claim the chain did not
         answer — if it never fills, this segment fails honestly. */
      let pin = null;
      for (let attempt = 0; attempt < 3 && !pin; attempt++) {
        try {
          await waitFor(
            page,
            () => {
              const el = document.getElementById("createPinLine");
              return !!el && !el.hidden && /Circuit/.test(el.textContent);
            },
            { timeout: 20_000, label: "the mainnet circuit pin line" }
          );
          pin = await page.evaluate(() => document.getElementById("createPinLine").textContent.trim());
        } catch {
          if (attempt === 2) throw new Error("mainnet circuit pin line never filled");
          await page.reload({ waitUntil: "domcontentloaded" });
          await settleSplash(page, "skip");
          await prepScroll(page);
          await ensureHealthy(page, 3);
          await page.waitForSelector("#createForm", { state: "visible" });
        }
      }
      await writeMarker("07-tapeout", { pin });

      await scrollToSel(page, "#createPinLine", { steps: 18, stepMs: 40 });
      await pause(page, 3200); // "Circuit pinned on mainnet." + USD₮0 pill
      await moveTo(page, page.locator("#tokenLabel"));
      await pause(page, 1200);
    },
  },
];

/* ── title cards ────────────────────────────────────────────────────────── */

/* Copy follows the narration spine (docs/DEMO-VIDEO.md holds the timed
   script): demand → problem → Pago → X Layer/TapeOut → impact → model →
   close. Same tokens as pago-home.css: #0a0a0a, Satoshi, the #bcff2f
   accent. Fonts are inlined from frontend/fonts so the cards render from
   file:// with no network. */
const CARDS_SPEC = [
  {
    name: "c0-open",
    eyebrow: "TapeOut hackathon · X Layer",
    head: `Send a link.<br><span class="g">Get paid.</span>`,
    sub: `Pago turns a payment request into a URL — paid in stablecoins, settled on chain, checkable by anyone.`,
  },
  {
    name: "c1-demand",
    eyebrow: "The demand",
    head: `Money moves in chat.<br>Getting paid doesn't.`,
    sub: `People already ask to be paid in messages every day. The links they get sent still demand sign-ups, card details, and days of settlement.`,
  },
  {
    name: "c2-problem",
    eyebrow: "The problem",
    head: `Payment links still need<br><span class="g">an account on both sides.</span>`,
    sub: `Invoicing platforms onboard the payer, hold the funds, and can reverse them. Cross-border adds fees, chargebacks, and a waiting game.`,
  },
  {
    name: "c3-pago",
    eyebrow: "What Pago does",
    head: `One link.<br><span class="g">Stablecoins on X Layer.</span>`,
    sub: `You create it in one signed transaction. They open the URL — no account, no app — and sign once. 0.5% flat; 99.5% released to you on claim.`,
  },
  {
    name: "c4-ecosystem",
    eyebrow: "X Layer · TapeOut",
    head: `Settled on X Layer.<br><span class="g">Verified by TapeOut.</span>`,
    sub: `Every payout runs through a hardware-checked circuit. The netlist hash, allowlisted processor, and circuit id are printed on the receipt.`,
  },
  {
    name: "c5-impact",
    eyebrow: "Why it matters",
    head: `Minutes, not banking days.<br><span class="g">No middleman.</span>`,
    sub: `No admin keys and no account to freeze — funds move only through the contract, and every payout is re-readable from chain state, not from our servers.`,
  },
  {
    name: "c6-model",
    eyebrow: "Business model",
    head: `<span class="g">0.5% flat,</span><br>only when money moves.`,
    sub: `Free to create, free to open, free to read. One fee, taken once on payout — no subscription, no listing fee, no spread.`,
  },
  {
    name: "c7-end",
    eyebrow: "Try it · submission",
    head: `<span class="g">pago-nu.vercel.app</span>`,
    sub: `Payment links on X Layer · built for the TapeOut hackathon`,
  },
];

function cardHtml(card, fonts) {
  return `<!doctype html>
<html lang="en"><head><meta charset="utf-8"><title>${card.name}</title>
<style>
@font-face{font-family:"Satoshi";src:url("data:font/woff2;base64,${fonts[400]}") format("woff2");font-weight:400;font-style:normal;font-display:block}
@font-face{font-family:"Satoshi";src:url("data:font/woff2;base64,${fonts[500]}") format("woff2");font-weight:500;font-style:normal;font-display:block}
@font-face{font-family:"Satoshi";src:url("data:font/woff2;base64,${fonts[700]}") format("woff2");font-weight:700;font-style:normal;font-display:block}
*{margin:0;padding:0;box-sizing:border-box}
html,body{width:${W}px;height:${H}px;overflow:hidden}
body{background:#0a0a0a;color:#f4f4f3;font-family:"Satoshi",system-ui,sans-serif;position:relative;
  display:flex;flex-direction:column;justify-content:center;padding:0 160px;-webkit-font-smoothing:antialiased}
body::before{content:"";position:absolute;inset:0;pointer-events:none;
  background:radial-gradient(1100px 640px at 80% 8%,rgba(91,165,240,.12),transparent 62%),
             radial-gradient(900px 620px at 8% 96%,rgba(188,255,47,.06),transparent 60%)}
.rule{position:absolute;left:160px;right:160px;height:1px;background:#1f1f1e}
.rule.top{top:96px}.rule.bot{bottom:150px}
.eyebrow{position:relative;font-size:25px;font-weight:500;letter-spacing:.34em;text-transform:uppercase;
  color:#8a8a88;margin-bottom:46px}
h1{position:relative;font-size:104px;line-height:1.06;font-weight:700;letter-spacing:-.022em;max-width:1600px}
h1 .g{color:#bcff2f}
.sub{position:relative;margin-top:46px;font-size:35px;line-height:1.52;color:#b9b9b6;max-width:1420px}
.foot{position:absolute;left:160px;bottom:64px;display:flex;gap:26px;align-items:baseline;
  color:#8a8a88;font-size:25px;letter-spacing:.05em}
.foot b{color:#f4f4f3;font-weight:500;letter-spacing:.16em;text-transform:uppercase;font-size:23px}
</style></head><body>
<div class="rule top"></div>
<div class="eyebrow">${card.eyebrow}</div>
<h1>${card.head}</h1>
<p class="sub">${card.sub}</p>
<div class="rule bot"></div>
<div class="foot"><b>Pago</b><span>pago-nu.vercel.app</span></div>
</body></html>`;
}

async function buildCards(browser) {
  const fonts = {};
  for (const [weight, file] of [
    [400, "satoshi-400.woff2"],
    [500, "satoshi-500.woff2"],
    [700, "satoshi-700.woff2"],
  ]) {
    fonts[weight] = (await readFile(join(FONT_DIR, file))).toString("base64");
  }
  const context = await browser.newContext({
    viewport: { width: W, height: H },
    deviceScaleFactor: 1,
    colorScheme: "dark",
  });
  const page = await context.newPage();
  for (const card of CARDS_SPEC) {
    const htmlPath = join(CARDS, `${card.name}.html`);
    await writeFile(htmlPath, cardHtml(card, fonts), "utf8");
    await page.goto(pathToFileURL(htmlPath).href, { waitUntil: "load" });
    await page.evaluate(() => document.fonts.ready);
    await page.waitForTimeout(150);
    await page.screenshot({ path: join(CARDS, `${card.name}.png`) });
    console.log(`  ▢ cards/${card.name}.png`);
  }
  await context.close();
}

/* ── main ───────────────────────────────────────────────────────────────── */

async function main() {
  const args = process.argv.slice(2);
  const onlyIdx = args.indexOf("--only");
  const only = onlyIdx >= 0 ? args[onlyIdx + 1] : null;
  const cardsOnly = args.includes("--cards");

  await mkdir(CLIPS, { recursive: true });
  await mkdir(CARDS, { recursive: true });

  const browser = await chromium.launch({
    /* The headless-shell binary is not installed on this machine; the full
       Chromium build is, and channel "chromium" runs it in the modern
       headless mode — same rendering as a visible window, no download. */
    channel: "chromium",
    args: ["--hide-scrollbars", "--force-color-profile=srgb"],
  });
  try {
    if (!only) {
      console.log("title cards →");
      await buildCards(browser);
    }

    if (!cardsOnly) {
      const failures = [];
      for (const seg of SEGMENTS) {
        if (only && !only.split(",").some((n) => seg.name.includes(n))) continue;
        console.log(`▶ ${seg.name}`);
        const t0 = Date.now();
        const context = await browser.newContext({
          viewport: { width: W, height: H },
          deviceScaleFactor: 1,
          locale: "en-US",
          colorScheme: "dark",
          recordVideo: { dir: CLIPS, size: { width: W, height: H } },
        });
        await context.grantPermissions(["clipboard-read", "clipboard-write"]);
        const page = await context.newPage();
        page.setDefaultTimeout(45_000);
        page.setDefaultNavigationTimeout(60_000);
        page.on("pageerror", (e) => console.log(`  ! page error: ${e.message}`));
        page.on("console", (m) => {
          if (m.type() === "error") console.log(`  ! console: ${m.text()}`);
        });
        try {
          await seg.run(page);
          console.log(`  ✓ ${((Date.now() - t0) / 1000).toFixed(1)}s`);
        } catch (err) {
          failures.push(`${seg.name}: ${err.message}`);
          console.error(`  ✗ ${err.message}`);
        }
        /* The Video object hangs off the page, not the context; grab it
           before close() and ask it for the path after the finalization
           that close() performs. */
        const video = page.video();
        await context.close();
        if (video) {
          const src = await video.path();
          const dst = join(CLIPS, `${seg.name}.webm`);
          await rm(dst, { force: true });
          await rename(src, dst);
          console.log(`  → clips/${seg.name}.webm`);
        }
      }
      if (failures.length) {
        console.error(`\n${failures.length} segment(s) failed — re-run just those with --only <name>:`);
        for (const f of failures) console.error(`  - ${f}`);
        process.exitCode = 1;
      } else {
        console.log("\nall segments recorded.");
      }
    }
  } finally {
    await browser.close();
  }
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
