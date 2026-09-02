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
        [int]$EntryBar = 100
    )

    [pscustomobject]@{
        Direction = $Direction
        Mode = $Mode
        EntryPrice = $EntryPrice
        EntryBar = $EntryBar
        SourceBar = $EntryBar - 1
        ValidBar = $EntryBar
        Expiry30Bar = $EntryBar + 2
        Expiry60Bar = $EntryBar + 4
        Settled30 = $false
        Settled60 = $false
        Result30 = 0
        Result60 = 0
        Expiry30Price = $null
        Expiry60Price = $null
        Pnl30 = $null
        Pnl60 = $null
    }
}

function Settle-ShadowEvent {
    param(
        [pscustomobject]$Event,
        [ValidateSet(30, 60)][int]$Horizon,
        [double]$Close,
        [double]$WinNet = 4.25,
        [double]$LossNet = -5.0
    )

    $is30 = $Horizon -eq 30
    if ($is30 -and $Event.Settled30) { return $null }
    if (-not $is30 -and $Event.Settled60) { return $null }

    # Strict comparisons model the Pine contract: equality is Loss.
    $won = if ($Event.Direction -eq 1) { $Close -gt $Event.EntryPrice } else { $Close -lt $Event.EntryPrice }
    $result = if ($won) { 1 } else { -1 }
    $pnl = if ($won) { $WinNet } else { $LossNet }

    if ($is30) {
        $Event.Settled30 = $true
        $Event.Result30 = $result
        $Event.Expiry30Price = $Close
        $Event.Pnl30 = $pnl
    }
    else {
        $Event.Settled60 = $true
        $Event.Result60 = $result
        $Event.Expiry60Price = $Close
        $Event.Pnl60 = $pnl
    }

    [pscustomobject]@{ Won = $won; Result = $result; Pnl = $pnl }
}

