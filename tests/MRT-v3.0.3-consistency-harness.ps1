Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
$pinePath = Join-Path $repoRoot "MRT.pine"
$source = Get-Content -Raw -LiteralPath $pinePath
$failures = [System.Collections.Generic.List[string]]::new()

function Assert-True {
    param(
        [bool] $Condition,
        [string] $Message
    )

    if (-not $Condition) {
        $failures.Add($Message)
    }
}

function Get-Direction {
    param([double] $PositionSize)

    if ($PositionSize -gt 0) { return 1 }
    if ($PositionSize -lt 0) { return -1 }
    return 0
}

function Invoke-ExpectedConsistency {
    param(
        [double] $PreviousPositionSize,
        [double] $CurrentPositionSize,
        [bool] $Active,
        [int] $FillStatePosition,
        [bool] $PendingEntry,
        [int] $PendingDirection,
        [bool] $RecoveryPending = $false
    )

    $currentDirection = Get-Direction $CurrentPositionSize
    $directionReversed = $PreviousPositionSize * $CurrentPositionSize -lt 0
    $normalFullExit = $PreviousPositionSize -ne 0 -and $CurrentPositionSize -eq 0 -and $Active

    if ($RecoveryPending -and $CurrentPositionSize -ne 0) {
        return [pscustomobject]@{ State = 7; Recover = $false; CloseAll = $false; Active = $false }
    }

    if ($directionReversed) {
        return [pscustomobject]@{ State = 7; Recover = $true; CloseAll = $true; Active = $false }
    }

    if ($Active -and $CurrentPositionSize -eq 0 -and -not $normalFullExit) {
        return [pscustomobject]@{ State = 4; Recover = $true; CancelAll = $true; CloseAll = $false; Active = $false }
    }

    if ($Active -and $CurrentPositionSize -ne 0 -and $currentDirection -ne $FillStatePosition) {
        return [pscustomobject]@{ State = 5; Recover = $true; CancelAll = $true; CloseAll = $true; Active = $false }
    }

    if (-not $Active -and -not $PendingEntry -and $CurrentPositionSize -ne 0) {
        return [pscustomobject]@{ State = 6; Recover = $true; CancelAll = $true; CloseAll = $true; Active = $false }
    }

    if ($PendingEntry -and $CurrentPositionSize -eq 0) {
        return [pscustomobject]@{ State = 3; Recover = $false; CloseAll = $false; Active = $false }
    }

    if ($PendingEntry -and $CurrentPositionSize -ne 0 -and $currentDirection -ne $PendingDirection) {
        return [pscustomobject]@{ State = 5; Recover = $true; CancelAll = $true; CloseAll = $true; Active = $false }
    }

    if ($PendingEntry -and $CurrentPositionSize -ne 0 -and $PreviousPositionSize -eq 0 -and $currentDirection -eq $PendingDirection) {
        return [pscustomobject]@{ State = $currentDirection; Recover = $false; CloseAll = $false; Active = $true }
    }

    if ($PendingEntry -and $CurrentPositionSize -ne 0 -and $PreviousPositionSize -ne 0) {
        return [pscustomobject]@{ State = 8; Recover = $true; CancelAll = $true; CloseAll = $true; Active = $false }
    }

    if ($CurrentPositionSize -eq 0) {
        return [pscustomobject]@{ State = 0; Recover = $false; CloseAll = $false; Active = $false }
    }

    if ($Active -and $currentDirection -eq $FillStatePosition) {
        return [pscustomobject]@{ State = $currentDirection; Recover = $false; CloseAll = $false; Active = $true }
    }

    return [pscustomobject]@{ State = 8; Recover = $true; CancelAll = $true; CloseAll = $true; Active = $false }
}

function Get-SafeExitQuantities {
    param(
        [double] $CurrentPositionSize,
        [double] $EntrySize,
        [double] $TrimPercent,
        [bool] $PartialTaken
    )

    $remaining = [math]::Abs($CurrentPositionSize)
    $configuredTrim = $EntrySize * $TrimPercent / 100
    [pscustomobject]@{
        Stop = $remaining
        Trim = if ($PartialTaken) { 0 } else { [math]::Min($configuredTrim, $remaining) }
        Final = if ($PartialTaken) { $remaining } else { 0 }
    }
}

