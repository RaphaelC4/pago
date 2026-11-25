# Rehearses the EXACT mainnet Tier 2 sequence as ordinary wallet transactions
# against a LOCAL fork of X Layer mainnet (chain 196).
#
# Why this exists: `forge script` simulated the chain and failed on the tape-out
# step with `call to non-contract address <deployer wallet>`, while a Foundry
# fork test running the same call from the same wallet passed. A test can
# behave differently from a real wallet, so this rehearsal sends every step as a
# separate, real, nonce-consuming transaction from the deployer - impersonated
# as a plain unlocked account, with no Foundry cheatcodes inside the steps.
#
# Nothing here talks to mainnet in the default -Mode fork: pass a LOCAL fork
# url in -Rpc (the default). -Mode live targets mainnet and is only for the
# run after the user gives the exact phrase.
#
# For each step it (a) simulates with `cast call --from <wallet>`, (b) sends
# with `cast send --unlocked --from <wallet>`, (c) requires receipt status
# 0x1, and (d) reads the state back. It stops at the FIRST failure and prints
# `REHEARSAL|FAIL|<step>|<reason>`; never resends anything.
#
# Step 11 additionally captures a node-side call trace of the tape-out BEFORE
# sending it, and reports every frame that touches the deployer wallet - that
# is the evidence for "who calls the wallet".
#
# The SAME script runs the live deployment (-Mode live): identical steps,
# identical checks, only the transport changes (keystore signing instead of
# impersonation, mainnet RPC instead of the local fork). Live mode additionally
# verifies the frozen contract sources before the first send, refuses to retry
# any send that may have gone through, and writes every receipt to docs/.
#
# Usage - rehearsal (from contracts-evm/), with anvil already running:
#   anvil --fork-url https://rpc.xlayer.tech --port 8545 --silent
#   powershell -ExecutionPolicy Bypass -File script\rehearse-castsend.ps1
#
# Usage - live (ONLY after the user gives the exact phrase; ETH_PASSWORD must
# be set in the environment from .env - it is never printed or passed as an
# argument):
#   powershell -ExecutionPolicy Bypass -File script\rehearse-castsend.ps1 -Mode live
param(
    [ValidateSet("fork", "live")]
    [string]$Mode = "fork",
    [string]$Rpc = "",
    [string]$Deployer = "0x3f1004AAeD662227d535D794dA679110111a2FC4",
    [string]$Account = "pago-deployer",
    # Funding inputs. The defaults are the proven fresh-wallet rehearsal
    # values: buy 0.132 BEM (0.11 spent + 20% buffer), 15% swap cap over
    # spot, 0.002 OKB gas headroom in the preflight fund check. A wallet
    # that already holds BEM overrides BuyBemUnits to buy only the
    # difference - total BEM spend is fixed at 0.11 (deployFee 0.1 +
    # protocolFee 0.01 flat per mint call, mintPrice 0).
    [bigint]$BuyBemUnits = 13200000,
    [int]$BufferPct = 115,
    [bigint]$GasHeadroom = 2000000000000000
)
$ErrorActionPreference = "Stop"
if ($Rpc -eq "") { $Rpc = if ($Mode -eq "live") { "https://rpc.xlayer.tech" } else { "http://127.0.0.1:8545" } }
$Tag = if ($Mode -eq "live") { "LIVE" } else { "REHEARSAL" }

# ---- X Layer mainnet constants (chain 196), identical to Tier2Mainnet.s.sol --
$FACTORY = "0x1f09DAeFA827f02CBb40967cc91b259763760761"
$BEM     = "0x60e62Efa9405d6873C5deaBD4E6CC91c25363952"
$POOL    = "0x2CcF8aa17F5DF9Fb5D51C9de12135a913fF29f7A"
$WOKB    = "0xe538905cf8410324e03A5A23C1c177a474D59b2b"
$USD_T0  = "0x779Ded0c9e1022225f8E0630b35a9b54bE713736"
$USDG    = "0x4ae46a509F6b1D9056937BA4500cb143933D2dc8"
$FEE_ACCT = "0x7FCe520D881454EA234d371E1256B75843609b62"

$NEW_SHELL = "0x8c799a18cd8e0d5f5f3c0cec4fbc145e2daf79f70c2b131c09d0f380921db545"
$BEACON    = "0xf70d1ed4f62CF3780157B0b421b7E2F45bD0991C"
$IMPL      = "0x977f217887E085D298Cb3819cDAD5A0ee35F29B2"
$IMPL_HASH = "0x7a15c353205e5245f40f5f5524542a982a4bb3b9a28476e4f10845163f941b30"

$BUY_BEM_UNITS = $BuyBemUnits               # BEM to buy this run (default 0.132 = fresh wallet)
$UNPINNED_CAP  = [bigint]10000000000       # 10,000 tokens at 6 decimals
$NAND_COUNT    = 104
$GATE_COUNT    = 100000
$CPU_NAME      = "Pago"
$CPU_SYMBOL    = "PAGO"
$CPU_DESC      = "Pago rule library: shareable payment-term circuits."

$NetlistHex  = (Get-Content (Join-Path $PSScriptRoot "split3-netlist.hex") -Raw).Trim()
$BuyerCode   = (Get-Content (Join-Path $PSScriptRoot "BemBuyer.creation.hex") -Raw).Trim()
$PagoCode    = (Get-Content (Join-Path $PSScriptRoot "Pago.creation.hex") -Raw).Trim()

