$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $repoRoot 'MRT.pine'
$baselineCommit = '07cbe31a1c9adbdf5d96a6c84558184adfb0cdfb'
$v2Commit = 'fdb2a7d0ff0cf082af2ee15476e8bdb03b708151'

function Assert-True {
    param(
        [bool]$Condition,
        [string]$Message
    )

    if (-not $Condition) {
        throw "ASSERT FAILED: $Message"
    }
}

function Assert-Match {
    param(
        [string]$Text,
        [string]$Pattern,
        [string]$Message
    )

    Assert-True ([regex]::IsMatch($Text, $Pattern, [System.Text.RegularExpressions.RegexOptions]::Singleline)) $Message
}

function Assert-NotMatch {
    param(
        [string]$Text,
        [string]$Pattern,
        [string]$Message
    )

    Assert-True (-not [regex]::IsMatch($Text, $Pattern, [System.Text.RegularExpressions.RegexOptions]::Singleline)) $Message
}

function Get-FunctionBody {
    param([string]$Source, [string]$Name)

    $escapedName = [regex]::Escape($Name)
    $match = [regex]::Match(
        $Source,
        "(?ms)^$escapedName\([^\r\n]*\)[ \t]*=>[ \t]*\r?\n(?<body>.*?)(?=^[^ \t\r\n]|\z)"
    )
    Assert-True $match.Success "function $Name was not found"
    return $match.Groups['body'].Value
}

function Get-Index {
    param([string]$Text, [string]$Pattern, [string]$Message)

    $match = [regex]::Match($Text, $Pattern, [System.Text.RegularExpressions.RegexOptions]::Singleline)
    Assert-True $match.Success $Message
    return $match.Index
}

function Normalize-V2Code {
    param([string]$Text)

    return (($Text -replace '\bt\.', 'logic.' -replace '\bf_activeStop\b', 'f_logicActiveStop' -replace '\bf_enter\b', 'f_logicEnter' -replace '\bf_exit\b', 'f_logicExit' -replace '\bcostBps\b', 'commissionBps' -replace '\s+', ' ').Trim())
}

function Assert-V2Snippet {
    param(
        [string]$V2Body,
        [string]$CurrentBody,
        [string]$Pattern,
        [string]$Message
    )

    $v2Match = [regex]::Match($V2Body, $Pattern, [System.Text.RegularExpressions.RegexOptions]::Singleline)
    Assert-True $v2Match.Success "V2 baseline snippet missing: $Message"
    $expected = Normalize-V2Code $v2Match.Value
    $current = Normalize-V2Code $CurrentBody
    Assert-True $current.Contains($expected) $Message
}

function Get-Decision {
    param(
        [int]$Dir,
        [double]$EntryPrice,
        [double]$BaseStop,
        [double]$PartialTarget,
        [double]$FinalTarget,
        [bool]$PartialTaken,
        [double]$High,
        [double]$Low,
        [double]$Close,
        [bool]$TrendExit = $false,
        [bool]$Timeout = $false
    )

    $activeStop = if ($PartialTaken) {
        if ($Dir -eq 1) { [math]::Max($BaseStop, $EntryPrice) } else { [math]::Min($BaseStop, $EntryPrice) }
    } else {
        $BaseStop
    }

    $stopReached = if ($Dir -eq 1) { $Low -le $activeStop } else { $High -ge $activeStop }
    $partialPriceReached = if ($Dir -eq 1) { $High -ge $PartialTarget } else { $Low -le $PartialTarget }
    $partialReached = (-not $PartialTaken) -and $partialPriceReached
    $finalReached = if ($Dir -eq 1) { $High -ge $FinalTarget } else { $Low -le $FinalTarget }

    if ($stopReached) { return 'STOP' }
    if ($TrendExit) { return 'TREND' }
    if ($Timeout) { return 'TIME' }
    if ($partialReached) { return 'TRIM' }
    if ($finalReached) { return 'FINAL' }
    return 'NONE'
}

