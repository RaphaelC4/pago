/* Paylink / Pago runtime configuration.
   Values are read from the built frontend. Kept as plain data so the page
   can be opened from a static host with no build step.

   There are two configuration blocks, because there are two builds of the
   same product:

     CONFIG — the original NEAR build (contracts/paylink-contract), still the
              one the deployed page talks to.
     XLAYER — the X Layer port, Pago (contracts-evm). Chain ids, RPCs,
              explorer, stablecoins, TapeOut addresses and Pago's own
              deployment slots all live here and nowhere else, so switching a
              page over to X Layer is one import rather than a hunt through
              the code.

   Every X Layer value below was read from the chain or proven on a fork
   (docs/RESEARCH.md). Anything that has not been verified is left out, and
   anything that has not happened yet is `null` — never a plausible-looking
   guess. */

export const CONFIG = {
  network: "testnet",
  /* rpc.testnet.near.org is deprecated: it answers 429 with no CORS headers, so
     the browser only ever sees "Failed to fetch". FastNEAR is the free testnet
     endpoint NEAR documents as its replacement. */
  rpcUrl: "https://test.rpc.fastnear.com",
  /* Read failover (Fix D): the same two alternates the Workers carry in
     wrangler RPC_URLS, so browser and backend fail over onto identical nodes.
     Both were CORS-checked against this origin and answer NEAR testnet status
     queries. Used only by the one permitted read retry - never by writes. */
  rpcUrls: ["https://near-testnet.drpc.org", "https://testnet-rpc.intea.rs"],
  explorer: "https://testnet.nearblocks.io",

  /* Paylink payment-link contract (v2: Tidepool sandbox USDC allowlist —
     paylink.testnet v1 kept usdc.fakes.testnet and cannot be re-inited). */
  contractId: "paylink-v2.testnet",

  /* Accepted NEP-141 token. Must be on the contract's allowlist, which is
     fixed at init — see contracts/paylink-contract/README.md. Tidepool's
     test USDC: the faucet drips it free and swaps settle into it. */
  tokenId: "usdc.tidepool-sandbox.testnet",

  /* Token display metadata — used for human-readable amounts only.
     On-chain the contract only ever sees the raw integer amount. */
  token: {
    symbol: "USDC",
    decimals: 6,
    label: "USDC (testnet)",
    /* Names a document may use for this same token. The contract id is the
       only thing that goes on chain; these exist so an invoice that says
       "USDC" is not rejected as a different asset. Deliberately does not
       list USDC.e — that is a different test token we do not accept. */
    aliases: ["USDC"],
    /* The token is a USDC test token: worth one dollar by definition.
       Real market prices are not needed by anything on this page. */
    usdPrice: 1,
  },

  /* Fee taken from the payout at `claim`, in basis points (50 = 0.5%).
     Mirrors FEE_BPS in the contract, which also exposes `fee_bps()` so this
     number can be checked against the chain rather than trusted. */
  feeBps: 50,
  feeAccount: "paylink-fees.testnet",

  /* Indicative naira line under the dollar figure on the pay card — the
     Lagos story, on screen. Free, keyless, CORS-enabled public FX reference
     (no account, no quota). Display only: if the fetch fails the line stays
     hidden and the pay flow never notices. */
  fx: {
    url: "https://open.er-api.com/v6/latest/USD",
    quote: "NGN",
  },

  /* Invoice parsing proxy (Cloudflare Worker in workers/parse/).
     Empty string = the "paste a payment request" block stays hidden. The Worker
     holds the Gemini key; this file never does. Set this to the Worker URL
     after deploying it — see README.md. */
  parseEndpoint: "https://paylink-parse.g32772584.workers.dev",

  /* Meta-transaction relayer (NEP-366, Cloudflare Worker in workers/relayer/).
     When set, creating a link signs a delegate action off-chain and POSTs it
     here: the relayer pays the gas AND the 0.01 NEAR stake, so the payee's
     NEAR balance never moves. Empty string = dev escape hatch: the create
     form sends the direct wallet transaction (payee pays), which is also the
     path taken by wallets with no signDelegateActions. The deployed Worker
     only accepts requests from this site's origin — see workers/relayer/. */
  relayer: {
    endpoint: "https://paylink-relayer.g32772584.workers.dev/submit",
  },

  /* Tidepool — community testnet sandbox of the NEAR 1Click API.
     Keyless, free: the faucet drips test tokens and quotes settle swaps
     into the allowlisted USDC. Fail-closed everywhere in app.js. */
  tidepool: {
    origin: "https://www.usetidepool.tech",
    verifier: "verifier.tidepool-sandbox.testnet",
  },

  /* Paylink Tidepool Worker (workers/tidepool/) — the browser's ONLY
     cross-chain payment endpoint. Discovery (/networks), quotes (/quote)
     and payment status (/status) all go here; the page never calls
     Tidepool directly for anything payment-related. Empty string = the
     cross-chain payment option is hidden (same convention as
     parseEndpoint). Set this to the Worker URL after deploying it —
     see workers/OPERATIONS.md. */
  tidepoolWorker: {
    endpoint: "https://paylink-tidepool.g32772584.workers.dev",
  },
};

