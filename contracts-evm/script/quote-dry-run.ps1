<#
Quote-only dry run for the Pago Tier 2 tape-out on X Layer MAINNET (chain 196).

READ-ONLY by construction:
  * chain reads only (cast call / cast gas-price / cast block-number) - no
    transaction is ever signed or broadcast, no key is loaded;
  * public price API reads (CoinGecko) plus the live BEM/WOKB pool spot;
  * one LOCAL fork simulation: `forge test test/QuoteDryRun.t.sol` runs the whole
    tape-out path inside the test EVM against a fork of mainnet. State changes
    stay in that simulation; nothing reaches the chain.

What it prints: every fee in USD next to a UTC timestamp, the measured BEM and
OKB amounts an EMPTY wallet needs to go from zero to a taped-out Split3 plus a
mainnet Pago deploy, and an explicit UNPRICEABLE marker for every step whose
cost has no price source (acquisition fee for OKB, price movement until the
real execution, the swap fill at execution time, any fee beyond gas x price).

Usage:
    powershell -ExecutionPolicy Bypass -File contracts-evm\script\quote-dry-run.ps1
Exit code 0 = quote produced, 1 = a required read or the simulation failed.
#>
param(
    [string]$Rpc = "https://rpc.xlayer.tech",
    [string]$OutDir = (Join-Path $PSScriptRoot "..\..\docs")
)

$ErrorActionPreference = 'Continue'

# ---- constants mirrored from the test (chain 196) ----------------------------
$CHAIN_ID = 196
$FACTORY = '0x1f09DAeFA827f02CBb40967cc91b259763760761'
$BEM = '0x60e62Efa9405d6873C5deaBD4E6CC91c25363952'
$POOL = '0x2ccf8aa17f5df9fb5d51c9de12135a913ff29f7a'
$EXEC_WALLET = '0x3f1004AAeD662227d535D794dA679110111a2FC4' # keystore pago-deployer (read-only check)

$script:logLines = New-Object System.Collections.Generic.List[string]
$script:stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss')

