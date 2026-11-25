# Pago on X Layer — Phase 0 Research Log

> **Update (Phase 1):** §13 corrects three Phase 0 conclusions that turned out
> to have the wrong cause — `createCPU`'s failure, the factory's implementation
> slot, and what taping out actually requires — and §14 prices the mainnet
> tape-out that is deliberately **not** started. Read §13–§14 as current and
> §10 as superseded where they disagree.
>
> **Update (contract rules):** §17 implements the master prompt's rules 1–10
> (`docs/MASTER_PROMPT.md`), redeploys Pago on testnet with the new interface,
> and supersedes §15's addresses. §16's closing audit bullet is resolved there.

Everything below was **read from X Layer mainnet (chain 196) or proven on a local
fork of it** during Phase 0. Nothing here is taken from documentation alone:
third-party docs about TapeOut fees and addresses were found to be stale, so
every fee, address and selector in this file was read live from the chain.

**AI assistance:** this research and the accompanying code were produced with the
help of AI models (Claude, OpenCode). All onchain claims below were verified by
running code against the chain, not by asking a model.

---

## 1. What TapeOut is, in one paragraph

TapeOut is a protocol on X Layer where anyone can deploy a **processor** (a pair
of contracts: `circuits` + `transistors`) and then **tape out** boolean circuits
onto it. A circuit is stored as a **netlist** — a compact byte string of NAND
gates — and anyone can call `eval(circuitId, inputs)` to get the circuit's
outputs, with the computation done by the chain itself. That makes a payment
rule literally a piece of published hardware: the rule is inspectable (you can
read the netlist), reproducible (the same inputs always give the same outputs)
and enforced by the same code that holds the money.

This is the hook Pago uses: **a payment link's terms are a circuit**, so the
payer and the payee can both verify the split/fee/deadline logic before any
money moves.

---

## 2. Verified addresses (X Layer mainnet, chain 196)

| Role | Address | How verified |
|---|---|---|
| TapeFactory (ERC-1967 proxy) | `0x1f09DAeFA827f02CBb40967cc91b259763760761` | `eth_getCode` non-empty |
| TapeFactory **implementation** | `0x336e9F0F4c3fEe7C8c803377e4DEA00293f4ae2a` | read from ERC-1967 slot `0x360894a1...` |
| Circuit beacon | `0xf70d1ed4f62cf3780157b0b421b7e2f45bd0991c` | read from processor-340 beacon slot |
| Transistor beacon | `0x1059Ad62cAbB6a6925bb65aA617300556c60A51B` | read live |
| Factory `owner()` | `0xB3D85b42A045c1A88D800CAD0F55d2566a4D3138` | read live |
| Factory `protocolWallet()` | `0x571d447f4f24688eC35Ccf07f1D6993655F6aF15` | read live |
| Circuit beacon `owner()` | `0x0000000000000000000000000000000000000000` (frozen) | read live |
| Circuit beacon `implementation()` | `0x977f217887E085D298Cb3819cDAD5A0ee35F29B2` | read live |
| Processor **#340** (circuits) | `0x9de448A1CE9537d24199B3b5355239d73aA6F591` | read live; holds circuit #1 |
| Processor #340 (transistors) | `0x729F874FF12faAdd73e8F921D65d23516717b145` | read live |
| Processor **#30** | `0x2046aa63bFB03f393AD85a518011fdf8aF3DDB53` | read live; 5 circuits |
| Processor **#333** | `0xE2a6c6393b5A8B99cb481035eB8e244C66641cd7` | read live; 19 circuits |
| Processor **#334** | `0x00586A4C37039aCbFC6aC135cAdd49367ABf390A` | read live; 33 circuits |
| Container opener | `0x536adD8F30f03b69f6fbF29d425A816A0dC50106` | read live; see §7 || Container opener implementation | `0xAC4f791353Ee9f06E2c50Ae4C34680d28ea52a57` | read from ERC-1967 slot |
| Container `registry()` | `0x000000006551c19487814612e58fe06813775758` | read live |
| Container `treasury()` | `0xE2f77062c6060503e0289c6638D1B0A7C76cBB9d` | read live |
| Container `payments()` | `0x13b8AFa4Fd1b29B09D23A57A75ba8D3078d44858` | read live |
| Processor #340 circuits (ERC721) | `0x9de448A1CE9537d24199B3b5355239d73aA6F591` | `ownerOf(1)` resolves |

> **Note on the implementation address.** The factory's ERC-1967 implementation
> slot holds `0x336e9F0F...`, which is *not* the "sealed" implementation
> described in third-party documentation. Source for `0x336e9F0F...` could not be
> retrieved (sourcify 404, etherscan v2 rejects chainid 196), so its behaviour was
> established by **disassembling the bytecode** — see §6.

### Stablecoins and tokens

| Token | Address | Notes |
|---|---|---|
| USDT0 | `0x779Ded0c9e1022225f8E0630b35a9b54bE713736` | EIP-3009 `transferWithAuthorization` works |
| USDG | `0x4ae46a509F6b1D9056937BA4500cb143933D2dc8` | EIP-3009 works (diamond — see the selector note below) |

Both tokens' EIP-3009 `DOMAIN_SEPARATOR` was recomputed off-chain and matched the
on-chain value exactly, for domain version `"1"`.

> **Selector correction (2026-11-24).** The rows above are right about the
> *tokens*: both implement EIP-3009 with `uint256` `validAfter`/`validBefore`,
> selector **`0xcf092995`**. What was wrong was
> **Pago's own `IEIP3009` interface**, which declared those two arguments as
> `uint64` and therefore called **`0xd8fde8d5`** — a function neither token
> has. USDG, being a diamond, answers that mismatched call with
> `FacetNotFound`. `payWithAuthorization`'s own selector (`0x69c1372a`) and
> `createLink`'s (`0x6c5b7a11`) were never affected; only the token hop was.
> Fixed in `contracts-evm/src/Pago.sol` and proven against a mainnet fork by
> `test/PagoGaslessFork.t.sol` (**8/8**): a full end-to-end settle through Pago
> for **each** token — USD₮0 and USDG — plus a direct call proving the genuine
> USDG diamond does not carry the old selector. Signature-level evidence for
> USDG first: `0xcf092995` reaches the signature check (`InvalidSignature` on a
> garbage signature, and `InsufficientFunds` — signature accepted — for a
> correctly signed authorization from a payer holding no USDG). USDG
> `DOMAIN_SEPARATOR`
> `0x415f0706e345fcaf25d5be24c4fd7830d0054fc5742c51a0db9319c759bd3743`.
> The mainnet contract has **not** been redeployed with the fix yet.

---

## 3. Verified function selectors

### Rule processor (circuits contract)

Confirmed live by `cast` and by parsing the factory's dispatcher (two independent
methods that agreed).

| Selector | Signature |
|---|---|
| `0x934d06ea` | `eval(uint256,bytes) returns (bytes)` |
| `0x084d60f1` | `circuitInfo(uint256) returns (uint32,uint32,uint32,uint32)` |
| `0x3fc4be56` | `netlist(uint256) returns (bytes)` |
| `0x61b8ce8c` | `nextId() returns (uint256)` |
| `0xe8281a1a` | `step(uint256,bytes,bytes)` |
| `0x1fc0021d` | `beat(...)` |
| `0x7bd3ac1d` | `tapeout(bytes,uint32,uint32) returns (uint256)` (payable) |

`eval` **reverts with `has latch: use step`** when `nState > 0` — stateful
circuits must be driven through `step`/`beat`, one beat at a time.

### Factory

| Selector | Signature |
|---|---|
| `0xa94da8a7` | `cpuCount() returns (uint256)` |
| `0x4bc7cbbd` | `cpuAt(uint256) returns (address)` |
| `0x47f9b5fd` | `createCPU(string,string,string,uint256,uint256)` |
| `0x8da5cb5b` | `owner()` |
| `0x715018a6` | `renounceOwnership()` |
| `0x4f1ef286` | **the only payable function in the 29-function dispatcher** (admin upgrade path) |

`cpuCount()` currently returns **425**.

---

## 4. Fees (read live — published docs are stale)

| Fee | Value | Where |
|---|---|---|
| `deployFee()` | `1e7` wei | TapeFactory |
| `protocolFee()` | `1e6` wei | TapeFactory |
| `TAPEOUT_FEE` | `1.3e15` wei | circuits contract |
| opener `FEE()` | `8e16` wei | opener contract |
| market `feeBps()` | `100` (1%) | market contract |
| factory `isSealed()` | `false` | TapeFactory |
| cpu #340 `mintPrice` | `0` | transistors |
| cpu #340 supply cap / minted | `10000` / `10000` | transistors |

These are re-read in `test_feesAreReadFromChainNotHardcoded` so the suite fails
if any of them changes.

---

## 5. TAP-02 netlist format (from the spec, then proven against the chain)

Source: `https://raw.githubusercontent.com/TapeOutProtocol/TAPs/main/TAPs/TAP-02.md`

A netlist is a **concatenation of records with no header, no padding and no
terminator**. `nIn`/`nOut` are *not* in the bytes; they are stored alongside.
All multi-byte integers are **big-endian**; `u24` is a 3-byte signal index.

**Signals**

| Index | Meaning |
|---|---|
| `0` | constant `0` |
| `1` | constant `1` |
| `2 … 2+nIn−1` | the inputs (input `i` at index `2+i`) |
| `2+nIn` onward | outputs of the elements, in record order |

**Records**

| Opcode | Name | Payload | Length | Produces |
|---|---|---|---|---|
| `0x00` | NAND | `a:u24 b:u24` | 7 bytes | 1 signal: `NOT (a AND b)` |
| `0x01` | LATCH | `d:u24` | 4 bytes | 1 signal: the stored state bit |
| `0x02` | REF | `cpu:20, id:u64, nIns:u8, nOuts:u8, ins:u24 × nIns` | `31 + 3·nIns` | `nOuts` signals |

**Bit packing.** Inputs and outputs are packed **least-significant-bit first**.

**One beat (§4).** Set signal 0=0, 1=1, `2+i = inputs[i]`. Walk the elements in
record order: NAND computes `1 − (s[a] AND s[b])`; LATCH outputs its state bit
*from the previous beat*; REF runs one beat of the referenced circuit. After all
elements, each LATCH's bit in `newState` is `s[d]`. Finally the outputs are the
last `nOut` signals, `s[S−nOut] … s[S−1]`, in index order.

**Worked example — processor #340, circuit #1**

```
netlist = 0x0000000200000300000006000006000000040000050000080000080000000700000900000a00000a
nIn=4  nOut=1  nState=0  gates=6
```

Decoded (signals: `0`=const0, `1`=const1, `2..5`=inputs `a,b,c,d`):

```
NAND(2,3) -> signal 6      NAND(a,b)
NAND(6,6) -> signal 7      NOT(NAND(a,b)) = AND(a,b)
NAND(4,5) -> signal 8      NAND(c,d)
NAND(8,8) -> signal 9      NOT(NAND(c,d)) = AND(c,d)
NAND(7,9) -> signal 10     NAND(AND(a,b), AND(c,d))
NAND(10,10) -> signal 11   NOT(...) = AND(a,b,c,d)
```

Output = last `nOut` = signal 11 → **the circuit computes `AND` of all four
inputs**. Exhaustively confirmed: of the 16 input combinations, exactly one
(`1111`) yields `1`.

---

## 6. `createCPU` is currently unsatisfiable — evidence

This is the single most important negative finding of Phase 0. On the current
factory implementation, **no value of `msg.value` allows a processor to be
created.**

Disassembling implementation `0x336e9F0F4c3fEe7C8c803377e4DEA00293f4ae2a`
(9,376 bytes, 29 dispatched functions), `createCPU`'s body begins at byte
`0x1027`:

```
01027  JUMPDEST
01028  POP
01029  CALLVALUE
0102d  PUSH3   0x000540
0102e  JUMPI            ; if msg.value != 0 -> jump to 0x540
...
```

and `0x540` is the shared empty-revert target:

```
00540  JUMPDEST
00541  PUSH0
00542  DUP1
00543  REVERT           ; revert(0,0)
```

That `CALLVALUE / JUMPI` sequence is Solidity's **non-payable guard**. So:

* **Paying** the 1e7 fee → trips the guard → `revert(0,0)` (empty).
  Confirmed by trace: the call reverts after **179 gas, before any storage
  read**, which is only possible for an immediate comparison.
* **Paying nothing** → passes the guard → reaches the fee check → reverts with
  `0xfb8f41b2` plus `(factory, 1e7)` (100 bytes of revert data).

Hypotheses ruled out empirically (all failed identically, empty revert):

* 9 combinations of sale-window timestamp (±30d, ±365d, ±1h), supply
  (64, 1_000, 10_000, 100_000), `mintPrice` (0, 1), and `msg.value`
  (`deployFee`, `deployFee+protocolFee`, `0.01 ether`);
* 3 senders (alice, a fresh address, the test contract itself);
* CREATE2 salt collision from a repeated name (tried unique names too);
* owner-only gating (calling as `owner()` and as `alice` at 5 timestamps).

Also checked: of the 29 functions in the dispatcher, **exactly one is payable**
(`0x4f1ef286` → body at `0xdb7`), and its body writes the ERC-1967
implementation slot `0x360894a1…` and `STATICCALL`s a proxy-admin check — it is
the **admin upgrade path**, not a creation path. So there is no payable way to
create a processor.

**Consequence for Pago:** minting transistors and taping out a netlist of our own
cannot be reproduced end-to-end on the current implementation. Tier 1
(read-only use of existing public circuits) is unaffected. This is recorded as
**UNSUPPORTED**, pinned by `test_createCPUIsCurrentlyUnsatisfiable` and
`test_createProcessorAndTapeOutOnFork`, so the suite turns red the day TapeOut
ships a payable `createCPU`.

---

## 7. Containers — address prediction, proven end to end

`0x536adD8F30f03b69f6fbF29d425A816A0dC50106` (implementation
`0xAC4f791353Ee9f06E2c50Ae4C34680d28ea52a57`) is a live **container opener**.
Its selectors were resolved against the 4byte directory:

| Selector | Signature | Value read live |
|---|---|---|
| `0x0a0e5c9d` | `open(address,uint256)` payable | — |
| `0x0c1905e5` | `accountOf(address,uint256) returns (address)` | — |
| `0xf13906b8` | `isDeployed(address,uint256) returns (bool)` | — |
| `0xc57981b5` | `FEE()` | `8e16` wei |
| `0xba9a91a5` | `SALT()` | `0` |
| `0x61d027b3` | `treasury()` | `0xE2f77062…BB9d` |
| `0xa6d23e10` | `payments()` | `0x13b8AFa4…4858` |
| `0x7b103999` | `registry()` | `0x00000000…775758` |
| `0x5c60da1b` | `implementation()` | `0xAC4f7913…2a57` |

