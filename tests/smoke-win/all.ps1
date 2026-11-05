# all.ps1 - End-to-end smoke test suite for Windows Nano Server Hyper-V microVMs.
$ErrorActionPreference = 'Stop'
$RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$FcPs1    = Join-Path $RepoRoot 'fc.ps1'

. (Join-Path $RepoRoot 'windows\lib\common.ps1')
. (Join-Path $RepoRoot 'windows\lib\runtime.ps1')

if (-not (Test-FcWinRuntimeReady 'docker') -and -not (Test-FcWinRuntimeReady 'containerd')) {
    throw "Windows microVM runtime is not ready. Run '.\fc.ps1 setup -Guest windows' in an elevated PowerShell prompt first."
}

try {
    Write-Host "=== [1/5] Windows setup & doctor (-Boot) ==="
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $FcPs1 setup -Guest windows -WinRuntime docker -ImageRepo malaker/nanoserver -Flavour aspnet-x86 -Yes
    if ($LASTEXITCODE -ne 0) { throw "setup -Guest windows failed" }

    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $FcPs1 doctor -Guest windows -Boot
    if ($LASTEXITCODE -ne 0) { throw "doctor -Guest windows -Boot failed" }

    Write-Host "=== [2/5] Isolated payload run & exit code propagation ==="
    & (Join-Path $PSScriptRoot 'net-isolated.ps1')

    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $FcPs1 run -Guest windows -Payload (Join-Path $RepoRoot 'samples\hello-win') -Cmd 'exit /b 3'
    if ($LASTEXITCODE -ne 3) { throw "Expected exit code 3 from guest command, got $LASTEXITCODE" }

    Write-Host "=== [3/5] Lifecycle, ssh, keep, timeout watchdog, stop & cleanup ==="
    & (Join-Path $PSScriptRoot 'lifecycle.ps1')

    Write-Host "=== [4/5] Networked mode (egress proxy), host/LAN protection & CIDR allowlist ==="
    & (Join-Path $PSScriptRoot 'net-protect.ps1')

    Write-Host "=== [5/5] Final cleanup & empty list check ==="
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $FcPs1 cleanup -Guest windows
    $remaining = (& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $FcPs1 list -Guest windows) | Where-Object { $_ -notmatch '^RUN-ID' -and $_.Trim() -ne '' }
    if ($remaining) {
        throw "Leftover Windows microVMs after cleanup: $($remaining -join ', ')"
    }
    if (Get-Process -Name 'fc-egress' -ErrorAction SilentlyContinue) {
        throw "Leftover fc-egress.exe processes after cleanup"
    }

    Write-Host "=== ALL WINDOWS MICROVM SMOKE TESTS PASSED ==="
} finally {
    [void](Invoke-FcNative -Exe 'powershell.exe' -ArgList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $FcPs1, 'cleanup', '-Guest', 'windows'))
}
