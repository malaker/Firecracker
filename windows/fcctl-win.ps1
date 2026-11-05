<#
.SYNOPSIS
  Windows Nano Server microVM controller (Hyper-V Utility VM via Docker or containerd+runhcs).
#>
[CmdletBinding(PositionalBinding = $false)]
param(
    [Parameter(Position = 0)]
    [string]$Command = 'help',

    [Parameter(Position = 1, ValueFromRemainingArguments = $true)]
    [string[]]$Rest,

    [string]$Flavour,
    [string]$WinRuntime,
    [string]$ImageRepo,
    [string]$Payload,
    [string]$Cmd,
    [string]$Net = 'isolated',
    [string[]]$Allow,
    [int]$Vcpu = 2,
    [int]$MemMib = 1024,
    [string]$Timeout = '30m',
    [switch]$Keep,
    [switch]$Boot,
    [string]$ResultsDir
)

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'lib\common.ps1')
. (Join-Path $PSScriptRoot 'lib\state.ps1')
. (Join-Path $PSScriptRoot 'lib\runtime.ps1')
. (Join-Path $PSScriptRoot 'lib\egress.ps1')
. (Join-Path $PSScriptRoot 'lib\net.ps1')
. (Join-Path $PSScriptRoot 'lib\doctor.ps1')

$cfg = Get-FcWinConfig
if (-not $WinRuntime) { $WinRuntime = $cfg.win_runtime }
if (-not $ImageRepo)  { $ImageRepo  = $cfg.image_repo }
if (-not $Flavour)    { $Flavour    = $cfg.default_flavour }
if (-not $ResultsDir) { $ResultsDir = Join-Path (Split-Path -Parent $PSScriptRoot) 'runs' }

function Show-FcWinUsage {
    @"
Usage: fc.ps1 <command> [-Guest linux|windows] [options]

Commands:
  setup [options]            Configure the Linux (fc-host WSL2) or Windows (Hyper-V Nano Server) host
  doctor [-Boot]             Check that this host can run microVMs (-Boot also boots a test VM)
  run -Payload DIR -Cmd CMD [vm options]
                             Boot a VM, upload DIR to /work/in (Linux) or C:\work\in (Windows),
                             run CMD in /work or C:\work, collect out/ and logs into runs\<run-id>\,
                             and destroy the VM
  shell [vm options]         Boot a VM and open an interactive root / ContainerAdministrator shell
  start [vm options]         Boot a VM in the background and print its run id
  ssh <run-id> [command]     Open a shell or run a command in a started VM
  list                       List VMs (running, dead or kept)
  stop <run-id>              Destroy a VM (and kept disk/container)
  cleanup                    Destroy every VM and remove all leftovers

Common VM options:
  -Guest linux|windows       Guest microVM backend (default: linux)
  -Net isolated|networked    Network mode (default: isolated = no network adapter)
  -Allow CIDR[,CIDR...]      networked only: allow egress only to these destinations
  -Vcpu N                    vCPUs (default 2)
  -MemMib MIB                Memory in MiB (default 1024)
  -Timeout DUR               Maximum lifetime, e.g. 90s, 30m, 1h (default 30m)
  -Keep                      Keep the VM's disk/container after it stops, for inspection

Windows-specific options (-Guest windows):
  -Flavour TAG               aspnet-x86 (default), aspnet-x64, iis-aspnet-x86, iis-aspnet-x64,
                             iis-netfx-x86, iis-netfx-x64
  -WinRuntime RUNTIME        docker (default) or containerd (experimental: nerdctl + runhcs-v1)
  -ImageRepo REPO            Image repository (default: malaker/nanoserver)
  -BuildFromSource           setup only: build the base image locally from .\externalimages
  -NanoBase IMAGE            setup -BuildFromSource only: Nano Server base image
                             (default: mcr.microsoft.com/windows/nanoserver:ltsc2025)
"@ | Write-Host
}

if ($Command -in @('', 'help', '--help', '-h')) {
    Show-FcWinUsage
    exit 0
}

