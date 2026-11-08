# files.ps1 - Smoke test for put / get on started Windows microVMs (spec: sandbox-test-runs / Copy files
# into a started VM, Copy files out of a started VM, Guest files leave only through the airlock).
param([ValidateSet('docker', 'containerd')][string]$WinRuntime = 'docker')
$ErrorActionPreference = 'Stop'
$RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$FcPs1    = Join-Path $RepoRoot 'fc.ps1'

$script:Fails = 0
function Expect([string]$Name, [bool]$Ok) {
    if ($Ok) { Write-Host "  ok   $Name" } else { Write-Host "  FAIL $Name"; $script:Fails++ }
}
$W = @('-Guest', 'windows', '-WinRuntime', $WinRuntime)
function Invoke-FcCmd([string[]]$FcArgs) {
    $ErrorActionPreference = 'Continue'
    $out = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $FcPs1 @FcArgs @W 2>&1 | ForEach-Object { "$_" })
    [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = ($out -join "`n") }
}

Write-Host "[smoke-win:files] runtime=$WinRuntime"
$host_ = Join-Path ([System.IO.Path]::GetTempPath()) "fc-smoke-files-$([guid]::NewGuid().ToString('N'))"
$res = Join-Path $host_ 'results'
New-Item -ItemType Directory -Force -Path (Join-Path $host_ 'tools\sub'), $res | Out-Null
Set-Content -LiteralPath (Join-Path $host_ 'sample.bin') -Value 'sample' -NoNewline
Set-Content -LiteralPath (Join-Path $host_ 'tools\t1.txt') -Value 't1' -NoNewline
Set-Content -LiteralPath (Join-Path $host_ 'tools\sub\t2.txt') -Value 't2' -NoNewline

$id = ((Invoke-FcCmd @('start', '-Vcpu', '1', '-MemMib', '512')).Output -split "`n" | ForEach-Object { $_.Trim() } |
    Where-Object { $_ -match '^\d{8}-\d{6}-[0-9a-f]{4}$' } | Select-Object -Last 1)
Expect "VM started" ([bool]$id)
try {
    $null = Invoke-FcCmd @('put', $id, (Join-Path $host_ 'sample.bin'))
    Expect "put file lands in C:\work\in" ((Invoke-FcCmd @('ssh', $id, 'type C:\work\in\sample.bin')).Output -match 'sample')
    $null = Invoke-FcCmd @('put', $id, (Join-Path $host_ 'tools'), '-Dest', 'C:\work\tools')
    $t = (Invoke-FcCmd @('ssh', $id, 'type C:\work\tools\t1.txt & echo. & type C:\work\tools\sub\t2.txt')).Output
    Expect "put folder copies its contents" ($t -match 't1' -and $t -match 't2')

    $null = Invoke-FcCmd @('ssh', $id, 'mkdir C:\work\out\sub & echo report> C:\work\out\report.txt & echo deep> C:\work\out\sub\deep.txt')
    $null = Invoke-FcCmd @('get', $id, 'C:\work\out', '-Dest', (Join-Path $res 'get-dir'))
    Expect "get folder" ((Test-Path (Join-Path $res 'get-dir\report.txt')) -and (Test-Path (Join-Path $res 'get-dir\sub\deep.txt')))
    $null = Invoke-FcCmd @('get', $id, 'C:\work\in\sample.bin', '-Dest', (Join-Path $res 'get-file'))
    Expect "get single file" ((Get-Content -LiteralPath (Join-Path $res 'get-file\sample.bin') -Raw) -eq 'sample')

    $missing = Invoke-FcCmd @('get', $id, 'C:\work\nope', '-Dest', (Join-Path $res 'get-missing'))
    Expect "missing guest path fails" ($missing.ExitCode -ne 0)
    Expect "missing guest path is named" ($missing.Output -match [regex]::Escape('C:\work\nope'))

    $null = Invoke-FcCmd @('ssh', $id, 'mklink C:\work\out\link C:\Windows\win.ini')
    $link = Invoke-FcCmd @('get', $id, 'C:\work\out', '-Dest', (Join-Path $res 'get-link'))
    Expect "guest symlink is refused" ($link.ExitCode -eq 1)
    Expect "refusal names the link" ($link.Output -match "not allowed: './link'")
    Expect "refused get writes nothing" (-not (Test-Path (Join-Path $res 'get-link')))

    $nonEmpty = Invoke-FcCmd @('get', $id, 'C:\work\in\sample.bin', '-Dest', (Join-Path $res 'get-dir'))
    Expect "get into a non-empty folder fails" ($nonEmpty.ExitCode -ne 0)
} finally {
    if ($id) { $null = Invoke-FcCmd @('stop', $id) }
}
$stoppedPut = Invoke-FcCmd @('put', $id, (Join-Path $host_ 'sample.bin'))
Expect "put on a stopped VM exits 125" ($stoppedPut.ExitCode -eq 125)
$stoppedGet = Invoke-FcCmd @('get', $id, 'C:\work\out', '-Dest', (Join-Path $res 'get-stopped'))
Expect "get on a stopped VM exits 125" ($stoppedGet.ExitCode -eq 125)
Expect "nothing written for a stopped VM" (-not (Test-Path (Join-Path $res 'get-stopped')))
$list = (Invoke-FcCmd @('list')).Output
Expect "no airlock left" (-not ($list -match 'airlock:'))

Remove-Item -LiteralPath $host_ -Recurse -Force -ErrorAction SilentlyContinue
if ($script:Fails) { Write-Host "[smoke-win:files] $($script:Fails) check(s) failed"; exit 1 }
Write-Host "[smoke-win:files] PASS"
