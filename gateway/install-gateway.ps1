<#
.SYNOPSIS
  Builds fc-llm-gateway for linux-x64 (self-contained, single file) into
  %LOCALAPPDATA%\fc-sandbox\gateway\linux-x64\ and prints that folder; provision.sh installs it into
  /opt/fc-sandbox/bin inside fc-host. Rebuilds only when a source file is newer than the binary.

  Exit codes: 0 ok, 1 no .NET 10 SDK, 2 build failure.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Write-GatewayLog([string]$Message) { [Console]::Error.WriteLine("[gateway] $Message") }

$sourceDir = $PSScriptRoot
$outDir = Join-Path $env:LOCALAPPDATA 'fc-sandbox\gateway\linux-x64'
$exe = Join-Path $outDir 'fc-llm-gateway'

$sources = @(Get-ChildItem -LiteralPath $sourceDir -Recurse -File -Include *.cs, *.csproj |
    Where-Object { $_.FullName -notmatch '\\(bin|obj|FcGateway\.Tests)\\' })
$newestSource = ($sources | Measure-Object -Property LastWriteTimeUtc -Maximum).Maximum

if ((Test-Path -LiteralPath $exe) -and (Get-Item -LiteralPath $exe).LastWriteTimeUtc -ge $newestSource) {
    Write-GatewayLog "fc-llm-gateway (linux-x64) is up to date."
    Write-Output $outDir
    exit 0
}

$dotnet = Get-Command dotnet.exe -ErrorAction SilentlyContinue
if (-not ($dotnet -and (& $dotnet.Source --list-sdks 2>$null | Where-Object { $_ -match '^10\.' }))) {
    Write-GatewayLog "ERROR: the .NET 10 SDK is required to build the LLM gateway. Install it from https://dotnet.microsoft.com/download/dotnet/10.0 and rerun setup."
    exit 1
}

Write-GatewayLog "Building fc-llm-gateway (linux-x64) into '$outDir'..."
# Not trimmed: ASP.NET Core is not fully trim-safe, and size matters little inside fc-host.
$log = & $dotnet.Source publish (Join-Path $sourceDir 'FcGateway\FcGateway.csproj') -c Release -r linux-x64 --self-contained true `
    -p:PublishSingleFile=true -p:DebugType=none -o $outDir --nologo 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-GatewayLog "ERROR: dotnet publish failed (exit $LASTEXITCODE): $(($log | Out-String).Trim())"
    exit 2
}
if (-not (Test-Path -LiteralPath $exe)) {
    Write-GatewayLog "ERROR: build finished but '$exe' is missing."
    exit 2
}
(Get-Item -LiteralPath $exe).LastWriteTimeUtc = [DateTime]::UtcNow
Write-Output $outDir
exit 0
