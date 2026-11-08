# airlock.ps1 - Guest output airlock for Windows guests (change: guest-output-airlock, design D4/D7/D8).
# Guest files reach the host only through a fresh airlock microVM: the host copies the guest's
# tar stream as opaque bytes, fc-airlock validates and re-encodes it inside the airlock as
# ContainerUser, and fc-airlock re-checks and unpacks it on the host under a non-admin token.
# The host never runs tar on guest data.
Set-StrictMode -Version Latest

$script:AIRLOCK_VCPU             = 1
$script:AIRLOCK_MEM_MIB          = 256
$script:AIRLOCK_LIFETIME_SEC     = 300
$script:AIRLOCK_PULL_TIMEOUT_SEC = 180
$script:AIRLOCK_VALIDATE_TIMEOUT_SEC = 240
$script:AIRLOCK_UNPACK_TIMEOUT_SEC   = 200
$script:AIRLOCK_GUEST_EXE        = 'C:\fc\fc-airlock.exe'
$script:AIRLOCK_GUEST_USER       = 'ContainerUser'

function Get-FcWinAirlockDir { Join-Path (Get-FcWinBinDir) 'airlock' }
function Get-FcWinAirlockExe { Join-Path (Get-FcWinAirlockDir) 'fc-airlock.exe' }

function Test-FcWinAirlockPresent {
    $exe = Get-FcWinAirlockExe
    if (-not (Test-Path -LiteralPath $exe)) { return $false }
    $r = Invoke-FcNative -Exe $exe -ArgList @('--version')
    return ($r.ExitCode -eq 0 -and $r.Output -match '^fc-airlock ')
}

# Total-bytes limit; must match FcAirlock.Core.Limits. FC_AIRLOCK_TEST_MAX_BYTES can only lower it.
function Get-FcWinAirlockMaxBytes {
    $def = [long]1GB
    $v = [long]0
    if ($env:FC_AIRLOCK_TEST_MAX_BYTES -and [long]::TryParse($env:FC_AIRLOCK_TEST_MAX_BYTES, [ref]$v) -and $v -gt 0 -and $v -lt $def) { return $v }
    return $def
}
# Cap for the guest's tar stream and the airlock output: total + 1536 * max entries + 1 MiB.
function Get-FcWinAirlockStreamCap { (Get-FcWinAirlockMaxBytes) + 1536L * 10000 + 1MB }

function New-FcWinAirlockResult([string]$Status, [string]$Reason = '', [long]$Files = 0, [long]$Bytes = 0) {
    [pscustomobject]@{ Status = $Status; Reason = $Reason; Files = $Files; Bytes = $Bytes }
}

# fc-airlock's one-line reason ("refused: ...", "malformed: ...", "error: ..."), safe to print.
function Get-FcWinAirlockReason([string]$StderrFile, [string]$Fallback) {
    $line = ''
    if (Test-Path -LiteralPath $StderrFile) {
        $line = @(Get-Content -LiteralPath $StderrFile -ErrorAction SilentlyContinue | Where-Object { $_ -match '^(refused|malformed|error): ' } | Select-Object -First 1)
        $line = if ($line.Count) { [string]$line[0] } else { '' }
    }
    if (-not $line) { $line = $Fallback }
    $line = $line -replace '^refused: ', '' -replace '[\x00-\x08\x0B-\x1F\x7F]', ''
    if ($line.Length -gt 500) { $line = $line.Substring(0, 500) }
    return $line
}

# Real exit code of an exec: nerdctl exits 1 for any failure and reports the guest's code on stderr.
function Resolve-FcWinExecCode([string]$WinRuntime, [int]$Rc, [string]$StderrFile) {
    if ($WinRuntime -eq 'containerd' -and $Rc -eq 1) { return (Resolve-FcNerdctlExecExitCode -StderrFile $StderrFile -Fallback $Rc) }
    return $Rc
}