try {
    Assert-ValidWinRuntime $WinRuntime
    Assert-ValidFlavour $Flavour
    if ($Net -notin @('isolated', 'networked')) {
        throw "-Net must be 'isolated' or 'networked'."
    }
    $allowCsv = if ($Allow) { ($Allow -join ',') } else { '' }
    if ($allowCsv) {
        if ($Net -ne 'networked') {
            throw "-Allow only applies to -Net networked."
        }
        [void](Assert-ValidCidrList $allowCsv)
    }
    $timeoutSec = ConvertFrom-Duration $Timeout
} catch {
    Stop-FcWithError $_.Exception.Message $script:EXIT_INFRA
}

function Complete-FcWinRunResults {
    param(
        [Parameter(Mandatory = $true)][string]$RunId,
        [Parameter(Mandatory = $true)][string]$WinRuntime,
        [Parameter(Mandatory = $true)][string]$OutRunDir,
        [Parameter(Mandatory = $true)][string]$CommandText,
        [Parameter(Mandatory = $true)][string]$PayloadPath,
        [Parameter(Mandatory = $true)][int]$ExitCode,
        [bool]$TimedOut = $false,
        [string]$ErrorMessage = ''
    )
    $outFilesDir = Join-Path $OutRunDir 'out'
    New-Item -ItemType Directory -Force -Path $outFilesDir | Out-Null
    try {
        if (Test-FcWinMicroVmRunning $RunId $WinRuntime) {
            Receive-FcWinGuestFiles -RunId $RunId -WinRuntime $WinRuntime -GuestDir 'C:\work\out' -DestDir $outFilesDir
        }
    } catch {}
    Write-FcTextFile -Path (Join-Path $OutRunDir 'exit_code') -Text "$ExitCode`n"
    Write-FcWinRunResultMeta -ResultsDir $OutRunDir -RunId $RunId -CommandText $CommandText `
        -PayloadPath $PayloadPath -ExitCode $ExitCode -TimedOut $TimedOut -ErrorMessage $ErrorMessage
}

function Remove-FcWinVmInstance([string]$RunId, [bool]$ForceDeleteKeep = $false) {
    $meta = Get-FcWinVmMeta $RunId
    $rt  = if ($meta -and $meta.win_runtime)  { [string]$meta.win_runtime }  else { $WinRuntime }
    $cid = if ($meta -and $meta.container_id) { [string]$meta.container_id } else { '' }
    $keepDisk = if ($meta -and $meta.keep_disk) { [bool]$meta.keep_disk } else { $false }

    Stop-FcWinWatchdog $RunId

    # The container goes first: its exit closes the relay channel, so the egress proxy logs
    # its open connections and exits on EOF before Stop-FcWinEgress has to kill anything.
    if ($keepDisk -and (-not $ForceDeleteKeep)) {
        Stop-FcWinMicroVmContainer -RunId $RunId -WinRuntime $rt -ContainerId $cid -RemoveContainer $false
        Stop-FcWinEgress $RunId
        Remove-FcWinVmNetworkPolicy $RunId
        Set-FcWinVmMetaProperty -RunId $RunId -Key 'state' -Value 'kept'
        $vmDir = Get-FcWinVmDir $RunId
        Write-FcLog "Kept Windows microVM $RunId (container $(Get-FcContainerName $RunId), state at $vmDir)"
    } else {
        Stop-FcWinMicroVmContainer -RunId $RunId -WinRuntime $rt -ContainerId $cid -RemoveContainer $true
        Stop-FcWinEgress $RunId
        Remove-FcWinVmNetworkPolicy $RunId
        $vmDir = Get-FcWinVmDir $RunId
        if (Test-Path -LiteralPath $vmDir) {
            Remove-Item -LiteralPath $vmDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function Start-NewFcWinVm([int]$LifetimeSec) {
    Assert-FcAdmin
    try {
        Assert-ValidResources -Vcpu $Vcpu -MemMib $MemMib
    } catch {
        Stop-FcWithError $_.Exception.Message $script:EXIT_INFRA
    }

    if (-not (Test-FcWinRuntimeReady $WinRuntime)) {
        Stop-FcWithError "Windows runtime '$WinRuntime' is not running; run '.\fc.ps1 doctor -Guest windows'." $script:EXIT_INFRA
    }

    $runId    = New-FcRunId
    $imageRef = Get-FcImageReference $ImageRepo $Flavour

    $startedAt = Get-IsoTimestamp
    $initialMeta = [ordered]@{
        run_id       = $runId
        guest        = 'windows'
        state        = 'running'
        flavour      = $Flavour
        image_repo   = $ImageRepo
        win_runtime  = $WinRuntime
        net          = $Net
        allow        = $allowCsv
        vcpu         = $Vcpu
        mem_mib      = $MemMib
        timeout_sec  = $timeoutSec
        lifetime_sec = $LifetimeSec
        started_at   = $startedAt
        keep_disk    = [bool]$Keep
        results_dir  = ''
        watchdog_pid = $null
        container_id = ''
        egress_pid   = $null
        relay_exec_pid = $null
    }
    Save-FcWinVmMeta -RunId $runId -MetaObj $initialMeta

    Write-FcLog "Starting Windows microVM $runId (flavour=$Flavour runtime=$WinRuntime net=$Net vcpu=$Vcpu mem=${MemMib}MiB timeout=${timeoutSec}s)"
    try {
        # Arm the watchdog before the Utility VM exists so a controller crash at any
        # later step still ends the VM on time (teardown falls back to the container name).
        Start-FcWinWatchdog -RunId $runId -LifetimeSec $LifetimeSec -ControllerScriptPath $PSCommandPath
        $started = Start-FcWinMicroVm -RunId $runId -WinRuntime $WinRuntime -ImageRef $imageRef `
            -Vcpu $Vcpu -MemMib $MemMib -NetMode $Net
        Set-FcWinVmMetaProperty -RunId $runId -Key 'container_id' -Value $started.ContainerId

        # The guest has no network adapter in either mode. Networked mode starts the egress
        # proxy and waits until it answers inside the guest, BEFORE the image entrypoint or payload.
        Set-FcWinVmNetworkPolicy -RunId $runId -WinRuntime $WinRuntime -NetMode $Net `
            -AllowCsv $allowCsv -Flavour $Flavour

        if (Test-IsIisFlavour $Flavour) {
            Start-FcWinImageEntrypoint -RunId $runId -WinRuntime $WinRuntime -ImageRef $imageRef
        }

        return $runId
    } catch {
        Remove-FcWinVmInstance -RunId $runId -ForceDeleteKeep $true
        Stop-FcWithError "Windows microVM $runId failed to start: $($_.Exception.Message)" $script:EXIT_INFRA
    }
}

switch ($Command) {
    'doctor' {
        $rc = Invoke-WinDoctor -WinRuntime $WinRuntime -ImageRepo $ImageRepo -Flavour $Flavour -Boot:$Boot
        exit $rc
    }

    'run' {
        if ([string]::IsNullOrWhiteSpace($Cmd)) {
            Stop-FcWithError "run requires -Cmd" $script:EXIT_INFRA
        }
        if ([string]::IsNullOrWhiteSpace($Payload) -or -not (Test-Path -LiteralPath $Payload -PathType Container)) {
            Stop-FcWithError "Payload directory '$Payload' not found." $script:EXIT_INFRA
        }
        $payloadFull = (Resolve-Path -LiteralPath $Payload).Path
        $runId       = Start-NewFcWinVm ($timeoutSec + $script:COLLECT_GRACE_SEC)
        $outRunDir   = Join-Path $ResultsDir $runId
        New-Item -ItemType Directory -Force -Path (Join-Path $outRunDir 'out') | Out-Null

        Write-FcWinRunResultMeta -ResultsDir $outRunDir -RunId $runId -CommandText $Cmd -PayloadPath $payloadFull
        Set-FcWinVmMetaProperty -RunId $runId -Key 'results_dir' -Value $outRunDir

        $rc = 0
        $timedOut = $false
        $errMsg = ''
        try {
            Send-FcWinGuestFiles -RunId $runId -WinRuntime $WinRuntime -SourceDir $payloadFull -GuestDir 'C:\work\in'
            Write-FcLog "Running in C:\work: $Cmd"
            $stdoutLog = Join-Path $outRunDir 'stdout.log'
            $stderrLog = Join-Path $outRunDir 'stderr.log'
            $execRes = Invoke-FcWinGuestCommand -RunId $runId -WinRuntime $WinRuntime `
                -CommandText $Cmd -TimeoutSec $timeoutSec -StdoutPath $stdoutLog -StderrPath $stderrLog
            $rc = [int]$execRes.ExitCode
            $timedOut = [bool]$execRes.TimedOut
            if ($timedOut) {
                Write-FcLog "Timed out after ${timeoutSec}s"
            } elseif (-not (Test-FcWinMicroVmRunning $runId $WinRuntime)) {
                $rc = $script:EXIT_INFRA
                $errMsg = 'Utility VM died during the run'
            }
        } catch {
            $rc = $script:EXIT_INFRA
            $errMsg = $_.Exception.Message
        } finally {
            Complete-FcWinRunResults -RunId $runId -WinRuntime $WinRuntime -OutRunDir $outRunDir `
                -CommandText $Cmd -PayloadPath $payloadFull -ExitCode $rc -TimedOut $timedOut -ErrorMessage $errMsg
            Remove-FcWinVmInstance -RunId $runId -ForceDeleteKeep $false
        }
        if ($errMsg) { Write-FcLog "error: $errMsg" }
        Write-FcLog "results: $outRunDir (exit code $rc)"
        exit $rc
    }

    'shell' {
        $runId = Start-NewFcWinVm $timeoutSec
        try {
            Write-FcLog "Windows microVM $runId ready; exit the shell to destroy it"
            [void](Invoke-FcWinInteractiveShell -RunId $runId -WinRuntime $WinRuntime)
        } finally {
            Remove-FcWinVmInstance -RunId $runId -ForceDeleteKeep $false
        }
        exit 0
    }

    'start' {
        $runId = Start-NewFcWinVm $timeoutSec
        Write-Output $runId
        exit 0
    }

    'ssh' {
        Assert-FcAdmin
        $id = if ($Rest -and $Rest.Count -ge 1) { $Rest[0] } else { '' }
        if (-not $id -or -not (Test-FcWinVmExists $id)) {
            Stop-FcWithError "No running Windows microVM '$id'" $script:EXIT_INFRA
        }
        $meta = Get-FcWinVmMeta $id
        if (-not (Test-FcWinMicroVmRunning $id $meta.win_runtime)) {
            Stop-FcWithError "Windows microVM '$id' is not running" $script:EXIT_INFRA
        }
        $remoteCmd = if ($Rest.Count -gt 1) { ($Rest[1..($Rest.Count - 1)] -join ' ') } else { '' }
        if ([string]::IsNullOrWhiteSpace($remoteCmd)) {
            $rc = Invoke-FcWinInteractiveShell -RunId $id -WinRuntime $meta.win_runtime
            exit $rc
        } else {
            $res = Invoke-FcWinGuestCommand -RunId $id -WinRuntime $meta.win_runtime -CommandText $remoteCmd
            exit $res.ExitCode
        }
    }

    'list' {
        $fmt = "{0,-22} {1,-8} {2,-16} {3,-10} {4,-5} {5,-7} {6,-20} {7}"
        Write-Output ($fmt -f 'RUN-ID', 'STATE', 'FLAVOUR', 'NET', 'VCPU', 'MEM', 'STARTED', 'ALLOW')
        foreach ($id in (Get-FcWinVmIds)) {
            $m = Get-FcWinVmMeta $id
            if (-not $m) { continue }
            $state = [string]$m.state
            if ($state -ne 'kept' -and -not (Test-FcWinMicroVmRunning $id $m.win_runtime)) {
                $state = 'dead'
            }
            Write-Output ($fmt -f $id, $state, $m.flavour, $m.net, $m.vcpu, "$($m.mem_mib)M", $m.started_at, $m.allow)
        }
        exit 0
    }

    'stop' {
        Assert-FcAdmin
        $id = if ($Rest -and $Rest.Count -ge 1) { $Rest[0] } else { '' }
        if (-not $id -or -not (Test-FcWinVmExists $id)) {
            Stop-FcWithError "Unknown Windows microVM '$id'" $script:EXIT_INFRA
        }
        Remove-FcWinVmInstance -RunId $id -ForceDeleteKeep $true
        Write-FcLog "Stopped $id"
        exit 0
    }

    'cleanup' {
        # Without elevation the container teardown fails silently; deleting the state anyway
        # would leave running VMs that nothing (not even their watchdog) can find again.
        if (-not (Test-FcAdmin)) {
            if (@(Get-FcWinVmIds).Count -eq 0) {
                Write-FcLog "No Windows microVMs to clean up."
                exit 0
            }
            Stop-FcWithError "Cleaning up Windows microVMs needs an elevated (Administrator) PowerShell prompt; their state was left untouched." $script:EXIT_INFRA
        }
        foreach ($id in (Get-FcWinVmIds)) {
            Remove-FcWinVmInstance -RunId $id -ForceDeleteKeep $true
        }
        foreach ($rt in @('docker', 'containerd')) {
            foreach ($name in (Get-FcWinOrphanContainers $rt)) {
                $orphanId = $name -replace '^fc-win-', ''
                Stop-FcWinMicroVmContainer -RunId $orphanId -WinRuntime $rt -RemoveContainer $true
            }
        }
        Stop-FcWinOrphanEgress
        Clear-AllFcWinNetworkPolicies
        $vmsDir = Get-FcWinVmsDir
        if (Test-Path -LiteralPath $vmsDir) {
            Get-ChildItem -LiteralPath $vmsDir -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
        }
        Write-FcLog "Windows cleanup complete"
        exit 0
    }

    '_expire' {
        $id = if ($Rest -and $Rest.Count -ge 1) { $Rest[0] } else { '' }
        if (-not $id -or -not (Test-FcWinVmExists $id)) { exit 0 }
        $meta = Get-FcWinVmMeta $id
        if (-not $meta -or $meta.state -eq 'kept') { exit 0 }
        Write-FcLog "Windows microVM $id reached its timeout; destroying"
        Set-FcWinVmMetaProperty -RunId $id -Key 'timed_out' -Value $true
        if ($meta.results_dir) {
            $resMetaPath = Join-Path $meta.results_dir 'meta.json'
            if (Test-Path -LiteralPath $resMetaPath) {
                try {
                    $rm = Get-Content -LiteralPath $resMetaPath -Raw | ConvertFrom-Json
                    if ($null -eq $rm.ended_at) {
                        Complete-FcWinRunResults -RunId $id -WinRuntime ([string]$meta.win_runtime) -OutRunDir ([string]$meta.results_dir) `
                            -CommandText ([string]$rm.command) -PayloadPath ([string]$rm.payload) `
                            -ExitCode $script:EXIT_TIMEOUT -TimedOut $true `
                            -ErrorMessage 'controller exited before the run finished; stopped by the watchdog'
                    }
                } catch {}
            }
        }
        Remove-FcWinVmInstance -RunId $id -ForceDeleteKeep $false
        exit 0
    }

    default {
        Stop-FcWithError "Unknown command '$Command'" $script:EXIT_INFRA
    }

