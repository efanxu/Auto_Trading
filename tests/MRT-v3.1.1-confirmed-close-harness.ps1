Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
$pinePath = Join-Path $repoRoot "MRT.pine"
$source = [System.IO.File]::ReadAllText($pinePath)
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
        [int] $EntryDecisionBar,
        [int] $TrimDecisionBar,
        [int] $BarIndex,
        [int] $TimeStop = -1,
        [bool] $TrendFailed = $false,
        [bool] $Confirmed = $true,
        [bool] $FillSync = $false,
        [bool] $PendingTrim = $false,
        [bool] $PendingFullExit = $false
    )

    if (-not $Confirmed -or $FillSync -or $PendingTrim -or $PendingFullExit -or $BarIndex -le $EntryDecisionBar) { return "None" }
    if ($PartialTaken -and ($TrimDecisionBar -lt 0 -or $BarIndex -le $TrimDecisionBar)) { return "None" }

    $stopFailed = if ($Direction -eq 1) { $Close -le $Risk } else { $Close -ge $Risk }
    $trimReached = -not $PartialTaken -and $(if ($Direction -eq 1) { $Close -ge $Trim } else { $Close -le $Trim })
    $finalReached = $PartialTaken -and $TrimDecisionBar -ge 0 -and $BarIndex -gt $TrimDecisionBar -and $(if ($Direction -eq 1) { $Close -ge $Final } else { $Close -le $Final })
    $timeFailed = $TimeStop -ge 0 -and ($BarIndex - $EntryDecisionBar) -ge $TimeStop

    if ($stopFailed) { return $(if ($PartialTaken) { "BE" } else { "Stop" }) }
    if ($TrendFailed) { return "Trend" }
    if ($timeFailed) { return "Timeout" }
    if ($trimReached) { return "Trim" }
    if ($finalReached) { return "Final" }
    return "None"
}

function Get-CooldownEligibility {
    param(
        [int] $ExitDecisionBar,
        [int] $BarIndex,
        [int] $CooldownBars
    )

    $requiredCooldown = [Math]::Max($CooldownBars, 1)
    return $BarIndex - $ExitDecisionBar -ge $requiredCooldown
}