function Log([string]$line) { Write-Output $line }

function Die([string]$step, [string]$why) {
    Log "$Tag|FAIL|$step|$why"
    # Show WHERE the failure happened, not only the message: the most recent
    # error record carries the script line and stack of the failing statement.
    $e = $null
    foreach ($x in $Error) { if ($x -ne $null) { $e = $x; break } }
    if ($e -ne $null -and $e.InvocationInfo -ne $null) {
        $pos = ($e.InvocationInfo.PositionMessage -replace "`r?`n", " ~ ")
        if ($pos) { Log "$Tag|DIAG|position|$pos" }
        $stk = ($e.ScriptStackTrace -replace "`r?`n", " ~ ")
        if ($stk) { Log "$Tag|DIAG|stack|$stk" }
    }
    exit 1
}

# ---- primitives ------------------------------------------------------------

function Call([string]$To, [string]$Sig, [string[]]$CallArgs = @(), [string]$Value = "") {
    $a = @("call", "--from", $Deployer, "--rpc-url", $Rpc)
    if ($Value -ne "") { $a += @("--value", $Value) }
    $a += $To
    if ($Sig -ne "") { $a += $Sig }
    $a += $CallArgs
    # Print every argument BEFORE the call: a native stderr under
    # EAP=Stop throws immediately, so the dump must exist beforehand.
    # The last DIARG|call block before a FAIL names the exact args.
    foreach ($x in $a) { Write-Host "$Tag|DIARG|call|[$x]" }
    # The fork's upstream RPC (rpc.xlayer.tech) has flaky DNS/TLS; a failed
    # read changes no state, so retrying is always safe.
    # Under EAP=Stop, cast's stderr becomes a terminating error the moment it
    # hits the pipeline — that would jump straight past this loop. Catch it
    # INSIDE the loop so the retries actually run.
    $out = ""
    $exit = 1
    foreach ($try in 1..8) {
        try {
            $out = (& cast @a 2>&1 | Out-String)
            $exit = $LASTEXITCODE
        } catch {
            $out = "$_"
            $exit = 1
        }
        if ($exit -eq 0) { break }
        if ($try -eq 8) { break }
        Start-Sleep 8
    }
    if ($exit -ne 0) { throw "cast call failed -> $out" }
    $out = $out.Trim()
    # cast appends a human annotation to single-line results:
    # "10000000 [1e7]" -> "10000000". Tuple results are multi-line and keep
    # their own parsing below.
    if ($out -notmatch "`n" -and $out -match " \[") { $out = $out.Substring(0, $out.IndexOf(" [")) }
    return $out
}

# Send one transaction, require receipt status 0x1, return the parsed receipt.
# The fork's upstream RPC (rpc.xlayer.tech) has flaky DNS; a failed ESTIMATE
# sends nothing, so retrying a send that errored before any hash was returned
# is safe. A tx that returned a hash is never sent again.
function Send([string]$Step, [string[]]$SendArgs) {
    # Options first: with `--create`, cast requires <CODE> as the trailing
    # positional, so `--from` after it is rejected as an unexpected argument.
    # Fork: impersonated unlocked account. Live: Foundry keystore (`--account`),
    # password read from ETH_PASSWORD by cast itself - never on this command
    # line, never printed.
    if ($Mode -eq "live") {
        $a = @("send", "--account", $Account, "--rpc-url", $Rpc, "--json") + $SendArgs
        $tries = 1
    } else {
        $a = @("send", "--from", $Deployer, "--unlocked", "--rpc-url", $Rpc, "--json") + $SendArgs
        $tries = 8
    }
    # The fork's upstream RPC (rpc.xlayer.tech) has flaky DNS; a failed ESTIMATE
    # sends nothing, so retrying a send that errored before any hash was returned
    # is safe. A tx that returned a hash is never sent again. LIVE mode never
    # retries at all: stop at the first failure and report, per the rule
    # "never resend a transaction that may have gone through".
    foreach ($x in $a) { Write-Host "$Tag|DIARG|send|[$x]" }
    # Same EAP=Stop guard as Call: catch stderr inside the loop so fork-mode
    # retries run. If a hash ever appears in a failed attempt, stop: never
    # resend a transaction that may have gone through.
    $out = ""
    $exit = 1
    $hashSeen = $false
    foreach ($try in 1..$tries) {
        try {
            $out = (& cast @a 2>&1 | Out-String)
            $exit = $LASTEXITCODE
        } catch {
            $out = "$_"
            $exit = 1
        }
        if ($exit -eq 0) { break }
        if ($out -match '0x[0-9a-fA-F]{64}') { $hashSeen = $true; break }
        if ($try -eq $tries) { break }
        Start-Sleep 8
    }
    if ($hashSeen) { throw "a transaction hash was returned but not parsed - DO NOT resend, inspect manually -> $out" }
    if ($exit -ne 0) { throw "cast send failed -> $out" }
    $s = $out.IndexOf("{"); $e = $out.LastIndexOf("}")
    if ($s -lt 0 -or $e -lt $s) { throw "no JSON receipt in output -> $out" }
    $r = $out.Substring($s, $e - $s + 1) | ConvertFrom-Json
    if ($r.status -ne "0x1") { throw "transaction REVERTED status=$($r.status) tx=$($r.transactionHash)" }
    Log "$Tag|TX|$Step|$($r.transactionHash)"
    if ($Mode -eq "live") {
        # Evidence: every receipt saved before the next step starts.
        $receiptPath = Join-Path $PSScriptRoot "..\..\docs\tier2-mainnet-$Step.json"
        Set-Content -Path $receiptPath -Value ($r | ConvertTo-Json -Depth 10)
        Log "$Tag|RECEIPT|$Step|$receiptPath"
    }
    return $r
}

