# net-isolated.ps1 - Smoke test for Windows microVM isolated network mode (--network=none) and HVSocket tar staging.
param([ValidateSet('docker', 'containerd')][string]$WinRuntime = 'docker')
$ErrorActionPreference = 'Stop'
$RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$FcPs1    = Join-Path $RepoRoot 'fc.ps1'

. (Join-Path $RepoRoot 'windows\lib\common.ps1')
. (Join-Path $RepoRoot 'windows\lib\state.ps1')
. (Join-Path $RepoRoot 'windows\lib\runtime.ps1')
. (Join-Path $RepoRoot 'windows\lib\net.ps1')

Write-Host "[smoke-win:net-isolated] 1. Start isolated Windows microVM, check ipconfig and verify outbound connection fails..."
$id = (& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $FcPs1 start -Guest windows -WinRuntime $WinRuntime -Net isolated).Trim()
try {
    $ipcfg = (& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $FcPs1 ssh $id 'ipconfig' -Guest windows -WinRuntime $WinRuntime) -join "`n"
    if ($ipcfg -match '172\.31\.') {
        throw "Isolated Windows microVM must not have a NAT IPv4 address:`n$ipcfg"
    }
    $pingRes = Invoke-FcNative -Exe 'powershell.exe' -ArgList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $FcPs1, 'ssh', $id, 'ping -n 1 -w 1000 1.1.1.1', '-Guest', 'windows', '-WinRuntime', $WinRuntime)
    if ($pingRes.ExitCode -eq 0) {
        throw "Outbound ping to 1.1.1.1 succeeded inside an isolated Windows microVM"
    }
} finally {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $FcPs1 stop $id -Guest windows -WinRuntime $WinRuntime
}

Write-Host "[smoke-win:net-isolated] 2. Run payload in isolated mode and verify C:\work\in -> C:\work\out tar collection..."
$sampleDir = Join-Path $RepoRoot 'samples\hello-win'
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $FcPs1 run -Guest windows -WinRuntime $WinRuntime -Net isolated -Payload $sampleDir -Cmd '.\in\hello.cmd'
if ($LASTEXITCODE -ne 0) {
    throw "Isolated payload run failed with exit code $LASTEXITCODE"
}
$latestRun = Get-ChildItem -LiteralPath (Join-Path $RepoRoot 'runs') -Directory | Sort-Object Name | Select-Object -Last 1
$whoamiFile = Join-Path $latestRun.FullName 'out\whoami.txt'
if (-not (Test-Path -LiteralPath $whoamiFile)) {
    throw "Expected output file '$whoamiFile' was not collected in isolated mode"
}

Write-Host "[smoke-win:net-isolated] PASS"
