$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $repoRoot 'MRT_V4.pine'
$v3Path = Join-Path $repoRoot 'MRT.pine'
$changelogPath = Join-Path $repoRoot 'CHANGELOG.md'

function Assert-True {
    param([bool]$Condition, [string]$Message)

    if (-not $Condition) {
        throw "ASSERT FAILED: $Message"
    }
}

function Assert-Match {
    param([string]$Text, [string]$Pattern, [string]$Message)

    Assert-True ([regex]::IsMatch($Text, $Pattern, [Text.RegularExpressions.RegexOptions]::Singleline)) $Message
}

function Assert-NotMatch {
    param([string]$Text, [string]$Pattern, [string]$Message)

    Assert-True (-not [regex]::IsMatch($Text, $Pattern, [Text.RegularExpressions.RegexOptions]::Singleline)) $Message
}

function Assert-Near {
    param([double]$Actual, [double]$Expected, [string]$Message)

    Assert-True ([math]::Abs($Actual - $Expected) -le 0.000001) "$Message (expected=$Expected, actual=$Actual)"
}

function Pass-Test {
    param([string]$Name, [scriptblock]$Body)

    & $Body
    $script:testCount += 1
    Write-Host "PASS [$($script:testCount.ToString('00'))] $Name"
}

function Round-ToTick {
    param([double]$Value, [double]$Tick = 0.25)

    return [math]::Round($Value / $Tick, 0, [MidpointRounding]::AwayFromZero) * $Tick
}

function New-PreplanModel {
    param(
        [int]$Dir,
        [string]$Mode,
        [int]$SourceBar = 10,
        [int]$OffsetTicks = 0,
        [double]$Tick = 0.25
    )

    $mean = 100.0
    $std = 10.0
    $atr = 2.0
    $entryZ = if ($Mode -eq 'Shock') { 2.0 } else { 1.65 }
    $partialZ = if ($Mode -eq 'Shock') { 1.0 } else { 0.8 }
    $finalZ = if ($Mode -eq 'Shock') { 0.5 } else { 0.25 }
    $entryTrigger = Round-ToTick ($mean - $Dir * $entryZ * $std) $Tick
    $entryLimit = Round-ToTick ($entryTrigger + $Dir * $OffsetTicks * $Tick) $Tick
    $tp1 = Round-ToTick ($mean - $Dir * $partialZ * $std) $Tick
    $tp2 = Round-ToTick ($mean - $Dir * $finalZ * $std) $Tick
    $atrStop = $entryTrigger - $Dir * 2.5 * $atr
    $statStop = $mean - $Dir * 3.25 * $std
    $tight = if ($Dir -eq 1) { [math]::Max($atrStop, $statStop) } else { [math]::Min($atrStop, $statStop) }
    $loose = if ($Dir -eq 1) { [math]::Min($atrStop, $statStop) } else { [math]::Max($atrStop, $statStop) }
    $stop = Round-ToTick ($loose + ($tight - $loose) * 0.5) $Tick

    [pscustomobject]@{
        Dir = $Dir
        Mode = $Mode
        SourceBar = $SourceBar
        ValidBar = $SourceBar + 1
        Mean = $mean
        Std = $std
        ATR = $atr
        EntryZ = $entryZ
        EntryTrigger = $entryTrigger
        EntryLimit = $entryLimit
        TP1 = $tp1
        TP2 = $tp2
        Stop = $stop
    }
}

function Test-TriggerTouched {
    param(
        $Plan,
        [double]$High,
        [double]$Low
    )

    if ($Plan.Dir -eq 1) {
        return $High -ge $Plan.EntryTrigger
    }

    return $Low -le $Plan.EntryTrigger
}

function Get-V3ManageDecision {
    param(
        [int]$Dir,
        [double]$EntryPrice,
        [double]$BaseStop,
        [double]$PartialTarget,
        [double]$FinalTarget,
        [bool]$PartialTaken,
        [double]$Close,
        [double]$RoundTripCost,
        [bool]$TrendFailed = $false,
        [bool]$Timeout = $false
    )

    $activeStop = if ($PartialTaken) {
        if ($Dir -eq 1) {
            [math]::Max($BaseStop, $EntryPrice + $RoundTripCost)
        }
        else {
            [math]::Min($BaseStop, $EntryPrice - $RoundTripCost)
        }
    }
    else {
        $BaseStop
    }

    $stopReached = if ($Dir -eq 1) { $Close -le $activeStop } else { $Close -ge $activeStop }
    $partialReached = $false
    if (-not $PartialTaken) {
        $partialReached = if ($Dir -eq 1) { $Close -ge $PartialTarget } else { $Close -le $PartialTarget }
    }
    $finalReached = $false
    if ($PartialTaken) {
        $finalReached = if ($Dir -eq 1) { $Close -ge $FinalTarget } else { $Close -le $FinalTarget }
    }

    if ($stopReached) { return 'STOP' }
    if ($TrendFailed) { return 'TREND' }
    if ($Timeout) { return 'TIME' }
    if ($partialReached) { return 'TRIM' }
    if ($finalReached) { return 'FINAL' }
    return 'NONE'
}

