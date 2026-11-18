/* Deterministic X Layer RPC layer for the smoke suite.
 *
 * The X Layer page (frontend/xlayer.html) talks to exactly one host — the
 * testnet JSON-RPC endpoint in frontend/config.js — and this answers it in
 * process, so a smoke test needs no network egress and can never touch a
 * live endpoint. It is registered AFTER installMocks()'s catch-all, because
 * Playwright matches the most recently registered route first: without that
 * ordering the catch-all would see an off-allowlist host and abort it.
 *
 * Ground truth for every byte it returns is frontend/abi.js itself — the
 * same codec the browser uses — so the mock cannot drift into inventing a
 * wire format that the page would then "successfully" decode. The links
 * below are shaped like the real ones from the Phase 2 run
 * (docs/RESEARCH.md §15): one open, one paid, one claimed.
 *
 * No secrets: every value is a fixture written here.
 */

import {
  SEL,
  GET_LINK_TYPES,
  GET_LINKS_TYPES,
  callData,
  encodeTuple,
  decodeTuple,
} from "../../frontend/abi.js";

export const XLAYER_RPC_HOST = "testrpc.xlayer.tech";
export const XLAYER_CHAIN_ID = 1952;

const PAYEE = "0x7fce520d881454ea234d371e1256b75843609b62";
const DEPLOYER = "0x3f1004aaed662227d535d794da679110111a2fc4";
const TOKEN = "0x15bc997887385520e3c906533f0d20cb8d6db7d0";
const ZERO = "0x0000000000000000000000000000000000000000";

/* Fixed clock, deliberately past every createdAt below so `fmtDate` renders
   the same string on every run. */
export const NOW_MS = 1_795_008_640_000;

const link = (over) => ({
  linkId: "",
  creator: PAYEE,
  amount: 1_000_000n,
  token: TOKEN,
  description: "fixture invoice",
  createdAt: 1_795_000_000_000n,
  expiresAt: 0n,
  status: 0n,
  paidBy: ZERO,
  paidAmount: 0n,
  paidAt: 0n,
  claimedAt: 0n,
  ...over,
});

/** The three links the mocked ledger and pay cards answer with. */
export function makeXlLinks() {
  return [
    link({
      linkId: "pago-e2e-0001-open",
      amount: 2_500_000n,
      description: "E2E fixture — unpaid invoice",
      status: 0n,
    }),
    link({
      linkId: "pago-e2e-0002-paid",
      description: "E2E fixture — paid, awaiting claim",
      status: 1n,
      paidBy: DEPLOYER,
      paidAmount: 1_000_000n,
      paidAt: 1_795_001_000_000n,
    }),
    link({
      linkId: "pago-e2e-0003-claimed",
      description: "E2E fixture — claimed and settled",
      status: 2n,
      paidBy: DEPLOYER,
      paidAmount: 1_000_000n,
      paidAt: 1_795_002_000_000n,
      claimedAt: 1_795_003_000_000n,
    }),
  ];
}

const CORS = {
  "access-control-allow-origin": "*",
  "access-control-allow-methods": "GET, POST, OPTIONS",
  "access-control-allow-headers": "content-type, accept",
};

const json = (route, body) =>
  route.fulfill({
    status: 200,
    headers: { "content-type": "application/json; charset=utf-8", ...CORS },
    body: JSON.stringify(body),
  });

/** Decode the argument tail of a calldata blob (selector already stripped). */
const argsOf = (data, types) => decodeTuple(types, "0x" + data.slice(10));

/**
 * Install the X Layer RPC mock. Call AFTER installMocks() — registration
 * order is what gives this route priority over the catch-all.
 *
 * Returns { log, links }: `log` is every JSON-RPC method the page asked for,
 * so a spec can assert the page only ever reads.
 */
export async function installXLayerMocks(page, links = makeXlLinks()) {
  const log = [];

  /* A predicate, not a glob: the endpoint in config.js has no path, and
     `https://host/**` does not match a bare origin. */
  await page.route(
    (url) => url.href.startsWith(`https://${XLAYER_RPC_HOST}`),
    async (route) => {
    if (route.request().method() === "OPTIONS") {
      return route.fulfill({ status: 204, headers: CORS, body: "" });
    }

    let msg = {};
    try {
      msg = JSON.parse(route.request().postData() || "{}");
    } catch { /* fall through to the default answer */ }
    const id = msg.id ?? 1;
    const ok = (result) => json(route, { jsonrpc: "2.0", id, result });
    const fail = (code, message) =>
      json(route, { jsonrpc: "2.0", id, error: { code, message } });

    log.push(msg.method || "unknown");

    if (msg.method === "eth_chainId") return ok("0x" + XLAYER_CHAIN_ID.toString(16));
    if (msg.method === "net_version") return ok(String(XLAYER_CHAIN_ID));

    if (msg.method !== "eth_call") {
      return fail(-32601, `e2e mock: ${msg.method} is never used by the smoke suite`);
    }

    const call = (msg.params && msg.params[0]) || {};
    const data = String(call.data || "0x");
    const selector = data.slice(0, 10);
    /* encodeTuple() returns bare hex by design (callData() adds the 0x and
       the selector), while decodeReturn() refuses anything without 0x — so
       the mock adds it here, exactly as the transport would. */
    const out = (types, values) => ok("0x" + encodeTuple(types, values));

    switch (selector) {
      case SEL.feeBps:
        return out(["uint256"], [50n]);
      case SEL.isTokenAllowed:
        return out(["bool"], [true]);
      case SEL.nowMs:
        return out(["uint256"], [BigInt(NOW_MS)]);
      case SEL.linkExists:
        return out(["bool"], [false]);
      case SEL.balanceOf:
      case SEL.allowance:
        /* No wallet in the smoke suite, so nothing is ever approved or held;
           the pay card therefore renders its "connect to pay" state. */
        return out(["uint256"], [0n]);
      case SEL.getLink: {
        const [id2] = argsOf(data, ["string"]);
        const found = links.find((l) => l.linkId === id2);
        if (!found) return out(GET_LINK_TYPES, [false, link({})]);
        return out(GET_LINK_TYPES, [true, found]);
      }
      case SEL.getLinksByCreator: {
        const [creator] = argsOf(data, ["address"]);
        const mine = String(creator).toLowerCase() === PAYEE ? links : [];
        return out(GET_LINKS_TYPES, [mine]);
      }
      default:
        return fail(-32601, `e2e mock: unhandled selector ${selector}`);
    }
  });

  return { log, links };
}

/** Convenience: the read-only path a spec asserts against. */
export const xlPayUrl = (id) => `/xlayer.html#pay/${encodeURIComponent(id)}`;
export { callData };
