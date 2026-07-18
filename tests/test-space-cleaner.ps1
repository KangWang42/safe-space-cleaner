$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $repositoryRoot 'safe-space-cleaner\scripts\space-cleaner.ps1'
$managedScriptPath = Join-Path $repositoryRoot 'safe-space-cleaner\scripts\managed-cache-cleaner.ps1'
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
$null = New-Item -ItemType Directory -Path (Join-Path $fixtureRoot 'cache') -Force
$null = New-Item -ItemType Directory -Path (Join-Path $fixtureRoot 'review') -Force
$null = New-Item -ItemType Directory -Path (Join-Path $fixtureRoot 'protected-target') -Force
foreach ($cacheId in @('pip-cache', 'uv-cache', 'npm-cache')) {
    $null = New-Item -ItemType Directory -Path (Join-Path $fixtureRoot ($cacheId + '\nested')) -Force
    [IO.File]::WriteAllText((Join-Path $fixtureRoot ($cacheId + '\root-cache.bin')), ($cacheId + ' root cache'))
    [IO.File]::WriteAllText((Join-Path $fixtureRoot ($cacheId + '\nested\nested-cache.bin')), ($cacheId + ' nested cache'))
}
$oldFile = Join-Path $fixtureRoot 'auto\old.tmp'
$oldNestedFile = Join-Path $fixtureRoot 'auto\nested\old-nested.tmp'
$recentFile = Join-Path $fixtureRoot 'auto\recent.tmp'
$changedFile = Join-Path $fixtureRoot 'auto\changed.tmp'
$lockedFile = Join-Path $fixtureRoot 'auto\locked.tmp'
$protectedFile = Join-Path $fixtureRoot 'protected-target\must-stay.tmp'
$recentCacheFile = Join-Path $fixtureRoot 'cache\recent-cache.bin'
[IO.File]::WriteAllText($oldFile, 'old temporary file')
[IO.File]::WriteAllText($oldNestedFile, 'old nested temporary file')
[IO.File]::WriteAllText($recentFile, 'recent temporary file')
[IO.File]::WriteAllText($changedFile, 'old snapshot')
[IO.File]::WriteAllText($lockedFile, 'old locked snapshot')
[IO.File]::WriteAllText($protectedFile, 'must not be reached through a junction')
[IO.File]::WriteAllText($recentCacheFile, 'pure cache should be planned regardless of age')
(Get-Item -LiteralPath $oldFile).LastWriteTimeUtc = [DateTime]::UtcNow.AddDays(-40)
(Get-Item -LiteralPath $oldNestedFile).LastWriteTimeUtc = [DateTime]::UtcNow.AddDays(-40)
(Get-Item -LiteralPath $changedFile).LastWriteTimeUtc = [DateTime]::UtcNow.AddDays(-40)
(Get-Item -LiteralPath $lockedFile).LastWriteTimeUtc = [DateTime]::UtcNow.AddDays(-40)
(Get-Item -LiteralPath $protectedFile).LastWriteTimeUtc = [DateTime]::UtcNow.AddDays(-40)
$junction = Join-Path $fixtureRoot 'auto\linked-target'
$null = New-Item -ItemType Junction -Path $junction -Target (Join-Path $fixtureRoot 'protected-target')

