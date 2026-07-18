[CmdletBinding()]
param(
    [ValidateSet('Audit', 'Clean', 'Interactive')]
    [string]$Mode = 'Audit',

    [ValidatePattern('^[A-Za-z]:?$')]
    [string]$Drive = 'C',

    [ValidateSet('Safe', 'Aggressive')]
    [string]$Profile = 'Aggressive',

    [ValidateRange(1, 3650)]
    [int]$MinAgeDays = 7,

    [string]$ReportDirectory = (Join-Path (Get-Location) 'local-reports'),

    [string]$PlanPath,

    [string]$ConfirmationToken,

    [switch]$DeepScan,

    [ValidateRange(1, 1048576)]
    [int]$LargeFileMinimumMB = 1024,

    [ValidateRange(5, 3600)]
    [int]$ReviewTimeoutSeconds = 180,

    [string]$TestRoot
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$Script:SchemaVersion = '1.1'
$Script:PolicyVersion = '2026-07-18'
$Script:Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$Script:UnsafeAttributes = [IO.FileAttributes]::ReparsePoint -bor [IO.FileAttributes]::System -bor [IO.FileAttributes]::Offline

function Normalize-Drive {
    param([string]$Value)
    return ($Value.Substring(0, 1).ToUpperInvariant() + ':')
}

function Normalize-Path {
    param([string]$Value)
    return [IO.Path]::GetFullPath($Value).TrimEnd('\')
}

function Test-PathWithinRoot {
    param(
        [string]$Path,
        [string]$Root
    )

    $normalizedPath = Normalize-Path $Path
    $normalizedRoot = Normalize-Path $Root
    if ($normalizedPath.Equals($normalizedRoot, [StringComparison]::OrdinalIgnoreCase)) {
        return $true
    }

    return $normalizedPath.StartsWith($normalizedRoot + '\', [StringComparison]::OrdinalIgnoreCase)
}

function Test-PathOnDrive {
    param(
        [string]$Path,
        [string]$TargetDrive
    )

    $root = [IO.Path]::GetPathRoot((Normalize-Path $Path))
    if ([string]::IsNullOrWhiteSpace($root)) {
        return $false
    }

    return $root.TrimEnd('\').Equals($TargetDrive, [StringComparison]::OrdinalIgnoreCase)
}

function Format-Bytes {
    param([Nullable[Int64]]$Bytes)

    if ($null -eq $Bytes) {
        return 'not measured'
    }

    $value = [double]$Bytes
    foreach ($unit in @('B', 'KiB', 'MiB', 'GiB', 'TiB')) {
        if ($value -lt 1024 -or $unit -eq 'TiB') {
            return ('{0:N2} {1}' -f $value, $unit)
        }
        $value = $value / 1024
    }
}

function Write-Utf8File {
    param(
        [string]$Path,
        [string]$Content
    )

    [IO.File]::WriteAllText($Path, $Content, $Script:Utf8NoBom)
}

function Write-JsonFile {
    param(
        [string]$Path,
        [object]$Value
    )

    Write-Utf8File -Path $Path -Content ($Value | ConvertTo-Json -Depth 10)
}

function Get-FileToken {
    param([string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-StableId {
    param(
        [string]$Prefix,
        [string]$Value
    )

    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($Value.ToLowerInvariant())
        $digest = $sha.ComputeHash($bytes)
        $short = ([BitConverter]::ToString($digest)).Replace('-', '').ToLowerInvariant().Substring(0, 12)
        return ($Prefix + '-' + $short)
    }
    finally {
        $sha.Dispose()
    }
}

function Get-IssueClass {
    param([string]$Reason)

    if ($Reason -like '*denied*' -or $Reason -like '*Unauthorized*') { return 'access denied' }
    if ($Reason -like '*without administrator*') { return 'not elevated' }
    if ($Reason -like '*reparse*') { return 'reparse skipped' }
    if ($Reason -like '*time budget*') { return 'time budget exceeded' }
    return 'other scan issue'
}

function Get-IssueSummary {
    param([object[]]$Issues)

    return @($Issues |
        ForEach-Object {
            [pscustomobject]@{
                Category = $_.Category
                Class = Get-IssueClass -Reason $_.Reason
            }
        } |
        Group-Object Category, Class |
        Sort-Object Count -Descending |
        ForEach-Object {
            [pscustomobject]@{
                Count = $_.Count
                Category = $_.Group[0].Category
                Class = $_.Group[0].Class
            }
        })
}

function Add-ScanIssue {
    param(
        [System.Collections.IList]$Issues,
        [string]$Category,
        [string]$Path,
        [string]$Reason
    )

    [void]$Issues.Add([pscustomobject]@{
        Category = $Category
        Path = $Path
        Reason = $Reason
    })
}

function Get-SafeTreeFiles {
    param(
        [string]$Root,
        [string]$Category,
        [System.Collections.IList]$Issues
    )

    if (-not [IO.Directory]::Exists($Root)) {
        return
    }

    # Get-ChildItem does not follow directory symlinks/junctions unless the
    # caller explicitly requests FollowSymlink. Keep that switch absent and
    # also reject any reparse-point file returned by the provider.
    $scanErrors = @()
    Get-ChildItem -LiteralPath $Root -Force -File -Recurse `
        -ErrorAction SilentlyContinue -ErrorVariable +scanErrors |
        Where-Object { -not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) } |
        ForEach-Object { Write-Output $_ }

    foreach ($scanError in $scanErrors) {
        Add-ScanIssue -Issues $Issues -Category $Category -Path $Root -Reason $scanError.Exception.Message
    }
}

function Measure-SafeTree {
    param(
        [string]$Root,
        [string]$Category,
        [System.Collections.IList]$Issues,
        [int]$TimeoutSeconds
    )

    if (-not [IO.Directory]::Exists($Root)) {
        return [pscustomobject]@{ Files = 0L; Bytes = 0L; Complete = $true; ElapsedMilliseconds = 0L }
    }

    # Review-only measurement deliberately avoids building deletion snapshots.
    # Windows PowerShell does not follow directory symlinks unless explicitly
    # requested; reparse files are also filtered from the measurement.
    $scanErrors = @()
    $count = 0L
    $bytes = 0L
    $complete = $true
    $watch = [Diagnostics.Stopwatch]::StartNew()
    try {
        Get-ChildItem -LiteralPath $Root -Force -File -Recurse `
            -ErrorAction SilentlyContinue -ErrorVariable +scanErrors |
            Where-Object { -not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) } |
            ForEach-Object {
                if ($watch.Elapsed.TotalSeconds -gt $TimeoutSeconds) {
                    throw ('review scan time budget exceeded: {0} seconds' -f $TimeoutSeconds)
                }
                $count++
                $bytes += [Int64]$_.Length
            }
    }
    catch {
        $complete = $false
        Add-ScanIssue -Issues $Issues -Category $Category -Path $Root -Reason $_.Exception.Message
    }
    finally {
        $watch.Stop()
    }

    foreach ($scanError in $scanErrors) {
        $complete = $false
        Add-ScanIssue -Issues $Issues -Category $Category -Path $Root -Reason $scanError.Exception.Message
    }

    return [pscustomobject]@{
        Files = $count
        Bytes = $bytes
        Complete = $complete
        ElapsedMilliseconds = [Int64]$watch.ElapsedMilliseconds
    }
}

function Get-DriveState {
    param([string]$TargetDrive)

    $name = $TargetDrive.Substring(0, 1)
    $driveInfo = Get-PSDrive -Name $name -PSProvider FileSystem -ErrorAction Stop
    return [pscustomobject]@{
        Drive = $TargetDrive
        UsedBytes = [Int64]$driveInfo.Used
        FreeBytes = [Int64]$driveInfo.Free
        CapacityBytes = [Int64]($driveInfo.Used + $driveInfo.Free)
    }
}

function Get-AutoCategoryDefinitions {
    param(
        [string]$TargetDrive,
        [string]$SelectedProfile,
        [int]$SelectedMinAgeDays,
        [string]$FixtureRoot
    )

    $effectiveAge = $SelectedMinAgeDays
    if ($SelectedProfile -eq 'Safe') {
        $effectiveAge = [Math]::Max(30, $SelectedMinAgeDays)
    }

    if (-not [string]::IsNullOrWhiteSpace($FixtureRoot)) {
        return @([pscustomobject]@{
            Id = 'fixture-temp'
            Root = (Normalize-Path (Join-Path $FixtureRoot 'auto'))
            MinAgeDays = $effectiveAge
            Description = 'isolated test temporary files'
            Impact = 'test files only'
        })
    }

    $local = [Environment]::GetFolderPath('LocalApplicationData')
    $definitions = New-Object 'System.Collections.Generic.List[object]'
    $candidates = @(
        [pscustomobject]@{
            Id = 'user-temp'
            Root = [IO.Path]::GetTempPath().TrimEnd('\')
            MinAgeDays = $effectiveAge
            Description = 'current-user temporary files'
            Impact = 'applications may recreate temporary files'
            Profiles = @('Safe', 'Aggressive')
        },
        [pscustomobject]@{
            Id = 'windows-temp'
            Root = (Join-Path $env:SystemRoot 'Temp')
            MinAgeDays = $effectiveAge
            Description = 'Windows temporary files'
            Impact = 'locked or protected files are skipped'
            Profiles = @('Safe', 'Aggressive')
        },
        [pscustomobject]@{
            Id = 'directx-shader-cache'
            Root = (Join-Path $local 'D3DSCache')
            MinAgeDays = $effectiveAge
            Description = 'DirectX shader cache'
            Impact = 'applications rebuild shaders when needed'
            Profiles = @('Aggressive')
        }
    )

    foreach ($candidate in $candidates) {
        if (($candidate.Profiles -contains $SelectedProfile) -and (Test-PathOnDrive -Path $candidate.Root -TargetDrive $TargetDrive)) {
            [void]$definitions.Add([pscustomobject]@{
                Id = $candidate.Id
                Root = (Normalize-Path $candidate.Root)
                MinAgeDays = $candidate.MinAgeDays
                Description = $candidate.Description
                Impact = $candidate.Impact
            })
        }
    }

    return $definitions.ToArray()
}

function Get-ReviewDefinitions {
    param(
        [string]$TargetDrive,
        [bool]$IncludeDeepScan,
        [string]$FixtureRoot
    )

    if (-not [string]::IsNullOrWhiteSpace($FixtureRoot)) {
        return @([pscustomobject]@{
            Id = 'fixture-review'
            Category = 'test review candidate'
            Root = (Normalize-Path (Join-Path $FixtureRoot 'review'))
            Impact = 'requires explicit selection'
            RecommendedAction = 'review files individually'
            ProcessGuard = ''
        })
    }

    $profileHome = [Environment]::GetFolderPath('UserProfile')
    $local = [Environment]::GetFolderPath('LocalApplicationData')
    $roaming = [Environment]::GetFolderPath('ApplicationData')
    $definitions = New-Object 'System.Collections.Generic.List[object]'

    $base = @(
        [pscustomobject]@{
            Id = 'nvidia-dx-cache'
            Category = 'NVIDIA shader cache'
            Root = (Join-Path $local 'NVIDIA\DXCache')
            Impact = 'games and GPU applications may stutter while shaders rebuild'
            RecommendedAction = 'delete only after user approval and when GPU applications are closed'
            ProcessGuard = 'GPU applications'
        },
        [pscustomobject]@{
            Id = 'edge-cache'
            Category = 'Microsoft Edge cache'
            Root = (Join-Path $local 'Microsoft\Edge\User Data\Default\Cache')
            Impact = 'sites may load more slowly once; profile and sign-in data must remain untouched'
            RecommendedAction = 'clear through Edge or delete only this cache root while Edge is closed'
            ProcessGuard = 'msedge'
        },
        [pscustomobject]@{
            Id = 'chrome-cache'
            Category = 'Google Chrome cache'
            Root = (Join-Path $local 'Google\Chrome\User Data\Default\Cache')
            Impact = 'sites may load more slowly once; profile and sign-in data must remain untouched'
            RecommendedAction = 'clear through Chrome or delete only this cache root while Chrome is closed'
            ProcessGuard = 'chrome'
        },
        [pscustomobject]@{
            Id = 'vscode-cache'
            Category = 'Visual Studio Code cache'
            Root = (Join-Path $roaming 'Code\Cache')
            Impact = 'Code recreates cached data; close Code before clearing'
            RecommendedAction = 'delete only this cache root after user approval'
            ProcessGuard = 'code'
        },
        [pscustomobject]@{
            Id = 'crash-dumps'
            Category = 'application crash dumps'
            Root = (Join-Path $local 'CrashDumps')
            Impact = 'removes local diagnostic evidence for past crashes'
            RecommendedAction = 'retain if debugging; otherwise delete selected dumps'
            ProcessGuard = ''
        },
        [pscustomobject]@{
            Id = 'system-wer'
            Category = 'Windows Error Reporting data'
            Root = (Join-Path $env:ProgramData 'Microsoft\Windows\WER')
            Impact = 'removes diagnostic reports that may help troubleshoot failures'
            RecommendedAction = 'retain if debugging; otherwise use Windows cleanup tools'
            ProcessGuard = ''
        }
    )

    foreach ($item in $base) {
        if (Test-PathOnDrive -Path $item.Root -TargetDrive $TargetDrive) {
            [void]$definitions.Add($item)
        }
    }

    if ($IncludeDeepScan) {
        $deep = @(
            [pscustomobject]@{
                Id = 'pip-cache'
                Category = 'pip download/build cache'
                Root = (Join-Path $local 'pip\Cache')
                Impact = 'future Python installs may need to download or rebuild packages'
                RecommendedAction = 'py -m pip cache purge'
                ProcessGuard = 'python or pip'
            },
            [pscustomobject]@{
                Id = 'uv-cache'
                Category = 'uv dependency cache'
                Root = (Join-Path $local 'uv\cache')
                Impact = 'future uv operations may re-download or rebuild; use uv, never delete the cache directly'
                RecommendedAction = 'uv cache clean'
                ProcessGuard = 'uv'
            },
            [pscustomobject]@{
                Id = 'npm-cache'
                Category = 'npm content cache'
                Root = (Join-Path $local 'npm-cache')
                Impact = 'future npm operations may download packages again'
                RecommendedAction = 'npm cache clean --force'
                ProcessGuard = 'node or npm'
            },
            [pscustomobject]@{
                Id = 'nuget-packages'
                Category = 'NuGet global packages cache'
                Root = (Join-Path $profileHome '.nuget\packages')
                Impact = 'projects may need package restore and offline builds may fail'
                RecommendedAction = 'dotnet nuget locals global-packages --clear'
                ProcessGuard = 'dotnet'
            },
            [pscustomobject]@{
                Id = 'gradle-cache'
                Category = 'Gradle cache'
                Root = (Join-Path $profileHome '.gradle\caches')
                Impact = 'future builds may download dependencies again; offline builds may fail'
                RecommendedAction = 'review with Gradle tooling; do not hard-delete active caches'
                ProcessGuard = 'java or gradle'
            },
            [pscustomobject]@{
                Id = 'maven-repository'
                Category = 'Maven local repository'
                Root = (Join-Path $profileHome '.m2\repository')
                Impact = 'future builds may download dependencies again; locally installed artifacts may be unique'
                RecommendedAction = 'review artifact provenance before any deletion'
                ProcessGuard = 'java or mvn'
            },
            [pscustomobject]@{
                Id = 'cargo-registry-cache'
                Category = 'Cargo registry cache'
                Root = (Join-Path $profileHome '.cargo\registry\cache')
                Impact = 'future Rust builds may download crates again'
                RecommendedAction = 'use Cargo-aware cleanup after user approval'
                ProcessGuard = 'cargo or rustc'
            },
            [pscustomobject]@{
                Id = 'conda-package-cache'
                Category = 'Conda package cache'
                Root = (Join-Path $profileHome '.conda\pkgs')
                Impact = 'incorrect force cleanup can break environments that link to package caches'
                RecommendedAction = 'conda clean --packages --tarballs after reviewing the Conda warning'
                ProcessGuard = 'conda or python'
            }
        )

        foreach ($item in $deep) {
            if (Test-PathOnDrive -Path $item.Root -TargetDrive $TargetDrive) {
                [void]$definitions.Add($item)
            }
        }
    }

    return $definitions.ToArray()
}

function Get-ReviewInventory {
    param(
        [string]$TargetDrive,
        [bool]$IncludeDeepScan,
        [int]$LargeMinimumMB,
        [int]$ReviewTimeout,
        [string]$FixtureRoot,
        [System.Collections.IList]$Issues
    )

    $review = New-Object 'System.Collections.Generic.List[object]'
    $isAdministrator = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    foreach ($definition in (Get-ReviewDefinitions -TargetDrive $TargetDrive -IncludeDeepScan $IncludeDeepScan -FixtureRoot $FixtureRoot)) {
        if (-not [IO.Directory]::Exists($definition.Root)) {
            continue
        }

        if ($definition.Id -eq 'system-wer' -and -not $isAdministrator) {
            $measurement = [pscustomobject]@{ Files = 0L; Bytes = 0L; Complete = $false; ElapsedMilliseconds = 0L }
            Add-ScanIssue -Issues $Issues -Category $definition.Id -Path $definition.Root -Reason 'protected review root skipped without administrator rights; elevation was not requested'
        }
        else {
            $measurement = Measure-SafeTree -Root $definition.Root -Category $definition.Id -Issues $Issues -TimeoutSeconds $ReviewTimeout
        }
        $running = $false
        if (-not [string]::IsNullOrWhiteSpace($definition.ProcessGuard)) {
            $names = $definition.ProcessGuard -split '\s+or\s+'
            foreach ($name in $names) {
                if (Get-Process -Name $name.Trim() -ErrorAction SilentlyContinue) {
                    $running = $true
                    break
                }
            }
        }

        [void]$review.Add([pscustomobject]@{
            Id = $definition.Id
            Kind = 'category'
            Category = $definition.Category
            Path = (Normalize-Path $definition.Root)
            Files = [Int64]$measurement.Files
            Bytes = [Int64]$measurement.Bytes
            LastWriteTimeUtc = $null
            Impact = $definition.Impact
            RecommendedAction = $definition.RecommendedAction
            ProcessRunning = $running
            MeasurementComplete = [bool]$measurement.Complete
            ElapsedMilliseconds = [Int64]$measurement.ElapsedMilliseconds
        })
    }

    if (-not [string]::IsNullOrWhiteSpace($FixtureRoot)) {
        return $review.ToArray()
    }

    $profileHome = [Environment]::GetFolderPath('UserProfile')
    $userRoots = @(
        (Join-Path $profileHome 'Downloads'),
        [Environment]::GetFolderPath('Desktop')
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and (Test-PathOnDrive -Path $_ -TargetDrive $TargetDrive) }

    $installerExtensions = @('.exe', '.msi', '.msix', '.appx', '.appxbundle', '.iso', '.img', '.zip', '.7z', '.rar', '.cab', '.whl', '.gz', '.bz2', '.xz')
    $installerCutoff = [DateTime]::UtcNow.AddDays(-30)
    foreach ($root in $userRoots) {
        foreach ($file in (Get-SafeTreeFiles -Root $root -Category 'old-installers' -Issues $Issues)) {
            if ($file.Length -ge 50MB -and $file.LastWriteTimeUtc -lt $installerCutoff -and ($installerExtensions -contains $file.Extension.ToLowerInvariant())) {
                [void]$review.Add([pscustomobject]@{
                    Id = Get-StableId -Prefix 'file' -Value $file.FullName
                    Kind = 'file'
                    Category = 'old installer or archive'
                    Path = $file.FullName
                    Files = 1
                    Bytes = [Int64]$file.Length
                    LastWriteTimeUtc = $file.LastWriteTimeUtc.ToString('o')
                    Impact = 'content may be unique; verify it is reproducible or backed up'
                    RecommendedAction = 'delete only this unchanged file after explicit approval'
                    ProcessRunning = $false
                    MeasurementComplete = $true
                    ElapsedMilliseconds = 0L
                })
            }
        }
    }

    if ($IncludeDeepScan) {
        $largeRoots = @(
            (Join-Path $profileHome 'Downloads'),
            [Environment]::GetFolderPath('Desktop'),
            [Environment]::GetFolderPath('MyDocuments'),
            [Environment]::GetFolderPath('MyVideos')
        ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and (Test-PathOnDrive -Path $_ -TargetDrive $TargetDrive) } | Select-Object -Unique

        $large = New-Object 'System.Collections.Generic.List[object]'
        foreach ($root in $largeRoots) {
            foreach ($file in (Get-SafeTreeFiles -Root $root -Category 'large-user-files' -Issues $Issues)) {
                if ($file.Length -ge ([Int64]$LargeMinimumMB * 1MB)) {
                    [void]$large.Add($file)
                }
            }
        }

        foreach ($file in ($large | Sort-Object Length -Descending | Select-Object -First 50)) {
            [void]$review.Add([pscustomobject]@{
                Id = Get-StableId -Prefix 'large' -Value $file.FullName
                Kind = 'file'
                Category = 'large user file'
                Path = $file.FullName
                Files = 1
                Bytes = [Int64]$file.Length
                LastWriteTimeUtc = $file.LastWriteTimeUtc.ToString('o')
                Impact = 'user content; never delete without explicit item-level approval'
                RecommendedAction = 'open, identify ownership, back up if needed, then decide'
                ProcessRunning = $false
                MeasurementComplete = $true
                ElapsedMilliseconds = 0L
            })
        }
    }

    return $review.ToArray()
}

function Get-ProtectedInventory {
    param([string]$TargetDrive)

    $items = New-Object 'System.Collections.Generic.List[object]'
    $windowsRoot = if ((Normalize-Drive $env:SystemDrive) -eq $TargetDrive) { $env:SystemRoot } else { Join-Path ($TargetDrive + '\') 'Windows' }
    $definitions = @(
        [pscustomobject]@{ Id = 'windows-component-store'; Path = (Join-Path $windowsRoot 'WinSxS'); Reason = 'never delete directly; analyze with DISM and use supported servicing only' },
        [pscustomobject]@{ Id = 'windows-installer-cache'; Path = (Join-Path $windowsRoot 'Installer'); Reason = 'required for repair, update, and uninstall operations' },
        [pscustomobject]@{ Id = 'windows-update-store'; Path = (Join-Path $windowsRoot 'SoftwareDistribution'); Reason = 'never hard-delete; use Windows cleanup and update servicing' },
        [pscustomobject]@{ Id = 'previous-windows'; Path = (Join-Path ($TargetDrive + '\') 'Windows.old'); Reason = 'deletion removes the ability to roll back the Windows upgrade' },
        [pscustomobject]@{ Id = 'hibernation-file'; Path = (Join-Path ($TargetDrive + '\') 'hiberfil.sys'); Reason = 'managed by powercfg; disabling it changes hibernate, hybrid sleep, and possibly fast startup' },
        [pscustomobject]@{ Id = 'paging-file'; Path = (Join-Path ($TargetDrive + '\') 'pagefile.sys'); Reason = 'operating-system managed virtual memory' },
        [pscustomobject]@{ Id = 'restore-points'; Path = (Join-Path ($TargetDrive + '\') 'System Volume Information'); Reason = 'contains restore and shadow-copy data; never delete as ordinary files' }
    )

    foreach ($definition in $definitions) {
        $exists = [IO.File]::Exists($definition.Path) -or [IO.Directory]::Exists($definition.Path)
        $bytes = $null
        if ([IO.File]::Exists($definition.Path)) {
            try {
                $bytes = [Int64](Get-Item -LiteralPath $definition.Path -Force -ErrorAction Stop).Length
            }
            catch {
                $bytes = $null
            }
        }

        [void]$items.Add([pscustomobject]@{
            Id = $definition.Id
            Path = $definition.Path
            Exists = $exists
            Bytes = $bytes
            Policy = 'never directly delete'
            Reason = $definition.Reason
        })
    }

    return $items.ToArray()
}

function Escape-MarkdownCell {
    param([object]$Value)
    if ($null -eq $Value) { return '' }
    return ([string]$Value).Replace('|', '\|').Replace("`r", ' ').Replace("`n", ' ')
}

function New-AuditMarkdown {
    param([object]$Audit)

    $builder = New-Object Text.StringBuilder
    [void]$builder.AppendLine('# Safe Space Cleaner audit')
    [void]$builder.AppendLine()
    [void]$builder.AppendLine(('- Run: `{0}`' -f $Audit.RunId))
    [void]$builder.AppendLine(('- Drive: `{0}`' -f $Audit.DriveState.Drive))
    [void]$builder.AppendLine(('- Profile: `{0}`' -f $Audit.Profile))
    [void]$builder.AppendLine(('- Created: `{0}`' -f $Audit.CreatedAtUtc))
    [void]$builder.AppendLine(('- Policy: `{0}`; schema: `{1}`' -f $Audit.PolicyVersion, $Audit.SchemaVersion))
    [void]$builder.AppendLine(('- Scan time: {0:N1} seconds; administrator: `{1}`' -f ([double]$Audit.ElapsedMilliseconds / 1000), $Audit.SystemContext.IsAdministrator))
    [void]$builder.AppendLine(('- Free space before: {0}' -f (Format-Bytes $Audit.DriveState.FreeBytes)))
    [void]$builder.AppendLine()
    [void]$builder.AppendLine('## Verified automatic cleanup plan')
    [void]$builder.AppendLine()
    [void]$builder.AppendLine(('{0:N0} unchanged, age-qualified files can reclaim {1}.' -f $Audit.AutoSummary.Files, (Format-Bytes $Audit.AutoSummary.Bytes)))
    [void]$builder.AppendLine()
    [void]$builder.AppendLine('| Category | Files | Reclaimable | Root | Impact |')
    [void]$builder.AppendLine('| --- | ---: | ---: | --- | --- |')
    foreach ($row in $Audit.AutoCategories) {
        [void]$builder.AppendLine(('| {0} | {1:N0} | {2} | `{3}` | {4} |' -f (Escape-MarkdownCell $row.Id), $row.Files, (Format-Bytes $row.Bytes), (Escape-MarkdownCell $row.Root), (Escape-MarkdownCell $row.Impact)))
    }
    [void]$builder.AppendLine()
    [void]$builder.AppendLine('The exact planned file list is stored in the adjacent plan JSON and audit CSV. Clean mode revalidates every path, root, size, timestamp, age, and attribute before deletion.')
    [void]$builder.AppendLine()
    [void]$builder.AppendLine('## Review-required candidates')
    [void]$builder.AppendLine()
    if (@($Audit.ReviewCandidates).Count -eq 0) {
        [void]$builder.AppendLine('No review candidates were found.')
    }
    else {
        [void]$builder.AppendLine('| ID | Candidate | Size | Complete | Time | Path | Running | Recommended action | Impact |')
        [void]$builder.AppendLine('| --- | --- | ---: | --- | ---: | --- | --- | --- | --- |')
        foreach ($row in ($Audit.ReviewCandidates | Sort-Object Bytes -Descending)) {
            [void]$builder.AppendLine(('| `{0}` | {1} | {2} | {3} | {4:N1}s | `{5}` | {6} | `{7}` | {8} |' -f (Escape-MarkdownCell $row.Id), (Escape-MarkdownCell $row.Category), (Format-Bytes $row.Bytes), $row.MeasurementComplete, ([double]$row.ElapsedMilliseconds / 1000), (Escape-MarkdownCell $row.Path), $row.ProcessRunning, (Escape-MarkdownCell $row.RecommendedAction), (Escape-MarkdownCell $row.Impact)))
        }
    }
    [void]$builder.AppendLine()
    [void]$builder.AppendLine('Review candidates are not part of the automatic deletion plan. Select them explicitly after checking ownership, reproducibility, active processes, and the stated impact.')
    [void]$builder.AppendLine()
    [void]$builder.AppendLine('## Protected locations')
    [void]$builder.AppendLine()
    [void]$builder.AppendLine('| Location | Exists | Size | Policy | Reason |')
    [void]$builder.AppendLine('| --- | --- | ---: | --- | --- |')
    foreach ($row in $Audit.Protected) {
        [void]$builder.AppendLine(('| `{0}` | {1} | {2} | {3} | {4} |' -f (Escape-MarkdownCell $row.Path), $row.Exists, (Format-Bytes $row.Bytes), (Escape-MarkdownCell $row.Policy), (Escape-MarkdownCell $row.Reason)))
    }
    [void]$builder.AppendLine()
    [void]$builder.AppendLine('## Scan issues')
    [void]$builder.AppendLine()
    if (@($Audit.ScanIssues).Count -eq 0) {
        [void]$builder.AppendLine('No scan issues were recorded.')
    }
    else {
        [void]$builder.AppendLine('| Category | Class | Count |')
        [void]$builder.AppendLine('| --- | --- | ---: |')
        foreach ($row in $Audit.ScanIssueSummary) {
            [void]$builder.AppendLine(('| {0} | {1} | {2:N0} |' -f (Escape-MarkdownCell $row.Category), (Escape-MarkdownCell $row.Class), $row.Count))
        }
        [void]$builder.AppendLine()
        [void]$builder.AppendLine('Exact issue paths are stored in the adjacent scan-issues CSV and audit JSON. Access-denied review roots remain unapproved and are never force-scanned.')
    }

    return $builder.ToString()
}

function Invoke-Audit {
    param(
        [string]$TargetDrive,
        [string]$SelectedProfile,
        [int]$SelectedMinAgeDays,
        [string]$OutputDirectory,
        [bool]$IncludeDeepScan,
        [int]$LargeMinimumMB,
        [int]$ReviewTimeout,
        [string]$FixtureRoot
    )

    if (-not [string]::IsNullOrWhiteSpace($FixtureRoot)) {
        if ($env:SAFE_SPACE_CLEANER_TESTING -ne '1') {
            throw 'TestRoot is disabled outside the isolated test harness.'
        }
        $FixtureRoot = Normalize-Path $FixtureRoot
        if (-not (Test-PathOnDrive -Path $FixtureRoot -TargetDrive $TargetDrive)) {
            throw 'TestRoot must be on the selected drive.'
        }
    }

    $auditWatch = [Diagnostics.Stopwatch]::StartNew()
    $null = New-Item -ItemType Directory -Path $OutputDirectory -Force
    $runId = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ') + '-' + ([Guid]::NewGuid().ToString('N').Substring(0, 8))
    $createdAt = [DateTime]::UtcNow
    $issues = New-Object 'System.Collections.Generic.List[object]'
    $planItems = New-Object 'System.Collections.Generic.List[object]'
    $categorySummaries = New-Object 'System.Collections.Generic.List[object]'
    $categories = @(Get-AutoCategoryDefinitions -TargetDrive $TargetDrive -SelectedProfile $SelectedProfile -SelectedMinAgeDays $SelectedMinAgeDays -FixtureRoot $FixtureRoot)

    foreach ($category in $categories) {
        $cutoff = $createdAt.AddDays(-1 * [int]$category.MinAgeDays)
        $categoryFiles = 0L
        $categoryBytes = 0L
        foreach ($file in (Get-SafeTreeFiles -Root $category.Root -Category $category.Id -Issues $issues)) {
            if ($file.LastWriteTimeUtc -ge $cutoff) {
                continue
            }
            if ($file.Attributes -band $Script:UnsafeAttributes) {
                Add-ScanIssue -Issues $issues -Category $category.Id -Path $file.FullName -Reason 'protected, offline, or reparse attribute skipped'
                continue
            }
            if (-not (Test-PathWithinRoot -Path $file.FullName -Root $category.Root)) {
                Add-ScanIssue -Issues $issues -Category $category.Id -Path $file.FullName -Reason 'path escaped the approved root'
                continue
            }

            [void]$planItems.Add([pscustomobject]@{
                Category = $category.Id
                Path = $file.FullName
                Length = [Int64]$file.Length
                LastWriteTimeUtcTicks = [Int64]$file.LastWriteTimeUtc.Ticks
                CutoffUtcTicks = [Int64]$cutoff.Ticks
            })
            $categoryFiles++
            $categoryBytes += [Int64]$file.Length
        }

        [void]$categorySummaries.Add([pscustomobject]@{
            Id = $category.Id
            Root = $category.Root
            Files = $categoryFiles
            Bytes = $categoryBytes
            MinAgeDays = $category.MinAgeDays
            Description = $category.Description
            Impact = $category.Impact
        })
    }

    $review = @(Get-ReviewInventory -TargetDrive $TargetDrive -IncludeDeepScan $IncludeDeepScan -LargeMinimumMB $LargeMinimumMB -ReviewTimeout $ReviewTimeout -FixtureRoot $FixtureRoot -Issues $issues)
    $protected = @(Get-ProtectedInventory -TargetDrive $TargetDrive)
    $driveState = Get-DriveState -TargetDrive $TargetDrive
    $totalBytes = [Int64](($categorySummaries | Measure-Object Bytes -Sum).Sum)
    $totalFiles = [Int64](($categorySummaries | Measure-Object Files -Sum).Sum)
    $issueSummary = @(Get-IssueSummary -Issues $issues.ToArray())
    $isAdministrator = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

    $plan = [pscustomobject]@{
        SchemaVersion = $Script:SchemaVersion
        PolicyVersion = $Script:PolicyVersion
        RunId = $runId
        CreatedAtUtc = $createdAt.ToString('o')
        Drive = $TargetDrive
        Profile = $SelectedProfile
        MinAgeDays = $SelectedMinAgeDays
        TestMode = (-not [string]::IsNullOrWhiteSpace($FixtureRoot))
        CategoryRoots = @($categories | Select-Object Id, Root, MinAgeDays)
        Items = $planItems.ToArray()
    }

    $audit = [pscustomobject]@{
        SchemaVersion = $Script:SchemaVersion
        PolicyVersion = $Script:PolicyVersion
        RunId = $runId
        CreatedAtUtc = $createdAt.ToString('o')
        DriveState = $driveState
        Profile = $SelectedProfile
        DeepScan = $IncludeDeepScan
        ReviewTimeoutSeconds = $ReviewTimeout
        SystemContext = [pscustomobject]@{
            OSVersion = [Environment]::OSVersion.VersionString
            PowerShellVersion = $PSVersionTable.PSVersion.ToString()
            IsAdministrator = $isAdministrator
        }
        AutoSummary = [pscustomobject]@{ Files = $totalFiles; Bytes = $totalBytes }
        AutoCategories = $categorySummaries.ToArray()
        ReviewCandidates = $review
        Protected = $protected
        ScanIssues = $issues.ToArray()
        ScanIssueSummary = $issueSummary
        ElapsedMilliseconds = 0L
    }

    $auditWatch.Stop()
    $audit.ElapsedMilliseconds = [Int64]$auditWatch.ElapsedMilliseconds

    $planFile = Join-Path $OutputDirectory ('plan-' + $runId + '.json')
    $auditJson = Join-Path $OutputDirectory ('audit-' + $runId + '.json')
    $auditMarkdown = Join-Path $OutputDirectory ('audit-' + $runId + '.md')
    $auditCsv = Join-Path $OutputDirectory ('audit-files-' + $runId + '.csv')
    $reviewCsv = Join-Path $OutputDirectory ('review-candidates-' + $runId + '.csv')
    $issueCsv = Join-Path $OutputDirectory ('scan-issues-' + $runId + '.csv')

    Write-Utf8File -Path $planFile -Content ($plan | ConvertTo-Json -Depth 10 -Compress)
    Write-JsonFile -Path $auditJson -Value $audit
    Write-Utf8File -Path $auditMarkdown -Content (New-AuditMarkdown -Audit $audit)
    $planItems.ToArray() | Export-Csv -LiteralPath $auditCsv -Encoding UTF8 -NoTypeInformation
    $review | Export-Csv -LiteralPath $reviewCsv -Encoding UTF8 -NoTypeInformation
    $issues.ToArray() | Export-Csv -LiteralPath $issueCsv -Encoding UTF8 -NoTypeInformation
    $token = Get-FileToken -Path $planFile

    Write-Host ('Audit complete: {0:N0} files, {1} verified for automatic cleanup.' -f $totalFiles, (Format-Bytes $totalBytes))
    Write-Host ('Review candidates: {0}; scan issues: {1}.' -f $review.Count, $issues.Count)
    Write-Host ('Plan: {0}' -f $planFile)
    Write-Host ('Confirmation token: {0}' -f $token)

    return [pscustomobject]@{
        Mode = 'Audit'
        RunId = $runId
        PlanPath = $planFile
        ConfirmationToken = $token
        AuditJsonPath = $auditJson
        AuditMarkdownPath = $auditMarkdown
        AuditCsvPath = $auditCsv
        ReviewCsvPath = $reviewCsv
        ScanIssueCsvPath = $issueCsv
        Files = $totalFiles
        Bytes = $totalBytes
        ReviewCandidates = $review.Count
        ScanIssues = $issues.Count
        ElapsedMilliseconds = [Int64]$auditWatch.ElapsedMilliseconds
    }
}

function New-CleanMarkdown {
    param([object]$Report)

    $builder = New-Object Text.StringBuilder
    [void]$builder.AppendLine('# Safe Space Cleaner cleanup report')
    [void]$builder.AppendLine()
    [void]$builder.AppendLine(('- Source plan: `{0}`' -f $Report.PlanPath))
    [void]$builder.AppendLine(('- Started: `{0}`' -f $Report.StartedAtUtc))
    [void]$builder.AppendLine(('- Finished: `{0}`' -f $Report.FinishedAtUtc))
    [void]$builder.AppendLine(('- Deleted: {0:N0} files, {1}' -f $Report.Summary.DeletedFiles, (Format-Bytes $Report.Summary.DeletedBytes)))
    [void]$builder.AppendLine(('- Free space before: {0}' -f (Format-Bytes $Report.DriveBefore.FreeBytes)))
    [void]$builder.AppendLine(('- Free space after: {0}' -f (Format-Bytes $Report.DriveAfter.FreeBytes)))
    [void]$builder.AppendLine(('- Measured free-space change: {0}' -f (Format-Bytes ([Int64]$Report.Summary.FreeSpaceChangeBytes))))
    [void]$builder.AppendLine()
    [void]$builder.AppendLine('## Status summary')
    [void]$builder.AppendLine()
    [void]$builder.AppendLine('| Status | Files | Bytes |')
    [void]$builder.AppendLine('| --- | ---: | ---: |')
    foreach ($row in $Report.StatusSummary) {
        [void]$builder.AppendLine(('| {0} | {1:N0} | {2} |' -f (Escape-MarkdownCell $row.Status), $row.Files, (Format-Bytes $row.Bytes)))
    }
    [void]$builder.AppendLine()
    [void]$builder.AppendLine('The adjacent cleanup CSV and JSON contain one record for every planned file, including skipped and failed items. Review candidates and protected locations were not touched.')
    return $builder.ToString()
}

function Invoke-Clean {
    param(
        [string]$TargetDrive,
        [string]$SelectedPlanPath,
        [string]$Token,
        [string]$OutputDirectory,
        [string]$FixtureRoot
    )

    if ([string]::IsNullOrWhiteSpace($SelectedPlanPath) -or -not [IO.File]::Exists($SelectedPlanPath)) {
        throw 'Clean mode requires an existing PlanPath.'
    }
    if ([string]::IsNullOrWhiteSpace($Token)) {
        throw 'Clean mode requires the full confirmation token from audit mode.'
    }

    $actualToken = Get-FileToken -Path $SelectedPlanPath
    if (-not $actualToken.Equals($Token.Trim(), [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Confirmation token mismatch. The plan may have changed; run a new audit.'
    }

    $plan = Get-Content -Raw -Encoding UTF8 -LiteralPath $SelectedPlanPath | ConvertFrom-Json
    if ($plan.SchemaVersion -ne $Script:SchemaVersion) {
        throw 'Unsupported plan schema.'
    }
    if ((Normalize-Drive $plan.Drive) -ne $TargetDrive) {
        throw 'The plan drive does not match the selected drive.'
    }
    if ([bool]$plan.TestMode -and [string]::IsNullOrWhiteSpace($FixtureRoot)) {
        throw 'A test plan can only run with the original TestRoot.'
    }
    if (-not [bool]$plan.TestMode -and -not [string]::IsNullOrWhiteSpace($FixtureRoot)) {
        throw 'A production plan cannot run in test mode.'
    }
    if (-not [string]::IsNullOrWhiteSpace($FixtureRoot) -and $env:SAFE_SPACE_CLEANER_TESTING -ne '1') {
        throw 'TestRoot is disabled outside the isolated test harness.'
    }

    $currentDefinitions = @(Get-AutoCategoryDefinitions -TargetDrive $TargetDrive -SelectedProfile $plan.Profile -SelectedMinAgeDays ([int]$plan.MinAgeDays) -FixtureRoot $FixtureRoot)
    $rootMap = @{}
    foreach ($definition in $currentDefinitions) {
        $rootMap[$definition.Id] = Normalize-Path $definition.Root
    }
    $planRootMap = @{}
    foreach ($plannedRoot in @($plan.CategoryRoots)) {
        $categoryId = [string]$plannedRoot.Id
        if ($planRootMap.ContainsKey($categoryId)) {
            throw ('Duplicate category root in plan: {0}' -f $categoryId)
        }
        if (-not $rootMap.ContainsKey($categoryId)) {
            throw ('Planned category is no longer approved: {0}' -f $categoryId)
        }
        $normalizedPlannedRoot = Normalize-Path ([string]$plannedRoot.Root)
        if (-not $normalizedPlannedRoot.Equals($rootMap[$categoryId], [StringComparison]::OrdinalIgnoreCase)) {
            throw ('Planned root differs from the current approved root: {0}' -f $categoryId)
        }
        $planRootMap[$categoryId] = $normalizedPlannedRoot
    }

    $null = New-Item -ItemType Directory -Path $OutputDirectory -Force
    $started = [DateTime]::UtcNow
    $driveBefore = Get-DriveState -TargetDrive $TargetDrive
    $actions = New-Object 'System.Collections.Generic.List[object]'

    foreach ($item in @($plan.Items)) {
        $status = 'SkippedValidation'
        $reason = ''
        $deletedBytes = 0L

        try {
            if (-not $planRootMap.ContainsKey([string]$item.Category)) {
                throw 'category is no longer approved'
            }
            $approvedRoot = $planRootMap[[string]$item.Category]
            if (-not (Test-PathWithinRoot -Path ([string]$item.Path) -Root $approvedRoot)) {
                throw 'path is outside the approved root'
            }
            if (-not (Test-PathOnDrive -Path ([string]$item.Path) -TargetDrive $TargetDrive)) {
                throw 'path is on a different drive'
            }
            if (-not [IO.File]::Exists([string]$item.Path)) {
                $status = 'SkippedMissing'
                $reason = 'file no longer exists'
            }
            else {
                $file = Get-Item -LiteralPath ([string]$item.Path) -Force -ErrorAction Stop
                if ($file.PSIsContainer) {
                    throw 'planned path is now a directory'
                }
                if ($file.Attributes -band $Script:UnsafeAttributes) {
                    throw 'file has protected, offline, or reparse attributes'
                }
                if ([Int64]$file.Length -ne [Int64]$item.Length) {
                    $status = 'SkippedChanged'
                    $reason = 'file size changed after audit'
                }
                elseif ([Int64]$file.LastWriteTimeUtc.Ticks -ne [Int64]$item.LastWriteTimeUtcTicks) {
                    $status = 'SkippedChanged'
                    $reason = 'file timestamp changed after audit'
                }
                elseif ([Int64]$file.LastWriteTimeUtc.Ticks -ge [Int64]$item.CutoffUtcTicks) {
                    $status = 'SkippedChanged'
                    $reason = 'file no longer satisfies the age rule'
                }
                else {
                    Remove-Item -LiteralPath $file.FullName -Force -ErrorAction Stop
                    $status = 'Deleted'
                    $reason = 'verified plan item deleted'
                    $deletedBytes = [Int64]$item.Length
                }
            }
        }
        catch {
            if ($status -eq 'SkippedValidation') {
                $status = 'Failed'
            }
            $reason = $_.Exception.Message
        }

        [void]$actions.Add([pscustomobject]@{
            Category = [string]$item.Category
            Path = [string]$item.Path
            PlannedBytes = [Int64]$item.Length
            Status = $status
            DeletedBytes = $deletedBytes
            Reason = $reason
        })
    }

    $driveAfter = Get-DriveState -TargetDrive $TargetDrive
    $finished = [DateTime]::UtcNow
    $deletedActions = @($actions | Where-Object { $_.Status -eq 'Deleted' })
    $deletedBytesTotal = [Int64](($deletedActions | Measure-Object DeletedBytes -Sum).Sum)
    $statusSummary = @($actions | Group-Object Status | ForEach-Object {
        [pscustomobject]@{
            Status = $_.Name
            Files = $_.Count
            Bytes = [Int64](($_.Group | Measure-Object PlannedBytes -Sum).Sum)
        }
    })

    $report = [pscustomobject]@{
        SchemaVersion = $Script:SchemaVersion
        RunId = $plan.RunId
        PlanPath = (Normalize-Path $SelectedPlanPath)
        PlanToken = $actualToken
        StartedAtUtc = $started.ToString('o')
        FinishedAtUtc = $finished.ToString('o')
        DriveBefore = $driveBefore
        DriveAfter = $driveAfter
        Summary = [pscustomobject]@{
            PlannedFiles = @($plan.Items).Count
            DeletedFiles = $deletedActions.Count
            DeletedBytes = $deletedBytesTotal
            FreeSpaceChangeBytes = [Int64]($driveAfter.FreeBytes - $driveBefore.FreeBytes)
        }
        StatusSummary = $statusSummary
        Actions = $actions.ToArray()
    }

    $baseName = 'cleanup-' + $plan.RunId
    $jsonPath = Join-Path $OutputDirectory ($baseName + '.json')
    $markdownPath = Join-Path $OutputDirectory ($baseName + '.md')
    $csvPath = Join-Path $OutputDirectory ($baseName + '.csv')
    Write-JsonFile -Path $jsonPath -Value $report
    Write-Utf8File -Path $markdownPath -Content (New-CleanMarkdown -Report $report)
    $actions.ToArray() | Export-Csv -LiteralPath $csvPath -Encoding UTF8 -NoTypeInformation

    Write-Host ('Cleanup complete: {0:N0} files deleted; {1} planned bytes reclaimed.' -f $deletedActions.Count, (Format-Bytes $deletedBytesTotal))
    Write-Host ('Measured free-space change: {0}.' -f (Format-Bytes ([Int64]($driveAfter.FreeBytes - $driveBefore.FreeBytes))))
    Write-Host ('Report: {0}' -f $markdownPath)

    return [pscustomobject]@{
        Mode = 'Clean'
        RunId = $plan.RunId
        DeletedFiles = $deletedActions.Count
        DeletedBytes = $deletedBytesTotal
        FreeSpaceChangeBytes = [Int64]($driveAfter.FreeBytes - $driveBefore.FreeBytes)
        ReportJsonPath = $jsonPath
        ReportMarkdownPath = $markdownPath
        ReportCsvPath = $csvPath
    }
}

$targetDrive = Normalize-Drive $Drive

switch ($Mode) {
    'Audit' {
        Invoke-Audit -TargetDrive $targetDrive -SelectedProfile $Profile -SelectedMinAgeDays $MinAgeDays -OutputDirectory $ReportDirectory -IncludeDeepScan ([bool]$DeepScan) -LargeMinimumMB $LargeFileMinimumMB -ReviewTimeout $ReviewTimeoutSeconds -FixtureRoot $TestRoot
    }
    'Clean' {
        Invoke-Clean -TargetDrive $targetDrive -SelectedPlanPath $PlanPath -Token $ConfirmationToken -OutputDirectory $ReportDirectory -FixtureRoot $TestRoot
    }
    'Interactive' {
        $auditResult = Invoke-Audit -TargetDrive $targetDrive -SelectedProfile $Profile -SelectedMinAgeDays $MinAgeDays -OutputDirectory $ReportDirectory -IncludeDeepScan ([bool]$DeepScan) -LargeMinimumMB $LargeFileMinimumMB -ReviewTimeout $ReviewTimeoutSeconds -FixtureRoot $TestRoot
        Write-Host ''
        Write-Host 'Review the Markdown report before continuing. Review-required candidates will not be deleted.'
        $prefix = $auditResult.ConfirmationToken.Substring(0, 12)
        $answer = Read-Host ('Type CLEAN ' + $prefix + ' to execute only the verified automatic plan')
        if ($answer -ceq ('CLEAN ' + $prefix)) {
            Invoke-Clean -TargetDrive $targetDrive -SelectedPlanPath $auditResult.PlanPath -Token $auditResult.ConfirmationToken -OutputDirectory $ReportDirectory -FixtureRoot $TestRoot
        }
        else {
            Write-Host 'Cleanup cancelled. The audit report remains available.'
            $auditResult
        }
    }
}