**`open`'s guards, decoded from the bytecode** (no source is published):

1. It STATICCALLs `factory.isCPU(addr)` — selector `0x5f5a364f`. If that
   returns false it reverts with the custom error **`0x5c69a867`**. The first
   argument is therefore a **processor address**, not an arbitrary owner.
2. It requires `msg.value >= FEE()` (`PUSH8 0x011c37937e080000` = 8e16).
3. It resolves the second argument as an **ERC721 token on that processor's
   circuits contract** and reverts with **`ERC721NonexistentToken(uint256)`**
   if it does not exist. Confirmed: `ownerOf(1)` resolves on processor #340's
   circuits contract, `ownerOf(7)`/`ownerOf(99)` revert.

**Why this matters for Pago.** `accountOf(processor, circuitId)` returns the
container address **before it exists**, deterministically, and `isDeployed` is
provably consistent with `eth_getCode` at that address. So a payment link can be
published (address and all) before any gas is spent, and a payer can check that
the link resolves to the address they expect. Proven by
`test_openWithFeeDeploysAtThePredictedAddress`, which opens a container on a
fork and asserts code appears at the exact address predicted beforehand.

> **A bug worth recording:** `vm.expectRevert` is consumed by *the next call*,
> so writing `c.open{value: c.FEE()}(...)` after `expectRevert` makes the
> expectation apply to the `FEE()` view call, not to `open`. The fee must be
> read into a local first.

---



The path Pago will use: the payer signs an authorization once; a **third party**
(the Pago relayer) submits it, so the payer never needs X Layer ETH for gas.

Proven on both USDT0 and USDG:

| Property | Result |
|---|---|
| `DOMAIN_SEPARATOR` matches an independently computed EIP-712 domain (version `"1"`) | ✅ |
| Third party may call `transferWithAuthorization` | ✅ gas ≈ **107,918** (USDT0), **105,896** (USDG) |
| Recipient may call `receiveWithAuthorization` on USDT0 | ✅ |
| Third party calling `receiveWithAuthorization` on USDT0 | ❌ reverts `TetherToken: to != msg.sender` |
| Replaying a used authorization | ❌ reverts, no second payment |
| Authorization not yet valid (`validAfter` in future) | ❌ reverts |
| Authorization expired (`validBefore` in past) | ❌ reverts |
| Signature from a key that is not the payer's | ❌ reverts, nothing moves |

**Design conclusion:** Pago uses `transferWithAuthorization`, submitted by a
relayer. `receiveWithAuthorization` is unusable for a relayer on USDT0.

> **Note on scope:** every row above was exercised **against the tokens
> directly**, using their real `uint256` window arguments (selector
> `0xcf092995`). It proves the *tokens* are ready. It does **not** prove Pago
> can reach them — Pago's `IEIP3009` declared those arguments as `uint64` and
> called `0xd8fde8d5`, which neither token implements. See the selector
> correction in §2 and
> [`README.md`](../README.md) "The gasless selector bug and its fix".

> **Note for reviewers:** an earlier version of these tests reported
> "invalid signature" for the third-party case. That was a bug in the test — it
> signed with `keccak256("key", alice)` without deriving alice's address from
> that key, so `ecrecover` returned a different address. Fixed by using
> `makeAddrAndKey` and asserting `ecrecover(...) == alice` before every call.

---

## 9. Demo circuits found on-chain (for the "Verify rule" demo)

X Layer's RPC rejects `eth_getLogs` ranges wider than **100 blocks**, so
enumerating all 425 processors through events is impossible. The scan is
therefore **bounded and documented**: indices `0..30` and `330..345`.

Result: **25 processors with at least one circuit** in that range.

| Processor | Address | Circuits | Notable |
|---|---|---|---|
| #30 | `0x2046aa63bFB03f393AD85a518011fdf8aF3DDB53` | 5 | #1/#2: 2-in/1-out/**3-NAND** gate; #3: 16-in/16-out, 1204 gates |
| #333 | `0xE2a6c6393b5A8B99cb481035eB8e244C66641cd7` | 19 | 1-in/1-out/**1-NAND** |
| #334 | `0x00586A4C37039aCbFC6aC135cAdd49367ABf390A` | 33 | LATCH-heavy (stateful) |
| #340 | `0x9de448A1CE9537d24199B3b5355239d73aA6F591` | 1 | 4-in/1-out/6-NAND = 4-input AND (fully decoded, §5) |

---

## 10. Reference evaluator

`contracts-evm/test/NetlistRef.t.sol` contains `Tap02`, a from-spec reference
implementation of the TAP-02 format, plus a `Tap02Harness` external wrapper
(`vm.expectRevert` cannot see a revert that happens inside an `internal` library
call at the test's own depth).

* **NAND is implemented** and proven **bit-for-bit against the chain** across all
  16 input combinations of processor #340's circuit #1.
* **LATCH and REF are parsed** (so record boundaries and opcode counts are
  validated) but **deliberately rejected at evaluation time**. REF would need to
  call another processor; LATCH feedback semantics are not implemented. A
  reference model must never guess — it fails loudly instead.

---

## 11. Phase 0 items — resolved

All three open items from the start of Phase 0 are now closed.

### ✅ 1. TapeSend liveness — **NOT live on X Layer. Do not depend on it.**

The TapeKit `send/README.md` states its status explicitly (dated 2026-09-18):

> - Live on BNB Smart Chain. Other chains (Base, X Layer) are planned but not
>   active.
> - The hub is upgradeable until sealed; it has not been sealed yet.
> - **Not independently audited.** All reviews so far were internal.

TapeSend's hub is deployed only on chain 56 (BNB Smart Chain). **Pago must not
depend on `tape://` links or on TapeSend messaging.** Container addresses
(§7) are the usable primitive on X Layer instead.

### ✅ 2. Container / name resolution — **verified working**

See §7. `accountOf(processor, circuitId)` predicts the container address before
deployment, `isDeployed` agrees with `eth_getCode`, and `open` deploys at exactly
the predicted address. All proven by `test/Container.t.sol` (7 tests).

### ✅ 3. Tier 1 satisfies the hackathon requirement — **confirmed in OKX's own words**

From `web3.okx.com/xlayer/build-x-series`:

> Your project must use TapeOut circuits, contracts or onchain data on X Layer
> and provide the relevant addresses. Interfaces and other components do not need
> to [use TapeOut]…

and from `web3.okx.com/xlayer/build-x-hackathon/xcup`:

> Ecosystem Integration: Effective use of TapeOut or ecosystem capabilities such
> as DeWEB, FabX, TapeCode, TapeKit, and TapeSend to create meaningful product
> value.

**Read-only use of existing mainnet circuits therefore qualifies**, provided Pago
publishes the addresses — which `docs/RESEARCH.md` §2 does. Note the judging
criteria explicitly name TapeSend among *optional* ecosystem capabilities, which
is consistent with it not being live on X Layer.

Also confirmed: the hackathon runs **Oct 16 – Dec 7 2026**, $100,000 USDT across
11 prizes (1 × $20k, 5 × $10k, 5 × $6k), submissions close **Dec 7 23:59 UTC**.

---

## 12. Reproducing this research

```powershell
$env:XLAYER_RPC = "https://rpc.xlayer.tech"
cd contracts-evm
forge test
```

`forge test` runs everything: the local suites (Pago, Split3, Tap02 reference)
need no network at all, and the fork suites (NetlistRef, ForkEval, Container,
Phase0Fork, DemoCircuits) pick up `XLAYER_RPC`.

Known environment quirks:

* The RPC intermittently fails DNS resolution — wrap commands in a retry loop.
* `eth_getLogs` rejects ranges > 100 blocks.
* `console.log` accepts at most 4 arguments in this forge-std version.
* Stack-too-deep recurs without `via-ir`; split functions rather than adding
  locals.
* X Layer **testnet** RPC: `https://testrpc.xlayer.tech`, chain id **1952**.
  (`rpc.testnet.xlayer.tech`, `testnet.rpc.xlayer.tech` and
  `xlayertestrpc.okx.com` all fail DNS; some X Layer docs print chain id `195`
  for testnet, which is wrong — `cast chain-id` answers `1952`.)

---

## 13. Corrections to Phase 0 — found while starting Phase 1

Everything in this section **supersedes** the corresponding Phase 0 findings.
It was written after re-probing the live chain; each item below replaced a
conclusion that had been drawn from a single failed call rather than from the
failure's actual reason.

### ❌ "createCPU is unsatisfiable" — wrong cause, and the blocker is lifted

Phase 0 recorded `createCPU` as **UNSUPPORTED**, on the grounds that the call
is non-payable and no value sent with it changes the outcome. The real reason
the call fails is a different one: **the fee is an ERC-20 `transferFrom`, not
`msg.value`.**

Simulated `createCPU` with no value reverts with:

```
ERC20InsufficientAllowance(0x1f09DAeFA827f02CBb40967cc91b259763760761, 0, 10000000 [1e7])
selector 0xfb8f41b2, arguments (factory, 10000000)
```

i.e. the factory tries to pull **1e7 units of the fee token** from the caller
and the caller has approved nothing. `createCPU` is non-payable *because* the
fee is a token — which is exactly why sending ETH changed nothing and why the
first probe looked like a dead end.

**Fix: `approve(factory, 1e7)` on the fee token, then call `createCPU` with no
value.** Phase 0's `test_createProcessorAndTapeOutOnFork` (which sends
`deployFee` in ETH) was testing the wrong thing and will be rewritten.

### The fee token is BEM

| | |
|---|---|
| Address | `0x60e62efa9405d6873c5deabd4e6cc91c25363952` |
| Name / symbol | `BEM` / `BEM` |
| Decimals | **8** |
| Total supply | 1,513,402,598,500 (1.513e12 = 15,134 BEM) |
| `owner()` | `0xB3D85b42A045c1A88D800CAD0F55d2566a4D3138` (= the factory's `owner()`) |
| `feeBps()` | 50 |
| Factory storage | slot 10 |

Confirmed against TapeOut's own announcement that fees moved to BEM: **create
processor 0.1 BEM** (1e7 at 8 decimals — exactly the 1e7 in the revert),
**mint transistor 0.01 BEM**, **50% of the protocol fee burned**, and
**processors created before the switch keep charging native coin** — which is
why processors #30/#333/#340 still take `msg.value` and why Phase 0's probes
on those behaved differently from a call to the factory.

BEM trades on Uniswap V3 X Layer (BEM/OKB pool), so it is buyable with OKB.

### Taping out requires holding one transistor PER GATE of the netlist

`tapeout(netlist, nIn, nOut)` on processor #340, called by an account that
holds nothing, reverts with:

```
ERC1155InsufficientBalance(0x000000000000000000000000000000000000dEaD, 0, 1, 0)
```

The processor's ERC-1155 id **0 is a "transistor"**, and minting on a
*new* processor costs **0.01 BEM each** (the caller sets the price in BEM
when creating the processor). `nextId()` per processor: #340 → 1, #333 → 20,
#30 → 6.

**Corrected 2026-11-19 by the Tier 2 fork test (§19): the gate wants one
transistor HELD PER GATE of the netlist, not one overall.** A fresh
processor's tapeout refusal is error `0x03dee4c5` with arguments
`(account, held, required, 0)` where `required` equals the netlist's gate
count — 104 for Split3 (Phase 0's 1-gate probe saw `required = 1`, which is
why this section used to say "one transistor").

So there are two routes to a Pago circuit on mainnet, both in BEM:

1. **Our own processor**: `approve` 0.1 BEM → `createCPU` → mint `gates`
   transistors in ONE call → `tapeout` (0.0013 native). The mint charges a
   flat **0.01 BEM protocol fee per call** plus `gates × mintPrice`, and
   `mintPrice` is the creator's argument at `createCPU` (§19 ran it at
   0.01/gate = 1.05 BEM; **execution decision 2026-11-20: `mintPrice = 0`**,
   the same as official CPU #340 — floor-free on X Layer, probe-proven in
   `test/MintPriceProbe.t.sol`) → one-time ≈ **0.11 BEM** + 0.0013 native
   + gas (0.1 createCPU + 0.01 flat mint fee).
2. **Someone else's processor**: hold `gates` of its transistors → `tapeout`
   (0.0013 native). Cheaper when its transistors are cheap, but we do not
   control the processor.

Both spend real funds, so **neither has been started** — see §14.

### The factory proxy uses a non-standard implementation slot

The factory at `0x1f09DAeFA827f02CBb40967cc91b259763760761` is a 131-byte
proxy. Its runtime code reads the implementation from

```
0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc5
```

not from the EIP-1967 slot
`0x360894a13ba4a77963041c062031413439307b4cf82ef756eefada3bc271191`, which
reads **0**. That is why Phase 0's "implementation slot" probes were
uninformative and why `implementation()` reverts (the selector does not
exist). The proxy falls back to a plain call when the slot is empty.

Proxy storage actually in use:

| Slot | Value | Meaning |
|---|---|---|
| 0 | `0x1059Ad62…60a51b` | transistor beacon |
| 1 | `0xf70d1ed4…bd0991c` | circuit beacon |
| 2 | `0x571d447f…5f6aF15` | `protocolWallet()` |
| 3 | `0x989680` (1e7) | `deployFee` |
| 4 | `0xf4240` (1e6) | `protocolFee` |
| 6 | `0x1aa` (426) | `cpuCount()` |
| 10 | `0x60e62efa…63952` | BEM fee token |
| 11 | `0x41cb2bfd…b9ce65` | 620-byte contract, `owner()` = 0 |

### `cpuCount` has moved: 425 → 426

A processor was created between Phase 0 and Phase 1. `cpuAt(425)` =
`0x1900801e311184063b9d9C119C9D98AA4950E12c` (592 bytes of code);
`cpuAt(426)` panics `0x32` (out of bounds), so `cpuCount()` is a count, not
the highest valid index. Anyone caching these values must re-read them.

### nand-arena's `createCPU` did succeed — on mainnet, in ETH

