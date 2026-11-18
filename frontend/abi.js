/* Pago ABI codec — encoder, decoder and the function selectors the X Layer
   page needs.

   Why this file exists: the frontend is deliberately buildless (no bundler,
   no npm, no step that compiles anything), so it cannot import ethers or
   web3 to talk to an EVM contract. What the page actually needs is small and
   closed — a dozen functions, no delegatecalls, no events — so the encoding
   is written out here in full instead of pulling in a library.

   Every selector below was produced with `cast sig "<signature>"` and then
   cross-checked against the deployed Pago bytecode's own dispatcher on chain
   1952 (each 4-byte value appears as `63<selector>` in the runtime code). If
   Pago is ever redeployed with a changed signature, `cast sig` is the
   authority and these must be regenerated — the test in
   test/abi.test.mjs pins them.

   Test vectors for the encoder and decoder come from real `eth_call` return
   blobs captured against the live testnet deployment (see that test), so the
   decoder is checked against what the chain actually sends rather than
   against my own idea of the format.
 */

/* ── selectors ─────────────────────────────────────────────────────────── */

export const SEL = {
  // Pago
  createLink: "0x167f1e66", // createLink(string,uint256,address,string,uint64)
  pay: "0x901c5953", // pay(string,uint256)
  claim: "0xf3fe12c9", // claim(string)
  cancelLink: "0xc49dc85c", // cancelLink(string)
  getLink: "0x7476452a", // getLink(string)
  getLinksByCreator: "0x4afe4a95", // getLinksByCreator(address)
  linkCountByCreator: "0xc0f27021", // linkCountByCreator(address)
  linkExists: "0xa34cc22b", // linkExists(string)
  feeBps: "0x24a9d853", // feeBps()
  isTokenAllowed: "0xf9eaee0d", // isTokenAllowed(address)

  // ERC-20 / EIP-3009 (the test token and any allowlisted stablecoin)
  approve: "0x095ea7b3", // approve(address,uint256)
  allowance: "0xdd62ed3e", // allowance(address,address)
  balanceOf: "0x70a08231", // balanceOf(address)
  decimals: "0x313ce567", // decimals()
  symbol: "0x95d89b41", // symbol()
  name: "0x06fdde03", // name()

  /* Pago's own clock and the MOCK token's public faucet. `nowMs` matters:
     expiry is written in chain time, not the browser's, so a laptop with a
     skewed clock cannot create a link that is already expired. `mint` is
     test scaffolding on pUSD only — it is public by design and the page
     labels it as such. */
  nowMs: "0x6202306a", // nowMs()
  mint: "0x40c10f19", // mint(address,uint256)
};

/* ── ABI types ───────────────────────────────────────────────────────────
 *
 * A type is one of:
 *   "string" | "bytes"              dynamic byte sequences
 *   "bool" | "address" | "bytes32"  one 32-byte word
 *   "uint8" ... "uint256"           one 32-byte word
 *   [t1, t2, ...]                   a tuple (static unless a member is)
 *   { array: T }                    a dynamic-length array of T
 *   { struct: [[name, T], ...] }    a named tuple — same wire format as a
 *                                   plain tuple, but it decodes to an object
 *                                   and encodes from an object (or an array,
 *                                   for round trips)
 *
 * Tuples are plain arrays and arrays are objects, so a type expression stays
 * readable where it matters — the Link struct below.
 */

/** Pago's Link struct, in declaration order. Mirrors src/Pago.sol. */
export const LINK_TYPES = {
  struct: [
    ["linkId", "string"],
    ["creator", "address"],
    ["amount", "uint256"],
    ["token", "address"],
    ["description", "string"],
    ["createdAt", "uint64"],
    ["expiresAt", "uint64"],
    ["status", "uint8"],
    ["paidBy", "address"],
    ["paidAmount", "uint256"],
    ["paidAt", "uint64"],
    ["claimedAt", "uint64"],
  ],
};

/** `getLink(string)` returns (bool found, Link link). */
export const GET_LINK_TYPES = ["bool", LINK_TYPES];

/** `getLinksByCreator(address)` returns Link[]. */
export const GET_LINKS_TYPES = [{ array: LINK_TYPES }];

/** Status enum values, matching Pago's `enum Status`. */
export const STATUS = ["Open", "Paid", "Claimed", "Cancelled", "Expired"];

/* ── low-level helpers ─────────────────────────────────────────────────── */

const encoder = new TextEncoder();
const decoder = new TextDecoder();

function word(n) {
  const h = BigInt(n).toString(16);
  if (h.length > 64) throw new RangeError("value does not fit in 32 bytes: " + n);
  return h.padStart(64, "0");
}

