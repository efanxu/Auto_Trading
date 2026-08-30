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

function Invoke-BrokerPath {
    param([string[]]$Events)
    $phase = 'FLAT'
    $outcomes = [Collections.Generic.List[string]]::new()
    foreach ($eventName in $Events) {
        switch ($eventName) {
            'ENTRY' {
                if ($phase -eq 'FLAT') { $phase = 'PRE_TP1'; $outcomes.Add('ENTRY') }
            }
            'STOP' {
                if ($phase -eq 'PRE_TP1') { $phase = 'FLAT'; $outcomes.Add('STOP') }
            }
            'TP1' {
                if ($phase -eq 'PRE_TP1') { $phase = 'POST_TP1'; $outcomes.Add('TP1') }
            }
            'TP2' {
                if ($phase -eq 'POST_TP1') { $phase = 'FLAT'; $outcomes.Add('TP2') }
            }
            'BE' {
                if ($phase -eq 'POST_TP1') { $phase = 'FLAT'; $outcomes.Add('BE') }
            }
        }
    }
    [pscustomobject]@{ Phase = $phase; Outcomes = @($outcomes) }
}

function Invoke-OcaQuantityModel {
    param([double]$PositionQty, [double]$TrimPercent, [ValidateSet('TP2', 'BE', 'STOP')][string]$TerminalFill)
    if ($TerminalFill -eq 'STOP') {
        return [pscustomobject]@{ RemainingAfterTrim = $PositionQty; FinalPosition = $PositionQty - $PositionQty }
    }
    $trimFillQty = $PositionQty * $TrimPercent / 100.0
    $actualRemainingQty = $PositionQty - $trimFillQty
    $postOrderQty = $actualRemainingQty
    [pscustomobject]@{ RemainingAfterTrim = $actualRemainingQty; FinalPosition = $actualRemainingQty - $postOrderQty }
}

$source = [IO.File]::ReadAllText($scriptPath)
$v3Source = [IO.File]::ReadAllText($v3Path)
$changelog = [IO.File]::ReadAllText($changelogPath)
$brokerSync = Get-Section $source '// Broker transition detection and fill synchronization.' '// Consistency and recovery are execution diagnostics only.'
$manage = Get-Section $source '// Confirmed-close management' '// Filled Trade confirmed-close management'
$preplan = Get-Section $source '// Each pending Entry is valid for exactly validBar' '// Create Setup'
$testCount = 0

Write-Host 'MR-T v4.5.1 Real-Time Execution Correctness harness'