function New-Stats {
    [pscustomobject]@{
        Total = 0
        Wins = 0
        Losses = 0
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
    param([pscustomobject]$Stats, [pscustomobject]$Event, [bool]$Won)
    $Stats.Total += 1
    if ($Won) { $Stats.Wins += 1 } else { $Stats.Losses += 1 }
    if ($Event.Direction -eq 1) {
        $Stats.LongEvents += 1
        if ($Won) { $Stats.LongWins += 1 }
    }
    else {
        $Stats.ShortEvents += 1
        if ($Won) { $Stats.ShortWins += 1 }
    }
    if ($Event.Mode -eq 1) {
        $Stats.RangeEvents += 1
        if ($Won) { $Stats.RangeWins += 1 }
    }
    else {
        $Stats.ShockEvents += 1
        if ($Won) { $Stats.ShockWins += 1 }
    }
}

$source = [IO.File]::ReadAllText($eventPath)
$changelog = [IO.File]::ReadAllText($changelogPath)
$testCount = 0

Write-Host 'MR-T Event Contract v0.1.0 harness'

Pass-Test '01 Event script exists and release identity is explicit' {
    Assert-True (Test-Path -LiteralPath $eventPath) 'MRT_EVENT.pine missing'
    Assert-Match $source 'strategy\("MR-T Event Contract v0\.1\.0"' 'strategy title/version'
    Assert-Match $source 'string SCRIPT_VERSION\s*=\s*"0\.1\.0"' 'version constant'
}
Pass-Test '02 MRT.pine and MRT_V4.pine remain unchanged from HEAD' {
    $null = & git -C $repoRoot diff HEAD --quiet -- MRT.pine MRT_V4.pine
    Assert-True ($LASTEXITCODE -eq 0) 'formal MR-T scripts differ from HEAD'
}
Pass-Test '03 v4.5.1 execution settings are retained' {
    foreach ($setting in @('process_orders_on_close\s*=\s*false', 'calc_on_order_fills\s*=\s*true', 'calc_on_every_tick\s*=\s*false', 'use_bar_magnifier\s*=\s*true')) {
        Assert-Match $source $setting "missing execution setting: $setting"
    }
}
Pass-Test '04 confirmed 15m and last-confirmed 1H regime are retained' {
    Assert-Match $source 'barstate\.isconfirmed' 'confirmed-bar decision gate'
    Assert-Match $source 'request\.security\(syminfo\.tickerid,\s*htfTf,\s*f_slopeATRPrev' 'confirmed 1H slope'
    Assert-Match $source 'request\.security\(syminfo\.tickerid,\s*htfTf,\s*f_erPrev' 'confirmed 1H ER'
}
Pass-Test '05 Hard Trend Veto, Range Engine, and Shock Engine remain in baseline' {
    foreach ($name in @('hardTrendVeto', 'rangeEnvironment', 'shockEnvironment', 'longShockSetup', 'shortShockSetup', 'longRangeSetup', 'shortRangeSetup')) {
        Assert-Match $source ([regex]::Escape($name)) "missing baseline signal component: $name"
    }
}
Pass-Test '06 PREPLAN source bar and next valid bar are explicit' {
    Assert-Match $source 'assist\.sourceBar\s*:=\s*bar_index\s*\n\s*assist\.validBar\s*:=\s*bar_index\s*\+\s*1' 'source N / valid N+1'
    Assert-Match $source 'actualEntryBar\s*\+\s*EVENT_30M_BARS' '30m anchored to fill bar'
    Assert-Match $source 'actualEntryBar\s*\+\s*EVENT_1H_BARS' '1h anchored to fill bar'
}
Pass-Test '07 both PREPLAN orders are real Stop-Limit orders' {
    foreach ($id in @('MR-L', 'MR-S')) {
        Assert-Match $source ('strategy\.entry\("{0}"[^\r\n]*stop\s*=.*limit\s*=' -f $id) "$id Stop-Limit"
    }
}
Pass-Test '08 Event Entry is owned by Broker flat-to-position fill fact' {
    Assert-Match $source 'positionEntered\s*=.*previousExecutionPositionSize\s*==\s*0\.0.*currentPositionSize\s*!=\s*0\.0' 'flat-to-position transition'
    Assert-Match $source 'entryFilled\s*=\s*positionEntered\s+and\s+broker\.entryIntentPending\s+and\s+assist\.active' 'PREPLAN ownership gate'
    Assert-Match $source 'float eventEntryPrice\s*=\s*strategy\.position_avg_price' 'actual Broker fill price'
}
Pass-Test '09 fill bar and entry timestamp use individual Broker trade facts' {
    Assert-Match $source 'strategy\.opentrades\.entry_bar_index\(fillTradeIndex\)' 'entry fill bar fact'
    Assert-Match $source 'strategy\.opentrades\.entry_time\(fillTradeIndex\)' 'entry timestamp fact'
    Assert-Match $source 'newEvent\.sourceBar\s*:=\s*assist\.sourceBar' 'source bar stored'
    Assert-Match $source 'newEvent\.validBar\s*:=\s*assist\.validBar' 'valid bar stored'
}
Pass-Test '10 Event queue stores independent 30m and 1h state' {
    Assert-Match $source 'type\s+MRShadowEvent' 'Shadow Event type'
    foreach ($field in @('direction', 'mode', 'entryPrice', 'entryBar', 'expiry30Bar', 'expiry60Bar', 'settled30', 'settled60', 'sourceBar', 'validBar')) {
        Assert-Match $source ("varip [^\r\n]+\s+{0}\s*=" -f $field) "missing Event field: $field"
    }
    Assert-Match $source 'varip array<MRShadowEvent>\s+activeEvents' 'active Event array'
}
Pass-Test '11 queue permits overlap and removes only fully settled records' {
    Assert-Match $source 'maxActiveEvents\s*=\s*input\.int\(100' 'fixed capacity input'
    Assert-Match $source 'array\.push\(activeEvents,\s*newEvent\)' 'append Event'
    Assert-Match $source 'if event\.settled30 and event\.settled60\s*\n\s*array\.remove\(activeEvents,\s*i\)' 'remove after both settlements'
    Assert-Match $source 'plot\(array\.size\(activeEvents\),\s*"Active Event Count"' 'active count diagnostic'
}
Pass-Test '12 settlement uses strict direction comparisons and equality is Loss' {
    Assert-Match $source 'event\.direction\s*==\s*1\s*\?\s*close\s*>\s*event\.entryPrice\s*:\s*close\s*<\s*event\.entryPrice' 'strict Long/Short settlement'
    Assert-Match $source 'float pnl30\s*=\s*won30\s*\?\s*winNetProfit\s*:\s*lossNetProfit' '30m payout branch'
    Assert-Match $source 'float pnl60\s*=\s*won60\s*\?\s*winNetProfit\s*:\s*lossNetProfit' '1h payout branch'
}
Pass-Test '13 ordinary TP/Stop/BE lifecycle is not used for Event results' {
    Assert-NotMatch $source 'strategy\.exit\s*\(' 'ordinary strategy.exit must be absent'
    Assert-NotMatch $source 'strategy\.order\s*\(' 'ordinary strategy.order brackets must be absent'
    Assert-Match $source 'strategy\.close\(filledEntryId,\s*comment\s*=\s*"EVENT_BROKER_RELEASE"' 'probe release is explicit'
}
Pass-Test '14 payout model and break-even rate are explicit' {
    Assert-Match $source 'stakeUSDT\s*=\s*input\.float\(5\.0' 'default stake'
    Assert-Match $source 'winningReturnUSDT\s*=\s*input\.float\(9\.25' 'default winning return'
    Assert-Match $source 'float winNetProfit\s*=\s*winningReturnUSDT\s*-\s*stakeUSDT' 'win net formula'
    Assert-Match $source 'float lossNetProfit\s*=\s*-stakeUSDT' 'loss net formula'
    Assert-Match $source 'float breakEvenWinRate\s*=\s*winningReturnUSDT\s*>\s*0\.0\s*\?\s*stakeUSDT\s*/\s*winningReturnUSDT\s*\*\s*100\.0' 'break-even formula'
}
Pass-Test '15 independent statistics and EV formula are exposed for both horizons' {
    foreach ($name in @('eventStats30', 'eventStats60', 'eventEquity30', 'eventEquity60', 'winRate30', 'winRate60', 'ev30', 'ev60', 'maxWinStreak', 'maxLossStreak', 'maxDrawdown')) {
        Assert-Match $source ([regex]::Escape($name)) "missing metric: $name"
    }
    Assert-Match $source 'winRate30\s*/\s*100\.0\s*\*\s*winNetProfit\s*\+\s*\(1\.0\s*-\s*winRate30\s*/\s*100\.0\)\s*\*\s*lossNetProfit' '30m EV formula'
    Assert-Match $source 'winRate60\s*/\s*100\.0\s*\*\s*winNetProfit\s*\+\s*\(1\.0\s*-\s*winRate60\s*/\s*100\.0\)\s*\*\s*lossNetProfit' '1h EV formula'
}
Pass-Test '16 direction, engine, and four fine categories are tracked' {
    foreach ($name in @('longEvents', 'longWins', 'shortEvents', 'shortWins', 'rangeEvents', 'rangeWins', 'shockEvents', 'shockWins', 'rangeLongEvents', 'rangeShortEvents', 'shockLongEvents', 'shockShortEvents')) {
        Assert-Match $source ([regex]::Escape($name)) "missing category statistic: $name"
    }
}
Pass-Test '17 panel has independent 30min and 1h columns' {
    Assert-Match $source 'table\.new\(position\.top_right,\s*3,\s*29' 'three-column panel'
    Assert-Match $source 'table\.cell\(panel,\s*1,\s*0,\s*"30min"' '30min column'
    Assert-Match $source 'table\.cell\(panel,\s*2,\s*0,\s*"1h"' '1h column'
    foreach ($label in @('Total Events', 'Wins', 'Losses', 'Win Rate', 'Break-even Win Rate', 'Win Rate Edge', 'Net P&L', 'Average P&L / Event', 'Expected Value / Event', 'Max Consecutive Wins', 'Max Consecutive Losses', 'Maximum Event Equity Drawdown')) {
        Assert-Match $source ([regex]::Escape($label)) "missing panel metric: $label"
    }
}
Pass-Test '18 equity curves are separate and hidden in Data Window' {
    Assert-Match $source 'plot\(eventEquity30,\s*"30m Event Cumulative P&L",\s*display\s*=\s*display\.data_window\)' '30m equity plot'
    Assert-Match $source 'plot\(eventEquity60,\s*"1h Event Cumulative P&L",\s*display\s*=\s*display\.data_window\)' '1h equity plot'
}
Pass-Test '19 entry and settlement labels are bounded' {
    Assert-Match $source 'maxEventLabels\s*=\s*input\.int\(250' 'label cap input'
    Assert-Match $source 'method retainEventLabel\(array<label>\s+labels,\s*label item\)' 'label queue method'
    Assert-Match $source '"EVENT "\s*\+\s*\(filledDir\s*==\s*1\s*\?\s*"LONG"\s*:\s*"SHORT"\)' 'entry label'
    foreach ($label in @('30W', '30L', '60W', '60L')) { Assert-Match $source $label "settlement label: $label" }
}
Pass-Test '20 required Data Window diagnostics are present' {
    foreach ($label in @('Last Event Direction', 'Last Event Mode', 'Last Event Entry Price', 'Last 30m Result', 'Last 30m Expiry Price', 'Last 30m P&L', 'Last 1h Result', 'Last 1h Expiry Price', 'Last 1h P&L', '30m Win Rate', '1h Win Rate', '30m EV / Event', '1h EV / Event', 'Active Event Count')) {
        Assert-Match $source ([regex]::Escape($label)) "missing Data Window field: $label"
    }
}

Pass-Test '21 Long 30m Win' {
    $event = New-ShadowEvent 1 1 100
    $result = Settle-ShadowEvent $event 30 101
    Assert-True ($result.Won -and $event.Result30 -eq 1 -and $event.Pnl30 -eq 4.25) 'Long 30m Win failed'
}
Pass-Test '22 Long 30m Loss' {
    $event = New-ShadowEvent 1 1 100
    $result = Settle-ShadowEvent $event 30 99
    Assert-True ((-not $result.Won) -and $event.Result30 -eq -1 -and $event.Pnl30 -eq -5.0) 'Long 30m Loss failed'
}
Pass-Test '23 Short 30m Win' {
    $event = New-ShadowEvent -1 1 100
    $result = Settle-ShadowEvent $event 30 99
    Assert-True ($result.Won -and $event.Result30 -eq 1) 'Short 30m Win failed'
}
Pass-Test '24 Short 30m Loss' {
    $event = New-ShadowEvent -1 1 100
    $result = Settle-ShadowEvent $event 30 101
    Assert-True ((-not $result.Won) -and $event.Result30 -eq -1) 'Short 30m Loss failed'
}
Pass-Test '25 Long and Short 1h Wins' {
    $long = New-ShadowEvent 1 1 100
    $short = New-ShadowEvent -1 2 100
    Assert-True ((Settle-ShadowEvent $long 60 101).Won) 'Long 1h Win failed'
    Assert-True ((Settle-ShadowEvent $short 60 99).Won) 'Short 1h Win failed'
}
Pass-Test '26 equality is Loss for both directions and horizons' {
    foreach ($direction in @(1, -1)) {
        foreach ($horizon in @(30, 60)) {
            $event = New-ShadowEvent $direction 1 100
            $result = Settle-ShadowEvent $event $horizon 100
            Assert-True (-not $result.Won -and $result.Pnl -eq -5.0) "equality not Loss: dir=$direction horizon=$horizon"
        }
    }
}
Pass-Test '27 one Entry can produce different 30m and 1h outcomes' {
    $event = New-ShadowEvent -1 2 100
    $r30 = Settle-ShadowEvent $event 30 99
    $r60 = Settle-ShadowEvent $event 60 100.3
    Assert-True ($r30.Won -and -not $r60.Won -and $event.Settled30 -and $event.Settled60) 'independent outcomes failed'
}
Pass-Test '28 multiple Shadow Events overlap in one queue' {
    $queue = [Collections.Generic.List[object]]::new()
    $queue.Add((New-ShadowEvent 1 1 100 100))
    $queue.Add((New-ShadowEvent -1 2 200 101))
    Assert-True ($queue.Count -eq 2 -and $queue[0].EntryBar -ne $queue[1].EntryBar) 'overlap queue failed'
}
Pass-Test '29 30m settlement leaves 1h Shadow Event active' {
    $event = New-ShadowEvent 1 1 100
    $null = Settle-ShadowEvent $event 30 101
    Assert-True ($event.Settled30 -and -not $event.Settled60) '30m settlement removed 1h state'
}
Pass-Test '30 fully settled Event is removed from active queue' {
    $queue = [Collections.Generic.List[object]]::new()
    $event = New-ShadowEvent 1 1 100
    $queue.Add($event)
    $null = Settle-ShadowEvent $event 30 101
    $null = Settle-ShadowEvent $event 60 101
    if ($event.Settled30 -and $event.Settled60) { $null = $queue.Remove($event) }
    Assert-True ($queue.Count -eq 0) 'fully settled Event not removed'
}
Pass-Test '31 payout model is +4.25U / -5U' {
    $winNet = 9.25 - 5.0
    $lossNet = -5.0
    Assert-True ([math]::Abs($winNet - 4.25) -lt 1e-9 -and $lossNet -eq -5.0) 'payout model failed'
}
Pass-Test '32 break-even win rate is approximately 54.054%' {
    $breakEven = 5.0 / 9.25 * 100.0
    Assert-True ([math]::Abs($breakEven - 54.054054) -lt 0.001) "break-even rate wrong: $breakEven"
}
Pass-Test '33 Long/Short and Range/Shock classifications are independent' {
    $stats = New-Stats
    $rangeLong = New-ShadowEvent 1 1 100
    $rangeShort = New-ShadowEvent -1 1 100
    $shockLong = New-ShadowEvent 1 2 100
    $shockShort = New-ShadowEvent -1 2 100
    Add-Stats $stats $rangeLong $true
    Add-Stats $stats $rangeShort $false
    Add-Stats $stats $shockLong $true
    Add-Stats $stats $shockShort $false
    Assert-True ($stats.LongEvents -eq 2 -and $stats.LongWins -eq 2) 'Long stats wrong'
    Assert-True ($stats.ShortEvents -eq 2 -and $stats.ShortWins -eq 0) 'Short stats wrong'
    Assert-True ($stats.RangeEvents -eq 2 -and $stats.RangeWins -eq 1) 'Range stats wrong'
    Assert-True ($stats.ShockEvents -eq 2 -and $stats.ShockWins -eq 1) 'Shock stats wrong'
}
Pass-Test '34 confirmed-bar / next-tick causal fill gate is preserved' {
    $sourceBar = 10
    $validBar = $sourceBar + 1
    $before = 0.0
    $after = 1.0
    $entryOwned = $before -eq 0.0 -and $after -ne 0.0 -and $validBar -eq 11
    Assert-True $entryOwned 'Entry must be a next-bar Broker transition'
    Assert-Match $source 'bool allowBarCloseDecision\s*=\s*barstate\.isconfirmed\s+and\s+not\s+isFillSynchronizationExecution' 'fill recalculation isolation'
    Assert-Match $source 'process_orders_on_close\s*=\s*false' 'next tick setting'
}
Pass-Test '35 Event documentation and changelog entry exist' {
    Assert-True (Test-Path -LiteralPath $docPath) 'MRT_EVENT.md missing'
    $doc = [IO.File]::ReadAllText($docPath)
    foreach ($term in @('d30f506719666df1ac89f79ef322f15f81d901ec', '30min', '1h', '5 USDT', '9.25 USDT', '54.05%', 'PREPLAN', 'Broker Fill', 'Event Contract Baseline Experiment')) {
        Assert-Match $doc ([regex]::Escape($term)) "missing doc term: $term"
    }
    Assert-Match $changelog '(?m)^## \[0\.1\.0\].*Event Contract' 'CHANGELOG event release'
}

Pass-Test '36 existing MRT harnesses remain green' {
    $null = & pwsh -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $v3HarnessPath 2>&1 | Out-String
    Assert-True ($LASTEXITCODE -eq 0) 'MRT v3 harness failed'
    $null = & pwsh -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $v4HarnessPath 2>&1 | Out-String
    Assert-True ($LASTEXITCODE -eq 0) 'MRT v4 harness failed'
}

Assert-True ($testCount -ge 36) "expected at least 36 tests, ran $testCount"
Write-Host "PASS: $testCount/$testCount MRT Event Contract tests"
Write-Host 'TradingView Pine v6 compilation, Bar Magnifier path ordering, and exact intrabar expiry remain manual release checks.'
