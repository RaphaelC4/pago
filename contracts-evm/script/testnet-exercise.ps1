# Pago on X Layer testnet — deploy, then settle two real invoices end to end.
#
# What it proves, on chain 1952, with real transactions:
#
#   leg A  the ordinary payer path   create -> approve -> pay -> claim
#                                    rule split VALID (10+6+4 = 20 steps)
#   leg B  the gasless payer path    create -> off-chain EIP-3009 signature ->
#                                    a *third party* submits it and pays the gas
#                                    -> claim
#                                    rule split INVALID (10+8+5 = 23 steps)
#
# Which table each claim pays is decided by rule 6's LIVE check (the master
# prompt's "verify both at claim"): `claim` re-runs the two-leg check inside
# the same transaction and only asks the circuit when it passes.
#
# This script reads evaluatorPinned() and BRANCHES its expectations - it
# never assumes which deploy it is talking to:
#
#   PINNED   the MOCK-pinned testnet copy: leg 1's reference is the MOCK
#            stand-in's own codehash, so the check passes and the rule path
#            pays live. (Mainnet uses the recorded TapeOut references.)
#              leg A rule table pays: payee 497,500 + fee seat 497,500
#              leg B falls back:      payee 995,000 (its 10/8/5 = 23 steps)
#              payee    +1,492,500
#              deployer -1,492,500  (two 1,000,000 payments + 497,500 rule
#                                    seat + 2 x 5,000 fees collected)
#
#   UNPINNED the honest failure-path copy: leg 1's reference is the recorded
#            TapeOut shell, which the stand-in can never match, so the check
#            fails and BOTH legs settle through the DEFAULT table:
#              payee    +1,990,000  (995,000 default x 2)
#              deployer -1,990,000  (two 1,000,000 payments + 2 x 5,000 fees;
#                                    no rule seat while unpinned)
#
#   in both modes: Pago holds exactly what it held before, and the three
#   deltas must sum to zero - nothing created, nothing lost.
#
# Signing: two Foundry keystore aliases, created in YOUR terminal so the keys
# never enter this repository or this conversation. This script only ever
# passes `--account <alias>` to cast/forge.
#
#   cast wallet import pago-deployer     # deployer, payer, fee account
#   cast wallet import pago-payee        # creates links, relays, claims
#
# Funding: ONE faucet claim is enough. Fund `pago-deployer` with ~0.02 OKB
# and the script sends a slice across to `pago-payee` itself — the whole run
# costs about 0.0001 OKB at the testnet's 20 gwei gas price.
#
# The token is pUSD — MOCK. It is a freely mintable test token with no
# backing and no redemption value, deployed by Deploy.s.sol purely so the
# payment path can be exercised. Every amount below is fake money.
#
# Passwords: cast prompts for the keystore password each time it signs. To run
# without prompts, put `ETH_PASSWORD=<password>` in the repository's .env —
# that file is gitignored and this script never prints it.
#
# Usage (from anywhere):
#   powershell -File contracts-evm/script/testnet-exercise.ps1
#
# Nothing here touches mainnet: the RPC defaults to the testnet endpoint and
# the chain id is asserted to be 1952 before a single transaction is sent.

$ErrorActionPreference = "Stop"

$Rpc = if ($env:XLAYER_RPC) { $env:XLAYER_RPC } else { "https://testrpc.xlayer.tech" }

# cast and forge read ETH_RPC_URL when a command carries no --rpc-url. Without
# it they fall back to http://localhost:8545, which is why every bare `cast
# call` below failed with "failed to retrieve chain ID from fork endpoint"
# (foundry.toml's [rpc_endpoints] xlayer alias is only reachable as `--rpc-url
# xlayer`, so setting XLAYER_RPC does not help). The chain id assertion further
# down still refuses anything that is not 1952.
$env:ETH_RPC_URL = $Rpc
$DeployerAlias = if ($env:PAGO_DEPLOYER_ALIAS) { $env:PAGO_DEPLOYER_ALIAS } else { "pago-deployer" }
$PayeeAlias = if ($env:PAGO_PAYEE_ALIAS) { $env:PAGO_PAYEE_ALIAS } else { "pago-payee" }

