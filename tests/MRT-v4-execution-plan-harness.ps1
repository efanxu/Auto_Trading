$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $repoRoot 'MRT_V4.pine'
$v3Path = Join-Path $repoRoot 'MRT.pine'
$v3HarnessPath = Join-Path $PSScriptRoot 'MRT-v3.3.2-v2-logic-parity-harness.ps1'
$changelogPath = Join-Path $repoRoot 'CHANGELOG.md'

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
    $Text.Substring($startIndex, $endIndex - $startIndex)
}

function Invoke-LongStopLimitPath {
    param([double]$Trigger, [double]$Limit, [double[]]$Prices)
    $activated = $false
    $filled = $false
    foreach ($price in $Prices) {
        if (-not $activated -and $price -ge $Trigger) { $activated = $true }
        if ($activated -and $price -le $Limit) { $filled = $true; break }
    }
    [pscustomobject]@{ Activated = $activated; Filled = $filled }
}

function Invoke-TradeManagement {
    param([int]$EntryBar, [int]$CurrentBar, [bool]$Confirmed, [bool]$StopHit, [bool]$TrimHit, [bool]$FinalHit)
    $canManage = $Confirmed -and $CurrentBar -gt $EntryBar
    if (-not $canManage) { return 'NONE' }
    if ($StopHit) { return 'STOP' }
    if ($TrimHit) { return 'TRIM' }
    if ($FinalHit) { return 'FINAL' }
    'NONE'
}

$source = [IO.File]::ReadAllText($scriptPath)
$v3Source = [IO.File]::ReadAllText($v3Path)
$changelog = [IO.File]::ReadAllText($changelogPath)
$testCount = 0

Write-Host 'MR-T v4.4.0 True Executable PREPLAN Entry harness'

Pass-Test 'Version, product role, and release notes are v4.4.0' {
    Assert-Match $source 'strategy\("MR-T Strategy v4\.4\.0"' 'strategy version'
    Assert-Match $source 'string SCRIPT_VERSION\s*=\s*"4\.4\.0"' 'script version'
    Assert-Match $source 'True Executable PREPLAN Entry' 'product role'
    Assert-Match $changelog '(?m)^## \[4\.4\.0\].*True Executable PREPLAN Entry' 'CHANGELOG entry'
}

Pass-Test 'Runtime configuration enables Bar Magnifier and deterministic fill recalculation' {
    Assert-Match $source 'process_orders_on_close\s*=\s*true' 'process_orders_on_close'
    Assert-Match $source 'calc_on_order_fills\s*=\s*true' 'calc_on_order_fills'
    Assert-Match $source 'calc_on_every_tick\s*=\s*false' 'calc_on_every_tick'
    Assert-Match $source 'use_bar_magnifier\s*=\s*true' 'Bar Magnifier'
    Assert-Match $source 'pyramiding\s*=\s*0' 'pyramiding'
}

Pass-Test 'Four-layer architecture includes a filled-trade state, not a result ledger' {
    foreach ($typeName in @('MRLogicState', 'MRExecutionAssistState', 'MRV4TradeState', 'MRBrokerState')) {
        Assert-Match $source "type $typeName" "missing $typeName"
    }
    Assert-Match $source 'var MRV4TradeState\s+trade\s*=\s*MRV4TradeState\.new\(\)' 'trade state instance'
    Assert-NotMatch $source 'MRV4ExecutionState|MRShadowExecutionState' 'retired state remains'
}

Pass-Test 'PREPLAN is generated only from confirmed source bar N for valid bar N+1' {
    Assert-Match $source 'bool allowBarCloseDecision\s*=\s*isNewLogicDecisionBar' 'confirmed decision gate'
    Assert-Match $source 'assist\.sourceBar\s*:=\s*bar_index[\s\S]*?assist\.validBar\s*:=\s*bar_index\s*\+\s*1' 'source/valid assignment'
    Assert-Match $source 'sourceMean\s*=\s*mean15[\s\S]*?sourceStd\s*=\s*safeStd[\s\S]*?sourceATR\s*=\s*safeATR' 'confirmed source stats'
}

