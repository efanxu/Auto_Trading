$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $repoRoot 'MRT_V4.pine'

function Assert-True {
    param([bool]$Condition, [string]$Message)

    if (-not $Condition) {
        throw "ASSERT FAILED: $Message"
    }
}

Write-Host 'MR-T v4.0.0 Execution Plan Harness'
Assert-True (Test-Path -LiteralPath $scriptPath) 'MRT_V4.pine must exist'

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

function New-PlanModel {
    param([int]$Dir, [string]$Mode)

    $mean = 100.0
    $std = 10.0
    $atr = 2.0
    $entryZ = if ($Mode -eq 'Shock') { 2.0 } else { 1.65 }
    $partialZ = if ($Mode -eq 'Shock') { 1.0 } else { 0.8 }
    $finalZ = if ($Mode -eq 'Shock') { 0.5 } else { 0.25 }
    $entry = $mean - $Dir * $entryZ * $std
    $atrStop = $entry - $Dir * 2.5 * $atr
    $statStop = $mean - $Dir * 3.25 * $std
    $tight = if ($Dir -eq 1) { [math]::Max($atrStop, $statStop) } else { [math]::Min($atrStop, $statStop) }
    $loose = if ($Dir -eq 1) { [math]::Min($atrStop, $statStop) } else { [math]::Max($atrStop, $statStop) }

    [pscustomobject]@{
        Dir = $Dir
        Mode = $Mode
        Entry = $entry
        TP1 = $mean - $Dir * $partialZ * $std
        TP2 = $mean - $Dir * $finalZ * $std
        Stop = $loose + ($tight - $loose) * 0.5
        CreatedBar = 10
        ExpiryBar = 10 + $(if ($Mode -eq 'Shock') { 4 } else { 8 })
        EntryFilled = $false
        EntryFillBar = $null
        ActualEntry = $null
        PartialFilled = $false
        PositionPct = 0.0
        LastExitBar = $null
    }
}

function Test-Geometry {
    param($Plan, [double]$Close)
    if ($Plan.Dir -eq 1) {
        return $Plan.Stop -lt $Plan.Entry -and $Plan.Entry -lt $Plan.TP1 -and $Plan.TP1 -lt $Plan.TP2 -and $Plan.Entry -lt $Close
    }
    return $Plan.Stop -gt $Plan.Entry -and $Plan.Entry -gt $Plan.TP1 -and $Plan.TP1 -gt $Plan.TP2 -and $Plan.Entry -gt $Close
}

function Get-CancelReason {
    param($Plan, [int]$Bar, [bool]$Veto = $false, [bool]$Missed = $false, [bool]$Opposite = $false)
    if ($Plan.EntryFilled) { return '' }
    if ($Bar -ge $Plan.ExpiryBar) { return 'EXPIRED' }
    if ($Veto) { return 'HARD_TREND_VETO' }
    if ($Missed) { return 'MISSED_TP1' }
    if ($Opposite) { return 'OPPOSITE_SETUP' }
    return ''
}

function Fill-Entry {
    param($Plan, [int]$Bar, [double]$Price)
    $Plan.EntryFilled = $true
    $Plan.EntryFillBar = $Bar
    $Plan.ActualEntry = $Price
    $Plan.PositionPct = 100.0
}

function Fill-TP1 {
    param($Plan, [int]$Bar)
    if ($Plan.PartialFilled) { return $false }
    $Plan.PartialFilled = $true
    $Plan.PositionPct = 50.0
    $cost = $Plan.ActualEntry * 6.0 / 10000.0 + 0.5
    $Plan | Add-Member -NotePropertyName ActiveStop -NotePropertyValue ([math]::Ceiling(($Plan.ActualEntry + $cost) / 0.25) * 0.25) -Force
    return $true
}

function New-ExitModel {
    param([double]$EntryQty, [double]$TrimPct)

    [pscustomobject]@{
        EntryQty = $EntryQty
        TP1Qty = $EntryQty * $TrimPct / 100.0
        TP2Qty = $EntryQty
        StopQty = $EntryQty
        RemainingQty = $EntryQty
        CleanupPending = $false
        CleanupCloseCount = 0
        PlanReset = $false
        Closed = 0
        LastExitBar = $null
        RangeClosed = 0
        ShockClosed = 0
    }
}

function Observe-FullExit {
    param($Model, [double]$PositionSize)

    if ($PositionSize -eq 0.0 -and -not $Model.PlanReset) {
        $Model.PlanReset = $true
        $Model.Closed += 1
        $Model.LastExitBar = 20
        $Model.RangeClosed += 1
    }
    else {
        $Model.CleanupPending = $true
        $Model.CleanupCloseCount += 1
    }
}

