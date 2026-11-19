# Master prompt — the rules this build answers to

This file holds the parts of the project's master prompt that govern the
code, so every agent working in this repository can read the original text
rather than a paraphrase of it.

The full prompt is longer than what is recorded here; what follows was
pasted verbatim into the session on 2026-11-19. Anything not quoted below
should be treated as not yet recorded, not as absent from the prompt.

---

## Contract rules to implement and test (from the master prompt)

```
Contract rules to implement and test (from the master prompt):
1. claim(linkId) takes NO result arguments, anyone can call it, and it pays only the
   recipients and the fee account, never the caller.
2. The contract derives the rule inputs from its own state (due date vs block.timestamp,
   credited amount, fields fixed at creation). It calls the processor with a strict
   staticcall: gas-limited, exact return length, strict decoding. The output only selects
   among preset split tables fixed at link creation. A rule can never invent a split.
3. The default split is fixed at creation with no setter. If the processor reverts,
   returns malformed data, runs out of gas or fails a check, claim uses the default split.
   A link must never freeze.
4. terms(linkId) and termsHash. pay and payWithAuthorization take expectedTermsHash and
   revert on mismatch. This does NOT prove what the payer saw; don't claim it does.
5. createLink reverts if the circuit's netlist identity can't be read. Store its hash.
6. evaluatorPinned flag. [paraphrase, added 2026-11-18; updated same day to the
   two-leg form after the mainnet probe - docs/RESEARCH.md section 18] The flag may
   become true ONLY through a real onchain implementation check - never via the
   change detector: the constructor takes the expected processor shell codehash AND
   the circuit beacon AND the expected implementation codehash, requires code present
   at the processor whose extcodehash equals the shell reference, then calls the
   beacon's public implementation() getter and requires that address's extcodehash to
   equal the implementation reference. Both legs must pass; a reverting or wrong
   beacon fails the second leg. Name the known-answer check "changeDetector", never
   "pin"; it stays a public view and never sets the flag.
   If unpinned: cap every link at MAX_LINK_AMOUNT_UNPINNED[token] in base units.
   [Still a paraphrase: the original verbatim sentence has not been supplied.]
7. Token allowlist fixed at deploy. Store expected decimals as written by us. Never read
   decimals() at runtime for safety limits. The deploy script aborts on a mismatch.
8. No markPaid. Underpay reverts, overpay is credited, double pay reverts, the creator
   can't self-pay, and the fee leg is skipped if it rounds to zero.
9. One failing recipient must not block the others.
10. Fuzz and invariant tests: payouts + fee == credited; balance >= owed; status never
    goes backward.
```

---

## Mainnet approval gates

X Layer mainnet (chain 196) is **read-only** until one of these phrases is
given in full, exactly, case-sensitive, as a whole message. Partial messages
("go ahead", "yes", "ok") and picker selections never count.

| Phrase | Authorises |
|---|---|
| `deploy to mainnet tier 1` | the payment contract (Pago) only |
| `deploy to mainnet tier 2` | tier 1 **plus** the Split3 tape-out |
| `deploy to mainnet tier 3` | scope not recorded here — do not infer it |
| `send mainnet demo payment` | one demo payment on mainnet |

Until a phrase arrives: no mainnet broadcast, no spending real funds
(BEM, OKB or otherwise), and no purchase of either token. Any cost estimate
must be quoted in dollars before anything is bought.