Pass-Test 'Trigger, Limit, TP1, and TP2 use the frozen source statistics and tick rounding' {
    Assert-Match $source 'planEntryTrigger\s*=\s*f_roundToTick\(sourceMean\s*-\s*planDir\s*\*\s*planEntryZ\s*\*\s*sourceStd\)' 'trigger formula'
    Assert-Match $source 'planEntryLimit\s*=\s*f_roundToTick\(planEntryTrigger\s*\+\s*planDir\s*\*\s*entryStopLimitOffsetTicks\s*\*\s*syminfo\.mintick\)' 'limit formula'
    Assert-Match $source 'planTP1\s*=\s*f_roundToTick\(sourceMean\s*-\s*planDir\s*\*\s*planPartialZ\s*\*\s*sourceStd\)' 'TP1 formula'
    Assert-Match $source 'planTP2\s*=\s*f_roundToTick\(sourceMean\s*-\s*planDir\s*\*\s*planFinalZ\s*\*\s*sourceStd\)' 'TP2 formula'
}

Pass-Test 'The only formal Entries are Long and Short Stop-Limit orders' {
    $entryCalls = [regex]::Matches($source, 'strategy\.entry\([^\r\n]+') | ForEach-Object { $_.Value }
    Assert-True ($entryCalls.Count -eq 2) 'expected exactly two strategy.entry calls'
    Assert-True (@($entryCalls | Where-Object { $_ -match '"MR-L"' -and $_ -match 'strategy\.long' -and $_ -match 'stop\s*=' -and $_ -match 'limit\s*=' }).Count -eq 1) 'Long Stop-Limit Entry'
    Assert-True (@($entryCalls | Where-Object { $_ -match '"MR-S"' -and $_ -match 'strategy\.short' -and $_ -match 'stop\s*=' -and $_ -match 'limit\s*=' }).Count -eq 1) 'Short Stop-Limit Entry'
    Assert-NotMatch ($entryCalls -join "`n") 'strategy\.entry\([^\r\n]*close' 'confirmed-close market Entry remains'
}

Pass-Test 'Legacy V3 close signals are diagnostics and cannot submit an Entry' {
    Assert-Match $source 'bool legacyV3EntryDiagnostic\s*=\s*longEntrySignal\s+or\s+shortEntrySignal' 'legacy diagnostic'
    $formalSection = Get-Section $source '// Filled Trade confirmed-close management' '// A confirmed Logic full exit owns'
    Assert-NotMatch $formalSection 'longEntrySignal|shortEntrySignal|strategy\.entry' 'legacy signal drives formal Entry'
}

Pass-Test 'One-bar expiry cancels the exact stale direction before replacement planning' {
    $expiry = Get-Section $source '// Each pending Entry is valid for exactly validBar' '// Create Setup'
    Assert-Match $expiry 'assist\.validBar\s*==\s*bar_index' 'valid-bar expiry gate'
    Assert-Match $expiry 'strategy\.cancel\(expiredEntryId\)' 'exact order cancellation'
    Assert-Match $expiry 'ENTRY_EXPIRED_UNFILLED' 'expiry alert'
    Assert-Match $source 'planEventName\s*=\s*expiredPlanThisBar\s*\?\s*"PREPLAN_UPDATE"\s*:\s*"PREPLAN_CREATE"' 'rolling update'
}

Pass-Test 'Rolling direction flips cancel the old order and submit only the new setup direction' {
    $pending = [pscustomobject]@{ Active = $true; Dir = 1; ValidBar = 11 }
    $bar = 11
    $newSetupDir = -1
    $cancelled = $pending.Active -and $pending.ValidBar -eq $bar
    if ($cancelled) { $pending.Active = $false }
    if (-not $pending.Active) { $pending.Dir = $newSetupDir; $pending.Active = $true }
    Assert-True ($cancelled -and $pending.Active -and $pending.Dir -eq -1) 'direction-flip model'
    Assert-Match $source 'if planDir == 1[\s\S]*?strategy\.entry\("MR-L"[\s\S]*?else[\s\S]*?strategy\.entry\("MR-S"' 'single-direction submit branch'
}

Pass-Test 'Formal fill is exact flat-to-position Broker transition' {
    Assert-Match $source 'positionEntered\s*=\s*positionSampleReady\s+and\s+previousExecutionPositionSize\s*==\s*0\.0\s+and\s+currentPositionSize\s*!=\s*0\.0' 'entry transition'
    Assert-Match $source 'entryFilled\s*=\s*positionEntered\s+and\s+broker\.entryIntentPending\s+and\s+assist\.active\s+and\s+assist\.validBar\s*==\s*bar_index' 'fill ownership'
    Assert-NotMatch (Get-Section $source '// A formal Entry exists only' 'if trimFilled') 'high\s*[><=]|low\s*[><=]' 'OHLC touch used as fill fact'
}