function Slot0Sqrt([string]$pool) {
    # cast prints tuple members one per line: "2883...949220 [2.883e33]" etc.
    $raw = Call $pool "slot0()(uint160,int24,uint16,uint16,uint16,uint8,bool)"
    $firstLine = ($raw -split "`n")[0].Trim()
    $firstLine = ($firstLine -split "\[")[0].Trim()
    return [System.Numerics.BigInteger]::Parse($firstLine)
}

# Single capability probe: returns the uint value, or $null when the call
# reverts (capability absent) or keeps failing. Under EAP=Stop cast's stderr
# throws, so catch INSIDE the loop (same guard as Call/Send).
# A network error that exhausts retries also yields $null - that can only
# make role discovery FAIL, never guess: discovery aborts unless exactly one
# address answers TAPEOUT_FEE() and the other answers mintPrice().
function ProbeUint([string]$to, [string]$sig) {
    $a = @("call", "--from", $Deployer, "--rpc-url", $Rpc, $to, $sig)
    $out = ""
    foreach ($try in 1..8) {
        $exit = 1
        try {
            $out = (& cast @a 2>&1 | Out-String)
            $exit = $LASTEXITCODE
        } catch { $out = "$_"; $exit = 1 }
        if ($exit -eq 0) {
            $v = $out.Trim()
            if ($v -match " \[") { $v = $v.Substring(0, $v.IndexOf(" [")) }
            return $v
        }
        # A revert is an ANSWER (capability absent), not a transport failure.
        if ($out -match 'revert|invalid opcode|does not have any code') { return $null }
        if ($try -eq 8) { return $null }
        Start-Sleep 8
    }
    return $null
}

# ---- preflight -------------------------------------------------------------
Log "$Tag|START|mode=$Mode|rpc=$Rpc|wallet=$Deployer"

if ($Mode -eq "fork") {
    # NOTE: the fork must be FRESH (started new, or restarted) before each run.
    # A previous run leaves wrapped WOKB, allowances and a created CPU behind.
    # anvil_reset cannot re-establish the fork on this anvil build, so restarting
    # anvil is the reliable way back to mainnet state.
}

$chainId = (& cast chain-id --rpc-url $Rpc 2>&1 | Out-String).Trim()
if ($chainId -ne "196") { Die "preflight" "chain id is $chainId, expected 196 (X Layer mainnet)" }
Log "$Tag|FACT|chainid|$chainId"

$okb = [System.Numerics.BigInteger]::Parse((& cast balance $Deployer --rpc-url $Rpc 2>&1 | Out-String).Trim())
Log "$Tag|FACT|okb_wei|$okb"

# Quote the swap's input cap from spot BEFORE any mode branch: the fund check
# below (live) and step 1 (both modes) both consume these numbers.
# spot input = output x price, where price = (sqrtPriceX96/2^96)^2 in raw
# token units (WOKB wei per BEM unit); +BufferPct% covers the 1% LP fee,
# price impact and any adverse move between quoting and execution. The
# swap's sqrtPriceLimitX96 below (+4.04% price) always binds before this
# cap, so the buffer sizes the preflight/wrap/approve guardrail, not the
# swap's own tolerance.
$sqrt = Slot0Sqrt $POOL
$two192 = [System.Numerics.BigInteger]::Pow(2, 192)
$price = [System.Numerics.BigInteger]::Divide($sqrt * $sqrt, $two192)
$maxIn = [System.Numerics.BigInteger]::Divide($BUY_BEM_UNITS * $price * [System.Numerics.BigInteger]$BufferPct, 100)
# Uniswap V3 rejects type(uint160).max with revert string "SPL": the limit
# must sit strictly between the current sqrt price and MAX_SQRT_RATIO.
# ~4% of headroom never bites at this size.
$limit = $sqrt + [System.Numerics.BigInteger]::Divide($sqrt, 50)
Log "$Tag|FACT|buy_bem_units|$BUY_BEM_UNITS"
Log "$Tag|FACT|buffer_pct|$BufferPct"
Log "$Tag|FACT|gas_headroom_wei|$GasHeadroom"
Log "$Tag|FACT|maxIn_wokb|$maxIn"
Log "$Tag|FACT|sqrtPriceLimitX96|$limit"