function U { (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss') + 'Z' }

function Say([string]$m) {
    $l = '[{0}] {1}' -f (U), $m
    Write-Host $l
    [void]$script:logLines.Add($l)
}

function SayKv([string]$k, [string]$v) {
    $l = '[{0}] {1,-44} {2}' -f (U), $k, $v
    Write-Host $l
    [void]$script:logLines.Add($l)
}

function Save-Log {
    try {
        if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }
        $path = Join-Path $OutDir ("quote-dry-run-{0}.log" -f $script:stamp)
        $script:logLines | Set-Content -Path $path -Encoding UTF8
        Write-Host ''
        Write-Host ("Transcript saved: {0}" -f $path)
    } catch {
        Write-Host ("(transcript could not be saved: {0})" -f $_.Exception.Message)
    }
}

# Run cast and always return its output as text; stderr is merged in as text
# (never swallowed, never thrown). Retries: DNS/RPC hiccups on this machine and
# this RPC are real - a quote must not die on the first empty answer.
function RunCast([string[]]$argv) {
    $text = ''
    for ($i = 1; $i -le 5; $i++) {
        $out = & cast @argv 2>&1 | ForEach-Object { $_.ToString() }
        $text = (($out -join "`n").Trim())
        if ($text -ne '' -and $text -notmatch '^Error:') { return $text }
        if ($i -lt 5) { Start-Sleep -Seconds 2 }
    }
    return $text
}

function GetJson([string]$url) {
    for ($i = 1; $i -le 4; $i++) {
        try {
            return (Invoke-RestMethod -Uri $url -TimeoutSec 30)
        } catch {
            if ($i -lt 4) { Start-Sleep -Seconds 3 }
        }
    }
    return $null
}

function Usd([double]$v) { return ('${0:N2}' -f $v) }

# ===========================================================================
Say ('=' * 100)
Say 'PAGO TIER 2 TAPE-OUT - QUOTE-ONLY DRY RUN (no transactions, no key, no approvals)'
Say ('RPC: {0}   chain expected: {1} (X Layer mainnet)' -f $Rpc, $CHAIN_ID)
Say ('Quote started at {0}' -f (U))
Say ('=' * 100)

# ---- chain reads ------------------------------------------------------------
$bnRaw = RunCast @('block-number', '--rpc-url', $Rpc)
$gasRaw = RunCast @('gas-price', '--rpc-url', $Rpc)
$block = $null; $gasPrice = $null
if ($bnRaw -match '^\d+$') { $block = [double]$bnRaw } else { Say ("FATAL: cannot read block number: {0}" -f $bnRaw) }
if ($gasRaw -match '^\d+$') { $gasPrice = [double]$gasRaw } else { Say ("FATAL: cannot read gas price: {0}" -f $gasRaw) }
if ($null -eq $block -or $null -eq $gasPrice) { Save-Log; exit 1 }

SayKv 'block number' ('{0:N0}' -f $block)
SayKv 'gas price (wei, live)' ('{0:N0}' -f $gasPrice)
SayKv 'gas price (gwei)' ('{0:N3}' -f ($gasPrice / 1e9))

# ---- price sources ----------------------------------------------------------
Say '- price sources ' + '-' * 60

$okbUsd = $null; $okb24 = $null
$j = GetJson 'https://api.coingecko.com/api/v3/simple/price?ids=okb&vs_currencies=usd&include_24hr_change=true'
if ($j -and $j.okb -and $null -ne $j.okb.usd) {
    $okbUsd = [double]$j.okb.usd
    if ($null -ne $j.okb.'usd_24h_change') { $okb24 = [double]$j.okb.'usd_24h_change' }
    SayKv 'OKB/USD (CoinGecko)' ('{0}  (24h change {1:N2}%)  fetched {2}' -f (Usd $okbUsd), $okb24, (U))
} else {
    SayKv 'OKB/USD (CoinGecko)' ('UNPRICEABLE - fetch failed at {0}' -f (U))
}

$bemUsdCg = $null; $bem24 = $null
$j = GetJson 'https://api.coingecko.com/api/v3/simple/price?ids=bem-2&vs_currencies=usd&include_24hr_change=true'
if ($j -and $j.'bem-2' -and $null -ne $j.'bem-2'.usd) {
    $bemUsdCg = [double]$j.'bem-2'.usd
    if ($null -ne $j.'bem-2'.'usd_24h_change') { $bem24 = [double]$j.'bem-2'.'usd_24h_change' }
    SayKv 'BEM/USD (CoinGecko global)' ('{0}  (24h change {1:N2}%)  fetched {2}' -f (Usd $bemUsdCg), $bem24, (U))
} else {
    SayKv 'BEM/USD (CoinGecko global)' ('UNPRICEABLE - fetch failed at {0}' -f (U))
}

# Live pool spot: token0 = BEM (8 dec), token1 = WOKB (18 dec).
# spot = (sqrtPriceX96 / 2^96)^2 * 1e8 / 1e18  = WOKB per BEM.
$bemPerOkb = $null
$slot = RunCast @('call', $POOL, 'slot0()(uint160,int24,uint16,uint16,uint16,uint8,bool)', '--rpc-url', $Rpc)
if ($slot -match '(\d+)') {
    $sqrtP = [double]$Matches[1]
    $ratio = $sqrtP / [math]::Pow(2, 96)
    $bemPerOkb = $ratio * $ratio * 1e-10
    $bemUsdPool = $null
    if ($null -ne $okbUsd) { $bemUsdPool = $bemPerOkb * $okbUsd }
    if ($null -ne $bemUsdPool) {
        SayKv 'BEM pool spot (BEM/WOKB 1% pool)' ('{0:N6} WOKB/BEM = {1}  read {2}' -f $bemPerOkb, (Usd $bemUsdPool), (U))
    } else {
        SayKv 'BEM pool spot (BEM/WOKB 1% pool)' ('{0:N6} WOKB/BEM (USD needs an OKB price)' -f $bemPerOkb)
    }
} else {
    SayKv 'BEM pool spot (BEM/WOKB 1% pool)' ('UNPRICEABLE - slot0 read failed: {0}' -f $slot)
}

# Which BEM dollar figure to use for the BEM-denominated fee lines.
$bemUsd = $null; $bemUsdSource = 'none'
if ($null -ne $bemUsdCg) { $bemUsd = $bemUsdCg; $bemUsdSource = 'CoinGecko global' }
elseif ($null -ne $bemUsdPool) { $bemUsd = $bemUsdPool; $bemUsdSource = 'pool spot' }

$crossNote = 'n/a'
if ($null -ne $bemUsdCg -and $null -ne $bemUsdPool -and $bemUsdCg -gt 0) {
    $deltaPct = [math]::Abs($bemUsdPool - $bemUsdCg) / $bemUsdCg * 100
    $crossNote = '{0:N1}% apart' -f $deltaPct
    if ($deltaPct -gt 15) {
        $crossNote += ' - DIVERGENT, treat BEM dollar figures as unpriceable'
        $bemUsd = $null; $bemUsdSource = 'none (divergent)'
    }
}
SayKv 'BEM cross-check (pool vs CoinGecko)' $crossNote
SayKv 'BEM price used for fee lines' $bemUsdSource

# ---- fork simulation --------------------------------------------------------
$forgeScriptDir = Split-Path -Parent $PSScriptRoot # contracts-evm
Say '- running the local fork simulation ' + '-' * 40
Say '  (test/QuoteDryRun.t.sol: empty wallet -> swap buyer -> buy BEM -> createCPU (gate price 0) -> mint 104 -> tapeout -> deploy Pago -> sweep)'
Say '  this takes about a minute...'

$forgeOut = ''; $forgeExit = -1
for ($attempt = 1; $attempt -le 2; $attempt++) {
    Push-Location $forgeScriptDir
    try {
        $env:XLAYER_RPC = $Rpc
        $raw = & forge test --match-path 'test/QuoteDryRun.t.sol' -vv 2>&1
        $forgeExit = $LASTEXITCODE
    } finally {
        Pop-Location
    }
    $forgeOut = (($raw | ForEach-Object { $_.ToString() }) -join "`n")
    if ($forgeExit -eq 0 -and $forgeOut -match 'QUOTE\|done\|steps=ok') { break }
    if ($attempt -lt 2) {
        Say ('simulation attempt {0} did not complete (exit {1}) - retrying once in 5 s...' -f $attempt, $forgeExit)
        Start-Sleep -Seconds 5
    }
}

$resultLine = ''
$m = [regex]::Match($forgeOut, '\[(?:PASS|FAIL)[^\]]*\]')
if ($m.Success) { $resultLine = $m.Value }
SayKv 'simulation result' $resultLine

# ---- parse the machine-readable QUOTE lines ---------------------------------
$steps = @{}
$infos = @{}
$warns = New-Object System.Collections.Generic.List[string]
$fails = New-Object System.Collections.Generic.List[string]
foreach ($line in ($forgeOut -split "`r?`n")) {
    if ($line -match 'QUOTE\|info\|([^=]+)=(.*)$') {
        $infos[$Matches[1]] = $Matches[2].Trim()
    } elseif ($line -match 'QUOTE\|WARN\|(.+)$') {
        [void]$warns.Add($Matches[1].Trim())
    } elseif ($line -match 'QUOTE\|FAIL\|(\S+?)=') {
        [void]$fails.Add($Matches[1])
    } elseif ($line -match 'QUOTE\|([A-Za-z0-9]+)\|gas=(\d+)\|bem=(-?\d+)\|okb=(-?\d+)\|wokb=(-?\d+)') {
        $steps[$Matches[1]] = [pscustomobject]@{
            Gas  = [double]$Matches[2]
            Bem  = [double]$Matches[3]
            Okb  = [double]$Matches[4]
            Wokb = [double]$Matches[5]
        }
    }
}

$chainOk = $true
if ($forgeOut -match 'QUOTE\|meta\|forkBlock=(\d+)\|chainid=(\d+)') {
    $forkBlock = $Matches[1]; $chainSeen = [int]$Matches[2]
    SayKv 'forked at block' $forkBlock
    if ($chainSeen -ne $CHAIN_ID) {
        Say ('FATAL: the RPC answered chain id {0}, expected {1} - refusing to price a quote for the wrong chain.' -f $chainSeen, $CHAIN_ID)
        $chainOk = $false
    }
}

$complete = ($forgeOut -match 'QUOTE\|done\|steps=ok')
if ($forgeExit -ne 0 -or -not $complete -or -not $chainOk) {
    Say ''
    Say '*** QUOTE ABORTED - the simulation did not run to completion. Nothing below is a price. ***'
    if ($fails.Count -gt 0) { Say ('failed step(s): {0}' -f ($fails -join ', ')) }
    if ($forgeExit -ne 0 -and $resultLine -eq '') { Say ('forge exit code: {0}' -f $forgeExit) }
    foreach ($line in (($forgeOut -split "`r?`n") | Select-Object -Last 30)) {
        if ($line.Trim() -ne '') { Say ('  | ' + $line.Trim()) }
    }
    Save-Log
    exit 1
}

# ---- facts read out of the simulation ---------------------------------------
Say '- simulation facts (measured on the fork) ' + '-' * 36
$factOrder = @(
    'freshWallet', 'factory', 'bem', 'pool', 'wokb', 'swapBuyer', 'quoteMode',
    'factoryDeployFee', 'factoryProtocolFee', 'gatePrice',
    'buyBem_amount0_delta_bem', 'buyBem_amount1_delta_wokb',
    'mintPrice_bemUnits', 'transistorsProtocolFee_wei', 'mintRoute',
    'tapeoutFee_wei', 'netlistBytes', 'circuitId', 'netlistServedBack',
    'recordedShellCodehash', 'recordedBeacon', 'beaconReportsImpl', 'recordedImplCodehash',
    'beaconMatchesRecorded18', 'implMatchesRecorded18', 'implHashMatchesRecorded18',
    'pagoAddress', 'evaluatorPinned', 'deployConfigNote',
    'leftoverBemToSweep_bemUnits', 'leftoverOkbToSweep_wei', 'sweepRecipient',
    'freshBemAfterSweep_units', 'freshOkbAfterSweep_wei'
)
foreach ($k in $factOrder) {
    if ($infos.ContainsKey($k)) { SayKv $k $infos[$k] }
}

# ---- read-only check of the existing execution keystore address -------------
$execBal = RunCast @('balance', $EXEC_WALLET, '--rpc-url', $Rpc)
$execNonce = RunCast @('nonce', $EXEC_WALLET, '--rpc-url', $Rpc)
$execBem = RunCast @('call', $BEM, 'balanceOf(address)(uint256)', $EXEC_WALLET, '--rpc-url', $Rpc)
Say '- execution wallet (keystore pago-deployer, read-only) ' + '-' * 20
SayKv 'native balance (OKB)' $execBal
SayKv 'nonce' $execNonce
SayKv 'BEM balance' $execBem
if ($execBal -eq '0') {
    Say '  note: this wallet is currently EMPTY - the funding figure below is exactly what it needs.'
} else {
    Say '  note: this wallet already holds funds; the quote below is still start-from-zero (conservative).'
}

# ---- price every step -------------------------------------------------------
$labels = [ordered]@{
    'wrap'              = 'wrap OKB -> WOKB'
    'deployBuyer'       = 'deploy swap buyer (callback)'
    'approveBuyer'      = 'approve WOKB : swap buyer'
    'buyBem'            = 'buy 0.132 BEM (1% pool)'
    'unwrap'            = 'unwrap leftover WOKB'
    'approveFactory'    = 'approve BEM : factory'
    'createCpu'         = 'createCPU (processor)'
    'approveTransistors'= 'approve BEM : transistors'
    'mint'              = 'mint 104 transistors'
    'mintValueRoute'    = 'mint 104 (value route)'
    'tapeout'           = 'tapeout Split3'
    'deployPago'        = 'deploy Pago (mainnet)'
    'sweepBem'          = 'sweep leftover BEM'
    'sweepOkb'          = 'sweep leftover OKB'
}

function MoveOf($s) {
    $parts = @()
    if ($s.Bem -ne 0)  { $parts += ('{0:+0.000000;-0.000000} BEM' -f ($s.Bem / 1e8)) }
    if ($s.Okb -ne 0)  { $parts += ('{0:+0.000000;-0.000000} OKB' -f ($s.Okb / 1e18)) }
    if ($s.Wokb -ne 0) { $parts += ('{0:+0.000000;-0.000000} WOKB' -f ($s.Wokb / 1e18)) }
    if ($parts.Count -eq 0) { return '-' }
    return ($parts -join ' ')
}

function GasUsdOf([double]$gas) {
    if ($null -eq $okbUsd) { return '[UNPRICEABLE]' }
    return (Usd ($gas * $gasPrice * $okbUsd / 1e18))
}

function TokenUsdOf([string]$name, $s) {
    switch ($name) {
        'buyBem' {
            if ($null -eq $okbUsd) { return '[UNPRICEABLE]' }
            return (Usd ((-$s.Wokb) / 1e18 * $okbUsd))
        }
        'createCpu' {
            if ($null -eq $bemUsd) { return '[UNPRICEABLE]' }
            $u = 0.0
            if ($s.Bem -lt 0) { $u += (-$s.Bem) / 1e8 }
            if ($s.Okb -ne 0) { if ($null -eq $okbUsd) { return '[UNPRICEABLE]' }; $u += (-$s.Okb) / 1e18 * $okbUsd }
            return (Usd ($u * $bemUsd))
        }
        { $_ -in @('mint', 'mintValueRoute') } {
            if ($null -eq $bemUsd) { return '[UNPRICEABLE]' }
            $u = 0.0
            if ($s.Bem -lt 0) { $u += (-$s.Bem) / 1e8 }
            if ($u -gt 0) { $u = $u * $bemUsd }
            if ($s.Okb -ne 0) {
                if ($null -eq $okbUsd) { return '[UNPRICEABLE]' }
                $u += (-$s.Okb) / 1e18 * $okbUsd
            }
            return (Usd $u)
        }
        'tapeout' {
            if ($null -eq $okbUsd) { return '[UNPRICEABLE]' }
            return (Usd ((-$s.Okb) / 1e18 * $okbUsd))
        }
        default { return '-' }
    }
}

Say ''
Say '- per-step quote (USD at the prices and gas price above) ' + '-' * 27
$hdr = '  {0,-22} {1,10} {2,10}  {3,-36} {4,10}' -f 'STEP', 'GAS', 'GAS USD', 'TOKEN MOVE', 'TOKEN USD'
Say $hdr
Say ('  {0}' -f ('-' * ($hdr.Length - 2)))

$gasSum = 0.0; $txCount = 0
foreach ($name in $labels.Keys) {
    if (-not $steps.ContainsKey($name)) { continue }
    $s = $steps[$name]
    $gasSum += $s.Gas; $txCount++
    $row = '  {0,-22} {1,10} {2,10}  {3,-36} {4,10}' -f `
        $name, ('{0:N0}' -f $s.Gas), (GasUsdOf $s.Gas), (MoveOf $s), (TokenUsdOf $name $s)
    Say $row
}
# any step the label map does not know (never expected - report loudly if seen)
foreach ($name in $steps.Keys) {
    if (-not $labels.Contains($name)) {
        Say ('  !! unexpected step id in output: {0} (priced as gas only)' -f $name)
        $gasSum += $steps[$name].Gas; $txCount++
        $row = '  {0,-22} {1,10} {2,10}  {3,-36} {4,10}' -f `
            $name, ('{0:N0}' -f $steps[$name].Gas), (GasUsdOf $steps[$name].Gas), (MoveOf $steps[$name]), '-'
        Say $row
    }
}

