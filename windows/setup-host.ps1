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

# SIG # Begin signature block
# MIIofAYJKoZIhvcNAQcCoIIobTCCKGkCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCBQkwxRb5K0ZKjr
# xBwK2Qn5IgAQidW7uWckl9TE4HamD6CCDSYwggZlMIIETaADAgECAhAjm5lqXajj
# dfXLKmfgR1EvMA0GCSqGSIb3DQEBCwUAMFYxCzAJBgNVBAYTAlBMMSEwHwYDVQQK
# ExhBc3NlY28gRGF0YSBTeXN0ZW1zIFMuQS4xJDAiBgNVBAMTG0NlcnR1bSBDb2Rl
# IFNpZ25pbmcgMjAyMSBDQTAeFw0yNTExMDUxNzUxMTlaFw0yNjExMDUxNzUxMTha
# MIGKMQswCQYDVQQGEwJQTDESMBAGA1UECAwJcG9tb3Jza2llMRAwDgYDVQQHDAdH
# ZGHFhHNrMR4wHAYDVQQKDBVPcGVuIFNvdXJjZSBEZXZlbG9wZXIxNTAzBgNVBAMM
# LE9wZW4gU291cmNlIERldmVsb3BlciwgS3J6eXN6dG9mIEJhbGNlcm93c2tpMIIB
# ojANBgkqhkiG9w0BAQEFAAOCAY8AMIIBigKCAYEAtO9bgiQpVXH07DAskdvEFW/y
# 87YiEMsSnUeXVI3t1msP0inDc9Bl1pQdWZdD4yY9JVCigPuaBqa+uCTr0EHXjxvb
# V+RtpzaMkt1kfyxm+sm4uNe8qUi+KIkBm2cB4EmU6YQriTGoNouOteM/Zj5ezeNr
# nGx5wi1isFeyXy6o5XD0uiEkCqn+Kysex1M2uv+zfdFMby+BDNnwmj1QSDBrSm97
# EMwM07/li8B+8fM/pnS8afg7u+8ljJ9WKwfDag0eLHTTJTI6PO52hSJIt23AWA9b
# /zCTLGnSKkjbwk61OAoYwYOeqaWETqTAxeoYM+SY4hGH62NosRs/QLquSzpz+Hhw
# hlzxdxQXmnjKQkKD5arj/1YnQOAqVZKyDjtYuR2wc/tlznqvLsCmTcmtzA9Hphs8
# oB0LxYkGAt/BFyq1wIYqojrLoBL8RtNwrw9jhFm7IkIBzkbImVv5bY711zw3tnyB
# RJnmhz0IpUMl7U+X7DgTwpiYKIyS4HOo+wWXzReNAgMBAAGjggF4MIIBdDAMBgNV
# HRMBAf8EAjAAMD0GA1UdHwQ2MDQwMqAwoC6GLGh0dHA6Ly9jY3NjYTIwMjEuY3Js
# LmNlcnR1bS5wbC9jY3NjYTIwMjEuY3JsMHMGCCsGAQUFBwEBBGcwZTAsBggrBgEF
# BQcwAYYgaHR0cDovL2Njc2NhMjAyMS5vY3NwLWNlcnR1bS5jb20wNQYIKwYBBQUH
# MAKGKWh0dHA6Ly9yZXBvc2l0b3J5LmNlcnR1bS5wbC9jY3NjYTIwMjEuY2VyMB8G
# A1UdIwQYMBaAFN10XUwA23ufoHTKsW73PMAywHDNMB0GA1UdDgQWBBTqEi0Om+CR
# +PpT0qg1rzMgLU2vWDBLBgNVHSAERDBCMAgGBmeBDAEEATA2BgsqhGgBhvZ3AgUB
# BDAnMCUGCCsGAQUFBwIBFhlodHRwczovL3d3dy5jZXJ0dW0ucGwvQ1BTMBMGA1Ud
# JQQMMAoGCCsGAQUFBwMDMA4GA1UdDwEB/wQEAwIHgDANBgkqhkiG9w0BAQsFAAOC
# AgEAVbnUF10ZA48MOfaqrRSTeLLQVK3ZcDLeHWBZIOFW1q/iM0mhDXU3sRur4Qzz
# sK5THy84Ius2Q+a/bjQFPQTK0OhUej9+pyqMxUIGxqoDjDJkyM9cDlUHDZvnSeSg
# xtI9neDymt+MxwSWtT1wtW4jZgSlcQ6JQrqWPPClgpFp9ZE/Dci8FbnZHp8nXH9p
# xJef83XgRmAuLRqKCpEhbXdhTWLP4n/FFMkcwq1KS5qp+BRgI4YoPpxyNJjs1C3V
# M34UnICX6zQGSwmKUJS42/XUim4YwWKegZV4CMh2VxyTGp9JOBtbMIOqkhekRWW4
# YYCq2kePdiaNwzFCO74K5bjYDqaSKCJR0PVJh6ePW3cdJOGPS9M3AJ8qonyS9dKR
# hwrPmGmaA5Sp0aqrwEokALoTyAf/dYpVcZxEQg/rzg/BLbbhpey2PJhxIDZt6n+K
# O7ck+6d6l74p7fvoL86mJca1JUpUdh/2nPX/B+nlb0nVNWZZS2GbVile6i6nA0uU
# 6ufXOzrWdpSkz/chD+bulj6ul27E1YKlMvkRxOS4Dv4aNlM8o8gHqZJyBIm833vV
# 35vBevRWHtAvV59w4Vy1dKnXqCJIRVGPxagqvulNWZXXgT0PACCDuRyHNDb7dPAY
# cPSDoMSLAFBTUlIMrv3qy3H/dFMYvtkLufKl9PMtDlEs2AYwgga5MIIEoaADAgEC
# AhEAmaOACiZVO2Wr3G6EprPqOTANBgkqhkiG9w0BAQwFADCBgDELMAkGA1UEBhMC
# UEwxIjAgBgNVBAoTGVVuaXpldG8gVGVjaG5vbG9naWVzIFMuQS4xJzAlBgNVBAsT
# HkNlcnR1bSBDZXJ0aWZpY2F0aW9uIEF1dGhvcml0eTEkMCIGA1UEAxMbQ2VydHVt
# IFRydXN0ZWQgTmV0d29yayBDQSAyMB4XDTIxMDUxOTA1MzIxOFoXDTM2MDUxODA1
# MzIxOFowVjELMAkGA1UEBhMCUEwxITAfBgNVBAoTGEFzc2VjbyBEYXRhIFN5c3Rl
# bXMgUy5BLjEkMCIGA1UEAxMbQ2VydHVtIENvZGUgU2lnbmluZyAyMDIxIENBMIIC
# IjANBgkqhkiG9w0BAQEFAAOCAg8AMIICCgKCAgEAnSPPBDAjO8FGLOczcz5jXXp1
# ur5cTbq96y34vuTmflN4mSAfgLKTvggv24/rWiVGzGxT9YEASVMw1Aj8ewTS4Ind
# U8s7VS5+djSoMcbvIKck6+hI1shsylP4JyLvmxwLHtSworV9wmjhNd627h27a8Rd
# rT1PH9ud0IF+njvMk2xqbNTIPsnWtw3E7DmDoUmDQiYi/ucJ42fcHqBkbbxYDB7S
# YOouu9Tj1yHIohzuC8KNqfcYf7Z4/iZgkBJ+UFNDcc6zokZ2uJIxWgPWXMEmhu1g
# MXgv8aGUsRdaCtVD2bSlbfsq7BiqljjaCun+RJgTgFRCtsuAEw0pG9+FA+yQN9n/
# kZtMLK+Wo837Q4QOZgYqVWQ4x6cM7/G0yswg1ElLlJj6NYKLw9EcBXE7TF3HybZt
# Yvj9lDV2nT8mFSkcSkAExzd4prHwYjUXTeZIlVXqj+eaYqoMTpMrfh5MCAOIG5kn
# N4Q/JHuurfTI5XDYO962WZayx7ACFf5ydJpoEowSP07YaBiQ8nXpDkNrUA9g7qf/
# rCkKbWpQ5boufUnq1UiYPIAHlezf4muJqxqIns/kqld6JVX8cixbd6PzkDpwZo4S
# lADaCi2JSplKShBSND36E/ENVv8urPS0yOnpG4tIoBGxVCARPCg1BnyMJ4rBJAcO
# SnAWd18Jx5n858JSqPECAwEAAaOCAVUwggFRMA8GA1UdEwEB/wQFMAMBAf8wHQYD
# VR0OBBYEFN10XUwA23ufoHTKsW73PMAywHDNMB8GA1UdIwQYMBaAFLahVDkCw6A/
# joq8+tT4HKbROg79MA4GA1UdDwEB/wQEAwIBBjATBgNVHSUEDDAKBggrBgEFBQcD
# AzAwBgNVHR8EKTAnMCWgI6Ahhh9odHRwOi8vY3JsLmNlcnR1bS5wbC9jdG5jYTIu
# Y3JsMGwGCCsGAQUFBwEBBGAwXjAoBggrBgEFBQcwAYYcaHR0cDovL3N1YmNhLm9j
# c3AtY2VydHVtLmNvbTAyBggrBgEFBQcwAoYmaHR0cDovL3JlcG9zaXRvcnkuY2Vy
# dHVtLnBsL2N0bmNhMi5jZXIwOQYDVR0gBDIwMDAuBgRVHSAAMCYwJAYIKwYBBQUH
# AgEWGGh0dHA6Ly93d3cuY2VydHVtLnBsL0NQUzANBgkqhkiG9w0BAQwFAAOCAgEA
# dYhYD+WPUCiaU58Q7EP89DttyZqGYn2XRDhJkL6P+/T0IPZyxfxiXumYlARMgwRz
# LRUStJl490L94C9LGF3vjzzH8Jq3iR74BRlkO18J3zIdmCKQa5LyZ48IfICJTZVJ
# eChDUyuQy6rGDxLUUAsO0eqeLNhLVsgw6/zOfImNlARKn1FP7o0fTbj8ipNGxHBI
# utiRsWrhWM2f8pXdd3x2mbJCKKtl2s42g9KUJHEIiLni9ByoqIUul4GblLQigO0u
# gh7bWRLDm0CdY9rNLqyA3ahe8WlxVWkxyrQLjH8ItI17RdySaYayX3PhRSC4Am1/
# 7mATwZWwSD+B7eMcZNhpn8zJ+6MTyE6YoEBSRVrs0zFFIHUR08Wk0ikSf+lIe5Iv
# 6RY3/bFAEloMU+vUBfSouCReZwSLo8WdrDlPXtR0gicDnytO7eZ5827NS2x7gCBi
# bESYkOh1/w1tVxTpV2Na3PR7nxYVlPu1JPoRZCbH86gc96UTvuWiOruWmyOEMLOG
# GniR+x+zPF/2DaGgK2W1eEJfo2qyrBNPvF7wuAyQfiFXLwvWHamoYtPZo0LHuH8X
# 3n9C+xN4YaNjt2ywzOr+tKyEVAotnyU9vyEVOaIYMk3IeBrmFnn0gbKeTTyYeEEU
# z/Qwt4HOUBCrW602NCmvO1nm+/80nLy5r0AZvCQxaQ4xghqsMIIaqAIBATBqMFYx
# CzAJBgNVBAYTAlBMMSEwHwYDVQQKExhBc3NlY28gRGF0YSBTeXN0ZW1zIFMuQS4x
# JDAiBgNVBAMTG0NlcnR1bSBDb2RlIFNpZ25pbmcgMjAyMSBDQQIQI5uZal2o43X1
# yypn4EdRLzANBglghkgBZQMEAgEFAKB8MBAGCisGAQQBgjcCAQwxAjAAMBkGCSqG
# SIb3DQEJAzEMBgorBgEEAYI3AgEEMBwGCisGAQQBgjcCAQsxDjAMBgorBgEEAYI3
# AgEVMC8GCSqGSIb3DQEJBDEiBCD0wCQho1fJdbBRHSCb3LGRUsSOOXBy8Vd5C80O
# jCqQHDANBgkqhkiG9w0BAQEFAASCAYAWk/VqdbiJDmkNNRDZ05B7eMGJ11kvvQ4g
# uuOo/T3FiXOg/29sRKN4OF4mAYRrVKLZl2R7slGSLKXUpAtlf3RCghSdzp9atVqc
# 9yhdo17dzcBt1RRX4MsmNLIDZXrxn3Gik0ph6jxJpDRaclz9F0ZPuae8tBwP59TB
# zD+EsVe7Hu7elp3S7CcLQhiWUjSPeG2puKnQUDUVbRgTtIFcs/oHdUIVwuZw/lV5
# gljPkva2s85Hf+OyGAzh51DSR+v8JIS847cxv0/mke9asl9a7hauw4aHsX0gIuKF
# j4xrkvULOSg2ThS8ZwLh3CCCiUXWf4/Nh97Qv8/nOV0HWR+3Ig/pSWpOQ3Eucfg7
# h5YLRrY/9TGaFnldzQcDv6Ol0w9m3PVaioFR2T86j5Uo15KF9ZWtmmPwPoZ0p4ui
# vSP2SxuzgUg16hpl2fM8Nif1tsozQexmP6mx67dtZuCn5GBs2WLHtpYNi3T1bq+W
# PdWr8gHX6bgx0XtH9pePQ9aQ/jkoWpyhghgVMIIYEQYKKwYBBAGCNwMDATGCGAEw
# ghf9BgkqhkiG9w0BBwKgghfuMIIX6gIBAzENMAsGCWCGSAFlAwQCAjCBzgYLKoZI
# hvcNAQkQAQSggb4EgbswgbgCAQEGCyqEaAGG9ncCBQELMDEwDQYJYIZIAWUDBAIB
# BQAEICn9QCNbmrVjSwS8dsa9IYto3RA7eoEmcdkcaFi+YzMAAgcKqHx0688BGA8y
# MDI2MTAyNzE4Mzc0OFowAwIBAaBUpFIwUDELMAkGA1UEBhMCUEwxITAfBgNVBAoM
# GEFzc2VjbyBEYXRhIFN5c3RlbXMgUy5BLjEeMBwGA1UEAwwVQ2VydHVtIFRpbWVz
# dGFtcCAyMDI2oIITEDCCBoIwggRqoAMCAQICECjwd8EcNr3+X3QyR3AnLgMwDQYJ
# KoZIhvcNAQEMBQAwVjELMAkGA1UEBhMCUEwxITAfBgNVBAoTGEFzc2VjbyBEYXRh
# IFN5c3RlbXMgUy5BLjEkMCIGA1UEAxMbQ2VydHVtIFRpbWVzdGFtcGluZyAyMDIx
# IENBMB4XDTI2MDMxMTA3MzQ1NFoXDTM2MDIyNzA3MzQ1NFowUDELMAkGA1UEBhMC
# UEwxITAfBgNVBAoMGEFzc2VjbyBEYXRhIFN5c3RlbXMgUy5BLjEeMBwGA1UEAwwV
# Q2VydHVtIFRpbWVzdGFtcCAyMDI2MIICIjANBgkqhkiG9w0BAQEFAAOCAg8AMIIC
# CgKCAgEAuL3N8HD7EjXaGLYX241AE05JORMiLXd+6HcOJbJsjnf3ZsF8nDq07vMO
# ztSo/+t6NV/jEVNTdc04+y44WQ/lI8WydbCfdUkv42E2Gy66O9ixC1pCe82jXCTj
# qt5ODCzUvw4UR0prGDKpPjM5DHzWYvA1lKpc1T1Gtv2gAlYkXgzJ3P4LV5u7QPT6
# +Aze2oBDxNTbTd+qAoI+oh0eWhoWof17JH7y2embLaGec3n1k62ay4d5HB/mJM6G
# WF/R3+qqq4s5IgY+AZUvUePlcFSjHY4Tu1BGv6X/HE1svo67AE7gBrYRu7FiDfty
# le/mLb+VMvg0BIH925/1bh+MDdGj4Y/5sLnifY5iIzcKrzP3Z6PHwXkdY7Z7j/vl
# 4L3kH20zD96rvXT0YPJbb7a63kGfSjwxclMRGTLKy1ZupydSSiYD3up+IMLC+la4
# 4x19M6Sxd71L7EPE4loJuLJOK+A+6XFxP619BNFcGvlTC0+9z4g2dp84SKXNUcDX
# W2/6kdzKWvLEFzTxxSKF/+22qRlLRubHdXFBrLy6iFpOnT/8QID29gZbnVIp0kwm
# Fe8rIh0EvLxZg1yFO3zJEhO/0B3GD0moa6OH5Oc/VtbdpCMW2USXtLOA14jw5UD8
# IkBZZS5FPcC71Og6kfL9+WuuSeE3iF4TDv/ogsy/gdKyPRhnii0CAwEAAaOCAVAw
# ggFMMHUGCCsGAQUFBwEBBGkwZzA7BggrBgEFBQcwAoYvaHR0cDovL3N1YmNhLnJl
# cG9zaXRvcnkuY2VydHVtLnBsL2N0c2NhMjAyMS5jZXIwKAYIKwYBBQUHMAGGHGh0
# dHA6Ly9zdWJjYS5vY3NwLWNlcnR1bS5jb20wHwYDVR0jBBgwFoAUvlQCL79AbHND
# zqwJJU6eQ0Qa7uAwDAYDVR0TAQH/BAIwADA5BgNVHR8EMjAwMC6gLKAqhihodHRw
# Oi8vc3ViY2EuY3JsLmNlcnR1bS5wbC9jdHNjYTIwMjEuY3JsMBYGA1UdJQEB/wQM
# MAoGCCsGAQUFBwMIMA4GA1UdDwEB/wQEAwIHgDAiBgNVHSAEGzAZMAgGBmeBDAEE
# AjANBgsqhGgBhvZ3AgUBCzAdBgNVHQ4EFgQUIzlqKKuaEqekp/If+UWav43+ggMw
# DQYJKoZIhvcNAQEMBQADggIBAGb+k5usC95OpgU8JK2HE1XAEdNbhN+4FBjYoYJ0
# yUfoAuNU9h/ZcBE0YxNdJxHQlDb9zYvEumgceFHDEV/d33fcOEVLXrmtiPqI9JAq
# bjWtz0AylMKMx2ZqLVor2jzvSk7NPMtGFYVUjGb7lB/63hXnPXi0+hSwBZ19EoPV
# nO/N97kAeUT2vE5lwZE6JQvGzcR1/tknxFkjSPMP2O6PagRfZdLsFUq40IrVbSHW
# aNqm/TbzKqjxS1mHn/UhvjxjKnzwENhKGHk9IZRS5Lm1hdV9x24g8F7c901NhFh1
# PlU3GTAuCMzMhyv/pIfZ96MUkOOcLGO9cu5qsSsmD8h0j6Fd0YgENU4a/XOuQXiS
# 2hC8VkinkMgBiHQbDJSFzzuqqflRphOPb6LKIENI2HtoYKuS4CeqDtCHt+uFf5CE
# wZ4n1Kkumcbvqo3zmEvKO9hHqBFiItOPwbh/GOpXjTT9u4/DSsGj3IlnKr/xwZ0I
# 4s85h/2ql59Nytkp472mD5QkfHxQAFtpOqLNHGbyxRITJxxwIIWEiK3cAj/fAa5I
# 4AN6IDrvo1xDv52w/Thi/O903ulNk3KDrvZakEMl2DR4i0eXjKia814g5aHWqzhC
# o5bpMjw5yyLi5INMuivEtQOcFPApDPOnF3VhRy0SBGHfZHQn0WQWR4Su4lT3hGWM
# WvW4MIIGuTCCBKGgAwIBAgIRAOf/acc7Nc5LkSbYdHxopYcwDQYJKoZIhvcNAQEM
# BQAwgYAxCzAJBgNVBAYTAlBMMSIwIAYDVQQKExlVbml6ZXRvIFRlY2hub2xvZ2ll
# cyBTLkEuMScwJQYDVQQLEx5DZXJ0dW0gQ2VydGlmaWNhdGlvbiBBdXRob3JpdHkx
# JDAiBgNVBAMTG0NlcnR1bSBUcnVzdGVkIE5ldHdvcmsgQ0EgMjAeFw0yMTA1MTkw
# NTMyMDdaFw0zNjA1MTgwNTMyMDdaMFYxCzAJBgNVBAYTAlBMMSEwHwYDVQQKExhB
# c3NlY28gRGF0YSBTeXN0ZW1zIFMuQS4xJDAiBgNVBAMTG0NlcnR1bSBUaW1lc3Rh
# bXBpbmcgMjAyMSBDQTCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBAOkS
# HwQ17bldesWmlUG+imV/TnfRbSV102aO2/hhKH9/t4NAoVoipzu0ePujH67y8iwl
# mWuhqRR4xLeLdPxolEL55CzgUXQaq+Qzr5Zk7ySbNl/GZloFiYwuzwWS2AVgLPLC
# Zd5DV8QTF+V57Y6lsdWTrrl5dEeMfsxhkjM2eOXabwfLy6UH2ZHzAv9bS/SmMo1P
# obSx+vHWST7c4aiwVRvvJY2dWRYpTipLEu/XqQnqhUngFJtnjExqTokt4HyzOsr2
# /AYOm8YOcoJQxgvc26+LAfXHiBkbQkBdTfHak4DP3UlYolICZHL+XSzSXlsRgqiW
# D4MypWGU4A13xiHmaRBZowS8FET+QAbMiqBaHDM3Y6wohW07yZ/mw9ZKu/KmVIAE
# BhrXesxifPB+DTyeWNkeCGq4IlgJr/Ecr1px6/1QPtj66yvXl3uauzPPGEXUk6vU
# ym6nZyE1IGXI45uGVI7XqvCt99WuD9LNop9Kd1LmzBGGvxucOo0lj1M3IRi8FimA
# X3krunSDguC5HgD75nWcUgdZVjm/R81VmaDPEP25Wj+C1reicY5CPckLGBjHQqsJ
# e7jJz1CJXBMUtZs10cVKMEK3n/xD2ku5GFWhx0K6eFwe50xLUIZD9GfT7s/5/MyB
# Z1Ep8Q6H+GMuudDwF0mJitk3G8g6EzZprfMQMc3DAgMBAAGjggFVMIIBUTAPBgNV
# HRMBAf8EBTADAQH/MB0GA1UdDgQWBBS+VAIvv0Bsc0POrAklTp5DRBru4DAfBgNV
# HSMEGDAWgBS2oVQ5AsOgP46KvPrU+Bym0ToO/TAOBgNVHQ8BAf8EBAMCAQYwEwYD
# VR0lBAwwCgYIKwYBBQUHAwgwMAYDVR0fBCkwJzAloCOgIYYfaHR0cDovL2NybC5j
# ZXJ0dW0ucGwvY3RuY2EyLmNybDBsBggrBgEFBQcBAQRgMF4wKAYIKwYBBQUHMAGG
# HGh0dHA6Ly9zdWJjYS5vY3NwLWNlcnR1bS5jb20wMgYIKwYBBQUHMAKGJmh0dHA6
# Ly9yZXBvc2l0b3J5LmNlcnR1bS5wbC9jdG5jYTIuY2VyMDkGA1UdIAQyMDAwLgYE
# VR0gADAmMCQGCCsGAQUFBwIBFhhodHRwOi8vd3d3LmNlcnR1bS5wbC9DUFMwDQYJ
# KoZIhvcNAQEMBQADggIBALiTWXfJTBX9lAcIoKd6oCzwQZOfARQkt0OmiQ390yEq
# MrStHmpfycggfPGlBHdMDDYhHDVTGyvY+WIbdsIWpJ1BNRt9pOrpXe8HMR5sOu71
# AWOqUqfEIXaHWOEs0UWmVs8mJb4lKclOHV8oSoR0p3GCX2tVO+XF8Qnt7E6fbkwZ
# t3/AY/C5KYzFElU7TCeqBLuSagmM0X3Op56EVIMM/xlWRaDgRna0hLQze5mYHJGv
# 7UuTCOO3wC1bzeZWdlPJOw5v4U1/AljsNLgWZaGRFuBwdF62t6hOKs86v+jPIMqF
# PwxNJN/ou22DqzpP+7TyYNbDocrThlEN9D2xvvtBXyYqA7jhYY/fW9edUqhZUmkU
# GM++Mvz9lyT/nBdfaKqM5otK0U5H8hCSL4SGfjOVyBWbbZlUIE8X6XycDBRRKEK0
# q5JTsaZksoKabFAyRKJYgtObwS1UPoDGcmGirwSeGMQTJSh+WR5EXZaEWJVA6ZZP
# BlGvjgjFYaQ0kLq1OitbmuXZmX7Z70ks9h/elK0A8wOg8oiNVd3o1bb59ms1QF4O
# jZ45rkWfsGuz8ctB9/leCuKzkx5Rt1WAOsXy7E7pws+9k+jrePrZKw2DnmlNaT19
# QgX2I+hFtvhC6uOhj/CgjVEA4q1i1OJzpoAmre7zdEg+kZcFIkrDHgokA5mcIMK1
# MIIFyTCCBLGgAwIBAgIQG7WPJSrfIwBJKMmuPX7tJzANBgkqhkiG9w0BAQwFADB+
# MQswCQYDVQQGEwJQTDEiMCAGA1UEChMZVW5pemV0byBUZWNobm9sb2dpZXMgUy5B
# LjEnMCUGA1UECxMeQ2VydHVtIENlcnRpZmljYXRpb24gQXV0aG9yaXR5MSIwIAYD
# VQQDExlDZXJ0dW0gVHJ1c3RlZCBOZXR3b3JrIENBMB4XDTIxMDUzMTA2NDMwNloX
# DTI5MDkxNzA2NDMwNlowgYAxCzAJBgNVBAYTAlBMMSIwIAYDVQQKExlVbml6ZXRv
# IFRlY2hub2xvZ2llcyBTLkEuMScwJQYDVQQLEx5DZXJ0dW0gQ2VydGlmaWNhdGlv
# biBBdXRob3JpdHkxJDAiBgNVBAMTG0NlcnR1bSBUcnVzdGVkIE5ldHdvcmsgQ0Eg
# MjCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBAL35ePjm1YAMZJ2GG5Zk
# Zz8iOh51AX3v+1xnjMnMXGupkea5QuUgS5vam3u5mV3Zm4BL14RAKyfT6Lowuz4J
# GqdJle8rQCTCl8en7psl76gKAJeFWqqd3CnJ4jUH63BNStbBs1a4oUE4m9H7MX+P
# 4F/hsT8PjhZJYNcGjRj5qiYQqyrT0NFnjRtGvkcw1S5y0cVj2udjeUR+S2MkiYYu
# ND8pTFKLKqfA4pEoibnAW/kd2ecnrf+aApfBxlCSmwIsvam5NFkKv4RK/9/+s5/r
# 2Z7gmCPspmt3FirbzK07HKSH3EZzXhliaEVX5JCCQrtC1vBh4MGjPWajXfQY7ojJ
# jRdFKZkydQIx7ikmyGsC5rViRX83FVojaInUPt5OJ7DwQAy8TRfLTaKzHtAGWt32
# k89XdZn1+oYaZ3izv5b+NNy951JW5bPldXvXQZEF3F1p45UNQ7n8g5Y5lXtsgFpP
# E3LG130pekS6UqQq1UFGCSD+IqC2WzCNvIkM1ddw+IdS/drvrFEuB7NO/tAJ2nDv
# mPpW5m3btVdL3OUsJRXIni54TvjanJ6GLMpX8xrlyJKLGoKWesO8UBJp2A5aRos6
# 6yb6I8m2sIG+QgCk+Nb+MC7H0kb25Y51/fLMudCHW8wGEGC7gzW3XmfeR+yZSPGk
# oRX+rYxijjlVTzkWubFjnf+3AgMBAAGjggE+MIIBOjAPBgNVHRMBAf8EBTADAQH/
# MB0GA1UdDgQWBBS2oVQ5AsOgP46KvPrU+Bym0ToO/TAfBgNVHSMEGDAWgBQIds3L
# B/8k9sXN7buQvOKEN0Z19zAOBgNVHQ8BAf8EBAMCAQYwLwYDVR0fBCgwJjAkoCKg
# IIYeaHR0cDovL2NybC5jZXJ0dW0ucGwvY3RuY2EuY3JsMGsGCCsGAQUFBwEBBF8w
# XTAoBggrBgEFBQcwAYYcaHR0cDovL3N1YmNhLm9jc3AtY2VydHVtLmNvbTAxBggr
# BgEFBQcwAoYlaHR0cDovL3JlcG9zaXRvcnkuY2VydHVtLnBsL2N0bmNhLmNlcjA5
# BgNVHSAEMjAwMC4GBFUdIAAwJjAkBggrBgEFBQcCARYYaHR0cDovL3d3dy5jZXJ0
# dW0ucGwvQ1BTMA0GCSqGSIb3DQEBDAUAA4IBAQBRwqFYFiIQi/yGMdTCMtNc+Eui
# L2o+TfirCB7t1ej65wgN7LfGHg6ydQV6sQv613RqAAYfpM6q8mt92BHAEQjUDk1h
# xTqo+rHh45jq4mP9QfWTfQ28XZI7kZplutBfTL5MjWgDEBbV8dAEioUz+TfnWy4m
# aUI8us281HrpTZ3a50P7Y1KAhQTEJZVV8H6nnwHFWyj44M6GcKYnOzn7OC6YU2Ui
# dS3X9t0iIpGW691o7T+jGZfTOyWI7DYSPal+zgKNBZqSpyduRbKcYoY3DaQzjteo
# TtBKF0NMxfGnbNIeWGwUUX6KVKH27595el2BmhaQD+G78UoA+fndvu2q7M4KMYID
# 7zCCA+sCAQEwajBWMQswCQYDVQQGEwJQTDEhMB8GA1UEChMYQXNzZWNvIERhdGEg
# U3lzdGVtcyBTLkEuMSQwIgYDVQQDExtDZXJ0dW0gVGltZXN0YW1waW5nIDIwMjEg
# Q0ECECjwd8EcNr3+X3QyR3AnLgMwDQYJYIZIAWUDBAICBQCgggFWMBoGCSqGSIb3
# DQEJAzENBgsqhkiG9w0BCRABBDAcBgkqhkiG9w0BCQUxDxcNMjYxMDI3MTgzNzQ4
# WjA3BgsqhkiG9w0BCRACLzEoMCYwJDAiBCCFvpDhCtJDjXzJKLavSLCasggXfOz4
# sBJsWNORBSXEPDA/BgkqhkiG9w0BCQQxMgQwtzi8yVYzilKc3U+uvIgQDjsqdTni
# xDDVz+cGOBF6l3U/5Z0qOdZltyY1CS1MNFpdMIGfBgsqhkiG9w0BCRACDDGBjzCB
# jDCBiTCBhgQUVxRoQQyoWvNCTvkWSlE2EPTTjZgwbjBapFgwVjELMAkGA1UEBhMC
# UEwxITAfBgNVBAoTGEFzc2VjbyBEYXRhIFN5c3RlbXMgUy5BLjEkMCIGA1UEAxMb
# Q2VydHVtIFRpbWVzdGFtcGluZyAyMDIxIENBAhAo8HfBHDa9/l90MkdwJy4DMA0G
# CSqGSIb3DQEBAQUABIICAIswcQ1Wv7/cixvGNIfJs5yRPvvcsyaoMhMCIYNfyT3U
# 8R1/WypkiP5/ZoemGu386pMDSv5Rq9ySRsBPH4GRPwFTtQetLy7CujTnV0wb4x2y
# sIfDVirba2XdXGY7zH1HHBAD6upryehLvnhfNRz/WV+tm9whHWrV26mzOd2SSL1t
# 9dtiyCoB0n+yxYwdNCYuR1bj9XdYodJq6hCPqKsZHHE5mqPDItR31drHLVuZJs7b
# AgEb7bDZrxeoare0WRRViiM+XiaWA9K5ecXGMTGk5YwtRwooQDHpOZt7lwT5L2Id
# JfbB59ghc1YtJ1TTi1kGVecMefoZRUYe+daj0Nv7gn01vOx7FbRaeiX+y7TAkjw+
# hJwoneeasgy1lpg7SvSkwy3n40MA9KEzTpBJLWEuL7WEbKok/9BVOExyo32JSII4
# rDHKyB7IQh56QXwhJXtCEg3oadMc9SrJxm2TeDQaRJh4nRiZn+C4i2SgCOtIpYgc
# 9Pxnyg1KJ8be8QhqbSHvbz7/VJyt3QQGJeR4cOqKMwGBMA2cVFcibNFYp/+Vcgfb
# Le2fjGYYKHkOo3L/pLJWbV2PQLvu0rh/b1niOUPXVb94Q4CTnZWLtaUo+MCV8Fu5
# qGGZp+02qsQYApXqo5NRpN1d0rQ3JHQM7ao689amkLu4bqTGXamvldlQ2gfPow2q
# SIG # End signature block
