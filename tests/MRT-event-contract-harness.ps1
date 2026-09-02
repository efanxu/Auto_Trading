$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
$eventPath = Join-Path $repoRoot 'MRT_EVENT.pine'
$v3Path = Join-Path $repoRoot 'MRT.pine'
$v4Path = Join-Path $repoRoot 'MRT_V4.pine'
$docPath = Join-Path $repoRoot 'MRT_EVENT.md'
$changelogPath = Join-Path $repoRoot 'CHANGELOG.md'
$v3HarnessPath = Join-Path $PSScriptRoot 'MRT-v3.3.2-v2-logic-parity-harness.ps1'
$v4HarnessPath = Join-Path $PSScriptRoot 'MRT-v4-execution-plan-harness.ps1'

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "ASSERT FAILED: $Message" }
}

function Assert-Match {
    param([string]$Text, [string]$Pattern, [string]$Message)
    Assert-True ([regex]::IsMatch($Text, $Pattern, [Text.RegularExpressions.RegexOptions]::Singleline)) $Message
}

function Assert-NotMatch {
    param([string]$Text, [string]$Pattern, [string]$Message)
    Assert-True (-not [regex]::IsMatch($Text, $Pattern, [Text.RegularExpressions.RegexOptions]::Singleline)) $Message
}

function Pass-Test {
    param([string]$Name, [scriptblock]$Body)
    & $Body
    $script:testCount += 1
    Write-Host "PASS [$($script:testCount.ToString('00'))] $Name"
}

function New-ShadowEvent {
    param(
        [ValidateSet(1, -1)][int]$Direction,
        [ValidateSet(1, 2)][int]$Mode,
        [double]$EntryPrice,
        [long]$EntryTimestamp = 0
    )

    [pscustomobject]@{
        Direction = $Direction
        Mode = $Mode
        EntryPrice = $EntryPrice
        EntryTimestamp = $EntryTimestamp
        Expiry30Time = [long]($EntryTimestamp + 30 * 60 * 1000)
        Expiry60Time = [long]($EntryTimestamp + 60 * 60 * 1000)
        Settled30 = $false
        Settled60 = $false
        Unresolved30 = $false
        Unresolved60 = $false
        Result30 = 0
        Result60 = 0
        Expiry30Price = $null
        Expiry60Price = $null
        Pnl30 = $null
        Pnl60 = $null
        Observed30Time = $null
        Observed60Time = $null
        TimingError30Seconds = $null
        TimingError60Seconds = $null
    }
}

function Get-FirstObservation {
    param(
        [pscustomobject]$Event,
        [ValidateSet(30, 60)][int]$Horizon,
        [object[]]$Observations
    )

    $targetTime = if ($Horizon -eq 30) { $Event.Expiry30Time } else { $Event.Expiry60Time }
    foreach ($observation in @($Observations)) {
        if ($null -ne $observation -and $observation.TimeClose -ge $targetTime) {
            return $observation
        }
    }
    return $null
}

function Settle-ShadowEvent {
    param(
        [pscustomobject]$Event,
        [ValidateSet(30, 60)][int]$Horizon,
        [object[]]$Observations,
        [bool]$CoverageComplete = $true,
        [double]$WinNet = 4.25,
        [double]$LossNet = -5.0
    )

    $is30 = $Horizon -eq 30
    if (($is30 -and ($Event.Settled30 -or $Event.Unresolved30)) -or (-not $is30 -and ($Event.Settled60 -or $Event.Unresolved60))) {
        return $null
    }

    $observation = Get-FirstObservation $Event $Horizon $Observations
    if ($null -eq $observation) {
        if (-not $CoverageComplete) { return $null }

        if ($is30) {
            $Event.Unresolved30 = $true
        }
        else {
            $Event.Unresolved60 = $true
        }
        return [pscustomobject]@{
            Status = 'UNRESOLVED_NO_INTRABAR_DATA'
            Won = $null
            Result = 0
            Pnl = $null
            ObservedTime = $null
            TimingErrorSeconds = $null
        }
    }

    $targetTime = if ($is30) { $Event.Expiry30Time } else { $Event.Expiry60Time }
    $observedTime = [long]$observation.TimeClose
    $won = if ($Event.Direction -eq 1) { $observation.Close -gt $Event.EntryPrice } else { $observation.Close -lt $Event.EntryPrice }
    $result = if ($won) { 1 } else { -1 }
    $pnl = if ($won) { $WinNet } else { $LossNet }
    $timingErrorSeconds = ($observedTime - $targetTime) / 1000.0

    if ($is30) {
        $Event.Settled30 = $true
        $Event.Result30 = $result
        $Event.Expiry30Price = $observation.Close
        $Event.Pnl30 = $pnl
        $Event.Observed30Time = $observedTime
        $Event.TimingError30Seconds = $timingErrorSeconds
    }
    else {
        $Event.Settled60 = $true
        $Event.Result60 = $result
        $Event.Expiry60Price = $observation.Close
        $Event.Pnl60 = $pnl
        $Event.Observed60Time = $observedTime
        $Event.TimingError60Seconds = $timingErrorSeconds
    }

    [pscustomobject]@{
        Status = 'RESOLVED'
        Won = $won
        Result = $result
        Pnl = $pnl
        ObservedTime = $observedTime
        TimingErrorSeconds = $timingErrorSeconds
    }
}