# ---- totals -----------------------------------------------------------------
$swapWokb = 0.0
if ($steps.ContainsKey('buyBem')) { $swapWokb = (-$steps['buyBem'].Wokb) / 1e18 }
$tapeoutOkb = 0.0
if ($steps.ContainsKey('tapeout')) { $tapeoutOkb = (-$steps['tapeout'].Okb) / 1e18 }

$gasBuffered = ($gasSum + 21000 * $txCount) * 1.20
$gasOkb = $gasBuffered * $gasPrice / 1e18

$bemBuy = 0.0
if ($steps.ContainsKey('buyBem')) { $bemBuy = $steps['buyBem'].Bem / 1e8 }
$bemSpent = 0.0
if ($steps.ContainsKey('createCpu') -and $steps['createCpu'].Bem -lt 0) { $bemSpent += (-$steps['createCpu'].Bem) / 1e8 }
$mintKey = $null
if ($steps.ContainsKey('mint')) { $mintKey = 'mint' }
elseif ($steps.ContainsKey('mintValueRoute')) { $mintKey = 'mintValueRoute' }
if ($mintKey -and $steps[$mintKey].Bem -lt 0) { $bemSpent += (-$steps[$mintKey].Bem) / 1e8 }

$swapAllowance = $swapWokb * 1.01 # 1% price-move allowance between quote and execution
$fundOkb = $swapAllowance + $tapeoutOkb + $gasOkb + 0.0005

