/* X Layer / Pago — smoke suite (mocked chain, no wallet, no egress).
 *
 * One module serves both documents: frontend/xlayer.html now owns only the
 * payment card, while the landing, create form and ledger live on
 * frontend/pago-onboarding.html — a bare visit to xlayer.html follows
 * route()'s redirect across, and the first four tests below ride it and
 * assert the site's own copy. Every chain byte either page reads comes
 * from fixtures/xlayer-mocks.mjs, encoded with the same frontend/abi.js
 * the browser uses, so this suite asserts rendering, routing and honest
 * failure without a wallet — and never claims a payment happened. Signing
 * is deliberately unreachable here: there is no window.ethereum, so the
 * create path must fail loudly rather than pretend.
 *
 * Runs under the `smoke` project only (specs/testnet/ is excluded there).
 */

import { test, expect } from "@playwright/test";
import { makeScenario, installMocks } from "../fixtures/mocks.mjs";
import { installXLayerMocks, xlPayUrl } from "../fixtures/xlayer-mocks.mjs";

/* installMocks() first (it owns the catch-all), then the X Layer route —
 * Playwright matches the most recently registered route first, so the RPC
 * is answered by the fixture rather than aborted as off-allowlist. */
async function openPago(page, path = "/xlayer.html") {
  const scenario = makeScenario();
  const { errors } = await installMocks(page, scenario);
  const xl = await installXLayerMocks(page);
  await page.goto(path);
  /* The site opens behind a ~5 s splash that swallows pointer events;
     close it the way a tap does so the header links are tappable at once.
     (xlayer.html has no splash — the id simply isn't there there.) */
  await page.evaluate(() => document.getElementById("splash")?.click());
  return { errors, scenario, xl };
}

