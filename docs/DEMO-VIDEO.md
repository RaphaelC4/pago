# Demo video — shot list, narration, and the wallet take

Target: **≤3:00**, the first artifact judges watch. Same spine the README
rewrite will use: **demand → problem → Pago → X Layer/TapeOut → impact →
business model → close.**

Honesty rules (they apply to the video exactly as they apply to the README):

- every product frame is the live site answering real `eth_call`s —
  recorded by `e2e/record-demo.mjs`, no mocks, no simulated clicks;
- signatures happen in the operator's wallet, on camera, in the browser —
  never scripted, never skipped;
- if a chain read fails, the shot is re-taken — nothing is edited around
  a state the chain did not report.

## Assets

| Asset | Source | State |
|---|---|---|
| 8 title cards (`c0-open` … `c7-end`) | `e2e/video/cards/*.png` | recorded by `node record-demo.mjs` |
| 7 product clips (`01-landing` … `07-tapeout`) | `e2e/video/clips/*.webm` | recorded by `node record-demo.mjs` |
| Wallet take (create → gasless sign → submit → claim) | Game Bar, your browser | **yours — runbook below** |
| Voiceover | script in this file | your voice, or free TTS |

Re-record anything with `node record-demo.mjs --only <name>` (from `e2e/`).
Clips that waited on the chain carry a `.marker.json` (`evidenceSec`) —
the edit cuts to that point so dead air never reaches the judges. The
marker clock starts when the claim-card wait begins, **~2-4s into the
clip** (after boot + health), so treat `evidenceSec` as a ballpark and
frame-check the exact moment the payout rows fill before cutting
(`ffmpeg -i clip.webm -ss T -frames:v 1` — output-side `-ss`, the
input-side form seeks to the wrong keyframe on Playwright's VP9).

## The timed script (~2:50)

Times are for the final cut; lock them with `ffprobe` after stitching.

| # | Visual | Narration |
|---|---|---|
| 0:00–0:08 | `c0-open` → `01-landing` (splash plays out, hero) | This is Pago — a payment request that's just a URL. But first, why it deserves to exist. |
| 0:08–0:26 | `c1-demand` → `c2-problem` | Money already moves in chat. Freelancers, renters, sellers — everyone gets asked "can you send me a link?", and then the other side is told to sign up for something, enter a card, and wait days. Today's payment links pull **both** sides into an account, hold the funds, and can reverse them. Cross-border, it gets worse: fees, chargebacks, a waiting game. |
| 0:26–0:52 | `c3-pago` → `02-create` → `03-share` | Pago collapses that to one link. You state the amount, the note, and an optional split — the form refuses to proceed until the shares total exactly one hundred percent. One signed transaction puts it on chain. The link holds no money, and there is nothing to log into. Share it: they open the URL, read the invoice straight from contract state, and pay from their wallet. |
| 0:52–1:30 | `04-pay-testnet` (rule-table receipt) | When it settles, the receipt doesn't come from our servers — it comes from the claim transaction's own events. This invoice settled **through the rule table**: the circuit checked the split, the payout pool was 0.995 after the flat half-percent fee, and each seat was paid exactly what the table said — 0.4975 to the payee, the rest to the other seats. Anyone can download the PDF or re-read the events themselves. |
| 1:30–2:02 | `c4-ecosystem` → `07-tapeout` → `05-pay-mainnet` | That check is why Pago belongs on X Layer. The split logic is a TapeOut-verified circuit — netlist hash, allowlisted processor, circuit id — pinned on mainnet and printed on every open invoice. And the settlement chain is X Layer itself: this is a real 0.1 USD₮0 payment, claimed on mainnet, its fee and payout read back from its own events. |
| 2:02–2:32 | **your wallet take** | In your own wallet: one signature creates the link. The payer then signs an authorization **off-chain** — no transaction, no gas for the signature — and anyone may submit it. The contract refuses a payee paying their own invoice; once it reads Paid, anyone can release the funds, and they can only ever go to the payee minus the fee. |
| 2:32–2:48 | `c5-impact` → `06-ledger` | What that means for real people: money arrives in minutes instead of banking days, no custodian can freeze it, no admin key can move it, and every payout is re-readable from chain state. The ledger starts empty — your wallet, your address, your history. Nothing pre-filled, nothing inferred. |
| 2:48–3:00 | `c6-model` → `c7-end` | The business model is one number: half a percent, taken only when money moves. Free to create, free to open, free to read. Try it — pago-nu.vercel.app. Pago, on X Layer, for TapeOut. |

## Your wallet take (~5 minutes, one sitting)

**Precondition:** `docs/FRONTEND-HANDOFF.md:207` — *Journey D must pass
before the demo video.* Run it first, off camera (`e2e/TESTNET.md`,
"Journey D"): create → approve + pay → claim → cancel. That pass also
proves the flow before you record it.

**Setup**

- Dedicated testnet wallet, chain **1952** (the page offers the switch),
  some testnet **OKB** for gas, `pUSD` is MOCK — the pay card mints it
  while your balance is short.
- **Two accounts**: `A` = payee (the wallet that creates), `B` = payer
  (the contract refuses the payee paying their own link).
- Recording: `Win+Alt+R` starts/stops Xbox Game Bar capture (check
  1080p in `Win+G` → Settings → Capturing first). Chrome maximized,
  100% zoom.

**The take** (total ≈ 4–5 min of footage; the edit keeps ~30s)

1. `https://pago-nu.vercel.app/#create` — **start recording.**
2. Connect wallet (**account A**) → approve the network switch if asked.
3. Amount `5`, note `Video demo — Pago`, expiry as-is → **Create link** →
   one signature. Share card appears — hold 3s (QR, payout split).
4. Copy the link. Switch the wallet to **account B**.
5. Open the copied `…#pay/<id>` in the same tab — reads **with no wallet
   connected** first (hold 2s: invoice renders read-only), then Connect.
6. If the balance is short, press **Mint 10 pUSD test tokens**.
7. **TapeOut shot — hold 4s:** scroll the Open card slowly past the rule
   card: *Rule · netlist hash · processor · Split3 circuit · Cap ·
   fallback*. This is the shot the claimed receipts cannot show (the rule
   card renders on Open invoices only).
8. **Gasless:** press **Sign payment authorization** → the wallet shows an
   EIP-712 signature request (sign it — no transaction, no gas) → the card
   now offers **Submit signed payment** → press it → one transaction → the
   card flips to **Paid**.
9. Press **Release … to the payee** (anyone may — B pressing it *is* the
   point) → the payout result fills from the claim events → hold the
   receipt + **Download PDF receipt** 3s.
10. **Stop recording** (`Win+Alt+R`).

Drop the resulting `.mp4` in `e2e/video/clips/` as `08-wallet.mp4`.

## Stitch (after the take)

```powershell
# from e2e/ — normalize each clip (trim 04/05: marker evidenceSec + ~3s
# of video-time is the fill; frame-check first), concat, check ≤ 3:00
ffmpeg -i video/clips/04-pay-testnet.webm -ss <fill-frame - 1> -c:v libx264 -crf 18 -pix_fmt yuv420p video/renders/04.mp4
# …same for the other clips… then:
ffmpeg -f concat -safe 0 -i video/renders/list.txt -c copy video/renders/pago-demo.mp4
ffprobe video/renders/pago-demo.mp4   # duration must read ≤ 00:03:00
```

Cards enter the concat as stills held for their narration beats
(`-loop 1 -t 2.5 -i c1-demand.png`). Voiceover is laid over the whole
timeline; captions optional but recommended (judges watch muted).

## After the run

1. README: the gasless browser click-through stops being *pending* —
   the take in step 8 is that run; update the wording to what was seen.
2. Google Form: access link, target users/GTM/revenue answers (drafted),
   processor `0xDd6BB6fbda8ee867EF838bbE56ebA7d1EcC2c2f4`, circuit ID `1`,
   video attached — before **Dec 7 2026 23:59 UTC**.
3. README rewrite (Claude) shares the story spine above.