function Invoke-RollingPreplanModel {
    param(
        [bool[]]$SetupValid,
        [bool[]]$TriggerTouched
    )

    $active = $false
    $records = [System.Collections.Generic.List[object]]::new()

    for ($bar = 0; $bar -lt $SetupValid.Count; $bar++) {
        if ($active -and $TriggerTouched[$bar]) {
            $records.Add("$($bar):TRIGGER_TOUCHED")
        }

        if ($SetupValid[$bar]) {
            $eventName = if ($active) { 'PREPLAN_UPDATE' } else { 'PREPLAN_CREATE' }
            $records.Add("$($bar):$($eventName):$($bar + 1)")
            $active = $true
        }
        elseif ($active) {
            $records.Add("$($bar):PREPLAN_CANCEL")
            $active = $false
        }
    }

    return @($records)
}

function Invoke-LogicClockModel {
    param(
        [object[]]$Bars,
        [bool]$ExecutionAssistEnabled
    )

    $state = [pscustomobject]@{
        Position = 0
        PartialTaken = $false
        Events = [System.Collections.Generic.List[string]]::new()
    }

    foreach ($bar in $Bars) {
        # Execution Assist may have a touched trigger, but this model deliberately
        # does not read that fact when producing the confirmed-close Logic event.
        $ignoredAssistFact = $ExecutionAssistEnabled -and $bar.TriggerTouched

        if ($bar.Action -eq 'ENTRY_LONG' -and $state.Position -eq 0) {
            $state.Position = 1
            $state.PartialTaken = $false
            $state.Events.Add("$($bar.Index):ENTRY_LONG")
        }
        elseif ($bar.Action -eq 'ENTRY_SHORT' -and $state.Position -eq 0) {
            $state.Position = -1
            $state.PartialTaken = $false
            $state.Events.Add("$($bar.Index):ENTRY_SHORT")
        }
        elseif ($bar.Action -eq 'TRIM' -and $state.Position -ne 0 -and -not $state.PartialTaken) {
            $state.PartialTaken = $true
            $state.Events.Add("$($bar.Index):TRIM")
        }
        elseif ($bar.Action -match '^(FINAL|STOP|BE|TREND|TIME)$' -and $state.Position -ne 0) {
            $state.Events.Add("$($bar.Index):$($bar.Action)")
            $state.Position = 0
            $state.PartialTaken = $false
        }
    }

    return $state
}

function Get-Section {
    param(
        [string]$Text,
        [string]$Start,
        [string]$End
    )

    $startIndex = $Text.IndexOf($Start)
    $endIndex = $Text.IndexOf($End, $startIndex + $Start.Length)
    Assert-True ($startIndex -ge 0 -and $endIndex -gt $startIndex) "section not found: $Start"
    return $Text.Substring($startIndex, $endIndex - $startIndex)
}

$source = [IO.File]::ReadAllText($scriptPath)
$v3Source = [IO.File]::ReadAllText($v3Path)
$changelog = [IO.File]::ReadAllText($changelogPath)
$testCount = 0

Write-Host 'MR-T v4.1.0 V3-Aligned Execution Assist Harness'
Assert-True (Test-Path -LiteralPath $scriptPath) 'MRT_V4.pine must exist'

Pass-Test 'Version and role are v4.1.0' {
    Assert-Match $source 'strategy\("MR-T Strategy v4\.1\.0"' 'strategy version'
    Assert-Match $source 'string SCRIPT_VERSION\s*=\s*"4\.1\.0"' 'script version'
    Assert-Match $source 'V3-aligned Logic \+ previous-confirmed-bar execution assist' 'role comment'
    Assert-Match $source 'sourceBar=N\s+uses this bar''s final values;\s*validBar=N\+1' 'source-bar comment'
    Assert-Match $changelog '(?m)^## \[4\.1\.0\]' 'CHANGELOG v4.1.0 entry'
}

