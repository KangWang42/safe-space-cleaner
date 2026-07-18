[CmdletBinding()]
param(
    [ValidateSet('Audit', 'Clean', 'Interactive')]
    [string]$Mode = 'Audit',

    [ValidatePattern('^[A-Za-z]:?$')]
    [string]$Drive = 'C',

    [string]$ReportDirectory = (Join-Path (Get-Location) 'local-reports'),

    [string]$PlanPath,

    [string]$ConfirmationToken,

    [string]$TestRoot
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$Script:SchemaVersion = '1.1'
$Script:Utf8NoBom = New-Object Text.UTF8Encoding($false)

function Normalize-Drive {
    param([string]$Value)
    return ($Value.Substring(0, 1).ToUpperInvariant() + ':')
}

function Normalize-Path {
    param([string]$Value)
    return [IO.Path]::GetFullPath($Value).TrimEnd('\')
}

function Test-PathWithinRoot {
    param([string]$Path, [string]$Root)
    $pathValue = Normalize-Path $Path
    $rootValue = Normalize-Path $Root
    return $pathValue.Equals($rootValue, [StringComparison]::OrdinalIgnoreCase) -or
        $pathValue.StartsWith($rootValue + '\', [StringComparison]::OrdinalIgnoreCase)
}

function Test-PathOnDrive {
    param([string]$Path, [string]$TargetDrive)
    $root = [IO.Path]::GetPathRoot((Normalize-Path $Path))
    return -not [string]::IsNullOrWhiteSpace($root) -and
        $root.TrimEnd('\').Equals($TargetDrive, [StringComparison]::OrdinalIgnoreCase)
}

function Format-Bytes {
    param([Int64]$Bytes)
    $value = [double]$Bytes
    foreach ($unit in @('B', 'KiB', 'MiB', 'GiB', 'TiB')) {
        if ($value -lt 1024 -or $unit -eq 'TiB') { return ('{0:N2} {1}' -f $value, $unit) }
        $value /= 1024
    }
}

function Write-Utf8File {
    param([string]$Path, [string]$Content)
    [IO.File]::WriteAllText($Path, $Content, $Script:Utf8NoBom)
}

function Write-JsonFile {
    param([string]$Path, [object]$Value)
    Write-Utf8File -Path $Path -Content ($Value | ConvertTo-Json -Depth 10)
}

function Get-FileToken {
    param([string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-DriveState {
    param([string]$TargetDrive)
    $driveInfo = Get-PSDrive -Name $TargetDrive.Substring(0, 1) -PSProvider FileSystem -ErrorAction Stop
    return [pscustomobject]@{
        Drive = $TargetDrive
        UsedBytes = [Int64]$driveInfo.Used
        FreeBytes = [Int64]$driveInfo.Free
        CapacityBytes = [Int64]($driveInfo.Used + $driveInfo.Free)
    }
}

function Measure-CacheRoot {
    param([string]$Root)
    if (-not [IO.Directory]::Exists($Root)) { return [pscustomobject]@{ Files = 0L; Bytes = 0L } }
    $files = 0L
    $bytes = 0L
    Get-ChildItem -LiteralPath $Root -Force -File -Recurse -ErrorAction SilentlyContinue |
        Where-Object { -not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) } |
        ForEach-Object { $files++; $bytes += [Int64]$_.Length }
    return [pscustomobject]@{ Files = $files; Bytes = $bytes }
}

function Measure-ManagedDefinition {
    param([object]$Definition)
    $files = 0L
    $bytes = 0L
    foreach ($root in @($Definition.MeasureRoots)) {
        $measurement = Measure-CacheRoot -Root ([string]$root)
        $files += [Int64]$measurement.Files
        $bytes += [Int64]$measurement.Bytes
    }
    return [pscustomobject]@{ Files = $files; Bytes = $bytes }
}

function Invoke-NativeCommand {
    param([string]$Executable, [string[]]$Arguments)
    $previousPreference = $ErrorActionPreference
    $output = @()
    $exitCode = -1
    try {
        # Windows PowerShell 5.1 turns native stderr into ErrorRecord objects.
        # Cache tools use stderr for normal progress and warnings, so rely on
        # the native exit code and retain both streams for the report.
        $ErrorActionPreference = 'Continue'
        $output = @(& $Executable @Arguments 2>&1)
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousPreference
    }
    return [pscustomobject]@{
        ExitCode = [int]$exitCode
        Output = @($output | ForEach-Object { [string]$_ })
    }
}

function Get-RootFromCommand {
    param([string]$Executable, [string[]]$Arguments)
    $result = Invoke-NativeCommand -Executable $Executable -Arguments $Arguments
    if ($result.ExitCode -ne 0) { throw ('cache directory query failed with exit code {0}' -f $result.ExitCode) }
    foreach ($line in $result.Output) {
        $candidate = ([string]$line).Trim()
        if (-not [string]::IsNullOrWhiteSpace($candidate) -and [IO.Path]::IsPathRooted($candidate)) {
            return Normalize-Path $candidate
        }
    }
    throw 'cache directory query returned no absolute path'
}

function Get-ManagedDefinitions {
    param(
        [string]$TargetDrive,
        [string]$FixtureRoot,
        [System.Collections.IList]$Issues
    )

    if (-not [string]::IsNullOrWhiteSpace($FixtureRoot)) {
        if ($env:SAFE_SPACE_CLEANER_TESTING -ne '1') { throw 'TestRoot is disabled outside the test harness.' }
        $repositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        $mockTool = Normalize-Path (Join-Path $repositoryRoot 'tests\mock-managed-cache.ps1')
        $powershell = (Get-Command powershell.exe -ErrorAction Stop).Source
        $definitions = New-Object 'System.Collections.Generic.List[object]'
        foreach ($id in @('pip-cache', 'uv-cache', 'npm-cache')) {
            $root = Normalize-Path (Join-Path $FixtureRoot $id)
            if ([IO.Directory]::Exists($root)) {
                $mockCommand = [pscustomobject]@{
                    Arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $mockTool, '-CacheRoot', $root)
                    Display = 'fixture cache clean'
                }
                $cleanCommands = @($mockCommand)
                if ($id -eq 'npm-cache') { $cleanCommands = @($mockCommand, $mockCommand) }
                [void]$definitions.Add([pscustomobject]@{
                    Id = $id
                    Tool = 'fixture'
                    Root = $root
                    MeasureRoots = @($root)
                    Executable = $powershell
                    CleanCommands = $cleanCommands
                    ProcessGuard = ''
                    Impact = 'isolated test cache only'
                })
            }
        }
        return $definitions.ToArray()
    }

    $local = [Environment]::GetFolderPath('LocalApplicationData')
    $specifications = @(
        [pscustomobject]@{
            Id = 'pip-cache'; Tool = 'pip'; Command = 'py.exe'; Query = @('-m', 'pip', 'cache', 'dir'); CleanCommands = @([pscustomobject]@{ Arguments = @('-m', 'pip', 'cache', 'purge'); Display = 'py -m pip cache purge' }); MeasureRelativeRoots = @(''); Expected = (Join-Path $local 'pip\Cache'); Guard = 'python'; Impact = 'future Python installs may download or rebuild packages'
        },
        [pscustomobject]@{
            Id = 'uv-cache'; Tool = 'uv'; Command = 'uv.exe'; Query = @('cache', 'dir'); CleanCommands = @([pscustomobject]@{ Arguments = @('cache', 'clean'); Display = 'uv cache clean' }); MeasureRelativeRoots = @(''); Expected = (Join-Path $local 'uv\cache'); Guard = 'uv'; Impact = 'future uv operations may download or rebuild disposable entries'
        },
        [pscustomobject]@{
            Id = 'npm-cache'; Tool = 'npm'; Command = 'npm.cmd'; Query = @('config', 'get', 'cache'); CleanCommands = @([pscustomobject]@{ Arguments = @('cache', 'clean', '--force'); Display = 'npm cache clean --force' }, [pscustomobject]@{ Arguments = @('cache', 'npx', 'rm', '--force'); Display = 'npm cache npx rm --force' }); MeasureRelativeRoots = @('_cacache', '_npx'); Expected = (Join-Path $local 'npm-cache'); Guard = ''; Impact = 'future npm and npx operations may download packages again'
        }
    )

    $definitions = New-Object 'System.Collections.Generic.List[object]'
    foreach ($specification in $specifications) {
        $command = Get-Command $specification.Command -ErrorAction SilentlyContinue
        if ($null -eq $command) {
            [void]$Issues.Add([pscustomobject]@{ Id = $specification.Id; Reason = 'owning tool is not installed or not on PATH' })
            continue
        }
        try {
            $reportedRoot = Get-RootFromCommand -Executable $command.Source -Arguments $specification.Query
            $expectedRoot = Normalize-Path $specification.Expected
            if (-not $reportedRoot.Equals($expectedRoot, [StringComparison]::OrdinalIgnoreCase)) {
                throw ('reported cache root differs from the approved default root: {0}' -f $reportedRoot)
            }
            if (-not (Test-PathOnDrive -Path $reportedRoot -TargetDrive $TargetDrive)) { continue }
            if (-not [IO.Directory]::Exists($reportedRoot)) { continue }
            $measureRoots = New-Object 'System.Collections.Generic.List[string]'
            foreach ($relativeRoot in @($specification.MeasureRelativeRoots)) {
                $measureRoot = if ([string]::IsNullOrWhiteSpace([string]$relativeRoot)) { $reportedRoot } else { Normalize-Path (Join-Path $reportedRoot ([string]$relativeRoot)) }
                if (-not (Test-PathWithinRoot -Path $measureRoot -Root $reportedRoot)) { throw 'measurement root is outside the approved cache root' }
                [void]$measureRoots.Add($measureRoot)
            }
            [void]$definitions.Add([pscustomobject]@{
                Id = $specification.Id
                Tool = $specification.Tool
                Root = $reportedRoot
                MeasureRoots = $measureRoots.ToArray()
                Executable = (Normalize-Path $command.Source)
                CleanCommands = @($specification.CleanCommands)
                ProcessGuard = $specification.Guard
                Impact = $specification.Impact
            })
        }
        catch {
            [void]$Issues.Add([pscustomobject]@{ Id = $specification.Id; Reason = $_.Exception.Message })
        }
    }
    return $definitions.ToArray()
}

function New-AuditMarkdown {
    param([object]$Audit)
    $builder = New-Object Text.StringBuilder
    [void]$builder.AppendLine('# Managed cache audit')
    [void]$builder.AppendLine()
    [void]$builder.AppendLine('| Cache | Files | Size | Owning command | Effect |')
    [void]$builder.AppendLine('| --- | ---: | ---: | --- | --- |')
    foreach ($action in $Audit.ManagedActions) {
        [void]$builder.AppendLine(('| `{0}` | {1:N0} | {2} | `{3}` | {4} |' -f $action.Id, $action.Files, (Format-Bytes $action.Bytes), $action.CommandDisplay, $action.Impact))
    }
    [void]$builder.AppendLine()
    [void]$builder.AppendLine('Only the owning tool may clear these roots. Project environments, installed tools, node_modules, and user files are outside this plan.')
    if (@($Audit.Issues).Count -gt 0) {
        [void]$builder.AppendLine()
        [void]$builder.AppendLine('## Skipped discovery')
        foreach ($issue in $Audit.Issues) { [void]$builder.AppendLine(('- `{0}`: {1}' -f $issue.Id, $issue.Reason)) }
    }
    return $builder.ToString()
}

function Invoke-Audit {
    param([string]$TargetDrive, [string]$OutputDirectory, [string]$FixtureRoot)
    if (-not [string]::IsNullOrWhiteSpace($FixtureRoot)) {
        $FixtureRoot = Normalize-Path $FixtureRoot
        if (-not (Test-PathOnDrive -Path $FixtureRoot -TargetDrive $TargetDrive)) { throw 'TestRoot must be on the selected drive.' }
    }
    $null = New-Item -ItemType Directory -Path $OutputDirectory -Force
    $runId = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ') + '-' + ([Guid]::NewGuid().ToString('N').Substring(0, 8))
    $issues = New-Object 'System.Collections.Generic.List[object]'
    $definitions = @(Get-ManagedDefinitions -TargetDrive $TargetDrive -FixtureRoot $FixtureRoot -Issues $issues)
    $actions = New-Object 'System.Collections.Generic.List[object]'
    foreach ($definition in $definitions) {
        $measurement = Measure-ManagedDefinition -Definition $definition
        if ($measurement.Files -eq 0 -and $measurement.Bytes -eq 0) { continue }
        [void]$actions.Add([pscustomobject]@{
            Id = $definition.Id
            Tool = $definition.Tool
            Root = $definition.Root
            MeasureRoots = @($definition.MeasureRoots)
            Executable = $definition.Executable
            CleanCommands = @($definition.CleanCommands)
            ProcessGuard = $definition.ProcessGuard
            Files = [Int64]$measurement.Files
            Bytes = [Int64]$measurement.Bytes
            CommandDisplay = (($definition.CleanCommands | ForEach-Object { $_.Display }) -join '; ')
            Impact = $definition.Impact
        })
    }
    $plan = [pscustomobject]@{
        SchemaVersion = $Script:SchemaVersion
        RunId = $runId
        Drive = $TargetDrive
        TestMode = (-not [string]::IsNullOrWhiteSpace($FixtureRoot))
        ManagedActions = $actions.ToArray()
    }
    $audit = [pscustomobject]@{
        SchemaVersion = $Script:SchemaVersion
        RunId = $runId
        DriveState = Get-DriveState -TargetDrive $TargetDrive
        ManagedActions = $actions.ToArray()
        Issues = $issues.ToArray()
    }
    $planFile = Join-Path $OutputDirectory ('managed-plan-' + $runId + '.json')
    $jsonFile = Join-Path $OutputDirectory ('managed-audit-' + $runId + '.json')
    $markdownFile = Join-Path $OutputDirectory ('managed-audit-' + $runId + '.md')
    Write-Utf8File -Path $planFile -Content ($plan | ConvertTo-Json -Depth 8 -Compress)
    Write-JsonFile -Path $jsonFile -Value $audit
    Write-Utf8File -Path $markdownFile -Content (New-AuditMarkdown -Audit $audit)
    $token = Get-FileToken -Path $planFile
    $bytes = 0L
    foreach ($action in $actions) { $bytes += [Int64]$action.Bytes }
    Write-Host ('Managed cache audit: {0} actions, {1}.' -f $actions.Count, (Format-Bytes $bytes))
    Write-Host ('Plan: {0}' -f $planFile)
    Write-Host ('Confirmation token: {0}' -f $token)
    return [pscustomobject]@{
        Mode = 'Audit'; RunId = $runId; PlanPath = $planFile; ConfirmationToken = $token; AuditJsonPath = $jsonFile; AuditMarkdownPath = $markdownFile; Actions = $actions.Count; Bytes = $bytes; Issues = $issues.Count
    }
}

function New-CleanupMarkdown {
    param([object]$Report)
    $builder = New-Object Text.StringBuilder
    [void]$builder.AppendLine('# Managed cache cleanup')
    [void]$builder.AppendLine()
    [void]$builder.AppendLine(('- Reclaimed cache bytes: {0}' -f (Format-Bytes $Report.Summary.ReclaimedBytes)))
    [void]$builder.AppendLine(('- Free-space change: {0}' -f (Format-Bytes $Report.Summary.FreeSpaceChangeBytes)))
    [void]$builder.AppendLine()
    [void]$builder.AppendLine('| Cache | Status | Before | After | Exit |')
    [void]$builder.AppendLine('| --- | --- | ---: | ---: | ---: |')
    foreach ($action in $Report.ManagedActions) {
        [void]$builder.AppendLine(('| `{0}` | {1} | {2} | {3} | {4} |' -f $action.Id, $action.Status, (Format-Bytes $action.BeforeBytes), (Format-Bytes $action.AfterBytes), $action.ExitCode))
    }
    return $builder.ToString()
}

function Invoke-Clean {
    param([string]$TargetDrive, [string]$SelectedPlanPath, [string]$Token, [string]$OutputDirectory, [string]$FixtureRoot)
    if ([string]::IsNullOrWhiteSpace($SelectedPlanPath) -or -not [IO.File]::Exists($SelectedPlanPath)) { throw 'Clean mode requires an existing PlanPath.' }
    $actualToken = Get-FileToken -Path $SelectedPlanPath
    if (-not $actualToken.Equals($Token, [StringComparison]::OrdinalIgnoreCase)) { throw 'Confirmation token mismatch. Run a new audit.' }
    $plan = Get-Content -Raw -Encoding UTF8 -LiteralPath $SelectedPlanPath | ConvertFrom-Json
    if ($plan.SchemaVersion -ne $Script:SchemaVersion) { throw 'Unsupported plan schema.' }
    if ((Normalize-Drive $plan.Drive) -ne $TargetDrive) { throw 'Plan drive mismatch.' }
    if ([bool]$plan.TestMode -and [string]::IsNullOrWhiteSpace($FixtureRoot)) { throw 'Test plan requires TestRoot.' }
    if (-not [bool]$plan.TestMode -and -not [string]::IsNullOrWhiteSpace($FixtureRoot)) { throw 'Production plan cannot use TestRoot.' }

    $null = New-Item -ItemType Directory -Path $OutputDirectory -Force
    $issues = New-Object 'System.Collections.Generic.List[object]'
    $definitions = @(Get-ManagedDefinitions -TargetDrive $TargetDrive -FixtureRoot $FixtureRoot -Issues $issues)
    $definitionMap = @{}
    foreach ($definition in $definitions) { $definitionMap[$definition.Id] = $definition }
    $driveBefore = Get-DriveState -TargetDrive $TargetDrive
    $results = New-Object 'System.Collections.Generic.List[object]'

    foreach ($planned in @($plan.ManagedActions)) {
        $status = 'SkippedValidation'
        $reason = ''
        $exitCode = -1
        $before = [pscustomobject]@{ Files = 0L; Bytes = 0L }
        $after = $before
        $outputSummary = ''
        $current = $null
        $definitionValidated = $false
        try {
            if (-not $definitionMap.ContainsKey([string]$planned.Id)) { throw 'managed cache definition is no longer available' }
            $current = $definitionMap[[string]$planned.Id]
            if (-not (Normalize-Path $current.Root).Equals((Normalize-Path ([string]$planned.Root)), [StringComparison]::OrdinalIgnoreCase)) { throw 'cache root changed after audit' }
            if (-not (Normalize-Path $current.Executable).Equals((Normalize-Path ([string]$planned.Executable)), [StringComparison]::OrdinalIgnoreCase)) { throw 'owning executable changed after audit' }
            if (-not (Test-PathOnDrive -Path $current.Root -TargetDrive $TargetDrive)) { throw 'cache root moved to another drive' }
            $before = Measure-ManagedDefinition -Definition $current
            $after = $before
            $definitionValidated = $true
            if (-not [string]::IsNullOrWhiteSpace($current.ProcessGuard) -and (Get-Process -Name $current.ProcessGuard -ErrorAction SilentlyContinue)) {
                $status = 'SkippedProcessRunning'
                $reason = ('owning process is running: {0}' -f $current.ProcessGuard)
            }
            else {
                $commandOutput = New-Object 'System.Collections.Generic.List[string]'
                foreach ($command in @($current.CleanCommands)) {
                    $commandResult = Invoke-NativeCommand -Executable $current.Executable -Arguments @($command.Arguments)
                    $exitCode = $commandResult.ExitCode
                    [void]$commandOutput.Add(('$ ' + $command.Display))
                    foreach ($line in $commandResult.Output) { [void]$commandOutput.Add($line) }
                    $outputSummary = ($commandOutput.ToArray() -join "`n")
                    if ($outputSummary.Length -gt 4000) { $outputSummary = $outputSummary.Substring(0, 4000) }
                    if ($exitCode -ne 0) { throw ('owning cleanup command failed with exit code {0}: {1}' -f $exitCode, $command.Display) }
                }
                $after = Measure-ManagedDefinition -Definition $current
                $status = 'Executed'
                $reason = 'owning cleanup command completed'
            }
        }
        catch {
            if ($status -eq 'SkippedValidation') { $status = 'Failed' }
            $reason = $_.Exception.Message
            if ($definitionValidated) { $after = Measure-ManagedDefinition -Definition $current } else { $after = $before }
        }
        [void]$results.Add([pscustomobject]@{
            Id = [string]$planned.Id; Tool = [string]$planned.Tool; Root = [string]$planned.Root; Status = $status; BeforeFiles = [Int64]$before.Files; BeforeBytes = [Int64]$before.Bytes; AfterFiles = [Int64]$after.Files; AfterBytes = [Int64]$after.Bytes; ReclaimedBytes = [Math]::Max([Int64]0, ([Int64]$before.Bytes - [Int64]$after.Bytes)); ExitCode = $exitCode; Reason = $reason; OutputSummary = $outputSummary
        })
    }

    $driveAfter = Get-DriveState -TargetDrive $TargetDrive
    $reclaimed = 0L
    foreach ($result in $results) { $reclaimed += [Int64]$result.ReclaimedBytes }
    $report = [pscustomobject]@{
        SchemaVersion = $Script:SchemaVersion; RunId = $plan.RunId; PlanPath = Normalize-Path $SelectedPlanPath; PlanToken = $actualToken; DriveBefore = $driveBefore; DriveAfter = $driveAfter; Summary = [pscustomobject]@{ PlannedActions = @($plan.ManagedActions).Count; ExecutedActions = @($results | Where-Object { $_.Status -eq 'Executed' }).Count; ReclaimedBytes = $reclaimed; FreeSpaceChangeBytes = [Int64]($driveAfter.FreeBytes - $driveBefore.FreeBytes) }; ManagedActions = $results.ToArray()
    }
    $jsonFile = Join-Path $OutputDirectory ('managed-cleanup-' + $plan.RunId + '.json')
    $markdownFile = Join-Path $OutputDirectory ('managed-cleanup-' + $plan.RunId + '.md')
    $csvFile = Join-Path $OutputDirectory ('managed-cleanup-' + $plan.RunId + '.csv')
    Write-JsonFile -Path $jsonFile -Value $report
    Write-Utf8File -Path $markdownFile -Content (New-CleanupMarkdown -Report $report)
    $results.ToArray() | Export-Csv -LiteralPath $csvFile -Encoding UTF8 -NoTypeInformation
    Write-Host ('Managed cache cleanup: {0} actions executed, {1} reclaimed.' -f $report.Summary.ExecutedActions, (Format-Bytes $reclaimed))
    return [pscustomobject]@{ Mode = 'Clean'; RunId = $plan.RunId; ExecutedActions = $report.Summary.ExecutedActions; ReclaimedBytes = $reclaimed; FreeSpaceChangeBytes = $report.Summary.FreeSpaceChangeBytes; ReportJsonPath = $jsonFile; ReportMarkdownPath = $markdownFile; ReportCsvPath = $csvFile }
}

$targetDrive = Normalize-Drive $Drive
switch ($Mode) {
    'Audit' { Invoke-Audit -TargetDrive $targetDrive -OutputDirectory $ReportDirectory -FixtureRoot $TestRoot }
    'Clean' { Invoke-Clean -TargetDrive $targetDrive -SelectedPlanPath $PlanPath -Token $ConfirmationToken -OutputDirectory $ReportDirectory -FixtureRoot $TestRoot }
    'Interactive' {
        $audit = Invoke-Audit -TargetDrive $targetDrive -OutputDirectory $ReportDirectory -FixtureRoot $TestRoot
        $prefix = $audit.ConfirmationToken.Substring(0, 12)
        $answer = Read-Host ('Type CLEAN ' + $prefix + ' to run the owning cache commands')
        if ($answer -ceq ('CLEAN ' + $prefix)) {
            Invoke-Clean -TargetDrive $targetDrive -SelectedPlanPath $audit.PlanPath -Token $audit.ConfirmationToken -OutputDirectory $ReportDirectory -FixtureRoot $TestRoot
        }
        else { $audit }
    }
}