$Root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent   # repository root
$EvmDir = Join-Path $Root "contracts-evm"
# Where a successful deploy is remembered, so a re-run after a mid-flow
# failure continues from the same contracts instead of deploying new ones.
$DeployFile = Join-Path $EvmDir ".testnet-deploy.json"

# ── helpers ────────────────────────────────────────────────────────────────

# Load .env without printing any of it. Only fills variables that are not
# already set, so the shell wins.
$EnvFile = Join-Path $Root ".env"
if (Test-Path $EnvFile) {
    Get-Content $EnvFile | ForEach-Object {
        $line = $_.Trim()
        if ($line -and -not $line.StartsWith("#") -and $line.Contains("=")) {
            $eq = $line.IndexOf("=")
            $key = $line.Substring(0, $eq).Trim()
            $val = $line.Substring($eq + 1).Trim()
            if (-not [Environment]::GetEnvironmentVariable($key)) {
                [Environment]::SetEnvironmentVariable($key, $val)
            }
        }
    }
}

# $ErrorActionPreference = "Stop" (set above) turns a native command's stderr
# into a terminating error, which would escape the loop below and kill the run
# on the first flaky RPC response - exactly what happened before this try/
# catch existed. Catch it here so the retries actually happen.
function Run-Retry {
    param([string]$What, [scriptblock]$Cmd)
    for ($i = 1; $i -le 6; $i++) {
        $out = ""
        try {
            $out = & $Cmd 2>&1 | Out-String
            if ($LASTEXITCODE -eq 0) { return $out.Trim() }
        } catch {
            $out = $_.Exception.Message
        }
        if ($i -eq 6) {
            throw "FAILED after 6 attempts: $What`n$out"
        }
        Write-Host ("  retry {0}/6: {1}" -f $i, $What) -ForegroundColor DarkYellow
        Start-Sleep -Seconds 5
    }
}

function Send-Tx {
    param([string]$What, [scriptblock]$Cmd)
    $out = Run-Retry $What $Cmd
    $hash = $null
    try { $hash = ($out | ConvertFrom-Json).transactionHash } catch { }
    if (-not $hash -and $out -match "0x[0-9a-fA-F]{64}") { $hash = $Matches[0] }
    Write-Host ("  ok  {0}" -f $What) -ForegroundColor Green
    if ($hash) { Write-Host ("      tx {0}" -f $hash) -ForegroundColor DarkGray }
    return $hash
}

function Call {
    param([string]$What, [scriptblock]$Cmd)
    $out = Run-Retry $What $Cmd
    # cast annotates a large integer with its own human-readable hint -
    # `1010000000 [1.01e9]` - and a later [bigint] cast throws on the whole
    # string. Strip it once here rather than at every call site. It never
    # appears on addresses, hex digests or plain small numbers, and Send-Tx
    # goes through Run-Retry directly, so JSON arrays stay untouched.
    return ($out -replace "\s+\[[^\]]*\]$", "")
}

# ── preflight ──────────────────────────────────────────────────────────────

Write-Host "Pago -> X Layer testnet" -ForegroundColor Cyan
Write-Host ("  rpc     {0}" -f $Rpc)
Write-Host ("  aliases {0} / {1}" -f $DeployerAlias, $PayeeAlias)
Write-Host "  token   pUSD (MOCK - a mintable test token, not a stablecoin)" -ForegroundColor DarkYellow

foreach ($alias in @($DeployerAlias, $PayeeAlias)) {
    $ks = Join-Path $env:USERPROFILE ".foundry\keystores\$alias"
    if (-not (Test-Path $ks)) {
        throw "no keystore named '$alias'. Create it in your own terminal with:`n`n  cast wallet import $alias`n`nThe key is typed there and never leaves that prompt."
    }
}

$chainId = Call "chain id" { cast chain-id --rpc-url $Rpc }
if ($chainId -ne "1952") {
    throw "refusing to continue: chain id is $chainId, expected 1952 (X Layer testnet)."
}
Write-Host ("  chain   {0} (testnet, confirmed)" -f $chainId) -ForegroundColor Green