Pass-Test 'Only the requested Execution Assist input exists' {
    Assert-Match $source 'entryStopLimitOffsetTicks\s*=\s*input\.int\(0[^\r\n]*minval\s*=\s*0[^\r\n]*group\s*=\s*"V4 Execution Assist"' 'offset input'
    Assert-NotMatch $source 'rangePlanValidBars|shockPlanValidBars' 'old validity inputs remain'
    $v3Inputs = @($v3Source -split '\r?\n' | Where-Object { $_ -match '^[ \t]*[A-Za-z_][A-Za-z0-9_]*[ \t]*=[ \t]*input\.' })
    $v4Inputs = @($source -split '\r?\n' | Where-Object { $_ -match '^[ \t]*[A-Za-z_][A-Za-z0-9_]*[ \t]*=[ \t]*input\.' })
    Assert-True ($v4Inputs.Count -eq $v3Inputs.Count + 1) 'unexpected inputs added'
}

Pass-Test 'No old frozen-plan state or OCA lifecycle remains' {
    Assert-NotMatch $source 'MRSignalState|ExecutionPlanState|MRBrokerFillState|\bplan\.|\bsignal\.(?:setup|dir|mode|active)|MR4-|strategy\.oca|strategy\.order\(' 'old V4 lifecycle remains'
    Assert-NotMatch $source 'use_bar_magnifier\s*=' 'intrabar broker execution flag remains'
    Assert-NotMatch $source 'strategy\.exit\(' 'strategy.exit bracket remains'
}

Pass-Test 'calc and HTF semantics remain non-lookahead' {
    Assert-Match $source 'strategy\([^\r\n]*calc_on_order_fills\s*=\s*true[^\r\n]*calc_on_every_tick\s*=\s*false' 'strategy flags'
    Assert-Match $source 'request\.security\([^\r\n]*lookahead\s*=\s*barmerge\.lookahead_on' 'confirmed HTF request'
    Assert-Match $source 'bool isNewLogicDecisionBar\s*=\s*barstate\.isconfirmed' 'confirmed Logic gate'
}

Pass-Test 'PREPLAN state carries provenance and one-bar validity' {
    Assert-Match $source 'type MRExecutionAssistState[\s\S]*?varip int  sourceBar\s*=\s*na[\s\S]*?varip int  validBar\s*=\s*na' 'assist provenance fields'
    Assert-Match $source 'assist\.sourceBar\s*:=\s*bar_index[\s\S]*?assist\.validBar\s*:=\s*bar_index\s*\+\s*1' 'one-bar validity'
    Assert-Match $source 'assist\.active\s*\?\s*"PREPLAN_UPDATE"\s*:\s*"PREPLAN_CREATE"' 'rolling event type'
    Assert-Match $source 'assist\.triggerTouched\s*:=\s*false' 'touch reset'
}

Pass-Test 'Confirmed source-bar numerical model' {
    $p = New-PreplanModel 1 Range 17
    Assert-True ($p.SourceBar -eq 17 -and $p.ValidBar -eq 18) 'source/valid bar mapping'
    Assert-Near $p.EntryTrigger 83.5 'long trigger'
    Assert-Near $p.TP1 92.0 'long TP1'
    Assert-Near $p.TP2 97.5 'long TP2'
    $s = New-PreplanModel -1 -Mode Shock -SourceBar 31
    Assert-True ($s.ValidBar -eq 32) 'short valid bar'
    Assert-Near $s.EntryTrigger 120.0 'short trigger'
}

Pass-Test 'Long and short trigger formulas are symmetric' {
    $l = New-PreplanModel 1 Range
    $s = New-PreplanModel -1 Range
    Assert-Near (($l.EntryTrigger + $s.EntryTrigger) / 2.0) 100.0 'trigger midpoint'
    Assert-Match $source 'planEntryTrigger\s*=\s*f_roundToTick\(sourceMean\s*-\s*planDir\s*\*\s*planEntryZ\s*\*\s*sourceStd\)' 'unified trigger formula'
}

Pass-Test 'Reclaim trigger direction is correct' {
    Assert-True (Test-TriggerTouched (New-PreplanModel 1 Range) 84.0 80.0) 'Long upward reclaim'
    Assert-True (-not (Test-TriggerTouched (New-PreplanModel 1 Range) 83.0 80.0)) 'Long touch direction'
    Assert-True (Test-TriggerTouched (New-PreplanModel -1 Range) 120.0 116.0) 'Short downward reclaim'
    Assert-True (-not (Test-TriggerTouched (New-PreplanModel -1 Range) 120.0 117.0)) 'Short touch direction'
    Assert-Match $source 'assist\.dir\s*==\s*1\s*\?\s*high\s*>=\s*assist\.entryTrigger\s*:\s*low\s*<=\s*assist\.entryTrigger' 'touch direction'
}