if ($Mode -eq "fork") {
    # Dirty-fork guard: a run that got past the wrap step leaves the wallet
    # below its mainnet balance. Fail loudly instead of rehearsing on stale state.
    $mainnetOkb = [System.Numerics.BigInteger]::Parse("29608427727769318")
    if ($okb -lt $mainnetOkb) { Die "preflight" "fork is dirty (balance $okb < mainnet $mainnetOkb) - restart anvil with --fork-url https://rpc.xlayer.tech" }

    # Impersonation: without it the unlocked sends below are rejected.
    $null = & cast rpc anvil_impersonateAccount $Deployer --rpc-url $Rpc 2>&1
    if ($LASTEXITCODE -ne 0) { Die "preflight" "anvil_impersonateAccount failed - is this an anvil fork?" }
} else {
    # ---- live-only pre-send checks. Nothing below can send; it all aborts
    # before transaction 1 if any condition fails. ----

    # 1. Contract sources are the frozen ones: no change since the freeze
    #    commit, and Pago.sol is byte-identical to the recorded blob.
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
    $head = (& git -C $repoRoot rev-parse HEAD 2>&1 | Out-String).Trim()
    Log "$Tag|FACT|git_head|$head"
    $srcDiff = (& git -C $repoRoot diff 48b045f..HEAD -- contracts-evm/src/ 2>&1 | Out-String).Trim()
    if ($srcDiff -ne "") { Die "preflight" "contracts-evm/src/ differs from freeze 48b045f - refusing to deploy" }
    $blob = (& git -C $repoRoot rev-parse "HEAD:contracts-evm/src/Pago.sol" 2>&1 | Out-String).Trim()
    Log "$Tag|FACT|pago_blob|$blob"
    if ($blob -ne "06737fe94e779d22ae552275d3a9003e79a535c6") { Die "preflight" "Pago.sol blob $blob != recorded 06737fe9..." }

    # 2. The keystore exists and its password is available to cast via
    #    ETH_PASSWORD (the value is never read into a variable, logged, or
    #    passed as an argument here).
    if (-not $env:ETH_PASSWORD) { Die "preflight" "ETH_PASSWORD is not set - load it from .env first" }
    $ks = Join-Path $env:USERPROFILE ".foundry\keystores\$Account"
    if (-not (Test-Path $ks)) { Die "preflight" "keystore $ks not found" }
    Log "$Tag|FACT|keystore|present:$Account"

    # 3. Funds: the quoted need (swap cap + tape-out fee + gas headroom) must
    #    be covered, or step-by-step sending could die halfway with money spent.
    $need = $maxIn + [System.Numerics.BigInteger]1300000000000000 + [System.Numerics.BigInteger]$GasHeadroom
    if ($okb -lt $need) { Die "preflight" "wallet holds $okb wei, need at least $need (swap cap + tapeout fee + gas)" }
    Log "$Tag|FACT|okb_required|$need"
}

$cpuCount = (Call $FACTORY "cpuCount()(uint256)")
Log "$Tag|FACT|factory_cpuCount|$cpuCount"

# ---- the twelve steps ------------------------------------------------------

# 1. wrap exactly the swap's input cap into WOKB
#    ($maxIn and $limit were quoted in preflight)
try {
    $null = Call $WOKB "deposit()" "" $maxIn.ToString()
    $r = Send "wrap" @($WOKB, "deposit()", "--value", $maxIn.ToString())
    $w = [System.Numerics.BigInteger]::Parse((Call $WOKB "balanceOf(address)(uint256)" $Deployer))
    if ($w -lt $maxIn) { Die "wrap" "WOKB balance $w is below the approved cap $maxIn" }
    Log "$Tag|STATE|wokb_after_wrap|$w"
} catch { Die "wrap" $_.Exception.Message }

# 2. deploy the swap helper (the pool's callback must land on a contract)
try {
    $ctor = (& cast abi-encode "constructor(address,address,address)" $POOL $WOKB $Deployer 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) { throw "abi-encode failed -> $ctor" }
    if ($ctor.StartsWith("0x")) { $ctor = $ctor.Substring(2) }
    $r = Send "deployBuyer" @("--create", "$BuyerCode$ctor")
    $buyer = $r.contractAddress
    if (-not $buyer) { Die "deployBuyer" "receipt carries no contractAddress" }
    $code = (& cast code $buyer --rpc-url $Rpc 2>&1 | Out-String).Trim()
    if ($code -eq "0x" -or $code.Length -le 2) { Die "deployBuyer" "no code at $buyer" }
    Log "$Tag|STATE|buyer|$buyer"
} catch { Die "deployBuyer" $_.Exception.Message }

# 3. approve the helper for EXACTLY maxIn - never an unlimited allowance
try {
    $null = Call $WOKB "approve(address,uint256)" @($buyer, $maxIn.ToString())
    $null = Send "approveBuyer" @($WOKB, "approve(address,uint256)", $buyer, $maxIn.ToString())
    $allow = [System.Numerics.BigInteger]::Parse((Call $WOKB "allowance(address,address)(uint256)" @($Deployer, $buyer)))
    if ($allow -ne $maxIn) { Die "approveBuyer" "allowance $allow != quoted cap $maxIn" }
    Log "$Tag|STATE|buyer_allowance|$allow"
} catch { Die "approveBuyer" $_.Exception.Message }

