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
# SIG # Begin signature block
# MIInggYJKoZIhvcNAQcCoIInczCCJ28CAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCD6g6hevNVr2cqm
# ig8hkAUegPXOVy45P/upPCAu7i/utqCCIDYwggXJMIIEsaADAgECAhAbtY8lKt8j
# AEkoya49fu0nMA0GCSqGSIb3DQEBDAUAMH4xCzAJBgNVBAYTAlBMMSIwIAYDVQQK
# ExlVbml6ZXRvIFRlY2hub2xvZ2llcyBTLkEuMScwJQYDVQQLEx5DZXJ0dW0gQ2Vy
# dGlmaWNhdGlvbiBBdXRob3JpdHkxIjAgBgNVBAMTGUNlcnR1bSBUcnVzdGVkIE5l
# dHdvcmsgQ0EwHhcNMjEwNTMxMDY0MzA2WhcNMjkwOTE3MDY0MzA2WjCBgDELMAkG
# A1UEBhMCUEwxIjAgBgNVBAoTGVVuaXpldG8gVGVjaG5vbG9naWVzIFMuQS4xJzAl
# BgNVBAsTHkNlcnR1bSBDZXJ0aWZpY2F0aW9uIEF1dGhvcml0eTEkMCIGA1UEAxMb
# Q2VydHVtIFRydXN0ZWQgTmV0d29yayBDQSAyMIICIjANBgkqhkiG9w0BAQEFAAOC
# Ag8AMIICCgKCAgEAvfl4+ObVgAxknYYblmRnPyI6HnUBfe/7XGeMycxca6mR5rlC
# 5SBLm9qbe7mZXdmbgEvXhEArJ9PoujC7Pgkap0mV7ytAJMKXx6fumyXvqAoAl4Va
# qp3cKcniNQfrcE1K1sGzVrihQTib0fsxf4/gX+GxPw+OFklg1waNGPmqJhCrKtPQ
# 0WeNG0a+RzDVLnLRxWPa52N5RH5LYySJhi40PylMUosqp8DikSiJucBb+R3Z5yet
# /5oCl8HGUJKbAiy9qbk0WQq/hEr/3/6zn+vZnuCYI+yma3cWKtvMrTscpIfcRnNe
# GWJoRVfkkIJCu0LW8GHgwaM9ZqNd9BjuiMmNF0UpmTJ1AjHuKSbIawLmtWJFfzcV
# WiNoidQ+3k4nsPBADLxNF8tNorMe0AZa3faTz1d1mfX6hhpneLO/lv403L3nUlbl
# s+V1e9dBkQXcXWnjlQ1DufyDljmVe2yAWk8TcsbXfSl6RLpSpCrVQUYJIP4ioLZb
# MI28iQzV13D4h1L92u+sUS4Hs07+0AnacO+Y+lbmbdu1V0vc5SwlFcieLnhO+Nqc
# noYsylfzGuXIkosagpZ6w7xQEmnYDlpGizrrJvojybawgb5CAKT41v4wLsfSRvbl
# jnX98sy50IdbzAYQYLuDNbdeZ95H7JlI8aShFf6tjGKOOVVPORa5sWOd/7cCAwEA
# AaOCAT4wggE6MA8GA1UdEwEB/wQFMAMBAf8wHQYDVR0OBBYEFLahVDkCw6A/joq8
# +tT4HKbROg79MB8GA1UdIwQYMBaAFAh2zcsH/yT2xc3tu5C84oQ3RnX3MA4GA1Ud
# DwEB/wQEAwIBBjAvBgNVHR8EKDAmMCSgIqAghh5odHRwOi8vY3JsLmNlcnR1bS5w
# bC9jdG5jYS5jcmwwawYIKwYBBQUHAQEEXzBdMCgGCCsGAQUFBzABhhxodHRwOi8v
# c3ViY2Eub2NzcC1jZXJ0dW0uY29tMDEGCCsGAQUFBzAChiVodHRwOi8vcmVwb3Np
# dG9yeS5jZXJ0dW0ucGwvY3RuY2EuY2VyMDkGA1UdIAQyMDAwLgYEVR0gADAmMCQG
# CCsGAQUFBwIBFhhodHRwOi8vd3d3LmNlcnR1bS5wbC9DUFMwDQYJKoZIhvcNAQEM
# BQADggEBAFHCoVgWIhCL/IYx1MIy01z4S6Ivaj5N+KsIHu3V6PrnCA3st8YeDrJ1
# BXqxC/rXdGoABh+kzqrya33YEcARCNQOTWHFOqj6seHjmOriY/1B9ZN9DbxdkjuR
# mmW60F9MvkyNaAMQFtXx0ASKhTP5N+dbLiZpQjy6zbzUeulNndrnQ/tjUoCFBMQl
# lVXwfqefAcVbKPjgzoZwpic7Ofs4LphTZSJ1Ldf23SIikZbr3WjtP6MZl9M7JYjs
# NhI9qX7OAo0FmpKnJ25FspxihjcNpDOO16hO0EoXQ0zF8ads0h5YbBRRfopUofbv
# n3l6XYGaFpAP4bvxSgD5+d2+7arszgowggZlMIIETaADAgECAhAjm5lqXajjdfXL
# KmfgR1EvMA0GCSqGSIb3DQEBCwUAMFYxCzAJBgNVBAYTAlBMMSEwHwYDVQQKExhB
# c3NlY28gRGF0YSBTeXN0ZW1zIFMuQS4xJDAiBgNVBAMTG0NlcnR1bSBDb2RlIFNp
# Z25pbmcgMjAyMSBDQTAeFw0yNTExMDUxNzUxMTlaFw0yNjExMDUxNzUxMThaMIGK
# MQswCQYDVQQGEwJQTDESMBAGA1UECAwJcG9tb3Jza2llMRAwDgYDVQQHDAdHZGHF
# hHNrMR4wHAYDVQQKDBVPcGVuIFNvdXJjZSBEZXZlbG9wZXIxNTAzBgNVBAMMLE9w
# ZW4gU291cmNlIERldmVsb3BlciwgS3J6eXN6dG9mIEJhbGNlcm93c2tpMIIBojAN
# BgkqhkiG9w0BAQEFAAOCAY8AMIIBigKCAYEAtO9bgiQpVXH07DAskdvEFW/y87Yi
# EMsSnUeXVI3t1msP0inDc9Bl1pQdWZdD4yY9JVCigPuaBqa+uCTr0EHXjxvbV+Rt
# pzaMkt1kfyxm+sm4uNe8qUi+KIkBm2cB4EmU6YQriTGoNouOteM/Zj5ezeNrnGx5
# wi1isFeyXy6o5XD0uiEkCqn+Kysex1M2uv+zfdFMby+BDNnwmj1QSDBrSm97EMwM
# 07/li8B+8fM/pnS8afg7u+8ljJ9WKwfDag0eLHTTJTI6PO52hSJIt23AWA9b/zCT
# LGnSKkjbwk61OAoYwYOeqaWETqTAxeoYM+SY4hGH62NosRs/QLquSzpz+Hhwhlzx
# dxQXmnjKQkKD5arj/1YnQOAqVZKyDjtYuR2wc/tlznqvLsCmTcmtzA9Hphs8oB0L
# xYkGAt/BFyq1wIYqojrLoBL8RtNwrw9jhFm7IkIBzkbImVv5bY711zw3tnyBRJnm
# hz0IpUMl7U+X7DgTwpiYKIyS4HOo+wWXzReNAgMBAAGjggF4MIIBdDAMBgNVHRMB
# Af8EAjAAMD0GA1UdHwQ2MDQwMqAwoC6GLGh0dHA6Ly9jY3NjYTIwMjEuY3JsLmNl
# cnR1bS5wbC9jY3NjYTIwMjEuY3JsMHMGCCsGAQUFBwEBBGcwZTAsBggrBgEFBQcw
# AYYgaHR0cDovL2Njc2NhMjAyMS5vY3NwLWNlcnR1bS5jb20wNQYIKwYBBQUHMAKG
# KWh0dHA6Ly9yZXBvc2l0b3J5LmNlcnR1bS5wbC9jY3NjYTIwMjEuY2VyMB8GA1Ud
# IwQYMBaAFN10XUwA23ufoHTKsW73PMAywHDNMB0GA1UdDgQWBBTqEi0Om+CR+PpT
# 0qg1rzMgLU2vWDBLBgNVHSAERDBCMAgGBmeBDAEEATA2BgsqhGgBhvZ3AgUBBDAn
# MCUGCCsGAQUFBwIBFhlodHRwczovL3d3dy5jZXJ0dW0ucGwvQ1BTMBMGA1UdJQQM
# MAoGCCsGAQUFBwMDMA4GA1UdDwEB/wQEAwIHgDANBgkqhkiG9w0BAQsFAAOCAgEA
# VbnUF10ZA48MOfaqrRSTeLLQVK3ZcDLeHWBZIOFW1q/iM0mhDXU3sRur4QzzsK5T
# Hy84Ius2Q+a/bjQFPQTK0OhUej9+pyqMxUIGxqoDjDJkyM9cDlUHDZvnSeSgxtI9
# neDymt+MxwSWtT1wtW4jZgSlcQ6JQrqWPPClgpFp9ZE/Dci8FbnZHp8nXH9pxJef
# 83XgRmAuLRqKCpEhbXdhTWLP4n/FFMkcwq1KS5qp+BRgI4YoPpxyNJjs1C3VM34U
# nICX6zQGSwmKUJS42/XUim4YwWKegZV4CMh2VxyTGp9JOBtbMIOqkhekRWW4YYCq
# 2kePdiaNwzFCO74K5bjYDqaSKCJR0PVJh6ePW3cdJOGPS9M3AJ8qonyS9dKRhwrP
# mGmaA5Sp0aqrwEokALoTyAf/dYpVcZxEQg/rzg/BLbbhpey2PJhxIDZt6n+KO7ck
# +6d6l74p7fvoL86mJca1JUpUdh/2nPX/B+nlb0nVNWZZS2GbVile6i6nA0uU6ufX
# OzrWdpSkz/chD+bulj6ul27E1YKlMvkRxOS4Dv4aNlM8o8gHqZJyBIm833vV35vB
# evRWHtAvV59w4Vy1dKnXqCJIRVGPxagqvulNWZXXgT0PACCDuRyHNDb7dPAYcPSD
# oMSLAFBTUlIMrv3qy3H/dFMYvtkLufKl9PMtDlEs2AYwggaCMIIEaqADAgECAhAo
# 8HfBHDa9/l90MkdwJy4DMA0GCSqGSIb3DQEBDAUAMFYxCzAJBgNVBAYTAlBMMSEw
# HwYDVQQKExhBc3NlY28gRGF0YSBTeXN0ZW1zIFMuQS4xJDAiBgNVBAMTG0NlcnR1
# bSBUaW1lc3RhbXBpbmcgMjAyMSBDQTAeFw0yNjAzMTEwNzM0NTRaFw0zNjAyMjcw
# NzM0NTRaMFAxCzAJBgNVBAYTAlBMMSEwHwYDVQQKDBhBc3NlY28gRGF0YSBTeXN0
# ZW1zIFMuQS4xHjAcBgNVBAMMFUNlcnR1bSBUaW1lc3RhbXAgMjAyNjCCAiIwDQYJ
# KoZIhvcNAQEBBQADggIPADCCAgoCggIBALi9zfBw+xI12hi2F9uNQBNOSTkTIi13
# fuh3DiWybI5392bBfJw6tO7zDs7UqP/rejVf4xFTU3XNOPsuOFkP5SPFsnWwn3VJ
# L+NhNhsuujvYsQtaQnvNo1wk46reTgws1L8OFEdKaxgyqT4zOQx81mLwNZSqXNU9
# Rrb9oAJWJF4Mydz+C1ebu0D0+vgM3tqAQ8TU203fqgKCPqIdHloaFqH9eyR+8tnp
# my2hnnN59ZOtmsuHeRwf5iTOhlhf0d/qqquLOSIGPgGVL1Hj5XBUox2OE7tQRr+l
# /xxNbL6OuwBO4Aa2EbuxYg37cpXv5i2/lTL4NASB/duf9W4fjA3Ro+GP+bC54n2O
# YiM3Cq8z92ejx8F5HWO2e4/75eC95B9tMw/eq7109GDyW2+2ut5Bn0o8MXJTERky
# ystWbqcnUkomA97qfiDCwvpWuOMdfTOksXe9S+xDxOJaCbiyTivgPulxcT+tfQTR
# XBr5UwtPvc+INnafOEilzVHA11tv+pHcylryxBc08cUihf/ttqkZS0bmx3VxQay8
# uohaTp0//ECA9vYGW51SKdJMJhXvKyIdBLy8WYNchTt8yRITv9Adxg9JqGujh+Tn
# P1bW3aQjFtlEl7SzgNeI8OVA/CJAWWUuRT3Au9ToOpHy/flrrknhN4heEw7/6ILM
# v4HSsj0YZ4otAgMBAAGjggFQMIIBTDB1BggrBgEFBQcBAQRpMGcwOwYIKwYBBQUH
# MAKGL2h0dHA6Ly9zdWJjYS5yZXBvc2l0b3J5LmNlcnR1bS5wbC9jdHNjYTIwMjEu
# Y2VyMCgGCCsGAQUFBzABhhxodHRwOi8vc3ViY2Eub2NzcC1jZXJ0dW0uY29tMB8G
# A1UdIwQYMBaAFL5UAi+/QGxzQ86sCSVOnkNEGu7gMAwGA1UdEwEB/wQCMAAwOQYD
# VR0fBDIwMDAuoCygKoYoaHR0cDovL3N1YmNhLmNybC5jZXJ0dW0ucGwvY3RzY2Ey
# MDIxLmNybDAWBgNVHSUBAf8EDDAKBggrBgEFBQcDCDAOBgNVHQ8BAf8EBAMCB4Aw
# IgYDVR0gBBswGTAIBgZngQwBBAIwDQYLKoRoAYb2dwIFAQswHQYDVR0OBBYEFCM5
# aiirmhKnpKfyH/lFmr+N/oIDMA0GCSqGSIb3DQEBDAUAA4ICAQBm/pObrAveTqYF
# PCSthxNVwBHTW4TfuBQY2KGCdMlH6ALjVPYf2XARNGMTXScR0JQ2/c2LxLpoHHhR
# wxFf3d933DhFS165rYj6iPSQKm41rc9AMpTCjMdmai1aK9o870pOzTzLRhWFVIxm
# +5Qf+t4V5z14tPoUsAWdfRKD1Zzvzfe5AHlE9rxOZcGROiULxs3Edf7ZJ8RZI0jz
# D9juj2oEX2XS7BVKuNCK1W0h1mjapv028yqo8UtZh5/1Ib48Yyp88BDYShh5PSGU
# UuS5tYXVfcduIPBe3PdNTYRYdT5VNxkwLgjMzIcr/6SH2fejFJDjnCxjvXLuarEr
# Jg/IdI+hXdGIBDVOGv1zrkF4ktoQvFZIp5DIAYh0GwyUhc87qqn5UaYTj2+iyiBD
# SNh7aGCrkuAnqg7Qh7frhX+QhMGeJ9SpLpnG76qN85hLyjvYR6gRYiLTj8G4fxjq
# V400/buPw0rBo9yJZyq/8cGdCOLPOYf9qpefTcrZKeO9pg+UJHx8UABbaTqizRxm
# 8sUSEycccCCFhIit3AI/3wGuSOADeiA676NcQ7+dsP04YvzvdN7pTZNyg672WpBD
# Jdg0eItHl4yomvNeIOWh1qs4QqOW6TI8Ocsi4uSDTLorxLUDnBTwKQzzpxd1YUct
# EgRh32R0J9FkFkeEruJU94RljFr1uDCCBrkwggShoAMCAQICEQCZo4AKJlU7Zavc
# boSms+o5MA0GCSqGSIb3DQEBDAUAMIGAMQswCQYDVQQGEwJQTDEiMCAGA1UEChMZ
# VW5pemV0byBUZWNobm9sb2dpZXMgUy5BLjEnMCUGA1UECxMeQ2VydHVtIENlcnRp
# ZmljYXRpb24gQXV0aG9yaXR5MSQwIgYDVQQDExtDZXJ0dW0gVHJ1c3RlZCBOZXR3
# b3JrIENBIDIwHhcNMjEwNTE5MDUzMjE4WhcNMzYwNTE4MDUzMjE4WjBWMQswCQYD
# VQQGEwJQTDEhMB8GA1UEChMYQXNzZWNvIERhdGEgU3lzdGVtcyBTLkEuMSQwIgYD
# VQQDExtDZXJ0dW0gQ29kZSBTaWduaW5nIDIwMjEgQ0EwggIiMA0GCSqGSIb3DQEB
# AQUAA4ICDwAwggIKAoICAQCdI88EMCM7wUYs5zNzPmNdenW6vlxNur3rLfi+5OZ+
# U3iZIB+AspO+CC/bj+taJUbMbFP1gQBJUzDUCPx7BNLgid1TyztVLn52NKgxxu8g
# pyTr6EjWyGzKU/gnIu+bHAse1LCitX3CaOE13rbuHbtrxF2tPU8f253QgX6eO8yT
# bGps1Mg+yda3DcTsOYOhSYNCJiL+5wnjZ9weoGRtvFgMHtJg6i671OPXIciiHO4L
# wo2p9xh/tnj+JmCQEn5QU0NxzrOiRna4kjFaA9ZcwSaG7WAxeC/xoZSxF1oK1UPZ
# tKVt+yrsGKqWONoK6f5EmBOAVEK2y4ATDSkb34UD7JA32f+Rm0wsr5ajzftDhA5m
# BipVZDjHpwzv8bTKzCDUSUuUmPo1govD0RwFcTtMXcfJtm1i+P2UNXadPyYVKRxK
# QATHN3imsfBiNRdN5kiVVeqP55piqgxOkyt+HkwIA4gbmSc3hD8ke66t9MjlcNg7
# 3rZZlrLHsAIV/nJ0mmgSjBI/TthoGJDydekOQ2tQD2Dup/+sKQptalDlui59SerV
# SJg8gAeV7N/ia4mrGoiez+SqV3olVfxyLFt3o/OQOnBmjhKUANoKLYlKmUpKEFI0
# PfoT8Q1W/y6s9LTI6ekbi0igEbFUIBE8KDUGfIwnisEkBw5KcBZ3XwnHmfznwlKo
# 8QIDAQABo4IBVTCCAVEwDwYDVR0TAQH/BAUwAwEB/zAdBgNVHQ4EFgQU3XRdTADb
# e5+gdMqxbvc8wDLAcM0wHwYDVR0jBBgwFoAUtqFUOQLDoD+Oirz61PgcptE6Dv0w
# DgYDVR0PAQH/BAQDAgEGMBMGA1UdJQQMMAoGCCsGAQUFBwMDMDAGA1UdHwQpMCcw
# JaAjoCGGH2h0dHA6Ly9jcmwuY2VydHVtLnBsL2N0bmNhMi5jcmwwbAYIKwYBBQUH
# AQEEYDBeMCgGCCsGAQUFBzABhhxodHRwOi8vc3ViY2Eub2NzcC1jZXJ0dW0uY29t
# MDIGCCsGAQUFBzAChiZodHRwOi8vcmVwb3NpdG9yeS5jZXJ0dW0ucGwvY3RuY2Ey
# LmNlcjA5BgNVHSAEMjAwMC4GBFUdIAAwJjAkBggrBgEFBQcCARYYaHR0cDovL3d3
# dy5jZXJ0dW0ucGwvQ1BTMA0GCSqGSIb3DQEBDAUAA4ICAQB1iFgP5Y9QKJpTnxDs
# Q/z0O23JmoZifZdEOEmQvo/79PQg9nLF/GJe6ZiUBEyDBHMtFRK0mXj3Qv3gL0sY
# Xe+PPMfwmreJHvgFGWQ7XwnfMh2YIpBrkvJnjwh8gIlNlUl4KENTK5DLqsYPEtRQ
# Cw7R6p4s2EtWyDDr/M58iY2UBEqfUU/ujR9NuPyKk0bEcEi62JGxauFYzZ/yld13
# fHaZskIoq2XazjaD0pQkcQiIueL0HKiohS6XgZuUtCKA7S6CHttZEsObQJ1j2s0u
# rIDdqF7xaXFVaTHKtAuMfwi0jXtF3JJphrJfc+FFILgCbX/uYBPBlbBIP4Ht4xxk
# 2GmfzMn7oxPITpigQFJFWuzTMUUgdRHTxaTSKRJ/6Uh7ki/pFjf9sUASWgxT69QF
# 9Ki4JF5nBIujxZ2sOU9e1HSCJwOfK07t5nnzbs1LbHuAIGJsRJiQ6HX/DW1XFOlX
# Y1rc9HufFhWU+7Uk+hFkJsfzqBz3pRO+5aI6u5abI4Qws4YaeJH7H7M8X/YNoaAr
# ZbV4Ql+jarKsE0+8XvC4DJB+IVcvC9Ydqahi09mjQse4fxfef0L7E3hho2O3bLDM
# 6v60rIRUCi2fJT2/IRU5ohgyTch4GuYWefSBsp5NPJh4QRTP9DC3gc5QEKtbrTY0
# Ka87Web7/zScvLmvQBm8JDFpDjCCBrkwggShoAMCAQICEQDn/2nHOzXOS5Em2HR8
# aKWHMA0GCSqGSIb3DQEBDAUAMIGAMQswCQYDVQQGEwJQTDEiMCAGA1UEChMZVW5p
# emV0byBUZWNobm9sb2dpZXMgUy5BLjEnMCUGA1UECxMeQ2VydHVtIENlcnRpZmlj
# YXRpb24gQXV0aG9yaXR5MSQwIgYDVQQDExtDZXJ0dW0gVHJ1c3RlZCBOZXR3b3Jr
# IENBIDIwHhcNMjEwNTE5MDUzMjA3WhcNMzYwNTE4MDUzMjA3WjBWMQswCQYDVQQG
# EwJQTDEhMB8GA1UEChMYQXNzZWNvIERhdGEgU3lzdGVtcyBTLkEuMSQwIgYDVQQD
# ExtDZXJ0dW0gVGltZXN0YW1waW5nIDIwMjEgQ0EwggIiMA0GCSqGSIb3DQEBAQUA
# A4ICDwAwggIKAoICAQDpEh8ENe25XXrFppVBvoplf0530W0lddNmjtv4YSh/f7eD
# QKFaIqc7tHj7ox+u8vIsJZlroakUeMS3i3T8aJRC+eQs4FF0GqvkM6+WZO8kmzZf
# xmZaBYmMLs8FktgFYCzywmXeQ1fEExflee2OpbHVk665eXRHjH7MYZIzNnjl2m8H
# y8ulB9mR8wL/W0v0pjKNT6G0sfrx1kk+3OGosFUb7yWNnVkWKU4qSxLv16kJ6oVJ
# 4BSbZ4xMak6JLeB8szrK9vwGDpvGDnKCUMYL3NuviwH1x4gZG0JAXU3x2pOAz91J
# WKJSAmRy/l0s0l5bEYKolg+DMqVhlOANd8Yh5mkQWaMEvBRE/kAGzIqgWhwzN2Os
# KIVtO8mf5sPWSrvyplSABAYa13rMYnzwfg08nljZHghquCJYCa/xHK9acev9UD7Y
# +usr15d7mrszzxhF1JOr1Mpup2chNSBlyOObhlSO16rwrffVrg/SzaKfSndS5swR
# hr8bnDqNJY9TNyEYvBYpgF95K7p0g4LguR4A++Z1nFIHWVY5v0fNVZmgzxD9uVo/
# gta3onGOQj3JCxgYx0KrCXu4yc9QiVwTFLWbNdHFSjBCt5/8Q9pLuRhVocdCunhc
# HudMS1CGQ/Rn0+7P+fzMgWdRKfEOh/hjLrnQ8BdJiYrZNxvIOhM2aa3zEDHNwwID
# AQABo4IBVTCCAVEwDwYDVR0TAQH/BAUwAwEB/zAdBgNVHQ4EFgQUvlQCL79AbHND
# zqwJJU6eQ0Qa7uAwHwYDVR0jBBgwFoAUtqFUOQLDoD+Oirz61PgcptE6Dv0wDgYD
# VR0PAQH/BAQDAgEGMBMGA1UdJQQMMAoGCCsGAQUFBwMIMDAGA1UdHwQpMCcwJaAj
# oCGGH2h0dHA6Ly9jcmwuY2VydHVtLnBsL2N0bmNhMi5jcmwwbAYIKwYBBQUHAQEE
# YDBeMCgGCCsGAQUFBzABhhxodHRwOi8vc3ViY2Eub2NzcC1jZXJ0dW0uY29tMDIG
# CCsGAQUFBzAChiZodHRwOi8vcmVwb3NpdG9yeS5jZXJ0dW0ucGwvY3RuY2EyLmNl
# cjA5BgNVHSAEMjAwMC4GBFUdIAAwJjAkBggrBgEFBQcCARYYaHR0cDovL3d3dy5j
# ZXJ0dW0ucGwvQ1BTMA0GCSqGSIb3DQEBDAUAA4ICAQC4k1l3yUwV/ZQHCKCneqAs
# 8EGTnwEUJLdDpokN/dMhKjK0rR5qX8nIIHzxpQR3TAw2IRw1Uxsr2PliG3bCFqSd
# QTUbfaTq6V3vBzEebDru9QFjqlKnxCF2h1jhLNFFplbPJiW+JSnJTh1fKEqEdKdx
# gl9rVTvlxfEJ7exOn25MGbd/wGPwuSmMxRJVO0wnqgS7kmoJjNF9zqeehFSDDP8Z
# VkWg4EZ2tIS0M3uZmByRr+1Lkwjjt8AtW83mVnZTyTsOb+FNfwJY7DS4FmWhkRbg
# cHRetreoTirPOr/ozyDKhT8MTSTf6Lttg6s6T/u08mDWw6HK04ZRDfQ9sb77QV8m
# KgO44WGP31vXnVKoWVJpFBjPvjL8/Zck/5wXX2iqjOaLStFOR/IQki+Ehn4zlcgV
# m22ZVCBPF+l8nAwUUShCtKuSU7GmZLKCmmxQMkSiWILTm8EtVD6AxnJhoq8EnhjE
# EyUoflkeRF2WhFiVQOmWTwZRr44IxWGkNJC6tTorW5rl2Zl+2e9JLPYf3pStAPMD
# oPKIjVXd6NW2+fZrNUBeDo2eOa5Fn7Brs/HLQff5Xgris5MeUbdVgDrF8uxO6cLP
# vZPo63j62SsNg55pTWk9fUIF9iPoRbb4QurjoY/woI1RAOKtYtTic6aAJq3u83RI
# PpGXBSJKwx4KJAOZnCDCtTGCBqIwggaeAgEBMGowVjELMAkGA1UEBhMCUEwxITAf
# BgNVBAoTGEFzc2VjbyBEYXRhIFN5c3RlbXMgUy5BLjEkMCIGA1UEAxMbQ2VydHVt
# IENvZGUgU2lnbmluZyAyMDIxIENBAhAjm5lqXajjdfXLKmfgR1EvMA0GCWCGSAFl
# AwQCAQUAoIGEMBgGCisGAQQBgjcCAQwxCjAIoAKAAKECgAAwGQYJKoZIhvcNAQkD
# MQwGCisGAQQBgjcCAQQwHAYKKwYBBAGCNwIBCzEOMAwGCisGAQQBgjcCARUwLwYJ
# KoZIhvcNAQkEMSIEICMiwiTM5auKhRvReji59gOzYv2qtfBzIeGt7N6EcHXrMA0G
# CSqGSIb3DQEBAQUABIIBgEbyOvVBcb2bRbSPcrrlWQeFo5IlubNACbDDLI+l73JZ
# J266o8Iq4is+0WMjyA2mm6/+SgRkWrZ2AAKrv6/X/IEsRIG6Y6t7Uze5bQx3lWEY
# eC9yQ6uHgoJmlIGSy3ZUNaixMGOkuRYcHl56DrKw23JVngGcASdajEcHpr8hFb4f
# r92WQcY6aJroYKvKuDJrw9RSgFGyLbM/mkKNnC0OO0xwuTd9yq4vSAtmQiKbz45I
# I4APgnpmlxywpYqrJeHgQ6A80EGl99cRNuTSEll+mm4CH1cdEd7pYzKkQ/G7EpUC
# O/0OeYUOymD1wcDJahdbgEJnmgAAuqV8jC74gmWgdYqH54aO1LgXffXaBhkjSNP5
# rDGwz+TwTHPS3twajKxd26J7l2VEPesB4EGKAW4BqrU4YvaDKL6LG1V6LejQ2Pjx
# 8NsOHtPWbTAKO9fugEFcGqAZ9arZO88kP45WSRWoIvej1C9eALs55NhniTt6U0OE
# HHrwazxp/ntJ9HZEjG5BlqGCBAIwggP+BgkqhkiG9w0BCQYxggPvMIID6wIBATBq
# MFYxCzAJBgNVBAYTAlBMMSEwHwYDVQQKExhBc3NlY28gRGF0YSBTeXN0ZW1zIFMu
# QS4xJDAiBgNVBAMTG0NlcnR1bSBUaW1lc3RhbXBpbmcgMjAyMSBDQQIQKPB3wRw2
# vf5fdDJHcCcuAzANBglghkgBZQMEAgIFAKCCAVYwGgYJKoZIhvcNAQkDMQ0GCyqG
# SIb3DQEJEAEEMBwGCSqGSIb3DQEJBTEPFw0yNjExMDUwNzE5MjJaMDcGCyqGSIb3
# DQEJEAIvMSgwJjAkMCIEIIW+kOEK0kONfMkotq9IsJqyCBd87PiwEmxY05EFJcQ8
# MD8GCSqGSIb3DQEJBDEyBDC8NzhJy+5AAD654rJgr4QY6B9eddVRKdbu+e9Oa1/H
# jppghUXLnAPP5s+mPqA046kwgZ8GCyqGSIb3DQEJEAIMMYGPMIGMMIGJMIGGBBRX
# FGhBDKha80JO+RZKUTYQ9NONmDBuMFqkWDBWMQswCQYDVQQGEwJQTDEhMB8GA1UE
# ChMYQXNzZWNvIERhdGEgU3lzdGVtcyBTLkEuMSQwIgYDVQQDExtDZXJ0dW0gVGlt
# ZXN0YW1waW5nIDIwMjEgQ0ECECjwd8EcNr3+X3QyR3AnLgMwDQYJKoZIhvcNAQEB
# BQAEggIAnVsi9c7Q5ohNNSLl6CL/H2fYI2Ah3F7ZQ678viYzhhzLffaSbjl8UeCo
# agu40+VPW3DT2rNZeTisV08gcM70bR2qnEcryLWnix0ZT2CpwMhrPQkvT3lPwWjU
# vk3sFE2NhbXEZScwK7M6L5fBaxlmQ2FXX96bNUBDpPObGOhSg7RnGC1WEu/BoKLm
# wxEeke01XDYIcVmJ2nfuPccwRlqMlfOYGuB3OvLQmoq5yKQd3XaCA41SBvEo+m/j
# fgSKNSvBagnh2eOvv5NAOMKlNU0caKyB1A5wOYm5gp18ni27BhalgETpqxLM70ax
# 88gqxOKiMmVoUUOUJQLUJHkhQkmyKG40QOAdXixyIGzAJ2tHXTSM8EBjs8nJMhZm
# LTDaqYw7FaJ8pQw9lviVIzKyw3u1g3b6C+6uEs0vra5AXriu0dzSETDaU/fHSBoy
# LmrQM/Zwq3mPYSIkhWvLsab5AKoad+QBjFOBBsXmNG0vQ2kiFPrcc1GqurI9U08A
# v5r6gzBUyeAc+33ZlXPlbrKT5plA8D6HGWm7qhxUgLreCZ7YxnOUrNxbElQ0uKXK
# fkyA1GdtHrRHhdm0FkOlGfdJAN+aG8SzDhUvnXJf+erXSJq9RrTkmxUP0e65Hd6K
# 4gFUpXz+x4OQYBlwxisy6W7wqiDbdNhGeOT3hZt4QcqvHsM3Go8=
# SIG # End signature block
