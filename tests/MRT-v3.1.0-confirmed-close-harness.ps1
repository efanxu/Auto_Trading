Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
$pinePath = Join-Path $repoRoot "MRT.pine"
$source = Get-Content -Raw -LiteralPath $pinePath
$failures = [System.Collections.Generic.List[string]]::new()

function Assert-True {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) { $failures.Add($Message) }
}

function Get-Decision {
    param(
        [int] $Direction,
        [double] $Close,
        [double] $Risk,
        [double] $Trim,
        [double] $Final,
        [bool] $PartialTaken,
        [int] $EntryBar,
        [int] $PartialBar,
        [int] $BarIndex,
        [bool] $TrendFailed = $false,
        [bool] $TimedOut = $false,
        [bool] $Confirmed = $true,
        [bool] $FillSync = $false,
        [bool] $PendingOrder = $false
    )

    if (-not $Confirmed -or $FillSync -or $PendingOrder -or $BarIndex -le $EntryBar) { return "None" }
    if ($PartialTaken -and $BarIndex -le $PartialBar) { return "None" }

    $stopFailed = if ($Direction -eq 1) { $Close -le $Risk } else { $Close -ge $Risk }
    $trimReached = -not $PartialTaken -and $(if ($Direction -eq 1) { $Close -ge $Trim } else { $Close -le $Trim })
    $finalReached = $PartialTaken -and $BarIndex -gt $PartialBar -and $(if ($Direction -eq 1) { $Close -ge $Final } else { $Close -le $Final })

    if ($stopFailed) { return $(if ($PartialTaken) { "BE" } else { "Stop" }) }
    if ($TrendFailed) { return "Trend" }
    if ($TimedOut) { return "Timeout" }
    if ($trimReached) { return "Trim" }
    if ($finalReached) { return "Final" }
    return "None"
}

function Get-ConsistencyState {
    param(
        [double] $PreviousSize,
        [double] $CurrentSize,
        [bool] $Active,
        [int] $LifecycleDirection,
        [bool] $PendingEntry,
        [int] $PendingDirection,
        [bool] $FullExitPending = $false
    )

    $brokerDirection = if ($CurrentSize -gt 0) { 1 } elseif ($CurrentSize -lt 0) { -1 } else { 0 }
    if ($PreviousSize * $CurrentSize -lt 0) { return "RECOVERY" }
    if ($PendingEntry -and $PreviousSize -eq 0 -and $CurrentSize -ne 0 -and $brokerDirection -eq $PendingDirection) { return "ENTRY_FILL" }
    if ($Active -and $CurrentSize -eq 0 -and $FullExitPending) { return "FULL_EXIT" }
    if ($Active -and $CurrentSize -eq 0) { return "RECOVERY" }
    if ($Active -and $brokerDirection -eq $LifecycleDirection) { return "ACTIVE" }
    if (-not $Active -and -not $PendingEntry -and $CurrentSize -ne 0) { return "RECOVERY" }
    if ($CurrentSize -eq 0) { return "FLAT" }
    return "RECOVERY"
}

# Version, execution settings, and unchanged parameter defaults.
Assert-True ($source -match 'SCRIPT_VERSION\s*=\s*"3\.1\.0"') 'SCRIPT_VERSION must be 3.1.0.'
Assert-True ($source -match 'process_orders_on_close\s*=\s*false') 'Orders must fill at the next available tick.'
Assert-True ($source -match 'calc_on_every_tick\s*=\s*false') 'Tick-by-tick decisions must remain disabled.'
Assert-True ($source -match 'calc_on_order_fills\s*=\s*true') 'Fill synchronization must remain enabled.'
Assert-True ($source -match 'pyramiding\s*=\s*0') 'Pyramiding must remain zero.'

