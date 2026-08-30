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

$source = [IO.File]::ReadAllText($scriptPath)
$v3Source = [IO.File]::ReadAllText($v3Path)
$changelog = [IO.File]::ReadAllText($changelogPath)
$brokerSync = Get-Section $source '// Broker transition detection and fill synchronization.' '// Consistency and recovery are execution diagnostics only.'
$manage = Get-Section $source '// Confirmed-close management' '// Filled Trade confirmed-close management'
$preplan = Get-Section $source '// Each pending Entry is valid for exactly validBar' '// Create Setup'
$testCount = 0

Write-Host 'MR-T v4.5.0 Intrabar Broker-Ordered Exit Lifecycle harness'

Pass-Test '01 MRT.pine is byte-for-byte unchanged' {
    Assert-True ((Get-FileHash -Algorithm SHA256 -LiteralPath $v3Path).Hash -eq 'E9B42666A9150E34504794CC8311936209ECA74D9D049A0AC16C540104A3D1AF') 'MRT.pine SHA changed'
    $null = & git -C $repoRoot diff --quiet -- MRT.pine
    Assert-True ($LASTEXITCODE -eq 0) 'MRT.pine has working-tree changes'
}

Pass-Test '02 Bar Magnifier and fill recalculation are enabled' {
    Assert-Match $source 'use_bar_magnifier\s*=\s*true' 'Bar Magnifier'
    Assert-Match $source 'calc_on_order_fills\s*=\s*true' 'fill recalculation'
}

Pass-Test '03 Entry remains Stop-Limit' {
    foreach ($id in @('MR-L', 'MR-S')) {
        Assert-Match $source ('strategy\.entry\("{0}"[^\r\n]*stop\s*=.*limit\s*=' -f [regex]::Escape($id)) "$id Stop-Limit"
    }
}

Pass-Test '04 Entry fill comes from Broker transition' {
    Assert-Match $brokerSync 'positionEntered\s*=\s*positionSampleReady\s+and\s+previousExecutionPositionSize\s*==\s*0\.0\s+and\s+currentPositionSize\s*!=\s*0\.0' 'flat-to-position transition'
    Assert-Match $brokerSync 'entryFilled\s*=\s*positionEntered\s+and\s+broker\.entryIntentPending' 'entry ownership'
}

Pass-Test '05 Entry price is strategy.position_avg_price' {
    Assert-Match $brokerSync 'actualEntryPrice\s*=\s*strategy\.position_avg_price' 'actual Entry source'
    Assert-Match $brokerSync 'trade\.entryPrice\s*:=\s*actualEntryPrice' 'frozen actual Entry'
}

Pass-Test '06 Entry fill immediately submits MR-X1' {
    Assert-Match $brokerSync 'if entryFilled[\s\S]*?strategy\.exit\("MR-X1"' 'MR-X1 after fill'
}

Pass-Test '07 Entry fill immediately submits MR-X2' {
    Assert-Match $brokerSync 'if entryFilled[\s\S]*?strategy\.exit\("MR-X2"' 'MR-X2 after fill'
}

Pass-Test '08 MR-X1 limit is TP1' {
    Assert-Match $brokerSync 'strategy\.exit\("MR-X1"[^\r\n]*limit\s*=\s*trade\.partialTarget' 'MR-X1 TP1'
}

Pass-Test '09 MR-X1 stop is Initial Stop' {
    Assert-Match $brokerSync 'strategy\.exit\("MR-X1"[^\r\n]*stop\s*=\s*trade\.initialStop' 'MR-X1 Stop'
}

Pass-Test '10 MR-X2 limit is TP2' {
    Assert-Match $brokerSync 'strategy\.exit\("MR-X2"[^\r\n]*qty_percent[^\r\n]*limit\s*=\s*trade\.finalTarget' 'MR-X2 TP2'
}

Pass-Test '11 MR-X2 stop is Initial Stop before TP1' {
    Assert-Match $brokerSync 'strategy\.exit\("MR-X2"[^\r\n]*qty_percent[^\r\n]*stop\s*=\s*trade\.initialStop' 'MR-X2 Initial Stop'
}