test.describe("X Layer / Pago page", () => {
  test("boots from files alone and reports a healthy chain from the mocked RPC", async ({ page }) => {
    const { errors, scenario, xl } = await openPago(page);

    /* The landing lives on the site now: a bare visit to xlayer.html must
       land there rather than on a document that has no home panel. */
    await expect(page).toHaveURL(/pago-onboarding\.html/);
    await expect(page).toHaveTitle("Pago — Send a link. Get paid on X Layer.");
    await expect(page.locator("#panel-home h1")).toContainText("Send a link.");
    await expect(page.locator("#panel-home h1 .accent")).toContainText("Get paid.");
    /* The redesign's four-stat hero row stands where the old three-step
       list was; it must be exactly four, not a stray markup drift. */
    await expect(page.locator("#panel-home .lp-stat")).toHaveCount(4);

    /* The connection dot is driven by a real eth_call (feeBps + allowlist),
       so a green dot means the mocked chain answered, not that we hoped. */
    await expect(page.locator("#netDot.ok")).toBeVisible({ timeout: 15_000 });
    await expect(page.locator("#netLabel")).toHaveText("X Layer testnet");

    /* No injected wallet in this browser: the header must say so rather
       than showing an address it does not have. */
    await expect(page.locator("#walletLabel")).toHaveText("No wallet");

    /* The footer keeps the honest line — no audit claim, and the reader
       is told to read the contract addresses back. MOCK labelling itself
       is asserted on the create form below, where the token is named. */
    await expect(page.locator(".lp-footer")).toContainText("not independently audited");
    await expect(page.locator(".lp-footer")).toContainText("Read the contract addresses back");

    expect(scenario.unexpected, "the page must not reach beyond the mocked allowlist").toEqual([]);
    expect(errors, "boot must produce no console errors").toEqual([]);
    expect(
      xl.log.filter((m) => m.startsWith("eth_send") || m === "eth_signTypedData_v4"),
      "a read-only boot must never ask for a signature"
    ).toEqual([]);
  });

  test("section tabs swap panels and drive the hash", async ({ page }) => {
    const { errors, scenario } = await openPago(page);
    await expect(page).toHaveURL(/pago-onboarding\.html/);

    /* The site's tabs are header links carrying data-tab, not the old
       #tab-* buttons the flat app had. */
    await page.locator('[data-tab="create"]').first().click();
    await expect(page.locator("#panel-create")).toBeVisible();
    await expect(page.locator("#panel-home")).toBeHidden();
    await expect(page).toHaveURL(/#create$/);

    await page.locator('[data-tab="ledger"]').first().click();
    await expect(page.locator("#panel-ledger")).toBeVisible();
    await expect(page).toHaveURL(/#ledger$/);

    /* No "home" tab: the brand mark is the way back. */
    await page.locator(".brand").click();
    await expect(page.locator("#panel-home")).toBeVisible();

    expect(scenario.unexpected).toEqual([]);
    expect(errors).toEqual([]);
  });

  test("the create form labels the token MOCK and refuses to pretend without a wallet", async ({ page }) => {
    const { errors, xl } = await openPago(page);
    await expect(page).toHaveURL(/pago-onboarding\.html/);
    await page.locator('[data-tab="create"]').first().click();

    await expect(page.locator("#tokenLabel")).toHaveText("pUSD (MOCK)");
    await expect(page.locator("#tokenBadge")).toHaveText("MOCK");
    await expect(page.locator("#tokenNote")).toContainText("freely mintable test token");
    /* The note is required, and the label says so in plain words — the
       banned "required by the contract" phrasing must not come back. */
    await expect(page.locator("label[for=description]")).toContainText("required");
    await expect(page.locator("label[for=description]")).not.toContainText("contract");

    await page.locator("#amount").fill("2.5");
    await page.locator("#description").fill("smoke fixture invoice");
    await page.locator("#createBtn").click();

    /* No window.ethereum exists here, so the page must fail loudly and say
       why — a silent "created" would be a lie the chain never told. */
    await expect(page.locator("#createResult")).toBeVisible();
    await expect(page.locator("#createResult")).toContainText("Connect a wallet to create a link");
    expect(xl.log.filter((m) => m === "eth_sendTransaction")).toEqual([]);
    expect(errors).toEqual([]);
  });

  test("the ledger reads fixtures, counts states and filters without a wallet", async ({ page }) => {
    const { errors, xl } = await openPago(page);
    await expect(page).toHaveURL(/pago-onboarding\.html/);
    await page.locator('[data-tab="ledger"]').first().click();

    /* Default creator is the configured payee, so the read-only path works
       with nothing connected — that is what the live testnet project uses. */
    await expect(page.locator("#creatorInput")).not.toHaveValue("");
    await expect(page.locator("#ledgerList .row-main")).toHaveCount(3, { timeout: 15_000 });

    await expect(page.locator("#statCount")).toHaveText("3");
    await expect(page.locator("#statOpen")).toHaveText("1");
    /* One claimed payout of 1.000000 minus the 0.5% fee = 0.995. */
    await expect(page.locator("#statReceived")).toHaveText("0.995");

    await expect(page.locator('#ledgerFilters [data-filter="open"] .f-n')).toHaveText("1");
    await expect(page.locator('#ledgerFilters [data-filter="claimed"] .f-n')).toHaveText("1");

    await page.locator('#ledgerFilters [data-filter="claimed"]').click();
    await expect(page.locator("#ledgerList .row-main")).toHaveCount(1);
    await expect(page.locator("#ledgerList .pill")).toHaveText("Claimed");

    await page.locator('#ledgerFilters [data-filter="all"]').click();
    await expect(page.locator("#ledgerList .row-main")).toHaveCount(3);

    expect(xl.log.every((m) => ["eth_call", "eth_chainId", "net_version"].includes(m) || m === "unknown"))
      .toBe(true);
    expect(errors).toEqual([]);
  });

  test("an unpaid invoice renders its amount, fee split and the no-wallet pay state", async ({ page }) => {
    const { errors } = await openPago(page, xlPayUrl("pago-e2e-0001-open"));

    await expect(page.locator("#payCard .pill")).toHaveText("Open", { timeout: 15_000 });
    await expect(page.locator("#payCard .pay-usd")).toContainText("2.5");
    await expect(page.locator("#payCard .pay-token")).toContainText("pUSD (MOCK)");
    await expect(page.locator("#payCard .pay-token")).toContainText("X Layer testnet");
    await expect(page.locator("#payCard .pay-desc")).toContainText("E2E fixture — unpaid invoice");

    /* The split is computed by the same formula the contract uses. */
    await expect(page.locator("#payCard .pay-items")).toContainText("2.4875"); // payout
    await expect(page.locator("#payCard .pay-items")).toContainText("0.0125"); // fee

    /* No wallet connected → the honest state, not a pay button that would
       fail in the signer. */
    await expect(page.locator("#payConnect")).toBeVisible();
    await expect(page.locator("#payNote")).toContainText("never needed a wallet");
    expect(errors).toEqual([]);
  });

  test("a claimed invoice shows the payout receipt and nothing payable", async ({ page }) => {
    const { errors } = await openPago(page, xlPayUrl("pago-e2e-0003-claimed"));

    /* Settled links show the receipt first — the redesign drops the old
       status-pill head row entirely, so there is no .pill to read. */
    await expect(page.locator("#payCard .pay-receipt")).toBeVisible({ timeout: 15_000 });
    await expect(page.locator("#payCard .pill")).toHaveCount(0);
    await expect(page.locator("#payCard .rcpt-state")).toContainText("Complete");
    await expect(page.locator("#payCard .pay-receipt")).toContainText("Paid out to the payee");
    await expect(page.locator("#payCard .pay-receipt")).toContainText("0.995");
    await expect(page.locator("#payBtn")).toHaveCount(0);
    await expect(page.locator("#payConnect")).toHaveCount(0);
    expect(errors).toEqual([]);
  });

  test("an unknown id says so instead of inventing an invoice", async ({ page }) => {
    const { errors } = await openPago(page, xlPayUrl("pago-does-not-exist"));

    await expect(page.locator("#payCard .empty-line")).toContainText("No link with the id", {
      timeout: 15_000,
    });
    await expect(page.locator("#payCard .pay-usd")).toHaveCount(0);
    expect(errors).toEqual([]);
  });

  test("a paid invoice offers the claim to anyone, because only the payee can receive it", async ({ page }) => {
    const { errors } = await openPago(page, xlPayUrl("pago-e2e-0002-paid"));

    await expect(page.locator("#payCard .pill")).toHaveText("Paid", { timeout: 15_000 });
    await expect(page.locator("#claimBtn")).toBeVisible();
    await expect(page.locator("#claimBtn")).toContainText("0.995");
    await expect(page.locator("#payCard .pay-fee")).toContainText("Anyone can press this");
    expect(errors).toEqual([]);
  });
});