<#
  Copies <GuestPath> (a folder's contents, or a single file) of running VM <SrcRunId> into
  <DestDir>, which must not exist or be empty, through a fresh airlock VM. <AfterPull> runs once
  the guest's bytes are on the host (run collection stops the source VM there). A missing guest
  path is an empty transfer unless -MissingIsError. Returns Status (ok|refused|failed), Reason,
  Files, Bytes; never throws.
#>
function Invoke-FcWinAirlockTransfer {
    param(
        [Parameter(Mandatory = $true)][string]$SrcRunId,
        [Parameter(Mandatory = $true)][string]$WinRuntime,
        [Parameter(Mandatory = $true)][string]$GuestPath,
        [Parameter(Mandatory = $true)][string]$DestDir,
        [scriptblock]$AfterPull,
        [switch]$MissingIsError
    )
    $afterDone = $false
    $work = $null
    $result = $null
    try {
        if ((Test-Path -LiteralPath $DestDir) -and @(Get-ChildItem -LiteralPath $DestDir -Force -ErrorAction SilentlyContinue).Count -gt 0) {
            $result = New-FcWinAirlockResult failed "destination $DestDir is not empty"
            return $result
        }
        # The probe runs as a batch file; refuse what cmd.exe would interpret inside quotes.
        if ($GuestPath -match '["%!\r\n]' -or -not $GuestPath) {
            $result = New-FcWinAirlockResult failed "unsupported characters in guest path '$GuestPath'"
            return $result
        }
        $gp = $GuestPath.TrimEnd('\')
        $work = Join-Path ([System.IO.Path]::GetTempPath()) "fc-airlock-$SrcRunId-$([guid]::NewGuid().ToString('N'))"
        New-Item -ItemType Directory -Force -Path $work | Out-Null

        # 1. What is there? An empty or missing folder needs no airlock (a lying guest only hurts itself).
        $probeOut = Join-Path $work 'probe.out'
        $probe = Invoke-FcWinGuestCommand -RunId $SrcRunId -WinRuntime $WinRuntime -Quiet -TimeoutSec 60 -StdoutPath $probeOut `
            -StderrPath (Join-Path $work 'probe.err') `
            -CommandText "if exist `"$gp\`" (echo d& dir /b /a `"$gp`" 2>nul& echo ::links::& dir /s /b /a:l `"$gp`" 2>nul) else if exist `"$gp`" (echo f) else (echo missing)"
        $all = @(if (Test-Path -LiteralPath $probeOut) { Get-Content -LiteralPath $probeOut | Where-Object { $_.Trim() } })
        # Entries before the marker list the folder; entries after it are reparse points.
        $marker = [array]::IndexOf($all, '::links::')
        $lines = @(if ($marker -gt 0) { $all[0..($marker - 1)] } elseif ($marker -lt 0) { $all })
        $links = @(if ($marker -ge 0 -and $marker + 1 -lt $all.Count) { $all[($marker + 1)..($all.Count - 1)] })
        if ($probe.TimedOut -or $lines.Count -eq 0) {
            if ($AfterPull) { & $AfterPull }; $afterDone = $true
            $result = New-FcWinAirlockResult failed "could not reach VM $SrcRunId to read its output"
            return $result
        }
        $kind = $lines[0].Trim()
        if ($kind -eq 'missing' -and $MissingIsError) {
            if ($AfterPull) { & $AfterPull }; $afterDone = $true
            $result = New-FcWinAirlockResult failed "guest path $GuestPath does not exist"
            return $result
        }
        # Windows tar follows junctions and directory links instead of archiving them, so the
        # airlock would never see them: refuse here. (A guest that hides one only gets its own
        # files collected, within the limits.)
        if ($links.Count -gt 0) {
            if ($AfterPull) { & $AfterPull }; $afterDone = $true
            $first = [string]$links[0]
            $rel = if ($first.StartsWith("$gp\", [StringComparison]::OrdinalIgnoreCase)) { $first.Substring($gp.Length + 1) } else { $first }
            $rel = ($rel -replace '\\', '/') -replace '[\x00-\x1F\x7F]', ''
            $result = New-FcWinAirlockResult refused "junction or symbolic link is not allowed: './$rel'"
            return $result
        }
        if ($kind -ne 'f' -and $lines.Count -lt 2) {
            if ($AfterPull) { & $AfterPull }; $afterDone = $true
            New-Item -ItemType Directory -Force -Path $DestDir | Out-Null
            $result = New-FcWinAirlockResult ok
            return $result
        }
        $tarArgs = if ($kind -eq 'f') { @('-cf', '-', '-C', (Split-Path -Parent $gp), (Split-Path -Leaf $gp)) } else { @('-cf', '-', '-C', $gp, '.') }

        # 2. Pull the guest's archive as opaque bytes, capped.
        $cap = Get-FcWinAirlockStreamCap
        $S = Join-Path $work 'S'
        $pullErr = Join-Path $work 'pull.err'
        $rc = Invoke-FcRuntimeProcess -WinRuntime $WinRuntime -StdoutFile $S -StderrFile $pullErr -TimeoutSec $script:AIRLOCK_PULL_TIMEOUT_SEC `
            -StdoutMaxBytes $cap -ArgList (@('exec', '-u', $script:GUEST_USER, (Get-FcContainerName $SrcRunId), 'tar.exe') + $tarArgs)
        if ($AfterPull) { & $AfterPull }; $afterDone = $true
        if ($rc -eq [FcProc]::CapExceeded) { $result = New-FcWinAirlockResult refused "guest output is larger than the $cap-byte cap"; return $result }
        if ($rc -eq [FcProc]::TimedOut) { $result = New-FcWinAirlockResult refused "timed out reading the guest output after $($script:AIRLOCK_PULL_TIMEOUT_SEC)s"; return $result }
        # The guest's exit code is the guest's to choose (tar warnings exit 1 too): whatever bytes
        # arrived go to the airlock, which decides. Only "nothing at all" is a failed read.
        $pulled = if (Test-Path -LiteralPath $S) { (Get-Item -LiteralPath $S).Length } else { 0 }
        if ((Resolve-FcWinExecCode $WinRuntime $rc $pullErr) -ne 0 -and $pulled -eq 0) { $result = New-FcWinAirlockResult failed "could not read the guest output (exit $rc)"; return $result }

        $result = Invoke-FcWinAirlockRun -SrcRunId $SrcRunId -WinRuntime $WinRuntime -Work $work -Cap $cap -DestDir $DestDir
        return $result
    } catch {
        $result = New-FcWinAirlockResult failed $_.Exception.Message
        return $result
    } finally {
        if (-not $afterDone -and $AfterPull) { try { & $AfterPull } catch {} }
        if ($work -and (Test-Path -LiteralPath $work)) { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
        if ($result -and $result.Status -ne 'ok') { Write-FcLog "collection $($result.Status): $($result.Reason)" }
    }
}

# Steps 3-8 of design D4, with the guest's archive in <Work>\S.
function Invoke-FcWinAirlockRun([string]$SrcRunId, [string]$WinRuntime, [string]$Work, [long]$Cap, [string]$DestDir) {
    $cfg = Get-FcWinConfig
    $repo = if ($cfg.image_repo) { [string]$cfg.image_repo } else { 'malaker/nanoserver' }
    $flavour = if ($cfg.default_flavour) { [string]$cfg.default_flavour } else { 'aspnet-x86' }

    # 3. Fresh airlock VM (Start-FcWinVmCore lives in fcctl-win.ps1 and throws on failure).
    try {
        $aid = Start-FcWinVmCore -VmRuntime $WinRuntime -VmImageRepo $repo -VmFlavour $flavour `
            -VmVcpu $script:AIRLOCK_VCPU -VmMemMib $script:AIRLOCK_MEM_MIB -VmNet 'isolated' `
            -VmTimeoutSec $script:AIRLOCK_LIFETIME_SEC -LifetimeSec $script:AIRLOCK_LIFETIME_SEC -Role 'airlock' -Parent $SrcRunId
    } catch {
        return (New-FcWinAirlockResult failed "the airlock VM did not start: $($_.Exception.Message)")
    }

    $O = Join-Path $Work 'O'
    $valErr = Join-Path $Work 'validate.err'
    try {
        # 4. Push the validator (trusted host data) into the fresh airlock.
        Send-FcWinGuestFiles -RunId $aid -WinRuntime $WinRuntime -SourceDir (Get-FcWinAirlockDir) -GuestDir 'C:\fc'
        # 5. Validate as an unprivileged guest user.
        $envArgs = @()
        $max = Get-FcWinAirlockMaxBytes
        if ($max -lt [long]1GB) { $envArgs = @('-e', "FC_AIRLOCK_TEST_MAX_BYTES=$max") }
        $rc = Invoke-FcRuntimeProcess -WinRuntime $WinRuntime -StdinFile (Join-Path $Work 'S') -StdoutFile $O -StderrFile $valErr `
            -TimeoutSec $script:AIRLOCK_VALIDATE_TIMEOUT_SEC -StdoutMaxBytes $Cap `
            -ArgList (@('exec', '-i', '-u', $script:AIRLOCK_GUEST_USER) + $envArgs + @((Get-FcContainerName $aid), $script:AIRLOCK_GUEST_EXE, 'validate'))
    } catch {
        Remove-FcWinVmInstance -RunId $aid -ForceDeleteKeep $true
        return (New-FcWinAirlockResult failed "could not run the validator in the airlock: $($_.Exception.Message)")
    }
    # 6. The airlock is used once, whatever happened.
    Remove-FcWinVmInstance -RunId $aid -ForceDeleteKeep $true
    Remove-Item -LiteralPath (Join-Path $Work 'S') -Force -ErrorAction SilentlyContinue

    if ($rc -eq [FcProc]::CapExceeded) { return (New-FcWinAirlockResult refused "airlock output is larger than the $Cap-byte cap") }
    if ($rc -eq [FcProc]::TimedOut) { return (New-FcWinAirlockResult refused "the airlock did not finish within $($script:AIRLOCK_VALIDATE_TIMEOUT_SEC)s") }
    $code = Resolve-FcWinExecCode $WinRuntime $rc $valErr
    if ($code -eq 3 -or $code -eq 4) { return (New-FcWinAirlockResult refused (Get-FcWinAirlockReason $valErr 'refused by the airlock')) }
    if ($code -ne 0) { return (New-FcWinAirlockResult failed (Get-FcWinAirlockReason $valErr "the airlock failed (exit $code)")) }

    # 7. Re-check and unpack on the host with a non-admin token (fc-airlock launch-unpack).
    $staging = Join-Path $Work 'st'
    New-Item -ItemType Directory -Force -Path $staging | Out-Null
    $unOut = Join-Path $Work 'unpack.json'
    $unErr = Join-Path $Work 'unpack.err'
    $code = [FcProc]::Run((Get-FcWinAirlockExe), (ConvertTo-FcArgString @('launch-unpack', '--in', $O, '--staging', $staging)),
        $null, $unOut, $unErr, $false, $script:AIRLOCK_UNPACK_TIMEOUT_SEC * 1000)
    if ($code -eq [FcProc]::TimedOut) { return (New-FcWinAirlockResult failed "the host check did not finish within $($script:AIRLOCK_UNPACK_TIMEOUT_SEC)s") }
    if ($code -eq 3 -or $code -eq 4) { return (New-FcWinAirlockResult refused (Get-FcWinAirlockReason $unErr 'refused by the host check')) }
    if ($code -ne 0) { return (New-FcWinAirlockResult failed (Get-FcWinAirlockReason $unErr "the host check failed (exit $code)")) }

    # 8. Only directories and regular files may be moved into place.
    $odd = Get-ChildItem -LiteralPath $staging -Recurse -Force -ErrorAction Stop |
        Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint } | Select-Object -First 1
    if ($odd) { return (New-FcWinAirlockResult failed "unexpected link in staging: $($odd.FullName.Substring($staging.Length + 1))") }
    try {
        $summary = Get-Content -LiteralPath $unOut -Raw | ConvertFrom-Json
        $files = [long]$summary.files
        $bytes = [long]$summary.bytes
    } catch {
        return (New-FcWinAirlockResult failed 'the host check returned no summary')
    }

    if (Test-Path -LiteralPath $DestDir) {
        if (@(Get-ChildItem -LiteralPath $DestDir -Force).Count -gt 0) { return (New-FcWinAirlockResult failed "destination $DestDir is not empty") }
        Remove-Item -LiteralPath $DestDir -Force
    }
    $parent = Split-Path -Parent $DestDir
    if ($parent) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
    Move-Item -LiteralPath $staging -Destination $DestDir
    return (New-FcWinAirlockResult ok '' $files $bytes)
}