# 4. exact-output buy, input-capped, helper must end empty
try {
    # The amount is NEGATIVE (exact-output in Uniswap V3 terms). cast's
    # call/send CLI parses a bare "-13200000" as flags, so build the calldata
    # with `cast calldata` (which parses it correctly) and pass raw hex.
    # Args are logged one per line first: a stderr here throws before we can
    # report anything afterwards.
    $cdArgs = @("calldata", "buy(address,int256,uint160,uint256)", $Deployer, ("-" + $BUY_BEM_UNITS), $limit.ToString(), $maxIn.ToString())
    foreach ($x in $cdArgs) { Write-Host "$Tag|DIARG|calldata|[$x]" }
    $buyData = (& cast @cdArgs 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or -not $buyData.StartsWith("0x")) { throw "calldata build failed -> $buyData" }
    $null = Call $buyer $buyData
    $null = Send "buyBem" @($buyer, $buyData)
    # NOTE: PowerShell variables are case-insensitive, so this must NOT be
    # named "$bem" — it would overwrite the $BEM contract address above.
    $bemBal = [System.Numerics.BigInteger]::Parse((Call $BEM "balanceOf(address)(uint256)" $Deployer))
    if ($bemBal -lt $BUY_BEM_UNITS) { Die "buyBem" "only bought $bemBal of $BUY_BEM_UNITS BEM units" }
    $buyerBem = [System.Numerics.BigInteger]::Parse((Call $BEM "balanceOf(address)(uint256)" $buyer))
    $buyerWokb = [System.Numerics.BigInteger]::Parse((Call $WOKB "balanceOf(address)(uint256)" $buyer))
    if ($buyerBem -ne 0 -or $buyerWokb -ne 0) { Die "buyBem" "helper not empty: bem=$buyerBem wokb=$buyerWokb" }
    Log "$Tag|STATE|bem_after_buy|$bemBal"
} catch { Die "buyBem" $_.Exception.Message }

# 5. revoke the allowance the swap just used
try {
    $null = Send "revokeBuyer" @($WOKB, "approve(address,uint256)", $buyer, "0")
    $allow = [System.Numerics.BigInteger]::Parse((Call $WOKB "allowance(address,address)(uint256)" @($Deployer, $buyer)))
    if ($allow -ne 0) { Die "revokeBuyer" "allowance still $allow" }
    Log "$Tag|STATE|buyer_allowance_after_revoke|$allow"
} catch { Die "revokeBuyer" $_.Exception.Message }

# 6. unwrap the WOKB the swap did not consume
try {
    $w = [System.Numerics.BigInteger]::Parse((Call $WOKB "balanceOf(address)(uint256)" $Deployer))
    if ($w -gt 0) { $null = Send "unwrap" @($WOKB, "withdraw(uint256)", $w.ToString()) }
    $left = [System.Numerics.BigInteger]::Parse((Call $WOKB "balanceOf(address)(uint256)" $Deployer))
    if ($left -ne 0) { Die "unwrap" "$left WOKB still held" }
    Log "$Tag|STATE|wokb_after_unwrap|$left"
} catch { Die "unwrap" $_.Exception.Message }

# 7. approve the factory for EXACTLY deployFee()
try {
    $deployFee = [System.Numerics.BigInteger]::Parse((Call $FACTORY "deployFee()(uint256)"))
    Log "$Tag|FACT|factory_deployFee|$deployFee"
    $null = Call $BEM "approve(address,uint256)" @($FACTORY, $deployFee.ToString())
    $null = Send "approveFactory" @($BEM, "approve(address,uint256)", $FACTORY, $deployFee.ToString())
} catch { Die "approveFactory" $_.Exception.Message }

# 8. createCPU (gate price 0, probe-proven to have no floor on this chain)
$circuits = ""; $transistors = ""
try {
    $sim = Call $FACTORY "createCPU(string,string,string,uint256,uint256)(address,address)" @($CPU_NAME, $CPU_SYMBOL, $CPU_DESC, $GATE_COUNT, "0")
    # cast prints multi-value returns one per line (or as a tuple); pull the
    # two addresses out with a regex so either shape works.
    $addrs = [regex]::Matches($sim, "0x[0-9a-fA-F]{40}") | ForEach-Object { $_.Value }
    if ($addrs.Count -ne 2) { Die "createCpu" "unexpected simulation return: $sim" }

    $null = Send "createCpu" @($FACTORY, "createCPU(string,string,string,uint256,uint256)", $CPU_NAME, $CPU_SYMBOL, $CPU_DESC, $GATE_COUNT, "0")

    # Roles BY CAPABILITY, never by position - same rule as ShellProbe.t.sol:
    # circuits answers TAPEOUT_FEE(), transistors answers mintPrice(). The
    # probe runs AFTER the send because pre-send the addresses have no code.
    # If the two addresses do not form exactly one (tape-only, mint-only)
    # pair, abort: never guess which is which.
    $tape0 = ProbeUint $addrs[0] "TAPEOUT_FEE()(uint256)"
    $mint0 = ProbeUint $addrs[0] "mintPrice()(uint256)"
    $tape1 = ProbeUint $addrs[1] "TAPEOUT_FEE()(uint256)"
    $mint1 = ProbeUint $addrs[1] "mintPrice()(uint256)"
    $isT0 = -not [string]::IsNullOrEmpty($tape0)
    $isM0 = -not [string]::IsNullOrEmpty($mint0)
    $isT1 = -not [string]::IsNullOrEmpty($tape1)
    $isM1 = -not [string]::IsNullOrEmpty($mint1)
    Log "$Tag|FACT|shape|pos0_tape=$isT0 pos0_mint=$isM0 pos1_tape=$isT1 pos1_mint=$isM1"
    if ($isT0 -and -not $isM0 -and -not $isT1 -and $isM1) {
        $circuits = $addrs[0]; $transistors = $addrs[1]
    } elseif (-not $isT0 -and $isM0 -and $isT1 -and -not $isM1) {
        $circuits = $addrs[1]; $transistors = $addrs[0]
    } else {
        Die "createCpu" "role discovery failed (tape0=$isT0 mint0=$isM0 tape1=$isT1 mint1=$isM1) - aborting, never guessing"
    }
    Log "$Tag|FACT|circuits|$circuits"
    Log "$Tag|FACT|transistors|$transistors"
    Log "$Tag|FACT|role_from|$(if ($circuits -eq $addrs[0]) { 'pos0' } else { 'pos1' })"

    $cCode = (& cast code $circuits --rpc-url $Rpc 2>&1 | Out-String).Trim()
    if ($cCode.Length -le 2) { Die "createCpu" "no code at circuits $circuits" }
    $shellHash = (& cast keccak $cCode 2>&1 | Out-String).Trim()
    Log "$Tag|STATE|circuits_codehash|$shellHash"
    if ($shellHash.ToLower() -ne $NEW_SHELL.ToLower()) {
        Die "createCpu" "shell codehash $shellHash != recorded probe $NEW_SHELL - Pago would pin the wrong reference"
    }
    Log "$Tag|STATE|shell_matches_probe|true"
} catch { Die "createCpu" $_.Exception.Message }