Pass-Test 'Actual Entry price is strategy.position_avg_price' {
    Assert-Match $source 'float actualEntryPrice\s*=\s*strategy\.position_avg_price' 'actual fill source'
    Assert-Match $source 'trade\.entryPrice\s*:=\s*actualEntryPrice' 'trade Entry price'
    Assert-Match $source 'broker\.brokerEntryPrice\s*:=\s*actualEntryPrice' 'broker Entry price'
    Assert-NotMatch $source 'trade\.entryPrice\s*:=\s*(close|assist\.entryLimit|assist\.entryTrigger)' 'synthetic Entry source'
}

Pass-Test 'Fill freezes the complete submitted PREPLAN snapshot and clears setup/pending state' {
    foreach ($field in @('sourceBar', 'validBar', 'sourceMean', 'sourceStd', 'sourceATR', 'sourceHalfLife', 'sourceRegimeScore', 'entryTrigger', 'entryLimit')) {
        Assert-Match $source "trade\.$field\s*:=\s*assist\.$field" "missing frozen $field"
    }
    Assert-Match $source 'logic\.setupBar\s*:=\s*na[\s\S]*?logic\.setupDir\s*:=\s*0[\s\S]*?logic\.setupMode\s*:=\s*0' 'setup clear'
    Assert-Match $source 'alert\(f_entryFilledMessage\(trade\)[\s\S]*?assist\.reset\(\)' 'pending clear after fill alert'
}

Pass-Test 'TP1 and TP2 are recomputed only from frozen source statistics' {
    Assert-Match $source 'trade\.partialTarget\s*:=\s*f_roundToTick\(assist\.sourceMean\s*-\s*filledDir\s*\*\s*partialZ\s*\*\s*assist\.sourceStd\)' 'filled TP1'
    Assert-Match $source 'trade\.finalTarget\s*:=\s*f_roundToTick\(assist\.sourceMean\s*-\s*filledDir\s*\*\s*finalZ\s*\*\s*assist\.sourceStd\)' 'filled TP2'
}

Pass-Test 'Initial Stop uses actual fill plus frozen ATR/statistics' {
    Assert-Match $source 'actualATRStop\s*=\s*actualEntryPrice\s*-\s*filledDir\s*\*\s*hardStopATR\s*\*\s*assist\.sourceATR' 'actual-fill ATR Stop'
    Assert-Match $source 'frozenStatStop\s*=\s*assist\.sourceMean\s*-\s*filledDir\s*\*\s*stopZ\s*\*\s*assist\.sourceStd' 'frozen Stat Stop'
    Assert-Match $source 'trade\.initialStop\s*:=\s*actualInitialStop' 'frozen initial Stop'
}

Pass-Test 'Break-even protection is anchored to actual trade.entryPrice' {
    $stopFunction = Get-Section $source 'f_logicActiveStop' '// Confirmed-close Trade Exit'
    Assert-Match $stopFunction 'trade\.entryPrice\s*\+\s*logic\.cost' 'Long BE anchor'
    Assert-Match $stopFunction 'trade\.entryPrice\s*-\s*logic\.cost' 'Short BE anchor'
    Assert-NotMatch $stopFunction 'logic\.entryPrice' 'legacy Entry price in BE'
}

Pass-Test 'Entry bar cannot create Stop, Trim, Final, Trend, or Timeout management' {
    Assert-Match $source 'canManage\s*=\s*trade\.active\s+and\s+trade\.dir\s*==\s*dir\s+and\s+bar_index\s*>\s*trade\.entryBar\s+and\s+barstate\.isconfirmed' 'Entry-bar guard'
    foreach ($outcome in @('STOP', 'TRIM', 'FINAL')) {
        Assert-True ((Invoke-TradeManagement 101 101 $true $true $true $true) -eq 'NONE') "Entry-bar $outcome guard model"
    }
    Assert-True ((Invoke-TradeManagement 101 102 $true $true $true $true) -eq 'STOP') 'next-bar priority model'
}

Pass-Test 'Confirmed-close exit priority remains Stop/BE, Trend, Timeout, Trim, Final' {
    $manage = Get-Section $source 'f_logicManage' '// Filled Trade confirmed-close management'
    $positions = @('if stopHit', 'else if trendFailed', 'else if timeFailed', 'else if partialReached', 'else if finalReached') | ForEach-Object { $manage.IndexOf($_) }
    Assert-True (@($positions | Where-Object { $_ -lt 0 }).Count -eq 0) 'missing management branch'
    Assert-True ($positions[0] -lt $positions[1] -and $positions[1] -lt $positions[2] -and $positions[2] -lt $positions[3] -and $positions[3] -lt $positions[4]) 'management priority'
    Assert-Match $manage 'close\s*<=\s*activeStop|close\s*>=\s*activeStop' 'confirmed-close Stop'
}

