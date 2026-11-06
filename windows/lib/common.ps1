# common.ps1 - Shared constants, validation, config and helpers for Windows Nano Server microVMs.
# Change: nanoserver-windows-microvm
Set-StrictMode -Version Latest

$script:EXIT_TIMEOUT        = 124
$script:EXIT_INFRA          = 125
$script:DEFAULT_VCPU        = 2
$script:DEFAULT_MEM_MIB     = 1024
$script:COLLECT_GRACE_SEC   = 30
$script:COLLECT_TIMEOUT_SEC = 120
# Guest-side loopback port of fc-relay, announced through HTTP_PROXY/HTTPS_PROXY.
$script:RELAY_PORT          = 3128
# NAT network created by versions before the egress proxy; only 'cleanup' still touches it.
$script:LEGACY_NAT_NAME     = 'fc-win-nat'
$script:GUEST_USER          = 'ContainerAdministrator'

$script:VALID_FLAVOURS = @(
    'aspnet-x86',
    'aspnet-x64',
    'iis-aspnet-x86',
    'iis-aspnet-x64',
    'iis-netfx-x86',
    'iis-netfx-x64'
)

$script:VALID_WIN_RUNTIMES = @('docker', 'containerd')

function Get-FcWinBaseDir {
    if ($env:FC_WIN_BASE) { return $env:FC_WIN_BASE }
    return 'C:\ProgramData\fc-sandbox-win'
}

function Get-FcWinBinDir   { Join-Path (Get-FcWinBaseDir) 'bin' }
function Get-FcWinVmsDir   { Join-Path (Get-FcWinBaseDir) 'vms' }
function Get-FcWinCfgPath  { Join-Path (Get-FcWinBaseDir) 'config.json' }

# Parses a .psd1 data file in restricted language mode (works on hosts where
# Import-PowerShellDataFile is unavailable).
function Import-FcPsd1([string]$LiteralPath) {
    $raw = Get-Content -LiteralPath $LiteralPath -Raw
    # Strip trailing Authenticode signature block before AST restricted-language evaluation.
    $clean = $raw -replace '(?ms)^# SIG # Begin signature block.*$', ''
    $sb = [scriptblock]::Create($clean)
    $sb.CheckRestrictedLanguage([string[]]@(), [string[]]@(), $false)
    return (& $sb)
}

function Get-FcVersionsData {
    Import-FcPsd1 (Join-Path (Split-Path -Parent $PSScriptRoot) 'versions.psd1')
}

function Write-FcLog([string]$Message) {
    [Console]::Error.WriteLine("[fc-win] $Message")
}

function Stop-FcWithError([string]$Message, [int]$ExitCode = 125) {
    [Console]::Error.WriteLine("[fc-win] ERROR: $Message")
    exit $ExitCode
}

# Invokes a native executable without PowerShell 5.1 turning stderr lines into
# terminating NativeCommandError exceptions when $ErrorActionPreference = 'Stop'.
function Invoke-FcNative {
    param(
        [Parameter(Mandatory = $true)][string]$Exe,
        [string[]]$ArgList = @(),
        [switch]$Passthru
    )
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        if ($Passthru) {
            & $Exe @ArgList | Out-Host
            return @{ ExitCode = $LASTEXITCODE; Output = '' }
        }
        $out = & $Exe @ArgList 2>&1
        $text = (($out | ForEach-Object { "$_" }) -join "`n").Trim()
        return @{ ExitCode = $LASTEXITCODE; Output = $text }
    } finally {
        $ErrorActionPreference = $prev
    }
}

