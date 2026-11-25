# Pago

**Status:** Live on X Layer mainnet. Reviewed and tested by the author: 150+ tests (unit, fuzz, invariant, mainnet-fork), addresses and hashes verified on-chain. Start with small amounts while you get comfortable.

**Send someone a link. Get paid in stablecoins.**

Pago turns an invoice into a URL. A freelancer sends a client a link; the
client pays with the stablecoins already in their wallet on X Layer; the
payout lands exactly where the split tables fixed at creation say it should —
0.5% fee, no custody, no account for anyone to freeze. The payer signs the
payment; from then on nobody has to sign anything.

Built for **X Layer TapeOut Accelerate** (Oct 16 – Dec 7 2026).

Run it from `frontend/` — static files, no build step, see
[Development](#development).

**What it does, in one list**

- **Create a link in one transaction.** Amount, note, expiry and two split
  tables — a default that must pay exactly 100%, and a rule candidate — are
  fixed at creation; a share card with a QR code follows.
- **Two payer paths.** An ordinary ERC-20 `approve` + `pay`, or a gasless
  EIP-3009 authorization the payer signs off-chain and a third party submits.
  **The gasless path is not usable on the mainnet contract yet** — it ships
  with a selector bug, fixed and fork-proven but not yet redeployed; see
  [The gasless selector bug and its fix](#the-gasless-selector-bug-and-its-fix).
- **The payout is computed, not argued.** At claim, the contract asks a
  published 104-gate circuit (Split3) whether the rule table holds; anything
  wrong with the answer — revert, garbage, gas exhaustion, an unsafe verdict —
  leaves the default table in charge, so a link can never freeze.
- **Nobody can route the money.** `claim(linkId)` takes no result arguments,
  is callable by anyone, and can only pay the selected table's recipients and
  the fee account — never the caller.
- **Receipts, CSV and PDF** are rendered from real payout events read from
  the chain, not from UI state.
- **A testnet mirror** on chain 1952 with a MOCK token and a faucet; the
  mainnet page shows USD₮0 and USDG only.

---

## The problem

Getting paid across borders still costs money and time.

| Route | What it costs |
| --- | --- |
| Bank wire | $25–45 in fees, 3–5 days, bank details shared with a stranger |
| PayPal / Wise | Poor support from many countries, freeze risk, still not instant |
| "Just send me crypto" | Both sides must pick the same chain, avoid a wrong-network send, and understand gas |

Every route asks one side to learn the other side's world.

Pago removes that requirement. The payee creates a link in one transaction
and sends the URL; the payer signs once with what they already hold; the
contract settles per the tables fixed at creation. No invoice details over
chat, no seed-phrase hand-holding, nothing held in between.

---

## How it works

### The networks and the contracts

**Mainnet (X Layer, chain 196) — live, ordinary `pay()` only.**

- **Pago:** `0xd63Ae612Cf9Acb9Ac8F7801eF68E8e71068E492c` — **superseded by the
  fixed source below; carries the gasless selector bug.** No link has ever
  been created on it (see
  [The gasless selector bug and its fix](#the-gasless-selector-bug-and-its-fix)).
- **Tokens:** USD₮0 `0x779Ded0c9e1022225f8E0630b35a9b54bE713736` · USDG
  `0x4ae46a509F6b1D9056937BA4500cb143933D2dc8` — 6 decimals, both EIP-3009
- **Fee:** 50 bps → `0x7FCe520D881454EA234d371E1256B75843609b62`, immutable
- **Processor:** `0xDd6BB6fbda8ee867EF838bbE56ebA7d1EcC2c2f4`
- **Beacon → implementation:** `0xf70d1ed4f62CF3780157B0b421b7E2F45bD0991C`
  → `0x977f217887E085D298Cb3819cDAD5A0ee35F29B2`
- **`evaluatorPinned()`:** `true` — both legs of the live code check pass
- **Codehash:** the deployed Pago code matches the prediction made before the
  send: `0x175bafd0c7ac2d363bedbde2ac17ee8b12d4cd3e565028588f7aa95050f0305d`

Every address and hash above was read back from the chain, not typed from
memory: the read-back list is
[`docs/FRONTEND-HANDOFF.md` §9](docs/FRONTEND-HANDOFF.md), the deploy
receipts are `docs/tier2-mainnet-*.json` with the full run in
`docs/tier2-mainnet-run.log`, and the build record is
[`docs/RESEARCH.md`](docs/RESEARCH.md) §17 and §19.

**Testnet (chain 1952) — the frozen build, redeployed 2026-11-25 from the
selector-fixed source.** Pago
`0xa65118a1434123648515929ce744D591ECC01a4B` — the source is frozen at this
build, only bug fixes may follow — with pUSD **(MOCK)**
`0xa0b2C3Df01696C508859c4949D2f960f420E79b3`, processor stand-in **(EVM, not
hardware)** `0xd71531A68a01d8f4E0ADB3aD76B68707F22F9655` and mock circuit
beacon **(MOCK)** `0xA106F05F6319F0d354E8A05B9d48632d10fF673e`. **The testnet
pin reference is the MOCK stand-in; mainnet uses the recorded TapeOut
references** — never a bare "pinned". Both legs of the live check pass here
against those stand-ins, so `evaluatorPinned()` reads `true` and the
configured cap is stored but not enforced while the check passes.

**Both payer paths ran end to end against this build and reconciled to the
unit:** the live rule-6 check passed, so leg A's claim was paid from the
**rule table** — payee 497,500 plus 497,500 back to the rule seat, with the
claim event recording `usedRuleSplit=true` — and leg B fell to the default
split (payee 995,000, `usedRuleSplit=false`); payee +1,492,500, payer
−1,492,500, the contract kept 0 (links `pago-261125-020108-a` / `-b`).
**This run is the post-fix proof:** both the deployed Pago and the deployed
mock carry the corrected `uint256` EIP-3009 window, so the gasless leg
settles through the same selector shape real USD₮0 and USDG implement
(`0xcf092995` / `0x91d26f16`). The earlier 2026-11-19 run against the
pre-fix pair (`0x36d212b8…`) settled as well — but both sides shared the old
`uint64` shape and only agreed with each other, so it is kept as history,
not as evidence for real tokens. Another copy (`0xA4AA0B19…17bfF`) stays on
chain as the **failure-path proof**, where leg 1 is checked against the
recorded TapeOut shell the stand-in can never match, so both claims fell to
the default split instead ([`docs/RESEARCH.md` §17](docs/RESEARCH.md)). The
contract carries the master prompt's split-rule interface (rules 1–10,
[`docs/MASTER_PROMPT.md`](docs/MASTER_PROMPT.md)).

### How the beacon address is bound — stated plainly

`evaluatorPinned()`'s leg 2 asks a beacon for its `implementation()`. **That
beacon address is a constructor argument** (`circuitBeacon`, readable on the
contract): Pago cannot read another account's storage and cannot parse
bytecode onchain, so the link between that argument and the real processor
shell is established **offline, by disassembling the shell** — not derived
onchain. On mainnet the configured value is the beacon the recorded shell
hardcodes: **`0xf70d1ed4f62CF3780157B0b421b7E2F45bD0991C`**.

So a user has to trust the deployed constructor arguments for that binding —
this is **not "fully verified onchain"**, and nothing here claims it is.
What *is* verified onchain, on every read: leg 1 — the processor's
`extcodehash` equals the recorded shell hash; leg 2 — the configured beacon
currently reports the stored implementation address, and the code there still
hashes to the recorded implementation hash. `claim` re-runs both in the
transaction that pays.

Anyone can check the binding themselves on X Layer mainnet (chain 196):

1. `cast code 0x9de448A1CE9537d24199B3b5355239d73aA6F591 --rpc-url https://rpc.xlayer.tech`
   — processor #340: a 295-byte beacon-proxy shell.
2. `cast keccak <that code>` → `0x57aa306f…17d5`, the recorded shell hash.
   Look inside those bytes: the `PUSH32` literal and the EIP-1967 beacon
   slot both read `0xf70d1ed4…bd0991c`.
3. `cast call 0xf70d1ed4f62CF3780157B0b421b7E2F45bD0991C "implementation()(address)"`
   → `0x977f217887E085D298Cb3819cDAD5A0ee35F29B2`.
4. `cast keccak $(cast code 0x977f217887E085D298Cb3819cDAD5A0ee35F29B2 …)`
   → `0x7a15c353…1b30`, the recorded implementation hash.
5. `cast call <Pago> "circuitBeacon()(address)"` must return `0xf70d…` —
   the argument the constructor was given, i.e. the same address steps 1–2
   found inside the shell.

The disassembly and every recorded value are in
[`docs/RESEARCH.md` §18](docs/RESEARCH.md), and `ForkPin.t.sol` runs those
references against a local fork of chain 196.

### Payer paths

`pay(linkId, amount, expectedTermsHash)` is the ordinary path: approve, then
pay, both transactions signed by the payer. The second path is gasless — the
payer signs an EIP-3009 `transferWithAuthorization` off-chain and any account
may submit it and pay the gas; its nonce is derived from `(linkKey, payer)`,
so one authorization can never pay two links. Both USD₮0 and USDG were proven
to support EIP-3009 on X Layer mainnet during Phase 0 — **but Pago's own
interface asked for it with the wrong argument types**, so the gasless hop
reverts against both tokens until the contract is redeployed; see
[The gasless selector bug and its fix](#the-gasless-selector-bug-and-its-fix).
Creation itself is an ordinary transaction the creator pays for — there is no
meta-transaction wrapper around `createLink`.

### Who relays a gasless payment

**Nobody — there is no relay service in this build.** Both payer paths
settle through ordinary transactions on X Layer:

- **Normal pay** is two transactions from the payer's own wallet: `approve`,
  then `pay`. The payer signs both and pays both gas fees; no third party is
  involved at any step.
- **Gasless pay** is one free off-chain signature: the payer signs an
  EIP-3009 `transferWithAuthorization` (no gas, no token approval) and the
  **payee — or any account at all — submits it on chain and pays that gas.**
  `claim` only ever moves money to the link's payee and the fee account,
  never to the caller, so the submitter gains nothing by submitting: there
  is no funded hot wallet, no keeper and no service to trust or to run.
  **This leg does not settle on the current mainnet contract** — the selector
  bug above — so on mainnet today the working route is the normal `approve` +
  `pay`.

**The web page does not offer it yet.** The pay card has no gasless submit
button — a payer's wallet only ever signs `approve` + `pay`. The gasless leg
is demonstrated by script instead: the twelve-transaction run across deploy
and both payer paths, recorded in [`docs/RESEARCH.md` §17](docs/RESEARCH.md),
while the browser journey signs nothing off chain.

**Who runs it: whoever's transaction it is.** Every state change — create,
pay, claim — is sent by the participant whose wallet it comes from.
Settlement is manual too: on a paid link the pay card shows a *Release*
button, and anyone may press it (or call `claim` themselves) — the caller
is never paid by it.

**If gasless is unavailable** — the wallet will not produce the
authorization, the RPC is having a bad day, anything — **fall back to a
normal pay**: connect the payer's wallet and send `approve` + `pay` from
it. Same contract, same 0.5% fee, same result; the payer simply pays gas
for those two transactions.

### The gasless selector bug and its fix

**The gasless path does not settle against the real tokens on the mainnet
contract as it stands today.** The ordinary `pay()` path is unaffected and is
what the page offers; this section exists so nobody has to discover the
gasless failure the hard way.

The `IEIP3009` interface inside `contracts-evm/src/Pago.sol` declared the two
authorization window arguments as `uint64`:

```solidity
function transferWithAuthorization(address from, address to, uint256 value,
                                   uint64 validAfter, uint64 validBefore,
                                   bytes32 nonce, bytes calldata signature) external;
```

Argument types are part of a function's selector, so that declaration hashes
to **`0xd8fde8d5`**. Real USD₮0 declares the same two arguments as `uint256`,
which hashes to **`0xcf092995`**. `payWithAuthorization` therefore called a
function the token does not have, and the token hop of every gasless payment
reverted. USDG is a diamond, and the mismatched call came back as
`FacetNotFound` — which is how it was caught.

**The fix is two type keywords in the interface.** `validAfter` and
`validBefore` are now `uint256`, matching the real tokens. Nothing else moved:

- `payWithAuthorization` keeps its selector `0x69c1372a`
- `createLink` keeps its selector `0x6c5b7a11`
- the deployed size stays 15,327 bytes
- `abi.js` and Pago's own ABI are unchanged, so the frontend needs no edit

**Proven against a mainnet fork, not against a mock.**
`contracts-evm/test/PagoGaslessFork.t.sol` deploys a fresh Pago from the fixed
source onto a fork of chain 196, funds a payer with `deal()`, and signs a real
EIP-3009 authorization with `vm.sign` — no keystore and no mainnet transaction
involved. Eight cases, **8/8 passing**: a full settle against live USD₮0 and a
second full settle against live USDG (each: payer debited exactly, Pago
escrowed, `LinkClaimed(key, 995_000, 5_000, false)`, the payee paid 995,000,
the fee 5,000, escrow back to 0), a direct call proving USDG does not carry
the old selector, plus replay, expired, wrong-signer, wrong-nonce and
underpayment rejections.

**USDG too — and now proven the same way, not just probed.** USDG lacks the
old selector (`FacetNotFound` on `0xd8fde8d5`) but has the fixed one:
`0xcf092995` reaches the signature check and returns `InvalidSignature` for a
garbage signature, and a correctly signed authorization made with the payee's
key reached `InsufficientFunds` — the signature was accepted and the call
failed only for want of a balance. The fork suite then settles USDG
**end-to-end through Pago** against the genuine diamond
(`test_gaslessPaySettlesAgainstRealUSDG`: payer debited exactly, escrowed,
`LinkClaimed(key, 995_000, 5_000, false)`, payee 995,000, fee 5,000, escrow
0), and `test_usdgRejectsTheOldSelector` calls the diamond directly with the
uint64 form to prove that selector is really absent. USDG's `DOMAIN_SEPARATOR`
is `0x415f0706e345fcaf25d5be24c4fd7830d0054fc5742c51a0db9319c759bd3743`.
**Both allowlisted tokens are covered by the same eight cases.**

**Status: fixed and proven, not yet deployed.** Until a corrected contract is
live on X Layer mainnet and a real gasless payment has settled through it,
this README does **not** claim gasless works on mainnet. The steps are:

1. ✅ interface fixed in `contracts-evm/src/Pago.sol`
2. ✅ mock token pinned to the real USD₮0 shape in all three places
3. ✅ fork test passing against live USD₮0
4. ✅ this record
5. ✅ full suite, smoke and testnet green
6. ✅ testnet redeploy and exercise of both payer paths
7. ✅ read-only mainnet preparation (fork rehearsal: deploy passed,
   ~$0.01, predicted codehash `0x684a360f…d598ed` recorded)
8. mainnet redeploy — **requires the phrase `deploy to mainnet tier 1`**
9. a live 0.1 USD₮0 gasless demo payment — **requires the phrase
   `send mainnet demo payment`**

**The superseded mainnet contract.** The Pago at
`0xd63Ae612Cf9Acb9Ac8F7801eF68E8e71068E492c` is the build that carries the
bug, and it is superseded by the fixed source above. **No payment link has
ever been created on it:** `getLinksByCreator` returns an empty list for all
three addresses that have ever held its keys — the payee
`0x7FCe520D881454EA234d371E1256B75843609b62`, the payer
`0x6256B90E4f36ee9e7A16cd29E7705dbdc539ec7b` and the deployer
`0x3f1004AAeD662227d535D794dA679110111a2FC4` — and no `LinkCreated` event
appears in the 100 blocks following its deployment at block 76,435,642. Its
ordinary `pay()` path works; only the gasless hop is affected.

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
  adder, a full adder and a compare, so the byte string can be read next to
  the arithmetic it encodes instead of being an opaque hex blob.
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
link can never freeze. `evaluatorPinned()` turns true **only through rule 6's
two-leg onchain implementation check, and it is a live view rather than a
value frozen at deploy**: on every call it first compares `extcodehash` of
the deployed processor against the recorded TapeOut shell codehash (the shell
is a beacon proxy that hardcodes its beacon — probe and disassembly in
[`docs/RESEARCH.md` §18](docs/RESEARCH.md)), then calls the beacon's public
`implementation()` getter and requires the answer to equal the **stored
implementation address** *and* `extcodehash` of that address's code to equal
the recorded circuit implementation codehash — the master prompt's verbatim
instruction: "store the implementation address and its `extcodehash` and
verify both at claim." `claim` consults this check in the transaction that
pays (a failing check means the default table, not the rule table, applies)
and `createLink` consults it too (while it fails, every new link is capped at
`MAX_LINK_AMOUNT_UNPINNED[token]`) — so a change behind the beacon after
link creation is caught at payout time. Never the change detector, which
stays a public view anyone may run as evidence. **What a passing check
proves, at that moment:** the shell code is the recorded byte sequence and
the beacon still reports the recorded implementation address whose code is
the recorded byte sequence. **What it does not prove:** the proxy's
delegation binding (verified offchain by disassembly), that a future change
cannot happen — only that any change is visible to the next read, which is
exactly why the check runs live — or anything about what the payer's screen
showed. **The Q3 probe behind this (§18):** the recorded implementation
(`0x977f…29B2`) has no proxy layer of its own — no upgrade selectors, zero
EIP-1967 implementation/admin slots, no `DELEGATECALL`, no `SELFDESTRUCT` —
and the beacon's upgrade path is owner-gated with `owner() = 0` (frozen),
read-only probes today; nobody can swap it now, but a pin only ever proves
the code at the moment it was checked, hence the live re-run. Full
rule-by-rule audit: [`docs/RESEARCH.md` §17](docs/RESEARCH.md); the pin
investigation itself: [§18](docs/RESEARCH.md).

**On testnet that processor is a labelled stand-in, not hardware.** TapeOut
exists only on X Layer mainnet (the factory has no code on chain 1952 —
probe recorded in §17), so `test/mocks/ProcessorStandIn.sol` implements the
same interface and runs the **real Split3 netlist bytes** through the same
TAP-02 evaluator that was proven bit-for-bit against a live mainnet
processor. The verdicts come from the netlist; the deploy log says
"EVM stand-in, not hardware". Its code is not the recorded TapeOut
implementation — on testnet leg 1 checks the stand-in's own codehash
instead, which is exactly why the page never says a bare "pinned" — so
`evaluatorPinned()` reads **true** there and the configured cap is stored
but not enforced while the check passes; mainnet runs the recorded
processor and the recorded beacon, both legs pass against the recorded
references, and the flag reads true for the recorded build.

The other reason is the hackathon: the X Layer TapeOut Accelerate track
explicitly asks for TapeOut circuits, contracts or onchain data
([evidence in `docs/RESEARCH.md` §11](docs/RESEARCH.md)).

**Split3 is taped out — live on X Layer mainnet.** The full Tier 2 chain ran
as real transactions on chain 196: BEM fee → processor creation → mint →
`tapeout(Split3)` → Pago deployed against the processor's recorded
references, with the runtime codehash predicted before the send and asserted
after it, and `evaluatorPinned()` reading `true` on the read-back. Receipts:
`docs/tier2-mainnet-*.json`, run log: `docs/tier2-mainnet-run.log`, cost
itemisation: [`docs/RESEARCH.md` §14](docs/RESEARCH.md) — the measured quote
was **$1.74** (2026-11-20), re-run immediately before purchase. The whole
chain is reproducible against a live fork of chain 196, fee to claim, with
the rule table paying one claim ([§19](docs/RESEARCH.md)).

**The processor is our own, on purpose.** The cheaper route — tape out onto
an existing third-party processor — was not taken because **the processor
owner controls it**: who may mint, what a transistor costs, and the
processor's own rules are theirs. Our own processor keeps that control with
the deployer; its shell differs from the official CPU #340 only in the
32-byte IPFS metadata, so the recorded beacon and implementation references
carry over and only the shell hash is per-deploy.

---

## Security

The tests assert every property below:

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
  contract) falls back to the default table; while `evaluatorPinned()` reads
  false — re-checked live at every claim and link creation — every link is
  capped at `MAX_LINK_AMOUNT_UNPINNED[token]`.
- **The payee cannot settle their own link**, on either payer path.
- **An EIP-3009 signature is bound to exactly one link**: the nonce it must
  carry is derived from `(linkKey, payer)`, so an authorization signed for
  invoice A cannot be replayed against invoice B, and a link can only be paid
  once.
- **A rejected payment moves nothing.** Every guard runs before the token
  transfer, so an expired, cancelled, underpaid, wrong-terms or self-paid
  attempt costs the payer gas and no tokens.
- **The allowlist and expected decimals are fixed at construction.** Only
  allowlisted tokens can ever call back in; the deploy script aborts if the
  token's onchain `decimals()` disagrees with the value we wrote, and the
  contract never reads `decimals()` at runtime.
- **There is no always-on amount cap.** `MAX_LINK_AMOUNT_UNPINNED[token]`
  applies only while `evaluatorPinned()` reads false; on this deployment the
  check passes, so links are uncapped. Adding an always-on cap would be a
  contract change, and the source is frozen at this build.

**Status:** Live on X Layer mainnet. Reviewed and tested by the author: 150+ tests (unit, fuzz, invariant, mainnet-fork), addresses and hashes verified on-chain. Start with small amounts while you get comfortable.

---

## Tests

```powershell
cd contracts-evm
$env:XLAYER_RPC = "https://rpc.xlayer.tech"   # only the fork suites need it
forge test
```

The local suites — `PagoTest` (the full contract: guards, money paths, ledger,
both payer paths), `PagoRuleTest` (the master-prompt rules: terms consent,
circuit identity, the live implementation check behind `evaluatorPinned()`, and every
processor fault proven to fall back instead of freezing), `PagoInvariantTest` +
`PagoFuzzTest` (conservation: payouts + fee == credited, balance ≥ owed,
status never backward — 128,000 interleaved calls in the invariant run),
`Split3Test` (the exhaustive circuit check) and the TAP-02 reference
evaluator's own suite — need no network at all. The fork suites prove the
Tier 2 and Phase 0 claims against real X Layer mainnet state. **150+ tests,
0 failed** (run 2026-11-24; build record:
[`docs/RESEARCH.md` §17](docs/RESEARCH.md)).

---

## The X Layer page

`frontend/xlayer.html` (+ `frontend/xlayer.js`) is Pago's own UI.

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
- **MOCK tokens are labelled `MOCK` everywhere** they are named; the mainnet
  build shows USD₮0 and USDG only.

```powershell
node frontend/test/abi.test.mjs       # ABI codec: selectors + encoding vs cast, decoding vs live-chain vectors
cd e2e; npm install
npx playwright test --project=smoke   # 32 tests: mocked chain, no egress
npx playwright test --project=testnet # read-only live checks, dispatched manually only
```

**What it does not prove:** no signing is automated — wallet approvals stay
human, in `e2e/TESTNET.md` Journey D — and the browser journey has not been
run end to end yet (the *scripted* journey has: twelve transactions across
deploy and both payer paths, deltas summing to zero, with the rule table
paying one claim and the fallback paying the other —
[`docs/RESEARCH.md` §17](docs/RESEARCH.md)). The gasless payment leg is
proven by that script rather than by this page: the page has the payer sign
and pay both transactions themselves, while any account can submit an
EIP-3009 authorization off chain. Full record: [`docs/RESEARCH.md` §16](docs/RESEARCH.md)
(page) and [§17](docs/RESEARCH.md) (contract). **That run exercised the tokens'
EIP-3009 directly; the selector bug below was found afterwards, in Pago's own
interface, and the mainnet contract has not been redeployed with the fix** —
see [The gasless selector bug and its fix](#the-gasless-selector-bug-and-its-fix).

---

## How to use

> Written as `do X, see Y` so a reviewer can follow along without asking anyone.

**Network:** X Layer — testnet (1952) with the MOCK faucet, or mainnet (196)
via `?chainId=196`. **Cost:** testnet free, mainnet gas in OKB.

1. **Serve the frontend.** `cd frontend && python -m http.server 8321` and
   open `http://localhost:8321/pago-onboarding.html` (ES modules need http,
   not `file://`).
2. **Create a link.** Connect a wallet on the right chain, enter an amount and
   an optional note, press *Create link*, approve the transaction. The share
   card follows: copy field, QR code, WhatsApp / Telegram / email buttons.
3. **Open the link** in a second browser profile. See the amount, the 0.5%
   fee, the expiry, and the destination in plain words — one recipient reads
   **"No split. The full amount, minus the 0.5% fee, goes to \<address\>."**,
   a split reads the full rule table with the sentence **"If the rule check
   fails at payout time, this default split applies instead"**.
4. **Pay it.** Approve the token if the allowance is missing, press *Pay*,
   approve the transaction. Watch the status move `Open → Paid`.
5. **Watch it settle.** Anyone can call `claim`; it pays the selected table's
   recipients and the 0.5% fee, never the caller. The payout result renders
   from the claim events: seat legs, fee and claim transaction, with the rest
   behind *More details*.
6. **Check My links.** Load a creator address: id, amount, status, filters,
   CSV export — read straight from `getLinksByCreator`, unsigned.
7. **See a payment rejected.** Send less than the invoice (or pay an expired
   one): the transfer is refused or fully returned, the link stays `OPEN`,
   and the payer loses only gas.
8. **Check the pin yourself.**
   `cast call <Pago> "evaluatorPinned()(bool)" --rpc-url https://rpc.xlayer.tech`
   — reads `true` on mainnet against the recorded TapeOut references, and
   `true` on the MOCK testnet build as well: there both legs pass against
   the stand-ins, which is why the page labels it "testnet pin reference is
   the MOCK stand-in; mainnet uses the recorded TapeOut references" instead
   of a bare "pinned".

---

## Limits

- **No refunds.** Payment links are final once claimed.
- **Pays in stablecoins.** USD₮0 and USDG on X Layer.
- **No cash-out.** Pago moves stablecoins between wallets; there is no bank off-ramp.
- **No relay service.** A normal payment is sent from the payer's own wallet; a gasless one is a free off-chain EIP-3009 signature that the payee — or any account — submits, paying the gas. **The gasless leg does not settle on the current mainnet contract** (selector bug, fixed and fork-proven, not yet redeployed), so on mainnet today the working route is `approve` + `pay`.

---

## Reused code and AI assistance

**Reused from my earlier [Polaris](https://github.com/RaphaelC4/Polaris) project**
(GenLayer StudioNet, committed 23-26 Oct 2026 — a different chain, not part of
this submission):

- The static, build-step-free frontend structure: hash routing, the tabbed
  shell, and the `?flat=1` screenshot flag.
- The CSS conventions that came with it: `.tiny`, `.mono`, `.pill`, `.net-k`
  and `html.flat`.

**Written new for this submission:** the Pago contract and its split-rule
interface, the Split3 circuit and its netlist, the X Layer frontend (page,
ABI codec, receipts) and the test battery — unit, fuzz, invariant,
mainnet-fork and browser e2e.

**Not used:** no GenLayer code, calldata codec or dependency appears anywhere in
this build.

**Third-party code:**

- QR Code Generator by Kazuhiko Arase (MIT, per the file header) — vendored as
  `frontend/vendor/qrcode.js`; renders the QR in the browser with no image
  request.
- Satoshi by Indian Type Foundry — self-hosted `.woff2`, free under the
  [Fontshare licence](https://www.fontshare.com/licenses/itf-ffl); documented
  in `frontend/fonts/README.md`.

**AI assistance:** this build was written with AI assistance (Claude and
OpenCode) — the contract, the circuit, the frontend and the tests. Every
onchain claim in `docs/RESEARCH.md` was verified by running code against the
chain rather than by asking a model, and no address, transaction hash or test
result in this repository was invented.

---

## Hackathon diff

Everything from the X Layer work forward is committed in this repository; the
tag `xlayer-pre` marks the state before it began, so
`git diff xlayer-pre..HEAD` is the submission diff in one command.

What is new versus the earlier NEAR build is pointed at by tags rather than
carried in the tree: `pre-hackathon` marks the empty baseline that build grew
from and `xlayer-pre` its last state, so `git diff pre-hackathon..xlayer-pre`
shows that build on its own.

---

## Development

```powershell
# contract suites — Foundry; only the fork suites need the RPC
cd contracts-evm
$env:XLAYER_RPC = "https://rpc.xlayer.tech"
forge test                                 # 150+ tests: unit, fuzz, invariant, mainnet-fork

# frontend unit tests — no dependencies, plain node (repo root)
Get-ChildItem frontend\test\*.test.mjs | %{ node $_.FullName }

# browser e2e (from e2e/, npm install once; e2e/README.md has the detail)
npx playwright test --project=smoke        # 32 mocked tests, no egress
npx playwright test --project=testnet      # live read-only checks, manual dispatch only

# local preview (ES modules need http, not file://)
cd frontend && python -m http.server 8321  # → http://localhost:8321/pago-onboarding.html
```

Keys belong in `.env`. Never in the repository.

---

## Deploy

The frontend is static: no build step, no server, no GitHub. Any host that
serves a folder works. Two that need no install and no repository connection:

- **Vercel** — open <https://vercel.com/new/drop> and drag the `frontend/`
  folder onto the page. It returns an HTTPS URL in a few seconds. (The CLI
  works too: after `npx vercel login`, run `npx vercel deploy --prod` from
  the repository root, not from inside `frontend/` — the linked project's
  Root Directory is already `frontend`, so a deploy started there fails
  with `Root Directory "frontend" does not exist`.)
- **Cloudflare Pages** — Workers & Pages → Create → Pages → *Upload assets*,
  then upload `frontend/`.

Hash routing stays intact (`#pay/<id>`), so payment links work as soon as the
folder is uploaded.

---

## References

- [`docs/RESEARCH.md`](docs/RESEARCH.md) — the build record: §16 (page),
  §17 (contract, rule-by-rule), §18 (pin investigation), §19 (Tier 2 on a
  live mainnet fork)
- [`docs/MASTER_PROMPT.md`](docs/MASTER_PROMPT.md) — the split-rule interface
  (rules 1–10) the contract implements
- [`docs/FRONTEND-HANDOFF.md`](docs/FRONTEND-HANDOFF.md) — selectors, struct
  layout, wording rules, verified read-backs
- [EIP-3009 `transferWithAuthorization`](https://eips.ethereum.org/EIPS/eip-3009)
  · [EIP-1967 proxy slots](https://eips.ethereum.org/EIPS/eip-1967)
- X Layer: RPC `https://rpc.xlayer.tech` · explorer
  <https://www.oklink.com/xlayer> · docs <https://docs.xlayer.com/>
