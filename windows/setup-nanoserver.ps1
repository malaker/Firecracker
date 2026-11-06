<#
.SYNOPSIS
  Bootstrap and verify the Windows Hyper-V microVM host for Nano Server guests.
  Idempotent: re-running skips already-installed runtime binaries and images.
#>
[CmdletBinding()]
param(
    [string]$WinRuntime,
    [string]$ImageRepo,
    [string]$Flavour,
    [switch]$BuildFromSource,
    [string]$SourceDir,
    [string]$NanoBase,
    [switch]$Yes
)

$ErrorActionPreference = 'Stop'
$RepoRoot = Split-Path -Parent $PSScriptRoot

. (Join-Path $PSScriptRoot 'lib\common.ps1')
. (Join-Path $PSScriptRoot 'lib\runtime.ps1')
. (Join-Path $PSScriptRoot 'lib\egress.ps1')

$cfg = Get-FcWinConfig
$versions = Get-FcVersionsData

if (-not $WinRuntime) { $WinRuntime = $cfg.win_runtime }
if (-not $ImageRepo)  { $ImageRepo  = $cfg.image_repo }
if (-not $Flavour)    { $Flavour    = $cfg.default_flavour }
if (-not $SourceDir)  { $SourceDir  = Join-Path $RepoRoot 'externalimages' }

Assert-ValidWinRuntime $WinRuntime
Assert-ValidFlavour $Flavour

function Confirm-FcChange([string]$Question) {
    if ($Yes) { return $true }
    $ans = Read-Host "$Question [y/N]"
    return ($ans -match '^(y|yes)$')
}

function Invoke-VerifiedDownload([string]$Name, [string]$Url, [string]$ExpectedSha256, [string]$DestPath) {
    if (Test-Path -LiteralPath $DestPath) {
        $existingHash = Get-FcFileSha256 $DestPath
        if ($existingHash -eq $ExpectedSha256.ToLower()) {
            Write-FcLog "Cached artifact '$Name' verified ($existingHash)."
            return
        }
        Remove-Item -LiteralPath $DestPath -Force -ErrorAction SilentlyContinue
    }
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $DestPath) | Out-Null
    Write-FcLog "Downloading '$Name' from $Url..."
    $ProgressPreference = 'SilentlyContinue'
    Invoke-WebRequest -Uri $Url -OutFile $DestPath -UseBasicParsing
    $actualHash = Get-FcFileSha256 $DestPath
    if ($actualHash -ne $ExpectedSha256.ToLower()) {
        Remove-Item -LiteralPath $DestPath -Force -ErrorAction SilentlyContinue
        Stop-FcWithError "Checksum mismatch for artifact '$Name' (expected $ExpectedSha256, got $actualHash)." 1
    }
}