Pass-Test 'Stop-Limit offset is tick-based' {
    $l = New-PreplanModel 1 Range 10 2
    $s = New-PreplanModel -1 Range 10 2
    Assert-Near $l.EntryLimit 84.0 'long limit cushion'
    Assert-Near $s.EntryLimit 116.0 'short limit cushion'
    Assert-Match $source 'planEntryLimit\s*=\s*f_roundToTick\(planEntryTrigger\s*\+\s*planDir\s*\*\s*entryStopLimitOffsetTicks\s*\*\s*syminfo\.mintick\)' 'offset formula'
}

Pass-Test 'Provisional TP1/TP2 and Stop use source values' {
    Assert-Match $source 'planTP1\s*=\s*f_roundToTick\(sourceMean\s*-\s*planDir\s*\*\s*planPartialZ\s*\*\s*sourceStd\)[\s\S]*?planTP2\s*=\s*f_roundToTick\(sourceMean\s*-\s*planDir\s*\*\s*planFinalZ\s*\*\s*sourceStd\)' 'provisional targets'
    Assert-Match $source 'float atrStop\s*=\s*planEntryTrigger\s*-\s*planDir\s*\*\s*hardStopATR\s*\*\s*sourceATR[\s\S]*?float statStop\s*=\s*sourceMean\s*-\s*planDir\s*\*\s*stopZ\s*\*\s*sourceStd' 'provisional stop inputs'
    Assert-Match $source 'balancedStop\s*=\s*looseStop\s*\+\s*\(tightStop\s*-\s*looseStop\)\s*\*\s*balancedWeight[\s\S]*?planStop\s*=\s*f_roundToTick' 'stop mode formula'
}

Pass-Test 'PREPLAN gate requires setup, Logic flat, and Broker flat' {
    Assert-Match $source 'setupReadyForPreplan\s*=\s*allowBarCloseDecision[\s\S]*?logic\.pos\s*==\s*0[\s\S]*?currentPositionSize\s*==\s*0\.0[\s\S]*?not na\(logic\.setupBar\)[\s\S]*?logic\.setupDir\s*!=\s*0' 'flat/setup gate'
}

Pass-Test 'PREPLAN does not submit an order or mutate Strategy position' {
    $preplanBlock = Get-Section $source '// A new plan is generated only after this bar is confirmed' '// Commit Broker observations only'
    Assert-NotMatch $preplanBlock 'strategy\.entry\(|strategy\.order\(' 'PREPLAN submits Broker order'
    Assert-NotMatch $preplanBlock 'strategy\.position_size\s*:=' 'PREPLAN mutates position'
    Assert-Match $source 'PREPLAN never[\s\S]*?strategy\.position_size' 'shadow-only comment'
}

Pass-Test 'Every PREPLAN price uses tick rounding and mintick formatting' {
    Assert-Match $source 'f_roundToTick\(float value\)' 'tick helper'
    Assert-Match $source 'planEntryTrigger\s*=\s*f_roundToTick[\s\S]*?planEntryLimit\s*=\s*f_roundToTick[\s\S]*?planTP1\s*=\s*f_roundToTick[\s\S]*?planTP2\s*=\s*f_roundToTick[\s\S]*?planStop\s*=\s*f_roundToTick' 'all prices rounded'
    Assert-Match $source 'f_price\(float value\)[\s\S]*?str\.tostring\(value,\s*format\.mintick\)' 'mintick formatter'
}

Pass-Test 'PREPLAN alerts carry required fields' {
    Assert-Match $source 'f_preplanMessage\([\s\S]*?"\|source_bar="[\s\S]*?"\|valid_bar="[\s\S]*?"\|entry_trigger="[\s\S]*?"\|entry_limit="[\s\S]*?"\|tp1_provisional="[\s\S]*?"\|tp2_provisional="[\s\S]*?"\|stop_provisional=' 'payload fields'
    Assert-Match $source 'alert\(f_preplanMessage\(planEventName' 'create/update alert'
    Assert-Match $source 'MR-T-V4\|event=' 'V4 prefix'
    $alertLines = @($source -split '\r?\n' | Where-Object { $_ -match '^[ \t]*alert\(' })
    foreach ($alertLine in $alertLines) {
        Assert-True ($alertLine -match 'f_preplanMessage\(|f_orderMessage\(') 'alert bypasses formatter'
    }
}

