# state.ps1 - Per-VM state management and detached timeout watchdog for Windows microVMs.
# Change: nanoserver-windows-microvm
Set-StrictMode -Version Latest

function Get-FcWinVmDir([string]$RunId) {
    Join-Path (Get-FcWinVmsDir) $RunId
}

function Get-FcWinVmMetaPath([string]$RunId) {
    Join-Path (Get-FcWinVmDir $RunId) 'meta.json'
}

function Test-FcWinVmExists([string]$RunId) {
    if ([string]::IsNullOrWhiteSpace($RunId)) { return $false }
    return (Test-Path -LiteralPath (Get-FcWinVmMetaPath $RunId))
}

function Get-FcWinVmMeta([string]$RunId) {
    $path = Get-FcWinVmMetaPath $RunId
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    try {
        return (Get-Content -LiteralPath $path -Raw | ConvertFrom-Json)
    } catch {
        return $null
    }
}

function Save-FcWinVmMeta([string]$RunId, $MetaObj) {
    $dir = Get-FcWinVmDir $RunId
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $path = Get-FcWinVmMetaPath $RunId
    $tmp  = "$path.tmp"
    $MetaObj | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $tmp -Encoding utf8
    Move-Item -LiteralPath $tmp -Destination $path -Force
}

function Set-FcWinVmMetaProperty([string]$RunId, [string]$Key, $Value) {
    $meta = Get-FcWinVmMeta $RunId
    if (-not $meta) { return }
    $ht = [ordered]@{}
    foreach ($prop in $meta.PSObject.Properties) {
        $ht[$prop.Name] = $prop.Value
    }
    $ht[$Key] = $Value
    Save-FcWinVmMeta -RunId $RunId -MetaObj $ht
}

function Get-FcWinVmIds {
    $vmsDir = Get-FcWinVmsDir
    if (-not (Test-Path -LiteralPath $vmsDir)) { return @() }
    $dirs = Get-ChildItem -LiteralPath $vmsDir -Directory -ErrorAction SilentlyContinue | Sort-Object Name
    $ids = @()
    foreach ($d in $dirs) {
        if (Test-Path -LiteralPath (Join-Path $d.FullName 'meta.json')) {
            $ids += $d.Name
        }
    }
    return $ids
}

if (-not ('FcStdHandles' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class FcStdHandles
{
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern IntPtr GetStdHandle(int which);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool GetHandleInformation(IntPtr handle, out uint flags);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool SetHandleInformation(IntPtr handle, uint mask, uint flags);
}
'@
}

# Clears HANDLE_FLAG_INHERIT on this process's stdin/stdout/stderr and returns what to restore.
function Disable-FcStdHandleInheritance {
    $saved = @()
    foreach ($which in @(-10, -11, -12)) {
        $h = [FcStdHandles]::GetStdHandle($which)
        if ($h -eq [IntPtr]::Zero -or $h -eq [IntPtr]::new(-1)) { continue }
        [uint32]$flags = 0
        if ([FcStdHandles]::GetHandleInformation($h, [ref]$flags) -and ($flags -band 1)) {
            [void][FcStdHandles]::SetHandleInformation($h, 1, 0)
            $saved += $h
        }
    }
    return ,$saved
}

function Restore-FcStdHandleInheritance($Saved) {
    foreach ($h in @($Saved)) { [void][FcStdHandles]::SetHandleInformation($h, 1, 1) }
}

function Start-FcWinWatchdog([string]$RunId, [int]$LifetimeSec, [string]$ControllerScriptPath) {
    $b64Path = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($ControllerScriptPath))
    $b64Base = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes((Get-FcWinBaseDir)))
    $script = @"
`$env:FC_WIN_BASE = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$b64Base'))
Start-Sleep -Seconds $LifetimeSec
`$ctrl = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$b64Path'))
& `$ctrl _expire '$RunId'
"@
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($script))
    # The watchdog outlives this process. If it inherited our stdout/stderr pipes, a caller
    # capturing 'fc.ps1 start' output would wait for the watchdog, i.e. the VM's whole lifetime.
    $saved = Disable-FcStdHandleInheritance
    try {
        $proc = Start-Process -FilePath 'powershell.exe' `
            -ArgumentList @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-EncodedCommand', $encoded) `
            -PassThru
    } finally {
        Restore-FcStdHandleInheritance $saved
    }
    if ($proc -and $proc.Id) {
        Set-FcWinVmMetaProperty -RunId $RunId -Key 'watchdog_pid' -Value $proc.Id
    }
}

