# net.ps1 - Network modes for Windows microVMs. No guest ever gets a network adapter:
# networked mode reaches the network only through fc-relay (guest, 127.0.0.1) tunnelled over
# the exec channel to fc-egress (host, unprivileged), which enforces the destination policy.
# Change: windows-proxy-networked-mode
Set-StrictMode -Version Latest

function Get-FcWinNetPolicyPath([string]$RunId) {
    Join-Path (Get-FcWinVmDir $RunId) 'net-policy.json'
}

function Get-FcWinNetLogPath([string]$RunId) {
    Join-Path (Get-FcWinVmDir $RunId) 'net.log'
}

# Writes net-policy.json (also the config 'fc-egress serve' reads) and, in networked mode,
# starts the egress proxy and waits until it answers inside the guest.
function Set-FcWinVmNetworkPolicy {
    param(
        [Parameter(Mandatory = $true)][string]$RunId,
        [Parameter(Mandatory = $true)][string]$WinRuntime,
        [Parameter(Mandatory = $true)][string]$NetMode,
        [string]$AllowCsv = '',
        [string]$Flavour = ''
    )
    $networked = $NetMode -eq 'networked'
    $allowList = if ($networked) { [string[]](Assert-ValidCidrList $AllowCsv) } else { [string[]]@() }
    $policy = [ordered]@{
        run_id   = $RunId
        mode     = $NetMode
        adapter  = 'none'
        egress   = $(if ($networked) { "proxy http://127.0.0.1:$($script:RELAY_PORT)" } else { 'none' })
        allow    = @($allowList)
        log_path = $(if ($networked) { Get-FcWinNetLogPath $RunId } else { '' })
    }
    $policy | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Get-FcWinNetPolicyPath $RunId) -Encoding utf8
    if ($networked) {
        Start-FcWinEgress -RunId $RunId -WinRuntime $WinRuntime -Flavour $Flavour
    }
}

function Start-FcWinEgress([string]$RunId, [string]$WinRuntime, [string]$Flavour) {
    if (-not (Test-FcWinEgressPresent)) {
        throw "egress proxy binaries are missing ('$(Get-FcWinEgressExe)'); install the .NET 10 SDK and rerun '.\fc.ps1 setup -Guest windows'."
    }
    $cli   = Get-FcCli $WinRuntime
    $name  = Get-FcContainerName $RunId
    $vmDir = Get-FcWinVmDir $RunId
    $proxy = "http://127.0.0.1:$($script:RELAY_PORT)"

    # 1. The relay binary goes in over the same tar-over-exec channel as payloads.
    $stage = Join-Path ([System.IO.Path]::GetTempPath()) "fc-relay-$RunId-$([guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Force -Path $stage | Out-Null
    try {
        Copy-Item -LiteralPath (Get-FcWinRelayExe) -Destination $stage
        Send-FcWinGuestFiles -RunId $RunId -WinRuntime $WinRuntime -SourceDir $stage -GuestDir 'C:\fc'
    } finally {
        Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
    }

    # 2. .NET Framework ignores HTTP_PROXY; point machine.config at the relay instead.
    if ($Flavour -like '*netfx*') {
        $cfg = Invoke-FcNative -Exe $cli -ArgList @('exec', '-u', $script:GUEST_USER, $name, 'C:\fc\fc-relay.exe', '--set-netfx-proxy', $proxy)
        if ($cfg.ExitCode -ne 0) { throw "Failed to set the .NET Framework proxy in machine.config: $($cfg.Output)" }
    }

    # 3. Elevated launcher: docker exec session for the relay + unprivileged 'serve'.
    $launch = Invoke-FcNative -Exe (Get-FcWinEgressExe) -ArgList @(
        'launch', '--docker', $cli, '--container', $name, '--policy', (Get-FcWinNetPolicyPath $RunId), '--stderr-dir', $vmDir)
    $json = @($launch.Output -split "`r?`n" | Where-Object { $_.TrimStart().StartsWith('{') }) | Select-Object -Last 1
    if ($launch.ExitCode -ne 0 -or -not $json) {
        throw "fc-egress launch failed (exit $($launch.ExitCode)): $($launch.Output)"
    }
    $pids = $json | ConvertFrom-Json
    Set-FcWinVmMetaProperty -RunId $RunId -Key 'egress_pid' -Value ([int]$pids.serve_pid)
    Set-FcWinVmMetaProperty -RunId $RunId -Key 'relay_exec_pid' -Value ([int]$pids.exec_pid)

    # 4. Readiness: the host refuses the RFC 2606 sentinel name without any lookup, so a 403
    #    proves guest relay -> exec channel -> host policy all work, with no outbound traffic.
    $deadline = (Get-Date).AddSeconds(20)
    $code = ''
    while ((Get-Date) -lt $deadline) {
        $probe = Invoke-FcNative -Exe $cli -ArgList @('exec', '-u', $script:GUEST_USER, $name,
            'curl.exe', '-s', '-o', 'NUL', '-w', '%{http_code}', '--max-time', '5', '-x', $proxy, 'http://fc-egress.invalid/')
        $code = [string]$probe.Output
        if ($code -eq '403') { return }
        if (-not (Get-Process -Id ([int]$pids.serve_pid) -ErrorAction SilentlyContinue)) { break }
        Start-Sleep -Milliseconds 300
    }
    $diag = foreach ($f in 'egress.err', 'relay-exec.err') {
        $p = Join-Path $vmDir $f
        if (Test-Path -LiteralPath $p) { "${f}: $((Get-Content -LiteralPath $p -Raw -ErrorAction SilentlyContinue) -replace '\s+', ' ')" }
    }
    throw "egress proxy did not become ready inside the guest (last probe: '$code'). $($diag -join ' | ')"
}