function New-Stats {
    [pscustomobject]@{
        Resolved = 0
        Unresolved = 0
        Wins = 0
        Losses = 0
        NetPnl = 0.0
        TimingErrors = [Collections.Generic.List[double]]::new()
        LongEvents = 0
        LongWins = 0
        ShortEvents = 0
        ShortWins = 0
        RangeEvents = 0
        RangeWins = 0
        ShockEvents = 0
        ShockWins = 0
    }
}

function Add-Stats {
    param([pscustomobject]$Stats, [pscustomobject]$Event, [pscustomobject]$Result)
    Assert-True ($Result.Status -eq 'RESOLVED') 'only resolved results can enter formal stats'
    $Stats.Resolved += 1
    if ($Result.Won) { $Stats.Wins += 1 } else { $Stats.Losses += 1 }
    $Stats.NetPnl += $Result.Pnl
    $Stats.TimingErrors.Add([double]$Result.TimingErrorSeconds)
    if ($Event.Direction -eq 1) {
        $Stats.LongEvents += 1
        if ($Result.Won) { $Stats.LongWins += 1 }
    }
    else {
        $Stats.ShortEvents += 1
        if ($Result.Won) { $Stats.ShortWins += 1 }
    }
    if ($Event.Mode -eq 1) {
        $Stats.RangeEvents += 1
        if ($Result.Won) { $Stats.RangeWins += 1 }
    }
    else {
        $Stats.ShockEvents += 1
        if ($Result.Won) { $Stats.ShockWins += 1 }
    }
}

function Add-Unresolved {
    param([pscustomobject]$Stats, [pscustomobject]$Result)
    Assert-True ($Result.Status -eq 'UNRESOLVED_NO_INTRABAR_DATA') 'unexpected unresolved status'
    $Stats.Unresolved += 1
}

$source = [IO.File]::ReadAllText($eventPath)
$doc = [IO.File]::ReadAllText($docPath)
$changelog = [IO.File]::ReadAllText($changelogPath)
$testCount = 0

Write-Host 'MR-T Event Contract v0.2.0 harness'

Pass-Test '01 Event script exists and v0.2.0 identity is explicit' {
    Assert-True (Test-Path -LiteralPath $eventPath) 'MRT_EVENT.pine missing'
    Assert-Match $source 'strategy\("MR-T Event Contract v0\.2\.0"' 'strategy title/version'
    Assert-Match $source 'string SCRIPT_VERSION\s*=\s*"0\.2\.0"' 'version constant'
}

Pass-Test '02 MRT.pine and MRT_V4.pine remain unchanged from HEAD' {
    $null = & git -C $repoRoot diff HEAD --quiet -- MRT.pine MRT_V4.pine
    Assert-True ($LASTEXITCODE -eq 0) 'formal MR-T scripts differ from HEAD'
}

