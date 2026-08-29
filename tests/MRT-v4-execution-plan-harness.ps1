$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $repoRoot 'MRT_V4.pine'
$v3Path = Join-Path $repoRoot 'MRT.pine'
$v3HarnessPath = Join-Path $PSScriptRoot 'MRT-v3.3.2-v2-logic-parity-harness.ps1'
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
    param([double]$Actual, [double]$Expected, [string]$Message, [double]$Tolerance = 0.000001)

    Assert-True ([math]::Abs($Actual - $Expected) -le $Tolerance) "$Message (expected=$Expected, actual=$Actual)"
}

function Pass-Test {
    param([string]$Name, [scriptblock]$Body)

    & $Body
    $script:testCount += 1
    Write-Host "PASS [$($script:testCount.ToString('00'))] $Name"
}

function Get-Section {
    param([string]$Text, [string]$Start, [string]$End)

    $startIndex = $Text.IndexOf($Start)
    $endIndex = $Text.IndexOf($End, $startIndex + $Start.Length)
    Assert-True ($startIndex -ge 0 -and $endIndex -gt $startIndex) "section not found: $Start"
    return $Text.Substring($startIndex, $endIndex - $startIndex)
}

function Get-FunctionBody {
    param([string]$Text, [string]$Name)

    $escapedName = [regex]::Escape($Name)
    $match = [regex]::Match($Text, "(?ms)^$escapedName\([^\r\n]*\)[ \t]*=>[ \t]*\r?\n(?<body>.*?)(?=^[^ \t\r\n]|\z)")
    Assert-True $match.Success "function $Name not found"
    return $match.Groups['body'].Value
}

function Round-ToTick {
    param([double]$Value, [double]$Tick = 0.25)

    return [math]::Round($Value / $Tick, 0, [MidpointRounding]::AwayFromZero) * $Tick
}

function Get-V4EntrySelection {
    param(
        [int]$OfficialDir,
        [int]$OfficialMode,
        [double]$LogicEntry,
        [bool]$PreplanForCurrentBar,
        [int]$PreplanDir,
        [int]$PreplanMode,
        [bool]$TriggerTouched,
        [double]$PreplanLimit = [double]::NaN
    )

    $hasLimit = -not [double]::IsNaN($PreplanLimit)
    $fromPreplan = $PreplanForCurrentBar -and
        $PreplanDir -eq $OfficialDir -and
        $PreplanMode -eq $OfficialMode -and
        $TriggerTouched -and
        $hasLimit
    $v4EntryPrice = if ($fromPreplan) { $PreplanLimit } else { $LogicEntry }
    $improvement = if ($OfficialDir -eq 1) {
        ($LogicEntry - $v4EntryPrice) / $LogicEntry * 100.0
    }
    else {
        ($v4EntryPrice - $LogicEntry) / $LogicEntry * 100.0
    }

    [pscustomobject]@{
        FromPreplan = $fromPreplan
        V4EntryPrice = $v4EntryPrice
        ImprovementPct = $improvement
    }
}

function Get-V4TradeReturn {
    param(
        [int]$Dir,
        [double]$Entry,
        [bool]$DidTrim,
        [double]$TrimPrice,
        [double]$TrimFraction,
        [double]$Exit,
        [double]$CommissionBps = 3.0
    )

    $c = $CommissionBps / 10000.0
    if ($DidTrim) {
        $remainder = 1.0 - $TrimFraction
        $grossTrim = $TrimFraction * $Dir * ($TrimPrice - $Entry) / $Entry
        $grossRemainder = $remainder * $Dir * ($Exit - $Entry) / $Entry
        $entryFee = $c
        $trimExitFee = $TrimFraction * $c * $TrimPrice / $Entry
        $finalExitFee = $remainder * $c * $Exit / $Entry
        return $grossTrim + $grossRemainder - $entryFee - $trimExitFee - $finalExitFee
    }

    $gross = $Dir * ($Exit - $Entry) / $Entry
    $entryFee = $c
    $exitFee = $c * $Exit / $Entry
    return $gross - $entryFee - $exitFee
}

function New-V4Ledger {
    [pscustomobject]@{
        V4EquityIndex = 1.0
        V4GrossProfit = 0.0
        V4GrossLoss = 0.0
        V4Trades = 0
        V4Wins = 0
        ConfirmedEntries = 0
        V4PreplanEntries = 0
    }
}

function Add-V4LedgerTrade {
    param($Ledger, [double]$TradeReturn)

    $tradePnLIndex = $Ledger.V4EquityIndex * $TradeReturn
    if ($tradePnLIndex -gt 0.0) {
        [void]($Ledger.V4GrossProfit += $tradePnLIndex)
    }
    elseif ($tradePnLIndex -lt 0.0) {
        [void]($Ledger.V4GrossLoss += [math]::Abs($tradePnLIndex))
    }

    [void]($Ledger.V4EquityIndex *= 1.0 + $TradeReturn)
    [void]($Ledger.V4Trades += 1)
    if ($TradeReturn -gt 0.0) {
        [void]($Ledger.V4Wins += 1)
    }

    return $tradePnLIndex
}