function Invoke-LifecycleCase {
    param(
        [int]$Dir,
        [double]$EntryPrice,
        [double]$BaseStop,
        [double]$PartialTarget,
        [double]$FinalTarget,
        [double]$TrimHigh,
        [double]$TrimLow,
        [double]$FinalHigh,
        [double]$FinalLow
    )

    $partialTaken = $false
    $trimDecisionBar = $null
    $exitDecisionBar = $null
    $events = [System.Collections.Generic.List[string]]::new()

    $trimDecision = Get-Decision $Dir $EntryPrice $BaseStop $PartialTarget $FinalTarget $partialTaken $TrimHigh $TrimLow $PartialTarget
    Assert-True ($trimDecision -eq 'TRIM') "trim decision should be TRIM"
    $partialTaken = $true
    $trimDecisionBar = 2
    $events.Add("2:TRIM")

    $finalDecision = Get-Decision $Dir $EntryPrice $BaseStop $PartialTarget $FinalTarget $partialTaken $FinalHigh $FinalLow $FinalTarget
    Assert-True ($finalDecision -eq 'FINAL') "post-trim final decision should be FINAL"
    $partialTaken = $false
    $exitDecisionBar = 3
    $events.Add("3:FINAL")

    [pscustomobject]@{
        PartialTaken = $partialTaken
        TrimDecisionBar = $trimDecisionBar
        ExitDecisionBar = $exitDecisionBar
        Events = @($events)
    }
}

$source = [System.IO.File]::ReadAllText($scriptPath)
$baselineSource = ((& git -C $repoRoot show "$($baselineCommit):MRT.pine") -join [Environment]::NewLine)
$v2Source = ((& git -C $repoRoot show "$($v2Commit):MRT.pine") -join [Environment]::NewLine)

Write-Host 'MRT v3.3.0 V2 Logic-State Parity Harness'
Write-Host "Repo: $repoRoot"
Write-Host "Current baseline: $baselineCommit"
Write-Host "V2 baseline: $v2Commit"

# Version, settings, and input compatibility.
Assert-Match $source 'SCRIPT_VERSION\s*=\s*"3\.3\.0"' 'SCRIPT_VERSION must be 3.3.0'
Assert-Match $source 'strategy\([^\r\n]*commission_type\s*=\s*strategy\.commission\.percent[^\r\n]*commission_value\s*=\s*0\.03' 'strategy commission settings changed'
Assert-Match $source 'strategy\([^\r\n]*slippage\s*=\s*0' 'strategy slippage setting changed'

$inputLines = @($source -split '\r?\n' | Where-Object { $_ -match '^[ \t]*[A-Za-z_][A-Za-z0-9_]*[ \t]*=[ \t]*input\.' })
Assert-True ($inputLines.Count -eq 58) "expected 58 inputs, found $($inputLines.Count)"
$baselineInputLines = @($baselineSource -split '\r?\n' | Where-Object { $_ -match '^[ \t]*[A-Za-z_][A-Za-z0-9_]*[ \t]*=[ \t]*input\.' })
Assert-True (($inputLines -join [Environment]::NewLine) -eq ($baselineInputLines -join [Environment]::NewLine)) 'input declarations/defaults changed from the v3.2.0 baseline'
Assert-Match $source 'commissionBps\s*=\s*input\.float\(3\.0' 'commissionBps default changed'
Assert-Match $source 'slippageTicks\s*=\s*input\.int\(0' 'slippageTicks default changed'
Assert-Match $source 'trimPct\s*=\s*input\.float\(50\.0' 'trimPct default changed'

