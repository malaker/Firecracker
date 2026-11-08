# smoke-lib.ps1 - Shared helpers for the Windows smoke tests. Dot-source after windows\lib\common.ps1
# and windows\lib\runtime.ps1.

# One refusal probe per feature in $script:WIN_RUNTIME_LIMITATIONS: the fc.ps1 arguments that
# request that feature. all.ps1 fails if a limitation has no probe here.
$script:FC_SMOKE_PROBES = @{
    'build-from-source' = { param($rt) @('setup', '-Guest', 'windows', '-WinRuntime', $rt, '-BuildFromSource') }
    'networked'         = { param($rt) @('start', '-Guest', 'windows', '-WinRuntime', $rt, '-Net', 'networked') }
}

# Everything a refused command must leave untouched.
function Get-FcSmokeHostState {
    $cfg = Get-FcWinCfgPath
    $vmsDir = Get-FcWinVmsDir
    [pscustomobject]@{
        Containers = @(foreach ($rt in $script:VALID_WIN_RUNTIMES) { Get-FcWinOrphanContainers $rt }) | Sort-Object
        VmDirs     = @(if (Test-Path -LiteralPath $vmsDir) { Get-ChildItem -LiteralPath $vmsDir -Directory | ForEach-Object Name }) | Sort-Object
        Egress     = @(Get-Process -Name 'fc-egress' -ErrorAction SilentlyContinue | ForEach-Object Id) | Sort-Object
        Config     = if (Test-Path -LiteralPath $cfg) { (Get-FileHash -LiteralPath $cfg).Hash } else { '' }
    } | ConvertTo-Json -Compress
}

# Returns $false when $Feature is supported on $WinRuntime. Otherwise asserts that requesting it
# exits 125 with the standard message and changes nothing, prints a SKIP line, and returns $true.
function Invoke-FcSmokeLimitationSkip([string]$Feature, [string]$WinRuntime, [string]$FcPs1, [string]$What) {
    $lim = Get-FcWinRuntimeLimitations $WinRuntime | Where-Object { $_.Feature -eq $Feature } | Select-Object -First 1
    if (-not $lim) { return $false }
    if (-not $script:FC_SMOKE_PROBES.ContainsKey($Feature)) { throw "No smoke probe for limitation '$Feature'; add one to smoke-lib.ps1" }
    $probeArgs = & $script:FC_SMOKE_PROBES[$Feature] $WinRuntime

    $before = Get-FcSmokeHostState
    $r = Invoke-FcNative -Exe 'powershell.exe' -ArgList (@('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $FcPs1) + $probeArgs)
    $after = Get-FcSmokeHostState
    if ($r.ExitCode -ne 125) {
        throw "$($lim.Flag) on $WinRuntime was not refused with exit 125 (exit $($r.ExitCode)): $($r.Output)"
    }
    if ($r.Output -notmatch [regex]::Escape($lim.Flag) -or $r.Output -notmatch '-WinRuntime docker') {
        throw "Refusal of $($lim.Flag) on $WinRuntime does not name the feature and -WinRuntime docker: $($r.Output)"
    }
    if ($before -ne $after) {
        throw "Refused $($lim.Flag) on $WinRuntime changed host state:`n before: $before`n after:  $after"
    }
    Write-Host "[smoke-win] SKIP $What on ${WinRuntime}: $($lim.Flag) is not supported ($($lim.Reason)); refused with exit 125, nothing left behind"
    return $true
}

# Runs 'fc.ps1 run <RunArgs>' and returns its exit code and the run's own results folder, read
# from -RunInfoFile. (Guessing "the newest folder in runs\" breaks: Linux run ids use the WSL
# distro's local time, Windows ids use UTC, and MCP session folders live there too.)
function Invoke-FcSmokeRun([string]$FcPs1, [string[]]$RunArgs) {
    $info = Join-Path ([System.IO.Path]::GetTempPath()) "fc-smoke-run-$([guid]::NewGuid().ToString('N')).json"
    # Under 'Stop', Windows PowerShell 5.1 would turn the run's stderr lines into errors.
    $ErrorActionPreference = 'Continue'
    # The run's console output (stdout and stderr) is shown and returned, not emitted as values.
    $out = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $FcPs1 run @RunArgs -RunInfoFile $info 2>&1 | ForEach-Object { "$_" })
    $rc = $LASTEXITCODE
    $out | Out-Host
    $dir = if (Test-Path -LiteralPath $info) { [string](Get-Content -LiteralPath $info -Raw | ConvertFrom-Json).results_dir } else { $null }
    Remove-Item -LiteralPath $info -Force -ErrorAction SilentlyContinue
    [pscustomobject]@{ ExitCode = $rc; ResultsDir = $dir; Output = ($out -join "`n") }
}

# Every declared limitation of $WinRuntime must have a probe.
function Assert-FcSmokeProbesComplete([string]$WinRuntime) {
    foreach ($lim in Get-FcWinRuntimeLimitations $WinRuntime) {
        if (-not $script:FC_SMOKE_PROBES.ContainsKey($lim.Feature)) {
            throw "Limitation '$($lim.Feature)' ($($lim.Flag)) on $WinRuntime has no smoke probe; add one to smoke-lib.ps1"
        }
    }
}