foreach ($alias in @($DeployerAlias, $PayeeAlias)) {
    $addr = Call "$alias address" { cast wallet address --account $alias }
    Set-Variable -Name ("ADDR_" + ($alias -replace "-", "_")) -Value $addr
    # cast balance reports wei unless --ether is passed, so convert here
    # rather than print a raw integer next to the word "OKB".
    $balWei = [bigint](Call "$alias balance" { cast balance $addr --rpc-url $Rpc })
    $balOkb = [decimal]$balWei / [decimal]1000000000000000000
    Write-Host ("  {0,-16} {1}  OKB {2}" -f $alias, $addr, $balOkb)
    if ($alias -eq $DeployerAlias -and $balWei -le 0) {
        throw "$DeployerAlias holds no testnet OKB. Fund it with ~0.001 OKB, then re-run."
    }
    if ($alias -eq $PayeeAlias -and $balWei -le 0) {
        Write-Host "      (no OKB yet - the deployer will top it up below, so one faucet claim is enough)" -ForegroundColor DarkYellow
    }
}

$Deployer = $ADDR_pago_deployer
$Payee = $ADDR_pago_payee
Write-Host ""

# ── 1. give the second account gas ─────────────────────────────────────────

# Both accounts send transactions (the deployer deploys and pays, the payee
# creates links, relays and claims), so both need OKB. Rather than requiring
# two faucet claims, the deployer sends a slice across.
#
# Counted in wei because `cast balance` returns wei: comparing that raw number
# against an OKB figure would pass for any balance at all, and then the transfer
# below would fail for lack of funds. 1 OKB = 10^18 wei on X Layer, measured.
$WeiPerOkb = [bigint]1000000000000000000
$payeeWei = [bigint](Call "payee OKB" { cast balance $Payee --rpc-url $Rpc })
$deployerWei = [bigint](Call "deployer OKB" { cast balance $Deployer --rpc-url $Rpc })

# The payee sends five transactions (two creates, one relay, two claims) and
# the deployer four plus two contract deployments - about 0.0001 OKB together
# at the testnet's 20 gwei. Send 0.0003 and keep 0.0006 back, leaving each
# side roughly a dozen times what it needs.
$TopupWei = 3 * $WeiPerOkb / 10000       # 0.0003 OKB, what the payee receives
$ReserveWei = 6 * $WeiPerOkb / 10000     # 0.0006 OKB, what the deployer keeps
$MinPayeeWei = 1 * $WeiPerOkb / 10000    # 0.0001 OKB, below this it needs more

if ($payeeWei -lt $MinPayeeWei) {
    if ($deployerWei -ge ($TopupWei + $ReserveWei)) {
        Write-Host ("topping up {0} with 0.0003 OKB from the deployer..." -f $PayeeAlias) -ForegroundColor Cyan
        Send-Tx "send 0.0003 OKB to $PayeeAlias" {
            # cast requires an explicit unit here - a bare `0.0003` fails to parse,
        # as does `eth`; only `ether` or a raw wei integer is accepted.
        cast send $Payee --value 0.0003ether --account $DeployerAlias --rpc-url $Rpc --json
        } | Out-Null
    } else {
        throw ("{0} has only {1} OKB but needs 0.0009 OKB free (0.0003 to send plus 0.0006 to keep). Fund it with ~0.001 OKB and re-run." -f $DeployerAlias, ([decimal]$deployerWei / [decimal]$WeiPerOkb))
    }
}

# ── 2. deploy ──────────────────────────────────────────────────────────────

$Pago = $env:PAGO
$Token = $env:PAGO_TOKEN

# Reuse a previous deployment unless the environment says otherwise: a run
# that fails halfway should be repeatable without scattering contracts.
if ((-not $Pago -or -not $Token) -and (Test-Path $DeployFile)) {
    $saved = Get-Content $DeployFile -Raw | ConvertFrom-Json
    if (-not $Pago) { $Pago = $saved.Pago }
    if (-not $Token) { $Token = $saved.Token }
    Write-Host ("reusing deployment from {0}" -f $DeployFile) -ForegroundColor DarkYellow
}