Pass-Test '03 v4.5.1 execution settings plus realtime settlement setting are explicit' {
    foreach ($setting in @('process_orders_on_close\s*=\s*false', 'calc_on_order_fills\s*=\s*true', 'calc_on_every_tick\s*=\s*true', 'use_bar_magnifier\s*=\s*true', 'commission_value\s*=\s*0', 'slippage\s*=\s*0')) {
        Assert-Match $source $setting "missing execution setting: $setting"
    }
    Assert-NotMatch $source 'calc_on_every_history_tick\s*=\s*true' 'historical-tick execution must stay disabled'
}

Pass-Test '04 confirmed 15m Signal and confirmed 1H Regime remain gated' {
    foreach ($name in @('barstate\.isconfirmed', 'allowBarCloseDecision', 'request\.security\(syminfo\.tickerid,\s*htfTf,\s*f_slopeATRPrev', 'request\.security\(syminfo\.tickerid,\s*htfTf,\s*f_erPrev', 'hardTrendVeto', 'rangeEnvironment', 'shockEnvironment', 'longShockSetup', 'shortShockSetup', 'longRangeSetup', 'shortRangeSetup')) {
        Assert-Match $source $name "missing confirmed signal component: $name"
    }
    Assert-Match $source 'bool setupReadyForPreplan\s*=\s*allowBarCloseDecision' 'PREPLAN is not confirmed-close gated'
}

Pass-Test '05 PREPLAN source bar and next valid bar are explicit' {
    Assert-Match $source 'assist\.sourceBar\s*:=\s*bar_index\s*\n\s*assist\.validBar\s*:=\s*bar_index\s*\+\s*1' 'source N / valid N+1'
    Assert-Match $source 'strategy\.entry\("MR-L"[^\r\n]*stop\s*=.*limit\s*=' 'MR-L Stop-Limit'
    Assert-Match $source 'strategy\.entry\("MR-S"[^\r\n]*stop\s*=.*limit\s*=' 'MR-S Stop-Limit'
}

Pass-Test '06 Event clock uses Broker fill timestamp and millisecond targets' {
    Assert-Match $source 'strategy\.opentrades\.entry_time\(fillTradeIndex\)' 'entry timestamp does not prefer Broker trade fact'
    Assert-Match $source 'newEvent\.entryTimestamp\s*:=\s*actualEntryTimestamp' 'Event entry timestamp missing'
    Assert-Match $source 'int EVENT_30M_MS\s*=\s*30\s*\*\s*60\s*\*\s*1000' '30m millisecond constant missing'
    Assert-Match $source 'int EVENT_1H_MS\s*=\s*60\s*\*\s*60\s*\*\s*1000' '1h millisecond constant missing'
    Assert-Match $source 'newEvent\.expiry30Time\s*:=\s*actualEntryTimestamp\s*\+\s*EVENT_30M_MS' '30m target not timestamp-based'
    Assert-Match $source 'newEvent\.expiry60Time\s*:=\s*actualEntryTimestamp\s*\+\s*EVENT_1H_MS' '1h target not timestamp-based'
    Assert-NotMatch $source 'expiry30Bar|expiry60Bar|EVENT_30M_BARS|EVENT_1H_BARS' 'bar-based expiry field remains'
    Assert-NotMatch $source 'bar_index\s*>=\s*[^\r\n]*expiry' 'bar index still drives expiry'
}

Pass-Test '07 Event stores target and observation diagnostics without an entry bar clock' {
    $eventType = [regex]::Match($source, '(?ms)^type MRShadowEvent.*?(?=^\s*var MRSignalState)').Value
    Assert-True ($eventType.Length -gt 0) 'MRShadowEvent type missing'
    foreach ($field in @('entryTimestamp', 'expiry30Time', 'expiry60Time', 'observed30Time', 'observed60Time', 'timingError30Seconds', 'timingError60Seconds', 'unresolved30', 'unresolved60')) {
        Assert-Match $eventType ("varip [^\r\n]+\s+{0}\s*=" -f $field) "missing Event field: $field"
    }
    Assert-NotMatch $eventType 'entryBar|expiry30Bar|expiry60Bar' 'MRShadowEvent still stores bar expiry state'
}