function Stop-FcWinWatchdog([string]$RunId) {
    $meta = Get-FcWinVmMeta $RunId
    if (-not $meta -or -not $meta.PSObject.Properties['watchdog_pid'] -or -not $meta.watchdog_pid) { return }
    $wpid = [int]$meta.watchdog_pid
    # Don't kill ourselves when the watchdog is the one destroying the VM (_expire).
    if ($wpid -eq $PID) { return }
    try {
        $p = Get-Process -Id $wpid -ErrorAction SilentlyContinue
        if ($p -and $p.ProcessName -match '^powershell|pwsh$') {
            Stop-Process -Id $wpid -Force -ErrorAction SilentlyContinue
        }
    } catch {}
}

# Writes runs\<run-id>\meta.json directly from the VM state object so callers
# don't duplicate field lists.
function Write-FcWinRunResultMeta {
    param(
        [Parameter(Mandatory = $true)][string]$ResultsDir,
        [Parameter(Mandatory = $true)][string]$RunId,
        [Parameter(Mandatory = $true)][string]$CommandText,
        [Parameter(Mandatory = $true)][string]$PayloadPath,
        $ExitCode = $null,
        [bool]$TimedOut = $false,
        [string]$ErrorMessage = ''
    )
    $vmMeta = Get-FcWinVmMeta $RunId
    if (-not $vmMeta) { return }

    New-Item -ItemType Directory -Force -Path $ResultsDir | Out-Null
    $endedAt = if ($null -eq $ExitCode) { $null } else { Get-IsoTimestamp }
    $errVal  = if ([string]::IsNullOrWhiteSpace($ErrorMessage)) { $null } else { $ErrorMessage }
    # PowerShell 7's ConvertFrom-Json turns ISO timestamps into DateTime; keep the ISO form.
    $startedAt = $vmMeta.started_at
    if ($startedAt -is [datetime]) { $startedAt = $startedAt.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') }
    $meta = [ordered]@{
        run_id      = $RunId
        guest       = 'windows'
        flavour     = [string]$vmMeta.flavour
        image_repo  = [string]$vmMeta.image_repo
        win_runtime = [string]$vmMeta.win_runtime
        command     = $CommandText
        payload     = $PayloadPath
        net         = [string]$vmMeta.net
        allow       = [string]$vmMeta.allow
        vcpu        = [int]$vmMeta.vcpu
        mem_mib     = [int]$vmMeta.mem_mib
        timeout_sec = [int]$vmMeta.timeout_sec
        started_at  = [string]$startedAt
        ended_at    = $endedAt
        exit_code   = $ExitCode
        timed_out   = $TimedOut
        error       = $errVal
        keep_disk   = [bool]$vmMeta.keep_disk
    }
    $metaPath = Join-Path $ResultsDir 'meta.json'
    $tmpPath  = "$metaPath.tmp"
    $meta | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $tmpPath -Encoding utf8
    Move-Item -LiteralPath $tmpPath -Destination $metaPath -Force
}

# SIG # Begin signature block
# MIInggYJKoZIhvcNAQcCoIInczCCJ28CAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCDmof5KKXUbHg+r
# 2vy8k42NCiJmNX4NdXbFYXYgBM7NEKCCIDYwggXJMIIEsaADAgECAhAbtY8lKt8j
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
# KoZIhvcNAQkEMSIEIB66deWc+Shc4/P2EptLI5Ovh5lf9beeC10j7BF4S3jTMA0G
# CSqGSIb3DQEBAQUABIIBgBk8lgX4kzEr466DXczoKxQjXlCmAWKbXAt4y6Oo3rM5
# p6U5An2Ot3b+XyqSdvn8LWaDT2hdyC1GKPzQrKWyIvDnRJiBdbY17Uj3ZQ/DQ6SO
# MctiYgG0B02WpJlaxKM+peXBphxv8yqXQBGl+j534MEFTwkx1peAf5DMqBvqn41P
# LIpFXlJGhVkUGcKkMS5bns0EN37WF276j49fTcFAuXtFFMphWHQerlO9jhRAOFH/
# hOOuEUxMXAxiES2htQ22L+Y8e2EtPASzzCYS4YPGfY4aW0fatQ0+BHVTVXAnZilD
# WfMsWF5FgznrlbQRApynrAHHmRAJyVSNuatPOgF9AGCYzHZ703yOMqQbV8am6aS2
# KjJl6mUUKBEysknyaSB8Guk+K2mcvW7v+6m2CNHLrm5dKX3A0flXARPyoBago/PG
# o9X/mMZb3cFwfIxSxCsrwXtO4ORu+xNFik5YaJQho4EVBH4emvZ0ggFCZGlELWd7
# 62c71Ooq8XO8/aqN8jZYuqGCBAIwggP+BgkqhkiG9w0BCQYxggPvMIID6wIBATBq
# MFYxCzAJBgNVBAYTAlBMMSEwHwYDVQQKExhBc3NlY28gRGF0YSBTeXN0ZW1zIFMu
# QS4xJDAiBgNVBAMTG0NlcnR1bSBUaW1lc3RhbXBpbmcgMjAyMSBDQQIQKPB3wRw2
# vf5fdDJHcCcuAzANBglghkgBZQMEAgIFAKCCAVYwGgYJKoZIhvcNAQkDMQ0GCyqG
# SIb3DQEJEAEEMBwGCSqGSIb3DQEJBTEPFw0yNjExMDQyMjE3MTJaMDcGCyqGSIb3
# DQEJEAIvMSgwJjAkMCIEIIW+kOEK0kONfMkotq9IsJqyCBd87PiwEmxY05EFJcQ8
# MD8GCSqGSIb3DQEJBDEyBDDu0kPrgVrrW4PU5sxTn0sHqmaMFeC7kQ0QLOQbTjjk
# /e9Ss6qHgEg/L9Z1pJPzRagwgZ8GCyqGSIb3DQEJEAIMMYGPMIGMMIGJMIGGBBRX
# FGhBDKha80JO+RZKUTYQ9NONmDBuMFqkWDBWMQswCQYDVQQGEwJQTDEhMB8GA1UE
# ChMYQXNzZWNvIERhdGEgU3lzdGVtcyBTLkEuMSQwIgYDVQQDExtDZXJ0dW0gVGlt
# ZXN0YW1waW5nIDIwMjEgQ0ECECjwd8EcNr3+X3QyR3AnLgMwDQYJKoZIhvcNAQEB
# BQAEggIAW1bOcM/6GJwxpIUMd8IVpmiKeamIqV+jgW2cAJ1vTTOy3q6v4nsiUM7j
# Uv4NXDTwVXQHK7xaFh699nYvluVZQ1IIBdCJlNlfRXG6bbQ1EbM5n6sSz0ArMoKR
# lQm4uz1hQBLVcTj/XDseIrJQepzcDsrYNW0b0NW8ynjRjIel0utud384vffQ4W1D
# GV4AXg5xgijveREoHfiN6NJq/lshQqeT4NPn8X2PdBwfdlmCsBM14JbrUBeH0tsg
# R4zIuIj5osA9f0l0WGNwmj9QuthkYYvzy1R8E88HrQOWxELKY1pCCoS9tLFWW3/b
# 4YSn3zX4BFLVdHLIzGkWWNRq21uegp9Iew47K2ULhWsMNkdyCpFrVjWfCl9xRRhj
# cDFBC/ycz5GYOnoSAQSr8ZAFO26x5YAVEElTEaZzkCc9DfEqrXSfDNoT1A/VW96b
# F2YOBrUP0aFZGadLOC86df2h0P4uLSz5oXmYEinxRhX1axCCcIzdoDNhz/iMY45i
# 44jvgNnfdHKe695unBREvMnnOuGBeosjrubGJ9j8srsaLQUQpI/Vza+rAHKgp/jX
# a+gsXhGt+OHEFc8n4grAthGpQMydzTCnigoFcsfPArHbQXhMeh5QThDMao4Op6+9
# 42F/mZMsCVQ6WyWbcZfqNM7E5Oo0TYLLZJMQh/Jdti4GuvkomAc=
# SIG # End signature block