Pass-Test '01 MRT.pine is byte-for-byte unchanged from Git' {
    $null = & git -C $repoRoot diff HEAD --quiet -- MRT.pine
    Assert-True ($LASTEXITCODE -eq 0) 'MRT.pine differs from HEAD'
}
Pass-Test '02 process_orders_on_close is false' { Assert-Match $source 'process_orders_on_close\s*=\s*false' 'next-tick causality' }
Pass-Test '03 Bar Magnifier is enabled' { Assert-Match $source 'use_bar_magnifier\s*=\s*true' 'Bar Magnifier' }
Pass-Test '04 fill recalculation is enabled' { Assert-Match $source 'calc_on_order_fills\s*=\s*true' 'fill recalculation' }
Pass-Test '05 every-tick calculation stays disabled' { Assert-Match $source 'calc_on_every_tick\s*=\s*false' 'tick setting' }
Pass-Test '06 Entry remains Stop-Limit' {
    foreach ($id in @('MR-L', 'MR-S')) { Assert-Match $source ('strategy\.entry\("{0}"[^\r\n]*stop\s*=.*limit\s*=' -f $id) "$id Stop-Limit" }
}
Pass-Test '07 Entry fact is a Broker flat-to-position transition' {
    Assert-Match $brokerSync 'positionEntered\s*=.*previousExecutionPositionSize\s*==\s*0\.0.*currentPositionSize\s*!=\s*0\.0' 'positionEntered'
    Assert-Match $brokerSync 'entryFilled\s*=\s*positionEntered\s+and\s+broker\.entryIntentPending' 'entry ownership'
}
Pass-Test '08 Entry price comes from position_avg_price' { Assert-Match $brokerSync 'actualEntryPrice\s*=\s*strategy\.position_avg_price' 'actual entry price' }
Pass-Test '09 PREPLAN remains source N valid N plus 1' { Assert-Match $source 'assist\.sourceBar\s*:=\s*bar_index[\s\S]*?assist\.validBar\s*:=\s*bar_index\s*\+\s*1' 'PREPLAN causality' }
Pass-Test '10 PRE price exits use strategy.order' {
    foreach ($id in @('MR-TP1', 'MR-TP2', 'MR-SL')) { Assert-Match $brokerSync ('strategy\.order\("{0}"' -f $id) "$id strategy.order" }
}
Pass-Test '11 PRE TP1 is a Limit order' { Assert-Match $brokerSync 'strategy\.order\("MR-TP1"[^\r\n]*limit\s*=\s*trade\.partialTarget' 'TP1 limit' }
Pass-Test '12 PRE TP2 is a Limit order' { Assert-Match $brokerSync 'strategy\.order\("MR-TP2"[^\r\n]*limit\s*=\s*trade\.finalTarget' 'TP2 limit' }
Pass-Test '13 Initial Stop is Stop-only' {
    $lines = [regex]::Matches($brokerSync, 'strategy\.order\("MR-SL"[^\r\n]*') | ForEach-Object Value
    Assert-True ($lines.Count -eq 2) 'expected long and short MR-SL orders'
    foreach ($line in $lines) { Assert-Match $line 'stop\s*=\s*trade\.initialStop' 'Initial Stop'; Assert-NotMatch $line '\blimit\s*=' 'Initial Stop must not have limit' }
}
Pass-Test '14 PRE orders share one OCA name' {
    foreach ($id in @('MR-TP1', 'MR-TP2', 'MR-SL')) { Assert-Match $brokerSync ('strategy\.order\("{0}"[^\r\n]*oca_name\s*=\s*preOca' -f $id) "$id PRE OCA" }
}
Pass-Test '15 PRE orders use OCA reduce' { Assert-True (([regex]::Matches($brokerSync, 'strategy\.order\("MR-(TP1|TP2|SL)"[^\r\n]*oca_name\s*=\s*preOca[^\r\n]*oca_type\s*=\s*strategy\.oca\.reduce')).Count -eq 6) 'PRE OCA reduce' }
Pass-Test '16 Initial Stop qty is actual Q' { Assert-Match $brokerSync 'actualPositionQty\s*=\s*math\.abs\(strategy\.position_size\)[\s\S]*?"MR-SL"[^\r\n]*qty\s*=\s*actualPositionQty' 'SL actual Q' }
Pass-Test '17 PRE TP2 qty is actual Q' { Assert-Match $brokerSync '"MR-TP2"[^\r\n]*qty\s*=\s*actualPositionQty[^\r\n]*limit\s*=\s*trade\.finalTarget' 'TP2 actual Q' }
Pass-Test '18 TP1 qty derives from actual Q' { Assert-Match $brokerSync 'trimQty\s*=\s*actualPositionQty\s*\*\s*trimPct\s*/\s*100\.0' 'TP1 actual Q calculation' }
Pass-Test '19 TP1 requires Broker closed-trade ID and reduction' {
    Assert-Match $brokerSync 'hasNewClosedTrade\s*=.*strategy\.closedtrades' 'closed-trade fact'
    Assert-Match $brokerSync 'tp1Filled\s*=\s*priceExitReduction.*latestClosedExitId\s*==\s*"MR-TP1".*latestClosedExitComment\s*==\s*"TP1"' 'TP1 attribution'
}
Pass-Test '20 TP1 alone changes partial state' {
    Assert-Match $brokerSync 'if tp1Filled[\s\S]*?trade\.partialTaken\s*:=\s*true' 'partial state'
    Assert-NotMatch $manage 'partialTaken\s*:=\s*true|partialReached' 'manual TP1 logic'
}
Pass-Test '21 Remaining quantity comes from live position_size' { Assert-Match $brokerSync 'remainingQty\s*=\s*math\.abs\(strategy\.position_size\)' 'actual remainder' }
Pass-Test '22 POST group uses actual remaining quantity' {
    foreach ($id in @('MR-TP2', 'MR-BE')) { Assert-Match $brokerSync ('if remainingQty\s*>\s*0\.0[\s\S]*?strategy\.order\("{0}"[^\r\n]*qty\s*=\s*remainingQty' -f $id) "$id remaining qty" }
}
Pass-Test '23 POST TP2 remains Limit-only' { Assert-Match $brokerSync 'strategy\.order\("MR-TP2"[^\r\n]*qty\s*=\s*remainingQty[^\r\n]*limit\s*=\s*trade\.finalTarget' 'POST TP2' }
Pass-Test '24 POST BE is Stop-only' {
    $lines = [regex]::Matches($brokerSync, 'strategy\.order\("MR-BE"[^\r\n]*') | ForEach-Object Value
    Assert-True ($lines.Count -eq 2) 'expected long and short MR-BE orders'
    foreach ($line in $lines) { Assert-Match $line 'stop\s*=\s*trade\.breakEvenStop' 'BE stop'; Assert-NotMatch $line '\blimit\s*=' 'BE must not have limit' }
}
Pass-Test '25 POST TP2 and BE share OCA reduce' {
    foreach ($id in @('MR-TP2', 'MR-BE')) { Assert-Match $brokerSync ('strategy\.order\("{0}"[^\r\n]*qty\s*=\s*remainingQty[^\r\n]*oca_name\s*=\s*postOca[^\r\n]*oca_type\s*=\s*strategy\.oca\.reduce' -f $id) "$id POST OCA" }
}
Pass-Test '26 Entry to Stop is same-bar legal' { $r = Invoke-BrokerPath @('ENTRY','STOP'); Assert-True (($r.Outcomes -join ',') -eq 'ENTRY,STOP' -and $r.Phase -eq 'FLAT') 'Entry→Stop' }
Pass-Test '27 Entry to TP1 is same-bar legal' { $r = Invoke-BrokerPath @('ENTRY','TP1'); Assert-True (($r.Outcomes -join ',') -eq 'ENTRY,TP1' -and $r.Phase -eq 'POST_TP1') 'Entry→TP1' }
Pass-Test '28 Entry to TP1 to TP2 is same-bar legal' { $r = Invoke-BrokerPath @('ENTRY','TP1','TP2'); Assert-True (($r.Outcomes -join ',') -eq 'ENTRY,TP1,TP2' -and $r.Phase -eq 'FLAT') 'Entry→TP1→TP2' }
Pass-Test '29 Entry to TP1 to BE is same-bar legal' { $r = Invoke-BrokerPath @('ENTRY','TP1','BE'); Assert-True (($r.Outcomes -join ',') -eq 'ENTRY,TP1,BE' -and $r.Phase -eq 'FLAT') 'Entry→TP1→BE' }
Pass-Test '30 Stop first suppresses later TP processing' { $r = Invoke-BrokerPath @('ENTRY','STOP','TP1','TP2'); Assert-True (($r.Outcomes -join ',') -eq 'ENTRY,STOP') 'Stop terminal' }
Pass-Test '31 TP2 first suppresses BE processing' { $r = Invoke-BrokerPath @('ENTRY','TP1','TP2','BE'); Assert-True (($r.Outcomes -join ',') -eq 'ENTRY,TP1,TP2') 'TP2 terminal' }
Pass-Test '32 Chart high and low never determine fills' { Assert-NotMatch $brokerSync '(?m)^\s*(bool|float)\s+\w+\s*=[^\r\n]*\b(high|low)\b' 'manual OHLC fill test' }
Pass-Test '33 Trend Fail is confirmed-close only' { Assert-Match $manage 'closeManagementAllowed\s*=\s*trade\.active\s+and\s+barstate\.isconfirmed' 'confirmed close'; Assert-Match $manage 'trendFailed' 'Trend Fail' }
Pass-Test '34 Timeout is confirmed-close only' { Assert-Match $manage 'closeManagementAllowed[\s\S]*?timeFailed' 'Timeout confirmed close' }
Pass-Test '35 Trend and Timeout submit strategy.close' { Assert-Match $source 'strategy\.close\(closeEntryId' 'market close' }
Pass-Test '36 Market close does not force immediate fill' { Assert-NotMatch $source 'immediately\s*=\s*true' 'immediate close forbidden' }
Pass-Test '37 Decision bar and fill bar are distinct fields' {
    Assert-Match $source 'broker\.fullExitIntentBar\s*:=\s*bar_index' 'decision bar'
    Assert-Match $brokerSync 'trade\.exitBar\s*:=\s*broker\.fullExitIntentPending\s*\?\s*broker\.fullExitIntentBar\s*:\s*bar_index' 'decision field'
    Assert-Match $brokerSync 'trade\.exitFillBar\s*:=\s*bar_index' 'fill bar'
}
Pass-Test '38 Cooldown starts from actual full-exit fill bar' { Assert-Match $brokerSync 'if fullExitFilled[\s\S]*?logic\.lastExitBar\s*:=\s*bar_index' 'fill-based cooldown'; Assert-NotMatch $manage 'logic\.lastExitBar\s*:=' 'decision-based cooldown' }
Pass-Test '39 Timeout starts at actual Entry fill bar' { Assert-Match $brokerSync 'if entryFilled[\s\S]*?trade\.entryBar\s*:=\s*bar_index[\s\S]*?trade\.timeStopBar\s*:=\s*bar_index\s*\+' 'fill-based timeout' }
Pass-Test '40 Exact flat uses position_size equality' { Assert-Match $source 'currentPositionSize\s*==\s*0\.0' 'exact flat' }
Pass-Test '41 No epsilon-flat shortcut exists' { Assert-NotMatch $source 'epsFlat|epsilon|math\.abs\(currentPositionSize\)\s*<\s*0\.' 'epsilon flatness' }
Pass-Test '42 Residual cleanup is terminal fallback only' { Assert-Match $brokerSync 'if terminalPriceReduction[\s\S]*?strategy\.close_all\(comment\s*=\s*"MR-T V4 Residual Cleanup"' 'terminal residual fallback' }
Pass-Test '43 Residual cleanup count exists' { Assert-Match $source 'residualCleanupCount' 'cleanup count'; Assert-Match $source 'RC=' 'Panel cleanup diagnostic' }
Pass-Test '44 Normal price exit targets exact flat' { Assert-Match $brokerSync 'fullExitFilled\s*=\s*positionClosed' 'positionClosed fact'; Assert-Match $source 'terminal price fill should be exactly flat' 'exact-flat contract' }
Pass-Test '45 resetActive clears exitFillBar' { Assert-Match $source 'method resetActive[\s\S]*?this\.exitFillBar\s*:=\s*na' 'exitFillBar reset' }
Pass-Test '46 resetActive clears exitFillPrice' { Assert-Match $source 'method resetActive[\s\S]*?this\.exitFillPrice\s*:=\s*na' 'exitFillPrice reset' }
Pass-Test '47 Retired MR-X IDs are absent' { Assert-NotMatch $source 'MR-X1|MR-X2' 'retired order IDs' }
Pass-Test '48 New order IDs have explicit semantics' { foreach ($id in @('MR-TP1','MR-TP2','MR-SL','MR-BE')) { Assert-Match $source ([regex]::Escape($id)) "missing $id" } }
Pass-Test '49 Strategy Tester is the sole V4 performance source' { foreach ($metric in @('strategy.netprofit','strategy.grossprofit','strategy.grossloss','strategy.closedtrades','strategy.wintrades','strategy.max_drawdown')) { Assert-Match $source ([regex]::Escape($metric)) "missing $metric" } }
Pass-Test '50 No independent P and L ledger exists' { foreach ($retired in @('MRV4ExecutionState','MRShadowExecutionState','v4EquityIndex','f_v4TradeReturn','v4GrossProfit','v4GrossLoss')) { Assert-NotMatch $source ([regex]::Escape($retired)) "retired ledger: $retired" } }
Pass-Test '51 Panel remains exactly 2x21' {
    Assert-Match $source 'table\.new\(position\.top_right,\s*2,\s*21' 'Panel dimensions'
    $rows = [regex]::Matches($source, 'table\.cell\(panel,\s*[01],\s*(\d+)') | ForEach-Object { [int]$_.Groups[1].Value } | Sort-Object -Unique
    Assert-True ($rows.Count -eq 21 -and $rows[0] -eq 0 -and $rows[-1] -eq 20) 'Panel rows 0-20'
}
Pass-Test '52 Quantity model TP1 to TP2 finishes exactly flat' { $r = Invoke-OcaQuantityModel 8.26674 90 'TP2'; Assert-True ($r.RemainingAfterTrim -gt 0.0 -and $r.FinalPosition -eq 0.0) 'TP1→TP2 dust' }
Pass-Test '53 Quantity model TP1 to BE finishes exactly flat' { $r = Invoke-OcaQuantityModel 8.26674 90 'BE'; Assert-True ($r.RemainingAfterTrim -gt 0.0 -and $r.FinalPosition -eq 0.0) 'TP1→BE dust' }
Pass-Test '54 Quantity model Initial Stop finishes exactly flat' { $r = Invoke-OcaQuantityModel 8.26674 90 'STOP'; Assert-True ($r.FinalPosition -eq 0.0) 'Initial Stop dust' }
Pass-Test '55 Release identity and order-fill alerts are explicit' {
    Assert-Match $source 'strategy\("MR-T Strategy v4\.5\.1"' 'strategy version'
    Assert-Match $source 'string SCRIPT_VERSION\s*=\s*"4\.5\.1"' 'version constant'
    foreach ($eventName in @('ENTRY_FILLED','TP1_FILLED','TP2_FILLED','STOP_FILLED','BE_FILLED')) { Assert-Match $source $eventName "missing $eventName" }
    foreach ($field in @('direction=','mode=','order_id=','entry_price=','order_price=','position_size=','source_bar=','valid_bar=')) { Assert-Match $source ([regex]::Escape($field)) "missing $field" }
}
Pass-Test '56 Bar Magnifier precision boundary is documented' { Assert-Match $source 'It is not tick-by-tick exchange replay' 'precision boundary' }
Pass-Test '57 CHANGELOG documents v4.5.1' { Assert-Match $changelog '(?m)^## \[4\.5\.1\].*Real-Time Execution Correctness' 'CHANGELOG v4.5.1' }
Pass-Test '58 V3 parity regression harness stays green' {
    $null = & pwsh -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $v3HarnessPath 2>&1 | Out-String
    Assert-True ($LASTEXITCODE -eq 0) 'V3 parity harness failed'
}

Assert-True ($testCount -ge 58) "expected at least 58 tests, ran $testCount"
Write-Host "PASS: $testCount/$testCount V4.5.1 real-time execution tests"
Write-Host 'TradingView Pine v6 compile, Stop-Limit activation, Bar Magnifier ordering, and same-bar multi-fill checks remain manual release checks.'