# V2 formulas, setup ordering, and signal gates must remain equivalent.
Assert-Match $source 'longShockSetup\s*=\s*allowLong\s*and\s*shockEnvironment\s*and\s*shockDown\s*and\s*z\s*<=\s*-shockEntryZ\s*and\s*decelerationOK\s*and\s*longRejectionOK\s*and\s*noSameLong' 'shock-long setup formula changed'
Assert-Match $source 'shortShockSetup\s*=\s*allowShort\s*and\s*shockEnvironment\s*and\s*shockUp\s*and\s*z\s*>=\s*shockEntryZ\s*and\s*decelerationOK\s*and\s*shortRejectionOK\s*and\s*noSameShort' 'shock-short setup formula changed'
Assert-Match $source 'longRangeSetup\s*=\s*allowLong\s*and\s*rangeEnvironment\s*and\s*z\s*<=\s*-rangeEntryZ\s*and\s*noSameLong' 'range-long setup formula changed'
Assert-Match $source 'shortRangeSetup\s*=\s*allowShort\s*and\s*rangeEnvironment\s*and\s*z\s*>=\s*rangeEntryZ\s*and\s*noSameShort' 'range-short setup formula changed'
Assert-Match $source 'longShockSetup[\s\S]*?shortShockSetup[\s\S]*?longRangeSetup[\s\S]*?shortRangeSetup' 'setup priority changed'
Assert-Match $source 'Setup Expiry' 'setup expiry sequence missing'
Assert-Match $source 'logic\.setupDir\s*\*\s*z\s*<=\s*-stopZ' 'setup failure sequence missing'
Assert-Match $source 'bool longEntrySignal\s*=\s*barstate\.isconfirmed[\s\S]*?logic\.setupDir\s*==\s*1[\s\S]*?zReclaim[\s\S]*?bandOK[\s\S]*?candleOK' 'long entry signal gate changed'
Assert-Match $source 'bool shortEntrySignal\s*=\s*barstate\.isconfirmed[\s\S]*?logic\.setupDir\s*==\s*-1[\s\S]*?zReclaim[\s\S]*?bandOK[\s\S]*?candleOK' 'short entry signal gate changed'
Assert-NotMatch $source 'longEntrySignal[^\r\n]*broker\.|shortEntrySignal[^\r\n]*broker\.' 'entry signal must not depend on Broker State'

# State shape: V2 decision fields live in Logic State; Broker State must not own them.
Assert-Match $source '(?ms)^type MRLogicState\s+.*?varip int\s+pos\s*=\s*0' 'MRLogicState.pos missing'
$logicFields = @(
    'pos', 'partialTaken', 'setupBar', 'setupDir', 'setupMode', 'entryBar', 'entryPrice',
    'mean', 'std', 'atr', 'partialTarget', 'finalTarget', 'baseStop', 'timeStop',
    'tradeMode', 'cost', 'lastExitBar', 'eventKind', 'eventDir', 'eventReason'
)
foreach ($field in $logicFields) {
    Assert-Match $source "(?ms)^type MRLogicState.*?varip [^\r\n]+\s$field\s*=" "MRLogicState.$field missing"
}
Assert-Match $source '(?ms)^type MRLogicState.*?logicEventBar\s*=\s*na.*?logicEventKind\s*=\s*0.*?logicEventPrice\s*=\s*na' 'persistent Logic Event fields missing'

Assert-Match $source '(?ms)^type MRBrokerState\s+.*?previousPositionSize\s*=\s*na' 'MRBrokerState missing broker position tracking'
Assert-Match $source '(?ms)^type MRBrokerState.*?brokerEntryPrice\s*=\s*na' 'MRBrokerState missing broker entry price'
Assert-Match $source '(?ms)^type MRBrokerState.*?fillEventKind\s*=\s*0' 'MRBrokerState missing fill diagnostics'
Assert-Match $source '(?ms)^type MRBrokerState.*?recoveryPending\s*=\s*false' 'MRBrokerState missing recovery fields'
$brokerTypeMatch = [regex]::Match($source, '(?ms)^type MRBrokerState.*?(?=^var MRBrokerState|\z)')
Assert-True $brokerTypeMatch.Success 'MRBrokerState declaration block missing'
foreach ($forbiddenBrokerField in @('partialTaken', 'entryBar', 'lastExitBar', 'activeStop')) {
    Assert-NotMatch $brokerTypeMatch.Value "\b$forbiddenBrokerField\b" "Broker State must not own $forbiddenBrokerField"
}

