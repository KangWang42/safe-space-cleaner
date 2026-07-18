[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Path
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

if (-not [IO.File]::Exists($Path)) {
    throw "Report does not exist: $Path"
}

$document = Get-Content -Raw -Encoding UTF8 -LiteralPath $Path | ConvertFrom-Json
$warnings = New-Object 'System.Collections.Generic.List[string]'
$errors = New-Object 'System.Collections.Generic.List[string]'

if ($document.PSObject.Properties.Name -contains 'AutoSummary') {
    $categoryFiles = [Int64](($document.AutoCategories | Measure-Object Files -Sum).Sum)
    $categoryBytes = [Int64](($document.AutoCategories | Measure-Object Bytes -Sum).Sum)
    if ($categoryFiles -ne [Int64]$document.AutoSummary.Files) {
        [void]$errors.Add('AutoSummary file count does not match category totals.')
    }
    if ($categoryBytes -ne [Int64]$document.AutoSummary.Bytes) {
        [void]$errors.Add('AutoSummary byte count does not match category totals.')
    }

    foreach ($candidate in @($document.ReviewCandidates)) {
        if ($candidate.PSObject.Properties.Name -contains 'MeasurementComplete' -and -not [bool]$candidate.MeasurementComplete) {
            [void]$warnings.Add(('Review measurement is partial: {0}' -f $candidate.Id))
        }
    }

    foreach ($summary in @($document.ScanIssueSummary)) {
        [void]$warnings.Add(('{0}: {1} x {2}' -f $summary.Category, $summary.Count, $summary.Class))
    }
}
elseif ($document.PSObject.Properties.Name -contains 'Actions') {
    $planned = @($document.Actions).Count
    if ($planned -ne [int]$document.Summary.PlannedFiles) {
        [void]$errors.Add('Cleanup action count does not match Summary.PlannedFiles.')
    }

    foreach ($action in @($document.Actions)) {
        if ($action.Status -in @('Failed', 'SkippedValidation')) {
            [void]$errors.Add(('{0}: {1}' -f $action.Status, $action.Path))
        }
        elseif ($action.Status -in @('SkippedChanged', 'SkippedMissing')) {
            [void]$warnings.Add(('{0}: {1}' -f $action.Status, $action.Path))
        }
        elseif ($action.Status -ne 'Deleted') {
            [void]$errors.Add(('Unknown cleanup status {0}: {1}' -f $action.Status, $action.Path))
        }
    }
}
elseif ($document.PSObject.Properties.Name -contains 'Items') {
    if (-not ($document.PSObject.Properties.Name -contains 'CategoryRoots')) {
        [void]$errors.Add('Plan is missing CategoryRoots.')
    }
}
else {
    [void]$errors.Add('Unrecognized Safe Space Cleaner document type.')
}

$status = if ($errors.Count -gt 0) { 'FAIL' } elseif ($warnings.Count -gt 0) { 'PASS_WITH_WARNINGS' } else { 'PASS' }
[pscustomobject]@{
    Status = $status
    Path = (Resolve-Path -LiteralPath $Path).Path
    SchemaVersion = $document.SchemaVersion
    Errors = $errors.ToArray()
    Warnings = $warnings.ToArray()
} | ConvertTo-Json -Depth 5

if ($errors.Count -gt 0) {
    exit 2
}