$swapUsd = $null; $tapeoutUsd = $null; $gasUsd = $null; $totalUsd = $null; $fundUsd = $null
if ($null -ne $okbUsd) {
    $swapUsd = $swapWokb * $okbUsd
    $tapeoutUsd = $tapeoutOkb * $okbUsd
    $gasUsd = $gasOkb * $okbUsd
    $totalUsd = $swapUsd + $tapeoutUsd + $gasUsd
    $fundUsd = $fundOkb * $okbUsd
}

$effPerBem = $null
if ($null -ne $swapUsd -and $bemBuy -gt 0) { $effPerBem = $swapUsd / $bemBuy }

Say ''
Say '- totals ' + '-' * 78
SayKv 'transactions priced' ('{0}' -f $txCount)
SayKv 'raw execution gas' ('{0:N0} units' -f $gasSum)
SayKv 'buffered gas (+21k/tx, +20%)' ('{0:N0} units' -f $gasBuffered)
SayKv 'BEM bought incl. 20% buffer' ('{0:N6} BEM' -f $bemBuy)
SayKv 'BEM spent (createCPU + transistor mint)' ('{0:N6} BEM' -f $bemSpent)
$bemLeft = 0.0
if ($infos.ContainsKey('leftoverBemToSweep_bemUnits')) { $bemLeft = [double]$infos['leftoverBemToSweep_bemUnits'] / 1e8 }
SayKv 'BEM leftover (swept back to owner)' ('{0:N6} BEM' -f $bemLeft)
if ($bemBuy + 1e-9 -lt $bemSpent) {
    Say ('*** buffer check FAILED: bought {0:N6} BEM but the steps spend {1:N6} - raise the buy amount. ***' -f $bemBuy, $bemSpent)
}

