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
    if ($Bar -gt $Plan.ExpiryBar) { return 'EXPIRED' }
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
    Assert-True ((Get-CancelReason $p 18) -eq '') 'expired too early'
    Assert-True ((Get-CancelReason $p 19) -eq 'EXPIRED') 'did not expire'
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
Pass-Test 'Entry fill submits TP and Stop' {
    Assert-Match $source 'if entryFilledNow[\s\S]*?strategy\.exit\("MR4-TP1"[\s\S]*?strategy\.exit\("MR4-TP2"' 'fill brackets missing'
}
Pass-Test 'TP1 remaining quantity correct' {
    $p = New-PlanModel 1 Range
    Fill-Entry $p 14 83.25
    $null = Fill-TP1 $p 15
    Assert-Near $p.PositionPct 50.0 'remainder'
    Assert-Match $source 'qty_percent\s*=\s*trimPct[\s\S]*?qty_percent\s*=\s*100\.0\s*-\s*trimPct' 'reservation missing'
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
    Assert-Match $source 'strategy\.exit\("MR4-TP1"[^\r\n]*stop\s*=\s*plan\.baseStop' 'TP1 stop missing'
    Assert-Match $source 'strategy\.exit\("MR4-TP2"[^\r\n]*stop\s*=\s*plan\.baseStop' 'TP2 stop missing'
}
Pass-Test 'BE Stop is a real updated order' {
    Assert-Match $source 'strategy\.cancel\("MR4-TP2"\)[\s\S]*?strategy\.exit\("MR4-TP2"[^\r\n]*stop\s*=\s*plan\.activeStop' 'BE bracket missing'
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
    Assert-Match $source 'partialReductionNow[\s\S]*?not plan\.partialFilled' 'source dedupe missing'
}
Pass-Test 'Same-bar final Stop idempotence' {
    Assert-Match $source 'fullExitFilledNow\s*=\s*positionClosed\s*and\s*plan\.active\s*and\s*plan\.entryFilled' 'fact gate missing'
    Assert-Match $source 'alert\(f_executionMessage\(fillEventName[\s\S]*?plan\.reset\(\)' 'atomic reset missing'
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

Assert-True ($testCount -eq 32) "expected 32 tests, ran $testCount"
Write-Host 'PASS: 32/32 execution-plan tests'
Write-Host 'Manual TradingView compile/backtest remains required for Pine syntax and Broker Emulator fill ordering.'
