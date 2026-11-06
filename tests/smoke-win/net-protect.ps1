# net-protect.ps1 - Smoke test for Windows networked mode: no guest adapter, proxied egress,
# host/LAN protection against the host's real addresses and listening ports, allowlist, net.log
# and teardown. Every "blocked" check has a positive control, so a probe that cannot reach
# anything never passes by accident.
param([ValidateSet('docker', 'containerd')][string]$WinRuntime = 'docker')
$ErrorActionPreference = 'Stop'
$RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$FcPs1    = Join-Path $RepoRoot 'fc.ps1'

. (Join-Path $RepoRoot 'windows\lib\common.ps1')
. (Join-Path $RepoRoot 'windows\lib\state.ps1')
. (Join-Path $RepoRoot 'windows\lib\runtime.ps1')
. (Join-Path $RepoRoot 'windows\lib\egress.ps1')
. (Join-Path $RepoRoot 'windows\lib\net.ps1')
. (Join-Path $PSScriptRoot 'smoke-lib.ps1')

if (Invoke-FcSmokeLimitationSkip 'networked' $WinRuntime $FcPs1 'networked mode tests') {
    Write-Host "[smoke-win:net-protect] PASS (skipped on $WinRuntime)"
    return
}

$cli   = Get-FcCli $WinRuntime
$proxy = "http://127.0.0.1:$($script:RELAY_PORT)"

function Start-FcSmokeNetworkedVm([string[]]$ExtraArgs = @()) {
    $ErrorActionPreference = 'Continue'
    $raw = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $FcPs1 start -Guest windows -WinRuntime $WinRuntime -Net networked @ExtraArgs 2>&1
    $rc = $LASTEXITCODE
    $id = $raw | ForEach-Object { "$_".Trim() } | Where-Object { $_ -match '^\d{8}-\d{6}-[0-9a-f]{4}$' } | Select-Object -Last 1
    if ($rc -ne 0 -or -not $id) { throw "Networked start failed (exit $rc): $(($raw | ForEach-Object { "$_" }) -join ' ')" }
    return $id
}

# Runs curl.exe inside the guest with an argument array (no cmd.exe parsing).
function Invoke-FcSmokeGuestCurl([string]$RunId, [string[]]$CurlArgs) {
    $r = Invoke-FcNative -Exe $cli -ArgList (@('exec', '-u', $script:GUEST_USER, (Get-FcContainerName $RunId), 'curl.exe', '-s', '-o', 'NUL', '--max-time', '10') + $CurlArgs)
    return @{ ExitCode = $r.ExitCode; Output = [string]$r.Output }
}

# The proxy's answer to CONNECT host:port ('200' tunnel established, '403' refused).
function Get-FcSmokeConnectCode([string]$RunId, [string]$Target) {
    (Get-FcSmokeConnectCodes $RunId @($Target))[$Target]
}

# One curl call (one guest exec) for many targets: curl prints the proxy's CONNECT answer per URL.
function Get-FcSmokeConnectCodes([string]$RunId, [string[]]$Targets) {
    $curlArgs = @('exec', '-u', $script:GUEST_USER, (Get-FcContainerName $RunId), 'curl.exe', '-s', '-p', '-x', $proxy,
        '--max-time', '10', '-w', '%{url_effective} %{http_connect}\n')
    foreach ($t in $Targets) { $curlArgs += @('-o', 'NUL', "http://$t/") }
    $r = Invoke-FcNative -Exe $cli -ArgList $curlArgs
    $codes = @{}
    foreach ($line in ([string]$r.Output -split "`r?`n")) {
        if ($line -match '^http://(\S+)/ (\d{3})$') { $codes[$Matches[1]] = $Matches[2] }
    }
    foreach ($t in $Targets) { if (-not $codes.ContainsKey($t)) { $codes[$t] = '' } }
    return $codes
}

function Get-FcSmokeNetLog([string]$RunId) {
    $p = Get-FcWinNetLogPath $RunId
    if (-not (Test-Path -LiteralPath $p)) { return @() }
    $fs = [System.IO.File]::Open($p, 'Open', 'Read', 'ReadWrite, Delete')
    try { return ((New-Object System.IO.StreamReader($fs)).ReadToEnd() -split "`n") } finally { $fs.Dispose() }
}

function Assert-FcSmokeDenied([string]$RunId, [string]$Ip, [int]$Port, [string]$Why) {
    $code = Get-FcSmokeConnectCode $RunId "${Ip}:$Port"
    if ($code -ne '403') { throw "$Why ${Ip}:$Port was not refused by the egress proxy (CONNECT answered '$code')" }
}

