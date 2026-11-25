# Frontend handoff — Pago on X Layer

Everything the frontend work needs, with the evidence for each value. Written
after the Tier 2 mainnet deploy (commit `0e54ddb`, 2026-11-20) so nothing here
has to be re-derived. Each line says where it came from: **read back** means a
live call answered during the mainnet run or right after it; **bytecode** means
the selector was matched inside the deployed runtime code (`63<selector>`
present) on that chain; **config** means it is a fixed parameter.

## 1. Network blocks

`frontend/config.js`, `XLAYER.pago.mainnet` is currently `null` — fill it with
this block. Testnet block stays as-is.

| Key | Mainnet value | Evidence |
|---|---|---|
| `chainId` | `196` | read back (deploy run) |
| `rpc` | `https://rpc.xlayer.tech` (alt `https://xlayerrpc.okx.com`) | config |
| `explorer` | `https://www.oklink.com/xlayer` | config |
| `pago` | `0x2fC4180db7318F4364F6FC559A25359c9F537D3e` — **fixed build live since 2026-11-25 (step 8); the old `0xd63Ae612…492c` is superseded (carries the selector bug, no link ever created on it)** | read back: receipt status `0x1`, block 76,820,955, tx `0x37683583826c0b16601ef067172287e767d7e788933da61a2f39296e51e98fe7`, runtime codehash `0x684a360f7560dfc77c2782f0309580fde43354521d669e7f6c5f535065d598ed` == pre-send prediction (RESEARCH §21) |
| `token` | **two** tokens (this deployment accepts both) | read back: `isTokenAllowed` true for each |
| USD₮0 | `0x779Ded0c9e1022225f8E0630b35a9b54bE713736`, 6 decimals, EIP-3009 | read back: `isTokenAllowed` true, `expectedDecimals` 6; EIP-3009 proven Phase 0 (RESEARCH §8) |
| USDG | `0x4ae46a509F6b1D9056937BA4500cb143933D2dc8`, 6 decimals, EIP-3009 (diamond) | same; both tokens implement the **fixed** selector `0xcf092995`, not Pago's old `0xd8fde8d5` |
| `feeBps` | `50` (0.5%) | read back: `feeBps()` = 50 |
| `feeAccount` | `0x7FCe520D881454EA234d371E1256B75843609b62` | read back: `feeAccount()` |
| `unpinnedCap` | `10_000_000_000` per token (10,000 at 6 decimals) | read back: `MAX_LINK_AMOUNT_UNPINNED(token)` for both |
| `deployer` | `0x3f1004AAeD662227d535D794dA679110111a2FC4` | keystore `pago-deployer`, nonce 12 after deploy |
| `payee` | `0x7FCe520D881454EA234d371E1256B75843609b62` | keystore `pago-payee` |
| `tokenIsMock` | **omit / false** — these are real stablecoins | config |
| `networkLabel` | `"X Layer mainnet"` | — |

Testnet block keeps `tokenIsMock: true`, label `"X Layer testnet"`.

## 2. The rule path on mainnet (no MOCK anywhere)

| Key | Value | Evidence |
|---|---|---|
| processor (circuits) | `0xDd6BB6fbda8ee867EF838bbE56ebA7d1EcC2c2f4` | read back: `processor()` on Pago; codehash `0x8c799a18cd8e0d5f5f3c0cec4fbc145e2daf79f70c2b131c09d0f380921db545` == recorded TapeOut shell (read back) |
| transistors | `0x96bCbd899f9D422b7051C492213DBEC68699B798` | read back: capability probe, `mintPrice()` 0, `protocolFee()` 1000000 |
| `circuitId` | `1` | read back: tape-out returned 1; `netlist(1)` served the 728-byte Split3 netlist byte-for-byte |
| netlist keccak | `0xa593ea65a0b457237eb079b0e51f27911b3bd5c70653108796ef540848fb343f` | read back: hash of served bytes == hash of `script/split3-netlist.hex` |
| shape | 15 inputs, 1 output, 104 NANDs, shares in 500 bps steps, `SPLIT_STEPS = 20` | config / contract |
| `evaluatorPinned` | **true** | read back on mainnet: real two-leg check (§18) against recorded shell + beacon `0xf70d1ed4f62CF3780157B0b421b7E2F45bD0991C` + impl `0x977f217887E085D298Cb3819cDAD5A0ee35F29B2` / `0x7a15c353…1b30` |