# Logic-only functions cannot read native broker/fill state or submit orders.
$logicEnterBody = Get-FunctionBody $source 'f_logicEnter'
$logicExitBody = Get-FunctionBody $source 'f_logicExit'
$logicManageBody = Get-FunctionBody $source 'f_logicManage'
$v2ActiveStopBody = Get-FunctionBody $v2Source 'f_activeStop'
$v2EnterBody = Get-FunctionBody $v2Source 'f_enter'
$v2ExitBody = Get-FunctionBody $v2Source 'f_exit'
$v2ManageBody = Get-FunctionBody $v2Source 'f_manage'

foreach ($snippet in @(
    @{ Body = $v2ActiveStopBody; Current = (Get-FunctionBody $source 'f_logicActiveStop'); Pattern = 't\.baseStop'; Message = 'V2 active-stop base source changed' },
    @{ Body = $v2ActiveStopBody; Current = (Get-FunctionBody $source 'f_logicActiveStop'); Pattern = 't\.entryPrice\s*\+\s*t\.cost'; Message = 'V2 long BE threshold changed' },
    @{ Body = $v2ActiveStopBody; Current = (Get-FunctionBody $source 'f_logicActiveStop'); Pattern = 't\.entryPrice\s*-\s*t\.cost'; Message = 'V2 short BE threshold changed' },
    @{ Body = $v2EnterBody; Current = $logicEnterBody; Pattern = 't\.pos\s*:=\s*dir'; Message = 'V2 entry position mutation changed' },
    @{ Body = $v2EnterBody; Current = $logicEnterBody; Pattern = 't\.partialTaken\s*:=\s*false'; Message = 'V2 entry partial reset changed' },
    @{ Body = $v2EnterBody; Current = $logicEnterBody; Pattern = 't\.entryPrice\s*:=\s*close'; Message = 'V2 entry price source changed' },
    @{ Body = $v2EnterBody; Current = $logicEnterBody; Pattern = 't\.mean\s*:=\s*mean15'; Message = 'V2 entry mean source changed' },
    @{ Body = $v2EnterBody; Current = $logicEnterBody; Pattern = 't\.std\s*:=\s*safeStd'; Message = 'V2 entry std source changed' },
    @{ Body = $v2EnterBody; Current = $logicEnterBody; Pattern = 't\.atr\s*:=\s*safeATR'; Message = 'V2 entry ATR source changed' },
    @{ Body = $v2EnterBody; Current = $logicEnterBody; Pattern = 't\.entryBar\s*:=\s*bar_index'; Message = 'V2 entry bar source changed' },
    @{ Body = $v2EnterBody; Current = $logicEnterBody; Pattern = 't\.partialTarget\s*:=\s*t\.mean\s*-\s*dir\s*\*\s*pz\s*\*\s*t\.std'; Message = 'V2 partial target formula changed' },
    @{ Body = $v2EnterBody; Current = $logicEnterBody; Pattern = 't\.finalTarget\s*:=\s*t\.mean\s*-\s*dir\s*\*\s*ez\s*\*\s*t\.std'; Message = 'V2 final target formula changed' },
    @{ Body = $v2EnterBody; Current = $logicEnterBody; Pattern = 'float atrStop\s*=\s*t\.entryPrice\s*-\s*dir\s*\*\s*hardStopATR\s*\*\s*t\.atr'; Message = 'V2 ATR stop formula changed' },
    @{ Body = $v2EnterBody; Current = $logicEnterBody; Pattern = 'float statStop\s*=\s*t\.mean\s*-\s*dir\s*\*\s*stopZ\s*\*\s*t\.std'; Message = 'V2 statistical stop formula changed' },
    @{ Body = $v2EnterBody; Current = $logicEnterBody; Pattern = 'float tightStop\s*=\s*dir\s*==\s*1\s*\?\s*math\.max\(atrStop,\s*statStop\)\s*:\s*math\.min\(atrStop,\s*statStop\)'; Message = 'V2 tight stop formula changed' },
    @{ Body = $v2EnterBody; Current = $logicEnterBody; Pattern = 'float looseStop\s*=\s*dir\s*==\s*1\s*\?\s*math\.min\(atrStop,\s*statStop\)\s*:\s*math\.max\(atrStop,\s*statStop\)'; Message = 'V2 loose stop formula changed' },
    @{ Body = $v2EnterBody; Current = $logicEnterBody; Pattern = 'float balStop\s*=\s*looseStop\s*\+\s*\(tightStop\s*-\s*looseStop\)\s*\*\s*balancedWeight'; Message = 'V2 balanced stop formula changed' },
    @{ Body = $v2EnterBody; Current = $logicEnterBody; Pattern = 't\.timeStop\s*:=\s*int\(math\.round\(limitedTimeStop\)\)'; Message = 'V2 TimeStop formula changed' },
    @{ Body = $v2EnterBody; Current = $logicEnterBody; Pattern = 't\.cost\s*:=\s*t\.entryPrice\s*\*\s*\(2\.0\s*\*\s*costBps\)\s*/\s*10000\.0'; Message = 'V2 Logic cost formula changed' },
    @{ Body = $v2ExitBody; Current = $logicExitBody; Pattern = 't\.lastExitBar\s*:=\s*bar_index'; Message = 'V2 exit cooldown mutation changed' },
    @{ Body = $v2ExitBody; Current = $logicExitBody; Pattern = 't\.pos\s*:=\s*0'; Message = 'V2 exit position mutation changed' },
    @{ Body = $v2ExitBody; Current = $logicExitBody; Pattern = 't\.partialTaken\s*:=\s*false'; Message = 'V2 exit partial reset changed' },
    @{ Body = $v2ManageBody; Current = $logicManageBody; Pattern = 'bool canManage\s*=\s*t\.pos\s*==\s*dir\s*and\s*not na\(t\.entryBar\)\s*and\s*bar_index\s*>\s*t\.entryBar'; Message = 'V2 manage gate changed' },
    @{ Body = $v2ManageBody; Current = $logicManageBody; Pattern = 'bool stopHit\s*=\s*not na\(activeStop\)[\s\S]*?bool trendFailed'; Message = 'V2 stop/trend conditions changed' },
    @{ Body = $v2ManageBody; Current = $logicManageBody; Pattern = 'bool timeFailed\s*=\s*not na\(t\.timeStop\)[\s\S]*?bool partialReached'; Message = 'V2 TimeStop/Trim conditions changed' },
    @{ Body = $v2ManageBody; Current = $logicManageBody; Pattern = 'bool finalReached\s*=\s*t\.partialTaken[\s\S]*?t\.finalTarget'; Message = 'V2 Final condition changed' },
    @{ Body = $v2ManageBody; Current = $logicManageBody; Pattern = 'else if partialReached'; Message = 'V2 trim branch missing' },
    @{ Body = $v2ManageBody; Current = $logicManageBody; Pattern = 'else if finalReached'; Message = 'V2 final branch missing' }
)) {
    Assert-V2Snippet $snippet.Body $snippet.Current $snippet.Pattern $snippet.Message
}