function Stop-FcSmokeVm([string]$RunId) {
    $meta = Get-FcWinVmMeta $RunId
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $FcPs1 stop $RunId -Guest windows -WinRuntime $WinRuntime | Out-Null
    if (Test-Path -LiteralPath (Get-FcWinNetPolicyPath $RunId)) { throw "Network policy for $RunId was not removed on stop" }
    foreach ($pidValue in @($meta.egress_pid, $meta.relay_exec_pid)) {
        if ($pidValue -and (Get-Process -Id ([int]$pidValue) -ErrorAction SilentlyContinue)) {
            throw "Egress process $pidValue of $RunId still running after stop"
        }
    }
}

# The host's real addresses and the TCP ports it listens on for every interface.
$hostIps = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Where-Object { $_.IPAddress -notlike '169.254.*' } | ForEach-Object { $_.IPAddress } | Sort-Object -Unique)
$hostPorts = @(Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue |
    Where-Object { $_.LocalAddress -in @('0.0.0.0', '::') } | ForEach-Object { [int]$_.LocalPort } | Sort-Object -Unique)
$gateways = @(Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
    Where-Object { $_.NextHop -and $_.NextHop -ne '0.0.0.0' } | ForEach-Object { $_.NextHop } | Sort-Object -Unique)
$lanIp = @(Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Sort-Object RouteMetric |
    ForEach-Object { (Get-NetIPAddress -InterfaceIndex $_.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).IPAddress } |
    Select-Object -First 1)
if ($hostIps.Count -eq 0 -or $hostPorts.Count -eq 0) { throw "Could not enumerate host IPv4 addresses or listening ports" }

Write-Host "[smoke-win:net-protect] 1. No adapter, proxied egress, and host protection ($($hostIps.Count) host IPs x $($hostPorts.Count) listening ports, $($gateways.Count) gateway(s))..."
$id1 = Start-FcSmokeNetworkedVm
try {
    $ipconfig = Invoke-FcNative -Exe $cli -ArgList @('exec', (Get-FcContainerName $id1), 'ipconfig')
    if ($ipconfig.Output -match 'adapter') { throw "Networked guest has a network adapter:`n$($ipconfig.Output)" }

    $direct = Invoke-FcSmokeGuestCurl $id1 @('--noproxy', '*', 'https://example.com')
    if ($direct.ExitCode -eq 0) { throw "Guest reached https://example.com without the proxy" }

    # Positive control: the same request through the proxy works.
    $viaProxy = Invoke-FcSmokeGuestCurl $id1 @('-x', $proxy, '-w', '%{http_code}', 'https://example.com')
    if ($viaProxy.ExitCode -ne 0 -or $viaProxy.Output.Trim() -notmatch '^[23]\d\d$') {
        throw "Proxied https://example.com failed (exit $($viaProxy.ExitCode), status '$($viaProxy.Output)')"
    }

    $targets = @(foreach ($ip in $hostIps) { foreach ($port in $hostPorts) { "${ip}:$port" } }) + @($gateways | ForEach-Object { "${_}:443" })
    $codes = Get-FcSmokeConnectCodes $id1 $targets
    $notRefused = @($targets | Where-Object { $codes[$_] -ne '403' })
    if ($notRefused.Count -gt 0) {
        throw "Host addresses/ports or gateways not refused by the egress proxy: $(($notRefused | ForEach-Object { "$_=$($codes[$_])" }) -join ', ')"
    }
    $v6 = Get-FcSmokeConnectCode $id1 '[2606:4700:4700::1111]:443'
    if ($v6 -ne '403') { throw "IPv6 literal was not refused (CONNECT answered '$v6')" }

    $log = Get-FcSmokeNetLog $id1
    foreach ($ip in $hostIps) {
        foreach ($port in $hostPorts) {
            if (-not ($log | Where-Object { $_ -match "decision=denied host=$([regex]::Escape($ip)) port=$port " })) {
                throw "net.log has no denied entry for ${ip}:$port"
            }
        }
    }
    if (-not ($log | Where-Object { $_ -match 'decision=allowed host=example\.com port=443 ' })) {
        throw "net.log has no allowed entry for example.com:443"
    }
} finally {
    Stop-FcSmokeVm $id1
}

Write-Host "[smoke-win:net-protect] 2. -Allow 1.1.1.1/32 (plus the host LAN IP, which must stay blocked)..."
$allow = @('1.1.1.1/32') + $(if ($lanIp) { @("$lanIp/32") } else { @() })
$id2 = Start-FcSmokeNetworkedVm @('-Allow', ($allow -join ','))
try {
    $hit = Get-FcSmokeConnectCode $id2 '1.1.1.1:443'
    if ($hit -ne '200') { throw "Allowlisted 1.1.1.1:443 was not tunnelled (CONNECT answered '$hit')" }
    Assert-FcSmokeDenied $id2 '8.8.8.8' 443 'Non-allowlisted public address'
    if ($lanIp) { Assert-FcSmokeDenied $id2 $lanIp ($hostPorts[0]) 'Allowlisted host LAN address' }
} finally {
    Stop-FcSmokeVm $id2
}

Write-Host "[smoke-win:net-protect] PASS"
