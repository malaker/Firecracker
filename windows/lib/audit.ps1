# audit.ps1 - 'fc.ps1 audit -Guest windows': run a program in disposable Windows microVMs and report
# what it did (spec: sandbox-audit, change: add-windows-sandbox-audit).
Set-StrictMode -Version Latest

function Get-FcWinAuditDir { Join-Path (Get-FcWinBinDir) 'audit' }
function Get-FcWinAuditExe { Join-Path (Get-FcWinAuditDir) 'fc-audit.exe' }

function Test-FcWinAuditPresent {
    $exe = Get-FcWinAuditExe
    if (-not (Test-Path -LiteralPath $exe)) { return $false }
    $r = Invoke-FcNative -Exe $exe -ArgList @('--version')
    return ($r.ExitCode -eq 0 -and $r.Output -match '^fc-audit ')
}

# Escapes the user's -Arguments for one line of a batch file (design D3), so the program receives
# exactly that text. cmd.exe expands '%' everywhere in a batch file, so it is always doubled; outside
# double quotes it also acts on ^ & | < > ( ), so those get a '^' prefix. Inside quotes they are
# already literal, and cmd's quote state flips on every '"' (it knows no backslash escapes), which is
# what this tracks. Delayed expansion is off, so '!' needs nothing. Control characters (CR, LF, ...)
# cannot be carried on one batch line and are refused.
function ConvertTo-FcBatchArguments([AllowEmptyString()][string]$Text) {
    if ($null -eq $Text) { return '' }
    foreach ($ch in $Text.ToCharArray()) {
        if ([int]$ch -lt 0x20 -or [int]$ch -eq 0x7f) {
            throw ("-Arguments cannot contain control characters (found U+{0:X4})." -f [int]$ch)
        }
    }
    $sb = [System.Text.StringBuilder]::new()
    $inQuotes = $false
    foreach ($ch in $Text.ToCharArray()) {
        if ($ch -eq '"') { $inQuotes = -not $inQuotes; [void]$sb.Append($ch); continue }
        if ($ch -eq '%') { [void]$sb.Append('%%'); continue }
        if (-not $inQuotes -and '^&|<>()'.IndexOf($ch) -ge 0) { [void]$sb.Append('^') }
        [void]$sb.Append($ch)
    }
    return $sb.ToString()
}

# Guest layout (design D1/D2): the sample copy and the audit scripts sit side by side in C:\work\in,
# so nothing in the sample can stand in for a script.
$script:AUDIT_GUEST_APP     = 'C:\work\in\app'
$script:AUDIT_GUEST_SCRIPTS = 'C:\work\in\.audit'
$script:AUDIT_SNAPSHOT_TIMEOUT_SEC = 300
$script:AUDIT_STOP_TIMEOUT_SEC     = 60

# snapshot.cmd before|after: file listing of C:\ and registry exports into C:\work\out\_audit.
# Absolute System32 paths, so a program that drops a reg.exe on the PATH cannot stand in for it.
$script:AUDIT_SNAPSHOT_CMD = @'
@echo off
setlocal
if /i not "%~1"=="before" if /i not "%~1"=="after" exit /b 2
if exist C:\Windows\System32\chcp.com C:\Windows\System32\chcp.com 65001 >nul
set "A=C:\work\out\_audit"
if not exist "%A%" mkdir "%A%"
dir /s /b /a C:\ > "%A%\fs-%~1.txt" 2>nul
C:\Windows\System32\reg.exe export HKLM\SOFTWARE "%A%\hklm-%~1.reg" /y >nul 2>&1
C:\Windows\System32\reg.exe export HKCU "%A%\hkcu-%~1.reg" /y >nul 2>&1
exit /b 0
'@

