# doctor.ps1 - Preflight diagnostics for Windows Hyper-V Nano Server microVMs.
# Change: nanoserver-windows-microvm
Set-StrictMode -Version Latest

function Invoke-WinDoctor {
    param(
        [string]$WinRuntime,
        [string]$ImageRepo,
        [string]$Flavour,
        [switch]$Boot
    )
    $cfg = Get-FcWinConfig
    if (-not $WinRuntime) { $WinRuntime = $cfg.win_runtime }
    if (-not $ImageRepo)  { $ImageRepo  = $cfg.image_repo }
    if (-not $Flavour)    { $Flavour    = $cfg.default_flavour }

    Assert-ValidWinRuntime $WinRuntime
    Assert-ValidFlavour $Flavour
    $imageRef = Get-FcImageReference $ImageRepo $Flavour

    $script:DoctorFailed = $false

    function Test-Check([string]$Name, [string]$Hint, [scriptblock]$Predicate) {
        $ok = $false
        try {
            $ok = [bool](& $Predicate)
        } catch {
            $ok = $false
        }
        if ($ok) {
            Write-Host "  [PASS] $Name"
        } else {
            Write-Host "  [FAIL] $Name"
            Write-Host "         hint: $Hint"
            $script:DoctorFailed = $true
        }
    }

    Write-Host "fc-sandbox Windows preflight (runtime=$WinRuntime, image=$imageRef)"
    $limitations = @(Get-FcWinRuntimeLimitations $WinRuntime)
    if ($limitations.Count -gt 0) {
        Write-Host "  [NOTE] not supported with runtime '$WinRuntime' (use '-WinRuntime docker' for these):"
        foreach ($lim in $limitations) {
            Write-Host "         $($lim.Flag): $($lim.Reason)"
        }
    }

    Test-Check "running as Administrator" `
        "open an elevated (Run as Administrator) PowerShell prompt; the Docker engine pipe requires elevation" `
        { Test-FcAdmin }

    Test-Check "Windows 'Microsoft-Hyper-V' feature enabled" `
        "run '.\fc.ps1 setup -Guest windows' in an elevated PowerShell prompt" `
        { Test-FcWindowsFeatureEnabled 'Microsoft-Hyper-V' }

    Test-Check "Windows 'Containers' feature enabled" `
        "run '.\fc.ps1 setup -Guest windows' in an elevated PowerShell prompt (requires a reboot on first enable)" `
        { Test-FcWindowsFeatureEnabled 'Containers' }

    Test-Check "Host Compute Service (vmcompute) running" `
        "start the service with 'Start-Service vmcompute' in an elevated PowerShell prompt" `
        { Test-FcHcsServiceRunning }

    # Only networked mode needs these, and setup only warns without a .NET 10 SDK, so a
    # missing build is a warning here too rather than a failure that blocks isolated runs.
    if (Test-FcWinEgressPresent) {
        Write-Host "  [PASS] egress proxy and relay binaries present (needed for -Net networked)"
    } else {
        Write-Host "  [WARN] egress proxy and relay binaries missing: -Net networked is unavailable, -Net isolated still works"
        Write-Host "         hint: install the .NET 10 SDK and rerun '.\fc.ps1 setup -Guest windows'"
    }

    Test-Check "guest output airlock tool (fc-airlock.exe)" `
        "rerun '.\fc.ps1 setup -Guest windows' in an elevated prompt (needs the .NET 10 SDK)" `
        { Test-FcWinAirlockPresent }

    Test-Check "Windows runtime '$WinRuntime' binaries installed" `
        "run '.\fc.ps1 setup -Guest windows -WinRuntime $WinRuntime'" `
        { Test-FcWinRuntimeBinariesPresent $WinRuntime }

    Test-Check "Windows runtime '$WinRuntime' service running and reachable" `
        "start the '$WinRuntime' service or run '.\fc.ps1 setup -Guest windows -WinRuntime $WinRuntime' as Administrator" `
        { Test-FcWinRuntimeReady $WinRuntime }

    Test-Check "Nano Server base image '$imageRef' present" `
        "run '.\fc.ps1 setup -Guest windows -ImageRepo $ImageRepo -Flavour $Flavour'" `
        { Test-FcWinImagePresent $WinRuntime $imageRef }

    Test-Check ">= 4 GiB free disk on C:" `
        "free disk space on C: or run '.\fc.ps1 cleanup -Guest windows'" `
        {
            $drive = Get-PSDrive -Name C -ErrorAction SilentlyContinue
            return ($null -ne $drive -and $drive.Free -ge (4L * 1024 * 1024 * 1024))
        }

    Test-Check ">= 1.5 GiB free physical memory" `
        "close memory-heavy workloads before starting Windows microVMs" `
        {
            $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction SilentlyContinue
            if (-not $os) { return $true }
            return (($os.FreePhysicalMemory / 1024) -ge 1536)
        }

    if ($Boot) {
        if ($script:DoctorFailed) {
            Write-Host "  [SKIP] boot a test Windows Nano Server microVM (fix the failures above first)"
        } else {
            Test-Check "boot a test Windows Nano Server microVM (--isolation=hyperv) and run a command over HVSocket" `
                "inspect runtime logs and run '.\fc.ps1 doctor -Guest windows'" `
                {
                    $testId = New-FcRunId
                    $started = $null
                    try {
                        $started = Start-FcWinMicroVm -RunId $testId -WinRuntime $WinRuntime `
                            -ImageRef $imageRef -Vcpu 1 -MemMib 512 -NetMode 'isolated'
                        $res = Invoke-FcWinGuestCommand -RunId $testId -WinRuntime $WinRuntime `
                            -CommandText 'echo fc-win-ok' -TimeoutSec 60
                        return ($res.ExitCode -eq 0)
                    } finally {
                        $cid = if ($started) { $started.ContainerId } else { '' }
                        Stop-FcWinMicroVmContainer -RunId $testId -WinRuntime $WinRuntime -ContainerId $cid -RemoveContainer $true
                    }
                }
        }
    }

    if ($script:DoctorFailed) {
        Write-Host "Some checks failed."
        return 1
    }
    Write-Host "All checks passed."
    return 0
}
