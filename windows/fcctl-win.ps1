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
# Refuse features the selected runtime cannot support before anything is started.
if ($Net -eq 'networked') { Assert-FcWinFeatureSupported 'networked' $WinRuntime }

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
}
