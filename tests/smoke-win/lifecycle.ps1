# lifecycle.ps1 - Smoke test for Windows microVM start, list, ssh, keep, timeout watchdog, stop, and cleanup.
param([ValidateSet('docker', 'containerd')][string]$WinRuntime = 'docker')
$ErrorActionPreference = 'Stop'
$RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$FcPs1    = Join-Path $RepoRoot 'fc.ps1'

. (Join-Path $RepoRoot 'windows\lib\common.ps1')
. (Join-Path $RepoRoot 'windows\lib\runtime.ps1')
. (Join-Path $PSScriptRoot 'smoke-lib.ps1')

Write-Host "[smoke-win:lifecycle] 1. Start two Windows microVMs (aspnet-x86 and iis-netfx-x86)..."
$id1 = "$(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $FcPs1 start -Guest windows -WinRuntime $WinRuntime -Flavour aspnet-x86 -Vcpu 2 -MemMib 1024)".Trim()
if ($LASTEXITCODE -ne 0) { throw "start -Flavour aspnet-x86 failed (exit $LASTEXITCODE)" }
$id2 = "$(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $FcPs1 start -Guest windows -WinRuntime $WinRuntime -Flavour iis-netfx-x86 -Vcpu 2 -MemMib 1024 -Keep)".Trim()
if ($LASTEXITCODE -ne 0) { throw "start -Flavour iis-netfx-x86 failed (exit $LASTEXITCODE); is the image built or pulled?" }

if (-not $id1 -or -not $id2 -or $id1 -eq $id2) {
    throw "Failed to start distinct Windows microVMs (id1='$id1', id2='$id2')"
}

$listOut = (& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $FcPs1 list -Guest windows -WinRuntime $WinRuntime) -join "`n"
if ($listOut -notmatch [regex]::Escape($id1) -or $listOut -notmatch [regex]::Escape($id2)) {
    throw "list -Guest windows did not include both VMs:`n$listOut"
}
if ($listOut -notmatch 'aspnet-x86' -or $listOut -notmatch 'iis-netfx-x86') {
    throw "list -Guest windows did not report flavours:`n$listOut"
}

Write-Host "[smoke-win:lifecycle] 2. Run command via ssh in running Windows microVM $id1..."
$sshOut = (& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $FcPs1 ssh $id1 'echo ssh-win-ok' -Guest windows -WinRuntime $WinRuntime) -join "`n"
if ($LASTEXITCODE -ne 0 -or $sshOut -notmatch 'ssh-win-ok') {
    throw "ssh into Windows microVM $id1 failed: $sshOut"
}

Write-Host "[smoke-win:lifecycle] 3. Stop $id1 and verify removal..."
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $FcPs1 stop $id1 -Guest windows -WinRuntime $WinRuntime
$listAfterStop = (& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $FcPs1 list -Guest windows -WinRuntime $WinRuntime) -join "`n"
if ($listAfterStop -match [regex]::Escape($id1)) {
    throw "Stopped VM $id1 still appears in list:`n$listAfterStop"
}

# Networked when the runtime supports it, so the watchdog also tears down the egress proxy.
$timeoutNet = if (Test-FcWinFeatureSupported 'networked' $WinRuntime) { 'networked' } else { 'isolated' }
Write-Host "[smoke-win:lifecycle] 4. Verify hard timeout (3s, $timeoutNet) records timed_out=true and exit_code=124..."
$sampleDir = Join-Path $RepoRoot 'samples\hello-win'
$timeoutRun = Invoke-FcSmokeRun $FcPs1 @('-Guest', 'windows', '-WinRuntime', $WinRuntime, '-Net', $timeoutNet, '-Payload', $sampleDir, '-Cmd', 'ping -n 15 127.0.0.1 >nul', '-Timeout', '3s')
$rcTimeout = $timeoutRun.ExitCode
if ($rcTimeout -ne 124) {
    throw "Expected exit code 124 on timeout, got $rcTimeout"
}
$latestRun = Get-Item -LiteralPath $timeoutRun.ResultsDir
$meta = Get-Content -LiteralPath (Join-Path $latestRun.FullName 'meta.json') -Raw | ConvertFrom-Json
if (-not $meta.timed_out -or $meta.exit_code -ne 124 -or $meta.guest -ne 'windows') {
    throw "Timeout run meta.json did not record timed_out=true and exit_code=124: $($meta | ConvertTo-Json -Compress)"
}
if ($timeoutNet -eq 'networked' -and -not (Test-Path -LiteralPath (Join-Path $latestRun.FullName 'net.log'))) {
    throw "Networked timeout run did not keep net.log in $($latestRun.FullName)"
}

Write-Host "[smoke-win:lifecycle] 5. Cleanup all Windows microVMs and verify empty list..."
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $FcPs1 cleanup -Guest windows -WinRuntime $WinRuntime
$listFinal = (& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $FcPs1 list -Guest windows -WinRuntime $WinRuntime) | Where-Object { $_ -notmatch '^RUN-ID' -and $_.Trim() -ne '' }
if ($listFinal) {
    throw "Expected empty list after cleanup -Guest windows, got:`n$($listFinal -join "`n")"
}
if (Get-Process -Name 'fc-egress' -ErrorAction SilentlyContinue) {
    throw "fc-egress.exe still running after cleanup -Guest windows"
}

Write-Host "[smoke-win:lifecycle] PASS"
