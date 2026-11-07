<#
.SYNOPSIS
  Builds the sandbox MCP server (fc-mcp.exe) into %LOCALAPPDATA%\fc-sandbox\mcp\, rebuilding
  only when a source file is newer than the published binary.

.DESCRIPTION
  Without a .NET 10 SDK it warns and exits 0: the MCP server is optional and the CLI works
  without it.

  -CheckOnly builds nothing: prints the exe path and exits 0 when the build is present and up
  to date, or exits 3 when it is missing or stale (used by 'fc.ps1 mcp').

  Exit codes: 0 ok (or skipped without SDK), 2 build failure, 3 missing or stale (-CheckOnly).
#>
[CmdletBinding()]
param([switch]$CheckOnly)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Write-McpLog([string]$Message) { [Console]::Error.WriteLine("[mcp] $Message") }

$sourceDir = $PSScriptRoot
$outDir = Join-Path $env:LOCALAPPDATA 'fc-sandbox\mcp'
$exe = Join-Path $outDir 'fc-mcp.exe'

$sources = @(Get-ChildItem -LiteralPath $sourceDir -Recurse -File -Include *.cs, *.csproj |
    Where-Object { $_.FullName -notmatch '\\(bin|obj|FcMcp\.Tests)\\' })
$newestSource = ($sources | Measure-Object -Property LastWriteTimeUtc -Maximum).Maximum
$upToDate = (Test-Path -LiteralPath $exe) -and (Get-Item -LiteralPath $exe).LastWriteTimeUtc -ge $newestSource

if ($CheckOnly) {
    if ($upToDate) { Write-Output $exe; exit 0 }
    exit 3
}
if ($upToDate) {
    Write-McpLog "fc-mcp is up to date."
    exit 0
}

$dotnet = Get-Command dotnet.exe -ErrorAction SilentlyContinue
$hasSdk = $dotnet -and (& $dotnet.Source --list-sdks 2>$null | Where-Object { $_ -match '^10\.' })
if (-not $hasSdk) {
    Write-McpLog "WARNING: .NET 10 SDK not found; skipping the MCP server build ('fc.ps1 mcp' needs it)."
    exit 0
}

Write-McpLog "Building fc-mcp into '$outDir'..."
$log = & $dotnet.Source publish (Join-Path $sourceDir 'FcMcp\FcMcp.csproj') -c Release -r win-x64 --self-contained false `
    -p:DebugType=none -o $outDir --nologo 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-McpLog "ERROR: dotnet publish failed (exit $LASTEXITCODE): $(($log | Out-String).Trim())"
    exit 2
}
if (-not (Test-Path -LiteralPath $exe)) {
    Write-McpLog "ERROR: build finished but '$exe' is missing."
    exit 2
}
# Compare later runs against this build, not against file copy times.
(Get-Item -LiteralPath $exe).LastWriteTimeUtc = [DateTime]::UtcNow
exit 0