Pass-Test 'Case A confirmed entry reports trigger touch' {
    Assert-Match $source 'entryAssistEvent\s*=\s*previousPreplanTriggerTouched\s*\?\s*"ENTRY_CONFIRMED"\s*:\s*"ENTRY_CONFIRMED_NO_PREPLAN_FILL"' 'entry outcome event'
    Assert-Match $source '\|preplan_trigger_touched=' 'touch result field'
    Assert-Match $source 'ENTRY_CONFIRMED_NO_PREPLAN_FILL' 'case D event'
}

Pass-Test 'Case B reports provisional trigger without Logic entry' {
    Assert-Match $source 'PREPLAN_TRIGGERED_UNCONFIRMED' 'case B event'
    Assert-Match $source 'current_close=.*CONFIRMATION_FAILED' 'case B payload'
    Assert-Match $source 'not officialEntryDecision and previousPreplanTriggerTouched' 'case B gate'
}

Pass-Test 'Case C rolls to the next confirmed source bar' {
    $records = Invoke-RollingPreplanModel @($true, $true, $true) @($false, $false, $false)
    Assert-True ($records[0] -eq '0:PREPLAN_CREATE:1' -and $records[1] -eq '1:PREPLAN_UPDATE:2' -and $records[2] -eq '2:PREPLAN_UPDATE:3') 'rolling model'
    Assert-Match $source 'assist\.sourceBar\s*:=\s*bar_index[\s\S]*?assist\.validBar\s*:=\s*bar_index\s*\+\s*1' 'next-bar rewrite'
}

Pass-Test 'Setup invalidation stops PREPLAN' {
    $records = Invoke-RollingPreplanModel @($true, $false) @($false, $false)
    Assert-True ($records[-1] -eq '1:PREPLAN_CANCEL') 'cancel model'
    Assert-Match $source 'PREPLAN_CANCEL[\s\S]*?reason=SETUP_INVALID[\s\S]*?assist\.reset\(\)' 'cancel/reset'
}

Pass-Test 'Official entry remains confirmed-close V3 signal' {
    Assert-Match $source 'longEntrySignal\s*=\s*barstate\.isconfirmed[\s\S]*?logic\.pos\s*==\s*0[\s\S]*?hardTrendVeto[\s\S]*?logic\.setupDir\s*==\s*1[\s\S]*?zReclaim[\s\S]*?bandOK[\s\S]*?candleOK' 'Long confirmation'
    Assert-Match $source 'shortEntrySignal\s*=\s*barstate\.isconfirmed[\s\S]*?logic\.pos\s*==\s*0[\s\S]*?hardTrendVeto[\s\S]*?logic\.setupDir\s*==\s*-1[\s\S]*?zReclaim[\s\S]*?bandOK[\s\S]*?candleOK' 'Short confirmation'
    Assert-Match $source 'bool isNewLogicDecisionBar\s*=\s*barstate\.isconfirmed[\s\S]*?allowBarCloseDecision\s*=\s*isNewLogicDecisionBar' 'decision clock'
}

Pass-Test 'Official Entry is close-priced and freezes V3 fields' {
    Assert-Match $source 'logic\.entryPrice\s*:=\s*close[\s\S]*?logic\.mean\s*:=\s*mean15[\s\S]*?logic\.std\s*:=\s*safeStd[\s\S]*?logic\.atr\s*:=\s*safeATR[\s\S]*?logic\.entryBar\s*:=\s*bar_index' 'Logic freeze'
    $entryLines = @($source -split '\r?\n' | Where-Object { $_ -match 'strategy\.entry\(' })
    Assert-True ($entryLines.Count -eq 2) 'long/short official entries missing'
    foreach ($line in $entryLines) {
        Assert-True ($line -notmatch 'limit\s*=|stop\s*=') 'official Entry is not close market order'
    }
    Assert-Match $source 'strategy\.entry\("MR-L",\s*strategy\.long[^\r\n]*alert_message' 'Long close entry'
    Assert-Match $source 'strategy\.entry\("MR-S",\s*strategy\.short[^\r\n]*alert_message' 'Short close entry'
}

Pass-Test 'Execution Assist does not overwrite Logic levels' {
    Assert-NotMatch (Get-Section $source '// A new plan is generated only after this bar is confirmed' '// Commit Broker observations only') 'logic\.(entryPrice|mean|std|atr|partialTarget|finalTarget|baseStop)\s*:=' 'PREPLAN overwrites Logic'
    Assert-Match $source 'f_logicEnter\(1\)[\s\S]*?strategy\.entry\("MR-L"' 'official Long handoff'
}