if (-not $Pago -or -not $Token) {
    Write-Host "deploying Pago (and its test token)..." -ForegroundColor Cyan
    if (-not $env:PAGO_DEPLOYER) { $env:PAGO_DEPLOYER = $Deployer }
    if (-not $env:PAGO_FEE_ACCOUNT) { $env:PAGO_FEE_ACCOUNT = $Deployer }
    $deployOut = Run-Retry "forge script Deploy" {
        Set-Location $EvmDir
        forge script script/Deploy.s.sol:Deploy --rpc-url $Rpc --account $DeployerAlias --broadcast
    }
    Set-Location $EvmDir
    if ($deployOut -match "Pago deployed at:\s*(0x[0-9a-fA-F]{40})") { $Pago = $Matches[1] }
    if ($deployOut -match "deployed test token \(pUSD[^)]*\):\s*(0x[0-9a-fA-F]{40})") { $Token = $Matches[1] }
    Write-Output $deployOut
    if ($Pago -and $Token) {
        @{ Pago = $Pago; Token = $Token; ChainId = 1952 } | ConvertTo-Json | Set-Content $DeployFile
        Write-Host ("  remembered in {0}" -f $DeployFile) -ForegroundColor DarkGray
    }
}
Set-Location $EvmDir

if (-not $Pago -or -not $Token) {
    throw "could not determine the Pago/token addresses. Set `$env:PAGO and `$env:PAGO_TOKEN, or let this script deploy."
}

$codeLen = (Call "Pago code" { cast code $Pago --rpc-url $Rpc }).Length
Write-Host ("  Pago  {0}  ({1} hex chars of code)" -f $Pago, $codeLen) -ForegroundColor Cyan
if ($codeLen -le 2) { throw "no contract code at $Pago" }

# Rule 6 evidence, read straight from the deployment. Two legs: (1) the
# processor's codehash vs the stored shell reference, (2) the circuit beacon's
# implementation() answer vs the stored implementation address AND its codehash.
# Which reference leg 1 holds decides the mode, and the mode decides the
# expectations further down - the script never assumes. The processor is an
# EVM stand-in, NOT hardware - TapeOut exists only on mainnet. References:
# docs/RESEARCH.md sections 17 (testnet) and 18 (recorded mainnet values).
$processor = Call "processor" { cast call $Pago "processor()(address)" }
$pinned = Call "evaluatorPinned" { cast call $Pago "evaluatorPinned()(bool)" }
$expectedCodehash = Call "leg 1 reference" { cast call $Pago "expectedProcessorCodehash()(bytes32)" }
$beacon = Call "circuit beacon" { cast call $Pago "circuitBeacon()(address)" }
$expectedImpl = Call "leg 2 reference" { cast call $Pago "expectedImplementationCodehash()(bytes32)" }
$changeDetector = Call "changeDetector" { cast call $Pago "changeDetector()(bool)" }

if ($pinned -eq "true") {
    $Mode = "pinned"
    $leg1Label = "MOCK stand-in codehash (testnet pin reference - mainnet uses the recorded TapeOut references)"
} elseif ($pinned -eq "false") {
    $Mode = "unpinned"
    $leg1Label = "recorded TapeOut shell codehash (the stand-in can never match it)"
} else {
    throw "evaluatorPinned returned '$pinned', neither true nor false. Inspect the deployment before going further."
}

Write-Host ("  processor {0}  (EVM stand-in for the TapeOut processor - not hardware)" -f $processor) -ForegroundColor DarkYellow
Write-Host ("  leg 1 shell reference {0}  ({1})" -f $expectedCodehash, $leg1Label) -ForegroundColor DarkGray
Write-Host ("  circuit beacon {0}  (MOCK beacon reporting the stand-in)" -f $beacon) -ForegroundColor DarkGray
Write-Host ("  leg 2 implementation reference {0}" -f $expectedImpl) -ForegroundColor DarkGray
Write-Host ("  evaluatorPinned {0}  (mode: {1})" -f $pinned, $Mode) -ForegroundColor Green
Write-Host ("  changeDetector {0}  (behaviour evidence only - never what sets the flag)" -f $changeDetector) -ForegroundColor DarkGray

