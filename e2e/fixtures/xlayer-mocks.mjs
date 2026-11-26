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
 * (docs/RESEARCH.md §15): one open, one paid, one claimed. The claimed
 * link's payout events mirror the real 2026-11-19 claim (pool 995000, fee
 * 5000, default split) and are served for the evidence path — linkKeyOf,
 * eth_blockNumber, eth_getBlockByNumber and eth_getLogs, including batch
 * arrays, which is exactly how the page locates a claim on a chain whose
 * eth_getLogs is capped at 100 blocks.
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
import { EVT } from "../../frontend/payout.js";

export const XLAYER_RPC_HOST = "testrpc.xlayer.tech";
export const XLAYER_CHAIN_ID = 1952;

/* Exported so the smoke spec can type it into the ledger: the ledger has no
   default address any more, and the mock only answers getLinksByCreator for
   this one. */
export const PAYEE = "0x7fce520d881454ea234d371e1256b75843609b62";
const DEPLOYER = "0x3f1004aaed662227d535d794da679110111a2fc4";
const TOKEN = "0x1bf9fd0c674bce9cdc9efc7c2a70e20e84e6953c";
const ZERO = "0x0000000000000000000000000000000000000000";

/* Fixed clock, deliberately past every createdAt below so `fmtDate` renders
   the same string on every run. */
export const NOW_MS = 1_795_008_640_000;

/* The claimed fixture's link key and claim transaction — arbitrary but
   fixed, and what linkKeyOf / eth_getLogs agree on. */
const CLAIM_KEY = "0x" + "c1".repeat(32);
const CLAIM_TX = "0x" + "ab".repeat(32);
const CLAIM_BLOCK = "0x100000";

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
  /* The three fields the rules build appended to the struct — without them
     encodeTuple refuses to write a 15-field Link, which is exactly the
     check that caught this fixture going stale. */
  defaultSplit: { recipients: [PAYEE, ZERO, ZERO], shares: [20, 0, 0] },
  ruleSplit: { recipients: [PAYEE, DEPLOYER, DEPLOYER], shares: [10, 6, 4] },
  netlistHash: "0x" + "a5".repeat(32),
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

/**
 * A one-recipient link: both preset tables pay the whole amount to the payee
 * and nothing to seats 2 and 3 — the shape whose pay card leads with the
 * "No split" line (handoff §7). Deliberately NOT part of makeXlLinks(): the
 * ledger test pins the mocked ledger at three links, and this one exists
 * only for the test that asks for it by id.
 */