Pass-Test 'Trim and full exits use strategy.close with strict intent handoff' {
    Assert-Match $source 'strategy\.close\(trimEntryId[^\r\n]*qty_percent\s*=\s*trimPct' 'Trim order'
    Assert-Match $source 'strategy\.close\(closeEntryId' 'full exit order'
    Assert-Match $source 'broker\.fullExitIntentPending\s*:=\s*true' 'full-exit intent'
}

Pass-Test 'Residual cleanup, recovery, and exact-flat semantics remain present' {
    Assert-Match $source 'currentPositionSize\s*==\s*0\.0' 'exact flat'
    Assert-Match $source 'MR-T V4 Residual Cleanup' 'residual cleanup'
    Assert-Match $source 'MR-T Broker Recovery' 'broker recovery'
    Assert-Match $source 'strategy\.close_all\(' 'recovery close'
    Assert-NotMatch $source 'epsilon|epsFlat|math\.abs\(currentPositionSize\)\s*<\s*0\.' 'epsilon flat'
}

Pass-Test 'Triggered-but-unconfirmed V3 diagnostic cannot undo a real fill' {
    $model = [pscustomobject]@{ BrokerFilled = $true; LegacyV3Confirmed = $false; TradeActive = $false }
    if ($model.BrokerFilled) { $model.TradeActive = $true }
    if (-not $model.LegacyV3Confirmed) { $null = 'diagnostic only' }
    Assert-True $model.TradeActive 'real fill was incorrectly revoked'
    Assert-NotMatch $source 'PREPLAN_TRIGGERED_UNCONFIRMED|CONFIRMATION_FAILED' 'legacy confirmation controls fill'
}

Pass-Test 'A gap beyond the Limit may activate without filling' {
    $gap = Invoke-LongStopLimitPath 79000.0 79000.0 @(79200.0, 79300.0, 79150.0)
    Assert-True ($gap.Activated -and -not $gap.Filled) 'gap-unfilled model'
    $return = Invoke-LongStopLimitPath 79000.0 79000.0 @(78980.0, 79020.0, 78995.0)
    Assert-True ($return.Activated -and $return.Filled) 'activate-then-return model'
    Assert-Match $source 'Stop activation without a Limit fill remains flat' 'gap behavior comment'
}

Pass-Test 'Alerts cover create, update, cancel, submit, fill, and unfilled expiry' {
    foreach ($eventName in @('PREPLAN_CREATE', 'PREPLAN_UPDATE', 'PREPLAN_CANCEL', 'ENTRY_ORDER_SUBMITTED', 'ENTRY_FILLED', 'ENTRY_EXPIRED_UNFILLED')) {
        Assert-Match $source $eventName "missing $eventName"
    }
    foreach ($field in @('source_bar=', 'valid_bar=', 'trigger=', 'limit=', 'fill_bar=', 'fill_price=', 'fill_vs_limit_ticks=')) {
        Assert-Match $source ([regex]::Escape($field)) "missing alert field $field"
    }
}

Pass-Test 'Strategy Tester is the only V4 performance source' {
    foreach ($metric in @('strategy.netprofit', 'strategy.grossprofit', 'strategy.grossloss', 'strategy.closedtrades', 'strategy.wintrades', 'strategy.max_drawdown')) {
        Assert-Match $source ([regex]::Escape($metric)) "missing Tester metric $metric"
    }
    foreach ($retired in @('v4EquityIndex', 'f_v4TradeReturn', 'v4GrossProfit', 'v4GrossLoss', 'v4Trades', 'v4Wins', 'V4_RESULT')) {
        Assert-NotMatch $source ([regex]::Escape($retired)) "independent ledger remains: $retired"
    }
}

Pass-Test 'Panel remains 2x21 and exposes the v4.4 operational layout' {
    Assert-Match $source 'table\.new\(position\.top_right,\s*2,\s*21' 'Panel dimensions'
    $rows = [regex]::Matches($source, 'table\.cell\(panel,\s*[01],\s*(\d+)') | ForEach-Object { [int]$_.Groups[1].Value } | Sort-Object -Unique
    Assert-True ($rows.Count -eq 21 -and $rows[0] -eq 0 -and $rows[-1] -eq 20) 'Panel rows 0-20'
    foreach ($label in @('Pending Trigger / Limit', 'Actual Entry Price', 'Active Stop', 'Last Exit', 'Net Profit / Net %', 'Max Drawdown', 'V4 Profit Factor', 'Trades / Win Rate', 'Broker / Consistency', 'Range / Shock Stats')) {
        Assert-Match $source ([regex]::Escape($label)) "missing Panel label $label"
    }
}