Say ''
SayKv 'BEM fill cost (OKB -> BEM swap)' ('{0:N6} OKB = {1}' -f $swapWokb, $(if ($null -ne $swapUsd) { Usd $swapUsd } else { '[UNPRICEABLE]' }))
if ($null -ne $effPerBem) {
    SayKv 'effective BEM price paid (incl. 1% fee+impact)' (Usd $effPerBem)
}
if ($null -ne $bemUsd) {
    SayKv 'BEM market price used for fee lines' ('{0} ({1})' -f (Usd $bemUsd), $bemUsdSource)
}
SayKv 'tape-out protocol fee' ('{0:N6} OKB = {1}' -f $tapeoutOkb, $(if ($null -ne $tapeoutUsd) { Usd $tapeoutUsd } else { '[UNPRICEABLE]' }))
SayKv 'gas total (buffered)' ('{0:N6} OKB = {1}' -f $gasOkb, $(if ($null -ne $gasUsd) { Usd $gasUsd } else { '[UNPRICEABLE]' }))
Say ''
if ($null -ne $totalUsd) {
    SayKv '>>> TIER 2 QUOTED TOTAL (USD)' (Usd $totalUsd)
    SayKv '>>> FUND THE FRESH WALLET WITH' ('{0:N6} OKB = {1}   (incl. 1% price-move allowance + 20% gas buffer + 0.0005 dust)' -f $fundOkb, (Usd $fundUsd))
} else {
    SayKv '>>> TIER 2 QUOTED TOTAL' 'UNPRICEABLE - no OKB/USD price source in this run'
    SayKv '>>> FUND THE FRESH WALLET WITH' ('{0:N6} OKB (USD UNPRICEABLE - no OKB/USD price source)' -f $fundOkb)
}
Say '    the fee to ACQUIRE that OKB (exchange withdrawal / P2P) is NOT part of these figures.'