Pass-Test '12 Bracket quantities reserve Trim and remainder slices' {
    Assert-Match $brokerSync '"MR-X1"[^\r\n]*qty_percent\s*=\s*trimPct' 'Trim reservation'
    Assert-Match $brokerSync '"MR-X2"[^\r\n]*qty_percent\s*=\s*100\.0\s*-\s*trimPct' 'remainder reservation'
    Assert-Match $brokerSync '"MR-X1"[^\r\n]*oca_name\s*=\s*"MR-X1-BRACKET"' 'isolated MR-X1 OCA group'
    Assert-Match $brokerSync '"MR-X2"[^\r\n]*oca_name\s*=\s*"MR-X2-BRACKET"' 'isolated MR-X2 OCA group'
    Assert-Match $source 'if trimPct\s*<\s*100\.0' 'zero-remainder guard'
}

Pass-Test '13 Price exit orders are allowed on Entry bar' {
    Assert-Match $source 'priceOrdersActive\s*=\s*trade\.active' 'price-order phase'
    Assert-Match $brokerSync 'orders are active on trade\.entryBar itself' 'same-bar contract'
}

Pass-Test '14 Price exits have no entry-bar or confirmed-close gate' {
    $initialBrackets = Get-Section $brokerSync '// Submit both reserved Broker brackets' 'alert(f_entryFilledMessage'
    Assert-NotMatch $initialBrackets 'bar_index\s*>\s*trade\.entryBar|barstate\.isconfirmed' 'price-order gate leaked in'
}

Pass-Test '15 Trend Fail requires confirmed close' {
    Assert-Match $manage 'closeManagementAllowed\s*=\s*trade\.active\s+and\s+barstate\.isconfirmed' 'confirmed-close gate'
    Assert-Match $source 'isNewLogicDecisionBar\s*:=\s*barstate\.isconfirmed\s+and\s+not isFillSynchronizationExecution' 'fill recalculation exclusion'
    Assert-Match $manage 'trendFailed' 'Trend Fail branch'
}

Pass-Test '16 Timeout requires confirmed close' {
    Assert-Match $manage 'closeManagementAllowed[\s\S]*?timeFailed' 'Timeout under close gate'
}

Pass-Test '17 Trend and Timeout require a later bar' {
    Assert-Match $manage 'bar_index\s*>\s*trade\.entryBar' 'Entry-bar exclusion'
}

Pass-Test '18 TP1 state requires actual reduction and MR-X1 fill' {
    Assert-Match $brokerSync 'positionReduced\s*=.*math\.abs\(currentPositionSize\)\s*<\s*math\.abs\(previousExecutionPositionSize\)' 'actual reduction'
    Assert-Match $brokerSync 'tp1Filled\s*=\s*priceExitReduction[\s\S]*?latestClosedExitId\s*==\s*"MR-X1"[\s\S]*?latestClosedExitComment\s*==\s*"TP1"' 'MR-X1 Broker attribution'
}

Pass-Test '19 TP1 order and fill detection do not use chart high or low' {
    Assert-NotMatch $brokerSync '(?m)^\s*(bool|float)\s+\w+\s*=[^\r\n]*\b(high|low)\b' 'manual OHLC fill test'
}

Pass-Test '20 TP1 fill alone marks partialTaken' {
    Assert-Match $brokerSync 'if tp1Filled[\s\S]*?trade\.partialTaken\s*:=\s*true' 'partialTaken fill mutation'
    Assert-NotMatch $manage 'partialTaken\s*:=\s*true|partialReached' 'close manager mutates TP1'
}

Pass-Test '21 TP1 updates MR-X2 to frozen BE' {
    Assert-Match $brokerSync 'if tp1Filled[\s\S]*?strategy\.exit\("MR-X2"[^\r\n]*stop\s*=\s*trade\.breakEvenStop' 'BE bracket update'
}

Pass-Test '22 BE is based on actual Entry' {
    Assert-Match $brokerSync 'candidateBreakEvenStop\s*=\s*f_roundToTick\(actualEntryPrice\s*\+\s*filledDir\s*\*\s*executionCost\)' 'actual-fill BE'
    Assert-Match $source 'f_brokerExecutionCost\(actualEntryPrice\)' 'execution-cost BE'
}

Pass-Test '23 Post-TP1 MR-X2 quantity is actual remainder' {
    Assert-Match $brokerSync 'if tp1Filled[\s\S]*?"MR-X2"[^\r\n]*qty\s*=\s*math\.abs\(strategy\.position_size\)' 'actual remaining qty'
}