$defaultContracts = @(
    'meanLen\s*=\s*input\.int\(32,', 'zLen\s*=\s*input\.int\(32,',
    'rangeEntryZ\s*=\s*input\.float\(1\.65,', 'shockEntryZ\s*=\s*input\.float\(2\.00,',
    'rangePartialZ\s*=\s*input\.float\(0\.80,', 'rangeExitZ\s*=\s*input\.float\(0\.25,',
    'shockPartialZ\s*=\s*input\.float\(1\.00,', 'shockExitZ\s*=\s*input\.float\(0\.50,',
    'stopZ\s*=\s*input\.float\(3\.25,', 'rangeMinScore\s*=\s*input\.float\(50\.0,',
    'shockMinScore\s*=\s*input\.float\(45\.0,', 'hardStopATR\s*=\s*input\.float\(2\.50,',
    'stopMode\s*=\s*input\.string\("Balanced",', 'balancedWeight\s*=\s*input\.float\(0\.50,',
    'trimPct\s*=\s*input\.float\(50\.0,', 'allowLong\s*=\s*input\.bool\(true,',
    'allowShort\s*=\s*input\.bool\(true,'
)
foreach ($contract in $defaultContracts) {
    Assert-True ($source -match $contract) "Default parameter contract missing: $contract"
}

# Confirmed-close Entry and frozen-context contracts.
Assert-True ($source -match 'allowBarCloseDecision\s*=\s*barstate\.isconfirmed\s+and\s+not\s+isFillSynchronizationExecution') 'Confirmed-close decision gate is missing.'
Assert-True ($source -match 'longShockSetup\s*=\s*longShockRejectionCandidate\s+and\s+noSameLong') 'Long Shock Setup formula or duplicate guard changed.'
Assert-True ($source -match 'shortShockSetup\s*=\s*shortShockRejectionCandidate\s+and\s+noSameShort') 'Short Shock Setup must mirror Long.'
Assert-True ($source -match 'longRangeSetup\s*=\s*allowLong\s+and\s+rangeEnvironment\s+and\s+z\s*<=\s*-rangeEntryZ\s+and\s+noSameLong') 'Long Range Setup formula changed.'
Assert-True ($source -match 'shortRangeSetup\s*=\s*allowShort\s+and\s+rangeEnvironment\s+and\s+z\s*>=\s*rangeEntryZ\s+and\s+noSameShort') 'Short Range Setup must mirror Long.'
Assert-True ($source -match 'if longShockSetup[\s\S]*else if shortShockSetup[\s\S]*else if longRangeSetup[\s\S]*else if shortRangeSetup') 'Shock Setup priority over Range changed.'
Assert-True ($source -match 'priceBandReclaim\s*:=\s*close\s*>\s*mean15\s*-\s*entryZ\s*\*\s*safeStd') 'Long band reclaim must use the Entry-Z price boundary.'
Assert-True ($source -match 'priceBandReclaim\s*:=\s*close\s*<\s*mean15\s*\+\s*entryZ\s*\*\s*safeStd') 'Short band reclaim must mirror the Entry-Z price boundary.'
Assert-True ($source -notmatch 'priceBandReclaim\s*:=\s*residual\s*[<>]\s*residual\[1\]') 'Residual momentum must not replace band reclaim.'
Assert-True ($source -match 'longEntrySignal[\s\S]*zReclaim\s+and\s+bandOK\s+and\s+candleOK') 'Long Entry must require Z reclaim, band, and candle confirmation.'
Assert-True ($source -match 'shortEntrySignal[\s\S]*zReclaim\s+and\s+bandOK\s+and\s+candleOK') 'Short Entry must require Z reclaim, band, and candle confirmation.'
Assert-True ($source -match 'strategy\.position_avg_price') 'Actual Strategy Tester average price must initialize Entry.'
Assert-True ($source -match 'partialTarget\s*:=\s*fillState\.mean\s*-\s*dir\s*\*\s*pz\s*\*\s*fillState\.std') 'Frozen partial target formula is missing.'
Assert-True ($source -match 'finalTarget\s*:=\s*fillState\.mean\s*-\s*dir\s*\*\s*ez\s*\*\s*fillState\.std') 'Frozen final target formula is missing.'