Transaction `0x087e378915fc84f4b463f49eb92951dc7ff7f0f39f12a2a10320582a5be88fe1`,
mined on **chain 196** at block 72,612,281 (7 Oct 2026 13:55 UTC), is a
contract-creation whose constructor calls `createCPU` (selector `0x47f9b5fd`,
with `tapeout` selector `0x7bd3ac1d` in the constructor arguments) with
`value = 6.6e15`. So `createCPU` *was* payable-fee at that time. Fees moved to
BEM afterwards (TapeOut's own announcement), which is why the same call now
fails on an ERC-20 allowance instead of on `msg.value`. The Phase 0 conclusion
was accurate for the chain *as probed* but its stated reason — "the current
implementation cannot be satisfied at all" — was not: it was a fee-token
change, not a missing feature.

### No TapeOut deployment on testnet 1952

Every address, fee and selector in §2 belongs to **mainnet (196)**. No
evidence of TapeOut on testnet was found: third-party docs and examples all
point at `https://xlayerrpc.okx.com`. Testnet is therefore usable for Pago's
own contracts (deploy, wire up, exercise) but **not** for the circuit itself —
taping out Split3 means mainnet, and §14 says what that requires.

---

## 14. What a mainnet tape-out of Split3 would cost — not started

**Nothing on this list has been done.** Mainnet is read-only until the
approval phrase is given in full: `deploy to mainnet tier 1`,
`deploy to mainnet tier 2` or `deploy to mainnet tier 3` (exact, case
sensitive, whole message — "go ahead" and "yes" do not count).

Taped out as a *new* processor (route 1 in §13):

| Item | Cost | Notes |
|---|---|---|
| Create processor | **0.1 BEM** | `approve` first, then `createCPU` with no value; the `mintPrice` argument is set to **0** (creator's choice, same as CPU #340) |
| Mint transistors | **0.01 BEM flat** | ONE `mint(0,104)` call: flat protocol fee per call + `gates × mintPrice` (= 0 here); `tapeout` requires one HELD PER GATE (§19). At 0.01/gate this line would instead be 104 × 0.01 + 0.01 = 1.05 BEM |
| Tape out Split3 | **0.0013 native coin** (`TAPEOUT_FEE` = 1.3e15 wei) | 15 inputs, 1 output, 104 NANDs, 728-byte netlist |
| **Total** | **≈ 0.11 BEM + 0.0013 native + gas** | Measured on a mainnet fork 2026-11-20: **$1.74** total (fund 0.0211 OKB ≈ $1.79) — transcript `docs/quote-dry-run-20261120-005520.log`; BEM is buyable with OKB on Uniswap V3 X Layer |

**Units, corrected 2026-11-18:** everything above is on **X Layer mainnet,
chain 196** — there is no second network involved. X Layer's native gas
token is **OKB** (18 decimals) on both mainnet and testnet, so "0.0013 ETH"
in earlier notes means 0.0013 **OKB** of native value; the `wei` figure is
right, the symbol was wrong. BEM is an ERC-20 *on this same chain*
(`0x60e62efa…3952`, symbol `BEM`, 8 decimals, 13,138 bytes of code — re-read
live 2026-11-18). Gas for every transaction is also OKB. So the whole
tape-out costs OKB: buy BEM with OKB, plus 0.0013 OKB, plus gas.

Alternatively, tapping out onto an existing third-party processor costs 0.0013
ETH plus `gates` of its transistors (104 for Split3), but hands control of the
processor to someone else.

Everything else — Pago's contracts, the Split3 netlist, its exhaustive
verification — is already written and tested locally, and Pago itself can be
deployed to **testnet 1952** without spending anything anyone would notice.
The circuit is the only part that needs mainnet money.

---

## 15. Phase 2 — live on X Layer testnet (chain 1952), 2026-11-18

> **Superseded by §17.** The contract interface changed when the master
> prompt's rules 1–10 were implemented, so the Pago address below is the
> *previous* deployment (it remains on chain and on the explorer as the
> record of this run; §17 has the current contracts). The run itself — both
> payer paths, reconciliation to the unit — stands as written.

Everything in this section was read back from the chain or printed by
`contracts-evm/script/testnet-exercise.ps1`. Nothing is inferred.

### Deployed contracts

| | Address | Proof |
|---|---|---|
| Pago | `0x3b5B96391039bf36A04CD447982a83510B23A6C5` | 8,325 bytes of code |
| pUSD — **MOCK**, not a stablecoin | `0x229A19B9D237629FC0c94812d21a4cf2b22B3615` | 3,864 bytes of code, 6 decimals, publicly mintable by anyone |
| chain id | 1952 | `cast chain-id`, asserted by the script before it spends anything |

Both open on the testnet explorer (checked 2026-11-18):

- Pago — `https://www.oklink.com/xlayer-test/address/0x3b5B96391039bf36A04CD447982a83510B23A6C5`
- pUSD — `https://www.oklink.com/xlayer-test/address/0x229A19B9D237629FC0c94812d21a4cf2b22B3615`

pUSD is `MockToken` (`test/mocks/MockToken.sol`): a real ERC-20 with EIP-3009
so the gasless path can be exercised, but **nothing backs it** and its `mint`
is public. It is test scaffolding, not a stablecoin, and no surface should
present it as one.

Deploy transactions (`broadcast/Deploy.s.sol/1952/run-latest.json`):

- pUSD create `0x7b24933873880f275d4c7dccf1e4ccffa5d0a1f67d5584403ec5cfd294ae0c28`
- initial mint `0xd09f12ad4b94a3814085e83d02b0f5b9340105b19e906f148a14bcd564f1d38b`
- Pago create `0x0dd01201e2e353ec784d4cef65ea830fc9f8c540754538fab9af15ba38e03b77`

Read live after deploy: `feeBps()` = **50** (0.5%), fee account = the
deployer, chain id 1952. The deployer is also the payer and the fee account;
the payee is a separate account because the contract requires the payer to
differ from the link creator.

### The passing run

`testnet-exercise.ps1`, run to completion — final line:

```
PASS - both payer paths settled live on X Layer testnet, every unit accounted for.
```

Link ids `pago-261118-002651-a` / `-b`. All nine transactions:

| Step | Tx |
|---|---|
| mint 10 pUSD to the payer | `0x1f5d7a2966d6f19ce846054d448c7934eb5983912aef43dda23a052cfa43741f` |
| **A** createLink | `0xdaf2242e0327695c82699288366d1182ed2b2919cf59e6e1de4653545e154707` |
| **A** approve | `0xb67942fea63379e6eaf42c7744cbe5ca8ca62edff1f1702553044ec39f7f1534` |
| **A** pay (payer sends it) | `0xa82bf0d92e7bcd36beb309c0a993eaf28df04525166e2487800e2712f6c4dcd7` |
| **B** createLink | `0xf18b84fdd15fce32ad6d6fb95cf2e657411ca9cd09d9d5aea7447491d983bb59` |
| **B** EIP-3009 digest (off-chain, not a tx) | `0x04a1f82743897616ae44e1400051b66d6bffb54b4d8c50b71354ed4936b16244` |
| **B** payWithAuthorization (relayed by the payee, who pays the gas) | `0x9b8b2ef14973797d993e1a2528b3e6bbd2b786481938dd55e72e264eec0cac87` |
| claim A | `0xf899a9df56cb2eff4f181ce3bf8e3c9093a527cb0b37080e508db73fb984ac9b` |
| claim B | `0x31dbb499c8decca565f94324234a4033f5bd0b8067112e0ef929a9c93ad33da3` |

The gasless leg is the NEP-366 equivalent: the payer signs the digest off-chain
with its keystore (`cast wallet sign <digest> --no-hash --account
pago-deployer`), and a *third party* — the payee — submits it and pays the
gas. The payer never sends a transaction for that leg.

### Verification (changes measured from a snapshot taken before either link existed)

```
links created by payee      6 (informational)
payee change                1990000 (want 1990000 = 2 payouts)
deployer change             -1990000 (want -1990000 = -2 payments + 2 fees)
held by Pago change         0 (want 0 - nothing left inside)
deltas sum to               0 (want 0 - every unit accounted for)
```

1,000,000 = 2 × 500,000 pUSD principal; 995,000 = 500,000 less the 0.5% fee
(2,500), paid to the fee account. `held by Pago` moving 0 proves the fee is
taken at `claim()` and nothing is left behind. (A separate 1,000,000 pUSD sits
in the contract from an earlier abandoned run — an unclaimed link — and is
deliberately *outside* these deltas, which measure only this run.)

### Bugs the run exposed — all fixed, all re-verified

Each of these only appeared because this was the first time the script
executed end to end against a live chain:

1. `cast balance` reports **wei**; the code compared it as OKB. Thresholds are
   now computed in wei (1 OKB = 10^18, measured on-chain).
2. This Foundry build rejects `--value 0.0003` — only `0.0003ether` or raw wei
   parse. Nothing was broadcast by the failed attempt.
3. `$ErrorActionPreference = "Stop"` turned native stderr into a terminating
   error that escaped `Run-Retry`, so retries never fired. Now caught inside
   the loop; proven against transient, permanent and clean scenarios.
4. Bare `cast call` has no endpoint and falls back to `http://localhost:8545`.
   `foundry.toml`'s `[rpc_endpoints] xlayer` alias is only reachable as
   `--rpc-url xlayer`, so `XLAYER_RPC` does not help. The script now sets
   `ETH_RPC_URL` once. (It never pointed at mainnet — it pointed at nothing.)
5. `cast` annotates large integers (`1010000000 [1.01e9]`), which breaks a
   later `[bigint]` cast. Stripped centrally in `Call()`.
6. `authorizationNonce()` returns `uint256` but `digestOf` /
   `payWithAuthorization` declare `bytes32` — `Pago.t.sol:866` does the same
   `bytes32(uint256)` cast, `Pago.sol:289` converts back. Decimal made cast
   parse it as hex ("odd number of digits"); and .NET's `BigInteger.ToString("x")`
   emits a stray leading nibble (65 digits), so the conversion goes through
   `cast to-hex` and is padded to 64.
7. `linkCountByCreator(address)` was called with no argument.

### Known limitation

Gasless *link creation* — the NEAR side's NEP-366 relayed `add_key` — has no
EVM equivalent here: creating a link is an ordinary transaction paid by the
creator. What is relayed is the *payment*, which is the part that matters to a
payer.

### Not done

Taping out Split3 still needs mainnet and ≈0.11 BEM + 0.0013 native OKB (§14), and
mainnet remains read-only until the exact approval phrase is given.

---

## 16. Phase 3 — the X Layer frontend, 2026-11-19

`frontend/xlayer.html` + `frontend/xlayer.js`: the port's own page, sitting
beside the NEAR app. `index.html`, `app.js` and `styles.css` were not
modified, so nothing that already worked can regress from this phase. Static
and buildless: no bundler, no npm dependency, no vendored ethers, no server of
our own. Everything quoted below was **run** on 2026-11-19, not reasoned.

### The codec — `frontend/abi.js`

The page cannot import ethers (buildless), and Pago needs a closed set of a
dozen functions, so the calldata codec is written by hand:

- **Selectors are constants**, produced with `cast sig` and cross-checked
  against the deployed Pago runtime bytecode on chain 1952 — each appears as
  `63<selector>` in the dispatcher. Nothing computes a hash in the browser, so
  a wrong selector would be caught by the codec tests rather than by a failed
  transaction.
- **Types cover what the contract uses**: static words, `string`/`bytes`,
  plain tuples, dynamic arrays, and a **named struct** form
  `{ struct: [[name, type], …] }` so `getLink` / `getLinksByCreator` decode
  to objects with field names. The wire format is identical to a plain tuple —
  only the in-memory shape differs — and encoding accepts an object *or* an
  array, so decode→encode round-trips exactly.
- **`node frontend/test/abi.test.mjs` → 62 passed, 0 failed.** The fixtures
  are live-chain vectors: `createLink` calldata compared byte for byte against
  `cast abi-encode`, return data captured from the deployed contract.

Four real bugs were found by writing those tests rather than by reading the
code: structs decoded positionally instead of by name; one offset expectation
was wrong (a dynamic member's offset is relative to its tuple, not to its own
head); `TextEncoder` silently coerces non-strings, so a number in a `string`
slot would have encoded into a wrong-but-plausible invoice id — now refused;
and one test destructured `getLink`'s `[found, link]` as if the first element
were the link. A UTF-8 BOM in the fixture JSON was stripped too.

### What the page does

- **Reads need no wallet.** Every fact on screen — fee, allowlist, ledger,
  invoice state, balance, allowance, chain clock — comes from unsigned
  `eth_call` with three-round endpoint failover (the testnet RPC resolves
  intermittently, §15). That is what makes the read-only Playwright project
  possible.
- **Writes go through an injected EIP-1193 wallet** (`window.ethereum`):
  `eth_sendTransaction` for `createLink`, `approve`, `pay`, `claim`,
  `cancelLink` and the MOCK token's `mint`, each followed by 90 s of receipt
  polling. No key, no relayer, no backend; the page never sees a private key.
- **The contract's rules are mirrored, not re-invented**: the note must be
  1–280 UTF-8 bytes (stated in the label, enforced before signing); expiry is
  written in *chain* time from `nowMs()` so a skewed browser clock cannot mint
  an already-expired link; the id is checked with `linkExists` before anything
  is signed; the payee is refused their own link with an explanation instead
  of a transaction that would revert; and when the balance is short the page
  offers **no approve/pay button at all** — only the MOCK faucet — because
  paying against a zero allowance would just manufacture a failed
  transaction.
- **pUSD is labelled `MOCK` on every surface** that names it: token pill,
  badge, note, hero line, footer, pay card. The faucet button exists only
  while that label says MOCK.
- **Routing is hash-based** (`#pay/<id>`, `#ready/<id>`), so a share link is
  just the URL; the QR code and Copy button are built from the id alone and
  therefore survive a dead RPC.

### Scope decisions, recorded rather than implied

- **Leg A only in the UI**: the payer signs `approve` then `pay` themselves —
  two transactions, two signatures. No relayer runs on X Layer, so nobody can
  submit a gasless EIP-3009 authorization on the payer's behalf. Leg B is
  proven by the Phase 2 script (§15), not by this page.
- **Gasless link creation is not ported** (same limitation as §15).
- **Mainnet is not in the page**: `config.js`'s `pago.mainnet` is `null` and
  the page reads only `pago.testnet` — there is nothing to point at until a
  mainnet deploy is explicitly approved.

### Test evidence — all run 2026-11-19

| Suite | Command | Result |
|---|---|---|
| ABI codec vs live-chain vectors | `node frontend/test/abi.test.mjs` | **62 passed, 0 failed** |
| X Layer page, mocked chain, no wallet | `npx playwright test --project=smoke specs/xlayer.spec.mjs` | **8 passed** |
| whole smoke suite (21 NEAR + 8 X Layer) | `npx playwright test --project=smoke` | **29 passed** — zero regressions |
| X Layer page, live chain 1952, read-only | `npx playwright test --project=testnet specs/testnet/xlayer.testnet.spec.mjs` | **4 passed** |

The 8 mocked tests assert: boot from static files with the health dot driven
by real `eth_call`s; tabs driving the hash; the create form labelling the
token MOCK and **failing loudly at the wallet boundary** — the fixture logs
every JSON-RPC method and the spec asserts none of them is a signing method;
the ledger reading fixtures and filtering by state with the 0.995 payout the
contract's split produces; the OPEN card's fee split (2.4875 / 0.0125); the
CLAIMED receipt; the PAID claim button; and an unknown id saying so instead of
inventing an invoice. Zero console errors and zero off-allowlist requests in
every one. (Two bugs the suite caught while being written: the mock route
needed a predicate because the endpoint URL has no path, and `encodeTuple`
returns bare hex where the decoder demands `0x`.)

The 4 live tests hit chain 1952 with no mocks: the health check, the payee's
real ledger (a `Claimed` pill must appear or the test fails), the claimed
invoice `pago-261118-002651-a` rendering "live test: ordinary payer path"
with its 0.995 receipt, and an unknown id.

### What the UI does **not** prove

- **No signing is automated.** Wallet approvals stay human, in a dedicated
  testnet wallet — `e2e/TESTNET.md` Journey D is the runbook. The automated
  suites assert the *absence* of signing requests, never their success.
- **The create → pay → claim journey through the browser has not been run end
  to end yet.** The equivalent journey has been run end to end by script: nine
  transactions, deltas summing to zero (§15).
- The gasless payment leg and gasless creation are not in the page (above).

### Master-prompt items still open

- **Q2 — what each approval phrase authorises.** As recorded from the prompt:
  **`deploy to mainnet tier 1` covers the payment contract only**, and **the
  Split3 tape-out is part of tier 2**. Tier 3's scope is written nowhere in
  this repository and is deliberately not guessed.
  `send mainnet demo payment` authorises a single demo payment on mainnet.
  **All of them remain unsent** — no phrase has been given, and mainnet (chain
  196) stays read-only.
- **Q3 — the `createCPU` blocker.** Solved in §13: the fee is an ERC-20
  `transferFrom` in BEM, so the sequence is `approve(factory, 1e7)` then
  `createCPU` with **no** value. **Third-party processor control:** tapping
  out onto someone else's existing processor is cheaper (0.0013 native plus
  `gates` of its transistors) but **the processor owner controls it** — mint
  pricing, admission and that processor's rules are theirs; only route 1 in
  §13 (our own processor, ≈0.11 BEM for Split3) keeps control with the
  deployer. The README says the same. **Per-link cap:** not implemented.
- **The contract-rule audit was made against the code alone**, because the
  master prompt's rule list was not in this repository. It has since been
  recorded verbatim (`docs/MASTER_PROMPT.md`) and every gap it found is closed
  in §17: token allowlist ✅, Split3 rule ✅, default-split fallback ✅, terms
  hash ✅, per-link cap ✅.

---

## 17. Contract rules 1–10: closing the gaps, and the redeployed testnet, 2026-11-18

The master prompt's rule list (recorded verbatim in
`docs/MASTER_PROMPT.md`) was audited against the code at the end of §16 and
found five gaps: the circuit existed but `Pago` never called it, there was no
default-split fallback, no terms hash, no per-link cap, and no stored
`evaluatorPinned` flag. All five are closed here, along with the rest of
rules 1–10.