Pass-Test '08 historical settlement requests and scans 2m time/time_close/close arrays' {
    Assert-Match $source 'request\.security_lower_tf\(syminfo\.tickerid,\s*"2",\s*\[time,\s*time_close,\s*close\]\)' '2m lower-TF tuple missing'
    Assert-Match $source 'array\.get\(lowerTimes,\s*lowerIndex\)' 'lower time is not read'
    Assert-Match $source 'array\.get\(lowerTimeCloses,\s*lowerIndex\)' 'lower time_close is not read'
    Assert-Match $source 'array\.get\(lowerCloses,\s*lowerIndex\)' 'lower close is not read'
    Assert-Match $source 'lowerTimeClose\s*>=\s*event\.expiry30Time' '30m first at/after target search missing'
    Assert-Match $source 'lowerTimeClose\s*>=\s*event\.expiry60Time' '1h first at/after target search missing'
    Assert-Match $source 'observedPrice30\s*:=\s*lowerClose' '30m price is not lower-TF close'
    Assert-Match $source 'observedPrice60\s*:=\s*lowerClose' '1h price is not lower-TF close'
}

Pass-Test '09 realtime settlement uses timenow and the first realtime tick' {
    Assert-Match $source 'bool realtimeSettlementExecution\s*=\s*barstate\.isrealtime' 'realtime settlement gate missing'
    Assert-Match $source 'realtimeSettlementExecution\s+and\s+timenow\s*>=\s*event\.expiry30Time' '30m timenow gate missing'
    Assert-Match $source 'realtimeSettlementExecution\s+and\s+timenow\s*>=\s*event\.expiry60Time' '1h timenow gate missing'
    Assert-Match $source 'observedTime30\s*:=\s*timenow[\s\S]{0,300}observedPrice30\s*:=\s*close' '30m realtime observation missing'
    Assert-Match $source 'observedTime60\s*:=\s*timenow[\s\S]{0,300}observedPrice60\s*:=\s*close' '1h realtime observation missing'
}

Pass-Test '10 unresolved coverage is explicit and never falls back to a 15m close' {
    Assert-Match $source 'event\.unresolved30\s*:=\s*true' '30m unresolved state missing'
    Assert-Match $source 'event\.unresolved60\s*:=\s*true' '1h unresolved state missing'
    Assert-Match $source 'UNRESOLVED_NO_INTRABAR_DATA' 'unresolved status missing'
    Assert-Match $source 'eventStats30\.recordUnresolved\(\)' '30m unresolved counter missing'
    Assert-Match $source 'eventStats60\.recordUnresolved\(\)' '1h unresolved counter missing'
    Assert-Match $source '\(event\.settled30\s+or\s+event\.unresolved30\)\s+and\s+\(event\.settled60\s+or\s+event\.unresolved60\)' 'queue cleanup does not understand unresolved horizons'
    Assert-NotMatch $source '(?ms)if historicalSettlementExecution.*?event\.expiry30Time[\s\S]{0,1500}event\.expiry30Price\s*:=\s*close' 'historical 30m settlement has a chart-close fallback'
    Assert-NotMatch $source '(?ms)if historicalSettlementExecution.*?event\.expiry60Time[\s\S]{0,1500}event\.expiry60Price\s*:=\s*close' 'historical 1h settlement has a chart-close fallback'
}

Pass-Test '11 strict direction outcomes and zero-cost Event payout are explicit' {
    foreach ($pattern in @('event\.direction\s*==\s*1\s*\?\s*observedPrice30\s*>\s*event\.entryPrice\s*:\s*observedPrice30\s*<\s*event\.entryPrice', 'event\.direction\s*==\s*1\s*\?\s*observedPrice60\s*>\s*event\.entryPrice\s*:\s*observedPrice60\s*<\s*event\.entryPrice', 'float winNetProfit\s*=\s*winningReturnUSDT\s*-\s*stakeUSDT', 'float lossNetProfit\s*=\s*-stakeUSDT', 'float breakEvenWinRate\s*=\s*winningReturnUSDT\s*>\s*0\.0')) {
        Assert-Match $source $pattern "missing contract rule: $pattern"
    }
    Assert-NotMatch $source 'strategy\.netprofit|strategy\.closedtrades|commissionBps|slippageTicks' 'formal Event result reads Strategy Tester cost/P&L'
}