# 9. approve the transistors for EXACTLY protocolFee + mintPrice x gates
try {
    $mintPrice = [System.Numerics.BigInteger]::Parse((Call $transistors "mintPrice()(uint256)"))
    $protoFee  = [System.Numerics.BigInteger]::Parse((Call $transistors "protocolFee()(uint256)"))
    $mintAllow = $protoFee + $mintPrice * $NAND_COUNT
    Log "$Tag|FACT|mintPrice|$mintPrice"
    Log "$Tag|FACT|protocolFee|$protoFee"
    Log "$Tag|FACT|mint_approved|$mintAllow"
    $null = Send "approveTransistors" @($BEM, "approve(address,uint256)", $transistors, $mintAllow.ToString())
    $allow = [System.Numerics.BigInteger]::Parse((Call $BEM "allowance(address,address)(uint256)" @($Deployer, $transistors)))
    if ($allow -ne $mintAllow) { Die "approveTransistors" "allowance $allow != $mintAllow" }
} catch { Die "approveTransistors" $_.Exception.Message }

# 10. mint the 104 gates (BEM allowance route, no native value)
try {
    $null = Call $transistors "mint(uint256,uint256)" @("0", "$NAND_COUNT")
    $null = Send "mint" @($transistors, "mint(uint256,uint256)", "0", "$NAND_COUNT")
    $bemBal = [System.Numerics.BigInteger]::Parse((Call $BEM "balanceOf(address)(uint256)" $Deployer))
    Log "$Tag|STATE|bem_after_mint|$bemBal"
} catch { Die "mint" $_.Exception.Message }

