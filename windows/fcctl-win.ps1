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
    [string]$ResultsDir,
    # run: write {"run_id","results_dir"} here as soon as the VM has an id (used by the MCP server).
    [string]$RunInfoFile,
    # put: guest folder (default C:\work\in). get: host folder (must not exist or be empty).
    [string]$Dest
)

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'lib\common.ps1')
. (Join-Path $PSScriptRoot 'lib\state.ps1')
. (Join-Path $PSScriptRoot 'lib\runtime.ps1')
. (Join-Path $PSScriptRoot 'lib\egress.ps1')
. (Join-Path $PSScriptRoot 'lib\net.ps1')
. (Join-Path $PSScriptRoot 'lib\airlock.ps1')
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
  put <run-id> <host-path> [-Dest <guest-dir>]
                             Copy a host file, or a folder's contents, into a started VM
                             (default /work/in or C:\work\in)
  get <run-id> <guest-path> [-Dest <host-dir>]
                             Copy a guest file or folder out of a started VM through the guest
                             output airlock (default runs\<run-id>\files; exit 1 if refused)
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
    # Captured now: the VM (and its state) is released as soon as its output is on the host.
    $vmMeta = Get-FcWinVmMeta $RunId
    # Output leaves the guest only through the airlock (spec: guest-output-airlock). A refused
    # collection keeps the exit code and is recorded in meta.json.
    if (Test-FcWinMicroVmRunning $RunId $WinRuntime) {
        $c = Invoke-FcWinAirlockTransfer -SrcRunId $RunId -WinRuntime $WinRuntime -GuestPath 'C:\work\out' -DestDir $outFilesDir `
            -AfterPull { Remove-FcWinVmInstance -RunId $RunId -ForceDeleteKeep $false }
        New-Item -ItemType Directory -Force -Path $outFilesDir | Out-Null
    } else {
        $c = New-FcWinAirlockResult failed 'the VM was no longer running when its output was collected'
        Write-FcLog "collection failed: $($c.Reason)"
    }
    $collection = [ordered]@{
        status = $c.Status
        reason = $(if ($c.Reason) { $c.Reason } else { $null })
        files  = $c.Files
        bytes  = $c.Bytes
    }
    Write-FcTextFile -Path (Join-Path $OutRunDir 'exit_code') -Text "$ExitCode`n"
    Write-FcWinRunResultMeta -ResultsDir $OutRunDir -RunId $RunId -CommandText $CommandText `
        -PayloadPath $PayloadPath -ExitCode $ExitCode -TimedOut $TimedOut -ErrorMessage $ErrorMessage `
        -Collection $collection -VmMeta $vmMeta
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

# A started VM that put/get may use: exists, running, and not an airlock. Returns its id.
function Assert-FcWinSessionVm([string]$Id) {
    Assert-FcAdmin
    if (-not $Id -or -not (Test-FcWinVmExists $Id)) { Stop-FcWithError "No running Windows microVM '$Id'" $script:EXIT_INFRA }
    $m = Get-FcWinVmMeta $Id
    if (-not (Test-FcWinMicroVmRunning $Id ([string]$m.win_runtime))) { Stop-FcWithError "Windows microVM '$Id' is not running" $script:EXIT_INFRA }
    if ($m.PSObject.Properties['role'] -and $m.role -eq 'airlock') { Stop-FcWithError "Windows microVM '$Id' is an airlock" $script:EXIT_INFRA }
    return $Id
}

# Destroys a VM unless it is already gone or kept (e.g. released by output collection).
function Remove-FcWinVmIfActive([string]$RunId) {
    $m = Get-FcWinVmMeta $RunId
    if ($m -and [string]$m.state -ne 'kept') { Remove-FcWinVmInstance -RunId $RunId -ForceDeleteKeep $false }
}

# Boots a Windows microVM with explicit settings and returns its run id. Throws on failure
# (after removing what it started), so callers that must survive a failed boot - the guest
# output airlock - can. role is 'vm' or 'airlock'; an airlock records the run it serves.
function Start-FcWinVmCore {
    param(
        [Parameter(Mandatory = $true)][string]$VmRuntime,
        [Parameter(Mandatory = $true)][string]$VmImageRepo,
        [Parameter(Mandatory = $true)][string]$VmFlavour,
        [Parameter(Mandatory = $true)][int]$VmVcpu,
        [Parameter(Mandatory = $true)][int]$VmMemMib,
        [Parameter(Mandatory = $true)][string]$VmNet,
        [string]$VmAllowCsv = '',
        [Parameter(Mandatory = $true)][int]$VmTimeoutSec,
        [Parameter(Mandatory = $true)][int]$LifetimeSec,
        [bool]$VmKeep = $false,
        [string]$Role = 'vm',
        [string]$Parent = ''
    )
    Assert-ValidResources -Vcpu $VmVcpu -MemMib $VmMemMib
    if (-not (Test-FcWinRuntimeReady $VmRuntime)) {
        throw "Windows runtime '$VmRuntime' is not running; run '.\fc.ps1 doctor -Guest windows'."
    }

    $runId    = New-FcRunId
    $imageRef = Get-FcImageReference $VmImageRepo $VmFlavour

    $initialMeta = [ordered]@{
        run_id       = $runId
        guest        = 'windows'
        state        = 'running'
        role         = $Role
        parent       = $(if ($Parent) { $Parent } else { $null })
        flavour      = $VmFlavour
        image_repo   = $VmImageRepo
        win_runtime  = $VmRuntime
        net          = $VmNet
        allow        = $VmAllowCsv
        vcpu         = $VmVcpu
        mem_mib      = $VmMemMib
        timeout_sec  = $VmTimeoutSec
        lifetime_sec = $LifetimeSec
        started_at   = (Get-IsoTimestamp)
        keep_disk    = $VmKeep
        results_dir  = ''
        watchdog_pid = $null
        container_id = ''
        egress_pid   = $null
        relay_exec_pid = $null
    }
    Save-FcWinVmMeta -RunId $runId -MetaObj $initialMeta

    $what = if ($Role -eq 'airlock') { "airlock for $Parent" } else { 'microVM' }
    Write-FcLog "Starting Windows $what $runId (flavour=$VmFlavour runtime=$VmRuntime net=$VmNet vcpu=$VmVcpu mem=${VmMemMib}MiB timeout=${VmTimeoutSec}s)"
    try {
        # Arm the watchdog before the Utility VM exists so a controller crash at any
        # later step still ends the VM on time (teardown falls back to the container name).
        Start-FcWinWatchdog -RunId $runId -LifetimeSec $LifetimeSec -ControllerScriptPath $PSCommandPath
        $started = Start-FcWinMicroVm -RunId $runId -WinRuntime $VmRuntime -ImageRef $imageRef `
            -Vcpu $VmVcpu -MemMib $VmMemMib -NetMode $VmNet
        Set-FcWinVmMetaProperty -RunId $runId -Key 'container_id' -Value $started.ContainerId

        # The guest has no network adapter in either mode. Networked mode starts the egress
        # proxy and waits until it answers inside the guest, BEFORE the image entrypoint or payload.
        Set-FcWinVmNetworkPolicy -RunId $runId -WinRuntime $VmRuntime -NetMode $VmNet `
            -AllowCsv $VmAllowCsv -Flavour $VmFlavour

        if ($Role -ne 'airlock' -and (Test-IsIisFlavour $VmFlavour)) {
            Start-FcWinImageEntrypoint -RunId $runId -WinRuntime $VmRuntime -ImageRef $imageRef
        }
        return $runId
    } catch {
        $msg = $_.Exception.Message
        Remove-FcWinVmInstance -RunId $runId -ForceDeleteKeep $true
        throw "Windows $what $runId failed to start: $msg"
    }
}

# Boots a VM with the command-line options; exits the controller on failure.
function Start-NewFcWinVm([int]$LifetimeSec) {
    Assert-FcAdmin
    try {
        return Start-FcWinVmCore -VmRuntime $WinRuntime -VmImageRepo $ImageRepo -VmFlavour $Flavour `
            -VmVcpu $Vcpu -VmMemMib $MemMib -VmNet $Net -VmAllowCsv $allowCsv -VmTimeoutSec $timeoutSec `
            -LifetimeSec $LifetimeSec -VmKeep ([bool]$Keep)
    } catch {
        Stop-FcWithError $_.Exception.Message $script:EXIT_INFRA
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
        if ($RunInfoFile) {
            try {
                $info = [ordered]@{ run_id = $runId; results_dir = $outRunDir } | ConvertTo-Json -Compress
                [System.IO.File]::WriteAllText("$RunInfoFile.tmp", $info)
                Move-Item -LiteralPath "$RunInfoFile.tmp" -Destination $RunInfoFile -Force
            } catch {
                Write-FcLog "warning: could not write the run info file ${RunInfoFile}: $($_.Exception.Message)"
            }
        }

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
            # Collection already released the VM once its output was pulled.
            Remove-FcWinVmIfActive $runId
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

    'put' {
        $id = Assert-FcWinSessionVm $(if ($Rest -and $Rest.Count -ge 1) { $Rest[0] } else { '' })
        $src = if ($Rest -and $Rest.Count -ge 2) { $Rest[1] } else { '' }
        if (-not $src -or -not (Test-Path -LiteralPath $src)) { Stop-FcWithError "Host path '$src' not found." $script:EXIT_INFRA }
        $guestDir = if ($Dest) { $Dest } else { 'C:\work\in' }
        if ($guestDir -match '["%!\r\n]') { Stop-FcWithError "Unsupported characters in guest folder '$guestDir'." $script:EXIT_INFRA }
        $rt = [string](Get-FcWinVmMeta $id).win_runtime
        try {
            $mk = Invoke-FcWinGuestCommand -RunId $id -WinRuntime $rt -Quiet -TimeoutSec 60 -CommandText "if not exist `"$guestDir\`" mkdir `"$guestDir`""
            if ($mk.ExitCode -ne 0) { throw "could not create $guestDir in the guest" }
            Send-FcWinGuestFiles -RunId $id -WinRuntime $rt -SourceDir (Resolve-Path -LiteralPath $src).Path -GuestDir $guestDir
        } catch {
            Stop-FcWithError "Copy into ${guestDir} failed: $($_.Exception.Message)" $script:EXIT_INFRA
        }
        Write-FcLog "Copied $src into $guestDir"
        exit 0
    }

    'get' {
        $id = Assert-FcWinSessionVm $(if ($Rest -and $Rest.Count -ge 1) { $Rest[0] } else { '' })
        $guestPath = if ($Rest -and $Rest.Count -ge 2) { $Rest[1] } else { '' }
        if (-not $guestPath) { Stop-FcWithError "get needs a guest path" $script:EXIT_INFRA }
        if (-not $Dest) { Stop-FcWithError "get needs -Dest <host folder>" $script:EXIT_INFRA }
        $rt = [string](Get-FcWinVmMeta $id).win_runtime
        $r = Invoke-FcWinAirlockTransfer -SrcRunId $id -WinRuntime $rt -GuestPath $guestPath -DestDir $Dest -MissingIsError
        if ($r.Status -eq 'ok') {
            Write-FcLog "Copied $($r.Files) files ($($r.Bytes) bytes) from $guestPath to $Dest"
            exit 0
        }
        if ($r.Status -eq 'refused' -or $r.Reason -like 'guest path *') { exit 1 }
        exit $script:EXIT_INFRA
    }

    'list' {
        $fmt ="{0,-22} {1,-8} {2,-16} {3,-10} {4,-5} {5,-7} {6,-20} {7,-18} {8}"
        Write-Output ($fmt -f 'RUN-ID', 'STATE', 'FLAVOUR', 'NET', 'VCPU', 'MEM', 'STARTED', 'ALLOW', 'ROLE')
        foreach ($id in (Get-FcWinVmIds)) {
            $m = Get-FcWinVmMeta $id
            if (-not $m) { continue }
            $state = [string]$m.state
            if ($state -ne 'kept' -and -not (Test-FcWinMicroVmRunning $id $m.win_runtime)) {
                $state = 'dead'
            }
            $role = if ($m.PSObject.Properties['role'] -and $m.role -eq 'airlock') { "airlock:$($m.parent)" } else { 'vm' }
            $allowShown = if ($m.allow) { $m.allow } else { '-' }
            Write-Output ($fmt -f $id, $state, $m.flavour, $m.net, $m.vcpu, "$($m.mem_mib)M", $m.started_at, $allowShown, $role)
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
        # Airlock leftovers: a host-side check still running and transfer staging folders.
        # (Airlock VMs themselves are ordinary VMs and were destroyed above.)
        Get-Process -Name 'fc-airlock' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        Get-ChildItem -LiteralPath ([System.IO.Path]::GetTempPath()) -Directory -Filter 'fc-airlock-*' -Force -ErrorAction SilentlyContinue |
            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
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
        Remove-FcWinVmIfActive $id
        exit 0
    }

    default {
        Stop-FcWithError "Unknown command '$Command'" $script:EXIT_INFRA
    }
}