function padRight(hex) {
  return hex + "0".repeat((64 - (hex.length % 64)) % 64);
}

function bytesToHex(bytes) {
  let s = "";
  for (const b of bytes) s += b.toString(16).padStart(2, "0");
  return s;
}

function isType(t) {
  return typeof t === "string" || Array.isArray(t) || (t && typeof t === "object");
}

function isDynamic(t) {
  if (Array.isArray(t)) return t.some(isDynamic);
  if (t && typeof t === "object") {
    if (t.struct) return t.struct.some(([, ty]) => isDynamic(ty));
    return true; // { array: T } — length is not known up front
  }
  return t === "string" || t === "bytes";
}

/** Size in bytes of a static type; null for a dynamic one. */
function staticSize(t) {
  if (Array.isArray(t)) {
    let n = 0;
    for (const m of t) {
      const s = staticSize(m);
      if (s === null) return null;
      n += s;
    }
    return n;
  }
  if (t && typeof t === "object") {
    if (t.struct) {
      let n = 0;
      for (const [, m] of t.struct) {
        const s = staticSize(m);
        if (s === null) return null;
        n += s;
      }
      return n;
    }
    return null; // { array: T }
  }
  if (t === "string" || t === "bytes") return null;
  if (t === "bool" || t === "address" || t === "bytes32" || /^u?int\d+$/.test(t)) return 32;
  throw new TypeError("unsupported ABI type: " + JSON.stringify(t));
}

/** A struct's member types, in declaration order. */
const structTypes = (t) => t.struct.map(([, ty]) => ty);

/**
 * A struct's values, in declaration order. Accepts an object keyed by field
 * name (what the decoder produces) or an array (what a round trip passes
 * back), so encoding and decoding are exact inverses.
 */
function structValues(t, v) {
  if (Array.isArray(v)) {
    if (v.length !== t.struct.length) {
      throw new TypeError(`expected ${t.struct.length} struct values, got ${v.length}`);
    }
    return v;
  }
  if (v && typeof v === "object") return t.struct.map(([name]) => v[name]);
  throw new TypeError("expected an object or array for a struct, got " + typeof v);
}

/* ── encoding ──────────────────────────────────────────────────────────── */

function encodeStatic(t, v) {
  if (Array.isArray(t)) return encodeTuple(t, v);
  if (t && typeof t === "object" && t.struct) return encodeTuple(structTypes(t), structValues(t, v));
  switch (t) {
    case "bool":
      return word(v ? 1 : 0);
    case "address": {
      if (typeof v !== "string" || !/^0x[0-9a-fA-F]{40}$/.test(v)) {
        throw new TypeError("not an address: " + JSON.stringify(v));
      }
      return word(BigInt(v));
    }
    case "bytes32": {
      if (typeof v !== "string" || !/^0x[0-9a-fA-F]{64}$/.test(v)) {
        throw new TypeError("not bytes32: " + JSON.stringify(v));
      }
      return v.slice(2).toLowerCase();
    }
    default:
      if (/^u?int\d+$/.test(t)) {
        const n = BigInt(v);
        if (n < 0n && t.startsWith("uint")) throw new RangeError("negative value for " + t);
        return word(n);
      }
      throw new TypeError("unsupported static type: " + t);
  }
}

function encodeDynamic(t, v) {
  if (Array.isArray(t)) return encodeTuple(t, v); // static or dynamic tuple body
  if (t && typeof t === "object" && t.struct) return encodeTuple(structTypes(t), structValues(t, v));

  if (t && typeof t === "object") {
    if (!Array.isArray(v)) throw new TypeError("expected an array for " + JSON.stringify(t));
    const inner = v.map(() => t.array);
    return word(v.length) + encodeTuple(inner, v);
  }

  if (t === "string") {
    /* TextEncoder coerces anything to a string, so a number in a string slot
       would encode happily and become a wrong-but-plausible invoice id on
       chain. Refuse it here instead. */
    if (typeof v !== "string") throw new TypeError("expected a string, got " + typeof v);
    const bytes = encoder.encode(v);
    return word(bytes.length) + padRight(bytesToHex(bytes));
  }
  if (t === "bytes") {
    if (typeof v !== "string") throw new TypeError("expected a hex string, got " + typeof v);
    const hex = String(v).replace(/^0x/, "");
    if (hex.length % 2) throw new TypeError("odd-length hex string");
    return word(hex.length / 2) + padRight(hex.toLowerCase());
  }
  throw new TypeError("unsupported dynamic type: " + t);
}

