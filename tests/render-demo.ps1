$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$cleaner = Join-Path $repositoryRoot 'safe-space-cleaner\scripts\space-cleaner.ps1'
$checker = Join-Path $repositoryRoot 'safe-space-cleaner\scripts\check-report.ps1'
$demoRoot = Join-Path $repositoryRoot 'tmp\demo'
$fixtureRoot = Join-Path $demoRoot 'fixture'
$reportRoot = Join-Path $demoRoot 'reports'
$htmlPath = Join-Path $demoRoot 'demo.html'
$drive = ([IO.Path]::GetPathRoot($fixtureRoot)).Substring(0, 1)

if (Test-Path -LiteralPath $demoRoot) {
    $resolvedDemo = [IO.Path]::GetFullPath($demoRoot)
    $resolvedRepository = [IO.Path]::GetFullPath($repositoryRoot).TrimEnd('\')
    if (-not $resolvedDemo.StartsWith($resolvedRepository + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Demo path escaped the repository.'
    }
    Remove-Item -LiteralPath $demoRoot -Recurse -Force
}

$null = New-Item -ItemType Directory -Path (Join-Path $fixtureRoot 'auto\nested') -Force
$null = New-Item -ItemType Directory -Path (Join-Path $fixtureRoot 'review') -Force
$null = New-Item -ItemType Directory -Path $reportRoot -Force

$oldA = Join-Path $fixtureRoot 'auto\old-render-cache.bin'
$oldB = Join-Path $fixtureRoot 'auto\nested\old-export-cache.bin'
$recent = Join-Path $fixtureRoot 'auto\current-session.tmp'
$review = Join-Path $fixtureRoot 'review\offline-installer.zip'
[IO.File]::WriteAllBytes($oldA, (New-Object byte[] (1536KB)))
[IO.File]::WriteAllBytes($oldB, (New-Object byte[] (768KB)))
[IO.File]::WriteAllBytes($recent, (New-Object byte[] (64KB)))
[IO.File]::WriteAllBytes($review, (New-Object byte[] (512KB)))
(Get-Item -LiteralPath $oldA).LastWriteTimeUtc = [DateTime]::UtcNow.AddDays(-45)
(Get-Item -LiteralPath $oldB).LastWriteTimeUtc = [DateTime]::UtcNow.AddDays(-45)
(Get-Item -LiteralPath $review).LastWriteTimeUtc = [DateTime]::UtcNow.AddDays(-45)

function Format-Bytes {
    param([Int64]$Value)
    if ($Value -ge 1GB) { return ('{0:N2} GiB' -f ($Value / 1GB)) }
    if ($Value -ge 1MB) { return ('{0:N2} MiB' -f ($Value / 1MB)) }
    if ($Value -ge 1KB) { return ('{0:N2} KiB' -f ($Value / 1KB)) }
    return ('{0:N0} B' -f $Value)
}

$env:SAFE_SPACE_CLEANER_TESTING = '1'
try {
    $auditResult = & $cleaner -Mode Audit -Drive $drive -Profile Aggressive -MinAgeDays 7 -ReportDirectory $reportRoot -TestRoot $fixtureRoot
    $cleanupResult = & $cleaner -Mode Clean -Drive $drive -PlanPath $auditResult.PlanPath -ConfirmationToken $auditResult.ConfirmationToken -ReportDirectory $reportRoot -TestRoot $fixtureRoot
    $checkResult = (& $checker -Path $cleanupResult.ReportJsonPath | ConvertFrom-Json)
    $audit = Get-Content -Raw -Encoding UTF8 -LiteralPath $auditResult.AuditJsonPath | ConvertFrom-Json
    $cleanup = Get-Content -Raw -Encoding UTF8 -LiteralPath $cleanupResult.ReportJsonPath | ConvertFrom-Json
    $tokenPrefix = $auditResult.ConfirmationToken.Substring(0, 12)
    $autoBytes = Format-Bytes ([Int64]$audit.AutoSummary.Bytes)
    $deletedBytes = Format-Bytes ([Int64]$cleanup.Summary.DeletedBytes)
    $spaceChange = Format-Bytes ([Math]::Max(0, [Int64]$cleanup.Summary.FreeSpaceChangeBytes))
    $reviewBytes = Format-Bytes ([Int64]$audit.ReviewCandidates[0].Bytes)

    $html = @"
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Safe Space Cleaner demo</title>
<style>
  * { box-sizing: border-box; }
  body { margin: 0; background: #f5f3ee; color: #1f2622; font-family: "Segoe UI", Arial, sans-serif; }
  main { width: 1360px; margin: 0 auto; padding: 54px 62px 48px; }
  header { display: flex; justify-content: space-between; align-items: flex-start; border-bottom: 2px solid #24382d; padding-bottom: 24px; }
  h1 { margin: 0 0 10px; font-size: 48px; letter-spacing: -1.5px; font-weight: 720; }
  .subtitle { margin: 0; font-size: 20px; color: #526057; }
  .fixture { padding: 10px 15px; border: 1px solid #9aa49e; border-radius: 5px; background: #fff; font-size: 14px; text-align: right; }
  .fixture strong { color: #2b6849; }
  .timeline { display: grid; grid-template-columns: repeat(5, 1fr); gap: 0; margin: 32px 0 30px; }
  .step { position: relative; padding: 13px 14px 13px 43px; border-top: 1px solid #a5afa8; border-bottom: 1px solid #a5afa8; background: #fff; font-weight: 650; }
  .step:first-child { border-left: 1px solid #a5afa8; border-radius: 5px 0 0 5px; }
  .step:last-child { border-right: 1px solid #a5afa8; border-radius: 0 5px 5px 0; }
  .step::before { content: attr(data-n); position: absolute; left: 13px; top: 10px; width: 24px; height: 24px; border-radius: 50%; color: #fff; background: #2b6849; text-align: center; line-height: 24px; }
  .grid { display: grid; grid-template-columns: 1.25fr 1fr 1fr; gap: 18px; }
  .card { min-height: 218px; padding: 24px; background: #fff; border: 1px solid #b8c0ba; border-radius: 6px; }
  .card.safe { border-top: 7px solid #2b6849; }
  .card.review { border-top: 7px solid #b77a24; }
  .card.protected { border-top: 7px solid #5f6b64; }
  .eyebrow { text-transform: uppercase; letter-spacing: 1.3px; font-size: 13px; color: #66736b; font-weight: 700; }
  .metric { font-size: 39px; font-weight: 740; margin: 13px 0 7px; }
  .detail { color: #526057; line-height: 1.55; font-size: 16px; }
  .token { margin-top: 17px; padding: 10px 12px; font-family: Consolas, monospace; font-size: 13px; background: #edf2ee; border-left: 3px solid #2b6849; }
  .result { margin-top: 22px; display: grid; grid-template-columns: 1fr 1fr 1fr 1.25fr; gap: 1px; background: #aab2ac; border: 1px solid #aab2ac; border-radius: 6px; overflow: hidden; }
  .result > div { background: #fff; padding: 18px 20px; min-height: 93px; }
  .result b { display: block; margin-top: 8px; font-size: 23px; }
  .pass { color: #2b6849; }
  footer { margin-top: 22px; display: flex; justify-content: space-between; color: #647068; font-size: 13px; }
  code { font-family: Consolas, monospace; }
</style>
</head>
<body>
<main>
  <header>
    <div>
      <h1>Safe Space Cleaner</h1>
      <p class="subtitle">Audit first. Revalidate every file. Report every action.</p>
    </div>
    <div class="fixture"><strong>REAL ISOLATED RUN</strong><br>No personal or system files</div>
  </header>

  <section class="timeline" aria-label="cleanup workflow">
    <div class="step" data-n="1">Audit</div>
    <div class="step" data-n="2">Review</div>
    <div class="step" data-n="3">Token</div>
    <div class="step" data-n="4">Revalidate</div>
    <div class="step" data-n="5">Report</div>
  </section>

  <section class="grid">
    <article class="card safe">
      <div class="eyebrow">Verified automatic plan</div>
      <div class="metric">$autoBytes</div>
      <div class="detail">$($audit.AutoSummary.Files) old temporary files qualified. The recent session file stayed outside the plan.</div>
      <div class="token">SHA-256&nbsp; $tokenPrefix...</div>
    </article>
    <article class="card review">
      <div class="eyebrow">Review required</div>
      <div class="metric">$reviewBytes</div>
      <div class="detail">One offline installer was listed with size and impact. It was not included in automatic cleanup.</div>
    </article>
    <article class="card protected">
      <div class="eyebrow">Protected</div>
      <div class="metric">$(@($audit.Protected).Count) rules</div>
      <div class="detail">System stores, rollback data, hibernation, pagefile, restore data, and user content remain direct-delete exclusions.</div>
    </article>
  </section>

  <section class="result">
    <div><span class="eyebrow">Deleted</span><b>$($cleanup.Summary.DeletedFiles) files</b></div>
    <div><span class="eyebrow">Planned bytes</span><b>$deletedBytes</b></div>
    <div><span class="eyebrow">Free-space change</span><b>$spaceChange</b></div>
    <div><span class="eyebrow">Structured check</span><b class="pass">$($checkResult.Status)</b></div>
  </section>

  <footer>
    <span>Schema $($audit.SchemaVersion) | Policy $($audit.PolicyVersion)</span>
    <span>Exact actions: Markdown + CSV + JSON</span>
  </footer>
</main>
</body>
</html>
"@

    [IO.File]::WriteAllText($htmlPath, $html, (New-Object Text.UTF8Encoding($false)))
    Write-Output $htmlPath
}
finally {
    Remove-Item Env:SAFE_SPACE_CLEANER_TESTING -ErrorAction SilentlyContinue
}