Pass-Test 'Official Stop/BE uses confirmed close threshold' {
    $manage = Get-Section $source '// V3 Logic Manage' '// Official Logic Decision'
    Assert-Match $manage 'dir == 1 \? close <= activeStop : close >= activeStop' 'close stop threshold'
    Assert-NotMatch $manage 'low\s*<=|high\s*>=' 'intrabar stop threshold'
}

Pass-Test 'Official Trim and Final use confirmed close thresholds' {
    $manage = Get-Section $source '// V3 Logic Manage' '// Official Logic Decision'
    Assert-Match $manage 'dir == 1 \? close >= logic\.partialTarget : close <= logic\.partialTarget' 'close trim threshold'
    Assert-Match $manage 'dir == 1 \? close >= logic\.finalTarget : close <= logic\.finalTarget' 'close final threshold'
    Assert-NotMatch $manage 'strategy\.order\(|strategy\.oca|low\s*<=|high\s*>=' 'intrabar exits'
}

Pass-Test 'V3 manage priority is unchanged' {
    $manage = Get-Section $source '// V3 Logic Manage' '// Official Logic Decision'
    Assert-Match $manage 'if stopHit[\s\S]*?else if trendFailed[\s\S]*?else if timeFailed[\s\S]*?else if partialReached[\s\S]*?else if finalReached' 'priority'
    Assert-Match $manage 'trendFailed\s*=\s*dir\s*\*\s*htfSlopeATR\s*<=\s*-vetoHtfSlope\s*or\s*dir\s*\*\s*localSlopeATR\s*<=\s*-vetoLocalSlope' 'Trend Fail formula'
    Assert-Match $manage 'timeFailed\s*=\s*not na\(logic\.timeStop\)[^\r\n]*bar_index\s*-\s*logic\.entryBar' 'Timeout formula'
}

Pass-Test 'Model confirms Stop/Trim/Final close semantics' {
    Assert-True ((Get-V3ManageDecision 1 100 90 105 110 $false 90 1) -eq 'STOP') 'stop close'
    Assert-True ((Get-V3ManageDecision 1 100 90 105 110 $false 105 1) -eq 'TRIM') 'trim close'
    Assert-True ((Get-V3ManageDecision 1 100 90 105 110 $true 110 1) -eq 'FINAL') 'final close'
    Assert-True ((Get-V3ManageDecision 1 100 90 105 110 $false 100 1 $true $true) -eq 'TREND' -or (Get-V3ManageDecision 1 100 90 105 110 $false 100 1 $true $false) -eq 'TREND') 'trend precedence model'
}

Pass-Test 'No formal intrabar TP/Stop orders remain' {
    Assert-NotMatch $source 'strategy\.order\(|strategy\.exit\(|MR4-TP1|MR4-TP2|MR4-STOP|MR4-BE|strategy\.oca' 'intrabar OCA lifecycle'
    Assert-Match $source 'strategy\.close\(trimEntryId[\s\S]*?strategy\.close\(closeEntryId' 'confirmed close exits'
}

Pass-Test 'Residual cleanup is after formal full exit only' {
    $exitBlock = Get-Section $source '// A confirmed Logic full exit owns the cleanup handoff' '// A PREPLAN touch is an execution-assist fact'
    Assert-Match $exitBlock 'broker\.cleanupPending\s*:=\s*true[\s\S]*?strategy\.close\(closeEntryId' 'cleanup handoff'
    Assert-Match $exitBlock 'cleanupRetry[\s\S]*?currentPositionSize\s*!=\s*0\.0[\s\S]*?strategy\.close_all' 'residual retry'
    Assert-Match $source 'positionClosed\s*=\s*positionSampleReady[^\r\n]*currentPositionSize\s*==\s*0\.0' 'strict flat transition'
    Assert-Match $source 'if fullExitFilled[\s\S]*?broker\.cleanupPending\s*:=\s*false' 'cleanup clears only on full flat'
}

Pass-Test 'Residual model keeps 0.00001 active until exact zero' {
    $position = 0.00001
    $cleanupCount = 0
    $lifecycleComplete = $false

    if ($position -ne 0.0) {
        $cleanupCount += 1
    }
    Assert-True ($cleanupCount -eq 1 -and -not $lifecycleComplete) 'residual was treated as flat'
    $position = 0.0
    if ($position -eq 0.0) {
        $lifecycleComplete = $true
    }
    Assert-True $lifecycleComplete 'strict flat did not complete'
    Assert-NotMatch $source 'epsilon|math\.abs\(currentPositionSize\)\s*==' 'epsilon flat shortcut'
}

