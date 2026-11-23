# audit.ps1 - Smoke test for 'fc.ps1 audit -Guest windows' (spec: sandbox-audit).
# Part 1 needs no VMs and no elevation: argument escaping round trip through the real cmd.exe,
# staging and the option refusals. Part 2 audits samples\audit-win in real microVMs (elevated).
#   -UnitOnly    run part 1 only
param(
    [ValidateSet('docker', 'containerd')][string]$WinRuntime = 'docker',
    [switch]$UnitOnly
)
$ErrorActionPreference = 'Stop'
$RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$FcPs1    = Join-Path $RepoRoot 'fc.ps1'

. (Join-Path $RepoRoot 'windows\lib\common.ps1')
. (Join-Path $RepoRoot 'windows\lib\audit.ps1')

$script:Fails = 0
function Expect([string]$Name, [bool]$Ok, [string]$Detail = '') {
    if ($Ok) { Write-Host "  ok   $Name" } else { Write-Host "  FAIL $Name $Detail"; $script:Fails++ }
}

Write-Host "[smoke-win:audit] part 1: no VMs"

# ---------- argument escaping (design D3) ----------
# Each case goes through a real batch file and cmd.exe, into a program that prints the raw command
# line it received; the arguments must arrive byte for byte.
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) "fc-smoke-audit-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
try {
    $echo = Join-Path $tmp 'echo.ps1'
    Set-Content -LiteralPath $echo -Value '[Console]::Out.Write([Environment]::CommandLine)' -Encoding ascii
    $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $cases = @(
        '-o video.%(ext)s https://example.com/watch?v=x&t=1',
        '50% %PATH% %%',
        'a&b "c|d" (e)',
        'x|y <in >out 2>&1',
        '^caret ^^ ^',
        '"quoted & | < > ( ) ^ %OS%" outside&',
        'unbalanced " quote & here',
        'bang!value',
        "single 'quotes' and \`"escaped\`" quotes",
        # Non-ASCII from code points, so Windows PowerShell 5.1 (which reads this file as ANSI) tests the same text.
        ('caf' + [char]0x00E9 + ' ' + [char]0x00FC + [char]0x00EF + ' ' + [char]0x2713)
    )
    foreach ($c in $cases) {
        $bat = Join-Path $tmp 'prog.cmd'
        $line = "`"$ps`" -NoProfile -ExecutionPolicy Bypass -File `"$echo`" " + (ConvertTo-FcBatchArguments $c)
        [System.IO.File]::WriteAllText($bat, "@echo off`r`nchcp 65001 >nul`r`n$line`r`nexit /b %ERRORLEVEL%`r`n", [System.Text.UTF8Encoding]::new($false))
        $outFile = Join-Path $tmp 'out.txt'
        $p = Start-Process -FilePath "$env:SystemRoot\System32\cmd.exe" -ArgumentList '/S', '/C', "`"$bat`"" -NoNewWindow -Wait -PassThru -RedirectStandardOutput $outFile
        $got = [System.IO.File]::ReadAllText($outFile, [System.Text.Encoding]::UTF8)
        Expect "argument round trip: $c" ($got.EndsWith(' ' + $c)) "(got: $got)"
    }
    $empty = ConvertTo-FcBatchArguments ''
    Expect "empty arguments stay empty" ($empty -eq '')
    foreach ($bad in @("a`r`nb", "a`nb", "a`tb")) {
        $refused = $false
        try { [void](ConvertTo-FcBatchArguments $bad) } catch { $refused = $_.Exception.Message -match 'control characters' }
        Expect ("control character refused: U+{0:X4}" -f [int]($bad.ToCharArray() | Where-Object { [int]$_ -lt 0x20 } | Select-Object -First 1)) $refused
    }
} finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

# ---------- staging (design D2) ----------
function Test-Refused([scriptblock]$Block, [string]$Pattern) {
    try { & $Block | Out-Null; return $false } catch { return ($_.Exception.Message -match $Pattern) }
}
$src = Join-Path ([System.IO.Path]::GetTempPath()) "fc-smoke-audit-src-$([guid]::NewGuid().ToString('N'))"
$stageBase = Join-Path ([System.IO.Path]::GetTempPath()) "fc-smoke-audit-stage-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Force -Path (Join-Path $src 'media'), (Join-Path $src 'bin'), (Join-Path $src 'my 100% dir'), $stageBase | Out-Null
Set-Content -LiteralPath (Join-Path $src 'app.exe') -Value 'not really an exe'
Set-Content -LiteralPath (Join-Path $src 'media\song.mp3') -Value 'user data'
Set-Content -LiteralPath (Join-Path $src 'bin\tool.exe') -Value 'tool'
Set-Content -LiteralPath (Join-Path $src 'my 100% dir\x.cmd') -Value '@echo x'
function Get-StageCount { @(Get-ChildItem -LiteralPath $stageBase -Directory -Filter 'fc-audit-*').Count }
try {
    $s = New-FcWinAuditStage -Sample $src -Entry 'app.exe' -Exclude @('media') -Arguments 'a&b' -StagingDir $stageBase
    Expect "-Exclude media leaves media out of the copy" (-not (Test-Path (Join-Path $s.Payload 'app\media')) -and (Test-Path (Join-Path $s.Payload 'app\app.exe')))
    Expect "scripts are staged beside the sample, not inside it" ((Test-Path (Join-Path $s.Payload '.audit\snapshot.cmd')) -and (Test-Path (Join-Path $s.Payload '.audit\program.cmd')) -and -not (Test-Path (Join-Path $s.Payload 'app\.audit')))
    Expect "staging is under -StagingDir" ($s.Root.StartsWith($stageBase))
    Expect "entry hash is the copy's SHA-256" ($s.Sha256 -eq (Get-FileHash (Join-Path $src 'app.exe')).Hash.ToLowerInvariant())
    $prog = Get-Content -LiteralPath (Join-Path $s.Payload '.audit\program.cmd') -Raw
    Expect "program.cmd runs the entry in C:\work\out with escaped arguments" ($prog -match [regex]::Escape('cd /d C:\work\out') -and $prog -match [regex]::Escape('"C:\work\in\app\app.exe" a^&b'))
    Remove-FcWinAuditStage $s
    Expect "staging folder removed after success" ((Get-StageCount) -eq 0)

    $s = New-FcWinAuditStage -Sample $src -Entry 'my 100% dir\x.cmd' -StagingDir $stageBase
    Expect "'%' in the entry path is doubled in program.cmd" ((Get-Content -LiteralPath (Join-Path $s.Payload '.audit\program.cmd') -Raw) -match [regex]::Escape('"C:\work\in\app\my 100%% dir\x.cmd"'))
    Remove-FcWinAuditStage $s

    $s = New-FcWinAuditStage -Sample (Join-Path $src 'bin\tool.exe') -StagingDir $stageBase
    Expect "a single-file sample needs no -Entry" ($s.Entry -eq 'tool.exe' -and (Test-Path (Join-Path $s.Payload 'app\tool.exe')))
    Remove-FcWinAuditStage $s

    Expect "folder without -Entry is refused naming -Entry" (Test-Refused { New-FcWinAuditStage -Sample $src -StagingDir $stageBase } '-Entry is required')
    Expect "-Entry ..\x.exe is refused" (Test-Refused { New-FcWinAuditStage -Sample $src -Entry '..\x.exe' -StagingDir $stageBase } "no '\.\.'")
    Expect "rooted -Entry is refused" (Test-Refused { New-FcWinAuditStage -Sample $src -Entry 'C:\Windows\notepad.exe' -StagingDir $stageBase } 'relative')
    Expect "-Entry that is not in the folder is refused" (Test-Refused { New-FcWinAuditStage -Sample $src -Entry 'nope.exe' -StagingDir $stageBase } 'not a file in the -Sample folder')
    Expect "-Entry removed by -Exclude is refused" (Test-Refused { New-FcWinAuditStage -Sample $src -Entry 'bin\tool.exe' -Exclude @('bin') -StagingDir $stageBase } 'after -Exclude')
    Expect "-Exclude of a missing name is refused" (Test-Refused { New-FcWinAuditStage -Sample $src -Entry 'app.exe' -Exclude @('nothere') -StagingDir $stageBase } 'not in the -Sample folder')
    Expect "control characters in -Arguments are refused before copying" (Test-Refused { New-FcWinAuditStage -Sample $src -Entry 'app.exe' -Arguments "a`nb" -StagingDir $stageBase } 'control characters')
    Expect "-Exclude with a nested path is refused" (Test-Refused { New-FcWinAuditStage -Sample $src -Entry 'app.exe' -Exclude @('media\song.mp3') -StagingDir $stageBase } 'not paths')
    Expect "-Exclude '..' is refused" (Test-Refused { New-FcWinAuditStage -Sample $src -Entry 'app.exe' -Exclude @('..') -StagingDir $stageBase } 'not paths')
    Expect "-Exclude '.' is refused" (Test-Refused { New-FcWinAuditStage -Sample $src -Entry 'app.exe' -Exclude @('.') -StagingDir $stageBase } 'not paths')
    Expect "staging folder removed after failures" ((Get-StageCount) -eq 0)

    $s = New-FcWinAuditStage -Sample $src -Entry 'bin\tool.exe' -StagingDir $stageBase
    $stop = Get-Content -LiteralPath (Join-Path $s.Payload '.audit\stop.cmd') -Raw
    Expect "stop.cmd stops the entry's image (and its children) with taskkill when the guest has it" ($stop -match [regex]::Escape('taskkill.exe /F /T /IM "tool.exe"'))
    Expect "stop.cmd falls back to the uploaded fc-audit.exe helper" ($stop -match [regex]::Escape('C:\work\in\.audit\fc-audit.exe kill --image "tool.exe"') -and $stop -match 'exit /b 3')
    Remove-FcWinAuditStage $s
    $s = New-FcWinAuditStage -Sample $src -Entry 'my 100% dir\x.cmd' -StagingDir $stageBase
    Expect "stop.cmd for a batch-file entry stops nothing (exit 4)" ((Get-Content -LiteralPath (Join-Path $s.Payload '.audit\stop.cmd') -Raw) -match 'exit /b 4' -and (Get-Content -LiteralPath (Join-Path $s.Payload '.audit\stop.cmd') -Raw) -notmatch 'taskkill')
    Remove-FcWinAuditStage $s

    # Only junctions and symbolic links count as links, not other reparse points (cloud placeholders).
    $placeholder = [pscustomobject]@{ Attributes = [IO.FileAttributes]::ReparsePoint -bor [IO.FileAttributes]::Archive; LinkType = $null; LinkTarget = $null }
    Expect "a non-link reparse point (e.g. a OneDrive placeholder) is not treated as a link" (-not (Test-FcWinAuditLink $placeholder))
    Expect "a junction is treated as a link" (Test-FcWinAuditLink ([pscustomobject]@{ Attributes = [IO.FileAttributes]::ReparsePoint -bor [IO.FileAttributes]::Directory; LinkType = 'Junction' }))
    Expect "a plain file is not a link" (-not (Test-FcWinAuditLink (Get-Item -LiteralPath (Join-Path $src 'app.exe'))))

    $linkDir = Join-Path $src 'linked'
    $j = cmd /c mklink /J "$linkDir" "$env:SystemRoot\System32\drivers\etc" 2>&1
    $nestedDir = Join-Path $src 'media\nested-link'
    $j2 = cmd /c mklink /J "$nestedDir" "$env:SystemRoot\System32\drivers\etc" 2>&1
    if ((Test-Path -LiteralPath $linkDir) -and (Test-Path -LiteralPath $nestedDir)) {
        Expect "a junction inside the sample is refused" (Test-Refused { New-FcWinAuditStage -Sample $src -Entry 'app.exe' -Exclude @('media') -StagingDir $stageBase } 'link or junction')
        Expect "a junction nested in a subfolder is refused" (Test-Refused { New-FcWinAuditStage -Sample $src -Entry 'app.exe' -Exclude @('linked') -StagingDir $stageBase } 'nested-link')
        $s = $null
        try { $s = New-FcWinAuditStage -Sample $src -Entry 'app.exe' -Exclude @('linked', 'media') -StagingDir $stageBase } catch { }
        Expect "junctions inside excluded entries do not block the audit" ($null -ne $s -and -not (Test-Path (Join-Path $s.Payload 'app\linked')))
        Remove-FcWinAuditStage $s
        cmd /c rmdir "$linkDir" | Out-Null
        cmd /c rmdir "$nestedDir" | Out-Null
        Expect "staging folder removed after the junction refusal" ((Get-StageCount) -eq 0)
    } else {
        Write-Host "  skip junction checks (could not create junctions: $j $j2)"
    }
} finally {
    Remove-Item -LiteralPath $src, $stageBase -Recurse -Force -ErrorAction SilentlyContinue
}

# ---------- refusals before any VM starts (exit 125) ----------
# Runs fc.ps1 in a child powershell.exe. The arguments travel inside -EncodedCommand as PowerShell
# string literals: passing them as native arguments loses embedded quotes when this script itself
# runs under Windows PowerShell 5.1 ('a "b"' arrives as 'a b').
function Invoke-FcAudit([string[]]$FcArgs) {
    $ErrorActionPreference = 'Continue'
    # Parameter names ('-Guest') stay bare so they bind as names; every other token is a quoted literal.
    $lit = { param($s) if ($s -match '^-[A-Za-z][A-Za-z0-9]*$') { $s } else { "'" + ($s -replace "'", "''") + "'" } }
    # Under -EncodedCommand the child writes progress records ("Preparing modules for first use") to
    # stderr as CLIXML, which the parent then fails to decode: silence progress, and turn error records
    # into plain text, so the child's stderr carries only text.
    $script = "`$ProgressPreference = 'SilentlyContinue'; & '$($FcPs1 -replace "'", "''")' " + (($FcArgs | ForEach-Object { & $lit $_ }) -join ' ') + ' 2>&1 | ForEach-Object { "$_" }; exit $LASTEXITCODE'
    $enc = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($script))
    # -OutputFormat Text: with -EncodedCommand the child would otherwise write its error stream as CLIXML.
    $out = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -OutputFormat Text -EncodedCommand $enc 2>&1 | ForEach-Object { "$_" })
    [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = ($out -join "`n") }
}
$anyExe = Join-Path $env:SystemRoot 'System32\whoami.exe'
$refusals = @(
    @{ Name = 'Linux guests are refused naming -Guest windows and the recipes'; Args = @('audit', '-Sample', $anyExe); Want = '-Guest windows.*recipe detonate.*recipe triage-static' },
    @{ Name = '-Cmd is refused with audit'; Args = @('audit', '-Guest', 'windows', '-Sample', $anyExe, '-Cmd', 'x'); Want = '-Cmd cannot be used with audit' },
    @{ Name = '-Payload is refused with audit'; Args = @('audit', '-Guest', 'windows', '-Sample', $anyExe, '-Payload', $env:TEMP); Want = '-Payload cannot be used with audit' },
    @{ Name = 'audit without -Sample is refused'; Args = @('audit', '-Guest', 'windows'); Want = 'needs -Sample' },
    @{ Name = '-Arguments outside audit is refused'; Args = @('run', '-Guest', 'windows', '-Payload', $env:TEMP, '-Cmd', 'x', '-Arguments', 'y'); Want = 'only apply to audit' },
    @{ Name = '-Allow with -Net isolated is refused'; Args = @('audit', '-Guest', 'windows', '-WinRuntime', $WinRuntime, '-Sample', $anyExe, '-Net', 'isolated', '-Allow', '1.1.1.1/32'); Want = '-Allow only applies to -Net networked' }
)
foreach ($r in $refusals) {
    $res = Invoke-FcAudit $r.Args
    Expect $r.Name ($res.ExitCode -eq 125 -and $res.Output -match $r.Want) "(exit $($res.ExitCode): $($res.Output))"
}

