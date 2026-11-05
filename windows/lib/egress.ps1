# egress.ps1 - Builds and locates the Windows networked-mode egress binaries:
# fc-egress.exe (host proxy, framework-dependent) and fc-relay.exe (guest relay, self-contained).
# Change: windows-proxy-networked-mode
Set-StrictMode -Version Latest

function Get-FcWinEgressDir  { Join-Path (Get-FcWinBinDir) 'egress' }
function Get-FcWinEgressExe  { Join-Path (Get-FcWinEgressDir) 'host\fc-egress.exe' }
function Get-FcWinRelayExe   { Join-Path (Get-FcWinEgressDir) 'guest\fc-relay.exe' }

function Test-FcWinEgressPresent {
    (Test-Path -LiteralPath (Get-FcWinEgressExe)) -and (Test-Path -LiteralPath (Get-FcWinRelayExe))
}

function Get-FcDotnetSdk10 {
    $dotnet = Get-Command dotnet.exe -ErrorAction SilentlyContinue
    if (-not $dotnet) { return $null }
    $sdks = & $dotnet.Source --list-sdks 2>$null
    if ($sdks | Where-Object { $_ -match '^10\.' }) { return $dotnet.Source }
    return $null
}

# Rebuilds only when a source file is newer than the published binaries. Without a .NET 10
# SDK it warns and returns $false: isolated mode still works, networked mode will refuse.
function Install-FcWinEgress([string]$SourceDir) {
    $sources = @(Get-ChildItem -LiteralPath $SourceDir -Recurse -File -Include *.cs, *.csproj |
        Where-Object { $_.FullName -notmatch '\\(bin|obj|FcEgress\.Tests)\\' })
    $newestSource = ($sources | Measure-Object -Property LastWriteTimeUtc -Maximum).Maximum
    if (Test-FcWinEgressPresent) {
        $oldestOutput = @((Get-Item -LiteralPath (Get-FcWinEgressExe)), (Get-Item -LiteralPath (Get-FcWinRelayExe)) |
            Measure-Object -Property LastWriteTimeUtc -Minimum).Minimum
        if ($oldestOutput -ge $newestSource) {
            Write-FcLog "Egress proxy and relay binaries are up to date."
            return $true
        }
    }

    $dotnet = Get-FcDotnetSdk10
    if (-not $dotnet) {
        Write-FcLog "WARNING: .NET 10 SDK not found; skipping the egress proxy build. '-Net networked' needs it (install the .NET 10 SDK and rerun setup)."
        return $false
    }

    $egressDir = Get-FcWinEgressDir
    Write-FcLog "Building egress proxy and relay into '$egressDir'..."
    $hostOut = Join-Path $egressDir 'host'
    $guestOut = Join-Path $egressDir 'guest'
    $builds = @(
        @('publish', (Join-Path $SourceDir 'FcEgress\FcEgress.csproj'), '-c', 'Release', '-r', 'win-x64', '--self-contained', 'false', '-o', $hostOut, '--nologo'),
        @('publish', (Join-Path $SourceDir 'FcRelay\FcRelay.csproj'), '-c', 'Release', '-r', 'win-x64', '--self-contained', 'true',
            '-p:PublishSingleFile=true', '-p:PublishTrimmed=true', '-o', $guestOut, '--nologo')
    )
    foreach ($argList in $builds) {
        $r = Invoke-FcNative -Exe $dotnet -ArgList $argList
        if ($r.ExitCode -ne 0) {
            throw "dotnet $($argList[0..1] -join ' ') failed (exit $($r.ExitCode)): $($r.Output)"
        }
    }
    if (-not (Test-FcWinEgressPresent)) { throw "Egress build finished but '$(Get-FcWinEgressExe)' or '$(Get-FcWinRelayExe)' is missing." }
    # Touch outputs so the up-to-date check compares against this build, not file copy times.
    $now = [DateTime]::UtcNow
    foreach ($f in (Get-FcWinEgressExe), (Get-FcWinRelayExe)) { (Get-Item -LiteralPath $f).LastWriteTimeUtc = $now }
    return $true
}