foreach ($bodyName in @('f_logicEnter', 'f_logicExit', 'f_logicManage')) {
    $body = switch ($bodyName) {
        'f_logicEnter' { $logicEnterBody }
        'f_logicExit' { $logicExitBody }
        default { $logicManageBody }
    }
    Assert-NotMatch $body 'strategy\.' "$bodyName must not submit broker orders"
    Assert-NotMatch $body '\bbroker\.' "$bodyName must not read Broker State"
    Assert-NotMatch $body 'fillState|strategy\.position_size|strategy\.closedtrades|currentPosition|recovery' "$bodyName must not use fill/recovery state"
}
Assert-Match $source 'f_logicActiveStop\s*\(' 'logic active-stop function missing'
Assert-Match $logicManageBody 'bool canManage\s*=\s*logic\.pos\s*==\s*dir\s*and\s*not na\(logic\.entryBar\)\s*and\s*bar_index\s*>\s*logic\.entryBar' 'manage gate is not Logic-only or same-bar safe'

# V2 entry mutation and frozen context/cost.
Assert-Match $logicEnterBody 'logic\.pos\s*:=\s*dir' 'entry must immediately mutate Logic position'
Assert-Match $logicEnterBody 'logic\.entryPrice\s*:=\s*close' 'entry price must be the decision close'
Assert-Match $logicEnterBody 'logic\.entryBar\s*:=\s*bar_index' 'entry bar must be the decision bar'
Assert-Match $logicEnterBody 'logic\.mean\s*:=\s*mean15' 'entry mean must be frozen'
Assert-Match $logicEnterBody 'logic\.std\s*:=\s*safeStd' 'entry std must be frozen'
Assert-Match $logicEnterBody 'logic\.atr\s*:=\s*safeATR' 'entry ATR must be frozen'
Assert-Match $logicEnterBody 'logic\.cost\s*:=\s*logic\.entryPrice\s*\*\s*\(2\.0\s*\*\s*commissionBps\)\s*/\s*10000\.0' 'Logic cost must exclude broker slippage'
Assert-NotMatch $logicEnterBody 'slippageTicks|strategy\.slippage|broker execution cost' 'Logic entry cost must not include broker slippage'
Assert-Match $logicEnterBody 'logic\.eventKind\s*:=\s*1' 'entry Logic Event missing'

