[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$CacheRoot
)

$ErrorActionPreference = 'Stop'
if ($env:SAFE_SPACE_CLEANER_TESTING -ne '1') {
    throw 'Mock cache tool is disabled outside the isolated test harness.'
}

$root = [IO.Path]::GetFullPath($CacheRoot).TrimEnd('\')
if ($root -notlike '*\tests\.tmp-fixture\*') {
    throw 'Mock cache root must stay inside tests/.tmp-fixture.'
}

foreach ($file in (Get-ChildItem -LiteralPath $root -Force -File -Recurse -ErrorAction SilentlyContinue)) {
    if (-not ($file.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        Remove-Item -LiteralPath $file.FullName -Force -ErrorAction Stop
    }
}

[Console]::Error.WriteLine('Mock cache diagnostic written to stderr with exit code zero.')
Write-Output 'Mock owning cache command completed.'
