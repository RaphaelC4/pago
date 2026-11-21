/* @testnet — READ-ONLY live-chain checks for the X Layer / Pago page.
 *
 * Excluded from `smoke` and matched only by the `testnet` project, which
 * nothing in CI triggers: .github/workflows/e2e-testnet.yml runs it through
 * workflow_dispatch alone (see e2e/TESTNET.md).
 *
 * Rules this file obeys, by construction:
 *   - NO mocks: frontend/xlayer.html talks to the public X Layer testnet
 *     JSON-RPC (chain 1952) over `eth_call` — reads only;
 *   - NO wallet is ever connected and no button that leads to a signing
 *     prompt is clicked: creating, approving, paying and claiming stay
 *     human, in a dedicated testnet wallet (e2e/TESTNET.md);
 *   - NO repository secrets are read; nothing here could print one;
 *   - success is asserted on UI state only, and the link ids below are real
 *     invoices from the 2026-11-19 live re-check run (docs/RESEARCH.md §17) — if
 *     one of them is ever absent the test fails honestly rather than skipping.
 *
 * pUSD is MOCK. Nothing here presents it as a stablecoin, and every assertion
 * that names it names it as MOCK.
 */

import { test, expect } from "@playwright/test";

/* The 2026-11-19 MOCK-pinned frozen build's leg B: created, paid through the
   gasless payer path by a third party and claimed, settling through the
   DEFAULT table (claim event usedRuleSplit=false; payee received the full
   995,000 post-fee, which is what the receipt below shows). Its sibling leg A
   (pago-261119-124452-a) settled through the RULE table instead — payee
   497,500 plus the remaining seats to the rule table's other recipients —
   and is asserted in its own test further down, because the page's receipt
   now reads which table the circuit selected out of the claim event
   (docs/RESEARCH.md §17). */
const CLAIMED_LINK = "pago-261119-124452-b";

test.describe("X Layer testnet read-only", () => {
  test("the page's health check answers from the live X Layer RPC", async ({ page }) => {
    await page.goto("/xlayer.html");

    /* refreshChainInfo() issues two real eth_calls (feeBps + allowlist);
       the dot only turns green if both answered. An outage fails here. */
    await expect(page.locator("#netDot.ok")).toBeVisible({ timeout: 60_000 });
    await expect(page.locator("#netLabel")).toHaveText("X Layer testnet");
    await expect(page.locator("#panel-home h1")).toContainText("Send a link.");
    await expect(page.locator("#heroChainNote")).toContainText("pUSD (MOCK)");
    await expect(page.locator("#walletLabel")).toHaveText("No wallet");
  });

  test("a creator's ledger renders from live contract state", async ({ page }) => {
    await page.goto("/xlayer.html");
    await page.locator("#tab-ledger").click();

    /* The form ships prefilled with the payee address from config.js, so the
       read path needs no wallet — Load is the only click. */
    await expect(page.locator("#creatorInput")).not.toHaveValue("");
    await page.locator("#ledgerLoad").click();

    await expect(page.locator("#ledgerList .row-main").first()).toBeVisible({ timeout: 60_000 });

    const rows = await page.locator("#ledgerList .row-main").count();
    expect(rows, "the payee created links in the 2026-11-19 run — an empty ledger means the read failed").toBeGreaterThan(0);

    /* Stats must agree with the rows actually on screen. */
    await expect(page.locator("#statCount")).toHaveText(String(rows));

    /* The 2026-11-19 run ended with both links claimed; if none of them show,
       the status mapping or the decoder has drifted from the contract. */
    const pills = await page.locator("#ledgerList .pill").allTextContents();
    expect(pills.some((p) => p === "Claimed"), `expected a Claimed link, saw: ${pills.join(", ")}`).toBe(true);
    expect(pills.every((p) => ["Open", "Paid", "Claimed", "Cancelled", "Expired"].includes(p)))
      .toBe(true);
  });

  test("a real claimed invoice renders its payout from live state", async ({ page }) => {
    await page.goto(`/xlayer.html#pay/${encodeURIComponent(CLAIMED_LINK)}`);

    await expect(page.locator("#payCard .pill")).toHaveText("Claimed", { timeout: 60_000 });
    await expect(page.locator("#payCard .pay-token")).toContainText("pUSD (MOCK)");
    await expect(page.locator("#payCard .pay-token")).toContainText("X Layer testnet");
    await expect(page.locator("#payCard .pay-desc")).toContainText("live test: gasless payer path");

    /* 1.000000 credited, 0.5% fee → 0.995000 — but the receipt does not
       compute that: it locates the claim block (the RPC caps eth_getLogs at
       100 blocks), reads the LinkClaimed and LegPaid events of that exact
       transaction and prints what they say. The generous timeout is the
       locate-then-read trip, not a slow assertion. */
    await expect(page.locator("#payCard .pay-receipt")).toBeVisible({ timeout: 60_000 });
    await expect(page.locator("#payCard .pay-receipt")).toContainText("Paid out to the payee", { timeout: 60_000 });
    await expect(page.locator("#payCard .pay-receipt")).toContainText("0.995", { timeout: 60_000 });
    await expect(page.locator("#payCard .pay-receipt")).toContainText("default split", { timeout: 60_000 });

    /* Nothing payable on a settled invoice: no approve, no pay, no claim. */
    await expect(page.locator("#payBtn")).toHaveCount(0);
    await expect(page.locator("#approveBtn")).toHaveCount(0);
    await expect(page.locator("#claimBtn")).toHaveCount(0);
  });

  test("a rule-table claim shows which table the circuit selected", async ({ page }) => {
    /* Leg A of the same run: its rule table summed to exactly 20 steps, so
       the circuit accepted it and the claim paid the rule seats — 497,500
       to the payee, not the whole pool. The receipt must say "rule table"
       and print the seat the chain actually paid. */
    await page.goto(`/xlayer.html#pay/pago-261119-124452-a`);

    await expect(page.locator("#payCard .pill")).toHaveText("Claimed", { timeout: 60_000 });
    await expect(page.locator("#payCard .pay-receipt")).toContainText("Paid out to the payee", { timeout: 60_000 });
    await expect(page.locator("#payCard .pay-receipt")).toContainText("rule table", { timeout: 60_000 });
    await expect(page.locator("#payCard .pay-receipt")).toContainText("0.4975", { timeout: 60_000 });
    await expect(page.locator("#payCard .pay-receipt")).toContainText("0.005", { timeout: 60_000 });
  });

  test("an unknown id says so instead of inventing an invoice", async ({ page }) => {
    await page.goto("/xlayer.html#pay/pago-this-id-never-existed");
    await expect(page.locator("#payCard .empty-line")).toContainText("No link with the id", {
      timeout: 60_000,
    });
    await expect(page.locator("#payCard .pay-usd")).toHaveCount(0);
  });
});