# ---- warnings and unpriceable markers ---------------------------------------
$unpriceable = New-Object System.Collections.Generic.List[string]
[void]$unpriceable.Add('OKB acquisition: the fee/venue to turn fiat or exchange balance into OKB on X Layer (chain 196) - only the PRINCIPAL is priced above.')
[void]$unpriceable.Add('Price movement between this quote and execution: BEM 24h change {0}; thin 1% pool - re-run this script immediately before buying.' -f $(if ($null -ne $bem24) { '{0:N1}%' -f $bem24 } else { 'unknown' }))
[void]$unpriceable.Add('Swap fill at execution time: the fill above is exact as of the forked block ({0}); pool state will differ when the real swap runs.' -f $forkBlock)
[void]$unpriceable.Add('Any chain fee component beyond gas x gas price: X Layer receipts expose no separate fee field, so none was priced - verify on the first real transaction.')
if ($null -eq $okbUsd) { [void]$unpriceable.Add('OKB/USD price source FAILED - every dollar figure above is UNPRICEABLE.') }
if ($null -eq $bemUsd) { [void]$unpriceable.Add('BEM/USD price source FAILED or divergent - BEM fee lines are UNPRICEABLE.') }

Say ''
Say '- UNPRICEABLE (no price source; disclosed, not silently omitted) ' + '-' * 16
$n = 1
foreach ($u in $unpriceable) { Say ('  {0}. {1}' -f $n, $u); $n++ }

if ($warns.Count -gt 0) {
    Say ''
    Say '- WARNINGS from the simulation ' + '-' * 46
    foreach ($w in $warns) { Say ('  ! ' + $w) }
}

Say ''
Say ('Quote completed at {0}' -f (U))
Say ('Every figure above carries that timestamp: prices, gas and fills are point-in-time and must be re-quoted before execution.')
Say ('=' * 100)

Save-Log
exit 0
