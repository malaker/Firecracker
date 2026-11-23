<#
.SYNOPSIS
  Builds fc-audit (self-contained, single file, trimmed) for win-x64 and prints the folder that
  holds it. Rebuilds only when a source file is newer than the published binary.

.DESCRIPTION
  win-x64 -> C:\ProgramData\fc-sandbox-win\bin\audit\fc-audit.exe   (needs elevation)
             The elevated controller runs this binary, so the folder is owned by Administrators
             and only Administrators and SYSTEM may modify it.

  Exit codes: 0 ok, 1 no .NET 10 SDK, 2 build or permission failure.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][ValidateSet('win-x64')][string]$Rid
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$SourceDir = $PSScriptRoot

function Write-AuditLog([string]$Message) { [Console]::Error.WriteLine("[audit] $Message") }

function Get-AuditOutDir {
    $base = if ($env:FC_WIN_BASE) { $env:FC_WIN_BASE } else { 'C:\ProgramData\fc-sandbox-win' }
    return (Join-Path $base 'bin\audit')
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
# Same treatment as the airlock tool's folder (airlock\install-airlock.ps1).
function Protect-AuditDir([string]$Dir) {
    # icacls reports per-file problems on stderr; Windows PowerShell 5.1 would turn that into a
    # terminating error under 'Stop', so only its exit code decides here.
    $ErrorActionPreference = 'Continue'
    function Invoke-Icacls([string]$What, [string[]]$IcaclsArgs) {
        $r = & icacls.exe @IcaclsArgs 2>&1
        if ($LASTEXITCODE -ne 0) { throw "Cannot $What`: $(($r | Out-String).Trim())" }
    }
    $base = Split-Path -Parent (Split-Path -Parent $Dir)
    foreach ($d in @($base, (Split-Path -Parent $Dir), $Dir)) {
        Invoke-Icacls "set the owner of '$d'" @($d, '/setowner', '*S-1-5-32-544', '/C', '/Q')
    }
    Invoke-Icacls "restrict '$Dir'" @($Dir, '/inheritance:r', '/grant:r', '*S-1-5-32-544:(OI)(CI)F', '*S-1-5-18:(OI)(CI)F', '*S-1-5-32-545:(OI)(CI)RX', '/C', '/Q')
    if (Get-ChildItem -LiteralPath $Dir -Force | Select-Object -First 1) {
        Invoke-Icacls "reset permissions under '$Dir'" @((Join-Path $Dir '*'), '/reset', '/T', '/C', '/Q')
        Invoke-Icacls "set the owner of files under '$Dir'" @((Join-Path $Dir '*'), '/setowner', '*S-1-5-32-544', '/T', '/C', '/Q')
    }
}

$outDir = Get-AuditOutDir
$exe = Join-Path $outDir 'fc-audit.exe'

if (-not (Test-Elevated)) {
    Write-AuditLog "ERROR: building the audit report tool needs an elevated prompt (it goes into an admin-only folder)."
    exit 2
}

# fc-audit also compiles the shared restricted-launch code in windows\common.
$commonDir = Join-Path (Split-Path -Parent $SourceDir) 'windows\common'
$sources = @(Get-ChildItem -LiteralPath @($SourceDir, $commonDir) -Recurse -File -Include *.cs, *.csproj -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -notmatch '\\(bin|obj|FcAudit\.Tests)\\' })
$newestSource = ($sources | Measure-Object -Property LastWriteTimeUtc -Maximum).Maximum

try {
    # Repair the folder's permissions first, so a damaged ACL cannot block the checks below.
    if (Test-Path -LiteralPath $outDir) { Protect-AuditDir $outDir }
    if ((Test-Path -LiteralPath $exe) -and (Get-Item -LiteralPath $exe).LastWriteTimeUtc -ge $newestSource) {
        Write-AuditLog "fc-audit ($Rid) is up to date."
        Write-Output $outDir
        exit 0
    }

    $dotnet = Get-DotnetSdk10
    if (-not $dotnet) {
        Write-AuditLog "ERROR: the .NET 10 SDK is required to build the audit report tool. Install it from https://dotnet.microsoft.com/download/dotnet/10.0 and rerun setup."
        exit 1
    }

    New-Item -ItemType Directory -Force -Path $outDir | Out-Null
    Protect-AuditDir $outDir
    Write-AuditLog "Building fc-audit ($Rid) into '$outDir'..."
    $log = & $dotnet publish (Join-Path $SourceDir 'FcAudit\FcAudit.csproj') -c Release -r $Rid --self-contained true `
        -p:PublishSingleFile=true -p:PublishTrimmed=true -p:DebugType=none -o $outDir --nologo 2>&1
    if ($LASTEXITCODE -ne 0) { throw "dotnet publish failed (exit $LASTEXITCODE): $(($log | Out-String).Trim())" }
    if (-not (Test-Path -LiteralPath $exe)) { throw "Build finished but '$exe' is missing." }
    # Compare later runs against this build, not against file copy times.
    (Get-Item -LiteralPath $exe).LastWriteTimeUtc = [DateTime]::UtcNow
    Protect-AuditDir $outDir
    Write-Output $outDir
    exit 0
} catch {
    Write-AuditLog "ERROR: $($_.Exception.Message)"
    exit 2
}