function Get-FillAction {
    param([string] $Phase)

    switch ($Phase) {
        "Entry" { return "None" }
        "Trim" { return "None" }
        "FullExit" { return "LifecycleSynchronizationOnly" }
        default { return "None" }
    }
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

function Get-StaticAssignmentType {
    param([string] $Line)

    if ([string]::IsNullOrWhiteSpace($Line)) { return "unknown" }
    if ($Line -match '(?i)\b(?:true|false)\b') { return "bool" }
    if ($Line.Contains('"')) { return "string" }
    if ($Line -match '(?i)\b(?:MANAGE_|R_|CONSISTENCY_)[A-Z_0-9]+') { return "int" }
    if ($Line -match '(?:\+=|-=)\s*\d+(?:\.\d+)?\s*$') { return "int" }
    if ($Line -match ':=\s*-?\d+\s*$') { return "int" }
    return "unknown"
}

# Version, execution settings, and unchanged parameter defaults.
Assert-True ($source -match 'SCRIPT_VERSION\s*=\s*"3\.1\.1"') 'SCRIPT_VERSION must be 3.1.1.'
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

# Decision-bar fields are strategy-time anchors; fill-bar fields are broker facts.
Assert-True ($source -match 'varip int\s+entryDecisionBar\s*=\s*na') 'entryDecisionBar field is missing.'
Assert-True ($source -match 'varip int\s+entryFillBar\s*=\s*na') 'entryFillBar field is missing.'
Assert-True ($source -match 'varip int\s+trimDecisionBar\s*=\s*na') 'trimDecisionBar field is missing.'
Assert-True ($source -match 'varip int\s+trimFillBar\s*=\s*na') 'trimFillBar field is missing.'
Assert-True ($source -match 'varip int\s+exitDecisionBar\s*=\s*na') 'exitDecisionBar field is missing.'
Assert-True ($source -match 'entryDecisionBar\s*:=\s*fillState\.pendingBar[\s\S]*entryFillBar\s*:=\s*bar_index') 'Entry decision/fill bars are not captured separately.'
Assert-True ($source -match 'trimFillBar\s*:=\s*bar_index') 'Trim fill bar is not captured.'
Assert-True ($source -match 'plot\(fillState\.entryDecisionBar,\s*"Entry Decision Bar"') 'Entry decision bar diagnostic is not exposed.'
Assert-True ($source -match 'plot\(fillState\.entryFillBar,\s*"Entry Fill Bar"') 'Entry fill bar diagnostic is not exposed.'
Assert-True ($source -match 'plot\(fillState\.trimDecisionBar,\s*"Trim Decision Bar"') 'Trim decision bar diagnostic is not exposed.'
Assert-True ($source -match 'plot\(fillState\.trimFillBar,\s*"Trim Fill Bar"') 'Trim fill bar diagnostic is not exposed.'
Assert-True ($source -match 'plot\(fillState\.exitDecisionBar,\s*"Exit Decision Bar"') 'Exit decision bar diagnostic is not exposed.'
Assert-True ($source -notmatch '(?<!Decision)entryBar') 'Legacy entryBar timing anchor remains.'
Assert-True ($source -notmatch 'partialBar') 'Legacy partialBar timing anchor remains.'
Assert-True ($source -match 'bar_index\s*>\s*fillState\.entryDecisionBar') 'Entry management must use entryDecisionBar.'
Assert-True ($source -match 'bar_index\s*>\s*fillState\.trimDecisionBar') 'Post-Trim management must use trimDecisionBar.'
Assert-True ($source -match 'canManage\s*=\s*[\s\S]*not\s+fillState\.trimRequested\s+and\s+not\s+fillState\.exitRequested') 'f_manage must block pending Trim and full-exit orders.'
Assert-True ($source -match 'bar_index\s*-\s*fillState\.entryDecisionBar\)\s*>=\s*fillState\.timeStop') 'TimeStop must use entryDecisionBar.'
Assert-True ($source -match 'cooldownDecisionBar\s*=\s*na\(fillState\.exitDecisionBar\)\s*\?\s*bar_index\s*:\s*fillState\.exitDecisionBar[\s\S]*fillState\.lastExitBar\s*:=\s*cooldownDecisionBar') 'Cooldown must persist exitDecisionBar rather than the fill bar.'
Assert-True ($source -match 'exitDecisionBar\s*:=\s*bar_index') 'Exit decisions must capture exitDecisionBar.'
Assert-True ($source -match 'isFillSynchronizationExecution\s*=\s*positionChanged') 'Broker position changes must identify fill recalculations.'

# f_manage must have one explicit int result, and all user-defined if/else chains
# must have a consistent statically inferable terminal assignment type.
$manageMatch = [regex]::Match($source, '(?ms)^f_manage\([^\r\n]*\)\s*=>\s*(?<body>.*?)(?=^//|\z)')
Assert-True $manageMatch.Success 'f_manage definition could not be located.'
if ($manageMatch.Success) {
    $manageBody = $manageMatch.Groups['body'].Value
    Assert-True ($manageBody -match 'int\s+decisionCode\s*=\s*MANAGE_NONE') 'f_manage must initialize a single int decisionCode.'
    Assert-True ($manageBody -match 'decisionCode\s*:=\s*MANAGE_STOP_BE') 'Stop/BE must set the unified management code.'
    Assert-True ($manageBody -match 'decisionCode\s*:=\s*MANAGE_TREND') 'Trend must set the unified management code.'
    Assert-True ($manageBody -match 'decisionCode\s*:=\s*MANAGE_TIMEOUT') 'Timeout must set the unified management code.'
    Assert-True ($manageBody -match 'decisionCode\s*:=\s*MANAGE_TRIM') 'Trim must set the unified management code.'
    Assert-True ($manageBody -match 'decisionCode\s*:=\s*MANAGE_FINAL') 'Final must set the unified management code.'
    Assert-True ($manageBody -match '(?ms)\r?\n\s+decisionCode\s*\r?\n\s*$') 'f_manage must explicitly return decisionCode as its final expression.'
}

$pineLines = $source -split "`r?`n"
$functionStarts = [System.Collections.Generic.List[int]]::new()
for ($i = 0; $i -lt $pineLines.Count; $i++) {
    if ($pineLines[$i] -match '^f_[A-Za-z0-9_]+\([^\r\n]*\)\s*=>\s*$') { $functionStarts.Add($i) }
}
 [int[]] $functionStartArray = @($functionStarts | ForEach-Object { $_ })
Assert-True ($functionStartArray.Count -ge 20) 'Expected user-defined Pine functions were not found for return-type scanning.'

$mixedBranchFunctions = [System.Collections.Generic.List[string]]::new()
foreach ($functionStart in $functionStartArray) {
    $functionName = [regex]::Match($pineLines[$functionStart], '^f_[A-Za-z0-9_]+').Value
    $bodyEnd = $pineLines.Count - 1
    for ($j = $functionStart + 1; $j -lt $pineLines.Count; $j++) {
        if ($pineLines[$j] -match '^\S') { $bodyEnd = $j - 1; break }
    }

    for ($i = $functionStart + 1; $i -le $bodyEnd; $i++) {
        $ifMatch = [regex]::Match($pineLines[$i], '^(?<indent>\s+)if\s+')
        if (-not $ifMatch.Success) { continue }

        $indent = $ifMatch.Groups['indent'].Value.Length
        $branchStarts = [System.Collections.Generic.List[int]]::new()
        $branchStarts.Add($i)
        $scanStart = $i + 1
        $chainEnd = $bodyEnd + 1

        while ($true) {
            $foundBranch = $false
            for ($k = $scanStart; $k -le $bodyEnd; $k++) {
                if ([string]::IsNullOrWhiteSpace($pineLines[$k]) -or $pineLines[$k].TrimStart().StartsWith('//')) { continue }
                $lineIndent = $pineLines[$k].Length - $pineLines[$k].TrimStart().Length
                if ($lineIndent -lt $indent) { $chainEnd = $k; break }
                if ($lineIndent -eq $indent) {
                    if ($pineLines[$k] -match '^\s*else(?:\s+if)?\b') {
                        $branchStarts.Add($k)
                        $scanStart = $k + 1
                        $foundBranch = $true
                    } else {
                        $chainEnd = $k
                    }
                    break
                }
            }
            if (-not $foundBranch) { break }
        }

        if ($branchStarts.Count -lt 2) { continue }

        $branchTypes = [System.Collections.Generic.List[string]]::new()
        for ($branchIndex = 0; $branchIndex -lt $branchStarts.Count; $branchIndex++) {
            $branchBodyStart = $branchStarts[$branchIndex] + 1
            $branchBodyEnd = if ($branchIndex + 1 -lt $branchStarts.Count) { $branchStarts[$branchIndex + 1] - 1 } else { $chainEnd - 1 }
            $lastStatement = $null
            for ($k = $branchBodyStart; $k -le $branchBodyEnd; $k++) {
                if (-not [string]::IsNullOrWhiteSpace($pineLines[$k]) -and -not $pineLines[$k].TrimStart().StartsWith('//')) { $lastStatement = $pineLines[$k] }
            }
            $branchType = Get-StaticAssignmentType $lastStatement
            if ($branchType -ne 'unknown') { $branchTypes.Add($branchType) }
        }

        if (@($branchTypes | Sort-Object -Unique).Count -gt 1) { $mixedBranchFunctions.Add($functionName) }
    }
}
Assert-True ($mixedBranchFunctions.Count -eq 0) ("Mixed terminal branch types found in: " + ($mixedBranchFunctions -join ', '))

Assert-True ($source -match 'stopFailed[\s\S]*else if trendFailed[\s\S]*else if timeFailed[\s\S]*else if trimReached[\s\S]*else if finalReached') 'Exit priority must be Stop, Trend, Timeout, Trim, Final.'
Assert-True ($source -match 'dir\s*\*\s*htfSlopeATR\s*<=\s*-vetoHtfSlope\s+or\s+dir\s*\*\s*localSlopeATR\s*<=\s*-vetoLocalSlope') 'Trend Fail formula changed.'
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
$entryDecisionBar = 10
Assert-True ((Get-Decision 1 110 90 105 108 $false $entryDecisionBar -1 10) -eq 'None') 'Entry decision bar must not manage.'
Assert-True ((Get-Decision 1 110 90 105 108 $false $entryDecisionBar -1 11 -FillSync $true) -eq 'None') 'Entry fill execution must only synchronize.'
Assert-True ((Get-Decision 1 106 90 105 108 $false $entryDecisionBar -1 11) -eq 'Trim') 'Long Entry fill bar close must allow Trim.'
Assert-True ((Get-Decision -1 94 110 95 92 $false $entryDecisionBar -1 11) -eq 'Trim') 'Short Entry fill bar close must allow Trim.'
Assert-True ((Get-Decision 1 89 90 105 108 $false $entryDecisionBar -1 11) -eq 'Stop') 'Long Entry fill bar close must allow Stop.'
Assert-True ((Get-Decision -1 111 110 95 92 $false $entryDecisionBar -1 11) -eq 'Stop') 'Short Entry fill bar close must allow Stop.'
Assert-True ((Get-Decision 1 100 90 105 108 $false $entryDecisionBar -1 11 -TrendFailed $true) -eq 'Trend') 'Entry fill bar close must allow Trend Fail.'
Assert-True ((Get-Decision -1 100 110 95 92 $false $entryDecisionBar -1 11 -TimeStop 1) -eq 'Timeout') 'Entry fill bar close must allow Timeout.'
Assert-True ((Get-Decision 1 106 90 105 108 $false $entryDecisionBar -1 11 -Confirmed $false) -eq 'None') 'Unconfirmed bars must not decide.'

# Trim decision bar and trim fill bar are distinct; post-Trim management uses the decision bar.
Assert-True ((Get-Decision 1 106 90 105 108 $false $entryDecisionBar -1 11) -eq 'Trim') 'Long confirmed close must trigger Trim.'
Assert-True ((Get-Decision -1 94 110 95 92 $false $entryDecisionBar -1 11) -eq 'Trim') 'Short confirmed close must trigger Trim.'
Assert-True ((Get-ConsistencyState 100 50 $true 1 $false 0) -eq 'ACTIVE') 'Long real Trim fill must remain active.'
Assert-True ((Get-ConsistencyState -100 -50 $true -1 $false 0) -eq 'ACTIVE') 'Short real Trim fill must remain active.'
Assert-True ((Get-FillAction 'Entry') -eq 'None') 'Entry fill recalculation must not decide.'
Assert-True ((Get-FillAction 'Trim') -eq 'None') 'Trim fill recalculation must not decide.'
Assert-True ((Get-FillAction 'FullExit') -eq 'LifecycleSynchronizationOnly') 'Full exit fill must only synchronize lifecycle state.'
Assert-True ((Get-Decision 1 109 101 105 108 $true $entryDecisionBar 11 12 -FillSync $true) -eq 'None') 'Trim fill execution must not trigger BE or Final.'
Assert-True ((Get-Decision -1 91 99 95 92 $true $entryDecisionBar 11 12 -FillSync $true) -eq 'None') 'Short Trim fill execution must not trigger BE or Final.'
Assert-True ((Get-Decision 1 109 101 105 108 $true $entryDecisionBar 11 12) -eq 'Final') 'Long Trim fill bar close must allow Final.'
Assert-True ((Get-Decision -1 91 99 95 92 $true $entryDecisionBar 11 12) -eq 'Final') 'Short Trim fill bar close must allow Final.'
Assert-True ((Get-Decision 1 100 101 105 108 $true $entryDecisionBar 11 12) -eq 'BE') 'Long Trim fill bar close must allow BE.'
Assert-True ((Get-Decision -1 100 99 95 92 $true $entryDecisionBar 11 12) -eq 'BE') 'Short Trim fill bar close must allow BE.'
Assert-True ((Get-Decision 1 109 101 105 108 $true $entryDecisionBar 12 12) -eq 'None') 'Trim decision bar must not also trigger Final.'

# TimeStop and cooldown count from confirmed-close decisions, not broker fill executions.
Assert-True ((Get-Decision 1 100 90 105 108 $false $entryDecisionBar -1 12 -TimeStop 2) -eq 'Timeout') 'TimeStop must count from entryDecisionBar.'
Assert-True ((Get-CooldownEligibility 20 22 3) -eq $false) 'Cooldown must still block before the decision-bar interval.'
Assert-True ((Get-CooldownEligibility 20 23 3) -eq $true) 'Cooldown must unlock from exitDecisionBar.'
Assert-True ((Get-CooldownEligibility 21 23 3) -eq $false) 'Using exit fill bar as cooldown anchor would be one bar late.'

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

Write-Host "PASS: MRT v3.1.1 confirmed-close lifecycle contract"
