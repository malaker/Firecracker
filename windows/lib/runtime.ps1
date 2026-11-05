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

    public static int Run(string exe, string args, string stdinFile, string stdoutFile,
                          string stderrFile, bool echo, int timeoutMs)
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
            Thread tOut = Pump(p.StandardOutput.BaseStream, stdoutFile, echo ? Console.OpenStandardOutput() : null);
            Thread tErr = Pump(p.StandardError.BaseStream, stderrFile, echo ? Console.OpenStandardError() : null);
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
            bool exited = p.WaitForExit(timeoutMs < 0 ? -1 : timeoutMs);
            if (!exited)
            {
                try { p.Kill(); } catch (InvalidOperationException) { }
                p.WaitForExit(5000);
            }
            tOut.Join(5000);
            tErr.Join(5000);
            return exited ? p.ExitCode : TimedOut;
        }
    }

    static Thread Pump(Stream src, string file, Stream echo)
    {
        var t = new Thread(() =>
        {
            FileStream fs = file != null ? new FileStream(file, FileMode.Create, FileAccess.Write, FileShare.Read) : null;
            try
            {
                var buf = new byte[8192];
                int n;
                while ((n = src.Read(buf, 0, buf.Length)) > 0)
                {
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
    if ($WinRuntime -ne 'docker') {
        throw "-BuildFromSource needs '-WinRuntime docker': nerdctl builds need BuildKit, which has no supported Windows container builder."
    }
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
    $runArgs = @(
        'run', '-d', '-i', '--name', $name,
        '--isolation=hyperv',
        "--cpus=$Vcpu", "--memory=${MemMib}m",
        '-u', $script:GUEST_USER,
        # No network adapter in either mode: networked guests reach the network only through
        # the egress proxy over the exec channel (see net.ps1).
        '--network=none'
    )
    $runArgs += @('--entrypoint', 'cmd.exe', $ImageRef, '/Q', '/K')

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
        [int]$TimeoutSec = 0
    )
    $timeoutMs = if ($TimeoutSec -gt 0) { $TimeoutSec * 1000 } else { -1 }
    return [FcProc]::Run((Get-FcCli $WinRuntime), (ConvertTo-FcArgString $ArgList),
        $StdinFile, $StdoutFile, $StderrFile, [bool]$Echo, $timeoutMs)
}

# Copies the contents of a host directory into a guest directory by streaming a
# tar archive over the runtime's exec channel (HVSocket). No host share is mounted.
function Send-FcWinGuestFiles([string]$RunId, [string]$WinRuntime, [string]$SourceDir, [string]$GuestDir) {
    $tmp = [System.IO.Path]::GetTempFileName()
    try {
        $tarRes = Invoke-FcNative -Exe $script:HOST_TAR -ArgList @('-cf', $tmp, '-C', $SourceDir, '.')
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
        [int]$TimeoutSec = 0
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

    $rc = Invoke-FcRuntimeProcess -WinRuntime $WinRuntime -StdoutFile $StdoutPath -StderrFile $StderrPath -Echo -TimeoutSec $TimeoutSec -ArgList (
        @('exec', '-u', $script:GUEST_USER, '-w', 'C:\work') + (Get-FcWinGuestEnvArgs $RunId) +
        @((Get-FcContainerName $RunId), 'cmd.exe', '/S', '/C', "C:\work\.fc\$scriptName"))
    if ($rc -eq [FcProc]::TimedOut) {
        return @{ ExitCode = $script:EXIT_TIMEOUT; TimedOut = $true }
    }
    return @{ ExitCode = $rc; TimedOut = $false }
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
# SIG # Begin signature block
# MIInggYJKoZIhvcNAQcCoIInczCCJ28CAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCDxlxWYyhmr5RI1
# StPaNtNvu9v41W1nSA5ZAUdMv73rYaCCIDYwggXJMIIEsaADAgECAhAbtY8lKt8j
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
# KoZIhvcNAQkEMSIEIFaCNne8R1123KI94hlLutD1T1aIzlpS5mBqZKWleTvCMA0G
# CSqGSIb3DQEBAQUABIIBgBkLbHKv+G2ynkojR4kaMfX5k6G0xcHTuZak45L09Xy+
# Ag74HFLWlw1zijsU05ZtmjcWagk6brfbG5WYpqOK3kYJ6pCrYL1lpAdVqCnubc41
# 1sl130Pu5c95Pv4j72UTMgg1a5y4ndVI11FdNHKVpjqKAr98tITKKWotGg/Vj+Xi
# zjMUpVeO2QN8zmh3t83BAQSwLT7rlPKxOhQAM0XzqcQoK/RIrdKSFT1+8x6p7vKP
# iWsKB4xFampHxWlfHCVq9oQyLPtxzymspeUIM594E7notJ4zs6lER0SSoGpM2kDl
# amKYyjpFo67L4RadCmLg74uCMj8u3Dl9dsrBY4ag6B/IEWNFgCVWFP0UM8PkTTxH
# ejGeQlK+V2Eb7riQKSqxc39V9izSvHrR+tejs7qznoHldW0pXTc5wWU4k7p9w3yr
# Ulgg9+nXMg8gV/plW32NSsKOLI07yrPNCpHgpz0+A37d5XZdAUCGVzZ6mLHKuRzG
# mgigzmXcSueugV/e5mnFeaGCBAIwggP+BgkqhkiG9w0BCQYxggPvMIID6wIBATBq
# MFYxCzAJBgNVBAYTAlBMMSEwHwYDVQQKExhBc3NlY28gRGF0YSBTeXN0ZW1zIFMu
# QS4xJDAiBgNVBAMTG0NlcnR1bSBUaW1lc3RhbXBpbmcgMjAyMSBDQQIQKPB3wRw2
# vf5fdDJHcCcuAzANBglghkgBZQMEAgIFAKCCAVYwGgYJKoZIhvcNAQkDMQ0GCyqG
# SIb3DQEJEAEEMBwGCSqGSIb3DQEJBTEPFw0yNjExMDUwNzA5MzJaMDcGCyqGSIb3
# DQEJEAIvMSgwJjAkMCIEIIW+kOEK0kONfMkotq9IsJqyCBd87PiwEmxY05EFJcQ8
# MD8GCSqGSIb3DQEJBDEyBDAW3afXUsawPqoSao8yB4tKST7t7i1b9V9mFK+tsCHM
# Xz6M+NcWtcsfVTrrlBVCEiUwgZ8GCyqGSIb3DQEJEAIMMYGPMIGMMIGJMIGGBBRX
# FGhBDKha80JO+RZKUTYQ9NONmDBuMFqkWDBWMQswCQYDVQQGEwJQTDEhMB8GA1UE
# ChMYQXNzZWNvIERhdGEgU3lzdGVtcyBTLkEuMSQwIgYDVQQDExtDZXJ0dW0gVGlt
# ZXN0YW1waW5nIDIwMjEgQ0ECECjwd8EcNr3+X3QyR3AnLgMwDQYJKoZIhvcNAQEB
# BQAEggIAL2uJq3ajcV4csjuWWPraznh8Ld2vjCWOxaUeFhpGaB6DfSoUTHgQOD/Z
# FEeF4ra9/nkQl6OH/n/e8tx/4QkeMT35lsVj7jYeNGokNF9oPhElcw3sqO6EdYFF
# o5R6G8B2TTbbBAZr2wD+YfgN5SwP/GL3aFb4MKEOVcQGSus4SLa7T2d10z2qjxTf
# oYlL0eN7M8TIc2oRbShfYoNbcmxw0R4gxuXGdESxYIRluVqCfONHzOHkFT9GTS2M
# Zgeme4bnrdMeOe8m2I6xR+tE/43lcsb+d6c1zKcHCpv9QFjoEmryo5fJk74+D4VP
# QNHrfJIfHjCYcVIF73nwjYkqx03CuoCpjx4V7RcqU90ejiwCCBG06Iw0BTC3cFfW
# xnBl3Lgm4RHhjW8rM8oypLq1mSbVcYFpZ2VBdIzgZSisdqd6aNMbRwawrahri0ms
# sMLv61tRcsP03hnRXyZwUFTmO59XgA3NiQN5/iGpqUuWA1DExH+aq/sQbO0v1Itn
# /ZsQAcRyxsdlBzMSJNU3XdrHGzlfF05Au5/EBaorkxe1Y1IE8FW1VYwvbrBqL+km
# D6M/Dm9CwxWUpWknM5wgEeEKfaEfQLGIt1sA3Ha+gsr+c7FxXK9p6f59EZlysa0u
# TlCjx78FAH83FthPg1XOAmvcL0KH9HCVtGniUPef/f1/C3fjJ1Q=
# SIG # End signature block
