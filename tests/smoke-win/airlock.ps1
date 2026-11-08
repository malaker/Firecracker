# airlock.ps1 - Smoke test for the guest output airlock on Windows guests (spec: guest-output-airlock;
# sandbox-test-runs / Result collection). Every run with output boots an extra airlock VM.
param([ValidateSet('docker', 'containerd')][string]$WinRuntime = 'docker')
$ErrorActionPreference = 'Stop'
$RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$FcPs1    = Join-Path $RepoRoot 'fc.ps1'

. (Join-Path $RepoRoot 'windows\lib\common.ps1')
. (Join-Path $RepoRoot 'windows\lib\runtime.ps1')
. (Join-Path $PSScriptRoot 'smoke-lib.ps1')

$sampleDir = Join-Path $RepoRoot 'samples\hello-win'
$script:Fails = 0
function Expect([string]$Name, [bool]$Ok) {
    if ($Ok) { Write-Host "  ok   $Name" } else { Write-Host "  FAIL $Name"; $script:Fails++ }
}
function Invoke-AirlockRun([string]$Cmd) {
    Invoke-FcSmokeRun $FcPs1 @('-Guest', 'windows', '-WinRuntime', $WinRuntime, '-Payload', $sampleDir, '-Cmd', $Cmd)
}
function Get-Collection($Run) { (Get-Content -LiteralPath (Join-Path $Run.ResultsDir 'meta.json') -Raw | ConvertFrom-Json).collection }
function Test-OutEmpty($Run) { @(Get-ChildItem -LiteralPath (Join-Path $Run.ResultsDir 'out') -Force -ErrorAction SilentlyContinue).Count -eq 0 }

function Test-Refused([string]$Name, [string]$Cmd, [string]$Reason) {
    $r = Invoke-AirlockRun $Cmd
    $c = Get-Collection $r
    Expect "${Name}: guest exit code kept" ($r.ExitCode -eq 0)
    Expect "${Name}: collection refused in meta.json" ($c.status -eq 'refused')
    Expect "${Name}: reason names the entry ($($c.reason))" ([string]$c.reason -like "*$Reason*")
    Expect "${Name}: out\ is empty" (Test-OutEmpty $r)
    Expect "${Name}: error printed" ($r.Output -match 'collection refused')
}

Write-Host "[smoke-win:airlock] runtime=$WinRuntime"

# 1. Normal output goes through an airlock that is gone afterwards.
$ok = Invoke-AirlockRun 'mkdir out\sub & echo hello> out\a.txt & echo world> out\sub\b.txt'
$c = Get-Collection $ok
Expect "output collected" ((Get-Content -LiteralPath (Join-Path $ok.ResultsDir 'out\a.txt')).Trim() -eq 'hello')
Expect "nested output collected" ((Get-Content -LiteralPath (Join-Path $ok.ResultsDir 'out\sub\b.txt')).Trim() -eq 'world')
Expect "an airlock was used" ($ok.Output -match 'Starting Windows airlock for')
Expect "collection ok in meta.json" ($c.status -eq 'ok' -and $c.files -eq 2)
$list = (& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $FcPs1 list -Guest windows -WinRuntime $WinRuntime 2>$null) -join "`n"
Expect "no airlock left after the run" (-not ($list -match 'airlock:'))

# 2. Hostile output is refused as a whole.
Test-Refused 'symbolic link' 'echo keep> out\ok.txt & mklink out\link C:\Windows\win.ini' "'./link'"
Test-Refused 'junction' 'mklink /J out\junc C:\Windows' "'./junc'"
Test-Refused 'reserved name' 'echo x> \\?\C:\work\out\con.txt' "reserved device name 'con'"
$env:FC_AIRLOCK_TEST_MAX_BYTES = '4096'
try {
    # The command runs from a batch file, so the loop variable is %%i. 200 lines of 42 bytes > 4096.
    Test-Refused 'over the byte limit' 'for /l %%i in (1,1,200) do @echo 0123456789012345678901234567890123456789>> out\big.txt' 'larger than 4096'
} finally {
    Remove-Item Env:\FC_AIRLOCK_TEST_MAX_BYTES -ErrorAction SilentlyContinue
}
# NTFS in the guest is case-insensitive and Nano Server has no fsutil to change that, so a
# Windows guest cannot produce Report.txt and report.txt; the unit tests and the Linux suite cover it.
Write-Host "  SKIP case collision: a Windows guest cannot create names that differ only in case"

# 3. A non-zero guest exit code is kept when collection is refused.
$r7 = Invoke-AirlockRun 'mklink /J out\junc C:\Windows & exit /b 7'
Expect "refused collection keeps exit code 7" ($r7.ExitCode -eq 7)

# 4. No output: no airlock at all.
$empty = Invoke-AirlockRun 'echo nothing'
Expect "empty output starts no airlock" (-not ($empty.Output -match 'Starting Windows airlock'))
Expect "empty output records ok with 0 files" ((Get-Collection $empty).status -eq 'ok' -and (Get-Collection $empty).files -eq 0)

$leftover = @(Get-ChildItem -LiteralPath ([System.IO.Path]::GetTempPath()) -Directory -Filter 'fc-airlock-*' -ErrorAction SilentlyContinue)
Expect "no staging folders left" ($leftover.Count -eq 0)

if ($script:Fails) { Write-Host "[smoke-win:airlock] $($script:Fails) check(s) failed"; exit 1 }
Write-Host "[smoke-win:airlock] PASS"
