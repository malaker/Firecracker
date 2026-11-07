<#
.SYNOPSIS
  Builds fc-airlock (self-contained, single file, trimmed) for one runtime and prints the
  folder that holds it. Rebuilds only when a source file is newer than the published binary.

.DESCRIPTION
  linux-x64  -> %LOCALAPPDATA%\fc-sandbox\airlock\linux-x64\fc-airlock
               (provision.sh installs it into /opt/fc-sandbox/bin inside fc-host)
  win-x64    -> C:\ProgramData\fc-sandbox-win\bin\airlock\fc-airlock.exe   (needs elevation)
               The elevated controller runs this binary, so the folder is owned by
               Administrators and only Administrators and SYSTEM may modify it.

  Exit codes: 0 ok, 1 no .NET 10 SDK, 2 build or permission failure.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][ValidateSet('linux-x64', 'win-x64')][string]$Rid
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$SourceDir = $PSScriptRoot

function Write-AirlockLog([string]$Message) { [Console]::Error.WriteLine("[airlock] $Message") }

function Get-AirlockOutDir {
    if ($Rid -eq 'linux-x64') { return (Join-Path $env:LOCALAPPDATA 'fc-sandbox\airlock\linux-x64') }
    $base = if ($env:FC_WIN_BASE) { $env:FC_WIN_BASE } else { 'C:\ProgramData\fc-sandbox-win' }
    return (Join-Path $base 'bin\airlock')
}

function Get-DotnetSdk10 {
    $dotnet = Get-Command dotnet.exe -ErrorAction SilentlyContinue
    if (-not $dotnet) { return $null }
    $sdks = & $dotnet.Source --list-sdks 2>$null
    if ($sdks | Where-Object { $_ -match '^10\.' }) { return $dotnet.Source }
    return $null
}

function Test-Elevated {
    ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Owner Administrators; protected ACL: Administrators + SYSTEM full control, Users read & execute.
# Ancestors under ProgramData get their owner reset too, so a folder pre-created by a
# non-admin cannot be used to swap the binary later.
function Protect-AirlockDir([string]$Dir) {
    $base = Split-Path -Parent (Split-Path -Parent $Dir)
    foreach ($d in @($base, (Split-Path -Parent $Dir))) {
        $r = & icacls.exe $d /setowner '*S-1-5-32-544' /C /Q 2>&1
        if ($LASTEXITCODE -ne 0) { throw "Cannot set the owner of '$d': $r" }
    }
    $r = & icacls.exe $Dir /setowner '*S-1-5-32-544' /T /C /Q 2>&1
    if ($LASTEXITCODE -ne 0) { throw "Cannot set the owner of '$Dir': $r" }
    $r = & icacls.exe $Dir /inheritance:r /grant:r '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-545:(OI)(CI)RX' /T /C /Q 2>&1
    if ($LASTEXITCODE -ne 0) { throw "Cannot restrict '$Dir': $r" }
}

$outDir = Get-AirlockOutDir
$exeName = if ($Rid -eq 'win-x64') { 'fc-airlock.exe' } else { 'fc-airlock' }
$exe = Join-Path $outDir $exeName

if ($Rid -eq 'win-x64' -and -not (Test-Elevated)) {
    Write-AirlockLog "ERROR: building the Windows airlock tool needs an elevated prompt (it goes into an admin-only folder)."
    exit 2
}

$sources = @(Get-ChildItem -LiteralPath $SourceDir -Recurse -File -Include *.cs, *.csproj |
    Where-Object { $_.FullName -notmatch '\\(bin|obj|FcAirlock\.Tests)\\' })
$newestSource = ($sources | Measure-Object -Property LastWriteTimeUtc -Maximum).Maximum

try {
    if ((Test-Path -LiteralPath $exe) -and (Get-Item -LiteralPath $exe).LastWriteTimeUtc -ge $newestSource) {
        if ($Rid -eq 'win-x64') { Protect-AirlockDir $outDir }
        Write-AirlockLog "fc-airlock ($Rid) is up to date."
        Write-Output $outDir
        exit 0
    }

    $dotnet = Get-DotnetSdk10
    if (-not $dotnet) {
        Write-AirlockLog "ERROR: the .NET 10 SDK is required to build the guest output airlock tool. Install it from https://dotnet.microsoft.com/download/dotnet/10.0 and rerun setup."
        exit 1
    }

    if ($Rid -eq 'win-x64') {
        New-Item -ItemType Directory -Force -Path $outDir | Out-Null
        Protect-AirlockDir $outDir
    }
    Write-AirlockLog "Building fc-airlock ($Rid) into '$outDir'..."
    $log = & $dotnet publish (Join-Path $SourceDir 'FcAirlock\FcAirlock.csproj') -c Release -r $Rid --self-contained true `
        -p:PublishSingleFile=true -p:PublishTrimmed=true -p:DebugType=none -o $outDir --nologo 2>&1
    if ($LASTEXITCODE -ne 0) { throw "dotnet publish failed (exit $LASTEXITCODE): $(($log | Out-String).Trim())" }
    if (-not (Test-Path -LiteralPath $exe)) { throw "Build finished but '$exe' is missing." }
    # Compare later runs against this build, not against file copy times.
    (Get-Item -LiteralPath $exe).LastWriteTimeUtc = [DateTime]::UtcNow
    if ($Rid -eq 'win-x64') { Protect-AirlockDir $outDir }
    Write-Output $outDir
    exit 0
} catch {
    Write-AirlockLog "ERROR: $($_.Exception.Message)"
    exit 2
}