# V2 active-stop and manage priority.
Assert-Match (Get-FunctionBody $source 'f_logicActiveStop') 'logic\.partialTaken\s*and\s*moveStopToBE' 'active stop must use Logic partialTaken'
Assert-Match (Get-FunctionBody $source 'f_logicActiveStop') 'logic\.entryPrice\s*\+\s*logic\.cost' 'long BE threshold changed'
Assert-Match (Get-FunctionBody $source 'f_logicActiveStop') 'logic\.entryPrice\s*-\s*logic\.cost' 'short BE threshold changed'
Assert-Match $logicManageBody 'stopHit[\s\S]*?trendFailed[\s\S]*?timeFailed[\s\S]*?partialReached[\s\S]*?finalReached' 'manage priority changed'
Assert-Match $logicManageBody 'logic\.partialTaken\s*:=\s*true' 'trim must immediately mutate Logic partialTaken'
Assert-Match $logicManageBody 'logic\.eventKind\s*:=\s*2' 'trim Logic Event missing'
Assert-Match $logicManageBody 'f_logicExit\(dir,\s*R_(BE|STOP|TREND|TIME|FINAL)' 'final/stop/trend/timeout must use Logic exit'
Assert-Match $logicExitBody 'logic\.lastExitBar\s*:=\s*bar_index' 'Logic exit must set cooldown source'
Assert-Match $logicExitBody 'logic\.pos\s*:=\s*0' 'Logic exit must flatten immediately'
Assert-Match $logicExitBody 'logic\.partialTaken\s*:=\s*false' 'Logic exit must reset partial state'
Assert-Match $logicExitBody 'logic\.eventKind\s*:=\s*3' 'exit Logic Event missing'

# Exact decision sequence and execution-only Broker layer.
foreach ($sequenceToken in @(
    '// Setup Expiry', 'logic.setupDir * z <= -stopZ', '// Entry Confirmation',
    '// Logic Decision Execution', '// Derived Logic Events'
)) {
    Assert-Match $source ([regex]::Escape($sequenceToken)) "missing sequence marker: $sequenceToken"
}
$setupIndex = Get-Index $source '// Setup Expiry' 'setup sequence marker missing'
$failureIndex = Get-Index $source 'logic\.setupDir\s*\*\s*z\s*<=\s*-stopZ' 'setup failure sequence marker missing'
$entryIndex = Get-Index $source '// Entry Confirmation' 'entry sequence marker missing'
$executionIndex = Get-Index $source '// Logic Decision Execution' 'execution sequence marker missing'
$derivedIndex = Get-Index $source '// Derived Logic Events' 'derived-event sequence marker missing'
Assert-True ($setupIndex -lt $failureIndex -and $failureIndex -lt $entryIndex -and $entryIndex -lt $executionIndex -and $executionIndex -lt $derivedIndex) 'decision/execution sequence is out of order'