/** Encode a tuple: static members in place, dynamic members as offset+body. */
export function encodeTuple(types, values) {
  if (!Array.isArray(values) || values.length !== types.length) {
    throw new TypeError(
      `expected ${types.length} values, got ${Array.isArray(values) ? values.length : typeof values}`
    );
  }
  let headLen = 0;
  for (const t of types) headLen += isDynamic(t) ? 32 : staticSize(t);

  let head = "";
  let tail = "";
  for (let i = 0; i < types.length; i++) {
    const t = types[i];
    if (isDynamic(t)) {
      /* Offset is counted in bytes from the start of this tuple: headLen is
         already bytes, tail is hex so it needs /2. Adding the two halves
         before dividing — (headLen + tail.length) / 2 — is the classic slip
         here and would misplace every dynamic member in a tuple whose head
         is longer than one word. */
      head += word(headLen + tail.length / 2);
      tail += encodeDynamic(t, values[i]);
    } else {
      head += encodeStatic(t, values[i]);
    }
  }
  return head + tail;
}

/** `0x`-prefixed calldata for one function call. */
export function callData(selector, types, values = []) {
  if (!/^0x[0-9a-fA-F]{8}$/.test(selector)) throw new TypeError("bad selector: " + selector);
  return selector + encodeTuple(types, values);
}

/* ── decoding ──────────────────────────────────────────────────────────── */

function readWord(data, bytePos) {
  const start = 2 + bytePos * 2;
  const w = data.slice(start, start + 64);
  if (w.length !== 64) {
    throw new RangeError(`return data too short: wanted a word at byte ${bytePos}, have ${data.length}`);
  }
  return w;
}

function decodeStatic(t, data, bytePos) {
  if (Array.isArray(t)) return decodeTuple(t, data, bytePos);
  if (t && typeof t === "object" && t.struct) return decodeStruct(t, data, bytePos);
  const w = readWord(data, bytePos);
  switch (t) {
    case "bool":
      return BigInt("0x" + w) !== 0n;
    case "address":
      return "0x" + w.slice(24);
    case "bytes32":
      return "0x" + w;
    default:
      if (/^u?int\d+$/.test(t)) return BigInt("0x" + w);
      throw new TypeError("unsupported static type: " + t);
  }
}

function decodeDynamic(t, data, bytePos) {
  if (Array.isArray(t)) return decodeTuple(t, data, bytePos);

  if (t && typeof t === "object") {
    if (t.struct) return decodeStruct(t, data, bytePos); // offsets are struct-relative
    const len = Number(BigInt("0x" + readWord(data, bytePos)));
    return decodeTuple(new Array(len).fill(t.array), data, bytePos + 32);
  }

  if (t === "string" || t === "bytes") {
    const len = Number(BigInt("0x" + readWord(data, bytePos)));
    const start = 2 + (bytePos + 32) * 2;
    const hex = data.slice(start, start + len * 2);
    if (hex.length !== len * 2) throw new RangeError("return data too short for a " + len + "-byte value");
    if (t === "bytes") return "0x" + hex;
    const bytes = new Uint8Array(len);
    for (let i = 0; i < len; i++) bytes[i] = parseInt(hex.slice(i * 2, i * 2 + 2), 16);
    return decoder.decode(bytes);
  }
  throw new TypeError("unsupported dynamic type: " + t);
}

/** Decode a struct at `bytePos`, as an object keyed by field name. */
function decodeStruct(t, data, bytePos) {
  const values = decodeTuple(structTypes(t), data, bytePos);
  const out = {};
  for (let i = 0; i < t.struct.length; i++) out[t.struct[i][0]] = values[i];
  return out;
}

/**
 * Decode return data (0x-prefixed) as a tuple of `types`.
 *
 * `base` is the byte position the current tuple starts at: offsets inside a
 * tuple are relative to its own start, which is what makes a nested struct
 * or an array of structs decode correctly.
 */
export function decodeTuple(types, data, base = 0) {
  const out = [];
  let pos = 0;
  for (const t of types) {
    if (isDynamic(t)) {
      const offset = Number(BigInt("0x" + readWord(data, base + pos)));
      out.push(decodeDynamic(t, data, base + offset));
      pos += 32;
    } else {
      out.push(decodeStatic(t, data, base + pos));
      pos += staticSize(t);
    }
  }
  return out;
}

/** Decode the return data of a call whose outputs are `types`. */
export function decodeReturn(types, data) {
  if (typeof data !== "string" || !/^0x[0-9a-fA-F]*$/.test(data)) {
    throw new TypeError("not hex return data: " + JSON.stringify(data));
  }
  if (data === "0x") throw new RangeError("empty return data — is this the right contract?");
  return decodeTuple(types, data, 0);
}