function Get-IsoTimestamp {
    (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
}

function New-FcRunId {
    $stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss')
    $bytes = New-Object byte[] 2
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    return "$stamp-" + (($bytes | ForEach-Object { $_.ToString('x2') }) -join '')
}

function ConvertFrom-Duration([string]$Duration) {
    if ($Duration -notmatch '^(\d+)([smh]?)$') {
        throw "Invalid duration '$Duration': expected <number>[s|m|h], e.g. 90s, 10m, 1h."
    }
    $num = [int]$Matches[1]
    $seconds = switch ($Matches[2]) {
        'h' { $num * 3600 }
        'm' { $num * 60 }
        default { $num }
    }
    if ($seconds -le 0) { throw "Invalid duration '$Duration': timeout must be greater than 0." }
    return $seconds
}

function Assert-ValidFlavour([string]$Flavour) {
    if ($script:VALID_FLAVOURS -notcontains $Flavour) {
        throw "Invalid Nano Server flavour '$Flavour'. Valid flavours: $($script:VALID_FLAVOURS -join ', ')"
    }
}

function Assert-ValidWinRuntime([string]$WinRuntime) {
    if ($script:VALID_WIN_RUNTIMES -notcontains $WinRuntime) {
        throw "Invalid Windows runtime '$WinRuntime'. Valid runtimes: $($script:VALID_WIN_RUNTIMES -join ', ')"
    }
}

# The one list of features a runtime backend cannot support. The controller and setup refuse
# them up front (Assert-FcWinFeatureSupported), doctor prints them, the smoke suite skips and
# probes them, and README's "containerd limitations" section mirrors this list.
$script:WIN_RUNTIME_LIMITATIONS = @(
    [pscustomobject]@{
        Feature  = 'build-from-source'
        Flag     = '-BuildFromSource'
        Runtimes = @('containerd')
        Reason   = 'nerdctl builds need BuildKit, which has no supported Windows container builder'
    }
)

function Get-FcWinRuntimeLimitations([string]$WinRuntime) {
    @($script:WIN_RUNTIME_LIMITATIONS | Where-Object { $_.Runtimes -contains $WinRuntime })
}

function Test-FcWinFeatureSupported([string]$Feature, [string]$WinRuntime) {
    -not (Get-FcWinRuntimeLimitations $WinRuntime | Where-Object { $_.Feature -eq $Feature })
}

# Exits 125 before anything is started or changed when $Feature is unsupported on $WinRuntime.
function Assert-FcWinFeatureSupported([string]$Feature, [string]$WinRuntime) {
    $lim = Get-FcWinRuntimeLimitations $WinRuntime | Where-Object { $_.Feature -eq $Feature } | Select-Object -First 1
    if ($lim) {
        Stop-FcWithError "$($lim.Flag) is not supported with -WinRuntime ${WinRuntime}: $($lim.Reason). Use -WinRuntime docker." $script:EXIT_INFRA
    }
}

# Returns the normalised list of IPv4 CIDRs (bare addresses become /32).
function Assert-ValidCidrList([string]$AllowCsv) {
    $cidrs = @()
    if ([string]::IsNullOrWhiteSpace($AllowCsv)) { return ,$cidrs }
    foreach ($raw in ($AllowCsv -split ',')) {
        $c = $raw.Trim()
        if (-not $c) { continue }
        if ($c -notmatch '^(\d{1,3}\.){3}\d{1,3}(/\d{1,2})?$') { throw "Invalid CIDR '$c' in -Allow." }
        $parts = $c -split '/'
        # Same strict form as fc-egress (Cidr.Parse): octets 0-255 without leading zeros, so an
        # entry accepted here can never make the egress proxy refuse to start.
        foreach ($octet in ($parts[0] -split '\.')) {
            if (($octet.Length -gt 1 -and $octet[0] -eq '0') -or [int]$octet -gt 255) {
                throw "Invalid IPv4 address in CIDR '$c' (octets must be 0-255 without leading zeros)."
            }
        }
        if ($parts.Count -eq 2) {
            if ([int]$parts[1] -gt 32) { throw "Invalid prefix length in CIDR '$c'." }
            $cidrs += $c
        } else {
            $cidrs += "$c/32"
        }
    }
    return ,$cidrs
}

function Assert-ValidResources([int]$Vcpu, [int]$MemMib) {
    $maxCpus = [Math]::Min(32, [Environment]::ProcessorCount)
    if ($Vcpu -lt 1 -or $Vcpu -gt $maxCpus) {
        throw "Invalid vCPU count '$Vcpu': must be between 1 and $maxCpus on this host."
    }
    if ($MemMib -lt 128) { throw "Invalid memory '${MemMib}MiB': must be at least 128 MiB." }
    $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction SilentlyContinue
    if ($os) {
        $freeMib = [int][Math]::Floor($os.FreePhysicalMemory / 1024)
        if ($MemMib -gt $freeMib) {
            throw "Requested memory (${MemMib} MiB) exceeds free host physical memory (${freeMib} MiB)."
        }
    }
}

function Get-FcWinConfig {
    $defaults = Get-FcVersionsData
    $cfg = [ordered]@{
        win_runtime     = $defaults.DefaultRuntime
        image_repo      = $defaults.ImageRepo
        default_flavour = $defaults.DefaultFlavour
    }
    $cfgPath = Get-FcWinCfgPath
    if (Test-Path -LiteralPath $cfgPath) {
        $raw = Get-Content -LiteralPath $cfgPath -Raw | ConvertFrom-Json
        foreach ($key in @('win_runtime', 'image_repo', 'default_flavour')) {
            $prop = $raw.PSObject.Properties[$key]
            if ($prop -and $prop.Value) { $cfg[$key] = [string]$prop.Value }
        }
    }
    return $cfg
}

function Test-FcWinConfigured {
    Test-Path -LiteralPath (Get-FcWinCfgPath)
}

function Save-FcWinConfig([string]$WinRuntime, [string]$ImageRepo, [string]$DefaultFlavour) {
    Assert-ValidWinRuntime $WinRuntime
    Assert-ValidFlavour $DefaultFlavour
    New-Item -ItemType Directory -Force -Path (Get-FcWinBaseDir) | Out-Null
    [ordered]@{
        win_runtime     = $WinRuntime
        image_repo      = $ImageRepo
        default_flavour = $DefaultFlavour
        updated_at      = Get-IsoTimestamp
    } | ConvertTo-Json | Set-Content -LiteralPath (Get-FcWinCfgPath) -Encoding utf8
}

function Test-FcAdmin {
    $principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-IsIisFlavour([string]$Flavour) {
    return $Flavour.StartsWith('iis-', [System.StringComparison]::OrdinalIgnoreCase)
}

function Get-FcFileSha256([string]$FilePath) {
    $stream = [System.IO.File]::OpenRead((Resolve-Path -LiteralPath $FilePath).Path)
    try {
        $hash = [System.Security.Cryptography.SHA256]::Create().ComputeHash($stream)
        return (($hash | ForEach-Object { $_.ToString('x2') }) -join '')
    } finally {
        $stream.Dispose()
    }
}

# Quotes an argument list into one Windows command line following the
# CommandLineToArgvW rules, so arguments survive Process.Start unchanged.
function ConvertTo-FcArgString([string[]]$ArgList) {
    $quoted = foreach ($a in $ArgList) {
        if ($a -ne '' -and $a -notmatch '[\s"]') { $a; continue }
        $sb = [System.Text.StringBuilder]::new()
        [void]$sb.Append('"')
        $backslashes = 0
        foreach ($ch in $a.ToCharArray()) {
            if ($ch -eq [char]'\') { $backslashes++; continue }
            if ($ch -eq [char]'"') {
                [void]$sb.Append([char]'\', 2 * $backslashes + 1)
                [void]$sb.Append('"')
            } else {
                if ($backslashes) { [void]$sb.Append([char]'\', $backslashes) }
                [void]$sb.Append($ch)
            }
            $backslashes = 0
        }
        if ($backslashes) { [void]$sb.Append([char]'\', 2 * $backslashes) }
        [void]$sb.Append('"')
        $sb.ToString()
    }
    return ($quoted -join ' ')
}

# Writes text with LF line endings (matches the Linux controller's result files).
function Write-FcTextFile([string]$Path, [string]$Text) {
    [System.IO.File]::WriteAllText($Path, $Text.Replace("`r`n", "`n"), [System.Text.UTF8Encoding]::new($false))
}

# Requires an elevated prompt: the Docker engine pipe is admin-only.
function Assert-FcAdmin {
    if (-not (Test-FcAdmin)) {
        Stop-FcWithError "Windows microVM commands need an elevated (Administrator) PowerShell prompt: the Docker engine pipe is admin-only." $script:EXIT_INFRA
    }
}