export function makeXlNosplitLink() {
  return [
    link({
      linkId: "pago-e2e-0004-nosplit",
      amount: 2_500_000n,
      description: "E2E fixture — one recipient, no split",
      status: 0n,
      defaultSplit: { recipients: [PAYEE, ZERO, ZERO], shares: [20, 0, 0] },
      ruleSplit: { recipients: [PAYEE, ZERO, ZERO], shares: [20, 0, 0] },
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

/** A 32-byte topic: 12 zero bytes then the address. */
const addrTopic = (addr) => "0x" + "00".repeat(12) + String(addr).slice(2).toLowerCase();

/* ── the claimed fixture's payout events ────────────────────────────────
   Same shape the chain returns: topic0 = event signature, topic1 = link
   key, topic2 = recipient (leg events only), data = ABI-encoded args.
   Fee leg first, then the seat — the contract's own emission order. */
const claimLogs = {
  linkClaimed: {
    address: "0x36d212b8814470d60aaddb6e204f09efb3a3dce9",
    blockNumber: CLAIM_BLOCK,
    transactionHash: CLAIM_TX,
    logIndex: "0x0",
    removed: false,
    topics: [EVT.linkClaimed, CLAIM_KEY],
    data: "0x" + encodeTuple(["uint256", "uint256", "bool"], [995_000n, 5_000n, false]),
  },
  legPaid: [
    {
      address: "0x36d212b8814470d60aaddb6e204f09efb3a3dce9",
      blockNumber: CLAIM_BLOCK,
      transactionHash: CLAIM_TX,
      logIndex: "0x1",
      removed: false,
      topics: [EVT.legPaid, CLAIM_KEY, addrTopic(DEPLOYER)],
      data: "0x" + encodeTuple(["uint256"], [5_000n]),
    },
    {
      address: "0x36d212b8814470d60aaddb6e204f09efb3a3dce9",
      blockNumber: CLAIM_BLOCK,
      transactionHash: CLAIM_TX,
      logIndex: "0x2",
      removed: false,
      topics: [EVT.legPaid, CLAIM_KEY, addrTopic(PAYEE)],
      data: "0x" + encodeTuple(["uint256"], [995_000n]),
    },
  ],
};

/**
 * Install the X Layer RPC mock. Call AFTER installMocks() — registration
 * order is what gives this route priority over the catch-all.
 *
 * Returns { log, links }: `log` is every JSON-RPC method the page asked for
 * (batch arrays are logged per message), so a spec can assert the page only
 * ever reads.
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

    /* One handler per message; a batch is answered with an array of the
       same shape, matched by id — never by position. */
    const answer = (m) => {
      const id = m.id ?? 1;
      const ok = (result) => ({ jsonrpc: "2.0", id, result });
      const fail = (code, message) => ({ jsonrpc: "2.0", id, error: { code, message } });

      log.push(m.method || "unknown");

      if (m.method === "eth_chainId") return ok("0x" + XLAYER_CHAIN_ID.toString(16));
      if (m.method === "net_version") return ok(String(XLAYER_CHAIN_ID));

      /* The evidence path: head, block timestamps (every block carries the
         fixed clock — >= every claimedAt, so the locate search terminates),
         and the claim's logs inside whatever window the page asks for. */
      if (m.method === "eth_blockNumber") return ok(CLAIM_BLOCK);
      if (m.method === "eth_getBlockByNumber") {
        return ok({ number: CLAIM_BLOCK, timestamp: "0x" + BigInt(NOW_MS / 1000).toString(16) });
      }
      if (m.method === "eth_getLogs") {
        const filter = (m.params && m.params[0]) || {};
        const topic0 = (filter.topics && filter.topics[0]) || null;
        const topic1 = (filter.topics && filter.topics[1]) || null;
        if (topic1 && String(topic1).toLowerCase() !== CLAIM_KEY) return ok([]);
        if (topic0 === EVT.linkClaimed) return ok([claimLogs.linkClaimed]);
        if (topic0 === EVT.legPaid) return ok(claimLogs.legPaid);
        if (topic0 === EVT.legOwed) return ok([]);
        return ok([]);
      }

      if (m.method !== "eth_call") {
        return fail(-32601, `e2e mock: ${m.method} is never used by the smoke suite`);
      }

      const call = (m.params && m.params[0]) || {};
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
        case SEL.linkKeyOf:
          return out(["bytes32"], [CLAIM_KEY]);
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
        /* Rule-6 state, answered the way the live testnet answers it: both
           legs pass (so the check reads true) and the configured cap is on
           the books. The create page and the pay card read these together —
           Promise.all rejects if either is missing. */
        case SEL.evaluatorPinned:
          return out(["bool"], [true]);
        case SEL.maxLinkAmountUnpinned:
          return out(["uint256"], [10_000_000_000n]);
        default:
          return fail(-32601, `e2e mock: unhandled selector ${selector}`);
      }
    };

    /* A batch arrives as a JSON array and must leave as one. */
    if (Array.isArray(msg)) return json(route, msg.map(answer));
    return json(route, answer(msg));
  });

  return { log, links };
}

/** Convenience: the read-only path a spec asserts against. */
export const xlPayUrl = (id) => `/xlayer.html#pay/${encodeURIComponent(id)}`;
export { callData };