Because `evaluatorPinned()` is true on mainnet, the unpinned cap is **stored
but not enforced** there (contract enforces it only while the flag is false).
The page must say which state it is showing, same honesty rule as testnet.

Testnet keeps its current labels: processor stand-in **(EVM stand-in, not
hardware)**, mock beacon **(MOCK)**, and the required sentence *"testnet pin
reference is the MOCK stand-in; mainnet uses the recorded TapeOut references."*
Never a bare "pinned" on testnet. On mainnet the rule path is the real
circuit — **no MOCK label on any mainnet surface**.

## 3. Selectors — two in `abi.js` are stale

Verified with `63<selector>` present in the deployed runtime code of **both**
mainnet Pago and testnet Pago (they share one dispatcher):

| Function | Selector | Status |
|---|---|---|
| `createLink(string,uint256,address,string,uint64,(address[3],uint8[3]),(address[3],uint8[3]))` | `0x6c5b7a11` | **current `0x167f1e66` is WRONG** — absent from both chains (old 5-param form is gone) |
| `pay(string,uint256,bytes32)` | `0x8032337c` | **current `0x901c5953` is WRONG** — absent from both chains (2-param form is gone) |
| `payWithAuthorization(string,address,uint256,uint64,uint64,bytes32,bytes,bytes32)` | `0x69c1372a` | not in `abi.js` yet (gasless payer path) |
| `termsHash(string)` | `0xe93341c4` | not in `abi.js` yet — required by both pay paths |
| `evaluatorPinned()` | `0xca24c8f4` | not in `abi.js` yet |
| `MAX_LINK_AMOUNT_UNPINNED(address)` | `0x7754d140` | not in `abi.js` yet |
| `claim(string)` | `0xf3fe12c9` | correct |
| `cancelLink(string)` | `0xc49dc85c` | correct |
| `getLink(string)` | `0x7476452a` | correct |
| `getLinksByCreator(address)` | `0x4afe4a95` | correct |
| `linkCountByCreator(address)` | `0xc0f27021` | correct |
| `linkExists(string)` | `0xa34cc22b` | correct |
| `feeBps()` | `0x24a9d853` | correct |
| `isTokenAllowed(address)` | `0xf9eaee0d` | correct |

`frontend/test/abi.test.mjs` pins these — update it together with `abi.js`.

## 4. ABI struct changes

`Link` grew by three trailing fields (both chains' `getLink` now returns them;
the old 12-field decoder will misread the struct):

```
… existing 12 fields …
defaultSplit  (address[3] recipients, uint8[3] shares)   // Split tuple
ruleSplit     (address[3] recipients, uint8[3] shares)   // Split tuple
netlistHash   bytes32                                    // keccak of netlist read at create
```

`Split` wire format: two static members — `address[3]` then `uint8[3]`, each
element its own 32-byte word. Shares are **steps** where 20 steps = 100%
(`SPLIT_STEPS = 20`, `shareStepBps = 500` → 1 step = 5%). A default table must
sum to exactly 20; a rule table's shares must each be 0–31 (5-bit fields); its
sum is the circuit's verdict and is deliberately not checked at creation.

## 5. Pay flow (rule 4)

1. Read the link (`getLink`).
2. Fetch consent hash from the chain: `termsHash(linkId)` → `bytes32`
   (`0xe93341c4`). It is `keccak256(abi.encode(linkId, amount, token,
   description, expiresAt, defaultSplit, ruleSplit, FEE_BPS, feeAccount,
   netlistHash, processor, circuitId))` — everything the payment is bound to.
3. Send `pay(linkId, amount, expectedTermsHash)` = selector `0x8032337c`.

**Wording rule (rule 4):** the terms hash binds the payer to the terms
*recorded onchain*. Never write that it proves what the payer saw on screen.

Gasless variant `payWithAuthorization` (`0x69c1372a`) takes the same
`expectedTermsHash` as its last argument; nonce comes from
`authorizationNonce(linkKeyOf(linkId), payer)`.

## 6. Create flow

`createLink` now takes both split tables — presets proven by
`script/testnet-exercise.ps1` (both legs ran live on testnet):

```
default: [payee, 0x0, 0x0], shares [20, 0, 0]      // payee 100%, sums to 20
rule:    [payee, X, X],     shares sum ≤ …         // 0–31 per seat; circuit judges the sum
```