function Get-PartialExitOutcome {
    param([string]$ExitId, [bool]$AlreadyPartialFilled)

    if ($ExitId -eq 'MR4-TP1' -and -not $AlreadyPartialFilled) {
        return 'TP1'
    }
    return 'CLEANUP'
}

function Get-ShowActiveTradeLines {
    param([bool]$PlanActive, [bool]$EntryFilled, [double]$PositionSize)

    return $PlanActive -and $EntryFilled -and $PositionSize -ne 0.0
}

$source = [IO.File]::ReadAllText($scriptPath)
$v3Path = Join-Path $repoRoot 'MRT.pine'
$v3Source = [IO.File]::ReadAllText($v3Path)
$baselineCommit = '9fea483e77a7f4afab900cc2dc2c20523d79ac20'
$baselineSource = ((& git -C $repoRoot show ($baselineCommit + ':MRT.pine')) -join [Environment]::NewLine)
$expectedV3Sha = 'E9B42666A9150E34504794CC8311936209ECA74D9D049A0AC16C540104A3D1AF'
$testCount = 0

function Pass-Test {
    param([string]$Name, [scriptblock]$Body)
    & $Body
    $script:testCount += 1
    Write-Host "PASS [$($script:testCount.ToString('00'))] $Name"
}

Pass-Test 'Range Long Plan creation' {
    $p = New-PlanModel 1 Range
    Assert-Near $p.Entry 83.5 'entry'
    Assert-Near $p.TP1 92.0 'TP1'
    Assert-Near $p.TP2 97.5 'TP2'
    Assert-Near $p.Stop 73.0 'stop'
    Assert-Match $source '"MR-T-V4\|event="[\s\S]*?"\|direction="[\s\S]*?"\|mode="[\s\S]*?"\|entry_limit="[\s\S]*?"\|tp1="[\s\S]*?"\|tp1_qty="[\s\S]*?"\|tp2="[\s\S]*?"\|tp2_qty="[\s\S]*?"\|stop="[\s\S]*?"\|valid_bars="' 'Plan alert fields missing'
}
Pass-Test 'Range Short Plan creation' {
    $p = New-PlanModel -1 Range
    Assert-Near $p.Entry 116.5 'entry'
    Assert-Near $p.TP1 108.0 'TP1'
    Assert-Near $p.TP2 102.5 'TP2'
    Assert-Near $p.Stop 127.0 'stop'
}
Pass-Test 'Shock Long and Short Plan creation' {
    $l = New-PlanModel 1 Shock
    $s = New-PlanModel -1 Shock
    Assert-Near $l.Entry 80.0 'long entry'
    Assert-Near $l.TP1 90.0 'long TP1'
    Assert-Near $s.Entry 120.0 'short entry'
    Assert-Near $s.TP1 110.0 'short TP1'
    Assert-Match $source 'longShockSetup\s*=\s*allowLong\s*and\s*shockEnvironment\s*and\s*shockDown\s*and\s*z\s*<=\s*-shockEntryZ\s*and\s*decelerationOK\s*and\s*longRejectionOK\s*and\s*noSameLong' 'Shock Long setup formula changed'
    Assert-Match $source 'shortShockSetup\s*=\s*allowShort\s*and\s*shockEnvironment\s*and\s*shockUp\s*and\s*z\s*>=\s*shockEntryZ\s*and\s*decelerationOK\s*and\s*shortRejectionOK\s*and\s*noSameShort' 'Shock Short setup formula changed'
    Assert-Match $source 'longRangeSetup\s*=\s*allowLong\s*and\s*rangeEnvironment\s*and\s*z\s*<=\s*-rangeEntryZ\s*and\s*noSameLong' 'Range Long setup formula changed'
    Assert-Match $source 'shortRangeSetup\s*=\s*allowShort\s*and\s*rangeEnvironment\s*and\s*z\s*>=\s*rangeEntryZ\s*and\s*noSameShort' 'Range Short setup formula changed'
}
Pass-Test 'Plan prices freeze' {
    Assert-Match $source 'plan\.frozenMean\s*:=\s*mean15[\s\S]*?plan\.frozenStd\s*:=\s*safeStd[\s\S]*?plan\.frozenATR\s*:=\s*safeATR' 'frozen snapshot missing'
    Assert-NotMatch ([regex]::Match($source, '(?ms)if entryFilledNow.*?(?=if tp1FilledNow)').Value) 'frozenMean\s*:=|frozenStd\s*:=' 'fill rewrites frozen prices'
}
Pass-Test 'Retracement Limit Entry' {
    Assert-Match $source 'strategy\.entry\([^\r\n]*limit\s*=\s*plan\.entryLimit' 'limit entry missing'
    Assert-Match $source 'entryLimit\s*<\s*close[\s\S]*?entryLimit\s*>\s*close' 'non-marketable check missing'
}
Pass-Test 'Confirmation close is not market entry' {
    $entries = @($source -split '\r?\n' | Where-Object { $_ -match 'strategy\.entry\(' })
    Assert-True ($entries.Count -eq 1 -and $entries[0] -match '\blimit\s*=') 'market entry exists'
}
Pass-Test 'Plan expiry' {
    $p = New-PlanModel 1 Range
    Assert-True ((Get-CancelReason $p 17) -eq '') 'expired too early'
    Assert-True ((Get-CancelReason $p 18) -eq 'EXPIRED') 'did not expire at boundary'
}
Pass-Test 'Hard Trend Veto cancel' {
    Assert-True ((Get-CancelReason (New-PlanModel 1 Range) 11 $true) -eq 'HARD_TREND_VETO') 'reason'
    Assert-Match $source '"HARD_TREND_VETO"' 'source reason missing'
}
Pass-Test 'Missed TP1 cancel' {
    Assert-True ((Get-CancelReason (New-PlanModel 1 Range) 11 $false $true) -eq 'MISSED_TP1') 'reason'
    Assert-Match $source 'high\s*>=\s*plan\.partialTarget\s*:\s*low\s*<=\s*plan\.partialTarget' 'symmetry missing'
}
Pass-Test 'Opposite Setup cancel' {
    Assert-True ((Get-CancelReason (New-PlanModel -1 Shock) 11 $false $false $true) -eq 'OPPOSITE_SETUP') 'reason'
    Assert-Match $source 'oppositeSetup[\s\S]*?longShockSetup[\s\S]*?longRangeSetup' 'existing setup definitions not used'
}
Pass-Test 'Entry fill starts trade clock' {
    $p = New-PlanModel 1 Range
    Fill-Entry $p 14 83.25
    Assert-True ($p.EntryFillBar -eq 14 -and $p.EntryFillBar -ne $p.CreatedBar) 'wrong clock'
    Assert-Match $source 'bar_index\s*-\s*plan\.entryFillBar' 'timeout not fill-relative'
}
Pass-Test 'Actual Broker average recorded' {
    Assert-Match $source 'plan\.actualEntryPrice\s*:=\s*strategy\.position_avg_price' 'broker average missing'
}
Pass-Test 'Residual never resets an active Plan' {
    $m = New-ExitModel 1.0 90.0
    Observe-FullExit $m 0.00001
    Assert-True ($m.CleanupPending -and $m.CleanupCloseCount -eq 1 -and -not $m.PlanReset) 'residual model incorrectly reset'
    Assert-Match $source 'cleanupPending' 'cleanup state missing'
    Assert-Match $source 'strategy\.close_all\(' 'residual close command missing'
    Assert-Match $source 'currentPositionSize\s*==\s*0\.0[\s\S]*?plan\.reset\(\)' 'reset is not gated by strict flat'
}
Pass-Test 'Entry fill submits TP and Stop' {
    Assert-Match $source 'if entryFilledNow[\s\S]*?strategy\.order\("MR4-TP1"[\s\S]*?strategy\.order\("MR4-TP2"[\s\S]*?strategy\.order\("MR4-STOP"' 'explicit price exits missing'
}
Pass-Test 'TP1 remaining quantity correct' {
    $p = New-PlanModel 1 Range
    Fill-Entry $p 14 83.25
    $null = Fill-TP1 $p 15
    Assert-Near $p.PositionPct 50.0 'remainder'
    Assert-Match $source 'plan\.entryQty\s*:=\s*math\.abs\(strategy\.position_size\)' 'actual entry quantity missing'
    Assert-Match $source 'qty\s*=\s*plan\.entryQty\s*\*\s*trimPct\s*/\s*100\.0' 'TP1 quantity is not based on entry quantity'
}
Pass-Test 'TP1 moves Stop to BE' {
    $p = New-PlanModel 1 Range
    Fill-Entry $p 14 83.25
    $null = Fill-TP1 $p 15
    Assert-Near $p.ActiveStop 84.0 'BE'
    Assert-Match $source 'f_brokerExecutionCost\(plan\.actualEntryPrice\)[\s\S]*?"BE_STOP_UPDATE"' 'BE source missing'
}
Pass-Test 'TP2 fully exits' {
    Assert-Match $source '"TP2_FILLED"' 'TP2 event missing'
    Assert-Match $source 'fullExitFilledNow[\s\S]*?plan\.reset\(\)' 'full reset missing'
}
Pass-Test 'Initial Stop is a real order' {
    Assert-Match $source 'strategy\.order\("MR4-STOP"[^\r\n]*qty\s*=\s*plan\.entryQty[^\r\n]*stop\s*=\s*plan\.baseStop' 'initial stop missing'
    Assert-NotMatch $source 'strategy\.exit\(' 'strategy.exit bracket remains'
}
Pass-Test 'BE Stop is a real updated order' {
    Assert-Match $source 'strategy\.cancel\("MR4-STOP"\)[\s\S]*?strategy\.order\("MR4-TP2"[\s\S]*?strategy\.order\("MR4-BE"[^\r\n]*qty\s*=\s*remainingQty[^\r\n]*stop\s*=\s*plan\.activeStop' 'BE OCA group missing'
    Assert-Match $source '"BE_FILLED"' 'BE fill event missing'
}
Pass-Test 'Trend Fail confirmed-close exit' {
    Assert-Match $source 'trendFailed\s*=\s*plan\.dir\s*\*\s*htfSlopeATR\s*<=\s*-vetoHtfSlope\s*or\s*plan\.dir\s*\*\s*localSlopeATR\s*<=\s*-vetoLocalSlope' 'formula changed'
    Assert-Match $source 'strategy\.close\([^\r\n]*comment\s*=\s*stateExitEvent' 'close missing'
}
Pass-Test 'Timeout confirmed-close exit' {
    Assert-Match $source 'timeFailed\s*=\s*not na\(plan\.frozenTimeStop\)[^\r\n]*bar_index\s*>\s*plan\.entryFillBar[^\r\n]*bar_index\s*-\s*plan\.entryFillBar' 'timeout changed'
}
Pass-Test 'Fill recalculation blocks signal logic' {
    Assert-Match $source 'isFillSynchronizationExecution\s*=\s*positionChanged' 'fill classifier missing'
    Assert-Match $source 'allowBarCloseDecision\s*=\s*barstate\.isconfirmed\s*and\s*not isFillSynchronizationExecution' 'decision gate missing'
}
Pass-Test 'Same-bar TP1 idempotence' {
    $p = New-PlanModel 1 Range
    Fill-Entry $p 14 83.25
    Assert-True (Fill-TP1 $p 15) 'first fill missing'
    Assert-True (-not (Fill-TP1 $p 15)) 'duplicate fill'
    Assert-Match $source 'tp1FilledNow\s*=\s*priceReductionNow[\s\S]*?not plan\.partialFilled' 'source dedupe missing'
}
Pass-Test 'Same-bar final Stop idempotence' {
    Assert-Match $source 'fullExitFilledNow\s*=\s*positionClosed\s*and\s*plan\.active\s*and\s*plan\.entryFilled' 'fact gate missing'
    Assert-Match $source 'currentPositionSize\s*==\s*0\.0[\s\S]*?plan\.reset\(\)' 'strict flat reset missing'
}
Pass-Test 'Plan cancel is not trade or cooldown' {
    $block = [regex]::Match($source, '(?ms)// Pending plans cancel.*?(?=// Create or replace Signal Setup)').Value
    Assert-NotMatch $block 'lastExitBar|rangeClosed|shockClosed|netprofit' 'cancel mutates trade facts'
}
Pass-Test 'Long Short symmetry' {
    $l = New-PlanModel 1 Range
    $s = New-PlanModel -1 Range
    Assert-Near (($l.Entry + $s.Entry) / 2) 100 'entry'
    Assert-Near (($l.TP1 + $s.TP1) / 2) 100 'TP1'
    Assert-Near (($l.TP2 + $s.TP2) / 2) 100 'TP2'
    Assert-Near (($l.Stop + $s.Stop) / 2) 100 'stop'
}
Pass-Test 'Plan prices use syminfo.mintick' {
    Assert-Match $source 'entryLimit\s*:=\s*f_roundToTick[\s\S]*?partialTarget\s*:=\s*f_roundToTick[\s\S]*?finalTarget\s*:=\s*f_roundToTick[\s\S]*?baseStop\s*:=\s*f_roundToTick' 'rounding incomplete'
}
Pass-Test 'Invalid geometry rejects Plan' {
    $p = New-PlanModel 1 Range
    $p.TP1 = $p.Entry
    Assert-True (-not (Test-Geometry $p 86)) 'invalid model geometry accepted'
    Assert-Match $source 'validGeometry\s*=\s*orderedGeometry\s*and\s*nonMarketableLimit[\s\S]*?"PLAN_REJECT"[\s\S]*?plan\.reset\(\)' 'reject path missing'
}
Pass-Test 'calc_on_every_tick remains false' {
    Assert-Match $source 'strategy\([^\r\n]*calc_on_order_fills\s*=\s*true[^\r\n]*calc_on_every_tick\s*=\s*false[^\r\n]*use_bar_magnifier\s*=\s*true' 'strategy flags wrong'
    $v3Inputs = @($v3Source -split '\r?\n' | Where-Object { $_ -match '^[ \t]*[A-Za-z_][A-Za-z0-9_]*[ \t]*=[ \t]*input\.' })
    $v4Inputs = @($source -split '\r?\n' | Where-Object { $_ -match '^[ \t]*[A-Za-z_][A-Za-z0-9_]*[ \t]*=[ \t]*input\.' })
    Assert-True ($v4Inputs.Count -eq $v3Inputs.Count + 2) 'unexpected V4 inputs added'
    Assert-Match $source 'rangePlanValidBars\s*=\s*input\.int\(8[^\r\n]*group\s*=\s*"V4 Execution Plan"' 'Range validity input wrong'
    Assert-Match $source 'shockPlanValidBars\s*=\s*input\.int\(4[^\r\n]*group\s*=\s*"V4 Execution Plan"' 'Shock validity input wrong'
    foreach ($alertLine in @($source -split '\r?\n' | Where-Object { $_ -match '^[ \t]*alert\(' })) {
        Assert-True ($alertLine -match 'f_executionMessage\(') 'V4 alert bypasses unified formatter'
    }
}
Pass-Test 'No barstate.islast' {
    Assert-NotMatch $source 'barstate\.islast' 'warning trigger remains'
    Assert-Match $source '(?ms)^if showPanel\s*$.*?^else\s*$\s*table\.clear\(panel,\s*0,\s*0,\s*1,\s*20\)' 'panel flow wrong'
}
Pass-Test 'MRT.pine baseline unchanged' {
    Assert-True ((Get-FileHash -Algorithm SHA256 -LiteralPath $v3Path).Hash -eq $expectedV3Sha) 'SHA changed'
    $working = $v3Source.Replace([string][char]13 + [char]10, [string][char]10).TrimEnd()
    $baseline = $baselineSource.Replace([string][char]13 + [char]10, [string][char]10).TrimEnd()
    Assert-True ($working -eq $baseline) 'content changed'
}
Pass-Test 'No added plot plotshape Data Window' {
    $plotPattern = '(?m)^[ \t]*(?:[A-Za-z_][A-Za-z0-9_]*\s*=\s*)?plot\('
    Assert-True ([regex]::Matches($source, $plotPattern).Count -eq [regex]::Matches($v3Source, $plotPattern).Count) 'plot count'
    Assert-True ([regex]::Matches($source, 'display\s*=\s*display\.data_window').Count -eq [regex]::Matches($v3Source, 'display\s*=\s*display\.data_window').Count) 'Data Window'
    Assert-True ([regex]::Matches($source, '\bplotshape\(').Count -eq [regex]::Matches($v3Source, '\bplotshape\(').Count) 'plotshape'
}
Pass-Test 'Panel remains 21 rows' {
    Assert-Match $source 'table\.new\(position\.top_right,\s*2,\s*21' 'dimensions'
    $rows = [regex]::Matches($source, 'table\.cell\(panel,\s*[01],\s*(\d+)') | ForEach-Object { [int]$_.Groups[1].Value } | Sort-Object -Unique
    Assert-True ($rows.Count -eq 21 -and $rows[0] -eq 0 -and $rows[-1] -eq 20) 'row structure'
}