Pass-Test 'Panel states distinguish flat, pending directions, trade phases, exit, and recovery' {
    foreach ($stateName in @('FLAT', 'PREPLAN_PENDING_LONG', 'PREPLAN_PENDING_SHORT', 'POSITION_PRE_TP1', 'POSITION_POST_TP1', 'FULL_EXIT_PENDING', 'RECOVERY')) {
        Assert-Match $source $stateName "missing state $stateName"
    }
}

Pass-Test 'Data Window exposes pending prices and actual Broker fill provenance' {
    foreach ($field in @('Pending Entry Trigger', 'Pending Entry Limit', 'Actual Entry Price', 'Entry Fill Bar')) {
        Assert-Match $source ([regex]::Escape($field)) "missing Data Window field $field"
    }
    Assert-Match $source 'actualEntryPriceWindow\s*=\s*trade\.active\s*\?\s*strategy\.position_avg_price' 'actual Entry display source'
}

Pass-Test 'Entry labels are emitted only by the Broker fill event' {
    Assert-Match $source 'entryEvent\s*:=\s*entryFilled' 'Entry label fill gate'
    Assert-Match $source 'if entryEvent and entryEventDir == 1[\s\S]*?"T\u4e70"' 'Long fill label'
    Assert-Match $source 'if entryEvent and entryEventDir == -1[\s\S]*?"T\u7a7a"' 'Short fill label'
}

Pass-Test 'Timeout starts at actual fill bar' {
    Assert-Match $source 'trade\.entryBar\s*:=\s*bar_index' 'actual fill bar'
    Assert-Match $source 'trade\.timeStopBar\s*:=\s*bar_index\s*\+\s*int\(math\.round\(limitedTimeStop\)\)' 'fill-relative timeout'
    Assert-Match $source 'bar_index\s*>=\s*trade\.timeStopBar' 'timeout decision'
}

Pass-Test '1008-like trade uses 79000 actual Entry and the Tester owns the return' {
    $entry = 79000.0
    $exit = 78626.0
    $commission = 0.0003
    $returnPct = (($exit - $entry) / $entry - $commission - $commission * $exit / $entry) * 100.0
    Assert-Near $returnPct -0.5332756962025317 '1008-like return percent'
    Assert-Match $source 'trade\.entryPrice\s*:=\s*actualEntryPrice' '1008 actual Entry source'
    Assert-NotMatch $source '79330\.75' 'confirmed-close fixture leaked into production'
}

Pass-Test 'V4 harness no longer asserts V3 Entry-bar or trade-count parity' {
    Assert-NotMatch $source 'V4 Entry bars == V3 Entry bars|V4 trade count == V3 trade count' 'production parity target'
    Assert-Match $source 'legacyV3EntryDiagnostic' 'V3 signal retained only as a diagnostic'
}

Pass-Test 'MRT.pine remains byte-for-byte unchanged and its V3 harness stays green' {
    $v3Sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $v3Path).Hash
    Assert-True ($v3Sha256 -eq 'E9B42666A9150E34504794CC8311936209ECA74D9D049A0AC16C540104A3D1AF') 'MRT.pine SHA changed'
    $null = & git -C $repoRoot diff --quiet -- MRT.pine
    Assert-True ($LASTEXITCODE -eq 0) 'MRT.pine has working-tree changes'
    $null = & pwsh -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $v3HarnessPath 2>&1 | Out-String
    Assert-True ($LASTEXITCODE -eq 0) 'V3 parity harness failed'
}

Pass-Test 'Historical fill limitation and live exchange-fill requirement are documented' {
    Assert-Match $source 'Historical Broker Emulator fills, even with Bar Magnifier, are not proof' 'historical limitation'
    Assert-Match $source "exchange's actual fill" 'live fill authority'
    Assert-Match $changelog 'Bar Magnifier.*not.*exchange.*tick fill|not exchange tick-fill proof' 'CHANGELOG limitation'
}

Assert-True ($testCount -ge 30) "expected at least 30 tests, ran $testCount"
Write-Host "PASS: $testCount/$testCount V4.4.0 executable PREPLAN tests"
Write-Host 'TradingView Pine v6 compile, Bar Magnifier runtime, and Trade List checks remain manual release checks.'
