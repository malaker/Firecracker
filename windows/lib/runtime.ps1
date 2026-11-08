# runtime.ps1 - Windows microVM runtime adapter: Hyper-V isolated containers through
# standalone Docker Engine (default) or containerd + nerdctl + runhcs-v1 (experimental).
# Change: nanoserver-windows-microvm
Set-StrictMode -Version Latest

if (-not ('FcProc' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Threading;

// Runs a process with binary-safe stdin/stdout/stderr redirection. Output is
// written to files as it arrives (and optionally echoed), so logs survive a
// timeout or a crashed controller.
public static class FcProc
{
    public const int TimedOut = int.MinValue;
    // RunCapped only: stdout went past stdoutMax bytes; the process was killed.
    public const int CapExceeded = int.MinValue + 1;

    public static int Run(string exe, string args, string stdinFile, string stdoutFile,
                          string stderrFile, bool echo, int timeoutMs)
    {
        return RunCapped(exe, args, stdinFile, stdoutFile, stderrFile, echo, timeoutMs, -1);
    }

    // Like Run, but stops writing stdout after stdoutMax bytes (+1, so the caller sees the cap
    // was passed) and kills the process. stdoutMax < 0 means no cap.
    public static int RunCapped(string exe, string args, string stdinFile, string stdoutFile,
                                string stderrFile, bool echo, int timeoutMs, long stdoutMax)
    {
        // PowerShell passes an omitted [string] parameter as "", not null.
        if (string.IsNullOrEmpty(stdinFile)) stdinFile = null;
        if (string.IsNullOrEmpty(stdoutFile)) stdoutFile = null;
        if (string.IsNullOrEmpty(stderrFile)) stderrFile = null;
        var psi = new ProcessStartInfo(exe, args);
        psi.UseShellExecute = false;
        psi.CreateNoWindow = true;
        psi.RedirectStandardOutput = true;
        psi.RedirectStandardError = true;
        psi.RedirectStandardInput = stdinFile != null;

        // .NET Framework (Windows PowerShell 5.1) writes Console.InputEncoding's preamble
        // into redirected stdin, so a UTF-8 console would prefix the tar stream with a BOM.
        Encoding prevIn = null;
        if (stdinFile != null && Console.InputEncoding.GetPreamble().Length > 0)
        {
            prevIn = Console.InputEncoding;
            Console.InputEncoding = new UTF8Encoding(false);
        }
        Process started;
        try { started = Process.Start(psi); }
        finally { if (prevIn != null) Console.InputEncoding = prevIn; }

        using (var p = started)
        {
            var capHit = new ManualResetEvent(false);
            Thread tOut = Pump(p.StandardOutput.BaseStream, stdoutFile, echo ? Console.OpenStandardOutput() : null, stdoutMax, capHit);
            Thread tErr = Pump(p.StandardError.BaseStream, stderrFile, echo ? Console.OpenStandardError() : null, -1, null);
            if (stdinFile != null)
            {
                var tIn = new Thread(() =>
                {
                    try { using (var fs = File.OpenRead(stdinFile)) { fs.CopyTo(p.StandardInput.BaseStream); } }
                    catch (IOException) { }
                    finally { try { p.StandardInput.Close(); } catch (IOException) { } }
                });
                tIn.IsBackground = true;
                tIn.Start();
            }
            bool exited;
            if (stdoutMax < 0)
            {
                exited = p.WaitForExit(timeoutMs < 0 ? -1 : timeoutMs);
            }
            else
            {
                // Wake up when the process exits or stdout passes the cap, whichever is first.
                var deadline = timeoutMs < 0 ? DateTime.MaxValue : DateTime.UtcNow.AddMilliseconds(timeoutMs);
                exited = false;
                while (!capHit.WaitOne(0) && DateTime.UtcNow < deadline)
                {
                    if (p.WaitForExit(200)) { exited = true; break; }
                }
            }
            bool capped = capHit.WaitOne(0);
            if (!exited || capped)
            {
                try { p.Kill(); } catch (InvalidOperationException) { }
                p.WaitForExit(5000);
            }
            tOut.Join(5000);
            tErr.Join(5000);
            if (capHit.WaitOne(0)) return CapExceeded;
            return exited ? p.ExitCode : TimedOut;
        }
    }

    static Thread Pump(Stream src, string file, Stream echo, long max, ManualResetEvent capHit)
    {
        var t = new Thread(() =>
        {
            FileStream fs = file != null ? new FileStream(file, FileMode.Create, FileAccess.Write, FileShare.Read) : null;
            try
            {
                var buf = new byte[81920];
                int n;
                long total = 0;
                while ((n = src.Read(buf, 0, buf.Length)) > 0)
                {
                    if (max >= 0 && total + n > max)
                    {
                        int keep = (int)Math.Min(n, max + 1 - total);
                        if (fs != null && keep > 0) fs.Write(buf, 0, keep);
                        capHit.Set();
                        break;
                    }
                    total += n;
                    if (fs != null) { fs.Write(buf, 0, n); fs.Flush(); }
                    if (echo != null) { echo.Write(buf, 0, n); echo.Flush(); }
                }
            }
            catch (IOException) { }
            finally { if (fs != null) fs.Dispose(); }
        });
        t.IsBackground = true;
        t.Start();
        return t;
    }
}
'@
}

$script:HOST_TAR = Join-Path $env:SystemRoot 'System32\tar.exe'

function Resolve-FcWinTool([string]$ExeName) {
    $localBin = Join-Path (Get-FcWinBinDir) $ExeName
    if (Test-Path -LiteralPath $localBin) { return $localBin }
    $cmd = Get-Command $ExeName -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $localBin
}

function Get-FcDockerExe     { Resolve-FcWinTool 'docker.exe' }
function Get-FcDockerdExe    { Resolve-FcWinTool 'dockerd.exe' }
function Get-FcContainerdExe { Resolve-FcWinTool 'containerd.exe' }
function Get-FcNerdctlExe    { Resolve-FcWinTool 'nerdctl.exe' }
function Get-FcCtrExe        { Resolve-FcWinTool 'ctr.exe' }
function Get-FcRunhcsShimExe { Resolve-FcWinTool 'containerd-shim-runhcs-v1.exe' }

function Get-FcCli([string]$WinRuntime) {
    if ($WinRuntime -eq 'docker') { return Get-FcDockerExe }
    return Get-FcNerdctlExe
}

function Get-FcContainerName([string]$RunId) { "fc-win-$RunId" }

# Win32_OptionalFeature is readable without elevation (InstallState 1 = enabled).
function Test-FcWindowsFeatureEnabled([string]$FeatureName) {
    $f = Get-CimInstance -ClassName Win32_OptionalFeature -Filter "Name='$FeatureName'" -ErrorAction SilentlyContinue
    return ($null -ne $f -and $f.InstallState -eq 1)
}

function Test-FcHcsServiceRunning {
    $svc = Get-Service -Name 'vmcompute' -ErrorAction SilentlyContinue
    return ($null -ne $svc -and $svc.Status -eq 'Running')
}

function Test-FcWinRuntimeBinariesPresent([string]$WinRuntime) {
    Assert-ValidWinRuntime $WinRuntime
    if ($WinRuntime -eq 'docker') {
        return (Test-Path -LiteralPath (Get-FcDockerExe)) -and (Test-Path -LiteralPath (Get-FcDockerdExe))
    }
    return (Test-Path -LiteralPath (Get-FcContainerdExe)) -and
           (Test-Path -LiteralPath (Get-FcNerdctlExe)) -and
           (Test-Path -LiteralPath (Get-FcRunhcsShimExe))
}

# Sets "dns" in Docker's daemon.json, keeping every other setting, and returns $true only when
# the file had to change. It compares parsed values, not text: Windows PowerShell 5.1 and
# PowerShell 7 format ConvertTo-Json differently, and a text comparison restarted Docker
# (stopping every running microVM) whenever setup ran under the other shell.
function Set-FcDockerDaemonDns([string]$Path, [string[]]$Dns) {
    $config = [ordered]@{}
    if (Test-Path -LiteralPath $Path) {
        $raw = Get-Content -LiteralPath $Path -Raw
        if (-not [string]::IsNullOrWhiteSpace($raw)) {
            try {
                $parsed = $raw | ConvertFrom-Json
            } catch {
                throw "'$Path' is not valid JSON; fix or remove it and rerun setup: $($_.Exception.Message)"
            }
            foreach ($p in $parsed.PSObject.Properties) { $config[$p.Name] = $p.Value }
        }
    }
    $current = if ($config.Contains('dns')) { @($config['dns'] | ForEach-Object { [string]$_ }) } else { @() }
    if (($current -join ',') -eq ($Dns -join ',')) { return $false }
    $config['dns'] = $Dns
    $config | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $Path -Encoding utf8
    return $true
}

function Test-FcWinRuntimeReady([string]$WinRuntime) {
    Assert-ValidWinRuntime $WinRuntime
    if (-not (Test-FcWinRuntimeBinariesPresent $WinRuntime)) { return $false }
    $svc = Get-Service -Name $WinRuntime -ErrorAction SilentlyContinue
    if (-not $svc -or $svc.Status -ne 'Running') { return $false }
    if ($WinRuntime -eq 'docker') {
        $r = Invoke-FcNative -Exe (Get-FcDockerExe) -ArgList @('info', '--format', '{{.OSType}}')
        return ($r.ExitCode -eq 0 -and $r.Output -eq 'windows')
    }
    $r = Invoke-FcNative -Exe (Get-FcCtrExe) -ArgList @('version')
    return ($r.ExitCode -eq 0)
}

function Get-FcImageReference([string]$ImageRepo, [string]$Flavour) {
    Assert-ValidFlavour $Flavour
    return "${ImageRepo}:${Flavour}"
}

function Test-FcWinImagePresent([string]$WinRuntime, [string]$ImageRef) {
    if (-not (Test-FcWinRuntimeReady $WinRuntime)) { return $false }
    $r = Invoke-FcNative -Exe (Get-FcCli $WinRuntime) -ArgList @('image', 'inspect', $ImageRef)
    return ($r.ExitCode -eq 0)
}

function Invoke-FcWinImagePull([string]$WinRuntime, [string]$ImageRef) {
    Write-FcLog "Pulling Nano Server image '$ImageRef' via $WinRuntime..."
    $r = Invoke-FcNative -Exe (Get-FcCli $WinRuntime) -ArgList @('pull', $ImageRef) -Passthru
    if ($r.ExitCode -ne 0) {
        throw "Failed to pull image '$ImageRef' using $WinRuntime (exit code $($r.ExitCode)). If '$ImageRef' is not published on Docker Hub yet, pass '-ImageRepo adaskothebeast/nanoserver' to pull the upstream prebuilt image, or build locally from C:\sources\nanoserver with '-BuildFromSource -SourceDir C:\sources\nanoserver'."
    }
}

function Resolve-FcNanoserverSourceDir([string]$SourceRoot, [string]$Flavour) {
    foreach ($dir in @($SourceRoot, (Join-Path $SourceRoot 'nanoserver'))) {
        if ($dir -and (Test-Path -LiteralPath (Join-Path $dir "nanoserver-$Flavour\Dockerfile"))) {
            return (Resolve-Path -LiteralPath $dir).Path
        }
    }
    return $null
}

function Invoke-FcWinImageBuild([string]$WinRuntime, [string]$SourceRoot, [string]$Flavour, [string]$ImageRef, [string]$NanoBase) {
    Assert-FcWinFeatureSupported 'build-from-source' $WinRuntime
    $root = Resolve-FcNanoserverSourceDir $SourceRoot $Flavour
    if (-not $root) {
        throw "Nano Server source tree not found under '$SourceRoot' (expected nanoserver-$Flavour\Dockerfile)."
    }
    $flavourDir = Join-Path $root "nanoserver-$Flavour"
    $rootShimDir = Join-Path $root 'sta-shim'
    $localShimDir = Join-Path $flavourDir 'sta-shim'

    # The flavour Dockerfiles COPY a staged sta-shim folder produced by build_shim.ps1.
    $buildShim = Join-Path $rootShimDir 'build_shim.ps1'
    if (-not (Test-Path -LiteralPath (Join-Path $rootShimDir 'install_sta_shim.exe')) -and (Test-Path -LiteralPath $buildShim)) {
        Write-FcLog "Building STA shim artifacts via '$buildShim'..."
        & $buildShim | Out-Host
        if ($LASTEXITCODE -ne 0) { throw "STA shim build '$buildShim' failed with exit code $LASTEXITCODE." }
    }
    if (Test-Path -LiteralPath (Join-Path $rootShimDir 'install_sta_shim.exe')) {
        New-Item -ItemType Directory -Path $localShimDir -Force | Out-Null
        foreach ($shimFile in @('nanoserver_sta_shim_x86.dll', 'nanoserver_sta_shim_x64.dll', 'install_sta_shim.exe', 'iis_service_monitor.exe')) {
            $srcFile = Join-Path $rootShimDir $shimFile
            if (Test-Path -LiteralPath $srcFile) {
                Copy-Item -LiteralPath $srcFile -Destination $localShimDir -Force
            }
        }
    }

    # Build using --isolation=process on matching Windows 11 24H2/25H2 / Server 2025 hosts so
    # DISM /Online /Add-Capability can service the container CBS hive directly (while all runtime
    # microVMs launched by Start-FcWinMicroVm run with --isolation=hyperv).
    # -NanoBase overrides the Dockerfiles' NANO_BASE build arg (default nanoserver:ltsc2025).
    $buildArgs = @('-t', $ImageRef)
    if ($NanoBase) {
        $buildArgs += @('--build-arg', "NANO_BASE=$NanoBase")
        Write-FcLog "Building '$ImageRef' from '$flavourDir' on base '$NanoBase'..."
    } else {
        Write-FcLog "Building '$ImageRef' from '$flavourDir'..."
    }
    $r = Invoke-FcNative -Exe (Get-FcDockerExe) -ArgList (@('build', '--isolation=process') + $buildArgs + $flavourDir) -Passthru
    # 0x800F0950 (CBS_E_NO_OPTIONAL_CONTENT_FOUND_FOR_BUILD): Windows Update has no Feature on Demand
    # payload for the base image build yet, so a Hyper-V retry would fail identically.
    if ($r.ExitCode -eq -2146498224) {
        throw "Failed to build '$ImageRef': DISM found no Feature on Demand content for Nano Server base '$(if ($NanoBase) { $NanoBase } else { 'mcr.microsoft.com/windows/nanoserver:ltsc2025' })' (0x800F0950). Windows Update usually lags new base images; rerun setup with an older build, e.g. '-NanoBase mcr.microsoft.com/windows/nanoserver:10.0.26100.<build>' (list builds at https://mcr.microsoft.com/v2/windows/nanoserver/tags/list)."
    }
    if ($r.ExitCode -ne 0) {
        Write-FcLog "Retrying '$ImageRef' build with --isolation=hyperv..."
        $r = Invoke-FcNative -Exe (Get-FcDockerExe) -ArgList (@('build', '--isolation=hyperv') + $buildArgs + $flavourDir) -Passthru
    }
    if ($r.ExitCode -ne 0) {
        throw "Failed to build '$ImageRef' from '$flavourDir' (exit code $($r.ExitCode))."
    }
}

# Starts the Utility VM with a holding cmd.exe process (blocked on open stdin)
# so no guest workload (IIS or payload) runs before network policies are in place.
function Start-FcWinMicroVm {
    param(
        [Parameter(Mandatory = $true)][string]$RunId,
        [Parameter(Mandatory = $true)][string]$WinRuntime,
        [Parameter(Mandatory = $true)][string]$ImageRef,
        [Parameter(Mandatory = $true)][int]$Vcpu,
        [Parameter(Mandatory = $true)][int]$MemMib,
        [Parameter(Mandatory = $true)][string]$NetMode
    )
    $name = Get-FcContainerName $RunId
    $cli = Get-FcCli $WinRuntime
    # No network adapter in either mode: networked guests reach the network only through
    # the egress proxy over the exec channel (see net.ps1).
    if ($WinRuntime -eq 'docker') {
        $runArgs = @(
            'run', '-d', '-i', '--name', $name,
            '--isolation=hyperv',
            "--cpus=$Vcpu", "--memory=${MemMib}m",
            '-u', $script:GUEST_USER,
            '--network=none',
            '--entrypoint', 'cmd.exe', $ImageRef, '/Q', '/K'
        )
    } else {
        # nerdctl 2.0 rejects '-d' with '-i', so 'cmd /K' would exit at once on closed stdin: keep
        # the guest alive with a command that never exits. Its '--memory' makes HCS refuse to
        # create the Utility VM, so size the VM with hcsshim's own annotations instead.
        $runArgs = @(
            'run', '-d', '--name', $name,
            '--isolation=hyperv',
            '--annotation', "io.microsoft.virtualmachine.computetopology.processor.count=$Vcpu",
            '--annotation', "io.microsoft.virtualmachine.computetopology.memory.sizeinmb=$MemMib",
            '-u', $script:GUEST_USER,
            '--network=none',
            '--entrypoint', 'cmd.exe', $ImageRef, '/S', '/C', 'ping -t 127.0.0.1 >nul'
        )
    }

    $r = Invoke-FcNative -Exe $cli -ArgList $runArgs
    if ($r.ExitCode -ne 0) {
        throw "Failed to start Hyper-V Utility VM '$name' from '$ImageRef' (exit code $($r.ExitCode)): $($r.Output)"
    }

    $mk = Invoke-FcNative -Exe $cli -ArgList @('exec', '-u', $script:GUEST_USER, $name, 'cmd.exe', '/S', '/C', 'mkdir C:\work\in C:\work\out C:\work\.fc C:\fc')
    if ($mk.ExitCode -ne 0) { throw "Failed to prepare C:\work inside '$name': $($mk.Output)" }

    $cidLine = ($r.Output -split "`r?`n")[-1].Trim()
    return @{
        ContainerName = $name
        ContainerId   = $cidLine
    }
}

# '-e' arguments that point every guest process at the egress proxy in networked mode.
function Get-FcWinGuestEnvArgs([string]$RunId) {
    $meta = Get-FcWinVmMeta $RunId
    if (-not $meta -or [string]$meta.net -ne 'networked') { return @() }
    $proxy = "http://127.0.0.1:$($script:RELAY_PORT)"
    $envArgs = @()
    foreach ($kv in @("HTTP_PROXY=$proxy", "HTTPS_PROXY=$proxy", "http_proxy=$proxy", "https_proxy=$proxy",
                      'NO_PROXY=localhost,127.0.0.1', 'no_proxy=localhost,127.0.0.1')) {
        $envArgs += @('-e', $kv)
    }
    return $envArgs
}

# Starts the image's own entrypoint (e.g. the IIS service monitor) after policies are applied.
function Start-FcWinImageEntrypoint([string]$RunId, [string]$WinRuntime, [string]$ImageRef) {
    $cli = Get-FcCli $WinRuntime
    $eRes = Invoke-FcNative -Exe $cli -ArgList @('image', 'inspect', '--format', '{{json .Config.Entrypoint}}', $ImageRef)
    $cRes = Invoke-FcNative -Exe $cli -ArgList @('image', 'inspect', '--format', '{{json .Config.Cmd}}', $ImageRef)
    $entry = if ($eRes.ExitCode -eq 0 -and $eRes.Output) { $eRes.Output | ConvertFrom-Json } else { $null }
    $cmd   = if ($cRes.ExitCode -eq 0 -and $cRes.Output) { $cRes.Output | ConvertFrom-Json } else { $null }
    $argv = @(@($entry) + @($cmd) | Where-Object { $_ })
    if ($argv.Count -eq 0) { return }
    $runRes = Invoke-FcNative -Exe $cli -ArgList (@('exec', '-d', '-u', $script:GUEST_USER) + (Get-FcWinGuestEnvArgs $RunId) + @((Get-FcContainerName $RunId)) + $argv)
    if ($runRes.ExitCode -ne 0) { throw "Failed to start the image entrypoint ($($argv -join ' ')): $($runRes.Output)" }
}

function Test-FcWinMicroVmRunning([string]$RunId, [string]$WinRuntime) {
    $cli = Get-FcCli $WinRuntime
    if (-not (Test-Path -LiteralPath $cli)) { return $false }
    $r = Invoke-FcNative -Exe $cli -ArgList @('inspect', '--format', '{{.State.Running}}', (Get-FcContainerName $RunId))
    return ($r.ExitCode -eq 0 -and $r.Output -eq 'true')
}

function Invoke-FcRuntimeProcess {
    param(
        [string]$WinRuntime,
        [string[]]$ArgList,
        [string]$StdinFile,
        [string]$StdoutFile,
        [string]$StderrFile,
        [switch]$Echo,
        [int]$TimeoutSec = 0,
        # Stop and kill once stdout passes this many bytes; returns [FcProc]::CapExceeded.
        [long]$StdoutMaxBytes = -1
    )
    $timeoutMs = if ($TimeoutSec -gt 0) { $TimeoutSec * 1000 } else { -1 }
    return [FcProc]::RunCapped((Get-FcCli $WinRuntime), (ConvertTo-FcArgString $ArgList),
        $StdinFile, $StdoutFile, $StderrFile, [bool]$Echo, $timeoutMs, $StdoutMaxBytes)
}

# Copies the contents of a host directory into a guest directory by streaming a
# tar archive over the runtime's exec channel (HVSocket). No host share is mounted.
# SourceDir may also be a single file, which lands in GuestDir under its own name.
function Send-FcWinGuestFiles([string]$RunId, [string]$WinRuntime, [string]$SourceDir, [string]$GuestDir) {
    $tmp = [System.IO.Path]::GetTempFileName()
    try {
        $what = if (Test-Path -LiteralPath $SourceDir -PathType Leaf) {
            @('-C', (Split-Path -Parent $SourceDir), (Split-Path -Leaf $SourceDir))
        } else {
            @('-C', $SourceDir, '.')
        }
        $tarRes = Invoke-FcNative -Exe $script:HOST_TAR -ArgList (@('-cf', $tmp) + $what)
        if ($tarRes.ExitCode -ne 0) { throw "Failed to archive '$SourceDir': $($tarRes.Output)" }
        $errLog = "$tmp.err"
        $rc = Invoke-FcRuntimeProcess -WinRuntime $WinRuntime -StdinFile $tmp -StderrFile $errLog -TimeoutSec $script:COLLECT_TIMEOUT_SEC -ArgList @(
            'exec', '-i', '-u', $script:GUEST_USER, (Get-FcContainerName $RunId), 'tar.exe', '-xf', '-', '-C', $GuestDir)
        if ($rc -ne 0) {
            throw "Upload to $GuestDir failed (exit $rc): $(Get-Content -LiteralPath $errLog -Raw -ErrorAction SilentlyContinue)"
        }
    } finally {
        Remove-Item -LiteralPath $tmp, "$tmp.err" -Force -ErrorAction SilentlyContinue
    }
}

# Copies a guest directory back to the host. Windows tar (bsdtar) refuses absolute
# paths and '..' entries by default, so a hostile archive cannot escape DestDir.
function Receive-FcWinGuestFiles([string]$RunId, [string]$WinRuntime, [string]$GuestDir, [string]$DestDir) {
    $tmp = [System.IO.Path]::GetTempFileName()
    try {
        $rc = Invoke-FcRuntimeProcess -WinRuntime $WinRuntime -StdoutFile $tmp -StderrFile "$tmp.err" -TimeoutSec $script:COLLECT_TIMEOUT_SEC -ArgList @(
            'exec', '-u', $script:GUEST_USER, (Get-FcContainerName $RunId), 'tar.exe', '-cf', '-', '-C', $GuestDir, '.')
        if ($rc -ne 0) {
            throw "Download of $GuestDir failed (exit $rc): $(Get-Content -LiteralPath "$tmp.err" -Raw -ErrorAction SilentlyContinue)"
        }
        New-Item -ItemType Directory -Force -Path $DestDir | Out-Null
        $tarRes = Invoke-FcNative -Exe $script:HOST_TAR -ArgList @('-xf', $tmp, '-C', $DestDir)
        if ($tarRes.ExitCode -ne 0) { throw "Failed to extract files from ${GuestDir}: $($tarRes.Output)" }
    } finally {
        Remove-Item -LiteralPath $tmp, "$tmp.err" -Force -ErrorAction SilentlyContinue
    }
}

# Runs CommandText in C:\work. The command is uploaded as a batch file instead of
# being passed on the command line, so quotes and spaces reach cmd.exe unchanged.
function Invoke-FcWinGuestCommand {
    param(
        [Parameter(Mandatory = $true)][string]$RunId,
        [Parameter(Mandatory = $true)][string]$WinRuntime,
        [Parameter(Mandatory = $true)][string]$CommandText,
        [string]$StdoutPath,
        [string]$StderrPath,
        [int]$TimeoutSec = 0,
        # Do not echo the guest's output to the console (internal probes).
        [switch]$Quiet
    )
    $staging = Join-Path ([System.IO.Path]::GetTempPath()) "fc-win-$RunId-$([guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Force -Path $staging | Out-Null
    $scriptName = "cmd-$([guid]::NewGuid().ToString('N').Substring(0, 8)).cmd"
    try {
        $body = "@echo off`r`ncd /d C:\work`r`n$CommandText`r`nexit /b %ERRORLEVEL%`r`n"
        [System.IO.File]::WriteAllText((Join-Path $staging $scriptName), $body, [System.Text.Encoding]::Default)
        Send-FcWinGuestFiles -RunId $RunId -WinRuntime $WinRuntime -SourceDir $staging -GuestDir 'C:\work\.fc'
    } finally {
        Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
    }

    # nerdctl exits 1 for any non-zero guest exit code and reports the real one only on its own
    # stderr, so on containerd stderr is always captured to a file to read it back.
    $errFile = $StderrPath
    $tmpErr = $null
    if ($WinRuntime -eq 'containerd' -and -not $errFile) {
        $tmpErr = [System.IO.Path]::GetTempFileName()
        $errFile = $tmpErr
    }
    try {
        $rc = Invoke-FcRuntimeProcess -WinRuntime $WinRuntime -StdoutFile $StdoutPath -StderrFile $errFile -Echo:(-not $Quiet) -TimeoutSec $TimeoutSec -ArgList (
            @('exec', '-u', $script:GUEST_USER, '-w', 'C:\work') + (Get-FcWinGuestEnvArgs $RunId) +
            @((Get-FcContainerName $RunId), 'cmd.exe', '/S', '/C', "C:\work\.fc\$scriptName"))
        if ($rc -eq [FcProc]::TimedOut) {
            return @{ ExitCode = $script:EXIT_TIMEOUT; TimedOut = $true }
        }
        if ($WinRuntime -eq 'containerd' -and $rc -eq 1) {
            $rc = Resolve-FcNerdctlExecExitCode -StderrFile $errFile -Fallback $rc
        }
        return @{ ExitCode = $rc; TimedOut = $false }
    } finally {
        if ($tmpErr) { Remove-Item -LiteralPath $tmpErr -Force -ErrorAction SilentlyContinue }
    }
}

# nerdctl 2.0 ends a failed exec with 'level=fatal msg="exec failed with exit code N"' on its
# stderr. Returns N and removes that line, so the file keeps only the guest's own stderr.
function Resolve-FcNerdctlExecExitCode([string]$StderrFile, [int]$Fallback) {
    if (-not $StderrFile -or -not (Test-Path -LiteralPath $StderrFile)) { return $Fallback }
    # ISO-8859-1 maps every byte to one char and back, so guest output in any code page
    # survives unchanged; only nerdctl's own trailing line is cut.
    $latin1 = [System.Text.Encoding]::GetEncoding(28591)
    $text = $latin1.GetString([System.IO.File]::ReadAllBytes($StderrFile))
    $m = [regex]::Match($text, '(?:\r?\n|^)time="[^"]*" level=fatal msg="exec failed with exit code (\d+)"\r?\n?$')
    if (-not $m.Success) { return $Fallback }
    [System.IO.File]::WriteAllBytes($StderrFile, $latin1.GetBytes($text.Substring(0, $m.Index)))
    return [int]$m.Groups[1].Value
}

function Invoke-FcWinInteractiveShell([string]$RunId, [string]$WinRuntime) {
    $r = Invoke-FcNative -Exe (Get-FcCli $WinRuntime) -ArgList (@('exec', '-it', '-u', $script:GUEST_USER, '-w', 'C:\work') +
        (Get-FcWinGuestEnvArgs $RunId) + @((Get-FcContainerName $RunId), 'cmd.exe')) -Passthru
    return $r.ExitCode
}

function Stop-FcWinMicroVmContainer {
    param(
        [Parameter(Mandatory = $true)][string]$RunId,
        [Parameter(Mandatory = $true)][string]$WinRuntime,
        [string]$ContainerId = '',
        [bool]$RemoveContainer = $true
    )
    $name = Get-FcContainerName $RunId
    $cli = Get-FcCli $WinRuntime
    if (Test-Path -LiteralPath $cli) {
        if ($RemoveContainer) {
            [void](Invoke-FcNative -Exe $cli -ArgList @('rm', '-f', $name))
        } else {
            [void](Invoke-FcNative -Exe $cli -ArgList @('kill', $name))
        }
    }
    # The HCS compute system id equals the container id; kill it if the runtime left it behind.
    if ($RemoveContainer -and $ContainerId -and (Test-FcAdmin)) {
        $hcs = Invoke-FcNative -Exe 'hcsdiag.exe' -ArgList @('list')
        if ($hcs.Output -and ($hcs.Output -match [regex]::Escape($ContainerId))) {
            [void](Invoke-FcNative -Exe 'hcsdiag.exe' -ArgList @('kill', $ContainerId))
        }
    }
}

# Containers left behind by a crashed controller (no state directory).
function Get-FcWinOrphanContainers([string]$WinRuntime) {
    $cli = Get-FcCli $WinRuntime
    if (-not (Test-Path -LiteralPath $cli)) { return @() }
    $r = Invoke-FcNative -Exe $cli -ArgList @('ps', '-a', '--filter', 'name=fc-win-', '--format', '{{.Names}}')
    if ($r.ExitCode -ne 0 -or -not $r.Output) { return @() }
    return @(($r.Output -split "`r?`n") | Where-Object { $_ -like 'fc-win-*' })
}
