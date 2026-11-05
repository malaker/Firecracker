<#
.SYNOPSIS
  Create and provision the fc-host WSL2 distro that runs Firecracker microVMs.
  Idempotent: re-running only repairs what is missing.
#>
[CmdletBinding()]
param(
    # Don't ask before changing .wslconfig / restarting WSL.
    [switch]$Yes
)

$ErrorActionPreference = 'Stop'
$env:WSL_UTF8 = '1'   # make wsl.exe print UTF-8 instead of UTF-16
$Distro = 'fc-host'
$RepoRoot = Split-Path -Parent $PSScriptRoot

function ConvertTo-WslPath([string]$Path) {
    $full = (Resolve-Path -LiteralPath $Path).Path
    '/mnt/' + $full.Substring(0, 1).ToLower() + ($full.Substring(2) -replace '\\', '/')
}

function Test-Distro {
    $names = wsl.exe --list --quiet | ForEach-Object { $_.Trim() }
    $names -contains $Distro
}

function Invoke-Root([string[]]$Cmd) {
    # Send output to the console so the function returns only the exit code.
    & wsl.exe -d $Distro -u root -e @Cmd | Out-Host
    $LASTEXITCODE
}

function Confirm-Change([string]$Question) {
    if ($Yes) { return $true }
    (Read-Host "$Question [y/N]") -match '^(y|yes)$'
}

function Enable-NestedVirtualization {
    $cfg = Join-Path $env:USERPROFILE '.wslconfig'
    $content = if (Test-Path $cfg) { Get-Content -LiteralPath $cfg -Raw } else { '' }

    if ($content -match '(?im)^\s*nestedVirtualization\s*=\s*true\s*$') {
        throw "nestedVirtualization is already enabled in $cfg but /dev/kvm is still missing. Check that virtualization (VT-x) is enabled in firmware and run 'wsl --shutdown'."
    }

    Write-Host ""
    Write-Host "/dev/kvm is not available in '$Distro'. Firecracker needs WSL2 nested virtualization."
    Write-Host "Setup will:"
    Write-Host "  1. set 'nestedVirtualization=true' under [wsl2] in $cfg (backup: $cfg.bak)"
    Write-Host "  2. run 'wsl --shutdown', which stops ALL running WSL distros (including podman machines)"
    if (-not (Confirm-Change 'Proceed?')) {
        Write-Host "No changes made. To do it yourself: add the line above to $cfg, run 'wsl --shutdown', then rerun setup."
        exit 1
    }

    if (Test-Path $cfg) { Copy-Item -LiteralPath $cfg -Destination "$cfg.bak" -Force }
    if ($content -match '(?im)^\s*nestedVirtualization\s*=.*$') {
        $content = $content -replace '(?im)^\s*nestedVirtualization\s*=.*$', 'nestedVirtualization=true'
    } elseif ($content -match '(?im)^\s*\[wsl2\]\s*$') {
        $content = $content -replace '(?im)^(\s*\[wsl2\]\s*)$', "`$1`r`nnestedVirtualization=true"
    } else {
        $content = $content.TrimEnd() + "`r`n[wsl2]`r`nnestedVirtualization=true`r`n"
        $content = $content.TrimStart()
    }
    Set-Content -LiteralPath $cfg -Value $content -NoNewline -Encoding utf8
    Write-Host "Updated $cfg; restarting WSL..."
    wsl.exe --shutdown

    if ((Invoke-Root @('test', '-c', '/dev/kvm')) -ne 0) {
        throw "/dev/kvm is still missing after enabling nested virtualization. Check that VT-x is enabled in firmware."
    }
}

# 1. Dedicated distro (other distros are never touched).
if (-not (Test-Distro)) {
    Write-Host "Creating WSL distro '$Distro' (Ubuntu 24.04)..."
    wsl.exe --install Ubuntu-24.04 --name $Distro --no-launch
    if ($LASTEXITCODE -ne 0 -or -not (Test-Distro)) { throw "Failed to create the '$Distro' distro." }
}
# Launching as root skips the interactive first-user setup.
if ((Invoke-Root @('true')) -ne 0) { throw "Cannot start the '$Distro' distro." }

# 2. KVM via nested virtualization.
if ((Invoke-Root @('test', '-c', '/dev/kvm')) -ne 0) {
    Enable-NestedVirtualization
}

# 3. Packages, binaries, images, controller.
$repoWsl = ConvertTo-WslPath $RepoRoot
if ((Invoke-Root @('bash', "$repoWsl/host/provision.sh", $repoWsl)) -ne 0) {
    throw "Provisioning failed (see output above)."
}