Pass-Test '12 resolved/unresolved statistics and timing aggregates are exposed' {
    foreach ($name in @('resolved', 'unresolved', 'wins', 'losses', 'maxWinStreak', 'maxLossStreak', 'maxDrawdown', 'timingErrorSecondsTotal', 'timingErrorCount', 'maxTimingErrorSeconds', 'eventEquity30', 'eventEquity60', 'winRate30', 'winRate60', 'ev30', 'ev60')) {
        Assert-Match $source ([regex]::Escape($name)) "missing formal statistic: $name"
    }
    foreach ($label in @('Resolved 30m Events', 'Unresolved 30m Events', 'Resolved 1h Events', 'Unresolved 1h Events', 'Average 30m Timing Error', 'Maximum 30m Timing Error', 'Average 1h Timing Error', 'Maximum 1h Timing Error')) {
        Assert-Match $source ([regex]::Escape($label)) "missing Data Window diagnostic: $label"
    }
    Assert-Match $source 'f_rate\(eventStats30\.wins,\s*eventStats30\.resolved\)' '30m Win Rate denominator is not resolved events'
    Assert-Match $source 'f_rate\(eventStats60\.wins,\s*eventStats60\.resolved\)' '1h Win Rate denominator is not resolved events'
}

Pass-Test '13 Long/Short, Range/Shock, and four fine categories remain separate' {
    foreach ($name in @('longEvents', 'longWins', 'shortEvents', 'shortWins', 'rangeEvents', 'rangeWins', 'shockEvents', 'shockWins', 'rangeLongEvents', 'rangeShortEvents', 'shockLongEvents', 'shockShortEvents')) {
        Assert-Match $source ([regex]::Escape($name)) "missing category statistic: $name"
    }
    foreach ($label in @('Long Events / Win Rate', 'Short Events / Win Rate', 'Range Events / Win Rate', 'Shock Events / Win Rate', 'Range Long (N / WR)', 'Range Short (N / WR)', 'Shock Long (N / WR)', 'Shock Short (N / WR)')) {
        Assert-Match $source ([regex]::Escape($label)) "missing category panel field: $label"
    }
}

Pass-Test '14 panel explicitly separates Event Contract from Strategy Tester probe' {
    Assert-Match $source 'table\.new\(position\.top_right,\s*3,\s*38' 'panel dimensions not updated'
    Assert-Match $source 'Event Contract Statistics' 'formal panel heading missing'
    Assert-Match $source 'Strategy Tester trades = Broker probe only' 'probe-only Strategy Tester note missing'
    Assert-Match $source 'Net Event P&L' 'formal P&L panel field missing'
    Assert-Match $source 'EV / Event' 'formal EV panel field missing'
}

Pass-Test '15 target/observed/timing diagnostics are named for both horizons' {
    foreach ($label in @('30m Target Time', '30m Observed Time', '30m Timing Error Seconds', '1h Target Time', '1h Observed Time', '1h Timing Error Seconds')) {
        Assert-Match $source ([regex]::Escape($label)) "missing timing diagnostic: $label"
    }
    Assert-Match $source 'f_timingErrorSeconds\(int targetTime,\s*int observedTime\)' 'timing error helper missing'
}

Pass-Test '16 ordinary MR-T TP/SL/BE lifecycle redundancy is absent' {
    foreach ($pattern in @('strategy\.exit\s*\(', 'strategy\.order\s*\(', 'rangePartialZ', 'rangeExitZ', 'shockPartialZ', 'shockExitZ', 'hardStopATR', 'stopMode', 'balancedWeight', 'moveStopToBE', 'tp1Provisional', 'tp2Provisional', 'stopProvisional', 'trimPct', 'Trend Fail', 'Early Failure', 'Max Risk Stop')) {
        Assert-NotMatch $source $pattern "ordinary lifecycle artifact remains: $pattern"
    }
    Assert-Match $source 'strategy\.close\(filledEntryId,\s*comment\s*=\s*"EVENT_BROKER_RELEASE"[^\r\n]*immediately\s*=\s*true' 'probe release is not immediate'
}

Pass-Test '17 Event has independent 30m and 1h timestamp targets' {
    $entryTimestamp = [long](17 * 60 * 1000)
    $event = New-ShadowEvent 1 1 100 $entryTimestamp
    Assert-True ($event.Expiry30Time -eq [long](47 * 60 * 1000)) '17 -> 47 30m target failed'
    Assert-True ($event.Expiry60Time -eq [long](77 * 60 * 1000)) '17 -> 77 1h target failed'
}