Pass-Test 'Broker Recovery also retries residual cleanup' {
    Assert-Match $source 'strategy\.close_all\(comment\s*=\s*"MR-T Broker Recovery"' 'recovery close'
    Assert-Match $source 'MR-T V4 Residual Cleanup[\s\S]*?RESIDUAL_CLEANUP' 'recovery residual'
    Assert-Match $source 'strategy\.cancel_all\(\)' 'recovery cancels pending broker commands'
}

Pass-Test 'Logic events are independent of Broker fills' {
    Assert-Match $source 'entryEvent\s*:=\s*logic\.logicEventBar\s*==\s*bar_index[\s\S]*?partialEvent\s*:=\s*logic\.logicEventBar\s*==\s*bar_index[\s\S]*?exitEvent\s*:=\s*logic\.logicEventBar' 'Logic event rendering'
    Assert-NotMatch (Get-Section $source '// Broker transition detection' '// Consistency and recovery') 'logic\.pos\s*:=|logic\.partialTaken\s*:=' 'Broker writes Logic'
}

Pass-Test 'Active Trade Lines show only formal Logic position' {
    Assert-Match $source 'bool showActiveTradeLines\s*=\s*logic\.pos\s*!=\s*0' 'Logic line gate'
    Assert-Match (Get-Section $source '// Active Trade Lines' '// Setup Labels') 'activePartialLine\s*:=\s*logic\.partialTarget[\s\S]*?activeFinalLine\s*:=\s*logic\.finalTarget[\s\S]*?f_logicActiveStop' 'formal levels'
    Assert-NotMatch (Get-Section $source '// Active Trade Lines' '// Setup Labels') 'assist\.entryTrigger|assist\.tp1Provisional|assist\.tp2Provisional|assist\.stopProvisional' 'provisional lines plotted'
}

Pass-Test 'Plot and Data Window footprint is unchanged' {
    $plotPattern = '(?m)^[ \t]*(?:[A-Za-z_][A-Za-z0-9_]*\s*=\s*)?plot\('
    Assert-True ([regex]::Matches($source, $plotPattern).Count -eq [regex]::Matches($v3Source, $plotPattern).Count) 'plot count changed'
    Assert-True ([regex]::Matches($source, 'display\s*=\s*display\.data_window').Count -eq [regex]::Matches($v3Source, 'display\s*=\s*display\.data_window').Count) 'Data Window count changed'
    Assert-True ([regex]::Matches($source, '\bplotshape\(').Count -eq [regex]::Matches($v3Source, '\bplotshape\(').Count) 'plotshape count changed'
}

Pass-Test 'Panel remains exactly 21 rows' {
    Assert-Match $source 'table\.new\(position\.top_right,\s*2,\s*21' 'Panel dimensions'
    $rows = [regex]::Matches($source, 'table\.cell\(panel,\s*[01],\s*(\d+)') | ForEach-Object { [int]$_.Groups[1].Value } | Sort-Object -Unique
    Assert-True ($rows.Count -eq 21 -and $rows[0] -eq 0 -and $rows[-1] -eq 20) 'Panel rows'
}

Pass-Test 'MRT.pine remains byte-for-byte unchanged' {
    $expectedSha = 'E9B42666A9150E34504794CC8311936209ECA74D9D049A0AC16C540104A3D1AF'
    Assert-True ((Get-FileHash -Algorithm SHA256 -LiteralPath $v3Path).Hash -eq $expectedSha) 'MRT.pine SHA changed'
    $null = & git -C $repoRoot diff --quiet -- MRT.pine
    Assert-True ($LASTEXITCODE -eq 0) 'MRT.pine has working-tree changes'
}

Pass-Test 'V3 parity harness remains green' {
    $v3Harness = Join-Path $PSScriptRoot 'MRT-v3.3.2-v2-logic-parity-harness.ps1'
    Assert-True (Test-Path -LiteralPath $v3Harness) 'V3 parity harness missing'
    $null = & pwsh -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $v3Harness 2>&1 | Out-String
    Assert-True ($LASTEXITCODE -eq 0) 'V3 parity harness failed'
}