if ($UnitOnly) {
    if ($script:Fails) { Write-Host "[smoke-win:audit] $($script:Fails) check(s) FAILED"; exit 1 }
    Write-Host "[smoke-win:audit] part 1 passed"
    exit 0
}

# ---------- part 2: real audits (elevated) ----------
Write-Host "[smoke-win:audit] part 2: audits of samples\audit-win (runtime=$WinRuntime)"
if (-not (Test-FcAdmin)) { throw 'Part 2 needs an elevated prompt (or pass -UnitOnly).' }

function Get-Reports([string]$Output) {
    $map = @{}
    foreach ($m in [regex]::Matches($Output, '(?m)(isolated|networked) report: (.+?audit-report\.md)\s*$')) { $map[$m.Groups[1].Value] = $m.Groups[2].Value }
    $map
}
function Read-ReportJson([string]$Md) { Get-Content -LiteralPath ([System.IO.Path]::ChangeExtension($Md, '.json')) -Raw | ConvertFrom-Json }
function Get-TempStages { @(Get-ChildItem -LiteralPath ([System.IO.Path]::GetTempPath()) -Directory -Filter 'fc-audit-*' -ErrorAction SilentlyContinue | ForEach-Object Name) }

# The probe is built for this test; it is a real .exe, so it records its raw command line exactly.
$probeDir = Join-Path ([System.IO.Path]::GetTempPath()) "fc-smoke-audit-probe-$([guid]::NewGuid().ToString('N'))"
$pub = Invoke-FcNative -Exe 'dotnet' -ArgList @('publish', (Join-Path $RepoRoot 'samples\audit-win\AuditProbe.csproj'), '-c', 'Release', '-r', 'win-x64',
    '--self-contained', 'true', '-p:PublishSingleFile=true', '-p:DebugType=none', '-o', $probeDir, '--nologo')