**Why this came before the demo video.** Adding the rule interface changes
`createLink` / `pay` / `payWithAuthorization` / `getLink` shapes, so the
contract's address changes, which invalidates §15's addresses, §16's ABI
codec and the nine recorded §15 transactions *as a description of the live
system*. Recording a video first would have shown a product about to be
replaced the same week.

**What this section supersedes.** §15's Pago/token addresses and its nine
transaction hashes (the superseded interface remains on chain as the
historical record of that run), and §16's closing audit bullet. §16's codec
still speaks the old ABI — updating the frontend is the next phase.

### The audit — every rule, as implemented

| # | Rule (abridged from `MASTER_PROMPT.md`) | Implemented as | Proven by |
|---|---|---|---|
| 1 | `claim(linkId)` takes no result arguments, anyone can call it, pays only the recipients and the fee account, never the caller | `claim(string)` — no result params; `_payLeg` transfers only to the selected table's `recipients[i]` and `feeAccount`; the caller is never a recipient by construction | `Pago.t.sol` claim suite (caller's balance stays 0); `PagoRule.t.sol` leg tests |
| 2 | Contract derives the rule inputs from its own state; strict gas-limited `staticcall`, exact return length, strict decoding; output only selects among preset tables fixed at creation; a rule can never invent a split | `_ruleApplies` packs the rule table's shares **from storage**; `_eval` staticcalls with `EVAL_GAS_LIMIT` = 500k; `_decodeEvalReturn` demands ret.length == 96, offset == 32, length == 1, payload ∈ {0,1}, zero padding; the bit selects `l.ruleSplit` vs `l.defaultSplit` — both written once by `createLink`, no setter | `PagoRule.t.sol`: valid table → rule pays; revert / wrong length / dirty padding / gas hog / lying / vanished processor → default pays |
| 3 | Default split fixed at creation with no setter; processor revert, malformed data, out of gas or failed check → default; a link must never freeze | `createLink` writes both tables once; no setter exists; any `_eval` anomaly returns false; plus a solvency check: a rule table whose shares don't sum to `SPLIT_STEPS` is refused **even if the evaluator said yes**; `claim` reverts only on "link not found" / "link is not paid" | every fallback test above, including `vm.etch(processor, "")` after creation ("the processor vanishes") |
| 4 | `terms(linkId)` and `termsHash`; `pay` and `payWithAuthorization` take `expectedTermsHash` and revert on mismatch; does **not** prove what the payer saw | `_termsBytes` = `abi.encode` of every immutable field (id, amount, token, description, expiry, **both split tables**, fee bps, fee account, `netlistHash`, `processor`, `circuitId`); guard order: settleable → nonce → terms; the contract's own doc says this binds the payer to the terms *recorded onchain*, nothing more | `PagoRule.t.sol` terms tests (mismatch moves nothing); live `termsHash` read by the exercise script before each payment (below) |
| 5 | `createLink` reverts if the circuit's netlist identity can't be read; store its hash | `_readNetlist()` staticcalls `netlist(circuitId)` under a 200k gas cap; empty/revert/malformed → `"circuit netlist is unreadable"`; `l.netlistHash = keccak256(nl)` stored per link | `PagoRule.t.sol`: `FaultyProcessor.NoNetlist` reverts creation; honest links store `keccak256(Split3.netlist())` |
| 6 | `evaluatorPinned` flag; the known-answer check is named `changeDetector`, never "pin"; while unpinned, cap every link at `MAX_LINK_AMOUNT_UNPINNED[token]` in base units | **Full-rule clause, paraphrased: the flag may become true only through a real onchain implementation check, never via the change detector.** Implemented as a **two-leg constructor check** (§18): leg 1 takes `expectedProcessorCodehash` and requires `processor_ != 0 && processor_.code.length > 0 && processor_.codehash == expectedProcessorCodehash_` (the processor is a beacon-proxy *shell*); leg 2 staticcalls the configured `circuitBeacon_`'s public `implementation()` getter with strict 32-byte decoding and requires the returned address to have code hashing to `expectedImplementationCodehash_` — a reverting beacon, an empty account or dirty return data fails the leg. Both legs must pass; `evaluatorPinned = shellMatches && implMatches`. Zero shell reference, zero beacon and zero implementation reference are each refused. `changeDetector()` stays a public view over six known-answer vectors (valid sums → 1, invalid → 0) and never writes the flag. `createLink` enforces the cap while unpinned; the constructor refuses a zero cap. Deploy references default to the recorded values (shell `0x57aa306f…17d5`, beacon `0xf70d1ed4…bd0991c`, implementation `0x7a15c353…1b30`), overridable via `PAGO_PROCESSOR_CODEHASH` / `PAGO_BEACON` / `PAGO_IMPLEMENTATION_CODEHASH` (never a live read — that would be tautological) | `Pago.t.sol`: stand-in + its mock beacon pins (both legs); zero shell reference, zero beacon, zero implementation reference each refused; shell-matched-but-wrong-beacon answer, a reverting beacon and a beacon reporting the zero address all leave the flag false. `PagoRule.t.sol`: fault mocks' different code never pins whatever their behaviour; a lying evaluator whose code matches pins while `changeDetector()` reports false; the honest stand-in with a wrong reference stays unpinned while `changeDetector()` reports true — decoupling proven in both directions; cap enforced to the unit; pinned deployment uncapped. `ForkPin.t.sol` (mainnet fork): the genuine chain pins, `vm.etch`-swapping the beacon to report a different implementation flips the flag false, a corrupted shell never pins. Live testnet: `evaluatorPinned: false`, `changeDetector: true` (below) — the honest capped state until tier 2 |
| 7 | Token allowlist fixed at deploy; store expected decimals as written by us; never read `decimals()` at runtime for safety limits; deploy script aborts on mismatch | `TokenConfig{token, decimals_, unpinnedCap}` is constructor-only; `expectedDecimals[token]` stored; `Pago` never calls `decimals()` anywhere; `Deploy.s.sol` reads the onchain value **once** and `require`s it equals `PAGO_EXPECTED_DECIMALS` | constructor tests; deploy log `token decimals (chain == expected): 6` (below) |
| 8 | No `markPaid`; underpay reverts, overpay credited, double pay reverts, creator can't self-pay, fee leg skipped if it rounds to zero | `_requireSettleable` (allowlist → exists → `Open` → not creator → `amount >= l.amount` → not expired) before any transfer; `paidAmount` stores what arrived; `if (fee > 0)` skips a zero fee | `Pago.t.sol` pay suite + `test_tinyInvoiceChargesNoFeeInsteadOfTransferringZero` |
| 9 | One failing recipient must not block the others | each seat (and the fee) is an **independent** `_payLeg`: a failed transfer becomes `owed[recipient][token]` + `LegOwed`, the other legs still run; `withdrawOwed(token)` pays the caller their own storage balance only; claim never reverts on transfer failure | `PagoRule.t.sol` with `MockToken.blockedRecipient`: blocked seat owed, others paid in the same tx, then withdrawn to the unit |
| 10 | Fuzz and invariant tests: payouts + fee == credited; balance ≥ owed; status never goes backward | `test/Pago.invariant.t.sol`: a handler interleaves create/pay/claim/cancel/withdraw, records violations as flags (a reverting handler would roll them back); 4 invariants + a 256-run conservation fuzz | PASS: 256 runs, **128,000 handler calls, 0 reverts**, all four invariants; fuzz 256 runs (below) |

**One honest note on rule 2's inputs.** The rule names due date vs
`block.timestamp`, the credited amount, and creation-fixed fields as inputs.
Split3's input space is exactly three 5-bit shares (15 bits) — there are no
spare input bits for a deadline or an amount. The deadline is therefore
enforced where it belongs (`pay` refuses an expired link against
`block.timestamp`), the credited amount is what `claim` derives the payout
base from, and the circuit receives the creation-fixed share fields. The
processor still only ever *selects* between two tables this contract stored;
it is never asked to compute money.

### The processor stand-in on testnet — not hardware

TapeOut exists **only on X Layer mainnet**: `eth_getCode` on the TapeFactory
proxy `0x1f09DAeFA827f02CBb40967cc91b259763760761` returns `0x` on chain 1952
and a 262-byte proxy on chain 196 (probe run for this phase; §2 has the
mainnet reading). Without a processor, rules 2, 5 and 6 could not be
exercised live on the chain the hackathon rules require development against.

`test/mocks/ProcessorStandIn.sol` fills that gap and is labelled everywhere
as what it is:

- implements the exact `IRuleProcessor` surface Pago calls (`eval`,
  `circuitInfo`, `netlist`, `nextId`);
- `netlist(1)` returns the **byte-for-byte Split3 netlist** that would be
  taped out on mainnet, so the identity Pago stores (rule 5) is real;
- `eval(1, inputs)` executes those bytes gate by gate through the same
  `Tap02` evaluator proven bit-for-bit against a live mainnet processor (§4)
  — the verdict comes from the netlist, not from a hard-coded answer;
- the deploy log says `DEPLOYED PROCESSOR STAND-IN (EVM, not hardware)`, the
  exercise script prints `EVM stand-in for the TapeOut processor - not
  hardware`, and every doc that shows this contract says "stand-in".

On mainnet tier 2, **only the constructor argument changes**: `PAGO_PROCESSOR`
points at the real taped-out processor; nothing in `Pago` changes.

### Test evidence — all run 2026-11-18

| Suite | Command | Result |
|---|---|---|
| Local: `PagoTest`, `PagoRuleTest`, `PagoInvariantTest`, `PagoFuzzTest`, `Split3Test`, `Tap02Test`, `MockToken`… | `forge test --no-match-contract "Fork\|Container\|DemoCircuits\|NetlistRef"` | **105 passed, 0 failed** |
| Mainnet-fork reads: `Container`, `DemoCircuits`, `NetlistRef` | `XLAYER_RPC` set, `--match-contract "Container\|DemoCircuits\|NetlistRef"` | **15 passed, 0 failed** |
| `Phase0Fork` (Phase 0 claims vs live chain 196) | `XLAYER_RPC` set, `--match-contract Phase0Fork` | **11 passed, 0 failed** |
| **Total** | | **131 passed, 0 failed, 0 skipped** |

Every processor fault the rules name has a matching mock
(`test/mocks/FaultyProcessor.sol`), and each one is proven to land on the
default split instead of freezing the link:

| Mode | What the evaluator does | Result at `claim` |
|---|---|---|
| `Revert` | `eval` reverts | default pays |
| `Short` | returns a 2-byte payload (decoder demands exactly 1) | default pays |
| `DirtyPad` | right length, payload 0x01, non-zero padding byte | default pays |
| `GasHog` | burns past the 500k gas cap | default pays |
| `Lie` | always answers 1 — even for an unsafe 23-step table | default pays (the contract's own solvency check refuses the lie) |
| `NoNetlist` | `netlist()` reverts | `createLink` reverts ("circuit netlist is unreadable") |
| (vanish) | `vm.etch` empties the processor *after* creation | default pays |

Two bugs the suite caught while being written, both recorded because they
are exactly what tests are for: the stand-in originally returned
`abi.encode(bytes1(...))` — a 32-byte payload that Pago's strict decoder
correctly rejected, which made `changeDetector` answer false — the first
symptom anyone noticed; and inline `pago.termsHash(...)` inside a `pay(...)`
argument list is an *external call evaluated before `pay`*, consuming the
test's `vm.prank`/`vm.expectRevert` — the suite now caches each link's hash
at creation.

### Live testnet redeploy (rules 1–10), superseded the same day (chain 1952), 2026-11-18

**Superseded:** the rule-6 fix gave the constructor an
`expectedProcessorCodehash` argument, which changed the bytecode and moved
the address again. The current deployment is recorded in the next section;
this one stands as the record of the rules 1–10 redeploy (commit `269428d`).

Read back from chain after deploy:

| What | Address | Deploy tx |
|---|---|---|
| **Pago** (rules 1–10, 14,529 bytes) | `0x2fC4180db7318F4364F6FC559A25359c9F537D3e` | `0x24f4c64df6b564fae4a927109e87976b6c49de2404380e2188745e8ff4e65673` |
| pUSD **(MOCK**, 6 decimals, freely mintable, no backing) | `0x3693a61572C1c5f120Da39A6F4e616ce46D32de4` | `0x995d3525fa5b2d5e4b28a7ad87cb4981a07ce9ecadfad950aa48f5bcfa2cbe43` (mint to deployer: `0x591d2e946de59a57af8c74ca4c39140b1fab764eb76af70ded97103cf379fcc9`) |
| **ProcessorStandIn** (EVM, **not hardware**) | `0x67a9B6F2AE5488B8ee993F019FE867E97585DEEF` | `0x7f3f3dffc28552920358280a782f8fe2d8a773fcc3da466fc6d2224d84fe99ba` |

Constructor state read back live: `evaluatorPinned: true` (the stand-in
passes `changeDetector` at deploy), unpinned cap `10,000,000,000` base units
(10,000 pUSD), fee 50 bps, circuit id 1, fee account = deployer.

`script/testnet-exercise.ps1` then settled two real invoices, one per payer
path, with the two split tables doing different work on purpose:

- **leg A** — ordinary `pay`, rule table `10/6/4` (= 20 steps, valid): the
  circuit **accepts** it and `claim` pays the rule table (payee 497,500,
  deployer-seat 497,500) instead of the default. The deployer receiving money
  back is the visible proof the rule was selected.
- **leg B** — gasless `payWithAuthorization` relayed by the payee, rule table
  `10/8/5` (= 23 steps, invalid): the circuit **rejects** it and `claim`
  falls back to the default table (payee 995,000 in full).

| Step | Tx |
|---|---|
| mint 10 pUSD to the payer | `0xe384cf41ebbeb701142256858d5c2d9104d1c39b475e2c4250a6653e0fc07ffb` |
| leg A `createLink` (two split tuples) | `0x815f6bdfc1979798dd30e78a166b5b54dfc281f64638652c489205cb9aa3de4d` |
| leg A `approve` | `0xc99d4cd130dfa707901be6409d4ebe64415eef7e2ad329c03ebf4f53cc3d2288` |
| leg A `pay` (terms hash `0x80f60f57…c5548`) | `0xa656cebb69eae73a8e1e0cd8e88331f627124594465f1372eafb6bfc23a9db20` |
| leg B `createLink` (invalid rule table) | `0xb00743595add3e557831f65462ed6bde2bbfea000a50178c1a7d8b33393497a5` |
| leg B `payWithAuthorization` (terms hash `0x84d97d01…91b49`) | `0x6ac233df041b997ce16615190f5c8d2fcc31107719c42a57458454db01eb5a3a` |
| `claim` leg A (rule table) | `0xe672fc89f39688c1769a057ace87072f906bd27a97a3432102616f74f11ec9fc` |
| `claim` leg B (fallback) | `0xec457bf075ce1545154d5729ee44909a25982cb3c4723ed1bdc374cc47c5f3fb` |

Reconciliation, measured from a snapshot taken before either link existed:

```
payee change        1,492,500   (rule 497,500 + default 995,000)
deployer change    -1,492,500   (two 1,000,000 payments + rule seat 497,500 + 2 x 5,000 fees)
held by Pago change        0    (nothing left inside)
deltas sum to              0    (every unit accounted for)
PASS - leg A settled through the rule table, leg B through the fallback default,
both payer paths live on X Layer testnet, every unit accounted for.
```

### Live testnet redeploy after the rule-6 fix (chain 1952), 2026-11-18

> **Superseded on 2026-11-19** by the two-leg constructor redeploy below —
> same script, same evidence structure, new addresses. Kept for the record.

The constructor now takes `expectedProcessorCodehash`, so the bytecode (and
with it the address) changed again. Read back from chain after deploy:

| What | Address | Deploy tx |
|---|---|---|
| **Pago** (rules 1–10 + the rule-6 code check, 14,580 bytes) | `0xd4337d6f6dba4DCea65Cfc53B457dBb21e7ba3aC` | `0x08a6cdd6ff5c5aeda7f15222d10f9f9f756c6afdc3b2808962b7379178c93fbb` |
| pUSD **(MOCK**, 6 decimals, freely mintable, no backing, 4,118 bytes) | `0x15bc997887385520E3C906533F0d20CB8D6DB7D0` | `0x57c61f06546dea6b412af68057b75d1b704932dfb170689a3dbc7d247b1ae32f` (mint to deployer: `0x84a2e5b8e5551425f73f3f1eb699de9b6b823f0c838ee1306b08cea43b750848`) |
| **ProcessorStandIn** (EVM, **not hardware**, 2,780 bytes) | `0x86A30B752d1cf860EC224885793Eb7d33011B1BC` | `0x05fd4883ba9b4ef99cd3ae3ff55f6d8613ba9e0409d6bb73e7bd20ad2e677b06` |

Constructor state read back live: `evaluatorPinned: false` — the reference
is the recorded TapeOut codehash `0x57aa306f…17d5` (probed identical across
processors #340, #30 and #333) and the stand-in's code correctly does not
match, so every link is capped at `10,000,000,000` base units (10,000 pUSD);
`changeDetector: true` (behaviour evidence only — rule 6 never lets it set
the flag), fee 50 bps, circuit id 1, fee account = deployer. On mainnet
tier 2 the recorded processor satisfies the same reference and the flag
flips true.

`script/testnet-exercise.ps1` then settled two real invoices, one per payer
path, with the two split tables doing different work on purpose:

- **leg A** — ordinary `pay`, rule table `10/6/4` (= 20 steps, valid): the
  circuit **accepts** it and `claim` pays the rule table (payee 497,500,
  deployer-seat 497,500) instead of the default. The deployer receiving money
  back is the visible proof the rule was selected.
- **leg B** — gasless `payWithAuthorization` relayed by the payee, rule table
  `10/8/5` (= 23 steps, invalid): the circuit **rejects** it and `claim`
  falls back to the default table (payee 995,000 in full).

| Step | Tx |
|---|---|
| mint 10 pUSD to the payer | `0xe9d7a59441dd0abfa1a4d557987c9277540fa313e5310475668cfe26c4d93475` |
| leg A `createLink` (two split tuples) | `0x87b900a76d4ef715fef3f326073bac2d233def395d91035af75150165d0440ca` |
| leg A `approve` | `0x9b7425d1ba15865641046b1812283902e9d716ef07e1608c263b90c76017b6ca` |
| leg A `pay` (terms hash `0x57458005…54b07`) | `0x166612b20cb425f4e84a0f51cc5710d1f9c41104fe7069b56b13138f63d01235` |
| leg B `createLink` (invalid rule table) | `0xf0464c34e1e4a29d499d5fb2f39baa7f8fefb09e044322e2a990f651d3fed464` |
| leg B `payWithAuthorization` (terms hash `0x6c2ee9a8…0118b`) | `0x109b21b9327ddbd6493b5b00ff6999cdc9bba22de5dbe1ac65b440f32e8df5ac` |
| `claim` leg A (rule table) | `0xdb61fb0be6dd624870289f91843d002a8a7d453e72319c87113767f039c2c081` |
| `claim` leg B (fallback) | `0x0e7f79f8434d4d8ad71ccd58fc333636f1d479386011bc80c6314bd6cefcdd3d` |

Reconciliation, measured from a snapshot taken before either link existed
(link ids `pago-261118-144006-a` / `-b`):

```
payee change        1,492,500   (rule 497,500 + default 995,000)
deployer change    -1,492,500   (two 1,000,000 payments + rule seat 497,500 + 2 x 5,000 fees)
held by Pago change        0    (nothing left inside)
deltas sum to              0    (every unit accounted for)
PASS - leg A settled through the rule table, leg B through the fallback default,
both payer paths live on X Layer testnet, every unit accounted for.
```

### Live testnet redeploy for the two-leg rule-6 check (chain 1952), 2026-11-19

> **Superseded later the same day** by the live re-check redeploy below: the
> constructor no longer stores a verdict, so this contract's
> `evaluatorPinned` (a stored bool frozen at deploy) was replaced. Kept as
> the record of the two-leg constructor deploy and its exercise run.

The constructor gained `circuitBeacon` and `expectedImplementationCodehash`
(§18), so the bytecode and addresses changed again. Deployed with
`forge script script/Deploy.s.sol:Deploy` (stand-in processor, mock beacon
reporting it, leg 1 reference = the recorded TapeOut shell), then
`script/testnet-exercise.ps1` settled both payer paths end to end. Read back
from chain with `cast` afterwards — **oklink was unreachable from this
machine, so the explorer character-check falls back to direct `cast` reads;
disclosed here rather than claimed as an explorer confirmation.**

| What | Address | Code size (cast) | Deploy tx |
|---|---|---|---|
| **Pago** (rules 1–10 + the two-leg rule-6 check) | `0x773A8dddc01d623a0E19df2E67F8e6FC70523b88` | 14,679 bytes | `0x81b3dc68ad7ec2f7defec126d97308683e4c45134102e0b77ccb967ac781dd40` |
| pUSD **(MOCK**, 6 decimals, freely mintable, no backing) | `0x5D00e40242B75Fe964F0a1f59D9C8Ee7A04F8e87` | 4,117 bytes | `0xadae6386767649a764e2594f738c94a74e990b0af413fb378c55c21c7e5170be` (mint to deployer: `0xd773a5c83a7414952e8ff4fc9864db3eabddc3c68f81e1d0b609f6f623445c95`) |
| **ProcessorStandIn** (EVM, **not hardware**) | `0x65Ec22321E3FC3823c5fDF235eEd20f2BcA66D71` | 2,779 bytes | `0xbfab5eb27cbc57d41fdd5a46512d1ec12b45a63face3663ac03c070949be6787` |
| **MockBeacon** (reports the stand-in; not the TapeOut beacon) | `0x6a8498A5d0a18d5785220152a3dD3020272fdeeB` | 240 bytes | `0x3c1c5d404701ad1e8949aee0b12c857221a1595807d8bf63e8b6a0f5c85090df` |

Constructor state, read back live with `cast call`:

| Read | Value | Meaning |
|---|---|---|
| `evaluatorPinned` | `false` | **unpinned, capped** — shown honestly everywhere |
| `changeDetector` | `true` | behaviour evidence only; never sets the flag |
| `expectedProcessorCodehash` | `0x57aa306f…17d5` | leg 1: the recorded TapeOut shell (§18) |
| live `extcodehash(processor)` | `0x250c2eab…8108b` | the stand-in's own code — correctly ≠ the recorded shell, so leg 1 fails |
| `circuitBeacon` | `0x6a8498A5…fdeeB` | the mock beacon |
| `expectedImplementationCodehash` | `0x250c2eab…8108b` | leg 2 reference = the stand-in's code, so leg 2 passes against the mock |
| live `beacon.implementation()` | `0x65Ec2232…66D71` | the stand-in, as the mock reports |
| `MAX_LINK_AMOUNT_UNPINNED(pUSD)` | `10,000,000,000` | 10,000 pUSD cap while unpinned |

So on testnet **leg 2 passes and leg 1 fails** — exactly the honest shape:
the machinery runs live on both legs, and the flag stays false because the
stand-in is not the recorded TapeOut shell. On mainnet tier 2 (recorded
processor + recorded beacon) both legs pass.

Exercise run — both payer paths, same reconciliation as before
(link ids `pago-261119-013711-a` / `-b`):

| Step | Tx |
|---|---|
| mint 10 pUSD to the payer | `0x1c3ee09ddd4183d8fb50ec486d2e0acecca192115328da921fd75730a5e9bf93` |
| leg A `createLink` (two split tuples) | `0xb89011848e8c99ba247709416e8e783039b487002a98a0cba3a49a2c00c5e917` |
| leg A `approve` | `0x8d7645c93f90268046b1aa9d72f2b065a21ae471860790c0dc1ed2f2217f8373` |
| leg A `pay` (terms hash `0xa55e2ac6…374f1`) | `0xfd7bf3b2f5f5c4aa48ca685345af158f0fc6e1fd8d51882b0a22c15cdf3aa397` |
| leg B `createLink` (invalid rule table) | `0x94496f931220cbb2f8643063761888853d112f5e902a161841baa42c4c3eb400` |
| leg B `payWithAuthorization` (terms hash `0x09c8a1d9…44f3a`, digest `0x40a7e205…217c1`) | `0x8f9224bbcf67293104a831e6978c1734cdb41abf12cc2e0e3779229eca49e7a2` |
| `claim` leg A (rule table) | `0x9d5216e796a6da05aeef6d7ef43f5ca6a5e8cc81f1bfc80b2d173a6cdd94ed4b` |
| `claim` leg B (fallback) | `0xfde2f091bd7d265be4f8669482be288484e0f663eba212bc8e37bfa14764bc2f` |

```
payee change        1,492,500   (rule 497,500 + default 995,000)
deployer change    -1,492,500   (two 1,000,000 payments + rule seat 497,500 + 2 x 5,000 fees)
held by Pago change        0    (nothing left inside)
deltas sum to              0    (every unit accounted for)
PASS - leg A settled through the rule table, leg B through the fallback default,
both payer paths live on X Layer testnet, every unit accounted for.
```

### Live testnet redeploy for the LIVE rule-6 re-check (chain 1952), 2026-11-19 (superseded the same day by the MOCK-pinned copy below — kept as the failure-path proof)

The rule-6 fix that gates the frontend phase: `evaluatorPinned` is no longer
a bool frozen at deploy — per the master prompt's verbatim sentence
("store the implementation address and its `extcodehash` and verify both at
claim") the constructor now stores the **implementation address** alongside
the references, and `evaluatorPinned()` is a view that re-runs both legs on
every call; `claim` and `createLink` consult it live (§18, Q3/Q4 update).
Bytecode and addresses therefore changed again.

Deployed with `forge script script/Deploy.s.sol:Deploy --account
pago-deployer --broadcast` from `contracts-evm/` (Foundry only auto-loads
`.env` from the working directory, so the keystore password variable was
loaded from the repository root `.env` into the session first — the file is
gitignored and nothing was printed). The testnet RPC dropped the first
submission round; `--resume` completed it. Character check by direct `cast`
reads again — oklink remains unreachable from this machine, disclosed rather
than claimed as an explorer confirmation.

| What | Address | Code size (cast) | Deploy tx |
|---|---|---|---|
| **Pago** (rules 1–10 + the LIVE two-leg rule-6 re-check) | `0xA4AA0B191807c13c9c8b83de7B2f48b7dd017bfF` | 15,327 bytes | `0xa2daef6fa41bf44b5c4cf05485cd5c29a4a8196e06bd10eeb2f75d509b45338c` |
| pUSD **(MOCK**, 6 decimals, freely mintable, no backing) | `0x1Bf9Fd0C674BcE9cdc9EFc7C2A70e20E84E6953C` | 4,117 bytes | `0x03fc9214dcdf9dcc005978d1c8bd487d799c1d84791b7c78e4d1b398e3c2c855` (mint to deployer: `0x7b5d1f6cab0ac5237ec1471f6bcd97e656dd0fdb8f530b6fed36f96c4dbe1b35`) |
| **ProcessorStandIn** (EVM, **not hardware**) | `0xe4b4ABb2c6A0B15603b1A308Eba0264f8f676E02` | 2,779 bytes | `0xcbc37cbee29d6f7148e2456bafa447d04f8b7e80be0fb86b14e9300f9009bd58` |
| **MockBeacon** (MOCK — reports the stand-in; not the TapeOut beacon) | `0x359749641523b7AcC791a856FC6afD35A756F723` | 240 bytes | `0x41d0dc33499aee123a77d3654d1876ab123eaa2168fb38df06926b7a07c2dbc5` |

Runtime codehashes, `cast keccak $(cast code …)` on the deployed addresses:

| Object | Codehash |
|---|---|
| Pago | `0x19fa780a9fa7ee14665e776225ee055a62bc5efdfcb9581184a599c2ba638389` |
| pUSD (MOCK) | `0x09322da210af77b45b75730eeb9019a343f77d6fdc48e6ea94a3103139a3b682` |
| ProcessorStandIn (EVM, not hardware) | `0x250c2eabb12262efcc680829e6c4e67e635abeeaf1c7b26c2eb0ccf9ae38108b` |
| MockBeacon (MOCK) | `0xc54052711441e659904163308bbec570a18c16e82b7f7a4916b8c0d80f5474f2` |

State, read back live with `cast call` after the broadcast:

| Read | Value | Meaning |
|---|---|---|
| `evaluatorPinned()` | `false` | **unpinned, capped** — a live view now, re-run on every call, never stored |
| `circuitImplementation` | `0xe4b4ABb2…76E02` | the stored implementation address — equals the stand-in, as the mock beacon reports |
| `circuitBeacon` | `0x35974964…6F723` | the MOCK beacon |
| `expectedProcessorCodehash` | `0x57aa306f…17d5` | leg 1: the recorded TapeOut shell (§18) |
| live `extcodehash(processor)` | `0x250c2eab…8108b` | the stand-in's own code — correctly ≠ the recorded shell, so leg 1 fails |
| `expectedImplementationCodehash` | `0x250c2eab…8108b` | leg 2's codehash reference = the stand-in's code |
| live `beacon.implementation()` | `0xe4b4ABb2…76E02` | equals `circuitImplementation` and hashes to the reference — leg 2 passes |
| `changeDetector` | `true` | behaviour evidence only; never sets the flag |
| `MAX_LINK_AMOUNT_UNPINNED(pUSD)` | `10,000,000,000` | 10,000 pUSD cap while the live check does not pass |

Same honest shape as before — **leg 2 passes, leg 1 fails, the flag reads
false** — but now the verdict is recomputed at every `claim` and every
`createLink`, which is what the swap tests in `ForkPin.t.sol` and
`PagoRule.t.sol` prove: swap the beacon after a link exists and the same
deployment's flag flips false, the claim pays the default split, and new
links are capped.

**Exercise run — 2026-11-19, PASS.** `script/testnet-exercise.ps1` settled
both payer paths against this deployment after the deployer was topped up
(0.2002 OKB faucet) and the script's own 0.0003 OKB payee top-up (tx
`0x7140223498fc30b12958b9fd4069c97e47dbcc60da5f5dec9e68ee345d9af1e0`).
Both legs settled through the **default** table — exactly what rule 6's live
check demands while `evaluatorPinned()` reads false, which on this deployment
it always does: the stand-in's code can never hash to the recorded TapeOut
shell reference, so `claim` re-runs the two-leg check, fails leg 1, and never
consults the circuit.

| Step | Link / Tx |
|---|---|
| mint 10 pUSD **(MOCK)** to the payer | `0x97d4f0b8de6416f38432a92dd04d7eae07ccac5e22cd0b72fef3cdae5b382dc8` |
| leg A `createLink` — `pago-261119-061618-a` | `0x30dca33df6a1090189db218f2c1d1f406f0e3bc369aa778613af44b53bc06e5b` |
| leg A `approve` | `0x9133550f0f621a3ed41612fe71a8b12305b4e7ae8c74ae9eba9f88c684180b3b` |
| leg A `pay` (terms hash `0x1f571714…e39f52`) | `0xaccf05312108021682647f45bfb8079f44c9188f245a8aa53fde25c83876ad8c` |
| leg B `createLink` — `pago-261119-061618-b` | `0x3aafe412b91143c21ee809d959b7176750d5f849dd706733fb1d762a3e83136a` |
| leg B `payWithAuthorization` (terms hash `0x087c9be6…09b51f`, relayed digest `0x55b8a737…fb37e4`) | `0x23622340a2c1643fb45fbff9b4974acad43a13d62269feecba45851f58a2945e` |
| `claim` leg A (default table) | `0xc244e339c79809942abf7ac63fa2386d8ff784a5736ba97c7d01a7d6ce8605ee` |
| `claim` leg B (default table) | `0x5236a6cc481344eb61e246da67adb5416eab8134686b05b7897c0b95b80bb5ce` |

Reconciliation, measured from a snapshot taken before either link existed:

```
payee change        1,990,000   (default 995,000 x 2 - the live check gated claim)
deployer change    -1,990,000   (two 1,000,000 payments + 2 x 5,000 fees; no rule seat while unpinned)
held by Pago change        0    (nothing left inside)
deltas sum to              0    (every unit accounted for)
PASS - both payer paths live on X Layer testnet; while unpinned the
live rule-6 check gated claim to the default table on both legs,
every unit accounted for.
```

Leg A's link carries a *valid* rule table (10/6/4 = 20 steps) and leg B an
invalid one (10/8/5 = 23 steps); neither was consulted, because `claim`
re-runs the check and returns the default table whenever it does not pass.
The rule-table path is proven where the check *does* pass: `PagoRule.t.sol`
(pinned constructor arguments) and `ForkPin.t.sol` (the genuine mainnet
shell + beacon). **Honest consequence for this deployment:** it can never
show the rule table paying live — the stand-in cannot satisfy the recorded
shell reference — so it stands as the failure-path proof. The second,
MOCK-pinned copy below exists so the browser can show the rule path paying;
`e2e/specs/testnet/` reads that run's link back.

### Second testnet copy — MOCK-pinned, so the rule table pays live (2026-11-19) (superseded the same day by the frozen build below)

**Why, and what it is not.** On the copy above a judge watching the browser
would only ever see the default split, because the check is built to fail
against a stand-in. Rule 6's references are constructor arguments — a deploy
setting, not a feature — so a second copy whose leg-1 reference is the MOCK
stand-in's own codehash makes the same two-leg machinery *pass*, and the
circuit decides a payout live in the browser. **Required label, everywhere:
"testnet pin reference is the MOCK stand-in; mainnet uses the recorded
TapeOut references." The UI must never show a bare "pinned."** Nothing was
removed: the deployment above remains on chain as the failure-path proof.

Deployed with the same `script/Deploy.s.sol`, adding environment overrides
only — no code change:

| Knob | Value | Why |
|---|---|---|
| `PAGO_TOKEN` | `0x1Bf9Fd0C…6953C` | reuse the pUSD **(MOCK)** |
| `PAGO_PROCESSOR` | `0xe4b4ABb2…76E02` | reuse the EVM stand-in (**not hardware**) |
| `PAGO_BEACON` | `0x35974964…6F723` | reuse the **MOCK** beacon (reports the stand-in) |
| `PAGO_IMPLEMENTATION` | `0xe4b4ABb2…76E02` | the address that beacon reports |
| `PAGO_PROCESSOR_CODEHASH` | `0x250c2eab…8108b` | **leg 1 = the stand-in's own codehash** |
| `PAGO_IMPLEMENTATION_CODEHASH` | `0x250c2eab…8108b` | leg 2 = the stand-in's codehash |

`0x250c2eab…8108b` is `cast keccak $(cast code 0xe4b4…76E02)` — the stand-in's
runtime code hash, recorded here rather than read back at deploy so the
constructor's check cannot become tautological.

| What | Address | Code size | Deploy tx |
|---|---|---|---|
| **Pago** (MOCK-pinned copy) | `0xfa47d03b5a30ed5105886590a12a7d63d88bacce` | 15,327 bytes | `0xf7ee9e948d71f2459cbbd0314e0e3fbc32b8543b7be8dce1c8399a2d7513632e` |

Runtime codehash `0x5480226bbbcdd15e7524ca49238c0f7fac96bb5f4d873374cd22bc2913f00b7a`
— different from the copy above because both references are immutables
inlined into the runtime code. Reads after the broadcast:

| Read | Value | Meaning |
|---|---|---|
| `evaluatorPinned()` | `true` | **both legs pass**, re-run live — not a stored bool |
| `expectedProcessorCodehash` | `0x250c2eab…8108b` | leg 1 = the MOCK stand-in, deliberately **not** the recorded shell |
| live `extcodehash(processor)` | `0x250c2eab…8108b` | equal → leg 1 passes |
| live `beacon.implementation()` | `0xe4b4ABb2…76E02` | equals `circuitImplementation` **and** hashes to `0x250c2eab…8108b` → leg 2 passes |
| `MAX_LINK_AMOUNT_UNPINNED(pUSD)` | `10,000,000,000` | stored, but never applied while the check passes |

**Exercise — 2026-11-19, PASS (mode: pinned).** The script now reads
`evaluatorPinned()` and branches its expectations instead of assuming a mode;
against this copy it expected the rule table on leg A.

| Step | Link / Tx |
|---|---|
| mint 10 pUSD **(MOCK)** to the payer | `0x52470e258a8c3e8f1cd190279f6083f3d8ac7c2d7aa2197c776548b6429b6d14` |
| leg A `createLink` — `pago-261119-115432-a` | `0xfdf73c776a37565a241a34b9e0b94ba0aba1027c7101fe17399c477e5441a5b6` |
| leg A `approve` | `0xd0b9e39fd237911cdd9e5a08e55e55f6ec0a23e63ffdf5dc4d5592a8834688ca` |
| leg A `pay` (terms hash `0x38f00456…07f793`) | `0x9a7bfa2b46c414437f63567f801d7fb4d0a7e29ef84c06aae5f23fbcd320580f` |
| leg B `createLink` — `pago-261119-115432-b` | `0xb6edcbcd3c9f6e69beebd630c635996dcc5f9e1dc019dbd80035ab906d730d4a` |
| leg B `payWithAuthorization` (terms `0xb820e02a…9ccbf8`, digest `0x5cf746d2…80ab1`) | `0xaf80a2cf2590b108a5d9bf5f5f5abe0f290e9bb9c411b6b88ef0adb698f15805` |
| `claim` leg A — **rule table** | `0xf69d9a08a2750b38b995a7f46c8a119415d2889c016f1f026a691e7ec35a956f` |
| `claim` leg B — default table | `0xd5c0d1f4d0794c5d4a38ab5c0c851d82633ad38825c87def8744dd27d6fe2650` |

The claims' own events say which table each one used — `LinkClaimed(bytes32
indexed, uint256 remainder, uint256 fee, bool usedRuleSplit)`, topic
`0xb5b858e9…cc398`, decoded from the two receipts:

| Claim | remainder | fee | `usedRuleSplit` |
|---|---|---|---|
| leg A | 995,000 | 5,000 | **`true`** — the circuit chose the rule table |
| leg B | 995,000 | 5,000 | **`false`** — 10/8/5 = 23 steps, default table |

Reconciliation, measured from a snapshot taken before either link existed:

```
mode                          pinned
payee change        1,492,500   (rule 497,500 + default 995,000)
deployer change    -1,492,500   (two 1,000,000 payments + rule seat 497,500 + 2 x 5,000 fees)
held by Pago change        0    (nothing left inside)
deltas sum to              0    (every unit accounted for)
PASS - both payer paths live on X Layer testnet, mode: pinned.
```

The deployer receiving 497,500 back as leg A's rule seat is the visible
proof the rule table — not the fallback — paid that claim; it is the same
figure `ForkPin.t.sol` asserts on the genuine mainnet chain. **Honest
caveat:** the "valid" verdict came from the **MOCK stand-in** executing the
real Split3 netlist bytes — not hardware. On mainnet the same path runs the
taped-out processor, which the fork suite proves with the recorded
references.

### Frozen build — comment-only fix (2026-11-19), then the EIP-3009 selector fix and final testnet redeploy (2026-11-25) — **the frozen source**

**What changed, and why now.** One sentence in `Pago`'s constructor comment
overstated leg 2 ("a wrong configured beacon can only make the flag false");
§18 Q2 above now states it precisely, and the source comment was aligned
with it. A comment changes the compiler metadata, so the compiled hash
changes even though behaviour does not — and this is the cheapest moment to
absorb that: before the frontend exists and before any mainnet deploy.
Same script, same six environment overrides, **no logic change**.

**What changed next — 2026-11-25.** Fork tests run against the real USD₮0
and USDG ABIs caught an interface bug: `IEIP3009.transferWithAuthorization`
declared its window as `uint64,uint64`, giving selector `0xd8fde8d5`, where
the real tokens implement `uint256,uint256` (`0xcf092995`) — so the gasless
leg could never have settled against a real token. The fix is two type
keywords in the interface (and the matching mock); `payWithAuthorization`
(`0x69c1372a`) and `createLink` (`0x6c5b7a11`) are unchanged. The source was
re-frozen, the testnet redeployed pinned against the MOCK stand-in's own
codehash, and both payer paths re-exercised live — figures below.

> **The contract source is FROZEN at this build.** Mainnet tier 1 deploys
> this same source. From here the only permitted changes are bug fixes, and
> each one means a new build, a fresh testnet redeploy and a re-recorded
> codehash.

| What | Value |
|---|---|
| **Pago (frozen build)** | `0xa65118a1434123648515929ce744D591ECC01a4B` |
| deploy tx | `0x27fc78cbfdb388d9fb8aac8db914da5ebb96b552d71cff2315e3267506371c9a` |
| code size | 15,327 bytes |
| runtime codehash | `0xb10629a023d401d855b90a2de5b2375230d89f2bc8799e0da991de2bc9f419aa` |
| `evaluatorPinned()` | `true` — **MOCK-pinned**: leg 1 = stand-in codehash `0x250c2eab…8108b` |
| tests after the change | **159/159** (`forge test`, local + mainnet-fork suites) |

Superseded testnet copies, all still on chain: `0xfa47d03b…bacce` (same
MOCK-pinned configuration, pre-fix source), `0xA4AA0B19…17bfF` (the
failure-path proof), `0x36d212b8…dce9` (the pre-fix pair — Pago and mock both
carried the old `uint64` window, so they agreed with each other and the
gasless leg settled) and `0x0825e9b9…C3f4` (fixed source but unpinned: leg 1
checked against the recorded shell, so every link was capped; abandoned after
leg A paid).

**Exercise — 2026-11-25, PASS (mode: pinned), the post-fix proof:** links
`pago-261125-020108-a` / `-b`, payee **+1,492,500**, deployer **−1,492,500**,
contract held **0**, deltas sum **0**.

| Step | Tx |
|---|---|
| mint 10 pUSD **(MOCK)** | `0x340b44e46f41ad12b080535bcd179afa7a8f3612270916ba78f266edb63f5ef6` |
| leg A `createLink` | `0x44074868cdc14eac5fa23aa03ac709ef857064f3ac82cda11e1dfba7a501f40b` |
| leg A `approve` | `0xa5786476462c6ce403e077197b97bd5533cd5cfbde5a62858a955dc6599b838b` |
| leg A `pay` (terms `0xcdd4e206…952f8`) | `0x77343f115fafe073a3d7895263a49b3d174588ea2e9a6699455f3a77f48d5980` |
| leg B `createLink` | `0x5c6d2fa83f3fc2ab1c881bfde9d4cb1de6b78c053c8aef5786027ba7058a616c` |
| leg B `payWithAuthorization` (terms `0x4c3d5684…2640c`, digest `0xb6895353…4b3c3`) | `0x23464a87b749f515112ef0f58c31d124540aed719c289da53e0cdd24d7f787f2` |
| `claim` leg A — **rule table** | `0x4b9c6386d65fdeb7cc658860ea954b72bd1cd37171ec2530538041f1d6d95959` |
| `claim` leg B — default table | `0xa6e3439c1acb860b8bcc207cae9b48222842cc4250b1170b80acde5e87a7f589` |

Claim events, decoded from the receipts: leg A `remainder 995,000 / fee
5,000 / usedRuleSplit = true`; leg B `remainder 995,000 / fee 5,000 /
usedRuleSplit = false`.

**Exercise — 2026-11-19, PASS (mode: pinned) — the pre-fix copy run, kept as
history:** links `pago-261119-124452-a` / `-b`, payee **+1,492,500**,
deployer **−1,492,500**, contract held **0**, deltas sum **0**. Both sides
carried the old `uint64` window then, so they agreed with each other — this
run proves the script and the reconciliation, not compatibility with the real
USD₮0/USDG.

| Step | Tx |
|---|---|
| mint 10 pUSD **(MOCK)** | `0x84b474a3c48648a561b0b36b2c23a3d777728d82fef10f1e07dd19124d1ce4d8` |
| leg A `createLink` | `0xe1e6fd2e270adf5d564e6a9bd59f58b9717d79fccd4373f03bccc8267bcbb2ea` |
| leg A `approve` | `0xfec4d1ae13e61708e14faed249f23de0c3a134b72e0a51f25a17d8dd41a24269` |
| leg A `pay` (terms `0xc4b733f4…a9639`) | `0x0f8ee164ae4f9e3769a07ab532fd5675a5a9da260e2efc6eee53386de115f1e2` |
| leg B `createLink` | `0xc71637a81f994e3f67c83d6fef406a9cc3ac7ae62fe176d9d1254d3035d02f83` |
| leg B `payWithAuthorization` (terms `0xea1c675d…4c41f4`, digest `0x101bd975…a4295`) | `0xd272ff5da20b82a82d27f27ceac5d7023fc740c4e2de40795bc8bd800cf76ea5` |
| `claim` leg A — **rule table** | `0xd645981905f6e97989285c857bd0967f20248fee7a1ffb2fc8707dfcca214c9e` |
| `claim` leg B — default table | `0x9a661e7f0b6d26cd81cce54f27897d1392ca8a54b38825616be0c26def4c4183` |

Claim events, decoded from the receipts: leg A `remainder 995,000 / fee
5,000 / usedRuleSplit = true`; leg B `remainder 995,000 / fee 5,000 /
usedRuleSplit = false`.

**No always-on cap exists without a code change — asked, answered, recorded.**
Can a modest cap that applies even while the check *passes* be set through
deploy-time configuration? **No.** The constructor writes exactly one value
per token, `MAX_LINK_AMOUNT_UNPINNED[token]`, and `createLink` enforces it
only when `evaluatorPinned()` is false (src/Pago.sol:429); there is no
second, always-enforced knob, so adding one would be a contract change —
which the freeze rules out. The honest position instead: **this contract's
only review is its own test battery**, and on a pinned deployment links are uncapped.

### Function selectors (`cast sig`, 2026-11-18)

| Selector | Signature |
|---|---|
| `0x6c5b7a11` | `createLink(string,uint256,address,string,uint64,(address[3],uint8[3]),(address[3],uint8[3]))` |
| `0x8032337c` | `pay(string,uint256,bytes32)` |
| `0x69c1372a` | `payWithAuthorization(string,address,uint256,uint64,uint64,bytes32,bytes,bytes32)` |
| `0xe93341c4` | `termsHash(string)` |
| `0x67cec07b` | `terms(string)` |
| `0xf3fe12c9` | `claim(string)` — unchanged |
| `0x84ff6985` | `withdrawOwed(address)` |

`getLink` / `getLinksByCreator` keep their signatures but their `Link`
struct grew (two `Split` tables + `netlistHash`), so decoders change even
where selectors do not.

### Still open, unchanged by this phase

- **Mainnet gates** are exactly as `docs/MASTER_PROMPT.md` records them: no
  phrase has been given, chain 196 stays read-only, no token purchase may be
  made without first quoting a dollar cost and asking.
- **Q2 tier 3 scope** remains unrecorded and is deliberately not guessed.
- The frontend codec (§16) still speaks the superseded ABI — next phase.

---

## 18. The mainnet pin question: what is behind `evaluatorPinned`? (2026-11-18)

Asked before the frontend may show any "pinned" wording: identical codehashes
across three processors look like proxy shells, so a `true` flag would mean
"the shell matches", not "the evaluator is unchanged" — unless Pago can reach
the real implementation onchain. Everything below is a live probe against X
Layer mainnet (chain 196) taken today; commands are given so any claim can be
re-run.

### Q1 — disassembly of one real processor

`cast disassemble $(cast code 0x9de448A1CE9537d24199B3b5355239d73aA6F591
--rpc-url https://rpc.xlayer.tech)` — processor **#340**:

| Fact | Evidence |
|---|---|
| 295 bytes, **not** an EIP-1167 minimal proxy | patterns `3d3d3d363d73` and `5af43d82803e903d91` absent from the hex |
| EIP-1967 implementation slot | reads `0` |
| EIP-1967 beacon slot `0xa3f0ad74…3d50` | `0xf70d1ed4…bd0991c` — the circuit beacon |
| codehash | `0x57aa306f…17d5`, identical on #340, #30 and #333 |
| what the code does | every call first `STATICCALL`s selector `0x5c60da1b`
(`implementation()`) at the **beacon address hardcoded in the bytecode as a
`PUSH32` literal** (`0xf70d1ed4…bd0991c`), then `DELEGATECALL`s the original
calldata to whatever address came back and bubbles the result — or the revert |
| opcode census (full disassembly) | **0 `SLOAD`** and exactly **one
`PUSH32`**, of the beacon address. The EIP-1967 beacon slot also holds
`0xf70d1ed4…bd0991c` (written once at construction), but the code never reads
storage — the operative beacon binding lives in the bytecode itself, which is
exactly what leg 1's codehash comparison pins |

So Q1's answer: **a custom ERC-1967-beacon proxy shell**, neither a minimal
proxy nor UUPS, whose beacon is pinned inside the very code whose hash we
check. The two other processors share that exact code (same codehash), so the
answer covers all three.

Direct reads of the other end of the chain (the offchain path):

| Object | Value | Probe |
|---|---|---|
| circuit beacon | `0xf70d1ed4f62cf3780157b0b421b7e2f45bd0991c` | #340's beacon slot; 619 bytes, codehash `0xc7cc9854…5362` |
| beacon `owner()` | `0x0000000000000000000000000000000000000000` (frozen) | read live today |
| beacon `implementation()` | `0x977f217887E085D298Cb3819cDAD5A0ee35F29B2` | read live today |
| circuit implementation | 12,562 bytes, codehash `0x7a15c353205e5245f40f5f5524542a982a4bb3b9a28476e4f10845163f941b30` | `cast code` + `cast keccak` |
| `implementation()` on the processor | **reverts** | probed today, ABI and raw selector `0x5c60da1b` |
| `beacon()` on the processor | **reverts** | probed today (selector `0x59659e90` not in its code) |
| circuit implementation's `implementation()` | **reverts** | probed today; selector absent from its 69 PUSH4 constants |

### Q2 — can Pago follow that chain onchain?

**No — not from the processor alone; yes — with the beacon address supplied
and both codehashes checked.** The reasoning, each step probed:

1. Pago cannot read another account's storage, so the beacon address sitting
   in #340's beacon slot is unreachable onchain.
2. No public getter reveals it: `implementation()` and `beacon()` revert on
   the processor (probes above), and the evaluator's own surface — `eval`,
   `circuitInfo`, `nextId`, `netlist` — returns circuit data only.
3. Pago also cannot parse bytecode onchain to find the `PUSH32` literal.
4. **But the beacon address can be passed in as constructor configuration, and
   that closes the loop rather than opening a hole:** the first leg checks
   `extcodehash(processor)` against the recorded shell hash. If that matches,
   the running code is byte-for-byte the code disassembled above — the code
   that hardcodes beacon `0xf70d…` and delegates to whatever *that* beacon
   returns. The second leg then calls `beacon.implementation()` (a public
   getter — an onchain read of the live state) and checks
   `extcodehash` of the returned address against the recorded implementation
   hash. Two guarantees, stated precisely (corrected 2026-11-19): a wrong
   configured beacon can never make a *wrong evaluator* pass — with leg 1
   pinning the shell, the actual delegation target is the shell's hardcoded
   beacon regardless of what the configuration says. What it *can* do is make
   leg 2 pass while pointing elsewhere: any address whose `implementation()`
   merely returns the recorded implementation satisfies the getter check. So
   leg 2 is a check against the **configured** address, and the binding
   between that address and the shell's hardcoded one is established
   offchain by the disassembly (Q1) — points 1–3 above say it cannot be
   re-derived onchain. On mainnet the configured value IS the recorded
   shell-embedded beacon (`0xf70d…`), so the two agree by construction.

So a genuine processor passing both legs means: *at construction, the shell
code is the recorded one and the beacon it is hardcode-bound to reported an
implementation whose code is the recorded one.* That is a real onchain
implementation check — stronger than the shell-only comparison.

### Q3 / Q4 — consequence, updated 2026-11-19 to the live re-check form

Q2's answer is **yes**, so the conditional rename to `proxyCodeMatches` does
not apply: `evaluatorPinned` keeps its rule-6 name and gains the second leg.
Per Q4 — and then per the original verbatim sentence supplied on 2026-11-19
("store the implementation address and its `extcodehash` and verify both at
claim"), the flag is **not a bool frozen at deploy**:

- the constructor stores the references — `expectedProcessorCodehash`,
  `circuitBeacon`, the **implementation address** and
  `expectedImplementationCodehash` — and computes no verdict;
- `evaluatorPinned()` is a **view that re-runs both legs on every call**:
  leg 1 `extcodehash(processor)` against the shell reference, leg 2 the
  beacon's public `implementation()` answer against BOTH the stored address
  and its stored codehash;
- `claim` consults it in the same transaction: a failing check means the
  rule table is never asked about and the **default split** applies;
  `createLink` consults it too: while it fails, every link is capped at
  `MAX_LINK_AMOUNT_UNPINNED[token]`;
- `changeDetector` remains a public view that can never make it true;
- `test/ForkPin.t.sol` runs against mainnet fork state: the genuine chain
  pins (`true`), `vm.etch`-swapping the beacon flips the **same
  deployment's** flag to `false` at the next read, and the required case is
  covered end to end — a link created and paid while both legs pass, the
  beacon swapped **after the link exists**, then `claim` pays the default
  split (event `usedRuleSplit = false`) and a new link above the cap is
  refused. A unit-level twin lives in `PagoRule.t.sol`.

### What the flag does and does not prove (disclosed wording for UI/README)

- **Proves, onchain, at every read (it is a view, not a stored value):** the
  deployed shell's code hash equals the recorded one, AND the beacon's public
  `implementation()` getter currently returns the stored implementation
  address, AND the code at that address still hashes to the recorded
  implementation's. `claim` re-verifies this in the transaction that pays, so
  a change behind the beacon after link creation is caught at payout time.
- **Does not prove:** that the proxy actually delegates where the configuration
  says (it doesn't need the configuration — it hardcodes its beacon; the
  binding was verified by the disassembly above, offchain);
  that a *future* change cannot happen — only that any change is visible to
  the next read, which is why the check runs live rather than once;
  what the payer's screen showed (rule 4, unchanged).
- **While the check does not pass, links stay capped.** Two testnet copies
  now show both sides: `0xA4AA0B19…17bfF` checks leg 1 against the recorded
  shell, fails (`false`), caps every link and settles every claim through the
  default split — the failure-path proof; `0xfa47d03b…bacce` checks leg 1
  against the MOCK stand-in's own codehash, passes (`true`), and lets the
  rule table pay live (§17). Neither may be shown as a bare "pinned": the
  label is "testnet pin reference is the MOCK stand-in; mainnet uses the
  recorded TapeOut references".

Recorded values, all probed 2026-11-18 on chain 196:

| Reference | Value |
|---|---|
| processor shell codehash (`PAGO_PROCESSOR_CODEHASH`) | `0x57aa306fd0be97087da3534e03398f5ff4efd533b5be4e45a405ce86fa6717d5` |
| circuit beacon (`PAGO_BEACON`) | `0xf70d1ed4f62cf3780157b0b421b7e2f45bd0991c` |
| circuit implementation address (`PAGO_IMPLEMENTATION`) | `0x977f217887E085D298Cb3819cDAD5A0ee35F29B2` |
| circuit implementation codehash (`PAGO_IMPLEMENTATION_CODEHASH`) | `0x7a15c353205e5245f40f5f5524542a982a4bb3b9a28476e4f10845163f941b30` |
| processor #340 (the example disassembled) | `0x9de448A1CE9537d24199B3b5355239d73aA6F591` |


## 19. Tier 2 on the fork: a real processor, a real tape-out, a real payout (2026-11-19)

`test_realFactoryProcessorTapesOutSplit3AndPaysTheRuleTable` runs the whole
Tier 2 chain against X Layer mainnet (chain 196) in a Foundry fork — no real
funds move, but every contract it touches is the live one. **It passes
end-to-end** (`forge test --match-test
test_realFactoryProcessorTapesOutSplit3AndPaysTheRuleTable -vv`, ~51 s):

`approve` BEM → `createCPU` → identify the two surfaces → mint 104
transistors → `tapeout` Split3 → deploy Pago against the new processor's
recorded references → `evaluatorPinned()` true → create link → pay → claim
with `usedRuleSplit = true` — seats **746,250 / 149,250 / 99,500**, fee
**5,000**, and the log line `TIER 2 REPRODUCIBLE: factory processor pinned
and the rule table paid`.

### What createCPU actually returns — roles assigned by capability

The test interface's `(circuits, transistors)` return names were an
unverified placeholder. The first fork probe had them **backwards**: the
**first** address returned carries the transistors surface (ERC-1155 mint),
the **second** the circuits surface (tapeout/netlist). The test no longer
trusts position — `_discoverRoles` probes each address and assigns by what
it *answers* (`TAPEOUT_FEE()` answers and `mintPrice()` doesn't → circuits;
the reverse → transistors), logging both shapes:

| | address | shape | evidence |
|---|---|---|---|
| first | `0x956bD5c56A947011e4B6A8bDF51e51108c4e9Be6` | 1 = transistors | answers `mintPrice()` (1e6), `protocolFee()`, `mint(uint256,uint256)` |
| second | `0xb325b72EaBb03B3f6FE1eEAd6BCbF31796c394da` | 2 = circuits | answers `TAPEOUT_FEE()`; impl answers `netlist`/`eval`/`circuitInfo`/`tapeout` |

Wiring confirmed by reading the circuits proxy's storage directly: **slot 0 =
the transistors contract** (tapeout's gate reads it from there), **slot 3 =
the factory**.

### Shell diff resolved: same proxy source, different compilation

The new processor's shell vs #340's recorded shell (`0x57aa306f…`): both
**295 bytes**, differing in exactly **32 bytes starting at byte 252** — the
trailing IPFS compiler-metadata hash. Both embed the **same recorded beacon
`0xf70d1ed4…`**. Consequences:

- the shell *codehash* is per-deploy (Tier 2 records its own, as the
  procedure already says) — the test logs the diff rather than assuming
  either way;
- the recorded **beacon `0xf70d1ed4…`, implementation `0x977f2178…` and
  implementation hash `0x7a15c353…` carry over unchanged** for new
  processors on this factory — the test re-follows the beacon and re-checks
  all four implementation-surface probes on every run.

### The gate wants one transistor PER GATE (and it costs BEM)

First tapeout attempt failed with error `0x03dee4c5`, arguments
`(account, held=1, required=104, 0)` — **104 = Split3's NAND count**.
Phase 0's 1-gate probe saw `required = 1`, which is why the docs used to say
"one transistor". The mint: **no value + BEM allowance** (the native-value
mint reverts empty — old processors charge native, new ones take BEM, §13);
`mintPrice` = 1e6 = 0.01 BEM at 8 decimals. The mint therefore cost
104 × 0.01 + the flat 0.01 BEM per-call protocol fee = **1.05 BEM** (the old
"1.04 / 1.14" figures missed that flat fee) — the route-1 total at that price
is **≈1.15 BEM + 0.0013 native + gas**. **Execution decision 2026-11-20:** run
with `mintPrice = 0` — the caller sets it, official CPU #340 runs at 0, and
`test/MintPriceProbe.t.sol` proves the factory has no floor on X Layer — which
brings the mints down to the flat 0.01 BEM alone and the route-1 total to
**≈0.11 BEM + 0.0013 native + gas** (§14, README and `config.js` corrected;
measured quote `docs/quote-dry-run-20261120-005520.log`, $1.74).

### Proves / does not prove

- **Proves:** the full Tier 2 chain is reproducible on this factory with a
  real BEM fee, a real 104-gate tape-out (circuit id 1, netlist 728 bytes,
  15-in/1-out roundtrip), Pago pinning against the new processor's recorded
  references (`evaluatorPinned()` true), and the rule table paid through the
  real factory circuit at claim time (`usedRuleSplit = true`).
- **Does not prove:** that mainnet was spent on (nothing here moves funds —
  a fork replays chain 196 read-only); that a *future* processor on the
  factory would embed the same beacon (each Tier 2 run records its own
  shell hash and re-follows the beacon — that is the procedure, not an
  assumption); what a payer's screen showed (rule 4, unchanged).

## 20. Step 7 — read-only mainnet preparation (2026-11-25)

**Nothing was broadcast to X Layer mainnet.** Everything below is either a
read (`cast call` / `cast code`) against the live chain or a deployment on a
**local anvil fork** of chain 196 pinned at block 76,802,574. The mainnet
deploy itself (step 8) stays gated on the exact phrase
`deploy to mainnet tier 1`.

### Constructor arguments re-probed live from the superseded Pago

The eight constructor arguments for the tier-1 deploy were re-read from the
superseded mainnet Pago `0xd63Ae612Cf9Acb9Ac8F7801eF68E8e71068E492c` —
the same values `Tier2Mainnet.s.sol`'s preflight constants record, confirmed
against live chain state rather than copied from a doc:

| Argument | Value |
|---|---|
| `tokens` | USD₮0 `0x779Ded0c…3736` (6 dec, cap 1e10), USDG `0x4ae46a50…2dc8` (6 dec, cap 1e10) |
| `feeAccount_` | `0x7FCe520D881454EA234d371E1256B75843609b62` |
| `processor_` | `0xDd6BB6fbda8ee867EF838bbE56ebA7d1EcC2c2f4` |
| `circuitId_` | `1` |
| `expectedProcessorCodehash_` | `0x8c799a18cd8e0d5f5f3c0cec4fbc145e2daf79f70c2b131c09d0f380921db545` |
| `circuitBeacon_` | `0xf70d1ed4f62CF3780157B0b421b7E2F45bD0991C` |
| `circuitImplementation_` | `0x977f217887E085D298Cb3819cDAD5A0ee35F29B2` |
| `expectedImplementationCodehash_` | `0x7a15c353205e5245f40f5f5524542a982a4bb3b9a28476e4f10845163f941b30` |

Also confirmed live on that contract: `evaluatorPinned()` **true**,
`feeBps` **50**, both decimals **6**, both caps **1e10**. Mainnet base fee
at probe time: **0.02 gwei** (block 76,802,574); OKB **$80.79** (CoinGecko
simple price). The creation bytecode compiled from the frozen source
(`forge inspect Pago bytecode`, 34,610 hex chars) was checked
byte-for-byte against the input of the successful 2026-11-25 testnet deploy
of the same source — identical.

### Fork deploy rehearsal — PASS

A local anvil fork of mainnet (chain 196, pinned block 76,802,574) was
deployed to with the exact constructor args above, sent as a raw
`eth_sendTransaction` from anvil's unlocked dev account (no private key
anywhere). Result:

- deploy tx (local fork only) `0x77dda1e7144ef72f2c3405d47e916bc635d04a2c576e3c08772dc03b8d3ad022`, status **0x1**
- contract `0xa82ff9afd8f496c3d6ac40e2a0f282e47488cfc9`, runtime **15,327 bytes**
- **gasUsed 3,554,000** (same order as the recorded quote `deployPago
  3,526,258 gas, $0.01`)
- `evaluatorPinned()` **true** with the recorded references; feeAccount /
  processor / circuitId correct; both caps 1e10, both decimals 6, `feeBps`
  50, `changeDetector` true
- runtime code contains `0xcf092995` (the fixed `uint256` selector) and
  **not** `0xd8fde8d5` (the old `uint64` one)

**Predicted mainnet runtime codehash:** all seven Pago immutables are
constructor parameters — none embeds `address(this)` — so the runtime code,
and hence its hash, is address-independent. The fork-deployed runtime hashes
to **`0x684a360f7560dfc77c2782f0309580fde43354521d669e7f6c5f535065d598ed`**
— this is what the real tier-1 deploy should produce, and it differs from
the superseded Pago's `0x175bafd0c7ac2d363bedbde2ac17ee8b12d4cd3e565028588f7aa95050f0305d`
because the selector fix changed the runtime code.

### Dollar estimate for step 8 (deploy only)

3,554,000 gas × 0.02 gwei base fee ≈ **0.000071 OKB ≈ $0.006**, i.e. **under
one cent** at the prices above — consistent with the recorded quote's $0.01.
No other spend is authorised: no BEM, no token purchase, and no mainnet
broadcast until `deploy to mainnet tier 1` arrives in full.

### Proves / does not prove

- **Proves:** the exact tier-1 constructor argument set compiles, encodes
  (15 words, offset `0x100`) and deploys cleanly against genuine X Layer
  mainnet state; the resulting contract is the fixed build (correct
  selectors, pinned evaluator, correct token config); the deploy costs about
  a cent; the predicted post-deploy codehash is recorded in advance.
- **Does not prove:** that mainnet was spent on (the rehearsal ran on a
  local fork only); what the real deploy address will be (CREATE address
  depends on the deployer nonce); that a gasless payment settles on mainnet
  — that is step 9, gated separately.

## 21. Step 8 — mainnet tier-1 deploy of the fixed build (2026-11-25)

Authorised by the exact phrase `deploy to mainnet tier 1` — the payment
contract only: no BEM purchase, no `createCPU`, no tape-out (those are tier 2).
Dollar estimate quoted before the send: 3,554,000 gas × 0.02 gwei ≈ 0.0000711
OKB ≈ **$0.006** at OKB $80.28 (CoinGecko), worst case ≈ $0.012 at the 0.04
gwei fee cap. The deployer held 0.001082488156794177 OKB (≈ $0.087).

### Preflight (read-only, all green)

- chainid **196**; gas price 20,000,001 wei; both tokens answer
  `decimals()` = 6.
- Every constructor argument was re-read **live from the superseded Pago**
  `0xd63Ae612Cf9Acb9Ac8F7801eF68E8e71068E492c` and matched §20's table
  exactly: feeAccount `0x7FCe520D…09b62`, processor `0xDd6BB6fb…2c2f4`,
  circuitId `1`, expectedProcessorCodehash `0x8c799a18…db545`,
  circuitBeacon `0xf70d1ed4…0991C`, circuitImplementation `0x977f2178…F29B2`,
  expectedImplementationCodehash `0x7a15c353…41b30`; `evaluatorPinned()`
  true, `feeBps` 50, both caps 1e10.
- References verified live: the processor's runtime codehash
  `0x8c799a18…db545` and the implementation's `0x7a15c353…41b30` (the public
  RPC does not serve `extcodehash`, so both were computed as
  keccak256(`cast code`)); the beacon's `implementation()` is the recorded
  `0x977f2178…F29B2`.
- The deployable bytes are the frozen build: `out/Pago.sol/Pago.json` (built
  2026-11-25 02:55, after the selector-fix commit `d8fe725`) carries
  `0xcf092995` and not `0xd8fde8d5`. `script/Pago.creation.hex` dates from
  2026-11-20, predates the fix, and was **not** used — its byte-equality
  check against the artifact correctly fails.
- **Prediction before spend:** the creation payload (artifact + ABI-encoded
  §20 args, posted as a JSON-RPC `eth_call`, never on an argv) returned
  runtime of **15,327 bytes** hashing to
  **`0x684a360f7560dfc77c2782f0309580fde43354521d669e7f6c5f535065d598ed`** —
  exactly §20's recorded prediction; fixed selector present, old absent; the
  constructor does not revert against live state.
- `forge create` dry run: exit 0, deployer nonce **17**, gas limit 3,583,502,
  predicted CREATE address **`0x2fC4180db7318F4364F6FC559A25359c9F537D3e`**.

### Broadcast (one send, plus one justified pre-send retry)

- Transport: `forge create src/Pago.sol:Pago --broadcast --account
  pago-deployer` — Foundry keystore signing with `ETH_PASSWORD` (a password
  file path); no private key on any command line or in any output.
- **The first attempt never reached the network:** DNS resolution failed
  connecting to `rpc.xlayer.tech` (the flaky upstream noted in
  `script/rehearse-castsend.ps1`), and the output contained no tx hash. The
  deployer nonce was re-read and still **17** before retrying — a send that
  provably never happened cannot have succeeded, so retrying does not break
  the never-resend rule.
- **Succeeded on the retry:**

  | Fact | Value |
  |---|---|
  | tx | `0x37683583826c0b16601ef067172287e767d7e788933da61a2f39296e51e98fe7` |
  | status | `0x1` |
  | block | 76,820,955 |
  | gasUsed | 3,554,000 — the rehearsal figure exactly |
  | effectiveGasPrice | 20,000,001 wei |
  | actual cost | 71,080,003,554,000 wei = 0.000071080003554 OKB ≈ **$0.0057** (matches the deployer balance delta exactly) |
  | contract | **`0x2fC4180db7318F4364F6FC559A25359c9F537D3e`** — equals the predicted CREATE address |

### Post-deploy verification (live reads)

| Check | Value |
|---|---|
| runtime code | 15,327 bytes |
| runtime codehash | `0x684a360f…d598ed` — **equals §20's pre-recorded prediction** |
| selectors | `0xcf092995` present, `0xd8fde8d5` absent |
| `evaluatorPinned()` | **true** from the first block |
| `changeDetector()` | true |
| `feeAccount` / `feeBps` | `0x7FCe520D…09b62` / 50 |
| `processor` / `circuitId` | `0xDd6BB6fb…2c2f4` / 1 |
| `expectedProcessorCodehash` | `0x8c799a18…db545` |
| `circuitBeacon` / `circuitImplementation` | `0xf70d1ed4…0991C` / `0x977f2178…F29B2` |
| `expectedImplementationCodehash` | `0x7a15c353…41b30` |
| `MAX_LINK_AMOUNT_UNPINNED` | 1e10 for USD₮0 and for USDG |
| `expectedDecimals` | 6 for USD₮0 and for USDG |

### Proves / does not prove

- **Proves:** the frozen fixed build is now the live mainnet Pago, deployed
  for ≈ $0.006, pinned (`evaluatorPinned()` true) against the recorded
  mainnet processor references from block one, with the corrected selector
  surface — and the real address equals the one predicted from
  (deployer, nonce) before the send.
- **Does not prove:** that a gasless payment settles on mainnet — that is
  step 9, gated on the exact phrase `send mainnet demo payment`; what a
  payer's screen showed (rule 4, unchanged).