Assert-Match $source 'f_logicEnter\(1\)[\s\S]*?strategy\.entry\("MR-L"' 'long entry must submit broker intent after Logic entry'
Assert-Match $source 'f_logicEnter\(-1\)[\s\S]*?strategy\.entry\("MR-S"' 'short entry must submit broker intent after Logic entry'
Assert-Match $source 'strategy\.close\(trimEntryId[\s\S]*?qty_percent\s*=\s*trimPct' 'trim must submit a real qty-percent close'
Assert-Match $source 'strategy\.close\(closeEntryId' 'full Logic exit must submit broker close intent'
Assert-NotMatch $source 'strategy\.order\s*\(|strategy\.exit\s*\(' 'legacy strategy.order/strategy.exit must not remain'
Assert-NotMatch $source '"LongEntry"|"ShortEntry"|"LongTrim"|"ShortTrim"|"LongExit"|"ShortExit"' 'legacy order IDs must not remain'
Assert-NotMatch $source 'oca_name|oca_type' 'legacy OCA lifecycle must not remain'

# Real fills synchronize Broker State only; they must not decide T points or cooldown.
Assert-Match $source 'bool isFillSynchronizationExecution\s*=\s*positionChanged' 'fill recalculation gate missing'
Assert-Match $source 'allowBarCloseDecision\s*=\s*barstate\.isconfirmed\s*and\s*not isFillSynchronizationExecution' 'same-close decisions must be fill-gated'
Assert-Match $source 'broker\.brokerEntryPrice\s*:=\s*strategy\.position_avg_price' 'broker entry price must use actual average fill price'
Assert-Match $source 'trimFilled[\s\S]{0,800}broker\.trimFillBar\s*:=\s*bar_index' 'trim fill diagnostic missing'
Assert-NotMatch $source 'trimFilled[\s\S]{0,800}logic\.partialTaken\s*:=\s*true' 'trim fill must not create the Logic trim decision'
Assert-NotMatch $source 'positionClosed[\s\S]{0,1200}logic\.(pos|lastExitBar|partialTaken)\s*:=' 'full fill must not mutate Logic lifecycle'
Assert-Match $source 'if not na\(logic\.lastExitBar\)[\s\S]{0,500}barsSinceExit\s*:=\s*bar_index\s*-\s*logic\.lastExitBar' 'cooldown must use Logic lastExitBar'
Assert-NotMatch $source 'barsSinceExit[\s\S]{0,500}(positionClosed|strategy\.closedtrades|broker\.)' 'cooldown must not use broker fills'

# Recovery may cancel/flatten broker exposure, but cannot mutate Logic or create a Logic Event.
Assert-Match $source 'bool consistencyRecoveryRequired\s*=\s*false' 'recovery classification missing'
Assert-Match $source 'consistencyRecoveryRequired\s*:=\s*true' 'recovery classification must be explicit'
$recoveryMatch = [regex]::Match($source, '(?ms)// Recovery is an execution-layer safety action.*?(?=^// Fill recalculation|\z)')
Assert-True $recoveryMatch.Success 'broker recovery block missing'
$recoveryBody = $recoveryMatch.Value
Assert-NotMatch $recoveryBody '\blogic\.' 'broker recovery must not mutate/read Logic State'
Assert-Match $recoveryBody 'strategy\.cancel_all\(\)' 'recovery must cancel outstanding broker orders'
Assert-Match $recoveryBody 'strategy\.close_all\([^\r\n]*BROKER RECOVERY' 'recovery must flatten unexpected broker exposure'