/* 1 yoctoNEAR, required by NEP-141 state-changing calls and by `claim`. */
export const ONE_YOCTO = "1";

/* Storage stake the contract demands on `create_link`
   (CREATE_STORAGE_STAKE in lib.rs = 0.01 NEAR). */
export const CREATE_STAKE = "10000000000000000000000";

/* Longest note `create_link` accepts (MAX_DESCRIPTION_LEN in lib.rs = 280).
   The contract counts UTF-8 BYTES via `String::len()`, not characters. */
export const MAX_DESCRIPTION_BYTES = 280;

/* Gas, in gas units (1 Tgas = 10^12).
   50  Tgas — plain calls: create_link, view-driven writes.
   200 Tgas — `claim`, which queues two ft_transfers (15 each), the on_claimed
              callback (10) and still executes its own state writes.
   150 Tgas — `ft_transfer_call`, which must fund the token's ft_transfer
              plus the receiver's `ft_on_transfer` (NEP-141 reserves 10
              Tgas for the receiver). */
export const GAS_DEFAULT = "50000000000000";
export const GAS_CLAIM = "200000000000000";
export const GAS_FT_CALL = "150000000000000";

/* ═════════════════════════════════════════════════════════════════════════
   X Layer — the Pago port.

   Read live from chain or proven on a local fork; docs/RESEARCH.md is the
   evidence for every line. Nothing here is copied from documentation,
   which for TapeOut in particular was found to be stale.
   ═════════════════════════════════════════════════════════════════════════ */