# Real market orders only: no normal intrabar bracket orders.
Assert-True ($source -match 'strategy\.entry\("MR-L",\s*strategy\.long') 'Long Entry ID is missing.'
Assert-True ($source -match 'strategy\.entry\("MR-S",\s*strategy\.short') 'Short Entry ID is missing.'
Assert-True ($source -match 'strategy\.close\(trimEntryId,[^\r\n]*qty_percent\s*=\s*trimPct[^\r\n]*immediately\s*=\s*false') 'Trim must be a next-tick partial market close using trimPct.'
Assert-True ($source -match 'strategy\.close\(closeEntryId,[^\r\n]*immediately\s*=\s*false') 'Full exits must be next-tick market closes.'
Assert-True ($source -notmatch 'strategy\.order\s*\(') 'Normal lifecycle must not use strategy.order price brackets.'
Assert-True ($source -notmatch 'strategy\.exit\s*\(') 'Normal lifecycle must not use strategy.exit price brackets.'
Assert-True ($source -notmatch 'MR-[LS]-(?:STOP|TRIM|FINAL)') 'Legacy STOP/TRIM/FINAL order IDs must be absent.'
Assert-True ($source -notmatch 'oca_(?:name|type)\s*=') 'OCA bracket management must be absent.'

# Lifecycle source guardrails and diagnostics.
Assert-True ($source -match 'bar_index\s*>\s*fillState\.entryBar') 'Entry fill bar must not be managed.'
Assert-True ($source -match 'bar_index\s*>\s*fillState\.partialBar') 'Final/BE phase must begin after the Trim fill bar.'
Assert-True ($source -match 'stopFailed[\s\S]*else if trendFailed[\s\S]*else if timeFailed[\s\S]*else if trimReached[\s\S]*else if finalReached') 'Exit priority must be Stop, Trend, Timeout, Trim, Final.'
Assert-True ($source -match 'dir\s*\*\s*htfSlopeATR\s*<=\s*-vetoHtfSlope\s+or\s+dir\s*\*\s*localSlopeATR\s*<=\s*-vetoLocalSlope') 'Trend Fail formula changed.'
Assert-True ($source -match 'bar_index\s*-\s*fillState\.entryBar\)\s*>=\s*fillState\.timeStop') 'Timeout formula changed.'
Assert-True ($source -match 'consistencyRecoveryCount') 'Consistency recovery diagnostic is missing.'
Assert-True ($source -match 'fullExitFilled\s*=\s*positionClosed[\s\S]*fillState\.exitRequested\s+and\s+fillState\.marketClosePlaced') 'A full exit must be attributed only to a pending lifecycle close.'
Assert-True ($source -match 'Pending Trim Fill') 'Pending Trim fill state is not surfaced.'
Assert-True ($source -match 'Pending Full Exit Fill') 'Pending full-exit state is not surfaced.'
Assert-True ($source -match 'pendingEntry') 'Pending Entry state is missing.'
Assert-True ($source -match 'trimRequested') 'Pending Trim fill state is missing.'
Assert-True ($source -match 'exitRequested') 'Pending Full Exit state is missing.'
Assert-True ($source -match 'rangeEntries\s*\+=\s*1[\s\S]*shockEntries\s*\+=\s*1') 'Range/Shock Entry attribution is missing.'
Assert-True ($source -match 'rangeClosed\s*\+=\s*1[\s\S]*shockClosed\s*\+=\s*1') 'Range/Shock lifecycle Close attribution is missing.'

$shockFields = @('Shock Z Candidates', 'Shock Move Candidates', 'Shock Environment Pass', 'Shock Deceleration Pass', 'Shock Rejection Pass', 'Shock Setups', 'Shock Confirmed Entries')
foreach ($field in $shockFields) { Assert-True ($source.Contains($field)) "Shock funnel field missing: $field" }

