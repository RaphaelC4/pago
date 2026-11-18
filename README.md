# Paylink

**First, the honest part: creating a link needs no NEAR from the payee** —
the wallet signs a delegate action off-chain (a signature is free), Paylink's
relayer pays the gas and the 0.01 NEAR storage stake, and the link still
belongs to the payee. A wallet that cannot sign a delegate falls back to the
direct transaction and covers that one creation itself (0.01 NEAR stake plus
gas). After that the payer signs once to send the money, and the payee signs
nothing.

**Send someone a link. Get paid from whatever they already hold.**

Paylink turns an invoice into a URL. A freelancer in Lagos sends a client in
Berlin a link. The client pays with the tokens already in their wallet. The
freelancer receives them on NEAR and never had to walk a client through a seed
phrase. The payer signs once to send the money — from then on the freelancer
signs nothing.

**On gas:** the track hints at meta transactions; Paylink uses them — a
NEP-366 delegate action carries `create_link` to chain with the relayer
paying the gas and the stake, while `claim` is callable by anyone and can
only pay the invoice's payee, so the release is signed by the keeper Worker
from its own gas account — the app's *Release* button is the manual fallback
— and the payee never holds gas
([how the relayer works](#references)).

Built for **NEAR HACKATHON**, track **`realworld` — Real-World Money**.

**Live demo:** <https://paylink-near.vercel.app/> ·
**Demo video:** [`docs/Paylink-demo-full.mp4`](docs/Paylink-demo-full.mp4) ·
**Launch post:** <https://x.com/agu_raphael_/status/2119552525439492372> ·
**Contract:** [`paylink-v2.testnet`](https://testnet.nearblocks.io/address/paylink-v2.testnet)
on NEAR testnet explorer

**What it does, in one list**

- **Gasless link creation:** the payee signs a free NEP-366 delegate action and the relayer pays gas and the 0.01 NEAR stake.
- **One-approval payment, automatic release:** the payer signs once; the keeper settles to the payee, minus the 0.5% fee.
- **Pay from another chain:** the swap row quotes a cross-chain deposit through Tidepool / NEAR Intents (testnet sandbox) that settles into the link's USDC. A real run is recorded in `e2e/TESTNET.md`.
- **Cross-chain payment, done and verified on testnet:** a payer on another chain paid a Paylink invoice through Tidepool / NEAR Intents. The payment intent `pi_2f1559538bde442d` took one deposit of 1.010102 USDC and reached `VERIFIED` with its payout transactions final on NEAR. The full run, including a wrong-token mistake that cost 1.02 USDC, is written up in [`e2e/TESTNET.md`](e2e/TESTNET.md) (Journey B).
- **PDF payment receipt:** once a payment is verified, the pay card shows "Payment delivered and verified on NEAR" with a **Download PDF receipt** button. This works for both NEAR and cross-chain payments.
- **Creator-only `cancel_link`:** live on testnet. It works only before payment and moves no money.
- **AI invoice parsing:** paste a message or attach a PDF or image and the form fills itself, and you still confirm.
- **Naira estimate, QR and share buttons:** the payment page shows an indicative NGN value, and the link can be shared by WhatsApp, Telegram or email.
- **Activity feed read from contract state:** nothing moves in the UI until the chain says so.

*Video drift note (M-05): the walkthrough was recorded 7 Nov 2026, before
the one-approval change of 9 Nov — its release beat (~1:45–1:55) shows the
payer's wallet signing `claim`, a second approval that no longer exists.
Today the payer signs only the payment; the keeper settles automatically
from its own gas account. The narration and the gasless creation clip are
accurate as recorded. [DEMO.md](DEMO.md) carries the re-record script.*

---

## Screenshots (live testnet run)

A real run on `https://paylink-near.vercel.app` (testnet): payee `tstst.testnet` creates a 10 USDC link, a payer pays it with one wallet approval, and the contract releases 9.95 USDC after the 0.5% fee.

| Step | Screen |
|---|---|
| 1. Payee creates a link (paste a request or fill the form) | ![Create link](docs/screenshots/01-create-link.png) |
| 2. Link ready to send: copy, WhatsApp, Telegram, email, QR | ![Link ready](docs/screenshots/02-link-ready-qr.png) |
| 3. Payer opens the link: OPEN, amount, naira estimate, fee shown | ![Payer view](docs/screenshots/03-payer-sees-link.png) |
| 4. Payer pays: CLAIMED, 9.95 USDC released to the payee | ![Paid](docs/screenshots/04-payer-pays-claimed.png) |
| 5. Payer's activity tab: "You paid" / "Payment released" | ![Payer activity](docs/screenshots/05-payer-activity.png) |
| 6. Payee sees the same link as CLAIMED, straight from contract state | ![Payee evidence](docs/screenshots/06-payee-evidence-paid.png) |
| 7. Payee's activity tab: "Payment received" / "Released to you" | ![Payee activity](docs/screenshots/07-payee-activity-released.png) |

The link in these screenshots is `lnk-sn3hrey6`: open `https://paylink-near.vercel.app/#pay/lnk-sn3hrey6` to see it CLAIMED, read from contract state. On-chain proof: the create, pay and claim transactions in the table below, and the live `cancel_link` transaction [`BFfwkup8JuSBWKKR3GkcgcfFufLdUJT8ibuWF3BDfD1U`](https://testnet.nearblocks.io/txns/BFfwkup8JuSBWKKR3GkcgcfFufLdUJT8ibuWF3BDfD1U).

## The problem

Getting paid across borders still costs money and time.

| Route | What it costs |
| --- | --- |
| Bank wire | $25–45 in fees, 3–5 days, bank details shared with a stranger |
| PayPal / Wise | Poor support from many countries, freeze risk, still not instant |
| "Just send me crypto" | Both sides must pick the same chain, avoid a wrong-network send, and understand gas |

Every route asks one side to learn the other side's world.

Paylink removes that requirement — even for creating the link. The payee's
wallet signs a delegate action off-chain and the relayer covers the 0.01 NEAR
stake and the gas for that first transaction (a wallet that cannot sign a
delegate pays it itself, once). After that, the payer uses what they have, and
the payee does not have to claim, sweep, or hold gas: a keeper Worker
releases the paid invoice automatically from its own gas account, sweeping
every minute, so settlement never waits on a browser staying open or on
another wallet prompt.

---

## What's proven

[Security](#security) below states the threat model. This is the other side:
what the build actually demonstrates, and the test that demonstrates it. All 56
tests are pure host tests — `cargo test --lib`. On-chain evidence for the
cross-contract steps that host tests cannot reach is
[in its own section](#one-full-run-on-chain) below.

| Behaviour | Proof |
| --- | --- |
| **Micro-invoices pay out.** A 100-unit link has a fee that rounds to zero, so `claim` skips the fee leg instead of failing on a zero-amount NEP-141 transfer, and the split never overflows or loses a unit. | `a_tiny_invoice_skips_the_fee_leg_instead_of_failing`, `split_fee_never_overflows_or_loses_a_unit` |
| **Nobody needs gas to get paid — not even for the link itself.** Creating the link goes through a NEP-366 delegate action: the payee signs off-chain and the relayer Worker attaches the 0.01 NEAR stake and pays the gas, measured on testnet with the payee's balance unchanged to the yocto across four creations. After that `claim` is callable by anyone, so the keeper releases every paid invoice within a minute from its own gas account — after the payer's single approval the frontend only watches the link move `PAID → CLAIMED` — and the payee holds no NEAR and signs nothing after payment. | `a_stranger_can_trigger_claim_but_only_the_payee_is_paid`, `claim_pays_the_payee_less_the_fee_in_one_batch`, `workers/keeper/test/sweep.test.mjs` (178 assertions over mocked RPC) |
| **Overpayment is never lost.** What arrived is what's credited, and the fee applies to the credited amount rather than the invoiced one. | `an_overpayment_is_credited_in_full`, `claim_applies_the_fee_to_an_overpayment` |
| **Paying twice never double-credits.** A link leaves `OPEN` once; a second payment is returned. | `paying_twice_does_not_double_credit` |
| **Expiry needs no background job.** `Expired` is derived on read from `expires_at`, never stored, so an aged link reports itself honestly and refuses payment. The same timestamp is also the due date: after it, payment is refused and the tokens return to the payer in the same transaction — a hard cutoff, rather than a late payment accepted and marked late. | `an_expired_invoice_cannot_be_paid`, `an_expired_invoice_is_reported_as_expired_even_unpaid` |
| **A creator can kill their own link before it is paid — and never after.** **Live on testnet:** `cancel_link` is deployed on `paylink-v2.testnet` and was exercised end to end through the relayer (see `e2e/TESTNET.md`, tx `BFfwkup8JuSBWKKR3GkcgcfFufLdUJT8ibuWF3BDfD1U`). `cancel_link` is callable only by the stored creator (no payer, keeper, relayer or admin path) and only while the stored status is `OPEN`, so an expired-but-unpaid link can be cancelled but `PAID` and `CLAIMED` never can — a paid link is unreachable for cancellation even before the keeper settles it. Cancellation writes one status and moves nothing: no promise, no transfer, no deposit, no stake refund. A cancelled link refuses every later payment with a full refund, can never be claimed, and is kept (not deleted), so cancellation and the keeper's `PAID`-only settlement live in disjoint states. | `the_creator_cancels_an_unpaid_link`, `a_paid_link_cannot_be_cancelled_before_settlement`, `a_cancelled_link_cannot_be_claimed`, `cancellation_moves_no_money_and_schedules_no_promises`, `cancel_and_pay_settle_exactly_one_winner_in_either_order` |
| **Sharing survives a dead RPC.** The QR code and Copy button are built from the link id alone — a vendored MIT encoder, no image request, no chain round trip. | `frontend/vendor/qrcode.js`, `qrMarkup()` in `frontend/app.js` |
| **The keeper needs no registry.** One `view_state` call with prefix `l` lists every link — and if that response ever gets too large or times out, it re-reads the same state as disjoint sub-prefix pages, keeps what it could read and claims it, so discovery scales without an indexer; it signs with the runtime's Ed25519 WebCrypto, so it is a single file with no dependencies. | `workers/keeper/src/index.js` |
| **Storage is funded up front.** `create_link` requires a 0.01 NEAR stake that covers its own storage and registers the payee on the token — on a delegated creation the relayer attaches it. | `create_link_requires_a_storage_stake`, `the_stake_really_is_ten_millinear` |
| **Settings are public getters.** The allowlist and both fee settings are readable by anyone, not admin-only views. | `the_allowlist_is_visible_to_callers`, `the_fee_settings_are_visible_to_callers` |

### One full run, on-chain

Host tests cannot execute the cross-contract steps, so here is a real run on
`paylink-v2.testnet` instead: link `keeper-005`, created, paid and released on
**5 Nov 2026** — the release signed by the keeper's cron, no human in the
loop.

| Step | Transaction |
| --- | --- |
| **Create** — payee calls `create_link` with a 0.01 NEAR stake, 12:14:24 UTC | [`4jLDBWkuAHRyPiZmGJmfN2uNdSsbJktvHhegH7rDCHaE`](https://testnet.nearblocks.io/txns/4jLDBWkuAHRyPiZmGJmfN2uNdSsbJktvHhegH7rDCHaE) — Success |
| **Pay** — payer calls `ft_transfer_call` for 3 USDC, **8 seconds later** | [`7LiwE8BvSoUdoHZJmBA85App2TVWkVugvWyE57LTocLn`](https://testnet.nearblocks.io/txns/7LiwE8BvSoUdoHZJmBA85App2TVWkVugvWyE57LTocLn) — Success |
| **Claim** — keeper cron calls `claim` 2 min 39 s later: 2.985 USDC to the payee, 0.015 to fees | [`HrrNqKHZoQu7QFZMENzsYT9eBxLqujRQrK8YuXvdocD1`](https://testnet.nearblocks.io/txns/HrrNqKHZoQu7QFZMENzsYT9eBxLqujRQrK8YuXvdocD1) — Success |

That is one link's full lifecycle in three transactions, all visible in the
explorer. This was not a one-off: the keeper's cron has released links on
testnet repeatedly — [`paylink-keeper.testnet`](https://testnet.nearblocks.io/address/paylink-keeper.testnet)
lists every `claim` it has sent, and each released link reads `CLAIMED` with a
`claimed_at` timestamp when queried on chain.

**After the payee-registration fix**, the same three-step cycle was run again
live against the deployed code on **6 Nov 2026**, link `review-fix-001`
(1 USDC): create
[`Frh8z8mdXTTwKBwtyi33k9paYJQ6K6AE3LMKkFp6FPGv`](https://testnet.nearblocks.io/txns/Frh8z8mdXTTwKBwtyi33k9paYJQ6K6AE3LMKkFp6FPGv) →
pay
[`4dVD9fRSwd5Hmq9dimJNxoUECbPwBM3p39dfFeykyGXb`](https://testnet.nearblocks.io/txns/4dVD9fRSwd5Hmq9dimJNxoUECbPwBM3p39dfFeykyGXb) →
claim
[`8WmbLm4E92XE9cgoGZHhvwCuBNS6rbqDeVtJw8Fp1jw6`](https://testnet.nearblocks.io/txns/8WmbLm4E92XE9cgoGZHhvwCuBNS6rbqDeVtJw8Fp1jw6) —
the claim's logs show the registration receipt executing before the payout
batch, which is the fix working end to end.

**With the relayer in front of `create_link`**, the creation step no longer
touches the payee's wallet at all. Link `lnk-jhfmt56d` (3.25 USDC, 72-hour
expiry) was created on **7 Nov 2026** through the full browser flow — Meteor
Wallet signed a delegate action, the frontend POSTed it to the relayer
Worker, the Worker wrapped and signed the transaction as
`paylink-relay.testnet`:
[`pYBw2vTh8B3ZDK7qwbDqre8x5c7iHqEzTLFVD68USYU`](https://testnet.nearblocks.io/transactions/pYBw2vTh8B3ZDK7qwbDqre8x5c7iHqEzTLFVD68USYU) —
Success. The payee's balance read 19.7890472296385996 NEAR before and after;
the relayer's dropped by 0.010514 (stake plus gas). Three earlier creations
proved the same path from other angles: `spikea01`
([`HJML2cY2AfWb5Tcows4C3BmyEAGV3FigtQ8xXGrtLwTz`](https://testnet.nearblocks.io/transactions/HJML2cY2AfWb5Tcows4C3BmyEAGV3FigtQ8xXGrtLwTz),
signed by near-cli-rs), `spikea02`
([`B37vJV8ZfGK3yo8KAQDoqjkPdi3yipVBsNX3GhijTWNf`](https://testnet.nearblocks.io/transactions/B37vJV8ZfGK3yo8KAQDoqjkPdi3yipVBsNX3GhijTWNf),
signed by Meteor Wallet) and `spikea03`
([`26asviviWDe7EFprdWH6fgDhrJUoUjRhJwZYLkKzJQcm`](https://testnet.nearblocks.io/transactions/26asviviWDe7EFprdWH6fgDhrJUoUjRhJwZYLkKzJQcm),
submitted through the Worker's `POST /submit` exactly as the frontend does).
All four links read `creator: paylink-payee.testnet` on chain.

---

## How it works

### The contract

`contracts/` holds a NEAR contract with exactly three jobs:

1. **Record a request.** `create_link` stores who is owed, how much, in which
   token, by when.
2. **Recognise payment.** The contract implements NEP-141 `ft_on_transfer`.
   When tokens arrive, the token contract itself calls the contract and passes
   the link id in `msg`. The contract checks it and marks the link paid.
3. **Release the money.** `claim` first makes sure the payee is registered on
   the token — a deposit from the contract's own balance, refunded in full if
   they already are — then sends the credited amount to the payee, minus a
   fixed 0.5% fee. **Anyone can call it** — the money can only go to the
   invoice's payee and the fee account, never to the caller — so
   `workers/keeper/` calls it from a cron every minute to release a paid
   invoice for the payee without asking them to come back and sign anything,
   and the frontend's *Release* button is the manual fallback anyone can
   press.

**There is no `mark_paid` function.** Nothing in the public interface lets
anyone assert that a link was paid. The only code path that marks a link paid
is `ft_on_transfer`, and it is invoked by the token contract, not by a user.
A caller cannot forge it without actually sending the tokens.

**The payee cannot pay their own link.** `ft_on_transfer` compares `sender_id`
with `link.creator` and returns the full amount when they match, so a creator's
payment is refunded and the link stays unpaid until somebody else pays it. The
pay page shows the creator a waiting state with the share tools instead of a
Pay button.

**The contract holds funds only between payment and claim, and `claim` is the
only way out.** It can pay exactly two destinations: the invoice's payee and
the fee account. Nothing else in the interface can move a balance. See
[Security](#security) for why the transfer is a separate call rather than
happening inline.

### The token

The contract is **token-agnostic but not token-blind**. It keeps an allowlist
of accepted token contracts and rejects anything else by returning the full
amount, which the token contract refunds to the sender automatically.

The allowlist is set once in `new()` and has no setter, so **widening it
requires a code upgrade signed by the deployer's key** rather than a quiet
call. That is the point: even the deployer cannot add an acceptance path
without the deploy showing up in the transaction history.

### The payer's path

- **Already on NEAR (the path the demo exercises):** send `ft_transfer_call`
  with `msg = <link id>`.
- **Arriving empty, or holding something else:** the pay page carries a
  Tidepool rail under **No test USDC?**. *Get test tokens* drips 100 test
  USDC (plus USDT, wNEAR and dust) into the connected wallet in one keyless
  call; the swap row quotes a deposit of wNEAR, USDT or ETH that settles into
  exactly this link's amount (native NEAR is not a source — it pays gas and
  nothing else). Both are free, both are testnet-only, and if Tidepool is
  unreachable the rail shows the error while the normal pay flow is
  untouched. The faucet itself is site-wide: the Account panel carries the
  same *Get test tokens* card at every size, and on phones a **Faucet** chip
  beside the floating bar opens it as a bottom sheet.

The on-chain path ends in `ft_on_transfer` called by the token contract, and
that call — not any user call — is what marks an invoice paid.

### Reading the chain

The one thing the share page exists to hand over is the link, so it never
waits on the chain. The QR code and the Copy button are built from the link id
alone: the QR comes from a vendored MIT encoder (`frontend/vendor/qrcode.js`)
that renders in the browser with no image request and no third-party service,
and the copy field needs only the URL. Only the WhatsApp / Telegram row reads
the chain, because those messages embed the amount.

Every other read has a 12 s timeout and **one automatic retry** — on a
network error or a 5xx reply only, never on a rate limit, a timeout or a
chain error, and only for reads — so a dead or restarting endpoint heals
itself while a slow or rate-limited one surfaces as *Could not read the
chain* with a **Try again** button rather than a spinner that never
resolves. The endpoint itself is
`test.rpc.fastnear.com`, set in `frontend/config.js`. The previously used
`rpc.testnet.near.org` is deprecated: it answers `429` with **no CORS
headers**, so a browser only ever sees `Failed to fetch` and cannot tell a
rate limit from an outage.

### Invoice parsing (optional)

Pasting an invoice is a convenience, not a trust boundary. `workers/parse/` is a
~150-line Cloudflare Worker that sends pasted text or one PDF/image to Gemini
and returns exactly five fields. The API key is a Worker secret; the browser
never sees it. The model's answer is treated as a proposal:

- amount must be a plain decimal, finite, positive, and at most 1,000,000 in
  base units — no exponent, no separators, no rounding surprises;
- the token must pass `is_token_allowed` **read from the chain**, or match the
  one token this deployment accepts by contract id or known alias;
- the payee is compared with the connected wallet and surfaced, never used —
  `create_link` issues to `predecessor_account_id` and ignores any payee field;
- the description is stripped of control characters and cut to 200 characters;
- the expiry is clamped to an integer number of hours between now and 365 days.

If any check fails the form is left untouched and the reason is shown. Nothing
the model returns can reach the contract without the user pressing **Create
link**. Leave `parseEndpoint` empty in `frontend/config.js` and the block does
not render at all.

### The release keeper

`workers/keeper/` is a small Cloudflare Worker, with no dependencies, that
releases paid links from a cron every minute — it is the settlement path, not
a backup: it needs no browser, no wallet prompt and no payee signature, so a
closed tab or a rejected prompt can never strand a paid invoice. (The
frontend's *Release* button is the manual fallback if the keeper is ever
down.) Discovery needs no registry — one `view_state` call with
prefix `l` lists every link the contract stores, and anything sitting in `PAID`
gets claimed, up to 10 per sweep. That single call is only the fast path: if
it fails after its retry, the same coverage is fetched as disjoint sub-prefix
pages, whatever was read is still claimed, and the next sweep re-covers the
rest from scratch.

It signs with the runtime's own Ed25519 WebCrypto, so the Worker is a single
file deployable from the dashboard. It pays gas from its own testnet account
(`paylink-keeper.testnet`); the payout still lands only on the link's payee
and the fee account, because that is all `claim` can pay. `POST /tick` runs the
same sweep on demand behind a secret, for tests and demos.
`workers/keeper/README.md` has the deploy steps.

### The relayer

`workers/relayer/` is the second Cloudflare Worker, also a single dependency-free
file. It makes creation free for the payee: the wallet signs a NEP-366
`DelegateAction` for `create_link` off-chain — a signature costs nothing — and
POSTs it to `POST /submit`. The Worker borsh-parses the delegate and validates
it before spending a yocto: outer receiver must be the delegate's sender
(NEP-366 rule 3), inner receiver must be the contract, the single action must be
`create_link` with at least the 0.01 NEAR stake, sane link id / amount / token /
description / future expiry, a nonce that beats the sender's access key, a
`max_block_height` still ahead of the chain, and — proven against two fixtures
the chain accepted — the signature itself under NEP-461's preimage (the NEP-366
discriminant prefixed to the delegate bytes, hashed). Rate-limited to 10
submissions per IP per hour, and it refuses to spend below a 1 NEAR balance
floor. Only then does it wrap the raw delegate bytes in a transaction signed by
`paylink-relay.testnet` and broadcast it.

On chain the inner call executes with the payee as `predecessor`, so the link's
creator is the payee exactly as with a direct transaction — no contract change.
Measured on testnet: the payee's balance does not move by one yocto; the relayer
pays the stake and gas. The frontend takes this path whenever
`CONFIG.relayer.endpoint` is set and the wallet offers `signDelegateActions`
(Meteor Wallet does); otherwise it falls back to the direct transaction. A
failed relayer POST never switches paths silently: the flow first confirms
against the chain that the link was not created, then offers an explicit
choice — **Create directly** (the creator's wallet pays the 0.01 NEAR stake
and the gas) or **Cancel**, which only stops the attempt and sends nothing to
the chain — an outcome the chain cannot confirm shows
*Check again* instead of a second transaction, reusing the original link id
so a late-landing relayer transaction can never become a duplicate invoice.
`workers/relayer/test/parse.test.mjs` (173 assertions) runs the parser,
validator and tx builder against the two real signed fixtures.

---

## Where the money moves

This is the part a bookkeeper cares about.

```
Payer's wallet
      │  ft_transfer_call(msg = link id)
      ▼
Paylink contract            ← credits the link, returns 0 (all tokens used)
      │  storage_deposit(payee)   register the payee first — refunded in full
      │                           if already registered
      │  ft_transfer(99.5% → payee)  ┐ one batch, so they
      │  ft_transfer(0.5%  → fee)    ┘ succeed or fail together
      ▼
Payee's wallet
```

At no point does a company, an operator, or a server hold the money. The
contract has **no owner, no admin function, and no withdrawal path in its
code**: the fee account is fixed in `new()` with no setter, and the 0.5% rate
is a constant. Changing either requires a code upgrade signed by the
deployer's key — and that key is real. Whoever holds it can redeploy
`paylink-v2.testnet` with different code, which is the one power retained
outside the contract. That is how NEAR deployments work rather than a
backdoor in this code, and it is stated here rather than left for a reviewer
to discover.

If any check fails — unknown link, expired, underpayment, token not
allowlisted — the contract returns the full amount and the token contract
refunds the payer automatically. **A failed payment costs the payer nothing.**
Overpayment is not a failure: what arrived is credited in full, so the payee
keeps the excess and the fee is taken from the credited amount rather than the
invoiced one.

---

## Pago — the same product on X Layer

**Status:** live on **X Layer testnet (chain 1952)** — Pago
`0x2fC4180db7318F4364F6FC559A25359c9F537D3e`, pUSD **(MOCK)**
`0x3693a61572C1c5f120Da39A6F4e616ce46D32de4`, processor stand-in **(EVM, not
hardware)** `0x67a9B6F2AE5488B8ee993F019FE867E97585DEEF` — with both payer
paths run end to end, the circuit's rule selecting one split table and its
rejection falling back to the other, reconciled to the unit
([`docs/RESEARCH.md` §17](docs/RESEARCH.md)), and its own page at
`frontend/xlayer.html` (below). The contract gained the master prompt's
split-rule interface (rules 1–10, [`docs/MASTER_PROMPT.md`](docs/MASTER_PROMPT.md))
in that phase; the page's ABI codec is being updated to match as the next
phase. **X Layer mainnet (chain 196) is read-only:** nothing has been spent
there, and nothing will be without an explicit approval phrase. This section
describes what exists in `contracts-evm/` and `frontend/` today.

This repository now carries two builds of one product:

| | NEAR build | X Layer build |
| --- | --- | --- |
| Name | Paylink | **Pago** |
| Code | `contracts/paylink-contract/` (Rust) | `contracts-evm/` (Solidity 0.8.28, Foundry) |
| Chain | NEAR testnet | X Layer (testnet 1952 to deploy to, mainnet 196 read-only) |
| Built for | NEAR HACKATHON, `realworld` track | **X Layer TapeOut Accelerate** (Oct 16 – Dec 7 2026) |

The **concept** is ported, not the code: NEAR's `ft_transfer_call` /
`ft_on_transfer` handshake has no EVM equivalent, so the payer path is an
ordinary ERC-20 `transferFrom`, plus a second, gasless path built on EIP-3009
`transferWithAuthorization` — a payer signs off-chain and any account (Pago's
relayer) submits it and pays the gas. Both stablecoins Pago will accept,
USD₮0 and USDG, were proven to support that on X Layer mainnet during Phase 0.

### What changed, and what deliberately did not

| Concern | NEAR | Pago on X Layer |
| --- | --- | --- |
| Recognising payment | the **token contract** calls `ft_on_transfer` with the link id | the payer calls `pay(linkId, amount, expectedTermsHash)`, or a relayer submits their EIP-3009 signature — either way the tokens physically move in the same call, so there is no status write a caller can make without paying |
| Creation stake | 0.01 NEAR, attached by the relayer | **gone.** EVM storage is paid in gas by whoever sends the transaction; an escrow for a record that holds no money would serve no purpose |
| "attach exactly 1 yocto" | required on every state change | **gone.** State-changing calls are already transaction-scoped and signed; the yocto guard protects against nothing here |
| `on_claimed` callback | needed, because NEAR's transfer batch can fail *after* `claim` has written `Claimed` | **replaced, not ported.** Each payout leg is independent: a leg whose transfer fails leaves its amount in the contract as `owed[recipient][token]`, withdrawable by that recipient alone, while every other leg — including the fee — still pays in the same transaction. `claim` never reverts on a transfer failure, so there is nothing to rewind and nothing to retry |
| Token registration | NEP-145 `storage_deposit` before payout | **gone.** ERC-20 has no per-account registration |
| Fee | 0.5%, constant, to a fee account fixed in `new()` | **identical** — 50 bps, `feeAccount` immutable, set in the constructor, no setter |
| Expiry | `Expired` derived on read, never stored | **identical** |
| Timestamps | milliseconds since epoch | **identical** (`nowMs`), so a browser keeps using `Date` |
| Fee rounding | floor, `payout + fee == amount` always | **identical**, same two-term decomposition, proven for `type(uint256).max` |
| Owner / admin / withdraw | none | **none** — `feeAccount` is immutable and the token allowlist is written only by the constructor, so widening it needs a new deploy that shows up in the explorer |
| Reentrancy | not applicable | `nonReentrant` on `pay` / `payWithAuthorization` / `claim`, on top of checks-effects-interactions |

**Gasless creation is not ported yet.** On NEAR the payee signs a NEP-366
delegate action for free and the relayer pays gas *and* the stake. The EVM
equivalent is an EIP-2771 / EIP-712 meta-transaction for `createLink`, which
does not exist in this build: today the payee's creation is a normal
transaction they pay for. The **payment** side is the reverse — the payer can
sign an EIP-3009 authorization and never touch gas at all. Closing the
creation gap is stated here rather than implied.

### Why a circuit

A payment split three ways is a rule: *the three shares must add up to 100%*.
Normally that rule lives in a few lines of contract code, and a reader has to
trust that the code says what they think it says and cannot be changed quietly.

**Split3** (`contracts-evm/src/circuits/Split3.sol`) states the same rule as a
piece of published hardware instead:

- The rule is a **TAP-02 netlist** — 15 input bits (three shares, each a 5-bit
  field counted in 5% steps: `20 = 100%`), one output bit, **104 NAND gates**,
  no latches and no references to anything else.
- It is **built, not hand-encoded**: `netlist()` assembles it from a half
  adder, a full adder and a compare, so the byte string can be read next to the
  arithmetic it encodes instead of being an opaque hex blob.
- The netlist is **verified exhaustively**. The whole input space is
  2^15 = 32,768 vectors, and `test/Split3.t.sol` evaluates every one of them
  through the TAP-02 reference evaluator and demands it agree with
  `Split3.holds(a, b, c)`, a plain `a + b + c == 20` written in Solidity. Two
  independent implementations of the rule agreeing on every possible input — a
  claim a reviewer can re-run with `forge test`, not a sample.
- Once taped out, anybody can call `eval()` **on X Layer itself** and get the
  rule's verdict computed by the chain, and anybody can read the netlist and
  count the gates themselves. There is no privileged reader, no oracle, and no
  admin who can relax the rule without deploying visibly different code.

**Pago now actually calls it.** Every link carries two split tables fixed at
creation: a *default* (must pay out exactly 100%, no setter) and a *rule*
candidate (shares 0–31, their sum is precisely what Split3 judges). At
`claim`, the contract derives the inputs from its own state and asks the
processor a strict, gas-limited `staticcall` — exact return length, strict
decoding — whose single output bit only ever **selects** between those two
stored tables; a rule can never invent a split, a recipient or an amount.
Whatever the processor does — reverts, returns malformed data, runs out of
gas, lies about an unsafe split, or vanishes — the default table pays, so a
link can never freeze. If the evaluator is not pinned by its `changeDetector`
known-answer check at deploy, every link is capped at
`MAX_LINK_AMOUNT_UNPINNED[token]`. Full rule-by-rule audit:
[`docs/RESEARCH.md` §17](docs/RESEARCH.md).

**On testnet that processor is a labelled stand-in, not hardware.** TapeOut
exists only on X Layer mainnet (the factory has no code on chain 1952 —
probe recorded in §17), so `test/mocks/ProcessorStandIn.sol` implements the
same interface and runs the **real Split3 netlist bytes** through the same
TAP-02 evaluator that was proven bit-for-bit against a live mainnet
processor. The verdicts come from the netlist; the deploy log says
"EVM stand-in, not hardware"; mainnet tier 2 replaces only the constructor
argument.

The other reason is the hackathon: the X Layer TapeOut Accelerate track
explicitly asks for TapeOut circuits, contracts or onchain data
([evidence in `docs/RESEARCH.md` §11](docs/RESEARCH.md)).

**Split3 has not been taped out.** That costs roughly 0.11 BEM plus 0.0013
native OKB on X Layer mainnet, spends real funds, and is deliberately **not
started** — it awaits an explicit go-ahead. `docs/RESEARCH.md` §14 itemises
the cost. (Everything is on X Layer chain 196: OKB is that chain's gas token,
and BEM is an ERC-20 on the same chain — no other network is involved.)

There is a cheaper route — tape out onto one of the existing third-party
processors for 0.0013 OKB plus one of its transistors — and it is **not**
taken, because **the processor owner controls it**: who may mint, what a
transistor costs, and the processor's own rules are theirs, not ours. Only our
own processor (the ≈0.11 BEM route) keeps that control with the deployer.

### Security model

Identical in spirit to the NEAR build, and the tests assert the same
properties:

- **Funds move only per what the contract computed from its own onchain
  state**, or per one of the two split tables fixed at link creation — the
  default, or the rule table the circuit's verdict selected. No function
  accepts a recipient or an amount that the contract did not derive itself.
- **`claim(linkId)` takes no result arguments, is callable by anyone, and can
  only pay the selected table's recipients and the fee account — never the
  caller.** The money cannot be routed anywhere else by whoever triggers it.
- **A payer consents to the onchain terms.** `pay` and `payWithAuthorization`
  take `expectedTermsHash` and revert on a mismatch; `terms(linkId)` is the
  canonical byte string of everything immutable on the link, including both
  split tables, the fee and the circuit identity. This binds the payer to
  what is *recorded onchain* — it does not prove what their screen displayed,
  and nothing claims it does.
- **A failing recipient never blocks the others.** Every payout leg is an
  independent transfer; a failed leg becomes `owed[recipient][token]`,
  withdrawable only by that recipient, while the rest — fee included — pay in
  the same transaction.
- **The evaluator is never trusted blindly.** Any anomaly in its answer
  (revert, malformed return, gas exhaustion, a verdict that would overdraw the
  contract) falls back to the default table; while `evaluatorPinned` is false,
  every link is capped at `MAX_LINK_AMOUNT_UNPINNED[token]`.
- **The payee cannot settle their own link**, on either payer path.
- **An EIP-3009 signature is bound to exactly one link**: the nonce it must
  carry is derived from `(linkKey, payer)`, so an authorization signed for
  invoice A cannot be replayed against invoice B, and a link can only be paid
  once.
- **A rejected payment moves nothing.** Every guard runs before the token
  transfer, so an expired, cancelled, underpaid, wrong-terms or self-paid
  attempt costs the payer gas and no tokens.
- **The allowlist and expected decimals are fixed at construction.** Only
  audited tokens can ever call back in; the deploy script aborts if the
  token's onchain `decimals()` disagrees with the value we wrote, and the
  contract never reads `decimals()` at runtime.

**Not audited.** This is a hackathon build. Do not send real funds to it.

### Tests

```powershell
cd contracts-evm
$env:XLAYER_RPC = "https://rpc.xlayer.tech"   # only the fork suites need it
forge test
```

The local suites — `PagoTest` (the full contract: guards, money paths, ledger,
both payer paths), `PagoRuleTest` (the master-prompt rules: terms consent,
circuit identity, `evaluatorPinned` / `changeDetector`, and every processor
fault proven to fall back instead of freezing), `PagoInvariantTest` +
`PagoFuzzTest` (conservation: payouts + fee == credited, balance ≥ owed,
status never backward — 128,000 interleaved calls in the invariant run),
`Split3Test` (the exhaustive circuit check) and the TAP-02 reference
evaluator's own suite — need no network at all. The fork suites prove the
Phase 0 claims against real X Layer mainnet state. **131 tests, 0 failed**
(recorded 2026-11-18, [`docs/RESEARCH.md` §17](docs/RESEARCH.md)).

### The X Layer page

`frontend/xlayer.html` (+ `frontend/xlayer.js`) is Pago's own UI, sitting
beside the NEAR app — `index.html` and `app.js` were not touched, so nothing
that already worked can regress from it.

- **Buildless on purpose**: no bundler, no npm dependency, no vendored ethers.
  Calldata is encoded by `frontend/abi.js`, a hand-rolled ABI codec whose
  selectors were produced with `cast sig` and cross-checked against the
  deployed bytecode; `getLink` and `getLinksByCreator` decode to named
  objects.
- **Reads need no wallet.** Fee, allowlist, ledger, invoice state, balance,
  allowance and the chain clock are unsigned `eth_call`s with endpoint
  failover, so the page — and the read-only Playwright project — render with
  nothing connected.
- **Writes go through an injected wallet** (MetaMask, OKX Wallet…): create →
  share card with QR → approve → pay → claim → cancel, plus a ledger with
  stats and state filters. The contract's rules are mirrored, not re-invented:
  a 1–280-byte note, expiry written in *chain* time, a `linkExists` id check
  before anything is signed, the payee refused their own link with an
  explanation instead of a reverting transaction, and **no approve/pay button
  while the balance is short** — only the MOCK faucet.
- **pUSD is labelled `MOCK` everywhere** it is named.

```powershell
node frontend/test/abi.test.mjs       # 62 assertions: selectors + encoding vs cast, decoding vs live-chain vectors
cd e2e; npm install
npx playwright test --project=smoke   # 29 tests: 21 NEAR + 8 X Layer, mocked, no egress
npx playwright test --project=testnet # read-only live checks, dispatched manually only
```

**What it does not prove:** no signing is automated — wallet approvals stay
human, in `e2e/TESTNET.md` Journey D — and the browser journey has not been
run end to end yet (the *scripted* journey has: twelve transactions across
deploy and both payer paths, deltas summing to zero, with the rule table
paying one claim and the fallback paying the other —
[`docs/RESEARCH.md` §17](docs/RESEARCH.md)). The gasless
payment leg is proven by that script rather than by this page, because **no
relayer runs on X Layer**: v1 has the payer sign and pay both transactions
themselves. Gasless link creation is not ported either. The page's ABI codec
still speaks the previous contract interface and is the next phase to update.
Full record: [`docs/RESEARCH.md` §16](docs/RESEARCH.md) (page) and
[§17](docs/RESEARCH.md) (contract).

---

## How to use

> These steps are the acceptance criteria for this build. They are written as
> `do X, see Y` so a reviewer can follow them without asking anyone.

**Network:** NEAR testnet · **Cost:** free (faucet-funded)

1. **Get two funded accounts.** Create a payee and a payer in a wallet the app
   lists (Meteor gives each new testnet account 10 NEAR). Then give the payer
   test USDC — either in the app (open any link, expand **No test USDC?**,
   press **Get test tokens**) or ahead of time with one call:

   ```bash
   curl -X POST https://www.usetidepool.tech/v0/faucet \
     -H "Content-Type: application/json" \
     -d '{"accountId":"<payer>.testnet","mode":"wallet"}'
   ```

   See `ft_balance_of(<payer>)` return `"100000000"` (100 USDC, 6 decimals).
   The wallet must hold the key for these accounts, because only the wallet can
   sign the app's transactions. If you created them with
   `near account create-account sponsor-by-faucet-service`, import the generated
   key into the wallet first.
2. **Create a link.** Open the app, connect a wallet, enter an amount and an
   optional note, press *Create link*. The button reads *Creating link…* while
   the wallet prompt is open; the app then lands on the share page with a
   copy field, a QR code, WhatsApp / Telegram / Email buttons and the status
   pill *UNPAID*.
3. **Copy the link.** Press *Copy* — the button flips to *Link copied!* — and
   open it in a second browser profile or a second wallet.
   See the link rendered with *Pay* available — the amount in dollars with an
   indicative naira line beneath it (fetched once from a public FX reference,
   hidden on its own if that reference is unreachable) — and *Expired* or *Paid*
   correctly reflected once the state changes.
4. **Pay it.** Switch the wallet to a payer account, press *Pay*, approve the
   transaction. See the timeline move `Open → Paid` and the payer's token
   balance decrease by exactly the link amount. If the payer holds no USDC,
   expand **No test USDC?** first: *Get test tokens* funds them for free, and
   the swap row covers the exact amount from wNEAR, USDT or ETH instead.
5. **Watch it release.** There is no second approval. The status line moves
   from *Your payment is being confirmed.* to *Payment confirmed! Your funds
   are being released automatically.*, and the keeper Worker — a Cloudflare
   cron sweeping every minute from its own gas account — calls `claim`. See
   the timeline move `Paid → Claimed`, the status line read *Payment completed
   successfully. The recipient has received the funds.*, the payee's token
   balance increase by 99.5% of the invoice, and the fee account increase by
   0.5%. `claim` is callable by anyone but can only pay the link's creator, so
   the payee never signs anything either. The *Release* button stays on the
   `PAID` card as manual fallback — anyone can press it if the keeper is ever
   down — and a second release attempt fails with `link is not paid`.
6. **Check My links.** Enter the creator account in *My links* and press *Load*.
   See the link listed with its id, amount, status and the payer that
   settled it — read straight from `get_links_by_creator`, unsigned. The stats
   row shows total received and awaiting payment; the filters narrow the list
   to All / Unpaid / Paid / Expired. The **Activity** panel works the other
   way round: a payee sees their created links from the chain, while a payer
   sees only the links this browser paid for — those ids are written to
   `localStorage` at payment time, because the contract indexes by creator,
   not by payer. Clearing site data clears that local history and nothing
   else.
7. **Export it.** Press *Export CSV*. See a file an accountant can open that
   contains the same rows with no jargon columns — no gas, no contract
   addresses, no yoctoNEAR.
8. **See a payment rejected.** Call `ft_transfer_call` on the token with an
   `amount` below the invoice and `msg` set to the link id. See the call
   succeed, the token contract refund the payer in full, and the link still
   `OPEN`.
9. **See a forgery rejected.** Call any method you can find that would mark a
   link paid without paying. See that no such method exists, and that
   `ft_on_transfer` from a token contract that is not on the allowlist returns
   the amount instead of crediting anything.

---

## Security

The design choices here are the product. They are listed because a reviewer
will look for them.

| Risk | Handling |
| --- | --- |
| Forging a "paid" status | No such method exists. Payment status is written only by `ft_on_transfer`, called by the token contract. |
| Payee pays their own link | `ft_on_transfer` returns the full amount when `sender_id == link.creator`, so a self-payment is refunded and the link stays `OPEN`. The UI shows the payee a waiting state instead of a Pay button. |
| Fake tokens | `predecessor_account_id` is checked against an allowlist. Unexpected token contracts get the full amount returned, per [NEAR's `ft_on_transfer` guidance](https://docs.near.org/smart-contracts/security/cross-contract-calls/ft-transfer-call). |
| Underpayment | The credited amount must be at least the invoiced amount, otherwise the full amount is returned. |
| Replaying one payment across links | Each `msg` names one link, and a link can only leave `OPEN` once. |
| Payee never receives the funds | `claim` pays only `link.creator` and the fee account, never the caller. A failed transfer reverts the link to `PAID` so anyone can retry. |
| Payee not registered with the token | `create_link` registers the payee but does not wait for the result, so `claim` now registers them again before every payout — a `storage_deposit` paid from the contract's own balance, refunded in full when the payee is already registered. If that registration fails, the payout batch fails too, `on_claimed` returns the link to `PAID`, and the next attempt — the keeper's next sweep or a press of the *Release* button — starts over. A slow registration can delay a payout; it can no longer strand one. Fixed in this build and deployed: test `claim_re_registers_the_payee_before_paying_out`, live in tx [`AZES8yzvj3nBxWeAe4HmgYfQMbqBPBYwGzdBXGUkDvYy`](https://testnet.nearblocks.io/txns/AZES8yzvj3nBxWeAe4HmgYfQMbqBPBYwGzdBXGUkDvYy). |
| Stuck links crowd out others | The keeper claims at most 10 links per sweep — a per-tick gas bound, not a queue with a tail. Every sweep re-reads contract state and takes the first 10 links still sitting in `PAID`, in contract key order, so a link one tick settled leaves the set and the next one in key order moves up. A link whose claim fails does not move to the back — it keeps its place in that order and is retried on every later sweep, holding one of the ten slots until a claim lands. That is precisely why the one failure which could make a claim fail forever (an unregistered payee) is now retried inside `claim` itself: the retry has to succeed rather than occupy a slot indefinitely. The *Release* button calls the contract directly and bypasses the keeper entirely. |
| Someone claims on the payee's behalf | `claim` is deliberately callable by anyone, but the payout address comes from the invoice, not from the caller. A stranger can only cause the payee to be paid. |
| Payer loses money on a bad payment | Every rejection returns the full amount; the token contract refunds the sender. |
| Deployer holds power | No admin function, no owner and no withdrawal path in the contract's code. The fee account and the 0.5% rate are fixed at deploy; changing either needs a code upgrade signed by the deployer's key — and that key can redeploy the contract, so the deployer retains that one power outside the code. |

**Not audited.** This is a hackathon build. Do not send real funds to
it.

---

## Honest limitations

Stated plainly, because saying otherwise would be worse than saying it.

- **Testnet only.** The demo runs on NEAR testnet with
  `usdc.tidepool-sandbox.testnet` (6 decimals) — Tidepool's sandbox test USDC —
  so no real money is involved. The contract is written to run on mainnet USDC
  unchanged — only an allowlist entry and a frontend config value would differ —
  but it has not been deployed there or tested against a mainnet token. The
  accepted token is also fixed at deploy (`#[init]` runs once), so moving this
  build to a different token took a fresh contract account — exactly how it
  went from `paylink.testnet` to `paylink-v2.testnet`, as described in
  [Development](#development).
- **Not production ready.** No audit, no indexer. Payment detection relies on
  the frontend polling contract state; the relayer caps submissions per IP and
  keeps a balance floor, but nothing here is hardened for mainnet traffic.
  Both of those guards are best-effort rather than a hard bound: the per-IP
  count lives in a single Worker instance's memory (a second instance allows
  the full quota again, and a restart clears it), and `ALLOWED_ORIGIN` only
  constrains browsers, which a script is free to ignore — so the real limit
  is the relayer's 1 NEAR balance floor, several hundred links away at the
  current balance. Testnet NEAR only, so nothing of value is at stake.
- **X Layer build: testnet only, and the UI proves less than the script.**
  `frontend/xlayer.html` runs against chain 1952 with pUSD — a **MOCK** token
  with a public `mint` and nothing behind it. Its automated tests cover the
  read path and every rendered state (62 codec assertions, 8 mocked page
  tests, 4 live read-only tests); the signing journeys stay manual in
  `e2e/TESTNET.md` Journey D, because wallet approvals are the security
  boundary and are never automated here. The payer signs and pays both
  transactions themselves, since no relayer runs on X Layer, and X Layer
  mainnet remains read-only.

---

## Reused code and AI assistance

Disclosed under [HACKATHON.md](https://nearhackathon.com/HACKATHON.md) **Q-002**
(existing product on another chain) and **Q-005** (list reused code and AI code).

**Reused from my earlier [Polaris](https://github.com/RaphaelC4/Polaris) project**
(GenLayer StudioNet, committed 23-26 Oct 2026 — a different chain, not part of
this submission):

- The static, build-step-free frontend structure: hash routing, the tabbed
  shell, and the `?flat=1` screenshot flag.
- The CSS conventions that came with it: `.tiny`, `.mono`, `.pill`, `.net-k`
  and `html.flat`.

**Written new for this hackathon:** the NEAR contract, the keeper and parser
Workers, the NEAR wallet layer, the pay / release / My links flow, and the
design system — its palette, layout and components.

**Not used:** no GenLayer code, calldata codec or dependency appears anywhere in
this build.

**Third-party libraries**, listed per Q-005:

- [`@hot-labs/near-connect`](https://github.com/azbang/near-connect) (HOT
  Labs, MIT) — the wallet layer, vendored as `frontend/vendor/near-connect.js`
  so the page needs no bundler, no npm install and no CDN. At runtime it
  fetches its wallet-selector manifest from
  `raw.githubusercontent.com/hot-dao/near-selector` — the wallet's own
  registry; no application data leaves the browser. Documented in
  `frontend/vendor/README.md`.
- QR Code Generator by Kazuhiko Arase (MIT, per the file header) — vendored as
  `frontend/vendor/qrcode.js`; renders the QR in the browser with no image
  request.
- Satoshi by Indian Type Foundry — self-hosted `.woff2`, free under the
  [Fontshare licence](https://www.fontshare.com/licenses/itf-ffl); documented
  in `frontend/fonts/README.md`.
- Gemini — called only by `workers/parse/` behind a Worker secret, described in
  [Invoice parsing](#invoice-parsing-optional); the browser never holds the key.

**AI assistance:** this build was written with AI assistance (Claude) — the
contract, the frontend and the Workers. Q-005 explicitly allows it, so it is
listed here rather than left for a reviewer to infer. The X Layer port in
`contracts-evm/` and `docs/RESEARCH.md` was likewise produced with AI
assistance (Claude and OpenCode); every onchain claim in `docs/RESEARCH.md`
was verified by running code against the chain rather than by asking a model,
and no address, transaction hash or test result in this repository was
invented.

---

## Hackathon diff

Everything in this repository was committed inside the NEAR HACKATHON window
(19 Oct – 14 Nov 2026); there is no earlier code to exclude. Two tags mark the
window for review:

- `pre-hackathon` — empty baseline (the repository did not exist before the window)
- `hackathon-submission` — the state submitted for judging

Full diff between them:
<https://github.com/RaphaelC4/Paylink/compare/pre-hackathon...hackathon-submission>

---

## Development

```bash
# prerequisites: rustup with the wasm32-unknown-unknown target, cargo-near,
# near-cli-rs, and nasm (near-sdk's aws-lc-sys needs it for host builds)
cargo near new contracts/paylink-contract   # generated project; never hand-rolled

cargo test --lib                            # 56 unit tests, all pure host tests

# the JS suites — no dependencies, plain node (the parse Worker's
# own suite is documented in workers/parse/README.md):
node workers/relayer/test/parse.test.mjs    # 219 assertions: parse, signing, rate limits, L-08 failover, cancel gate
node workers/keeper/test/sweep.test.mjs     # 178 assertions: settlement, retry, logs, L-08 failover
node frontend/test/one-approval.test.mjs    # 26 assertions: one payer approval only
node frontend/test/parse-errors.test.mjs    # 48 assertions: parse errors + L-06 timeout
node frontend/test/rpc-retry.test.mjs       # 23 assertions: one read retry, never for writes
node frontend/test/relayer-fallback.test.mjs # 120 assertions: relayer outage → chain check → consent → direct
node frontend/test/cancel.test.mjs          # 52 assertions: creator-only cancel, arm→confirm, cancelled surfaces
node frontend/test/abi.test.mjs             # 62 assertions: X Layer ABI codec vs cast and live-chain vectors

# browser E2E (two projects, e2e/README.md has the detail)
cd e2e && npm install && npx playwright test --project=smoke   # mocked, no egress, runs on PRs
npx playwright test --project=testnet                          # live read-only, manual dispatch only

# build the wasm with its NEP-330 ABI embedded
cargo near build non-reproducible-wasm --abi-features near-sdk/unit-testing
#   -> contracts/paylink-contract/target/near/paylink_contract.wasm   (156 KB)

# testnet accounts (keys saved to ~/.near-credentials)
near account create-account sponsor-by-faucet-service paylink-v2.testnet \
  autogenerate-new-keypair save-to-legacy-keychain
near account create-account sponsor-by-faucet-service paylink-fees.testnet \
  autogenerate-new-keypair save-to-legacy-keychain

# deploy + init in one transaction. `new` registers the contract and the fee
# account with the token, so it needs 0.02 NEAR per allowlisted token.
near contract deploy paylink-v2.testnet \
  use-file target/near/paylink_contract.wasm \
  with-init-call new json-args \
  '{"allowed_tokens":["usdc.tidepool-sandbox.testnet"],"fee_account":"paylink-fees.testnet"}' \
  prepaid-gas '100.0 Tgas' attached-deposit '0.02 NEAR' \
  network-config testnet sign-with-keychain send

# frontend (static, no build step)
cd frontend && python -m http.server 8000
```

The live deployment is **`paylink-v2.testnet`**. The first account,
`paylink.testnet`, was initialised with the previous allowlist, and `#[init]`
runs once — switching the accepted token therefore took a fresh account with
the same wasm rather than a re-init.

The invoice parser is optional and is not built here. Deploy it by pasting
`workers/parse/src/index.js` into a Cloudflare Worker (dashboard → Workers &
Pages → Create → Worker), then add `GEMINI_API_KEY` as a **secret** and set
`ALLOWED_ORIGIN` to the demo's origin. Copy the Worker URL into
`frontend/config.js` as `parseEndpoint`. `workers/parse/README.md` has the
step-by-step and a `curl` check. Without it the "paste a payment request"
block simply does not render.

The release keeper deploys the same way: paste `workers/keeper/src/index.js`
into a second Worker (one file, no dependencies), add the `KEEPER_KEY` and
`TICK_SECRET` secrets plus four text variables (and optionally a fifth,
`RPC_URLS` — a comma-separated list of read-only RPC fallbacks; reads try
each endpoint in order, broadcasts always go to `RPC_URL` alone exactly
once), and set a `* * * * *` cron
trigger. `workers/keeper/README.md` has the steps and a `curl` check. Without
it nothing settles automatically: paid links wait until someone presses the
*Release* button, so the keeper is the settlement path rather than a backstop.

The relayer is a third Worker of the same shape: paste
`workers/relayer/src/index.js`, add the `RELAYER_KEY` secret plus five text
variables (optionally a sixth, `RPC_URLS`, with the same read-only failover
semantics as the keeper's), and put its `/submit` URL into `frontend/config.js`
as
`relayer.endpoint` (then bump the `?v=` cache bust). `workers/relayer/README.md`
has the steps and the fund check. With the endpoint empty the create form
sends the direct wallet transaction — the payee covers that one stake and gas —
so the demo works with or without it.

`--abi-features near-sdk/unit-testing` is not optional on a host build:
near-sdk's ABI step links a host `cdylib`, and `unit-testing` is what
supplies NEAR's host-side stubs. Without it the link fails on
`storage_has_key`, `promise_batch_create` and friends.

Keys belong in `.env`. Never in the repository.

---

## Deploy the demo

The frontend is static: no build step, no server, no GitHub. Any host that
serves a folder works. Two that need no install and no repository connection:

- **Vercel** — open <https://vercel.com/new/drop> and drag the `frontend/`
  folder onto the page. It returns an HTTPS URL in a few seconds. (The CLI
  works too: after `npx vercel login`, run `npx vercel deploy --prod` from
  the repository root, not from inside `frontend/` - the linked project's
  Root Directory is already `frontend`, so a deploy started there fails
  with `Root Directory "frontend" does not exist`.)
- **Cloudflare Pages** — Workers & Pages → Create → Pages → *Upload assets*,
  then upload `frontend/`.

Both keep the hash routing intact (`/#pay/<id>`), so payment links work as
soon as the folder is uploaded. If you deploy the parser too, set its
`ALLOWED_ORIGIN` to the new origin and put the Worker URL in
`frontend/config.js` before uploading.

---

## References

- [NEAR HACKATHON](https://nearhackathon.com/) · [HACKATHON.md](https://nearhackathon.com/HACKATHON.md)
- Track prompt: `tracks/08-realworld.md`
- [NEP-141 Fungible Token Standard](https://github.com/near/NEPs/blob/master/neps/nep-0141.md)
- [NEP-366 Meta Transactions](https://docs.near.org/protocol/transactions/meta-tx.md)
  · [NEP-461 signing scheme](https://github.com/near/NEPs/pull/461): used for
  `create_link`. The payee's wallet signs a `DelegateAction` off-chain, the
  relayer Worker validates it (receiver, method, stake, nonce, expiry, and the
  NEP-461 signature) and submits it signed by `paylink-relay.testnet`, which
  pays the gas and the 0.01 NEAR stake — while the inner call still runs with
  the payee as predecessor, so the link belongs to the payee exactly as with a
  direct transaction ([how the relayer works](#the-relayer)). The payer's
  wallet signs their own payment, and `claim` can be called by anyone but can
  only pay the invoice's payee and the fee account: the release is signed by
  whoever is holding the app (or by the keeper Worker). Between the two, the
  payee never holds gas at any point in the lifecycle.
- [1Click API](https://docs.near-intents.org/integration/distribution-channels/1click-api/quickstart) · [Tidepool testnet sandbox](https://www.usetidepool.tech/docs/quickstart)
- [NEAR docs index](https://docs.near.org/llms.txt) · [NEAR Intents docs index](https://docs.near-intents.org/llms.txt)