function Get-LogicTimeline {
    param([object[]]$Bars, [bool]$AssistTouched)

    $state = [pscustomobject]@{
        Position = 0
        PartialTaken = $false
        Events = [System.Collections.Generic.List[string]]::new()
    }

    foreach ($bar in $Bars) {
        # A PREPLAN touch is an execution fact and must not create a Logic event.
        $ignoredAssistFact = $AssistTouched -and $bar.TriggerTouched

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

function Get-PlotLines {
    param([string]$Text)

    return @($Text -split '\r?\n' | Where-Object {
        $_ -match '^[ \t]*(?:[A-Za-z_][A-Za-z0-9_]*\s*=\s*)?plot\('
    })
}

function Get-OrderLines {
    param([string]$Text)

    return @($Text -split '\r?\n' | Where-Object {
        $_ -match 'strategy\.(entry|close|close_all|cancel_all)\('
    })
}

$source = [IO.File]::ReadAllText($scriptPath)
$v3Source = [IO.File]::ReadAllText($v3Path)
$baselineSource = (& git -C $repoRoot show 'HEAD:MRT_V4.pine' | Out-String)
$changelog = [IO.File]::ReadAllText($changelogPath)
$testCount = 0

Write-Host 'MR-T v4.3.0 standalone V4 Execution Accounting harness'
Assert-True (Test-Path -LiteralPath $scriptPath) 'MRT_V4.pine must exist'

Pass-Test 'Version and product role are v4.3.0' {
    Assert-Match $source 'strategy\("MR-T Strategy v4\.3\.0"' 'strategy version'
    Assert-Match $source 'string SCRIPT_VERSION\s*=\s*"4\.3\.0"' 'script version'
    Assert-Match $source 'V3 Logic Clock \+ Previous-Bar PREPLAN \+ V4 Execution Accounting' 'product role comment'
    Assert-Match $changelog '(?m)^## \[4\.3\.0\]' 'CHANGELOG v4.3.0 entry'
}

Pass-Test 'Final architecture has Logic, Assist, Broker, and V4 execution states' {
    Assert-Match $source 'type MRLogicState' 'Logic state missing'
    Assert-Match $source 'type MRExecutionAssistState' 'Execution Assist state missing'
    Assert-Match $source 'type MRBrokerState' 'Broker state missing'
    Assert-Match $source 'type MRV4ExecutionState' 'V4 execution state missing'
    Assert-Match $source 'MRLogicState[\s\S]*?MRExecutionAssistState[\s\S]*?MRBrokerState[\s\S]*?MRV4ExecutionState' 'state order changed'
    Assert-Match $source 'var MRV4ExecutionState\s+v4Exec\s*=\s*MRV4ExecutionState\.new\(\)' 'V4 state instance'
    Assert-NotMatch $source 'MRShadowExecutionState|\bshadow\b|\bShadow\b' 'retired execution naming remains'
}

Pass-Test 'Logic state retains the confirmed-close event clock without V3 P&L accounting' {
    Assert-Match $source 'bool isNewLogicDecisionBar\s*=\s*barstate\.isconfirmed' 'confirmed Logic clock'
    Assert-Match $source 'bool allowBarCloseDecision\s*=\s*isNewLogicDecisionBar' 'Logic decision gate'
    Assert-Match $source 'logic\.logicEventBar\s*:=\s*bar_index[\s\S]*?logic\.logicEventKind\s*:=\s*1' 'entry event snapshot'
    Assert-Match $source 'logic\.logicEventBar\s*:=\s*bar_index[\s\S]*?logic\.logicEventKind\s*:=\s*3' 'exit event snapshot'
    Assert-NotMatch (Get-FunctionBody $source 'f_logicExit') 'lastPnlATR|lastPnlPct|sumPnlATR|tradeCount' 'Logic computes a trade ledger'
}

Pass-Test 'PREPLAN remains previous-bar, one-bar-valid, and non-ordering' {
    Assert-Match $source 'assist\.sourceBar\s*:=\s*bar_index[\s\S]*?assist\.validBar\s*:=\s*bar_index\s*\+\s*1' 'source/valid bars'
    Assert-Match $source 'preplanForCurrentBar\s*=\s*allowBarCloseDecision\s+and\s+assist\.active\s+and\s+assist\.validBar\s*==\s*bar_index' 'PREPLAN validity gate'
    Assert-Match $source 'previousPreplanTriggerTouched\s*=\s*preplanForCurrentBar\s+and\s+\(assist\.dir\s*==\s*1\s*\?\s*high\s*>=\s*assist\.entryTrigger\s*:\s*low\s*<=\s*assist\.entryTrigger\)' 'touch direction'
    $preplanSection = Get-Section $source '// A new plan is generated only after this bar is confirmed' '// Commit Broker observations only'
    Assert-NotMatch $preplanSection 'strategy\.(entry|order|close|close_all)\(' 'PREPLAN submits an order'
    Assert-NotMatch $preplanSection 'strategy\.position_size\s*:=' 'PREPLAN mutates Broker position'
}

Pass-Test 'PREPLAN numeric prices remain tick-rounded and source-bar based' {
    Assert-Match $source 'planEntryTrigger\s*=\s*f_roundToTick\(sourceMean\s*-\s*planDir\s*\*\s*planEntryZ\s*\*\s*sourceStd\)' 'trigger formula'
    Assert-Match $source 'planEntryLimit\s*=\s*f_roundToTick\(planEntryTrigger\s*\+\s*planDir\s*\*\s*entryStopLimitOffsetTicks\s*\*\s*syminfo\.mintick\)' 'limit formula'
    Assert-Match $source 'planTP1\s*=\s*f_roundToTick\(sourceMean\s*-\s*planDir\s*\*\s*planPartialZ\s*\*\s*sourceStd\)[\s\S]*?planTP2\s*=\s*f_roundToTick' 'target formulas'
    Assert-Match $source 'planStop\s*=\s*f_roundToTick' 'stop rounding'
    Assert-Match $source 'str\.tostring\(value,\s*format\.mintick\)' 'mintick formatting'
    Assert-Near (Round-ToTick 83.5) 83.5 'tick model'
    Assert-Near (Round-ToTick 83.62) 83.5 'tick model half-down'
}

Pass-Test 'V4 entry selection uses a valid touched matching PREPLAN Limit' {
    $selection = Get-V4EntrySelection 1 1 79330.75 $true 1 1 $true 79000.0
    Assert-True $selection.FromPreplan 'valid PREPLAN was not selected'
    Assert-Near $selection.V4EntryPrice 79000.0 'V4 Entry did not use PREPLAN Limit'
    Assert-True ($selection.ImprovementPct -gt 0.0) 'Long lower Limit should improve entry'
    Assert-Match $source 'float v4EntryPrice\s*=\s*fromPreplan\s*\?\s*planLimit\s*:\s*logicPrice' 'V4 entry price rule'
    Assert-Match $source 'v4Exec\.enter\(officialEntryDir,\s*officialEntryMode,\s*logic\.entryPrice,\s*v4EntryFromPreplan' 'V4 entry handoff'
}

Pass-Test 'No touch falls back to confirmed Logic close' {
    $selection = Get-V4EntrySelection 1 1 79330.75 $true 1 1 $false 79000.0
    Assert-True (-not $selection.FromPreplan) 'untouched PREPLAN was selected'
    Assert-Near $selection.V4EntryPrice 79330.75 'no-touch fallback price'
    Assert-Match $source 'v4EntryFromPreplan\s*=\s*officialEntryDecision[\s\S]*?previousPreplanTriggerTouched[\s\S]*?not na\(previousPreplanLimit\)' 'fallback gate'
}

Pass-Test 'Wrong direction, wrong mode, and absent PREPLAN fall back' {
    $wrongDirection = Get-V4EntrySelection 1 1 100.0 $true -1 1 $true 90.0
    $wrongMode = Get-V4EntrySelection 1 1 100.0 $true 1 2 $true 90.0
    $absent = Get-V4EntrySelection 1 1 100.0 $false 0 0 $false
    foreach ($case in @($wrongDirection, $wrongMode, $absent)) {
        Assert-True (-not $case.FromPreplan) 'invalid PREPLAN selected'
        Assert-Near $case.V4EntryPrice 100.0 'invalid PREPLAN fallback'
    }
}

Pass-Test 'Touched but unconfirmed PREPLAN creates no V4 trade' {
    $touchSection = Get-Section $source '// A PREPLAN touch is an execution-assist fact' '// A new plan is generated only after this bar is confirmed'
    Assert-Match $touchSection 'not officialEntryDecision\s+and\s+previousPreplanTriggerTouched' 'unconfirmed touch gate'
    Assert-NotMatch $touchSection 'v4Exec\.(enter|closeTrade)\(' 'unconfirmed touch created V4 trade'
    Assert-Match $touchSection 'PREPLAN_TRIGGERED_UNCONFIRMED' 'unconfirmed alert'
}

Pass-Test 'V4 entry bar remains the Logic Entry bar' {
    Assert-Match $source 'logic\.entryPrice\s*:=\s*close[\s\S]*?logic\.entryBar\s*:=\s*bar_index' 'Logic Entry bar'
    Assert-Match $source 'this\.entryBar\s*:=\s*bar_index[\s\S]*?this\.entryPrice\s*:=\s*v4EntryPrice' 'V4 Entry bar'
    Assert-Match $source 'v4Exec\.enter\([\s\S]*?v4EntryFromPreplan' 'same-bar V4 entry'
}

Pass-Test 'V4 Trim and every full exit use the Logic event bar and close' {
    $decisionSection = Get-Section $source '// Official Logic Decision' '// Retry cleanup after a formal full-exit command'
    Assert-Match $decisionSection 'logic\.logicEventKind\s*==\s*2[\s\S]*?v4Exec\.recordTrim\(bar_index,\s*close,\s*trimPct\s*/\s*100\.0\)' 'Trim mapping'
    Assert-Match $decisionSection 'logic\.logicEventKind\s*==\s*3[\s\S]*?v4Exec\.closeTrade\(bar_index,\s*close,\s*logic\.logicEventReason\)' 'Full exit mapping'
    Assert-Match $source 'this\.trimBar\s*:=\s*decisionBar[\s\S]*?this\.trimPrice\s*:=\s*decisionPrice' 'Trim provenance'
    Assert-Match $source 'this\.lastExitBar\s*:=\s*decisionBar[\s\S]*?this\.lastExitPrice\s*:=\s*decisionPrice' 'Exit provenance'
}

Pass-Test 'V4 no-Trim return formula is correct' {
    $actual = Get-V4TradeReturn 1 100.0 $false 0.0 0.0 110.0
    $expected = (110.0 - 100.0) / 100.0 - 0.0003 - 0.0003 * 110.0 / 100.0
    Assert-Near $actual $expected 'no-Trim return'
    $v4Section = Get-Section $source '// V4 Execution Accounting' '// Broker transition detection'
    Assert-Match $v4Section 'float c\s*=\s*commissionBps\s*/\s*10000\.0' 'commission normalization'
    Assert-Match $v4Section 'float grossReturn\s*=\s*dir\s*\*\s*\(exitPrice\s*-\s*entryPrice\)\s*/\s*entryPrice' 'no-Trim gross'
    Assert-Match $v4Section 'grossReturn\s*-\s*entryFee\s*-\s*exitFee' 'no-Trim net'
}

Pass-Test 'V4 Trim return formula uses one Entry and two confirmed-close exit legs' {
    $actual = Get-V4TradeReturn 1 100.0 $true 105.0 0.5 110.0
    $expected = 0.5 * (105.0 - 100.0) / 100.0 + 0.5 * (110.0 - 100.0) / 100.0 - 0.0003 - 0.5 * 0.0003 * 105.0 / 100.0 - 0.5 * 0.0003 * 110.0 / 100.0
    Assert-Near $actual $expected 'Trim return'
    $v4Section = Get-Section $source '// V4 Execution Accounting' '// Broker transition detection'
    Assert-Match $v4Section 'float remainderFraction\s*=\s*1\.0\s*-\s*trimFraction' 'remainder fraction'
    Assert-Match $v4Section 'float grossTrim\s*=\s*trimFraction\s*\*\s*dir\s*\*\s*\(trimPrice\s*-\s*entryPrice\)\s*/\s*entryPrice' 'Trim gross'
    Assert-Match $v4Section 'float grossRemainder\s*=\s*remainderFraction\s*\*\s*dir\s*\*\s*\(exitPrice\s*-\s*entryPrice\)' 'remainder gross'
}

Pass-Test 'V4 commission charges Entry, Trim, and final exit legs' {
    $noTrimBeforeFees = Get-V4TradeReturn 1 100.0 $false 0.0 0.0 110.0 0.0
    $noTrimAfterFees = Get-V4TradeReturn 1 100.0 $false 0.0 0.0 110.0 3.0
    Assert-Near ($noTrimBeforeFees - $noTrimAfterFees) (0.0003 + 0.0003 * 110.0 / 100.0) 'Entry/final commission'
    $trimBeforeFees = Get-V4TradeReturn 1 100.0 $true 105.0 0.5 110.0 0.0
    $trimAfterFees = Get-V4TradeReturn 1 100.0 $true 105.0 0.5 110.0 3.0
    Assert-Near ($trimBeforeFees - $trimAfterFees) (0.0003 + 0.5 * 0.0003 * 105.0 / 100.0 + 0.5 * 0.0003 * 110.0 / 100.0) 'Entry/Trim/final commission'
    Assert-Match $source 'trimExitFee\s*=\s*trimFraction\s*\*\s*c\s*\*\s*trimPrice\s*/\s*entryPrice' 'Trim commission'
}

Pass-Test 'V4 equity index compounds from 1.0 and uses trade PnL index for PF' {
    $ledger = New-V4Ledger
    $firstPnL = Add-V4LedgerTrade $ledger 0.10
    $secondPnL = Add-V4LedgerTrade $ledger -0.05
    $thirdPnL = Add-V4LedgerTrade $ledger 0.20
    Assert-Near $ledger.V4EquityIndex 1.254 'V4 compounded equity'
    Assert-Near (($ledger.V4EquityIndex - 1.0) * 100.0) 25.4 'V4 Net percent'
    Assert-Near $firstPnL 0.10 'first trade PnL index'
    Assert-Near $secondPnL -0.055 'second trade PnL index'
    Assert-Near $thirdPnL 0.209 'third trade PnL index'
    Assert-Match $source 'varip float\s+v4EquityIndex\s*=\s*1\.0' 'V4 equity seed'
    Assert-Match $source 'float tradePnLIndex\s*=\s*v4EquityBeforeTrade\s*\*\s*v4TradeReturn' 'V4 PF basis'
    Assert-Match $source 'this\.v4EquityIndex\s*\*=\s*1\.0\s*\+\s*v4TradeReturn' 'V4 compounding'
}

Pass-Test 'V4 Profit Factor is gross winning PnL index over gross losing PnL index' {
    $ledger = New-V4Ledger
    [void](Add-V4LedgerTrade $ledger 0.10)
    [void](Add-V4LedgerTrade $ledger -0.05)
    [void](Add-V4LedgerTrade $ledger 0.20)
    $expectedPF = (0.10 + 0.209) / 0.055
    Assert-Near ($ledger.V4GrossProfit / $ledger.V4GrossLoss) $expectedPF
    $v4Section = Get-Section $source '// V4 Execution Accounting' '// Broker transition detection'
    Assert-Match $v4Section 'f_v4ProfitFactor\(MRV4ExecutionState this\)[\s\S]*?this\.v4GrossProfit\s*/\s*this\.v4GrossLoss' 'V4 PF formula'
    Assert-Match $v4Section 'if tradePnLIndex\s*>\s*0\.0[\s\S]*?this\.v4GrossProfit\s*\+=\s*tradePnLIndex[\s\S]*?else if tradePnLIndex\s*<\s*0\.0[\s\S]*?this\.v4GrossLoss\s*\+=\s*math\.abs\(tradePnLIndex\)' 'PF accumulators'
}

Pass-Test 'V4 Win Rate counts complete positive-return trades only' {
    $ledger = New-V4Ledger
    [void](Add-V4LedgerTrade $ledger 0.10)
    [void](Add-V4LedgerTrade $ledger -0.05)
    [void](Add-V4LedgerTrade $ledger 0.20)
    Assert-True ($ledger.V4Trades -eq 3 -and $ledger.V4Wins -eq 2) 'V4 trades/wins'
    Assert-Near ($ledger.V4Wins / $ledger.V4Trades * 100.0) (200.0 / 3.0) 'V4 win rate'
    Assert-Match $source 'f_v4WinRate\(MRV4ExecutionState this\)[\s\S]*?this\.v4Wins\s*/\s*this\.v4Trades\s*\*\s*100\.0' 'V4 win rate formula'
    Assert-Match $source 'if v4TradeReturn\s*>\s*0\.0[\s\S]*?this\.v4Wins\s*\+=\s*1' 'V4 win gate'
}

Pass-Test 'PREPLAN usage counts confirmed entries and only selected PREPLAN entries' {
    $ledger = New-V4Ledger
    foreach ($case in @(
        (Get-V4EntrySelection 1 1 100.0 $true 1 1 $true 90.0),
        (Get-V4EntrySelection 1 1 100.0 $true 1 1 $false 90.0),
        (Get-V4EntrySelection 1 1 100.0 $false 0 0 $false)
    )) {
        $ledger.ConfirmedEntries += 1
        if ($case.FromPreplan) { $ledger.V4PreplanEntries += 1 }
    }
    Assert-True ($ledger.ConfirmedEntries -eq 3 -and $ledger.V4PreplanEntries -eq 1) 'PREPLAN usage counters'
    Assert-Near ($ledger.V4PreplanEntries / $ledger.ConfirmedEntries * 100.0) (100.0 / 3.0) 'PREPLAN usage percent'
    Assert-Match $source 'this\.confirmedEntries\s*\+=\s*1[\s\S]*?if fromPreplan[\s\S]*?this\.v4PreplanEntries\s*\+=\s*1' 'PREPLAN usage accumulator'
    Assert-Match $source 'this\.confirmedEntries\s*>\s*0\s*\?\s*this\.v4PreplanEntries\s*/\s*this\.confirmedEntries\s*\*\s*100\.0' 'PREPLAN usage formula'
}

Pass-Test 'Reset clears active trade state but preserves all last-result fields' {
    $resetBlock = Get-Section $source 'method resetTrade' 'method enter'
    foreach ($field in @(
        'lastTradeNumber', 'lastEntryPrice', 'lastEntryFromPreplan', 'lastTrimPrice',
        'lastExitPrice', 'lastExitReason', 'lastTradeReturnPct', 'lastEntryBar',
        'lastExitBar', 'lastPreplanTrigger', 'lastPreplanLimit', 'lastResultEventBar'
    )) {
        Assert-NotMatch $resetBlock "this\.$field\s*:=" "resetTrade cleared $field"
    }
    Assert-Match $source 'this\.lastTradeNumber\s*:=\s*completedTradeNumber[\s\S]*?this\.lastResultEventBar\s*:=\s*decisionBar[\s\S]*?this\.resetTrade\(\)' 'snapshot before reset'
    Assert-Match $source 'this\.lastEntryPrice\s*:=\s*this\.entryPrice[\s\S]*?this\.lastEntryFromPreplan\s*:=\s*this\.entryFromPreplan' 'last entry snapshot'
}

Pass-Test 'V4 result event remains tied to the full Logic exit bar' {
    Assert-Match $source 'varip int v4ResultEventBar\s*=\s*na' 'result cursor'
    Assert-Match $source 'v4Exec\.closeTrade\(bar_index,\s*close,\s*logic\.logicEventReason\)[\s\S]*?v4ResultEventBar\s*:=\s*v4Exec\.lastResultEventBar' 'result cursor handoff'
    Assert-Match $source 'bool v4ResultEvent\s*=\s*v4ResultEventBar\s*==\s*bar_index' 'result label gate'
}

Pass-Test 'Data Window keeps only the required V4 result fields and removes four old export series' {
    $oldSeries = @(
        'V4 Shadow Trade Event', 'V4 Shadow Logic Entry',
        'V4 Shadow Executed Entry', 'V4 Shadow Trade Delta %'
    )
    foreach ($series in $oldSeries) {
        Assert-NotMatch $source ([regex]::Escape($series)) "old export remains: $series"
    }
    foreach ($field in @(
        'V4 Entry Price', 'V4 Entry From PREPLAN', 'V4 Entry Improvement %',
        'V4 Last Trade %', 'V4 Net %', 'V4 Profit Factor', 'V4 Win Rate',
        'V4 PREPLAN Usage %'
    )) {
        Assert-Match $source ([regex]::Escape($field)) "missing V4 Data Window field: $field"
    }
    $v4Plots = Get-PlotLines $source
    $v3Plots = Get-PlotLines $v3Source
    $v4VisiblePlots = @($v4Plots | Where-Object { $_ -notmatch 'display\s*=\s*display\.data_window' })
    $v3VisiblePlots = @($v3Plots | Where-Object { $_ -notmatch 'display\s*=\s*display\.data_window' })
    Assert-True ($v4Plots.Count -eq $v3Plots.Count + 8) 'V4 Data Window field count'
    Assert-True ([regex]::Matches($source, 'display\s*=\s*display\.data_window').Count -eq [regex]::Matches($v3Source, 'display\s*=\s*display\.data_window').Count + 8) 'V4 Data Window plot count'
    Assert-True ($v4VisiblePlots.Count -eq $v3VisiblePlots.Count) 'visible chart footprint changed'
}

Pass-Test 'Data Window and Panel use V4 Entry Price, never Broker average fill' {
    Assert-Match $source 'float displayedV4Entry\s*=\s*v4Exec\.active\s*\?\s*v4Exec\.entryPrice\s*:\s*v4Exec\.lastEntryPrice' 'V4 displayed entry'
    $panelSection = Get-Section $source '// Panel' '// Alerts'
    Assert-Match $panelSection 'string entryText\s*=\s*v4Exec\.active\s*\?\s*f_price\(v4Exec\.entryPrice\)\s*:\s*f_price\(v4Exec\.lastEntryPrice\)' 'Panel V4 entry'
    Assert-NotMatch $panelSection 'entryText[\s\S]*?logic\.entryPrice|entryText[\s\S]*?strategy\.position_avg_price' 'Panel uses a non-V4 entry source'
}

Pass-Test 'Panel remains exactly 21 rows with the standalone V4 layout' {
    Assert-Match $source 'var table panel\s*=\s*table\.new\(position\.top_right,\s*2,\s*21' 'Panel dimensions'
    $rows = [regex]::Matches($source, 'table\.cell\(panel,\s*[01],\s*(\d+)') | ForEach-Object { [int]$_.Groups[1].Value } | Sort-Object -Unique
    Assert-True ($rows.Count -eq 21 -and $rows[0] -eq 0 -and $rows[-1] -eq 20) 'Panel rows 0-20'
    foreach ($label in @('V4 Entry Price', 'PREPLAN Trigger / Limit', 'Recent Trade', 'Last Return %', 'V4 Net %', 'V4 Profit Factor', 'V4 Win Rate / PREPLAN Usage')) {
        Assert-Match $source ([regex]::Escape($label)) "missing Panel label: $label"
    }
    $panelSection = Get-Section $source '// Panel' '// Alerts'
    Assert-NotMatch $panelSection 'V3|Reference|Delta|Shadow' 'retired comparison appears in Panel'
}

Pass-Test 'Recent trade fields remain visible after reset' {
    foreach ($field in @('lastTradeNumber', 'lastEntryPrice', 'lastEntryFromPreplan', 'lastTrimPrice', 'lastExitPrice', 'lastExitReason', 'lastTradeReturnPct')) {
        Assert-Match $source "\b$field\b" "missing recent-result field: $field"
    }
    Assert-Match $source 'recentTradeText\s*=\s*v4Exec\.lastTradeNumber\s*>\s*0[\s\S]*?v4Exec\.lastDir[\s\S]*?v4Exec\.lastExitReason' 'recent trade text'
    Assert-Match $source 'recentReturnText\s*=\s*f_panelPct\(v4Exec\.lastTradeReturnPct' 'recent return text'
    Assert-NotMatch (Get-Section $source '// Panel' '// Alerts') 'Tester Net|Tester PF|V3|Reference|Delta' 'Panel exposes a non-V4 result'
}

Pass-Test 'Formal Logic labels remain the lifecycle labels' {
    foreach ($labelText in @('T买', 'T空', 'T减', 'T平', 'T止损', 'T保本', '趋势失效', 'T超时')) {
        Assert-Match $source ([regex]::Escape($labelText)) "formal label changed: $labelText"
    }
    Assert-Match $source 'string v4ResultText\s*=\s*na\(v4Exec\.lastTradeReturnPct\)[\s\S]*?"V4 "' 'V4 result label text'
    Assert-NotMatch $source 'V4\s*Δ|V4\s*Delta|Trade Delta' 'delta result label remains'
}

Pass-Test 'V4_RESULT alert has the required fields and no comparison fields' {
    $resultSection = Get-Section $source 'f_v4ResultMessage' '// Broker transition detection'
    foreach ($field in @(
        'event=V4_RESULT', 'trade_number=', 'direction=', 'mode=', 'entry_bar=',
        'entry_price=', 'entry_from_preplan=', 'preplan_trigger=', 'preplan_limit=',
        'trim_price=', 'exit_bar=', 'exit_price=', 'exit_reason=',
        'trade_return_pct=', 'v4_net_pct=', 'v4_pf=', 'v4_win_rate=',
        'preplan_usage_pct='
    )) {
        Assert-Match $resultSection ([regex]::Escape($field)) "missing V4_RESULT field: $field"
    }
    foreach ($field in @('logic_entry', 'reference_trade_pct', 'reference_net_pct', 'delta_trade_pct', 'reference_pf', 'SHADOW_RESULT', 'shadow_entry')) {
        Assert-NotMatch $resultSection ([regex]::Escape($field)) "forbidden V4_RESULT field remains: $field"
    }
    Assert-Match $source 'alert\(f_v4ResultMessage\(v4Exec\),\s*alert\.freq_all\)' 'V4_RESULT emission'
}

Pass-Test 'Strategy Tester Broker path remains official and separate from V4 accounting' {
    Assert-Match $source 'strategy\.entry\("MR-L",\s*strategy\.long' 'official Long order'
    Assert-Match $source 'strategy\.entry\("MR-S",\s*strategy\.short' 'official Short order'
    Assert-Match $source 'strategy\.close\(trimEntryId[\s\S]*?strategy\.close\(closeEntryId' 'official close path'
    Assert-NotMatch $source 'strategy\.(order|exit)\(' 'new order API path'
    $v4Section = Get-Section $source '// V4 Execution Accounting' '// Broker transition detection'
    Assert-NotMatch $v4Section 'strategy\.' 'V4 accounting submits or reads a Tester order'
    Assert-Match $v4Section 'Strategy Tester broker P&L is not the V4 execution-performance source of truth' 'source-of-truth comment'
    Assert-Match $v4Section 'V4 Execution Accounting is the source of truth' 'V4 source-of-truth comment'
}

Pass-Test 'Official Strategy Tester order lines are unchanged from the baseline' {
    $currentOrderLines = @(Get-OrderLines $source)
    $baselineOrderLines = @(Get-OrderLines $baselineSource)
    Assert-True (($currentOrderLines -join "`n") -eq ($baselineOrderLines -join "`n")) 'Strategy Tester order path changed'
}

Pass-Test 'Confirmed-close Logic timeline remains unchanged when PREPLAN is touched' {
    $bars = @(
        [pscustomobject]@{ Index = 21; Action = 'ENTRY_LONG'; TriggerTouched = $true },
        [pscustomobject]@{ Index = 22; Action = 'TRIM'; TriggerTouched = $true },
        [pscustomobject]@{ Index = 23; Action = 'FINAL'; TriggerTouched = $false },
        [pscustomobject]@{ Index = 25; Action = 'ENTRY_SHORT'; TriggerTouched = $true },
        [pscustomobject]@{ Index = 26; Action = 'STOP'; TriggerTouched = $true },
        [pscustomobject]@{ Index = 28; Action = 'ENTRY_LONG'; TriggerTouched = $false },
        [pscustomobject]@{ Index = 29; Action = 'TREND'; TriggerTouched = $true },
        [pscustomobject]@{ Index = 31; Action = 'ENTRY_SHORT'; TriggerTouched = $false },
        [pscustomobject]@{ Index = 32; Action = 'TIME'; TriggerTouched = $true }
    )
    $withoutAssist = Get-LogicTimeline $bars $false
    $withAssist = Get-LogicTimeline $bars $true
    Assert-True (($withoutAssist.Events -join '|') -eq ($withAssist.Events -join '|')) 'PREPLAN changed Logic timeline'
    Assert-True (($withAssist.Events -join '|') -eq '21:ENTRY_LONG|22:TRIM|23:FINAL|25:ENTRY_SHORT|26:STOP|28:ENTRY_LONG|29:TREND|31:ENTRY_SHORT|32:TIME') 'unexpected Logic timeline'
    Assert-Match $source 'f_logicManage\(int dir\)' 'Logic manager missing'
    Assert-Match $source 'logic\.logicEventBar\s*==\s*bar_index\s+and\s+logic\.logicEventKind\s*==\s*2' 'Logic Trim event source'
    Assert-Match $source 'logic\.logicEventBar\s*==\s*bar_index\s+and\s+logic\.logicEventKind\s*==\s*3' 'Logic Exit event source'
}

Pass-Test 'V3 Logic parity harness and MRT.pine byte baseline remain green' {
    Assert-True (Test-Path -LiteralPath $v3HarnessPath) 'V3 parity harness missing'
    $v3Sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $v3Path).Hash
    Assert-True ($v3Sha256 -eq 'E9B42666A9150E34504794CC8311936209ECA74D9D049A0AC16C540104A3D1AF') 'MRT.pine SHA changed'
    $null = & git -C $repoRoot diff --quiet -- MRT.pine
    Assert-True ($LASTEXITCODE -eq 0) 'MRT.pine has working-tree changes'
    $null = & pwsh -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $v3HarnessPath 2>&1 | Out-String
    Assert-True ($LASTEXITCODE -eq 0) 'V3 parity harness failed'
}

Pass-Test '1008-like valid PREPLAN result is a single V4 result' {
    $logicEntry = 79330.75
    $preplanLimit = 79000.0
    $exit = 78626.0
    $selection = Get-V4EntrySelection 1 1 $logicEntry $true 1 1 $true $preplanLimit
    $v4Return = Get-V4TradeReturn 1 $selection.V4EntryPrice $false 0.0 0.0 $exit
    $expected = (78626.0 - 79000.0) / 79000.0 - 0.0003 - 0.0003 * 78626.0 / 79000.0
    Assert-Near $selection.V4EntryPrice 79000.0 '1008-like V4 Entry'
    Assert-Near $v4Return $expected '1008-like V4 Return'
    Assert-Near ($v4Return * 100.0) -0.5332756962025317 '1008-like V4 Return percent' 0.000001
    Assert-Match $source 'entry_price=' 'V4 entry payload'
    Assert-Match $source 'trade_return_pct=' 'V4 trade payload'
    Assert-NotMatch $source 'reference_trade_pct|delta_trade_pct|V4\s*Δ' '1008 comparison output remains'
}

Pass-Test 'Fallback and adverse PREPLAN cases remain V4 trades, not optimized hindsight' {
    $fallback = Get-V4EntrySelection 1 1 79330.75 $false 0 0 $false
    $adverse = Get-V4EntrySelection 1 1 79000.0 $true 1 1 $true 79330.0
    Assert-Near $fallback.V4EntryPrice 79330.75 'fallback V4 Entry'
    Assert-True (-not $fallback.FromPreplan) 'fallback incorrectly marked PREPLAN'
    Assert-Near $adverse.V4EntryPrice 79330.0 'adverse Limit must be retained'
    Assert-True ($adverse.ImprovementPct -lt 0.0) 'adverse improvement was optimized away'
    Assert-Match $source 'this\.entryPrice\s*:=\s*v4EntryPrice' 'single V4 selected price'
    Assert-NotMatch (Get-Section $source '// V4 Execution Accounting' '// Broker transition detection') 'math\.(min|max)\([^\r\n]*(logicPrice|entryPrice|planLimit)' 'hindsight better-of-two price'
}

Pass-Test 'No V3 Reference accounting or V4 Delta accounting remains' {
    foreach ($token in @(
        'referenceEntryPrice', 'referenceEquityIndex', 'referenceGrossProfit',
        'referenceGrossLoss', 'lastReferenceReturnPct', 'f_referenceNetPct',
        'f_referenceProfitFactor', 'referenceTradeReturn', 'referenceTradePnLIndex',
        'lastDeltaPct', 'f_shadowVsReferencePct', 'SHADOW_RESULT',
        'V3 Reference Net', 'V4 vs V3 Delta', 'V4 Shadow Net',
        'V4 Shadow Last Trade', 'V4 Shadow Entry Price'
    )) {
        Assert-NotMatch $source ([regex]::Escape($token)) "retired accounting token remains: $token"
    }
}

Assert-True ($testCount -ge 30) "expected at least 30 tests, ran $testCount"
Write-Host "PASS: $testCount/$testCount V4.3.0 standalone execution-accounting tests"
Write-Host 'TradingView Pine v6 compile and Strategy Tester runtime checks remain manual release checks.'