Validation the contract enforces (mirror in the form's errors): link id 4–64
chars; amount > 0; description 1–280 chars, not blank; expiry in chain time
(`nowMs()`, not the browser clock); unique id; default sum == 20 with honest
seats (zero share ⇔ zero recipient); rule shares 0–31 with honest seats; while
`evaluatorPinned()` is false, `amount <= MAX_LINK_AMOUNT_UNPINNED[token]`.

## 7. Pay card — required content before the payer pays

Show, from the link's own stored fields:

1. **The rule** — what the Split3 circuit judges (the rule table's three
   shares, the circuit identity `netlistHash`, processor `0xDd6BB6fb…`,
   `circuitId 1` on mainnet).
2. **The default split** — the stored default table, seat by seat.
3. **The cap** — `MAX_LINK_AMOUNT_UNPINNED[token]` = 10000000000, labelled
   with whether it is being *enforced* right now (enforced only while
   `evaluatorPinned()` is false; on mainnet it is true, so stored-not-enforced).
4. The sentence, verbatim: **"If the rule check fails at payout time, this
   default split applies instead"**.

**Amendment (one-recipient links).** Every pay card must show these details
before payment. For a one-recipient link — both the rule and the default
table pay 100% to the same seat-1 destination, nothing to seats 2 and 3 —
the card shows one plain line above the invoice table, **"No split. The full amount,
minus the 0.5% fee, goes to \<payee address\>."**, under it the small line
**"The rule check can't change where this money goes."**, and the details
above may be collapsed into a **"Payment details"** section (one click
away, collapsed by default, always visible before the Pay button). For those
links the details may be collapsed, but they must be present and must not
be removed from the page. Multi-recipient links are unchanged: they show the
full rule card as it renders today.

## 8. Labels and honesty rules

- Network chip / footer: **"X Layer mainnet"** when the page runs on chain 196,
  **"X Layer testnet"** on 1952. Never a bare "testnet" on the mainnet build.
- MOCK labels (`pUSD (MOCK)`, the MOCK badge, faucet button, "fake money"
  note) appear **only** where `tokenIsMock` is true — testnet. Mainnet shows
  `USD₮0` / `USDG` as allowlisted stablecoins.
- **Say nothing about being audited.** The current testnet footer carries
  `… · not audited · …` — that line must go, not be reworded.
- The receipt sentence in `frontend/receipt.js` is NEAR-specific
  (`"Payment delivered and verified on NEAR"`) — the X Layer page needs its own
  honest sentence; don't reuse the NEAR one.
- **Never claim gasless works on mainnet** until a corrected contract is
  deployed there and a real payment has settled through it. The current
  mainnet Pago carries a selector bug in its EIP-3009 interface (`uint64`
  window args → `0xd8fde8d5`; the real tokens want `uint256` → `0xcf092995`),
  so its gasless hop reverts against both USD₮0 and USDG. The ordinary
  `approve` + `pay` path is unaffected and is what the page offers. Full
  record: `README.md` "The gasless selector bug and its fix".

## 9. README verification marks

Mark an address **verified** in `README.md` only where a read-back proved it.
Currently proven (safe to mark): Pago (code + codehash), USD₮0, USDG, fee
account, processor + its codehash, transistors, factory (`cpuCount` 437,
`deployFee` 1e7), beacon, implementation (+ codehash), both caps, `feeBps`,
`evaluatorPinned`, netlist identity. Everything else stays unmarked until a
call answers.

**OKLink source verification** for Pago is free and worth doing: submit the
verified source for `0xd63Ae612…492c` on `oklink.com/xlayer`, then mark it
"source verified" in the README only after the explorer shows it. Nothing in
the repo may claim explorer verification before that happens.

## 10. Commands

```text
# frontend unit tests (from repo root)
Get-ChildItem frontend\test\*.test.mjs | %{ node $_.FullName }

# local preview (ES modules need http, not file://)
cd frontend && python -m http.server 8321     # → http://localhost:8321/xlayer.html

# e2e Journey D (from e2e/, never in parallel with other e2e runs)
npx playwright test --project=testnet
# spec: e2e/specs/testnet/xlayer.testnet.spec.mjs, CLAIMED_LINK = "pago-261125-020108-b"
```

Journey D must pass before the demo video. Testnet and mainnet caps are
separate config values — never share one between the blocks.