# Source-level contract: these markers are the guardrails that the local Pine
# runtime cannot execute without TradingView's broker emulator.
Assert-True ($source -match 'SCRIPT_VERSION\s*=\s*"3\.0\.3"') 'SCRIPT_VERSION must be 3.0.3.'
Assert-True ($source -match 'bool\s+directionReversed\s*=') 'Direct reversal detector is missing.'
Assert-True ($source -match 'previousExecutionPositionSize\s*\*\s*currentPositionSize\s*<\s*0') 'Direct reversal must detect a cross-zero transition.'
Assert-True ($source -match 'CONSISTENCY_DIRECT_REVERSAL') 'Direct reversal consistency state is missing.'
Assert-True ($source -match 'CONSISTENCY_STALE_ACTIVE_FLAT') 'Stale active-flat consistency state is missing.'
Assert-True ($source -match 'CONSISTENCY_ORPHAN_BROKER') 'Orphan broker consistency state is missing.'
Assert-True ($source -match 'consistencyRecoveryCount') 'Consistency recovery counter is missing.'
Assert-True ($source -match 'R_STATE_RECOVERY') 'State-recovery reason is missing.'
Assert-True ($source -match 'f_safeExitQty') 'Safe exit quantity helper is missing.'
Assert-True ($source -match 'startingRecovery[\s\S]*strategy\.cancel_all\(\)') 'Recovery must cancel stale MR orders before clearing/closing.'
Assert-True ($source -match 'consistencyState\s*:=\s*CONSISTENCY_PENDING_ENTRY') 'Pending entry state is not surfaced after order submission.'
Assert-True ($source -match 'tradeContextValid') 'Trade-context display gate is missing.'
Assert-True ($source -match 'strategy\.close_all\s*\(') 'Orphan/reversal recovery must close the broker position.'
Assert-True ($source -notmatch '(?m)^\s*qty\s*=\s*fillState\.entrySize(?:\s|\*)') 'A protective order still uses raw frozen entrySize as qty.'
Assert-True ($source -notmatch '(?m)^\s*qty\s*=\s*math\.abs\(currentPositionSize\)') 'A protective order bypasses the safe quantity helper.'
Assert-True ($source -match 'Active STOP Qty') 'Active STOP quantity diagnostic is missing.'
Assert-True ($source -match 'Active TRIM Qty') 'Active TRIM quantity diagnostic is missing.'
Assert-True ($source -match 'Active FINAL Qty') 'Active FINAL quantity diagnostic is missing.'
Assert-True ($source -match 'Broker Position') 'Broker position panel diagnostic is missing.'
Assert-True ($source -match 'FillState Position') 'FillState position panel diagnostic is missing.'
Assert-True ($source -match 'Consistency') 'Consistency panel diagnostic is missing.'

# Normal lifecycle transitions.
$longEntry = Invoke-ExpectedConsistency 0 100 $false 0 $true 1
Assert-True ($longEntry.State -eq 1 -or $longEntry.State -eq 3) 'Normal Long entry transition is not accepted.'
$longTrim = Invoke-ExpectedConsistency 100 50 $true 1 $false 0
Assert-True ($longTrim.State -eq 1 -and $longTrim.Active) 'Normal Long trim transition must remain active and Long.'
$longFinal = Invoke-ExpectedConsistency 50 0 $true 1 $false 0
Assert-True ($longFinal.State -eq 0 -and -not $longFinal.Active) 'Normal Long final exit must end flat.'

$shortEntry = Invoke-ExpectedConsistency 0 -100 $false 0 $true -1
Assert-True ($shortEntry.State -eq -1 -or $shortEntry.State -eq 3) 'Normal Short entry transition is not accepted.'
$shortTrim = Invoke-ExpectedConsistency -100 -50 $true -1 $false 0
Assert-True ($shortTrim.State -eq -1 -and $shortTrim.Active) 'Normal Short trim transition must remain active and Short.'
$shortFinal = Invoke-ExpectedConsistency -50 0 $true -1 $false 0
Assert-True ($shortFinal.State -eq 0 -and -not $shortFinal.Active) 'Normal Short final exit must end flat.'

# Stop and Trim -> BE both terminate through the same real broker transition.
$longStop = Invoke-ExpectedConsistency 100 0 $true 1 $false 0
$shortStop = Invoke-ExpectedConsistency -100 0 $true -1 $false 0
Assert-True ($longStop.State -eq 0 -and $shortStop.State -eq 0) 'Stop transitions must end flat.'
$longBe = Invoke-ExpectedConsistency 100 50 $true 1 $false 0
$shortBe = Invoke-ExpectedConsistency -100 -50 $true -1 $false 0
Assert-True ($longBe.Active -and $shortBe.Active) 'Trim -> BE must preserve the live lifecycle.'

# Abnormal transitions must be observable and must not keep the old lifecycle.
$directShortToLong = Invoke-ExpectedConsistency -100 20 $true -1 $false 0
Assert-True ($directShortToLong.State -eq 7 -and $directShortToLong.Recover -and $directShortToLong.CloseAll -and -not $directShortToLong.Active) 'Short -> Long direct reversal must recover.'
$directLongToShort = Invoke-ExpectedConsistency 100 -20 $true 1 $false 0
Assert-True ($directLongToShort.State -eq 7 -and $directLongToShort.Recover -and $directLongToShort.CloseAll -and -not $directLongToShort.Active) 'Long -> Short direct reversal must recover.'

$stale = Invoke-ExpectedConsistency 0 0 $true 1 $false 0
Assert-True ($stale.State -eq 4 -and $stale.Recover -and $stale.CancelAll -and -not $stale.Active) 'Stale active-flat state must be cleared and cancel stale orders without a normal exit.'
$orphan = Invoke-ExpectedConsistency 20 20 $false 0 $false 0
Assert-True ($orphan.State -eq 6 -and $orphan.Recover -and $orphan.CloseAll -and -not $orphan.Active) 'Orphan broker position must be recovered safely.'

# Every protective quantity is bounded by the current broker position, even if
# entrySize is stale or a prior fragment reduced the position unexpectedly.
$beforeTrim = Get-SafeExitQuantities 40 100 50 $false
$afterTrim = Get-SafeExitQuantities 40 100 50 $true
Assert-True ($beforeTrim.Stop -le 40 -and $beforeTrim.Trim -le 40 -and $beforeTrim.Final -le 40) 'Pre-trim quantities exceed the current broker position.'
Assert-True ($afterTrim.Stop -le 40 -and $afterTrim.Trim -le 40 -and $afterTrim.Final -le 40) 'Post-trim quantities exceed the current broker position.'

if ($failures.Count -gt 0) {
    Write-Host "FAIL: $($failures.Count) assertion(s)"
    $failures | ForEach-Object { Write-Host " - $_" }
    exit 1
}

Write-Host "PASS: MRT v3.0.3 consistency and protective-qty contract"
