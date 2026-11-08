# all.ps1 - End-to-end smoke test suite for Windows Nano Server Hyper-V microVMs.
# -WinRuntime selects the backend under test (default docker). The host's configured default
# runtime, image repository and flavour are restored afterwards, even when a part fails.
param([ValidateSet('docker', 'containerd')][string]$WinRuntime = 'docker')
$ErrorActionPreference = 'Stop'
$RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$FcPs1    = Join-Path $RepoRoot 'fc.ps1'

. (Join-Path $RepoRoot 'windows\lib\common.ps1')
. (Join-Path $RepoRoot 'windows\lib\runtime.ps1')
. (Join-Path $PSScriptRoot 'smoke-lib.ps1')

Assert-FcSmokeProbesComplete $WinRuntime

if (-not (Test-FcWinRuntimeReady 'docker') -and -not (Test-FcWinRuntimeReady 'containerd')) {
    throw "Windows microVM runtime is not ready. Run '.\fc.ps1 setup -Guest windows' in an elevated PowerShell prompt first."
}

# setup rewrites config.json as a side effect; keep the original bytes to put back.
$cfgPath   = Get-FcWinCfgPath
$cfgBackup = if (Test-Path -LiteralPath $cfgPath) { [System.IO.File]::ReadAllBytes($cfgPath) } else { $null }

Write-Host "=== Windows microVM smoke tests (runtime=$WinRuntime) ==="
try {
    Write-Host "=== [1/6] Windows setup & doctor (-Boot) ==="
    [void](Invoke-FcSmokeLimitationSkip 'build-from-source' $WinRuntime $FcPs1 'local image build')
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $FcPs1 setup -Guest windows -WinRuntime $WinRuntime -ImageRepo malaker/nanoserver -Flavour aspnet-x86 -Yes
    if ($LASTEXITCODE -ne 0) { throw "setup -Guest windows failed" }

    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $FcPs1 doctor -Guest windows -WinRuntime $WinRuntime -Boot
    if ($LASTEXITCODE -ne 0) { throw "doctor -Guest windows -Boot failed" }

    Write-Host "=== [2/6] Isolated payload run & exit code propagation ==="
    & (Join-Path $PSScriptRoot 'net-isolated.ps1') -WinRuntime $WinRuntime

    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $FcPs1 run -Guest windows -WinRuntime $WinRuntime -Payload (Join-Path $RepoRoot 'samples\hello-win') -Cmd 'exit /b 3'
    if ($LASTEXITCODE -ne 3) { throw "Expected exit code 3 from guest command, got $LASTEXITCODE" }

    Write-Host "=== [3/6] Lifecycle, ssh, keep, timeout watchdog, stop & cleanup ==="
    & (Join-Path $PSScriptRoot 'lifecycle.ps1') -WinRuntime $WinRuntime

    Write-Host "=== [4/6] Guest output airlock (links, reserved names, limits) and put/get ==="
    & (Join-Path $PSScriptRoot 'airlock.ps1') -WinRuntime $WinRuntime
    if ($LASTEXITCODE -ne 0) { throw "airlock smoke test failed" }
    & (Join-Path $PSScriptRoot 'files.ps1') -WinRuntime $WinRuntime
    if ($LASTEXITCODE -ne 0) { throw "put/get smoke test failed" }

    Write-Host "=== [5/6] Networked mode (egress proxy), host/LAN protection & CIDR allowlist ==="
    & (Join-Path $PSScriptRoot 'net-protect.ps1') -WinRuntime $WinRuntime

    Write-Host "=== [6/6] Final cleanup & empty list check ==="
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $FcPs1 cleanup -Guest windows -WinRuntime $WinRuntime
    $remaining = (& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $FcPs1 list -Guest windows -WinRuntime $WinRuntime) | Where-Object { $_ -notmatch '^RUN-ID' -and $_.Trim() -ne '' }
    if ($remaining) {
        throw "Leftover Windows microVMs after cleanup: $($remaining -join ', ')"
    }
    if (Get-Process -Name 'fc-egress' -ErrorAction SilentlyContinue) {
        throw "Leftover fc-egress.exe processes after cleanup"
    }

    Write-Host "=== ALL WINDOWS MICROVM SMOKE TESTS PASSED (runtime=$WinRuntime) ==="
} finally {
    # Restore first: it is instant, while cleanup can be slow and a second Ctrl+C there
    # would abort the rest of this block. Cleanup takes -WinRuntime, not the config default.
    if ($null -ne $cfgBackup) {
        [System.IO.File]::WriteAllBytes($cfgPath, $cfgBackup)
    } elseif (Test-Path -LiteralPath $cfgPath) {
        Remove-Item -LiteralPath $cfgPath -Force
    }
    Write-Host "Restored the host's Windows microVM configuration ($cfgPath)."
    # A failed cleanup here leaves microVMs behind, so report it instead of discarding it.
    $cleanup = Invoke-FcNative -Exe 'powershell.exe' -ArgList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $FcPs1, 'cleanup', '-Guest', 'windows', '-WinRuntime', $WinRuntime)
    if ($cleanup.ExitCode -ne 0) {
        Write-Host "WARNING: final 'cleanup -Guest windows' failed (exit $($cleanup.ExitCode)); microVMs may be left behind:"
        Write-Host $cleanup.Output
    }
    $left = (Invoke-FcNative -Exe 'powershell.exe' -ArgList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $FcPs1, 'list', '-Guest', 'windows', '-WinRuntime', $WinRuntime)).Output -split "`r?`n" |
        Where-Object { $_ -notmatch '^RUN-ID' -and $_.Trim() -ne '' }
    if ($left) {
        Write-Host "WARNING: microVMs still listed after the final cleanup (cleanup exit $($cleanup.ExitCode), output: $($cleanup.Output)):"
        $left | ForEach-Object { Write-Host "  $_" }
    }
}