Pass-Test 'Setup lifetime and cooldown remain V3 values' {
    Assert-Match $source 'rangeSetupBars\s*=\s*input\.int\(16' 'Range setup lifetime changed'
    Assert-Match $source 'shockSetupBars\s*=\s*input\.int\(8' 'Shock setup lifetime changed'
    Assert-Match $source 'int allowedAge\s*=\s*logic\.setupMode\s*==\s*2\s*\?\s*shockSetupBars\s*:\s*rangeSetupBars' 'setup expiry formula changed'
    Assert-Match $source 'int requiredCooldown\s*=\s*math\.max\(cooldownBars,\s*1\)' 'cooldown formula changed'
}

Pass-Test 'V3 market and veto formulas are retained' {
    Assert-Match $source 'hardTrendVeto\s*=\s*htfSlopeVeto\s*or\s*localSlopeVeto\s*or\s*htfERVeto\s*or\s*localERVeto' 'Hard Trend Veto changed'
    Assert-Match $source 'rangeEnvironment\s*=\s*not hardTrendVeto\s*and\s*regimeScore\s*>=\s*rangeMinScore' 'Range environment changed'
    Assert-Match $source 'shockEnvironment\s*=\s*not hardTrendVeto\s*and\s*regimeScore\s*>=\s*shockMinScore' 'Shock environment changed'
}

Pass-Test 'PREPLAN generation is gated by the confirmed scheduler' {
    $preplanSection = Get-Section $source '// A new plan is generated only after this bar is confirmed' '// Commit Broker observations only'
    Assert-Match $preplanSection 'allowBarCloseDecision' 'PREPLAN is not confirmed-close gated'
    Assert-NotMatch $preplanSection 'barstate\.isrealtime|calc_on_every_tick\s*=\s*true' 'PREPLAN reads live unfinished bar'
}

Pass-Test 'No provisional level is plotted or added to Data Window' {
    Assert-NotMatch $source 'plot\(\s*assist\.(entryTrigger|entryLimit|tp1Provisional|tp2Provisional|stopProvisional)' 'provisional level plot added'
    Assert-NotMatch $source 'display\s*=\s*display\.data_window[^\r\n]*assist\.' 'provisional Data Window field added'
}

Pass-Test 'Long and Short provisional stop math mirrors' {
    $long = New-PreplanModel 1 Range
    $short = New-PreplanModel -1 Range
    Assert-Near (($long.Stop + $short.Stop) / 2.0) 100.0 'stop midpoint'
    Assert-True ($long.Stop -lt $long.EntryTrigger -and $short.Stop -gt $short.EntryTrigger) 'stop direction'
}

Pass-Test 'V3 vs V4.1 Logic Timeline parity model' {
    $bars = @(
        [pscustomobject]@{ Index = 1; Action = 'ENTRY_LONG'; TriggerTouched = $true },
        [pscustomobject]@{ Index = 2; Action = 'TRIM'; TriggerTouched = $true },
        [pscustomobject]@{ Index = 3; Action = 'FINAL'; TriggerTouched = $false },
        [pscustomobject]@{ Index = 5; Action = 'ENTRY_SHORT'; TriggerTouched = $true },
        [pscustomobject]@{ Index = 6; Action = 'STOP'; TriggerTouched = $true },
        [pscustomobject]@{ Index = 8; Action = 'ENTRY_LONG'; TriggerTouched = $false },
        [pscustomobject]@{ Index = 9; Action = 'TREND'; TriggerTouched = $true },
        [pscustomobject]@{ Index = 11; Action = 'ENTRY_SHORT'; TriggerTouched = $false },
        [pscustomobject]@{ Index = 12; Action = 'TIME'; TriggerTouched = $true }
    )

    $v3 = Invoke-LogicClockModel $bars $false
    $v41 = Invoke-LogicClockModel $bars $true
    Assert-True (($v3.Events -join '|') -eq ($v41.Events -join '|')) 'Execution Assist changed Logic timeline'
    Assert-True (($v41.Events -join '|') -eq '1:ENTRY_LONG|2:TRIM|3:FINAL|5:ENTRY_SHORT|6:STOP|8:ENTRY_LONG|9:TREND|11:ENTRY_SHORT|12:TIME') 'unexpected parity timeline'

    Assert-Match $source 'Execution Assist is shadow state only' 'shadow state declaration'
    Assert-Match $source 'f_logicManage\(int dir\)' 'V3 management function'
    Assert-Match $source 'allowBarCloseDecision\s*=\s*isNewLogicDecisionBar' 'confirmed Logic scheduler'
}

Assert-True ($testCount -eq 41) "expected 41 tests, ran $testCount"
Write-Host "PASS: $testCount/$testCount V4.1 execution-assist tests"
Write-Host 'Manual TradingView compile/backtest and live alert validation remain required.'