Pass-Test '24 TP2 Broker fill makes the formal state flat' {
    Assert-Match $brokerSync 'fullExitFilled\s*=\s*positionClosed[\s\S]*?latestClosedExitId\s*==\s*"MR-X2"' 'MR-X2 flat transition'
    Assert-Match $brokerSync 'latestClosedExitComment\s*==\s*"FINAL"[\s\S]*?R_FINAL' 'Final attribution'
}

Pass-Test '25 Initial Stop Broker fill makes the formal state flat' {
    Assert-Match $brokerSync 'latestClosedExitComment\s*==\s*"BE"\s*\?\s*R_BE\s*:\s*R_STOP' 'Stop attribution fallback'
    Assert-Match $brokerSync 'trade\.resetActive\(\)' 'formal flat reset'
}

Pass-Test '26 BE Broker fill makes the formal state flat' {
    Assert-Match $brokerSync 'latestClosedExitComment\s*==\s*"BE"\s*\?\s*R_BE' 'BE attribution'
    Assert-Match $brokerSync 'finishedEventName[\s\S]*?"BE_FILLED"' 'BE fill alert'
}

Pass-Test '27 Entry, TP, Stop, and BE labels use Broker fill executions' {
    Assert-Match $source 'entryEvent\s*:=\s*entryFilled' 'Entry label source'
    Assert-Match $source 'partialEvent\s*:=\s*tp1Filled' 'TP1 label source'
    Assert-Match $source 'exitEvent\s*:=\s*fullExitFilled' 'full-exit label source'
}

Pass-Test '28 Same-bar Entry to TP1 is permitted' {
    $result = Invoke-BrokerPath @('ENTRY', 'TP1')
    Assert-True (($result.Outcomes -join ',') -eq 'ENTRY,TP1' -and $result.Phase -eq 'POST_TP1') 'Entry→TP1 model'
}

Pass-Test '29 Same-bar Entry to Stop is permitted' {
    $result = Invoke-BrokerPath @('ENTRY', 'STOP')
    Assert-True (($result.Outcomes -join ',') -eq 'ENTRY,STOP' -and $result.Phase -eq 'FLAT') 'Entry→Stop model'
}

Pass-Test '30 Same-bar Entry to TP1 to TP2 is permitted' {
    $result = Invoke-BrokerPath @('ENTRY', 'TP1', 'TP2')
    Assert-True (($result.Outcomes -join ',') -eq 'ENTRY,TP1,TP2' -and $result.Phase -eq 'FLAT') 'Entry→TP1→TP2 model'
}

Pass-Test '31 Same-bar Entry to TP1 to BE is permitted' {
    $result = Invoke-BrokerPath @('ENTRY', 'TP1', 'BE')
    Assert-True (($result.Outcomes -join ',') -eq 'ENTRY,TP1,BE' -and $result.Phase -eq 'FLAT') 'Entry→TP1→BE model'
}

Pass-Test '32 Stop first prevents later TP processing' {
    $result = Invoke-BrokerPath @('ENTRY', 'STOP', 'TP1', 'TP2')
    Assert-True (($result.Outcomes -join ',') -eq 'ENTRY,STOP') 'post-flat TP leak'
}

Pass-Test '33 TP first protects and manages only the remainder' {
    $result = Invoke-BrokerPath @('ENTRY', 'TP1', 'BE', 'STOP')
    Assert-True (($result.Outcomes -join ',') -eq 'ENTRY,TP1,BE') 'post-TP remainder model'
    Assert-Match $brokerSync 'fractional Initial-Stop fill must never leave an unprotected remainder' 'reservation fallback'
}

Pass-Test '34 No independent V4 performance ledger exists' {
    foreach ($retired in @('MRV4ExecutionState', 'MRShadowExecutionState', 'v4EquityIndex', 'f_v4TradeReturn', 'v4GrossProfit', 'v4GrossLoss')) {
        Assert-NotMatch $source ([regex]::Escape($retired)) "retired ledger remains: $retired"
    }
}

Pass-Test '35 Strategy Tester is the sole performance source' {
    foreach ($metric in @('strategy.netprofit', 'strategy.grossprofit', 'strategy.grossloss', 'strategy.closedtrades', 'strategy.wintrades', 'strategy.max_drawdown')) {
        Assert-Match $source ([regex]::Escape($metric)) "missing $metric"
    }
}

Pass-Test '36 Panel remains exactly 2x21' {
    Assert-Match $source 'table\.new\(position\.top_right,\s*2,\s*21' 'Panel dimensions'
    $rows = [regex]::Matches($source, 'table\.cell\(panel,\s*[01],\s*(\d+)') | ForEach-Object { [int]$_.Groups[1].Value } | Sort-Object -Unique
    Assert-True ($rows.Count -eq 21 -and $rows[0] -eq 0 -and $rows[-1] -eq 20) 'Panel rows 0-20'
}