# SIG # Begin signature block
# MIInggYJKoZIhvcNAQcCoIInczCCJ28CAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCCcwQrJhpTwo+K6
# IG6HW88l/68EQlQpjDwBpyQiJpB1CqCCIDYwggXJMIIEsaADAgECAhAbtY8lKt8j
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
# KoZIhvcNAQkEMSIEIGc8DldHfcLyGEPIXXLVxVCZ1+lq54KZfghf3O4uVLTIMA0G
# CSqGSIb3DQEBAQUABIIBgGkE68wCaErW/3g1MevHLkUeKhAfm/yXHxj6eJn2ciLO
# nH+a+Ux7fCJVkTyMUpeYXkTuLLBqBBZ6M+D0e4YRKfmcC4q2jmh9E2mSM6LB4kqb
# ssymqMqN63OcJa+mzdy17IsxdHh48k1ujPzUGRCpCazkhKet6LoJ97BU4xxXMDOF
# s8PAOdx9MUz+is8shPKpFbA7EETr8vjm2aEQh8sfrwyuU/lkp13n82hgdlThQA5d
# +8fB4jlqs1onEewrqD5wP4tmqY2UIE+zxXFpvblLm8JO2NV+xeJjTDs6Im/k0+LJ
# fgFUpTgiWWp0ZPJh3X39ekOHTK2L3ME+5Nm+lPQAY3zziIFvyF2Mt3tGuQmjOPmx
# jcIhfXMA2KS0jvix29bahjvwcpVwbhfTGSZ/5kBZMVB/JYZEiRZbN2e6HUcYxPvL
# NA7VbuztSCQLDrC7QBOqlmmaDHms+v2xhnjwv0eBgF3YsvsLiUGrSV828YtWkPC4
# cdeL2BDMmhSW+67XhZSkrqGCBAIwggP+BgkqhkiG9w0BCQYxggPvMIID6wIBATBq
# MFYxCzAJBgNVBAYTAlBMMSEwHwYDVQQKExhBc3NlY28gRGF0YSBTeXN0ZW1zIFMu
# QS4xJDAiBgNVBAMTG0NlcnR1bSBUaW1lc3RhbXBpbmcgMjAyMSBDQQIQKPB3wRw2
# vf5fdDJHcCcuAzANBglghkgBZQMEAgIFAKCCAVYwGgYJKoZIhvcNAQkDMQ0GCyqG
# SIb3DQEJEAEEMBwGCSqGSIb3DQEJBTEPFw0yNjExMDUwNzE5MjFaMDcGCyqGSIb3
# DQEJEAIvMSgwJjAkMCIEIIW+kOEK0kONfMkotq9IsJqyCBd87PiwEmxY05EFJcQ8
# MD8GCSqGSIb3DQEJBDEyBDDipIVVxxSwdcnjiH80vXgsDCA7QhPhskjn94byDK1h
# A9ovnXRwwDc0oxnCSGB1dL8wgZ8GCyqGSIb3DQEJEAIMMYGPMIGMMIGJMIGGBBRX
# FGhBDKha80JO+RZKUTYQ9NONmDBuMFqkWDBWMQswCQYDVQQGEwJQTDEhMB8GA1UE
# ChMYQXNzZWNvIERhdGEgU3lzdGVtcyBTLkEuMSQwIgYDVQQDExtDZXJ0dW0gVGlt
# ZXN0YW1waW5nIDIwMjEgQ0ECECjwd8EcNr3+X3QyR3AnLgMwDQYJKoZIhvcNAQEB
# BQAEggIAgWPdx9VbNFA4k9u+jD/OB6wmIqFmSTR3bK6NzzZq8jJlS1raKZwTF71e
# LPEWVgSPdT3WlzdzoF7XV4JJbipsf/KzeKoNqY/J/IBxG9ArXFbD48A7oMqchPWb
# vfEpUzVj5Ehxjc2f8maQGhMOHmP04ketYvCXSj9yNY4rwV2Kr1ATjgAkaZYfVGgw
# 96+uzXSWUb7OQ44BSkrEARkXgSnEmi4aF78J4tKTKqir1UJRX0LIRelDcD5c7lJG
# QQcjurq68ZxeLZXWy3WqxSXYlnZqsXx3DV1D7mBr/ld2WGm1sHRrlGmKpLAsYxSo
# 4H3bNp8C9R3XV6iFwmpZlulYjeIc1rl7KkPTNqljgMkaHF1KGZL1t6c/4WWxhl8q
# qGyfJ+aC2tb9LPNwbc5FIwZQDX7KdqScpHicFu1gaLiS2WVRtFJDQJPV9SeBR9D+
# CzEQWonHShi3AvVpRhwUG8+zYSEixzN0XljUF43H04gWzRTnW9DckfEroIQYN+7J
# ByyuNidFK1gKnDiHnj/9UiMU5RJEOqgotChsgAHMs322co69AGAgxXQtzgGKutB8
# GVZ5r3MzfLJSi0NFeEPlUjXuc6WF8O/cqQLNGwp61ThR76Unjt/KLYbaUvtn6ULb
# PwwBgmAVuaxas4bxegEynJUlot9RZq3i67FeIU8sww7hJN0DN/E=
# SIG # End signature block