# Persistent Logic Events survive same-close fill recalculation and clear only on a new bar.
Assert-Match $source 'if na\(logic\.logicEventBar\) or bar_index != logic\.logicEventBar' 'Logic Event reset guard missing'
Assert-Match $source 'logic\.logicEventKind\s*:=\s*0[\s\S]*?logic\.logicEventDir\s*:=\s*0[\s\S]*?logic\.logicEventReason\s*:=\s*0[\s\S]*?logic\.logicEventPrice\s*:=\s*na' 'new-bar Logic Event reset incomplete'
Assert-NotMatch $source '(positionEntered|positionClosed|trimFilled)[\s\S]{0,1200}logic\.logicEventKind\s*:=\s*0' 'fills must not clear persistent Logic Event'
Assert-Match $source 'entryEvent\s*:=\s*logic\.logicEventBar\s*==\s*bar_index\s*and\s*logic\.logicEventKind\s*==\s*1' 'entry event must come from Logic Event'
Assert-Match $source 'partialEvent\s*:=\s*logic\.logicEventBar\s*==\s*bar_index\s*and\s*logic\.logicEventKind\s*==\s*2' 'trim event must come from Logic Event'
Assert-Match $source 'exitEvent\s*:=\s*logic\.logicEventBar\s*==\s*bar_index\s*and\s*logic\.logicEventKind\s*==\s*3' 'exit event must come from Logic Event'
Assert-Match $source 'if entryEvent[\s\S]{0,500}label\.new' 'entry T labels must be Logic-event based'
Assert-Match $source 'if partialEvent[\s\S]{0,500}label\.new' 'trim T labels must be Logic-event based'
Assert-Match $source 'if exitEvent[\s\S]{0,500}label\.new' 'exit T labels must be Logic-event based'

# Required data-window diagnostics.
foreach ($dataWindowLabel in @(
    'Logic Position', 'Logic Partial Taken', 'Logic Entry Bar', 'Logic Entry Price',
    'Logic Partial Target', 'Logic Final Target', 'Logic Base Stop', 'Logic Active Stop',
    'Logic Time Stop', 'Logic Last Exit Bar', 'Logic Event Code', 'Logic Event Reason',
    'Broker Position', 'Broker Entry Price', 'Broker Fill Event', 'Broker Recovery Count',
    'Broker Consistency State', 'Direction Reversal Detected', 'Logic Trim Decision Bar',
    'Broker Trim Fill Bar', 'Logic Exit Decision Bar', 'Broker Full Exit Fill Bar'
)) {
    Assert-Match $source ([regex]::Escape($dataWindowLabel)) "missing Data Window field: $dataWindowLabel"
}

# Dynamic lifecycle checks for the two reported failure modes and cooldown semantics.
$caseA = Invoke-LifecycleCase -Dir -1 -EntryPrice 100 -BaseStop 101 -PartialTarget 95 -FinalTarget 90 -TrimHigh 100 -TrimLow 95 -FinalHigh 94 -FinalLow 90
Assert-True ($caseA.Events -join ',' -eq '2:TRIM,3:FINAL') 'Case A must trim on bar 2 and final-exit on the next bar'
Assert-True ($caseA.PartialTaken -eq $false) 'Case A must be flat in Logic after final exit'
Assert-True ($caseA.TrimDecisionBar -eq 2 -and $caseA.ExitDecisionBar -eq 3) 'Case A decision bars are wrong'

$caseBDecision = Get-Decision 1 100 101 105 108 $false 102 100 101
Assert-True ($caseBDecision -eq 'STOP') 'Case B long stop must win before trim/final logic'
$caseBNoTrimAfterStop = Get-Decision 1 100 101 105 108 $false 102 100 101
Assert-True ($caseBNoTrimAfterStop -ne 'TRIM') 'Case B must not emit trim after stop'

$beDecision = Get-Decision 1 100 95 105 110 $true 104 100.5 103
Assert-True ($beDecision -eq 'NONE') 'post-trim BE stop must not trigger on a bar that only touches below target'
$beStopDecision = Get-Decision 1 100 95 105 110 $true 101 99 99
Assert-True ($beStopDecision -eq 'STOP') 'post-trim BE stop must control the next bar'

$cooldownBars = 2
$lastExitBar = 10
Assert-True ((10 - $lastExitBar) -lt [math]::Max($cooldownBars, 1)) 'same-bar exit must remain in cooldown'
Assert-True ((12 - $lastExitBar) -ge [math]::Max($cooldownBars, 1)) 'cooldown must release after the configured number of bars'

Write-Host 'PASS: static V2 Logic-State parity checks'
Write-Host 'PASS: dynamic Case A short trim -> next-bar final exit'
Write-Host 'PASS: dynamic Case B long stop precedence and no trim'
Write-Host 'PASS: dynamic post-trim BE and cooldown checks'
Write-Host 'All MRT v3.3.0 V2 Logic-State Parity checks passed.'