# Called after the container is stopped: the relay channel is closed by then, so 'serve'
# normally exits on its own after logging; anything still alive is killed by PID (after a
# process-name check, in case the PID was reused). The connection log is kept with the run.
function Stop-FcWinEgress([string]$RunId) {
    $meta = Get-FcWinVmMeta $RunId
    if (-not $meta) { return }
    foreach ($entry in @(@('egress_pid', '^fc-egress$'), @('relay_exec_pid', '^(docker|nerdctl)$'))) {
        $prop = $meta.PSObject.Properties[$entry[0]]
        if (-not $prop -or -not $prop.Value) { continue }
        $p = Get-Process -Id ([int]$prop.Value) -ErrorAction SilentlyContinue
        if (-not $p -or $p.ProcessName -notmatch $entry[1]) { continue }
        if (-not $p.WaitForExit(5000)) {
            Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
        }
    }
    $log = Get-FcWinNetLogPath $RunId
    $resultsProp = $meta.PSObject.Properties['results_dir']
    if ($resultsProp -and $resultsProp.Value -and (Test-Path -LiteralPath $log)) {
        try {
            Copy-Item -LiteralPath $log -Destination (Join-Path ([string]$resultsProp.Value) 'net.log') -Force
        } catch {}
    }
}

# For 'cleanup': relay sessions and proxies whose PIDs were never recorded (a controller that
# died between 'fc-egress launch' and writing meta.json) are found by their command line.
function Stop-FcWinOrphanEgress {
    $procs = Get-CimInstance Win32_Process -Filter "Name='fc-egress.exe' OR Name='docker.exe' OR Name='nerdctl.exe'" -ErrorAction SilentlyContinue
    foreach ($p in @($procs)) {
        $cmd = [string]$p.CommandLine
        $isRelaySession = $p.Name -ne 'fc-egress.exe' -and $cmd -match ' exec -i .*fc-win-\S+ C:\\fc\\fc-relay\.exe'
        $isServe = $p.Name -eq 'fc-egress.exe' -and $cmd -match ' serve --policy '
        if ($isRelaySession -or $isServe) {
            Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
        }
    }
}

function Remove-FcWinVmNetworkPolicy([string]$RunId) {
    $policyPath = Get-FcWinNetPolicyPath $RunId
    if (Test-Path -LiteralPath $policyPath) {
        Remove-Item -LiteralPath $policyPath -Force -ErrorAction SilentlyContinue
    }
}

# Removes what versions before the egress proxy left behind: per-VM 'fc-win-*' firewall
# rules and the 'fc-win-nat' HNS NAT network. Nothing creates either any more.
function Clear-AllFcWinNetworkPolicies([string]$WinRuntime = 'docker') {
    if ((Test-FcAdmin) -and (Get-Command Get-NetFirewallRule -ErrorAction SilentlyContinue)) {
        $rules = Get-NetFirewallRule -ErrorAction SilentlyContinue | Where-Object { $_.Group -like 'fc-win-*' }
        if ($rules) {
            $rules | Remove-NetFirewallRule -ErrorAction SilentlyContinue | Out-Null
        }
    }
    $cli = Get-FcCli $WinRuntime
    if (Test-Path -LiteralPath $cli) {
        $insp = Invoke-FcNative -Exe $cli -ArgList @('network', 'inspect', $script:LEGACY_NAT_NAME)
        if ($insp.ExitCode -eq 0) {
            [void](Invoke-FcNative -Exe $cli -ArgList @('network', 'rm', $script:LEGACY_NAT_NAME))
        }
    }
}