# 11. tape out the Split3 netlist.
#     First: a node-side call trace of the exact call, to answer
#     "who calls the wallet?" BEFORE any value is committed.
$circuitId = ""
try {
    $tapeFee = [System.Numerics.BigInteger]::Parse((Call $circuits "TAPEOUT_FEE()(uint256)"))
    Log "$Tag|FACT|tapeout_fee|$tapeFee"

    # N_IN=15, N_OUT=1 for Split3 (Split3.N_IN / Split3.N_OUT).
    # uint32, NOT uint256: the contract's function is tapeout(bytes,uint32,uint32)
    # (selector 0x7bd3ac1d, RESEARCH L97). uint256 builds 0xb139edee, which hits
    # the fallback and reverts with empty data.
    $calldata = (& cast calldata "tapeout(bytes,uint32,uint32)" $NetlistHex "15" "1" 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) { throw "calldata build failed -> $calldata" }

    $txObj = @{
        from  = $Deployer
        to    = $circuits
        value = "0x" + $tapeFee.ToString("x")
        data  = $calldata
    }
    # POST straight to anvil instead of `cast rpc`: PS 5.1's native-argument
    # quoting strips the embedded quotes from the JSON object before cast ever
    # sees it, and cast then forwards a bare string anvil rejects.
    $reqBody = @{
        jsonrpc = "2.0"
        id      = 1
        method  = "debug_traceCall"
        # Geth shape: [txObj, blockTag, traceConfig]. Position 2 is the block,
        # not the tracer - anvil rejects [txObj,{tracer}] with "unknown field
        # tracer, expected one of blockNumber, blockHash, requireCanonical".
        params  = @($txObj, "latest", @{ tracer = "callTracer" })
    } | ConvertTo-Json -Depth 6 -Compress

    $traceJson = ""
    try {
        $resp = Invoke-RestMethod -Uri $Rpc -Method Post -ContentType 'application/json' -Body $reqBody -ErrorAction Stop
        if ($resp.error) { throw "rpc error: $(($resp.error | ConvertTo-Json -Compress))" }
        if (-not $resp.result) { throw "empty trace result" }
        $traceJson = ($resp.result | ConvertTo-Json -Depth 30 -Compress)
    } catch {
        Log "$Tag|TRACE|unavailable|$_"
    }
    if ($traceJson -ne "") {
        $traceName = if ($Mode -eq "live") { "tapeout-calltrace-mainnet.json" } else { "tapeout-calltrace-fork.json" }
        Set-Content -Path (Join-Path $PSScriptRoot "..\..\docs\$traceName") -Value $traceJson
        $walletHits = ([regex]::Matches($traceJson, "(?i)3f1004aaed662227d535d794da679110111a2fc4")).Count
        Log "$Tag|TRACE|wallet_mentions|$walletHits"
        Log "$Tag|TRACE|top_level_error|$(if ($traceJson -match '"error"\s*:\s*"([^"]+)"') { $Matches[1] } else { 'none' })"
        # Every frame that involves the wallet, so the caller is named outright.
        foreach ($m in [regex]::Matches($traceJson, '\{[^{}]*"from"\s*:\s*"0x[^"]*"[^{}]*\}')) {
            if ($m.Value -match "(?i)3f1004aaed662227d535d794da679110111a2fc4") {
                Log "$Tag|TRACE|frame|$($m.Value)"
            }
        }
    }

    # Simulate for the returned circuit id, then send for real.
    $circuitId = (Call $circuits "tapeout(bytes,uint32,uint32)(uint256)" @($NetlistHex, "15", "1") $tapeFee.ToString())
    Log "$Tag|FACT|circuitId|$circuitId"

    $null = Send "tapeout" @($circuits, "tapeout(bytes,uint32,uint32)", "--value", $tapeFee.ToString(), $NetlistHex, "15", "1")

    $back = Call $circuits "netlist(uint256)(bytes)" $circuitId
    if ($back.ToLower() -ne $NetlistHex.ToLower()) { Die "tapeout" "processor did not serve the netlist bytes back" }
    Log "$Tag|STATE|netlist_served_back|true"
} catch { Die "tapeout" $_.Exception.Message }

# 12. deploy Pago with the two allowlisted stablecoins and the recorded refs.
#     `cast send --create` cannot carry the payload: Pago's creation code is
#     ~35 KB of hex and Windows caps a command line at 32,767 characters.
#     `forge create` reads the creation bytecode from the build artifact and
#     takes the constructor arguments as short values. The artifact is asserted
#     byte-identical to script/Pago.creation.hex first, so the rehearsed bytes
#     are the deployed bytes. Same transport split as Send: fork sends through
#     the impersonated account, live signs with the pago-deployer keystore.
$pago = ""
try {
    $artPath = Join-Path $PSScriptRoot "..\out\Pago.sol\Pago.json"
    $artHex = ((Get-Content $artPath -Raw | ConvertFrom-Json).bytecode.object)
    if ($artHex.ToLower() -ne $PagoCode.ToLower()) {
        Die "deployPago" "forge artifact bytecode != script/Pago.creation.hex - do not deploy bytes we did not rehearse"
    }
    Log "$Tag|FACT|pago_artifact_matches_rehearsed_hex|true"

    # Predict the EXACT runtime code BEFORE spending anything: eth_call the
    # creation payload (init code + ABI-encoded constructor args) and keep the
    # returned runtime bytecode. The payload is ~35 KB - past the Windows
    # 32,767-char argv cap - so the JSON body is posted with
    # Invoke-RestMethod (same transport as the callTracer probe), never argv.
    # A constructor revert stops here, before any value leaves the wallet.
    $encArgs = (& cast abi-encode "f((address,uint8,uint256)[],address,address,uint256,bytes32,address,address,bytes32)" "[($USD_T0,6,$UNPINNED_CAP),($USDG,6,$UNPINNED_CAP)]" $FEE_ACCT $circuits "$circuitId" $NEW_SHELL $BEACON $IMPL $IMPL_HASH 2>&1) -join ''
    if ($LASTEXITCODE -ne 0 -or $encArgs -notmatch '^0x[0-9a-fA-F]+$') { Die "deployPago" "constructor arg encode failed -> $encArgs" }
    $payload = $PagoCode + $encArgs.Substring(2)
    $predicted = ""
    $predErr = ""
    foreach ($try in 1..8) {
        try {
            $b = @{ jsonrpc='2.0'; id=1; method='eth_call'; params=@(@{ from=$Deployer; data=$payload }, 'latest') } | ConvertTo-Json -Depth 5
            $resp = Invoke-RestMethod -Uri $Rpc -Method Post -ContentType 'application/json' -Body $b -TimeoutSec 60
            if ($resp.error) { throw ($resp.error | ConvertTo-Json -Compress) }
            $predicted = "$($resp.result)"
            $predErr = ""
            break
        } catch {
            $predErr = "$_"
            # A revert is a deterministic ANSWER (the constructor would fail):
            # stop now, before sending, and never burn retries on it.
            if ($predErr -match 'revert|execution reverted') { Die "deployPago" "constructor would revert -> $predErr" }
            if ($try -eq 8) { Die "deployPago" "runtime prediction eth_call failed -> $predErr" }
            Start-Sleep 8
        }
    }
    if ($predicted -notmatch '^0x[0-9a-fA-F]+$') { Die "deployPago" "prediction returned no runtime code -> $predicted" }
    $predictedHash = (($predicted | cast keccak 2>&1) -join '').Trim()
    if ($predictedHash -notmatch '^0x[0-9a-fA-F]{64}$') { Die "deployPago" "keccak of predicted runtime failed -> $predictedHash" }
    Log "$Tag|FACT|pago_predicted_runtime_len|$($predicted.Length)"
    Log "$Tag|FACT|pago_predicted_codehash|$predictedHash"

    # forge parses this tuple syntax directly (proven on the fork); all other
    # options MUST precede --constructor-args because it is variadic.
    $ctor = "[($USD_T0,6,$UNPINNED_CAP),($USDG,6,$UNPINNED_CAP)]"
    if ($Mode -eq "live") {
        $fa = @("create", "src/Pago.sol:Pago", "--rpc-url", $Rpc, "--broadcast", "--json",
                "--account", $Account, "--constructor-args", $ctor,
                $FEE_ACCT, $circuits, "$circuitId", $NEW_SHELL, $BEACON, $IMPL, $IMPL_HASH)
        $tries = 1
    } else {
        $fa = @("create", "src/Pago.sol:Pago", "--rpc-url", $Rpc, "--broadcast", "--json",
                "--unlocked", "--from", $Deployer, "--constructor-args", $ctor,
                $FEE_ACCT, $circuits, "$circuitId", $NEW_SHELL, $BEACON, $IMPL, $IMPL_HASH)
        $tries = 3
    }
    foreach ($x in $fa) { Write-Host "$Tag|DIARG|forge|[$x]" }

    Push-Location (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
    $out = ""; $exit = 1; $hashSeen = $false
    try {
        # Same guards as Send: stderr caught inside the loop, LIVE never
        # retries, and a hash in a failed output means DO NOT resend.
        foreach ($try in 1..$tries) {
            try {
                $out = (& forge @fa 2>&1 | Out-String)
                $exit = $LASTEXITCODE
            } catch {
                $out = "$_"
                $exit = 1
            }
            if ($exit -eq 0) { break }
            if ($out -match '0x[0-9a-fA-F]{64}') { $hashSeen = $true; break }
            if ($try -eq $tries) { break }
            Start-Sleep 8
        }
    } finally { Pop-Location }
    if ($hashSeen) { Die "deployPago" "a transaction hash was returned but not parsed - DO NOT resend, inspect manually -> $out" }
    if ($exit -ne 0) { Die "deployPago" "forge create failed -> $out" }
    $s = $out.IndexOf("{"); $e = $out.LastIndexOf("}")
    if ($s -lt 0 -or $e -lt $s) { Die "deployPago" "no JSON in forge output -> $out" }
    $fc = $out.Substring($s, $e - $s + 1) | ConvertFrom-Json
    $pago = $fc.deployedTo
    if (-not $pago) { Die "deployPago" "forge output carries no deployedTo" }
    Log "$Tag|TX|deployPago|$($fc.transactionHash)"
    Log "$Tag|STATE|pago|$pago"
    if ($Mode -eq "live") {
        # Evidence: same docs/tier2-mainnet-<step>.json contract as every step.
        $receiptPath = Join-Path $PSScriptRoot "..\..\docs\tier2-mainnet-deployPago.json"
        Set-Content -Path $receiptPath -Value ($fc | ConvertTo-Json -Depth 10)
        Log "$Tag|RECEIPT|deployPago|$receiptPath"
    }

    # Compare what actually landed against the pre-send prediction. Reading
    # `cast code` yields the runtime bytes (stdout, not argv - no size cap);
    # the keccak goes through stdin. A mismatch means we did not deploy the
    # bytes we predicted: stop the run right here.
    $actualCode = ""
    foreach ($try in 1..8) {
        try {
            $actualCode = (& cast code $pago --rpc-url $Rpc 2>&1) -join ''
            if ($LASTEXITCODE -eq 0) { break }
        } catch { $actualCode = "$_" }
        if ($try -eq 8) { Die "deployPago" "could not read deployed code at $pago -> $actualCode" }
        Start-Sleep 8
    }
    if ($actualCode -notmatch '^0x[0-9a-fA-F]+$') { Die "deployPago" "no runtime code at $pago -> $actualCode" }
    $actualHash = (($actualCode | cast keccak 2>&1) -join '').Trim()
    Log "$Tag|STATE|pago_deployed_codehash|$actualHash"
    if ($actualHash.ToLower() -ne $predictedHash.ToLower()) {
        Die "deployPago" "deployed codehash $actualHash != predicted $predictedHash - deployed bytes differ from the pre-send prediction"
    }
    Log "$Tag|STATE|pago_codehash_matches_prediction|true"
} catch { Die "deployPago" $_.Exception.Message }

# ---- verify what the deployment claims about itself -------------------------
try {
    $pinned = (Call $pago "evaluatorPinned()(bool)")
    $capT0  = (Call $pago "MAX_LINK_AMOUNT_UNPINNED(address)(uint256)" $USD_T0)
    $capG   = (Call $pago "MAX_LINK_AMOUNT_UNPINNED(address)(uint256)" $USDG)
    $feeAcct = (Call $pago "feeAccount()(address)")
    $proc    = (Call $pago "processor()(address)")
    Log "$Tag|STATE|evaluatorPinned|$pinned"
    Log "$Tag|STATE|cap_USDT0|$capT0"
    Log "$Tag|STATE|cap_USDG|$capG"
    Log "$Tag|STATE|feeAccount|$feeAcct"
    Log "$Tag|STATE|processor|$proc"
    if ($pinned -ne "true") { Die "verify" "evaluatorPinned() is false - every link would stay capped" }
    if ($capT0 -ne "$UNPINNED_CAP" -or $capG -ne "$UNPINNED_CAP") { Die "verify" "unpinned cap wrong: $capT0 / $capG" }
    if ($feeAcct.ToLower() -ne $FEE_ACCT.ToLower()) { Die "verify" "fee account $feeAcct != $FEE_ACCT" }
    if ($proc.ToLower() -ne $circuits.ToLower()) { Die "verify" "processor $proc != $circuits" }
} catch { Die "verify" $_.Exception.Message }

Log "$Tag|RESULT|PASS|12/12 steps + verification, all as real transactions"
exit 0