# ── 3. fund the payer with test tokens ─────────────────────────────────────

$Amount = 1000000            # 1.00 pUSD, 6 decimals
$Mint = 10000000             # 10.00 pUSD to play with
$FeeBps = [int](Call "fee bps" { cast call $Pago "feeBps()(uint256)" })

Write-Host ("`nfunding the payer: mint {0} pUSD -> {1}" -f $Mint, $Deployer) -ForegroundColor Cyan
Send-Tx "mint pUSD" { cast send $Token "mint(address,uint256)" $Deployer $Mint --account $DeployerAlias --rpc-url $Rpc --json } | Out-Null

# Snapshot taken after the mint and before any link exists. Every check at the
# end is a *change* from here, so a re-run after a partial failure measures
# exactly what this run did rather than everything that has ever happened.
$payeeBefore = [bigint](Call "payee pUSD" { cast call $Token "balanceOf(address)(uint256)" $Payee })
$deployerBefore = [bigint](Call "deployer pUSD" { cast call $Token "balanceOf(address)(uint256)" $Deployer })
$heldBefore = [bigint](Call "pUSD held by Pago" { cast call $Token "balanceOf(address)(uint256)" $Pago })

# Fresh link ids per run: a link id is one-time use, so reusing a fixed name
# would make the second attempt revert with "link id already used".
$stamp = Get-Date -Format "yyMMdd-HHmmss"
$IdA = "pago-$stamp-a"
$IdB = "pago-$stamp-b"

# The two preset split tables every link carries (contract rules 2 and 3):
#   default — who always gets paid; shares must sum to exactly 20 steps (100%)
#   rule    — the candidate the Split3 circuit judges at claim; its sum is the
#             verdict, so 20 passes and 23 is rejected by the hardware
# Both are passed to createLink as (address[3],uint8[3]) tuples.
$Z = "0x0000000000000000000000000000000000000000"
$DefSplit = '(["{0}","{1}","{2}"],[20,0,0])' -f $Payee, $Z, $Z          # payee 100%
$RuleSplitOk = '(["{0}","{1}","{2}"],[10,6,4])' -f $Payee, $Deployer, $Deployer   # 20 steps: accepted
$RuleSplitBad = '(["{0}","{1}","{2}"],[10,8,5])' -f $Payee, $Deployer, $Deployer  # 23 steps: rejected
$CreateSig = "createLink(string,uint256,address,string,uint64,(address[3],uint8[3]),(address[3],uint8[3]))"

# ── 4. leg A: the ordinary payer path ──────────────────────────────────────

