$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $repositoryRoot 'safe-space-cleaner\scripts\space-cleaner.ps1'
$checkScriptPath = Join-Path $repositoryRoot 'safe-space-cleaner\scripts\check-report.ps1'
$fixtureRoot = Join-Path $PSScriptRoot '.tmp-fixture'
$reportRoot = Join-Path $fixtureRoot 'reports'
$drive = ([IO.Path]::GetPathRoot($fixtureRoot)).Substring(0, 1)

function Assert-True {
    param(
        [bool]$Condition,
        [string]$Message
    )
    if (-not $Condition) {
        throw $Message
    }
}

if (Test-Path -LiteralPath $fixtureRoot) {
    Remove-Item -LiteralPath $fixtureRoot -Recurse -Force
}

$null = New-Item -ItemType Directory -Path (Join-Path $fixtureRoot 'auto\nested') -Force
$null = New-Item -ItemType Directory -Path (Join-Path $fixtureRoot 'review') -Force
$null = New-Item -ItemType Directory -Path (Join-Path $fixtureRoot 'protected-target') -Force
$oldFile = Join-Path $fixtureRoot 'auto\old.tmp'
$oldNestedFile = Join-Path $fixtureRoot 'auto\nested\old-nested.tmp'
$recentFile = Join-Path $fixtureRoot 'auto\recent.tmp'
$changedFile = Join-Path $fixtureRoot 'auto\changed.tmp'
$protectedFile = Join-Path $fixtureRoot 'protected-target\must-stay.tmp'
[IO.File]::WriteAllText($oldFile, 'old temporary file')
[IO.File]::WriteAllText($oldNestedFile, 'old nested temporary file')
[IO.File]::WriteAllText($recentFile, 'recent temporary file')
[IO.File]::WriteAllText($changedFile, 'old snapshot')
[IO.File]::WriteAllText($protectedFile, 'must not be reached through a junction')
(Get-Item -LiteralPath $oldFile).LastWriteTimeUtc = [DateTime]::UtcNow.AddDays(-40)
(Get-Item -LiteralPath $oldNestedFile).LastWriteTimeUtc = [DateTime]::UtcNow.AddDays(-40)
(Get-Item -LiteralPath $changedFile).LastWriteTimeUtc = [DateTime]::UtcNow.AddDays(-40)
(Get-Item -LiteralPath $protectedFile).LastWriteTimeUtc = [DateTime]::UtcNow.AddDays(-40)
$junction = Join-Path $fixtureRoot 'auto\linked-target'
$null = New-Item -ItemType Junction -Path $junction -Target (Join-Path $fixtureRoot 'protected-target')

$env:SAFE_SPACE_CLEANER_TESTING = '1'
try {
    $audit = & $scriptPath -Mode Audit -Drive $drive -Profile Aggressive -MinAgeDays 7 -ReportDirectory $reportRoot -TestRoot $fixtureRoot
    Assert-True ($audit.Files -eq 3) 'Audit did not select the expected old files.'
    Assert-True (Test-Path -LiteralPath $audit.PlanPath) 'Audit plan was not created.'
    Assert-True (Test-Path -LiteralPath $audit.AuditCsvPath) 'Exact audit CSV was not created.'
    $auditCheck = (& $checkScriptPath -Path $audit.AuditJsonPath | ConvertFrom-Json)
    Assert-True ($auditCheck.Status -eq 'PASS') 'Structured audit validation did not pass.'

    [IO.File]::WriteAllText($changedFile, 'changed after the audit')
    $cleanup = & $scriptPath -Mode Clean -Drive $drive -PlanPath $audit.PlanPath -ConfirmationToken $audit.ConfirmationToken -ReportDirectory $reportRoot -TestRoot $fixtureRoot
    Assert-True (-not (Test-Path -LiteralPath $oldFile)) 'Old file was not deleted.'
    Assert-True (-not (Test-Path -LiteralPath $oldNestedFile)) 'Nested old file was not deleted.'
    Assert-True (Test-Path -LiteralPath $recentFile) 'Recent file must not be deleted.'
    Assert-True (Test-Path -LiteralPath $changedFile) 'Changed file must not be deleted.'
    Assert-True (Test-Path -LiteralPath $protectedFile) 'A file reached through a junction must not be planned or deleted.'
    Assert-True ($cleanup.DeletedFiles -eq 2) 'Cleanup deleted an unexpected number of files.'
    $cleanupCheck = (& $checkScriptPath -Path $cleanup.ReportJsonPath | ConvertFrom-Json)
    Assert-True ($cleanupCheck.Status -eq 'PASS_WITH_WARNINGS') 'Changed-file cleanup must pass with a structured warning.'

    (Get-Item -LiteralPath $changedFile).LastWriteTimeUtc = [DateTime]::UtcNow.AddDays(-40)
    $secondAudit = & $scriptPath -Mode Audit -Drive $drive -Profile Aggressive -MinAgeDays 7 -ReportDirectory $reportRoot -TestRoot $fixtureRoot
    Add-Content -LiteralPath $secondAudit.PlanPath -Value ' '
    $tokenRejected = $false
    try {
        & $scriptPath -Mode Clean -Drive $drive -PlanPath $secondAudit.PlanPath -ConfirmationToken $secondAudit.ConfirmationToken -ReportDirectory $reportRoot -TestRoot $fixtureRoot
    }
    catch {
        $tokenRejected = $_.Exception.Message -like '*token mismatch*'
    }
    Assert-True $tokenRejected 'A modified plan must fail token validation.'
    Assert-True (Test-Path -LiteralPath $changedFile) 'Token rejection must occur before deletion.'

    $logText = Get-Content -Raw -Encoding UTF8 -LiteralPath $cleanup.ReportCsvPath
    Assert-True ($logText -match 'SkippedChanged') 'Cleanup CSV did not record the changed file.'

    Write-Output 'PASS: isolated audit, cleanup, changed-file guard, and token guard'
}
finally {
    Remove-Item Env:SAFE_SPACE_CLEANER_TESTING -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $fixtureRoot) {
        Remove-Item -LiteralPath $fixtureRoot -Recurse -Force
    }
}