export const XLAYER = {
  mainnet: {
    chainId: 196,
    /* Official endpoints, in order of preference. The RPC intermittently
       fails DNS on this network, so the page keeps two and falls back. */
    rpcUrls: ["https://rpc.xlayer.tech", "https://xlayerrpc.okx.com"],
    explorer: "https://www.oklink.com/xlayer",
    nativeCurrency: { name: "OKB", symbol: "OKB", decimals: 18 },
  },

  testnet: {
    chainId: 1952,
    /* The only X Layer testnet endpoint that resolves. testnet.rpc.xlayer.tech,
       rpc.testnet.xlayer.tech and xlayertestrpc.okx.com all fail DNS, and some
       X Layer docs print chain id 195 for the testnet — `cast chain-id`
       answers 1952, which is what this page must request. */
    rpcUrls: ["https://testrpc.xlayer.tech"],
    explorer: "https://www.oklink.com/xlayer-test",
    nativeCurrency: { name: "OKB", symbol: "OKB", decimals: 18 },
  },

  /* Stablecoins Pago accepts. Both proven in Phase 0 to implement EIP-3009
     `transferWithAuthorization` on mainnet (RESEARCH.md §8): a third party may
     submit the signed authorization — which is what makes Pago's gasless payer
     path possible — and a signature naming any other recipient fails to
     recover `from`. Decimals and symbols read from each contract. */
  tokens: [
    {
      address: "0x779Ded0c9e1022225f8E0630b35a9b54bE713736",
      symbol: "USD₮0",
      name: "USD₮0",
      decimals: 6,
      eip3009: true,
    },
    {
      address: "0x4ae46a509F6b1D9056937BA4500cb143933D2dc8",
      symbol: "USDG",
      name: "Global Dollar",
      decimals: 6,
      eip3009: true,
    },
  ],

  /* TapeOut protocol, mainnet only: nothing from this block exists on
     testnet 1952 (RESEARCH.md §13). */
  tapeout: {
    factory: "0x1f09DAeFA827f02CBb40967cc91b259763760761",
    factoryOwner: "0xB3D85b42A045c1A88D800CAD0F55d2566a4D3138",
    protocolWallet: "0x571d447f4f24688eC35Ccf07f1D6993655F6aF15",

    /* The protocol's fee token. createCPU pulls this with transferFrom, so a
       caller must approve it first — never send msg.value (RESEARCH.md §13). */
    feeToken: {
      address: "0x60e62efa9405d6873c5deabd4e6cc91c25363952",
      symbol: "BEM",
      decimals: 8,
    },
    createProcessorFee: 10_000_000, // 0.1 BEM
    mintTransistorFee: 1_000_000, // 0.01 BEM

    /* Tape-out price, read live (published figures were stale). */
    tapeoutFeeWei: "1300000000000000", // 0.0013 native coin (OKB — not ETH)

    /* Container opener, proven end to end in Phase 0 (test/Container.t.sol). */
    opener: "0x536adD8F30f03b69f6fbF29d425A816A0dC50106",
    openerFeeWei: "80000000000000000", // 0.08 ETH, read live

    /* Processors Pago reads today. Each address was pulled from the factory's
       own `cpuAt(id)` and then called directly (RESEARCH.md §2, §6). */
    processors: [
      { id: 30, address: "0x2046aa63bFB03f393AD85a518011fdf8aF3DDB53" },
      { id: 333, address: "0xE2a6c6393b5A8B99cb481035eB8e244C66641cd7" },
      { id: 334, address: "0x00586A4C37039aCbFC6aC135cAdd49367ABf390A" },
      { id: 340, address: "0x9de448A1CE9537d24199B3b5355239d73aA6F591" },
    ],
  },

  /* Pago's own contracts. `null` = not deployed yet.
     testnet below was written from a completed end-to-end run of
     contracts-evm/script/testnet-exercise.ps1 on chain 1952: create -> pay ->
     gasless pay -> claim, both legs, with the split verified to the unit
     (RESEARCH.md §15). Mainnet stays null until a mainnet deploy is approved. */
  pago: {
    testnet: {
      chainId: 1952,
      rpc: "https://testrpc.xlayer.tech",
      explorer: "https://www.oklink.com/xlayer-test",

      /* Deployed by `forge script script/Deploy.s.sol:Deploy`, recorded in
         contracts-evm/.testnet-deploy.json and read back from chain with
         `cast code` (oklink is unreachable from this machine, so the explorer
         check falls back to direct reads - disclosed in RESEARCH.md §17):
         Pago has 14,679 bytes of code, the token 4,117, the stand-in 2,779,
         the mock beacon 240.
         Rule 6 state of this deployment, read live: evaluatorPinned false -
         "unpinned, capped". Leg 1 compares the stand-in shell against the
         recorded TapeOut shell reference (0x57aa306f...17d5) and fails, as it
         must; leg 2's mock beacon reports the stand-in; changeDetector true
         (behaviour evidence only). Every link is capped at
         MAX_LINK_AMOUNT_UNPINNED. */
      pago: "0x773A8dddc01d623a0E19df2E67F8e6FC70523b88",
      token: "0x5D00e40242B75Fe964F0a1f59D9C8Ee7A04F8e87",

      /* The testnet asset is MockToken promoted to a real deployable: an
         ERC-20 with EIP-3009, which is what the gasless path needs. 6
         decimals, read from the contract.

         MOCK — not a stablecoin. Nothing backs pUSD; anyone can call its
         public `mint`. It exists only so the payment path can be exercised
         on testnet. Every surface that shows this token must render it as
         "pUSD (MOCK)" — see `tokenIsMock`, which the UI reads rather than
         guessing. */
      tokenSymbol: "pUSD",
      tokenDecimals: 6,
      tokenIsMock: true,

      /* Explorer permalinks, both confirmed to open in a browser. */
      pagoExplorerUrl: "https://www.oklink.com/xlayer-test/address/0x773A8dddc01d623a0E19df2E67F8e6FC70523b88",
      tokenExplorerUrl: "https://www.oklink.com/xlayer-test/address/0x5D00e40242B75Fe964F0a1f59D9C8Ee7A04F8e87",

      /* Both read live after deploy: `feeBps()` answered 50 (0.5%) and the
         fee account is the deployer itself. */
      feeBps: 50,
      feeAccount: "0x3f1004AAeD662227d535D794dA679110111a2FC4",

      /* Two keystore aliases, created in the operator's own terminal so the
         keys never enter this repo. The payer must differ from the link
         creator, which is why there are two accounts rather than one.
         Deployer: deploys, pays leg A, signs leg B, collects the fee.
         Payee: creates links, relays leg B, claims. */
      deployer: "0x3f1004AAeD662227d535D794dA679110111a2FC4",
      payee: "0x7FCe520D881454EA234d371E1256B75843609b62",
    },

    mainnet: null,
  },

  /* The Split3 payment rule, once it is taped out onto a processor.
     `null` = not taped out: it needs mainnet approval and roughly 0.11 BEM
     plus 0.0013 native OKB (RESEARCH.md §14), which has deliberately not been
     spent. The shape below is fixed by the circuit itself. */
  split3: {
    processor: null,
    circuitId: null,
    inputs: 15, // three 5-bit shares
    outputs: 1, // "the shares add up to 100%"
    nands: 104,
    shareStepBps: 500, // each share is counted in 5% steps
  },
};