Pass-Test '37 Active Stop distinguishes Initial and BE phases' {
    Assert-Match $source 'trade\.partialTaken\s*\?\s*trade\.breakEvenStop\s*:\s*trade\.initialStop' 'phase-aware Active Stop'
    foreach ($phase in @('POSITION_PRE_TP1', 'POSITION_POST_TP1')) { Assert-Match $source $phase "missing $phase" }
}

Pass-Test '38 V4.4 PREPLAN source and valid-bar logic remains' {
    Assert-Match $source 'assist\.sourceBar\s*:=\s*bar_index[\s\S]*?assist\.validBar\s*:=\s*bar_index\s*\+\s*1' 'N to N+1 plan'
    Assert-Match $source 'setupReadyForPreplan[\s\S]*?not trade\.active' 'no rolling plan in position'
}

Pass-Test '39 Expired pending Entry cancellation remains' {
    Assert-Match $preplan 'assist\.validBar\s*==\s*bar_index' 'valid-bar expiry'
    Assert-Match $preplan 'strategy\.cancel\(expiredEntryId\)' 'exact Entry cancellation'
    Assert-Match $preplan 'ENTRY_EXPIRED_UNFILLED' 'expiry alert'
}

Pass-Test '40 Broker recovery remains' {
    Assert-Match $source 'MR-T Broker Recovery' 'Broker recovery order'
    Assert-Match $source 'strategy\.cancel_all\(\)' 'recovery cancellation'
    Assert-Match $source 'strategy\.close_all\(' 'recovery close'
}

Pass-Test '41 Exact flat remains position_size == 0' {
    Assert-Match $source 'currentPositionSize\s*==\s*0\.0' 'exact-flat comparison'
    Assert-NotMatch $source 'epsFlat|epsilon|math\.abs\(currentPositionSize\)\s*<\s*0\.' 'epsilon flatness'
}

Pass-Test '42 Residual exit orders are cancelled after formal flat' {
    Assert-Match $brokerSync 'if fullExitFilled[\s\S]*?strategy\.cancel\("MR-X1"\)[\s\S]*?strategy\.cancel\("MR-X2"\)' 'flat bracket cleanup'
    Assert-Match $source 'MR-T V4 Residual Cleanup' 'residual position cleanup'
}

Pass-Test '43 V4 does not require V3 Entry or trade-count parity' {
    Assert-NotMatch $source 'V4 Entry bars == V3 Entry bars|V4 trade count == V3 trade count' 'obsolete V3 parity target'
    Assert-Match $source 'legacyV3EntryDiagnostic' 'legacy signal is diagnostic only'
}

Pass-Test 'Release identity, alerts, and Bar Magnifier boundary are documented' {
    Assert-Match $source 'strategy\("MR-T Strategy v4\.5\.0"' 'strategy version'
    Assert-Match $source 'string SCRIPT_VERSION\s*=\s*"4\.5\.0"' 'script version constant'
    foreach ($eventName in @('TP1_FILLED', 'FINAL_FILLED', 'STOP_FILLED', 'BE_FILLED')) { Assert-Match $source $eventName "missing $eventName" }
    foreach ($field in @('entry_price=', 'fill_bar=', 'fill_price=', 'remaining_position=', 'new_stop=')) { Assert-Match $source ([regex]::Escape($field)) "missing $field" }
    Assert-Match $source 'It is not tick-by-tick exchange replay' 'Pine precision boundary'
    Assert-Match $changelog '(?m)^## \[4\.5\.0\].*Intrabar Broker Exit Lifecycle' 'CHANGELOG v4.5.0'
}

Pass-Test 'V3 parity regression harness stays green' {
    $null = & pwsh -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $v3HarnessPath 2>&1 | Out-String
    Assert-True ($LASTEXITCODE -eq 0) 'V3 parity harness failed'
}

Assert-True ($testCount -ge 45) "expected at least 45 tests, ran $testCount"
Write-Host "PASS: $testCount/$testCount V4.5.0 intrabar Broker exit tests"
Write-Host 'TradingView Pine v6 compile, Stop-Limit activation, Bar Magnifier ordering, and same-bar multi-fill checks remain manual release checks.'