Pass-Test '18 first lower-TF observation at or after target is selected' {
    $event = New-ShadowEvent 1 1 100 ([long](17 * 60 * 1000))
    $observations = @(
        [pscustomobject]@{ Time = [long](46 * 60 * 1000); TimeClose = [long](46 * 60 * 1000); Close = 99.0 },
        [pscustomobject]@{ Time = [long](48 * 60 * 1000); TimeClose = [long](48 * 60 * 1000); Close = 101.0 }
    )
    $result = Settle-ShadowEvent $event 30 $observations
    Assert-True ($result.Status -eq 'RESOLVED' -and $event.Observed30Time -eq [long](48 * 60 * 1000) -and $event.Expiry30Price -eq 101.0 -and $event.TimingError30Seconds -eq 60.0) '46/48 first-observation selection failed'
}

Pass-Test '19 historical settlement does not substitute a 15m chart close' {
    $event = New-ShadowEvent 1 1 100 ([long](17 * 60 * 1000))
    $observations = @(
        [pscustomobject]@{ Time = [long](46 * 60 * 1000); TimeClose = [long](46 * 60 * 1000); Close = 99.0 },
        [pscustomobject]@{ Time = [long](48 * 60 * 1000); TimeClose = [long](48 * 60 * 1000); Close = 101.0 }
    )
    $chartClose = 110.0
    $result = Settle-ShadowEvent $event 30 $observations
    Assert-True ($result.Pnl -eq 4.25 -and $event.Expiry30Price -ne $chartClose) '15m chart close was used as expiry price'
}

Pass-Test '20 Long strict greater-than and Short strict less-than are Wins' {
    $long = New-ShadowEvent 1 1 100
    $short = New-ShadowEvent -1 1 100
    $longResult = Settle-ShadowEvent $long 30 @([pscustomobject]@{ TimeClose = 1800060; Close = 100.01 })
    $shortResult = Settle-ShadowEvent $short 30 @([pscustomobject]@{ TimeClose = 1800060; Close = 99.99 })
    Assert-True ($longResult.Won -and $shortResult.Won) 'strict direction win comparison failed'
}

Pass-Test '21 equality is a Loss for both directions and horizons' {
    foreach ($direction in @(1, -1)) {
        foreach ($horizon in @(30, 60)) {
            $event = New-ShadowEvent $direction 1 100
            $target = if ($horizon -eq 30) { $event.Expiry30Time } else { $event.Expiry60Time }
            $result = Settle-ShadowEvent $event $horizon @([pscustomobject]@{ TimeClose = $target; Close = 100.0 })
            Assert-True (-not $result.Won -and $result.Result -eq -1 -and $result.Pnl -eq -5.0) "equality not Loss: dir=$direction horizon=$horizon"
        }
    }
}

Pass-Test '22 30m and 1h settlements are independent' {
    $event = New-ShadowEvent -1 2 100 ([long](17 * 60 * 1000))
    $r30 = Settle-ShadowEvent $event 30 @([pscustomobject]@{ TimeClose = 2880060; Close = 99.0 })
    $r60 = Settle-ShadowEvent $event 60 @([pscustomobject]@{ TimeClose = 4620000; Close = 100.3 })
    Assert-True ($r30.Won -and -not $r60.Won -and $event.Settled30 -and $event.Settled60) 'independent horizon outcomes failed'
}

Pass-Test '23 overlapping Shadow Events remain concurrently addressable' {
    $queue = [Collections.Generic.List[object]]::new()
    $first = New-ShadowEvent 1 1 100 ([long](17 * 60 * 1000))
    $second = New-ShadowEvent -1 2 200 ([long](17 * 60 * 1000 + 5 * 60 * 1000))
    $queue.Add($first)
    $queue.Add($second)
    Assert-True ($queue.Count -eq 2 -and $queue[0].EntryTimestamp -ne $queue[1].EntryTimestamp -and -not $queue[0].Settled30 -and -not $queue[1].Settled30) 'overlap queue failed'
}