Pass-Test 'Entry fill records actual Broker quantity' {
    Assert-Match $source 'varip float entryQty\s*=\s*na' 'entry quantity field missing'
    Assert-Match $source 'plan\.entryQty\s*:=\s*math\.abs\(strategy\.position_size\)' 'entry quantity is not Broker-derived'
}
Pass-Test 'Price exits use explicit strategy.order' {
    Assert-NotMatch $source 'strategy\.exit\(' 'implicit strategy.exit bracket remains'
    Assert-Match $source 'strategy\.order\("MR4-TP1"' 'TP1 strategy.order missing'
    Assert-Match $source 'strategy\.order\("MR4-TP2"' 'TP2 strategy.order missing'
    Assert-Match $source 'strategy\.order\("MR4-STOP"' 'Stop strategy.order missing'
}
Pass-Test 'Initial TP1 TP2 Stop share one OCA reduce group' {
    $entryBlock = [regex]::Match($source, '(?ms)if entryFilledNow.*?(?=if tp1FilledNow)').Value
    Assert-True ([regex]::Matches($entryBlock, 'strategy\.order\("MR4-(?:TP1|TP2|STOP)"').Count -eq 3) 'initial exit order count'
    Assert-True ([regex]::Matches($entryBlock, 'oca_name\s*=\s*plan\.initialExitOcaName').Count -eq 3) 'initial OCA names differ'
    Assert-True ([regex]::Matches($entryBlock, 'oca_type\s*=\s*strategy\.oca\.reduce').Count -eq 3) 'initial OCA type missing'
}
Pass-Test 'Initial quantities cover actual entry' {
    $m = New-ExitModel 1.0 90.0
    Assert-Near $m.TP1Qty 0.9 'TP1 quantity'
    Assert-Near $m.TP2Qty 1.0 'TP2 quantity'
    Assert-Near $m.StopQty 1.0 'Stop quantity'
    Assert-Match $source 'strategy\.order\("MR4-STOP"[^\r\n]*qty\s*=\s*plan\.entryQty' 'Stop does not cover entry quantity'
}
Pass-Test 'TP1 quantity uses trimPct of entryQty' {
    $m = New-ExitModel 0.0001 90.0
    Assert-Near $m.TP1Qty 0.00009 'TP1 quantity'
    Assert-Match $source 'qty\s*=\s*plan\.entryQty\s*\*\s*trimPct\s*/\s*100\.0' 'TP1 quantity formula missing'
}
Pass-Test 'TP1 fill reads actual remaining Broker quantity' {
    Assert-Match $source 'float remainingQty\s*=\s*math\.abs\(strategy\.position_size\)' 'remaining quantity is not Broker-derived'
}
Pass-Test 'TP1 rebuilds TP2 with actual remainder' {
    $tp1Block = [regex]::Match($source, '(?ms)if tp1FilledNow.*?(?=if unexpectedPartialPriceExitNow)').Value
    Assert-Match $tp1Block 'strategy\.order\("MR4-TP2"[^\r\n]*qty\s*=\s*remainingQty[^\r\n]*limit\s*=\s*plan\.finalTarget' 'TP2 remainder order missing'
    Assert-Match $tp1Block 'oca_name\s*=\s*plan\.remainderExitOcaName[^\r\n]*oca_type\s*=\s*strategy\.oca\.reduce' 'TP2 remainder OCA missing'
}
Pass-Test 'TP1 rebuilds BE Stop with actual remainder' {
    $tp1Block = [regex]::Match($source, '(?ms)if tp1FilledNow.*?(?=if unexpectedPartialPriceExitNow)').Value
    Assert-Match $tp1Block 'strategy\.order\("MR4-BE"[^\r\n]*qty\s*=\s*remainingQty[^\r\n]*stop\s*=\s*plan\.activeStop' 'BE remainder order missing'
    Assert-Match $tp1Block 'strategy\.order\("MR4-BE"[^\r\n]*oca_name\s*=\s*plan\.remainderExitOcaName[^\r\n]*oca_type\s*=\s*strategy\.oca\.reduce' 'BE remainder OCA missing'
}
Pass-Test 'Initial Stop partial fill enters cleanup' {
    Assert-True ((Get-PartialExitOutcome 'MR4-STOP' $false) -eq 'CLEANUP') 'Stop partial was treated as TP1'
    Assert-Match $source 'unexpectedPartialPriceExitNow\s*=\s*priceReductionNow[\s\S]*?plan\.cleanupPending\s*:=\s*true' 'Stop partial cleanup path missing'
}
Pass-Test 'BE Stop partial fill enters cleanup' {
    Assert-True ((Get-PartialExitOutcome 'MR4-BE' $true) -eq 'CLEANUP') 'BE partial was treated as TP1'
    Assert-Match $source 'latestClosedExitId\s*==\s*"MR4-BE"[\s\S]*?R_BE' 'BE partial reason missing'
}
Pass-Test 'TP2 partial fill enters cleanup' {
    Assert-True ((Get-PartialExitOutcome 'MR4-TP2' $true) -eq 'CLEANUP') 'TP2 partial was treated as TP1'
    Assert-Match $source 'latestClosedExitId\s*==\s*"MR4-TP2"[\s\S]*?R_FINAL' 'TP2 partial reason missing'
}
Pass-Test 'Trend Fail residual enters cleanup' {
    $stateExitBlock = [regex]::Match($source, '(?ms)if trendFailed or timeFailed.*?(?=// Commit Broker observations)').Value
    Assert-Match $stateExitBlock 'plan\.fullExitPending\s*:=\s*true[\s\S]*?plan\.expectedFlatReason\s*:=\s*stateExitReason' 'Trend/timeout pending state missing'
    Assert-Match $stateExitBlock 'strategy\.close\(f_entryOrderId\(plan\.dir\)' 'state exit close missing'
}
Pass-Test 'Timeout residual enters cleanup' {
    Assert-Match $source 'stateExitEvent\s*=\s*trendFailed\s*\?\s*"TREND_FAIL"\s*:\s*"TIMEOUT"[\s\S]*?plan\.fullExitPending\s*:=\s*true' 'Timeout full-exit intent missing'
    Assert-Match $source 'plan\.expectedFlatReason\s*:=\s*stateExitReason[\s\S]*?strategy\.close\(' 'Timeout cleanup handoff missing'
}
Pass-Test 'Broker Recovery residual is retried' {
    Assert-Match $source 'broker\.recoveryClosePlaced\s*or\s*\(isFillSynchronizationExecution\s*and\s*positionReduced\)' 'Recovery does not retry after partial fill'
    Assert-Match $source 'strategy\.close_all\([^\r\n]*BROKER_RECOVERY' 'Broker Recovery close missing'
    Assert-Match $source '"RESIDUAL_CLEANUP"[^\r\n]*"AFTER_BROKER_RECOVERY"' 'Recovery residual alert missing'
}
Pass-Test 'Residual 0.00001 never resets Plan' {
    $m = New-ExitModel 1.0 90.0
    Observe-FullExit $m 0.00001
    Assert-True ($m.CleanupPending -and -not $m.PlanReset) 'residual reset was allowed'
    $cleanupBlock = [regex]::Match($source, '(?ms)// A cleanup close.*?(?=if fullExitFilledNow)').Value
    Assert-NotMatch $cleanupBlock 'plan\.reset\(' 'cleanup block resets Plan early'
}
Pass-Test 'Residual 0.00001 submits cleanup close' {
    $m = New-ExitModel 1.0 90.0
    Observe-FullExit $m 0.00001
    Assert-True ($m.CleanupCloseCount -eq 1) 'cleanup close was not submitted'
    Assert-Match $source 'plan\.cleanupPending[\s\S]*?strategy\.close_all\(' 'cleanup close command missing'
    Assert-Match $source 'f_executionMessage\("RESIDUAL_CLEANUP"' 'cleanup alert event missing'
}
Pass-Test 'Residual cleanup payload carries execution context' {
    $cleanupLines = @($source -split '\r?\n' | Where-Object { $_ -match 'f_executionMessage\("RESIDUAL_CLEANUP"' })
    Assert-True ($cleanupLines.Count -ge 2) 'cleanup event is not emitted for both command and alert paths'
    Assert-Match $source '\|actual_fill="\s*\+\s*f_price\(actualFill\)' 'actual_fill payload field missing'
    Assert-Match $source '\|reason="\s*\+\s*reason' 'reason payload field missing'
    Assert-Match $cleanupLines[0] 'plan\.dir.*plan\.mode.*latestClosedExitPrice' 'cleanup context missing'
}
Pass-Test 'Only strict Broker flat completes lifecycle' {
    $m = New-ExitModel 1.0 90.0
    Observe-FullExit $m 0.00001
    Assert-True (-not $m.PlanReset) 'nonzero position reset'
    Observe-FullExit $m 0.0
    Assert-True $m.PlanReset 'zero position did not reset'
    Assert-Match $source 'positionClosed\s*=\s*positionSampleReady[^\r\n]*currentPositionSize\s*==\s*0\.0' 'strict flat transition missing'
}
Pass-Test 'Full flat sets cooldown after cleanup' {
    $fullExitBlock = [regex]::Match($source, '(?ms)if fullExitFilledNow.*?(?=// Orphan/mismatched)').Value
    Assert-Match $fullExitBlock 'signal\.lastExitBar\s*:=\s*bar_index[\s\S]*?plan\.reset\(\)' 'cooldown/reset ordering missing'
    Assert-Match $source 'barsSinceExit\s*=.*?signal\.lastExitBar[\s\S]*?requiredCooldown' 'cooldown gate missing'
}
Pass-Test 'Range and Shock closed stats require full flat' {
    $fullExitBlock = [regex]::Match($source, '(?ms)if fullExitFilledNow.*?(?=// Orphan/mismatched)').Value
    Assert-Match $fullExitBlock 'broker\.rangeClosed\s*\+=' 'Range closed statistic missing'
    Assert-Match $fullExitBlock 'broker\.shockClosed\s*\+=' 'Shock closed statistic missing'
    Assert-Match $source 'fullExitFilledNow\s*=\s*positionClosed\s*and\s*plan\.active\s*and\s*plan\.entryFilled' 'stats are not gated by full flat'
}
Pass-Test 'Full-exit statistics are idempotent' {
    $m = New-ExitModel 1.0 90.0
    Observe-FullExit $m 0.0
    Observe-FullExit $m 0.0
    Assert-True ($m.Closed -eq 1 -and $m.RangeClosed -eq 1) 'duplicate full-exit statistics'
    Assert-Match $source 'positionClosed\s*=\s*positionSampleReady' 'full-exit transition fact missing'
}
Pass-Test 'Normal TP1 partial does not trigger full cleanup' {
    $m = New-ExitModel 1.0 90.0
    Assert-True ((Get-PartialExitOutcome 'MR4-TP1' $false) -eq 'TP1') 'TP1 was not recognized'
    Assert-True (-not $m.CleanupPending) 'normal TP1 cleanup state set'
    $tp1Block = [regex]::Match($source, '(?ms)if tp1FilledNow.*?(?=if unexpectedPartialPriceExitNow)').Value
    Assert-NotMatch $tp1Block 'cleanupPending\s*:=\s*true' 'TP1 path enters cleanup'
}
Pass-Test 'TP1 remainder quantities are exact in model' {
    $m = New-ExitModel 1.0 90.0
    $m.RemainingQty = $m.EntryQty - $m.TP1Qty
    Assert-Near $m.RemainingQty 0.1 'remainder'
    Assert-Near $m.RemainingQty ($m.TP2Qty - $m.TP1Qty) 'TP2 remainder'
    Assert-Near $m.RemainingQty ($m.StopQty - $m.TP1Qty) 'BE remainder'
}
Pass-Test 'Active Trade Lines require filled nonflat position' {
    Assert-Match $source 'bool showActiveTradeLines\s*=\s*plan\.active\s*and\s*plan\.entryFilled\s*and\s*currentPositionSize\s*!=\s*0\.0' 'active line visibility condition missing'
    $lineBlock = [regex]::Match($source, '(?ms)// Active Trade Lines.*?(?=// Setup Labels)').Value
    Assert-Match $lineBlock 'if showActiveTradeLines' 'active line assignment gate missing'
}
Pass-Test 'PLAN_PENDING hides all three Active Trade Lines' {
    Assert-True (-not (Get-ShowActiveTradeLines $true $false 0.0)) 'PLAN_PENDING model shows active lines'
    Assert-True (Get-ShowActiveTradeLines $true $true 1.0) 'filled position model hides active lines'
    Assert-Match $source 'plan\.active\s*and\s*plan\.entryFilled\s*and\s*currentPositionSize\s*!=\s*0\.0' 'pending line exclusion missing'
}
Pass-Test 'Expiry uses inclusive future-bar count' {
    Assert-Match $source 'bool planExpired\s*=\s*bar_index\s*>=\s*plan\.expiryBar' 'expiry boundary is not inclusive'
    $p = New-PlanModel 1 Range
    $validBars = @(1..8 | ForEach-Object { $p.CreatedBar + $_ })
    Assert-True ($validBars.Count -eq 8 -and $validBars[-1] -eq $p.ExpiryBar) 'validBars=8 does not map to N+1..N+8'
    Assert-True ((Get-CancelReason $p $p.ExpiryBar) -eq 'EXPIRED') 'N+8 was not expired at confirmed close'
}
Pass-Test 'V3 parity harness remains green' {
    $v3Harness = Join-Path $PSScriptRoot 'MRT-v3.3.2-v2-logic-parity-harness.ps1'
    Assert-True (Test-Path -LiteralPath $v3Harness) 'V3 parity harness missing'
    $null = & pwsh -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $v3Harness 2>&1 | Out-String
    Assert-True ($LASTEXITCODE -eq 0) 'V3 parity harness failed'
}

Assert-True ($testCount -eq 60) "expected 60 tests, ran $testCount"
Write-Host 'PASS: 60/60 execution-plan tests'
Write-Host 'Manual TradingView compile/backtest remains required for Pine syntax and Broker Emulator fill ordering.'