# Long/Short confirmed-close lifecycle model.
Assert-True ((Get-ConsistencyState 0 100 $false 0 $true 1) -eq 'ENTRY_FILL') 'Long Entry fill transition failed.'
Assert-True ((Get-ConsistencyState 0 -100 $false 0 $true -1) -eq 'ENTRY_FILL') 'Short Entry fill transition failed.'
Assert-True ((Get-Decision 1 110 90 105 108 $false 10 -1 10) -eq 'None') 'Long Entry bar must not Trim.'
Assert-True ((Get-Decision -1 90 110 95 92 $false 10 -1 10) -eq 'None') 'Short Entry bar must not Trim.'
Assert-True ((Get-Decision 1 106 90 105 108 $false 10 -1 11) -eq 'Trim') 'Long confirmed close must trigger Trim.'
Assert-True ((Get-Decision -1 94 110 95 92 $false 10 -1 11) -eq 'Trim') 'Short confirmed close must trigger Trim.'
Assert-True ((Get-ConsistencyState 100 50 $true 1 $false 0) -eq 'ACTIVE') 'Long real Trim fill must remain active.'
Assert-True ((Get-ConsistencyState -100 -50 $true -1 $false 0) -eq 'ACTIVE') 'Short real Trim fill must remain active.'
Assert-True ((Get-Decision 1 109 101 105 108 $true 10 12 12) -eq 'None') 'Trim fill bar must not trigger BE or Final.'
Assert-True ((Get-Decision -1 91 99 95 92 $true 10 12 12) -eq 'None') 'Short Trim fill bar must not trigger BE or Final.'
Assert-True ((Get-Decision 1 109 101 105 108 $true 10 12 13) -eq 'Final') 'Long Final must be eligible after the Trim fill bar.'
Assert-True ((Get-Decision -1 91 99 95 92 $true 10 12 13) -eq 'Final') 'Short Final must be eligible after the Trim fill bar.'
Assert-True ((Get-Decision 1 89 90 105 108 $false 10 -1 11) -eq 'Stop') 'Long close-confirmed Stop failed.'
Assert-True ((Get-Decision -1 111 110 95 92 $false 10 -1 11) -eq 'Stop') 'Short close-confirmed Stop failed.'
Assert-True ((Get-Decision 1 100 101 105 108 $true 10 11 12) -eq 'BE') 'Long post-Trim BE failed.'
Assert-True ((Get-Decision -1 100 99 95 92 $true 10 11 12) -eq 'BE') 'Short post-Trim BE failed.'
Assert-True ((Get-Decision 1 100 90 105 108 $false 10 -1 11 -TrendFailed $true) -eq 'Trend') 'Trend Fail decision failed.'
Assert-True ((Get-Decision -1 100 110 95 92 $false 10 -1 11 -TimedOut $true) -eq 'Timeout') 'Timeout decision failed.'
Assert-True ((Get-Decision 1 106 90 105 108 $false 10 -1 11 -Confirmed $false) -eq 'None') 'Unconfirmed bars must not decide.'
Assert-True ((Get-Decision 1 106 90 105 108 $false 10 -1 11 -FillSync $true) -eq 'None') 'Fill recalculation must only synchronize.'

# Cross-date holding is represented by continuous bar indexes; there is no date/session exit.
Assert-True ((Get-Decision 1 100 90 105 108 $false 199 -1 200) -eq 'None') 'Cross-date position should remain active without an exit condition.'
Assert-True ($source -notmatch 'dayofmonth|dayofweek|session\.islastbar|time_tradingday') 'A date/session liquidation rule was introduced.'

$normalRecoveryCount = 0
foreach ($state in @(
    (Get-ConsistencyState 0 100 $false 0 $true 1),
    (Get-ConsistencyState 100 50 $true 1 $false 0),
    (Get-ConsistencyState 50 0 $true 1 $false 0 $true),
    (Get-ConsistencyState 0 -100 $false 0 $true -1),
    (Get-ConsistencyState -100 -50 $true -1 $false 0),
    (Get-ConsistencyState -50 0 $true -1 $false 0 $true)
)) { if ($state -eq 'RECOVERY') { $normalRecoveryCount++ } }
Assert-True ($normalRecoveryCount -eq 0) 'Normal Long/Short lifecycles must require zero consistency recoveries.'
Assert-True ((Get-ConsistencyState -50 25 $true -1 $false 0) -eq 'RECOVERY') 'Direct reversal recovery protection failed.'
Assert-True ((Get-ConsistencyState 25 25 $false 0 $false 0) -eq 'RECOVERY') 'Orphan broker recovery protection failed.'
Assert-True ((Get-ConsistencyState 25 0 $true 1 $false 0) -eq 'RECOVERY') 'Unrequested active-to-flat transition must recover.'

if ($failures.Count -gt 0) {
    Write-Host "FAIL: $($failures.Count) assertion(s)"
    $failures | ForEach-Object { Write-Host " - $_" }
    exit 1
}

Write-Host "PASS: MRT v3.1.0 confirmed-close lifecycle contract"