Pass-Test '24 lower-TF unavailable marks a horizon unresolved' {
    $event = New-ShadowEvent 1 1 100 ([long](17 * 60 * 1000))
    $result = Settle-ShadowEvent $event 30 @()
    Assert-True ($result.Status -eq 'UNRESOLVED_NO_INTRABAR_DATA' -and $event.Unresolved30 -and -not $event.Settled30 -and $event.Pnl30 -eq $null) 'unavailable lower-TF coverage was not unresolved'
}

Pass-Test '25 unresolved horizons do not enter Win Rate or P&L' {
    $stats = New-Stats
    $unresolvedEvent = New-ShadowEvent 1 1 100
    $unresolved = Settle-ShadowEvent $unresolvedEvent 30 @()
    Add-Unresolved $stats $unresolved
    $resolvedEvent = New-ShadowEvent 1 1 100
    $resolved = Settle-ShadowEvent $resolvedEvent 30 @([pscustomobject]@{ TimeClose = 1800000; Close = 101.0 })
    Add-Stats $stats $resolvedEvent $resolved
    $winRate = $stats.Wins / $stats.Resolved * 100.0
    Assert-True ($stats.Resolved -eq 1 -and $stats.Unresolved -eq 1 -and $stats.Wins -eq 1 -and $stats.NetPnl -eq 4.25 -and $winRate -eq 100.0) 'unresolved horizon polluted formal stats'
}

Pass-Test '26 timing error aggregates are in seconds and preserve large errors' {
    $stats = New-Stats
    $first = New-ShadowEvent 1 1 100
    $firstResult = Settle-ShadowEvent $first 30 @([pscustomobject]@{ TimeClose = 1860000; Close = 101.0 })
    Add-Stats $stats $first $firstResult
    $second = New-ShadowEvent 1 1 100
    $secondResult = Settle-ShadowEvent $second 30 @([pscustomobject]@{ TimeClose = 1920000; Close = 101.0 })
    Add-Stats $stats $second $secondResult
    Assert-True ($stats.TimingErrors.Count -eq 2 -and (($stats.TimingErrors | Measure-Object -Average).Average -eq 90.0) -and ($stats.TimingErrors | Measure-Object -Maximum).Maximum -eq 120.0) 'timing aggregate calculation failed'
}

Pass-Test '27 payout model is +4.25U / -5U with zero fees' {
    $winNet = 9.25 - 5.0
    $lossNet = -5.0
    Assert-True ([math]::Abs($winNet - 4.25) -lt 1e-9 -and $lossNet -eq -5.0) 'payout model failed'
    Assert-Match $source 'commission_value\s*=\s*0' 'commission is not zero'
    Assert-Match $source 'slippage\s*=\s*0' 'slippage is not zero'
}

Pass-Test '28 Long/Short and Range/Shock categories only count resolved outcomes' {
    $stats = New-Stats
    $rangeLong = New-ShadowEvent 1 1 100
    $rangeShort = New-ShadowEvent -1 1 100
    $shockLong = New-ShadowEvent 1 2 100
    $shockShort = New-ShadowEvent -1 2 100
    foreach ($pair in @(
        @($rangeLong, (Settle-ShadowEvent $rangeLong 30 @([pscustomobject]@{ TimeClose = 1800000; Close = 101.0 }))),
        @($rangeShort, (Settle-ShadowEvent $rangeShort 30 @([pscustomobject]@{ TimeClose = 1800000; Close = 101.0 }))),
        @($shockLong, (Settle-ShadowEvent $shockLong 30 @([pscustomobject]@{ TimeClose = 1800000; Close = 101.0 }))),
        @($shockShort, (Settle-ShadowEvent $shockShort 30 @([pscustomobject]@{ TimeClose = 1800000; Close = 99.0 })))
    )) {
        Add-Stats $stats $pair[0] $pair[1]
    }
    Assert-True ($stats.Resolved -eq 4 -and $stats.LongEvents -eq 2 -and $stats.ShortEvents -eq 2 -and $stats.RangeEvents -eq 2 -and $stats.ShockEvents -eq 2) 'resolved category counters failed'
}