# 1. Check early if -BuildFromSource was requested with a missing source directory or unsupported runtime.
if ($BuildFromSource) {
    Assert-FcWinFeatureSupported 'build-from-source' $WinRuntime
    $resolvedSrc = Resolve-FcNanoserverSourceDir $SourceDir $Flavour
    if (-not $resolvedSrc) {
        Stop-FcWithError "Nano Server source directory '$SourceDir' not found or missing nanoserver-$Flavour\Dockerfile. Clone https://github.com/malaker/nanoserver into '$SourceDir' or link C:\sources\nanoserver (e.g. cmd /c mklink /J `"$SourceDir`" C:\sources\nanoserver)." 1
    }
}

# 2. Check Windows optional features (Microsoft-Hyper-V and Containers).
$missingFeatures = @()
foreach ($feat in @('Microsoft-Hyper-V', 'Containers')) {
    if (-not (Test-FcWindowsFeatureEnabled $feat)) {
        $missingFeatures += $feat
    }
}

if ($missingFeatures.Count -gt 0) {
    Write-Host ""
    Write-Host "Windows microVMs require the following Windows optional features: $($missingFeatures -join ', ')."
    Write-Host "Setup will enable $($missingFeatures -join ', ') via Enable-WindowsOptionalFeature (a reboot may be required)."
    if (-not (Confirm-FcChange 'Enable required Windows features now?')) {
        Write-Host "No changes made. To enable manually in an elevated PowerShell prompt:"
        Write-Host "  Enable-WindowsOptionalFeature -Online -FeatureName $($missingFeatures -join ',') -All"
        exit 1
    }
    if (-not (Test-FcAdmin)) {
        Stop-FcWithError "Administrator privileges are required to enable Windows features ($($missingFeatures -join ', ')). Re-run in an elevated PowerShell prompt." 1
    }
    $restartNeeded = $false
    foreach ($feat in $missingFeatures) {
        Write-FcLog "Enabling Windows feature '$feat'..."
        $res = Enable-WindowsOptionalFeature -Online -FeatureName $feat -All -NoRestart
        if ($res.RestartNeeded) { $restartNeeded = $true }
    }
    if ($restartNeeded) {
        Write-FcLog "Windows feature enablement requires a system restart. Please reboot Windows and re-run '.\fc.ps1 setup -Guest windows'."
        exit 1
    }
}

# 3. Install and start the selected Windows microVM runtime (docker or containerd).
Assert-FcAdmin
$binDir = Get-FcWinBinDir
$cacheDir = Join-Path $RepoRoot '.cache'
New-Item -ItemType Directory -Force -Path $binDir, $cacheDir | Out-Null

if ($WinRuntime -eq 'docker') {
    if (-not (Test-FcWinRuntimeBinariesPresent 'docker')) {
        $zipPath = Join-Path $cacheDir "docker-$($versions.Docker.Version).zip"
        Invoke-VerifiedDownload -Name "docker-$($versions.Docker.Version).zip" `
            -Url $versions.Docker.Url -ExpectedSha256 $versions.Docker.Sha256 -DestPath $zipPath
        $extractDir = Join-Path $cacheDir 'docker-extract'
        if (Test-Path -LiteralPath $extractDir) { Remove-Item -LiteralPath $extractDir -Recurse -Force }
        Expand-Archive -LiteralPath $zipPath -DestinationPath $extractDir -Force
        Copy-Item -Path (Join-Path $extractDir 'docker\*') -Destination $binDir -Force
        Remove-Item -LiteralPath $extractDir -Recurse -Force
    }
    # Configure public DNS in daemon.json so docker build can reach Windows Update / FOD servers
    # even when a host VPN adapter sets a tunnel-local DNS server (runtime VMs always pass --isolation=hyperv).
    $dockerCfgDir = 'C:\ProgramData\docker\config'
    New-Item -ItemType Directory -Force -Path $dockerCfgDir | Out-Null
    $daemonJsonPath = Join-Path $dockerCfgDir 'daemon.json'
    $daemonChanged = Set-FcDockerDaemonDns -Path $daemonJsonPath -Dns @('1.1.1.1', '8.8.8.8')
    $svc = Get-Service -Name 'docker' -ErrorAction SilentlyContinue
    if (-not $svc) {
        [void](Invoke-FcNative -Exe (Get-FcDockerdExe) -ArgList @('--register-service'))
    }
    if (-not (Test-FcWinRuntimeReady 'docker')) {
        Start-Service -Name 'docker'
    } elseif ($daemonChanged) {
        Write-FcLog "Restarting 'docker' service to apply updated daemon.json DNS configuration..."
        Restart-Service -Name 'docker'
    } else {
        Write-FcLog "Windows runtime 'docker' is already installed and running."
    }
    # Ensure IPv4 forwarding is enabled on Docker's default NAT vSwitch, which 'docker build'
    # containers use to download installers (VPN clients like ProtonVPN disable it). MicroVM
    # guests never get an adapter, so this does not affect their isolation.
    Get-NetIPInterface -InterfaceAlias 'vEthernet (*nat*)' -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.Forwarding -ne 'Enabled' } |
        Set-NetIPInterface -Forwarding Enabled -ErrorAction SilentlyContinue
} else {
    Write-FcLog "NOTE: runtime 'containerd' (nerdctl + runhcs-v1) is experimental on Windows."
    if (Test-FcWinRuntimeReady 'containerd') {
        Write-FcLog "Windows runtime 'containerd' is already installed and running."
    } else {
        if (-not (Test-FcWinRuntimeBinariesPresent 'containerd')) {
            $ctdTar = Join-Path $cacheDir "containerd-$($versions.Containerd.Version)-windows-amd64.tar.gz"
            Invoke-VerifiedDownload -Name "containerd-$($versions.Containerd.Version)-windows-amd64.tar.gz" `
                -Url $versions.Containerd.Url -ExpectedSha256 $versions.Containerd.Sha256 -DestPath $ctdTar
            [void](Invoke-FcNative -Exe 'tar.exe' -ArgList @('-xzf', $ctdTar, '--strip-components=1', '-C', $binDir))

            $nerdTar = Join-Path $cacheDir "nerdctl-$($versions.Nerdctl.Version)-windows-amd64.tar.gz"
            Invoke-VerifiedDownload -Name "nerdctl-$($versions.Nerdctl.Version)-windows-amd64.tar.gz" `
                -Url $versions.Nerdctl.Url -ExpectedSha256 $versions.Nerdctl.Sha256 -DestPath $nerdTar
            [void](Invoke-FcNative -Exe 'tar.exe' -ArgList @('-xzf', $nerdTar, '-C', $binDir))
        }
        $svc = Get-Service -Name 'containerd' -ErrorAction SilentlyContinue
        if (-not $svc) {
            [void](Invoke-FcNative -Exe (Get-FcContainerdExe) -ArgList @('--register-service'))
        }
        Start-Service -Name 'containerd'
    }
}

# 4. Persist Windows configuration.
Save-FcWinConfig -WinRuntime $WinRuntime -ImageRepo $ImageRepo -DefaultFlavour $Flavour

# 5. Provision the Nano Server guest image (pull or local build from ./externalimages).
$imageRef = Get-FcImageReference $ImageRepo $Flavour
if ($BuildFromSource) {
    Invoke-FcWinImageBuild -WinRuntime $WinRuntime -SourceRoot $SourceDir -Flavour $Flavour -ImageRef $imageRef -NanoBase $NanoBase
} else {
    if (Test-FcWinImagePresent $WinRuntime $imageRef) {
        Write-FcLog "Nano Server image '$imageRef' is already present; all components are up to date."
    } else {
        Invoke-FcWinImagePull -WinRuntime $WinRuntime -ImageRef $imageRef
    }
}

# 6. Build the networked-mode egress proxy (host) and relay (guest).
[void](Install-FcWinEgress (Join-Path $PSScriptRoot 'egress'))

Write-FcLog "Windows Nano Server microVM setup complete (runtime=$WinRuntime, image=$imageRef)."
exit 0