Write-Host "`nleg A - ordinary pay (payer sends the transaction)" -ForegroundColor Cyan
Send-Tx "createLink $IdA" {
    cast send $Pago $CreateSig $IdA $Amount $Token "live test: ordinary payer path" 0 $DefSplit $RuleSplitOk `
        --account $PayeeAlias --rpc-url $Rpc --json
} | Out-Null
Send-Tx "approve" {
    cast send $Token "approve(address,uint256)" $Pago ([uint64]::MaxValue) --account $DeployerAlias --rpc-url $Rpc --json
} | Out-Null
# Terms consent (rule 4): pay demands the hash of everything this payer is
# agreeing to, read from the chain — fetched after createLink, before pay.
$termsA = Call "termsHash($IdA)" { cast call $Pago "termsHash(string)(bytes32)" $IdA }
Write-Host ("  termsHash {0}" -f $termsA) -ForegroundColor DarkGray
Send-Tx "pay $IdA" {
    cast send $Pago "pay(string,uint256,bytes32)" $IdA $Amount $termsA --account $DeployerAlias --rpc-url $Rpc --json
} | Out-Null

# ── 5. leg B: the gasless payer path ───────────────────────────────────────

Write-Host "`nleg B - gasless pay (payer signs off-chain, payee submits)" -ForegroundColor Cyan
Send-Tx "createLink $IdB" {
    cast send $Pago $CreateSig $IdB $Amount $Token "live test: gasless payer path" 0 $DefSplit $RuleSplitBad `
        --account $PayeeAlias --rpc-url $Rpc --json
} | Out-Null

# The nonce is derived from (linkKey, payer) by the contract itself, so the
# signature we are about to produce can only ever settle this one link.
$linkKey = Call "linkKeyOf($IdB)" { cast call $Pago "linkKeyOf(string)(bytes32)" $IdB }
$nonce = Call "authorization nonce" { cast call $Pago "authorizationNonce(bytes32,address)(uint256)" $linkKey $Deployer }
# authorizationNonce returns a uint256, but both digestOf and
# payWithAuthorization declare the nonce as bytes32 - Pago.t.sol:866 does the
# same `bytes32(uint256)` cast and Pago.sol:289 converts back with
# `uint256(nonce)`. Left as decimal, cast parses it as hex and fails with the
# misleading "odd number of digits". Convert with cast's own to-hex (a
# BigInteger's "x" format emits a stray leading nibble on this value, giving
# 65 digits instead of 64) and pad out to the fixed width a bytes32 needs.
$nonceHex = (Call "nonce as bytes32" { cast to-hex $nonce }) -replace "^0x", ""
$nonce = "0x" + $nonceHex.PadLeft(64, "0")
$validBefore = "18446744073709551615"                     # type(uint64).max
$digest = Call "EIP-3009 digest" {
    cast call $Token "digestOf(address,address,uint256,uint256,uint256,bytes32)(bytes32)" `
        $Deployer $Pago $Amount 0 $validBefore $nonce
}
Write-Host ("  digest {0}" -f $digest) -ForegroundColor DarkGray

# `--no-hash`: the digest is already the final 32 bytes to sign. Signing it
# again with the EIP-191 prefix would produce a signature no token accepts.
$sigJson = Run-Retry "keystore signature" {
    cast wallet sign $digest --no-hash --account $DeployerAlias
}
$sig = $sigJson
if ($sigJson -match "0x[0-9a-fA-F]{130}") { $sig = $Matches[0] }
Write-Host ("  signed by {0} ({1} bytes)" -f $DeployerAlias, (($sig.Length - 2) / 2)) -ForegroundColor DarkGray

# Terms consent (rule 4) for the gasless path too: same onchain hash, passed
# as the final argument of payWithAuthorization.
$termsB = Call "termsHash($IdB)" { cast call $Pago "termsHash(string)(bytes32)" $IdB }
Write-Host ("  termsHash {0}" -f $termsB) -ForegroundColor DarkGray
Send-Tx "payWithAuthorization $IdB" {
    cast send $Pago "payWithAuthorization(string,address,uint256,uint64,uint64,bytes32,bytes,bytes32)" `
        $IdB $Deployer $Amount 0 $validBefore $nonce $sig $termsB `
        --account $PayeeAlias --rpc-url $Rpc --json
} | Out-Null

# ── 6. claim both, as an uninvolved account ────────────────────────────────

Write-Host "`nclaiming - callable by anyone, pays only payee + fee account" -ForegroundColor Cyan
foreach ($id in @($IdA, $IdB)) {
    Send-Tx "claim $id" { cast send $Pago "claim(string)" $id --account $PayeeAlias --rpc-url $Rpc --json } | Out-Null
}

# ── 7. verify ──────────────────────────────────────────────────────────────

Write-Host "`nverification" -ForegroundColor Cyan
$payeeAfter = [bigint](Call "payee pUSD" { cast call $Token "balanceOf(address)(uint256)" $Payee })
$deployerAfter = [bigint](Call "deployer pUSD" { cast call $Token "balanceOf(address)(uint256)" $Deployer })
$heldAfter = [bigint](Call "pUSD held by Pago" { cast call $Token "balanceOf(address)(uint256)" $Pago })
$links = Call "links created by payee" { cast call $Pago "linkCountByCreator(address)(uint256)" $Payee }

# What this run alone should have moved, measured from the snapshot above.
# Rule 6's live check gates claim, and $Mode (read from the deployment, never
# assumed) says which table that check allowed the circuit to be asked about:
#
#   pinned    leg A's VALID rule table (10+6+4 = 20 steps) is consulted and
#             pays payee 497,500 + fee-account seat 497,500; leg B's
#             10+8+5 = 23 steps is rejected and falls to the default table
#             (payee 995,000). The deployer receiving money back as a rule
#             seat is what distinguishes this from the fallback.
#               payee    = 497,500 + 995,000 = 1,492,500
#               deployer = -2 x 1,000,000 + 497,500 rule seat + 2 x 5,000 fees
#                        = -1,492,500
#   unpinned  claim never consults the circuit and BOTH legs settle through
#             the DEFAULT table:
#               payee    = 995,000 + 995,000 = 1,990,000
#               deployer = -2 x 1,000,000 payments + 2 x 5,000 fees
#                        = -1,990,000
#
#   in both modes: Pago holds exactly what it held before, and the three
#   deltas must sum to zero - nothing created, nothing lost.
$payeeDelta = $payeeAfter - $payeeBefore
$deployerDelta = $deployerAfter - $deployerBefore
$heldDelta = $heldAfter - $heldBefore
$payout = [bigint]$Amount * [bigint](10000 - $FeeBps) / 10000     # 995,000 post-fee
$fee = [bigint]$Amount * $FeeBps / 10000                          # 5,000
if ($Mode -eq "pinned") {
    $rulePayee = $payout * 10 / 20                                # leg A seat 1 = payee, 50%
    $ruleSeat = $payout * (6 + 4) / 20                            # leg A seats 2+3, 50%
    $expectedPayout = $rulePayee + $payout                        # rule table + default
    $expectedDeployer = [bigint](-2 * $Amount) + $ruleSeat + 2 * $fee
    $payeeWant = "rule {0} + default {1}" -f $rulePayee, $payout
    $deployerWant = "-2 payments + rule seat {0} + 2 fees" -f $ruleSeat
} else {
    $expectedPayout = 2 * $payout                                 # default table on both legs
    $expectedDeployer = [bigint](-2 * $Amount) + 2 * $fee         # no rule seat while unpinned
    $payeeWant = "default {0} x 2" -f $payout
    $deployerWant = "-2 payments + 2 fees; no rule seat"
}
$sum = $payeeDelta + $deployerDelta + $heldDelta

Write-Host ("  mode                        {0}" -f $Mode)
Write-Host ("  links created by payee      {0} (informational)" -f $links)
Write-Host ("  payee change                {0} (want {1})" -f $payeeDelta, $payeeWant)
Write-Host ("  deployer change             {0} (want {1})" -f $deployerDelta, $deployerWant)
Write-Host ("  held by Pago change         {0} (want 0 - nothing left inside)" -f $heldDelta)
Write-Host ("  deltas sum to               {0} (want 0 - every unit accounted for)" -f $sum)

$ok = ($heldDelta -eq 0) -and ($sum -eq 0) -and ($payeeDelta -eq $expectedPayout) `
    -and ($deployerDelta -eq $expectedDeployer)
if ($ok) {
    Write-Host "`nPASS - both payer paths live on X Layer testnet, mode: $Mode." -ForegroundColor Green
    if ($Mode -eq "pinned") {
        Write-Host "The live rule-6 check passed, so the circuit decided leg A's split" -ForegroundColor Green
        Write-Host "(money back to the rule seat) and leg B fell to the default table." -ForegroundColor Green
    } else {
        Write-Host "The live rule-6 check failed, so claim was gated to the default" -ForegroundColor Green
        Write-Host "table on both legs and the rule table was never consulted." -ForegroundColor Green
    }
    Write-Host "Every unit accounted for." -ForegroundColor Green
} else {
    Write-Host "`nFAIL - balances do not match the expected split for mode '$Mode'. Inspect the transactions above." -ForegroundColor Red
    exit 1
}