$env:SAFE_SPACE_CLEANER_TESTING = '1'
$lockHandle = $null
try {
    $audit = & $scriptPath -Mode Audit -Drive $drive -Profile Aggressive -MinAgeDays 7 -ReportDirectory $reportRoot -TestRoot $fixtureRoot
    Assert-True ($audit.Files -eq 5) 'Audit did not select the expected old, locked, and pure-cache files.'
    Assert-True (Test-Path -LiteralPath $audit.PlanPath) 'Audit plan was not created.'
    Assert-True (Test-Path -LiteralPath $audit.AuditCsvPath) 'Exact audit CSV was not created.'
    $auditCheck = (& $checkScriptPath -Path $audit.AuditJsonPath | ConvertFrom-Json)
    Assert-True ($auditCheck.Status -eq 'PASS') 'Structured audit validation did not pass.'

    [IO.File]::WriteAllText($changedFile, 'changed after the audit')
    $lockHandle = [IO.File]::Open($lockedFile, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    $cleanup = & $scriptPath -Mode Clean -Drive $drive -PlanPath $audit.PlanPath -ConfirmationToken $audit.ConfirmationToken -ReportDirectory $reportRoot -TestRoot $fixtureRoot
    $lockHandle.Dispose()
    $lockHandle = $null
    Assert-True (-not (Test-Path -LiteralPath $oldFile)) 'Old file was not deleted.'
    Assert-True (-not (Test-Path -LiteralPath $oldNestedFile)) 'Nested old file was not deleted.'
    Assert-True (Test-Path -LiteralPath $recentFile) 'Recent file must not be deleted.'
    Assert-True (Test-Path -LiteralPath $changedFile) 'Changed file must not be deleted.'
    Assert-True (Test-Path -LiteralPath $lockedFile) 'A locked file must be retained.'
    Assert-True (Test-Path -LiteralPath $protectedFile) 'A file reached through a junction must not be planned or deleted.'
    Assert-True (-not (Test-Path -LiteralPath $recentCacheFile)) 'A pure cache file must be included even when recent.'
    Assert-True ($cleanup.DeletedFiles -eq 3) 'Cleanup deleted an unexpected number of files.'
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
    Assert-True ($logText -match 'SkippedLocked') 'Cleanup CSV did not record the locked file.'

    $managedAudit = & $managedScriptPath -Mode Audit -Drive $drive -ReportDirectory $reportRoot -TestRoot $fixtureRoot
    Assert-True ($managedAudit.Actions -eq 3) 'Managed audit did not discover all three fixture caches.'
    $managedAuditCheck = (& $checkScriptPath -Path $managedAudit.AuditJsonPath | ConvertFrom-Json)
    Assert-True ($managedAuditCheck.Status -eq 'PASS') 'Structured managed audit validation did not pass.'

    Add-Content -LiteralPath $managedAudit.PlanPath -Value ' '
    $managedTokenRejected = $false
    try {
        & $managedScriptPath -Mode Clean -Drive $drive -PlanPath $managedAudit.PlanPath -ConfirmationToken $managedAudit.ConfirmationToken -ReportDirectory $reportRoot -TestRoot $fixtureRoot
    }
    catch {
        $managedTokenRejected = $_.Exception.Message -like '*token mismatch*'
    }
    Assert-True $managedTokenRejected 'A modified managed plan must fail token validation.'
    foreach ($cacheId in @('pip-cache', 'uv-cache', 'npm-cache')) {
        Assert-True (Test-Path -LiteralPath (Join-Path $fixtureRoot ($cacheId + '\root-cache.bin'))) 'Managed token rejection must occur before cache cleanup.'
    }

    $managedAudit = & $managedScriptPath -Mode Audit -Drive $drive -ReportDirectory $reportRoot -TestRoot $fixtureRoot
    $managedCleanup = & $managedScriptPath -Mode Clean -Drive $drive -PlanPath $managedAudit.PlanPath -ConfirmationToken $managedAudit.ConfirmationToken -ReportDirectory $reportRoot -TestRoot $fixtureRoot
    Assert-True ($managedCleanup.ExecutedActions -eq 3) 'All three owning cache commands must execute.'
    $managedReport = Get-Content -Raw -Encoding UTF8 -LiteralPath $managedCleanup.ReportJsonPath | ConvertFrom-Json
    foreach ($action in @($managedReport.ManagedActions)) {
        Assert-True ($action.Status -eq 'Executed') ('Managed cache command did not execute: ' + $action.Id)
        Assert-True ($action.OutputSummary -match 'Mock owning cache command completed') ('Managed cache command output was not recorded: ' + $action.Id)
        Assert-True ($action.OutputSummary -match 'Mock cache diagnostic written to stderr') ('Managed cache stderr was not recorded without causing failure: ' + $action.Id)
        if ($action.Id -eq 'npm-cache') {
            Assert-True (([regex]::Matches($action.OutputSummary, 'Mock owning cache command completed')).Count -eq 2) 'npm fixture must execute both content-cache and npx-cache commands.'
        }
    }
    foreach ($cacheId in @('pip-cache', 'uv-cache', 'npm-cache')) {
        Assert-True (-not (Get-ChildItem -LiteralPath (Join-Path $fixtureRoot $cacheId) -Force -File -Recurse -ErrorAction SilentlyContinue)) ('Managed cache still contains files: ' + $cacheId)
    }
    $managedCleanupCheck = (& $checkScriptPath -Path $managedCleanup.ReportJsonPath | ConvertFrom-Json)
    Assert-True ($managedCleanupCheck.Status -eq 'PASS') 'Structured managed cleanup validation did not pass.'

    $emptyManagedAudit = & $managedScriptPath -Mode Audit -Drive $drive -ReportDirectory $reportRoot -TestRoot $fixtureRoot
    Assert-True ($emptyManagedAudit.Actions -eq 0) 'Empty managed caches must not create no-op cleanup actions.'

    Write-Output 'PASS: isolated file and managed-cache audit, cleanup, changed-file guard, and token guards'
}
finally {
    if ($null -ne $lockHandle) { $lockHandle.Dispose() }
    Remove-Item Env:SAFE_SPACE_CLEANER_TESTING -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $fixtureRoot) {
        Remove-Item -LiteralPath $fixtureRoot -Recurse -Force
    }
}