if ($pub.ExitCode -ne 0) { throw "Building samples\audit-win failed: $($pub.Output)" }
$probe = Join-Path $probeDir 'fc-audit-probe.exe'
$stagesBefore = Get-TempStages
$W = @('-Guest', 'windows', '-WinRuntime', $WinRuntime)
try {
    # Shell characters plus non-ASCII (from code points, so Windows PowerShell 5.1 sends the same text).
    $probeArgs = 'a&b "c|d" (e) 50% caf' + [char]0x00E9 + ' ' + [char]0x2713
    $res = Invoke-FcAudit (@('audit', '-Sample', $probe, '-Arguments', $probeArgs) + $W)
    $res.Output | Out-Host
    Expect "audit of the probe exits 0" ($res.ExitCode -eq 0) "(exit $($res.ExitCode))"
    $rep = Get-Reports $res.Output
    Expect "two runs: isolated then networked, each with a report" ($rep.ContainsKey('isolated') -and $rep.ContainsKey('networked') -and (Test-Path $rep['isolated']) -and (Test-Path $rep['networked']))
    if ($rep.ContainsKey('isolated') -and $rep.ContainsKey('networked')) {
        $iso = Read-ReportJson $rep['isolated']; $net = Read-ReportJson $rep['networked']
        $isoDir = Split-Path -Parent $rep['isolated']; $netDir = Split-Path -Parent $rep['networked']
        Expect "the reports name each other's run" ($iso.paired_run_id -eq $net.run_id -and $net.paired_run_id -eq $iso.run_id)
        Expect "isolated report states no network" ($iso.network.status -eq 'isolated' -and (Get-Content -LiteralPath $rep['isolated'] -Raw) -match 'no network device')
        $ex = @($net.network.destinations | Where-Object { $_.host -eq 'example.com' -and $_.port -eq 80 -and $_.decision -eq 'allowed' })
        Expect "networked report lists example.com:80 allowed" ($ex.Count -eq 1)
        foreach ($pair in @(@('isolated', $iso, $isoDir), @('networked', $net, $netDir))) {
            $n, $j, $d = $pair
            Expect "$n`: created file listed" (@($j.files.created) -contains 'C:\Users\Public\fc-audit-probe.txt')
            $hkcu = @($j.registry | Where-Object { $_.hive -eq 'HKCU' })[0]
            Expect "$n`: HKCU\Software\FcAuditProbe value x added" (@($hkcu.added | Where-Object { $_.key -like '*\Software\FcAuditProbe' -and $_.name -eq '"x"' }).Count -eq 1)
            Expect "$n`: output file listed" (@($j.outputs.files | ForEach-Object path) -contains 'out\out-file.txt')
            $got = [System.IO.File]::ReadAllText((Join-Path $d 'out\args.txt'))
            Expect "$n`: the probe received its arguments exactly" ($got -eq $probeArgs) "(got: $got)"
            Expect "$n`: program exit code 0 recorded" ($j.program.finished -and $j.program.exit_code -eq 0)
            $meta = Get-Content -LiteralPath (Join-Path $d 'meta.json') -Raw | ConvertFrom-Json
            Expect "$n`: meta.json records the audit" ($meta.audit.sample -eq 'fc-audit-probe.exe' -and $meta.audit.sha256 -eq $j.sample.sha256)
            Expect "$n`: full lists are in audit\" (Test-Path (Join-Path $d 'audit\files-created.txt'))
        }
    }

    # A program that never ends: the after snapshots are still taken.
    $res = Invoke-FcAudit (@('audit', '-Sample', $probe, '-Arguments', '--hang', '-Net', 'isolated', '-Timeout', '20s') + $W)
    $res.Output | Out-Host
    $rep = Get-Reports $res.Output
    Expect "audit of a never-ending program exits 0" ($res.ExitCode -eq 0) "(exit $($res.ExitCode))"
    if ($rep.ContainsKey('isolated')) {
        $j = Read-ReportJson $rep['isolated']; $d = Split-Path -Parent $rep['isolated']
        Expect "never-ending program: report says it did not finish" ($j.program.did_not_finish -and $null -eq $j.program.exit_code)
        Expect "never-ending program: run exit code 124" ((Get-Content -LiteralPath (Join-Path $d 'exit_code') -Raw).Trim() -eq '124')
        Expect "never-ending program: after snapshots taken" ((Test-Path (Join-Path $d 'out\_audit\fs-after.txt')) -and $j.files.status -eq 'ok')
        Expect "never-ending program: stopped at the limit" ($j.program.stopped) "(report: $($j.program | ConvertTo-Json -Compress); a 'could not be stopped' line in the output above says why)"
    } else {
        Expect "never-ending program: report written" $false
    }

    # A program that keeps writing to its working folder past the limit: it is stopped before the
    # after snapshots, so the snapshots and the collection of C:\work\out still succeed.
    $res = Invoke-FcAudit (@('audit', '-Sample', $probe, '-Arguments', '--hang-write', '-Net', 'isolated', '-Timeout', '20s') + $W)
    $res.Output | Out-Host
    $rep = Get-Reports $res.Output
    Expect "audit of a program that keeps writing exits 0" ($res.ExitCode -eq 0) "(exit $($res.ExitCode))"
    if ($rep.ContainsKey('isolated')) {
        $j = Read-ReportJson $rep['isolated']; $d = Split-Path -Parent $rep['isolated']
        Expect "program that keeps writing: stopped, snapshots compared, output collected" ($j.program.stopped -and $j.files.status -eq 'ok' -and (Test-Path (Join-Path $d 'out\grow.txt')))
        $grow = (Get-Item -LiteralPath (Join-Path $d 'out\grow.txt')).Length
        Expect "program that keeps writing: grow.txt listed in the report" (@($j.outputs.files | ForEach-Object path) -contains 'out\grow.txt') "(grow.txt is $grow bytes)"
    } else {
        Expect "program that keeps writing: report written" $false
    }

    # A missing report tool is refused before any VM starts.
    $auditExe = Get-FcWinAuditExe
    $hidden = "$auditExe.smoke-hidden"
    Move-Item -LiteralPath $auditExe -Destination $hidden
    try {
        $res = Invoke-FcAudit (@('audit', '-Sample', $probe) + $W)
        Expect "missing fc-audit.exe is refused with exit 125 and a setup hint" ($res.ExitCode -eq 125 -and $res.Output -match 'setup -Guest windows') "(exit $($res.ExitCode))"
    } finally {
        Move-Item -LiteralPath $hidden -Destination $auditExe
    }

    $left = @(Get-TempStages | Where-Object { $stagesBefore -notcontains $_ })
    Expect "no staging or report folders left in the temp folder" ($left.Count -eq 0) "($($left -join ', '))"
} finally {
    Remove-Item -LiteralPath $probeDir -Recurse -Force -ErrorAction SilentlyContinue
}

if ($script:Fails) { Write-Host "[smoke-win:audit] $($script:Fails) check(s) FAILED"; exit 1 }
Write-Host "[smoke-win:audit] PASSED"
exit 0