Pass-Test '29 probe size is independent from the Event stake' {
    Assert-Match $source 'default_qty_type\s*=\s*strategy\.percent_of_equity,\s*default_qty_value\s*=\s*0\.1' 'probe is not 0.1% equity'
    Assert-NotMatch $source 'default_qty_value\s*=\s*100' 'probe still uses 100% equity'
    Assert-Match $source 'stakeUSDT\s*=\s*input\.float\(5\.0' 'Event stake missing'
    Assert-Match $source 'strategy\.close\(filledEntryId[\s\S]{0,300}immediately\s*=\s*true' 'probe release path missing'
}

Pass-Test '30 active queue removes only after both horizons resolve or become unresolved' {
    $event = New-ShadowEvent 1 1 100
    $queue = [Collections.Generic.List[object]]::new()
    $queue.Add($event)
    $null = Settle-ShadowEvent $event 30 @([pscustomobject]@{ TimeClose = 1800000; Close = 101.0 })
    Assert-True ($queue.Count -eq 1 -and $event.Settled30 -and -not $event.Settled60) '30m settlement removed 1h state'
    $null = Settle-ShadowEvent $event 60 @()
    if (($event.Settled30 -or $event.Unresolved30) -and ($event.Settled60 -or $event.Unresolved60)) { $null = $queue.Remove($event) }
    Assert-True ($queue.Count -eq 0 -and $event.Unresolved60) 'fully closed/unresolved Event was not removed'
}

Pass-Test '31 original v3 and v4 harnesses are still invoked' {
    Assert-True (Test-Path -LiteralPath $v3HarnessPath) 'v3 harness missing'
    Assert-True (Test-Path -LiteralPath $v4HarnessPath) 'v4 harness missing'
    Assert-Match $source 'bool allowBarCloseDecision\s*=\s*barstate\.isconfirmed\s+and\s+not\s+isFillSynchronizationExecution' 'fill recalculation isolation changed'
}

Pass-Test '32 documentation and changelog describe v0.2.0 contract' {
    Assert-Match $doc '^# MR-T Event Contract v0\.2\.0' 'MRT_EVENT.md version missing'
    foreach ($term in @('actual Broker Fill timestamp', '30m Target', '1h Target', 'request.security_lower_tf', 'UNRESOLVED_NO_INTRABAR_DATA', 'Average and maximum timing errors', '5.00 USDT', '9.25 USDT', '0.1', 'Strategy Tester trades = Broker probe only', 'MRT.pine` and `MRT_V4.pine')) {
        Assert-Match $doc ([regex]::Escape($term)) "missing documentation term: $term"
    }
    Assert-Match $changelog '(?m)^## \[0\.2\.0\] — Timestamp-based intrabar Event settlement' 'CHANGELOG v0.2.0 release'
}

Pass-Test '33 source does not reintroduce ordinary Strategy Tester result accounting' {
    Assert-NotMatch $source 'strategy\.netprofit|strategy\.closedtrades|strategy commissions|Profit Factor|Average Trade' 'Strategy Tester metrics were used as Event results'
    Assert-Match $source 'eventEquity30\s*:=\s*eventStats30\.recordSettlement' '30m Event equity ledger missing'
    Assert-Match $source 'eventEquity60\s*:=\s*eventStats60\.recordSettlement' '1h Event equity ledger missing'
}

Pass-Test '34 formal MR-T sources remain byte-identical in the worktree diff' {
    $null = & git -C $repoRoot diff --quiet -- MRT.pine MRT_V4.pine
    Assert-True ($LASTEXITCODE -eq 0) 'formal MR-T scripts have worktree changes'
}

$null = & pwsh -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $v3HarnessPath 2>&1 | Out-String
Assert-True ($LASTEXITCODE -eq 0) 'MRT v3 harness failed'
$null = & pwsh -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $v4HarnessPath 2>&1 | Out-String
Assert-True ($LASTEXITCODE -eq 0) 'MRT v4 harness failed'

Assert-True ($testCount -ge 34) "expected at least 34 tests, ran $testCount"
Write-Host "PASS: $testCount/$testCount MRT Event Contract tests"
Write-Host 'TradingView Pine v6 compilation, lower-TF coverage at the account limit, Broker fill ordering, and realtime tick behavior remain manual release checks.'