# The program step: run the entry in C:\work\out with the escaped arguments (design D3). The file
# is UTF-8 and switches cmd to code page 65001 first (when chcp.com exists), so non-ASCII arguments arrive intact.
function New-FcWinAuditProgramCmd([string]$Entry, [AllowEmptyString()][string]$Arguments) {
    $exe = (Join-Path $script:AUDIT_GUEST_APP $Entry) -replace '%', '%%'
    $line = "`"$exe`""
    $escaped = ConvertTo-FcBatchArguments $Arguments
    if ($escaped) { $line += " $escaped" }
    return "@echo off`r`nif exist C:\Windows\System32\chcp.com C:\Windows\System32\chcp.com 65001 >nul`r`ncd /d C:\work\out`r`n$line`r`nexit /b %ERRORLEVEL%`r`n"
}

# Where the controller uploads fc-audit.exe as the stop helper, only after a timeout (Nano Server has
# no taskkill.exe).
$script:AUDIT_GUEST_STOP_HELPER = 'C:\work\in\.audit\fc-audit.exe'

# stop.cmd: after a timeout, stop the program (and the processes it started) by its image name before
# the after snapshots, so they and the output collection see a quiet guest. It uses taskkill.exe when
# the guest has one, else the uploaded helper ('fc-audit kill'). Exit 0 stopped (or already gone),
# 1 stopping failed, 3 no way to stop it (no taskkill.exe and no helper), 4 the entry is a batch file,
# which runs as cmd.exe and cannot be stopped by name without stopping the audit's own shell.
function New-FcWinAuditStopCmd([string]$Entry) {
    $leaf = Split-Path -Leaf $Entry
    if ([System.IO.Path]::GetExtension($leaf) -in @('.cmd', '.bat')) { return "@echo off`r`nexit /b 4`r`n" }
    $image = $leaf -replace '%', '%%'
    return (@(
        '@echo off'
        'if exist C:\Windows\System32\taskkill.exe goto taskkill'
        "if exist $script:AUDIT_GUEST_STOP_HELPER goto helper"
        'exit /b 3'
        ':taskkill'
        "C:\Windows\System32\taskkill.exe /F /T /IM `"$image`" >nul 2>&1"
        'rem 128: no such process (it already ended)'
        'if errorlevel 1 if not errorlevel 128 exit /b 1'
        'exit /b 0'
        ':helper'
        "$script:AUDIT_GUEST_STOP_HELPER kill --image `"$image`""
        'if errorlevel 1 exit /b 1'
        'exit /b 0'
    ) -join "`r`n") + "`r`n"
}

# True for a junction or symbolic link (not for other reparse points such as cloud placeholders).
function Test-FcWinAuditLink($Item) {
    if (-not ($Item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { return $false }
    $lt = $Item.PSObject.Properties['LinkType']
    if ($lt -and $lt.Value) { return ([string]$lt.Value -in @('Junction', 'SymbolicLink')) }
    # No LinkType: .NET's LinkTarget is set only for name-surrogate links (PowerShell 7).
    $tgt = $Item.PSObject.Properties['LinkTarget']
    return [bool]($tgt -and $tgt.Value)
}

# Checks -Entry: a relative path to a file inside the sample folder (no rooted paths, no '..', no
# quotes or control characters, which cannot be carried on the batch line).
function Assert-FcWinAuditEntry([string]$Entry) {
    if ([string]::IsNullOrWhiteSpace($Entry)) { throw '-Entry is required when -Sample is a folder: name the program inside it, e.g. -Entry bin\tool.exe' }
    if ($Entry -match '[\x00-\x1f"]') { throw "-Entry '$Entry' contains characters that cannot be used (quotes or control characters)." }
    if ([System.IO.Path]::IsPathRooted($Entry) -or $Entry -match '^[\\/]' -or $Entry -match ':') { throw "-Entry '$Entry' must be a path relative to the -Sample folder." }
    if (($Entry -split '[\\/]') -contains '..') { throw "-Entry '$Entry' must stay inside the -Sample folder (no '..')." }
}

# Stages the sample for upload (design D2) and returns what the controller needs. Throws with a
# user-facing message on any refusal; the caller removes $result.Root in a finally block.
function New-FcWinAuditStage {
    param(
        [Parameter(Mandatory = $true)][string]$Sample,
        [string]$Entry,
        [string[]]$Exclude = @(),
        [AllowEmptyString()][string]$Arguments = '',
        [string]$StagingDir
    )
    if (-not (Test-Path -LiteralPath $Sample)) { throw "-Sample '$Sample' not found." }
    $sampleFull = (Resolve-Path -LiteralPath $Sample).ProviderPath
    $isFile = Test-Path -LiteralPath $sampleFull -PathType Leaf
    if ($isFile) {
        $leaf = Split-Path -Leaf $sampleFull
        if ($Entry -and $Entry -ne $leaf) { throw "-Entry '$Entry' does not match -Sample: for a single file, leave -Entry out or give its name ('$leaf')." }
        if ($Exclude) { throw '-Exclude only applies when -Sample is a folder.' }
        $Entry = $leaf
    }
    Assert-FcWinAuditEntry $Entry
    # Validate the arguments before copying anything.
    [void](ConvertTo-FcBatchArguments $Arguments)

    $base = if ($StagingDir) { $StagingDir } else { [System.IO.Path]::GetTempPath() }
    if (-not (Test-Path -LiteralPath $base -PathType Container)) { throw "-StagingDir '$base' is not an existing folder." }
    $root = Join-Path (Resolve-Path -LiteralPath $base).ProviderPath "fc-audit-$([guid]::NewGuid().ToString('N'))"
    $payload = Join-Path $root 'payload'
    $app = Join-Path $payload 'app'
    $scripts = Join-Path $payload '.audit'
    New-Item -ItemType Directory -Force -Path $app, $scripts | Out-Null
    try {
        if ($isFile) {
            Copy-Item -LiteralPath $sampleFull -Destination $app
        } else {
            # -Exclude takes top-level names only: a path such as 'config\secrets.json' would pass an
            # existence check but not the top-level filter, and the file would silently go into the VM.
            $skip = @($Exclude | Where-Object { $_ })
            $badSkip = @($skip | Where-Object { $_ -match '[\\/:\x00-\x1f]' -or $_ -in @('.', '..') })
            if ($badSkip) { throw "-Exclude takes names of entries directly inside the -Sample folder, not paths: $($badSkip -join ', ')" }
            $missing = @($skip | Where-Object { -not (Test-Path -LiteralPath (Join-Path $sampleFull $_)) })
            if ($missing) { throw "-Exclude names entries that are not in the -Sample folder: $($missing -join ', ')" }
            $top = @(Get-ChildItem -LiteralPath $sampleFull -Force -ErrorAction Stop | Where-Object { $skip -notcontains $_.Name })
            # A junction or symbolic link inside the sample could pull other host files into the VM:
            # refuse it instead of following it. Only real links count: other reparse points (OneDrive
            # and cloud placeholders, deduplicated files) are ordinary files. Excluded entries are not scanned.
            foreach ($t in $top) {
                $items = @($t) + $(if ($t.PSIsContainer -and -not (Test-FcWinAuditLink $t)) { @(Get-ChildItem -LiteralPath $t.FullName -Recurse -Force -ErrorAction Stop) } else { @() })
                $link = $items | Where-Object { Test-FcWinAuditLink $_ } | Select-Object -First 1
                if ($link) { throw "-Sample contains a link or junction, which is not supported: $($link.FullName)" }
            }
            foreach ($t in $top) { Copy-Item -LiteralPath $t.FullName -Destination $app -Recurse -Force }
        }
        $entryPath = [System.IO.Path]::GetFullPath((Join-Path $app $Entry))
        if (-not $entryPath.StartsWith($app + '\', [StringComparison]::OrdinalIgnoreCase) -or -not (Test-Path -LiteralPath $entryPath -PathType Leaf)) {
            throw "-Entry '$Entry' is not a file in the -Sample folder" + $(if ($Exclude) { ' (after -Exclude)' } else { '' }) + '.'
        }
        $utf8 = [System.Text.UTF8Encoding]::new($false)
        [System.IO.File]::WriteAllText((Join-Path $scripts 'snapshot.cmd'), ($script:AUDIT_SNAPSHOT_CMD -replace "`r?`n", "`r`n"), $utf8)
        [System.IO.File]::WriteAllText((Join-Path $scripts 'program.cmd'), (New-FcWinAuditProgramCmd -Entry $Entry -Arguments $Arguments), $utf8)
        [System.IO.File]::WriteAllText((Join-Path $scripts 'stop.cmd'), (New-FcWinAuditStopCmd -Entry $Entry), $utf8)
        return [pscustomobject]@{
            Root       = $root
            Payload    = $payload
            SamplePath = $sampleFull
            Entry      = $Entry
            Sha256     = (Get-FileHash -LiteralPath $entryPath -Algorithm SHA256).Hash.ToLowerInvariant()
        }
    } catch {
        Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
        throw
    }
}

# One audit run (design D1 steps 1-4) in a fresh microVM. Never throws: returns what happened, so
# a failed isolated run does not stop the networked one (spec: audit exit codes).
function Invoke-FcWinAuditRun {
    param(
        [Parameter(Mandatory = $true)]$Stage,
        [Parameter(Mandatory = $true)][ValidateSet('isolated', 'networked')][string]$Mode,
        [Parameter(Mandatory = $true)][string]$WinRuntime,
        [Parameter(Mandatory = $true)][string]$ImageRepo,
        [Parameter(Mandatory = $true)][string]$Flavour,
        [int]$Vcpu,
        [int]$MemMib,
        [string]$AllowCsv = '',
        [Parameter(Mandatory = $true)][int]$TimeoutSec,
        [bool]$Keep = $false,
        [Parameter(Mandatory = $true)][string]$ResultsDir,
        [AllowEmptyString()][string]$Arguments = ''
    )
    $result = [pscustomobject]@{ Mode = $Mode; RunId = $null; ResultsDir = $null; Ok = $false; ProgramExitCode = $null; ProgramFinished = $false; ProgramStopped = $false; Error = '' }
    $commandText = "audit: $($Stage.Entry)" + $(if ($Arguments) { " $Arguments" } else { '' })
    $auditMeta = [ordered]@{ sample = (Split-Path -Leaf $Stage.SamplePath); sample_path = $Stage.SamplePath; entry = $Stage.Entry; sha256 = $Stage.Sha256; arguments = $Arguments; mode = $Mode }
    # Every step that runs while the VM must stay up: the program, two snapshots, the stop step, the
    # payload upload, the stop helper's upload, one script upload per guest command (4 commands), and
    # the airlock's pull.
    $lifetime = $TimeoutSec + 2 * $script:AUDIT_SNAPSHOT_TIMEOUT_SEC + $script:AUDIT_STOP_TIMEOUT_SEC +
        6 * $script:COLLECT_TIMEOUT_SEC + $script:AIRLOCK_PULL_TIMEOUT_SEC + $script:COLLECT_GRACE_SEC
    try {
        $runId = Start-FcWinVmCore -VmRuntime $WinRuntime -VmImageRepo $ImageRepo -VmFlavour $Flavour `
            -VmVcpu $Vcpu -VmMemMib $MemMib -VmNet $Mode -VmAllowCsv $(if ($Mode -eq 'networked') { $AllowCsv } else { '' }) `
            -VmTimeoutSec $TimeoutSec -LifetimeSec $lifetime -VmKeep $Keep
    } catch {
        $result.Error = $_.Exception.Message
        Write-FcLog "error: $($result.Error)"
        return $result
    }
    $result.RunId = $runId

    # Nothing below may escape (the caller relies on that), and the VM is always removed.
    try {
        $outRunDir = Join-Path $ResultsDir $runId
        $result.ResultsDir = $outRunDir
        New-Item -ItemType Directory -Force -Path (Join-Path $outRunDir 'out') | Out-Null
        Write-FcWinRunResultMeta -ResultsDir $outRunDir -RunId $runId -CommandText $commandText -PayloadPath $Stage.SamplePath -Audit $auditMeta
        Set-FcWinVmMetaProperty -RunId $runId -Key 'results_dir' -Value $outRunDir

        $rc = $script:EXIT_INFRA
        $timedOut = $false
        $errMsg = ''
        try {
            Send-FcWinGuestFiles -RunId $runId -WinRuntime $WinRuntime -SourceDir $Stage.Payload -GuestDir 'C:\work\in'
            Write-FcLog "Snapshotting files and registry (before)"
            $snap = Invoke-FcWinGuestCommand -RunId $runId -WinRuntime $WinRuntime -Quiet -TimeoutSec $script:AUDIT_SNAPSHOT_TIMEOUT_SEC `
                -CommandText "$script:AUDIT_GUEST_SCRIPTS\snapshot.cmd before"
            if ($snap.TimedOut -or $snap.ExitCode -ne 0) { Write-FcLog "warning: the before snapshot did not complete (exit $($snap.ExitCode))" }

            Write-FcLog "Running $($Stage.Entry) in C:\work\out (limit ${TimeoutSec}s)"
            $exec = Invoke-FcWinGuestCommand -RunId $runId -WinRuntime $WinRuntime -TimeoutSec $TimeoutSec `
                -CommandText "$script:AUDIT_GUEST_SCRIPTS\program.cmd" `
                -StdoutPath (Join-Path $outRunDir 'stdout.log') -StderrPath (Join-Path $outRunDir 'stderr.log')
            if ($exec.TimedOut) {
                $timedOut = $true
                $rc = $script:EXIT_TIMEOUT
                # Ending the exec leaves the program running in the guest: stop it, so the after
                # snapshots and the collection of its working folder see a quiet guest. Nano Server has
                # no taskkill.exe, so fc-audit.exe goes in as the stop helper (only on this path).
                try {
                    Send-FcWinGuestFiles -RunId $runId -WinRuntime $WinRuntime -SourceDir (Get-FcWinAuditExe) -GuestDir $script:AUDIT_GUEST_SCRIPTS
                } catch {
                    Write-FcLog "warning: could not upload the stop helper: $($_.Exception.Message)"
                }
                $stop = Invoke-FcWinGuestCommand -RunId $runId -WinRuntime $WinRuntime -Quiet -TimeoutSec $script:AUDIT_STOP_TIMEOUT_SEC `
                    -CommandText "$script:AUDIT_GUEST_SCRIPTS\stop.cmd"
                $result.ProgramStopped = (-not $stop.TimedOut -and $stop.ExitCode -eq 0)
                $why = if ($stop.TimedOut) { 'the stop step timed out' } else {
                    switch ($stop.ExitCode) { 0 { '' } 3 { 'no taskkill.exe in the guest and no stop helper' } 4 { 'a batch-file entry cannot be stopped by name' } default { "stopping it failed (exit $($stop.ExitCode))" } } }
                if ($result.ProgramStopped) {
                    Write-FcLog "The program did not finish within ${TimeoutSec}s and was stopped; taking the after snapshots"
                } else {
                    Write-FcLog "The program did not finish within ${TimeoutSec}s and could not be stopped ($why); taking the after snapshots while it may still run"
                }
            } else {
                $rc = [int]$exec.ExitCode
                $result.ProgramExitCode = $rc
                $result.ProgramFinished = $true
                Write-FcLog "Program exit code $rc"
            }
            if (-not (Test-FcWinMicroVmRunning $runId $WinRuntime)) { throw 'Utility VM died during the run' }

            # Taken even after a timeout (spec: in-guest snapshots): the VM is still up.
            Write-FcLog "Snapshotting files and registry (after)"
            $snap = Invoke-FcWinGuestCommand -RunId $runId -WinRuntime $WinRuntime -Quiet -TimeoutSec $script:AUDIT_SNAPSHOT_TIMEOUT_SEC `
                -CommandText "$script:AUDIT_GUEST_SCRIPTS\snapshot.cmd after"
            if ($snap.TimedOut -or $snap.ExitCode -ne 0) { Write-FcLog "warning: the after snapshot did not complete (exit $($snap.ExitCode))" }
        } catch {
            $rc = $script:EXIT_INFRA
            $errMsg = $_.Exception.Message
        } finally {
            try {
                Complete-FcWinRunResults -RunId $runId -WinRuntime $WinRuntime -OutRunDir $outRunDir `
                    -CommandText $commandText -PayloadPath $Stage.SamplePath -ExitCode $rc -TimedOut $timedOut -ErrorMessage $errMsg -Audit $auditMeta
            } catch {
                if (-not $errMsg) { $errMsg = "collecting the results failed: $($_.Exception.Message)" }
            }
        }
        if ($errMsg) {
            $result.Error = $errMsg
            Write-FcLog "error: $errMsg"
            return $result
        }
        # The report needs the collected snapshots; a refused or failed collection means no report.
        $collection = (Get-Content -LiteralPath (Join-Path $outRunDir 'meta.json') -Raw | ConvertFrom-Json).collection
        if (-not $collection -or [string]$collection.status -ne 'ok') {
            $result.Error = "output collection $(if ($collection) { $collection.status } else { 'missing' }): $(if ($collection) { $collection.reason } else { '' })"
            Write-FcLog "error: $($result.Error)"
            return $result
        }
        $result.Ok = $true
        return $result
    } catch {
        $result.Ok = $false
        $result.Error = $_.Exception.Message
        Write-FcLog "error: $($result.Error)"
        return $result
    } finally {
        try { Remove-FcWinVmIfActive $runId } catch { Write-FcLog "warning: could not remove VM ${runId}: $($_.Exception.Message)" }
    }
}

# Builds the report for one run with fc-audit launch-report (design D4): the controller writes only
# trusted facts (info.json), the restricted child reads the guest-derived data and writes into an
# empty staging folder, and the controller moves the expected files into place without reading them.
function Invoke-FcWinAuditReport {
    param(
        [Parameter(Mandatory = $true)]$Run,
        [string]$PairedRunId,
        [Parameter(Mandatory = $true)]$Stage,
        [AllowEmptyString()][string]$Arguments = '',
        [Parameter(Mandatory = $true)][int]$TimeoutSec
    )
    $work = Join-Path ([System.IO.Path]::GetTempPath()) "fc-audit-report-$($Run.RunId)-$([guid]::NewGuid().ToString('N'))"
    $staging = Join-Path $work 'out'
    New-Item -ItemType Directory -Force -Path $staging | Out-Null
    try {
        $info = [ordered]@{
            run_id            = $Run.RunId
            paired_run_id     = $(if ($PairedRunId) { $PairedRunId } else { $null })
            mode              = $Run.Mode
            sample_path       = $Stage.SamplePath
            entry             = $Stage.Entry
            sha256            = $Stage.Sha256
            arguments         = $Arguments
            program_exit_code = $Run.ProgramExitCode
            program_finished  = [bool]$Run.ProgramFinished
            program_stopped   = [bool]$Run.ProgramStopped
            timeout_sec       = $TimeoutSec
        }
        $infoPath = Join-Path $work 'info.json'
        Write-FcTextFile -Path $infoPath -Text ($info | ConvertTo-Json -Depth 3)
        $outLog = Join-Path $work 'report.out'
        $errLog = Join-Path $work 'report.err'
        $code = [FcProc]::Run((Get-FcWinAuditExe), (ConvertTo-FcArgString @('launch-report', '--run', $Run.ResultsDir, '--info', $infoPath, '--out', $staging)),
            $null, $outLog, $errLog, $false, 180 * 1000)
        if ($code -ne 0) {
            $why = (Get-Content -LiteralPath $errLog -Raw -ErrorAction SilentlyContinue)
            if ($code -eq [FcProc]::TimedOut) { $why = 'fc-audit did not finish' }
            throw "the report could not be built (exit $code): $("$why".Trim())"
        }
        # Only the expected regular files are moved into place.
        $odd = Get-ChildItem -LiteralPath $staging -Recurse -Force | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint } | Select-Object -First 1
        if ($odd) { throw "unexpected link in the report staging folder: $($odd.Name)" }
        foreach ($name in @('audit-report.md', 'audit-report.json')) {
            $f = Join-Path $staging $name
            if (-not (Test-Path -LiteralPath $f -PathType Leaf)) { throw "fc-audit did not write $name" }
        }
        $lists = Join-Path $Run.ResultsDir 'audit'
        New-Item -ItemType Directory -Force -Path $lists | Out-Null
        foreach ($f in @(Get-ChildItem -LiteralPath (Join-Path $staging 'audit') -File -ErrorAction SilentlyContinue)) {
            if ($f.Name -in @('files-created.txt', 'files-deleted.txt', 'registry-changes.txt')) {
                Move-Item -LiteralPath $f.FullName -Destination (Join-Path $lists $f.Name) -Force
            }
        }
        Move-Item -LiteralPath (Join-Path $staging 'audit-report.json') -Destination (Join-Path $Run.ResultsDir 'audit-report.json') -Force
        Move-Item -LiteralPath (Join-Path $staging 'audit-report.md') -Destination (Join-Path $Run.ResultsDir 'audit-report.md') -Force
        return (Join-Path $Run.ResultsDir 'audit-report.md')
    } finally {
        Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# 'audit': stage, run each mode, build the reports, clean up. Returns the exit code (spec: audit exit codes).
function Invoke-FcWinAudit {
    param(
        [Parameter(Mandatory = $true)][string]$Sample,
        [string]$Entry,
        [string[]]$Exclude = @(),
        [AllowEmptyString()][string]$Arguments = '',
        [string]$StagingDir,
        [Parameter(Mandatory = $true)][string[]]$Modes,
        [Parameter(Mandatory = $true)][string]$WinRuntime,
        [Parameter(Mandatory = $true)][string]$ImageRepo,
        [Parameter(Mandatory = $true)][string]$Flavour,
        [int]$Vcpu,
        [int]$MemMib,
        [string]$AllowCsv = '',
        [Parameter(Mandatory = $true)][int]$TimeoutSec,
        [bool]$Keep = $false,
        [Parameter(Mandatory = $true)][string]$ResultsDir
    )
    if (-not (Test-FcWinAuditPresent)) {
        Write-FcLog "ERROR: the audit report tool (fc-audit.exe) is missing; rerun '.\fc.ps1 setup -Guest windows' in an elevated prompt."
        return $script:EXIT_INFRA
    }
    try {
        $stage = New-FcWinAuditStage -Sample $Sample -Entry $Entry -Exclude $Exclude -Arguments $Arguments -StagingDir $StagingDir
    } catch {
        Write-FcLog "ERROR: $($_.Exception.Message)"
        return $script:EXIT_INFRA
    }
    $rc = 0
    $runs = @()
    try {
        Write-FcLog "Auditing $($stage.Entry) (SHA-256 $($stage.Sha256)) in $($Modes -join ' then ') mode"
        foreach ($m in $Modes) {
            $runs += Invoke-FcWinAuditRun -Stage $stage -Mode $m -WinRuntime $WinRuntime -ImageRepo $ImageRepo -Flavour $Flavour `
                -Vcpu $Vcpu -MemMib $MemMib -AllowCsv $AllowCsv -TimeoutSec $TimeoutSec -Keep $Keep -ResultsDir $ResultsDir -Arguments $Arguments
        }
        # Reports come last, so each one can name the other run of the pair.
        foreach ($r in $runs) {
            if (-not $r.Ok) { $rc = $script:EXIT_INFRA; continue }
            $other = @($runs | Where-Object { $_.RunId -and $_.RunId -ne $r.RunId } | ForEach-Object { $_.RunId }) | Select-Object -First 1
            try {
                $report = Invoke-FcWinAuditReport -Run $r -PairedRunId $other -Stage $stage -Arguments $Arguments -TimeoutSec $TimeoutSec
                Write-FcLog "$($r.Mode) report: $report"
            } catch {
                $rc = $script:EXIT_INFRA
                Write-FcLog "error: run $($r.RunId): $($_.Exception.Message)"
            }
        }
    } finally {
        Remove-FcWinAuditStage $stage
    }
    foreach ($r in $runs) {
        $state = if ($r.Ok) { if ($r.ProgramFinished) { "program exit $($r.ProgramExitCode)" } elseif ($r.ProgramStopped) { 'program did not finish (stopped at the limit)' } else { 'program did not finish (could not be stopped)' } } else { "FAILED: $($r.Error)" }
        Write-FcLog ("{0,-9} {1} {2}" -f $r.Mode, $(if ($r.RunId) { $r.RunId } else { '(no VM)' }), $state)
    }
    return $rc
}

function Remove-FcWinAuditStage($Stage) {
    if ($Stage -and $Stage.Root -and (Test-Path -LiteralPath $Stage.Root)) {
        Remove-Item -LiteralPath $Stage.Root -Recurse -Force -ErrorAction SilentlyContinue
    }
}
