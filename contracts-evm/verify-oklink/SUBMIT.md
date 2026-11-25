# OKLink verification — mainnet Pago

Contract: **`0x2fC4180db7318F4364F6FC559A25359c9F537D3e`** (X Layer mainnet)
Form: <https://www.oklink.com/x-layer/evm/verify-contract-preliminary>

## Why these inputs are correct

- Compiler: **solc 0.8.28+commit.7893614a**, optimizer **enabled, 200 runs**, evmVersion **prague**, metadata bytecodeHash **ipfs** (from `foundry.toml` + artifact metadata).
- `Pago.input.json` (standard JSON, 2 sources, UTF-8 no BOM) was compiled locally with solc 0.8.28:
  - creation bytecode **byte-identical** to `out/Pago.sol/Pago.json`
  - deployed bytecode **byte-identical** to the artifact, and the artifact's creation code is a **prefix of deploy tx `0x37683583…98fe7`'s input** (proven)
  - `src/Pago.sol` keccak **`0x56d65a6326e2d66889943f57c3ffe0da8ab637d179bd1fa11db3ee2001a4163d`** matches the artifact metadata; `IRuleProcessor.sol` matches too
- `Pago.constructor-args.txt` = the 480 bytes appended after creation code in the deploy tx (960 hex chars, **no `0x` prefix**), decoded and matching RESEARCH §20.

## Fill in, step by step

1. Open the form URL above (network: X Layer, EVM).
2. **Contract address:** `0x2fC4180db7318F4364F6FC559A25359c9F537D3e`
3. **Compiler type:** `Solidity(StandardJsonInput)`
4. **Compiler version:** `v0.8.28+commit.7893614a` — confirmed present in the dropdown. Note: the version dropdown stays **disabled** until the address and compiler type are filled first. Do not pick a nearby version.
5. **Next.** On page 2:
   - **Standard JSON input:** upload/paste the contents of **`verify-oklink/Pago.input.json`** as-is (UTF-8; keep the non-ASCII characters in comments intact — do not retype it in an editor that changes encoding)
   - **Constructor arguments:** paste the contents of **`verify-oklink/Pago.constructor-args.txt`** (960 hex chars, no `0x`). If the field rejects it, prepend `0x`.
   - If asked separately: **optimizer enabled**, **runs 200** (already embedded in the JSON; only fill if the form shows the fields).
6. Submit and wait for the result. Success = the contract page switches from "Contract source code unverified" to verified / shows Read Contract.

## Fallback (only if StandardJsonInput is rejected)

- **Compiler type:** `Solidity(SingleFile)`
- **Source:** `verify-oklink/Pago.flat.sol` (973 lines, forge flatten)
- Same version v0.8.28, optimizer 200.
- Caveat: the flattened file's metadata tail differs from the deployed one (different source layout), so the explorer may report a bytecode mismatch — prefer Standard JSON.

## Files

| File | Role |
|---|---|
| `Pago.input.json` | primary — standard JSON input, locally proven byte-exact |
| `Pago.constructor-args.txt` | constructor args from the deploy tx |
| `Pago.flat.sol` | single-file fallback |
| `solc-out.json` | local compile proof, scratch — not for upload |

## After the explorer shows "verified"

OpenCode marks the README verified — **only after** the explorer itself displays verified.
